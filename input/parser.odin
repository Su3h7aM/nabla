package input

import "base:runtime"

Parser_State :: enum u8 {
	Ground,
	Utf8,
	Escape,
	Csi,
	Ss3,
	Osc,
}

// Parser is a caller-owned, pure byte-to-event state machine. It retains
// state across feed calls (a key sequence may span reads) and performs no
// I/O: acquisition feeds byte slices and drains the emitted events. Malformed
// input normalizes to Unknown_Input events and resynchronizes; only resource
// failures are errors.
Parser :: struct {
	state:         Parser_State,
	utf8_expected: int, // remaining UTF-8 continuation bytes
	utf8_pending:  u32, // accumulated code point bits
	params:        [8]u8,
	param_count:   int,
	intermediate:  u8,
}

parser_init :: proc(p: ^Parser) {
	p^ = {}
}

// feed consumes a byte chunk and appends the produced events. A lone ESC
// leaves the parser in the Escape state without emitting; the acquisition
// layer resolves it via parser_escape_pending/parser_resolve_escape after its
// deadline.
feed :: proc(p: ^Parser, data: []byte, events: ^[dynamic]Event, allocator := context.allocator) -> (err: Error) {
	for i := 0; i < len(data); {
		consumed: int
		switch p.state {
		case .Ground:
			consumed, err = parser_ground(p, data[i], events, allocator)
		case .Utf8:
			consumed, err = parser_utf8(p, data[i], events, allocator)
		case .Escape:
			consumed, err = parser_escape(p, data[i], events, allocator)
		case .Csi, .Ss3:
			consumed, err = parser_sequence(p, data[i], events, allocator)
		case .Osc:
			consumed, err = parser_osc(p, data[i])
		}
		if err != nil {
			return err
		}
		i += consumed
	}
	return nil
}

// parser_escape_pending reports whether the parser is awaiting the byte after
// a lone ESC.
parser_escape_pending :: proc(p: ^Parser) -> bool {
	return p.state == .Escape
}

// parser_resolve_escape emits an Escape for a lone ESC whose deadline
// expired, then returns to Ground.
parser_resolve_escape :: proc(p: ^Parser, events: ^[dynamic]Event, allocator := context.allocator) -> (err: Error) {
	if p.state != .Escape {
		return nil
	}
	parser_reset(p)
	return parser_emit(p, events, Key_Event{code = .Escape}, allocator)
}

parser_reset :: proc(p: ^Parser) {
	p.state = .Ground
	p.utf8_expected = 0
	p.utf8_pending = 0
	p.param_count = 0
	p.intermediate = 0
}

parser_emit :: proc(p: ^Parser, events: ^[dynamic]Event, event: Event, allocator: runtime.Allocator) -> Error {
	previous := context.allocator
	context.allocator = allocator
	_, err := runtime.append_elem(events, event)
	context.allocator = previous
	return err
}

