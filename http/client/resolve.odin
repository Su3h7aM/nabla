package client

import "base:runtime"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

// DNS_TIMEOUT bounds one nameserver attempt. An exhausted attempt moves on to the
// next nameserver; it only ends the lookup when the caller's own deadline or
// cancellation says so.
DNS_TIMEOUT :: 5 * time.Second

// DNS_MAX_RESPONSE bounds a single response datagram.
DNS_MAX_RESPONSE :: 4096

// resolve_host returns one address for hostname, preferring IPv4. Every network
// wait goes through the wait hook, so a stalled lookup is interrupted by the same
// cancellation and deadline as the rest of the request. Resolution runs on the
// calling thread, so an interrupted lookup owns nothing that outlives it.
resolve_host :: proc(hostname: string, options: Options, allocator: mem.Allocator) -> (address: net.Address, found: bool, err: Error) {
	if host, ok := hosts_lookup(hostname, allocator); ok { return host, true, .None }
	if !net.validate_hostname(hostname) { return nil, false, .Resolve }

	servers := options.nameservers
	owned := false
	if len(servers) == 0 {
		loaded, loaded_ok := system_nameservers(allocator)
		if !loaded_ok { return nil, false, .Resolve }
		servers = loaded
		owned = true
	}
	defer if owned { delete(servers, allocator) }
	if len(servers) == 0 { return nil, false, .Resolve }

	for kind in ([2]net.DNS_Record_Type{net.DNS_Record_Type.DNS_TYPE_A, net.DNS_Record_Type.DNS_TYPE_AAAA}) {
		records, query_err := query_nameservers(hostname, kind, servers, options, allocator)
		if query_err != .None { return nil, false, query_err }
		if len(records) == 0 { continue }
		defer net.destroy_dns_records(records, allocator)
		for record in records {
			#partial switch value in record {
			case net.DNS_Record_IP4:
				return value.address, true, .None
			case net.DNS_Record_IP6:
				return value.address, true, .None
			}
		}
	}
	return nil, false, .Resolve
}

// query_nameservers asks each nameserver in turn for one record type, returning an
// empty result when none of them produced a usable answer.
query_nameservers :: proc(
	hostname: string,
	kind: net.DNS_Record_Type,
	servers: []net.Endpoint,
	options: Options,
	allocator: mem.Allocator,
) -> (
	[]net.DNS_Record,
	Error,
) {
	id: u16be
	if !runtime.random_generator_read_ptr(context.random_generator, &id, size_of(id)) { return nil, .Resolve }

	packet_buffer: [net.DNS_PACKET_MIN_LEN]u8
	packet, packet_err := net.make_dns_packet(packet_buffer[:], id, hostname, kind)
	if packet_err != .None { return nil, .Resolve }

	response_buffer: [DNS_MAX_RESPONSE]u8
	for server in servers {
		count, source, exchange_err := exchange_udp(server, packet, response_buffer[:], options)
		if exchange_err != .None { return nil, exchange_err }
		// A datagram from anyone but the queried server cannot answer this query.
		if count == 0 || source != server { continue }
		records, xid, parsed := net.parse_response(response_buffer[:count], kind, allocator)
		if !parsed { continue }
		if xid != id || len(records) == 0 {
			net.destroy_dns_records(records, allocator)
			continue
		}
		return records, .None
	}
	return nil, .None
}

// exchange_udp sends one query and waits for one datagram. A server that cannot be
// reached is skipped; only cancellation and the operation deadline are terminal.
// A zero count means no usable reply arrived from this server.
exchange_udp :: proc(server: net.Endpoint, packet: []u8, buffer: []u8, options: Options) -> (count: int, source: net.Endpoint, err: Error) {
	created, create_err := net.create_socket(net.family_from_endpoint(server), .UDP)
	if create_err != .None { return 0, {}, .None }
	socket := created.(net.UDP_Socket)
	defer net.close(socket)
	if options.probe.check != nil {
		if block_err := net.set_blocking(socket, false); block_err != .None { return 0, {}, .None }
	} else {
		// Without a hook there is nothing to interrupt, so the attempt is bounded by
		// the socket itself. A discarded reply must not turn into an endless wait.
		_ = net.set_option(socket, .Receive_Timeout, DNS_TIMEOUT)
		_ = net.set_option(socket, .Send_Timeout, DNS_TIMEOUT)
	}

	sent, send_err := send_query(socket, packet, server, options)
	if send_err != .None { return 0, {}, send_err }
	if !sent { return 0, {}, .None }
	return receive_reply(socket, buffer, options)
}

