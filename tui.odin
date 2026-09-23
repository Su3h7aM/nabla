#+build linux
package main

// Draws the frame: the conversation, a rule, the input line, another rule, and
// a two-line footer, into term's grid, then presents it.
//
// The screen is a projection of runtime state: the conversation comes from the
// snapshot and the footer from the status block; nothing here owns conversation
// state.

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"

import "nabla:layout"
import "nabla:term"
import "nabla:text"
import "nabla:tui"
import "nabla:tui/widgets"

// TUI_MAX_CELLS bounds the frame budget. Larger terminals simply skip the
// frame; the terminal keeps its previous contents.
TUI_MAX_CELLS :: 256 * 128

// The prompt shows at most five wrapped rows. Its border adds two more, then
// the working directory and status each use one row.
INPUT_MAX_ROWS :: 5
TUI_FOOTER_ROWS :: INPUT_MAX_ROWS + 4

// Styles use the terminal's default foreground/background and ANSI palette.
// Indexed status colors follow the user's terminal theme instead of defining a
// Nabla theme.
RULE_STYLE :: term.Style {
	modifiers = {.Dim},
}

// The working indicator: the reference TUI's braille spinner on the rule row
// above the input, shown only while a request is active.
SPINNER_FRAMES :: 10
WORKING_LABEL :: "Working"
// SPINNER_INTERVAL is one spinner frame.
SPINNER_INTERVAL :: 100 * time.Millisecond

// spinner_glyph returns one braille spinner frame.
spinner_glyph :: proc(index: int) -> string {
	glyphs := [10]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
	return glyphs[index % len(glyphs)]
}
WORKING_SPINNER :: term.Style {
	foreground = term.Indexed_Color(6),
}
WORKING_TEXT :: term.Style{}
WORKING_BORDER_TEXT :: term.Style {
	foreground = term.Indexed_Color(5),
}
LABEL_STYLE :: term.Style {
	modifiers = {.Bold},
}
// A user message is a band across the terminal. Its background is the terminal's
// own black, the darkest color a theme offers, so light message text keeps its
// contrast however the theme is set.
USER_TEXT :: term.Style {
	background = term.Indexed_Color(0),
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

// STARTUP_HINT is what an empty transcript shows under the title.
STARTUP_HINT :: "pgup/wheel scroll | escape interrupt | ctrl+c clear/cancel/quit | /help for commands"

// CONVERSATION_ID names the transcript's scroll-container root inside the
// frame, so the solved scroll range can be looked up after the solve.
CONVERSATION_ID :: layout.Id(1)

// A tool box tags its node with the ordinal of the entry it draws, so a wheel
// report can find the box under the pointer by reading the solved frame. The
// ordinal is stored plus one, because zero is layout's untagged value.
tool_box_tag :: proc(ordinal: int) -> layout.User_Tag {
	return layout.User_Tag(ordinal + 1)
}

tool_box_ordinal :: proc(tag: layout.User_Tag) -> int {
	return int(tag) - 1
}

// FONT_NORMAL and FONT_BOLD travel in layout.Text_Style.font, which layout
// never interprets: the transcript's one styling distinction beyond color.
FONT_NORMAL :: layout.Font(0)
FONT_BOLD :: layout.Font(1)
FONT_USER :: layout.Font(2)
FONT_DIM :: layout.Font(3)
FONT_RED :: layout.Font(4)
FONT_GREEN :: layout.Font(5)
FONT_CYAN :: layout.Font(6)
FONT_YELLOW :: layout.Font(7)

// TUI_COMMAND_CAPACITY bounds the command nodes retained for one transcript frame.
TUI_COMMAND_CAPACITY :: 4096

// FOOTER_KIB_ROUNDING and KIBIBYTE keep footer token counts rounded to the nearest KiB.
FOOTER_KIB_ROUNDING :: 512
KIBIBYTE :: 1024

// CONVERSATION_CAPACITIES budgets one transcript frame: three nodes per
// labeled entry (label, body element, body text) and two per unlabeled one,
// plus the root. Commands stay bounded by the viewport because culling drops
// every line outside the conversation's clip. A frame whose transcript
// outgrows a pool fails and leaves the previous screen up.
// ponytail: layout storage is fixed at init, so measured_words bounds a frame
// at ~131k transcript words; the upgrade path is a reserve API in layout.
CONVERSATION_CAPACITIES :: layout.Capacities {
	nodes          = 16384,
	children       = 32768,
	clips          = 8,
	commands       = TUI_COMMAND_CAPACITY,
	text_lines     = 32768,
	measured_words = 131072,
	measure_cache  = 8192,
	id_table       = 8,
	depth          = 8,
	diagnostics    = 64,
}

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
}

