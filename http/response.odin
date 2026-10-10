package http

import "base:runtime"

import "core:io"
import "core:log"
import "core:mem/virtual"
import "core:nbio"
import "core:slice"
import "core:strconv"

Response :: struct {
	// Add your headers and cookies here directly.
	headers:          Headers,
	cookies:          [dynamic]Cookie,
	sent:             bool,

	// NOTE: use `http.response_status` if the response body might have been set already.
	status:           Status,
	_conn:            ^Connection,
	_buf:             [dynamic]byte,
	_err:             runtime.Allocator_Error,
	_heading_written: bool,
	// _head_len is where the head ends in _buf, which is all a HEAD request is
	// sent (RFC 9110 9.3.2).
	_head_len:        int,
}

response_init :: proc(response: ^Response, allocator := context.allocator) {
	response.status = .Not_Found
	response.cookies.allocator = allocator
	response._buf.allocator = allocator

	headers_init(&response.headers, allocator)
}

// response_append appends content with the response allocator. An allocation
// error is returned and retained so a partial response is never sent.
@(require_results)
response_append :: proc(response: ^Response, content: []byte) -> runtime.Allocator_Error {
	if response._err != nil { return response._err }
	_, response._err = append(&response._buf, ..content)
	return response._err
}

@(private, require_results)
response_append_string :: proc(response: ^Response, content: string) -> runtime.Allocator_Error {
	return response_append(response, transmute([]byte)content)
}

// body_set_bytes writes the heading and content with the response allocator.
// An allocation error prevents the response from being sent.
@(require_results)
body_set_bytes :: proc(response: ^Response, content: []byte, loc := #caller_location) -> runtime.Allocator_Error {
	assert(len(response._buf) == 0, "the response body has already been written", loc)
	_response_write_heading(response, len(content)) or_return
	return response_append(response, content)
}

@(require_results)
body_set_str :: proc(response: ^Response, content: string, loc := #caller_location) -> runtime.Allocator_Error {
	return body_set_bytes(response, transmute([]byte)content, loc)
}

// body_set writes the heading and body. Later header changes have no effect;
// response_status can still change the status.
body_set :: proc {
	body_set_str,
	body_set_bytes,
}

// response_status changes the status even after the body was written.
response_status :: proc(response: ^Response, status: Status) {
	if response.status == status { return }

	response.status = status

	// The status code has a fixed width and the reason phrase is omitted.
	if len(response._buf) > 0 {
		OFFSET :: len("HTTP/1.1 ")

		status_text := status_string(response.status)
		if len(status_text) < 4 {
			status_text = "500 "
		} else {
			status_text = status_text[0:4]
		}

		copy(response._buf[OFFSET:OFFSET + 4], status_text)
	}
}

Response_Writer :: struct {
	response:        ^Response,
	// close_delimited frames the body by closing the connection, for a client
	// that cannot receive chunked (RFC 9112 6.1).
	close_delimited: bool,
	// The writer you can write to.
	output:          io.Writer,
	// A dynamic wrapper over the `buffer` given in `response_writer_init`, doesn't allocate.
	buffer:          [dynamic]byte,
	// If destroy or close has been called.
	ended:           bool,
}

// response_writer_init frames an unknown-length body, chunked for HTTP/1.1 and
// close-delimited for HTTP/1.0. buffer is borrowed and never grows. io.close
// sends the response; io.destroy only ends the body. Allocation errors leave
// the response unsent.
@(require_results)
response_writer_init :: proc(writer: ^Response_Writer, response: ^Response, buffer: []byte) -> (output: io.Writer, err: runtime.Allocator_Error) {
	line, has_line := response._conn.loop.request.line.?
	writer.close_delimited = has_line && line.version.minor == 0
	if writer.close_delimited {
		headers_set_close(&response.headers) or_return
	} else {
		_ = headers_set_unsafe(&response.headers, "transfer-encoding", "chunked") or_return
	}
	_response_write_heading(response, -1) or_return

	writer.buffer = slice.into_dynamic(buffer)
	writer.response = response

	writer.output = io.Stream {
		procedure = proc(stream_data: rawptr, mode: io.Stream_Mode, content: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
			writer := (^Response_Writer)(stream_data)
			if writer.response._err != nil { return 0, .Short_Write }

			#partial switch mode {
			case .Flush:
				assert(!writer.ended)

				response_writer_chunk(writer, writer.buffer[:]) or_return
				clear(&writer.buffer)
				return 0, nil

			case .Destroy:
				assert(!writer.ended)

				response_writer_chunk(writer, writer.buffer[:]) or_return

				response_writer_end(writer) or_return
				return 0, nil

			case .Close:
				response_writer_chunk(writer, writer.buffer[:]) or_return

				if !writer.ended { response_writer_end(writer) or_return }

				respond(writer.response)
				return 0, nil

			case .Write:
				assert(!writer.ended)

				if len(writer.buffer) + len(content) > cap(writer.buffer) {
					response_writer_chunk(writer, writer.buffer[:]) or_return
					clear(&writer.buffer)

					if len(content) > cap(writer.buffer) {
						response_writer_chunk(writer, content) or_return
					} else {
						if _, append_err := append(&writer.buffer, ..content); append_err != nil { return 0, .Short_Write }
					}
				} else {
					if _, append_err := append(&writer.buffer, ..content); append_err != nil { return 0, .Short_Write }
				}

				return i64(len(content)), .None

			case .Query:
				return io.query_utility({.Write, .Flush, .Destroy, .Close})
			}
			return 0, .Empty
		},
		data = writer,
	}
	return writer.output, nil
}

