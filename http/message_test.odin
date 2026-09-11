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
