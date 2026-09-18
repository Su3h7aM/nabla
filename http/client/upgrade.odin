package client

import "core:fmt"
import "core:mem"
import "core:nbio"

import "nabla:http"

// Upgraded is a connection whose HTTP exchange ended with the peer taking it over,
// which a 101 response states (RFC 9110 15.2.2). A caller reads and writes the
// protocol it upgraded to through this handle: the handle owns the connection, the
// response head, and the event loop the exchange began on.
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
	// Failure releases the loop; success leaves the acquisition with the handle.
	released := false
	defer if !released { nbio.release_thread_event_loop() }

	connection, send_failure := request_send(request, options, &phase, &summary)
	if send_failure.kind != .None { return nil, send_failure }

	phase = .Response_Head
	reader: Reader
	reader_init(&reader, connection_read_source, connection, request.allocator)
	defer reader_destroy(&reader)

	status, headers, head_err := read_final_response_head(&reader, request.allocator)
	if head_err != .None {
		headers_destroy(&headers, request.allocator)
		connection_destroy(connection)
		return nil, failure_from_error(head_err, request.allocator)
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
		headers_destroy(&headers, request.allocator)
		connection_destroy(connection)
		detail := fmt.aprintf("HTTP %d: the response did not upgrade the connection", status, allocator = request.allocator)
		return nil, Failure{kind = .HTTP_Status, status = status, detail = detail}
	}

	handle := new(Upgraded, request.allocator)
	handle.connection = connection
	handle.headers = headers
	handle.allocator = request.allocator
	// The reader may have buffered octets that belong to the upgraded protocol, and
	// they are handed over in the order they arrived.
	if reader.head < reader.tail {
		handle.pending = make([]u8, reader.tail - reader.head, request.allocator)
		copy(handle.pending, reader.buffer[reader.head:reader.tail])
	}

	summary.request_complete = true
	phase = .Complete
	released = true
	return handle, {}
}

// upgraded_read takes bytes out of the upgraded protocol's stream. The octets read
// past the response head are returned first, so nothing the peer already sent is
// dropped.
upgraded_read :: proc(upgraded: ^Upgraded, buffer: []u8) -> (count: int, err: Error) {
	if upgraded.pending_at < len(upgraded.pending) {
		count = copy(buffer, upgraded.pending[upgraded.pending_at:])
		upgraded.pending_at += count
		return count, .None
	}
	return connection_read(upgraded.connection, buffer)
}

upgraded_write :: proc(upgraded: ^Upgraded, buffer: []u8) -> (accepted: int, err: Error) {
	return connection_write_all(upgraded.connection, buffer)
}

upgraded_destroy :: proc(upgraded: ^Upgraded) {
	if upgraded == nil { return }
	delete(upgraded.pending, upgraded.allocator)
	headers_destroy(&upgraded.headers, upgraded.allocator)
	connection_destroy(upgraded.connection)
	allocator := upgraded.allocator
	// The loop was acquired for the upgraded connection as much as for the request
	// that opened it, so it is released once the connection is gone.
	nbio.release_thread_event_loop()
	free(upgraded, allocator)
}
