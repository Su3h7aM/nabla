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

	// If the response has been sent.
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

response_init :: proc(r: ^Response, allocator := context.allocator) {
	r.status = .Not_Found
	r.cookies.allocator = allocator
	r._buf.buf.allocator = allocator

	headers_init(&r.headers, allocator)
}

/*
Prefer the procedure group `body_set`.
*/
body_set_bytes :: proc(r: ^Response, byts: []byte, loc := #caller_location) {
	assert(bytes.buffer_length(&r._buf) == 0, "the response body has already been written", loc)
	_response_write_heading(r, len(byts))
	bytes.buffer_write(&r._buf, byts)
}

/*
Prefer the procedure group `body_set`.
*/
body_set_str :: proc(r: ^Response, str: string, loc := #caller_location) {
	// This is safe because we don't write to the bytes.
	body_set_bytes(r, transmute([]byte)str, loc)
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
response_status :: proc(r: ^Response, status: Status) {
	if r.status == status { return }

	r.status = status

	// If we have already written the heading, we can address the bytes directly to overwrite,
	// this is because of the fact that every status code is of length 3, and because we omit
	// the "optional" reason phrase out of the response.
	if bytes.buffer_length(&r._buf) > 0 {
		OFFSET :: len("HTTP/1.1 ")

		status_int_str := status_string(r.status)
		if len(status_int_str) < 4 {
			status_int_str = "500 "
		} else {
			status_int_str = status_int_str[0:4]
		}

		copy(r._buf.buf[OFFSET:OFFSET + 4], status_int_str)
	}
}

Response_Writer :: struct {
	r:               ^Response,
	// close_delimited frames the body by closing the connection, for a client
	// that cannot receive chunked (RFC 9112 6.1).
	close_delimited: bool,
	// The writer you can write to.
	w:               io.Writer,
	// A dynamic wrapper over the `buffer` given in `response_writer_init`, doesn't allocate.
	buf:             [dynamic]byte,
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
response_writer_init :: proc(rw: ^Response_Writer, r: ^Response, buffer: []byte) -> io.Writer {
	line, has_line := r._conn.loop.req.line.?
	rw.close_delimited = has_line && line.version.minor == 0
	if rw.close_delimited {
		headers_set_close(&r.headers)
	} else {
		headers_set_unsafe(&r.headers, "transfer-encoding", "chunked")
	}
	_response_write_heading(r, -1)

	rw.buf = slice.into_dynamic(buffer)
	rw.r = r

	rw.w = io.Stream {
		procedure = proc(stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
			rw := (^Response_Writer)(stream_data)
			b := &rw.r._buf

			#partial switch mode {
			case .Flush:
				assert(!rw.ended)

				response_writer_chunk(rw, b, rw.buf[:])
				clear(&rw.buf)
				return 0, nil

			case .Destroy:
				assert(!rw.ended)

				// Write what is left.
				response_writer_chunk(rw, b, rw.buf[:])

				response_writer_end(rw, b)
				return 0, nil

			case .Close:
				// Write what is left.
				response_writer_chunk(rw, b, rw.buf[:])

				if !rw.ended { response_writer_end(rw, b) }

				// Send the response.
				respond(rw.r)
				return 0, nil

			case .Write:
				assert(!rw.ended)

				// No space, first write rw.buf, then check again for space, if still no space,
				// fully write the given p.
				if len(rw.buf) + len(p) > cap(rw.buf) {
					response_writer_chunk(rw, b, rw.buf[:])
					clear(&rw.buf)

					if len(p) > cap(rw.buf) {
						response_writer_chunk(rw, b, p)
					} else {
						append(&rw.buf, ..p)
					}
				} else {
					// Space, append bytes to the buffer.
					append(&rw.buf, ..p)
				}

				return i64(len(p)), .None

			case .Query:
				return io.query_utility({.Write, .Flush, .Destroy, .Close})
			}
			return 0, .Empty
		},
		data = rw,
	}
	return rw.w
}

// response_writer_chunk appends one piece of the body, framed as one chunk
// (RFC 9112 7.1) unless the body is delimited by the connection closing.
@(private)
response_writer_chunk :: proc(rw: ^Response_Writer, b: ^bytes.Buffer, chunk: []byte) {
	if len(chunk) == 0 { return }
	if rw.close_delimited {
		bytes.buffer_write(b, chunk)
		return
	}
	size_buf: [16]byte
	bytes.buffer_write_string(b, strconv.write_int(size_buf[:], i64(len(chunk)), 16))
	bytes.buffer_write_string(b, "\r\n")
	bytes.buffer_write(b, chunk)
	bytes.buffer_write_string(b, "\r\n")
}

// response_writer_end ends the body: the last chunk and an empty trailer
// section end a chunked one.
@(private)
response_writer_end :: proc(rw: ^Response_Writer, b: ^bytes.Buffer) {
	if !rw.close_delimited { bytes.buffer_write_string(b, "0\r\n\r\n") }
	rw.ended = true
}

/*
Writes the response status and headers to the buffer.

This is automatically called before writing anything to the Response.body or before calling a procedure
that sends the response.

You can pass `content_length < 0` to omit the content-length header, note that this header is
required on most responses, but there are things like transfer-encodings that could leave it out.
*/
_response_write_heading :: proc(r: ^Response, content_length: int) {
	if r._heading_written { return }
	r._heading_written = true

	ws :: bytes.buffer_write_string
	conn := r._conn
	b := &r._buf

	MIN :: len("HTTP/1.1 200 \r\ndate: \r\ncontent-length: 1000\r\n") + HTTP_DATE_LENGTH
	AVG_HEADER_SIZE :: 20
	reserve_size := MIN + content_length + (AVG_HEADER_SIZE * headers_count(r.headers))
	bytes.buffer_grow(&r._buf, reserve_size)

	// According to RFC 7230 3.1.2 the reason phrase is insignificant,
	// because not doing so (and the fact that a status code is always length 3), we can change
	// the status code when we are already writing a body by just addressing the 3 bytes directly.
	status_int_str := status_string(r.status)
	if len(status_int_str) < 4 {
		status_int_str = "500 "
	} else {
		status_int_str = status_int_str[0:4]
	}

	ws(b, "HTTP/1.1 ")
	ws(b, status_int_str)
	ws(b, "\r\n")

	// RFC 9110 6.6.1: an origin server with a clock sends Date in every 2xx,
	// 3xx, and 4xx response, and may in 1xx and 5xx ones.
	if !status_is_informational(r.status) && !headers_has_unsafe(r.headers, "date") {
		ws(b, "date: ")
		ws(b, server_date())
		ws(b, "\r\n")
	}

	if (content_length > -1 && !headers_has_unsafe(r.headers, "content-length") && response_needs_content_length(r, conn)) {
		if content_length == 0 {
			ws(b, "content-length: 0\r\n")
		} else {
			ws(b, "content-length: ")

			assert(content_length < 1000000000000000000 && content_length > -1000000000000000000)
			buf: [20]byte
			ws(b, strconv.write_int(buf[:], i64(content_length), 10))
			ws(b, "\r\n")
		}
	}

	bstream := bytes.buffer_to_stream(b)

	for header, value in r.headers._kv {
		ws(b, header) // already has newlines escaped.
		ws(b, ": ")
		write_escaped_newlines(bstream, value)
		ws(b, "\r\n")
	}

	for cookie in r.cookies {
		cookie_write(bstream, cookie)
		ws(b, "\r\n")
	}

	// Empty line denotes end of headers and start of body.
	ws(b, "\r\n")
	r._head_len = bytes.buffer_length(b)
}

// Sends the response over the connection.
// Frees the allocator (should be a request scoped allocator).
// Closes the connection or starts the handling of the next request.
@(private)
response_send :: proc(r: ^Response, conn: ^Connection, loc := #caller_location) {
	assert(!r.sent, "response has already been sent", loc)
	r.sent = true

	// RFC 9112 9.3: a server reads the entire request body or closes the
	// connection after its response, or the unread rest would be taken for the
	// next request. A body the handler left unread is not read here on its
	// behalf, so the connection closes instead.
	will_close := response_must_close(&conn.loop.req, r)
	if !will_close && conn.loop.req._body_ok == nil && request_has_body(&conn.loop.req) {
		headers_set_close(&r.headers)
		will_close = true
	}
	if will_close && !connection_set_state(conn, .Will_Close) { return }

	if bytes.buffer_length(&r._buf) == 0 {
		_response_write_heading(r, 0)
	}
	buf := bytes.buffer_to_bytes(&r._buf)
	if conn.loop.req.is_head { buf = buf[:r._head_len] }
	nbio.send_poly(conn.socket, {buf}, conn, on_response_sent)
}

// request_has_body reports whether the request's framing says content follows
// its header section (RFC 9112 6.3).
@(private)
request_has_body :: proc(req: ^Request) -> bool {
	if headers_has_unsafe(req.headers, "transfer-encoding") { return true }
	length, has_length := headers_get_unsafe(req.headers, "content-length")
	if !has_length { return false }
	size, valid := content_length_parse(length)
	return !valid || size > 0
}

@(private)
on_response_sent :: proc(op: ^nbio.Operation, conn: ^Connection) {
	if op.send.err != nil {
		log.errorf("could not send response: %v", op.send.err)
		if !connection_set_state(conn, .Will_Close) { return }
	}

	clean_request_loop(conn)
}

// Response has been sent, clean up and close/handle next.
@(private)
clean_request_loop :: proc(conn: ^Connection, close: Maybe(bool) = nil) {
	context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)

	// blocks, size, used := allocator_free_all(&conn.temp_allocator)
	// log.debugf("temp_allocator had %d blocks of a total size of %m of which %m was used", blocks, size, used)
	free_all(context.temp_allocator)

	scanner_reset(&conn.scanner)

	client := conn.loop.req.client
	conn.loop.req = {}
	conn.loop.req.client = client

	conn.loop.res = {}

	if c, ok := close.?; (ok && c) || conn.state == .Will_Close || atomic_load(&conn.server.closing) {
		connection_close(conn)
	} else {
		if !connection_set_state(conn, .Idle) { return }
		conn_handle_req(conn, context.temp_allocator)
	}
}

