#+build linux
package main

// Draws the frame: the conversation, a rule, the input line, another rule, and a
// two-line footer, into term's grid, then presents it. The screen is a projection of
// runtime state; nothing here owns conversation state.

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"

import "nabla:layout"
import "nabla:markdown"
import "nabla:term"
import "nabla:text"
import "nabla:tui"
import "nabla:tui/markdown_view"
import "nabla:tui/widgets"

// The prompt shows at most ten wrapped rows. Its border adds two more, then
// the working directory and status each use one row.
INPUT_MAX_ROWS :: 10

// Styles use the terminal's default foreground/background and ANSI palette.
// Indexed status colors follow the user's terminal theme instead of defining a
// Nabla theme.
RULE_STYLE :: term.Style {
	modifiers = {.Dim},
}

// The working indicator: the reference TUI's braille spinner, shown only while a
// request is active.
WORKING_LABEL :: "Working"
// SPINNER_INTERVAL is one spinner frame.
SPINNER_INTERVAL :: 100 * time.Millisecond

WORKING_BORDER_TEXT :: term.Style {
	foreground = term.Indexed_Color(5),
}
LABEL_STYLE :: term.Style {
	modifiers = {.Bold},
}
// A user message is a band across the terminal. Its background is the terminal's
// brightest color with dark text, so the text keeps its contrast however the theme is set.
USER_TEXT :: term.Style {
	background = term.Indexed_Color(15),
	foreground = term.Indexed_Color(0),
}
// A subagent message is a band like a user message. Its background is the
// terminal's darkest color with light text, so the two read apart.
SUBAGENT_TEXT :: term.Style {
	background = term.Indexed_Color(0),
	foreground = term.Indexed_Color(15),
}
// The heading of a subagent message names who sent it and why. Bold sets it
// apart from the body; the background and light text match the band behind it.
SUBAGENT_LABEL :: term.Style {
	background = term.Indexed_Color(0),
	foreground = term.Indexed_Color(15),
	modifiers  = {.Bold},
}
AGENT_TEXT :: term.Style{}
NOTICE_TEXT :: term.Style {
	foreground = term.Indexed_Color(6),
}
WARNING_TEXT :: term.Style {
	foreground = term.Indexed_Color(3),
}
ERROR_TEXT :: term.Style {
	foreground = term.Indexed_Color(1),
}
// A tool box draws its border in the outcome color and its content in ordinary
// text, so a failed call is marked without tinting everything inside it.
TOOL_BODY :: term.Style{}
TOOL_SUCCESS :: term.Style {
	foreground = term.Indexed_Color(2),
}
// A Code Mode box draws its border in blue, so a script and the calls it made read
// apart from a direct tool call. Its content is ordinary text, like any tool box.
CODEMODE_SUCCESS :: term.Style {
	foreground = term.Indexed_Color(4),
}
TOOL_FAILURE :: term.Style {
	foreground = term.Indexed_Color(1),
}
INPUT_TEXT :: term.Style{}
INPUT_PROMPT :: term.Style {
	modifiers = {.Bold},
}
TITLE_STYLE :: term.Style {
	modifiers = {.Bold},
}
HINT_STYLE :: term.Style {
	modifiers = {.Dim},
}
FOOTER_TEXT :: term.Style{}
FOOTER_MUTED :: term.Style {
	modifiers = {.Dim},
}
PICKED_STYLE :: term.Style {
	modifiers = {.Bold},
}

// TOOL_WINDOW_ROWS is how many content rows a tool box shows at once. A result
// with more rows is a window the wheel scrolls, and the box's bottom border says
// how many rows it is holding back.
TOOL_WINDOW_ROWS :: 10

// TOOL_CONTENT_START is the column a box's result row starts at, which its tabs expand from.
TOOL_CONTENT_START :: 1

// FOCUS_HINT is on the prompt's border while the keyboard drives the transcript.
FOCUS_HINT :: " ↑↓ rows/boxes · enter tool · tab prompt "
ACTIVE_BOX_HINT :: " ↑↓ box · enter collapse · esc deactivate "

// STARTUP_HINT is what an empty transcript shows under the title.
STARTUP_HINT :: "pgup/wheel scroll | escape interrupt | ctrl+c clear/cancel/quit | /help for commands"

// CONVERSATION_ID names the transcript's scroll-container root inside the
// frame, so the solved scroll range can be looked up after the solve.
CONVERSATION_ID :: layout.Id(1)

// TOKENS_PER_THOUSAND and TOKENS_PER_TENTH_MILLION are the units footer token counts round to.
TOKENS_PER_THOUSAND :: 1000
TOKENS_PER_TENTH_MILLION :: 100_000

// CONVERSATION_CAPACITIES is where one transcript frame's budget starts: room for about a
// screen of entries, not for every entry a session ever produced. A frame that outgrows a
// pool reports it, and conversation_solve raises the budget, so the storage settles at
// the transcript's own high-water mark instead of a worst-case reservation.
CONVERSATION_CAPACITIES :: layout.Capacities {
	nodes          = 512,
	children       = 1024,
	clips          = 16,
	commands       = 512,
	text_lines     = 1024,
	measured_words = 4096,
	tracks         = 64,
	measure_cache  = 512,
	id_table       = 8,
	depth          = 8,
	diagnostics    = 64,
}

// CONVERSATION_GROW_ATTEMPTS bounds how many times one solve may raise the
// budget. A frame reports one exhausted pool at a time, and growth doubles it,
// so the attempts cover several pools raised in sequence; the bound is what
// fails the frame instead of looping when a pool cannot be satisfied.
CONVERSATION_GROW_ATTEMPTS :: 16

// Line is one wrapped display line: text is borrowed from frame scratch and
// lives until the frame is presented.
Line :: struct {
	text:   string,
	style:  term.Style,
	indent: int,
}

// input_content_width is the columns the prompt's text is drawn in: the frame's
// content rect, less the box's border and its one-cell inset on each side. The
// caret's rows are wrapped at this width, so the key handler and the box have to
// agree on it.
input_content_width :: proc(app: ^App) -> int {
	return max(app.columns - 6, 1)
}

Render_Status :: enum u8 {
	None,
	Too_Small,
	Layout_Failed,
	Buffer_Too_Small,
	// The frame could not be composed because an allocation failed; the next
	// frame retries with a reset temp pool.
	Allocation_Failed,
}

