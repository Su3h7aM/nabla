package http

import "core:bytes"
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

	// Only for internal usage.
	_conn:            ^Connection,
	// TODO/PERF: with some internal refactoring, we should be able to write directly to the
	// connection (maybe a small buffer in this struct).
	_buf:             bytes.Buffer,
	_heading_written: bool,
	// _head_len is where the head ends in _buf, which is all a HEAD request is
	// sent (RFC 9110 9.3.2).
	_head_len:        int,
}

response_init :: proc(response: ^Response, allocator := context.allocator) {
	response.status = .Not_Found
	response.cookies.allocator = allocator
	response._buf.buf.allocator = allocator

	headers_init(&response.headers, allocator)
}

/*
Prefer the procedure group `body_set`.
*/
body_set_bytes :: proc(response: ^Response, content: []byte, loc := #caller_location) {
	assert(bytes.buffer_length(&response._buf) == 0, "the response body has already been written", loc)
	_response_write_heading(response, len(content))
	bytes.buffer_write(&response._buf, content)
}

/*
Prefer the procedure group `body_set`.
*/
body_set_str :: proc(response: ^Response, content: string, loc := #caller_location) {
	// This is safe because we don't write to the bytes.
	body_set_bytes(response, transmute([]byte)content, loc)
}

/*
Sets the response body. After calling this you can no longer add headers to the response.
If, after calling, you want to change the status code, use the `response_status` procedure.

For bodies where you do not know the size or want an `io.Writer`, use the `response_writer_init`
procedure to create a writer.
*/
body_set :: proc {
	body_set_str,
	body_set_bytes,
}

