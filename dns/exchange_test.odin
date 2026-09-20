#+test
#+private file
package dns

import "core:mem"
import "core:net"
import "core:testing"
import "core:thread"
import "core:time"

// A truncated UDP reply carries no answers; the same query retried over TCP
// on the same port does. Both peers are local: UDP and TCP share one port,
// which the two protocols allow, so the retry dials exactly where the
// datagram went.
//
// Each peer serves one exchange and leaves on its own: every blocking call
// below has a timeout, so a broken exchange fails the test instead of
// hanging the suite.
@(test)
test_truncated_udp_falls_back_to_tcp :: proc(t: ^testing.T) {
	fixture: Exchange_Fixture
	fixture.answer = net.IP4_Address{192, 0, 2, 1}

	udp_thread, tcp_thread, port, started := start_peers(t, &fixture)
	if !started { return }
	servers := [1]net.Endpoint{{address = net.IP4_Address{127, 0, 0, 1}, port = port}}
	records, lookup_err := lookup("example.com", net.DNS_Record_Type.DNS_TYPE_A, Options{servers = servers[:]}, context.temp_allocator)
	testing.expect_value(t, lookup_err, Error.None)
	if lookup_err == .None {
		defer net.destroy_dns_records(records, context.temp_allocator)
		if testing.expect_value(t, len(records), 1) {
			address, is_ip4 := records[0].(net.DNS_Record_IP4)
			if testing.expect(t, is_ip4, "the TCP answer is an A record") {
				testing.expect_value(t, address.address, fixture.answer)
			}
		}
	}

	stop_peers(&fixture, udp_thread, tcp_thread)
	testing.expect(t, fixture.udp_hit, "the query went out over UDP first")
	testing.expect(t, fixture.tcp_hit, "the truncated reply was retried over TCP")
}

// test_mismatched_replies_are_passed_over sends a forged reply for another
// query before the real truncated one. The client waits out the same attempt
// for the genuine reply instead of acting on the forgery or abandoning the
// server.
@(test)
test_mismatched_replies_are_passed_over :: proc(t: ^testing.T) {
	fixture: Exchange_Fixture
	fixture.answer = net.IP4_Address{192, 0, 2, 1}
	fixture.send_decoy = true

	udp_thread, tcp_thread, port, started := start_peers(t, &fixture)
	if !started { return }
	servers := [1]net.Endpoint{{address = net.IP4_Address{127, 0, 0, 1}, port = port}}
	records, lookup_err := lookup("example.com", net.DNS_Record_Type.DNS_TYPE_A, Options{servers = servers[:]}, context.temp_allocator)
	testing.expect_value(t, lookup_err, Error.None)
	if lookup_err == .None {
		defer net.destroy_dns_records(records, context.temp_allocator)
		if testing.expect_value(t, len(records), 1) {
			address, _ := records[0].(net.DNS_Record_IP4)
			testing.expect_value(t, address.address, fixture.answer)
		}
	}

	stop_peers(&fixture, udp_thread, tcp_thread)
	testing.expect(t, fixture.udp_hit, "the query went out over UDP first")
	testing.expect(t, fixture.tcp_hit, "the truncated reply was retried over TCP")
}

// test_split_length_prefix_is_assembled delivers the TCP length prefix in two
// pieces. The client assembles the framing rather than reading it whole.
@(test)
test_split_length_prefix_is_assembled :: proc(t: ^testing.T) {
	fixture: Exchange_Fixture
	fixture.answer = net.IP4_Address{192, 0, 2, 1}
	fixture.split_prefix = true

	udp_thread, tcp_thread, port, started := start_peers(t, &fixture)
	if !started { return }
	servers := [1]net.Endpoint{{address = net.IP4_Address{127, 0, 0, 1}, port = port}}
	records, lookup_err := lookup("example.com", net.DNS_Record_Type.DNS_TYPE_A, Options{servers = servers[:]}, context.temp_allocator)
	testing.expect_value(t, lookup_err, Error.None)
	if lookup_err == .None {
		defer net.destroy_dns_records(records, context.temp_allocator)
		if testing.expect_value(t, len(records), 1) {
			address, _ := records[0].(net.DNS_Record_IP4)
			testing.expect_value(t, address.address, fixture.answer)
		}
	}

	stop_peers(&fixture, udp_thread, tcp_thread)
	testing.expect(t, fixture.tcp_hit, "the split reply was retried over TCP")
}

