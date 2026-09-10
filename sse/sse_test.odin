package sse

import "core:mem"
import "core:strings"
import "core:testing"

// The parser's contract is the WHATWG HTML Standard's event stream
// interpretation algorithm. Each test below names the rule it locks, and the
// examples marked "standard example" are the standard's own worked examples.

Recorded_Event :: struct {
	type:          string,
	data:          string,
	id:            string,
	retry_ms:      i64,
	retry_present: bool,
}

Recorder :: struct {
	events:    [dynamic]Recorded_Event,
	allocator: mem.Allocator,
}

recorder_init :: proc(recorder: ^Recorder, allocator := context.allocator) {
	recorder.events = make([dynamic]Recorded_Event, 0, allocator)
	recorder.allocator = allocator
}

recorder_destroy :: proc(recorder: ^Recorder) {
	for &event in recorder.events {
		delete(event.type)
		delete(event.data)
		delete(event.id)
	}
	delete(recorder.events)
	recorder^ = {}
}

record_event :: proc(user_data: rawptr, event: Event) {
	recorder := cast(^Recorder)user_data
	append(
		&recorder.events,
		Recorded_Event {
			type = strings.clone(event.type, recorder.allocator),
			data = strings.clone(event.data, recorder.allocator),
			id = strings.clone(event.id, recorder.allocator),
			retry_ms = event.retry_ms,
			retry_present = event.retry_present,
		},
	)
}

// parse feeds every chunk in order and then finishes the stream, which is what a
// real reader does when the connection ends.
parse :: proc(recorder: ^Recorder, chunks: ..string) -> Error {
	parser: Parser
	parser_init(&parser, record_event, recorder, allocator = recorder.allocator)
	defer parser_destroy(&parser)
	for chunk in chunks {
		// A chunk is bytes on the wire; a string literal is the most readable way
		// to write one in a test.
		if err := parser_feed(&parser, transmute([]u8)chunk); err != .None { return err }
	}
	return parser_finish(&parser)
}

expect_events :: proc(t: ^testing.T, recorder: ^Recorder, expected: []Recorded_Event, loc := #caller_location) {
	testing.expectf(t, len(recorder.events) == len(expected), "%v: expected %d event(s), got %d", loc, len(expected), len(recorder.events))
	for got, i in recorder.events {
		if i >= len(expected) { break }
		want := expected[i]
		testing.expectf(t, got.type == want.type, "%v: event %d type: expected %q, got %q", loc, i, want.type, got.type)
		testing.expectf(t, got.data == want.data, "%v: event %d data: expected %q, got %q", loc, i, want.data, got.data)
		testing.expectf(t, got.id == want.id, "%v: event %d id: expected %q, got %q", loc, i, want.id, got.id)
		testing.expectf(
			t,
			got.retry_present == want.retry_present,
			"%v: event %d retry_present: expected %v, got %v",
			loc,
			i,
			want.retry_present,
			got.retry_present,
		)
		testing.expectf(t, got.retry_ms == want.retry_ms, "%v: event %d retry_ms: expected %d, got %d", loc, i, want.retry_ms, got.retry_ms)
	}
}

@(test)
test_multi_line_data_joins_with_lf :: proc(t: ^testing.T) {
	// Standard example: three data fields become one event whose data is the
	// three lines joined by LF.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: YHOO\ndata: +2\ndata: 10\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = "YHOO\n+2\n10"}})
}

@(test)
test_space_after_colon_is_ignored :: proc(t: ^testing.T) {
	// Standard example: "data: test" and "data:test" produce identical events,
	// because one space after the colon is syntax rather than data.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: test\n\ndata:test\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = "test"}, {type = "message", data = "test"}})
}

@(test)
test_only_one_space_after_colon_is_removed :: proc(t: ^testing.T) {
	// Standard example: the last block's data is " third event", with a single
	// leading space, because only one space is consumed as syntax.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data:  third event\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = " third event"}})
}

