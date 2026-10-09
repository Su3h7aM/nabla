#+build linux
#+test
#+private file
package term

import "core:slice"
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

	expected := "\x1b[?2026h\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[38;2;255;0;0mb\x1b[2;1H\x1b[mcd\x1b[?25l\x1b[m\x1b[?2026l"
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
	testing.expect_value(t, padded_out, "\x1b[?2026h\x1b[H\x1b[m\x1b[1;1Habc\x1b[?25l\x1b[m\x1b[?2026l")
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
	testing.expect_value(t, out, "\x1b[?2026h\x1b[H\x1b[m\x1b[1;1Hxyz\x1b[1;2H\x1b[?25h\x1b[m\x1b[?2026l")

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
		expected := strings.concatenate({"\x1b[?2026h\x1b[H\x1b[m\x1b[1;1Hxyz", sequence, "\x1b[m\x1b[?2026l"})
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
		{.True_Color, "\x1b[?2026h\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[38;2;255;0;0mb\x1b[mc\x1b[?25l\x1b[m\x1b[?2026l"},
		{.Eight_Bit, "\x1b[?2026h\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[38;5;196mb\x1b[mc\x1b[?25l\x1b[m\x1b[?2026l"},
		{.Four_Bit, "\x1b[?2026h\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[91mb\x1b[mc\x1b[?25l\x1b[m\x1b[?2026l"},
		{.None, "\x1b[?2026h\x1b[H\x1b[m\x1b[1;1Ha\x1b[mb\x1b[mc\x1b[?25l\x1b[m\x1b[?2026l"},
	}
	for fixture in cases {
		scratch: [4096]byte
		out, ok := _encode_frame(buffer, {color_depth = fixture.depth}, {}, scratch[:])
		testing.expect(t, ok, "a valid frame must encode")
		testing.expect_value(t, out, fixture.expected)
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
	testing.expect_value(t, indexed_out, "\x1b[?2026h\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[91mb\x1b[mc\x1b[?25l\x1b[m\x1b[?2026l")
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
	testing.expect_value(t, out, "\x1b[?2026h\x1b[H\x1b[m\x1b[1;1Ha\x1b[m\x1b[38;2;255;0;0mbcd\x1b[?25l\x1b[m\x1b[?2026l")
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
	testing.expect_value(t, wide_out, "\x1b[?2026h\x1b[H\x1b[m\x1b[1;1H界\x1b[?25l\x1b[m\x1b[?2026l")

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

@(test)
test_encode_hyperlinks_close_before_wrapped_row_cursor_moves :: proc(t: ^testing.T) {
	buffer := Frame_Buffer {
		columns = 1,
		rows    = 2,
		cells   = []Cell{{grapheme = "a", width = 1, link = Link_Id(2)}, {grapheme = "b", width = 1, link = Link_Id(2)}},
		links   = []string{"https://other.example", "https://example.com"},
	}
	scratch: [4096]byte
	out, ok := _encode_frame(buffer, {}, {}, scratch[:])
	if !testing.expect(t, ok) { return }
	open := "\x1b]8;id=2;https://example.com\x1b\\"
	close := "\x1b]8;;\x1b\\"
	first_open := strings.index(out, open)
	first_close := strings.index(out, close)
	second_open := strings.index(out[first_close + len(close):], open)
	second_close := strings.index(out[first_close + len(close):], close)
	row_move := strings.index(out, "\x1b[2;1H")
	testing.expect(t, first_open >= 0 && first_close > first_open)
	testing.expect(t, second_open >= 0 && second_close > second_open)
	testing.expect(t, row_move > first_close && row_move < first_close + len(close) + 20)
}

@(test)
test_encode_invalid_hyperlink_uri_without_osc8 :: proc(t: ^testing.T) {
	buffer := Frame_Buffer {
		columns = 1,
		rows    = 1,
		cells   = []Cell{{grapheme = "x", width = 1, link = Link_Id(1)}},
		links   = []string{"https://bad\x1b]8;;"},
	}
	scratch: [4096]byte
	out, ok := _encode_frame(buffer, {}, {}, scratch[:])
	if !testing.expect(t, ok) { return }
	testing.expect(t, strings.index(out, "\x1b]8;") < 0)
}

@(test)
test_encode_wraps_the_frame_in_synchronized_output :: proc(t: ^testing.T) {
	buffer := Frame_Buffer {
		columns = 1,
		rows    = 1,
		cells   = []Cell{{grapheme = "x", width = 1}},
	}
	scratch: [4096]byte
	out, ok := _encode_frame(buffer, {}, {}, scratch[:])
	if !testing.expect(t, ok) { return }
	testing.expect(t, strings.has_prefix(out, "\x1b[?2026h"))
	testing.expect(t, strings.has_suffix(out, "\x1b[?2026l"))
	testing.expect_value(t, strings.count(out, "\x1b[?2026"), 2)
}

@(test)
test_encode_emits_the_cursor_shape :: proc(t: ^testing.T) {
	buffer := Frame_Buffer {
		columns = 1,
		rows    = 1,
		cells   = []Cell{{grapheme = "x", width = 1}},
	}
	expected := [Cursor_Shape]string {
		.Default         = "",
		.Block_Blink     = "\x1b[1 q",
		.Block           = "\x1b[2 q",
		.Underline_Blink = "\x1b[3 q",
		.Underline       = "\x1b[4 q",
		.Beam_Blink      = "\x1b[5 q",
		.Beam            = "\x1b[6 q",
	}
	for shape in Cursor_Shape {
		scratch: [4096]byte
		out, ok := _encode_frame(buffer, {}, {shape = shape}, scratch[:])
		if !testing.expect(t, ok) { return }
		want := strings.concatenate({"\x1b[?2026h\x1b[H\x1b[m\x1b[1;1Hx", expected[shape], "\x1b[?25l\x1b[m\x1b[?2026l"})
		defer delete(want)
		testing.expect_value(t, out, want)
	}
}

@(test)
test_encode_maps_rgb_to_the_nearest_xterm_256_entry :: proc(t: ^testing.T) {
	testing.expect_value(t, _rgb_to_256({135, 0, 0}), 88)
	testing.expect_value(t, _rgb_to_256({95, 175, 215}), 16 + 36 * 1 + 6 * 3 + 4)
	testing.expect_value(t, _rgb_to_256({128, 128, 128}), 244)
}

// _encode_diff encodes next against previous through the public contract.
_encode_diff :: proc(t: ^testing.T, next: Frame_Buffer, previous: ^Frame_Buffer, cursor: Cursor, scratch: []byte) -> string {
	written, required, err := encode(next, {}, cursor, scratch, previous)
	testing.expect_value(t, err, nil)
	size, size_err := encoded_size(next, {}, cursor, previous)
	testing.expect_value(t, size_err, nil)
	testing.expect_value(t, size, required)
	return string(scratch[:written])
}

@(test)
test_encode_diff_unchanged_frame_emits_only_the_wrap_and_cursor :: proc(t: ^testing.T) {
	cells := []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}, {grapheme = "c", width = 1}, {grapheme = "d", width = 1}}
	next := Frame_Buffer {
		columns = 2,
		rows    = 2,
		cells   = cells,
	}
	previous := Frame_Buffer {
		columns = 2,
		rows    = 2,
		cells   = slice.clone(cells),
	}
	defer delete(previous.cells)
	scratch: [256]byte
	testing.expect_value(t, _encode_diff(t, next, &previous, {}, scratch[:]), "\x1b[?2026h\x1b[m\x1b[?25l\x1b[m\x1b[?2026l")
	placed := Cursor {
		visible  = true,
		placed   = true,
		position = {1, 0},
	}
	testing.expect_value(t, _encode_diff(t, next, &previous, placed, scratch[:]), "\x1b[?2026h\x1b[m\x1b[1;2H\x1b[?25h\x1b[m\x1b[?2026l")
}

