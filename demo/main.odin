#+build linux
package main

import "core:fmt"
import "core:os"
import input "nabla:input"
import "nabla:layout"
import "nabla:tty"
import "nabla:tui"
import widgets "nabla:widgets"

// App is the demo model: a viewport and one selectable list. It exercises the
// full pipeline end to end: viewport -> layout -> Cell_Buffer ->
// plan_presentation -> present_operations, with keyboard input driving the
// selection.
App :: struct {
	columns:  int,
	rows:     int,
	items:    [3]string,
	selected: int,
	quit:     bool,
}

DEFAULT_APP :: App {
	items = {"alpha", "beta", "gamma"},
}

// MAX_PLAN_OPS sizes the operation scratch: worst case is one move + one
// style + one write/erase per logical cell, plus the full-redraw baseline.
MAX_PLAN_OPS :: 4096 * 3 + 8

// Render_Storage holds every buffer the pipeline needs for one frame, sized
// for a terminal up to roughly 128x32. cells is the current logical frame;
// previous_cells keeps the presented frame for the next diff (grapheme
// strings borrow from the demo's static item text, so copying the cell
// structs is safe). ops is the caller-owned operation scratch; output is the
// caller-owned reusable presentation scratch: 4096 logical cells at the
// worst-case ~66 serialized bytes per cell (reset + six modifier SGRs + two
// truecolor SGRs + a 4-byte grapheme) fits in 270336 bytes.
Render_Storage :: struct {
	ctx:             layout.Context,
	layout_storage:  [65536]byte,
	measure_context: tui.ASCII_Measure_Context,
	cells:           [4096]tui.Cell,
	previous_cells:  [4096]tui.Cell,
	buffer:          tui.Cell_Buffer,
	previous:        tui.Cell_Buffer,
	ops:             [MAX_PLAN_OPS]tty.Presentation_Op,
	output:          [270336]byte,
	first_frame:     bool,
	needs_redraw:    bool,
}