// Frame_Storage is the caller-owned frame budget: the cell grid backing, the
// presentation scratch, and the layout context with its fixed storage, sized
// to the current viewport.
Frame_Storage :: struct {
	cells:          []term.Cell,
	buffer:         term.Frame_Buffer,
	output:         []byte,
	alloc:          mem.Allocator,
	layout_ctx:     layout.Context,
	layout_storage: []byte, // owned,
	measure:        tui.Measure_Context,
}

frame_storage_new :: proc(alloc := context.allocator) -> ^Frame_Storage {
	storage, storage_error := new(Frame_Storage, alloc)
	if storage_error != nil { return nil }
	storage.alloc = alloc
	// Measurement and drawing share one width policy, so a tab or an
	// emoji-presentation sequence measures the columns drawing produces.
	// The zero profile would drop tabs while drawing expands them, and the
	// box math below would place the border from the wrong width.
	storage.measure.profile = text.DEFAULT_WIDTH_PROFILE
	storage.layout_storage, storage_error = make([]byte, layout.storage_size(CONVERSATION_CAPACITIES), alloc)
	if storage_error != nil {
		free(storage, alloc)
		return nil
	}
	config := layout.Options {
		capacities = CONVERSATION_CAPACITIES,
		cull       = .Visible,
	}
	if layout.init_from_buffer(&storage.layout_ctx, config, storage.layout_storage) != nil {
		delete(storage.layout_storage, alloc)
		free(storage, alloc)
		return nil
	}
	return storage
}

frame_storage_destroy :: proc(storage: ^Frame_Storage) {
	if storage.cells != nil { delete(storage.cells, storage.alloc) }
	if storage.output != nil { delete(storage.output, storage.alloc) }
	layout.destroy(&storage.layout_ctx)
	if storage.layout_storage != nil { delete(storage.layout_storage, storage.alloc) }
	free(storage, storage.alloc)
}

// ensure_frame grows the cell grid to the viewport. The presentation scratch is
// sized from term.present's required-size contract in present_frame, not
// guessed here: a grapheme can carry arbitrarily many combining bytes, so no
// bytes-per-cell bound is a valid upper bound.
ensure_frame :: proc(storage: ^Frame_Storage, cols, rows: int) -> bool {
	need := cols * rows
	if need > TUI_MAX_CELLS {
		return false
	}
	if len(storage.cells) < need {
		cells, alloc_error := make([]term.Cell, need, storage.alloc)
		if alloc_error != nil { return false }
		if storage.cells != nil { delete(storage.cells, storage.alloc) }
		storage.cells = cells
	}
	return true
}

// present_frame renders the runtime snapshot and writes the frame to the
// terminal.
//
// The runtime mutex is held only for the render. Everything the grid holds is
// either this thread's state or a copy taken out of the snapshot under that
// lock, so the terminal write does not hold up the worker.
present_frame :: proc(app: ^App, storage: ^Frame_Storage) {
	// Frame scratch is temp-allocated; the previous frame was already
	// presented, so its borrows are dead and the pool can be recycled.
	free_all(context.temp_allocator)
	sync.mutex_lock(&app.run.mu)
	cursor, err := render_frame(app, storage)
	sync.mutex_unlock(&app.run.mu)
	if err != .None {
		return
	}
	_, required, present_err := term.present(app.terminal, storage.buffer, term.profile_default(), cursor, storage.output)
	if present_err == term.General_Error.Presentation_Workspace_Too_Small {
		// The encoder reports the exact required count before writing anything,
		// so the scratch can be grown once and the frame retried.
		output, alloc_error := make([]byte, required, storage.alloc)
		if alloc_error != nil {
			fmt.eprintln("nabla: present: the frame scratch could not be allocated")
			return
		}
		delete(storage.output, storage.alloc)
		storage.output = output
		_, _, present_err = term.present(app.terminal, storage.buffer, term.profile_default(), cursor, storage.output)
	}
	if present_err != nil {
		fmt.eprintln("nabla: present:", present_err)
	}
}

