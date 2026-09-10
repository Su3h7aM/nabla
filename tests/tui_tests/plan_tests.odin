#+build linux
package main

import "nabla:tty"
import "nabla:tui"

// plan_presentation suite: full-redraw/diff semantics, run coalescing, the
// corner reservation, the exact required contract, and byte round-trips
// through tty.encode_operations.

// plan_ops plans through the public contract and returns the ops for
// inspection; ok is false when the plan failed or the contract's exact
// required count disagrees with the returned slice.
plan_ops :: proc(
	current: tui.Cell_Buffer,
	previous: Maybe(tui.Cell_Buffer),
	scratch: []tty.Presentation_Op,
) -> (
	ops: []tty.Presentation_Op,
	full_redraw: bool,
	ok: bool,
) {
	planned, required, redraw, err := tui.plan_presentation(current, previous, tty.profile_default(), tty.Capabilities{}, scratch)
	if err != tui.Presentation_Error.None || required != len(planned) {
		return nil, false, false
	}
	full_redraw = redraw
	return planned, full_redraw, true
}

// plan_bytes plans and encodes through the public terminal contract,
// returning the exact output bytes.
plan_bytes :: proc(current: tui.Cell_Buffer, previous: Maybe(tui.Cell_Buffer), scratch: []tty.Presentation_Op, bytes: []byte) -> (out: string, ok: bool) {
	ops, _, planned := plan_ops(current, previous, scratch)
	if !planned {
		return "", false
	}
	written, required, encode_err := tty.encode_operations(ops, {color_depth = .True_Color}, bytes)
	if encode_err != nil || written != required {
		return "", false
	}
	return string(bytes[:written]), true
}

test_plan_presentation_nil_previous_forces_full_redraw :: proc(t: ^T) {
	storage: [4]tui.Cell
	current: tui.Cell_Buffer
	_ = tui.init(&current, 2, 2, storage[:])
	tui.put(&current, 0, 0, {grapheme = "a"})
	tui.put(&current, 1, 0, {grapheme = "b"})
	tui.put(&current, 0, 1, {grapheme = "c"})

	scratch: [64]tty.Presentation_Op
	ops, full_redraw, ok := plan_ops(current, nil, scratch[:])
	expect(t, ok, "a nil previous must plan")
	expect(t, full_redraw, "a nil previous must force a full redraw")

	// Set_Style baseline + the row-0 write run + the row-1 write. The
	// reserved bottom-right cell is never planned.
	expect_value(t, len(ops), 6)
	expect_value(t, ops[0], tty.Presentation_Op(tty.Set_Style_Op{}))
	expect_value(t, ops[1], tty.Presentation_Op(tty.Move_Cursor_Op{position = {x = 0, y = 0}}))
	expect_value(t, ops[2], tty.Presentation_Op(tty.Write_Grapheme_Op{grapheme = "a", width = 1}))
	expect_value(t, ops[3], tty.Presentation_Op(tty.Write_Grapheme_Op{grapheme = "b", width = 1}))
	expect_value(t, ops[4], tty.Presentation_Op(tty.Move_Cursor_Op{position = {x = 0, y = 1}}))
	expect_value(t, ops[5], tty.Presentation_Op(tty.Write_Grapheme_Op{grapheme = "c", width = 1}))

	// The full redraw encodes to a deterministic ANSI stream: baseline
	// reset, origin, the write run, the second row, no trailing restore
	// (the stream ends default).
	bytes: [256]byte
	out, encoded := plan_bytes(current, nil, scratch[:], bytes[:])
	expect(t, encoded, "a full-redraw plan must encode")
	expect_value(t, out, "\x1b[m\x1b[1;1Hab\x1b[2;1Hc")
}

