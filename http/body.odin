package http

import "core:bufio"
import "core:io"
import "core:log"
import "core:net"
import "core:strings"

Body :: string

Body_Callback :: #type proc(user_data: rawptr, body: Body, err: Body_Error)

Body_Error :: bufio.Scanner_Error

/*
Retrieves the request's body, framed as RFC 9112 6.3 says: by the chunked
transfer coding when it is the final one, otherwise by Content-Length, and as
empty when the request has neither.

`max_length` is the caller's bound on the body; a larger one is an error. A
negative value reads whatever the request carries, since HTTP itself sets no
limit (RFC 9110 5.4).

Do not call this more than once.

**Tip** If an error is returned, easily respond with an appropriate error code like this, `http.respond(response, http.body_error_status(err))`.
*/
body :: proc(request: ^Request, max_length: int = -1, user_data: rawptr, callback: Body_Callback) {
	assert(request._body_ok == nil, "you can only call body once per request")

	if coding, has_coding := headers_get_unsafe(request.headers, "transfer-encoding"); has_coding {
		if !final_transfer_coding_is_chunked(coding) {
			// The server answers such a request with 400 before a handler runs
			// (RFC 9112 6.3 item 4), so this is only reached by misuse.
			request._body_ok = false
			callback(user_data, "", .Bad_Read_Count)
			return
		}
		_body_chunked(request, max_length, user_data, callback)
	} else {
		_body_length(request, max_length, user_data, callback)
	}
}

/*
Parses a URL encoded body, aka bodies with the 'Content-Type: application/x-www-form-urlencoded'.

Key&value pairs are percent decoded and put in a map.
*/
body_url_encoded :: proc(encoded: Body, allocator := context.temp_allocator) -> (queries: map[string]string, ok: bool) {

	insert :: proc(result: ^map[string]string, text: string, key_start: int, value_start: int, end: int, allocator := context.temp_allocator) -> bool {
		has_value := value_start != -1
		key_end := value_start - 1 if has_value else end
		key := text[key_start:key_end]
		value := text[value_start:end] if has_value else ""

		// PERF: this could be a hot spot and I don't like that we allocate the decoded key and value here.
		decoded_key := (net.percent_decode(key, allocator) or_return) if strings.index_byte(key, '%') > -1 else key
		decoded_value := (net.percent_decode(value, allocator) or_return) if has_value && strings.index_byte(value, '%') > -1 else value

		result[decoded_key] = decoded_value
		return true
	}

	count := 1
	for character in encoded {
		if character == '&' { count += 1 }
	}

	parsed, make_err := make(map[string]string, count, allocator)
	if make_err != nil { return nil, false }
	queries = parsed

	key_start := 0
	value_start := -1
	for character, index in encoded {
		switch character {
		case '=':
			value_start = index + 1
		case '&':
			insert(&queries, encoded, key_start, value_start, index) or_return
			key_start = index + 1
			value_start = -1
		}
	}

	insert(&queries, encoded, key_start, value_start, len(encoded)) or_return

	return queries, true
}

// Returns an appropriate status code for the given body error.
body_error_status :: proc(body_err: Body_Error) -> Status {
	switch specific in body_err {
	case bufio.Scanner_Extra_Error:
		switch specific {
		case .Too_Long:
			return .Content_Too_Large
		case .Too_Short, .Bad_Read_Count:
			return .Bad_Request
		case .Negative_Advance, .Advanced_Too_Far:
			return .Internal_Server_Error
		case .None:
			return .OK
		case:
			return .Internal_Server_Error
		}
	case io.Error:
		switch specific {
		case .EOF, .Unknown, .No_Progress, .Unexpected_EOF:
			return .Bad_Request
		case .Empty,
		     .Short_Write,
		     .Buffer_Full,
		     .Short_Buffer,
		     .Invalid_Write,
		     .Negative_Read,
		     .Invalid_Whence,
		     .Invalid_Offset,
		     .Invalid_Unread,
		     .Negative_Write,
		     .Negative_Count,
		     .Permission_Denied,
		     .No_Size,
		     .Closed:
			return .Internal_Server_Error
		case .None:
			return .OK
		case:
			return .Internal_Server_Error
		}
	case:
		unreachable()
	}
}

// _body_length frames the body by Content-Length, and as empty when the request
// carries neither framing field (RFC 9112 6.3 items 5 and 7).
_body_length :: proc(request: ^Request, max_length: int = -1, user_data: rawptr, callback: Body_Callback) {
	request._body_ok = false

	length_text, has_length := headers_get_unsafe(request.headers, "content-length")
	if !has_length {
		// Neither framing field: the request has no content (RFC 9112 6.3 item 7).
		request._body_ok = true
		callback(user_data, "", nil)
		return
	}

	length, length_ok := content_length_parse(length_text)
	if !length_ok {
		callback(user_data, "", .Bad_Read_Count)
		return
	}

	if max_length > -1 && length > max_length {
		callback(user_data, "", .Too_Long)
		return
	}

	if length == 0 {
		request._body_ok = true
		callback(user_data, "", nil)
		return
	}

	request._scanner.max_token_size = length

	request._scanner.split = scan_num_bytes
	request._scanner.split_data = rawptr(uintptr(length))

	request._body_ok = true
	scanner_scan(request._scanner, user_data, callback)
}

