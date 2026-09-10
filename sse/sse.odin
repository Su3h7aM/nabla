// Package sse is Server-Sent Events framing: a byte-stream parser that turns the
// text/event-stream wire format into events, and the POST that asks for one.
//
// It knows nothing about what the events mean. The parser is a pure state
// machine over bytes: no I/O, no connection, no retained stream. The caller owns
// the byte source and the event callbacks.
package sse

MAX_LINE_BYTES :: 64 * 1024
MAX_EVENT_BYTES :: 1024 * 1024
MAX_RETRY_MS :: 24 * 60 * 60 * 1000

// One worst-case line must always fit the event budget it accumulates into.
#assert(MAX_LINE_BYTES < MAX_EVENT_BYTES)

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

Error :: enum {
	None,
	Line_Too_Long,
	Event_Too_Large,
	Invalid_Retry,
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

parser_error :: proc(parser: ^Parser) -> Error {
	return parser.error
}

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
	if line[0] == ':' { return }
	colon := -1
	for byte, i in line {
		if byte == ':' { colon = i; break }
	}
	name := line if colon < 0 else line[:colon]
	value := []u8{} if colon < 0 else line[colon + 1:]
	if len(value) > 0 && value[0] == ' ' { value = value[1:] }

	switch string(name) {
	case "data":
		if parser.event_bytes + len(value) + 1 > MAX_EVENT_BYTES {
			parser.error = .Event_Too_Large
			return
		}
		for byte in value { append(&parser.event_data, byte) }
		append(&parser.event_data, '\n')
		parser.event_bytes += len(value) + 1
	case "event":
		clear(&parser.event_type)
		for byte in value { append(&parser.event_type, byte) }
	case "id":
		clear(&parser.event_id)
		for byte in value {
			if byte == 0 { return }
			append(&parser.event_id, byte)
		}
	case "retry":
		retry, ok := parse_retry(value)
		if !ok { parser.error = .Invalid_Retry; return }
		parser.retry_ms = retry
		parser.retry_present = true
	}
}

@(private)
parse_retry :: proc(value: []u8) -> (i64, bool) {
	if len(value) == 0 { return 0, false }
	result: i64
	for byte in value {
		if byte < '0' || byte > '9' { return 0, false }
		result = result * 10 + i64(byte - '0')
		if result > MAX_RETRY_MS { return 0, false }
	}
	return result, true
}

@(private)
parser_dispatch :: proc(parser: ^Parser) -> Error {
	if len(parser.event_data) == 0 {
		clear(&parser.event_type)
		parser.event_bytes = 0
		return .None
	}
	data := parser.event_data[:len(parser.event_data) - 1]
	event_type := "message"
	if len(parser.event_type) > 0 { event_type = string(parser.event_type[:]) }
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
	parser.retry_ms = 0
	parser.retry_present = false
	return .None
}
