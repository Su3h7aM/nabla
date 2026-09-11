package client

import "core:testing"

import "nabla:http"

// Slice_Source feeds a response from memory, so the parsing path can be tested
// without a socket.
Slice_Source :: struct {
	bytes: []u8,
	at:    int,
	// chunk bounds one read, so a test can force a response to arrive in pieces.
	chunk: int,
}

slice_read :: proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error) {
	source := (^Slice_Source)(user_data)
	if source.at >= len(source.bytes) { return 0, .Closed }

	count = min(len(buffer), len(source.bytes) - source.at)
	if source.chunk > 0 { count = min(count, source.chunk) }
	copy(buffer[:count], source.bytes[source.at:])
	source.at += count
	return count, .None
}

// _reader builds a reader over a response, delivered no more than `chunk` octets
// at a time so that a chunk boundary cannot hide a parsing bug.
_reader :: proc(response: string, chunk := 0) -> Reader {
	source := new(Slice_Source, context.temp_allocator)
	source.bytes = transmute([]u8)response
	source.chunk = chunk

	reader: Reader
	reader_init(&reader, slice_read, source, context.temp_allocator)
	return reader
}

// Collector gathers the decoded body.
Collector :: struct {
	buffer: [dynamic]u8,
}

collect :: proc(user_data: rawptr, chunk: []u8) {
	collector := (^Collector)(user_data)
	append(&collector.buffer, ..chunk)
}

@(test)
test_response_head_is_parsed :: proc(t: ^testing.T) {
	reader := _reader("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nX-A: 1\r\nx-a: 2\r\n\r\nabc")

	status, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, status, 200)

	// RFC 9112 5: field names are case-insensitive.
	length, found := http.headers_get_unsafe(headers, "content-length")
	testing.expect(t, found)
	testing.expect_value(t, length, "3")

	// RFC 9110 5.3: field lines with the same name may be combined in order,
	// separated by comma SP.
	merged, merged_found := http.headers_get_unsafe(headers, "x-a")
	testing.expect(t, merged_found)
	testing.expect_value(t, merged, "1, 2")
}

@(test)
test_response_head_split_across_reads_is_parsed :: proc(t: ^testing.T) {
	// One octet per read: every field line and the head/body boundary land on a
	// read boundary at some point.
	reader := _reader("HTTP/1.1 204 No Content\r\nserver: x\r\n\r\n", 1)

	status, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, status, 204)
}

@(test)
test_chunked_body_is_decoded :: proc(t: ^testing.T) {
	// RFC 9112 7.1: chunks are sized in hex, each followed by CRLF, and the body
	// ends with a zero-sized chunk.
	reader := _reader("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", 1)

	status, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)

	framing, length, framing_err := response_framing(status, .Post, headers)
	testing.expect_value(t, framing_err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Chunked)

	collector: Collector
	defer delete(collector.buffer)
	testing.expect_value(t, stream_body(&reader, framing, length, &collector, collect), Error.None)
	testing.expect_value(t, string(collector.buffer[:]), "hello world")
}

@(test)
test_chunk_extensions_are_ignored :: proc(t: ^testing.T) {
	// RFC 9112 7.1.1: a recipient MUST ignore unrecognized chunk extensions.
	reader := _reader("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5;a=b;c\r\nhello\r\n0\r\n\r\n", 1)

	status, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)

	framing, length, framing_err := response_framing(status, .Post, headers)
	testing.expect_value(t, framing_err, Error.None)

	collector: Collector
	defer delete(collector.buffer)
	testing.expect_value(t, stream_body(&reader, framing, length, &collector, collect), Error.None)
	testing.expect_value(t, string(collector.buffer[:]), "hello")
}

@(test)
test_a_content_length_body_is_read_exactly :: proc(t: ^testing.T) {
	// The reader is handed more than the body so that reading only the declared
	// length is what proves the framing.
	reader := _reader("HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\nabcEXTRA")

	status, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)

	framing, length, framing_err := response_framing(status, .Post, headers)
	testing.expect_value(t, framing_err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Exact)
	testing.expect_value(t, length, 3)

	collector: Collector
	defer delete(collector.buffer)
	testing.expect_value(t, stream_body(&reader, framing, length, &collector, collect), Error.None)
	testing.expect_value(t, string(collector.buffer[:]), "abc")
}

@(test)
test_a_bodyless_response_consumes_nothing :: proc(t: ^testing.T) {
	// RFC 9112 6.3 item 1: a 204 is terminated by the empty line, so a following
	// response on the same connection must be readable immediately.
	reader := _reader("HTTP/1.1 204 No Content\r\n\r\nHTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi")

	status, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)

	framing, length, framing_err := response_framing(status, .Post, headers)
	testing.expect_value(t, framing_err, Error.None)
	testing.expect_value(t, framing, Body_Framing.None)

	collector: Collector
	defer delete(collector.buffer)
	testing.expect_value(t, stream_body(&reader, framing, length, &collector, collect), Error.None)
	testing.expect_value(t, len(collector.buffer), 0)

	next_status, next_headers, next_err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&next_headers, context.temp_allocator)
	testing.expect_value(t, next_err, Error.None)
	testing.expect_value(t, next_status, 200)
}

