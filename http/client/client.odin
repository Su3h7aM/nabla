package client

import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"

import "nabla:http"


HTTP_MAX_ERROR_BYTES :: 4096
HTTP_MAX_HEADER_LINES :: 256
HTTP_MAX_LINE_BYTES :: 32 * 1024

Failure_Kind :: enum {
	None,
	Cancelled,
	Timed_Out,
	TLS,
	Transport,
	Truncated,
	Closed,
	Invalid_URL,
	HTTP_Status,
	Content_Type,
}

// Failure describes why a request did not deliver a complete response. Only an
// HTTP_Status detail is allocated, with the request allocator, and the caller
// owns it; every other detail is a literal.
Failure :: struct {
	kind:   Failure_Kind,
	status: int,
	detail: string,
}

Chunk_Callback :: #type proc(user_data: rawptr, chunk: []u8)

Header :: struct {
	name:  string,
	value: string,
}

Request :: struct {
	url:                   string,
	method:                http.Method,
	headers:               []Header,
	body:                  []u8,
	// Empty accepts any response type.
	expected_content_type: string,
	allocator:             mem.Allocator,
}

// stream_request performs one request and delivers the response body through
// callback. Cancellation and deadlines reach every blocking phase except name
// resolution, which is bracketed instead of interrupted.
stream_request :: proc(request: Request, options: Options, user_data: rawptr, callback: Chunk_Callback) -> Failure {
	url := http.url_parse(request.url)
	if url.scheme != "http" && url.scheme != "https" { return failure_from_error(.None, .Invalid_URL, "URL scheme must be http or https") }
	if url.host == "" { return failure_from_error(.None, .Invalid_URL, "URL host is empty") }

	if stop := stop_from_wait(wait_probe(options.wait)); stop != .None {
		return failure_from_error(error_from_stop(stop))
	}
	endpoint, resolve_err := resolve_endpoint(url, options, request.allocator)
	if resolve_err != .None { return failure_from_error(resolve_err) }
	if stop := stop_from_wait(wait_probe(options.wait)); stop != .None {
		return failure_from_error(error_from_stop(stop))
	}

	connection, dial_err := connection_dial(endpoint, options, request.allocator)
	if dial_err != .None { return failure_from_error(dial_err) }
	defer connection_destroy(connection)

	if url.scheme == "https" {
		if handshake_err := connection_handshake(connection, url.host); handshake_err != .None {
			return failure_from_error(handshake_err)
		}
	}

	buffer := format_request(url, request)
	defer bytes.buffer_destroy(&buffer)
	if write_err := connection_write_all(connection, bytes.buffer_to_bytes(&buffer)); write_err != .None {
		return failure_from_error(write_err)
	}

	reader: Reader
	reader_init(&reader, connection, request.allocator)
	defer reader_destroy(&reader)

	status, headers, head_err := read_response_head(&reader, request.allocator)
	defer headers_destroy(&headers, request.allocator)
	if head_err != .None { return failure_from_error(head_err) }

	if status < 200 || status >= 300 {
		return Failure{kind = .HTTP_Status, status = status, detail = error_detail(status, &reader, request.allocator)}
	}

	if request.expected_content_type != "" {
		content_type, present := http.headers_get_unsafe(headers, "content-type")
		if !present || !content_type_matches(content_type, request.expected_content_type) {
			return Failure {
				kind = .Content_Type,
				status = status,
				detail = fmt.aprintf("response content-type is not %s", request.expected_content_type, allocator = request.allocator),
			}
		}
	}

	if framing, length, framing_err := response_framing(status, request.method, headers); framing_err != .None {
		return failure_from_error(framing_err)
	} else if body_err := stream_body(&reader, framing, length, user_data, callback); body_err != .None {
		return failure_from_error(body_err)
	}
	return {}
}

