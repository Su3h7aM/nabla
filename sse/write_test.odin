package sse

import "core:strings"
import "core:testing"

// The writer's contract is the same format the parser reads, so the tests are
// mostly round trips: whatever write_event produces, parsing it must yield the
// event it was given. That is the strongest statement available without
// restating the wire format twice.

write_to_string :: proc(
	buffer: ^[dynamic]u8,
	data: string,
	event_type := "",
	id: Maybe(string) = nil,
	retry_ms: Maybe(i64) = nil,
) -> (
	wire: string,
	err: Write_Error,
) {
	clear(buffer)
	err = write_event(buffer, data, event_type, id, retry_ms)
	return string(buffer[:]), err
}

@(test)
test_write_read_round_trip :: proc(t: ^testing.T) {
	wire: [dynamic]u8
	defer delete(wire)

	// data is the only field written for a default event.
	text, err := write_to_string(&wire, "hello")
	testing.expect_value(t, err, Write_Error.None)
	testing.expect_value(t, text, "data: hello\n\n")

	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)
	testing.expect_value(t, parse(&recorder, text), Error.None)
	expect_events(t, &recorder, {{type = DEFAULT_EVENT_TYPE, data = "hello"}})
}

@(test)
test_write_read_round_trip_of_every_field :: proc(t: ^testing.T) {
	wire: [dynamic]u8
	defer delete(wire)

	text, err := write_to_string(&wire, "body", event_type = "add", id = "42", retry_ms = 1500)
	testing.expect_value(t, err, Write_Error.None)

	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)
	testing.expect_value(t, parse(&recorder, text), Error.None)
	expect_events(t, &recorder, {{type = "add", data = "body", id = "42", retry_ms = 1500, retry_present = true}})
}

@(test)
test_write_read_round_trip_of_multi_line_data :: proc(t: ^testing.T) {
	// One data field per line is the format's mechanism for multi-line data: the
	// reader joins them back with LF.
	wire: [dynamic]u8
	defer delete(wire)

	text, err := write_to_string(&wire, "one\ntwo\nthree")
	testing.expect_value(t, err, Write_Error.None)
	testing.expect_value(t, text, "data: one\ndata: two\ndata: three\n\n")

	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)
	testing.expect_value(t, parse(&recorder, text), Error.None)
	expect_events(t, &recorder, {{type = DEFAULT_EVENT_TYPE, data = "one\ntwo\nthree"}})
}

@(test)
test_write_read_round_trip_of_data_edge_cases :: proc(t: ^testing.T) {
	// Empty data, a trailing newline, and a leading space: each is a case where a
	// naive writer changes the event.
	data_cases := []string{"", "\n", "a\n", "\na", " leading", "  two leading"}
	for data in data_cases {
		wire: [dynamic]u8
		text, err := write_to_string(&wire, data)
		testing.expect_value(t, err, Write_Error.None)

		recorder: Recorder
		recorder_init(&recorder)
		testing.expect_value(t, parse(&recorder, text), Error.None)
		testing.expectf(t, len(recorder.events) == 1, "data %q: expected one event, got %d", data, len(recorder.events))
		if len(recorder.events) == 1 {
			testing.expectf(t, recorder.events[0].data == data, "data: expected %q, got %q (wire %q)", data, recorder.events[0].data, text)
		}
		recorder_destroy(&recorder)
		delete(wire)
	}
}

@(test)
test_empty_data_still_writes_a_data_field :: proc(t: ^testing.T) {
	// An event with no fields would carry nothing; the format's empty data field
	// is how the empty string travels.
	wire: [dynamic]u8
	defer delete(wire)

	text, err := write_to_string(&wire, "")
	testing.expect_value(t, err, Write_Error.None)
	testing.expect_value(t, text, "data:\n\n")
}

@(test)
test_the_default_event_type_is_not_written :: proc(t: ^testing.T) {
	// Writing "event: message" would be redundant: the reader defaults to it.
	wire: [dynamic]u8
	defer delete(wire)

	text, err := write_to_string(&wire, "x", event_type = DEFAULT_EVENT_TYPE)
	testing.expect_value(t, err, Write_Error.None)
	testing.expect_value(t, text, "data: x\n\n")
}

