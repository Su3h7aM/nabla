#+test
#+private file
package client

import "core:testing"

import "nabla:http"

// Slice_Source feeds a response from memory, so the parsing path can be tested
// without a socket.
Slice_Source :: struct {
	bytes:     []u8,
	at:        int,
	// chunk bounds one read, so a test can force a response to arrive in pieces.
	chunk:     int,
	// truncated reports the end of the stream as an error rather than a clean
	// close, which is what a lost connection or an incomplete TLS close looks like.
	truncated: bool,
}

slice_read :: proc(user_data: rawptr, buffer: []u8) -> (count: int, err: Error) {
	source := (^Slice_Source)(user_data)
	if source.at >= len(source.bytes) {
		if source.truncated {
			return 0, .Truncated
		}
		return 0, .Closed
	}

	count = min(len(buffer), len(source.bytes) - source.at)
	if source.chunk > 0 {
		count = min(count, source.chunk)
	}
	copy(buffer[:count], source.bytes[source.at:])
	source.at += count
	return count, .None
}

// _reader builds a reader over a response, delivered no more than `chunk` octets
// at a time so that a chunk boundary cannot hide a parsing bug.
_reader :: proc(response: string, chunk := 0, truncated := false) -> Reader {
	source := new(Slice_Source, context.temp_allocator)
	source.bytes = transmute([]u8)response
	source.chunk = chunk
	source.truncated = truncated

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
test_response_head :: proc(t: ^testing.T) {
	reader := _reader("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nX-A: 1\r\nx-a: 2\r\n\r\nabc")
	status, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, status, 200)

	// RFC 9112 5: field names are case-insensitive.
	length, found := http.headers_get_unsafe(headers, "content-length")
	testing.expect(t, found)
	testing.expect_value(t, length, "3")

	// RFC 9110 5.3: field lines with the same name combine in order, comma SP.
	merged, merged_found := http.headers_get_unsafe(headers, "x-a")
	testing.expect(t, merged_found)
	testing.expect_value(t, merged, "1, 2")

	// A head arriving one octet at a time parses the same way.
	split := _reader("HTTP/1.1 204 No Content\r\nserver: x\r\n\r\n", 1)
	split_status, split_headers, split_err := read_response_head(&split, context.temp_allocator)
	defer headers_destroy(&split_headers, context.temp_allocator)
	testing.expect_value(t, split_err, Error.None)
	testing.expect_value(t, split_status, 204)
}

@(test)
test_chunked_body :: proc(t: ^testing.T) {
	// RFC 9112 7.1: chunks are hex-sized, CRLF-terminated, and the body ends with
	// a zero-sized chunk.
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

	// RFC 9112 7.1.1: unrecognized chunk extensions are ignored.
	extended := _reader("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5;a=b;c\r\nhello\r\n0\r\n\r\n", 1)
	ext_status, ext_headers, ext_err := read_response_head(&extended, context.temp_allocator)
	defer headers_destroy(&ext_headers, context.temp_allocator)
	testing.expect_value(t, ext_err, Error.None)
	ext_framing, ext_length, ext_framing_err := response_framing(ext_status, .Post, ext_headers)
	testing.expect_value(t, ext_framing_err, Error.None)
	ext_collector: Collector
	defer delete(ext_collector.buffer)
	testing.expect_value(t, stream_body(&extended, ext_framing, ext_length, &ext_collector, collect), Error.None)
	testing.expect_value(t, string(ext_collector.buffer[:]), "hello")
}

@(test)
test_content_length_and_bodyless_bodies :: proc(t: ^testing.T) {
	// The reader is handed more than the body, so reading only the declared
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

	// A 204 is terminated by the empty line, so the following response on the
	// same connection is readable immediately.
	bodyless := _reader("HTTP/1.1 204 No Content\r\n\r\nHTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi")
	bodyless_status, bodyless_headers, bodyless_err := read_response_head(&bodyless, context.temp_allocator)
	defer headers_destroy(&bodyless_headers, context.temp_allocator)
	testing.expect_value(t, bodyless_err, Error.None)
	bodyless_framing, bodyless_length, bodyless_framing_err := response_framing(bodyless_status, .Post, bodyless_headers)
	testing.expect_value(t, bodyless_framing_err, Error.None)
	testing.expect_value(t, bodyless_framing, Body_Framing.None)
	bodyless_collector: Collector
	defer delete(bodyless_collector.buffer)
	testing.expect_value(t, stream_body(&bodyless, bodyless_framing, bodyless_length, &bodyless_collector, collect), Error.None)
	testing.expect_value(t, len(bodyless_collector.buffer), 0)

	next_status, next_headers, next_err := read_response_head(&bodyless, context.temp_allocator)
	defer headers_destroy(&next_headers, context.temp_allocator)
	testing.expect_value(t, next_err, Error.None)
	testing.expect_value(t, next_status, 200)
}