format_request :: proc(url: http.URL, request: Request) -> (buffer: bytes.Buffer) {
	// The request target is the origin-form of the URL -- path and query both.
	request_target := http.request_path(url, request.allocator)
	defer delete(request_target, request.allocator)

	bytes.buffer_init_allocator(&buffer, 0, len(request.body) + 512, request.allocator)

	// The request line is appended rather than formatted through a fixed buffer.
	// A URL has no length limit, and a line that outgrows such a buffer makes fmt
	// allocate from the ambient context allocator, which this call does not own
	// and never releases.
	bytes.buffer_write_string(&buffer, http.method_string(request.method))
	bytes.buffer_write_string(&buffer, " ")
	bytes.buffer_write_string(&buffer, request_target)
	bytes.buffer_write_string(&buffer, " HTTP/1.1\r\n")
	bytes.buffer_write_string(&buffer, "host: ")
	bytes.buffer_write_string(&buffer, url.host)
	bytes.buffer_write_string(&buffer, "\r\nconnection: close\r\n")
	length_line: [48]u8
	bytes.buffer_write_string(&buffer, fmt.bprintf(length_line[:], "content-length: %d\r\n", len(request.body)))
	for header in request.headers {
		bytes.buffer_write_string(&buffer, header.name)
		bytes.buffer_write_string(&buffer, ": ")
		bytes.buffer_write_string(&buffer, header.value)
		bytes.buffer_write_string(&buffer, "\r\n")
	}
	bytes.buffer_write_string(&buffer, "\r\n")
	bytes.buffer_write(&buffer, request.body)
	return
}

// resolve_endpoint turns a URL authority into a connectable endpoint. A literal
// address skips resolution; a name goes through the interruptible resolver, so
// cancellation during lookup retires with the operation instead of outliving it.
resolve_endpoint :: proc(url: http.URL, options: Options, allocator: mem.Allocator) -> (net.Endpoint, Error) {
	hostname, port, ok := host_and_port(url.host)
	if !ok || hostname == "" { return {}, .Invalid_URL }
	if port == 0 { port = 443 if url.scheme == "https" else 80 }
	if literal := net.parse_address(hostname); literal != nil {
		return net.Endpoint{address = literal, port = port}, .None
	}
	address, found, resolve_err := resolve_host(hostname, options, allocator)
	if resolve_err != .None { return {}, resolve_err }
	if !found { return {}, .Resolve }
	return net.Endpoint{address = address, port = port}, .None
}

read_response_head :: proc(reader: ^Reader, allocator: mem.Allocator) -> (status_code: int, headers: http.Headers, err: Error) {
	line, line_err := reader_line(reader)
	if line_err != .None { return 0, headers, line_err }
	code, parsed := parse_status_line(line)
	if !parsed { return 0, headers, .Bad_Response }
	status_code = code
	http.headers_init(&headers, allocator)
	for count := 0;; count += 1 {
		if count > HTTP_MAX_HEADER_LINES { return 0, headers, .Bad_Response }
		header_line, header_err := reader_line(reader)
		if header_err != .None { return 0, headers, header_err }
		if header_line == "" { break }
		if _, ok := http.header_parse(&headers, header_line, allocator); !ok {
			return 0, headers, .Bad_Response
		}
	}
	return status_code, headers, .None
}

parse_status_line :: proc(line: string) -> (int, bool) {
	space := strings.index_byte(line, ' ')
	if space < 0 { return 0, false }
	version, version_ok := http.version_parse(line[:space])
	if !version_ok || version.major != 1 { return 0, false }
	rest := line[space + 1:]
	code_text := rest
	if end := strings.index_byte(rest, ' '); end >= 0 { code_text = rest[:end] }
	code, code_ok := strconv.parse_int(code_text)
	if !code_ok || code < 100 || code > 599 { return 0, false }
	return code, true
}

content_type_matches :: proc(value, expected: string) -> bool {
	semi := strings.index_byte(value, ';')
	media := strings.trim_space(value if semi < 0 else value[:semi])
	return strings.equal_fold(media, expected)
}

// Body_Framing is how the end of a response body is found.
Body_Framing :: enum {
	// The response has no body at all.
	None,
	// The chunked transfer coding delimits the body.
	Chunked,
	// Exactly Length octets.
	Exact,
	// The body ends when the peer closes the connection.
	Until_Close,
}

