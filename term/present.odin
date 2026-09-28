package term

import "core:terminal/ansi"
import "core:unicode/utf8"

// Frame encoding and presentation.
//
// The output path is caller-owned and reusable: the caller keeps one byte
// scratch, asks encoded_size for the exact required count, and calls encode
// (pure serialization) or present (serialize + one buffered write). No
// procedure allocates or retains output. encoded_size and encode share one
// validation and sizing pass, so a too-small scratch is observable through
// the exact required return before anything is written.
//
// Serialization establishes the Presentation Baseline (cursor origin +
// explicit base style) before any cell output, overwrites the viewport
// without a preliminary clear, reduces authored colors deterministically to
// the profile's color depth (TrueColor as authored, 256 via the xterm cube,
// 16/8 via the nearest ANSI entry, None drops colors), writes the full
// logical frame including the bottom-right cell (the session disables
// autowrap so the corner is safe), and restores the base SGR state at the
// end.
//
// A hard write failure may occur after a prefix has reached the terminal;
// terminal contents and cursor state are then unspecified. The caller
// recovers with a later successful full frame or by closing the session.
// There is no transactional acceptance: bytes already consumed by the
// terminal cannot be undone.

@(require_results)
encoded_size :: proc(buffer: Frame_Buffer, profile: Target_Profile, cursor: Cursor) -> (required: int, err: Error) {
	if validation_error := _validate_frame(buffer, cursor); validation_error != nil {
		return 0, validation_error
	}
	if buffer.columns == 0 || buffer.rows == 0 {
		// Zero-sized frame: deterministic no-op success.
		return 0, nil
	}
	encoder := _Encoder {
		count_only = true,
	}
	_serialize(&encoder, buffer, profile, cursor)
	return encoder.pos, nil
}

// encode serializes the frame into caller-owned output. It returns written
// (the bytes to consume: output[:written]) and repeats the exact required
// count. A too-small scratch returns .Presentation_Workspace_Too_Small with
// written == 0 and nothing usable written; the caller resizes and retries,
// never guessing.
@(require_results)
encode :: proc(buffer: Frame_Buffer, profile: Target_Profile, cursor: Cursor, output: []byte) -> (written: int, required: int, err: Error) {
	if validation_error := _validate_frame(buffer, cursor); validation_error != nil {
		return 0, 0, validation_error
	}
	if buffer.columns == 0 || buffer.rows == 0 {
		return 0, 0, nil
	}
	encoder := _Encoder {
		count_only = true,
	}
	_serialize(&encoder, buffer, profile, cursor)
	required = encoder.pos
	if required > len(output) {
		return 0, required, General_Error.Presentation_Workspace_Too_Small
	}
	writer := _Encoder {
		out = output,
	}
	_serialize(&writer, buffer, profile, cursor)
	if writer.overflowed {
		// Unreachable: the count pass just produced the exact size.
		return 0, required, General_Error.Presentation_Workspace_Too_Small
	}
	return writer.pos, required, nil
}

// present performs the same preflight as encode and never touches the
// session when the scratch is too small; on success it writes the encoded
// frame as one buffered sequence and returns the number of bytes committed
// before any transport failure.
@(require_results)
present :: proc(
	session: ^Session,
	buffer: Frame_Buffer,
	profile: Target_Profile,
	cursor: Cursor,
	output: []byte,
) -> (
	committed: int,
	required: int,
	err: Error,
) {
	if session == nil || !session.opened {
		return 0, 0, General_Error.Not_Open
	}
	if validation_error := _validate_frame(buffer, cursor); validation_error != nil {
		return 0, 0, validation_error
	}
	if buffer.columns == 0 || buffer.rows == 0 {
		return 0, 0, nil
	}
	encoder := _Encoder {
		count_only = true,
	}
	_serialize(&encoder, buffer, profile, cursor)
	required = encoder.pos
	if required > len(output) {
		return 0, required, General_Error.Presentation_Workspace_Too_Small
	}
	writer := _Encoder {
		out = output,
	}
	_serialize(&writer, buffer, profile, cursor)
	if writer.overflowed {
		return 0, required, General_Error.Presentation_Workspace_Too_Small
	}
	committed_bytes, write_err := _session_present(session, output[:required])
	return committed_bytes, required, write_err
}

