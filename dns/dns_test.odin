#+test
#+private file
package dns

import "core:testing"

// The query every vector below answers: ID 0x1234, RD set, one A question
// for example.com.
TEST_QUERY :: "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + "\x07example\x03com\x00\x00\x01\x00\x01"

// A matching reply: same ID, QR set, the question echoed, one A answer.
TEST_REPLY ::
	"\x12\x34\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00" +
	"\x07example\x03com\x00\x00\x01\x00\x01" +
	"\xC0\x0C\x00\x01\x00\x01\x00\x00\x00\x3C\x00\x04\x5D\xB8\xD8\x22"

// wire views a text literal as bytes for a vector. The vectors are written
// as escapes for readability; the decoder reads bytes.
wire :: proc(s: string) -> []u8 { return transmute([]u8)s }

@(test)
test_message_truncated :: proc(t: ^testing.T) {
	// QR and TC set, no answers: the shape of a truncated reply.
	truncated := "\x12\x34\x82\x00\x00\x01\x00\x00\x00\x00\x00\x00" + "\x07example\x03com\x00\x00\x01\x00\x01"
	testing.expect(t, message_truncated(wire(truncated)), "a TC reply is truncated")

	testing.expect(t, !message_truncated(wire(TEST_REPLY)), "a complete reply is not truncated")
	testing.expect(t, !message_truncated(wire(TEST_QUERY)), "a query is not truncated")
	query := wire(TEST_QUERY)
	testing.expect(t, !message_truncated(query[:7]), "a short buffer is not truncated")
}

@(test)
test_response_matches :: proc(t: ^testing.T) {
	query := wire(TEST_QUERY)
	reply := wire(TEST_REPLY)
	testing.expect(t, response_matches(query, reply), "the reply answers the query")

	// A different ID is a different query's answer.
	other_id := wire("\x12\x35\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00" + "\x07example\x03com\x00\x00\x01\x00\x01")
	testing.expect(t, !response_matches(query, other_id), "a reply ID must match the query ID")

	// Without QR the message is not a response at all.
	no_qr := wire("\x12\x34\x01\x00\x00\x01\x00\x01\x00\x00\x00\x00" + "\x07example\x03com\x00\x00\x01\x00\x01")
	testing.expect(t, !response_matches(query, no_qr), "a message without QR is not a response")

	// A different question type is a different question.
	aaaa := wire("\x12\x34\x81\x80\x00\x01\x00\x00\x00\x00\x00\x00" + "\x07example\x03com\x00\x00\x1C\x00\x01")
	testing.expect(t, !response_matches(query, aaaa), "a reply question type must match the query")

	// Names match ASCII case-insensitively.
	upper := wire("\x12\x34\x81\x80\x00\x01\x00\x00\x00\x00\x00\x00" + "\x07EXAMPLE\x03COM\x00\x00\x01\x00\x01")
	testing.expect(t, response_matches(query, upper), "a reply name matches the query folded")

	// A different name is a different question.
	other_name := wire("\x12\x34\x81\x80\x00\x01\x00\x00\x00\x00\x00\x00" + "\x07example\x03org\x00\x00\x01\x00\x01")
	testing.expect(t, !response_matches(query, other_name), "a reply name must match the query")

	// A question that points at itself is a pointer loop, not a question.
	self_pointer := wire("\x12\x34\x81\x80\x00\x01\x00\x00\x00\x00\x00\x00" + "\xC0\x0C\x00\x01\x00\x01")
	testing.expect(t, !response_matches(query, self_pointer), "a pointer loop is not a question")

	// Short buffers match nothing.
	testing.expect(t, !response_matches(query, reply[:11]), "a short reply matches nothing")
	testing.expect(t, !response_matches(query[:11], reply), "a short query matches nothing")
	// A question cut off before its type and class is incomplete.
	cut := wire("\x12\x34\x81\x80\x00\x01\x00\x00\x00\x00\x00\x00" + "\x07example\x03com\x00")
	testing.expect(t, !response_matches(query, cut), "a cut-off question matches nothing")
}
