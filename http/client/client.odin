package client

import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strconv"
import "core:strings"

import "nabla:http"


Failure_Kind :: enum {
	None,
	Cancelled,
	Timed_Out,
	TLS,
	Transport,
	Truncated,
	Closed,
	Invalid_URL,
	Invalid_Request,
	HTTP_Status,
	Content_Type,
}

// Failure describes why a request did not deliver a usable response. Every kind
// owns exactly the same field, `detail`, so one destructor releases any of them.
Failure :: struct {
	kind:   Failure_Kind,
	// cause is the transport error this failure came from, and is .None for a
	// failure that never reached the transport: a URL this client refuses, a
	// status it will not use, or a media type the caller did not ask for. The kind
	// is the coarse view of the same fact; the cause is what keeps a peer that
	// never authenticated distinct from a connection that broke after the request
	// went out.
	cause:  Error,
	status: int,
	// detail is a short human-readable account, owned by the caller.
	detail: string,
}

// failure_destroy releases what a failure owns.
failure_destroy :: proc(failure: ^Failure, allocator: mem.Allocator) {
	if failure == nil { return }
	if failure.detail != "" { delete(failure.detail, allocator) }
	failure^ = {}
}

// Chunk_Callback receives response body bytes as they arrive. A nil callback
// discards the body.
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
//
// The body is delivered whatever the status is. A response this client will not
// use still carries the peer's own account of what went wrong, and HTTP places no
// limit on a body (RFC 9110 5.4), so no size is invented here and the caller
// decides how much of it to keep.
stream_request :: proc(request: Request, options: Options, user_data: rawptr, callback: Chunk_Callback) -> (failure: Failure) {
	// One observation per request, reported on every path once validation has
	// begun. The phase names the stage about to run, so an error inside a stage is
	// reported as that stage: a failure before anything was written cannot be
	// confused with one after the whole request went out.
	summary: Transfer_Summary
	phase := Transfer_Phase.Validate
	defer {
		summary.stopped_at = phase
		summary.error = failure.cause
		if options.observer.complete != nil {
			options.observer.complete(options.observer.user_data, summary)
		}
	}

	if loop_failure := event_loop_acquire(request.allocator); loop_failure.kind != .None { return loop_failure }
	defer nbio.release_thread_event_loop()

	connection, send_failure := request_send(request, options, &phase, &summary)
	if send_failure.kind != .None { return send_failure }
	defer connection_destroy(connection)

	phase = .Response_Head
	reader: Reader
	reader_init(&reader, connection_read_source, connection, request.allocator)
	defer reader_destroy(&reader)

	status, headers, head_err := read_final_response_head(&reader, request.allocator)
	defer headers_destroy(&headers, request.allocator)
	if head_err != .None { return failure_from_error(head_err, request.allocator) }
	summary.response_head_received = true
	summary.status = status

	// The head is where a declared length comes from, whatever the status is, and a
	// refusal is reported for what it is however the head's framing turned out.
	framing, length, framing_err := response_framing(status, request.method, headers)
	if framing_err == .None && framing == Body_Framing.Exact {
		summary.declared_body_bytes = u64(length)
		summary.declared_body_bytes_present = true
	}

	// The head is reported before its body, so a caller that has to read the
	// peer's own account of what went wrong knows what arrived in time to decide
	// how much of that body to keep. The fields are borrowed for this call only.
	//
	// Anything outside 2xx ends the request and is reported by its status.
	// Redirects are deliberately not followed: RFC 9110 15.4 makes automatic
	// redirection optional for a user agent, and no API this client serves depends
	// on it. A response whose media type is not the one the caller asked for is a
	// refusal too: that is the shape a 2xx error document takes.
	status_usable := status >= 200 && status < 300
	content_type_usable := true
	if request.expected_content_type != "" {
		value, present := http.headers_get_unsafe(headers, "content-type")
		content_type_usable = present && content_type_matches(value, request.expected_content_type)
	}
	if options.response_head.observed != nil {
		head := Response_Head {
			status = status,
			usable = status_usable && content_type_usable,
		}
		options.response_head.observed(options.response_head.user_data, head, headers)
	}

	refusal: Failure
	if !status_usable {
		refusal = Failure {
			kind   = .HTTP_Status,
			status = status,
			detail = status_detail(status, request.allocator),
		}
	} else if !content_type_usable {
		refusal = Failure {
			kind   = .Content_Type,
			status = status,
			detail = fmt.aprintf("response content-type is not %s (HTTP %d)", request.expected_content_type, status, allocator = request.allocator),
		}
	}

	// A refused response still has a body, and that body is the peer's own account
	// of why. It is framed and delivered exactly as a usable one is, so the caller
	// keeps what it wants and nothing is decided here on its behalf. The phase stays
	// in the body: what ended the exchange was the status, not the transport, and the
	// status is what the caller reads.
	phase = .Response_Body
	if framing_err != .None {
		// The head's framing is unusable, so there is no body this client can frame
		// or hand over. A refusal is still reported as the refusal it is.
		if refusal.kind != .None { return refusal }
		return failure_from_error(framing_err, request.allocator)
	}
	if body_err := stream_body(&reader, framing, length, user_data, callback); body_err != .None {
		if refusal.kind != .None { return refusal }
		return failure_from_error(body_err, request.allocator)
	}
	if refusal.kind != .None { return refusal }

	phase = .Complete
	return {}
}