// _validate_frame checks every frame invariant before a single byte is
// serialized or written: dimensions, logical cell count, width, grapheme
// safety, and cursor bounds. A zero-sized frame is a deterministic no-op
// (nil error) unless the cursor intent is invalid.
_validate_frame :: proc(buffer: Frame_Buffer, cursor: Cursor) -> Error {
	if buffer.columns < 0 || buffer.rows < 0 {
		return General_Error.Invalid_Frame_Data
	}
	if cursor.placed {
		if cursor.position.x < 0 || cursor.position.y < 0 || cursor.position.x >= buffer.columns || cursor.position.y >= buffer.rows {
			return General_Error.Invalid_Cursor
		}
	}
	if buffer.columns == 0 || buffer.rows == 0 {
		return nil
	}
	// Division form: columns * rows could overflow int on hostile
	// dimensions and slip past a product check, then index out of bounds.
	if buffer.columns > len(buffer.cells) / buffer.rows {
		return General_Error.Invalid_Frame_Data
	}
	for i in 0 ..< buffer.columns * buffer.rows {
		cell := buffer.cells[i]
		column := i % buffer.columns
		switch cell.width {
		case 0:
			// A zero-width cell is the placeholder a wide cell needs and must
			// carry no text: emitting it would advance the cursor past the
			// wide cluster's second column.
			if i == 0 || buffer.cells[i - 1].width != 2 {
				return General_Error.Unsupported
			}
			if len(cell.grapheme) != 0 {
				return General_Error.Invalid_Cell
			}
		case 1:
			if len(cell.grapheme) > 0 && !_grapheme_safe(cell.grapheme) {
				return General_Error.Invalid_Cell
			}
		case 2:
			// A wide cell spans two physical columns. It needs room for its
			// placeholder (checked before indexing i + 1). There is no
			// corner exception: the session disables autowrap, so the
			// bottom-right cell is written and a wide cell may span it.
			if column >= buffer.columns - 1 {
				return General_Error.Unsupported
			}
			if buffer.cells[i + 1].width != 0 {
				return General_Error.Unsupported
			}
			if len(cell.grapheme) == 0 || !_grapheme_safe(cell.grapheme) {
				return General_Error.Invalid_Cell
			}
		case:
			return General_Error.Unsupported
		}
	}
	return nil
}

// _grapheme_safe accepts exactly the graphemes the frame contract allows: a
// non-empty grapheme must be valid UTF-8 and contain no C0 control, DEL, or
// C1 control code point. ESC is rejected both as a byte and as U+001B, so a
// cell can never inject terminal control into the output stream.
_grapheme_safe :: proc(grapheme: string) -> bool {
	if !utf8.valid_string(grapheme) {
		return false
	}
	for i := 0; i < len(grapheme); {
		code_point, width := utf8.decode_rune(grapheme[i:])
		if code_point < 0x20 || code_point == 0x7f || (code_point >= 0x80 && code_point <= 0x9f) {
			return false
		}
		i += width
	}
	return true
}

// _Encoder writes serialization bytes into caller-owned storage. count_only
// mode sizes the exact required byte count without touching the output, so
// encoded_size, encode, and present share one emission implementation.
_Encoder :: struct {
	out:        []byte,
	pos:        int,
	count_only: bool,
	overflowed: bool,
}

_encoder_write :: proc(encoder: ^_Encoder, bytes: []byte) {
	if encoder.count_only {
		encoder.pos += len(bytes)
		return
	}
	if encoder.pos + len(bytes) > len(encoder.out) {
		// Defensive: callers preflight with the count pass, so this is
		// unreachable in normal operation.
		encoder.overflowed = true
		return
	}
	copy(encoder.out[encoder.pos:], bytes)
	encoder.pos += len(bytes)
}

_encoder_write_text :: proc(encoder: ^_Encoder, text: string) {
	_encoder_write(encoder, transmute([]byte)text)
}

