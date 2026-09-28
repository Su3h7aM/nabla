// One query against one server, over UDP with a TCP retry when the reply is
// truncated. The transfers are direct calls on non-blocking sockets, and every
// wait for readiness goes through the calling thread's core:nbio event loop,
// bounded by one monotonic deadline for the whole attempt. Unrelated datagrams
// are passed over within the same attempt rather than ending it.
package dns

import "base:runtime"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:time"

// UDP_MESSAGE_MAX is the largest message UDP carries (RFC 1035 4.2.1). A longer
// reply is truncated with TC set, and no OPT record leaves this resolver to ask
// for more (RFC 6891), so a datagram that does not fit is asked for over TCP.
UDP_MESSAGE_MAX :: 512

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

// Wait is how a wait on the event loop ended.
Wait :: enum {
	Ready,
	Expired,
	Cancelled,
	Failed,
}

// outcome_of maps a wait that did not end ready onto the attempt: only the
// caller's interrupt stops the lookup, and anything else moves on.
outcome_of :: proc(wait: Wait) -> Query_Outcome {
	return .Cancelled if wait == .Cancelled else .Skip
}

// query_id draws the correlation nonce for one lookup from the runtime
// generator: unpredictable across the full 16-bit range, per RFC 5452 9.2.
query_id :: proc() -> (id: u16be, ok: bool) {
	return id, runtime.random_generator_read_ptr(context.random_generator, &id, size_of(id))
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
	deadline := time.tick_add(time.tick_now(), timeout)
	records, outcome = exchange_udp(server, packet, id, kind, deadline, interrupt, allocator)
	if outcome != .Retry_TCP { return }
	// The TCP retry gets a bound of its own: the UDP exchange may have spent
	// most of the first one before the truncated reply arrived.
	deadline = time.tick_add(time.tick_now(), timeout)
	return exchange_tcp(server, packet, id, kind, deadline, interrupt, allocator)
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
	deadline: time.Tick,
	interrupt: Interrupt,
	allocator: mem.Allocator,
) -> (
	records: []net.DNS_Record,
	outcome: Query_Outcome,
) {
	socket, create_err := nbio.create_udp_socket(net.family_from_endpoint(server))
	if create_err != nil { return nil, .Skip }
	defer net.close(socket)
	// The event loop may hand back a blocking socket, and a blocking read would
	// wait past the deadline and the interrupt.
	if net.set_blocking(socket, false) != nil { return nil, .Skip }

	for {
		written, send_err := net.send_udp(socket, packet, server)
		#partial switch send_err {
		case .None:
			// A datagram is all-or-nothing, so a short write is not retryable.
			if written != len(packet) { return nil, .Skip }
		case .Would_Block:
			if wait := wait_ready(socket, .Send, deadline, interrupt); wait != .Ready { return nil, outcome_of(wait) }
			continue
		case .Interrupted:
			continue
		case:
			return nil, .Skip
		}
		break
	}

	buffer: [UDP_MESSAGE_MAX]u8
	for {
		count, source, recv_err := net.recv_udp(socket, buffer[:])
		#partial switch recv_err {
		case .None:
		case .Excess_Truncated:
			return nil, .Retry_TCP
		case .Would_Block:
			if wait := wait_ready(socket, .Receive, deadline, interrupt); wait != .Ready { return nil, outcome_of(wait) }
			continue
		case .Interrupted:
			continue
		case:
			return nil, .Skip
		}
		// A datagram from anyone but the queried server cannot answer this
		// query. Its arrival does not end the attempt.
		reply := buffer[:count]
		if source != server || !response_matches(packet, reply) { continue }
		if message_truncated(reply) { return nil, .Retry_TCP }
		answer, response_id, parsed := net.parse_response(reply, kind, allocator)
		if !parsed || response_id != id {
			net.destroy_dns_records(answer, allocator)
			continue
		}
		return reply_outcome(reply, answer, allocator)
	}
}

// reply_outcome turns a parsed reply to this query into the attempt's outcome.
// A Name Error is definitive: no other server can answer the name either.
reply_outcome :: proc(reply: []u8, answer: []net.DNS_Record, allocator: mem.Allocator) -> ([]net.DNS_Record, Query_Outcome) {
	if response_nxdomain(reply) {
		net.destroy_dns_records(answer, allocator)
		return nil, .Name_Error
	}
	return answer, .Answer
}