// event_loop_acquire brackets a request with the calling thread's event loop,
// which owns readiness for both the socket and the resolver's. The caller releases
// it, except when the request ends in an upgraded connection: that connection's
// holder waits on the loop for as long as the connection lives, so the acquisition
// passes to it.
event_loop_acquire :: proc(allocator: mem.Allocator) -> Failure {
	if nbio.acquire_thread_event_loop() != nil {
		return failure_from_error(.None, allocator, .Transport, "the event loop could not be started")
	}
	return {}
}

// request_send validates a request, opens its connection, and writes it. The
// connection is returned complete, with its TLS session when the URL is https, and
// the caller takes ownership of it; a failure is returned with the connection
// already released. The caller holds the thread's event loop and releases it.
//
// phase and summary are written in place, so the caller's single observation covers
// validation and the request write as well as the response that follows.
request_send :: proc(request: Request, options: Options, phase: ^Transfer_Phase, summary: ^Transfer_Summary) -> (connection: ^Connection, failure: Failure) {
	url := http.url_parse(request.url)
	phase^ = .Validate
	if valid_err, valid_detail := request_validate(url, request, request.allocator); valid_err != .None {
		// A refused request never reached the transport, so like a refused
		// URL it carries no cause; the kind names the refusal.
		kind := Failure_Kind.Invalid_Request
		if valid_err == .Invalid_URL { kind = .Invalid_URL }
		return nil, failure_from_error(.None, request.allocator, kind, valid_detail)
	}

	phase^ = .Resolve
	if stop := stop_from_wait(probe_now(options.probe)); stop != .None {
		return nil, failure_from_error(error_from_stop(stop), request.allocator)
	}
	endpoints, resolve_err := resolve_endpoints(url, options, request.allocator)
	if resolve_err != .None { return nil, failure_from_error(resolve_err, request.allocator) }
	defer delete(endpoints, request.allocator)
	if len(endpoints) == 0 { return nil, failure_from_error(.Resolve, request.allocator) }
	if stop := stop_from_wait(probe_now(options.probe)); stop != .None {
		return nil, failure_from_error(error_from_stop(stop), request.allocator)
	}

	phase^ = .Connect
	dialed, dial_err := dial_first(endpoints, options, request.allocator)
	if dial_err != .None { return nil, failure_from_error(dial_err, request.allocator) }

	if url.scheme == "https" {
		phase^ = .TLS
		if handshake_err := connection_handshake(dialed, url.host); handshake_err != .None {
			detail := handshake_failure_detail(dialed, handshake_err, request.allocator)
			defer if detail != "" { delete(detail, request.allocator) }
			connection_destroy(dialed)
			return nil, failure_from_error(handshake_err, request.allocator, .None, detail)
		}
	}

	phase^ = .Request_Write
	buffer, body_offset := format_request(url, request)
	defer bytes.buffer_destroy(&buffer)
	request_bytes := bytes.buffer_to_bytes(&buffer)
	summary.request_write_started = true
	accepted, write_err := connection_write_all(dialed, request_bytes)
	summary.request_bytes_accepted = u64(accepted)
	summary.request_body_bytes_accepted = u64(max(accepted - body_offset, 0))
	summary.request_complete = accepted == len(request_bytes)
	if write_err != .None {
		connection_destroy(dialed)
		return nil, failure_from_error(write_err, request.allocator)
	}
	return dialed, {}
}

