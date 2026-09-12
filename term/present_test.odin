#+build linux
#+test
#+private file
package term

import "core:strings"
import "core:terminal"
import "core:testing"

// The frame-encoding suite. Expected bytes use \x1b hex escapes (not \e) so a
// mangled ESC literal cannot satisfy an expectation vacuously.

// _encode_frame serializes through the public `encode` contract and checks
// that the reported count agrees with `encoded_size`, so the fixtures pin the
// real path rather than an internal helper.
_encode_frame :: proc(buffer: Frame_Buffer, profile: Target_Profile, cursor: Cursor, scratch: []byte) -> (out: string, ok: bool) {
	written, required, err := encode(buffer, profile, cursor, scratch)
	if err != nil {
		return "", false
	}
	required_size, size_err := encoded_size(buffer, profile, cursor)
	if size_err != nil || required != required_size || written != required {
		return "", false
	}
	return string(scratch[:written]), true
}

@(test)
test_encode_reference_bytes_and_escape_correctness :: proc(t: ^testing.T) {
	// 2x2: a and c are default cells; b is styled; d closes the frame. Row 1
	// emits its own style reset because row 0 ended styled (CUP does not reset
	// SGR attributes). The whole frame is written, corner included.
	buffer := Frame_Buffer {
		columns = 2,
		rows    = 2,
		cells   = []Cell {
			{grapheme = "a", width = 1},
			{grapheme = "b", width = 1, style = {foreground = Color(RGB_Color{255, 0, 0})}},
			{grapheme = "c", width = 1},
			{grapheme = "d", width = 1},
		},
	}
	profile := Target_Profile {
		color_depth = .True_Color,
	}
	scratch: [4096]byte
	out, ok := _encode_frame(buffer, profile, {}, scratch[:])
	testing.expect(t, ok, "a valid frame must encode")

	expected := "\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[38;2;255;0;0mb\x1b[2;1H\x1b[mcd\x1b[?25l\x1b[m"
	testing.expect_value(t, out, expected)

	// The stream carries real ESC bytes and never a literal backslash-e.
	testing.expect(t, len(out) > 0 && out[0] == 0x1b, "encoded frame must start with a real ESC byte")
	for i in 0 ..< len(out) {
		if out[i] == '\\' {
			testing.expect(t, i + 1 >= len(out) || out[i + 1] != 'e', "mangled ESC literal in output")
		}
	}

	// Cells past columns * rows are unused backing capacity and must not veto
	// the visible frame.
	cells := make([]Cell, 4)
	defer delete(cells)
	cells[0] = Cell {
		grapheme = "a",
		width    = 1,
	}
	cells[1] = Cell {
		grapheme = "b",
		width    = 1,
	}
	cells[2] = Cell {
		grapheme = "c",
		width    = 1,
	}
	padded := Frame_Buffer {
		columns = 3,
		rows    = 1,
		cells   = cells,
	}
	padded_scratch: [4096]byte
	padded_out, padded_ok := _encode_frame(padded, profile_default(), {}, padded_scratch[:])
	testing.expect(t, padded_ok, "unused trailing cells must not veto the frame")
	testing.expect_value(t, padded_out, "\x1b[H\x1b[m\x1b[1;1Habc\x1b[?25l\x1b[m")
}

@(test)
test_encode_emits_the_cursor_intent :: proc(t: ^testing.T) {
	// 3x1: x, y, and z all write; the corner is part of the frame.
	buffer := Frame_Buffer {
		columns = 3,
		rows    = 1,
		cells   = []Cell{{grapheme = "x", width = 1}, {grapheme = "y", width = 1}, {grapheme = "z", width = 1}},
	}
	profile := Target_Profile {
		color_depth = .True_Color,
	}

	scratch: [4096]byte
	placed := Cursor {
		visible  = true,
		position = {1, 0},
		placed   = true,
	}
	out, ok := _encode_frame(buffer, profile, placed, scratch[:])
	testing.expect(t, ok, "an in-bounds position must encode")
	testing.expect_value(t, out, "\x1b[H\x1b[m\x1b[1;1Hxyz\x1b[1;2H\x1b[?25h\x1b[m")

	// Visibility and position are independent: a frame with no position still
	// sets visibility, and an unplaced cursor keeps the frame's end position.
	for hiding in ([?]bool{true, false}) {
		intent := Cursor {
			visible = true,
		}
		sequence := "\x1b[?25h"
		if hiding {
			intent = Cursor{}
			sequence = "\x1b[?25l"
		}
		hide_scratch: [4096]byte
		hide_out, hide_ok := _encode_frame(buffer, profile, intent, hide_scratch[:])
		testing.expect(t, hide_ok, "hide/show must encode")
		expected := strings.concatenate({"\x1b[H\x1b[m\x1b[1;1Hxyz", sequence, "\x1b[m"})
		defer delete(expected)
		testing.expect_value(t, hide_out, expected)
	}
}

