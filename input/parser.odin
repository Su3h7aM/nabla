package input

import "base:runtime"
import "core:strings"

Parser_State :: enum u8 {
	Ground,
	Utf8,
	Escape,
	Csi,
	Ss3,
	Osc,
	Paste,
}

// The bracketed-paste end marker (DECSET 2004). The parser matches it on the
// tail of the paste buffer so a partial marker stays content.
PASTE_END :: "\e[201~"

// PASTE_LIMIT bounds one retained paste. It exists so a missing or malformed
// closing marker cannot grow the parser without bound: content that reaches the
// limit is discarded as it arrives and the paste is reported as Unknown_Input.
// Once discarded, the scratch keeps only the tail that can still begin the
// closing marker, so the scan stays linear.
PASTE_LIMIT :: 1 << 20

// Parser is a caller-owned, pure byte-to-event state machine. It retains
// state across feed calls (a key sequence may span reads) and performs no
// I/O: acquisition feeds byte slices and drains the emitted events. Malformed
// input normalizes to Unknown_Input events and resynchronizes; only resource
// failures are errors.
Parser :: struct {
	state:            Parser_State,
	utf8_expected:    int, // remaining UTF-8 continuation bytes
	utf8_pending:     u32, // accumulated code point bits
	// params holds the raw parameter bytes of one CSI/SS3 sequence. An SGR
	// mouse report needs up to 14 bytes ('<' plus three decimal fields with
	// separators), so the buffer is sized for that, not for key sequences.
	params:           [16]u8,
	param_count:      int,
	intermediate:     u8,
	// paste is the scratch for a bracketed paste's raw bytes, allocated with
	// the feed allocator and owned by the parser until parser_destroy.
	paste:            [dynamic]u8,
	// paste_overflowed marks a paste past PASTE_LIMIT: its content is being
	// discarded, and the closing marker yields Unknown_Input instead of Paste.
	paste_overflowed: bool,
}

parser_init :: proc(p: ^Parser) {
	p^ = {}
}

// parser_destroy releases the parser's paste scratch after the last feed.
parser_destroy :: proc(p: ^Parser) {
	delete(p.paste)
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
		case .Paste:
			consumed, err = parser_paste(p, data[i], events, allocator)
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
		// Bracketed paste begins here (CSI 200 ~). The parser then collects the
		// raw bytes in parser_paste until CSI 201 ~, so the content is emitted
		// as one Paste event instead of being decoded into keys.
		if p.state == .Csi && b == '~' && parser_first_param(p) == 200 {
			if p.paste == nil {
				p.paste = make([dynamic]u8, 0, 64, allocator)
			} else {
				clear(&p.paste)
			}
			p.paste_overflowed = false
			p.state = .Paste
			return 1, nil
		}
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
	// An SGR mouse report is CSI < Cb ; Cx ; Cy M/m: the leading '<' rides in
	// the parameter bytes and 'M' (press/motion) and 'm' (release) finalize it.
	if state == .Csi && p.param_count > 0 && p.params[0] == '<' && (final == 'M' || final == 'm') {
		return parser_mouse_event(p, final, events, allocator)
	}
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
		// Kitty's keyboard protocol reports Enter as CSI 13 ; modifier u.
		// xterm's modifyOtherKeys mode uses CSI 27 ; modifier ; 13 ~.
		if final == 'u' && param == 13 {
			return parser_emit(p, events, Key_Event{code = .Enter, modifiers = parser_key_modifiers(p, 1)}, allocator)
		}
		if final == '~' && param == 27 && parser_param(p, 2) == 13 {
			return parser_emit(p, events, Key_Event{code = .Enter, modifiers = parser_key_modifiers(p, 1)}, allocator)
		}
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
	value := parser_param(p, 0)
	if value == 0 { return 1 }
	return value
}

parser_param :: proc(p: ^Parser, wanted: int) -> int {
	field := 0
	value := 0
	for i in 0 ..< p.param_count {
		c := p.params[i]
		if c == ';' {
			if field == wanted { return value }
			field += 1
			value = 0
			continue
		}
		if c >= '0' && c <= '9' && field == wanted {
			value = value * 10 + int(c - '0')
		}
	}
	if field == wanted { return value }
	return 0
}

parser_key_modifiers :: proc(p: ^Parser, field: int) -> Key_Modifiers {
	encoded := parser_param(p, field)
	if encoded <= 1 { return {} }
	bits := encoded - 1
	result: Key_Modifiers
	if bits & 1 != 0 { result += {.Shift} }
	if bits & 2 != 0 { result += {.Alt} }
	if bits & 4 != 0 { result += {.Control} }
	if bits & 8 != 0 { result += {.Super} }
	return result
}

