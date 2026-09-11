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
test_a_204_response_has_no_body :: proc(t: ^testing.T) {
	// RFC 9112 6.3 item 1: a 204 is always terminated by the empty line after the
	// field section, whatever fields are present.
	headers := _framing_headers(t, "content-length: 5")
	framing, _, err := response_framing(204, .Post, headers)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.None)
}

@(test)
test_a_304_response_has_no_body :: proc(t: ^testing.T) {
	headers := _framing_headers(t, "transfer-encoding: chunked")
	framing, _, err := response_framing(304, .Get, headers)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.None)
}

@(test)
test_an_informational_response_has_no_body :: proc(t: ^testing.T) {
	// RFC 9112 6.3 item 1. A 1xx precedes the final response rather than
	// replacing it.
	headers := _framing_headers(t)
	for status in ([]int{100, 101, 103}) {
		framing, _, err := response_framing(status, .Post, headers)
		testing.expect_value(t, err, Error.None)
		testing.expectf(t, framing == Body_Framing.None, "%d was framed as %v", status, framing)
	}
}

@(test)
test_a_head_response_has_no_body :: proc(t: ^testing.T) {
	headers := _framing_headers(t, "content-length: 5")
	framing, _, err := response_framing(200, .Head, headers)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.None)
}

@(test)
test_content_length_gives_the_length :: proc(t: ^testing.T) {
	headers := _framing_headers(t, "content-length: 12")
	framing, length, err := response_framing(200, .Post, headers)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Exact)
	testing.expect_value(t, length, 12)
}

@(test)
test_a_repeated_equal_content_length_is_one_value :: proc(t: ^testing.T) {
	// RFC 9112 6.3 item 5: a list is acceptable when every value is valid and
	// identical, and the message is then framed by that one value.
	headers := _framing_headers(t, "content-length: 7", "content-length: 7")
	framing, length, err := response_framing(200, .Post, headers)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Exact)
	testing.expect_value(t, length, 7)
}

@(test)
test_a_differing_content_length_is_rejected :: proc(t: ^testing.T) {
	// RFC 9112 6.3 item 5: differing values are an unrecoverable error, not a
	// reason to frame the message with whichever came first. The field parser
	// reports the second line as invalid, which the response head reader turns
	// into a failed request.
	headers: http.Headers
	http.headers_init(&headers, context.temp_allocator)
	_, first_ok := http.header_parse(&headers, "content-length: 5", context.temp_allocator)
	testing.expect(t, first_ok)
	_, second_ok := http.header_parse(&headers, "content-length: 6", context.temp_allocator)
	testing.expect(t, !second_ok)
}

@(test)
test_a_chunked_transfer_encoding_frames_the_body :: proc(t: ^testing.T) {
	// RFC 9112 6.3 item 3: Transfer-Encoding overrides Content-Length.
	headers := _framing_headers(t, "transfer-encoding: chunked", "content-length: 5")
	framing, _, err := response_framing(200, .Post, headers)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Chunked)
}

@(test)
test_a_final_coding_that_is_not_chunked_reads_to_close :: proc(t: ^testing.T) {
	// RFC 9112 6.3 item 4: it is the final coding that decides, so a body that is
	// chunked and then further coded is read until the connection closes.
	headers := _framing_headers(t, "transfer-encoding: chunked, gzip")
	framing, _, err := response_framing(200, .Post, headers)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Until_Close)
}

@(test)
test_coding_names_are_case_insensitive :: proc(t: ^testing.T) {
	// RFC 9112 7: transfer coding names are case-insensitive.
	for value in ([]string{"chunked", "Chunked", "CHUNKED", " gzip , ChUnKeD "}) {
		field := strings.concatenate({"transfer-encoding: ", value}, context.temp_allocator)
		headers := _framing_headers(t, field)
		framing, _, err := response_framing(200, .Post, headers)
		testing.expect_value(t, err, Error.None)
		testing.expectf(t, framing == Body_Framing.Chunked, "%q was framed as %v", value, framing)
	}
}

@(test)
test_a_response_without_a_framing_field_reads_to_close :: proc(t: ^testing.T) {
	// RFC 9112 6.3 item 8.
	headers := _framing_headers(t)
	framing, _, err := response_framing(200, .Post, headers)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Until_Close)
}

@(test)
test_an_invalid_content_length_is_rejected :: proc(t: ^testing.T) {
	for value in ([]string{"", "5x", "-5", "5 5", "99999999999999999999999999"}) {
		_, ok := content_length_parse(value)
		testing.expectf(t, !ok, "%q was accepted as a Content-Length", value)
	}

	length, ok := content_length_parse("  42  ")
	testing.expect(t, ok)
	testing.expect_value(t, length, 42)
}
