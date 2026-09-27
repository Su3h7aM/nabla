#+test
#+private file
package http

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// TEST_BOUND bounds every client read, so a server that never answers fails
// the test instead of hanging it.
TEST_BOUND :: 5 * time.Second

// Test_Server runs a server on its own thread: listen and serve share the
// thread's event loop, so both run there, and ready carries the bound endpoint
// back.
Test_Server :: struct {
	server:   Server,
	endpoint: net.Endpoint,
	listened: bool,
	ready:    sync.Sema,
	thread:   ^thread.Thread,
}

// test_handle answers "/echo" with the request body, "/json" with a streamed
// JSON value, and anything else with "ok".
test_handle :: proc(req: ^Request, res: ^Response) {
	if req.url.path == "/json" {
		respond_json(res, 7)
		return
	}
	if req.url.path != "/echo" {
		respond_plain(res, "ok")
		return
	}
	body(req, -1, res, proc(user_data: rawptr, content: Body, err: Body_Error) {
		res := (^Response)(user_data)
		if err != nil {
			respond(res, body_error_status(err))
			return
		}
		respond_plain(res, content)
	})
}

test_server_start :: proc(t: ^testing.T, fixture: ^Test_Server) -> bool {
	fixture.thread = thread.create_and_start_with_poly_data(fixture, proc(fixture: ^Test_Server) {
		opts := Default_Server_Opts
		opts.thread_count = 1
		listen_err := listen(&fixture.server, {address = net.IP4_Loopback, port = 0}, opts)
		if listen_err == nil {
			bound, bound_err := net.bound_endpoint(fixture.server.tcp_sock)
			fixture.endpoint, fixture.listened = bound, bound_err == nil
		}
		sync.sema_post(&fixture.ready)
		if listen_err == nil { serve(&fixture.server, handler(test_handle)) }
	})
	if fixture.thread == nil { return false }
	sync.sema_wait(&fixture.ready)
	testing.expect(t, fixture.listened, "the server listens")
	return fixture.listened
}

test_server_stop :: proc(fixture: ^Test_Server) {
	server_shutdown(&fixture.server)
	thread.join(fixture.thread)
	thread.destroy(fixture.thread)
}

// exchange sends request, then continuation once the server has answered with
// anything, and returns everything the server sent until it closed.
exchange :: proc(t: ^testing.T, endpoint: net.Endpoint, request: string, continuation := "") -> string {
	socket, dial_err := net.dial_tcp_from_endpoint(endpoint)
	if dial_err != nil {
		testing.expectf(t, false, "dial failed: %v", dial_err)
		return ""
	}
	defer net.close(socket)
	net.set_option(socket, .Receive_Timeout, TEST_BOUND)
	net.send_tcp(socket, transmute([]byte)request)

	pending := continuation
	received: strings.Builder
	strings.builder_init(&received, context.temp_allocator)
	buffer: [1024]byte
	for {
		count, recv_err := net.recv_tcp(socket, buffer[:])
		if recv_err != nil || count == 0 { break }
		strings.write_bytes(&received, buffer[:count])
		if pending != "" {
			net.send_tcp(socket, transmute([]byte)pending)
			pending = ""
		}
	}
	return strings.to_string(received)
}

@(test)
test_server_follows_rfc_9112 :: proc(t: ^testing.T) {
	fixture: Test_Server
	if !test_server_start(t, &fixture) { return }
	defer test_server_stop(&fixture)
	at := fixture.endpoint

	// RFC 9112 3.2: Host is required of HTTP/1.1 requests only.
	older := exchange(t, at, "GET / HTTP/1.0\r\n\r\n")
	testing.expectf(t, strings.has_prefix(older, "HTTP/1.1 200 ") && strings.has_suffix(older, "\r\n\r\nok"), "HTTP/1.0 without Host: %q", older)
	hostless := exchange(t, at, "GET / HTTP/1.1\r\n\r\n")
	testing.expectf(t, strings.has_prefix(hostless, "HTTP/1.1 400 "), "HTTP/1.1 without Host: %q", hostless)

	// RFC 9110 2.5: a later minor version is served as HTTP/1.1.
	later := exchange(t, at, "GET / HTTP/1.2\r\nHost: a\r\nConnection: close\r\n\r\n")
	testing.expectf(t, strings.has_prefix(later, "HTTP/1.1 200 "), "HTTP/1.2: %q", later)

	// RFC 9112 3: an invalid request line is answered with 400.
	invalid := exchange(t, at, "GET\r\n\r\n")
	testing.expectf(t, strings.has_prefix(invalid, "HTTP/1.1 400 "), "invalid request line: %q", invalid)

	// RFC 9110 9.3.2: HEAD is answered like GET, without the content.
	head := exchange(t, at, "HEAD / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n")
	testing.expectf(t, strings.has_prefix(head, "HTTP/1.1 200 ") && strings.has_suffix(head, "\r\n\r\n"), "HEAD: %q", head)

	// RFC 9110 10.1.1: the expectation is case-insensitive, and the content is
	// sent once the interim 100 arrives.
	continued := exchange(t, at, "POST /echo HTTP/1.1\r\nHost: a\r\nExpect: 100-Continue\r\nContent-Length: 5\r\nConnection: close\r\n\r\n", "hello")
	testing.expectf(
		t,
		strings.has_prefix(continued, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 ") && strings.has_suffix(continued, "\r\n\r\nhello"),
		"100-continue: %q",
		continued,
	)

	// RFC 9112 7.1.1: chunk extensions are parsed and ignored.
	chunked := exchange(t, at, "POST /echo HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5;name=\"v\"\r\nhello\r\n0\r\n\r\n")
	testing.expectf(t, strings.has_suffix(chunked, "\r\n\r\nhello"), "chunked: %q", chunked)

	// RFC 9112 6.1: a streamed body is chunked for an HTTP/1.1 client and
	// delimited by the close for an HTTP/1.0 one, which cannot read chunked.
	streamed := exchange(t, at, "GET /json HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n")
	testing.expectf(t, strings.has_suffix(streamed, "\r\n\r\n1\r\n7\r\n0\r\n\r\n"), "chunked stream: %q", streamed)
	delimited := exchange(t, at, "GET /json HTTP/1.0\r\n\r\n")
	testing.expectf(
		t,
		strings.has_suffix(delimited, "\r\n\r\n7") && !strings.contains(delimited, "transfer-encoding"),
		"close-delimited stream: %q",
		delimited,
	)

	// RFC 9112 6.1: a Transfer-Encoding in an HTTP/1.0 request is faulty framing.
	faulty := exchange(t, at, "POST /echo HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
	testing.expectf(t, strings.has_prefix(faulty, "HTTP/1.1 400 "), "Transfer-Encoding in HTTP/1.0: %q", faulty)
}
