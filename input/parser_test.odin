#+test
#+private file
package input

import "core:mem"
import "core:testing"

_feed_events :: proc(t: ^testing.T, data: string, expected: []Event) {
	parser: Parser
	parser_init(&parser)
	defer parser_destroy(&parser)
	events: [dynamic]Event
	defer events_destroy(&events)
	err := feed(&parser, transmute([]byte)data, &events)
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
	parser: Parser
	parser_init(&parser)
	defer parser_destroy(&parser)
	events: [dynamic]Event
	defer events_destroy(&events)
	// U+00E9 (e-acute) is 0xC3 0xA9, split across two feeds.
	testing.expect(t, feed(&parser, []u8{0xc3}, &events) == nil, "first half must not error")
	testing.expect_value(t, len(events), 0)
	testing.expect(t, feed(&parser, []u8{0xa9}, &events) == nil, "second half must not error")
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event(Key_Event{code = .Character, character = rune(0xe9)}))
}

@(test)
test_escape_sequences :: proc(t: ^testing.T) {
	// CSI arrows and tilde keys, a CSI modifier, and the SS3 function-key form.
	_feed_events(
		t,
		"\e[A\e[3~\e[1;5D\eOP",
		[]Event{Key_Event{code = .Up}, Key_Event{code = .Delete}, Key_Event{code = .Left, modifiers = {.Control}}, Key_Event{code = .F1}},
	)
}

@(test)
test_modified_enter_sequences :: proc(t: ^testing.T) {
	_feed_events(t, "\e[13;2u\e[27;2;13~", []Event{Key_Event{code = .Enter, modifiers = {.Shift}}, Key_Event{code = .Enter, modifiers = {.Shift}}})
}

@(test)
test_lone_escape_resolves_on_deadline :: proc(t: ^testing.T) {
	parser: Parser
	parser_init(&parser)
	defer parser_destroy(&parser)
	events: [dynamic]Event
	defer events_destroy(&events)
	testing.expect(t, feed(&parser, []u8{0x1b}, &events) == nil, "feed ESC must not error")
	testing.expect(t, parser_escape_pending(&parser), "parser must await the sequence byte")
	testing.expect_value(t, len(events), 0)
	testing.expect(t, parser_resolve_escape(&parser, &events) == nil, "resolve must not error")
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event(Key_Event{code = .Escape}))
}

@(test)
test_escape_then_key_is_alt_key :: proc(t: ^testing.T) {
	_feed_events(
		t,
		"\eX\e]\e\t\e\r\e\x7f\e ",
		[]Event {
			Key_Event{code = .Character, character = 'X', modifiers = {.Alt}},
			Key_Event{code = .Character, character = ']', modifiers = {.Alt}},
			Key_Event{code = .Tab, modifiers = {.Alt}},
			Key_Event{code = .Enter, modifiers = {.Alt}},
			Key_Event{code = .Backspace, modifiers = {.Alt}},
			Key_Event{code = .Character, character = ' ', modifiers = {.Alt}},
		},
	)
	// ESC before a control byte is still Escape, then the key.
	_feed_events(t, "\e\x01", []Event{Key_Event{code = .Escape}, Key_Event{code = .Character, character = 'a', modifiers = {.Control}}})
	// ESC ESC before a cursor key is how legacy Alt terminals send Alt with it.
	_feed_events(t, "\e\e[A\e\eOB\e[A", []Event{Key_Event{code = .Up, modifiers = {.Alt}}, Key_Event{code = .Down, modifiers = {.Alt}}, Key_Event{code = .Up}})
}

@(test)
test_control_bytes_normalize_to_letters :: proc(t: ^testing.T) {
	_feed_events(
		t,
		"\x01\x03\x1a\x00\x1c\x1f",
		[]Event {
			Key_Event{code = .Character, character = 'a', modifiers = {.Control}},
			Key_Event{code = .Character, character = 'c', modifiers = {.Control}},
			Key_Event{code = .Character, character = 'z', modifiers = {.Control}},
			Key_Event{code = .Character, character = ' ', modifiers = {.Control}},
			Key_Event{code = .Character, character = '4', modifiers = {.Control}},
			Key_Event{code = .Character, character = '7', modifiers = {.Control}},
		},
	)
}