@(test)
test_encode_reduces_colors_by_depth :: proc(t: ^testing.T) {
	// One styled cell after a default cell; the frame is written whole. Every
	// depth's emission is byte-exact.
	buffer := Frame_Buffer {
		columns = 3,
		rows    = 1,
		cells   = []Cell {
			{grapheme = "a", width = 1},
			{grapheme = "b", width = 1, style = {foreground = Color(RGB_Color{255, 0, 0})}},
			{grapheme = "c", width = 1},
		},
	}
	cases := []struct {
		depth:    Color_Depth,
		expected: string,
	} {
		{.True_Color, "\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[38;2;255;0;0mb\x1b[mc\x1b[?25l\x1b[m"},
		{.Eight_Bit, "\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[38;5;196mb\x1b[mc\x1b[?25l\x1b[m"},
		{.Four_Bit, "\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[91mb\x1b[mc\x1b[?25l\x1b[m"},
		{.None, "\x1b[H\x1b[m\x1b[1;1Ha\x1b[mb\x1b[mc\x1b[?25l\x1b[m"},
	}
	for c in cases {
		scratch: [4096]byte
		out, ok := _encode_frame(buffer, {color_depth = c.depth}, {}, scratch[:])
		testing.expect(t, ok, "a valid frame must encode")
		testing.expect_value(t, out, c.expected)
	}

	// xterm-256 red (196) must reduce to ANSI red (91), never wrap to blue
	// (196 % 16 == 4). The payload flows through a variable to avoid a
	// constant-folding backend bug for unions holding an integer payload.
	indexed := make([]Cell, 3)
	defer delete(indexed)
	indexed[0] = Cell {
		grapheme = "a",
		width    = 1,
	}
	index: u8 = 196
	indexed[1] = Cell {
		grapheme = "b",
		width = 1,
		style = {foreground = Color(Indexed_Color(index))},
	}
	indexed[2] = Cell {
		grapheme = "c",
		width    = 1,
	}
	indexed_scratch: [4096]byte
	indexed_out, indexed_ok := _encode_frame(Frame_Buffer{columns = 3, rows = 1, cells = indexed}, {color_depth = .Four_Bit}, {}, indexed_scratch[:])
	testing.expect(t, indexed_ok, "an indexed frame must encode")
	testing.expect_value(t, indexed_out, "\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[91mb\x1b[mc\x1b[?25l\x1b[m")
}

@(test)
test_encode_emits_style_once_per_run :: proc(t: ^testing.T) {
	// Three adjacent cells with the same style: one SGR group for the run,
	// not one per cell.
	buffer := Frame_Buffer {
		columns = 4,
		rows    = 1,
		cells   = []Cell {
			{grapheme = "a", width = 1},
			{grapheme = "b", width = 1, style = {foreground = Color(RGB_Color{255, 0, 0})}},
			{grapheme = "c", width = 1, style = {foreground = Color(RGB_Color{255, 0, 0})}},
			{grapheme = "d", width = 1, style = {foreground = Color(RGB_Color{255, 0, 0})}},
		},
	}
	scratch: [4096]byte
	out, ok := _encode_frame(buffer, {color_depth = .True_Color}, {}, scratch[:])
	testing.expect(t, ok, "a valid frame must encode")
	testing.expect_value(t, out, "\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[38;2;255;0;0mbcd\x1b[?25l\x1b[m")
}

