#+build linux
#+test
#+private file
package tui

import "core:testing"
import "nabla:term"

// The plan_presentation suite: full-redraw and diff semantics, run coalescing,
// the corner reservation, the exact-required contract, and byte round-trips
// through term.encode_operations.

// _plan_ops plans through the public contract and returns the ops for
// inspection; ok is false when the plan failed or the exact required count
// disagrees with the returned slice.
_plan_ops :: proc(
	current: Cell_Buffer,
	previous: Maybe(Cell_Buffer),
	scratch: []term.Presentation_Op,
) -> (
	ops: []term.Presentation_Op,
	full_redraw: bool,
	ok: bool,
) {
	planned, required, redraw, err := plan_presentation(current, previous, term.profile_default(), term.Capabilities{}, scratch)
	if err != Presentation_Error.None || required != len(planned) {
		return nil, false, false
	}
	return planned, redraw, true
}

// _plan_bytes plans and encodes through the public terminal contract, returning
// the exact output bytes.
_plan_bytes :: proc(current: Cell_Buffer, previous: Maybe(Cell_Buffer), scratch: []term.Presentation_Op, bytes: []byte) -> (out: string, ok: bool) {
	ops, _, planned := _plan_ops(current, previous, scratch)
	if !planned {
		return "", false
	}
	written, required, encode_err := term.encode_operations(ops, {color_depth = .True_Color}, bytes)
	if encode_err != nil || written != required {
		return "", false
	}
	return string(bytes[:written]), true
}

@(test)
test_plan_forces_a_full_redraw :: proc(t: ^testing.T) {
	storage: [4]Cell
	current: Cell_Buffer
	_ = init(&current, 2, 2, storage[:])
	put(&current, 0, 0, {grapheme = "a"})
	put(&current, 1, 0, {grapheme = "b"})
	put(&current, 0, 1, {grapheme = "c"})

	scratch: [64]term.Presentation_Op
	ops, full_redraw, ok := _plan_ops(current, nil, scratch[:])
	testing.expect(t, ok, "a nil previous must plan")
	testing.expect(t, full_redraw, "a nil previous must force a full redraw")

	// Set_Style baseline, the row-0 write run, and the row-1 write. The
	// reserved bottom-right cell is never planned.
	testing.expect_value(t, len(ops), 6)
	testing.expect_value(t, ops[0], term.Presentation_Op(term.Set_Style_Op{}))
	testing.expect_value(t, ops[1], term.Presentation_Op(term.Move_Cursor_Op{position = {x = 0, y = 0}}))
	testing.expect_value(t, ops[2], term.Presentation_Op(term.Write_Grapheme_Op{grapheme = "a", width = 1}))
	testing.expect_value(t, ops[3], term.Presentation_Op(term.Write_Grapheme_Op{grapheme = "b", width = 1}))
	testing.expect_value(t, ops[4], term.Presentation_Op(term.Move_Cursor_Op{position = {x = 0, y = 1}}))
	testing.expect_value(t, ops[5], term.Presentation_Op(term.Write_Grapheme_Op{grapheme = "c", width = 1}))

	bytes: [256]byte
	out, encoded := _plan_bytes(current, nil, scratch[:], bytes[:])
	testing.expect(t, encoded, "a full-redraw plan must encode")
	testing.expect_value(t, out, "\x1b[m\x1b[1;1Hab\x1b[2;1Hc")

	// A dimension change also forces a full redraw, independently of content.
	resized_storage: [6]Cell
	resized: Cell_Buffer
	_ = init(&resized, 3, 2, resized_storage[:])
	previous_storage: [4]Cell
	previous: Cell_Buffer
	_ = init(&previous, 2, 2, previous_storage[:])
	resize_ops, resize_redraw, resize_ok := _plan_ops(resized, Maybe(Cell_Buffer)(previous), scratch[:])
	testing.expect(t, resize_ok, "a resize must plan")
	testing.expect(t, resize_redraw, "a dimension change must force a full redraw")
	testing.expect(t, len(resize_ops) > 0, "a full redraw must plan ops")
}