@(test)
test_field_without_colon_has_an_empty_value :: proc(t: ^testing.T) {
	// The grammar makes the colon and everything after it optional, so a bare
	// "data" is a data field with the empty value: the event's data is the empty
	// string, not absent.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = ""}})
}

@(test)
test_empty_data_dispatches_and_a_nonexistent_event_does_not :: proc(t: ^testing.T) {
	// Standard example: the first block dispatches an event with empty data, the
	// middle block one whose data is a single LF, and the last block is
	// discarded because no blank line follows it.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data\n\ndata\ndata\n\ndata:\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = ""}, {type = "message", data = "\n"}})
}

@(test)
test_comment_lines_are_ignored :: proc(t: ^testing.T) {
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, ": a comment\n:data: not a field\n\ndata: kept\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = "kept"}})
}

@(test)
test_comment_only_block_dispatches_nothing :: proc(t: ^testing.T) {
	// Standard example: the first block of the four-block stream is a comment
	// and fires nothing.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, ": test stream\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {})
}

@(test)
test_id_persists_across_events_and_is_reset_by_an_empty_id_field :: proc(t: ^testing.T) {
	// Standard example: the second block sets the last event ID to "1", the third
	// resets it with an empty id field, and the last has no id field at all. An
	// event without an id field reports whatever the last seen id was.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: first event\nid: 1\n\ndata:second event\nid\n\ndata:  third event\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(
		t,
		&recorder,
		{
			{type = "message", data = "first event", id = "1"},
			{type = "message", data = "second event", id = ""},
			{type = "message", data = " third event", id = ""},
		},
	)
}

@(test)
test_id_containing_null_is_ignored_and_the_previous_id_stands :: proc(t: ^testing.T) {
	// "If the field value does not contain U+0000 NULL, then set the last event
	// ID buffer to the field value. Otherwise, ignore the field." Ignoring means
	// the previous value survives, so a rejected update cannot erase it.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: a\nid: keep\n\ndata: b\nid: bad\x00value\n\ndata: c\nid: \x00\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(
		t,
		&recorder,
		{{type = "message", data = "a", id = "keep"}, {type = "message", data = "b", id = "keep"}, {type = "message", data = "c", id = "keep"}},
	)
}

@(test)
test_event_type_defaults_to_message_and_does_not_leak_to_the_next_event :: proc(t: ^testing.T) {
	// The event type buffer is cleared on dispatch, so a named type applies to
	// the event it was set for and the next event is a "message" again.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "event: add\ndata: 1\n\ndata: 2\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "add", data = "1"}, {type = "message", data = "2"}})
}

@(test)
test_event_type_without_data_is_discarded :: proc(t: ^testing.T) {
	// A block with no data dispatches nothing and clears the event type buffer,
	// so the type set there does not apply to the next event.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "event: add\n\ndata: 1\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = "1"}})
}

@(test)
test_unknown_fields_are_ignored :: proc(t: ^testing.T) {
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: kept\nunknown: value\nData: not a field\ndata : value\n\n")
	testing.expect_value(t, err, Error.None)
	// "data " is a different field name (trailing space), so it is ignored too.
	expect_events(t, &recorder, {{type = "message", data = "kept"}})
}

@(test)
test_retry_sets_the_reconnection_time_and_persists :: proc(t: ^testing.T) {
	// The reconnection time is stream state: it holds its value until the stream
	// changes it, so later events report the value currently in force.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: before\n\nretry: 5000\ndata: after\n\ndata: later\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(
		t,
		&recorder,
		{
			{type = "message", data = "before"},
			{type = "message", data = "after", retry_ms = 5000, retry_present = true},
			{type = "message", data = "later", retry_ms = 5000, retry_present = true},
		},
	)
}

