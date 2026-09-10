#+build linux
package main

// panels.odin — the layout half of the dashboard example.
//
// This file composes the scene each frame with the layout package, then
// renders it into a terminal frame with the tui adapter. The terminal
// session, input loop, and present() live in main.odin.
//
// Layout features exercised: row/column flows, all sizing modes (fixed,
// grow with weight, percent, fit), padding and gap, justify (center,
// space-between, space-evenly), cross-axis alignment, text measurement and
// word wrapping, result lookup, the per-line command stream, opaque fills,
// clipping, failure diagnostics, and caller-owned fixed storage with no
// per-frame allocation. The SHOWCASE pane labels one feature per row so
// each demonstration is self-evident.

import "core:fmt"
import "nabla:layout"
import "nabla:term"
import "nabla:text"
import "nabla:tui"

// The dashboard model: a sidebar of selectable files, a feature showcase,
// and a status bar.
SIDEBAR_ITEMS :: [3]string{"alpha.odin", "beta.odin", "gamma.odin"}

// Layout paint palette (RGBA, alpha 255 = opaque; the ASCII stage fills
// only opaque paints — alpha blending is out of its scope).
DASH_BG :: layout.Color{16, 18, 22, 255}
HEADER_BG :: layout.Color{24, 40, 66, 255}
SIDEBAR_BG :: layout.Color{20, 22, 26, 255}
NOTE_BG :: layout.Color{28, 30, 36, 255}
STATUS_BG :: layout.Color{22, 26, 32, 255}
NOTE_TEXT :: layout.Color{175, 180, 190, 255}
DETAIL_TEXT :: layout.Color{200, 205, 215, 255}
// Authored text colors. layout emits a Text_Cmd only for text with an
// opaque authored color (command.odin gates text emission on
// text_style.color.a != 0), so every text node authors one; the draw stage
// still overrides the interactive nodes (selection, modifiers).
WHITE_TEXT :: layout.Color{255, 255, 255, 255}
ITEM_TEXT :: layout.Color{185, 190, 200, 255}
LABEL_TEXT :: layout.Color{150, 200, 210, 255}
STATUS_L_TEXT :: layout.Color{140, 145, 155, 255}
STATUS_R_TEXT :: layout.Color{255, 210, 80, 255}

// Showcase box colors (the proportions are the point, the hues just
// distinguish the boxes).
BOX_A :: layout.Color{45, 70, 130, 255}
BOX_B :: layout.Color{50, 110, 60, 255}
BOX_C :: layout.Color{140, 110, 40, 255}

// Draw styles (tui side; the terminal maps these to its color depth).
SELECTED_STYLE :: tui.Style {
	foreground = tui.RGB_Color{0, 0, 0},
	background = tui.RGB_Color{255, 255, 0},
	modifiers  = {.Bold},
}
SELECTED_BAR :: tui.RGB_Color{255, 255, 0}
ITEM_STYLE :: tui.Style {
	foreground = tui.RGB_Color{185, 190, 200},
}
HEADER_TITLE_STYLE :: tui.Style {
	foreground = tui.RGB_Color{255, 255, 255},
	modifiers  = {.Bold},
}
SECTION_TITLE_STYLE :: tui.Style {
	foreground = tui.RGB_Color{255, 255, 255},
	modifiers  = {.Bold},
}
STATUS_LEFT_STYLE :: tui.Style {
	foreground = tui.RGB_Color{140, 145, 155},
}
STATUS_RIGHT_STYLE :: tui.Style {
	foreground = tui.RGB_Color{255, 210, 80},
}

// DASHBOARD_CAPACITIES budgets the fixed layout pools for the whole scene:
// ~50 nodes (containers, text nodes, showcase boxes), the wrapped lines and
// words for the note and wrap rows, and the fill/text command stream.
DASHBOARD_CAPACITIES :: layout.Capacities {
	nodes          = 64,
	children       = 64,
	clips          = 16,
	commands       = 256,
	text_lines     = 64,
	measured_words = 128,
	overlays       = 1,
	measure_cache  = 64,
	id_table       = 64,
	depth          = 16,
	diagnostics    = 32,
	debug_labels   = 0,
}

