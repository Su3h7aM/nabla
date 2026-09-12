#+build linux
#+test
#+private file
// Pipeline tests for the drawing stack: a small list app composed from layout
// declarations and rendered end to end through layout, tui, and term. It lives
// under `test/` because it exercises the whole stack, not one procedure, and
// because the tuple of packages it needs (layout + tui + term) is exactly
// tui's dependency direction.
package tui_test

import "core:testing"
import input "nabla:input"
import "nabla:layout"
import "nabla:term"
import "nabla:tui"

// App is the whole slice state: a viewport and one selectable label. It is the
// smallest model that exercises Key and Resize without inventing a framework.
App :: struct {
	columns:  int,
	rows:     int,
	items:    [3]string,
	selected: int,
}

DEFAULT_APP :: App {
	columns = 24,
	rows    = 6,
	items   = {"alpha", "beta", "gamma"},
}

// update is pure with respect to the terminal: it takes normalized event data
// and performs no I/O.
update :: proc(app: ^App, event: input.Event) {
	switch data in event {
	case input.Key_Event:
		#partial switch data.code {
		case .Down:
			app.selected = min(app.selected + 1, len(app.items) - 1)
		case .Up:
			app.selected = max(app.selected - 1, 0)
		}
	case input.Resize_Event:
		app.columns = data.columns
		app.rows = data.rows
	case input.Paste:
	// The slice test has no paste handling; the paste is ignored.
	case input.End_Of_Input:
	case input.Unknown_Input:
	}
}

SELECTED_STYLE :: term.Style {
	foreground = term.Indexed_Color(0),
	background = term.Indexed_Color(7),
	modifiers  = {.Bold},
}

// item_style exists because a *constant* struct holding a union miscompiles when
// it reaches a conditional expression: `selected ? SELECTED_STYLE : term.Style{}`
// makes LLVM reject the module with "PHI node operands are not the same type as
// the result". Copying the constant to a local first is enough to avoid it,
// which is why this reads `style := SELECTED_STYLE` rather than returning the
// constant directly. Broken on every Odin release that has the feature
// (dev-2025-11 through dev-2026-07a, verified).
item_style :: proc(selected: bool) -> term.Style {
	if selected {
		selected_style := SELECTED_STYLE
		return selected_style
	}
	return term.Style{}
}

// SLICE_CAPACITIES is the layout budget for one frame of this app: a frame root,
// the container, three labels, and the pools those declarations touch.
SLICE_CAPACITIES :: layout.Capacities {
	nodes          = 8,
	children       = 16,
	clips          = 4,
	commands       = 16,
	text_lines     = 8,
	measured_words = 64,
	overlays       = 1,
	measure_cache  = 8,
	id_table       = 8,
	depth          = 4,
	diagnostics    = 8,
	debug_labels   = 0,
}

// SLICE_STORAGE_BYTES must be at least `layout.storage_size(SLICE_CAPACITIES)`.
// The bound is checked in render rather than asserted, so a capacity change
// that outgrows the buffer fails loudly instead of corrupting memory.
SLICE_STORAGE_BYTES :: 16384

// Render_Storage holds every buffer the pipeline needs for one frame. Keeping it
// caller-owned is what lets a test prove that a reused workspace and a fresh one
// produce identical output.
Render_Storage :: struct {
	ctx:             layout.Context,
	layout_storage:  [SLICE_STORAGE_BYTES]byte,
	measure_context: tui.Measure_Context,
	cells:           [512]term.Cell,
	buffer:          term.Frame_Buffer,
}

Render_Error :: enum u8 {
	None,
	Layout_Failed,
	Buffer_Too_Small,
	Not_Integral,
	Undrawable_Text,
}