@(test)
test_modified_csi_and_ss3_keys :: proc(t: ^testing.T) {
	_feed_events(
		t,
		"\e[1;5D\e[3;3~\e[5;2~\e[1;2H\e[1;6F\e[1;5P\e[1;3S\e[1;2R\eO5Q\e[Z",
		[]Event {
			Key_Event{code = .Left, modifiers = {.Control}},
			Key_Event{code = .Delete, modifiers = {.Alt}},
			Key_Event{code = .Page_Up, modifiers = {.Shift}},
			Key_Event{code = .Home, modifiers = {.Shift}},
			Key_Event{code = .End, modifiers = {.Shift, .Control}},
			Key_Event{code = .F1, modifiers = {.Control}},
			Key_Event{code = .F4, modifiers = {.Alt}},
			Key_Event{code = .F3, modifiers = {.Shift}},
			Key_Event{code = .F2, modifiers = {.Control}},
			Key_Event{code = .Tab, modifiers = {.Shift}},
		},
	)
}

@(test)
test_function_keys_f6_to_f12 :: proc(t: ^testing.T) {
	_feed_events(
		t,
		"\e[17~\e[18~\e[19~\e[20~\e[21~\e[23~\e[24~",
		[]Event {
			Key_Event{code = .F6},
			Key_Event{code = .F7},
			Key_Event{code = .F8},
			Key_Event{code = .F9},
			Key_Event{code = .F10},
			Key_Event{code = .F11},
			Key_Event{code = .F12},
		},
	)
}

@(test)
test_kitty_keys :: proc(t: ^testing.T) {
	_feed_events(
		t,
		"\e[97;5u\e[97:65;2u\e[97;1:3u\e[98;3:2u\e[27u\e[9;2u\e[127u\e[57441u\e[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18A",
		[]Event {
			Key_Event{code = .Character, character = 'a', modifiers = {.Control}},
			Key_Event{code = .Character, character = 'A'},
			Key_Event{code = .Character, character = 'a', kind = .Release},
			Key_Event{code = .Character, character = 'b', modifiers = {.Alt}, kind = .Repeat},
			Key_Event{code = .Escape},
			Key_Event{code = .Tab, modifiers = {.Shift}},
			Key_Event{code = .Backspace},
			Unknown_Input{},
			Unknown_Input{},
		},
	)
}

@(test)
test_extra_parameters_are_rejected :: proc(t: ^testing.T) {
	// More parameter bytes than the buffer holds must not decode as the key the first bytes spell.
	_feed_events(
		t,
		"\e[1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1A\e[1$~q",
		[]Event{Unknown_Input{}, Unknown_Input{}, Key_Event{code = .Character, character = 'q'}},
	)
}

@(test)
test_malformed_input_emits_unknown_and_resyncs :: proc(t: ^testing.T) {
	// 0x80 is an invalid UTF-8 lead byte; report Unknown, then continue with
	// the following byte.
	_feed_events(t, "\x80a", []Event{Unknown_Input{}, Key_Event{code = .Character, character = 'a'}})
}

@(test)
test_overlong_utf8_emits_unknown_and_resyncs :: proc(t: ^testing.T) {
	parser: Parser
	parser_init(&parser)
	defer parser_destroy(&parser)
	events: [dynamic]Event
	defer events_destroy(&events)

	data := []u8{0xe0, 0x80, 0xaf, 'q'}
	testing.expect(t, feed(&parser, data, &events) == nil, "overlong input must not error")
	testing.expect_value(t, len(events), 2)
	testing.expect_value(t, events[0], Event(Unknown_Input{}))
	testing.expect_value(t, events[1], Event(Key_Event{code = .Character, character = 'q'}))
}

