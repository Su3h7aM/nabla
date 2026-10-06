package client

import "core:fmt"
import "core:mem"
import "core:nbio"

import "nabla:http"

// Upgraded is a connection whose HTTP exchange ended with the peer taking it over:
// a 101 response (RFC 9110 15.2.2) or a successful CONNECT response (RFC 9110
// 9.3.6). A caller reads and writes the protocol through this handle, which owns
// the connection and response head.
//
// The handle is bound to no thread. One thread at a time may use it, and each read
// or write waits on that thread's own event loop. A holder that reads or writes
// repeatedly from a thread with no loop of its own acquires one around the whole
// exchange, so each wait does not start and stop a loop.
Upgraded :: struct {
	connection: ^Connection,
	// pending holds the octets already read past the response head, which are the
	// upgraded protocol's first bytes and would otherwise be lost with the reader.
	pending:    []u8,
	pending_at: int,
	// headers are the response's fields, and are borrowed for as long as the handle
	// lives.
	headers:    http.Headers,
	allocator:  mem.Allocator,
}

// upgrade_request performs a request that asks the peer to take the connection over,
// and returns the connection when the response is a 101. A response that is not a 101
// is a failure with its status, because an upgrade only happened if the peer said so
// (RFC 9110 7.8).
//
// Anything the peer sent before its response head was read stays with the handle,
// since the upgraded protocol's first bytes can arrive in the same segment as the
// head. The caller owns the handle and releases it with upgraded_destroy.
@(require_results)
upgrade_request :: proc(request: Request, options: Options) -> (upgraded: ^Upgraded, failure: Failure) {
	summary: Transfer_Summary
	phase := Transfer_Phase.Validate
	defer {
		summary.stopped_at = phase
		summary.error = failure.cause
		if options.observer.complete != nil {
			options.observer.complete(options.observer.user_data, summary)
		}
	}

	if loop_failure := event_loop_acquire(request.allocator); loop_failure.kind != .None { return nil, loop_failure }
	defer nbio.release_thread_event_loop()

	connection, send_failure := request_send(request, options, &phase, &summary)
	if send_failure.kind != .None { return nil, send_failure }

	phase = .Response_Head
	reader: Reader
	if reader_err := reader_init(&reader, connection_read_source, connection, request.allocator); reader_err != .None {
		connection_destroy(connection)
		return nil, failure_from_error(reader_err, request.allocator)
	}
	defer reader_destroy(&reader)

	head, headers, head_err := read_final_response_head(&reader, request.allocator, request.method)
	status := head.code
	if head_err != .None {
		http.headers_destroy(&headers)
		connection_destroy(connection)
		return nil, failure_from_read(head_err, options, request.allocator)
	}
	summary.response_head_received = true
	summary.status = status

	if options.response_head.observed != nil {
		head := Response_Head {
			status = status,
			usable = status == 101,
		}
		options.response_head.observed(options.response_head.user_data, head, headers)
	}
	if status != 101 {
		http.headers_destroy(&headers)
		connection_destroy(connection)
		detail := fmt.aprintf("HTTP %d: the response did not upgrade the connection", status, allocator = request.allocator)
		return nil, Failure{kind = .HTTP_Status, status = status, detail = detail}
	}

	handle, handle_err := upgraded_make(connection, &reader, headers, request.allocator)
	if handle_err != .None {
		http.headers_destroy(&headers)
		connection_destroy(connection)
		return nil, failure_from_error(handle_err, request.allocator)
	}

	summary.request_complete = true
	phase = .Complete
	return handle, {}
}

// upgraded_make copies the reader's buffered protocol bytes and takes ownership
// of the connection and response fields on success. On failure the caller retains
// both inputs.
@(private, require_results)
upgraded_make :: proc(connection: ^Connection, reader: ^Reader, headers: http.Headers, allocator: mem.Allocator) -> (upgraded: ^Upgraded, err: Error) {
	pending: []u8
	if reader.head < reader.tail {
		buffered, buffered_err := make([]u8, reader.tail - reader.head, allocator)
		if buffered_err != nil { return nil, .No_Room }
		copy(buffered, reader.buffer[reader.head:reader.tail])
		pending = buffered
	}

	handle, handle_err := new(Upgraded, allocator)
	if handle_err != nil {
		delete(pending, allocator)
		return nil, .No_Room
	}
	handle.connection = connection
	handle.headers = headers
	handle.pending = pending
	handle.allocator = allocator
	return handle, .None
}

// upgraded_read takes bytes out of the upgraded protocol's stream. The octets read
// past the response head are returned first, so nothing the peer already sent is
// dropped.
@(require_results)
upgraded_read :: proc(upgraded: ^Upgraded, buffer: []u8) -> (count: int, err: Error) {
	if upgraded.pending_at < len(upgraded.pending) {
		count = copy(buffer, upgraded.pending[upgraded.pending_at:])
		upgraded.pending_at += count
		return count, .None
	}
	return connection_read(upgraded.connection, buffer)
}

@(require_results)
upgraded_write :: proc(upgraded: ^Upgraded, buffer: []u8) -> (accepted: int, err: Error) {
	return connection_write_all(upgraded.connection, buffer)
}

upgraded_destroy :: proc(upgraded: ^Upgraded) {
	upgraded_release(upgraded, false)
}

// upgraded_abort releases an upgraded connection without a protocol-level TLS close.
// Cancellation and shutdown paths use it when teardown must not wait on the peer.
upgraded_abort :: proc(upgraded: ^Upgraded) {
	upgraded_release(upgraded, true)
}

upgraded_release :: proc(upgraded: ^Upgraded, aborted: bool) {
	if upgraded == nil { return }
	delete(upgraded.pending, upgraded.allocator)
	http.headers_destroy(&upgraded.headers)
	if aborted { connection_abort(upgraded.connection) } else { connection_destroy(upgraded.connection) }
	allocator := upgraded.allocator
	free(upgraded, allocator)
}