@(test)
test_malformed_retry_is_ignored_not_fatal :: proc(t: ^testing.T) {
	// "If the field value consists of only ASCII digits ... Otherwise, ignore the
	// field." A malformed value leaves the previous value in place and never
	// fails the stream.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(
		&recorder,
		"retry: 100\ndata: a\n\n" + "retry: not a number\ndata: b\n\n" + "retry:\ndata: c\n\n" + "retry: 50x\ndata: d\n\n" + "retry: -1\ndata: e\n\n",
	)
	testing.expect_value(t, err, Error.None)
	expect_events(
		t,
		&recorder,
		{
			{type = "message", data = "a", retry_ms = 100, retry_present = true},
			{type = "message", data = "b", retry_ms = 100, retry_present = true},
			{type = "message", data = "c", retry_ms = 100, retry_present = true},
			{type = "message", data = "d", retry_ms = 100, retry_present = true},
			{type = "message", data = "e", retry_ms = 100, retry_present = true},
		},
	)
}

@(test)
test_retry_beyond_the_bound_is_clamped :: proc(t: ^testing.T) {
	// A digit string is always a valid reconnection time; one too large to
	// represent is clamped to the package's bound rather than rejected.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "retry: 999999999999999999999999\ndata: a\n\nretry: 0\ndata: b\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(
		t,
		&recorder,
		{{type = "message", data = "a", retry_ms = MAX_RETRY_MS, retry_present = true}, {type = "message", data = "b", retry_ms = 0, retry_present = true}},
	)
}

@(test)
test_line_endings_lf_cr_and_crlf_are_equivalent :: proc(t: ^testing.T) {
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: lf\n\n", "data: cr\r\r", "data: crlf\r\n\r\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = "lf"}, {type = "message", data = "cr"}, {type = "message", data = "crlf"}})
}

@(test)
test_crlf_separates_lines_and_a_blank_crlf_dispatches_once :: proc(t: ^testing.T) {
	// A CRLF pair is one line terminator, not two, so "\r\n\r\n" is a single
	// blank line and dispatches one event.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: a\r\ndata: b\r\n\r\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = "a\nb"}})
}

@(test)
test_a_cr_not_followed_by_lf_still_terminates_a_line :: proc(t: ^testing.T) {
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: a\rdata: b\r\r")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = "a\nb"}})
}

@(test)
test_a_trailing_cr_terminates_the_last_line :: proc(t: ^testing.T) {
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: a\r")
	testing.expect_value(t, err, Error.None)
	// The line is processed, but without a blank line nothing is dispatched.
	expect_events(t, &recorder, {})
}

@(test)
test_a_leading_bom_is_stripped :: proc(t: ^testing.T) {
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "\xEF\xBB\xBFdata: a\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = "a"}})
}

@(test)
test_a_bom_that_is_not_leading_is_data :: proc(t: ^testing.T) {
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: a\n\ndata: \xEF\xBB\xBFb\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = "a"}, {type = "message", data = "\uFEFFb"}})
}

@(test)
test_a_stream_that_is_only_a_bom_yields_nothing :: proc(t: ^testing.T) {
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "\xEF\xBB\xBF")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {})
}

@(test)
test_bom_bytes_that_differ_from_a_bom_are_data :: proc(t: ^testing.T) {
	// The first three bytes are held back to test for a BOM; when they are not
	// one they must all still be parsed.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "da\xFFta: a\n\ndata: b\n\n")
	testing.expect_value(t, err, Error.None)
	// The first line's field name is not "data" (its 3rd byte is invalid), so it
	// is ignored; only the second event is dispatched.
	expect_events(t, &recorder, {{type = "message", data = "b"}})
}

@(test)
test_end_of_stream_discards_pending_data :: proc(t: ^testing.T) {
	// "Once the end of the file is reached, any pending data must be discarded."
	// The end of a stream never dispatches an event.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: complete\n\n", "data: incomplete\nid: never")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = "complete"}})
}

