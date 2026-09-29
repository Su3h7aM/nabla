package input

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

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

// Parser is a caller-owned, pure byte-to-event state machine. It retains
// state across feed calls (a key sequence may span reads) and performs no
// I/O: acquisition feeds byte slices and drains the emitted events. Malformed
// input normalizes to Unknown_Input events and resynchronizes; only resource
// failures are errors.
Parser :: struct {
	state:         Parser_State,
	utf8_expected: int, // remaining UTF-8 continuation bytes
	utf8_bytes:    [4]u8,
	utf8_length:   int,
	// params holds the raw parameter bytes of one CSI/SS3 sequence. An SGR
	// mouse report needs up to 14 bytes ('<' plus three decimal fields with
	// separators), so the buffer is sized for that, not for key sequences.
	params:        [16]u8,
	param_count:   int,
	intermediate:  u8,
	osc_escape:    bool,
	// paste is the scratch for a bracketed paste's raw bytes, allocated with
	// the feed allocator and owned by the parser until parser_destroy. It grows
	// with the paste it is collecting, however large that paste is.
	paste:         [dynamic]u8,
}

parser_init :: proc(parser: ^Parser) {
	parser^ = {}
}

// parser_destroy releases the parser's paste scratch after the last feed.
parser_destroy :: proc(parser: ^Parser) {
	delete(parser.paste)
	parser^ = {}
}