/*
Sets the status code with the safety of being able to do this after writing (part of) the body.
*/
response_status :: proc(response: ^Response, status: Status) {
	if response.status == status { return }

	response.status = status

	// If we have already written the heading, we can address the bytes directly to overwrite,
	// this is because of the fact that every status code is of length 3, and because we omit
	// the "optional" reason phrase out of the response.
	if bytes.buffer_length(&response._buf) > 0 {
		OFFSET :: len("HTTP/1.1 ")

		status_text := status_string(response.status)
		if len(status_text) < 4 {
			status_text = "500 "
		} else {
			status_text = status_text[0:4]
		}

		copy(response._buf.buf[OFFSET:OFFSET + 4], status_text)
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

/*
Initialize a writer you can use to write responses. Use the `body_set` procedure group if you have
a string or byte slice.

The buffer can be used to avoid very small writes, like the ones when you use the json package
(each write in the json package is only a few bytes). You are allowed to pass nil which will disable
buffering.

The body is framed with the chunked transfer coding. A server must not send
that to an HTTP/1.0 client (RFC 9112 6.1), so its body is framed by closing the
connection instead.

NOTE: You need to call io.destroy to signal the end of the body, OR io.close to send the response.
*/
response_writer_init :: proc(writer: ^Response_Writer, response: ^Response, buffer: []byte) -> io.Writer {
	line, has_line := response._conn.loop.request.line.?
	writer.close_delimited = has_line && line.version.minor == 0
	if writer.close_delimited {
		headers_set_close(&response.headers)
	} else {
		headers_set_unsafe(&response.headers, "transfer-encoding", "chunked")
	}
	_response_write_heading(response, -1)

	writer.buffer = slice.into_dynamic(buffer)
	writer.response = response

	writer.output = io.Stream {
		procedure = proc(stream_data: rawptr, mode: io.Stream_Mode, content: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
			writer := (^Response_Writer)(stream_data)
			body_buffer := &writer.response._buf

			#partial switch mode {
			case .Flush:
				assert(!writer.ended)

				response_writer_chunk(writer, body_buffer, writer.buffer[:])
				clear(&writer.buffer)
				return 0, nil

			case .Destroy:
				assert(!writer.ended)

				// Write what is left.
				response_writer_chunk(writer, body_buffer, writer.buffer[:])

				response_writer_end(writer, body_buffer)
				return 0, nil

			case .Close:
				// Write what is left.
				response_writer_chunk(writer, body_buffer, writer.buffer[:])

				if !writer.ended { response_writer_end(writer, body_buffer) }

				// Send the response.
				respond(writer.response)
				return 0, nil

			case .Write:
				assert(!writer.ended)

				// No space, first write writer.buffer, then check again for space, if still no space,
				// fully write the given content.
				if len(writer.buffer) + len(content) > cap(writer.buffer) {
					response_writer_chunk(writer, body_buffer, writer.buffer[:])
					clear(&writer.buffer)

					if len(content) > cap(writer.buffer) {
						response_writer_chunk(writer, body_buffer, content)
					} else {
						append(&writer.buffer, ..content)
					}
				} else {
					// Space, append bytes to the buffer.
					append(&writer.buffer, ..content)
				}

				return i64(len(content)), .None

			case .Query:
				return io.query_utility({.Write, .Flush, .Destroy, .Close})
			}
			return 0, .Empty
		},
		data = writer,
	}
	return writer.output
}

// response_writer_chunk appends one piece of the body, framed as one chunk
// (RFC 9112 7.1) unless the body is delimited by the connection closing.
@(private)
response_writer_chunk :: proc(writer: ^Response_Writer, body_buffer: ^bytes.Buffer, chunk: []byte) {
	if len(chunk) == 0 { return }
	if writer.close_delimited {
		bytes.buffer_write(body_buffer, chunk)
		return
	}
	size_text: [16]byte
	bytes.buffer_write_string(body_buffer, strconv.write_int(size_text[:], i64(len(chunk)), 16))
	bytes.buffer_write_string(body_buffer, "\r\n")
	bytes.buffer_write(body_buffer, chunk)
	bytes.buffer_write_string(body_buffer, "\r\n")
}

// response_writer_end ends the body: the last chunk and an empty trailer
// section end a chunked one.
@(private)
response_writer_end :: proc(writer: ^Response_Writer, body_buffer: ^bytes.Buffer) {
	if !writer.close_delimited { bytes.buffer_write_string(body_buffer, "0\r\n\r\n") }
	writer.ended = true
}

/*
Writes the response status and headers to the buffer.

This is automatically called before writing anything to the Response.body or before calling a procedure
that sends the response.

You can pass `content_length < 0` to omit the content-length header, note that this header is
required on most responses, but there are things like transfer-encodings that could leave it out.
*/
_response_write_heading :: proc(response: ^Response, content_length: int) {
	if response._heading_written { return }
	response._heading_written = true

	write_string :: bytes.buffer_write_string
	connection := response._conn
	body_buffer := &response._buf

	MIN :: len("HTTP/1.1 200 \r\ndate: \r\ncontent-length: 1000\r\n") + HTTP_DATE_LENGTH
	AVG_HEADER_SIZE :: 20
	reserve_size := MIN + content_length + (AVG_HEADER_SIZE * headers_count(response.headers))
	bytes.buffer_grow(&response._buf, reserve_size)

	// According to RFC 7230 3.1.2 the reason phrase is insignificant,
	// because not doing so (and the fact that a status code is always length 3), we can change
	// the status code when we are already writing a body by just addressing the 3 bytes directly.
	status_text := status_string(response.status)
	if len(status_text) < 4 {
		status_text = "500 "
	} else {
		status_text = status_text[0:4]
	}

	write_string(body_buffer, "HTTP/1.1 ")
	write_string(body_buffer, status_text)
	write_string(body_buffer, "\r\n")

	// RFC 9110 6.6.1: an origin server with a clock sends Date in every 2xx,
	// 3xx, and 4xx response, and may in 1xx and 5xx ones.
	if !status_is_informational(response.status) && !headers_has_unsafe(response.headers, "date") {
		write_string(body_buffer, "date: ")
		write_string(body_buffer, server_date())
		write_string(body_buffer, "\r\n")
	}

	if (content_length > -1 && !headers_has_unsafe(response.headers, "content-length") && response_needs_content_length(response, connection)) {
		if content_length == 0 {
			write_string(body_buffer, "content-length: 0\r\n")
		} else {
			write_string(body_buffer, "content-length: ")

			assert(content_length < 1000000000000000000 && content_length > -1000000000000000000)
			number_text: [20]byte
			write_string(body_buffer, strconv.write_int(number_text[:], i64(content_length), 10))
			write_string(body_buffer, "\r\n")
		}
	}

	stream := bytes.buffer_to_stream(body_buffer)

	// The head is written into a core:bytes.Buffer, whose writes report no
	// failure: it grows with a resize whose allocation error it drops, so a
	// writer over it can only ever return nil.
	for header, value in response.headers._kv {
		write_string(body_buffer, header) // already has newlines escaped.
		write_string(body_buffer, ": ")
		_ = write_escaped_newlines(stream, value)
		write_string(body_buffer, "\r\n")
	}

	for cookie in response.cookies {
		_ = cookie_write(stream, cookie)
		write_string(body_buffer, "\r\n")
	}

	// Empty line denotes end of headers and start of body.
	write_string(body_buffer, "\r\n")
	response._head_len = bytes.buffer_length(body_buffer)
}

// Sends the response over the connection.
// Frees the allocator (should be a request scoped allocator).
// Closes the connection or starts the handling of the next request.
@(private)
response_send :: proc(response: ^Response, connection: ^Connection, loc := #caller_location) {
	assert(!response.sent, "response has already been sent", loc)
	response.sent = true

	// RFC 9112 9.3: a server reads the entire request body or closes the
	// connection after its response, or the unread rest would be taken for the
	// next request. A body the handler left unread is not read here on its
	// behalf, so the connection closes instead.
	will_close := response_must_close(&connection.loop.request, response)
	if !will_close && connection.loop.request._body_ok == nil && request_has_body(&connection.loop.request) {
		headers_set_close(&response.headers)
		will_close = true
	}
	if will_close && !connection_set_state(connection, .Will_Close) { return }

	if bytes.buffer_length(&response._buf) == 0 {
		_response_write_heading(response, 0)
	}
	body := bytes.buffer_to_bytes(&response._buf)
	if connection.loop.request.is_head { body = body[:response._head_len] }
	nbio.send_poly(connection.socket, {body}, connection, on_response_sent)
}

// request_has_body reports whether the request's framing says content follows
// its header section (RFC 9112 6.3).
@(private)
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
	context.temp_allocator = virtual.arena_allocator(&connection.temp_allocator)
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
@(private)
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
@(private)
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
		headers_set_close(&response.headers)
		return true
	}

	if response._conn.state >= .Will_Close {
		headers_set_close(&response.headers)
		return true
	}

	// RFC 9112 9.3: an HTTP/1.0 connection persists only when the client asked
	// with keep-alive, which this server does not offer.
	if line, has_line := request.line.?; !has_line || line.version.minor == 0 {
		headers_set_close(&response.headers)
		return true
	}
	return false
}
