package term

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
// logical frame except the reserved bottom-right cell, and restores the
// base SGR state at the end.
//
// A hard write failure may occur after a prefix has reached the terminal;
// terminal contents and cursor state are then unspecified. The caller
// recovers with a later successful full frame or by closing the session.
// There is no transactional acceptance: bytes already consumed by the
// terminal cannot be undone.

@(require_results)
encoded_size :: proc(buffer: Frame_Buffer, profile: Target_Profile, cursor: Cursor_Intent) -> (required: int, err: Error) {
	if v_err := _validate_frame(buffer, cursor); v_err != nil {
		return 0, v_err
	}
	if buffer.columns == 0 || buffer.rows == 0 {
		// Zero-sized frame: deterministic no-op success.
		return 0, nil
	}
	e := _Encoder {
		count_only = true,
	}
	_serialize(&e, buffer, profile, cursor)
	return e.pos, nil
}

// encode serializes the frame into caller-owned output. It returns written
// (the bytes to consume: output[:written]) and repeats the exact required
// count. A too-small scratch returns .Presentation_Workspace_Too_Small with
// written == 0 and nothing usable written; the caller resizes and retries,
// never guessing.
@(require_results)
encode :: proc(buffer: Frame_Buffer, profile: Target_Profile, cursor: Cursor_Intent, output: []byte) -> (written: int, required: int, err: Error) {
	if v_err := _validate_frame(buffer, cursor); v_err != nil {
		return 0, 0, v_err
	}
	if buffer.columns == 0 || buffer.rows == 0 {
		return 0, 0, nil
	}
	e := _Encoder {
		count_only = true,
	}
	_serialize(&e, buffer, profile, cursor)
	required = e.pos
	if required > len(output) {
		return 0, required, General_Error.Presentation_Workspace_Too_Small
	}
	w := _Encoder {
		out = output,
	}
	_serialize(&w, buffer, profile, cursor)
	if w.overflowed {
		// Unreachable: the count pass just produced the exact size.
		return 0, required, General_Error.Presentation_Workspace_Too_Small
	}
	return w.pos, required, nil
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
	cursor: Cursor_Intent,
	output: []byte,
) -> (
	committed: int,
	required: int,
	err: Error,
) {
	if session == nil || !session.opened {
		return 0, 0, General_Error.Not_Open
	}
	if v_err := _validate_frame(buffer, cursor); v_err != nil {
		return 0, 0, v_err
	}
	if buffer.columns == 0 || buffer.rows == 0 {
		return 0, 0, nil
	}
	e := _Encoder {
		count_only = true,
	}
	_serialize(&e, buffer, profile, cursor)
	required = e.pos
	if required > len(output) {
		return 0, required, General_Error.Presentation_Workspace_Too_Small
	}
	w := _Encoder {
		out = output,
	}
	_serialize(&w, buffer, profile, cursor)
	if w.overflowed {
		return 0, required, General_Error.Presentation_Workspace_Too_Small
	}
	committed_bytes, write_err := _session_present(session, output[:required])
	return committed_bytes, required, write_err
}

