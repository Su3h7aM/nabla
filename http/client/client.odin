package client

import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
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
@(require_results)
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
	if reader_err := reader_init(&reader, connection_read_source, connection, request.allocator); reader_err != .None {
		return failure_from_error(reader_err, request.allocator)
	}
	defer reader_destroy(&reader)

	head, headers, head_err := read_final_response_head(&reader, request.allocator, request.method)
	defer http.headers_destroy(&headers)
	if head_err != .None { return failure_from_error(head_err, request.allocator) }
	status := head.code
	summary.response_head_received = true
	summary.status = status

	// The head is where a declared length comes from, whatever the status is, and a
	// refusal is reported for what it is however the head's framing turned out.
	framing, length, framing_err := response_framing(status, head.version, request.method, headers)
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
	// keeps what it wants and nothing is decided here on its behalf. If that transfer
	// fails, preserve both the refusal status and the error that ended its body.
	phase = .Response_Body
	if framing_err != .None {
		// The head's framing is unusable, so there is no body this client can frame
		// or hand over. A refusal is still reported as the refusal it is.
		if refusal.kind != .None { return refusal }
		return failure_from_error(framing_err, request.allocator)
	}
	if body_err := stream_body(&reader, framing, length, user_data, callback); body_err != .None {
		if refusal.kind != .None {
			refusal.cause = body_err
			return refusal
		}
		return failure_from_error(body_err, request.allocator)
	}
	if refusal.kind != .None { return refusal }

	phase = .Complete
	return {}
}