// test_interruption_stops_a_lookup points a lookup at a peer that never
// answers and fires the interrupt mid-attempt. The lookup reports Cancelled
// rather than waiting out the attempt bound.
@(test)
test_interruption_stops_a_lookup :: proc(t: ^testing.T) {
	fixture: Exchange_Fixture

	udp, udp_err := net.make_bound_udp_socket(net.IP4_Address{127, 0, 0, 1}, 0)
	if udp_err != nil {
		testing.expectf(t, false, "the blackhole peer could not bind: %v", udp_err)
		return
	}
	fixture.udp = udp
	_ = net.set_option(udp, .Receive_Timeout, DNS_TIMEOUT)
	bound, bound_err := net.bound_endpoint(udp)
	if bound_err != nil {
		testing.expectf(t, false, "the blackhole peer has no port: %v", bound_err)
		net.close(udp)
		return
	}
	blackhole := thread.create(udp_blackhole_serve)
	if blackhole == nil {
		testing.expect(t, false, "the blackhole thread could not start")
		net.close(udp)
		return
	}
	blackhole.data = &fixture
	thread.start(blackhole)

	state: Interrupt_State
	servers := [1]net.Endpoint{{address = net.IP4_Address{127, 0, 0, 1}, port = bound.port}}
	_, lookup_err := lookup(
		"example.com",
		net.DNS_Record_Type.DNS_TYPE_A,
		Options{servers = servers[:], interrupt = {check = interrupt_fire, user_data = &state}},
		context.temp_allocator,
	)
	testing.expect_value(t, lookup_err, Error.Cancelled)
	testing.expect(t, state.calls > 0, "the interrupt was asked")

	thread.join(blackhole)
	thread.destroy(blackhole)
	net.close(udp)
}

// Interrupt_State counts interrupt checks; the check fires from the third
// call on, so the lookup starts its attempt before it is stopped.
Interrupt_State :: struct {
	calls: int,
}

// interrupt_fire stops a lookup once it has begun: the first calls let the
// attempt start so the stop lands mid-flight rather than at the door.
interrupt_fire :: proc(user_data: rawptr) -> bool {
	state := (^Interrupt_State)(user_data)
	state.calls += 1
	return state.calls >= 3
}

// udp_blackhole_serve reads one query and never answers it.
udp_blackhole_serve :: proc(thread: ^thread.Thread) {
	fixture := cast(^Exchange_Fixture)thread.data
	buffer: [512]u8
	net.recv_udp(fixture.udp, buffer[:])
}

// start_peers binds the UDP peer and the TCP peer on one shared port and
// starts their threads. The fixture owns both sockets; stop_peers releases
// everything. Threads are joined, never abandoned: every blocking call in a
// peer carries a timeout.
start_peers :: proc(t: ^testing.T, fixture: ^Exchange_Fixture) -> (udp_thread, tcp_thread: ^thread.Thread, port: int, started: bool) {
	udp, udp_err := net.make_bound_udp_socket(net.IP4_Address{127, 0, 0, 1}, 0)
	if udp_err != nil {
		testing.expectf(t, false, "the UDP peer could not bind: %v", udp_err)
		return nil, nil, 0, false
	}
	fixture.udp = udp
	_ = net.set_option(udp, .Receive_Timeout, DNS_TIMEOUT)
	bound, bound_err := net.bound_endpoint(udp)
	if bound_err != nil {
		testing.expectf(t, false, "the UDP peer has no port: %v", bound_err)
		net.close(udp)
		return nil, nil, 0, false
	}
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = bound.port})
	if listen_err != nil {
		testing.expectf(t, false, "the TCP peer could not listen: %v", listen_err)
		net.close(udp)
		return nil, nil, 0, false
	}
	fixture.tcp = listener
	if block_err := net.set_blocking(listener, false); block_err != nil {
		testing.expectf(t, false, "the TCP peer could not poll: %v", block_err)
		net.close(listener)
		net.close(udp)
		return nil, nil, 0, false
	}

	udp_thread, tcp_thread = thread.create(udp_truncate_serve), thread.create(tcp_answer_serve)
	if udp_thread == nil || tcp_thread == nil {
		testing.expect(t, false, "the peer threads could not start")
		if udp_thread != nil { thread.destroy(udp_thread) }
		if tcp_thread != nil { thread.destroy(tcp_thread) }
		net.close(listener)
		net.close(udp)
		return nil, nil, 0, false
	}
	udp_thread.data = fixture
	tcp_thread.data = fixture
	thread.start(udp_thread)
	thread.start(tcp_thread)
	return udp_thread, tcp_thread, bound.port, true
}

// stop_peers joins the peer threads and closes their sockets.
stop_peers :: proc(fixture: ^Exchange_Fixture, udp_thread, tcp_thread: ^thread.Thread) {
	thread.join(udp_thread)
	thread.destroy(udp_thread)
	thread.join(tcp_thread)
	thread.destroy(tcp_thread)
	net.close(fixture.tcp)
	net.close(fixture.udp)
}

// Exchange_Fixture is one UDP peer that truncates every query and one TCP
// peer that answers it, sharing a port. The flags ask for hostile shapes:
// a decoy reply before the real one, and a split length prefix. The result
// flags are read after both threads join, so no further synchronization is
// needed.
Exchange_Fixture :: struct {
	udp:          net.UDP_Socket,
	tcp:          net.TCP_Socket,
	answer:       net.IP4_Address,
	udp_hit:      bool,
	tcp_hit:      bool,
	send_decoy:   bool,
	split_prefix: bool,
}