// request_validate refuses what this client will not put on the wire: a URL
// it does not speak, and fields or a target that would frame ambiguously or
// inject bytes. URL problems report Invalid_URL; everything the caller built
// reports Invalid_Request. The detail is a static string the failure clones.
request_validate :: proc(url: http.URL, request: Request, allocator: mem.Allocator) -> (err: Error, detail: string) {
	// RFC 9110 4.2.3: schemes are case-insensitive.
	if !strings.equal_fold(url.scheme, "http") && !strings.equal_fold(url.scheme, "https") {
		return .Invalid_URL, "URL scheme must be http or https"
	}
	if url.host == "" { return .Invalid_URL, "URL host is empty" }
	if strings.index_byte(url.host, '@') >= 0 {
		return .Invalid_URL, "URL authority states userinfo, which this client does not send"
	}
	for i in 0 ..< len(url.host) {
		if url.host[i] <= 0x20 || url.host[i] == 0x7F { return .Invalid_URL, "URL host holds a control byte or space" }
	}

	target := http.request_path(url, allocator)
	defer delete(target, allocator)
	if cut := strings.index_byte(target, '#'); cut >= 0 { target = target[:cut] }
	for i in 0 ..< len(target) {
		if target[i] <= 0x20 || target[i] == 0x7F { return .Invalid_Request, "request target holds a control byte or space" }
	}

	for header in request.headers {
		if !field_name_is_token(header.name) { return .Invalid_Request, "a request field name is not a token" }
		for i in 0 ..< len(header.value) {
			if header.value[i] < 0x20 || header.value[i] == 0x7F {
				return .Invalid_Request, "a request field value holds a control byte"
			}
		}
		// This client frames with Content-Length or close, never with transfer
		// codings, so a caller coding would frame ambiguously.
		if strings.equal_fold(header.name, "transfer-encoding") {
			return .Invalid_Request, "this client sends no transfer codings"
		}
		// A stated length that is invalid or differs from the body would frame
		// a different message than the one sent.
		if strings.equal_fold(header.name, "content-length") {
			stated, stated_ok := content_length_parse(header.value)
			if !stated_ok || stated != len(request.body) {
				return .Invalid_Request, "a stated content length conflicts with the body"
			}
		}
	}
	return .None, ""
}

// field_name_is_token reports whether a name is an HTTP token: one or more
// tchars (RFC 9110 5.1).
field_name_is_token :: proc(name: string) -> bool {
	if len(name) == 0 { return false }
	for i in 0 ..< len(name) {
		switch name[i] {
		case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		case:
			if (name[i] < '0' || name[i] > '9') && (name[i] < 'a' || name[i] > 'z') && (name[i] < 'A' || name[i] > 'Z') {
				return false
			}
		}
	}
	return true
}

// format_request builds the request line, the fields, and the body. body_offset is
// where the body begins, which is what lets a partial write say how much of the
// body the transport took rather than how much of the whole request it took.
format_request :: proc(url: http.URL, request: Request) -> (buffer: bytes.Buffer, body_offset: int) {
	// The request target is the origin-form of the URL -- path and query both.
	// A fragment is never sent: RFC 9112 3.2 excludes it from the target.
	request_target := http.request_path(url, request.allocator)
	defer delete(request_target, request.allocator)
	if cut := strings.index_byte(request_target, '#'); cut >= 0 { request_target = request_target[:cut] }

	bytes.buffer_init_allocator(&buffer, 0, len(request.body) + 512, request.allocator)

	// The request line is appended rather than formatted through a fixed buffer.
	// A URL has no length limit, and a line that outgrows such a buffer makes fmt
	// allocate from the ambient context allocator, which this call does not own
	// and never releases.
	bytes.buffer_write_string(&buffer, http.method_string(request.method))
	bytes.buffer_write_string(&buffer, " ")
	bytes.buffer_write_string(&buffer, request_target)
	bytes.buffer_write_string(&buffer, " HTTP/1.1\r\n")
	// A field this builder supplies is written once: a caller that set the same
	// field itself meant its own value, which is how a request states a connection
	// it keeps or a body length it already knows.
	if !request_has_header(request, "host") {
		bytes.buffer_write_string(&buffer, "host: ")
		bytes.buffer_write_string(&buffer, url.host)
		bytes.buffer_write_string(&buffer, "\r\n")
	}
	if !request_has_header(request, "connection") {
		bytes.buffer_write_string(&buffer, "connection: close\r\n")
	}
	if !request_has_header(request, "content-length") && request_states_length(request) {
		length_line: [48]u8
		bytes.buffer_write_string(&buffer, fmt.bprintf(length_line[:], "content-length: %d\r\n", len(request.body)))
	}
	for header in request.headers {
		bytes.buffer_write_string(&buffer, header.name)
		bytes.buffer_write_string(&buffer, ": ")
		bytes.buffer_write_string(&buffer, header.value)
		bytes.buffer_write_string(&buffer, "\r\n")
	}
	bytes.buffer_write_string(&buffer, "\r\n")
	body_offset = len(bytes.buffer_to_bytes(&buffer))
	bytes.buffer_write(&buffer, request.body)
	return
}

