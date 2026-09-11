#+test
#+private file
package client

import "core:strings"
import "core:testing"

import "nabla:http"

// _framing_headers parses field lines that the response head parser accepts.
_framing_headers :: proc(t: ^testing.T, fields: ..string) -> http.Headers {
	headers: http.Headers
	http.headers_init(&headers, context.temp_allocator)
	for field in fields {
		_, ok := http.header_parse(&headers, field, context.temp_allocator)
		testing.expectf(t, ok, "%q was rejected", field)
	}
	return headers
}

@(test)
test_bodyless_responses :: proc(t: ^testing.T) {
	// RFC 9112 6.3 item 1: 204, 304, 1xx, and HEAD responses are terminated by
	// the empty line after the field section, whatever fields are present.
	no_content := _framing_headers(t, "content-length: 5")
	framing, _, err := response_framing(204, .Post, no_content)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.None)

	not_modified := _framing_headers(t, "transfer-encoding: chunked")
	framing, _, err = response_framing(304, .Get, not_modified)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.None)

	informational := _framing_headers(t)
	for status in ([]int{100, 101, 103}) {
		framing, _, err = response_framing(status, .Post, informational)
		testing.expect_value(t, err, Error.None)
		testing.expectf(t, framing == Body_Framing.None, "%d was framed as %v", status, framing)
	}

	head := _framing_headers(t, "content-length: 5")
	framing, _, err = response_framing(200, .Head, head)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.None)
}

@(test)
test_content_length_framing :: proc(t: ^testing.T) {
	headers := _framing_headers(t, "content-length: 12")
	framing, length, err := response_framing(200, .Post, headers)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Exact)
	testing.expect_value(t, length, 12)

	// RFC 9112 6.3 item 5: a repeated, identical list is one value.
	repeated := _framing_headers(t, "content-length: 7", "content-length: 7")
	framing, length, err = response_framing(200, .Post, repeated)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Exact)
	testing.expect_value(t, length, 7)

	// Differing values are an unrecoverable error, reported by the field parser.
	differing: http.Headers
	http.headers_init(&differing, context.temp_allocator)
	_, first_ok := http.header_parse(&differing, "content-length: 5", context.temp_allocator)
	testing.expect(t, first_ok)
	_, second_ok := http.header_parse(&differing, "content-length: 6", context.temp_allocator)
	testing.expect(t, !second_ok)

	// An invalid value is rejected; surrounding whitespace is not part of it.
	for value in ([]string{"", "5x", "-5", "5 5", "99999999999999999999999999"}) {
		_, ok := content_length_parse(value)
		testing.expectf(t, !ok, "%q was accepted as a Content-Length", value)
	}
	parsed, parsed_ok := content_length_parse("  42  ")
	testing.expect(t, parsed_ok)
	testing.expect_value(t, parsed, 42)
}

@(test)
test_transfer_encoding_framing :: proc(t: ^testing.T) {
	// RFC 9112 6.3 item 3: Transfer-Encoding overrides Content-Length.
	headers := _framing_headers(t, "transfer-encoding: chunked", "content-length: 5")
	framing, _, err := response_framing(200, .Post, headers)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Chunked)

	// RFC 9112 6.3 item 4: the final coding decides, so chunked-then-further-
	// coded reads until close.
	trailing := _framing_headers(t, "transfer-encoding: chunked, gzip")
	framing, _, err = response_framing(200, .Post, trailing)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Until_Close)

	// RFC 9112 7: transfer coding names are case-insensitive.
	for value in ([]string{"chunked", "Chunked", "CHUNKED", " gzip , ChUnKeD "}) {
		field := strings.concatenate({"transfer-encoding: ", value}, context.temp_allocator)
		cased := _framing_headers(t, field)
		framing, _, err = response_framing(200, .Post, cased)
		testing.expect_value(t, err, Error.None)
		testing.expectf(t, framing == Body_Framing.Chunked, "%q was framed as %v", value, framing)
	}

	// RFC 9112 6.3 item 8: with no framing field the body reads until close.
	none := _framing_headers(t)
	framing, _, err = response_framing(200, .Post, none)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Until_Close)
}