// event_loop_acquire brackets a request with the calling thread's event loop,
// which owns readiness for both the socket and the resolver's. The caller releases
// it when the request returns, including one that ends in an upgraded connection:
// that connection's later waits acquire the loop of whichever thread performs them.
@(require_results)
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
@(require_results)
request_send :: proc(
	request: Request,
	options: Options,
	phase: ^Transfer_Phase,
	summary: ^Transfer_Summary,
	connect_authority: string = "",
) -> (
	connection: ^Connection,
	failure: Failure,
) {
	url := http.url_parse(request.url)
	phase^ = .Validate
	if valid_err, valid_detail := request_validate(url, request, connect_authority); valid_err != .None {
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
	buffer, body_offset, formatted := format_request(url, request, connect_authority)
	defer bytes.buffer_destroy(&buffer)
	if !formatted {
		connection_destroy(dialed)
		return nil, failure_from_error(.Send, request.allocator, .Transport, "the request could not be built")
	}
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
@(require_results)
request_validate :: proc(url: http.URL, request: Request, connect_authority: string = "") -> (err: Error, detail: string) {
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

	if request.method == .Connect {
		// RFC 9110 9.3.6 forbids CONNECT content; RFC 9112 3.2.3 requires
		// its request target to be an explicit host-and-port authority.
		if !connect_authority_valid(connect_authority) {
			return .Invalid_Request, "CONNECT target must be a valid host and nonempty port"
		}
		if len(request.body) != 0 {
			return .Invalid_Request, "CONNECT requests cannot contain content"
		}
	} else {
		if connect_authority != "" { return .Invalid_Request, "a CONNECT target was supplied for a non-CONNECT request" }
		for part in ([2]string{url.path, url.query}) {
			for i in 0 ..< len(part) {
				if part[i] <= 0x20 || part[i] == 0x7F { return .Invalid_Request, "request target holds a control byte or space" }
			}
		}
	}

	connect_host_count := 0
	for header in request.headers {
		if !http.token_valid(header.name) { return .Invalid_Request, "a request field name is not a token" }
		for i in 0 ..< len(header.value) {
			if header.value[i] < 0x20 || header.value[i] == 0x7F {
				return .Invalid_Request, "a request field value holds a control byte"
			}
		}
		if request.method == .Connect && strings.equal_fold(header.name, "host") {
			connect_host_count += 1
			if header.value != connect_authority {
				return .Invalid_Request, "a CONNECT Host field must exactly match its target"
			}
			if connect_host_count > 1 { return .Invalid_Request, "a CONNECT request cannot contain more than one Host field" }
		}
		// This client frames with Content-Length or close, never with transfer
		// codings, so a caller coding would frame ambiguously.
		if strings.equal_fold(header.name, "transfer-encoding") {
			if request.method == .Connect { return .Invalid_Request, "CONNECT requests cannot contain Transfer-Encoding" }
			return .Invalid_Request, "this client sends no transfer codings"
		}
		if request.method == .Connect && strings.equal_fold(header.name, "content-length") {
			return .Invalid_Request, "CONNECT requests cannot contain Content-Length"
		}
		// A stated length that is invalid or differs from the body would frame
		// a different message than the one sent.
		if strings.equal_fold(header.name, "content-length") {
			stated, stated_ok := http.content_length_parse(header.value)
			if !stated_ok || stated != len(request.body) {
				return .Invalid_Request, "a stated content length conflicts with the body"
			}
		}
	}
	return .None, ""
}

// format_request builds the request line, the fields, and the body. body_offset is
// where the body begins, which is what lets a partial write say how much of the
// body the transport took rather than how much of the whole request it took.
@(require_results)
format_request :: proc(url: http.URL, request: Request, connect_authority: string = "") -> (buffer: bytes.Buffer, body_offset: int, formatted: bool) {
	bytes.buffer_init_allocator(&buffer, 0, len(request.body) + 512, request.allocator)

	// The request line is appended rather than formatted through a fixed buffer.
	// A URL has no length limit, and a line that outgrows such a buffer makes fmt
	// allocate from the ambient context allocator, which this call does not own
	// and never releases.
	// CONNECT uses authority-form (RFC 9112 3.2.3); other methods use origin-form
	// (RFC 9112 3.2.1). A fragment is never sent.
	target := url.path if url.path != "" else "/"
	if request.method == .Connect { target = connect_authority }
	if !request_buffer_string(&buffer, http.method_string(request.method)) ||
	   !request_buffer_string(&buffer, " ") ||
	   !request_buffer_string(&buffer, target) ||
	   (request.method != .Connect && url.query != "" && (!request_buffer_string(&buffer, "?") || !request_buffer_string(&buffer, url.query))) ||
	   !request_buffer_string(&buffer, " HTTP/1.1\r\n") {
		return buffer, 0, false
	}
	// A field this builder supplies is written once: a caller that set the same
	// field itself meant its own value, which is how a request states a connection
	// it keeps or a body length it already knows.
	if !request_has_header(request, "host") {
		host := url.host
		if request.method == .Connect { host = connect_authority }
		if !request_buffer_string(&buffer, "host: ") || !request_buffer_string(&buffer, host) || !request_buffer_string(&buffer, "\r\n") {
			return buffer, 0, false
		}
	}
	if request.method != .Connect && !request_has_header(request, "connection") && !request_buffer_string(&buffer, "connection: close\r\n") {
		return buffer, 0, false
	}
	if !request_has_header(request, "content-length") && request_states_length(request) {
		length_line: [48]u8
		if !request_buffer_string(&buffer, fmt.bprintf(length_line[:], "content-length: %d\r\n", len(request.body))) {
			return buffer, 0, false
		}
	}
	for header in request.headers {
		if !request_buffer_string(&buffer, header.name) ||
		   !request_buffer_string(&buffer, ": ") ||
		   !request_buffer_string(&buffer, header.value) ||
		   !request_buffer_string(&buffer, "\r\n") {
			return buffer, 0, false
		}
	}
	if !request_buffer_string(&buffer, "\r\n") { return buffer, 0, false }
	body_offset = bytes.buffer_length(&buffer)
	if !request_buffer_bytes(&buffer, request.body) { return buffer, 0, false }
	return buffer, body_offset, true
}

@(private, require_results)
request_buffer_string :: proc(buffer: ^bytes.Buffer, value: string) -> bool {
	written, err := bytes.buffer_write_string(buffer, value)
	return err == nil && written == len(value)
}

@(private, require_results)
request_buffer_bytes :: proc(buffer: ^bytes.Buffer, value: []u8) -> bool {
	written, err := bytes.buffer_write(buffer, value)
	return err == nil && written == len(value)
}

// request_states_length reports whether a request says how long its content is.
//
// RFC 9110 8.6: a request whose method defines a meaning for enclosed content states its
// length even when there is none, which is how a server tells an empty body from no body;
// a request with no content whose method defines no such meaning states nothing, because
// there is nothing to state.
@(require_results)
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
@(require_results)
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
@(require_results)
resolve_endpoints :: proc(url: http.URL, options: Options, allocator: mem.Allocator) -> (endpoints: []net.Endpoint, err: Error) {
	hostname, port, ok := host_and_port(url.host)
	if !ok || hostname == "" { return nil, .Invalid_URL }
	if port == 0 { port = 443 if url.scheme == "https" else 80 }
	if literal := net.parse_address(hostname); literal != nil {
		found, make_err := make([]net.Endpoint, 1, allocator)
		if make_err != nil { return nil, .No_Room }
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
	found, make_err := make([]net.Endpoint, len(addresses), allocator)
	if make_err != nil { return nil, .No_Room }
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
@(require_results)
status_detail :: proc(status: int, allocator: mem.Allocator) -> string {
	return fmt.aprintf("HTTP %d: the response status is not 2xx", status, allocator = allocator)
}

// Response_Status is what a status line says: the code and the version the
// peer speaks.
Response_Status :: struct {
	code:    int,
	version: http.Version,
}

@(require_results)
read_response_head :: proc(
	reader: ^Reader,
	allocator: mem.Allocator,
	method: http.Method = .Get,
) -> (
	status: Response_Status,
	headers: http.Headers,
	err: Error,
) {
	line, line_err := reader_line(reader)
	if line_err != .None { return {}, headers, line_err }
	code, version, parsed := parse_status_line(line)
	if !parsed { return {}, headers, .Bad_Response }
	http.headers_init(&headers, allocator)

	ignore_connect_framing := method == .Connect && code >= 200 && code < 300
	if section_err := read_field_section(reader, &headers, ignore_connect_framing); section_err != .None {
		return {}, headers, section_err
	}
	return {code, version}, headers, .None
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
@(require_results)
read_field_section :: proc(reader: ^Reader, headers: ^http.Headers, ignore_connect_framing: bool = false) -> Error {
	// The field a folded line continues.
	last_key: string
	for {
		header_line, header_err := reader_line(reader)
		if header_err != .None { return header_err }
		if header_line == "" { return .None }

		if header_line[0] == ' ' || header_line[0] == '\t' {
			if last_key == "" { return .Bad_Response }
			if !http.header_fold(headers, last_key, header_line) {
				return .Bad_Response
			}
			continue
		}

		// A successful CONNECT ignores framing fields. The shared parser rejects
		// conflicting Content-Length repetitions, so retain the first field instead
		// of letting an ignored field prevent the tunnel from being established.
		if ignore_connect_framing {
			colon := strings.index_byte(header_line, ':')
			if colon > 0 && strings.equal_fold(header_line[:colon], "content-length") {
				if _, present := http.headers_get_unsafe(headers^, "content-length"); present { continue }
			}
		}
		key, ok := http.header_parse(headers, header_line)
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
@(require_results)
read_final_response_head :: proc(
	reader: ^Reader,
	allocator: mem.Allocator,
	method: http.Method = .Get,
) -> (
	status: Response_Status,
	headers: http.Headers,
	err: Error,
) {
	// How many interim responses may precede the final one is not this client's
	// decision: RFC 9110 15.2 says a client must be able to parse one or more of
	// them. A peer that only ever sends them is bounded by the caller's own
	// cancellation and deadline, asked on every read.
	for {
		head_status, head, head_err := read_response_head(reader, allocator, method)
		if head_err != .None { return {}, head, head_err }
		if head_status.code == 101 || head_status.code >= 200 { return head_status, head, .None }

		http.headers_destroy(&head)
	}
}

@(require_results)
parse_status_line :: proc(line: string) -> (code: int, version: http.Version, ok: bool) {
	space := strings.index_byte(line, ' ')
	if space < 0 { return }
	version_ok: bool
	version, version_ok = http.version_parse(line[:space])
	if !version_ok || version.major != 1 { return }
	rest := line[space + 1:]
	code_text := rest
	if end := strings.index_byte(rest, ' '); end >= 0 { code_text = rest[:end] }
	// RFC 9112 4: status-code is exactly three digits. A code this client does not
	// recognize is still reported as the code it is, rather than refused for being
	// one this build happens to have a name for. The reason phrase after it is
	// discarded: RFC 9110 15 says a client should ignore it.
	if len(code_text) != 3 { return }
	for character in transmute([]u8)code_text {
		if character < '0' || character > '9' { return }
		code = code * 10 + int(character - '0')
	}
	if code < 100 { return }
	return code, version, true
}

@(require_results)
content_type_matches :: proc(value, expected: string) -> bool {
	semi := strings.index_byte(value, ';')
	media := http.trim_ows(value if semi < 0 else value[:semi])
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
@(require_results)
response_framing :: proc(status: int, version: http.Version, method: http.Method, headers: http.Headers) -> (framing: Body_Framing, length: int, err: Error) {
	// 1. Responses that never carry content, whatever their fields say.
	if method == .Head || (status >= 100 && status < 200) || status == 204 || status == 304 {
		return .None, 0, .None
	}
	// RFC 9112 6.3 item 2: a successful CONNECT begins a tunnel at the end of
	// the response head, regardless of either framing field.
	if method == .Connect && status >= 200 && status < 300 { return .None, 0, .None }

	// 3 and 4. A Transfer-Encoding overrides Content-Length, and it is the final
	// coding that decides the framing.
	if encoding, has_encoding := http.headers_get_unsafe(headers, "transfer-encoding"); has_encoding {
		// RFC 9112 6.1: Transfer-Encoding in an HTTP/1.0 message is faulty
		// framing, which a response survives only by reading to the close.
		if version.minor >= 1 && http.final_transfer_coding_is_chunked(encoding) { return .Chunked, 0, .None }
		return .Until_Close, 0, .None
	}

	// 5 and 6. Content-Length.
	if length_text, has_length := http.headers_get_unsafe(headers, "content-length"); has_length {
		value, value_ok := http.content_length_parse(length_text)
		if !value_ok { return .None, 0, .Bad_Response }
		return .Exact, value, .None
	}

	// 8. No framing field at all.
	return .Until_Close, 0, .None
}

@(require_results)
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

// stream_exact delivers exactly length octets. Each chunk is a view of the
// reader's buffer, borrowed for the callback.
@(require_results)
stream_exact :: proc(reader: ^Reader, length: int, user_data: rawptr, callback: Chunk_Callback) -> Error {
	remaining := length
	for remaining > 0 {
		chunk := reader_take(reader, remaining) or_return
		if callback != nil { callback(user_data, chunk) }
		remaining -= len(chunk)
	}
	return .None
}

// stream_until_closed delivers everything until the peer closes the stream.
@(require_results)
stream_until_closed :: proc(reader: ^Reader, user_data: rawptr, callback: Chunk_Callback) -> Error {
	for {
		chunk, err := reader_take(reader, max(int))
		if err == .Closed { return .None }
		if err != .None { return err }
		if callback != nil { callback(user_data, chunk) }
	}
}

@(require_results)
stream_chunked :: proc(reader: ^Reader, user_data: rawptr, callback: Chunk_Callback) -> Error {
	for {
		line, line_err := reader_line(reader)
		if line_err != .None { return line_err }
		size, size_ok := http.chunk_line_parse(line)
		if !size_ok { return .Bad_Response }
		if size == 0 {
			// RFC 9112 7.1.2: the body ends with a trailer section read to its
			// empty line. Its lines are field lines like any other, so a line
			// that is not one ends the body in failure rather than in a body
			// framed past garbage. The values are discarded; only the syntax
			// is checked, in scratch storage owned by this call.
			trailers: http.Headers
			http.headers_init(&trailers, reader.allocator)
			section_err := read_field_section(reader, &trailers)
			http.headers_destroy(&trailers)
			if section_err != .None { return section_err }
			return .None
		}
		if err := stream_exact(reader, size, user_data, callback); err != .None { return err }
		ending: [2]u8
		if err := reader_read_full(reader, ending[:]); err != .None { return err }
		if ending[0] != '\r' || ending[1] != '\n' { return .Bad_Response }
	}
}

// failure_from_error builds a failure from the transport's own error. The text is
// cloned so that every failure owns its detail, which is what lets one
// destructor release any of them.
@(require_results)
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
		case .None, .Connect, .Resolve, .Send, .Recv, .Bad_Response, .No_Room:
			kind = .Transport
		}
	}
	text := detail
	if text == "" { text = error_text(err) }
	message, clone_err := strings.clone(text, allocator)
	// A failure that could not copy its account is still the failure it is: the
	// kind and the cause are what the caller acts on.
	if clone_err != nil { message = "" }
	return Failure{kind = kind, cause = err, detail = message}
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
	case .No_Room:
		return "the client could not allocate memory"
	}
	return "request failed"
}
