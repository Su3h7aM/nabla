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
	Paste,
}

// The bracketed-paste end marker (DECSET 2004). The parser matches it on the
// tail of the paste buffer so a partial marker stays content.
PASTE_END :: "\e[201~"

// PARAMS_CAPACITY fits the longest sequence decoded: a kitty key with alternates, modifiers and
// event kind, or an SGR mouse report with wide coordinates.
PARAMS_CAPACITY :: 32

// PARAM_LIMIT saturates a decimal parameter so a long digit run cannot overflow int.
PARAM_LIMIT :: 1 << 24

// Parser is a caller-owned, pure byte-to-event state machine. It retains
// state across feed calls (a key sequence may span reads) and performs no
// I/O: acquisition feeds byte slices and drains the emitted events. Malformed
// input normalizes to Unknown_Input events and resynchronizes; only resource
// failures are errors.
Parser :: struct {
	state:           Parser_State,
	utf8_expected:   int, // remaining UTF-8 continuation bytes
	utf8_bytes:      [4]u8,
	utf8_length:     int,
	// params holds the raw parameter bytes of one CSI/SS3 sequence. A byte
	// that does not fit sets params_overflow and the sequence becomes
	// Unknown_Input, so a truncated parameter list is never decoded.
	params:          [PARAMS_CAPACITY]u8,
	param_count:     int,
	params_overflow: bool,
	intermediate:    u8,
	// paste is the scratch for a bracketed paste's raw bytes, allocated with
	// the feed allocator and owned by the parser until parser_destroy. It grows
	// with the paste it is collecting, however large that paste is.
	paste:           [dynamic]u8,
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
	return parser_emit(events, Key_Event{code = .Escape}, allocator)
}

parser_reset :: proc(parser: ^Parser) {
	parser.state = .Ground
	parser.utf8_expected = 0
	parser.utf8_length = 0
	parser.param_count = 0
	parser.params_overflow = false
	parser.intermediate = 0
}

@(require_results)
parser_emit :: proc(events: ^[dynamic]Event, event: Event, allocator: runtime.Allocator) -> Error {
	context.allocator = allocator
	_, err := append(events, event)
	return err
}

@(require_results)
parser_ground :: proc(parser: ^Parser, input_byte: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> (consumed: int, err: Error) {
	switch {
	case input_byte == 0x1b:
		parser.state = .Escape
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
			err = parser_emit(events, Unknown_Input{}, allocator)
		}
		if expected > 0 {
			parser.utf8_bytes[0] = input_byte
			parser.utf8_length = 1
			parser.state = .Utf8
			parser.utf8_expected = expected
		}
	case:
		err = parser_emit(events, parser_key_from_byte(input_byte), allocator)
	}
	return 1, err
}

// parser_key_from_byte maps a single input byte below 0x80, other than ESC, to its key. Tab, Enter
// and Backspace keep their own codes; the other control bytes are the letter or digit they are typed
// with, plus Control.
parser_key_from_byte :: proc(input_byte: u8) -> Key_Event {
	switch {
	case input_byte == 0x09:
		return {code = .Tab}
	case input_byte == 0x0d:
		return {code = .Enter}
	case input_byte == 0x7f:
		return {code = .Backspace}
	case input_byte == 0x00:
		return {code = .Character, character = ' ', modifiers = {.Control}}
	case input_byte <= 0x1a:
		return {code = .Character, character = 'a' + rune(input_byte - 1), modifiers = {.Control}}
	case input_byte >= 0x1c && input_byte <= 0x1f:
		return {code = .Character, character = '4' + rune(input_byte - 0x1c), modifiers = {.Control}}
	}
	return {code = .Character, character = rune(input_byte)}
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
				return 1, parser_emit(events, Unknown_Input{}, allocator)
			}
			code_point, _ := utf8.decode_rune(encoded)
			parser_reset(parser)
			return 1, parser_emit(events, Key_Event{code = .Character, character = code_point}, allocator)
		}
		return 1, nil
	}
	// Not a continuation byte: the sequence is malformed. Report it, then
	// resynchronize by reprocessing the byte in Ground (consumed = 0).
	parser_reset(parser)
	if unknown_err := parser_emit(events, Unknown_Input{}, allocator); unknown_err != nil {
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
		parser_begin_sequence(parser, .Csi)
		return 1, nil
	case 'O':
		parser_begin_sequence(parser, .Ss3)
		return 1, nil
	case 0x20 ..= 0x7f, 0x09, 0x0d:
		key := parser_key_from_byte(input_byte)
		key.modifiers += {.Alt}
		parser.state = .Ground
		return 1, parser_emit(events, key, allocator)
	case:
		// ESC before a control or non-ASCII byte: emit Escape, then
		// reprocess the byte in Ground.
		parser.state = .Ground
		if esc_err := parser_emit(events, Key_Event{code = .Escape}, allocator); esc_err != nil {
			return 0, esc_err
		}
		return 0, nil
	}
}

parser_begin_sequence :: proc(parser: ^Parser, state: Parser_State) {
	parser_reset(parser)
	parser.state = state
}