// exchange_tcp retries one query over TCP: a two-octet length prefix frames
// the exchange both ways (RFC 1035 4.2.2), and the reply's own length sizes
// the read.
exchange_tcp :: proc(
	server: net.Endpoint,
	packet: []u8,
	id: u16be,
	kind: net.DNS_Record_Type,
	deadline: time.Tick,
	interrupt: Interrupt,
	allocator: mem.Allocator,
) -> (
	records: []net.DNS_Record,
	outcome: Query_Outcome,
) {
	framed: [2 + net.DNS_PACKET_MIN_LEN]u8
	if len(packet) > net.DNS_PACKET_MIN_LEN { return nil, .Skip }
	framed[0], framed[1] = u8(len(packet) >> 8), u8(len(packet))
	copy(framed[2:], packet)

	socket, dialed := dial_tcp(server, deadline, interrupt)
	if dialed != .Ready { return nil, outcome_of(dialed) }
	defer net.close(socket)

	if wait := tcp_send(socket, framed[:2 + len(packet)], deadline, interrupt); wait != .Ready { return nil, outcome_of(wait) }

	prefix: [2]u8
	if wait := tcp_receive(socket, prefix[:], deadline, interrupt); wait != .Ready { return nil, outcome_of(wait) }
	length := int(prefix[0]) << 8 | int(prefix[1])
	if length < HEADER_SIZE { return nil, .Skip }
	response, alloc_err := make([]u8, length, allocator)
	if alloc_err != nil { return nil, .Skip }
	defer delete(response, allocator)
	if wait := tcp_receive(socket, response, deadline, interrupt); wait != .Ready { return nil, outcome_of(wait) }

	if !response_matches(packet, response) { return nil, .Skip }
	answer, response_id, parsed := net.parse_response(response, kind, allocator)
	if !parsed || response_id != id {
		net.destroy_dns_records(answer, allocator)
		return nil, .Skip
	}
	return reply_outcome(response, answer, allocator)
}

// tcp_send writes the whole buffer, consuming prefixes the peer accepted.
tcp_send :: proc(socket: net.TCP_Socket, buffer: []u8, deadline: time.Tick, interrupt: Interrupt) -> Wait {
	pending := buffer
	for len(pending) > 0 {
		written, send_err := net.send_tcp(socket, pending)
		pending = pending[written:]
		#partial switch send_err {
		case .None, .Interrupted:
		case .Would_Block:
			if wait := wait_ready(socket, .Send, deadline, interrupt); wait != .Ready { return wait }
		case:
			return .Failed
		}
	}
	return .Ready
}

// tcp_receive reads exactly len(buffer) bytes. Fewer means the peer went away
// before the framed message was complete.
tcp_receive :: proc(socket: net.TCP_Socket, buffer: []u8, deadline: time.Tick, interrupt: Interrupt) -> Wait {
	pending := buffer
	for len(pending) > 0 {
		count, recv_err := net.recv_tcp(socket, pending)
		#partial switch recv_err {
		case .None:
			if count == 0 { return .Failed }
			pending = pending[count:]
		case .Interrupted:
		case .Would_Block:
			if wait := wait_ready(socket, .Receive, deadline, interrupt); wait != .Ready { return wait }
		case:
			return .Failed
		}
	}
	return .Ready
}

@(private)
Dial_State :: struct {
	socket: net.TCP_Socket,
	failed: bool,
	done:   bool,
}

// on_dialed copies the dial's answer out of the operation, which is reaped as
// soon as this callback returns. A failed dial has already closed its socket.
@(private)
on_dialed :: proc(operation: ^nbio.Operation, state: ^Dial_State) {
	state.socket = operation.dial.socket
	state.failed = operation.dial.err != nil
	state.done = true
}

// dial_tcp opens a non-blocking TCP stream through the event loop, so the
// attempt deadline and the interrupt bound the connect as well.
dial_tcp :: proc(server: net.Endpoint, deadline: time.Tick, interrupt: Interrupt) -> (socket: net.TCP_Socket, wait: Wait) {
	state: Dial_State
	operation := nbio.dial_poly(server, &state, on_dialed)
	if wait = tick_until(operation, &state.done, deadline, interrupt); wait != .Ready { return 0, wait }
	if state.failed { return 0, .Failed }
	// The dial may hand back a blocking socket, and a blocking read would wait
	// past the deadline and the interrupt.
	if net.set_blocking(state.socket, false) != nil {
		net.close(state.socket)
		return 0, .Failed
	}
	return state.socket, .Ready
}

@(private)
Poll_State :: struct {
	result: nbio.Poll_Result,
	done:   bool,
}

@(private)
on_polled :: proc(operation: ^nbio.Operation, state: ^Poll_State) {
	state.result = operation.poll.result
	state.done = true
}

// wait_ready waits until socket is ready for event.
wait_ready :: proc(socket: net.Any_Socket, event: nbio.Poll_Event, deadline: time.Tick, interrupt: Interrupt) -> Wait {
	state: Poll_State
	operation := nbio.poll_poly(socket, event, &state, on_polled)
	if wait := tick_until(operation, &state.done, deadline, interrupt); wait != .Ready { return wait }
	return .Ready if state.result == .Ready else .Failed
}

// tick_until runs the thread's event loop until operation sets done, the deadline
// passes, or the interrupt fires. Without an interrupt check the deadline is
// the only timeout; with one, the check runs at least every DNS_IO_SLICE. An
// operation that did not finish is removed, so its callback never runs and the
// state it writes may leave scope.
tick_until :: proc(operation: ^nbio.Operation, done: ^bool, deadline: time.Tick, interrupt: Interrupt) -> Wait {
	for !done^ {
		if interrupt_now(interrupt) {
			nbio.remove(operation)
			return .Cancelled
		}
		remaining := -time.tick_since(deadline)
		if remaining <= 0 {
			nbio.remove(operation)
			return .Expired
		}
		if interrupt.check != nil { remaining = min(remaining, DNS_IO_SLICE) }
		if nbio.tick(remaining) != nil && !done^ {
			nbio.remove(operation)
			return .Failed
		}
	}
	return .Ready
}
