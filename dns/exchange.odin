// One query against one server, over UDP with a TCP retry when the reply is
// truncated. Every wait is sliced: the interrupt is checked between slices
// and one monotonic deadline bounds the whole attempt, so unrelated datagrams
// are passed over within the same attempt rather than ending it.
package dns

import "base:runtime"
import "core:c"
import "core:mem"
import "core:net"
import "core:sys/posix"
import "core:time"

// DNS_MAX_UDP is the receive room for one datagram. Without an OPT record a
// compliant reply never exceeds 512 bytes; the headroom accepts common
// practice without treating it as a limit, and anything unparsable is
// skipped like any other unusable reply.
DNS_MAX_UDP :: 4096

// Query_Outcome is what one server attempt established. Answer carries usable
// records. Skip moves on to the next server. Retry_TCP retries the same
// query over TCP. Name_Error stops the lookup: the name does not exist, so
// no other server can answer. Cancelled stops the lookup: the caller's
// interrupt fired.
Query_Outcome :: enum {
	Answer,
	Skip,
	Retry_TCP,
	Name_Error,
	Cancelled,
}

// query_id draws the correlation nonce for one lookup from the runtime
// generator: unpredictable across the full 16-bit range, per RFC 5452 9.2.
query_id :: proc() -> (id: u16be, ok: bool) {
	if !runtime.random_generator_read_ptr(context.random_generator, &id, size_of(id)) {
		return 0, false
	}
	return id, true
}

// query_server asks one server and returns its usable answer, if any.
query_server :: proc(
	server: net.Endpoint,
	packet: []u8,
	id: u16be,
	kind: net.DNS_Record_Type,
	timeout: time.Duration,
	interrupt: Interrupt,
	allocator: mem.Allocator,
) -> (
	records: []net.DNS_Record,
	outcome: Query_Outcome,
) {
	answer, udp_outcome := exchange_udp(server, packet, id, kind, timeout, interrupt, allocator)
	switch udp_outcome {
	case .Answer:
		return answer, .Answer
	case .Retry_TCP:
		// Truncation is detected before parsing, so there is nothing to
		// release: the same query goes over TCP.
		return exchange_tcp(server, packet, id, kind, timeout, interrupt, allocator)
	case .Name_Error, .Cancelled:
		return nil, udp_outcome
	case .Skip:
		net.destroy_dns_records(answer, allocator)
		return nil, outcome_after(interrupt)
	}
	return nil, .Skip
}

// outcome_after reports a stop that fired during a failed attempt: the
// attempt's own failure must not hide the caller's interruption.
outcome_after :: proc(interrupt: Interrupt) -> Query_Outcome {
	if interrupt_now(interrupt) { return .Cancelled }
	return .Skip
}

// exchange_udp sends one query and reads datagrams until the attempt
// deadline. A datagram from anyone but the queried server, or one that does
// not answer this query, is passed over: a forgery is not an error, and the
// genuine reply may still arrive.
exchange_udp :: proc(
	server: net.Endpoint,
	packet: []u8,
	id: u16be,
	kind: net.DNS_Record_Type,
	timeout: time.Duration,
	interrupt: Interrupt,
	allocator: mem.Allocator,
) -> (
	records: []net.DNS_Record,
	outcome: Query_Outcome,
) {
	created, create_err := net.create_socket(net.family_from_endpoint(server), .UDP)
	if create_err != nil { return nil, outcome_after(interrupt) }
	socket := created.(net.UDP_Socket)
	if socket == 0 { return nil, outcome_after(interrupt) }
	defer net.close(socket)
	// Short slices keep interruption prompt; the deadline below bounds the
	// whole attempt no matter how many slices it takes.
	_ = net.set_option(socket, .Receive_Timeout, DNS_IO_SLICE)
	_ = net.set_option(socket, .Send_Timeout, DNS_IO_SLICE)

	if !udp_send(socket, packet, server, timeout, interrupt) { return nil, outcome_after(interrupt) }

	buffer: [DNS_MAX_UDP]u8
	deadline := time.tick_add(time.tick_now(), timeout)
	for time.tick_since(deadline) < 0 {
		if interrupt_now(interrupt) { return nil, .Cancelled }
		count, source, recv_err := net.recv_udp(socket, buffer[:])
		if recv_err == .Excess_Truncated {
			// The reply did not fit the datagram room. Its prefix is
			// unusable, and the whole answer is over TCP.
			return nil, .Retry_TCP
		}
		if recv_err != .None { continue }
		// A datagram from anyone but the queried server cannot answer this
		// query. Its arrival does not end the attempt.
		if count <= 0 || source != server { continue }
		if message_truncated(buffer[:count]) { return nil, .Retry_TCP }
		answer, xid, parsed := net.parse_response(buffer[:count], kind, allocator)
		if !parsed || xid != id || !response_matches(packet, buffer[:count]) {
			net.destroy_dns_records(answer, allocator)
			continue
		}
		if response_nxdomain(buffer[:count]) {
			net.destroy_dns_records(answer, allocator)
			return nil, .Name_Error
		}
		return answer, .Answer
	}
	return nil, outcome_after(interrupt)
}