// render runs the whole pipeline for one frame: compose, solve, project, draw.
// It touches no backend, which is what makes the boundary testable.
//
// Partial progress: on any error nothing is presented, so a failed frame cannot
// reach the terminal half-drawn.
//
// The context is re-initialized on every call: `init_from_buffer` refuses a context
// that is already initialized, and the fixed storage belongs to the caller, so
// destroy is the no-op reset that makes reuse sound.
render :: proc(app: App, storage: ^Render_Storage) -> (frame: term.Frame_Buffer, err: Render_Error) {
	config := layout.Options {
		capacities = SLICE_CAPACITIES,
	}
	if layout.storage_size(config.capacities) > len(storage.layout_storage) {
		return {}, .Layout_Failed
	}
	layout.destroy(&storage.ctx)
	if layout.init_from_buffer(&storage.ctx, config, storage.layout_storage[:]) != nil {
		return {}, .Layout_Failed
	}

	viewport := layout.Vec2{layout.Scalar(app.columns), layout.Scalar(app.rows)}
	layout.set_services(&storage.ctx, {measure_text = tui.measure_proc, measure_text_user_data = &storage.measure_context, break_text = tui.break_proc})
	if layout.frame(&storage.ctx, viewport) {
		if layout.element(
			&storage.ctx,
			layout.Element_Desc {
				id = 1,
				layout = {flow = .Column, sizing = {layout.grow(), layout.grow()}, padding = {left = 2, top = 1, right = 2, bottom = 1}, gap = 1},
			},
		) {
			for item, index in app.items {
				layout.text(&storage.ctx, layout.Text_Desc{id = layout.Id(index + 2), text = item, sizing = {layout.fit(), layout.fit()}})
			}
		}
	}
	frame_result, frame_error := layout.result(&storage.ctx)
	if frame_error != nil {
		return {}, .Layout_Failed
	}

	if !tui.init(&storage.buffer, app.columns, app.rows, storage.cells[:]) {
		return {}, .Buffer_Too_Small
	}

	for item, index in app.items {
		node, found := layout.lookup(frame_result, layout.Id(index + 2))
		if !found {
			return {}, .Layout_Failed
		}
		rect, projection_error := tui.project_rect_integral(node.outer)
		if projection_error != nil {
			return {}, .Not_Integral
		}
		if _, ok := tui.draw_text(&storage.buffer, rect, item, item_style(index == app.selected)); !ok {
			return {}, .Undrawable_Text
		}
	}

	return storage.buffer, .None
}

// present_frame is the only procedure in the slice that talks to the terminal.
// Everything else renders into the caller-owned grid, which is what keeps the
// boundary testable without a tty.
present_frame :: proc(session: ^term.Session, app: App, storage: ^Render_Storage) -> (Render_Error, term.Error) {
	frame, render_error := render(app, storage)
	if render_error != nil {
		return render_error, nil
	}
	output: [4096]byte
	_, _, present_error := term.present(session, frame, term.profile_default(), {}, output[:])
	return .None, present_error
}

// glyph_row reads one row of the grid as a string, so snapshots are legible in
// a failure message instead of being a wall of cell structs.
glyph_row :: proc(buffer: term.Frame_Buffer, row: int, storage: []byte) -> string {
	count := 0
	for column in 0 ..< buffer.columns {
		grapheme := buffer.cells[row * buffer.columns + column].grapheme
		if len(grapheme) > 0 {
			storage[count] = grapheme[0]
		} else {
			storage[count] = ' '
		}
		count += 1
	}
	return string(storage[:count])
}

_expect_frames_equal :: proc(t: ^testing.T, first, second: term.Frame_Buffer) {
	testing.expect_value(t, second.columns, first.columns)
	testing.expect_value(t, second.rows, first.rows)
	testing.expect_value(t, len(second.cells), len(first.cells))
	for cell, index in first.cells {
		testing.expect_value(t, second.cells[index], cell)
	}
}

@(test)
test_slice_renders_a_known_snapshot :: proc(t: ^testing.T) {
	storage: Render_Storage
	_, err := render(DEFAULT_APP, &storage)
	testing.expect_value(t, err, Render_Error.None)

	// Padding 2/1 and gap 1 place the labels at x=2, y=1/3/5. The viewport is 6
	// rows, so the last label lands on the final row.
	expected := [?]string {
		"                        ",
		"  alpha                 ",
		"                        ",
		"  beta                  ",
		"                        ",
		"  gamma                 ",
	}
	row_storage: [64]byte
	for row, index in expected {
		testing.expect_value(t, glyph_row(storage.buffer, index, row_storage[:]), row)
	}
}

@(test)
test_selection_is_the_only_styled_run :: proc(t: ^testing.T) {
	storage: Render_Storage
	_, err := render(DEFAULT_APP, &storage)
	testing.expect_value(t, err, Render_Error.None)

	for cell, index in storage.buffer.cells {
		row := index / storage.buffer.columns
		column := index % storage.buffer.columns
		selected_run := row == 1 && column >= 2 && column < 7
		testing.expect_value(t, cell.style, item_style(selected_run))
	}
}