@(test)
test_an_empty_id_resets_the_readers_last_event_id :: proc(t: ^testing.T) {
	// Absent and present-but-empty are different facts: absent inherits the
	// previous ID, present-but-empty clears it. The Maybe carries that.
	// Separate buffers: write_to_string clears the buffer it is given, which
	// would invalidate a string view already returned from it.
	first: [dynamic]u8
	defer delete(first)
	second: [dynamic]u8
	defer delete(second)

	absent, err := write_to_string(&first, "a")
	testing.expect_value(t, err, Write_Error.None)
	present_empty, err2 := write_to_string(&second, "b", id = "")
	testing.expect_value(t, err2, Write_Error.None)

	testing.expect_value(t, absent, "data: a\n\n")
	testing.expect_value(t, present_empty, "id:\ndata: b\n\n")

	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)
	testing.expect_value(t, parse(&recorder, "id: keep\n\n", absent, present_empty), Error.None)
	expect_events(t, &recorder, {{type = DEFAULT_EVENT_TYPE, data = "a", id = "keep"}, {type = DEFAULT_EVENT_TYPE, data = "b", id = ""}})
}

@(test)
test_an_absent_retry_is_not_written :: proc(t: ^testing.T) {
	wire: [dynamic]u8
	defer delete(wire)

	text, err := write_to_string(&wire, "x")
	testing.expect_value(t, err, Write_Error.None)
	testing.expect(t, !strings.contains(text, "retry"))
}

@(test)
test_events_accumulate_in_one_buffer :: proc(t: ^testing.T) {
	wire: [dynamic]u8
	defer delete(wire)

	testing.expect_value(t, write_event(&wire, "one"), Write_Error.None)
	testing.expect_value(t, write_event(&wire, "two", event_type = "add"), Write_Error.None)
	testing.expect_value(t, write_event(&wire, "three"), Write_Error.None)

	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)
	testing.expect_value(t, parse(&recorder, string(wire[:])), Error.None)
	expect_events(t, &recorder, {{type = DEFAULT_EVENT_TYPE, data = "one"}, {type = "add", data = "two"}, {type = DEFAULT_EVENT_TYPE, data = "three"}})
}

@(test)
test_a_carriage_return_in_any_value_is_rejected :: proc(t: ^testing.T) {
	// CR would end the field's line early, so it can never be carried.
	wire: [dynamic]u8
	defer delete(wire)

	testing.expect_value(t, write_event(&wire, "a\rb"), Write_Error.Invalid_Value)
	testing.expect_value(t, write_event(&wire, "a", event_type = "x\ry"), Write_Error.Invalid_Value)
	testing.expect_value(t, write_event(&wire, "a", id = "x\ry"), Write_Error.Invalid_Value)
}

@(test)
test_a_line_feed_outside_data_is_rejected :: proc(t: ^testing.T) {
	// LF inside data is multi-line data; inside any other field it would start a
	// second, unintended field.
	wire: [dynamic]u8
	defer delete(wire)

	testing.expect_value(t, write_event(&wire, "a", event_type = "x\ny"), Write_Error.Invalid_Value)
	testing.expect_value(t, write_event(&wire, "a", id = "x\ny"), Write_Error.Invalid_Value)
	testing.expect_value(t, write_event(&wire, "a\nb"), Write_Error.None)
}

@(test)
test_a_rejected_event_leaves_the_buffer_untouched :: proc(t: ^testing.T) {
	// All-or-nothing: a caller that streams many events must not have to repair
	// the buffer after a rejected one.
	wire: [dynamic]u8
	defer delete(wire)

	testing.expect_value(t, write_event(&wire, "kept"), Write_Error.None)
	before := len(wire)
	testing.expect_value(t, write_event(&wire, "a", id = "bad\rid"), Write_Error.Invalid_Value)
	testing.expect_value(t, len(wire), before)
}