@(test)
test_sgr_mouse_modifiers_motion_and_unknown_buttons :: proc(t: ^testing.T) {
	_feed_events(t, "\e[<4;1;2M", []Event{Mouse_Event{button = .Left, x = 0, y = 1, modifiers = {.Shift}}})
	_feed_events(t, "\e[<24;3;4m", []Event{Mouse_Event{button = .Left, x = 2, y = 3, modifiers = {.Alt, .Control}, release = true}})
	_feed_events(t, "\e[<68;5;6M", []Event{Mouse_Event{button = .Wheel_Up, x = 4, y = 5, modifiers = {.Shift}}})
	_feed_events(t, "\e[<35;7;8M", []Event{Mouse_Event{button = .None, x = 6, y = 7, motion = true}})
	_feed_events(t, "\e[<34;7;8M", []Event{Mouse_Event{button = .Right, x = 6, y = 7, motion = true}})
	_feed_events(t, "\e[<128;1;1M\e[<129;1;1M", []Event{Unknown_Input{}, Unknown_Input{}})
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
test_bracketed_paste_allocation_failure_can_be_retried :: proc(t: ^testing.T) {
	parser: Parser
	parser_init(&parser)
	defer parser_destroy(&parser)
	events: [dynamic]Event
	defer events_destroy(&events)
	marker := "\e[200~"
	backing: [1]byte
	arena: mem.Arena
	mem.arena_init(&arena, backing[:])
	testing.expect_value(t, feed(&parser, transmute([]byte)marker, &events, mem.arena_allocator(&arena)), Error(mem.Allocator_Error.Out_Of_Memory))
	testing.expect_value(t, len(events), 0)

	// The failed allocation leaves the sequence waiting for its final byte.
	retry := "~hello\e[201~q"
	if !testing.expect_value(t, feed(&parser, transmute([]byte)retry, &events), nil) { return }
	if !testing.expect_value(t, len(events), 2) { return }
	testing.expect_value(t, events[0], Event(Paste{text = "hello"}))
	testing.expect_value(t, events[1], Event(Key_Event{code = .Character, character = 'q'}))
}

@(test)
test_sgr_mouse_reports_decode :: proc(t: ^testing.T) {
	// Wheel up/down with extended coordinates, a button press, its release,
	// and a drag (motion with the button held).
	_feed_events(t, "\e[<64;10;5M", []Event{Mouse_Event{button = .Wheel_Up, x = 9, y = 4}})
	_feed_events(t, "\e[<65;10;5M", []Event{Mouse_Event{button = .Wheel_Down, x = 9, y = 4}})
	_feed_events(t, "\e[<0;12;9M", []Event{Mouse_Event{button = .Left, x = 11, y = 8}})
	_feed_events(t, "\e[<0;12;9m", []Event{Mouse_Event{button = .Left, x = 11, y = 8, release = true}})
	_feed_events(t, "\e[<32;7;7M", []Event{Mouse_Event{button = .Left, x = 6, y = 6, motion = true}})

	// Coordinates the size of a wide terminal still fit the parameter buffer,
	// a report split across feeds waits for its final byte, and a malformed
	// report (an empty field, a release with no button) becomes Unknown_Input and resynchronizes.
	parser: Parser
	parser_init(&parser)
	defer parser_destroy(&parser)
	events: [dynamic]Event
	defer events_destroy(&events)
	partial := "\e[<0;1000;900"
	testing.expect(t, feed(&parser, transmute([]byte)partial, &events) == nil, "partial report must not error")
	testing.expect_value(t, len(events), 0)
	final := "M"
	testing.expect(t, feed(&parser, transmute([]byte)final, &events) == nil, "final must not error")
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event(Mouse_Event{button = .Left, x = 999, y = 899}))
	events_clear(&events)
	malformed := []string{"\e[<0;;1M", "\e[<3;1;1M"}
	for data in malformed {
		testing.expect(t, feed(&parser, transmute([]byte)data, &events) == nil, "malformed report must not error")
		testing.expect_value(t, len(events), 1)
		testing.expect_value(t, events[0], Event(Unknown_Input{}))
		events_clear(&events)
	}
	resync := "q"
	testing.expect(t, feed(&parser, transmute([]byte)resync, &events) == nil, "resync must not error")
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], Event(Key_Event{code = .Character, character = 'q'}))
}

@(test)
test_a_large_paste_arrives_whole :: proc(t: ^testing.T) {
	parser: Parser
	parser_init(&parser)
	defer parser_destroy(&parser)
	events: [dynamic]Event
	defer events_destroy(&events)

	// A paste larger than any scratch the parser could have pre-sized arrives
	// as one event with every byte of its content, and the closing marker
	// leaves the parser in Ground so the next key is decoded normally.
	body := make([]u8, 1 << 20)
	defer delete(body)
	for i in 0 ..< len(body) { body[i] = 'x' }

	open_marker := "\e[200~"
	close_and_key := "\e[201~q"
	testing.expect(t, feed(&parser, transmute([]byte)open_marker, &events) == nil, "open must not error")
	testing.expect(t, feed(&parser, body, &events) == nil, "content must not error")
	testing.expect(t, feed(&parser, transmute([]byte)close_and_key, &events) == nil, "close must not error")

	testing.expect_value(t, len(events), 2)
	paste, is_paste := events[0].(Paste)
	testing.expect(t, is_paste, "a paste must arrive as a Paste event")
	testing.expect_value(t, len(paste.text), len(body))
	testing.expect(t, paste.text == string(body), "every pasted byte must arrive")
	testing.expect_value(t, events[1], Event(Key_Event{code = .Character, character = 'q'}))
	events_clear(&events)
	testing.expect_value(t, len(events), 0)
}