@(test)
test_encode_validates_frame_and_cells :: proc(t: ^testing.T) {
	scratch: [4096]byte

	// Wide rendering uses the placeholder rule: a width-2 cell plus its
	// zero-width placeholder encode as the wide grapheme followed by nothing.
	// columns == 2 places the wide cell over the bottom-right corner, which is
	// written because the session disables autowrap.
	wide := Frame_Buffer {
		columns = 2,
		rows    = 1,
		cells   = []Cell{{grapheme = "界", width = 2}, {grapheme = "", width = 0}},
	}
	wide_out, wide_ok := _encode_frame(wide, {color_depth = .True_Color}, {}, scratch[:])
	testing.expect(t, wide_ok, "a well-formed wide frame must encode")
	testing.expect_value(t, wide_out, "\x1b[H\x1b[m\x1b[1;1H界\x1b[?25l\x1b[m")

	// Malformed wide grids are rejected before any byte is written.
	width_three := Frame_Buffer {
		columns = 3,
		rows    = 1,
		cells   = []Cell{{grapheme = "x", width = 3}, {grapheme = "", width = 0}, {grapheme = "", width = 0}},
	}
	_, _, width_three_err := encode(width_three, profile_default(), {}, scratch[:])
	testing.expectf(t, width_three_err == General_Error.Unsupported, "width 3 must be unsupported")

	// A wide cell with no room for its placeholder is rejected: the last
	// column has no second physical cell.
	no_room := Frame_Buffer {
		columns = 3,
		rows    = 1,
		cells   = []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}, {grapheme = "界", width = 2}},
	}
	_, _, no_room_err := encode(no_room, profile_default(), {}, scratch[:])
	testing.expectf(t, no_room_err == General_Error.Unsupported, "a wide cell in the last column must be unsupported")

	// A wide cell without its placeholder is rejected.
	no_placeholder := Frame_Buffer {
		columns = 3,
		rows    = 1,
		cells   = []Cell{{grapheme = "界", width = 2}, {grapheme = "a", width = 1}, {grapheme = "b", width = 1}},
	}
	_, _, no_placeholder_err := encode(no_placeholder, profile_default(), {}, scratch[:])
	testing.expectf(t, no_placeholder_err == General_Error.Unsupported, "a wide cell needs a placeholder")

	// A placeholder with no wide cell before it is rejected.
	leading := Frame_Buffer {
		columns = 1,
		rows    = 1,
		cells   = []Cell{{grapheme = "", width = 0}},
	}
	_, _, leading_err := encode(leading, profile_default(), {}, scratch[:])
	testing.expectf(t, leading_err == General_Error.Unsupported, "a leading placeholder must be unsupported")

	// A placeholder that carries text would advance the cursor.
	filled := Frame_Buffer {
		columns = 3,
		rows    = 1,
		cells   = []Cell{{grapheme = "界", width = 2}, {grapheme = "x", width = 0}, {grapheme = "a", width = 1}},
	}
	_, _, filled_err := encode(filled, profile_default(), {}, scratch[:])
	testing.expectf(t, filled_err == General_Error.Invalid_Cell, "a placeholder must carry no text")

	// A grapheme must be valid UTF-8 with no C0, C1, or DEL controls, so a
	// frame can never inject terminal control into the stream.
	unsafe_graphemes := [?]string{"\x1b", "\x01", "\x7f", "\xc2\x85", "\xc0\xaf", "\xff"}
	for grapheme in unsafe_graphemes {
		unsafe := Frame_Buffer {
			columns = 1,
			rows    = 1,
			cells   = []Cell{{grapheme = grapheme, width = 1}},
		}
		_, _, unsafe_err := encode(unsafe, profile_default(), {}, scratch[:])
		testing.expectf(t, unsafe_err == General_Error.Invalid_Cell, "unsafe grapheme %q must be rejected", grapheme)
	}
	// A valid non-ASCII grapheme whose continuation byte is in the C1 byte
	// range but not as a code point must pass.
	safe := Frame_Buffer {
		columns = 1,
		rows    = 1,
		cells   = []Cell{{grapheme = "\xc3\xa9", width = 1}},
	}
	_, _, safe_err := encode(safe, profile_default(), {}, scratch[:])
	testing.expect_value(t, safe_err, nil)

	// Too few cells for the declared dimensions, and negative dimensions.
	too_few := Frame_Buffer {
		columns = 3,
		rows    = 2,
		cells   = []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}},
	}
	_, _, too_few_err := encode(too_few, profile_default(), {}, scratch[:])
	testing.expect_value(t, too_few_err, General_Error.Invalid_Frame_Data)

	negative := Frame_Buffer {
		columns = -1,
		rows    = 2,
		cells   = []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}},
	}
	_, _, negative_err := encode(negative, profile_default(), {}, scratch[:])
	testing.expect_value(t, negative_err, General_Error.Invalid_Frame_Data)

	// A cursor target outside the frame is rejected, but the reserved
	// bottom-right corner is a legal target.
	two := Frame_Buffer {
		columns = 2,
		rows    = 1,
		cells   = []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}},
	}
	for position in ([?]Position{{-1, 0}, {0, -1}, {2, 0}, {0, 1}}) {
		_, _, cursor_err := encode(two, profile_default(), Cursor{placed = true, position = position}, scratch[:])
		testing.expectf(t, cursor_err == General_Error.Invalid_Cursor, "out-of-bounds cursor %v must be rejected", position)
	}
	_, _, corner_err := encode(two, profile_default(), Cursor{placed = true, position = {1, 0}}, scratch[:])
	testing.expect_value(t, corner_err, nil)

	// A zero-sized frame is a no-op, but its cursor intent is still validated.
	zero := Frame_Buffer {
		columns = 0,
		rows    = 4,
	}
	zero_written, zero_required, zero_err := encode(zero, profile_default(), {}, scratch[:])
	testing.expect_value(t, zero_err, nil)
	testing.expect_value(t, zero_written, 0)
	testing.expect_value(t, zero_required, 0)
	_, _, zero_cursor_err := encode(zero, profile_default(), Cursor{placed = true, position = {0, 0}}, scratch[:])
	testing.expect_value(t, zero_cursor_err, General_Error.Invalid_Cursor)
}