// parser_mouse_fields splits the parameter bytes of an SGR mouse report (after
// the leading '<') into the protocol's three decimal fields. A field that is
// empty, non-numeric, or beyond three reports failure.
parser_mouse_fields :: proc(p: ^Parser) -> (cb, x, y: int, ok: bool) {
	field := 0
	value := 0
	digits := false
	for i := 1; i < p.param_count; i += 1 {
		c := p.params[i]
		switch {
		case c >= '0' && c <= '9':
			value = value * 10 + int(c - '0')
			digits = true
		case c == ';':
			if !digits {
				return 0, 0, 0, false
			}
			switch field {
			case 0:
				cb = value
			case 1:
				x = value
			case:
				return 0, 0, 0, false
			}
			field += 1
			value = 0
			digits = false
		case:
			return 0, 0, 0, false
		}
	}
	if field != 2 || !digits {
		return 0, 0, 0, false
	}
	y = value
	return cb, x, y, true
}

// parser_mouse_event decodes an SGR mouse report into a Mouse_Event. The
// protocol packs the control into Cb: the low two bits name the button, bit 32
// marks motion with a button held, bit 64 marks the wheel, and bits 4/8/16
// carry shift/alt/ctrl, which pass through the button and wheel masks. A
// report outside the 1002 vocabulary (button 3, hover reports from tracking
// modes this parser never enables) is malformed here and becomes
// Unknown_Input; wheel reports never release.
parser_mouse_event :: proc(p: ^Parser, final: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> Error {
	cb, x, y, ok := parser_mouse_fields(p)
	if !ok || x <= 0 || y <= 0 {
		return parser_emit(p, events, Unknown_Input{}, allocator)
	}
	switch {
	case cb & 64 != 0:
		// The wheel block starts at Mouse_Button.Wheel_Up: 64..67 map to 3..6.
		return parser_emit(p, events, Mouse_Event{button = Mouse_Button((cb & 3) + 3), x = x, y = y}, allocator)
	case cb & 32 != 0:
		if cb & 3 == 3 {
			return parser_emit(p, events, Unknown_Input{}, allocator)
		}
		return parser_emit(p, events, Mouse_Event{button = Mouse_Button(cb & 3), x = x, y = y, motion = true}, allocator)
	case:
		if cb & 3 == 3 {
			return parser_emit(p, events, Unknown_Input{}, allocator)
		}
		return parser_emit(p, events, Mouse_Event{button = Mouse_Button(cb & 3), x = x, y = y, release = final == 'm'}, allocator)
	}
}

// parser_osc discards string content (OSC/DCS/APC/PM/SOS) until BEL or an
// ESC terminator; the content is intentionally dropped, not surfaced.
parser_osc :: proc(p: ^Parser, b: u8) -> (consumed: int, err: Error) {
	if b == 0x07 || b == 0x1b {
		parser_reset(p)
	}
	return 1, nil
}

// parser_paste collects the raw bytes of a bracketed paste after CSI 200 ~ and
// emits one Paste event when the closing CSI 201 ~ arrives. The content is not
// decoded: a paste may contain newlines and escape bytes that must not become
// events. The end marker is matched on the tail of the buffer, so a partial
// marker stays content.
//
// A paste past PASTE_LIMIT is discarded as it arrives and reported as
// Unknown_Input. Once discarded, the scratch keeps only the tail that can still
// start the marker, so a large paste costs linear time instead of shifting the
// whole payload per byte. A paste whose marker never arrives is dropped with
// the parser on parser_destroy.
parser_paste :: proc(p: ^Parser, b: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> (consumed: int, err: Error) {
	if p.paste_overflowed {
		_paste_keep_tail(&p.paste)
	}
	if _, append_err := append(&p.paste, b); append_err != nil {
		return 1, append_err
	}
	// Match the marker before discarding, so a paste that ends exactly at the
	// limit still closes.
	marker_at := len(p.paste) - len(PASTE_END)
	if b == '~' && marker_at >= 0 && string(p.paste[marker_at:]) == PASTE_END {
		if p.paste_overflowed {
			clear(&p.paste)
			p.paste_overflowed = false
			p.state = .Ground
			return 1, parser_emit(p, events, Unknown_Input{}, allocator)
		}
		text, clone_err := strings.clone(string(p.paste[:marker_at]), allocator)
		if clone_err != nil {
			return 1, clone_err
		}
		clear(&p.paste)
		p.state = .Ground
		emit_err := parser_emit(p, events, Paste{text = text}, allocator)
		if emit_err != nil {
			delete(text, allocator)
		}
		return 1, emit_err
	}
	if len(p.paste) > PASTE_LIMIT {
		p.paste_overflowed = true
	}
	if p.paste_overflowed {
		_paste_keep_tail(&p.paste)
	}
	return 1, nil
}

// _paste_keep_tail shrinks the paste scratch to the bytes that can still begin
// the closing marker, so discarded content is neither carried nor shifted.
_paste_keep_tail :: proc(paste: ^[dynamic]u8) {
	keep := len(PASTE_END) - 1
	if len(paste^) <= keep {
		return
	}
	copy(paste[:], paste[len(paste^) - keep:])
	resize(paste, keep)
}