@(test)
test_encode_diff_changed_cell_emits_one_positioned_write :: proc(t: ^testing.T) {
	cells := []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}, {grapheme = "c", width = 1}, {grapheme = "d", width = 1}}
	previous := Frame_Buffer {
		columns = 2,
		rows    = 2,
		cells   = slice.clone(cells),
	}
	defer delete(previous.cells)
	cells[3].grapheme = "x"
	next := Frame_Buffer {
		columns = 2,
		rows    = 2,
		cells   = cells,
	}
	scratch: [256]byte
	testing.expect_value(t, _encode_diff(t, next, &previous, {}, scratch[:]), "\x1b[?2026h\x1b[m\x1b[2;2Hx\x1b[?25l\x1b[m\x1b[?2026l")

	// Adjacent changes share one move; the link table is compared by URI, so a
	// different frame-local id for the same URI is not a change.
	cells[0].grapheme = "y"
	cells[1].grapheme = "z"
	links := []string{"https://a.example"}
	cells[2].link = 1
	previous.cells[2].link = 2
	previous.links = []string{"https://other.example", "https://a.example"}
	next.links = links
	testing.expect_value(t, _encode_diff(t, next, &previous, {}, scratch[:]), "\x1b[?2026h\x1b[m\x1b[1;1Hyz\x1b[2;2Hx\x1b[?25l\x1b[m\x1b[?2026l")
}