@(test)
test_plan_diffs_against_the_previous_frame :: proc(t: ^testing.T) {
	scratch: [64]term.Presentation_Op

	// Identical frames plan nothing.
	current_storage: [4]Cell
	current: Cell_Buffer
	_ = init(&current, 2, 2, current_storage[:])
	put(&current, 0, 0, {grapheme = "a"})
	previous_storage: [4]Cell
	previous: Cell_Buffer
	_ = init(&previous, 2, 2, previous_storage[:])
	put(&previous, 0, 0, {grapheme = "a"})
	identical_ops, identical_redraw, identical_ok := _plan_ops(current, Maybe(Cell_Buffer)(previous), scratch[:])
	testing.expect(t, identical_ok)
	testing.expect(t, !identical_redraw, "identical frames are not a full redraw")
	testing.expect_value(t, len(identical_ops), 0)

	// A changed cell plans a move and a write.
	changed_storage: [4]Cell
	changed: Cell_Buffer
	_ = init(&changed, 2, 2, changed_storage[:])
	put(&changed, 0, 0, {grapheme = "y"})
	base_storage: [4]Cell
	base: Cell_Buffer
	_ = init(&base, 2, 2, base_storage[:])
	put(&base, 0, 0, {grapheme = "x"})
	changed_ops, changed_redraw, changed_ok := _plan_ops(changed, Maybe(Cell_Buffer)(base), scratch[:])
	testing.expect(t, changed_ok)
	testing.expect(t, !changed_redraw)
	testing.expect_value(t, len(changed_ops), 2)
	testing.expect_value(t, changed_ops[0], term.Presentation_Op(term.Move_Cursor_Op{position = {x = 0, y = 0}}))
	testing.expect_value(t, changed_ops[1], term.Presentation_Op(term.Write_Grapheme_Op{grapheme = "y", width = 1}))
	changed_bytes: [256]byte
	changed_out, changed_encoded := _plan_bytes(changed, Maybe(Cell_Buffer)(base), scratch[:], changed_bytes[:])
	testing.expect(t, changed_encoded)
	testing.expect_value(t, changed_out, "\x1b[1;1Hy")

	// A blank change plans an erase run.
	blank_storage: [4]Cell
	blank: Cell_Buffer
	_ = init(&blank, 2, 2, blank_storage[:])
	put(&blank, 0, 0, {grapheme = " "})
	full_storage: [4]Cell
	full: Cell_Buffer
	_ = init(&full, 2, 2, full_storage[:])
	put(&full, 0, 0, {grapheme = "a"})
	put(&full, 1, 0, {grapheme = "b"})
	blank_ops, blank_redraw, blank_ok := _plan_ops(blank, Maybe(Cell_Buffer)(full), scratch[:])
	testing.expect(t, blank_ok)
	testing.expect(t, !blank_redraw)
	testing.expect_value(t, len(blank_ops), 2)
	testing.expect_value(t, blank_ops[0], term.Presentation_Op(term.Move_Cursor_Op{position = {x = 0, y = 0}}))
	testing.expect_value(t, blank_ops[1], term.Presentation_Op(term.Erase_Cells_Op{count = 2}))
	blank_bytes: [256]byte
	blank_out, blank_encoded := _plan_bytes(blank, Maybe(Cell_Buffer)(full), scratch[:], blank_bytes[:])
	testing.expect(t, blank_encoded)
	testing.expect_value(t, blank_out, "\x1b[1;1H\x1b[2X")

	// The reserved bottom-right corner is never written, even when it changes.
	corner_storage: [4]Cell
	corner: Cell_Buffer
	_ = init(&corner, 2, 2, corner_storage[:])
	put(&corner, 1, 1, {grapheme = "y"})
	corner_prev_storage: [4]Cell
	corner_prev: Cell_Buffer
	_ = init(&corner_prev, 2, 2, corner_prev_storage[:])
	put(&corner_prev, 1, 1, {grapheme = "x"})
	corner_ops, corner_redraw, corner_ok := _plan_ops(corner, Maybe(Cell_Buffer)(corner_prev), scratch[:])
	testing.expect(t, corner_ok)
	testing.expect(t, !corner_redraw)
	testing.expect_value(t, len(corner_ops), 0)
}

@(test)
test_plan_reports_exact_required :: proc(t: ^testing.T) {
	storage: [4]Cell
	current: Cell_Buffer
	_ = init(&current, 2, 1, storage[:])
	put(&current, 0, 0, {grapheme = "a"})

	// The full redraw needs 3 ops; a 2-op scratch reports the exact count with
	// no ops and keeps the redraw flag.
	scratch: [2]term.Presentation_Op
	ops, required, full_redraw, err := plan_presentation(current, nil, term.profile_default(), term.Capabilities{}, scratch[:])
	testing.expect_value(t, err, Presentation_Error.Buffer_Too_Small)
	testing.expect_value(t, required, 3)
	testing.expect_value(t, len(ops), 0)
	testing.expect(t, full_redraw, "the required-size report must keep the redraw flag")

	// An exact-fit scratch succeeds with the same count.
	full_scratch: [3]term.Presentation_Op
	planned, planned_required, _, planned_err := plan_presentation(current, nil, term.profile_default(), term.Capabilities{}, full_scratch[:])
	testing.expect_value(t, planned_err, Presentation_Error.None)
	testing.expect_value(t, planned_required, 3)
	testing.expect_value(t, len(planned), 3)
}