@(test)
test_interim_responses :: proc(t: ^testing.T) {
	// RFC 9112 9.2: interim responses are read and discarded rather than answered.
	wire := "HTTP/1.1 100 Continue\r\n\r\n" + "HTTP/1.1 103 Early Hints\r\nlink: </s.css>\r\n\r\n" + "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi"
	reader := _reader(wire, 1)
	status, headers, err := read_final_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, status, 200)
	framing, length, framing_err := response_framing(status, .Post, headers)
	testing.expect_value(t, framing_err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Exact)
	testing.expect_value(t, length, 2)
	collector: Collector
	defer delete(collector.buffer)
	testing.expect_value(t, stream_body(&reader, framing, length, &collector, collect), Error.None)
	testing.expect_value(t, string(collector.buffer[:]), "hi")

	// A 101 ends the exchange instead of preceding a final response, and this
	// client never asks to upgrade.
	switched := _reader("HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\n\r\n", 1)
	switch_status, switch_headers, switch_err := read_final_response_head(&switched, context.temp_allocator)
	defer headers_destroy(&switch_headers, context.temp_allocator)
	testing.expect_value(t, switch_err, Error.None)
	testing.expect_value(t, switch_status, 101)

	// A peer that only ever sends interim responses must not keep the request
	// running forever.
	interim := "HTTP/1.1 100 Continue\r\n\r\n"
	bounded: [dynamic]u8
	defer delete(bounded)
	for _ in 0 ..< HTTP_MAX_INTERIM_RESPONSES + 1 {
		append(&bounded, ..transmute([]u8)interim)
	}
	source := new(Slice_Source, context.temp_allocator)
	source.bytes = bounded[:]
	loop_reader: Reader
	reader_init(&loop_reader, slice_read, source, context.temp_allocator)
	_, loop_headers, loop_err := read_final_response_head(&loop_reader, context.temp_allocator)
	defer headers_destroy(&loop_headers, context.temp_allocator)
	testing.expect_value(t, loop_err, Error.Bad_Response)
}

@(test)
test_folded_fields :: proc(t: ^testing.T) {
	// RFC 9112 5.2: an obs-fold becomes one or more SP octets.
	reader := _reader("HTTP/1.1 200 OK\r\nx-a: one\r\n  two\r\n\tthree\r\ncontent-length: 0\r\n\r\n")
	status, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, status, 200)
	value, found := http.headers_get_unsafe(headers, "x-a")
	testing.expect(t, found)
	testing.expect_value(t, value, "one two three")
	_, length_found := http.headers_get_unsafe(headers, "content-length")
	testing.expect(t, length_found)

	// A fold split across reads joins the same way.
	split := _reader("HTTP/1.1 200 OK\r\nx-a: one\r\n   two\r\n\r\n", 1)
	_, split_headers, split_err := read_response_head(&split, context.temp_allocator)
	defer headers_destroy(&split_headers, context.temp_allocator)
	testing.expect_value(t, split_err, Error.None)
	split_value, split_found := http.headers_get_unsafe(split_headers, "x-a")
	testing.expect(t, split_found)
	testing.expect_value(t, split_value, "one two")

	// A whitespace-only continuation adds nothing.
	blank := _reader("HTTP/1.1 200 OK\r\nx-a: one\r\n \t \r\n\r\n", 1)
	_, blank_headers, blank_err := read_response_head(&blank, context.temp_allocator)
	defer headers_destroy(&blank_headers, context.temp_allocator)
	testing.expect_value(t, blank_err, Error.None)
	blank_value, _ := http.headers_get_unsafe(blank_headers, "x-a")
	testing.expect_value(t, blank_value, "one")

	// A line beginning with whitespace cannot begin a field section.
	stray := _reader("HTTP/1.1 200 OK\r\n  stray\r\n\r\n", 1)
	_, stray_headers, stray_err := read_response_head(&stray, context.temp_allocator)
	defer headers_destroy(&stray_headers, context.temp_allocator)
	testing.expect_value(t, stray_err, Error.Bad_Response)
}