// response_nxdomain reports a definitive Name Error on a reply already known
// to answer the query: no other server can answer it either, so trying them
// only spends the lookup's time.
response_nxdomain :: proc(response: []u8) -> bool {
	rcode, ok := response_rcode(response)
	return ok && rcode == Rcode_Name_Error
}

// udp_send writes the whole query, retrying across slices until the attempt
// deadline. A socket failure is an unusable server, not a failed lookup.
udp_send :: proc(socket: net.UDP_Socket, packet: []u8, server: net.Endpoint, timeout: time.Duration, interrupt: Interrupt) -> bool {
	deadline := time.tick_add(time.tick_now(), timeout)
	for time.tick_since(deadline) < 0 {
		if interrupt_now(interrupt) { return false }
		written, send_err := net.send_udp(socket, packet, server)
		if send_err == .None {
			// A datagram is all-or-nothing, so a short write is not retryable.
			return written == len(packet)
		}
		if send_err != .Would_Block && send_err != .Interrupted && send_err != .Timeout {
			return false
		}
	}
	return false
}

// exchange_tcp retries one query over TCP: a two-octet length prefix frames
// the exchange both ways (RFC 1035 4.2.2), and the reply's own length sizes
// the read. The query size guard is the wire's own two-octet bound.
exchange_tcp :: proc(
	server: net.Endpoint,
	packet: []u8,
	id: u16be,
	kind: net.DNS_Record_Type,
	timeout: time.Duration,
	interrupt: Interrupt,
	allocator: mem.Allocator,
) -> (
	records: []net.DNS_Record,
	outcome: Query_Outcome,
) {
	if len(packet) > int(max(u16)) { return nil, outcome_after(interrupt) }
	socket, dialed := dial_tcp_deadline(server, timeout, interrupt)
	if !dialed { return nil, outcome_after(interrupt) }
	defer net.close(socket)

	prefix := [2]u8{u8(len(packet) >> 8), u8(len(packet))}
	if !tcp_send(socket, prefix[:], timeout, interrupt) { return nil, outcome_after(interrupt) }
	if !tcp_send(socket, packet, timeout, interrupt) { return nil, outcome_after(interrupt) }

	length_prefix := [2]u8{}
	if !tcp_receive(socket, length_prefix[:], timeout, interrupt) { return nil, outcome_after(interrupt) }
	length := int(length_prefix[0]) << 8 | int(length_prefix[1])
	// A reply shorter than a header names nothing; overlong lengths cannot
	// arrive in two octets, so the wire bound is the only check needed.
	if length < HEADER_SIZE { return nil, outcome_after(interrupt) }
	response := make([]u8, length, allocator)
	defer delete(response, allocator)
	if !tcp_receive(socket, response, timeout, interrupt) { return nil, outcome_after(interrupt) }
	answer, xid, parsed := net.parse_response(response, kind, allocator)
	if !parsed || xid != id || !response_matches(packet, response) {
		net.destroy_dns_records(answer, allocator)
		return nil, outcome_after(interrupt)
	}
	if response_nxdomain(response) {
		net.destroy_dns_records(answer, allocator)
		return nil, .Name_Error
	}
	return answer, .Answer
}

// tcp_send writes the whole buffer, consuming prefixes the peer accepted. A
// closed or failed stream is an unusable server.
tcp_send :: proc(socket: net.TCP_Socket, buffer: []u8, timeout: time.Duration, interrupt: Interrupt) -> bool {
	pending := buffer
	deadline := time.tick_add(time.tick_now(), timeout)
	for len(pending) > 0 {
		if interrupt_now(interrupt) { return false }
		if time.tick_since(deadline) >= 0 { return false }
		_ = net.set_option(socket, .Send_Timeout, DNS_IO_SLICE)
		written, send_err := net.send_tcp(socket, pending)
		if send_err == .None {
			if written == 0 { return false }
			pending = pending[written:]
			continue
		}
		if send_err != .Would_Block && send_err != .Interrupted && send_err != .Timeout {
			return false
		}
	}
	return true
}