// response_framing decides how a response body is delimited.
//
// RFC 9112 6.3, in order of precedence: a response to HEAD and any 1xx, 204 or
// 304 response is always terminated by the empty line that ends the field
// section, whatever its fields claim; a Transfer-Encoding whose final coding is
// chunked delimits the body, and one whose final coding is not chunked leaves a
// response delimited by the connection closing; a Content-Length gives the
// length in octets; and with neither, the body is delimited by the connection
// closing.
response_framing :: proc(status: int, method: http.Method, headers: http.Headers) -> (framing: Body_Framing, length: int, err: Error) {
	// 1. Responses that never carry content, whatever their fields say.
	if method == .Head || (status >= 100 && status < 200) || status == 204 || status == 304 {
		return .None, 0, .None
	}

	// 3 and 4. A Transfer-Encoding overrides Content-Length, and it is the final
	// coding that decides the framing.
	if encoding, has_encoding := http.headers_get_unsafe(headers, "transfer-encoding"); has_encoding {
		if final_transfer_coding_is_chunked(encoding) { return .Chunked, 0, .None }
		return .Until_Close, 0, .None
	}

	// 5 and 6. Content-Length.
	if length_text, has_length := http.headers_get_unsafe(headers, "content-length"); has_length {
		value, value_ok := content_length_parse(length_text)
		if !value_ok { return .None, 0, .Bad_Response }
		return .Exact, value, .None
	}

	// 8. No framing field at all.
	return .Until_Close, 0, .None
}

// final_transfer_coding_is_chunked reports whether the last coding of a
// Transfer-Encoding field is chunked. The final coding decides the framing, not
// the presence of the name anywhere in the list, and coding names are
// case-insensitive (RFC 9112 6.1 and 7).
final_transfer_coding_is_chunked :: proc(value: string) -> bool {
	last := value
	for {
		comma := strings.index_byte(last, ',')
		if comma < 0 { break }
		last = last[comma + 1:]
	}
	return strings.equal_fold(http.trim_ows(last), "chunked")
}

// content_length_parse reads a Content-Length field value. RFC 9112 6.3 item 5
// allows a comma-separated list only when every value is valid and identical, in
// which case the message is framed by that single value.
content_length_parse :: proc(value: string) -> (length: int, ok: bool) {
	parsed := -1
	remaining := value
	for part in strings.split_iterator(&remaining, ",") {
		text := http.trim_ows(part)
		if text == "" { return 0, false }
		number := 0
		for c in text {
			if c < '0' || c > '9' { return 0, false }
			if number > (max(int) - int(c - '0')) / 10 { return 0, false }
			number = number * 10 + int(c - '0')
		}
		if parsed >= 0 && parsed != number { return 0, false }
		parsed = number
	}
	if parsed < 0 { return 0, false }
	return parsed, true
}

stream_body :: proc(reader: ^Reader, framing: Body_Framing, length: int, user_data: rawptr, callback: Chunk_Callback) -> Error {
	switch framing {
	case .None:
		return .None
	case .Chunked:
		return stream_chunked(reader, user_data, callback)
	case .Exact:
		return stream_exact(reader, length, user_data, callback)
	case .Until_Close:
		return stream_until_closed(reader, user_data, callback)
	}
	return .None
}

stream_exact :: proc(reader: ^Reader, length: int, user_data: rawptr, callback: Chunk_Callback) -> Error {
	scratch: [16384]u8
	remaining := length
	for remaining > 0 {
		count := min(len(scratch), remaining)
		if err := reader_read_full(reader, scratch[:count]); err != .None { return err }
		callback(user_data, scratch[:count])
		remaining -= count
	}
	return .None
}

stream_until_closed :: proc(reader: ^Reader, user_data: rawptr, callback: Chunk_Callback) -> Error {
	scratch: [16384]u8
	for {
		count, err := reader_read(reader, scratch[:])
		if err == .Closed { return .None }
		if err != .None { return err }
		callback(user_data, scratch[:count])
	}
}