// PEER_BOUND limits one peer exchange. It is hit only when the exchange
// itself is broken; the success path answers in milliseconds on loopback.
PEER_BOUND :: 15 * time.Second

// udp_truncate_serve answers one query with its own question back and nothing
// else: QR and TC set, no answers. The truncated bit is what sends the client
// to TCP.
udp_truncate_serve :: proc(thread: ^thread.Thread) {
	// Threads share the process-global temp allocator, whose arena is not
	// thread-safe, so a peer that allocates temporary memory needs its own.
	// The arena lives in this frame and dies with the thread.
	backing: [16 * 1024]u8
	arena: mem.Arena
	mem.arena_init(&arena, backing[:])
	context.temp_allocator = mem.arena_allocator(&arena)
	fixture := cast(^Exchange_Fixture)thread.data
	buffer: [512]u8
	received, source, recv_err := net.recv_udp(fixture.udp, buffer[:])
	if recv_err != .None || received <= HEADER_SIZE { return }
	fixture.udp_hit = true
	reply: [512]u8
	reply[0] = buffer[0]
	reply[1] = buffer[1]
	reply[2] = 0x82
	reply[3] = 0x00
	reply[5] = 0x01
	copy(reply[HEADER_SIZE:], buffer[HEADER_SIZE:received])
	if fixture.send_decoy {
		// A forged reply for another query: same shape, a flipped ID. The
		// client passes it over within the same attempt.
		decoy := reply
		decoy[0] ~= 0xFF
		net.send_udp(fixture.udp, decoy[:received], source)
	}
	net.send_udp(fixture.udp, reply[:received], source)
}

// tcp_answer_serve answers one length-prefixed query with one A record.
tcp_answer_serve :: proc(thread: ^thread.Thread) {
	backing: [16 * 1024]u8
	arena: mem.Arena
	mem.arena_init(&arena, backing[:])
	context.temp_allocator = mem.arena_allocator(&arena)
	fixture := cast(^Exchange_Fixture)thread.data
	deadline := time.tick_add(time.tick_now(), PEER_BOUND)
	for {
		conn, _, accept_err := net.accept_tcp(fixture.tcp)
		if accept_err == .None {
			tcp_answer(fixture, conn)
			return
		}
		if time.tick_since(deadline) >= 0 { return }
		time.sleep(5 * time.Millisecond)
	}
}

// tcp_answer serves the one query on an accepted connection. Its reads carry
// timeouts like every other blocking call in this file.
tcp_answer :: proc(fixture: ^Exchange_Fixture, conn: net.TCP_Socket) {
	defer net.close(conn)
	_ = net.set_option(conn, .Receive_Timeout, DNS_TIMEOUT)
	_ = net.set_option(conn, .Send_Timeout, DNS_TIMEOUT)
	fixture.tcp_hit = true

	prefix: [2]u8
	if !tcp_read_full(conn, prefix[:]) { return }
	length := int(prefix[0]) << 8 | int(prefix[1])
	if length <= HEADER_SIZE || length > 512 { return }
	query := make([]u8, length, context.temp_allocator)
	defer delete(query, context.temp_allocator)
	if !tcp_read_full(conn, query) { return }

	// Header with one answer, the question echoed back, and one A record
	// naming the queried name through a compression pointer at the question.
	head := [12]u8{0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04}
	reply: [530]u8
	reply[2] = query[0]
	reply[3] = query[1]
	reply[4] = 0x81
	reply[5] = 0x80
	reply[7] = 0x01
	reply[9] = 0x01
	at := 14 + copy(reply[14:], query[12:])
	at += copy(reply[at:], head[:])
	at += copy(reply[at:], fixture.answer[:])
	reply[0] = u8((at - 2) >> 8)
	reply[1] = u8(at - 2)
	if fixture.split_prefix {
		// The length prefix arrives in two pieces, so the client must
		// assemble it rather than read it whole.
		tcp_write_full(conn, reply[:1])
		time.sleep(50 * time.Millisecond)
		tcp_write_full(conn, reply[1:at])
		return
	}
	tcp_write_full(conn, reply[:at])
}

// tcp_read_full reads exactly len(buffer) bytes: fewer means the peer went
// away first.
tcp_read_full :: proc(socket: net.TCP_Socket, buffer: []u8) -> bool {
	pending := buffer
	for len(pending) > 0 {
		count, recv_err := net.recv_tcp(socket, pending)
		if recv_err != .None || count == 0 { return false }
		pending = pending[count:]
	}
	return true
}

// tcp_write_full writes the whole buffer.
tcp_write_full :: proc(socket: net.TCP_Socket, buffer: []u8) -> bool {
	pending := buffer
	for len(pending) > 0 {
		count, send_err := net.send_tcp(socket, pending)
		if send_err != .None || count == 0 { return false }
		pending = pending[count:]
	}
	return true
}
