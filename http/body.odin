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

**Tip** If an error is returned, easily respond with an appropriate error code like this, `http.respond(res, http.body_error_status(err))`.
*/
body :: proc(req: ^Request, max_length: int = -1, user_data: rawptr, cb: Body_Callback) {
	assert(req._body_ok == nil, "you can only call body once per request")

	if coding, has_coding := headers_get_unsafe(req.headers, "transfer-encoding"); has_coding {
		if !final_transfer_coding_is_chunked(coding) {
			// The server answers such a request with 400 before a handler runs
			// (RFC 9112 6.3 item 4), so this is only reached by misuse.
			req._body_ok = false
			cb(user_data, "", .Bad_Read_Count)
			return
		}
		_body_chunked(req, max_length, user_data, cb)
	} else {
		_body_length(req, max_length, user_data, cb)
	}
}

/*
Parses a URL encoded body, aka bodies with the 'Content-Type: application/x-www-form-urlencoded'.

Key&value pairs are percent decoded and put in a map.
*/
body_url_encoded :: proc(plain: Body, allocator := context.temp_allocator) -> (res: map[string]string, ok: bool) {

	insert :: proc(m: ^map[string]string, plain: string, keys: int, vals: int, end: int, allocator := context.temp_allocator) -> bool {
		has_value := vals != -1
		key_end := vals - 1 if has_value else end
		key := plain[keys:key_end]
		val := plain[vals:end] if has_value else ""

		// PERF: this could be a hot spot and I don't like that we allocate the decoded key and value here.
		keye := (net.percent_decode(key, allocator) or_return) if strings.index_byte(key, '%') > -1 else key
		vale := (net.percent_decode(val, allocator) or_return) if has_value && strings.index_byte(val, '%') > -1 else val

		m[keye] = vale
		return true
	}

	count := 1
	for b in plain {
		if b == '&' { count += 1 }
	}

	queries := make(map[string]string, count, allocator)

	keys := 0
	vals := -1
	for b, i in plain {
		switch b {
		case '=':
			vals = i + 1
		case '&':
			insert(&queries, plain, keys, vals, i) or_return
			keys = i + 1
			vals = -1
		}
	}

	insert(&queries, plain, keys, vals, len(plain)) or_return

	return queries, true
}

