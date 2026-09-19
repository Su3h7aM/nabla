// Package sse is Server-Sent Events framing: parsing an
// application/event-stream byte stream into events, writing events back out in
// the same format, and the POST that asks for a stream.
//
// The behaviour follows the WHATWG HTML Standard, "Server-sent events" -- the
// event stream format and its interpretation algorithm.
//
// The grammar sets no size bound on lines or events (`*any-char` repeats
// without limit), so the parser accumulates without one: a provider may send
// an event of any size and it still parses.
//
// The parser is a pure state machine over bytes: no I/O, no connection, no
// retained stream. The caller owns the byte source and the event callbacks.
package sse

import "core:unicode/utf8"

// CONTENT_TYPE is the media type of an event stream. It is the type a response
// must declare, and the type a caller asks for when it wants one.
CONTENT_TYPE :: "text/event-stream"

// DEFAULT_EVENT_TYPE is the type an event has when its block named none.
DEFAULT_EVENT_TYPE :: "message"

// Event is one dispatched event. The format's event type buffer defaults to
// "message"; id is the stream's last event ID, which persists across events;
// retry_ms is the reconnection time currently in force.
Event :: struct {
	type:          string,
	data:          string,
	id:            string,
	retry_ms:      i64,
	retry_present: bool,
}

// Event_Callback runs synchronously during parser_feed/parser_finish. Event
// strings borrow parser storage and are valid only until the callback returns;
// copy them if they must outlive the call.
Event_Callback :: #type proc(user_data: rawptr, event: Event)

Parser :: struct {
	line:          [dynamic]u8,
	event_type:    [dynamic]u8,
	event_data:    [dynamic]u8,
	event_id:      [dynamic]u8,
	retry_ms:      i64,
	retry_present: bool,
	callback:      Event_Callback,
	user_data:     rawptr,
	bom:           [3]u8,
	bom_len:       int,
	pending_cr:    bool,
	finished:      bool,
}

// parser_init prepares parser for one stream. callback may be nil. user_data is
// passed back to the callback unchanged. The parser borrows no input: bytes are
// consumed by parser_feed.
parser_init :: proc(parser: ^Parser, callback: Event_Callback, user_data: rawptr = nil, allocator := context.allocator) {
	parser^ = {}
	parser.line.allocator = allocator
	parser.event_type.allocator = allocator
	parser.event_data.allocator = allocator
	parser.event_id.allocator = allocator
	parser.callback = callback
	parser.user_data = user_data
}

parser_destroy :: proc(parser: ^Parser) {
	delete(parser.line)
	delete(parser.event_type)
	delete(parser.event_data)
	delete(parser.event_id)
	parser^ = {}
}

// parser_feed consumes the next chunk of the stream and dispatches any events it
// completes. A chunk may split anywhere -- mid-line, between CR and LF, or inside
// the leading BOM -- because the parser carries that state between calls. Feeding
// after the stream was finished is a no-op.
parser_feed :: proc(parser: ^Parser, bytes: []u8) {
	if parser.finished { return }
	for byte in bytes {
		if parser.bom_len < 3 {
			parser.bom[parser.bom_len] = byte
			parser.bom_len += 1
			if parser.bom_len < 3 { continue }
			if parser.bom == {0xEF, 0xBB, 0xBF} { continue }
			for prefix_byte in parser.bom[:] { parser_byte(parser, prefix_byte) }
			continue
		}
		parser_byte(parser, byte)
	}
}

// parser_finish ends the stream: a trailing CR is treated as a line terminator,
// and any pending data is discarded. An event is dispatched only by its
// terminating blank line, never by the end of the stream, so a stream cut off in
// the middle of an event yields no event for it.
//
// A line with no terminator at all is not a line: the format's grammar requires
// every field to end with CRLF, CR, or LF, so a truncated final line is left
// unprocessed and discarded with the pending data.
//
// Calling it twice is harmless.
parser_finish :: proc(parser: ^Parser) {
	if parser.finished { return }
	if parser.bom_len > 0 && parser.bom_len < 3 {
		saved_bom_len := parser.bom_len
		parser.bom_len = 3
		for i in 0 ..< saved_bom_len { parser_byte(parser, parser.bom[i]) }
	}
	if parser.pending_cr {
		parser.pending_cr = false
		parser_line(parser)
	}
	// EOF never dispatches an event without a terminating blank line.
	parser.finished = true
}

@(private)
parser_byte :: proc(parser: ^Parser, byte: u8) {
	if parser.pending_cr {
		parser.pending_cr = false
		if byte == '\n' { parser_line(parser); return }
		parser_line(parser)
	}
	if byte == '\r' {
		parser.pending_cr = true
		return
	}
	if byte == '\n' { parser_line(parser); return }
	append(&parser.line, byte)
}

@(private)
parser_line :: proc(parser: ^Parser) {
	line := parser.line[:]
	if len(line) == 0 {
		parser_dispatch(parser)
	} else {
		parser_field(parser, line)
	}
	clear(&parser.line)
}

