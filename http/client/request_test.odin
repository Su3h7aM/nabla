#+test
#+private file
package client

import "core:bytes"
import "core:mem"
import "core:strings"
import "core:testing"

import "nabla:http"

// _render formats a request the way the transport sends it. It runs under a
// tracking allocator, so a request that does not free what it takes fails the
// test instead of quietly leaking into the caller's.
_render :: proc(t: ^testing.T, request: Request) -> string {
	ambient := context.allocator

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, ambient)
	defer mem.tracking_allocator_destroy(&track)
	defer context.allocator = ambient

	// Both the request's own allocator and the ambient one are tracked: anything
	// the request reaches for through fmt lands on the ambient allocator.
	tracked := mem.tracking_allocator(&track)
	context.allocator = tracked

	owned := request
	owned.allocator = tracked

	buffer, _, formatted := format_request(http.url_parse(owned.url), owned)
	if !formatted { testing.fail_now(t, "the request could not be formatted") }
	text := strings.clone(bytes.buffer_to_string(&buffer), context.temp_allocator)
	bytes.buffer_destroy(&buffer)

	for _, entry in track.allocation_map {
		testing.expectf(t, false, "the request leaked %d bytes allocated at %v", entry.size, entry.location)
	}
	return text
}

// _request_line_of returns the first line of the rendered request, without CRLF.
_request_line_of :: proc(t: ^testing.T, request: Request) -> string {
	text := _render(t, request)
	end := strings.index(text, "\r\n")
	return text if end < 0 else text[:end]
}

@(test)
test_request_target :: proc(t: ^testing.T) {
	// RFC 9112 3.2.1: origin-form = absolute-path [ "?" query ]; an empty path
	// is sent as "/".
	query_request := Request {
		url    = "https://api.example.com/v1/responses?stream=true",
		method = .Post,
	}
	testing.expect_value(t, _request_line_of(t, query_request), "POST /v1/responses?stream=true HTTP/1.1")

	root_request := Request {
		url    = "https://api.example.com",
		method = .Get,
	}
	testing.expect_value(t, _request_line_of(t, root_request), "GET / HTTP/1.1")

	// RFC 9112 3: senders and recipients should support request lines of at least
	// 8000 octets.
	query := strings.repeat("a", 4096, context.temp_allocator)
	long_request := Request {
		url    = strings.concatenate({"https://api.example.com/v1/responses?q=", query}, context.temp_allocator),
		method = .Post,
	}
	line := _request_line_of(t, long_request)
	testing.expectf(t, strings.contains(line, query), "request line is %d octets and lost its query", len(line))
	testing.expectf(t, len(line) > 4096, "request line is only %d octets", len(line))

	// RFC 9112 3.2: a fragment is never sent; it names a part of the
	// response for the caller, not of the request for the peer.
	fragment_request := Request {
		url    = "https://api.example.com/v1#section",
		method = .Get,
	}
	testing.expect_value(t, _request_line_of(t, fragment_request), "GET /v1 HTTP/1.1")
}

// refused_request_case is one request validation expects refused, with the
// error it is refused with, before anything reaches the peer.
refused_request_case :: proc(url: string, headers: []Header, body: []u8, err: Error, t: ^testing.T) {
	request := Request {
		url     = url,
		method  = .Post,
		headers = headers,
		body    = body,
	}
	valid_err, _ := request_validate(http.url_parse(request.url), request, context.temp_allocator)
	testing.expect_value(t, valid_err, err)
}

@(test)
test_invalid_requests_are_refused_before_the_wire :: proc(t: ^testing.T) {
	// A scheme this client does not speak, and an empty host, stay URL errors.
	refused_request_case("gopher://api.example.com/", nil, nil, .Invalid_URL, t)
	refused_request_case("https://", nil, nil, .Invalid_URL, t)
	// Schemes compare without case; credentials are never sent.
	refused_request_case("HTTP://api.example.com/v1", nil, nil, .None, t)
	refused_request_case("https://user:pass@api.example.com/", nil, nil, .Invalid_URL, t)
	refused_request_case("https://api .example.com/", nil, nil, .Invalid_URL, t)
	// A target with a space would frame two lines as one request line.
	refused_request_case("https://api.example.com/v1 with space", nil, nil, .Invalid_Request, t)
	// Field names are tokens; values carry no control bytes.
	refused_request_case("https://api.example.com/", {{"x bad", "1"}}, nil, .Invalid_Request, t)
	refused_request_case("https://api.example.com/", {{"", "1"}}, nil, .Invalid_Request, t)
	refused_request_case("https://api.example.com/", {{"x-a", "1\r\ninjected: 2"}}, nil, .Invalid_Request, t)
	// This client frames with Content-Length or close, so a caller coding or
	// a conflicting length would frame ambiguously.
	refused_request_case("https://api.example.com/", {{"transfer-encoding", "chunked"}}, nil, .Invalid_Request, t)
	refused_request_case("https://api.example.com/", {{"content-length", "5"}}, transmute([]u8)string("hi"), .Invalid_Request, t)
	refused_request_case("https://api.example.com/", {{"content-length", "5x"}}, transmute([]u8)string("hello"), .Invalid_Request, t)
	// A length that states exactly the body is the caller's own value kept.
	refused_request_case("https://api.example.com/", {{"content-length", "2"}}, transmute([]u8)string("hi"), .None, t)
}