@(test)
test_chunk_boundaries_do_not_change_the_result :: proc(t: ^testing.T) {
	// A stream is a byte sequence; where the reader's buffers happen to fall must
	// not affect the events it produces. Feeding one byte at a time is the
	// strictest form of that.
	stream := "\xEF\xBB\xBF: comment\r\nevent: add\rdata: one\r\ndata: two\n\nretry: 250\n\ndata\n\n"
	expected := []Recorded_Event{{type = "add", data = "one\ntwo"}, {type = "message", data = "", retry_ms = 250, retry_present = true}}

	whole: Recorder
	recorder_init(&whole)
	defer recorder_destroy(&whole)
	testing.expect_value(t, parse(&whole, stream), Error.None)
	expect_events(t, &whole, expected)

	byte_at_a_time: Recorder
	recorder_init(&byte_at_a_time)
	defer recorder_destroy(&byte_at_a_time)
	parser: Parser
	parser_init(&parser, record_event, &byte_at_a_time, allocator = byte_at_a_time.allocator)
	defer parser_destroy(&parser)
	for i in 0 ..< len(stream) {
		testing.expect_value(t, parser_feed(&parser, transmute([]u8)stream[i:i + 1]), Error.None)
	}
	testing.expect_value(t, parser_finish(&parser), Error.None)
	expect_events(t, &byte_at_a_time, expected)
}

@(test)
test_line_of_exactly_the_bound_is_accepted :: proc(t: ^testing.T) {
	// The bound is on the line, inclusive: a line of exactly MAX_LINE_BYTES bytes
	// plus its terminator fits.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	prefix := "data: "
	filler := strings.repeat("x", MAX_LINE_BYTES - len(prefix), context.temp_allocator)
	line := strings.concatenate({prefix, filler}, context.temp_allocator)
	testing.expect_value(t, len(line), MAX_LINE_BYTES)

	err := parse(&recorder, line, "\n\n")
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(recorder.events), 1)
	testing.expect_value(t, len(recorder.events[0].data), MAX_LINE_BYTES - len(prefix))
}

@(test)
test_line_beyond_the_bound_is_fatal_and_sticky :: proc(t: ^testing.T) {
	parser: Parser
	parser_init(&parser, nil)
	defer parser_destroy(&parser)

	overlong := strings.repeat("x", MAX_LINE_BYTES + 1, context.temp_allocator)
	testing.expect_value(t, parser_feed(&parser, transmute([]u8)overlong), Error.Line_Too_Long)
	// Sticky: the same error on every later call, and the stream is not resumed.
	testing.expect_value(t, parser_feed(&parser, transmute([]u8)string("\n\n")), Error.Line_Too_Long)
	testing.expect_value(t, parser_finish(&parser), Error.Line_Too_Long)
	testing.expect_value(t, parser_error(&parser), Error.Line_Too_Long)
}

@(test)
test_event_beyond_the_bound_is_fatal :: proc(t: ^testing.T) {
	// Many bounded data lines can still overflow the event budget. The stream is
	// bounded so a peer cannot make the parser allocate without limit.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	parser: Parser
	parser_init(&parser, record_event, &recorder, allocator = recorder.allocator)
	defer parser_destroy(&parser)

	prefix := "data: "
	filler := strings.repeat("x", MAX_LINE_BYTES - len(prefix) - 1, context.temp_allocator)
	line := strings.concatenate({prefix, filler, "\n"}, context.temp_allocator)

	err := Error.None
	lines := 0
	for err == .None {
		err = parser_feed(&parser, transmute([]u8)line)
		lines += 1
		testing.expect(t, lines <= MAX_EVENT_BYTES / MAX_LINE_BYTES + 2, "budget was never exceeded")
	}
	testing.expect_value(t, err, Error.Event_Too_Large)
	// Nothing is dispatched: the event was never completed.
	testing.expect_value(t, len(recorder.events), 0)
}