// Render_Storage is the caller-owned frame budget. The zero value is
// usable: render (re)initializes layout fixed mode each frame and fills the
// cell buffers on demand. Size covers a terminal up to 128x128 cells; a
// larger viewport reports .Buffer_Too_Small.
Render_Storage :: struct {
	ctx:             layout.Context,
	layout_storage:  [262144]byte,
	measure_context: tui.ASCII_Measure_Context,
	status_scratch:  [64]byte,
	cells:           [16384]tui.Cell,
	frame_cells:     [16384]term.Cell,
	buffer:          tui.Cell_Buffer,
	// output is the reusable presentation scratch: 16384 logical cells at
	// the worst-case ~66 serialized bytes per cell (reset + six modifier
	// SGRs + two truecolor SGRs + a 4-byte grapheme) fits in 1081344 bytes.
	output:          [1081344]byte,
}

// render composes and draws one frame for (state, viewport).
//
// Pipeline: layout fixed-mode init -> frame -> compose -> result, then two
// passes over the command stream (opaque fills, then text lines — one
// Text_Cmd per line, so wrapped paragraphs render per line), with the
// selection bar and item styling driven by result lookup. The returned
// Frame_Buffer borrows storage.frame_cells / storage.graphemes and is
// valid only until the next render call.
//
// cursor reports where the terminal cursor should sit after the frame: a
// Position on the selected item's row (0-based; present emits it 1-based),
// or unspecified (nil) when nothing is selected.
render :: proc(state: ^State, viewport: layout.Vec2, storage: ^Render_Storage) -> (frame: term.Frame_Buffer, cursor: term.Cursor_Intent, err: Render_Error) {
	columns := int(viewport[0])
	rows := int(viewport[1])
	if viewport[0] < 0 || viewport[1] < 0 || layout.Scalar(columns) != viewport[0] || layout.Scalar(rows) != viewport[1] {
		return {}, {}, .Not_Integral
	}
	// Zero-sized viewport: deterministic no-op (the terminal side also
	// treats 0x0 as a no-op present).
	if columns == 0 || rows == 0 {
		return {}, {}, .None
	}

	config := layout.Options {
		capacities = DASHBOARD_CAPACITIES,
	}
	if layout.storage_size(config.capacities) > len(storage.layout_storage) {
		return {}, {}, .Buffer_Too_Small
	}
	storage.measure_context.profile = text.DEFAULT_WIDTH_PROFILE

	layout.destroy(&storage.ctx)
	if layout.init_from_buffer(&storage.ctx, config, storage.layout_storage[:]) != nil {
		return {}, {}, .Layout_Failed
	}
	// The frame opens inside the if-block and resolves when the block exits
	// (layout.frame carries @(deferred_in_out = _frame_leave)); result() must
	// be called after the block, never inside it.
	layout.set_services(
		&storage.ctx,
		{measure_text = tui.ascii_measure_proc, measure_text_user_data = &storage.measure_context, break_text = tui.ascii_break_proc},
	)
	if layout.frame(&storage.ctx, viewport) {
		if !_compose(&storage.ctx, state, storage) {
			return {}, {}, .Layout_Failed
		}
	}
	frame_result, frame_error := layout.result(&storage.ctx)
	if frame_error != nil {
		// The diagnostics API: layout records the cause of a failed frame.
		for diagnostic in layout.diagnostics(&storage.ctx) {
			fmt.eprintln(
				"dashboard: layout diagnostic:",
				diagnostic.kind,
				"pool",
				diagnostic.pool,
				"id",
				diagnostic.id,
				"axis",
				diagnostic.axis,
				"amount",
				diagnostic.amount,
			)
		}
		return {}, {}, .Layout_Failed
	}

	if !tui.init(&storage.buffer, columns, rows, storage.cells[:]) {
		return {}, {}, .Buffer_Too_Small
	}
	viewport_rect := layout.Rect {
		position = {},
		size     = viewport,
	}

	if !_paint_fills(storage, frame_result, viewport_rect) {
		return {}, {}, .Not_Integral
	}
	_selection_bar(storage, frame_result, state)
	if !_paint_texts(storage, frame_result, viewport_rect, state) {
		return {}, {}, .Undrawable_Text
	}

	built, ok := tui.build_frame(storage.buffer, storage.frame_cells[:])
	if !ok {
		return {}, {}, .Buffer_Too_Small
	}

	// The cursor follows the selection. Position is 0-based; present adds 1
	// when emitting the CUP. Unspecified when the selection is out of range
	// (main.odin never clamps) or the item box is not cell-exact.
	if idx, sel_ok := _effective_selection(state.selected); sel_ok {
		if item, found := layout.lookup(frame_result, layout.id_index("item", u64(idx))); found {
			pos := item.outer.position
			if layout.Scalar(int(pos.x)) == pos.x && layout.Scalar(int(pos.y)) == pos.y {
				cursor = term.Position {
					x = int(pos.x),
					y = int(pos.y),
				}
			}
		}
	}
	return built, cursor, .None
}