// request_states_length reports whether a request says how long its content is.
//
// RFC 9110 8.6: a request whose method defines a meaning for enclosed content states its
// length even when there is none, which is how a server tells an empty body from no body;
// a request with no content whose method defines no such meaning states nothing, because
// there is nothing to state.
request_states_length :: proc(request: Request) -> bool {
	if len(request.body) > 0 { return true }
	switch request.method {
	case .Post, .Put, .Patch:
		return true
	case .Get, .Head, .Delete, .Options, .Trace, .Connect:
		return false
	}
	return false
}

// request_has_header reports whether the caller set a field, so the defaults this
// builder would supply do not appear twice.
request_has_header :: proc(request: Request, name: string) -> bool {
	for header in request.headers {
		if strings.equal_fold(header.name, name) { return true }
	}
	return false
}

// resolve_endpoints turns a URL authority into connectable endpoints: every
// usable address for a name, or the single literal address. A literal
// address skips resolution; a name goes through the interruptible resolver,
// so cancellation during lookup retires with the operation instead of
// outliving it. The caller owns the result on every path.
resolve_endpoints :: proc(url: http.URL, options: Options, allocator: mem.Allocator) -> (endpoints: []net.Endpoint, err: Error) {
	hostname, port, ok := host_and_port(url.host)
	if !ok || hostname == "" { return nil, .Invalid_URL }
	if port == 0 { port = 443 if url.scheme == "https" else 80 }
	if literal := net.parse_address(hostname); literal != nil {
		found := make([]net.Endpoint, 1, allocator)
		found[0] = net.Endpoint {
			address = literal,
			port    = port,
		}
		return found, .None
	}
	addresses, resolve_err := resolve_addresses(hostname, options, allocator)
	defer delete(addresses)
	if resolve_err != .None { return nil, resolve_err }
	if len(addresses) == 0 { return nil, .Resolve }
	found := make([]net.Endpoint, len(addresses), allocator)
	for address, i in addresses {
		found[i] = net.Endpoint {
			address = address,
			port    = port,
		}
	}
	return found, .None
}

// status_detail names the status a response was refused for. The reason phrase
// is left out on purpose: RFC 9110 15 tells a client to ignore it because it is
// not a reliable channel for information.
status_detail :: proc(status: int, allocator: mem.Allocator) -> string {
	return fmt.aprintf("HTTP %d: the response status is not 2xx", status, allocator = allocator)
}

// append_folded_value continues a field with the value of a folded line.
//
// RFC 9112 5.2 defines obs-fold as OWS CRLF RWS and requires a user agent that
// receives one in a response to replace it with one or more SP octets before the
// field value is interpreted. The continuation's leading whitespace is the RWS,
// and a continuation carrying nothing adds nothing, because trailing whitespace is
// excluded from the field value when it is extracted.
append_folded_value :: proc(headers: ^http.Headers, key, line: string, allocator: mem.Allocator) -> bool {
	value := http.trim_ows(line)
	if value == "" { return true }

	_, value_ptr, just_inserted := http.headers_entry_unsafe(headers, key)
	if just_inserted { return false }

	continued := strings.concatenate({value_ptr^, " ", value}, allocator)
	delete(value_ptr^, allocator)
	value_ptr^ = continued
	return true
}