// render_frame composes one frame from the current snapshot. The caller
// holds the runtime mutex.
//
// Every string it puts in the grid must outlive the lock: the snapshot's mutable
// strings are copied into frame scratch, and everything else belongs to this
// thread. A borrow straight from the snapshot would dangle once the worker
// replaces it.
render_frame :: proc(app: ^App, storage: ^Frame_Storage) -> (cursor: term.Cursor, err: Render_Status) {
	cols, rows := app.columns, app.rows
	if cols <= 0 || rows <= 0 {
		return {}, .None
	}
	if rows < 6 {
		return {}, .Too_Small
	}
	if !ensure_frame(storage, cols, rows) {
		return {}, .Too_Small
	}
	if !tui.init(&storage.buffer, cols, rows, storage.cells) {
		return {}, .Buffer_Too_Small
	}

	// The prompt grows with wrapped input until five content rows, then keeps the
	// caret visible by scrolling those rows inside its border.
	content := tui.Cell_Rect {
		x      = 1,
		y      = 0,
		width  = max(cols - 2, 0),
		height = rows,
	}
	input_rows := input_visible_rows(&app.input, input_content_width(app))
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
		cursor = draw_input(app, storage, input_rect)
	}
	draw_footer(app, storage, cwd_rect, status_rect)
	return cursor, .None
}

// draw_conversation solves the transcript as a layout column and draws the
// visible text lines into rect. The conversation root is a scroll container:
// app.scroll counts rows back from the bottom (0 follows it), and the clip
// offset is range - scroll.
//
// The offset needs the solved range, which the same frame produces. The first
// pass uses the previous frame's range; when that moved (new rows, a resize,
// a cleared transcript), the frame re-solves once with the corrected offset,
// so following the bottom never trails the newest row.
draw_conversation :: proc(app: ^App, storage: ^Frame_Storage, rect: tui.Cell_Rect) -> bool {
	if rect.height <= 0 || rect.width <= 0 {
		return true
	}
	if app.scroll > app.conv_scroll_range {
		app.scroll = app.conv_scroll_range
	}
	offset := app.conv_scroll_range - app.scroll
	viewport := layout.Vec2{layout.Scalar(rect.width), layout.Scalar(rect.height)}

	for pass in 0 ..< 2 {
		// Services bind for one frame only, so both passes re-bind.
		layout.set_services(
			&storage.layout_ctx,
			layout.Services{measure_text = tui.measure_proc, measure_text_user_data = &storage.measure, break_text = tui.break_proc},
		)
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
				if len(app.run.snap.entries) == 0 {
					if layout.element(&storage.layout_ctx, layout.Element_Desc{layout = {flow = .Column}}) {
						layout.text(&storage.layout_ctx, layout.Text_Desc{text = "nabla", style = layout_text_style(TITLE_STYLE)})
						layout.text(&storage.layout_ctx, layout.Text_Desc{text = STARTUP_HINT, style = layout_text_style(HINT_STYLE)})
					}
				} else {
					for &entry, ordinal in app.run.snap.entries {
						declare_entry(&storage.layout_ctx, &entry, rect.width, ordinal)
					}
				}
			}
		}
		frame_result, frame_error := layout.result(&storage.layout_ctx)
		if frame_error != .None {
			return false
		}
		node, found := layout.lookup(frame_result, CONVERSATION_ID)
		if !found {
			return false
		}
		app.conv_scroll_range = int(node.scroll_range.y)
		if app.scroll > app.conv_scroll_range {
			app.scroll = app.conv_scroll_range
		}
		corrected := app.conv_scroll_range - app.scroll
		if corrected == offset || pass == 1 {
			if !draw_conversation_commands(storage, frame_result, rect) { return false }
			selection_paint(app, storage, rect)
			return true
		}
		offset = corrected
	}
	return false
}

