#+test
#+private file
package client

import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

CONNECT_TEST_REQUEST :: "CONNECT destination.example:443 HTTP/1.1\r\nhost: destination.example:443\r\n\r\n"

Connect_Test_Server :: struct {
	listener:            net.TCP_Socket,
	response:            string,
	expect_tunnel_data:  bool,
	request_matches:     bool,
	tunnel_data_matches: bool,
	client_closed:       bool,
}

Connect_Test_Body :: struct {
	bytes:  [16]u8,
	length: int,
}

connect_test_serve :: proc(thread_handle: ^thread.Thread) {
	server := cast(^Connect_Test_Server)thread_handle.data
	socket, _, accept_err := net.accept_tcp(server.listener)
	if accept_err != nil { return }
	defer net.close(socket)
	_ = net.set_option(socket, .Receive_Timeout, 2 * time.Second)

	request: [512]u8
	request_length := 0
	for {
		if request_length == len(request) { return }
		count, read_err := net.recv_tcp(socket, request[request_length:])
		if read_err != nil || count <= 0 { return }
		request_length += count
		if strings.contains(string(request[:request_length]), "\r\n\r\n") { break }
	}
	server.request_matches = string(request[:request_length]) == CONNECT_TEST_REQUEST

	response_bytes := transmute([]u8)server.response
	sent := 0
	for sent < len(response_bytes) {
		count, send_err := net.send_tcp(socket, response_bytes[sent:])
		if send_err != nil || count <= 0 { return }
		sent += count
	}
	if !server.expect_tunnel_data { return }

	tunnel_data: [1]u8
	count, read_err := net.recv_tcp(socket, tunnel_data[:])
	server.tunnel_data_matches = read_err == nil && count == 1 && tunnel_data[0] == 'X'
	for {
		count, read_err = net.recv_tcp(socket, tunnel_data[:])
		if read_err != nil { return }
		if count == 0 {
			server.client_closed = true
			return
		}
	}
}

connect_test_start :: proc(t: ^testing.T, server: ^Connect_Test_Server) -> (listener: net.TCP_Socket, worker: ^thread.Thread, url: string) {
	opened_listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	listener = opened_listener
	if !testing.expectf(t, listen_err == nil, "the CONNECT test endpoint could not listen: %v", listen_err) { return }
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if !testing.expectf(t, endpoint_err == nil, "the CONNECT test endpoint could not be read: %v", endpoint_err) {
		net.close(listener)
		listener = 0
		return
	}
	server.listener = listener
	url = fmt.aprintf("http://127.0.0.1:%d/", endpoint.port, allocator = context.allocator)
	worker = thread.create(connect_test_serve, name = "nabla-http-connect-test")
	if worker == nil {
		delete(url, context.allocator)
		net.close(listener)
		listener = 0
		url = ""
		testing.fail_now(t, "the CONNECT test server thread could not be created")
	}
	worker.data = server
	thread.start(worker)
	return
}

connect_test_stop :: proc(listener: net.TCP_Socket, worker: ^thread.Thread) {
	if worker != nil {
		thread.join(worker)
		thread.destroy(worker)
	}
	if listener != 0 { net.close(listener) }
}

connect_test_collect :: proc(user_data: rawptr, chunk: []u8) {
	body := cast(^Connect_Test_Body)user_data
	count := min(len(chunk), len(body.bytes) - body.length)
	copy(body.bytes[body.length:body.length + count], chunk[:count])
	body.length += count
}

@(test)
test_connect_hands_off_coalesced_tunnel_bytes_and_destroy_closes_it :: proc(t: ^testing.T) {
	server := Connect_Test_Server {
		response           = "HTTP/1.1 200 Connection Established\r\ncontent-length: 99\r\ncontent-length: 1\r\ntransfer-encoding: chunked\r\n\r\nTLS",
		expect_tunnel_data = true,
	}
	listener, worker, url := connect_test_start(t, &server)
	defer {
		connect_test_stop(listener, worker)
		delete(url, context.allocator)
	}
	if worker == nil { return }

	response, failure := connect_request("destination.example:443", url, nil, {}, nil, nil)
	defer failure_destroy(&failure, context.allocator)
	if !testing.expect_value(t, failure.kind, Failure_Kind.None) { return }
	if !testing.expect(t, response != nil, "a successful CONNECT returned no tunnel") { return }
	defer if response != nil { upgraded_destroy(response) }

	buffer: [3]u8
	count, read_err := upgraded_read(response, buffer[:])
	if !testing.expect_value(t, read_err, Error.None) { return }
	testing.expect_value(t, count, 3)
	testing.expect_value(t, string(buffer[:count]), "TLS")

	accepted, write_err := upgraded_write(response, transmute([]u8)string("X"))
	if !testing.expect_value(t, write_err, Error.None) { return }
	testing.expect_value(t, accepted, 1)

	upgraded_destroy(response)
	response = nil
	thread.join(worker)
	testing.expect(t, server.request_matches, "the server received an unexpected CONNECT request")
	testing.expect(t, server.tunnel_data_matches, "the tunnel did not carry the caller's write")
	testing.expect(t, server.client_closed, "destroy did not close the tunnel connection")
	thread.destroy(worker)
	worker = nil
}

@(test)
test_connect_streams_a_non_success_response_body :: proc(t: ^testing.T) {
	server := Connect_Test_Server {
		response = "HTTP/1.1 407 Proxy Authentication Required\r\ncontent-length: 6\r\n\r\ndenied",
	}
	listener, worker, url := connect_test_start(t, &server)
	defer {
		connect_test_stop(listener, worker)
		delete(url, context.allocator)
	}
	if worker == nil { return }

	body: Connect_Test_Body
	response, failure := connect_request("destination.example:443", url, nil, {}, &body, connect_test_collect)
	defer if response != nil { upgraded_destroy(response) }
	defer failure_destroy(&failure, context.allocator)
	testing.expect_value(t, failure.kind, Failure_Kind.HTTP_Status)
	testing.expect_value(t, failure.status, 407)
	testing.expect_value(t, string(body.bytes[:body.length]), "denied")
	testing.expect(t, server.request_matches, "the server received an unexpected CONNECT request")
}
