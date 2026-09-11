package http

import "core:testing"

@(test)
test_url_parse_splits_the_reference :: proc(t: ^testing.T) {
	url := url_parse("https://api.example.com:8443/v1/responses?stream=true")
	testing.expect_value(t, url.scheme, "https")
	testing.expect_value(t, url.host, "api.example.com:8443")
	testing.expect_value(t, url.path, "/v1/responses")
	testing.expect_value(t, url.query, "stream=true")
}

@(test)
test_request_path_is_the_origin_form :: proc(t: ^testing.T) {
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
test_a_field_value_keeps_bytes_that_are_not_ows :: proc(t: ^testing.T) {
	// RFC 9112 5.1 excludes optional whitespace -- SP and HTAB -- from the field
	// line value. Anything else is not whitespace to discard, and a bare CR is
	// not something a parser may quietly remove (RFC 9112 2.2).
	headers: Headers
	headers_init(&headers, context.temp_allocator)

	_, ok := header_parse(&headers, "x:\ta\vb\t", context.temp_allocator)
	testing.expect(t, ok)
	value, found := headers_get_unsafe(headers, "x")
	testing.expect(t, found)
	testing.expect_value(t, value, "a\vb")
}

@(test)
test_a_field_value_keeps_a_trailing_carriage_return :: proc(t: ^testing.T) {
	// A trailing CR is not optional whitespace, so it is not trimmed away. RFC 9112
	// 2.2 lets a recipient either treat a bare CR as invalid or replace it with SP;
	// silently deleting it is neither.
	headers: Headers
	headers_init(&headers, context.temp_allocator)

	_, ok := header_parse(&headers, "x: a\r", context.temp_allocator)
	testing.expect(t, ok)
	value, _ := headers_get_unsafe(headers, "x")
	testing.expect_value(t, value, "a\r")
}

@(test)
test_a_field_line_cannot_begin_with_whitespace :: proc(t: ^testing.T) {
	// RFC 9112 5: field-line = field-name ":" OWS field-value OWS, and a field name
	// is a token, so a field line cannot begin with whitespace. RFC 9112 5.2 defines
	// obs-fold as OWS CRLF RWS, and RWS is SP or HTAB, so a line beginning with
	// either is a continuation rather than a field line -- including a tab.
	headers: Headers
	headers_init(&headers, context.temp_allocator)

	for line in ([]string{" x: 1", "\tx: 1", "\t: 1", " \t: 1"}) {
		_, ok := header_parse(&headers, line, context.temp_allocator)
		testing.expectf(t, !ok, "%q was accepted as a field line", line)
	}
}

@(test)
test_version_parse_reads_http_1_1 :: proc(t: ^testing.T) {
	version, ok := version_parse("HTTP/1.1")
	testing.expect(t, ok)
	testing.expect_value(t, version.major, 1)
	testing.expect_value(t, version.minor, 1)

	older, older_ok := version_parse("HTTP/1.0")
	testing.expect(t, older_ok)
	testing.expect_value(t, older.major, 1)
	testing.expect_value(t, older.minor, 0)
}

@(test)
test_version_parse_rejects_a_non_digit :: proc(t: ^testing.T) {
	// RFC 9112 2.3: HTTP-version = HTTP-name "/" DIGIT "." DIGIT. A field that is
	// not digits must be rejected rather than read as a number.
	_, ok := version_parse("HTTP/a.b")
	testing.expect(t, !ok)
}

@(test)
test_version_parse_rejects_a_malformed_field :: proc(t: ^testing.T) {
	// HTTP-name is case-sensitive (RFC 9112 2.3), and both digits are required.
	malformed := []string{"", "HTTP/", "HTTP/1.", "HTTP/1.11", "http/1.1", "HTTP/1,1", "HTTP//1.1", " HTTP/1.1"}
	for text in malformed {
		_, ok := version_parse(text)
		testing.expectf(t, !ok, "%q was accepted as a version", text)
	}
}