@(test)
test_encode_reports_exact_required_when_scratch_is_too_small :: proc(t: ^testing.T) {
	buffer := Frame_Buffer {
		columns = 3,
		rows    = 1,
		cells   = []Cell {
			{grapheme = "a", width = 1},
			{grapheme = "b", width = 1, style = {foreground = Color(RGB_Color{255, 0, 0})}},
			{grapheme = "c", width = 1},
		},
	}
	profile := Target_Profile {
		color_depth = .True_Color,
	}
	required, size_err := encoded_size(buffer, profile, {})
	testing.expect_value(t, size_err, nil)

	// One byte short: nothing written, the exact required count returned.
	small := make([]byte, required - 1)
	defer delete(small)
	written, reported, err := encode(buffer, profile, {}, small)
	testing.expect_value(t, err, General_Error.Presentation_Workspace_Too_Small)
	testing.expect_value(t, written, 0)
	testing.expect_value(t, reported, required)

	// An exactly-sized scratch encodes cleanly.
	exact := make([]byte, required)
	defer delete(exact)
	written, reported, err = encode(buffer, profile, {}, exact)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, written, required)
	testing.expect_value(t, reported, required)
}

@(test)
test_color_reduction_helpers_and_modifiers :: proc(t: ^testing.T) {
	// xterm cube: 16 + 36r + 6g + b over the 6x6x6 cube.
	testing.expect_value(t, _rgb_to_256(RGB_Color{0, 0, 0}), u8(16))
	testing.expect_value(t, _rgb_to_256(RGB_Color{255, 255, 255}), u8(231))
	testing.expect_value(t, _rgb_to_256(RGB_Color{255, 0, 0}), u8(196))

	// Nearest ANSI, and the xterm-256 decode (16/231 cube corners, 232 the
	// first grayscale step).
	testing.expect_value(t, _nearest_ansi(RGB_Color{255, 0, 0}, 16), u8(9))
	testing.expect_value(t, _nearest_ansi(RGB_Color{255, 0, 0}, 8), u8(1))
	testing.expect_value(t, _xterm_256_to_rgb(16), RGB_Color{0, 0, 0})
	testing.expect_value(t, _xterm_256_to_rgb(196), RGB_Color{255, 0, 0})
	testing.expect_value(t, _xterm_256_to_rgb(231), RGB_Color{255, 255, 255})
	testing.expect_value(t, _xterm_256_to_rgb(232), RGB_Color{8, 8, 8})

	// SGR codes: 30-37/90-97 foreground, 40-47/100-107 background.
	testing.expect_value(t, _ansi_4bit(38, 0), u8(30))
	testing.expect_value(t, _ansi_4bit(38, 9), u8(91))
	testing.expect_value(t, _ansi_4bit(48, 15), u8(107))

	// Every modifier maps to a distinct settable SGR code; the empty set is
	// the neutral value.
	seen: Modifiers
	for modifier in Modifier {
		testing.expect(t, modifier not_in seen, "Modifier enumerants must be distinct")
		seen += {modifier}
		testing.expect(t, _modifier_sgr(modifier) != 0, "every Modifier must map to a real SGR code")
	}
}

@(test)
test_profile_default_follows_the_color_state :: proc(t: ^testing.T) {
	previous_depth := terminal.color_depth
	previous_enabled := terminal.color_enabled
	defer {
		terminal.color_depth = previous_depth
		terminal.color_enabled = previous_enabled
	}

	terminal.color_enabled = true
	terminal.color_depth = .True_Color
	testing.expect_value(t, profile_default().color_depth, Color_Depth.True_Color)

	// NO_COLOR collapses the depth to .None.
	terminal.color_enabled = false
	testing.expect_value(t, profile_default().color_depth, Color_Depth.None)
}

@(test)
test_present_requires_an_open_session :: proc(t: ^testing.T) {
	committed, required, err := present(nil, {}, profile_default(), {}, nil)
	testing.expect_value(t, err, General_Error.Not_Open)
	testing.expect_value(t, committed, 0)
	testing.expect_value(t, required, 0)
}