@(test)
test_request_heading_headers :: proc(t: ^testing.T) {
	request := Request {
		url    = "https://api.example.com:8443/v1/messages",
		method = .Post,
		body   = transmute([]u8)string(`{"a":1}`),
	}
	text := _render(t, request)

	// RFC 9112 3.2.1: Host is identical to the target URI's authority component.
	testing.expectf(t, strings.contains(text, "host: api.example.com:8443\r\n"), "missing host in:\n%s", text)

	// RFC 9112 6.3: a request with content is framed by Content-Length.
	testing.expectf(t, strings.contains(text, "content-length: 7\r\n"), "missing content-length in:\n%s", text)

	// RFC 9112 9.3: a client that does not support persistent connections sends
	// the "close" connection option in every request.
	testing.expectf(t, strings.contains(text, "connection: close\r\n"), "missing close in:\n%s", text)
}

@(test)
test_content_length_is_stated_only_where_it_means_something :: proc(t: ^testing.T) {
	// RFC 9110 8.6: a method that defines a meaning for enclosed content states its
	// length even when there is none, and a method that does not leaves the field out.
	empty_post := Request {
		url    = "https://api.example.com/v1/messages",
		method = .Post,
	}
	post_text := _render(t, empty_post)
	testing.expectf(t, strings.contains(post_text, "content-length: 0\r\n"), "an empty POST does not state its content:\n%s", post_text)

	empty_get := Request {
		url    = "https://api.example.com/",
		method = .Get,
	}
	get_text := _render(t, empty_get)
	testing.expectf(t, !strings.contains(get_text, "content-length"), "a GET states a length it has no content for:\n%s", get_text)
}

@(test)
test_a_callers_own_field_replaces_the_one_this_builder_supplies :: proc(t: ^testing.T) {
	// A request that keeps the connection it opened says so itself, and the field is
	// written once.
	request := Request {
		url     = "https://api.example.com/realtime",
		method  = .Get,
		headers = {{"connection", "Upgrade"}, {"upgrade", "websocket"}},
	}
	text := _render(t, request)
	testing.expectf(t, strings.contains(text, "connection: Upgrade\r\n"), "the caller's own connection field is missing:\n%s", text)
	testing.expectf(t, !strings.contains(text, "connection: close"), "the builder's connection field was written as well:\n%s", text)
	testing.expectf(t, strings.contains(text, "upgrade: websocket\r\n"), "the caller's upgrade field is missing:\n%s", text)
}

@(test)
test_the_body_offset_names_where_the_body_begins :: proc(t: ^testing.T) {
	// The offset is what lets a partial write say how much of the *body* the
	// transport took, so it must land exactly on the first body byte however
	// long the head is.
	for body in ([]string{"", "x", `{"a":1}`}) {
		request := Request {
			url       = "https://api.example.com/v1/messages",
			method    = .Post,
			headers   = {{"x-extra", "a-value-longer-than-the-line"}},
			body      = transmute([]u8)body,
			allocator = context.allocator,
		}
		rendered, body_offset, formatted := format_request(http.url_parse(request.url), request)
		defer bytes.buffer_destroy(&rendered)
		if !formatted { testing.fail_now(t, "the request could not be formatted") }

		text := bytes.buffer_to_string(&rendered)
		testing.expectf(t, body_offset >= 0 && body_offset <= len(text), "the offset should be inside the request")
		testing.expect_value(t, text[body_offset:], body)
		testing.expectf(t, strings.has_suffix(text[:body_offset], "\r\n\r\n"), "the body should begin after the empty line, got %q", text[:body_offset])
	}
}