// Frame_Storage is the caller-owned frame budget: the screen, the Markdown
// presentation cache, and the layout context, whose storage grows to the
// transcript it is given.
Frame_Storage :: struct {
	screen:            tui.Screen,
	alloc:             mem.Allocator,
	markdown:          Markdown_Cache,
	// links is this frame's hyperlink table (term.Frame_Buffer.links); the URIs are
	// views into markdown's records, which live through the frame's present.
	links:             [dynamic]string,
	// paints resolves the ids this frame's declarations carry; cleared with links.
	paints:            tui.Paints,
	layout_ctx:        layout.Context,
	// capacities is what layout_ctx is currently sized for. The context owns its
	// storage, so the budget is raised through layout.reserve as the transcript
	// outgrows it, and this is the base a raise is computed from.
	capacities:        layout.Capacities,
	measure:           tui.Measure_Context,
	// conversation_rows is the transcript area's height in the frame being drawn, which bounds a picture.
	conversation_rows: int,
	// cell_pixels is the size of a terminal cell in pixels, zero when unknown.
	cell_pixels:       [2]int,
	// shown is the images this frame draws; placed is what the terminal holds; uploads and stale are the work images_collect found between them.
	shown:             [dynamic]tui.Image_Placement,
	placed:            [dynamic]tui.Image_Placement,
	uploads:           [dynamic]Image_Upload,
	stale:             [dynamic]term.Image_Id,
	// graphics_failed latches the one warning a failing image write produces.
	graphics_failed:   bool,
}

@(require_results)
frame_storage_new :: proc(alloc := context.allocator) -> ^Frame_Storage {
	storage, storage_error := new(Frame_Storage, alloc)
	if storage_error != nil { return nil }
	storage.alloc = alloc
	tui.screen_init(&storage.screen, alloc)
	storage.links = make([dynamic]string, alloc)
	storage.paints = make(tui.Paints, alloc)
	storage.shown = make([dynamic]tui.Image_Placement, alloc)
	storage.placed = make([dynamic]tui.Image_Placement, alloc)
	storage.uploads = make([dynamic]Image_Upload, alloc)
	storage.stale = make([dynamic]term.Image_Id, alloc)
	markdown_cache_init(&storage.markdown, alloc)
	// Measurement and drawing share one width policy, so a tab or an
	// emoji-presentation sequence measures the columns drawing produces.
	// The zero profile would drop tabs while drawing expands them, and the
	// box math below would place the border from the wrong width.
	storage.measure.profile = text.DEFAULT_WIDTH_PROFILE
	storage.capacities = CONVERSATION_CAPACITIES
	config := layout.Options {
		capacities = storage.capacities,
		cull       = .Visible,
		snap       = 1,
	}
	// layout.init gives the context storage of its own, which is what makes the
	// budget raisable: init_from_buffer storage belongs to the caller, and a
	// context built on it cannot reserve.
	if layout.init(&storage.layout_ctx, config, alloc) != nil {
		markdown_cache_destroy(&storage.markdown)
		frame_storage_tables_destroy(storage)
		free(storage, alloc)
		return nil
	}
	return storage
}

frame_storage_tables_destroy :: proc(storage: ^Frame_Storage) {
	delete(storage.links)
	delete(storage.paints)
	delete(storage.shown)
	delete(storage.placed)
	for &upload in storage.uploads { delete(upload.pixels) }
	delete(storage.uploads)
	delete(storage.stale)
}

frame_storage_destroy :: proc(storage: ^Frame_Storage) {
	// A launch that could not allocate the budget has none to release.
	if storage == nil { return }
	tui.screen_destroy(&storage.screen)
	markdown_cache_destroy(&storage.markdown)
	frame_storage_tables_destroy(storage)
	layout.destroy(&storage.layout_ctx)
	free(storage, storage.alloc)
}

// present_frame renders the runtime snapshot and writes the frame to the terminal. The
// runtime mutex is held only for the render: everything the grid holds is this thread's
// state or a copy taken out of the snapshot under that lock, so the write does not hold
// up the worker.
present_frame :: proc(app: ^App, storage: ^Frame_Storage) {
	// Transient frame scratch is temp-allocated; cached Markdown uses frame storage
	// and survives this reset. The previous frame was already presented, so its
	// remaining borrows are dead and the pool can be recycled.
	free_all(context.temp_allocator)
	cursor: term.Cursor
	err: Render_Status
	transcript_sync(app)
	for {
		if sync.mutex_guard(&app.run.mu) {
			cursor, err = render_frame(app, storage)
		}
		if err != .None { return }
		if !transcript_slide(app) { break }
		// This grid will be replaced, not presented. Its scratch-backed cells and
		// links are no longer read; the final grid keeps them through screen_present.
		free_all(context.temp_allocator)
	}
	images_sync(app, storage)
	if present_err := tui.screen_present(&storage.screen, app.terminal, term.profile_default(), cursor); present_err != nil {
		fmt.eprintln("nabla: present:", present_err)
	}
}

// render_frame composes one frame from the current snapshot, and the caller holds the
// runtime mutex. Every string it puts in the grid must outlive the lock: the snapshot's
// mutable strings are copied into frame scratch, and a borrow straight from the snapshot
// would dangle once the worker replaces it.
@(require_results)
render_frame :: proc(app: ^App, storage: ^Frame_Storage) -> (cursor: term.Cursor, err: Render_Status) {
	cols, rows := app.columns, app.rows
	if cols <= 0 || rows <= 0 {
		return {}, .None
	}
	if rows < 6 {
		return {}, .Too_Small
	}
	if _, begin_err := tui.screen_begin(&storage.screen, cols, rows); begin_err != nil {
		return {}, .Buffer_Too_Small
	}
	clear(&storage.shown)

	// The prompt grows with wrapped input until ten content rows, then keeps the
	// caret visible by scrolling those rows inside its border.
	content := tui.Cell_Rect {
		x      = 1,
		y      = 0,
		width  = max(cols - 2, 0),
		height = rows,
	}
	input_rows, input_rows_error := input_visible_rows(&app.input, input_content_width(app))
	if input_rows_error != nil {
		return {}, .Allocation_Failed
	}
	heights := [4]int{-1, input_rows + 2, 1, 1}
	regions: [4]tui.Cell_Rect
	if !tui.rows(content, heights[:], regions[:]) {
		return {}, .Layout_Failed
	}
	conv_rect := regions[0]
	input_rect := regions[1]
	cwd_rect := regions[2]
	status_rect := regions[3]
	// A mouse report arrives as screen cells, while the frame is solved in the
	// conversation's own coordinates. Remembering where the conversation landed
	// is what lets the report be aimed at a tool box inside it.
	app.conversation_rect = conv_rect

	if conv_rect.width <= 0 && input_rect.width <= 0 {
		return {}, .Layout_Failed
	}

	if app.menu_open {
		draw_menu(app, storage, conv_rect)
		draw_input_hint(app, storage, input_rect)
	} else {
		if !draw_conversation(app, storage, conv_rect) {
			return {}, .Layout_Failed
		}
		drawn_cursor, draw_error := draw_input(app, storage, input_rect)
		if draw_error != nil {
			return {}, .Allocation_Failed
		}
		cursor = drawn_cursor
	}
	images_collect(app, storage)
	draw_footer(app, storage, cwd_rect, status_rect)
	storage.screen.buffer.links = storage.links[:]
	return cursor, .None
}