send_query :: proc(socket: net.UDP_Socket, packet: []u8, server: net.Endpoint, options: Options) -> (bool, Error) {
	for {
		written, send_err := net.send_udp(socket, packet, server)
		#partial switch send_err {
		case nil:
			// A datagram is all-or-nothing, so a short write is not retryable.
			return written == len(packet), .None
		case .Would_Block:
			result, stop := wait_ready(socket, .Write, options.probe, DNS_TIMEOUT)
			if err := attempt_end(result, stop, options); err != .None {
				return false, err
			}
		case .Interrupted:
			continue
		case:
			return false, .None
		}
	}
}

receive_reply :: proc(socket: net.UDP_Socket, buffer: []u8, options: Options) -> (count: int, source: net.Endpoint, err: Error) {
	for {
		received, from, recv_err := net.recv_udp(socket, buffer)
		#partial switch recv_err {
		case nil:
			if received > 0 { return received, from, .None }
		case .Would_Block:
			result, stop := wait_ready(socket, .Read, options.probe, DNS_TIMEOUT)
			if result == .Ready { continue }
			if wait_err := attempt_end(result, stop, options); wait_err != .None {
				return 0, {}, wait_err
			}
			return 0, {}, .None
		case .Timeout:
			return 0, {}, .None
		case .Interrupted:
			continue
		case:
			// Includes an ICMP port-unreachable for this server.
			return 0, {}, .None
		}
	}
}

// attempt_end decides whether an exhausted attempt ends the request or only this
// attempt. A wait that stopped because the caller's own policy said so ends the
// request; one that merely ran out its own bound moves on to the next server,
// which is why the policy is asked again rather than inferred from the stop.
attempt_end :: proc(result: Wait_Result, stop: Transport_Stop, options: Options) -> Error {
	if result == .Ready { return .None }
	if result == .Failed { return .Recv }
	switch stop_from_wait(probe_now(options.probe)) {
	case .None:
		return .None
	case .Cancelled:
		return .Cancelled
	case .Timed_Out:
		return .Timed_Out
	case .Peer_Closed:
		return .Closed
	case .Truncated:
		return .Truncated
	case .Failed:
		return .Recv
	}
	return .None
}

// hosts_lookup consults the hosts file before any nameserver, so local names
// resolve without one.
hosts_lookup :: proc(hostname: string, allocator: mem.Allocator) -> (address: net.Address, found: bool) {
	handle, open_err := os.open(net.dns_configuration.hosts_file)
	if open_err != nil { return nil, false }
	defer os.close(handle)

	hosts, ok := net.parse_hosts(os.to_stream(handle), allocator)
	defer {
		for entry in hosts { delete(entry.name, allocator) }
		delete(hosts, allocator)
	}
	if !ok { return nil, false }

	var_ip4: net.IP4_Address
	var_ip6: net.IP6_Address
	has_ip4, has_ip6 := false, false
	for entry in hosts {
		if !strings.equal_fold(entry.name, hostname) { continue }
		#partial switch value in entry.addr {
		case net.IP4_Address:
			if !has_ip4 {
				var_ip4 = value
				has_ip4 = true
			}
		case net.IP6_Address:
			if !has_ip6 {
				var_ip6 = value
				has_ip6 = true
			}
		}
	}
	if has_ip4 { return var_ip4, true }
	if has_ip6 { return var_ip6, true }
	return nil, false
}

system_nameservers :: proc(allocator: mem.Allocator) -> ([]net.Endpoint, bool) {
	contents, read_err := os.read_entire_file(net.dns_configuration.resolv_conf, allocator)
	if read_err != nil { return nil, false }
	defer delete(contents, allocator)
	return net.parse_resolv_conf(string(contents), allocator), true
}

// host_and_port splits an authority into its name and port. A bracketed IPv6
// literal carries its port outside the brackets; any other authority with more
// than one colon is a bare IPv6 literal with no port.
host_and_port :: proc(authority: string) -> (host: string, port: int, ok: bool) {
	if authority == "" { return "", 0, false }
	if authority[0] == '[' {
		end := strings.index_byte(authority, ']')
		if end < 0 { return "", 0, false }
		host = authority[1:end]
		rest := authority[end + 1:]
		if rest == "" { return host, 0, true }
		if rest[0] != ':' { return "", 0, false }
		port, ok = parse_port(rest[1:])
		return
	}
	colons := 0
	for byte in authority { if byte == ':' { colons += 1 } }
	if colons > 1 { return authority, 0, true }
	if colon := strings.index_byte(authority, ':'); colon >= 0 {
		port, ok = parse_port(authority[colon + 1:])
		return authority[:colon], port, ok
	}
	return authority, 0, true
}

parse_port :: proc(text: string) -> (int, bool) {
	if text == "" { return 0, false }
	port := 0
	for byte in text {
		if byte < '0' || byte > '9' { return 0, false }
		port = port * 10 + int(byte - '0')
		if port > 65535 { return 0, false }
	}
	return port, port > 0
}