test_plan_presentation_identical_frames_plan_nothing :: proc(t: ^T) {
	storage: [4]tui.Cell
	current: tui.Cell_Buffer
	_ = tui.init(&current, 2, 2, storage[:])
	tui.put(&current, 0, 0, {grapheme = "a"})

	prev_storage: [4]tui.Cell
	previous: tui.Cell_Buffer
	_ = tui.init(&previous, 2, 2, prev_storage[:])
	tui.put(&previous, 0, 0, {grapheme = "a"})

	scratch: [64]tty.Presentation_Op
	ops, full_redraw, ok := plan_ops(current, Maybe(tui.Cell_Buffer)(previous), scratch[:])
	expect(t, ok, "identical frames must plan")
	expect(t, !full_redraw, "identical frames are not a full redraw")
	expect_value(t, len(ops), 0)
}

test_plan_presentation_changed_cell_plans_a_write :: proc(t: ^T) {
	storage: [4]tui.Cell
	current: tui.Cell_Buffer
	_ = tui.init(&current, 2, 2, storage[:])
	tui.put(&current, 0, 0, {grapheme = "y"})

	prev_storage: [4]tui.Cell
	previous: tui.Cell_Buffer
	_ = tui.init(&previous, 2, 2, prev_storage[:])
	tui.put(&previous, 0, 0, {grapheme = "x"})

	scratch: [64]tty.Presentation_Op
	ops, full_redraw, ok := plan_ops(current, Maybe(tui.Cell_Buffer)(previous), scratch[:])
	expect(t, ok, "a changed cell must plan")
	expect(t, !full_redraw, "a single-cell diff is not a full redraw")
	expect_value(t, len(ops), 2)
	expect_value(t, ops[0], tty.Presentation_Op(tty.Move_Cursor_Op{position = {x = 0, y = 0}}))
	expect_value(t, ops[1], tty.Presentation_Op(tty.Write_Grapheme_Op{grapheme = "y", width = 1}))

	bytes: [256]byte
	out, encoded := plan_bytes(current, Maybe(tui.Cell_Buffer)(previous), scratch[:], bytes[:])
	expect(t, encoded, "a diff must encode")
	expect_value(t, out, "\x1b[1;1Hy")
}

test_plan_presentation_blank_change_plans_an_erase :: proc(t: ^T) {
	storage: [4]tui.Cell
	current: tui.Cell_Buffer
	_ = tui.init(&current, 2, 2, storage[:])
	// (0,0) and (1,0) both clear to blank: one erase run.
	tui.put(&current, 0, 0, {grapheme = " "})

	prev_storage: [4]tui.Cell
	previous: tui.Cell_Buffer
	_ = tui.init(&previous, 2, 2, prev_storage[:])
	tui.put(&previous, 0, 0, {grapheme = "a"})
	tui.put(&previous, 1, 0, {grapheme = "b"})

	scratch: [64]tty.Presentation_Op
	ops, full_redraw, ok := plan_ops(current, Maybe(tui.Cell_Buffer)(previous), scratch[:])
	expect(t, ok, "a blank change must plan")
	expect(t, !full_redraw, "a blank diff is not a full redraw")
	expect_value(t, len(ops), 2)
	expect_value(t, ops[0], tty.Presentation_Op(tty.Move_Cursor_Op{position = {x = 0, y = 0}}))
	expect_value(t, ops[1], tty.Presentation_Op(tty.Erase_Cells_Op{count = 2}))

	bytes: [256]byte
	out, encoded := plan_bytes(current, Maybe(tui.Cell_Buffer)(previous), scratch[:], bytes[:])
	expect(t, encoded, "an erase diff must encode")
	expect_value(t, out, "\x1b[1;1H\x1b[2X")
}

test_plan_presentation_resize_forces_full_redraw :: proc(t: ^T) {
	storage: [6]tui.Cell
	current: tui.Cell_Buffer
	_ = tui.init(&current, 3, 2, storage[:])

	prev_storage: [4]tui.Cell
	previous: tui.Cell_Buffer
	_ = tui.init(&previous, 2, 2, prev_storage[:])

	scratch: [64]tty.Presentation_Op
	ops, full_redraw, ok := plan_ops(current, Maybe(tui.Cell_Buffer)(previous), scratch[:])
	expect(t, ok, "a resize must plan")
	expect(t, full_redraw, "a dimension change must force a full redraw")
	expect(t, len(ops) > 0, "a full redraw must plan ops")
}

