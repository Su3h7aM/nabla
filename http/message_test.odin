#+test
#+private file
package http

import "core:testing"

@(test)
test_url_parse_and_request_target :: proc(t: ^testing.T) {
	url := url_parse("https://api.example.com:8443/v1/responses?stream=true")
	testing.expect_value(t, url.scheme, "https")
	testing.expect_value(t, url.host, "api.example.com:8443")
	testing.expect_value(t, url.path, "/v1/responses")
	testing.expect_value(t, url.query, "stream=true")

	// RFC 9112 3.2.1: origin-form = absolute-path [ "?" query ], and an empty
	// path is sent as "/".
	testing.expect_value(t, request_path(url_parse("https://a.example/b?c=d"), context.temp_allocator), "/b?c=d")
	testing.expect_value(t, request_path(url_parse("https://a.example"), context.temp_allocator), "/")
}

@(test)
test_method_round_trips :: proc(t: ^testing.T) {
	for method in Method {
		text := method_string(method)
		testing.expectf(t, text != "", "%v has no text", method)
		parsed, ok := method_parse(text)
		testing.expectf(t, ok, "%q did not parse", text)
		testing.expect_value(t, parsed, method)
	}
}

@(test)
test_header_field_lines :: proc(t: ^testing.T) {
	// RFC 9112 5.1 excludes only SP and HTAB from the field value, and RFC 9112
	// 2.2 forbids quietly deleting a bare CR, so a non-OWS byte survives.
	{
		headers: Headers
		headers_init(&headers, context.temp_allocator)
		_, ok := header_parse(&headers, "x:\ta\vb\t", context.temp_allocator)
		testing.expect(t, ok)
		value, found := headers_get_unsafe(headers, "x")
		testing.expect(t, found)
		testing.expect_value(t, value, "a\vb")
	}
	{
		headers: Headers
		headers_init(&headers, context.temp_allocator)
		_, ok := header_parse(&headers, "x: a\r", context.temp_allocator)
		testing.expect(t, ok)
		value, _ := headers_get_unsafe(headers, "x")
		testing.expect_value(t, value, "a\r")
	}

	// A field name is a token, so a line beginning with SP or HTAB is an
	// obs-fold continuation, not a field line.
	headers: Headers
	headers_init(&headers, context.temp_allocator)
	for line in ([]string{" x: 1", "\tx: 1", "\t: 1", " \t: 1"}) {
		_, ok := header_parse(&headers, line, context.temp_allocator)
		testing.expectf(t, !ok, "%q was accepted as a field line", line)
	}
}

@(test)
test_version_parse :: proc(t: ^testing.T) {
	version, ok := version_parse("HTTP/1.1")
	testing.expect(t, ok)
	testing.expect_value(t, version.major, 1)
	testing.expect_value(t, version.minor, 1)

	older, older_ok := version_parse("HTTP/1.0")
	testing.expect(t, older_ok)
	testing.expect_value(t, older.major, 1)
	testing.expect_value(t, older.minor, 0)

	// RFC 9112 2.3: HTTP-version = HTTP-name "/" DIGIT "." DIGIT, and HTTP-name
	// is case-sensitive. Anything else is rejected rather than read as a number.
	for text in ([]string{"", "HTTP/", "HTTP/1.", "HTTP/1.11", "http/1.1", "HTTP/1,1", "HTTP//1.1", " HTTP/1.1", "HTTP/a.b"}) {
		_, malformed := version_parse(text)
		testing.expectf(t, !malformed, "%q was accepted as a version", text)
	}
}