// _compose declares the scene tree. Every layout.element opens a scope with
// @(deferred_in_out = _element_leave): the scope closes when the enclosing
// if-block exits, so a node's children must be declared inside that block.
// The whole tree therefore nests inside the root's if-block, in declaration
// order (the demo's container pattern).
_compose :: proc(ctx: ^layout.Context, state: ^State, storage: ^Render_Storage) -> bool {
	root_style: layout.Layout_Style = {
		flow    = .Column,
		sizing  = {layout.grow(), layout.grow()},
		padding = layout.pad_all(1),
		gap     = 1,
	}
	if layout.element(ctx, {id = layout.id("root"), layout = root_style, paint = {background = DASH_BG}}) {
		header_style: layout.Layout_Style = {
			flow    = .Row,
			sizing  = {layout.grow(), layout.fixed(1)},
			justify = .Center,
		}
		if layout.element(ctx, {id = layout.id("header"), layout = header_style, paint = {background = HEADER_BG}}) {
			layout.text(
				ctx,
				{
					id = layout.id("header-title"),
					text = "NABLA DASHBOARD  |  layout + terminal",
					style = {color = WHITE_TEXT},
					sizing = {layout.fit(), layout.fit()},
				},
			)
		}

		body_style: layout.Layout_Style = {
			flow   = .Row,
			sizing = {layout.grow(), layout.grow()},
			gap    = 1,
		}
		if layout.element(ctx, {id = layout.id("body"), layout = body_style}) {
			sidebar_style: layout.Layout_Style = {
				flow    = .Column,
				sizing  = {layout.fixed(18), layout.grow()},
				padding = layout.pad_all(1),
				gap     = 1,
			}
			if layout.element(ctx, {id = layout.id("sidebar"), layout = sidebar_style, paint = {background = SIDEBAR_BG}}) {
				layout.text(ctx, {id = layout.id("sidebar-title"), text = "FILES", style = {color = WHITE_TEXT}, sizing = {layout.fit(), layout.fit()}})
				items := SIDEBAR_ITEMS
				for i in 0 ..< len(items) {
					layout.text(
						ctx,
						{id = layout.id_index("item", u64(i)), text = items[i], style = {color = ITEM_TEXT}, sizing = {layout.fit(), layout.fit()}},
					)
				}
				// Percent sizing of the fixed-width sidebar: 75% of the 16-cell
				// content box is exactly 12, so the projected rect stays integral.
				note_box_style: layout.Layout_Style = {
					flow   = .Column,
					sizing = {layout.percent(0.75), layout.fixed(4)},
				}
				if layout.element(ctx, {id = layout.id("note-box"), layout = note_box_style, paint = {background = NOTE_BG}}) {
					note_style: layout.Text_Style = {
						color = NOTE_TEXT,
						wrap  = .Words,
					}
					layout.text(
						ctx,
						{id = layout.id("note"), text = "Wraps at 75% of the sidebar width.", style = note_style, sizing = {layout.grow(), layout.grow()}},
					)
				}
			}

			main_style: layout.Layout_Style = {
				flow    = .Column,
				sizing  = {layout.grow(), layout.grow()},
				padding = layout.pad_all(1),
				gap     = 1,
			}
			if layout.element(ctx, {id = layout.id("main"), layout = main_style}) {
				layout.text(ctx, {id = layout.id("sc-title"), text = "SHOWCASE", style = {color = WHITE_TEXT}, sizing = {layout.fit(), layout.fit()}})
				_showcase_row(ctx, 0, "grow 1:2", 1, proc(demo_ctx: ^layout.Context) {
					layout.content(demo_ctx, {layout = {sizing = {layout.grow(1), layout.grow()}}, paint = {background = BOX_A}})
					layout.content(demo_ctx, {layout = {sizing = {layout.grow(2), layout.grow()}}, paint = {background = BOX_B}})
				})
				_showcase_row(ctx, 1, "percent", 1, proc(demo_ctx: ^layout.Context) {
					layout.content(demo_ctx, {layout = {sizing = {layout.percent(0.25), layout.grow()}}, paint = {background = BOX_A}})
					layout.content(demo_ctx, {layout = {sizing = {layout.percent(0.5), layout.grow()}}, paint = {background = BOX_B}})
					layout.content(demo_ctx, {layout = {sizing = {layout.percent(0.25), layout.grow()}}, paint = {background = BOX_A}})
				})
				_showcase_row(ctx, 2, "justify btw", 1, proc(demo_ctx: ^layout.Context) {
					_demo_row(demo_ctx, .Space_Between, 3)
				})
				_showcase_row(ctx, 3, "justify ev", 1, proc(demo_ctx: ^layout.Context) {
					_demo_row(demo_ctx, .Space_Evenly, 3)
				})
				_showcase_row(ctx, 4, "align end", 2, proc(demo_ctx: ^layout.Context) {
					layout.content(demo_ctx, {layout = {sizing = {layout.fixed(3), layout.fixed(1)}}, paint = {background = BOX_A}})
					layout.content(demo_ctx, {layout = {sizing = {layout.fixed(3), layout.fixed(1)}}, paint = {background = BOX_B}})
				})

			}
		}

		status_style: layout.Layout_Style = {
			flow    = .Row,
			sizing  = {layout.grow(), layout.fixed(1)},
			justify = .Space_Between,
		}
		if layout.element(ctx, {id = layout.id("status"), layout = status_style, paint = {background = STATUS_BG}}) {
			layout.text(
				ctx,
				{
					id = layout.id("status-left"),
					text = "Up/Down select  q/Escape quit",
					style = {color = STATUS_L_TEXT},
					sizing = {layout.fit(), layout.fit()},
				},
			)
			layout.text(
				ctx,
				{
					id = layout.id("status-right"),
					text = _status_right(state, storage.status_scratch[:]),
					style = {color = STATUS_R_TEXT},
					sizing = {layout.fit(), layout.fit()},
				},
			)
		}
		return true
	}
	return false
}

