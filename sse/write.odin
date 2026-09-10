package sse

import "core:fmt"
import "core:strings"

// Write_Error reports why an event could not be written.
Write_Error :: enum {
	None,
	// A field value contained a character that would end the field's line early
	// and change how the stream is parsed: CR in any value, or LF in anything
	// but data.
	Invalid_Value,
}

// write_event appends one complete event to buffer: its fields, then the blank
// line that dispatches it. Events accumulate, so a caller can build a batch and
// write it once.
//
// data is written as one data field per line, which is how the format carries
// multi-line data; an empty data string still writes one data field, so the
// event carries the empty string rather than nothing. type is written only when
// it is not the format's default, "message". id and retry are written only when
// present, and an id that is present but empty writes a bare "id:" -- which is
// how the format resets the reader's last event ID.
//
// Writes are all-or-nothing: on .Invalid_Value nothing is appended.
write_event :: proc(buffer: ^[dynamic]u8, data: string, event_type := "", id: Maybe(string) = nil, retry_ms: Maybe(i64) = nil) -> Write_Error {
	// Validate before appending, so a rejected event leaves buffer untouched.
	if strings.contains_rune(event_type, '\r') || strings.contains_rune(event_type, '\n') {
		return .Invalid_Value
	}
	if strings.contains_rune(data, '\r') { return .Invalid_Value }
	if id_value, has_id := id.?; has_id {
		if strings.contains_rune(id_value, '\r') || strings.contains_rune(id_value, '\n') {
			return .Invalid_Value
		}
	}

	if retry_value, has_retry := retry_ms.?; has_retry {
		scratch: [32]u8
		line := fmt.bprintf(scratch[:], "retry: %d\n", retry_value)
		append(buffer, ..transmute([]u8)line)
	}
	if id_value, has_id := id.?; has_id {
		append_field(buffer, "id", id_value)
	}
	if event_type != "" && event_type != DEFAULT_EVENT_TYPE {
		append_field(buffer, "event", event_type)
	}

	line_start := 0
	for i in 0 ..= len(data) {
		if i == len(data) || data[i] == '\n' {
			append_field(buffer, "data", data[line_start:i])
			line_start = i + 1
		}
	}
	append(buffer, '\n')
	return .None
}

// append_field writes one "name: value" line. One space after the colon is
// syntax, not data -- the reader removes exactly one -- so a value that begins
// with a space keeps it, and an empty value is written without the space to
// leave no trailing whitespace on the line.
@(private)
append_field :: proc(buffer: ^[dynamic]u8, name, value: string) {
	append(buffer, ..transmute([]u8)name)
	append(buffer, ':')
	if len(value) > 0 {
		append(buffer, ' ')
		append(buffer, ..transmute([]u8)value)
	}
	append(buffer, '\n')
}