@(private)
parser_field :: proc(parser: ^Parser, line: []u8) {
	// A line starting with a colon is a comment, ignored whole.
	if line[0] == ':' { return }

	colon := -1
	for byte, i in line {
		if byte == ':' { colon = i; break }
	}
	// A line with no colon carries the whole line as the field name and the
	// empty string as its value.
	name := line if colon < 0 else line[:colon]
	value := []u8{} if colon < 0 else line[colon + 1:]
	// Exactly one leading space belongs to the syntax, not to the value.
	if len(value) > 0 && value[0] == ' ' { value = value[1:] }

	// Field names are compared literally, with no case folding. Comparing the raw
	// bytes is the same test as comparing decoded text here: no ill-formed or
	// non-ASCII sequence can equal one of the four ASCII field names.
	switch string(name) {
	case "event":
		clear(&parser.event_type)
		append_decoded_utf8(&parser.event_type, value)
	case "data":
		// Appending the value and one LF is what makes several data fields
		// join with "\n" when the event is dispatched.
		append_decoded_utf8(&parser.event_data, value)
		append(&parser.event_data, '\n')
	case "id":
		// A value containing U+0000 NULL means the field is ignored and the
		// previous last event ID stands. The buffer is not cleared first: the
		// old value must survive a rejected update.
		if contains_null(value) { return }
		clear(&parser.event_id)
		append_decoded_utf8(&parser.event_id, value)
	case "retry":
		// A malformed value is ignored, not an error: the reconnection time
		// keeps whatever value it already had.
		if retry, ok := parse_retry(value); ok {
			parser.retry_ms = retry
			parser.retry_present = true
		}
	}
}

@(private)
contains_null :: proc(value: []u8) -> bool {
	for byte in value {
		if byte == 0 { return true }
	}
	return false
}

// append_decoded_utf8 appends value to dst as UTF-8 text.
//
// The standard decodes the stream with the UTF-8 decode algorithm, which
// replaces ill-formed input with U+FFFD. This is that step, applied per field
// value. A value is complete before it is stored -- line terminators cannot
// appear inside a UTF-8 sequence, so splitting on them first is safe -- which
// makes this equivalent to decoding the whole stream up front.
//
// One U+FFFD is emitted per ill-formed byte. The Encoding Standard's decoder
// emits one per maximal subpart of an ill-formed sequence, so a truncated
// sequence yields more replacement characters here than it would there. The
// difference is confined to how many U+FFFD characters malformed input
// produces: well-formed input is copied byte for byte either way.
@(private)
append_decoded_utf8 :: proc(dst: ^[dynamic]u8, value: []u8) {
	for i := 0; i < len(value); {
		r, size := utf8.decode_rune_in_bytes(value[i:])
		// A well-formed sequence decodes with its own length, including a
		// literal U+FFFD. An ill-formed byte or a truncated sequence reports
		// RUNE_ERROR with a length of one.
		if r == utf8.RUNE_ERROR && size <= 1 {
			append_replacement_character(dst)
			i += 1
			continue
		}
		width := max(size, 1)
		append(dst, ..value[i:i + width])
		i += width
	}
}

@(private)
append_replacement_character :: proc(dst: ^[dynamic]u8) {
	// U+FFFD REPLACEMENT CHARACTER. Encoded by the standard library rather than
	// written out as bytes, which is how the wrong character gets in.
	bytes, size := utf8.encode_rune(utf8.RUNE_ERROR)
	append(dst, ..bytes[:size])
}

// parse_retry reads a reconnection time. The specification accepts a field value
// of ASCII digits and ignores anything else, so ok is false for a malformed or
// empty value. A digit string wider than the representable time saturates there:
// the field is an integer of any length, and the only bound added here is the one
// the type itself has, not a policy about how long a client should wait. Every
// octet is checked before the result is used, so a digit run followed by anything
// else is malformed rather than a valid saturated time.
@(private)
parse_retry :: proc(value: []u8) -> (ms: i64, ok: bool) {
	if len(value) == 0 { return 0, false }
	result: i64
	saturated := false
	for byte in value {
		if byte < '0' || byte > '9' { return 0, false }
		if saturated { continue }
		digit := i64(byte - '0')
		if result > (max(i64) - digit) / 10 {
			saturated = true
			continue
		}
		result = result * 10 + digit
	}
	if saturated { return max(i64), true }
	return result, true
}

@(private)
parser_dispatch :: proc(parser: ^Parser) {
	// A blank line with an empty data buffer dispatches nothing. It still clears
	// the event type buffer, which the specification requires before returning.
	// The last event ID buffer is deliberately not cleared: it persists across
	// dispatches until the stream sets it again.
	if len(parser.event_data) == 0 {
		clear(&parser.event_type)
		return
	}

	data := parser.event_data[:]
	// Every data field appended an LF; the final one is a separator, not part of
	// the event's data.
	if len(data) > 0 && data[len(data) - 1] == '\n' { data = data[:len(data) - 1] }

	event_type := DEFAULT_EVENT_TYPE
	if len(parser.event_type) > 0 { event_type = string(parser.event_type[:]) }

	// retry_ms is not reset here. The reconnection time is stream state, not
	// event state: it holds its value until the stream changes it, so every
	// event reports the value currently in force.
	event := Event {
		type          = event_type,
		data          = string(data),
		id            = string(parser.event_id[:]),
		retry_ms      = parser.retry_ms,
		retry_present = parser.retry_present,
	}
	if parser.callback != nil { parser.callback(parser.user_data, event) }
	clear(&parser.event_type)
	clear(&parser.event_data)
}