// _validate_frame checks every frame invariant before a single byte is
// serialized or written: dimensions, logical cell count, width, grapheme
// safety, and cursor bounds. A zero-sized frame is a deterministic no-op
// (nil error) unless the cursor intent is invalid.
_validate_frame :: proc(buffer: Frame_Buffer, cursor: Cursor_Intent) -> Error {
	if buffer.columns < 0 || buffer.rows < 0 {
		return General_Error.Invalid_Frame_Data
	}
	switch c in cursor {
	case Hide, Show:
	// Explicit mode changes carry no position to validate.
	case Position:
		if c.x < 0 || c.y < 0 || c.x >= buffer.columns || c.y >= buffer.rows {
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
		if cell.width != 1 {
			// v1 implements width-1 only; width-0/1/2 is the complete target.
			return General_Error.Unsupported
		}
		if len(cell.grapheme) > 0 && !_grapheme_safe(cell.grapheme) {
			return General_Error.Invalid_Cell
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
		r, width := utf8.decode_rune(grapheme[i:])
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f) {
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

_enc_write :: proc(e: ^_Encoder, bytes: []byte) {
	if e.count_only {
		e.pos += len(bytes)
		return
	}
	if e.pos + len(bytes) > len(e.out) {
		// Defensive: callers preflight with the count pass, so this is
		// unreachable in normal operation.
		e.overflowed = true
		return
	}
	copy(e.out[e.pos:], bytes)
	e.pos += len(bytes)
}

_enc_str :: proc(e: ^_Encoder, s: string) {
	_enc_write(e, transmute([]byte)s)
}

_enc_byte :: proc(e: ^_Encoder, b: u8) {
	one := [1]u8{b}
	_enc_write(e, one[:])
}

// _enc_uint writes the decimal form of a nonnegative value. The parameter is
// u64 so the complete nonnegative int domain is representable (a CUP
// coordinate of max(int) needs the +1 computed in the unsigned domain, where
// max(int) + 1 == 2^63 fits). Callers validate nonnegativity before
// encoding; a negative int passed through is a caller bug, not this proc's
// contract.
_enc_uint :: proc(e: ^_Encoder, v: u64) {
	// Decimal digits for the complete u64 domain: max(u64) is 20 digits, so
	// size_of(u64) * 3 bytes is always enough.
	digits: [size_of(u64) * 3]u8
	n := 0
	if v == 0 {
		_enc_byte(e, '0')
		return
	}
	value := v
	for value > 0 {
		digits[n] = u8('0' + value % 10)
		value /= 10
		n += 1
	}
	for n > 0 {
		n -= 1
		_enc_byte(e, digits[n])
	}
}

// _serialize renders the (validated) frame to the ANSI byte stream. The
// escape sequences are written literally because the ansi subpackage cannot
// be imported here — its package name collides with core:terminal/ansi once
// core:testing is linked (see doc.odin).
_serialize :: proc(e: ^_Encoder, buffer: Frame_Buffer, profile: Target_Profile, cursor: Cursor_Intent) {
	// Baseline: cursor origin + explicit base style. The frame overwrites the
	// viewport without a preliminary clear (framework contract); the
	// unconditional SGR reset prevents stale attributes from a previous frame.
	_enc_str(e, "\e[H\e[m")
	previous_style: Presentation_Style

	for y in 0 ..< buffer.rows {
		// Per-row cursor positioning. CUP does not reset SGR attributes, so
		// the diff carries the previous row's last style into the next row —
		// a default cell after a styled row end emits its own reset.
		_enc_str(e, "\e[")
		_enc_uint(e, u64(y) + 1)
		_enc_str(e, ";1H")

		for x in 0 ..< buffer.columns {
			// Corner reserve: the bottom-right cell is never written —
			// writing it can trigger autowrap scroll on some terminals.
			if x == buffer.columns - 1 && y == buffer.rows - 1 {
				break
			}
			idx := y * buffer.columns + x
			_enc_cell(e, buffer.cells[idx], &previous_style, profile.color_depth)
		}
	}

	switch c in cursor {
	case Hide:
		_enc_str(e, "\e[?25l")
	case Show:
		_enc_str(e, "\e[?25h")
	case Position:
		_enc_str(e, "\e[")
		_enc_uint(e, u64(c.y) + 1)
		_enc_str(e, ";")
		_enc_uint(e, u64(c.x) + 1)
		_enc_str(e, "H")
	}

	// Restore the base style at the end of the frame (baseline contract).
	_enc_str(e, "\e[m")
}

_enc_cell :: proc(e: ^_Encoder, cell: Cell, previous: ^Presentation_Style, depth: Color_Depth) {
	_enc_style_diff(e, previous^, cell.style, depth)
	previous^ = cell.style
	_enc_str(e, cell.grapheme)
}

// _enc_style_establish resets to the base rendition and applies `style` from
// scratch. The frame path calls it on every style change; the operation path
// calls it for the first Set_Style_Op, where the terminal's current rendition
// is unknown and the reset is required even when the target is the base style
// (an external write may have left attributes set).
_enc_style_establish :: proc(e: ^_Encoder, style: Presentation_Style, depth: Color_Depth) {
	_enc_str(e, "\e[m")
	if style != (Presentation_Style{}) {
		for mod in Modifier {
			if mod in style.modifiers {
				_enc_str(e, "\e[")
				_enc_uint(e, u64(_modifier_sgr(mod)))
				_enc_str(e, "m")
			}
		}
		_enc_color(e, 38, style.foreground, depth)
		_enc_color(e, 48, style.background, depth)
	}
}

_enc_style_diff :: proc(e: ^_Encoder, prev, next: Presentation_Style, depth: Color_Depth) {
	// SGR diff: the whole style is emitted only when it changes. The
	// baseline \e[m already reset at frame start, so an unchanged style
	// needs nothing — a style run is one SGR group, not one per cell.
	if prev != next {
		_enc_style_establish(e, next, depth)
	}
}

_modifier_sgr :: proc(mod: Modifier) -> u8 {
	switch mod {
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

_enc_color :: proc(e: ^_Encoder, prefix: u8, color: Color, depth: Color_Depth) {
	// Depth reduction is deterministic: TrueColor as authored, 256 via the
	// xterm cube, 16/8 via the nearest ANSI entry, None drops colors.
	if depth == .None {
		return
	}
	switch c in color {
	case Default_Color:
	// No-op: the SGR reset already set defaults.
	case Indexed_Color:
		index := u8(c)
		switch depth {
		case .True_Color, .Eight_Bit:
			_enc_str(e, "\e[")
			_enc_uint(e, u64(prefix))
			_enc_str(e, ";5;")
			_enc_uint(e, u64(index))
			_enc_str(e, "m")
		case .Four_Bit:
			// Decode the xterm-256 index (ANSI/cube/grayscale) to RGB, then
			// reduce to the nearest 16-color entry — never a modulo wrap
			// (xterm 196 is red, not blue).
			_enc_str(e, "\e[")
			_enc_uint(e, u64(_ansi_4bit(prefix, _nearest_ansi(_xterm_256_to_rgb(index), 16))))
			_enc_str(e, "m")
		case .Three_Bit:
			_enc_str(e, "\e[")
			_enc_uint(e, u64(_ansi_4bit(prefix, _nearest_ansi(_xterm_256_to_rgb(index), 8))))
			_enc_str(e, "m")
		case .None:
			unreachable()
		}
	case RGB_Color:
		switch depth {
		case .True_Color:
			_enc_str(e, "\e[")
			_enc_uint(e, u64(prefix))
			_enc_str(e, ";2;")
			_enc_uint(e, u64(c[0]))
			_enc_str(e, ";")
			_enc_uint(e, u64(c[1]))
			_enc_str(e, ";")
			_enc_uint(e, u64(c[2]))
			_enc_str(e, "m")
		case .Eight_Bit:
			_enc_str(e, "\e[")
			_enc_uint(e, u64(prefix))
			_enc_str(e, ";5;")
			_enc_uint(e, u64(_rgb_to_256(c)))
			_enc_str(e, "m")
		case .Four_Bit:
			_enc_str(e, "\e[")
			_enc_uint(e, u64(_ansi_4bit(prefix, _nearest_ansi(c, 16))))
			_enc_str(e, "m")
		case .Three_Bit:
			_enc_str(e, "\e[")
			_enc_uint(e, u64(_ansi_4bit(prefix, _nearest_ansi(c, 8))))
			_enc_str(e, "m")
		case .None:
			unreachable()
		}
	}
}