_encoder_write_byte :: proc(encoder: ^_Encoder, value: u8) {
	one := [1]u8{value}
	_encoder_write(encoder, one[:])
}

// _encoder_write_uint writes the decimal form of a nonnegative value. The parameter is
// u64 so the complete nonnegative int domain is representable (a CUP
// coordinate of max(int) needs the +1 computed in the unsigned domain, where
// max(int) + 1 == 2^63 fits). Callers validate nonnegativity before
// encoding; a negative int passed through is a caller bug, not this proc's
// contract.
_encoder_write_uint :: proc(encoder: ^_Encoder, value: u64) {
	// Decimal digits for the complete u64 domain: max(u64) is 20 digits, so
	// size_of(u64) * 3 bytes is always enough.
	digits: [size_of(u64) * 3]u8
	digit_count := 0
	if value == 0 {
		_encoder_write_byte(encoder, '0')
		return
	}
	remaining := value
	for remaining > 0 {
		digits[digit_count] = u8('0' + remaining % 10)
		remaining /= 10
		digit_count += 1
	}
	for digit_count > 0 {
		digit_count -= 1
		_encoder_write_byte(encoder, digits[digit_count])
	}
}

// _serialize renders the (validated) frame to the ANSI byte stream. The fixed
// sequences come from core:terminal/ansi; the numeric ones (SGR parameters,
// CUP coordinates) are composed here because the encoder owns their exact
// byte layout.
_serialize :: proc(encoder: ^_Encoder, buffer: Frame_Buffer, profile: Target_Profile, cursor: Cursor) {
	// Baseline: cursor origin + explicit base style. The frame overwrites the
	// viewport without a preliminary clear (framework contract); the
	// unconditional SGR reset prevents stale attributes from a previous frame.
	_encoder_write_text(encoder, ansi.CSI + ansi.CUP + ansi.CSI + ansi.SGR)
	previous_style: Style

	for y in 0 ..< buffer.rows {
		// Per-row cursor positioning. CUP does not reset SGR attributes, so
		// the diff carries the previous row's last style into the next row —
		// a default cell after a styled row end emits its own reset.
		_encoder_write_text(encoder, ansi.CSI)
		_encoder_write_uint(encoder, u64(y) + 1)
		_encoder_write_text(encoder, ";1" + ansi.CUP)

		for x in 0 ..< buffer.columns {
			index := y * buffer.columns + x
			_encoder_write_cell(encoder, buffer.cells[index], &previous_style, profile.color_depth)
		}
	}

	// Position first, then visibility: showing after the move keeps a
	// terminal from rendering a frame at the stale position.
	if cursor.placed {
		_encoder_write_text(encoder, ansi.CSI)
		_encoder_write_uint(encoder, u64(cursor.position.y) + 1)
		_encoder_write_text(encoder, ";")
		_encoder_write_uint(encoder, u64(cursor.position.x) + 1)
		_encoder_write_text(encoder, ansi.CUP)
	}
	if cursor.visible {
		_encoder_write_text(encoder, ansi.CSI + ansi.DECTCEM_SHOW)
	} else {
		_encoder_write_text(encoder, ansi.CSI + ansi.DECTCEM_HIDE)
	}

	// Restore the base style at the end of the frame (baseline contract).
	_encoder_write_text(encoder, ansi.CSI + ansi.SGR)
}

_encoder_write_cell :: proc(encoder: ^_Encoder, cell: Cell, previous: ^Style, depth: Color_Depth) {
	_encoder_style_diff(encoder, previous^, cell.style, depth)
	previous^ = cell.style
	_encoder_write_text(encoder, cell.grapheme)
}

// _encoder_style_establish resets to the base rendition and applies `style` from
// scratch. It is called on every style change.
_encoder_style_establish :: proc(encoder: ^_Encoder, style: Style, depth: Color_Depth) {
	_encoder_write_text(encoder, ansi.CSI + ansi.SGR)
	if style != (Style{}) {
		for modifier in Modifier {
			if modifier in style.modifiers {
				_encoder_write_text(encoder, ansi.CSI)
				_encoder_write_uint(encoder, u64(_modifier_sgr(modifier)))
				_encoder_write_text(encoder, ansi.SGR)
			}
		}
		_encoder_write_color(encoder, 38, style.foreground, depth)
		_encoder_write_color(encoder, 48, style.background, depth)
	}
}

