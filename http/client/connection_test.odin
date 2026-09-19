#+test
#+private file
package client

import "core:bytes"
import "core:nbio"
import "core:net"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:tls"

WRITE_TEST_BYTES :: 8 * 1024 * 1024
READ_TEST_BYTES: string : "a connection with no probe reads what the peer sent"

Read_Test_Server :: struct {
	listener: net.TCP_Socket,
	sent:     bool,
}

read_test_serve :: proc(thread_handle: ^thread.Thread) {
	server := cast(^Read_Test_Server)thread_handle.data
	socket, _, accept_err := net.accept_tcp(server.listener)
	if accept_err != nil { return }
	defer net.close(socket)
	if _, send_err := net.send_tcp(socket, transmute([]u8)READ_TEST_BYTES); send_err != nil { return }
	server.sent = true
}

Write_Test_Server :: struct {
	listener: net.TCP_Socket,
	expected: []u8,
	matched:  bool,
}

write_test_serve :: proc(thread_handle: ^thread.Thread) {
	server := cast(^Write_Test_Server)thread_handle.data
	socket, _, accept_err := net.accept_tcp(server.listener)
	if accept_err != nil { return }
	defer net.close(socket)
	_ = net.set_option(socket, .Receive_Timeout, 2 * time.Second)

	// Let the client's small send buffer fill before draining it. This forces the
	// non-blocking send path to return progress together with Would_Block.
	time.sleep(100 * time.Millisecond)

	offset := 0
	scratch: [16 * 1024]u8
	for offset < len(server.expected) {
		count, read_err := net.recv_tcp(socket, scratch[:])
		if read_err != nil || count <= 0 { return }
		if count > len(server.expected) - offset { return }
		if !bytes.equal(scratch[:count], server.expected[offset:offset + count]) { return }
		offset += count
	}
	server.matched = true
}

write_test_probe :: proc(_: rawptr) -> Wait_Status {
	return .Ready
}

@(test)
test_nonblocking_write_does_not_repeat_a_partially_accepted_prefix :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if !testing.expectf(t, listen_err == nil, "the test endpoint could not listen: %v", listen_err) { return }
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if !testing.expectf(t, endpoint_err == nil, "the test endpoint could not be read: %v", endpoint_err) { return }

	payload := make([]u8, WRITE_TEST_BYTES)
	defer delete(payload)
	state: u64 = 0x9e3779b97f4a7c15
	for &byte in payload {
		state = state * 6364136223846793005 + 1442695040888963407
		byte = u8(state >> 56)
	}

	if loop_err := nbio.acquire_thread_event_loop(); loop_err != nil {
		testing.fail_now(t, "the test event loop could not be started")
	}
	defer nbio.release_thread_event_loop()

	connection, dial_err := connection_dial(endpoint, {probe = {check = write_test_probe}}, context.allocator)
	if !testing.expect_value(t, dial_err, Error.None) { return }
	defer connection_destroy(connection)
	if option_err := net.set_option(connection.socket, .Send_Buffer_Size, 4096); option_err != nil {
		testing.fail_now(t, "the client send buffer could not be reduced")
	}

	server := Write_Test_Server {
		listener = listener,
		expected = payload,
	}
	worker := thread.create(write_test_serve, name = "nabla-http-write-test")
	if worker == nil {
		testing.fail_now(t, "the test server thread could not be created")
	}
	worker.data = &server
	thread.start(worker)
	defer if worker != nil {
		thread.join(worker)
		thread.destroy(worker)
	}

	accepted, write_err := connection_write_all(connection, payload)
	testing.expect_value(t, write_err, Error.None)
	testing.expect_value(t, accepted, len(payload))

	thread.join(worker)
	testing.expect(t, server.matched, "the server did not receive the payload byte-for-byte")
	thread.destroy(worker)
	worker = nil
}

// A connection with no probe has no event loop behind it, so the only wait left to
// it is blocking on the socket. That is a different connect and a different read
// from the interruptible path, and nothing else covers it.
@(test)
test_connection_without_a_probe_moves_bytes_on_the_socket :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if !testing.expectf(t, listen_err == nil, "the test endpoint could not listen: %v", listen_err) { return }
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if !testing.expectf(t, endpoint_err == nil, "the test endpoint could not be read: %v", endpoint_err) { return }

	server := Read_Test_Server {
		listener = listener,
	}
	worker := thread.create(read_test_serve, name = "nabla-http-read-test")
	if worker == nil {
		testing.fail_now(t, "the test server thread could not be created")
	}
	worker.data = &server
	thread.start(worker)
	defer if worker != nil {
		thread.join(worker)
		thread.destroy(worker)
	}

	connection, dial_err := connection_dial(endpoint, {}, context.allocator)
	if !testing.expect_value(t, dial_err, Error.None) { return }
	defer connection_destroy(connection)

	received: [len(READ_TEST_BYTES)]u8
	offset := 0
	for offset < len(received) {
		count, read_err := connection_read(connection, received[offset:])
		if !testing.expectf(t, read_err == Error.None, "the read stopped early: %v", read_err) { return }
		if count <= 0 { break }
		offset += count
	}
	testing.expect(t, bytes.equal(received[:offset], transmute([]u8)READ_TEST_BYTES), "the client did not read the payload byte-for-byte")
	thread.join(worker)
	testing.expect(t, server.sent, "the server did not send the payload")
	thread.destroy(worker)
	worker = nil
}

@(test)
test_a_bare_tls_transport_close_is_truncation :: proc(t: ^testing.T) {
	connection := Connection {
		stop = .Peer_Closed,
	}
	testing.expect_value(t, tls_error(&connection, tls.Error.Transport, .TLS_Read), Error.Truncated)
}