@(test)
test_key_events_move_and_clamp_the_selection :: proc(t: ^testing.T) {
	app := DEFAULT_APP
	storage: Render_Storage
	_, err := render(app, &storage)
	testing.expect_value(t, err, Render_Error.None)

	// Clamp at the top, then walk past the end.
	update(&app, input.Key_Event{code = .Up})
	testing.expect_value(t, app.selected, 0)
	for _ in 0 ..< 8 {
		update(&app, input.Key_Event{code = .Down})
	}
	testing.expect_value(t, app.selected, len(app.items) - 1)

	// The render follows the model: only the styling moves to the new selection.
	update(&app, input.Key_Event{code = .Up})
	testing.expect_value(t, app.selected, len(app.items) - 2)
	_, err = render(app, &storage)
	testing.expect_value(t, err, Render_Error.None)
	for cell, index in storage.buffer.cells {
		row := index / storage.buffer.columns
		column := index % storage.buffer.columns
		selected_run := row == 3 && column >= 2 && column < 6
		testing.expect_value(t, cell.style, item_style(selected_run))
	}
}

@(test)
test_rendering_is_deterministic_and_reuse_matches_fresh :: proc(t: ^testing.T) {
	// Two fresh workspaces produce byte-identical frames, and a warmed reused
	// workspace matches a fresh one: `init_from_buffer` + `destroy` is sound.
	fresh: Render_Storage
	expected, expected_err := render(DEFAULT_APP, &fresh)
	testing.expect_value(t, expected_err, Render_Error.None)

	second: Render_Storage
	again, again_err := render(DEFAULT_APP, &second)
	testing.expect_value(t, again_err, Render_Error.None)
	_expect_frames_equal(t, expected, again)

	reused: Render_Storage
	warmup := DEFAULT_APP
	warmup.columns = 12
	warmup.rows = 4
	warmup.selected = 2
	_, warmup_err := render(warmup, &reused)
	testing.expect_value(t, warmup_err, Render_Error.None)

	actual, actual_err := render(DEFAULT_APP, &reused)
	testing.expect_value(t, actual_err, Render_Error.None)
	_expect_frames_equal(t, expected, actual)
}

@(test)
test_resize_recomputes_geometry :: proc(t: ^testing.T) {
	app := DEFAULT_APP
	storage: Render_Storage
	_, err := render(app, &storage)
	testing.expect_value(t, err, Render_Error.None)
	testing.expect_value(t, storage.buffer.columns, 24)

	update(&app, input.Resize_Event{columns = 10, rows = 4})
	_, resized_err := render(app, &storage)
	testing.expect_value(t, resized_err, Render_Error.None)
	testing.expect_value(t, storage.buffer.columns, 10)
	testing.expect_value(t, storage.buffer.rows, 4)

	// The old geometry must not survive: nothing may be drawn past the new width,
	// and rows beyond the new viewport simply do not exist.
	row_storage: [64]byte
	expected := [?]string{"          ", "  alpha   ", "          ", "  beta    "}
	for row, index in expected {
		testing.expect_value(t, glyph_row(storage.buffer, index, row_storage[:]), row)
	}
}

@(test)
test_content_overflow_is_clipped :: proc(t: ^testing.T) {
	// Differential oracle: the reference resolves this root to its content
	// minimum (5 text cells + 4 horizontal padding = 9) and publishes one
	// viewport Overflow diagnostic on X with amount 3.
	app := DEFAULT_APP
	app.columns = 6
	app.rows = 6
	storage: Render_Storage
	_, err := render(app, &storage)
	testing.expect_value(t, err, Render_Error.None)

	frame_result, frame_error := layout.result(&storage.ctx)
	testing.expect_value(t, frame_error, layout.Frame_Error.None)
	// Node 0 is the frame root; the container is node 1, the first label node 2.
	testing.expect_value(t, frame_result.nodes[1].outer.size[0], layout.Scalar(9))
	testing.expect_value(t, frame_result.nodes[2].outer.position[0], layout.Scalar(2))
	testing.expect_value(t, frame_result.nodes[2].outer.size[0], layout.Scalar(5))

	found := false
	for diagnostic in layout.diagnostics(&storage.ctx) {
		if diagnostic.kind == .Overflow && diagnostic.node == 0 && diagnostic.axis == .X && diagnostic.amount == 3 {
			found = true
		}
	}
	testing.expect(t, found, "expected viewport Overflow X 3")

	row_storage: [64]byte
	testing.expect_value(t, glyph_row(storage.buffer, 1, row_storage[:]), "  alph")
}

@(test)
test_presenting_to_a_closed_session_reports_and_draws_nothing :: proc(t: ^testing.T) {
	// A zeroed session (never opened) reports Not_Open before any serialization
	// or write, so nothing can reach the terminal.
	session: term.Session
	storage: Render_Storage
	render_error, present_error := present_frame(&session, DEFAULT_APP, &storage)
	testing.expect_value(t, render_error, Render_Error.None)
	testing.expect(t, present_error == term.General_Error.Not_Open, "expected not-open error")
}
