package sse

import "core:testing"

// The writer's contract is the same format the parser reads, so the tests are
// mostly round trips: whatever write_event produces, parsing it must yield the
// event it was given.

_write_to_string :: proc(
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
	text, err := _write_to_string(&wire, "hello")
	testing.expect_value(t, err, Write_Error.None)
	testing.expect_value(t, text, "data: hello\n\n")

	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)
	parse(&recorder, text)
	expect_events(t, &recorder, {{type = DEFAULT_EVENT_TYPE, data = "hello"}})

	// Every optional field round-trips.
	all, all_err := _write_to_string(&wire, "body", event_type = "add", id = "42", retry_ms = 1500)
	testing.expect_value(t, all_err, Write_Error.None)
	all_recorder: Recorder
	recorder_init(&all_recorder)
	defer recorder_destroy(&all_recorder)
	parse(&all_recorder, all)
	expect_events(t, &all_recorder, {{type = "add", data = "body", id = "42", retry_ms = 1500, retry_present = true}})
}

@(test)
test_write_read_round_trip_of_data_edge_cases :: proc(t: ^testing.T) {
	wire: [dynamic]u8
	defer delete(wire)

	// One data field per line carries multi-line data; the empty string travels
	// as an empty data field.
	multi, multi_err := _write_to_string(&wire, "one\ntwo\nthree")
	testing.expect_value(t, multi_err, Write_Error.None)
	testing.expect_value(t, multi, "data: one\ndata: two\ndata: three\n\n")
	multi_recorder: Recorder
	recorder_init(&multi_recorder)
	defer recorder_destroy(&multi_recorder)
	parse(&multi_recorder, multi)
	expect_events(t, &multi_recorder, {{type = DEFAULT_EVENT_TYPE, data = "one\ntwo\nthree"}})

	empty, empty_err := _write_to_string(&wire, "")
	testing.expect_value(t, empty_err, Write_Error.None)
	testing.expect_value(t, empty, "data:\n\n")

	// A leading space or a trailing newline must survive the round trip.
	for data in ([]string{"\n", "a\n", "\na", " leading", "  two leading"}) {
		text, err := _write_to_string(&wire, data)
		testing.expect_value(t, err, Write_Error.None)
		recorder: Recorder
		recorder_init(&recorder)
		parse(&recorder, text)
		testing.expectf(t, len(recorder.events) == 1, "data %q: expected one event, got %d", data, len(recorder.events))
		if len(recorder.events) == 1 {
			testing.expectf(t, recorder.events[0].data == data, "data: expected %q, got %q (wire %q)", data, recorder.events[0].data, text)
		}
		recorder_destroy(&recorder)
	}
}

@(test)
test_empty_id_resets_the_readers_last_event_id :: proc(t: ^testing.T) {
	// Absent and present-but-empty are different facts: absent inherits the
	// previous ID, present-but-empty clears it.
	first: [dynamic]u8
	defer delete(first)
	second: [dynamic]u8
	defer delete(second)

	absent, err := _write_to_string(&first, "a")
	testing.expect_value(t, err, Write_Error.None)
	present_empty, err2 := _write_to_string(&second, "b", id = "")
	testing.expect_value(t, err2, Write_Error.None)
	testing.expect_value(t, absent, "data: a\n\n")
	testing.expect_value(t, present_empty, "id:\ndata: b\n\n")

	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)
	parse(&recorder, "id: keep\n\n", absent, present_empty)
	expect_events(t, &recorder, {{type = DEFAULT_EVENT_TYPE, data = "a", id = "keep"}, {type = DEFAULT_EVENT_TYPE, data = "b", id = ""}})
}

@(test)
test_rejected_values_leave_the_buffer_untouched :: proc(t: ^testing.T) {
	// CR would end a field's line early; LF outside data would start an
	// unintended field. A rejected event is all-or-nothing.
	wire: [dynamic]u8
	defer delete(wire)

	testing.expect_value(t, write_event(&wire, "kept"), Write_Error.None)
	before := len(wire)

	testing.expect_value(t, write_event(&wire, "a\rb"), Write_Error.Invalid_Value)
	testing.expect_value(t, write_event(&wire, "a", event_type = "x\ry"), Write_Error.Invalid_Value)
	testing.expect_value(t, write_event(&wire, "a", id = "x\ry"), Write_Error.Invalid_Value)
	testing.expect_value(t, write_event(&wire, "a", event_type = "x\ny"), Write_Error.Invalid_Value)
	testing.expect_value(t, write_event(&wire, "a", id = "x\ny"), Write_Error.Invalid_Value)
	testing.expect_value(t, len(wire), before)

	// LF inside data is multi-line data, which is allowed.
	testing.expect_value(t, write_event(&wire, "a\nb"), Write_Error.None)
}