@(test)
test_plan_rejects_invalid_buffers :: proc(t: ^testing.T) {
	scratch: [64]term.Presentation_Op

	// Negative extents.
	_, _, _, err := plan_presentation({width = -1, height = 2}, nil, term.profile_default(), term.Capabilities{}, scratch[:])
	testing.expect_value(t, err, Presentation_Error.Invalid_Buffer)

	// Too few cells for the grid.
	short_storage: [4]Cell
	short := Cell_Buffer {
		width  = 3,
		height = 2,
		cells  = short_storage[:3],
	}
	_, _, _, err = plan_presentation(short, nil, term.profile_default(), term.Capabilities{}, scratch[:])
	testing.expect_value(t, err, Presentation_Error.Invalid_Buffer)

	// A malformed previous is a caller error, not a redraw trigger.
	storage: [4]Cell
	current: Cell_Buffer
	_ = init(&current, 2, 2, storage[:])
	bad_previous := Cell_Buffer {
		width  = -1,
		height = 2,
	}
	_, _, _, err = plan_presentation(current, Maybe(Cell_Buffer)(bad_previous), term.profile_default(), term.Capabilities{}, scratch[:])
	testing.expect_value(t, err, Presentation_Error.Invalid_Buffer)
}

@(test)
test_plan_coalesces_style_runs_and_keeps_erase_style :: proc(t: ^testing.T) {
	// Two changed styled cells in one run: one move, one style, two writes.
	style := Style {
		foreground = RGB_Color{255, 0, 0},
	}
	storage: [4]Cell
	current: Cell_Buffer
	_ = init(&current, 2, 2, storage[:])
	put(&current, 0, 0, {grapheme = "a", style = style})
	put(&current, 1, 0, {grapheme = "b", style = style})

	previous_storage: [4]Cell
	previous: Cell_Buffer
	_ = init(&previous, 2, 2, previous_storage[:])

	scratch: [64]term.Presentation_Op
	ops, full_redraw, ok := _plan_ops(current, Maybe(Cell_Buffer)(previous), scratch[:])
	testing.expect(t, ok, "a styled run must plan")
	testing.expect(t, !full_redraw)
	testing.expect_value(t, len(ops), 4)
	testing.expect_value(t, ops[0], term.Presentation_Op(term.Move_Cursor_Op{position = {x = 0, y = 0}}))
	testing.expect_value(t, ops[1], term.Presentation_Op(term.Set_Style_Op{style = {foreground = term.Color(term.RGB_Color{255, 0, 0})}}))
	testing.expect_value(t, ops[2], term.Presentation_Op(term.Write_Grapheme_Op{grapheme = "a", width = 1}))
	testing.expect_value(t, ops[3], term.Presentation_Op(term.Write_Grapheme_Op{grapheme = "b", width = 1}))

	// A blank cell with a background style erases with that rendition: the
	// styled background survives the clear.
	styled_blank := Style {
		background = RGB_Color{255, 0, 0},
	}
	blank_storage: [4]Cell
	blank: Cell_Buffer
	_ = init(&blank, 2, 2, blank_storage[:])
	put(&blank, 0, 0, {grapheme = " ", style = styled_blank})

	base_storage: [4]Cell
	base: Cell_Buffer
	_ = init(&base, 2, 2, base_storage[:])
	put(&base, 0, 0, {grapheme = "a"})

	erase_ops, erase_redraw, erase_ok := _plan_ops(blank, Maybe(Cell_Buffer)(base), scratch[:])
	testing.expect(t, erase_ok, "a styled blank must plan")
	testing.expect(t, !erase_redraw)
	testing.expect_value(t, len(erase_ops), 3)
	testing.expect_value(t, erase_ops[1], term.Presentation_Op(term.Set_Style_Op{style = {background = term.Color(term.RGB_Color{255, 0, 0})}}))
	testing.expect_value(t, erase_ops[2], term.Presentation_Op(term.Erase_Cells_Op{count = 1}))

	erase_bytes: [256]byte
	erase_out, erase_encoded := _plan_bytes(blank, Maybe(Cell_Buffer)(base), scratch[:], erase_bytes[:])
	testing.expect(t, erase_encoded, "a styled erase must encode")
	testing.expect_value(t, erase_out, "\x1b[1;1H\x1b[m\x1b[48;2;255;0;0m\x1b[1X\x1b[m")
}
