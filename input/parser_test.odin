#+test
package input

import "core:testing"

test_feed_events :: proc(t: ^testing.T, data: string, expected: []Event) {
	p: Parser
	parser_init(&p)
	events: [dynamic]Event
	defer delete(events)
	err := feed(&p, transmute([]byte)data, &events)
	testing.expect(t, err == nil, "feed must not error")
	testing.expect_value(t, len(events), len(expected))
	for i in 0 ..< min(len(events), len(expected)) {
		testing.expect_value(t, events[i], expected[i])
	}
}

@(test)
test_text_and_c0_keys :: proc(t: ^testing.T) {
	test_feed_events(
		t,
		"ab\t\r\x7f",
		[]Event {
			Key_Event{code = .Character, character = 'a'},
			Key_Event{code = .Character, character = 'b'},
			Key_Event{code = .Tab},
			Key_Event{code = .Enter},
			Key_Event{code = .Backspace},
		},
	)
}

@(test)
test_utf8_split_across_feeds :: proc(t: ^testing.T) {
	p: Parser
	parser_init(&p)
	events: [dynamic]Event
	defer delete(events)
	// U+00E9 (e-acute) = 0xC3 0xA9, split across two feeds.
	testing.expect(t, feed(&p, []u8{0xc3}, &events) == nil, "first half must not error")
	testing.expect_value(t, len(events), 0)
	testing.expect(t, feed(&p, []u8{0xa9}, &events) == nil, "second half must not error")
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event(Key_Event{code = .Character, character = rune(0xe9)}))
}

@(test)
test_csi_arrow_and_tilde_keys :: proc(t: ^testing.T) {
	test_feed_events(t, "\e[A\e[3~\e[1;5D", []Event{Key_Event{code = .Up}, Key_Event{code = .Delete}, Key_Event{code = .Left}})
}

@(test)
test_ss3_function_keys :: proc(t: ^testing.T) {
	test_feed_events(t, "\eOP", []Event{Key_Event{code = .F1}})
}

@(test)
test_lone_escape_resolves_on_deadline :: proc(t: ^testing.T) {
	p: Parser
	parser_init(&p)
	events: [dynamic]Event
	defer delete(events)
	testing.expect(t, feed(&p, []u8{0x1b}, &events) == nil, "feed ESC must not error")
	testing.expect(t, parser_escape_pending(&p), "parser must await the sequence byte")
	testing.expect_value(t, len(events), 0)
	testing.expect(t, parser_resolve_escape(&p, &events) == nil, "resolve must not error")
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event(Key_Event{code = .Escape}))
}

@(test)
test_escape_then_printable_emits_escape_then_key :: proc(t: ^testing.T) {
	// Alt+x arrives as ESC x; the policy is an Escape event followed by the key.
	test_feed_events(t, "\eX", []Event{Key_Event{code = .Escape}, Key_Event{code = .Character, character = 'X'}})
}

@(test)
test_malformed_input_emits_unknown_and_resyncs :: proc(t: ^testing.T) {
	// 0x80 is an invalid UTF-8 lead byte; report Unknown, then continue with
	// the following byte.
	test_feed_events(t, "\x80a", []Event{Unknown_Input{}, Key_Event{code = .Character, character = 'a'}})
}
