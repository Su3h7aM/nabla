// Package sse is Server-Sent Events framing: parsing an
// application/event-stream byte stream into events, writing events back out in
// the same format, and the POST that asks for a stream.
//
// The behaviour follows the WHATWG HTML Standard, "Server-sent events" -- the
// event stream format and its interpretation algorithm. Where this package makes
// a choice the specification leaves open (memory bounds, and how a bounded
// parser reports them) the choice is documented on the declaration that makes
// it.
//
// The parser is a pure state machine over bytes: no I/O, no connection, no
// retained stream. The caller owns the byte source and the event callbacks.
package sse

import "core:unicode/utf8"

MAX_LINE_BYTES :: 64 * 1024
MAX_EVENT_BYTES :: 1024 * 1024
MAX_RETRY_MS :: 24 * 60 * 60 * 1000

// One worst-case line must always fit the event budget it accumulates into.
#assert(MAX_LINE_BYTES < MAX_EVENT_BYTES)

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

// Error reports why a stream stopped being parseable.
//
// The specification defines no memory bound, so the two limits here are this
// package's policy. Both are fatal rather than skipped: a line that cannot be
// stored cannot be interpreted, silently dropping it would misparse the stream,
// and the error is sticky so the caller cannot accidentally continue past it.
Error :: enum {
	None,
	// A single line exceeded MAX_LINE_BYTES.
	Line_Too_Long,
	// The accumulated data buffer exceeded MAX_EVENT_BYTES.
	Event_Too_Large,
}

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
	line_len:      int,
	event_bytes:   int,
	pending_cr:    bool,
	finished:      bool,
	error:         Error,
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

// parser_error reports the parser's sticky error, which is .None until one is
// raised.
parser_error :: proc(parser: ^Parser) -> Error {
	return parser.error
}

// parser_feed consumes the next chunk of the stream and dispatches any events it
// completes. A chunk may split anywhere -- mid-line, between CR and LF, or inside
// the leading BOM -- because the parser carries that state between calls.
//
// Once an error is raised it is sticky: this and every later call returns it, and
// no further events are dispatched.
parser_feed :: proc(parser: ^Parser, bytes: []u8) -> Error {
	if parser.finished || parser.error != .None { return parser.error }
	for byte in bytes {
		if parser.bom_len < 3 {
			parser.bom[parser.bom_len] = byte
			parser.bom_len += 1
			if parser.bom_len < 3 { continue }
			if parser.bom == {0xEF, 0xBB, 0xBF} { continue }
			for prefix_byte in parser.bom[:] {
				if parser_byte(parser, prefix_byte) != .None { return parser.error }
			}
			continue
		}
		if parser_byte(parser, byte) != .None { return parser.error }
	}
	return .None
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
// Calling it twice is harmless; the second call reports the same result.
parser_finish :: proc(parser: ^Parser) -> Error {
	if parser.finished { return parser.error }
	if parser.bom_len > 0 && parser.bom_len < 3 {
		saved_bom_len := parser.bom_len
		parser.bom_len = 3
		for i in 0 ..< saved_bom_len {
			if parser_byte(parser, parser.bom[i]) != .None { return parser.error }
		}
	}
	if parser.pending_cr {
		parser.pending_cr = false
		if parser_line(parser) != .None { return parser.error }
	}
	// EOF never dispatches an event without a terminating blank line.
	parser.finished = true
	return parser.error
}

@(private)
parser_byte :: proc(parser: ^Parser, byte: u8) -> Error {
	if parser.pending_cr {
		parser.pending_cr = false
		if byte == '\n' { return parser_line(parser) }
		if parser_line(parser) != .None { return parser.error }
	}
	if byte == '\r' {
		parser.pending_cr = true
		return .None
	}
	if byte == '\n' { return parser_line(parser) }
	if parser.line_len >= MAX_LINE_BYTES {
		parser.error = .Line_Too_Long
		return parser.error
	}
	append(&parser.line, byte)
	parser.line_len += 1
	return .None
}

@(private)
parser_line :: proc(parser: ^Parser) -> Error {
	line := parser.line[:parser.line_len]
	if len(line) == 0 {
		if parser_dispatch(parser) != .None { return parser.error }
	} else {
		parser_field(parser, line)
		if parser.error != .None { return parser.error }
	}
	clear(&parser.line)
	parser.line_len = 0
	return .None
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
		// join with "\n" when the event is dispatched. The budget is charged
		// after appending, because a decode can expand the value: the
		// overshoot is bounded by one line's expansion, and the parser is dead
		// once the error is raised.
		parser.event_bytes += append_decoded_utf8(&parser.event_data, value) + 1
		append(&parser.event_data, '\n')
		if parser.event_bytes > MAX_EVENT_BYTES {
			parser.error = .Event_Too_Large
			return
		}
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

// append_decoded_utf8 appends value to dst as UTF-8 text and returns the number
// of bytes appended.
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
append_decoded_utf8 :: proc(dst: ^[dynamic]u8, value: []u8) -> int {
	appended := 0
	for i := 0; i < len(value); {
		r, size := utf8.decode_rune_in_bytes(value[i:])
		// A well-formed sequence decodes with its own length, including a
		// literal U+FFFD. An ill-formed byte or a truncated sequence reports
		// RUNE_ERROR with a length of one.
		if r == utf8.RUNE_ERROR && size <= 1 {
			appended += append_replacement_character(dst)
			i += 1
			continue
		}
		width := max(size, 1)
		append(dst, ..value[i:i + width])
		appended += width
		i += width
	}
	return appended
}

@(private)
append_replacement_character :: proc(dst: ^[dynamic]u8) -> int {
	// U+FFFD REPLACEMENT CHARACTER. Encoded by the standard library rather than
	// written out as bytes, which is how the wrong character gets in.
	bytes, size := utf8.encode_rune(utf8.RUNE_ERROR)
	append(dst, ..bytes[:size])
	return size
}

// parse_retry reads a reconnection time. The specification accepts a field value
// of ASCII digits and ignores anything else, so ok is false for a malformed or
// empty value. A digit string too large to represent is clamped to MAX_RETRY_MS
// rather than rejected: the bound is this package's memory policy, not a
// validity rule, and a caller is told the longest delay it will be asked to wait.
@(private)
parse_retry :: proc(value: []u8) -> (ms: i64, ok: bool) {
	if len(value) == 0 { return 0, false }
	result: i64
	for byte in value {
		if byte < '0' || byte > '9' { return 0, false }
		if result >= MAX_RETRY_MS / 10 { return MAX_RETRY_MS, true }
		result = result * 10 + i64(byte - '0')
	}
	return min(result, MAX_RETRY_MS), true
}

@(private)
parser_dispatch :: proc(parser: ^Parser) -> Error {
	// A blank line with an empty data buffer dispatches nothing. It still clears
	// the event type buffer, which the specification requires before returning.
	// The last event ID buffer is deliberately not cleared: it persists across
	// dispatches until the stream sets it again.
	if len(parser.event_data) == 0 {
		clear(&parser.event_type)
		parser.event_bytes = 0
		return .None
	}

	data := parser.event_data[:]
	// Every data field appended an LF; the final one is a separator, not part of
	// the event's data.
	if len(data) > 0 && data[len(data) - 1] == '\n' { data = data[:len(data) - 1] }

	event_type := "message"
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
	parser.event_bytes = 0
	return .None
}