@(test)
test_finish_is_idempotent_and_reports_the_same_result :: proc(t: ^testing.T) {
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	parser: Parser
	parser_init(&parser, record_event, &recorder, allocator = recorder.allocator)
	defer parser_destroy(&parser)

	testing.expect_value(t, parser_feed(&parser, transmute([]u8)string("data: a\n\n")), Error.None)
	testing.expect_value(t, parser_finish(&parser), Error.None)
	testing.expect_value(t, parser_finish(&parser), Error.None)
	testing.expect_value(t, len(recorder.events), 1)
}

@(test)
test_a_nil_callback_still_parses :: proc(t: ^testing.T) {
	// The parser is usable purely to validate a stream.
	parser: Parser
	parser_init(&parser, nil)
	defer parser_destroy(&parser)

	testing.expect_value(t, parser_feed(&parser, transmute([]u8)string("data: a\n\n")), Error.None)
	testing.expect_value(t, parser_finish(&parser), Error.None)
}

@(test)
test_well_formed_utf8_is_preserved_byte_for_byte :: proc(t: ^testing.T) {
	// The decode step must not re-encode: a valid multi-byte sequence is stored
	// exactly as it arrived.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: héllo → ✅\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = "héllo → ✅"}})
}

@(test)
test_ill_formed_bytes_become_replacement_characters :: proc(t: ^testing.T) {
	// "Streams must be decoded using the UTF-8 decode algorithm." A lone
	// continuation byte, a byte that is never valid in UTF-8, and a truncated
	// sequence are each ill-formed.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: a\x80b\xFFc\xE2\x82d\n\n")
	testing.expect_value(t, err, Error.None)
	// \x80 -> one, \xFF -> one, \xE2\x82 -> two (one per ill-formed byte).
	expect_events(t, &recorder, {{type = "message", data = "a\uFFFDb\uFFFDc\uFFFD\uFFFDd"}})
}

@(test)
test_a_literal_replacement_character_is_not_replaced :: proc(t: ^testing.T) {
	// U+FFFD is a valid character: an encoded one decodes to RUNE_ERROR with a
	// length of three, which must be treated as well-formed and kept.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: \xEF\xBF\xBD\n\ndata: \xFF\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = "\uFFFD"}, {type = "message", data = "\uFFFD"}})
}

@(test)
test_ill_formed_bytes_in_event_type_and_id_are_replaced :: proc(t: ^testing.T) {
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "event: b\xFFd\nid: i\xFFd\ndata: a\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "b\uFFFDd", data = "a", id = "i\uFFFDd"}})
}

@(test)
test_spanning_chunks_completes_a_multi_byte_sequence :: proc(t: ^testing.T) {
	// A sequence split across two reads is still one character, because the line
	// is only decoded once its terminator arrives.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	err := parse(&recorder, "data: \xE2\x9C", "\x85\n\n")
	testing.expect_value(t, err, Error.None)
	expect_events(t, &recorder, {{type = "message", data = "✅"}})
}

@(test)
test_the_event_budget_counts_decoded_bytes :: proc(t: ^testing.T) {
	// An ill-formed byte is stored as three bytes, so a stream of them reaches
	// the budget sooner than its wire size suggests. Counting what is stored is
	// what keeps the bound meaningful.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)

	parser: Parser
	parser_init(&parser, record_event, &recorder, allocator = recorder.allocator)
	defer parser_destroy(&parser)

	filler := strings.repeat("\xFF", MAX_LINE_BYTES - 6, context.temp_allocator)
	line := strings.concatenate({"data: ", filler, "\n"}, context.temp_allocator)
	testing.expect(t, 3 * (MAX_LINE_BYTES - 6) < MAX_EVENT_BYTES, "one line must fit the budget")

	err := Error.None
	lines := 0
	for err == .None {
		err = parser_feed(&parser, transmute([]u8)line)
		lines += 1
		testing.expect(t, lines <= MAX_EVENT_BYTES / (3 * (MAX_LINE_BYTES - 6)) + 2, "budget was never exceeded")
	}
	testing.expect_value(t, err, Error.Event_Too_Large)
	testing.expect_value(t, len(recorder.events), 0)
}
