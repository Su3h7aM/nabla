#+test
#+private file
package input

import "core:testing"

_feed_events :: proc(t: ^testing.T, data: string, expected: []Event) {
	p: Parser
	parser_init(&p)
	defer parser_destroy(&p)
	events: [dynamic]Event
	defer events_destroy(&events)
	err := feed(&p, transmute([]byte)data, &events)
	testing.expect(t, err == nil, "feed must not error")
	testing.expect_value(t, len(events), len(expected))
	for i in 0 ..< min(len(events), len(expected)) {
		testing.expect_value(t, events[i], expected[i])
	}
}

@(test)
test_text_and_c0_keys :: proc(t: ^testing.T) {
	_feed_events(
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
	defer parser_destroy(&p)
	events: [dynamic]Event
	defer events_destroy(&events)
	// U+00E9 (e-acute) is 0xC3 0xA9, split across two feeds.
	testing.expect(t, feed(&p, []u8{0xc3}, &events) == nil, "first half must not error")
	testing.expect_value(t, len(events), 0)
	testing.expect(t, feed(&p, []u8{0xa9}, &events) == nil, "second half must not error")
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event(Key_Event{code = .Character, character = rune(0xe9)}))
}

@(test)
test_escape_sequences :: proc(t: ^testing.T) {
	// CSI arrows and tilde keys, a CSI modifier, and the SS3 function-key form.
	_feed_events(t, "\e[A\e[3~\e[1;5D\eOP", []Event{Key_Event{code = .Up}, Key_Event{code = .Delete}, Key_Event{code = .Left}, Key_Event{code = .F1}})
}

@(test)
test_lone_escape_resolves_on_deadline :: proc(t: ^testing.T) {
	p: Parser
	parser_init(&p)
	defer parser_destroy(&p)
	events: [dynamic]Event
	defer events_destroy(&events)
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
	_feed_events(t, "\eX", []Event{Key_Event{code = .Escape}, Key_Event{code = .Character, character = 'X'}})
}

@(test)
test_malformed_input_emits_unknown_and_resyncs :: proc(t: ^testing.T) {
	// 0x80 is an invalid UTF-8 lead byte; report Unknown, then continue with
	// the following byte.
	_feed_events(t, "\x80a", []Event{Unknown_Input{}, Key_Event{code = .Character, character = 'a'}})
}

@(test)
test_bracketed_paste :: proc(t: ^testing.T) {
	// The bytes between CSI 200 ~ and CSI 201 ~ become one Paste event with the
	// exact content: newlines and escape bytes are not decoded into events.
	_feed_events(t, "\e[200~hi\e[201~", []Event{Paste{text = "hi"}})
	_feed_events(t, "\e[200~a\r\nb\e[201~", []Event{Paste{text = "a\r\nb"}})
	// A complete paste followed by a key keeps both events.
	_feed_events(t, "\e[200~x\e[201~q", []Event{Paste{text = "x"}, Key_Event{code = .Character, character = 'q'}})
}

@(test)
test_sgr_mouse_reports_decode :: proc(t: ^testing.T) {
	// Wheel up/down with extended coordinates, a button press, its release,
	// and a drag (motion with the button held).
	_feed_events(t, "\e[<64;10;5M", []Event{Mouse_Event{button = .Wheel_Up, x = 10, y = 5}})
	_feed_events(t, "\e[<65;10;5M", []Event{Mouse_Event{button = .Wheel_Down, x = 10, y = 5}})
	_feed_events(t, "\e[<0;12;9M", []Event{Mouse_Event{button = .Left, x = 12, y = 9}})
	_feed_events(t, "\e[<0;12;9m", []Event{Mouse_Event{button = .Left, x = 12, y = 9, release = true}})
	_feed_events(t, "\e[<32;7;7M", []Event{Mouse_Event{button = .Left, x = 7, y = 7, motion = true}})

	// Coordinates the size of a wide terminal still fit the parameter buffer,
	// a report split across feeds waits for its final byte, and a malformed
	// report (an empty field, a hover report from a mode this parser never
	// enables) becomes Unknown_Input and resynchronizes.
	p: Parser
	parser_init(&p)
	defer parser_destroy(&p)
	events: [dynamic]Event
	defer events_destroy(&events)
	partial := "\e[<0;1000;900"
	testing.expect(t, feed(&p, transmute([]byte)partial, &events) == nil, "partial report must not error")
	testing.expect_value(t, len(events), 0)
	final := "M"
	testing.expect(t, feed(&p, transmute([]byte)final, &events) == nil, "final must not error")
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event(Mouse_Event{button = .Left, x = 1000, y = 900}))
	events_clear(&events)
	malformed := []string{"\e[<0;;1M", "\e[<35;1;1M"}
	for data in malformed {
		testing.expect(t, feed(&p, transmute([]byte)data, &events) == nil, "malformed report must not error")
		testing.expect_value(t, len(events), 1)
		testing.expect_value(t, events[0], Event(Unknown_Input{}))
		events_clear(&events)
	}
	resync := "q"
	testing.expect(t, feed(&p, transmute([]byte)resync, &events) == nil, "resync must not error")
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event(Key_Event{code = .Character, character = 'q'}))
}

@(test)
test_oversized_paste_is_discarded_and_reported :: proc(t: ^testing.T) {
	p: Parser
	parser_init(&p)
	defer parser_destroy(&p)
	events: [dynamic]Event
	defer events_destroy(&events)

	// One byte past the limit: the content is dropped, but the closing marker
	// is still recognised so the parser returns to Ground and the next key is
	// decoded normally.
	chunk := make([]u8, PASTE_LIMIT + 1)
	defer delete(chunk)
	for i in 0 ..< len(chunk) {
		chunk[i] = 'x'
	}
	open_marker := "\e[200~"
	close_and_key := "\e[201~q"
	testing.expect(t, feed(&p, transmute([]byte)open_marker, &events) == nil, "open must not error")
	testing.expect(t, feed(&p, chunk, &events) == nil, "content must not error")
	// The scratch is bounded, not the paste: once discarded it keeps only the
	// bytes that can still start the marker.
	testing.expect(t, len(p.paste) <= len(PASTE_END), "scratch must stay bounded")
	testing.expect(t, feed(&p, transmute([]byte)close_and_key, &events) == nil, "close must not error")

	testing.expect_value(t, len(events), 2)
	testing.expect_value(t, events[0], Event(Unknown_Input{}))
	testing.expect_value(t, events[1], Event(Key_Event{code = .Character, character = 'q'}))
	events_clear(&events)
	testing.expect_value(t, len(events), 0)
}
