package sse

import "core:mem"
import "core:strings"
import "core:testing"

// The parser's contract is the WHATWG HTML Standard's event stream
// interpretation algorithm. Each test names the rule it locks; the examples
// marked "standard example" are the standard's own worked examples.

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
		if err := parser_feed(&parser, transmute([]u8)chunk); err != .None {
			return err
		}
	}
	return parser_finish(&parser)
}

expect_events :: proc(t: ^testing.T, recorder: ^Recorder, expected: []Recorded_Event, loc := #caller_location) {
	testing.expectf(t, len(recorder.events) == len(expected), "%v: expected %d event(s), got %d", loc, len(expected), len(recorder.events))
	for got, i in recorder.events {
		if i >= len(expected) {
			break
		}
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
test_field_parsing_and_data_assembly :: proc(t: ^testing.T) {
	// Standard example: three data fields join with LF.
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "data: YHOO\ndata: +2\ndata: 10\n\n"), Error.None)
		expect_events(t, &recorder, {{type = "message", data = "YHOO\n+2\n10"}})
	}
	// Standard example: one space after the colon is syntax, and exactly one.
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "data: test\n\ndata:test\n\ndata:  third event\n\n"), Error.None)
		expect_events(t, &recorder, {{type = "message", data = "test"}, {type = "message", data = "test"}, {type = "message", data = " third event"}})
	}
	// The colon and value are optional, so a bare field has the empty value.
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "data\n\n"), Error.None)
		expect_events(t, &recorder, {{type = "message", data = ""}})
	}
	// Standard example: empty data dispatches, a single LF dispatches, and a
	// trailing block with no blank line is discarded.
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "data\n\ndata\ndata\n\ndata:\n"), Error.None)
		expect_events(t, &recorder, {{type = "message", data = ""}, {type = "message", data = "\n"}})
	}
}

@(test)
test_comments_are_ignored :: proc(t: ^testing.T) {
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)
	// A line beginning with a colon is a comment, and a comment-only block on
	// the standard's four-block example fires nothing.
	testing.expect_value(t, parse(&recorder, ": a comment\n:data: not a field\n\ndata: kept\n\n: test stream\n\n"), Error.None)
	expect_events(t, &recorder, {{type = "message", data = "kept"}})
}

@(test)
test_id_state :: proc(t: ^testing.T) {
	// Standard example: an id persists across events, and an empty id field
	// resets it. An event with no id field reports the current value.
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "data: first event\nid: 1\n\ndata:second event\nid\n\ndata:  third event\n\n"), Error.None)
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
	// A field value containing U+0000 is ignored, so the previous id stands.
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "data: a\nid: keep\n\ndata: b\nid: bad\x00value\n\ndata: c\nid: \x00\n\n"), Error.None)
		expect_events(
			t,
			&recorder,
			{{type = "message", data = "a", id = "keep"}, {type = "message", data = "b", id = "keep"}, {type = "message", data = "c", id = "keep"}},
		)
	}
}

@(test)
test_event_type_state :: proc(t: ^testing.T) {
	// A named type applies only to the event it was set for; the next event is a
	// "message" again. A block with no data dispatches nothing and clears the
	// type, and unknown fields are ignored.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)
	testing.expect_value(t, parse(&recorder, "event: add\ndata: 1\n\ndata: 2\n\nevent: add\n\ndata: 3\n\nunknown: value\nData: x\ndata : y\n\n"), Error.None)
	expect_events(t, &recorder, {{type = "add", data = "1"}, {type = "message", data = "2"}, {type = "message", data = "3"}})
}

@(test)
test_retry_state :: proc(t: ^testing.T) {
	// The reconnection time is stream state: it persists until changed, a
	// malformed value is ignored rather than fatal, and an unrepresentable digit
	// string is clamped.
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)
	wire :=
		"data: before\n\n" +
		"retry: 5000\ndata: after\n\n" +
		"retry: not a number\ndata: b\n\n" +
		"retry:\ndata: c\n\n" +
		"retry: 50x\ndata: d\n\n" +
		"retry: -1\ndata: e\n\n" +
		"retry: 999999999999999999999999\ndata: f\n\n" +
		"retry: 0\ndata: g\n\n"
	testing.expect_value(t, parse(&recorder, wire), Error.None)
	expect_events(
		t,
		&recorder,
		{
			{type = "message", data = "before"},
			{type = "message", data = "after", retry_ms = 5000, retry_present = true},
			{type = "message", data = "b", retry_ms = 5000, retry_present = true},
			{type = "message", data = "c", retry_ms = 5000, retry_present = true},
			{type = "message", data = "d", retry_ms = 5000, retry_present = true},
			{type = "message", data = "e", retry_ms = 5000, retry_present = true},
			{type = "message", data = "f", retry_ms = MAX_RETRY_MS, retry_present = true},
			{type = "message", data = "g", retry_ms = 0, retry_present = true},
		},
	)
}

@(test)
test_line_endings :: proc(t: ^testing.T) {
	recorder: Recorder
	recorder_init(&recorder)
	defer recorder_destroy(&recorder)
	// LF, CR, and CRLF are each one line terminator, so "\r\n\r\n" is a single
	// blank line. A CR not followed by LF still terminates a line, and a trailing
	// CR processes its line without dispatching.
	testing.expect_value(t, parse(&recorder, "data: lf\n\n", "data: cr\r\r", "data: crlf\r\n\r\n", "data: a\rdata: b\r\r", "data: a\r"), Error.None)
	expect_events(
		t,
		&recorder,
		{{type = "message", data = "lf"}, {type = "message", data = "cr"}, {type = "message", data = "crlf"}, {type = "message", data = "a\nb"}},
	)
}