test_plan_presentation_reports_exact_required :: proc(t: ^T) {
	storage: [4]tui.Cell
	current: tui.Cell_Buffer
	_ = tui.init(&current, 2, 1, storage[:])
	tui.put(&current, 0, 0, {grapheme = "a"})

	// The full redraw needs 3 ops (baseline, move, write); a 2-op scratch
	// reports the exact count with no ops.
	scratch: [2]tty.Presentation_Op
	ops, required, full_redraw, err := tui.plan_presentation(current, nil, tty.profile_default(), tty.Capabilities{}, scratch[:])
	expect_value(t, err, tui.Presentation_Error.Buffer_Too_Small)
	expect_value(t, required, 3)
	expect_value(t, len(ops), 0)
	expect(t, full_redraw, "the required-size report must keep the redraw flag")

	// Exact-fit scratch succeeds with the same count.
	full_scratch: [3]tty.Presentation_Op
	planned, planned_required, _, planned_err := tui.plan_presentation(current, nil, tty.profile_default(), tty.Capabilities{}, full_scratch[:])
	expect_value(t, planned_err, tui.Presentation_Error.None)
	expect_value(t, planned_required, 3)
	expect_value(t, len(planned), 3)
}

test_plan_presentation_rejects_invalid_buffers :: proc(t: ^T) {
	scratch: [64]tty.Presentation_Op

	// Negative extents.
	negative: tui.Cell_Buffer
	_, _, _, err := tui.plan_presentation({width = -1, height = 2}, nil, tty.profile_default(), tty.Capabilities{}, scratch[:])
	expect_value(t, err, tui.Presentation_Error.Invalid_Buffer)

	// Too few cells for the grid.
	short_storage: [4]tui.Cell
	short := tui.Cell_Buffer {
		width  = 3,
		height = 2,
		cells  = short_storage[:3],
	}
	_, _, _, err = tui.plan_presentation(short, nil, tty.profile_default(), tty.Capabilities{}, scratch[:])
	expect_value(t, err, tui.Presentation_Error.Invalid_Buffer)

	// A malformed previous is a caller error, not a redraw trigger.
	storage: [4]tui.Cell
	current: tui.Cell_Buffer
	_ = tui.init(&current, 2, 2, storage[:])
	bad_previous := tui.Cell_Buffer {
		width  = -1,
		height = 2,
	}
	_, _, _, err = tui.plan_presentation(current, Maybe(tui.Cell_Buffer)(bad_previous), tty.profile_default(), tty.Capabilities{}, scratch[:])
	expect_value(t, err, tui.Presentation_Error.Invalid_Buffer)
}

test_plan_presentation_reserves_the_corner :: proc(t: ^T) {
	// A diff that only touches the bottom-right cell plans nothing: the
	// corner is never written (autowrap/scroll hazard).
	storage: [4]tui.Cell
	current: tui.Cell_Buffer
	_ = tui.init(&current, 2, 2, storage[:])
	tui.put(&current, 1, 1, {grapheme = "y"})

	prev_storage: [4]tui.Cell
	previous: tui.Cell_Buffer
	_ = tui.init(&previous, 2, 2, prev_storage[:])
	tui.put(&previous, 1, 1, {grapheme = "x"})

	scratch: [64]tty.Presentation_Op
	ops, full_redraw, ok := plan_ops(current, Maybe(tui.Cell_Buffer)(previous), scratch[:])
	expect(t, ok, "a corner-only diff must plan")
	expect(t, !full_redraw, "a corner-only diff is not a full redraw")
	expect_value(t, len(ops), 0)

	// A full redraw skips the corner cell the same way.
	fresh_storage: [4]tui.Cell
	fresh: tui.Cell_Buffer
	_ = tui.init(&fresh, 2, 2, fresh_storage[:])
	tui.put(&fresh, 1, 1, {grapheme = "x"})
	corner_ops, _, corner_ok := plan_ops(fresh, nil, scratch[:])
	expect(t, corner_ok, "a full redraw with a corner cell must plan")
	expect_value(t, len(corner_ops), 5)
	expect_value(t, corner_ops[0], tty.Presentation_Op(tty.Set_Style_Op{}))
	expect_value(t, corner_ops[2], tty.Presentation_Op(tty.Erase_Cells_Op{count = 2}))
}