@(require_results)
parser_sequence :: proc(parser: ^Parser, input_byte: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> (consumed: int, err: Error) {
	if input_byte >= 0x30 && input_byte <= 0x3f {
		if parser.param_count < len(parser.params) {
			parser.params[parser.param_count] = input_byte
			parser.param_count += 1
		} else {
			parser.params_overflow = true
		}
		return 1, nil
	}
	if input_byte >= 0x20 && input_byte <= 0x2f {
		parser.intermediate = input_byte
		return 1, nil
	}
	if input_byte >= 0x40 && input_byte <= 0x7e {
		if parser.state == .Csi && input_byte == '~' && parser_param(parser, 0) == 200 {
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
	return 1, parser_emit(events, Unknown_Input{}, allocator)
}

@(require_results)
parser_sequence_final :: proc(parser: ^Parser, state: Parser_State, final: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> Error {
	if parser.params_overflow || parser.intermediate != 0 {
		return parser_emit(events, Unknown_Input{}, allocator)
	}
	// A leading '<', '=', '>' or '?' marks a private sequence (mouse, replies), never a key.
	private := parser.param_count > 0 && parser.params[0] >= '<' && parser.params[0] <= '?'
	if state == .Csi && parser.param_count > 0 && parser.params[0] == '<' && (final == 'M' || final == 'm') {
		return parser_mouse_event(parser, final, events, allocator)
	}
	key: Key_Event
	found: bool
	if !private {
		if state == .Csi {
			key, found = parser_csi_key(parser, final)
		} else {
			key, found = parser_ss3_key(parser, final)
		}
	}
	if !found {
		return parser_emit(events, Unknown_Input{}, allocator)
	}
	return parser_emit(events, key, allocator)
}

// parser_letter_key maps the final bytes that name a key without a number, shared by CSI and SS3.
parser_letter_key :: proc(final: u8) -> (code: Key_Code, ok: bool) {
	switch final {
	case 'A':
		return .Up, true
	case 'B':
		return .Down, true
	case 'C':
		return .Right, true
	case 'D':
		return .Left, true
	case 'H':
		return .Home, true
	case 'F':
		return .End, true
	case 'P':
		return .F1, true
	case 'Q':
		return .F2, true
	case 'R':
		return .F3, true
	case 'S':
		return .F4, true
	}
	return {}, false
}

// parser_tilde_key maps the number of a `CSI number ~` key.
parser_tilde_key :: proc(number: int) -> (code: Key_Code, ok: bool) {
	switch number {
	case 1, 7:
		return .Home, true
	case 2:
		return .Insert, true
	case 3:
		return .Delete, true
	case 4, 8:
		return .End, true
	case 5:
		return .Page_Up, true
	case 6:
		return .Page_Down, true
	case 11:
		return .F1, true
	case 12:
		return .F2, true
	case 13:
		return .F3, true
	case 14:
		return .F4, true
	case 15:
		return .F5, true
	case 17:
		return .F6, true
	case 18:
		return .F7, true
	case 19:
		return .F8, true
	case 20:
		return .F9, true
	case 21:
		return .F10, true
	case 23:
		return .F11, true
	case 24:
		return .F12, true
	}
	return {}, false
}

// parser_ss3_key decodes ESC O [modifiers] final; xterm puts the modifier before the final byte.
parser_ss3_key :: proc(parser: ^Parser, final: u8) -> (key: Key_Event, ok: bool) {
	key.code = parser_letter_key(final) or_return
	key.modifiers = parser_key_modifiers(parser, 0)
	key.kind = parser_key_kind(parser, 0)
	return key, true
}

// parser_csi_key decodes a CSI key: `CSI [1;modifiers[:kind]] final`, `CSI number[;modifiers[:kind]] ~`,
// `CSI Z`, and the kitty form handled by parser_kitty_key.
parser_csi_key :: proc(parser: ^Parser, final: u8) -> (key: Key_Event, ok: bool) {
	number := parser_param(parser, 0)
	switch final {
	case 'Z':
		return {code = .Tab, modifiers = {.Shift}}, true
	case 'u':
		return parser_kitty_key(parser)
	case '~':
		if number == 27 && parser_param(parser, 2) == 13 {
			// xterm modifyOtherKeys: CSI 27 ; modifiers ; 13 ~.
			return {code = .Enter, modifiers = parser_key_modifiers(parser, 1)}, true
		}
		key.code = parser_tilde_key(number) or_return
	case:
		key.code = parser_letter_key(final) or_return
	}
	key.modifiers = parser_key_modifiers(parser, 1)
	key.kind = parser_key_kind(parser, 1)
	return key, true
}

// parser_kitty_key decodes the kitty keyboard protocol form
// `CSI code[:shifted[:base]] ; modifiers[:kind] [; text] u`. With Shift held, the shifted alternate
// is the character and Shift is dropped, matching how a legacy terminal reports typed text. The text
// field and the base alternate are ignored.
parser_kitty_key :: proc(parser: ^Parser) -> (key: Key_Event, ok: bool) {
	code := parser_param(parser, 0)
	key.modifiers = parser_key_modifiers(parser, 1)
	key.kind = parser_key_kind(parser, 1)
	switch code {
	case 9:
		key.code = .Tab
	case 13:
		key.code = .Enter
	case 27:
		key.code = .Escape
	case 127:
		key.code = .Backspace
	case:
		key.code = .Character
		key.character = parser_kitty_character(code) or_return
		if shifted := parser_param(parser, 0, 1); .Shift in key.modifiers && shifted != 0 {
			key.character = parser_kitty_character(shifted) or_return
			key.modifiers -= {.Shift}
		}
	}
	return key, true
}

// parser_kitty_character accepts a printable code point and rejects the private-use block kitty
// uses for keys that have no character, such as modifier and media keys.
parser_kitty_character :: proc(code: int) -> (character: rune, ok: bool) {
	if code < 0x20 || code == 0x7f || code >= 0xe000 && code <= 0xf8ff || utf8.rune_size(rune(code)) < 0 {
		return 0, false
	}
	return rune(code), true
}

// parser_param returns the decimal value of one parameter: `field` counts ';' separators and `sub`
// counts ':' separators within the field. A missing or empty parameter is 0.
parser_param :: proc(parser: ^Parser, field: int, sub := 0) -> int {
	field_index, sub_index, value := 0, 0, 0
	for parameter_byte in parser.params[:parser.param_count] {
		switch {
		case parameter_byte == ';' || parameter_byte == ':':
			if field_index == field && sub_index == sub {
				return value
			}
			if parameter_byte == ';' {
				field_index += 1
				sub_index = 0
			} else {
				sub_index += 1
			}
			value = 0
		case parameter_byte >= '0' && parameter_byte <= '9':
			value = min(value * 10 + int(parameter_byte - '0'), PARAM_LIMIT)
		}
	}
	if field_index == field && sub_index == sub {
		return value
	}
	return 0
}

// parser_key_modifiers decodes the xterm modifier parameter, which is 1 plus the modifier bits.
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

parser_key_kind :: proc(parser: ^Parser, field: int) -> Key_Kind {
	switch parser_param(parser, field, 1) {
	case 2:
		return .Repeat
	case 3:
		return .Release
	}
	return .Press
}

// parser_mouse_fields splits an SGR mouse report into its three decimal fields.
@(require_results)
parser_mouse_fields :: proc(parser: ^Parser) -> (control_byte, x, y: int, ok: bool) {
	field := 0
	value := 0
	digits := false
	for i := 1; i < parser.param_count; i += 1 {
		parameter_byte := parser.params[i]
		switch {
		case parameter_byte >= '0' && parameter_byte <= '9':
			value = min(value * 10 + int(parameter_byte - '0'), PARAM_LIMIT)
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

// parser_mouse_event decodes an SGR mouse report into a Mouse_Event. Bits 4, 8 and 16 are the
// modifiers, 32 marks motion, and 64 the wheel block; any other bit (buttons 8 and above) is
// Unknown_Input.
@(require_results)
parser_mouse_event :: proc(parser: ^Parser, final: u8, events: ^[dynamic]Event, allocator: runtime.Allocator) -> Error {
	MOUSE_KNOWN_BITS :: 3 | 4 | 8 | 16 | 32 | 64
	control_byte, x, y, ok := parser_mouse_fields(parser)
	if !ok || x <= 0 || y <= 0 || control_byte & ~int(MOUSE_KNOWN_BITS) != 0 {
		return parser_emit(events, Unknown_Input{}, allocator)
	}
	mouse := Mouse_Event {
		x = x,
		y = y,
	}
	if control_byte & 4 != 0 {
		mouse.modifiers += {.Shift}
	}
	if control_byte & 8 != 0 {
		mouse.modifiers += {.Alt}
	}
	if control_byte & 16 != 0 {
		mouse.modifiers += {.Control}
	}
	low_bits := control_byte & 3
	switch {
	case control_byte & 64 != 0:
		// The wheel block follows Mouse_Button.Right: 64..67 map to Wheel_Up..Wheel_Right.
		mouse.button = Mouse_Button(low_bits + int(Mouse_Button.Wheel_Up))
	case control_byte & 32 != 0:
		mouse.motion = true
		if low_bits != 3 {
			mouse.button = Mouse_Button(low_bits + int(Mouse_Button.Left))
		}
	case low_bits == 3:
		return parser_emit(events, Unknown_Input{}, allocator)
	case:
		mouse.button = Mouse_Button(low_bits + int(Mouse_Button.Left))
		mouse.release = final == 'm'
	}
	return parser_emit(events, mouse, allocator)
}

// parser_paste collects a bracketed paste and emits one Paste event at the closing marker.
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
		emit_err := parser_emit(events, Paste{text = text}, allocator)
		if emit_err != nil {
			delete(text, allocator)
		}
		return 1, emit_err
	}
	return 1, nil
}