// draw_conversation solves the transcript as a layout column and draws the visible text
// lines into rect. The conversation root is a scroll container whose clip offset is
// the scroll's offset. The offset needs the solved range, so the first pass uses the
// previous frame's; when the solved range moved it, the frame re-solves once.
@(require_results)
draw_conversation :: proc(app: ^App, storage: ^Frame_Storage, rect: tui.Cell_Rect) -> bool {
	if rect.height <= 0 || rect.width <= 0 {
		return true
	}
	offset := widgets.scroll_offset(app.conversation_scroll)
	viewport := layout.Vec2{layout.Scalar(rect.width), layout.Scalar(rect.height)}
	storage.conversation_rows = rect.height
	order := transcript_order(app)

	for pass in 0 ..< 2 {
		selected_before := app.transcript.selected_entry
		frame_result, solved := conversation_solve(app, storage, viewport, rect.width, offset, order)
		if !solved {
			return false
		}
		node, found := layout.lookup(frame_result, CONVERSATION_ID)
		if !found {
			return false
		}
		transcript_scroll_set_range(app, int(node.scroll_range.y))
		transcript_measure(app, order, frame_result, rect.height)
		corrected := widgets.scroll_offset(app.conversation_scroll)
		if (corrected == offset && selected_before == app.transcript.selected_entry) || pass == 1 {
			// The last solve declared every entry this frame draws, so the
			// Markdown it did not ask for belongs to entries that are gone.
			markdown_cache_sweep(&storage.markdown)
			if !draw_bands(storage, frame_result, rect) { return false }
			if tui.draw_commands(&storage.screen.buffer, storage.paints[:], frame_result, rect, &storage.shown) != .None { return false }
			selection_paint(app, storage, rect)
			box_drag_paint(app, storage, frame_result, rect)
			return true
		}
		offset = corrected
	}
	return false
}

// conversation_solve declares one conversation frame and returns its solved result,
// raising the layout budget when the frame ran out of a pool. Each pool pays this once
// per session, so the storage settles at what this session used instead of a worst-case
// reservation. False means the budget could not be raised.
@(require_results)
conversation_solve :: proc(
	app: ^App,
	storage: ^Frame_Storage,
	viewport: layout.Vec2,
	width: int,
	offset: int,
	order: []^Entry,
) -> (
	layout.Frame_Result,
	bool,
) {
	declare_conversation(app, storage, viewport, width, offset, order)
	frame_result, frame_error := layout.result(&storage.layout_ctx)
	for _ in 0 ..< CONVERSATION_GROW_ATTEMPTS {
		if frame_error != .Capacity_Exhausted {
			break
		}
		if !conversation_budget_raise(storage) {
			return {}, false
		}
		declare_conversation(app, storage, viewport, width, offset, order)
		frame_result, frame_error = layout.result(&storage.layout_ctx)
	}
	if frame_error != .None {
		return {}, false
	}
	return frame_result, true
}

// declare_conversation declares one frame's tree: the transcript column, the startup hint
// when there is nothing to show, and one element per entry. The declarations live inside
// the frame's own `if` block, because that block is what layout closes the frame on.
declare_conversation :: proc(app: ^App, storage: ^Frame_Storage, viewport: layout.Vec2, width: int, offset: int, order: []^Entry) {
	clear(&storage.links)
	clear(&storage.paints)
	// Services bind for one frame only, so every solve re-binds them.
	layout.set_services(&storage.layout_ctx, tui.layout_services(&storage.measure))
	if layout.frame(&storage.layout_ctx, viewport) {
		if layout.element(
		&storage.layout_ctx,
		layout.Element_Desc {
			id = CONVERSATION_ID,
			layout = layout.Layout_Style{flow = .Column, sizing = layout.Sizing{width = layout.grow(), height = layout.grow()}, align = .Stretch},
			// The conversation is a vertical scroll container, so it clips
			// horizontally too. An unbreakable token wider than the viewport
			// must not widen the root, or every entry would wrap at that
			// width and be truncated at the terminal edge.
			clip = layout.Clip_Style{axes = {.X, .Y}, offset = {0, layout.Scalar(offset)}},
		},
		) {
			if len(order) == 0 {
				if layout.element(&storage.layout_ctx, layout.Element_Desc{layout = {flow = .Column}}) {
					layout.text(
						&storage.layout_ctx,
						layout.Text_Desc{text = "nabla", style = {size = 1, wrap = .None}, paint = storage_paint(storage, {style = TITLE_STYLE})},
					)
					layout.text(
						&storage.layout_ctx,
						layout.Text_Desc{text = STARTUP_HINT, style = {size = 1, wrap = .None}, paint = storage_paint(storage, {style = HINT_STYLE})},
					)
				}
			} else {
				for entry in order {
					declare_entry(&storage.layout_ctx, storage, entry, width, working_elapsed(app))
				}
			}
		}
	}
}

// conversation_budget_raise doubles the pool the last frame ran out of and
// raises the context's budget to match. False means the frame failed for
// another reason, or the raise itself failed; either way the context is left
// usable at its previous capacities.
@(require_results)
conversation_budget_raise :: proc(storage: ^Frame_Storage) -> bool {
	pool := layout.Pool_Id.None
	for diagnostic in layout.diagnostics(&storage.layout_ctx) {
		if diagnostic.kind == .Pool_Exhausted {
			pool = diagnostic.pool
			break
		}
	}
	if pool == .None {
		return false
	}
	next := conversation_capacities_raise(storage.capacities, pool)
	if layout.reserve(&storage.layout_ctx, next) != nil {
		return false
	}
	storage.capacities = next
	return true
}

