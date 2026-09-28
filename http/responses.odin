package http

import "core:bytes"
import "core:encoding/json"
import "core:io"
import "core:log"
import "core:nbio"
import "core:path/filepath"
import "core:strings"

// Sets the response to one that sends the given HTML.
respond_html :: proc(response: ^Response, html: string, status: Status = .OK, loc := #caller_location) {
	response.status = status
	headers_set_content_type(&response.headers, mime_to_content_type(Mime_Type.Html))
	body_set(response, html, loc)
	respond(response, loc)
}

// Sets the response to one that sends the given plain text.
respond_plain :: proc(response: ^Response, text: string, status: Status = .OK, loc := #caller_location) {
	response.status = status
	headers_set_content_type(&response.headers, mime_to_content_type(Mime_Type.Plain))
	body_set(response, text, loc)
	respond(response, loc)
}

/*
Sends the content of the file at the given path as the response.

This procedure uses non blocking IO and only allocates the size of the file in the body's buffer,
no other allocations or temporary buffers, this is to make it as fast as possible.

The content type is taken from the path, optionally overwritten using the parameter.

If the file doesn't exist, a 404 response is sent.
If any other error occurs, a 500 is sent and the error is logged.
*/
respond_file :: proc(response: ^Response, path: string, content_type: Maybe(Mime_Type) = nil, loc := #caller_location) {
	// PERF: we are still putting the content into the body buffer, we could stream it.

	assert_on_server_thread(loc)
	assert(!response.sent, "response has already been sent", loc)

	mime := content_type.? or_else mime_from_extension(path)
	headers_set_content_type(&response.headers, mime_to_content_type(mime))

	nbio.open_poly(path, response, on_open)

	// These record the operation and the file error, never the path. The caller
	// chose the path and is the one that can decide whether naming it is safe, so a
	// path never reaches a log a different process may persist.
	on_open :: proc(op: ^nbio.Operation, response: ^Response) {
		#partial switch op.open.err {
		case .Not_Found:
			log.debug("a file response has no such file")
			respond_with_status(response, .Not_Found)
		case:
			log.warnf("a file response could not open its file: %i", op.open.err)
			respond_with_status(response, .Not_Found)
		case nil:
			nbio.stat_poly2(op.open.handle, op.open.path, response, on_stat)
		}
	}

	on_stat :: proc(op: ^nbio.Operation, path: string, response: ^Response) {
		#partial switch op.stat.err {
		case:
			log.errorf("a file response could not stat its file: %v", op.stat.err)
			nbio.close(op.stat.handle)
			respond_with_status(response, .Not_Found)
		case nil:
			assert(op.stat.size < i64(max(int)))

			_response_write_heading(response, int(op.stat.size))

			bytes.buffer_grow(&response._buf, int(op.stat.size))
			buffer := _dynamic_unwritten(response._buf.buf)[:op.stat.size]

			nbio.read_poly2(op.stat.handle, 0, buffer, path, response, on_read, all = true)
		}
	}

	on_read :: proc(op: ^nbio.Operation, path: string, response: ^Response) {
		nbio.close(op.read.handle)
		#partial switch op.read.err {
		case:
			log.errorf("a file response could not read its file: %v", op.read.err)
			respond_with_status(response, .Internal_Server_Error)
		case nil:
			_dynamic_add_len(&response._buf.buf, op.read.read)
			respond_with_status(response, .OK)
		}
	}
}

/*
Responds with the given content, determining content type from the given path.

This is very useful when you want to `#load(path)` at compile time and respond with that.
*/
respond_file_content :: proc(response: ^Response, path: string, content: []byte, status: Status = .OK, loc := #caller_location) {
	mime := mime_from_extension(path)

	response.status = status
	headers_set_content_type(&response.headers, mime_to_content_type(mime))
	body_set(response, content, loc)
	respond(response, loc)
}

/*
Sets the response to one that, based on the request path, returns a file.
base:    The base of the request path that should be removed when retrieving the file.
target:  The path to the directory to serve.
request: The request path.

Path traversal is detected and cleaned up.
The Content-Type is set based on the file extension, see the MimeType enum for known file extensions.
*/
respond_dir :: proc(response: ^Response, base, target, request: string, loc := #caller_location) {
	if !strings.has_prefix(request, base) {
		respond(response, Status.Not_Found)
		return
	}

	// Detect path traversal attacks.
	request_clean, request_err := filepath.clean(request, context.temp_allocator)
	base_clean, base_err := filepath.clean(base, context.temp_allocator)
	if request_err != nil || base_err != nil || !strings.has_prefix(request_clean, base_clean) {
		respond(response, Status.Not_Found)
		return
	}

	file_path, path_err := filepath.join([]string{"./", target, strings.trim_prefix(request_clean, base_clean)}, context.temp_allocator)
	if path_err != nil {
		respond(response, Status.Internal_Server_Error)
		return
	}
	respond_file(response, file_path, loc = loc)
}

// Sets the response to one that returns the JSON representation of the given value.
respond_json :: proc(
	response: ^Response,
	value: any,
	status: Status = .OK,
	options: json.Marshal_Options = {},
	loc := #caller_location,
) -> (
	err: json.Marshal_Error,
) {
	options := options

	response.status = status
	headers_set_content_type(&response.headers, mime_to_content_type(Mime_Type.Json))

	// Going to write a MINIMUM of 128 bytes at a time.
	writer: Response_Writer
	buffer: [128]byte
	response_writer_init(&writer, response, buffer[:])

	// Ends the body and sends the response.
	defer io.close(writer.output)

	if err = json.marshal_to_writer(writer.output, value, &options); err != nil {
		headers_set_close(&response.headers)
		response_status(response, .Internal_Server_Error)
	}

	return
}

/*
Prefer the procedure group `respond`.
*/
respond_with_none :: proc(response: ^Response, loc := #caller_location) {
	assert_on_server_thread(loc)

	response_send(response, response._conn, loc)
}

/*
Prefer the procedure group `respond`.
*/
respond_with_status :: proc(response: ^Response, status: Status, loc := #caller_location) {
	response_status(response, status)
	respond(response, loc)
}

// Sends the response back to the client, handlers should call this.
respond :: proc {
	respond_with_none,
	respond_with_status,
}
