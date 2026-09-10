#+build linux
package main

import input "nabla:input"
import "nabla:layout"
import "nabla:term"
import "nabla:tui"
import "nabla:widgets"

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
	case input.End_Of_Input:
	case input.Unknown_Input:
	}
}

SELECTED_STYLE :: tui.Style {
	foreground = tui.Indexed_Color(0),
	background = tui.Indexed_Color(7),
	modifiers  = {.Bold},
}

// item_style exists because a *constant* struct holding a union miscompiles when
// it reaches a conditional expression: `selected ? SELECTED_STYLE : tui.Style{}`
// makes LLVM reject the module with "PHI node operands are not the same type as
// the result". Copying the constant to a local first is enough to avoid it,
// which is why this reads `style := SELECTED_STYLE` rather than returning the
// constant directly. Broken on every Odin release that has the feature
// (dev-2025-11 through dev-2026-07a, verified).
item_style :: proc(selected: bool) -> tui.Style {
	if selected {
		selected_style := SELECTED_STYLE
		return selected_style
	}
	return tui.Style{}
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
	measure_context: tui.ASCII_Measure_Context,
	cells:           [512]tui.Cell,
	frame_cells:     [400]term.Cell,
	buffer:          tui.Cell_Buffer,
}

Render_Error :: enum u8 {
	None,
	Layout_Failed,
	Buffer_Too_Small,
	Not_Integral,
	Undrawable_Text,
	Presentation_Too_Small,
}

// render runs the whole pipeline for one frame: compose, solve, project, draw,
// plan. It touches no backend, which is what makes the boundary testable.
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
	layout.set_services(
		&storage.ctx,
		{measure_text = tui.ascii_measure_proc, measure_text_user_data = &storage.measure_context, break_text = tui.ascii_break_proc},
	)
	if layout.frame(&storage.ctx, viewport) {
		if layout.element(
			&storage.ctx,
			widgets.container_desc(
				widgets.Container {
					id = 1,
					style = {flow = .Column, sizing = {layout.grow(), layout.grow()}, padding = {left = 2, top = 1, right = 2, bottom = 1}, gap = 1},
				},
			),
		) {
			for item, index in app.items {
				layout.text(&storage.ctx, widgets.label_desc(widgets.Label{id = layout.Id(index + 2), text = item}, {layout.fit(), layout.fit()}))
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
		if _, ok := tui.draw_ascii(&storage.buffer, rect, item, item_style(index == app.selected)); !ok {
			return {}, .Undrawable_Text
		}
	}

	built, ok := tui.build_frame(storage.buffer, storage.frame_cells[:])
	if !ok {
		return {}, .Presentation_Too_Small
	}
	return built, .None
}

// expect_frames_equal compares two rendered frames field by field.
expect_frames_equal :: proc(t: ^T, first, second: term.Frame_Buffer) {
	expect_value(t, second.columns, first.columns)
	expect_value(t, second.rows, first.rows)
	expect_value(t, len(second.cells), len(first.cells))
	for cell, index in first.cells {
		expect_value(t, second.cells[index], cell)
	}
}

// present_frame is the only procedure in the slice that talks to the
// terminal. Everything else renders into the caller-owned buffer, which is
// what keeps the boundary testable without a tty. The output scratch is a
// fixed reusable buffer; the only test path that reaches present passes a
// closed session, so the scratch never actually fills.
present_frame :: proc(session: ^term.Session, app: App, storage: ^Render_Storage) -> (Render_Error, term.Error) {
	frame, render_error := render(app, storage)
	if render_error != nil {
		return render_error, nil
	}
	output: [4096]byte
	_, _, present_error := term.present(session, frame, term.profile_default(), {}, output[:])
	return .None, present_error
}

// glyph_row reads one row of the buffer as a string, so snapshots are legible in
// a failure message instead of being a wall of cell structs.
glyph_row :: proc(buffer: tui.Cell_Buffer, row: int, storage: []byte) -> string {
	count := 0
	for column in 0 ..< buffer.width {
		grapheme := buffer.cells[row * buffer.width + column].grapheme
		if len(grapheme) > 0 {
			storage[count] = grapheme[0]
		} else {
			storage[count] = ' '
		}
		count += 1
	}
	return string(storage[:count])
}

test_snapshot_is_known_and_complete :: proc(t: ^T) {
	app := DEFAULT_APP
	storage: Render_Storage
	_, err := render(app, &storage)
	expect_value(t, err, Render_Error.None)

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
		expect_value(t, glyph_row(storage.buffer, index, row_storage[:]), row)
	}
}

test_selection_is_the_only_styled_run :: proc(t: ^T) {
	app := DEFAULT_APP
	storage: Render_Storage
	_, err := render(app, &storage)
	expect_value(t, err, Render_Error.None)

	for cell, index in storage.buffer.cells {
		row := index / storage.buffer.width
		column := index % storage.buffer.width
		selected_run := row == 1 && column >= 2 && column < 7
		expected := item_style(selected_run)
		expect_value(t, cell.style, expected)
	}
}

test_two_identical_renders_produce_identical_output :: proc(t: ^T) {
	// Full redraw is the policy, so the correct invariant is byte equality of two
	// complete frames -- not "the second frame writes nothing", which would
	// presuppose a diff.
	app := DEFAULT_APP
	first_storage: Render_Storage
	second_storage: Render_Storage
	first, first_err := render(app, &first_storage)
	second, second_err := render(app, &second_storage)
	expect_value(t, first_err, Render_Error.None)
	expect_value(t, second_err, Render_Error.None)
	expect_frames_equal(t, first, second)
}