// conversation_capacities_raise doubles the capacity behind one exhausted pool.
// Growth is per pool, so a transcript of text does not also buy node room it
// never used. The pools without a capacity of their own are carved from nodes,
// so raising nodes is what makes room for them.
conversation_capacities_raise :: proc(current: layout.Capacities, pool: layout.Pool_Id) -> layout.Capacities {
	next := current
	switch pool {
	case .Nodes, .None, .Solver_Scratch, .Hit_Order, .Id_Index:
		next.nodes = max(current.nodes * 2, 256)
	case .Children:
		next.children = max(current.children * 2, 512)
	case .Clips:
		next.clips = max(current.clips * 2, 8)
	case .Commands:
		next.commands = max(current.commands * 2, 256)
	case .Text_Lines:
		next.text_lines = max(current.text_lines * 2, 256)
	case .Measured_Words:
		next.measured_words = max(current.measured_words * 2, 1024)
	case .Tracks:
		next.tracks = max(current.tracks * 2, 64)
	case .Overlays:
		next.overlays = max(current.overlays * 2, 4)
	case .Measure_Cache:
		next.measure_cache = max(current.measure_cache * 2, 256)
	case .Id_Table:
		next.id_table = max(current.id_table * 2, 8)
	case .Depth:
		next.depth = max(current.depth * 2, 8)
	case .Diagnostics:
		next.diagnostics = max(current.diagnostics * 2, 64)
	case .Debug_Labels:
		next.debug_labels = max(current.debug_labels * 2, 64)
	}
	return next
}

// draw_bands fills the whole terminal row behind each text line whose paint has a background, and behind each
// background fill that repeats the space; a layout element would only span the conversation's width.
@(require_results)
draw_bands :: proc(storage: ^Frame_Storage, frame_result: layout.Frame_Result, viewport: tui.Cell_Rect) -> bool {
	for command in frame_result.commands {
		paint: layout.Paint
		switch data in command.data {
		case layout.Text_Cmd:
			paint = data.paint
		case layout.Fill_Cmd:
			paint = data.paint
		case layout.Border_Cmd, layout.Image_Cmd, layout.Custom_Cmd:
			continue
		}
		value, found := tui.paint_of(storage.paints[:], paint)
		if !found || value.style.background == nil || value.fill != "" { continue }
		rows, project_err := tui.project_rect_integral(command.bounds)
		if project_err != nil { return false }
		first := max(rows.y, 0)
		last := min(rows.y + rows.height, viewport.height)
		tui.fill(&storage.screen.buffer, {x = 0, y = viewport.y + first, width = storage.screen.buffer.columns, height = last - first}, " ", value.style)
	}
	return true
}

// selection_paint marks the cells a drag covers, reversing each cell's own style so a
// themed terminal stays themed. A cell outside the transcript's rect is not painted, so
// the highlight stops where the content does.
selection_paint :: proc(app: ^App, storage: ^Frame_Storage, viewport: tui.Cell_Rect) {
	if !app.selecting || storage.screen.buffer.cells == nil { return }
	start, end := selection_bounds(app)
	for row in max(start.y, 0) ..= min(end.y, viewport.height - 1) {
		first, last := selection_row_range(app, row, viewport.width)
		for column in first ..= last {
			cell := &storage.screen.buffer.cells[(viewport.y + row) * storage.screen.buffer.columns + viewport.x + column]
			cell.style.modifiers += {.Reverse}
		}
	}
}

// box_drag_paint marks selected content rows inside the box, excluding its border.
box_drag_paint :: proc(app: ^App, storage: ^Frame_Storage, frame_result: layout.Frame_Result, viewport: tui.Cell_Rect) {
	drag := app.box_drag
	entry := entry_find(app, drag.id)
	if !drag.active || !drag.moved || entry == nil { return }
	offset := widgets.scroll_offset(entry.tool_scroll) if entry.full != "" || entry.running else 0
	for node in frame_result.nodes {
		if u64(node.user) != drag.id { continue }
		for shown in 0 ..< entry.tool_rows {
			row := offset + shown
			if row < min(drag.anchor, drag.cursor) || row > max(drag.anchor, drag.cursor) { continue }
			y := int(node.outer.position.y) + 1 + shown
			if y < 0 || y >= viewport.height { continue }
			for x in int(node.outer.position.x) + 1 ..< int(node.outer.position.x + node.outer.size.x) - 1 {
				if x < 0 || x >= viewport.width { continue }
				storage.screen.buffer.cells[(viewport.y + y) * storage.screen.buffer.columns + viewport.x + x].style.modifiers += {.Reverse}
			}
		}
		return
	}
}

// selection_row_range returns the columns one row of the selection covers, both
// ends included. The first row starts at the drag's anchor and the last ends at
// its cursor; the rows between are covered whole.
selection_row_range :: proc(app: ^App, row, columns: int) -> (first, last: int) {
	start, end := selection_bounds(app)
	first = 0
	if row == start.y { first = max(start.x, 0) }
	last = columns - 1
	if row == end.y { last = min(end.x, columns - 1) }
	return
}

// selection_text reads the selected cells back as text: one line per transcript
// row, with each line's trailing blanks trimmed, because the frame pads a line
// out to its box and that padding is not what the user picked. The returned
// string is allocated with `allocator` and owned by the caller. False means the
// text could not be built, which is distinct from an empty selection.
@(require_results)
selection_text :: proc(app: ^App, storage: ^Frame_Storage, allocator: mem.Allocator) -> (text: string, ok: bool) {
	if storage == nil || storage.screen.buffer.cells == nil { return "", true }
	start, end := selection_bounds(app)
	buffer := storage.screen.buffer
	builder, builder_error := strings.builder_make(allocator)
	if builder_error != nil { return "", false }
	for row in max(start.y, 0) ..= min(end.y, buffer.rows - 1) {
		first, last := selection_row_range(app, row, buffer.columns)
		for last >= first {
			if !selection_cell_blank(buffer.cells[selection_index(app, buffer, row, last)]) { break }
			last -= 1
		}
		if row > start.y { strings.write_byte(&builder, '\n') }
		for column in first ..= last {
			grapheme := buffer.cells[selection_index(app, buffer, row, column)].grapheme
			// A picture's cells are not text, so a drag across one copies a space.
			strings.write_string(&builder, " " if strings.has_prefix(grapheme, term.GRAPHICS_PLACEHOLDER) else grapheme)
		}
	}
	return strings.to_string(builder), true
}