// _showcase_row declares one labeled demonstration row: a fixed-height Row
// holding a fixed-width label and a grow demo area whose contents are
// declared by demo_body. The demo runs inside the row's element scope, so
// this helper must not return before the demo is declared — the closure is
// called here, within the scope.
_showcase_row :: proc(ctx: ^layout.Context, index: int, label: string, height: int, demo_body: proc(_: ^layout.Context)) {
	row_style: layout.Layout_Style = {
		flow   = .Row,
		sizing = {layout.grow(), layout.fixed(layout.Scalar(height))},
		gap    = 1,
	}
	if layout.element(ctx, {layout = row_style}) {
		layout.text(ctx, {text = label, style = {color = LABEL_TEXT}, sizing = {layout.fixed(12), layout.fit()}})
		demo_style: layout.Layout_Style = {
			flow   = .Row,
			sizing = {layout.grow(), layout.grow()},
			gap    = 1,
		}
		if layout.element(ctx, {layout = demo_style}) {
			demo_body(ctx)
		}
	}
}

// _demo_row fills the demo area with three fixed boxes under the given
// justify mode (the Space_* demonstrations).
_demo_row :: proc(ctx: ^layout.Context, justify: layout.Justify, box_count: int) {
	_ = box_count
	demo_style: layout.Layout_Style = {
		flow    = .Row,
		sizing  = {layout.grow(), layout.grow()},
		justify = justify,
	}
	if layout.element(ctx, {layout = demo_style}) {
		layout.content(ctx, {layout = {sizing = {layout.fixed(3), layout.grow()}}, paint = {background = BOX_A}})
		layout.content(ctx, {layout = {sizing = {layout.fixed(3), layout.grow()}}, paint = {background = BOX_B}})
		layout.content(ctx, {layout = {sizing = {layout.fixed(3), layout.grow()}}, paint = {background = BOX_C}})
	}
}