DEMO_CAPACITIES :: layout.Capacities {
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

SELECTED_STYLE :: tui.Style {
	foreground = tui.RGB_Color{0, 0, 0},
	background = tui.RGB_Color{255, 255, 0},
	modifiers  = {.Bold},
}

item_style :: proc(selected: bool) -> tui.Style {
	if selected {
		return SELECTED_STYLE
	}
	return tui.Style{}
}

// Render_Error classifies a failed frame; render returns it (present()'s
// own failures stay on the terminal side). The loop exits on a render
// failure — the demo has nothing to draw — but the session teardown still
// runs through the defer.
Render_Error :: enum u8 {
	None,
	Layout_Failed,
	Buffer_Too_Small,
	Not_Integral,
	Undrawable_Text,
}

// render runs the whole pipeline for one frame: compose, solve, project,
// and draw into the logical buffer. It touches no backend.
render :: proc(app: ^App, storage: ^Render_Storage) -> Render_Error {
	config := layout.Options {
		capacities = DEMO_CAPACITIES,
	}
	if layout.storage_size(config.capacities) > len(storage.layout_storage) {
		return .Buffer_Too_Small
	}
	layout.destroy(&storage.ctx)
	if layout.init_from_buffer(&storage.ctx, config, storage.layout_storage[:]) != nil {
		return .Layout_Failed
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
	if frame_error != .None {
		return .Layout_Failed
	}

	if !tui.init(&storage.buffer, app.columns, app.rows, storage.cells[:]) {
		return .Buffer_Too_Small
	}
	for item, index in app.items {
		node, found := layout.lookup(frame_result, layout.Id(index + 2))
		if !found {
			return .Layout_Failed
		}
		rect, projection_error := tui.project_rect_integral(node.outer)
		if projection_error != .None {
			return .Not_Integral
		}
		if _, ok := tui.draw_ascii(&storage.buffer, rect, item, item_style(index == app.selected)); !ok {
			return .Undrawable_Text
		}
	}
	return .None
}

// present_frame plans the diff against the previous frame and presents it as
// one buffered operation stream. The first frame and any frame after a
// failed write present a complete redraw (nil previous): a failed write
// leaves terminal state unspecified, and a later successful full frame is
// the recovery contract. After a successful present, the current buffer
// becomes the previous buffer for the next diff.
present_frame :: proc(session: ^tty.Session, app: ^App, storage: ^Render_Storage) -> (render_err: Render_Error, present_err: tty.Error) {
	if err := render(app, storage); err != .None {
		return err, nil
	}
	previous := Maybe(tui.Cell_Buffer)(nil)
	if !storage.first_frame && !storage.needs_redraw {
		previous = Maybe(tui.Cell_Buffer)(storage.previous)
	}
	ops, _, _, plan_err := tui.plan_presentation(storage.buffer, previous, tty.profile_default(), tty.Capabilities{}, storage.ops[:])
	switch plan_err {
	case .None:
	// The planner always fits: ops is sized for the worst-case per-cell
	// plan of the fixed 4096-cell grid.
	case .Buffer_Too_Small:
		return .Buffer_Too_Small, nil
	case .Invalid_Buffer, .Unsupported:
		return .Layout_Failed, nil
	}
	_, _, present_error := tty.present_operations(session, ops, tty.profile_default(), storage.output[:])
	if present_error != nil {
		// Terminal contents and cursor state are unspecified after a failed
		// write; the next frame must be a complete redraw.
		storage.needs_redraw = true
		return .None, present_error
	}
	copy(storage.previous_cells[:], storage.buffer.cells)
	storage.previous = {
		width  = storage.buffer.width,
		height = storage.buffer.height,
		cells  = storage.previous_cells[:len(storage.buffer.cells)],
	}
	storage.first_frame = false
	storage.needs_redraw = false
	return .None, nil
}

handle :: proc(app: ^App, event: input.Event) {
	switch data in event {
	case input.Key_Event:
		#partial switch data.code {
		case .Down:
			app.selected = min(app.selected + 1, len(app.items) - 1)
		case .Up:
			app.selected = max(app.selected - 1, 0)
		case .Escape:
			app.quit = true
		case .Character:
			if data.character == 'q' {
				app.quit = true
			}
		}
	case input.Resize_Event:
	// Resize is handled structurally: the loop re-reads the viewport
	// every frame.
	case input.End_Of_Input:
		app.quit = true
	case input.Unknown_Input:
	}
}

main :: proc() {
	session, open_err := tty.open({alternate_screen = true, hide_cursor = true, input_mode = .Raw})
	if open_err != nil {
		fmt.eprintln("demo: open failed:", open_err)
		os.exit(1)
	}
	defer { _ = tty.close(session) }

	tty_file, file_err := tty.session_file(session)
	if file_err != nil {
		fmt.eprintln("demo: session file:", file_err)
		os.exit(1)
	}

	parser: input.Parser
	input.parser_init(&parser)
	events: [dynamic]input.Event
	defer delete(events)

	app := DEFAULT_APP
	// Render_Storage is ~280 KB (fixed layout/cell buffers): heap-allocate it.
	storage := new(Render_Storage)
	defer free(storage)

	for !app.quit {
		viewport, vp_err := tty.viewport(session)
		if vp_err != nil {
			fmt.eprintln("demo: viewport:", vp_err)
			break
		}
		app.columns = viewport.columns
		app.rows = viewport.rows
		if render_err, present_err := present_frame(session, &app, storage); render_err != .None {
			fmt.eprintln("demo: render:", render_err)
			break
		} else if present_err != nil {
			fmt.eprintln("demo: present:", present_err)
			break
		}

		_, read_err := input.read_events(&parser, tty_file, &events, -1)
		if read_err != nil {
			fmt.eprintln("demo: read:", read_err)
			break
		}
		for event in events {
			handle(&app, event)
		}
		clear(&events)
	}
}