selection_index :: proc(app: ^App, buffer: term.Frame_Buffer, row, column: int) -> int {
	return (app.conversation_rect.y + row) * buffer.columns + app.conversation_rect.x + column
}

// selection_cell_blank reports whether a cell carries only the frame's padding.
// An empty grapheme is a wide character's continuation cell, which is padding
// for this purpose too.
@(require_results)
selection_cell_blank :: proc(cell: term.Cell) -> bool {
	return cell.grapheme == "" || cell.grapheme == " "
}

// declare_entry adds one transcript entry to the open conversation frame: the
// cleaned body in an element whose bottom padding is the blank row that
// separates entries, so the spacing scrolls with the content instead of being
// pasted in at draw time.
declare_entry :: proc(ctx: ^layout.Context, storage: ^Frame_Storage, entry: ^Entry, width: int, elapsed: time.Duration) {
	switch entry.kind {
	case .Tool, .Codemode:
		declare_tool_entry(ctx, storage, entry, width, elapsed)
	case .User, .Assistant, .Subagent:
		declare_message_entry(ctx, storage, entry)
	case .Notice, .Warning, .Error:
		cleaned := text.sanitize_text(string(entry.text[:]), context.temp_allocator) or_else ""
		if layout.element(ctx, layout.Element_Desc{layout = text_entry_layout()}) {
			if len(cleaned) > 0 {
				layout.text(
					ctx,
					layout.Text_Desc{text = cleaned, style = {size = 1, wrap = .Words}, paint = storage_paint(storage, {style = entry_style(entry.kind)})},
				)
			}
		}
	}
}

// text_entry_layout is the column a text entry sits in. Its bottom padding is the blank
// row that separates entries.
text_entry_layout :: proc() -> layout.Layout_Style {
	return {flow = .Column, sizing = layout.Sizing{width = layout.grow(), height = layout.fit()}, align = .Stretch, padding = layout.Edges{bottom = 1}}
}

// message_split returns the part of a message's raw text that is a heading and the part
// that is prose. A subagent message starts with a line naming the sender and the kind,
// written by the harness, so the split reads no wording. The prose of every other message
// is all of it.
message_split :: proc(kind: Entry_Kind, raw: string) -> (heading, body: string) {
	if kind != .Subagent { return "", raw }
	split := strings.index_byte(raw, '\n')
	if split < 0 { return raw, "" }
	return raw[:split], raw[split + 1:]
}

// declare_message_entry adds a user, assistant, or subagent message with its body as
// Markdown. A user or subagent message is a band: its element paints the band's
// background, with one padding row above and below, and draw_bands stretches that
// background across the terminal. A subagent message has its heading in bold above the
// body. Text the cache cannot parse is drawn as it is.
declare_message_entry :: proc(ctx: ^layout.Context, storage: ^Frame_Storage, entry: ^Entry) {
	heading, body := message_split(entry.kind, string(entry.text[:]))
	base := entry_style(entry.kind)
	band := layout.Element_Desc {
		layout = {flow = .Column, sizing = layout.Sizing{width = layout.grow(), height = layout.fit()}, align = .Stretch},
	}
	if heading != "" && body != "" { band.layout.gap = 1 }
	if entry.kind != .Assistant {
		band.layout.padding = layout.Edges {
			top    = 1,
			bottom = 1,
		}
		band.paint = {
			background = storage_paint(storage, {style = base}),
		}
	}
	if layout.element(ctx, layout.Element_Desc{layout = text_entry_layout()}) {
		if layout.element(ctx, band) {
			if label := text.sanitize_text(heading, context.temp_allocator) or_else ""; label != "" {
				layout.text(ctx, layout.Text_Desc{text = label, style = {size = 1, wrap = .Words}, paint = storage_paint(storage, {style = SUBAGENT_LABEL})})
			}
			if document, parse_error := markdown_cache_document(&storage.markdown, entry); parse_error == nil {
				declare_markdown_entry(ctx, storage, document, base)
			} else if cleaned := text.sanitize_text(body, context.temp_allocator) or_else ""; cleaned != "" {
				layout.text(ctx, layout.Text_Desc{text = cleaned, style = {size = 1, wrap = .Words}, paint = storage_paint(storage, {style = base})})
			}
		}
	}
}

// MARKDOWN_LINK_SCHEMES are the destinations a click may open. Links come from model
// output, so schemes that run or read something locally (file, javascript, custom
// handlers) stay text.
MARKDOWN_LINK_SCHEMES := [?]string{"http", "https", "mailto"}

// markdown_theme is the Markdown look. Nabla has no theme, so it uses only the
// terminal's default colors, ANSI indices 1 to 6, and modifiers, and follows whatever
// theme the terminal has.
markdown_theme :: proc(base: term.Style) -> markdown_view.Theme {
	theme := markdown_view.Theme {
		base = base,
		code = {foreground = term.Indexed_Color(1)},
		link = {foreground = term.Indexed_Color(4), modifiers = {.Underline}},
		dim = {modifiers = {.Dim}},
		table_header = {modifiers = {.Bold}},
		link_schemes = MARKDOWN_LINK_SCHEMES[:],
	}
	for &heading, index in theme.headings {
		heading.modifiers = {.Bold, .Underline} if index < 2 else {.Bold}
	}
	return theme
}

// declare_markdown_entry adds a message body rendered from Markdown over the style base.
// Layout wraps it and sizes its tables. An allocation failure leaves the body partial for
// this frame, and the next frame declares it again.
declare_markdown_entry :: proc(ctx: ^layout.Context, storage: ^Frame_Storage, document: markdown.Document, base: term.Style) {
	target := markdown_view.Target {
		ctx    = ctx,
		paints = &storage.paints,
		links  = &storage.links,
	}
	_ = markdown_view.declare(target, document, markdown_theme(base), context.temp_allocator)
}

// storage_paint returns the id of value in the frame's paint table, or zero when the table cannot grow.
storage_paint :: proc(storage: ^Frame_Storage, value: tui.Paint) -> layout.Paint {
	id, _ := tui.paint(&storage.paints, value)
	return id
}