// feed consumes a byte chunk and appends the produced events. A lone ESC
// leaves the parser in the Escape state without emitting; the acquisition
// layer resolves it via parser_escape_pending/parser_resolve_escape after its
// deadline.
@(require_results)
feed :: proc(parser: ^Parser, data: []byte, events: ^[dynamic]Event, allocator := context.allocator) -> (err: Error) {
	for i := 0; i < len(data); {
		consumed: int
		switch parser.state {
		case .Ground:
			consumed, err = parser_ground(parser, data[i], events, allocator)
		case .Utf8:
			consumed, err = parser_utf8(parser, data[i], events, allocator)
		case .Escape:
			consumed, err = parser_escape(parser, data[i], events, allocator)
		case .Csi, .Ss3:
			consumed, err = parser_sequence(parser, data[i], events, allocator)
		case .Paste:
			consumed, err = parser_paste(parser, data[i], events, allocator)
		case .Osc:
			consumed, err = parser_osc(parser, data[i])
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
@(require_results)
parser_escape_pending :: proc(parser: ^Parser) -> bool {
	return parser.state == .Escape
}

// parser_resolve_escape emits an Escape for a lone ESC whose deadline
// expired, then returns to Ground.
@(require_results)
parser_resolve_escape :: proc(parser: ^Parser, events: ^[dynamic]Event, allocator := context.allocator) -> (err: Error) {
	if parser.state != .Escape {
		return nil
	}
	parser_reset(parser)
	return parser_emit(parser, events, Key_Event{code = .Escape}, allocator)
}

parser_reset :: proc(parser: ^Parser) {
	parser.state = .Ground
	parser.utf8_expected = 0
	parser.utf8_length = 0
	parser.param_count = 0
	parser.intermediate = 0
	parser.osc_escape = false
}

@(require_results)
parser_emit :: proc(parser: ^Parser, events: ^[dynamic]Event, event: Event, allocator: runtime.Allocator) -> Error {
	previous := context.allocator
	context.allocator = allocator
	_, err := runtime.append_elem(events, event)
	context.allocator = previous
	return err
}

@(require_results)
parser_ground :: proc(parser: ^Parser, input_byte: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> (consumed: int, err: Error) {
	switch {
	case input_byte == 0x1b:
		parser.state = .Escape
	case input_byte == 0x09:
		err = parser_emit(parser, events, Key_Event{code = .Tab}, allocator)
	case input_byte == 0x0d:
		err = parser_emit(parser, events, Key_Event{code = .Enter}, allocator)
	case input_byte == 0x7f:
		err = parser_emit(parser, events, Key_Event{code = .Backspace}, allocator)
	case input_byte >= 0x01 && input_byte <= 0x1a:
		err = parser_emit(parser, events, Key_Event{code = .Character, character = rune(input_byte), modifiers = {.Control}}, allocator)
	case input_byte >= 0x80:
		expected := 0
		switch {
		case input_byte >= 0xc2 && input_byte <= 0xdf:
			expected = 1
		case input_byte >= 0xe0 && input_byte <= 0xef:
			expected = 2
		case input_byte >= 0xf0 && input_byte <= 0xf4:
			expected = 3
		case:
			err = parser_emit(parser, events, Unknown_Input{}, allocator)
		}
		if expected > 0 {
			parser.utf8_bytes[0] = input_byte
			parser.utf8_length = 1
			parser.state = .Utf8
			parser.utf8_expected = expected
		}
	case input_byte < 0x80:
		err = parser_emit(parser, events, Key_Event{code = .Character, character = rune(input_byte)}, allocator)
	}
	return 1, err
}

@(require_results)
parser_utf8 :: proc(parser: ^Parser, input_byte: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> (consumed: int, err: Error) {
	if input_byte >= 0x80 && input_byte <= 0xbf {
		parser.utf8_bytes[parser.utf8_length] = input_byte
		parser.utf8_length += 1
		parser.utf8_expected -= 1
		if parser.utf8_expected == 0 {
			encoded := string(parser.utf8_bytes[:parser.utf8_length])
			if !utf8.valid_string(encoded) {
				parser_reset(parser)
				return 1, parser_emit(parser, events, Unknown_Input{}, allocator)
			}
			code_point, _ := utf8.decode_rune(encoded)
			parser_reset(parser)
			return 1, parser_emit(parser, events, Key_Event{code = .Character, character = code_point}, allocator)
		}
		return 1, nil
	}
	// Not a continuation byte: the sequence is malformed. Report it, then
	// resynchronize by reprocessing the byte in Ground (consumed = 0).
	parser_reset(parser)
	if unknown_err := parser_emit(parser, events, Unknown_Input{}, allocator); unknown_err != nil {
		return 0, unknown_err
	}
	return 0, nil
}

@(require_results)
parser_escape :: proc(parser: ^Parser, input_byte: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> (consumed: int, err: Error) {
	switch input_byte {
	case 0x1b:
		// ESC ESC: restart the escape sequence.
		return 1, nil
	case '[':
		parser.state = .Csi
		parser.param_count = 0
		parser.intermediate = 0
		return 1, nil
	case 'O':
		parser.state = .Ss3
		parser.param_count = 0
		parser.intermediate = 0
		return 1, nil
	case ']':
		parser.state = .Osc
		return 1, nil
	case:
		// A lone ESC followed by an ordinary byte: emit Escape, then
		// reprocess the byte in Ground (ESC + printable = Escape then key).
		parser.state = .Ground
		if esc_err := parser_emit(parser, events, Key_Event{code = .Escape}, allocator); esc_err != nil {
			return 0, esc_err
		}
		return 0, nil
	}
}

@(require_results)
parser_sequence :: proc(parser: ^Parser, input_byte: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> (consumed: int, err: Error) {
	if input_byte >= 0x30 && input_byte <= 0x3f {
		if parser.param_count < len(parser.params) {
			parser.params[parser.param_count] = input_byte
			parser.param_count += 1
		}
		return 1, nil
	}
	if input_byte >= 0x20 && input_byte <= 0x2f {
		parser.intermediate = input_byte
		return 1, nil
	}
	if input_byte >= 0x40 && input_byte <= 0x7e {
		// Bracketed paste begins here (CSI 200 ~). The parser then collects the
		// raw bytes in parser_paste until CSI 201 ~, so the content is emitted
		// as one Paste event instead of being decoded into keys.
		if parser.state == .Csi && input_byte == '~' && parser_first_param(parser) == 200 {
			if parser.paste == nil {
				parser.paste = make([dynamic]u8, 0, 64, allocator)
			} else {
				clear(&parser.paste)
			}
			parser.state = .Paste
			return 1, nil
		}
		state := parser.state
		final_err := parser_sequence_final(parser, state, input_byte, events, allocator)
		parser_reset(parser)
		return 1, final_err
	}
	if input_byte == 0x1b {
		// ESC inside a sequence: restart at Escape (tcell PR 1053).
		parser.state = .Escape
		return 1, nil
	}
	// A byte outside the sequence alphabet: malformed, resynchronize.
	parser_reset(parser)
	return 1, parser_emit(parser, events, Unknown_Input{}, allocator)
}

@(require_results)
parser_sequence_final :: proc(parser: ^Parser, state: Parser_State, final: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> Error {
	// An SGR mouse report is CSI < Cb ; Cx ; Cy M/m: the leading '<' rides in
	// the parameter bytes and 'M' (press/motion) and 'm' (release) finalize it.
	if state == .Csi && parser.param_count > 0 && parser.params[0] == '<' && (final == 'M' || final == 'm') {
		return parser_mouse_event(parser, final, events, allocator)
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
		param := parser_first_param(parser)
		// Kitty's keyboard protocol reports Enter as CSI 13 ; modifier u.
		// xterm's modifyOtherKeys mode uses CSI 27 ; modifier ; 13 ~.
		if final == 'u' && param == 13 {
			return parser_emit(parser, events, Key_Event{code = .Enter, modifiers = parser_key_modifiers(parser, 1)}, allocator)
		}
		if final == '~' && param == 27 && parser_param(parser, 2) == 13 {
			return parser_emit(parser, events, Key_Event{code = .Enter, modifiers = parser_key_modifiers(parser, 1)}, allocator)
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
		return parser_emit(parser, events, Key_Event{code = code}, allocator)
	}
	return parser_emit(parser, events, Unknown_Input{}, allocator)
}

parser_first_param :: proc(parser: ^Parser) -> int {
	value := parser_param(parser, 0)
	if value == 0 {
		return 1
	}
	return value
}

parser_param :: proc(parser: ^Parser, wanted: int) -> int {
	field := 0
	value := 0
	for i in 0 ..< parser.param_count {
		parameter_byte := parser.params[i]
		if parameter_byte == ';' {
			if field == wanted {
				return value
			}
			field += 1
			value = 0
			continue
		}
		if parameter_byte >= '0' && parameter_byte <= '9' && field == wanted {
			value = value * 10 + int(parameter_byte - '0')
		}
	}
	if field == wanted {
		return value
	}
	return 0
}

parser_key_modifiers :: proc(parser: ^Parser, field: int) -> Key_Modifiers {
	encoded_modifiers := parser_param(parser, field)
	if encoded_modifiers <= 1 {
		return {}
	}
	modifier_bits := encoded_modifiers - 1
	result: Key_Modifiers
	if modifier_bits & 1 != 0 {
		result += {.Shift}
	}
	if modifier_bits & 2 != 0 {
		result += {.Alt}
	}
	if modifier_bits & 4 != 0 {
		result += {.Control}
	}
	if modifier_bits & 8 != 0 {
		result += {.Super}
	}
	return result
}

// parser_mouse_fields splits the parameter bytes of an SGR mouse report (after
// the leading '<') into the protocol's three decimal fields. A field that is
// empty, non-numeric, or beyond three reports failure.
@(require_results)
parser_mouse_fields :: proc(parser: ^Parser) -> (control_byte, x, y: int, ok: bool) {
	field := 0
	value := 0
	digits := false
	for i := 1; i < parser.param_count; i += 1 {
		parameter_byte := parser.params[i]
		switch {
		case parameter_byte >= '0' && parameter_byte <= '9':
			value = value * 10 + int(parameter_byte - '0')
			digits = true
		case parameter_byte == ';':
			if !digits {
				return 0, 0, 0, false
			}
			switch field {
			case 0:
				control_byte = value
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
	return control_byte, x, y, true
}

// parser_mouse_event decodes an SGR mouse report into a Mouse_Event. The
// protocol packs the control into Cb: the low two bits name the button, bit 32
// marks motion with a button held, bit 64 marks the wheel, and bits 4/8/16
// carry shift/alt/ctrl, which pass through the button and wheel masks. A
// report outside the 1002 vocabulary (button 3, hover reports from tracking
// modes this parser never enables) is malformed here and becomes
// Unknown_Input; wheel reports never release.
@(require_results)
parser_mouse_event :: proc(parser: ^Parser, final: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> Error {
	control_byte, x, y, ok := parser_mouse_fields(parser)
	if !ok || x <= 0 || y <= 0 {
		return parser_emit(parser, events, Unknown_Input{}, allocator)
	}
	switch {
	case control_byte & 64 != 0:
		// The wheel block starts at Mouse_Button.Wheel_Up: 64..67 map to 3..6.
		return parser_emit(parser, events, Mouse_Event{button = Mouse_Button((control_byte & 3) + 3), x = x, y = y}, allocator)
	case control_byte & 32 != 0:
		if control_byte & 3 == 3 {
			return parser_emit(parser, events, Unknown_Input{}, allocator)
		}
		return parser_emit(parser, events, Mouse_Event{button = Mouse_Button(control_byte & 3), x = x, y = y, motion = true}, allocator)
	case:
		if control_byte & 3 == 3 {
			return parser_emit(parser, events, Unknown_Input{}, allocator)
		}
		return parser_emit(parser, events, Mouse_Event{button = Mouse_Button(control_byte & 3), x = x, y = y, release = final == 'm'}, allocator)
	}
}

// parser_osc discards string content (OSC/DCS/APC/PM/SOS) until BEL or an
// ESC terminator; the content is intentionally dropped, not surfaced.
@(require_results)
parser_osc :: proc(parser: ^Parser, input_byte: u8) -> (consumed: int, err: Error) {
	if parser.osc_escape {
		if input_byte == '\\' {
			parser_reset(parser)
			return 1, nil
		}
		parser_reset(parser)
		return 0, nil
	}
	if input_byte == 0x07 {
		parser_reset(parser)
	} else if input_byte == 0x1b {
		parser.osc_escape = true
	}
	return 1, nil
}

// parser_paste collects the raw bytes of a bracketed paste after CSI 200 ~ and
// emits one Paste event when the closing CSI 201 ~ arrives. The content is not
// decoded: a paste may contain newlines and escape bytes that must not become
// events. The end marker is matched on the tail of the buffer, so a partial
// marker stays content.
//
// The scratch grows to hold the paste, so a paste of any size is delivered
// whole. A paste whose closing marker never arrives stays in the scratch and is
// dropped with the parser on parser_destroy.
@(require_results)
parser_paste :: proc(parser: ^Parser, input_byte: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> (consumed: int, err: Error) {
	if _, append_err := append(&parser.paste, input_byte); append_err != nil {
		return 1, append_err
	}
	marker_at := len(parser.paste) - len(PASTE_END)
	if input_byte == '~' && marker_at >= 0 && string(parser.paste[marker_at:]) == PASTE_END {
		text, clone_err := strings.clone(string(parser.paste[:marker_at]), allocator)
		if clone_err != nil {
			return 1, clone_err
		}
		clear(&parser.paste)
		parser.state = .Ground
		emit_err := parser_emit(parser, events, Paste{text = text}, allocator)
		if emit_err != nil {
			delete(text, allocator)
		}
		return 1, emit_err
	}
	return 1, nil
}