// draw_conversation_commands projects the solved frame's text commands into
// the cell grid. Culling already dropped every line outside the clip.
draw_conversation_commands :: proc(storage: ^Frame_Storage, frame_result: layout.Frame_Result, viewport: tui.Cell_Rect) -> bool {
	for command in frame_result.commands {
		text_data, is_text := command.data.(layout.Text_Cmd)
		if !is_text {
			continue
		}
		line, project_err := tui.project_rect_integral(command.bounds)
		if project_err != nil {
			return false
		}
		line.x += viewport.x
		line.y += viewport.y
		style := term_text_style(text_data.style)
		if text_data.style.font == FONT_USER {
			// A user message is a band across the whole terminal, not a block inside
			// the conversation's indent: the text keeps that indent as its padding.
			tui.fill(&storage.buffer, {x = 0, y = line.y, width = storage.buffer.columns, height = 1}, " ", style)
		}
		_, _ = tui.draw_text(&storage.buffer, line, text_data.text, style)
	}
	return true
}

// selection_paint marks the cells a drag covers. The mark reverses each cell's
// own style, so the terminal's colors are what the selection inverts and a
// themed terminal stays themed.
//
// A cell outside the transcript's rect is not painted: a drag that ran past the
// area is clamped to it, so the highlight stops where the content does.
selection_paint :: proc(app: ^App, storage: ^Frame_Storage, viewport: tui.Cell_Rect) {
	if !app.selecting || storage.buffer.cells == nil { return }
	start, end := selection_bounds(app)
	for row in max(start.y, 0) ..= min(end.y, viewport.height - 1) {
		first, last := selection_row_range(app, row, viewport.width)
		for column in first ..= last {
			cell := &storage.buffer.cells[(viewport.y + row) * storage.buffer.columns + viewport.x + column]
			cell.style.modifiers += {.Reverse}
		}
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
// string is allocated with `allocator` and owned by the caller.
selection_text :: proc(app: ^App, storage: ^Frame_Storage, allocator: mem.Allocator) -> string {
	if storage == nil || storage.buffer.cells == nil { return "" }
	start, end := selection_bounds(app)
	buffer := storage.buffer
	builder := strings.builder_make(allocator)
	for row in max(start.y, 0) ..= min(end.y, buffer.rows - 1) {
		first, last := selection_row_range(app, row, buffer.columns)
		for last >= first {
			if !selection_cell_blank(buffer.cells[selection_index(app, buffer, row, last)]) { break }
			last -= 1
		}
		if row > start.y { strings.write_byte(&builder, '\n') }
		for column in first ..= last {
			strings.write_string(&builder, buffer.cells[selection_index(app, buffer, row, column)].grapheme)
		}
	}
	return strings.to_string(builder)
}

// selection_index locates one transcript cell in the screen grid.
selection_index :: proc(app: ^App, buffer: term.Frame_Buffer, row, column: int) -> int {
	return (app.conversation_rect.y + row) * buffer.columns + app.conversation_rect.x + column
}

// selection_cell_blank reports whether a cell carries only the frame's padding.
// An empty grapheme is a wide character's continuation cell, which is padding
// for this purpose too.
selection_cell_blank :: proc(cell: term.Cell) -> bool {
	return cell.grapheme == "" || cell.grapheme == " "
}

// declare_entry adds one transcript entry to the open conversation frame: the
// cleaned body in an element whose bottom padding is the blank row that
// separates entries, so the spacing scrolls with the content instead of being
// pasted in at draw time.
declare_entry :: proc(ctx: ^layout.Context, entry: ^Entry, width, ordinal: int) {
	if entry.kind == .Tool {
		declare_tool_entry(ctx, entry, width, ordinal)
		return
	}
	cleaned := display_clean(string(entry.text[:]), context.temp_allocator)
	body_style := layout_text_style(entry_style(entry.kind))
	// A user message is a band, and the band's padding rows are painted too, so
	// they keep the band's style rather than the body's wrapping one.
	band_style := body_style
	body_style.wrap = .Words
	if layout.element(
		ctx,
		layout.Element_Desc {
			layout = layout.Layout_Style {
				flow = .Column,
				sizing = layout.Sizing{width = layout.fit(), height = layout.fit()},
				align = .Stretch,
				padding = layout.Edges{bottom = 1},
			},
		},
	) {
		if entry.kind == .User { declare_band_pad(ctx, band_style) }
		if len(cleaned) > 0 {
			layout.text(ctx, layout.Text_Desc{text = cleaned, style = body_style})
		}
		if entry.kind == .User { declare_band_pad(ctx, band_style) }
	}
}

// declare_band_pad reserves one row of a user message's background. The row is a
// single cell wide: the renderer paints a user row across the whole terminal, so
// the row only has to exist, and `Wrap.None` is what keeps one cell one line.
declare_band_pad :: proc(ctx: ^layout.Context, band: layout.Text_Style) {
	layout.text(ctx, layout.Text_Desc{text = " ", style = band})
}

// declare_tool_entry draws one tool call as a bordered box: the call's name on
// the top border, then a window of its result. A result taller than the window
// scrolls (see `entry.tool_scroll`), and the bottom border says how many rows
// the window is holding back, so a box never looks like the whole output when it
// is a preview of one.
//
// The box starts where the prompt box does and pads its content one cell inside
// the border, so a call and a prompt line up on the same columns. Only the
// border carries the outcome color; the content is ordinary text.
declare_tool_entry :: proc(ctx: ^layout.Context, entry: ^Entry, width, ordinal: int) {
	outline := widgets.BORDER_ROUNDED
	box_width := max(width, 4)
	border_inner_width := max(box_width - 2, 1)
	content_width := max(box_width - 4, 1)
	// A content row is " piece fill ": the piece starts one cell in, so its
	// tabs expand from column 1. The top and bottom labels sit after the
	// corner, one rule, and one space, so theirs expand from column 3. Width
	// math uses those starts, or a tab puts the border in the wrong column.
	TOOL_CONTENT_START :: 1
	TOOL_LABEL_START :: 3
	value := string(entry.text[:])
	name := value
	preview := ""
	if split := strings.index(value, "\n"); split >= 0 {
		name = value[:split]
		preview = value[split + 1:]
	}
	// The corner, the leading rule, and the space after the name leave the name
	// this much room; the rest of the top border is rule.
	name = text.truncate_text_at(name, max(border_inner_width - 3, 0), TOOL_LABEL_START)
	preview = display_clean(preview, context.temp_allocator)
	// These presentation scratch strings are best effort. A failed repeat leaves a
	// shorter border or spacer, never a tool result or a model-visible field; the
	// next frame retries with a fresh temporary arena.
	rule_fill :=
		strings.repeat(outline.horizontal, max(border_inner_width - text.text_columns_at(name, TOOL_LABEL_START) - 3, 0), context.temp_allocator) or_else ""
	top := fmt.tprintf("%s%s %s %s%s", outline.top_left, outline.horizontal, name, rule_fill, outline.top_right)
	// The window is the part of the result the box shows. Its offset is clamped
	// here because this is where the row count and the box's width are both known:
	// a resize or a shorter result can leave a remembered offset past the end.
	content_rows := tool_preview_rows(preview, content_width, TOOL_CONTENT_START)
	visible_rows := min(content_rows, TOOL_WINDOW_ROWS)
	// The bound is kept on the entry because the wheel asks whether the window has
	// room left before it decides who owns the report.
	entry.tool_scroll_max = max(content_rows - visible_rows, 0)
	entry.tool_scroll = clamp(entry.tool_scroll, 0, entry.tool_scroll_max)
	bottom := tool_border_bottom(outline, border_inner_width, tool_window_label(entry.tool_scroll, entry.tool_scroll_max - entry.tool_scroll))
	border_style := TOOL_FAILURE
	if entry.tool_outcome == .Success { border_style = TOOL_SUCCESS }
	if layout.element(
		ctx,
		layout.Element_Desc{layout = layout.Layout_Style{flow = .Column, padding = layout.Edges{bottom = 1}}, user = tool_box_tag(ordinal)},
	) {
		border := layout_text_style(border_style)
		body := layout_text_style(TOOL_BODY)
		layout.text(ctx, layout.Text_Desc{text = top, style = border})
		remaining := preview
		row_index := 0
		drawn := 0
		for len(remaining) > 0 {
			piece, rest := tool_row_next(remaining, content_width, TOOL_CONTENT_START)
			if row_index >= entry.tool_scroll && drawn < visible_rows {
				fill := strings.repeat(" ", max(content_width - text.text_columns_at(piece, TOOL_CONTENT_START), 0), context.temp_allocator) or_else ""
				declare_tool_row(ctx, fmt.tprintf(" %s%s ", piece, fill), border, body, outline.vertical)
				drawn += 1
			}
			row_index += 1
			remaining = rest
			if drawn >= visible_rows { break }
		}
		if content_rows == 0 {
			fill := strings.repeat(" ", content_width, context.temp_allocator) or_else ""
			declare_tool_row(ctx, fmt.tprintf(" %s ", fill), border, body, outline.vertical)
		}
		layout.text(ctx, layout.Text_Desc{text = bottom, style = border})
	}
}

// tool_row_next splits the first row a tool box draws from `value` and returns
// it with the remainder. A row ends at a newline or at the content width,
// whichever comes first; a grapheme wider than the width still takes a row, so
// the split always advances. start_column is where the row starts inside its
// drawn line, so tabs stop where drawing puts them.
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

// tool_border_bottom draws the box's bottom edge, carrying the window's label
// when it has one. The label is truncated to the room the border has, and an
// empty result is a plain rule.
tool_border_bottom :: proc(outline: widgets.Border, inner_width: int, label: string) -> string {
	visible := text.truncate_text_at(label, max(inner_width - 3, 0), 3)
	if visible == "" {
		fill := strings.repeat(outline.horizontal, inner_width, context.temp_allocator) or_else ""
		return fmt.tprintf("%s%s%s", outline.bottom_left, fill, outline.bottom_right)
	}
	fill := strings.repeat(outline.horizontal, max(inner_width - text.text_columns_at(visible, 3) - 3, 0), context.temp_allocator) or_else ""
	return fmt.tprintf("%s%s %s %s%s", outline.bottom_left, outline.horizontal, visible, fill, outline.bottom_right)
}

// declare_tool_row adds one framed content row. The vertical bars carry the
// outline style and the text between them the body style, so the box reads as
// one outline without tinting the result inside it.
declare_tool_row :: proc(ctx: ^layout.Context, content: string, border, body: layout.Text_Style, vertical: string) {
	if layout.element(ctx, layout.Element_Desc{layout = layout.Layout_Style{flow = .Row}}) {
		layout.text(ctx, layout.Text_Desc{text = vertical, style = border})
		layout.text(ctx, layout.Text_Desc{text = content, style = body})
		layout.text(ctx, layout.Text_Desc{text = vertical, style = border})
	}
}

// layout_text_style converts a palette style into layout's text style: the RGB
// foreground and the bold distinction. Wrap is the declaration's choice.
layout_text_style :: proc(style: term.Style) -> layout.Text_Style {
	result := layout.Text_Style {
		size  = 1,
		font  = FONT_NORMAL,
		wrap  = .None,
		// Layout uses alpha as command visibility. RGB is ignored by this
		// terminal adapter, which restores terminal-default or ANSI styling.
		color = layout.Color{0, 0, 0, 255},
	}
	if _, background_ok := style.background.(term.Indexed_Color); background_ok {
		result.font = FONT_USER
	} else if .Bold in style.modifiers {
		result.font = FONT_BOLD
	} else if .Dim in style.modifiers {
		result.font = FONT_DIM
	} else if indexed, foreground_ok := style.foreground.(term.Indexed_Color); foreground_ok {
		switch indexed {
		case 1:
			result.font = FONT_RED
		case 2:
			result.font = FONT_GREEN
		case 3:
			result.font = FONT_YELLOW
		case 6:
			result.font = FONT_CYAN
		case:
		}
	}
	return result
}

// term_text_style maps a solved text command back onto the palette: the
// inverse of layout_text_style, so the transcript's styles have one origin.
term_text_style :: proc(style: layout.Text_Style) -> term.Style {
	result: term.Style
	switch style.font {
	case FONT_BOLD:
		result.modifiers = {.Bold}
	case FONT_USER:
		result.background = USER_TEXT.background
	case FONT_DIM:
		result.modifiers = {.Dim}
	case FONT_RED:
		result.foreground = term.Indexed_Color(1)
	case FONT_GREEN:
		result.foreground = term.Indexed_Color(2)
	case FONT_CYAN:
		result.foreground = term.Indexed_Color(6)
	case FONT_YELLOW:
		result.foreground = term.Indexed_Color(3)
	case:
	}
	return result
}

// draw_menu renders the open choice list: the title, the last selection error
// when there is one, and one line per choice with its detail column. The cursor
// stays visible in a scrolling window.
draw_menu :: proc(app: ^App, storage: ^Frame_Storage, rect: tui.Cell_Rect) {
	if rect.height <= 0 || rect.width <= 0 {
		return
	}
	lines := make([dynamic]Line, 0, 64, context.temp_allocator)
	append(&lines, Line{text = app.menu.title, style = TITLE_STYLE})
	if setup_error := setup_error_text(app); setup_error != "" {
		append(&lines, Line{text = strings.clone(setup_error, context.temp_allocator), style = ERROR_TEXT})
	}
	cursor := app.menu.cursor
	if cursor >= len(app.menu.choices) {
		cursor = max(len(app.menu.choices) - 1, 0)
	}
	for choice, index in app.menu.choices {
		marker := "> " if index == cursor else "  "
		style := PICKED_STYLE if index == cursor else HINT_STYLE
		if choice.detail != "" {
			append(&lines, Line{text = fmt.tprintf("%s%-24s %s", marker, choice.label, choice.detail), style = style})
		} else {
			append(&lines, Line{text = fmt.tprintf("%s%s", marker, choice.label), style = style})
		}
	}
	total := len(lines)
	if total == 0 {
		return
	}
	// The cursor's line must stay inside the window.
	cursor_line := min(cursor + 1, total - 1)
	visible := rect.height
	if cursor_line < app.menu.top {
		app.menu.top = cursor_line
	}
	if cursor_line >= app.menu.top + visible {
		app.menu.top = cursor_line - visible + 1
	}
	start := app.menu.top
	if start > max(total - visible, 0) {
		start = max(total - visible, 0)
	}
	for i in 0 ..< visible {
		idx := start + i
		if idx >= total {
			break
		}
		line := &lines[idx]
		row := tui.Cell_Rect {
			x      = rect.x + line.indent,
			y      = rect.y + i,
			width  = rect.width - line.indent,
			height = 1,
		}
		if row.width <= 0 {
			continue
		}
		_, _ = tui.draw_text(&storage.buffer, row, line.text, line.style)
	}
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
	_, _ = tui.draw_text(&storage.buffer, rect, hint, HINT_STYLE)
}

entry_style :: proc(kind: Entry_Kind) -> term.Style {
	switch kind {
	case .User:
		return USER_TEXT
	case .Assistant:
		return AGENT_TEXT
	case .Tool:
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

// working_label reports the elapsed time for the complete active turn. The
// start survives provider requests, tool calls, and retries, and is replaced
// only when a later prompt starts from idle.
working_label :: proc(app: ^App) -> string {
	status := &app.run.snap.status
	elapsed := time.tick_diff(status.working_since, time.tick_now())
	seconds := i64(time.duration_seconds(elapsed))
	return fmt.tprintf("Working for %s", working_duration(seconds))
}

// draw_working renders the rule row as the working indicator: dashes, a gap,
// the braille frame, a gap, the label, then the rule continuing after it.
draw_working :: proc(storage: ^Frame_Storage, rect: tui.Cell_Rect, frame_index: int, label: string) {
	if rect.height <= 0 || rect.width <= 0 {
		return
	}
	// "──" + gap + spinner + gap + label + gap.
	prefix := 2 + 1 + 1 + 1 + text.text_columns(label) + 1
	if rect.width < prefix + 2 {
		draw_rule(storage, rect)
		return
	}
	tui.fill(&storage.buffer, tui.Cell_Rect{x = rect.x, y = rect.y, width = 2, height = 1}, "─", RULE_STYLE)
	_ = tui.put(&storage.buffer, rect.x + 3, rect.y, spinner_glyph(frame_index), WORKING_SPINNER)
	_, _ = tui.draw_text(&storage.buffer, tui.Cell_Rect{x = rect.x + 5, y = rect.y, width = text.text_columns(label), height = 1}, label, WORKING_TEXT)
	tail := rect.width - prefix
	if tail > 0 {
		tui.fill(&storage.buffer, tui.Cell_Rect{x = rect.x + prefix, y = rect.y, width = tail, height = 1}, "─", RULE_STYLE)
	}
}

// draw_rule paints one horizontal rule across the row.
draw_rule :: proc(storage: ^Frame_Storage, rect: tui.Cell_Rect) {
	if rect.height <= 0 || rect.width <= 0 {
		return
	}
	tui.fill(&storage.buffer, rect, "─", RULE_STYLE)
}

input_visible_rows :: proc(input: ^widgets.Input, width: int) -> int {
	lines := widgets.input_lines(input, width)
	return clamp(len(lines), 1, INPUT_MAX_ROWS)
}

// draw_input draws a rounded prompt box and returns the caret. The box grows
// through five content rows; after that the rows scroll around the caret, which
// is the widget's own window (draw_input).
draw_input :: proc(app: ^App, storage: ^Frame_Storage, rect: tui.Cell_Rect) -> term.Cursor {
	if rect.height < 3 || rect.width <= 4 { return {} }
	border_style := RULE_STYLE
	widgets.draw_block(&storage.buffer, rect, widgets.Block{border = widgets.BORDER_ROUNDED, style = border_style})
	if app.run.snap.status.running {
		title := fmt.tprintf(" %s %s ", spinner_glyph(app.spin_frame), working_label(app))
		_, _ = tui.draw_text(
			&storage.buffer,
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
	if content.width <= 0 || content.height <= 0 { return {} }
	return widgets.draw_input(&storage.buffer, content, &app.input, INPUT_TEXT)
}

// draw_footer paints the two footer rows: the working directory, then the
// usage and cost on the left with provider, model, and effort on the right.
draw_footer :: proc(app: ^App, storage: ^Frame_Storage, cwd_rect, status_rect: tui.Cell_Rect) {
	if cwd_rect.height > 0 && cwd_rect.width > 0 {
		directory := text.truncate_text(shorten_home(app, app.run.snap.status.cwd), cwd_rect.width)
		_, _ = tui.draw_text(&storage.buffer, cwd_rect, strings.clone(directory, context.temp_allocator), FOOTER_TEXT)
	}
	if status_rect.height <= 0 || status_rect.width <= 0 {
		return
	}
	status := &app.run.snap.status
	left := "no model selected"
	right := ""
	if status.model_id != "" {
		cost := "-"
		if status.cost_present {
			cost = fmt.tprintf("$%.2f", status.cost)
		}
		cache := "cache n/a"
		if status.session_hit_measured {
			cache = fmt.tprintf("cache %.1f%%", status.session_hit_rate * 100)
			// A rate measured over part of the session is not the session's rate, and
			// the footer is the only place a reader can see that from.
			if status.session_hit_partial { cache = fmt.tprintf("%s (partial)", cache) }
		} else if status.session_cache_present {
			cache = fmt.tprintf("cache %dk", (status.session_cache_read + FOOTER_KIB_ROUNDING) / KIBIBYTE)
		}
		left = fmt.tprintf(
			"%dk/%dk | cost %s | %s",
			(status.est_input + FOOTER_KIB_ROUNDING) / KIBIBYTE,
			(status.context_window + FOOTER_KIB_ROUNDING) / KIBIBYTE,
			cost,
			cache,
		)
		right = fmt.tprintf("(%s) %s", status.provider_id, status.model_id)
		if effort_text := strings.trim_space(status.effort); effort_text != "" {
			right = fmt.tprintf("%s | %s", right, effort_text)
		}
	}
	// The session disables autowrap, so the whole width is usable: the
	// bottom-right cell is written like any other, and a wide cluster may span
	// the final two columns. Widths are cells, not bytes.
	usable := status_rect.width
	if usable <= 0 {
		return
	}
	left = text.truncate_text(left, usable)
	_, _ = tui.draw_text(&storage.buffer, status_rect, left, FOOTER_MUTED)
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
	_, _ = tui.draw_text(&storage.buffer, right_rect, right, FOOTER_TEXT)
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