@(test)
test_interim_responses_precede_the_final_one :: proc(t: ^testing.T) {
	// RFC 9112 9.2: the association between a request and a response is only
	// complete on a final (non-1xx) response, so interim responses are read and
	// discarded rather than answered.
	wire := "HTTP/1.1 100 Continue\r\n\r\n" + "HTTP/1.1 103 Early Hints\r\nlink: </s.css>\r\n\r\n" + "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi"
	reader := _reader(wire, 1)

	status, headers, err := read_final_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, status, 200)

	// The interim heads were consumed exactly, so the body begins where it should.
	framing, length, framing_err := response_framing(status, .Post, headers)
	testing.expect_value(t, framing_err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Exact)
	testing.expect_value(t, length, 2)

	collector: Collector
	defer delete(collector.buffer)
	testing.expect_value(t, stream_body(&reader, framing, length, &collector, collect), Error.None)
	testing.expect_value(t, string(collector.buffer[:]), "hi")
}

@(test)
test_an_unexpected_protocol_switch_is_returned_as_final :: proc(t: ^testing.T) {
	// 101 ends the HTTP exchange instead of preceding a final response, and this
	// client never asks to upgrade, so it must not wait for a response that will
	// never come.
	reader := _reader("HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\n\r\n", 1)

	status, headers, err := read_final_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, status, 101)
}

@(test)
test_too_many_interim_responses_fail_the_request :: proc(t: ^testing.T) {
	// A peer that only ever sends interim responses must not be able to keep the
	// request running.
	interim := "HTTP/1.1 100 Continue\r\n\r\n"
	wire: [dynamic]u8
	defer delete(wire)
	for _ in 0 ..< HTTP_MAX_INTERIM_RESPONSES + 1 {
		append(&wire, ..transmute([]u8)interim)
	}

	source := new(Slice_Source, context.temp_allocator)
	source.bytes = wire[:]
	reader: Reader
	reader_init(&reader, slice_read, source, context.temp_allocator)

	_, headers, err := read_final_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.Bad_Response)
}

@(test)
test_a_folded_field_is_joined_with_sp :: proc(t: ^testing.T) {
	// RFC 9112 5.2: a user agent that receives an obs-fold in a response replaces it
	// with one or more SP octets before the field value is interpreted.
	reader := _reader("HTTP/1.1 200 OK\r\nx-a: one\r\n  two\r\n\tthree\r\ncontent-length: 0\r\n\r\n")

	status, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, status, 200)

	value, found := http.headers_get_unsafe(headers, "x-a")
	testing.expect(t, found)
	testing.expect_value(t, value, "one two three")

	// The field after the fold was read normally, so the fold ended where it should.
	_, length_found := http.headers_get_unsafe(headers, "content-length")
	testing.expect(t, length_found)
}

@(test)
test_a_folded_field_split_across_reads_is_joined :: proc(t: ^testing.T) {
	// One octet per read, so the CRLF and the continuation always land in different
	// reads.
	reader := _reader("HTTP/1.1 200 OK\r\nx-a: one\r\n   two\r\n\r\n", 1)

	_, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)

	value, found := http.headers_get_unsafe(headers, "x-a")
	testing.expect(t, found)
	testing.expect_value(t, value, "one two")
}

@(test)
test_a_whitespace_only_continuation_adds_nothing :: proc(t: ^testing.T) {
	// The fold becomes a SP, and trailing whitespace is excluded from a field value
	// when it is extracted, so a continuation carrying nothing adds nothing.
	reader := _reader("HTTP/1.1 200 OK\r\nx-a: one\r\n \t \r\n\r\n", 1)

	_, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)

	value, _ := http.headers_get_unsafe(headers, "x-a")
	testing.expect_value(t, value, "one")
}

@(test)
test_a_fold_that_continues_nothing_is_rejected :: proc(t: ^testing.T) {
	// RFC 9112 2.2: a line that begins with whitespace cannot be a field line, so
	// one arriving before any field cannot begin a field section.
	reader := _reader("HTTP/1.1 200 OK\r\n  stray\r\n\r\n", 1)

	_, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.Bad_Response)
}

@(test)
test_a_truncated_body_is_reported :: proc(t: ^testing.T) {
	// RFC 9112 8: a body shorter than its Content-Length is incomplete, and the
	// peer closing is what ends it.
	reader := _reader("HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nabc")

	status, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)

	framing, length, framing_err := response_framing(status, .Post, headers)
	testing.expect_value(t, framing_err, Error.None)

	collector: Collector
	defer delete(collector.buffer)
	testing.expect_value(t, stream_body(&reader, framing, length, &collector, collect), Error.Closed)
}