test_reused_storage_matches_fresh_storage :: proc(t: ^T) {
	app := DEFAULT_APP
	fresh: Render_Storage
	expected, expected_err := render(app, &fresh)
	expect_value(t, expected_err, Render_Error.None)

	reused: Render_Storage
	other := app
	other.columns = 12
	other.rows = 4
	other.selected = 2
	_, warmup_err := render(other, &reused)
	expect_value(t, warmup_err, Render_Error.None)

	actual, actual_err := render(app, &reused)
	expect_value(t, actual_err, Render_Error.None)
	expect_frames_equal(t, expected, actual)
}

test_key_event_moves_the_selection_and_render_follows :: proc(t: ^T) {
	app := DEFAULT_APP
	storage: Render_Storage
	_, err := render(app, &storage)
	expect_value(t, err, Render_Error.None)

	update(&app, input.Key_Event{code = .Down})
	expect_value(t, app.selected, 1)

	_, err = render(app, &storage)
	expect_value(t, err, Render_Error.None)

	// Full redraw is the policy: the whole frame is re-rendered, and only the
	// styling moved to the new selection. (Presenting the frame is exercised
	// end to end by the demo; the slice's render output is what changes.)
	for cell, index in storage.buffer.cells {
		row := index / storage.buffer.width
		column := index % storage.buffer.width
		selected_run := row == 3 && column >= 2 && column < 6
		expected := item_style(selected_run)
		expect_value(t, cell.style, expected)
	}
}

test_selection_is_clamped_at_the_ends :: proc(t: ^T) {
	app := DEFAULT_APP
	update(&app, input.Key_Event{code = .Up})
	expect_value(t, app.selected, 0)
	for _ in 0 ..< 8 {
		update(&app, input.Key_Event{code = .Down})
	}
	expect_value(t, app.selected, len(app.items) - 1)
}

test_resize_recomputes_geometry_without_stale_cache :: proc(t: ^T) {
	app := DEFAULT_APP
	storage: Render_Storage
	_, err := render(app, &storage)
	expect_value(t, err, Render_Error.None)
	expect_value(t, storage.buffer.width, 24)

	update(&app, input.Resize_Event{columns = 10, rows = 4})
	_, resized_err := render(app, &storage)
	expect_value(t, resized_err, Render_Error.None)
	expect_value(t, storage.buffer.width, 10)
	expect_value(t, storage.buffer.height, 4)

	// The old geometry must not survive: nothing may be drawn past the new width,
	// and rows beyond the new viewport simply do not exist.
	row_storage: [64]byte
	expected := [?]string{"          ", "  alpha   ", "          ", "  beta    "}
	for row, index in expected {
		expect_value(t, glyph_row(storage.buffer, index, row_storage[:]), row)
	}
}

test_content_wider_than_its_parent_overflows_and_is_clipped :: proc(t: ^T) {
	// Differential oracle: the reference resolves this root to its content
	// minimum (5 text cells + 4 horizontal padding = 9) and publishes one
	// viewport Overflow diagnostic on X with amount 3.
	app := DEFAULT_APP
	app.columns = 6
	app.rows = 6
	storage: Render_Storage
	_, err := render(app, &storage)
	expect_value(t, err, Render_Error.None)

	frame_result, frame_error := layout.result(&storage.ctx)
	expect_value(t, frame_error, layout.Frame_Error.None)
	// Node 0 is the frame root; the container is node 1, the first label node 2.
	expect_value(t, frame_result.nodes[1].outer.size[0], layout.Scalar(9))
	expect_value(t, frame_result.nodes[2].outer.position[0], layout.Scalar(2))
	expect_value(t, frame_result.nodes[2].outer.size[0], layout.Scalar(5))

	published := layout.diagnostics(&storage.ctx)
	found_horizontal := false
	for diagnostic in published {
		if diagnostic.kind == .Overflow && diagnostic.node == 0 && diagnostic.axis == .X && diagnostic.amount == 3 {
			found_horizontal = true
		}
	}
	expect(t, found_horizontal, "expected viewport Overflow X 3")

	row_storage: [64]byte
	expect_value(t, glyph_row(storage.buffer, 1, row_storage[:]), "  alph")
}

test_insufficient_presentation_capacity_fails_the_frame :: proc(t: ^T) {
	app := DEFAULT_APP
	// The frame needs one cell entry per buffer cell; this viewport exceeds
	// the frame_cells storage even though the cell storage fits. render fails
	// before anything could reach present (present_frame short-circuits on a
	// render error), so the terminal never sees a half-built frame.
	app.columns = 20
	app.rows = 21
	storage: Render_Storage
	_, render_error := render(app, &storage)
	expect_value(t, render_error, Render_Error.Presentation_Too_Small)

	// The next valid frame still works: a rejected frame leaves no wedged state.
	app = DEFAULT_APP
	_, render_error = render(app, &storage)
	expect_value(t, render_error, Render_Error.None)
}

test_presenting_to_a_closed_session_reports_and_draws_nothing :: proc(t: ^T) {
	// A zeroed session (never opened) reports Not_Open before any serialization
	// or write, so nothing can reach the terminal. The boundary claim that the
	// frame bytes are independent of the backend is pinned by the terminal
	// package's own serialization fixtures (present_test.odin) — the slice's
	// render output is deterministic (test_two_identical_renders...), and
	// render never sees a session.
	session: term.Session

	app := DEFAULT_APP
	storage: Render_Storage
	render_error, present_error := present_frame(&session, app, &storage)
	expect_value(t, render_error, Render_Error.None)
	expect(t, present_error == term.General_Error.Not_Open, "expected not-open error")
}