stream_chunked :: proc(reader: ^Reader, user_data: rawptr, callback: Chunk_Callback) -> Error {
	for {
		line, line_err := reader_line(reader)
		if line_err != .None { return line_err }
		size_text := line
		if semi := strings.index_byte(line, ';'); semi >= 0 { size_text = line[:semi] }
		size, size_ok := strconv.parse_int(strings.trim_space(size_text), 16)
		if !size_ok || size < 0 { return .Bad_Response }
		if size == 0 {
			for {
				trailer, trailer_err := reader_line(reader)
				if trailer_err != .None { return trailer_err }
				if trailer == "" { return .None }
			}
		}
		if err := stream_exact(reader, size, user_data, callback); err != .None { return err }
		ending: [2]u8
		if err := reader_read_full(reader, ending[:]); err != .None { return err }
		if ending[0] != '\r' || ending[1] != '\n' { return .Bad_Response }
	}
}

error_detail :: proc(status: int, reader: ^Reader, allocator: mem.Allocator) -> string {
	body := read_bounded_body(reader, HTTP_MAX_ERROR_BYTES, allocator)
	defer delete(body, allocator)
	text := strings.trim_space(body)
	if text == "" { return fmt.aprintf("HTTP %d: HTTP response was not successful", status, allocator = allocator) }
	limit := len(text)
	if limit > 2000 { limit = 2000 }
	return fmt.aprintf("HTTP %d: %s", status, text[:limit], allocator = allocator)
}

read_bounded_body :: proc(reader: ^Reader, limit: int, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	scratch: [4096]u8
	for strings.builder_len(builder) < limit {
		want := min(len(scratch), limit - strings.builder_len(builder))
		count, err := reader_read(reader, scratch[:want])
		if count > 0 { strings.write_bytes(&builder, scratch[:count]) }
		if err != .None || count == 0 { break }
	}
	return strings.to_string(builder)
}

// headers_destroy frees what http.header_parse allocated, which nabla:http does not
// provide.
@(private)
headers_destroy :: proc(headers: ^http.Headers, allocator: mem.Allocator) {
	for key, value in headers._kv {
		delete(value, allocator)
		delete(key, allocator)
	}
	delete(headers._kv)
	headers^ = {}
}

failure_from_error :: proc(err: Error, override: Failure_Kind = .None, detail: string = "") -> Failure {
	kind := override
	if kind == .None {
		switch err {
		case .Cancelled:
			kind = .Cancelled
		case .Timed_Out:
			kind = .Timed_Out
		case .Closed:
			kind = .Closed
		case .Truncated:
			kind = .Truncated
		case .TLS_Config, .TLS_Trust, .TLS_Hostname, .TLS_Peer_Rejected, .TLS_Handshake, .TLS_Read, .TLS_Write:
			kind = .TLS
		case .Invalid_URL:
			kind = .Invalid_URL
		case .None, .Connect, .Resolve, .Send, .Recv, .Bad_Response:
			kind = .Transport
		}
	}
	text := detail
	if text == "" { text = error_text(err) }
	return Failure{kind = kind, detail = text}
}

error_text :: proc(err: Error) -> string {
	switch err {
	case .None:
		return ""
	case .Cancelled:
		return "request cancelled"
	case .Timed_Out:
		return "request deadline exceeded"
	case .Closed:
		return "connection closed before a response arrived"
	case .Truncated:
		return "connection was lost before a response arrived"
	case .Connect:
		return "connection could not be established"
	case .Invalid_URL:
		return "request URL host is invalid"
	case .Resolve:
		return "host could not be resolved"
	case .TLS_Config:
		return "TLS could not be configured with peer verification"
	case .TLS_Trust:
		return "no trusted certificate store is available"
	case .TLS_Hostname:
		return "TLS could not verify the requested host"
	case .TLS_Peer_Rejected:
		return "TLS peer certificate was rejected"
	case .TLS_Handshake:
		return "TLS handshake failed"
	case .TLS_Read:
		return "TLS read failed"
	case .TLS_Write:
		return "TLS write failed"
	case .Send:
		return "request could not be sent"
	case .Recv:
		return "response could not be read"
	case .Bad_Response:
		return "HTTP response was malformed"
	}
	return "request failed"
}