// Returns an appropriate status code for the given body error.
body_error_status :: proc(e: Body_Error) -> Status {
	switch t in e {
	case bufio.Scanner_Extra_Error:
		switch t {
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
		switch t {
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


// "Decodes" a request body based on the content length header.
// Meant for internal usage, you should use `http.request_body`.
_body_length :: proc(req: ^Request, max_length: int = -1, user_data: rawptr, cb: Body_Callback) {
	req._body_ok = false

	length_text, has_length := headers_get_unsafe(req.headers, "content-length")
	if !has_length {
		// Neither framing field: the request has no content (RFC 9112 6.3 item 7).
		req._body_ok = true
		cb(user_data, "", nil)
		return
	}

	ilen, lenok := content_length_parse(length_text)
	if !lenok {
		cb(user_data, "", .Bad_Read_Count)
		return
	}

	if max_length > -1 && ilen > max_length {
		cb(user_data, "", .Too_Long)
		return
	}

	if ilen == 0 {
		req._body_ok = true
		cb(user_data, "", nil)
		return
	}

	req._scanner.max_token_size = ilen

	req._scanner.split = scan_num_bytes
	req._scanner.split_data = rawptr(uintptr(ilen))

	req._body_ok = true
	scanner_scan(req._scanner, user_data, cb)
}

/*
"Decodes" a chunked transfer encoded request body.
Meant for internal usage, you should use `http.request_body`.

PERF: this could be made non-allocating by writing over the part of the body that contains the
metadata with the rest of the body, and then returning a slice of that, but it is some effort and
I don't think this functionality of HTTP is used that much anyway.

RFC 7230 4.1.3 pseudo-code:

length := 0
read chunk-size, chunk-ext (if any), and CRLF
while (chunk-size > 0) {
   read chunk-data and CRLF
   append chunk-data to decoded-body
   length := length + chunk-size
   read chunk-size, chunk-ext (if any), and CRLF
}
read trailer field
while (trailer field is not empty) {
   if (trailer field is allowed to be sent in a trailer) {
   	append trailer field to existing header fields
   }
   read trailer-field
}
Content-Length := length
Remove "chunked" from Transfer-Encoding
Remove Trailer from existing header fields
*/
_body_chunked :: proc(req: ^Request, max_length: int = -1, user_data: rawptr, cb: Body_Callback) {
	req._body_ok = false

	on_scan :: proc(s: rawptr, size_line: string, err: bufio.Scanner_Error) {
		s := cast(^Chunked_State)s

		if err != nil {
			s.cb(s.user_data, "", err)
			return
		}

		size, ok := chunk_line_parse(size_line)
		if !ok {
			log.info("a chunked body declared an invalid chunk size")
			s.cb(s.user_data, "", .Bad_Read_Count)
			return
		}

		// start scanning trailer headers.
		if size == 0 {
			scanner_scan(s.req._scanner, s, on_scan_trailer)
			return
		}

		if s.max_length > -1 && size > s.max_length - strings.builder_len(s.buf) {
			s.cb(s.user_data, "", .Too_Long)
			return
		}

		s.req._scanner.max_token_size = size

		s.req._scanner.split = scan_num_bytes

		#assert(size_of(int) == size_of(uintptr))
		s.req._scanner.split_data = rawptr(uintptr(size))

		scanner_scan(s.req._scanner, s, on_scan_chunk)
	}

	on_scan_chunk :: proc(s: rawptr, token: string, err: bufio.Scanner_Error) {
		s := cast(^Chunked_State)s

		if err != nil {
			s.cb(s.user_data, "", err)
			return
		}

		s.req._scanner.max_token_size = 0
		s.req._scanner.split = scan_lines

		strings.write_string(&s.buf, token)

		on_scan_empty_line :: proc(s: rawptr, token: string, err: bufio.Scanner_Error) {
			s := cast(^Chunked_State)s

			if err != nil {
				s.cb(s.user_data, "", err)
				return
			}
			// chunk-data is followed by CRLF and nothing else (RFC 9112 7.1).
			if len(token) != 0 {
				s.cb(s.user_data, "", .Bad_Read_Count)
				return
			}

			scanner_scan(s.req._scanner, s, on_scan)
		}

		scanner_scan(s.req._scanner, s, on_scan_empty_line)
	}

	on_scan_trailer :: proc(s: rawptr, line: string, err: bufio.Scanner_Error) {
		s := cast(^Chunked_State)s

		if err != nil {
			s.cb(s.user_data, "", err)
			return
		}
		// The empty line ends the trailer section and the message. RFC 9112
		// 7.1.3: the decoded message no longer carries chunked or Trailer.
		if len(line) == 0 {
			s.req.headers.readonly = false
			headers_delete_unsafe(&s.req.headers, "trailer")
			coding := headers_get_unsafe(s.req.headers, "transfer-encoding")
			if comma := strings.last_index_byte(coding, ','); comma >= 0 {
				headers_set_unsafe(&s.req.headers, "transfer-encoding", trim_ows(coding[:comma]))
			} else {
				headers_delete_unsafe(&s.req.headers, "transfer-encoding")
			}
			s.req.headers.readonly = true

			s.req._body_ok = true
			s.cb(s.user_data, strings.to_string(s.buf), nil)
			return
		}

		// A trailer field that may not be one is ignored (RFC 9110 6.5.1), and
		// a field the header section already has is not merged into it.
		colon := strings.index_byte(line, ':')
		name := line[:max(colon, 0)]
		if colon <= 0 || !token_valid(name) {
			log.info("a chunked body carried an invalid trailer field")
			s.cb(s.user_data, "", .Bad_Read_Count)
			return
		}
		lower := sanitize_key(s.req.headers, name)
		if header_allowed_trailer(lower) && !headers_has_unsafe(s.req.headers, lower) {
			s.req.headers.readonly = false
			_, ok := header_parse(&s.req.headers, line)
			s.req.headers.readonly = true
			if !ok {
				s.cb(s.user_data, "", .Bad_Read_Count)
				return
			}
		}

		scanner_scan(s.req._scanner, s, on_scan_trailer)
	}

	Chunked_State :: struct {
		req:        ^Request,
		max_length: int,
		user_data:  rawptr,
		cb:         Body_Callback,
		buf:        strings.Builder,
	}

	s, s_error := new(Chunked_State, context.temp_allocator)
	if s_error != nil {
		cb(user_data, "", .Unknown)
		return
	}

	s.buf.buf.allocator = context.temp_allocator

	s.req = req
	s.max_length = max_length
	s.user_data = user_data
	s.cb = cb

	s.req._scanner.split = scan_lines
	scanner_scan(s.req._scanner, s, on_scan)
}