parser_ground :: proc(p: ^Parser, b: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> (consumed: int, err: Error) {
	switch {
	case b == 0x1b:
		p.state = .Escape
	case b == 0x09:
		err = parser_emit(p, events, Key_Event{code = .Tab}, allocator)
	case b == 0x0d:
		err = parser_emit(p, events, Key_Event{code = .Enter}, allocator)
	case b == 0x7f:
		err = parser_emit(p, events, Key_Event{code = .Backspace}, allocator)
	case b >= 0x01 && b <= 0x1a:
		err = parser_emit(p, events, Key_Event{code = .Character, character = rune(b), modifiers = {.Control}}, allocator)
	case b >= 0x80:
		expected := 0
		switch {
		case b >= 0xc2 && b <= 0xdf:
			expected = 1
			p.utf8_pending = u32(b & 0x1f)
		case b >= 0xe0 && b <= 0xef:
			expected = 2
			p.utf8_pending = u32(b & 0x0f)
		case b >= 0xf0 && b <= 0xf4:
			expected = 3
			p.utf8_pending = u32(b & 0x07)
		case:
			err = parser_emit(p, events, Unknown_Input{}, allocator)
		}
		if expected > 0 {
			p.state = .Utf8
			p.utf8_expected = expected
		}
	case b < 0x80:
		err = parser_emit(p, events, Key_Event{code = .Character, character = rune(b)}, allocator)
	}
	return 1, err
}

parser_utf8 :: proc(p: ^Parser, b: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> (consumed: int, err: Error) {
	if b >= 0x80 && b <= 0xbf {
		p.utf8_pending = (p.utf8_pending << 6) | u32(b & 0x3f)
		p.utf8_expected -= 1
		if p.utf8_expected == 0 {
			r := rune(p.utf8_pending)
			parser_reset(p)
			if (r >= 0xd800 && r <= 0xdfff) || r > 0x10ffff {
				return 1, parser_emit(p, events, Unknown_Input{}, allocator)
			}
			return 1, parser_emit(p, events, Key_Event{code = .Character, character = r}, allocator)
		}
		return 1, nil
	}
	// Not a continuation byte: the sequence is malformed. Report it, then
	// resynchronize by reprocessing b in Ground (consumed = 0).
	parser_reset(p)
	if unknown_err := parser_emit(p, events, Unknown_Input{}, allocator); unknown_err != nil {
		return 0, unknown_err
	}
	return 0, nil
}

parser_escape :: proc(p: ^Parser, b: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> (consumed: int, err: Error) {
	switch b {
	case 0x1b:
		// ESC ESC: restart the escape sequence.
		return 1, nil
	case '[':
		p.state = .Csi
		p.param_count = 0
		p.intermediate = 0
		return 1, nil
	case 'O':
		p.state = .Ss3
		p.param_count = 0
		p.intermediate = 0
		return 1, nil
	case ']':
		p.state = .Osc
		return 1, nil
	case:
		// A lone ESC followed by an ordinary byte: emit Escape, then
		// reprocess the byte in Ground (ESC + printable = Escape then key).
		p.state = .Ground
		if esc_err := parser_emit(p, events, Key_Event{code = .Escape}, allocator); esc_err != nil {
			return 0, esc_err
		}
		return 0, nil
	}
}

parser_sequence :: proc(p: ^Parser, b: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> (consumed: int, err: Error) {
	if b >= 0x30 && b <= 0x3f {
		if p.param_count < len(p.params) {
			p.params[p.param_count] = b
			p.param_count += 1
		}
		return 1, nil
	}
	if b >= 0x20 && b <= 0x2f {
		p.intermediate = b
		return 1, nil
	}
	if b >= 0x40 && b <= 0x7e {
		state := p.state
		final_err := parser_sequence_final(p, state, b, events, allocator)
		parser_reset(p)
		return 1, final_err
	}
	if b == 0x1b {
		// ESC inside a sequence: restart at Escape (tcell PR 1053).
		p.state = .Escape
		return 1, nil
	}
	// A byte outside the sequence alphabet: malformed, resynchronize.
	parser_reset(p)
	return 1, parser_emit(p, events, Unknown_Input{}, allocator)
}

parser_sequence_final :: proc(p: ^Parser, state: Parser_State, final: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> Error {
	code: Key_Code
	found := false
	if state == .Ss3 {
		switch final {
		case 'P':
			code, found = .F1, true
		case 'Q':
			code, found = .F2, true
		case 'R':
			code, found = .F3, true
		case 'S':
			code, found = .F4, true
		case 'H':
			code, found = .Home, true
		case 'F':
			code, found = .End, true
		case 'A':
			code, found = .Up, true
		case 'B':
			code, found = .Down, true
		case 'C':
			code, found = .Right, true
		case 'D':
			code, found = .Left, true
		}
	} else {
		param := parser_first_param(p)
		switch final {
		case 'A':
			code, found = .Up, true
		case 'B':
			code, found = .Down, true
		case 'C':
			code, found = .Right, true
		case 'D':
			code, found = .Left, true
		case 'H':
			code, found = .Home, true
		case 'F':
			code, found = .End, true
		case '~':
			switch param {
			case 1, 7:
				code, found = .Home, true
			case 2:
				code, found = .Insert, true
			case 3:
				code, found = .Delete, true
			case 4, 8:
				code, found = .End, true
			case 5:
				code, found = .Page_Up, true
			case 6:
				code, found = .Page_Down, true
			case 11:
				code, found = .F1, true
			case 12:
				code, found = .F2, true
			case 13:
				code, found = .F3, true
			case 14:
				code, found = .F4, true
			case 15:
				code, found = .F5, true
			}
		}
	}
	if found {
		return parser_emit(p, events, Key_Event{code = code}, allocator)
	}
	return parser_emit(p, events, Unknown_Input{}, allocator)
}

parser_first_param :: proc(p: ^Parser) -> int {
	value := 0
	for i in 0 ..< p.param_count {
		c := p.params[i]
		if c >= '0' && c <= '9' {
			value = value * 10 + int(c - '0')
		} else if c == ';' {
			break
		}
	}
	if value == 0 {
		return 1
	}
	return value
}

// parser_osc discards string content (OSC/DCS/APC/PM/SOS) until BEL or an
// ESC terminator; the content is intentionally dropped, not surfaced.
parser_osc :: proc(p: ^Parser, b: u8) -> (consumed: int, err: Error) {
	if b == 0x07 || b == 0x1b {
		parser_reset(p)
	}
	return 1, nil
}