// declare_tool_entry draws one tool call as a bordered box: the call's name on the top
// border, then a window of its result. A collapsed box shows the first rows its entry kept and
// the bottom border counts the lines hidden. An expanded box (entry.full) scrolls its whole
// text in the window (see `entry.tool_scroll`) and draws its border in the bright color.
// The box is a widgets.block, whose padding reserves the border and whose title and footer
// are overlays on the border rows.
// Only the border carries the outcome color. Code Mode calls draw here too, in blue on success.
// A running call draws the spinner frame before its name and the working border color.
declare_tool_entry :: proc(ctx: ^layout.Context, storage: ^Frame_Storage, entry: ^Entry, width: int, elapsed: time.Duration) {
	outline := tui.BORDER_ROUNDED
	box_width := max(width, 4)
	border_inner_width := max(box_width - 2, 1)
	content_width := max(box_width - 4, 1)
	// The top and bottom labels sit after the corner, one rule, and one space, so their
	// tabs expand from column 3. Width math uses those starts, or a tab puts the border in the wrong column.
	TOOL_LABEL_START :: 3
	expanded := entry.full != ""
	value := entry.full if expanded else string(entry.text[:])
	name := value
	preview := ""
	if split := strings.index(value, "\n"); split >= 0 {
		name = value[:split]
		preview = value[split + 1:]
	}
	if entry.running { name = fmt.tprintf("%s %s", widgets.spinner_frame(widgets.SPINNER_BRAILLE, elapsed, SPINNER_INTERVAL), name) }
	// The corner, the leading rule, and the space after the name leave the name
	// this much room; the rest of the top border is rule.
	name = text.truncate_text_at(name, max(border_inner_width - 3, 0), TOOL_LABEL_START)
	preview = text.sanitize_text(preview, context.temp_allocator) or_else ""
	title := fmt.tprintf("%s %s ", outline.horizontal, name)
	// The window is the part of the result the box shows. Its range is set
	// here because this is where the row count and the box's width are both known:
	// a resize or a shorter result can leave a remembered offset past the end.
	content_rows := tool_preview_rows(preview, content_width, TOOL_CONTENT_START)
	visible_rows := min(content_rows, TOOL_WINDOW_ROWS)
	scrolls := expanded || entry.running
	// The range stays on the entry because the wheel asks whether the window has
	// room left before it decides who owns the report. A collapsed box has no range
	// and keeps its position, so it opens where it was left.
	first_row := 0
	if scrolls {
		widgets.scroll_set_range(&entry.tool_scroll, content_rows - visible_rows)
		first_row = widgets.scroll_offset(entry.tool_scroll)
	} else {
		entry.tool_scroll.range = 0
	}
	entry.tool_rows = visible_rows
	label: string
	if scrolls {
		label = tool_window_label(first_row, entry.tool_scroll.range - first_row)
	} else if hidden := entry.hidden_lines + content_rows - visible_rows; hidden > 0 {
		label = fmt.tprintf("%d more line%s", hidden, "" if hidden == 1 else "s")
	}
	footer: string
	if visible := text.truncate_text_at(label, max(border_inner_width - 3, 0), TOOL_LABEL_START); visible != "" {
		footer = fmt.tprintf("%s %s ", outline.horizontal, visible)
	}
	border_style := TOOL_FAILURE
	switch {
	case entry.running:
		border_style = WORKING_BORDER_TEXT
	case entry.tool_outcome == .Success:
		border_style = CODEMODE_SUCCESS if entry.kind == .Codemode else TOOL_SUCCESS
	}
	if expanded { border_style = tool_border_bright(border_style) }
	if entry.selected { border_style.modifiers += {.Bold} }
	// The outer element holds the blank row that separates boxes, so the box's own rect is exactly its border.
	if layout.element(ctx, layout.Element_Desc{layout = layout.Layout_Style{flow = .Column, padding = layout.Edges{bottom = 1}}}) {
		box := widgets.Block_Desc {
			id = layout.id_index("tool-box", u64(entry.id)),
			user = layout.User_Tag(entry.id),
			sizing = layout.Sizing{width = layout.fixed(layout.Scalar(box_width)), height = layout.fit()},
			border = outline,
			style = border_style,
			title = title,
			footer = footer,
		}
		if widgets.block(ctx, &storage.paints, box) {
			body := storage_paint(storage, {style = TOOL_BODY})
			remaining := preview
			row_index := 0
			drawn := 0
			for len(remaining) > 0 {
				piece, rest := tool_row_next(remaining, content_width, TOOL_CONTENT_START)
				if row_index >= first_row && drawn < visible_rows {
					layout.text(ctx, layout.Text_Desc{text = fmt.tprintf(" %s", piece), style = {size = 1, wrap = .None}, paint = body})
					drawn += 1
				}
				row_index += 1
				remaining = rest
				if drawn >= visible_rows { break }
			}
			if content_rows == 0 {
				layout.text(ctx, layout.Text_Desc{text = " ", style = {size = 1, wrap = .None}, paint = body})
			}
			if entry.image.id != 0 {
				columns, rows := image_cells(entry.image, content_width, storage.conversation_rows, storage.cell_pixels)
				declare_tool_image(ctx, storage, entry.image.id, columns, rows)
			}
		}
	}
}

// tool_border_bright returns style in the bright variant of its indexed color.
tool_border_bright :: proc(style: term.Style) -> term.Style {
	bright := style
	if index, indexed := style.foreground.(term.Indexed_Color); indexed && index < 8 { bright.foreground = index + 8 }
	return bright
}

// declare_tool_image reserves a box's picture rows below its text, inside the border.
declare_tool_image :: proc(ctx: ^layout.Context, storage: ^Frame_Storage, id: term.Image_Id, columns, rows: int) {
	picture_box := layout.Layout_Style {
		sizing = layout.Sizing{width = layout.fixed(layout.Scalar(columns + 1)), height = layout.fixed(layout.Scalar(rows))},
		padding = layout.Edges{left = 1},
	}
	if layout.element(ctx, layout.Element_Desc{layout = picture_box}) {
		picture := layout.Layout_Style {
			sizing = layout.Sizing{width = layout.fixed(layout.Scalar(columns)), height = layout.fixed(layout.Scalar(rows))},
		}
		layout.content(
			ctx,
			layout.Element_Desc {
				layout = picture,
				content = layout.Image_Content {
					handle = layout.Image_Handle(id),
					intrinsic_size = {layout.Scalar(columns), layout.Scalar(rows)},
					paint = storage_paint(storage, {}),
				},
			},
		)
	}
}