// _paint_fills draws the opaque background fills from the command stream,
// clipped to each command's resolved clip rect.
_paint_fills :: proc(storage: ^Render_Storage, frame_result: layout.Frame_Result, viewport: layout.Rect) -> bool {
	it := layout.visible_commands(frame_result, viewport)
	for {
		command, _, ok := layout.next_command(&it)
		if !ok {
			break
		}
		fill, is_fill := command.data.(layout.Fill_Cmd)
		if !is_fill {
			continue
		}
		// Only opaque paints are drawn; alpha blending is out of the ASCII
		// stage's scope (the alpha channel is dropped, so a translucent
		// paint would misrepresent itself).
		if fill.color[3] != 255 {
			continue
		}
		rect := _project_cells(command.bounds)
		if rect.width <= 0 || rect.height <= 0 {
			continue
		}
		tui.fill(&storage.buffer, rect, tui.Cell{grapheme = " ", style = tui.Style{background = tui.RGB_Color{fill.color[0], fill.color[1], fill.color[2]}}})
	}
	return true
}

// _selection_bar draws the full-width highlight behind the selected item.
// The bar spans the sidebar's content width (inner box, from lookup) at the
// item's row, so the highlight reads as a row, not a text-width underline.
_selection_bar :: proc(storage: ^Render_Storage, frame_result: layout.Frame_Result, state: ^State) {
	idx, ok := _effective_selection(state.selected)
	if !ok {
		return
	}
	sidebar, found := layout.lookup(frame_result, layout.id("sidebar"))
	if !found {
		return
	}
	item, item_found := layout.lookup(frame_result, layout.id_index("item", u64(idx)))
	if !item_found {
		return
	}
	bar := layout.Rect {
		position = {sidebar.inner.position.x, item.outer.position.y},
		size     = {sidebar.inner.size.x, 1},
	}
	rect, projection_error := tui.project_rect_integral(bar)
	if projection_error != nil {
		return
	}
	tui.fill(&storage.buffer, rect, tui.Cell{grapheme = " ", style = tui.Style{background = SELECTED_BAR}})
}