test_plan_presentation_coalesces_style_runs :: proc(t: ^T) {
	// Two changed styled cells in one run: one move, one Set_Style, two
	// writes — not per-cell style ops.
	style := tui.Style {
		foreground = tui.RGB_Color{255, 0, 0},
	}
	storage: [4]tui.Cell
	current: tui.Cell_Buffer
	_ = tui.init(&current, 2, 2, storage[:])
	tui.put(&current, 0, 0, {grapheme = "a", style = style})
	tui.put(&current, 1, 0, {grapheme = "b", style = style})

	prev_storage: [4]tui.Cell
	previous: tui.Cell_Buffer
	_ = tui.init(&previous, 2, 2, prev_storage[:])

	scratch: [64]tty.Presentation_Op
	ops, full_redraw, ok := plan_ops(current, Maybe(tui.Cell_Buffer)(previous), scratch[:])
	expect(t, ok, "a styled run must plan")
	expect(t, !full_redraw, "a styled diff is not a full redraw")
	expect_value(t, len(ops), 4)
	expect_value(t, ops[0], tty.Presentation_Op(tty.Move_Cursor_Op{position = {x = 0, y = 0}}))
	expect_value(t, ops[1], tty.Presentation_Op(tty.Set_Style_Op{style = {foreground = tty.Color(tty.RGB_Color{255, 0, 0})}}))
	expect_value(t, ops[2], tty.Presentation_Op(tty.Write_Grapheme_Op{grapheme = "a", width = 1}))
	expect_value(t, ops[3], tty.Presentation_Op(tty.Write_Grapheme_Op{grapheme = "b", width = 1}))
}

test_plan_presentation_erase_carries_the_cell_style :: proc(t: ^T) {
	// A blank cell with a background style erases with that rendition: the
	// styled background survives the clear.
	style := tui.Style {
		background = tui.RGB_Color{255, 0, 0},
	}
	storage: [4]tui.Cell
	current: tui.Cell_Buffer
	_ = tui.init(&current, 2, 2, storage[:])
	tui.put(&current, 0, 0, {grapheme = " ", style = style})

	prev_storage: [4]tui.Cell
	previous: tui.Cell_Buffer
	_ = tui.init(&previous, 2, 2, prev_storage[:])
	tui.put(&previous, 0, 0, {grapheme = "a"})

	scratch: [64]tty.Presentation_Op
	ops, full_redraw, ok := plan_ops(current, Maybe(tui.Cell_Buffer)(previous), scratch[:])
	expect(t, ok, "a styled blank must plan")
	expect(t, !full_redraw, "a styled blank diff is not a full redraw")
	expect_value(t, len(ops), 3)
	expect_value(t, ops[1], tty.Presentation_Op(tty.Set_Style_Op{style = {background = tty.Color(tty.RGB_Color{255, 0, 0})}}))
	expect_value(t, ops[2], tty.Presentation_Op(tty.Erase_Cells_Op{count = 1}))

	bytes: [256]byte
	out, encoded := plan_bytes(current, Maybe(tui.Cell_Buffer)(previous), scratch[:], bytes[:])
	expect(t, encoded, "a styled erase must encode")
	expect_value(t, out, "\x1b[1;1H\x1b[m\x1b[48;2;255;0;0m\x1b[1X\x1b[m")
}