// tcp_receive reads exactly len(buffer) bytes. Fewer means the peer went
// away before the framed message was complete.
tcp_receive :: proc(socket: net.TCP_Socket, buffer: []u8, timeout: time.Duration, interrupt: Interrupt) -> bool {
	pending := buffer
	deadline := time.tick_add(time.tick_now(), timeout)
	for len(pending) > 0 {
		if interrupt_now(interrupt) { return false }
		if time.tick_since(deadline) >= 0 { return false }
		_ = net.set_option(socket, .Receive_Timeout, DNS_IO_SLICE)
		count, recv_err := net.recv_tcp(socket, pending)
		if recv_err == .None {
			if count == 0 { return false }
			pending = pending[count:]
			continue
		}
		if recv_err != .Would_Block && recv_err != .Interrupted && recv_err != .Timeout {
			return false
		}
	}
	return true
}

// dial_tcp_deadline opens a TCP stream with an explicit deadline. core:net's
// dial blocks without one, and a Send timeout does not apply to connect, so
// a black-holed server would otherwise hold the attempt for the kernel's
// whole SYN budget. Non-blocking connect with a readiness poll bounds it;
// Linux is the only target.
dial_tcp_deadline :: proc(endpoint: net.Endpoint, timeout: time.Duration, interrupt: Interrupt) -> (socket: net.TCP_Socket, connected: bool) {
	family: posix.AF
	switch _ in endpoint.address {
	case net.IP4_Address:
		family = .INET
	case net.IP6_Address:
		family = .INET6
	case:
		return 0, false
	}
	fd := posix.socket(family, .STREAM)
	if c.int(fd) < 0 { return 0, false }
	ok := false
	defer if !ok { posix.close(fd) }

	flags := posix.fcntl(fd, .GETFL)
	if flags < 0 { return 0, false }
	if posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK)) < 0 { return 0, false }

	storage: posix.sockaddr_in6
	addr_len: posix.socklen_t
	fill_sockaddr(endpoint, &storage, &addr_len)
	if res := posix.connect(fd, cast(^posix.sockaddr)&storage, addr_len); res != .OK {
		if posix.errno() != .EINPROGRESS { return 0, false }
		deadline := time.tick_add(time.tick_now(), timeout)
		for {
			if interrupt_now(interrupt) { return 0, false }
			remaining := -time.tick_since(deadline)
			if remaining <= 0 { return 0, false }
			slice := DNS_IO_SLICE
			if remaining < slice { slice = remaining }
			polling := [1]posix.pollfd{{fd = fd, events = {.OUT}}}
			n := posix.poll(raw_data(polling[:]), 1, c.int(slice / time.Millisecond))
			if n == 0 { continue }
			if n < 0 { return 0, false }
			// Writability is not success; SO_ERROR carries the verdict.
			so_err: c.int
			so_len := posix.socklen_t(size_of(so_err))
			if posix.getsockopt(fd, posix.SOL_SOCKET, .ERROR, &so_err, &so_len) != .OK {
				return 0, false
			}
			if so_err != 0 { return 0, false }
			break
		}
	}
	if posix.fcntl(fd, .SETFL, flags) < 0 { return 0, false }
	ok = true
	return net.TCP_Socket(fd), true
}

// fill_sockaddr renders an endpoint into the address structure connect needs.
fill_sockaddr :: proc(endpoint: net.Endpoint, storage: ^posix.sockaddr_in6, out_len: ^posix.socklen_t) {
	switch a in endpoint.address {
	case net.IP4_Address:
		v4 := cast(^posix.sockaddr_in)storage
		v4^ = {}
		v4.sin_family = .INET
		v4.sin_port = posix.in_port_t(u16be(u16(endpoint.port)))
		bytes := a
		v4.sin_addr = transmute(posix.in_addr)bytes
		out_len^ = posix.socklen_t(size_of(posix.sockaddr_in))
	case net.IP6_Address:
		storage^ = {}
		storage.sin6_family = .INET6
		storage.sin6_port = posix.in_port_t(u16be(u16(endpoint.port)))
		groups := a
		bytes: [16]u8
		for g, i in groups {
			v := u16(g)
			bytes[i * 2] = u8(v >> 8)
			bytes[i * 2 + 1] = u8(v)
		}
		storage.sin6_addr = transmute(posix.in6_addr)bytes
		out_len^ = posix.socklen_t(size_of(posix.sockaddr_in6))
	}
}