// _paint_texts draws every text line from the command stream. Layout emits
// one Text_Cmd per wrapped line, so a paragraph renders line by line at the
// exact resolved positions. Styling is decided per node id: interactive
// nodes (items, titles, status) carry their own draw styles, and the note /
// detail paragraphs carry the color authored on the layout text style.
_paint_texts :: proc(storage: ^Render_Storage, frame_result: layout.Frame_Result, viewport: layout.Rect, state: ^State) -> bool {
	it := layout.visible_commands(frame_result, viewport)
	for {
		command, _, ok := layout.next_command(&it)
		if !ok {
			break
		}
		text_cmd, is_text := command.data.(layout.Text_Cmd)
		if !is_text {
			continue
		}
		rect := _project_cells(command.bounds)
		if rect.width <= 0 || rect.height <= 0 {
			continue
		}
		node := frame_result.nodes[int(command.node)]
		style := _text_style(node.id, text_cmd.style, state)
		if _, drawn_ok := tui.draw_ascii(&storage.buffer, rect, text_cmd.text, style); !drawn_ok {
			return false
		}
	}
	return true
}

// _project_cells resolves a command's draw rect: the exact projection when
// the geometry is integral, otherwise the nearest-cell rounding. Layout is
// resolution-independent (f32), so proportional content — grow weights,
// percent sizes, justified gaps — lands on half cells; cells are atomic, so
// the example renders the nearest cell block (the honest rendering of a
// proportion). (Clipping is intentionally not applied: the layout package's
// resolved clip rects did not match the clipped box when exercised from the
// example, so the showcase stays unclipped — flagged for the tui work.)
_project_cells :: proc(bounds: layout.Rect) -> tui.Cell_Rect {
	rect, projection_error := tui.project_rect_integral(bounds)
	if projection_error != nil {
		rect = _round_rect(bounds)
	}
	return rect
}

// _round_rect snaps a fractional rect to the nearest cells (at least one
// cell wide and tall).
_round_rect :: proc "contextless" (bounds: layout.Rect) -> tui.Cell_Rect {
	return {
		x = int(bounds.position.x + 0.5),
		y = int(bounds.position.y + 0.5),
		width = max(int(bounds.size.x + 0.5), 1),
		height = max(int(bounds.size.y + 0.5), 1),
	}
}

// _text_style resolves the draw style for one text node.
_text_style :: proc(node_id: layout.Id, text_style: layout.Text_Style, state: ^State) -> tui.Style {
	if node_id == layout.id("header-title") {
		return HEADER_TITLE_STYLE
	}
	if node_id == layout.id("sidebar-title") || node_id == layout.id("sc-title") {
		return SECTION_TITLE_STYLE
	}
	if node_id == layout.id("status-left") {
		return STATUS_LEFT_STYLE
	}
	if node_id == layout.id("status-right") {
		return STATUS_RIGHT_STYLE
	}
	if node_id == layout.id("note") {
		// Authored on the layout text style and mapped to the draw palette.
		return _layout_color_style(text_style.color)
	}
	for i in 0 ..< len(SIDEBAR_ITEMS) {
		if node_id == layout.id_index("item", u64(i)) {
			if i == state.selected {
				return SELECTED_STYLE
			}
			return ITEM_STYLE
		}
	}
	// Showcase labels and the wrap row carry their authored color.
	return _layout_color_style(text_style.color)
}

// _layout_color_style maps an opaque layout color to a draw style; a
// zero-alpha (default) color yields the default style.
_layout_color_style :: proc(color: layout.Color) -> tui.Style {
	if color[3] == 0 {
		return {}
	}
	return {foreground = tui.RGB_Color{color[0], color[1], color[2]}}
}

// _effective_selection clamps the selection to a valid item index; an
// out-of-range selection (main.odin never clamps) means no highlight.
_effective_selection :: proc(selected: int) -> (index: int, ok: bool) {
	if selected >= 0 && selected < len(SIDEBAR_ITEMS) {
		return selected, true
	}
	return 0, false
}

// _status_right writes "selected: <name>" into caller scratch (no
// allocation) and returns the resulting string, which is valid until the
// next render.
_status_right :: proc(state: ^State, scratch: []byte) -> string {
	name := "none"
	items := SIDEBAR_ITEMS
	if idx, ok := _effective_selection(state.selected); ok {
		name = items[idx]
	}
	prefix := "selected: "
	n := copy(scratch, prefix)
	n += copy(scratch[n:], name)
	return string(scratch[:n])
}