_encoder_style_diff :: proc(encoder: ^_Encoder, previous_style, next_style: Style, depth: Color_Depth) {
	// SGR diff: the whole style is emitted only when it changes. The
	// baseline \e[m already reset at frame start, so an unchanged style
	// needs nothing — a style run is one SGR group, not one per cell.
	if previous_style != next_style {
		_encoder_style_establish(encoder, next_style, depth)
	}
}

_modifier_sgr :: proc(modifier: Modifier) -> u8 {
	switch modifier {
	case .Bold:
		return 1
	case .Dim:
		return 2
	case .Italic:
		return 3
	case .Underline:
		return 4
	case .Strikethrough:
		return 9
	case .Reverse:
		return 7
	}
	return 0
}

_encoder_write_color :: proc(encoder: ^_Encoder, prefix: u8, color: Color, depth: Color_Depth) {
	// Depth reduction is deterministic: TrueColor as authored, 256 via the
	// xterm cube, 16/8 via the nearest ANSI entry, None drops colors.
	if depth == .None {
		return
	}
	switch color_value in color {
	case Default_Color:
	// No-op: the SGR reset already set defaults.
	case Indexed_Color:
		index := u8(color_value)
		switch depth {
		case .True_Color, .Eight_Bit:
			_encoder_write_text(encoder, ansi.CSI)
			_encoder_write_uint(encoder, u64(prefix))
			_encoder_write_text(encoder, ";5;")
			_encoder_write_uint(encoder, u64(index))
			_encoder_write_text(encoder, ansi.SGR)
		case .Four_Bit:
			// Decode the xterm-256 index (ANSI/cube/grayscale) to RGB, then
			// reduce to the nearest 16-color entry — never a modulo wrap
			// (xterm 196 is red, not blue).
			_encoder_write_text(encoder, ansi.CSI)
			_encoder_write_uint(encoder, u64(_ansi_4bit(prefix, _nearest_ansi(_xterm_256_to_rgb(index), 16))))
			_encoder_write_text(encoder, ansi.SGR)
		case .Three_Bit:
			_encoder_write_text(encoder, ansi.CSI)
			_encoder_write_uint(encoder, u64(_ansi_4bit(prefix, _nearest_ansi(_xterm_256_to_rgb(index), 8))))
			_encoder_write_text(encoder, ansi.SGR)
		case .None:
			unreachable()
		}
	case RGB_Color:
		switch depth {
		case .True_Color:
			_encoder_write_text(encoder, ansi.CSI)
			_encoder_write_uint(encoder, u64(prefix))
			_encoder_write_text(encoder, ";2;")
			_encoder_write_uint(encoder, u64(color_value[0]))
			_encoder_write_text(encoder, ";")
			_encoder_write_uint(encoder, u64(color_value[1]))
			_encoder_write_text(encoder, ";")
			_encoder_write_uint(encoder, u64(color_value[2]))
			_encoder_write_text(encoder, ansi.SGR)
		case .Eight_Bit:
			_encoder_write_text(encoder, ansi.CSI)
			_encoder_write_uint(encoder, u64(prefix))
			_encoder_write_text(encoder, ";5;")
			_encoder_write_uint(encoder, u64(_rgb_to_256(color_value)))
			_encoder_write_text(encoder, ansi.SGR)
		case .Four_Bit:
			_encoder_write_text(encoder, ansi.CSI)
			_encoder_write_uint(encoder, u64(_ansi_4bit(prefix, _nearest_ansi(color_value, 16))))
			_encoder_write_text(encoder, ansi.SGR)
		case .Three_Bit:
			_encoder_write_text(encoder, ansi.CSI)
			_encoder_write_uint(encoder, u64(_ansi_4bit(prefix, _nearest_ansi(color_value, 8))))
			_encoder_write_text(encoder, ansi.SGR)
		case .None:
			unreachable()
		}
	}
}