@(test)
test_incomplete_bodies :: proc(t: ^testing.T) {
	// A chunked body without its terminating zero-sized chunk is incomplete.
	no_last := _reader("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhello\r\n", 1)
	status, headers, err := read_response_head(&no_last, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	framing, length, framing_err := response_framing(status, .Post, headers)
	testing.expect_value(t, framing_err, Error.None)
	collector: Collector
	defer delete(collector.buffer)
	testing.expect(t, stream_body(&no_last, framing, length, &collector, collect) != Error.None)

	// A body that stops after the last chunk but before the trailer terminator is
	// short too.
	no_trailer := _reader("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n", 1)
	no_trailer_status, no_trailer_headers, no_trailer_err := read_response_head(&no_trailer, context.temp_allocator)
	defer headers_destroy(&no_trailer_headers, context.temp_allocator)
	testing.expect_value(t, no_trailer_err, Error.None)
	no_trailer_framing, no_trailer_length, no_trailer_framing_err := response_framing(no_trailer_status, .Post, no_trailer_headers)
	testing.expect_value(t, no_trailer_framing_err, Error.None)
	no_trailer_collector: Collector
	defer delete(no_trailer_collector.buffer)
	testing.expect(t, stream_body(&no_trailer, no_trailer_framing, no_trailer_length, &no_trailer_collector, collect) != Error.None)

	// A body shorter than its Content-Length is incomplete; the peer closing is
	// what ends it.
	truncated := _reader("HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nabc")
	truncated_status, truncated_headers, truncated_err := read_response_head(&truncated, context.temp_allocator)
	defer headers_destroy(&truncated_headers, context.temp_allocator)
	testing.expect_value(t, truncated_err, Error.None)
	truncated_framing, truncated_length, truncated_framing_err := response_framing(truncated_status, .Post, truncated_headers)
	testing.expect_value(t, truncated_framing_err, Error.None)
	truncated_collector: Collector
	defer delete(truncated_collector.buffer)
	testing.expect_value(t, stream_body(&truncated, truncated_framing, truncated_length, &truncated_collector, collect), Error.Closed)
}

@(test)
test_close_delimited_bodies :: proc(t: ^testing.T) {
	// Without a framing field the body ends at a clean close.
	reader := _reader("HTTP/1.1 200 OK\r\n\r\nbody", 1)
	status, headers, err := read_response_head(&reader, context.temp_allocator)
	defer headers_destroy(&headers, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	framing, length, framing_err := response_framing(status, .Post, headers)
	testing.expect_value(t, framing_err, Error.None)
	testing.expect_value(t, framing, Body_Framing.Until_Close)
	collector: Collector
	defer delete(collector.buffer)
	testing.expect_value(t, stream_body(&reader, framing, length, &collector, collect), Error.None)
	testing.expect_value(t, string(collector.buffer[:]), "body")

	// RFC 9112 9.8: a response closed without a clean signal is incomplete, the
	// shape of an incomplete TLS close.
	truncated := _reader("HTTP/1.1 200 OK\r\n\r\nbody", 1, truncated = true)
	truncated_status, truncated_headers, truncated_err := read_response_head(&truncated, context.temp_allocator)
	defer headers_destroy(&truncated_headers, context.temp_allocator)
	testing.expect_value(t, truncated_err, Error.None)
	truncated_framing, truncated_length, truncated_framing_err := response_framing(truncated_status, .Post, truncated_headers)
	testing.expect_value(t, truncated_framing_err, Error.None)
	truncated_collector: Collector
	defer delete(truncated_collector.buffer)
	testing.expect_value(t, stream_body(&truncated, truncated_framing, truncated_length, &truncated_collector, collect), Error.Truncated)
}