// response_writer_chunk frames one chunk. Allocation errors become io.Error
// only at this writer boundary; the response retains their original value.
@(private, require_results)
response_writer_chunk :: proc(writer: ^Response_Writer, chunk: []byte) -> io.Error {
	if len(chunk) == 0 { return nil }
	response := writer.response
	if writer.close_delimited {
		if response_append(response, chunk) != nil { return .Short_Write }
		return nil
	}
	size_text: [16]byte
	if response_append_string(response, strconv.write_int(size_text[:], i64(len(chunk)), 16)) != nil ||
	   response_append_string(response, "\r\n") != nil ||
	   response_append(response, chunk) != nil ||
	   response_append_string(response, "\r\n") != nil { return .Short_Write }
	return nil
}

@(private, require_results)
response_writer_end :: proc(writer: ^Response_Writer) -> io.Error {
	if !writer.close_delimited && response_append_string(writer.response, "0\r\n\r\n") != nil { return .Short_Write }
	writer.ended = true
	return nil
}

// response_buffer_writer adapts checked response appends to io.Writer.
@(private)
response_buffer_writer :: proc(response: ^Response) -> io.Writer {
	return {data = response, procedure = proc(data: rawptr, mode: io.Stream_Mode, content: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
			response := cast(^Response)data
			#partial switch mode {
			case .Write:
				if response_append(response, content) != nil { return 0, .Short_Write }
				return i64(len(content)), nil
			case .Query:
				return io.query_utility({.Write})
			}
			return 0, .Empty
		}}
}

// _response_write_heading omits Content-Length when content_length is negative.
@(require_results)
_response_write_heading :: proc(response: ^Response, content_length: int) -> runtime.Allocator_Error {
	if response._err != nil { return response._err }
	if response._heading_written { return nil }

	write_string :: response_append_string
	connection := response._conn
	body_buffer := response

	MIN :: len("HTTP/1.1 200 \r\ndate: \r\ncontent-length: 1000\r\n") + HTTP_DATE_LENGTH
	AVG_HEADER_SIZE :: 20
	reserve_size := MIN + content_length + (AVG_HEADER_SIZE * headers_count(response.headers))
	if err := reserve(&response._buf, max(0, reserve_size)); err != nil {
		response._err = err
		return err
	}

	status_text := status_string(response.status)
	if len(status_text) < 4 {
		status_text = "500 "
	} else {
		status_text = status_text[0:4]
	}

	write_string(body_buffer, "HTTP/1.1 ") or_return
	write_string(body_buffer, status_text) or_return
	write_string(body_buffer, "\r\n") or_return

	// RFC 9110 6.6.1: an origin server with a clock sends Date in every 2xx,
	// 3xx, and 4xx response, and may in 1xx and 5xx ones.
	if !status_is_informational(response.status) && !headers_has_unsafe(response.headers, "date") {
		write_string(body_buffer, "date: ") or_return
		write_string(body_buffer, server_date()) or_return
		write_string(body_buffer, "\r\n") or_return
	}

	if (content_length > -1 && !headers_has_unsafe(response.headers, "content-length") && response_needs_content_length(response, connection)) {
		if content_length == 0 {
			write_string(body_buffer, "content-length: 0\r\n") or_return
		} else {
			write_string(body_buffer, "content-length: ") or_return

			assert(content_length < 1000000000000000000 && content_length > -1000000000000000000)
			number_text: [20]byte
			write_string(body_buffer, strconv.write_int(number_text[:], i64(content_length), 10)) or_return
			write_string(body_buffer, "\r\n") or_return
		}
	}

	stream := response_buffer_writer(response)

	for header, value in response.headers._kv {
		write_string(body_buffer, header) or_return // already has newlines escaped.
		write_string(body_buffer, ": ") or_return
		if write_escaped_newlines(stream, value) != nil { return response._err }
		write_string(body_buffer, "\r\n") or_return
	}
	for value in response.headers._set_cookie_values {
		write_string(body_buffer, "set-cookie: ") or_return
		if write_escaped_newlines(stream, value) != nil { return response._err }
		write_string(body_buffer, "\r\n") or_return
	}

	for cookie in response.cookies {
		if cookie_write(stream, cookie) != nil { return response._err }
		write_string(body_buffer, "\r\n") or_return
	}

	write_string(body_buffer, "\r\n") or_return
	response._head_len = len(response._buf)
	response._heading_written = true
	return nil
}