@(test)
test_byte_order_mark :: proc(t: ^testing.T) {
	// A leading BOM is stripped; the same bytes later are data, a stream of only
	// a BOM yields nothing, and held-back non-BOM bytes are still parsed.
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "\xEF\xBB\xBFdata: a\n\n"), Error.None)
		expect_events(t, &recorder, {{type = "message", data = "a"}})
	}
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "data: a\n\ndata: \xEF\xBB\xBFb\n\n"), Error.None)
		expect_events(t, &recorder, {{type = "message", data = "a"}, {type = "message", data = "\uFEFFb"}})
	}
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "\xEF\xBB\xBF"), Error.None)
		expect_events(t, &recorder, {})
	}
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "da\xFFta: a\n\ndata: b\n\n"), Error.None)
		expect_events(t, &recorder, {{type = "message", data = "b"}})
	}
}

@(test)
test_end_of_stream_and_chunk_boundaries :: proc(t: ^testing.T) {
	// Pending data is discarded at the end of the stream, and where the reader's
	// buffers fall must not change the events produced.
	stream := "\xEF\xBB\xBF: comment\r\nevent: add\rdata: one\r\ndata: two\n\nretry: 250\n\ndata\n\n"
	expected := []Recorded_Event{{type = "add", data = "one\ntwo"}, {type = "message", data = "", retry_ms = 250, retry_present = true}}

	whole: Recorder
	recorder_init(&whole)
	defer recorder_destroy(&whole)
	testing.expect_value(t, parse(&whole, stream, "data: incomplete\nid: never"), Error.None)
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
test_line_and_event_bounds :: proc(t: ^testing.T) {
	// The line bound is inclusive.
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		prefix := "data: "
		filler := strings.repeat("x", MAX_LINE_BYTES - len(prefix), context.temp_allocator)
		line := strings.concatenate({prefix, filler}, context.temp_allocator)
		testing.expect_value(t, len(line), MAX_LINE_BYTES)
		testing.expect_value(t, parse(&recorder, line, "\n\n"), Error.None)
		testing.expect_value(t, len(recorder.events), 1)
		testing.expect_value(t, len(recorder.events[0].data), MAX_LINE_BYTES - len(prefix))
	}
	// An overlong line is a sticky, fatal error.
	{
		parser: Parser
		parser_init(&parser, nil)
		defer parser_destroy(&parser)
		overlong := strings.repeat("x", MAX_LINE_BYTES + 1, context.temp_allocator)
		testing.expect_value(t, parser_feed(&parser, transmute([]u8)overlong), Error.Line_Too_Long)
		testing.expect_value(t, parser_feed(&parser, transmute([]u8)string("\n\n")), Error.Line_Too_Long)
		testing.expect_value(t, parser_finish(&parser), Error.Line_Too_Long)
		testing.expect_value(t, parser_error(&parser), Error.Line_Too_Long)
	}
	// Many bounded lines still overflow the event budget, and nothing dispatches.
	{
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
		testing.expect_value(t, len(recorder.events), 0)
	}
	// The budget counts decoded bytes, so ill-formed bytes reach it sooner.
	{
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
}

@(test)
test_parser_lifecycle :: proc(t: ^testing.T) {
	// finish is idempotent, and a nil callback parses purely to validate.
	{
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
	{
		parser: Parser
		parser_init(&parser, nil)
		defer parser_destroy(&parser)
		testing.expect_value(t, parser_feed(&parser, transmute([]u8)string("data: a\n\n")), Error.None)
		testing.expect_value(t, parser_finish(&parser), Error.None)
	}
}

@(test)
test_utf8_decoding :: proc(t: ^testing.T) {
	// Well-formed multi-byte input is preserved byte for byte, and a sequence
	// split across reads is completed before the line is decoded.
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "data: héllo → ✅\n\n"), Error.None)
		expect_events(t, &recorder, {{type = "message", data = "héllo → ✅"}})
	}
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "data: \xE2\x9C", "\x85\n\n"), Error.None)
		expect_events(t, &recorder, {{type = "message", data = "✅"}})
	}
	// Each ill-formed byte becomes one replacement character; an encoded
	// U+FFFD is well-formed and kept as itself.
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "data: a\x80b\xFFc\xE2\x82d\n\n"), Error.None)
		expect_events(t, &recorder, {{type = "message", data = "a\uFFFDb\uFFFDc\uFFFD\uFFFDd"}})
	}
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "data: \xEF\xBF\xBD\n\ndata: \xFF\n\n"), Error.None)
		expect_events(t, &recorder, {{type = "message", data = "\uFFFD"}, {type = "message", data = "\uFFFD"}})
	}
	// The event type and id decode the same way.
	{
		recorder: Recorder
		recorder_init(&recorder)
		defer recorder_destroy(&recorder)
		testing.expect_value(t, parse(&recorder, "event: b\xFFd\nid: i\xFFd\ndata: a\n\n"), Error.None)
		expect_events(t, &recorder, {{type = "b\uFFFDd", data = "a", id = "i\uFFFDd"}})
	}
}