read_response_head :: proc(reader: ^Reader, allocator: mem.Allocator) -> (status_code: int, headers: http.Headers, err: Error) {
	line, line_err := reader_line(reader)
	if line_err != .None { return 0, headers, line_err }
	code, parsed := parse_status_line(line)
	if !parsed { return 0, headers, .Bad_Response }
	status_code = code
	http.headers_init(&headers, allocator)

	if section_err := read_field_section(reader, &headers, allocator); section_err != .None {
		return 0, headers, section_err
	}
	return status_code, headers, .None
}

// read_field_section reads field lines until the empty line that ends them.
// A line beginning with whitespace continues the previous field as an obs-fold
// (RFC 9112 5.2); one that continues nothing is a message that cannot be read
// as a field section. A field line cannot begin with whitespace (RFC 9112 5),
// so whitespace here can only be an obs-fold.
//
// The section is read until its empty line, with no bound on how many fields it
// may hold or how long any of them may be: RFC 9110 5.4 states that HTTP places
// no predefined limit on a field line, a field value, or a field section, and a
// client that refuses a long one fails where every other client succeeds.
read_field_section :: proc(reader: ^Reader, headers: ^http.Headers, allocator: mem.Allocator) -> Error {
	// The field a folded line continues.
	last_key: string
	for {
		header_line, header_err := reader_line(reader)
		if header_err != .None { return header_err }
		if header_line == "" { return .None }

		if header_line[0] == ' ' || header_line[0] == '\t' {
			if last_key == "" { return .Bad_Response }
			if !append_folded_value(headers, last_key, header_line, allocator) {
				return .Bad_Response
			}
			continue
		}

		key, ok := http.header_parse(headers, header_line, allocator)
		if !ok { return .Bad_Response }
		last_key = key
	}
	return .None
}

// read_final_response_head reads response heads until a final one arrives.
//
// RFC 9112 9.2: responses are associated with requests in the order they arrive on
// a connection, and that association is only complete on a final (non-1xx)
// response. RFC 9112 6.3 item 1: an interim response cannot carry a body or a
// trailer section, so each one is discarded in place and the next head is read.
//
// 101 is the exception. It ends the HTTP exchange rather than preceding a final
// response, and this client never asks to upgrade, so an unexpected 101 is
// returned as the final response for the caller to report as a failure rather
// than being waited past.
read_final_response_head :: proc(reader: ^Reader, allocator: mem.Allocator) -> (status_code: int, headers: http.Headers, err: Error) {
	// How many interim responses may precede the final one is not this client's
	// decision: RFC 9110 15.2 says a client must be able to parse one or more of
	// them. A peer that only ever sends them is bounded by the caller's own
	// cancellation and deadline, asked on every read.
	for {
		code, head, head_err := read_response_head(reader, allocator)
		if head_err != .None { return 0, head, head_err }
		if code == 101 || code >= 200 { return code, head, .None }

		headers_destroy(&head, allocator)
	}
}

parse_status_line :: proc(line: string) -> (int, bool) {
	space := strings.index_byte(line, ' ')
	if space < 0 { return 0, false }
	version, version_ok := http.version_parse(line[:space])
	if !version_ok || version.major != 1 { return 0, false }
	rest := line[space + 1:]
	code_text := rest
	if end := strings.index_byte(rest, ' '); end >= 0 { code_text = rest[:end] }
	// RFC 9112 4: status-code is exactly three digits. A code this client does not
	// recognize is still reported as the code it is, rather than refused for being
	// one this build happens to have a name for. The reason phrase after it is
	// discarded: RFC 9110 15 says a client should ignore it.
	if len(code_text) != 3 { return 0, false }
	code, code_ok := strconv.parse_int(code_text)
	if !code_ok || code < 100 { return 0, false }
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
		if callback != nil { callback(user_data, scratch[:count]) }
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
		if callback != nil { callback(user_data, scratch[:count]) }
	}
}