// _body_chunked decodes a chunked body (RFC 9112 7.1) into one buffer, owned by
// the request's temp allocator, and hands it to the callback once. A trailer
// field that may be one and is not already in the header section is merged into
// it; the decoded message carries neither chunked nor Trailer afterwards.
_body_chunked :: proc(request: ^Request, max_length: int = -1, user_data: rawptr, callback: Body_Callback) {
	request._body_ok = false

	on_scan :: proc(state_data: rawptr, size_line: string, err: bufio.Scanner_Error) {
		state := cast(^Chunked_State)state_data

		if err != nil {
			state.callback(state.user_data, "", err)
			return
		}

		size, ok := chunk_line_parse(size_line)
		if !ok {
			log.info("a chunked body declared an invalid chunk size")
			state.callback(state.user_data, "", .Bad_Read_Count)
			return
		}

		// start scanning trailer headers.
		if size == 0 {
			scanner_scan(state.request._scanner, state_data, on_scan_trailer)
			return
		}

		if state.max_length > -1 && size > state.max_length - strings.builder_len(state.buffer) {
			state.callback(state.user_data, "", .Too_Long)
			return
		}

		state.request._scanner.max_token_size = size

		state.request._scanner.split = scan_num_bytes

		#assert(size_of(int) == size_of(uintptr))
		state.request._scanner.split_data = rawptr(uintptr(size))

		scanner_scan(state.request._scanner, state_data, on_scan_chunk)
	}

	on_scan_chunk :: proc(state_data: rawptr, token: string, err: bufio.Scanner_Error) {
		state := cast(^Chunked_State)state_data

		if err != nil {
			state.callback(state.user_data, "", err)
			return
		}

		state.request._scanner.max_token_size = 0
		state.request._scanner.split = scan_lines

		// A builder reports the growth it could not make as a short write, which
		// would silently truncate the body a handler sees.
		if strings.write_string(&state.buffer, token) != len(token) {
			state.callback(state.user_data, "", .Unknown)
			return
		}

		on_scan_empty_line :: proc(state_data: rawptr, token: string, err: bufio.Scanner_Error) {
			state := cast(^Chunked_State)state_data

			if err != nil {
				state.callback(state.user_data, "", err)
				return
			}
			// chunk-data is followed by CRLF and nothing else (RFC 9112 7.1).
			if len(token) != 0 {
				state.callback(state.user_data, "", .Bad_Read_Count)
				return
			}

			scanner_scan(state.request._scanner, state_data, on_scan)
		}

		scanner_scan(state.request._scanner, state_data, on_scan_empty_line)
	}

	on_scan_trailer :: proc(state_data: rawptr, line: string, err: bufio.Scanner_Error) {
		state := cast(^Chunked_State)state_data

		if err != nil {
			state.callback(state.user_data, "", err)
			return
		}
		// The empty line ends the trailer section and the message. RFC 9112
		// 7.1.3: the decoded message no longer carries chunked or Trailer.
		if len(line) == 0 {
			state.request.headers.readonly = false
			headers_delete_unsafe(&state.request.headers, "trailer")
			coding := headers_get_unsafe(state.request.headers, "transfer-encoding")
			if comma := strings.last_index_byte(coding, ','); comma >= 0 {
				headers_set_unsafe(&state.request.headers, "transfer-encoding", trim_ows(coding[:comma]))
			} else {
				headers_delete_unsafe(&state.request.headers, "transfer-encoding")
			}
			state.request.headers.readonly = true

			state.request._body_ok = true
			state.callback(state.user_data, strings.to_string(state.buffer), nil)
			return
		}

		// A trailer field that may not be one is ignored (RFC 9110 6.5.1), and
		// a field the header section already has is not merged into it.
		colon := strings.index_byte(line, ':')
		name := line[:max(colon, 0)]
		if colon <= 0 || !token_valid(name) {
			log.info("a chunked body carried an invalid trailer field")
			state.callback(state.user_data, "", .Bad_Read_Count)
			return
		}
		lower, lower_err := sanitize_key(state.request.headers, name)
		if lower_err != nil {
			state.callback(state.user_data, "", .Unknown)
			return
		}
		if header_allowed_trailer(lower) && !headers_has_unsafe(state.request.headers, lower) {
			state.request.headers.readonly = false
			_, ok := header_parse(&state.request.headers, line)
			state.request.headers.readonly = true
			if !ok {
				state.callback(state.user_data, "", .Bad_Read_Count)
				return
			}
		}

		scanner_scan(state.request._scanner, state_data, on_scan_trailer)
	}

	Chunked_State :: struct {
		request:    ^Request,
		max_length: int,
		user_data:  rawptr,
		callback:   Body_Callback,
		buffer:     strings.Builder,
	}

	state, state_error := new(Chunked_State, context.temp_allocator)
	if state_error != nil {
		callback(user_data, "", .Unknown)
		return
	}

	state.buffer.buf.allocator = context.temp_allocator

	state.request = request
	state.max_length = max_length
	state.user_data = user_data
	state.callback = callback

	state.request._scanner.split = scan_lines
	scanner_scan(state.request._scanner, state, on_scan)
}