@(test)
test_encode_diff_wide_cell_is_written_with_its_placeholder :: proc(t: ^testing.T) {
	previous_cells := []Cell{{grapheme = "x", width = 1}, {grapheme = "y", width = 1}, {grapheme = "a", width = 1}, {grapheme = "b", width = 1}}
	next_cells := []Cell{{grapheme = "界", width = 2}, {width = 0}, {grapheme = "a", width = 1}, {grapheme = "b", width = 1}}
	previous := Frame_Buffer {
		columns = 4,
		rows    = 1,
		cells   = previous_cells,
	}
	next := Frame_Buffer {
		columns = 4,
		rows    = 1,
		cells   = next_cells,
	}
	scratch: [256]byte
	testing.expect_value(t, _encode_diff(t, next, &previous, {}, scratch[:]), "\x1b[?2026h\x1b[m\x1b[1;1H界\x1b[?25l\x1b[m\x1b[?2026l")

	// The wide cell replaced by two narrow cells rewrites both columns.
	testing.expect_value(t, _encode_diff(t, previous, &next, {}, scratch[:]), "\x1b[?2026h\x1b[m\x1b[1;1Hxy\x1b[?25l\x1b[m\x1b[?2026l")

	// A wide cell whose neighbour changes is not rewritten.
	changed := []Cell{{grapheme = "界", width = 2}, {width = 0}, {grapheme = "a", width = 1}, {grapheme = "c", width = 1}}
	testing.expect_value(
		t,
		_encode_diff(t, Frame_Buffer{columns = 4, rows = 1, cells = changed}, &next, {}, scratch[:]),
		"\x1b[?2026h\x1b[m\x1b[1;4Hc\x1b[?25l\x1b[m\x1b[?2026l",
	)
}

@(test)
test_encode_diff_falls_back_to_the_full_frame :: proc(t: ^testing.T) {
	cells := []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}}
	next := Frame_Buffer {
		columns = 2,
		rows    = 1,
		cells   = cells,
	}
	other := Frame_Buffer {
		columns = 1,
		rows    = 2,
		cells   = cells,
	}
	full := "\x1b[?2026h\x1b[H\x1b[m\x1b[1;1Hab\x1b[?25l\x1b[m\x1b[?2026l"
	scratch: [256]byte
	testing.expect_value(t, _encode_diff(t, next, nil, {}, scratch[:]), full)
	testing.expect_value(t, _encode_diff(t, next, &other, {}, scratch[:]), full)
}