// tool_row_next splits the first row a tool box draws from `value` and returns it with the
// remainder. A row ends at a newline or at the content width; a grapheme wider than the
// width still takes a row, so the split always advances. start_column is where the row
// starts inside its drawn line.
tool_row_next :: proc(value: string, width, start_column: int) -> (row: string, rest: string) {
	newline := strings.index(value, "\n")
	logical := value
	if newline >= 0 { logical = value[:newline] }
	piece := text.truncate_text_at(logical, width, start_column)
	if piece == "" && len(logical) > 0 {
		piece = logical[:text.next_grapheme_offset(logical, 0)]
	}
	switch {
	case len(piece) < len(logical):
		return piece, value[len(piece):]
	case newline >= 0:
		return piece, value[newline + 1:]
	}
	return piece, ""
}

// tool_preview_rows counts the rows a tool box draws for a result: one per
// wrapped row, so the box knows what its window is holding back.
tool_preview_rows :: proc(preview: string, width, start_column: int) -> int {
	rows := 0
	remaining := preview
	for len(remaining) > 0 {
		_, remaining = tool_row_next(remaining, width, start_column)
		rows += 1
	}
	return rows
}

// tool_window_label names what a window is holding back. The arrows point at the
// rows they count, and an empty label means nothing is hidden and the border
// stays a plain rule.
tool_window_label :: proc(hidden_above, hidden_below: int) -> string {
	switch {
	case hidden_above == 0 && hidden_below == 0:
		return ""
	case hidden_above == 0:
		return fmt.tprintf("↓ %d more lines", hidden_below)
	case hidden_below == 0:
		return fmt.tprintf("↑ %d more lines", hidden_above)
	}
	return fmt.tprintf("↑ %d · ↓ %d lines", hidden_above, hidden_below)
}

// draw_menu renders the open choice list: the title, the last selection error
// when there is one, and the choices below them in a list that scrolls to keep
// the selection visible. The rows the list got are remembered for paging.
draw_menu :: proc(app: ^App, storage: ^Frame_Storage, rect: tui.Cell_Rect) {
	if rect.height <= 0 || rect.width <= 0 {
		return
	}
	list_rect := rect
	_, _ = tui.draw_text(&storage.screen.buffer, {rect.x, list_rect.y, rect.width, 1}, app.menu.title, TITLE_STYLE)
	list_rect.y += 1
	list_rect.height -= 1
	if setup_error := setup_error_text(app); setup_error != "" && list_rect.height > 0 {
		_, _ = tui.draw_text(&storage.screen.buffer, {rect.x, list_rect.y, rect.width, 1}, setup_error, ERROR_TEXT)
		list_rect.y += 1
		list_rect.height -= 1
	}
	app.menu.rows = max(list_rect.height, 0)

	items, items_error := make([]string, len(app.menu.choices), context.temp_allocator)
	if items_error != nil {
		snap_report_dropped_locked(app)
		return
	}
	for choice, index in app.menu.choices {
		marker := "> " if index == app.menu.list.selected else "  "
		if choice.detail != "" {
			items[index] = fmt.tprintf("%s%-24s %s", marker, choice.label, choice.detail)
		} else {
			items[index] = fmt.tprintf("%s%s", marker, choice.label)
		}
	}
	_ = widgets.draw_list(&storage.screen.buffer, list_rect, {items = items, style = HINT_STYLE, selected_style = PICKED_STYLE}, &app.menu.list)
}

// draw_input_hint replaces the prompt with the menu's keys while one is open.
// The startup chooser cannot be escaped, so the hint names quitting there and
// cancelling elsewhere.
draw_input_hint :: proc(app: ^App, storage: ^Frame_Storage, rect: tui.Cell_Rect) {
	if rect.height <= 0 || rect.width <= 0 {
		return
	}
	hint := "up/down move | enter select | esc cancel"
	if app.menu.required {
		hint = "up/down move | enter select | esc quit"
	}
	_, _ = tui.draw_text(&storage.screen.buffer, rect, hint, HINT_STYLE)
}

entry_style :: proc(kind: Entry_Kind) -> term.Style {
	switch kind {
	case .User:
		return USER_TEXT
	case .Assistant:
		return AGENT_TEXT
	case .Subagent:
		return SUBAGENT_TEXT
	case .Tool:
		return TOOL_BODY
	case .Codemode:
		return TOOL_BODY
	case .Notice:
		return NOTICE_TEXT
	case .Warning:
		return WARNING_TEXT
	case .Error:
		return ERROR_TEXT
	}
	return {}
}

WORKING_SECONDS_PER_MINUTE :: i64(60)
WORKING_MINUTES_PER_HOUR :: i64(60)
WORKING_SECONDS_PER_HOUR :: WORKING_SECONDS_PER_MINUTE * WORKING_MINUTES_PER_HOUR

// working_duration formats whole seconds with every useful unit. Seconds stand
// alone below one minute, minutes include seconds, and hours include both.
working_duration :: proc(total_seconds: i64) -> string {
	seconds := max(total_seconds, 0)
	if seconds < WORKING_SECONDS_PER_MINUTE {
		return fmt.tprintf("%ds", seconds)
	}
	if seconds < WORKING_SECONDS_PER_HOUR {
		minutes := seconds / WORKING_SECONDS_PER_MINUTE
		remaining_seconds := seconds % WORKING_SECONDS_PER_MINUTE
		return fmt.tprintf("%dm %ds", minutes, remaining_seconds)
	}
	hours := seconds / WORKING_SECONDS_PER_HOUR
	minutes := seconds % WORKING_SECONDS_PER_HOUR / WORKING_SECONDS_PER_MINUTE
	remaining_seconds := seconds % WORKING_SECONDS_PER_MINUTE
	return fmt.tprintf("%dh %dm %ds", hours, minutes, remaining_seconds)
}

// working_elapsed is the time since the active turn started.
working_elapsed :: proc(app: ^App) -> time.Duration {
	return time.tick_diff(app.run.snap.status.working_since, time.tick_now())
}

// working_label reports the elapsed time for the complete active turn. The
// start survives provider requests, tool calls, and retries, and is replaced
// only when a later prompt starts from idle.
working_label :: proc(app: ^App) -> string {
	seconds := i64(time.duration_seconds(working_elapsed(app)))
	return fmt.tprintf("Working for %s", working_duration(seconds))
}

@(require_results)
input_visible_rows :: proc(input: ^widgets.Input, width: int) -> (rows: int, err: mem.Allocator_Error) {
	lines, lines_error := widgets.input_lines(input, width)
	if lines_error != nil {
		return 1, lines_error
	}
	return clamp(len(lines), 1, INPUT_MAX_ROWS), nil
}

