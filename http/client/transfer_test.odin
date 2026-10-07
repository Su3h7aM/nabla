#+test
#+private file
package client

import "core:fmt"
import "core:mem"
import "core:net"
import "core:testing"
import "core:thread"

// The transport's own account of a request is the one observation a caller cannot
// make for itself: a truncated stream and a request that was never written both
// surface as a transport failure. These tests cover the paths that need no peer,
// which is every path before a connection exists; the paths past it are covered
// where a real server is available.

Transfer_Log :: struct {
	calls:   int,
	summary: Transfer_Summary,
}

transfer_log_complete :: proc(user_data: rawptr, summary: Transfer_Summary) {
	log := cast(^Transfer_Log)user_data
	log.calls += 1
	log.summary = summary
}

transfer_log_options :: proc(log: ^Transfer_Log) -> Options {
	return {observer = {user_data = log, complete = transfer_log_complete}}
}

Refusal_Body_Server :: struct {
	listener: net.TCP_Socket,
	sent:     bool,
}

refusal_body_serve :: proc(thread_handle: ^thread.Thread) {
	server := cast(^Refusal_Body_Server)thread_handle.data
	socket, _, accept_err := net.accept_tcp(server.listener)
	if accept_err != nil { return }
	defer net.close(socket)

	response := "HTTP/1.1 404 Not Found\r\ncontent-length: 4\r\n\r\nx"
	response_bytes := transmute([]u8)response
	sent := 0
	for sent < len(response_bytes) {
		count, send_err := net.send_tcp(socket, response_bytes[sent:])
		if send_err != nil || count <= 0 { return }
		sent += count
	}
	server.sent = true

	// Keep the peer open so the client probe, rather than an EOF, ends the
	// incomplete body after its first byte reaches the callback.
	scratch: [1024]u8
	for {
		count, read_err := net.recv_tcp(socket, scratch[:])
		if read_err != nil || count <= 0 { return }
	}
}

Body_Cancel_State :: struct {
	cancelled: bool,
	bytes:     int,
}

body_cancel_probe :: proc(user_data: rawptr) -> Wait_Status {
	state := cast(^Body_Cancel_State)user_data
	return .Cancelled if state.cancelled else .Ready
}

body_cancel_collect :: proc(user_data: rawptr, chunk: []u8) {
	state := cast(^Body_Cancel_State)user_data
	state.bytes += len(chunk)
	state.cancelled = true
}

// Every kind of failure owns its own detail, so one destructor releases any of
// them, and a tracking allocator is what proves nothing else was left behind.
@(test)
test_failure_destroy_releases_any_kind :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	failure := stream_request({url = "ftp://api.example.com/v1/messages", method = .Post, allocator = allocator}, {}, nil, nil)
	// A refused URL is a failure the transport never saw, and it still owns its text.
	testing.expect_value(t, failure.kind, Failure_Kind.Invalid_URL)
	testing.expect_value(t, failure.cause, Error.None)
	testing.expect_value(t, failure.detail, "URL scheme must be http or https")
	failure_destroy(&failure, allocator)

	for _, entry in track.allocation_map {
		testing.expectf(t, false, "the failure leaked %d bytes allocated at %v", entry.size, entry.location)
	}
}

@(test)
test_transfer_reports_a_request_that_was_never_written :: proc(t: ^testing.T) {
	// A URL this client refuses is not a failed request: nothing was resolved,
	// connected, or written, and the summary says exactly that.
	for url in ([]string{"ftp://api.example.com/v1/messages", "api.example.com/v1/messages"}) {
		log: Transfer_Log
		failure := stream_request({url = url, method = .Post, allocator = context.allocator}, transfer_log_options(&log), nil, nil)

		testing.expect_value(t, failure.kind, Failure_Kind.Invalid_URL)
		testing.expect_value(t, log.calls, 1)
		testing.expect_value(t, log.summary.stopped_at, Transfer_Phase.Validate)
		testing.expect_value(t, log.summary.request_bytes_accepted, u64(0))
		testing.expect_value(t, log.summary.request_body_bytes_accepted, u64(0))
		testing.expect(t, !log.summary.request_complete, "nothing was written")
		testing.expect(t, !log.summary.response_head_received, "nothing was read")
		testing.expect(t, log.summary.declared_body_bytes == nil, "an absent head declares nothing")
		failure_destroy(&failure, context.allocator)
	}

	// An empty host is refused at the same boundary, with the same account.
	log: Transfer_Log
	failure := stream_request({url = "https:///v1/messages", method = .Post, allocator = context.allocator}, transfer_log_options(&log), nil, nil)
	defer failure_destroy(&failure, context.allocator)
	testing.expect_value(t, failure.kind, Failure_Kind.Invalid_URL)
	testing.expect_value(t, log.summary.stopped_at, Transfer_Phase.Validate)
}

@(test)
test_refused_response_preserves_body_cancellation :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if !testing.expectf(t, listen_err == nil, "the test endpoint could not listen: %v", listen_err) { return }
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if !testing.expectf(t, endpoint_err == nil, "the test endpoint could not be read: %v", endpoint_err) { return }

	server := Refusal_Body_Server {
		listener = listener,
	}
	worker := thread.create(refusal_body_serve, name = "nabla-http-refusal-body-test")
	if worker == nil { testing.fail_now(t, "the test server thread could not be created") }
	worker.data = &server
	thread.start(worker)
	defer if worker != nil {
		thread.join(worker)
		thread.destroy(worker)
	}

	state: Body_Cancel_State
	log: Transfer_Log
	options := transfer_log_options(&log)
	options.probe = {
		check     = body_cancel_probe,
		user_data = &state,
	}
	url := fmt.aprintf("http://127.0.0.1:%d/", endpoint.port, allocator = context.allocator)
	defer delete(url, context.allocator)
	failure := stream_request({url = url, method = .Get, allocator = context.allocator}, options, &state, body_cancel_collect)
	defer failure_destroy(&failure, context.allocator)

	thread.join(worker)
	testing.expect(t, server.sent, "the test server did not send the refusal")
	testing.expect_value(t, state.bytes, 1)
	testing.expect_value(t, failure.kind, Failure_Kind.HTTP_Status)
	testing.expect_value(t, failure.status, 404)
	testing.expect_value(t, failure.cause, Error.Cancelled)
	testing.expect_value(t, log.summary.stopped_at, Transfer_Phase.Response_Body)
	testing.expect_value(t, log.summary.error, Error.Cancelled)
	thread.destroy(worker)
	worker = nil
}

@(test)
test_a_zero_observer_is_no_observer :: proc(t: ^testing.T) {
	// Observing is opt-in, so a caller that wants none pays nothing and a zero
	// observer must not be reached through a nil callback.
	failure := stream_request({url = "ftp://api.example.com", method = .Post, allocator = context.allocator}, {}, nil, nil)
	defer failure_destroy(&failure, context.allocator)
	testing.expect_value(t, failure.kind, Failure_Kind.Invalid_URL)
}