// A server MUST NOT send a Content-Length header field in any response
// with a status code of 1xx (Informational) or 204 (No Content).  A
// server MUST NOT send a Content-Length header field in any 2xx
// (Successful) response to a CONNECT request.
@(private)
response_needs_content_length :: proc(r: ^Response, conn: ^Connection) -> bool {
	if status_is_informational(r.status) || r.status == .No_Content {
		return false
	}

	if line, has_line := conn.loop.req.line.?; has_line && status_is_success(r.status) && line.method == .Connect {
		return false
	}

	return true
}

// response_must_close reports whether the connection closes after this
// response, and states it in the response when the server decided it.
@(private)
response_must_close :: proc(req: ^Request, res: ^Response) -> bool {
	// RFC 9112 9.6: a "close" connection option from either side ends the
	// connection after this response. Connection is a list of case-insensitive
	// options (RFC 9110 7.6.1).
	if value, has := headers_get_unsafe(req.headers, "connection"); has && list_has_token(value, "close") {
		return true
	}
	if value, has := headers_get_unsafe(res.headers, "connection"); has && list_has_token(value, "close") {
		return true
	}

	// A body that could not be read leaves the rest of the stream unframed.
	if body_ok, got_body := req._body_ok.?; got_body && !body_ok {
		headers_set_close(&res.headers)
		return true
	}

	if res._conn.state >= .Will_Close {
		headers_set_close(&res.headers)
		return true
	}

	// RFC 9112 9.3: an HTTP/1.0 connection persists only when the client asked
	// with keep-alive, which this server does not offer.
	if line, has_line := req.line.?; !has_line || line.version.minor == 0 {
		headers_set_close(&res.headers)
		return true
	}
	return false
}