// draw_input draws a rounded prompt box and returns the caret. The box grows
// through ten content rows; after that the rows scroll around the caret, which
// is the widget's own window (draw_input).
@(require_results)
draw_input :: proc(app: ^App, storage: ^Frame_Storage, rect: tui.Cell_Rect) -> (cursor: term.Cursor, err: mem.Allocator_Error) {
	if rect.height < 3 || rect.width <= 4 { return {}, nil }
	border_style := RULE_STYLE
	widgets.draw_block(&storage.screen.buffer, rect, widgets.Block{border = tui.BORDER_ROUNDED, style = border_style})
	if app.transcript.focused {
		hint := ACTIVE_BOX_HINT if app.transcript.active_call != 0 else FOCUS_HINT
		_, _ = tui.draw_text(
			&storage.screen.buffer,
			{x = rect.x + 2, y = rect.y, width = min(text.text_columns(hint), rect.width - 4), height = 1},
			hint,
			HINT_STYLE,
		)
	} else if app.run.snap.status.running {
		title := fmt.tprintf(" %s %s ", widgets.spinner_frame(widgets.SPINNER_BRAILLE, working_elapsed(app), SPINNER_INTERVAL), working_label(app))
		_, _ = tui.draw_text(
			&storage.screen.buffer,
			{x = rect.x + 2, y = rect.y, width = min(text.text_columns(title), rect.width - 4), height = 1},
			title,
			WORKING_BORDER_TEXT,
		)
	}
	content := tui.Cell_Rect {
		x      = rect.x + 2,
		y      = rect.y + 1,
		width  = rect.width - 4,
		height = rect.height - 2,
	}
	if content.width <= 0 || content.height <= 0 { return {}, nil }
	if app.transcript.focused {
		_, input_error := widgets.draw_input(&storage.screen.buffer, content, &app.input, HINT_STYLE)
		return {}, input_error
	}
	return widgets.draw_input(&storage.screen.buffer, content, &app.input, INPUT_TEXT)
}

// draw_footer paints the two footer rows: the working directory, then the
// usage and cost on the left with provider, model, and effort on the right.
draw_footer :: proc(app: ^App, storage: ^Frame_Storage, cwd_rect, status_rect: tui.Cell_Rect) {
	if cwd_rect.height > 0 && cwd_rect.width > 0 {
		directory := text.truncate_text(shorten_home(app, app.run.snap.status.cwd), cwd_rect.width)
		shown, clone_error := strings.clone(directory, context.temp_allocator)
		if clone_error != nil {
			snap_report_dropped_locked(app)
		} else {
			_, _ = tui.draw_text(&storage.screen.buffer, cwd_rect, shown, FOOTER_TEXT)
		}
	}
	if status_rect.height <= 0 || status_rect.width <= 0 {
		return
	}
	status := &app.run.snap.status
	left := "no model selected"
	right := ""
	if app.run.snap.display_incomplete {
		left = "display incomplete: out of memory"
	} else if status.model_id != "" {
		cost := "-"
		if priced, priced_ok := status.cost.?; priced_ok {
			cost = fmt.tprintf("$%.2f", priced)
			// A total under a cent would round to "$0.00", which reads as free.
			if priced < 0.01 { cost = fmt.tprintf("$%.4f", priced) }
			// A total that prices only some of the session is not the session's
			// cost, and the footer is the only place a reader can see that.
			if status.cost_partial { cost = fmt.tprintf("%s (partial)", cost) }
		}
		cache := "cache n/a"
		if status.session_hit_measured {
			cache = fmt.tprintf("cache %.1f%%", status.session_hit_rate * 100)
			// A rate measured over part of the session is not the session's rate, and
			// the footer is the only place a reader can see that from.
			if status.session_hit_partial { cache = fmt.tprintf("%s (partial)", cache) }
		} else if cache_read, cache_ok := status.session_cache_read.?; cache_ok {
			cache = fmt.tprintf("cache %s", footer_token_count(int(cache_read)))
		}
		left = fmt.tprintf("%s/%s | cost %s | %s", footer_token_count(status.est_input), footer_token_count(status.context_window), cost, cache)
		right = fmt.tprintf("(%s) %s", status.provider_id, status.model_id)
		if effort_text := strings.trim_space(status.effort); effort_text != "" {
			right = fmt.tprintf("%s | %s", right, effort_text)
		}
	}
	// A follower says so, since its model is not the one the session runs.
	if status.following {
		right = fmt.tprintf("following | %s", right) if right != "" else "following"
	}
	// The session disables autowrap, so the whole width is usable: the
	// bottom-right cell is written like any other, and a wide cluster may span
	// the final two columns. Widths are cells, not bytes.
	usable := status_rect.width
	if usable <= 0 {
		return
	}
	left = text.truncate_text(left, usable)
	_, _ = tui.draw_text(&storage.screen.buffer, status_rect, left, FOOTER_MUTED)
	right_columns := text.text_columns(right)
	if right_columns >= usable {
		return
	}
	right_rect := tui.Cell_Rect {
		x      = status_rect.x + usable - right_columns,
		y      = status_rect.y,
		width  = right_columns,
		height = 1,
	}
	_, _ = tui.draw_text(&storage.screen.buffer, right_rect, right, FOOTER_TEXT)
}

// footer_token_count formats a token count for the footer: the nearest thousand below a
// million ("977k"), otherwise millions to one decimal place ("1M", "1.5M"). The string is
// allocated with context.temp_allocator.
footer_token_count :: proc(count: int) -> string {
	thousands := (count + TOKENS_PER_THOUSAND / 2) / TOKENS_PER_THOUSAND
	if thousands < 1000 { return fmt.tprintf("%dk", thousands) }
	tenths := (count + TOKENS_PER_TENTH_MILLION / 2) / TOKENS_PER_TENTH_MILLION
	if tenths % 10 == 0 { return fmt.tprintf("%dM", tenths / 10) }
	return fmt.tprintf("%d.%dM", tenths / 10, tenths % 10)
}

// shorten_home replaces a leading home directory with "~", the way the
// reference footer shows the working directory.
shorten_home :: proc(app: ^App, path: string) -> string {
	home := app.home
	if home == "" || len(path) < len(home) || !strings.has_prefix(path, home) {
		return path
	}
	return fmt.tprintf("~%s", path[len(home):])
}