// Sends the response over the connection.
// Frees the allocator (should be a request scoped allocator).
// Closes the connection or starts the handling of the next request.
@(private)
response_send :: proc(response: ^Response, connection: ^Connection, loc := #caller_location) {
	assert(!response.sent, "response has already been sent", loc)
	response.sent = true
	if response._err != nil {
		connection_close(connection)
		return
	}

	// RFC 9112 9.3: a server reads the entire request body or closes the
	// connection after its response, or the unread rest would be taken for the
	// next request. A body the handler left unread is not read here on its
	// behalf, so the connection closes instead.
	will_close := response_must_close(&connection.loop.request, response)
	if !will_close && connection.loop.request._body_ok == nil && request_has_body(&connection.loop.request) {
		if err := headers_set_close(&response.headers); err != nil { response._err = err }
		will_close = true
	}
	if response._err != nil {
		connection_close(connection)
		return
	}
	if will_close && !connection_set_state(connection, .Will_Close) { return }

	if len(response._buf) == 0 {
		if err := _response_write_heading(response, 0); err != nil {
			connection_close(connection)
			return
		}
	}
	body := response._buf[:]
	if connection.loop.request.is_head { body = body[:response._head_len] }
	nbio.send_poly(connection.socket, {body}, connection, on_response_sent)
}

// request_has_body reports whether the request's framing says content follows
// its header section (RFC 9112 6.3).
@(private, require_results)
request_has_body :: proc(request: ^Request) -> bool {
	if headers_has_unsafe(request.headers, "transfer-encoding") { return true }
	length_text, has_length := headers_get_unsafe(request.headers, "content-length")
	if !has_length { return false }
	length, valid := content_length_parse(length_text)
	return !valid || length > 0
}

@(private)
on_response_sent :: proc(op: ^nbio.Operation, connection: ^Connection) {
	if op.send.err != nil {
		log.errorf("could not send response: %v", op.send.err)
		if !connection_set_state(connection, .Will_Close) { return }
	}

	clean_request_loop(connection)
}

@(private)
clean_request_loop :: proc(connection: ^Connection, close_connection: Maybe(bool) = nil) {
	previous_temp := context.temp_allocator
	context.temp_allocator = virtual.arena_allocator(&connection.temp_allocator)
	defer context.temp_allocator = previous_temp
	free_all(context.temp_allocator)

	scanner_reset(&connection.scanner)

	client := connection.loop.request.client
	connection.loop.request = {}
	connection.loop.request.client = client

	connection.loop.response = {}

	if close_now, ok := close_connection.?; (ok && close_now) || connection.state == .Will_Close || atomic_load(&connection.server.closing) {
		connection_close(connection)
	} else {
		if !connection_set_state(connection, .Idle) { return }
		connection_handle_request(connection, context.temp_allocator)
	}
}

// A server MUST NOT send a Content-Length header field in any response
// with a status code of 1xx (Informational) or 204 (No Content).  A
// server MUST NOT send a Content-Length header field in any 2xx
// (Successful) response to a CONNECT request.
@(private, require_results)
response_needs_content_length :: proc(response: ^Response, connection: ^Connection) -> bool {
	if status_is_informational(response.status) || response.status == .No_Content {
		return false
	}

	if line, has_line := connection.loop.request.line.?; has_line && status_is_success(response.status) && line.method == .Connect {
		return false
	}

	return true
}

// response_must_close reports whether the connection closes after this
// response, and states it in the response when the server decided it.
@(private, require_results)
response_must_close :: proc(request: ^Request, response: ^Response) -> bool {
	// RFC 9112 9.6: a "close" connection option from either side ends the
	// connection after this response. Connection is a list of case-insensitive
	// options (RFC 9110 7.6.1).
	if value, has := headers_get_unsafe(request.headers, "connection"); has && list_has_token(value, "close") {
		return true
	}
	if value, has := headers_get_unsafe(response.headers, "connection"); has && list_has_token(value, "close") {
		return true
	}

	// A body that could not be read leaves the rest of the stream unframed.
	if body_ok, got_body := request._body_ok.?; got_body && !body_ok {
		if err := headers_set_close(&response.headers); err != nil { response._err = err }
		return true
	}

	if response._conn.state >= .Will_Close {
		if err := headers_set_close(&response.headers); err != nil { response._err = err }
		return true
	}

	// RFC 9112 9.3: an HTTP/1.0 connection persists only when the client asked
	// with keep-alive, which this server does not offer.
	if line, has_line := request.line.?; !has_line || line.version.minor == 0 {
		if err := headers_set_close(&response.headers); err != nil { response._err = err }
		return true
	}
	return false
}