stream_chunked :: proc(reader: ^Reader, user_data: rawptr, callback: Chunk_Callback) -> Error {
	for {
		line, line_err := reader_line(reader)
		if line_err != .None { return line_err }
		size_text := line
		extensions := ""
		if semi := strings.index_byte(line, ';'); semi >= 0 {
			size_text = line[:semi]
			extensions = line[semi:]
		}
		size, size_ok := http.chunk_size_parse(size_text)
		if !size_ok || !chunk_extensions_valid(extensions) { return .Bad_Response }
		if size == 0 {
			// RFC 9112 7.1.2: the body ends with a trailer section read to its
			// empty line. Its lines are field lines like any other, so a line
			// that is not one ends the body in failure rather than in a body
			// framed past garbage. The values are discarded; only the syntax
			// is checked, in scratch storage owned by this call.
			trailers: http.Headers
			http.headers_init(&trailers, reader.allocator)
			section_err := read_field_section(reader, &trailers, reader.allocator)
			headers_destroy(&trailers, reader.allocator)
			if section_err != .None { return section_err }
			return .None
		}
		if err := stream_exact(reader, size, user_data, callback); err != .None { return err }
		ending: [2]u8
		if err := reader_read_full(reader, ending[:]); err != .None { return err }
		if ending[0] != '\r' || ending[1] != '\n' { return .Bad_Response }
	}
}

// chunk_extensions_valid reports whether the text after the chunk-size on a
// chunk-size line is a legal chunk-ext sequence. RFC 9112 7.1.1: a recipient
// ignores unrecognized extensions, but the sequence still has to parse; a size
// line that is not a chunk at all ends the body in failure rather than in a
// body framed by a guess. Empty text means no extensions, which is valid.
chunk_extensions_valid :: proc(text: string) -> bool {
	rest := text
	for {
		rest = http.trim_ows(rest)
		if rest == "" { return true }
		if rest[0] != ';' { return false }
		rest = http.trim_ows(rest[1:])
		width := 0
		for width < len(rest) && is_token_char(rest[width]) { width += 1 }
		if width == 0 { return false }
		rest = http.trim_ows(rest[width:])
		if len(rest) > 0 && rest[0] == '=' {
			rest = http.trim_ows(rest[1:])
			value_width, value_ok := chunk_ext_value_width(rest)
			if !value_ok { return false }
			rest = rest[value_width:]
		}
	}
}

// chunk_ext_value_width measures a chunk extension value at the start of text:
// a token or a quoted-string, RFC 9112 7.1.1. It returns how many bytes the
// value occupies and whether one was there at all.
chunk_ext_value_width :: proc(text: string) -> (width: int, ok: bool) {
	if text == "" { return 0, false }
	if text[0] != '"' {
		for width < len(text) && is_token_char(text[width]) { width += 1 }
		if width == 0 { return 0, false }
		return width, true
	}
	i := 1
	for i < len(text) {
		c := text[i]
		if c == '\\' {
			i += 1
			if i >= len(text) { return 0, false }
			c = text[i]
			// quoted-pair = "\" ( HTAB / SP / VCHAR / obs-text ).
			if c != '\t' && c != ' ' && (c < 0x21 || c > 0x7e) && c < 0x80 {
				return 0, false
			}
			i += 1
			continue
		}
		if c == '"' { return i + 1, true }
		// qdtext = HTAB / SP / %x21 / %x23-5B / %x5D-7E / obs-text.
		if c == '\t' || c == ' ' || c == 0x21 || (c >= 0x23 && c <= 0x5b) || (c >= 0x5d && c <= 0x7e) || c >= 0x80 {
			i += 1
			continue
		}
		return 0, false
	}
	return 0, false
}

// is_token_char reports whether a byte may appear in an HTTP token, RFC 9110
// 5.6.2. Chunk extension names are tokens, and so are their values unless
// quoted.
is_token_char :: proc(c: byte) -> bool {
	switch c {
	case '0' ..= '9', 'a' ..= 'z', 'A' ..= 'Z':
		return true
	case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		return true
	case:
		return false
	}
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

// failure_from_error builds a failure from the transport's own error. The text is
// cloned so that every failure owns its detail, which is what lets one
// destructor release any of them.
failure_from_error :: proc(err: Error, allocator: mem.Allocator, override: Failure_Kind = .None, detail: string = "") -> Failure {
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
		case .Invalid_Request:
			kind = .Invalid_Request
		case .None, .Connect, .Resolve, .Send, .Recv, .Bad_Response:
			kind = .Transport
		}
	}
	text := detail
	if text == "" { text = error_text(err) }
	return Failure{kind = kind, cause = err, detail = strings.clone(text, allocator)}
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
	case .Invalid_Request:
		return "request holds a field this client will not send"
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
