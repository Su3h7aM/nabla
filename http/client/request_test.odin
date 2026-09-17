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

	buffer, _ := format_request(http.url_parse(owned.url), owned)
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
		rendered, body_offset := format_request(http.url_parse(request.url), request)
		defer bytes.buffer_destroy(&rendered)

		text := bytes.buffer_to_string(&rendered)
		testing.expectf(t, body_offset >= 0 && body_offset <= len(text), "the offset should be inside the request")
		testing.expect_value(t, text[body_offset:], body)
		testing.expectf(t, strings.has_suffix(text[:body_offset], "\r\n\r\n"), "the body should begin after the empty line, got %q", text[:body_offset])
	}
}
