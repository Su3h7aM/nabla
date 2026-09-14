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

// Fixed rows below the conversation: rule, input, rule, cwd, status.
TUI_FOOTER_ROWS :: 5

// The palette follows the dark theme of the reference TUI: amber labels,
// muted lavender rules, and grey body text.
RULE_STYLE :: term.Style {
	foreground = term.RGB_Color{150, 130, 165},
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
	foreground = term.RGB_Color{129, 162, 190},
}
WORKING_TEXT :: term.Style {
	foreground = term.RGB_Color{205, 205, 212},
}
LABEL_STYLE :: term.Style {
	foreground = term.RGB_Color{240, 198, 116},
	modifiers  = {.Bold},
}
USER_TEXT :: term.Style {
	foreground = term.RGB_Color{228, 228, 234},
}
AGENT_TEXT :: term.Style {
	foreground = term.RGB_Color{205, 205, 212},
}
TOOL_TEXT :: term.Style {
	foreground = term.RGB_Color{138, 138, 148},
}
NOTICE_TEXT :: term.Style {
	foreground = term.RGB_Color{129, 162, 190},
}
WARNING_TEXT :: term.Style {
	foreground = term.RGB_Color{240, 198, 116},
}
ERROR_TEXT :: term.Style {
	foreground = term.RGB_Color{204, 102, 102},
}
INPUT_TEXT :: term.Style {
	foreground = term.RGB_Color{228, 228, 234},
}
INPUT_PROMPT :: term.Style {
	foreground = term.RGB_Color{129, 162, 190},
	modifiers  = {.Bold},
}
TITLE_STYLE :: term.Style {
	foreground = term.RGB_Color{228, 228, 234},
	modifiers  = {.Bold},
}
HINT_STYLE :: term.Style {
	foreground = term.RGB_Color{140, 140, 146},
}
FOOTER_TEXT :: term.Style {
	foreground = term.RGB_Color{205, 205, 212},
}
FOOTER_MUTED :: term.Style {
	foreground = term.RGB_Color{110, 110, 118},
}
PICKED_STYLE :: term.Style {
	foreground = term.RGB_Color{129, 162, 190},
	modifiers  = {.Bold},
}

// BODY_INDENT is how far message bodies sit under their label, matching the
// reference layout.
BODY_INDENT :: 2

// STARTUP_HINT is what an empty transcript shows under the title.
STARTUP_HINT :: "pgup/wheel scroll | escape interrupt | ctrl+c clear/cancel/quit | /help for commands"

// CONVERSATION_ID names the transcript's scroll-container root inside the
// frame, so the solved scroll range can be looked up after the solve.
CONVERSATION_ID :: layout.Id(1)

// FONT_NORMAL and FONT_BOLD travel in layout.Text_Style.font, which layout
// never interprets: the transcript's one styling distinction beyond color.
FONT_NORMAL :: layout.Font(0)
FONT_BOLD :: layout.Font(1)

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
	commands       = 4096,
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
	storage := new(Frame_Storage, alloc)
	storage.alloc = alloc
	storage.layout_storage = make([]byte, layout.storage_size(CONVERSATION_CAPACITIES), alloc)
	config := layout.Options{
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
		if storage.cells != nil { delete(storage.cells, storage.alloc) }
		storage.cells = make([]term.Cell, need, storage.alloc)
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
		delete(storage.output, storage.alloc)
		storage.output = make([]byte, required, storage.alloc)
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
	if rows < TUI_FOOTER_ROWS + 1 {
		return {}, .Too_Small
	}
	if !ensure_frame(storage, cols, rows) {
		return {}, .Too_Small
	}
	if !tui.init(&storage.buffer, cols, rows, storage.cells) {
		return {}, .Buffer_Too_Small
	}

	// One grow region for the conversation, then the fixed footer rows.
	viewport := tui.Cell_Rect {
		x      = 0,
		y      = 0,
		width  = cols,
		height = rows,
	}
	heights := [TUI_FOOTER_ROWS + 1]int{-1, 1, 1, 1, 1, 1}
	regions: [TUI_FOOTER_ROWS + 1]tui.Cell_Rect
	if !tui.rows(viewport, heights[:], regions[:]) {
		return {}, .Layout_Failed
	}
	conv_rect := regions[0]
	rule_top_rect := regions[1]
	input_rect := regions[2]
	rule_bottom_rect := regions[3]
	cwd_rect := regions[4]
	status_rect := regions[5]

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
	// The rule above the input doubles as the working indicator while a
	// request is active.
	if app.run.snap.status.running {
		draw_working(storage, rule_top_rect, app.spin_frame)
	} else {
		draw_rule(storage, rule_top_rect)
	}
	draw_rule(storage, rule_bottom_rect)
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
		layout.set_services(&storage.layout_ctx, layout.Services{
			measure_text           = tui.measure_proc,
			measure_text_user_data = &storage.measure,
			break_text             = tui.break_proc,
		})
		if layout.frame(&storage.layout_ctx, viewport) {
			if layout.element(&storage.layout_ctx, layout.Element_Desc{
				id     = CONVERSATION_ID,
				layout = layout.Layout_Style{
					flow   = .Column,
					sizing = layout.Sizing{width = layout.grow(), height = layout.grow()},
					align  = .Stretch,
				},
				clip = layout.Clip_Style{axes = {.Y}, offset = {0, layout.Scalar(offset)}},
			}) {
				if len(app.run.snap.entries) == 0 {
					if layout.element(&storage.layout_ctx, layout.Element_Desc{layout = {flow = .Column}}) {
						layout.text(&storage.layout_ctx, layout.Text_Desc{text = "nabla", style = layout_text_style(TITLE_STYLE)})
						layout.text(&storage.layout_ctx, layout.Text_Desc{text = STARTUP_HINT, style = layout_text_style(HINT_STYLE)})
					}
				} else {
					for &entry in app.run.snap.entries {
						declare_entry(&storage.layout_ctx, &entry)
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
			return draw_conversation_commands(storage, frame_result)
		}
		offset = corrected
	}
	return false
}

// draw_conversation_commands projects the solved frame's text commands into
// the cell grid. Culling already dropped every line outside the clip.
draw_conversation_commands :: proc(storage: ^Frame_Storage, frame_result: layout.Frame_Result) -> bool {
	for command in frame_result.commands {
		text_data, is_text := command.data.(layout.Text_Cmd)
		if !is_text {
			continue
		}
		line, project_err := tui.project_rect_integral(command.bounds)
		if project_err != nil {
			return false
		}
		_, _ = tui.draw_text(&storage.buffer, line, text_data.text, term_text_style(text_data.style))
	}
	return true
}

// declare_entry adds one transcript entry to the open conversation frame: the
// label when the kind has one, then the cleaned body in a padded element. The
// element's bottom padding is the blank row that separates entries, so the
// spacing scrolls with the content instead of being pasted in at draw time.
declare_entry :: proc(ctx: ^layout.Context, entry: ^Entry) {
	label, label_style := entry_label(entry.kind)
	if label != "" {
		layout.text(ctx, layout.Text_Desc{text = label, style = layout_text_style(label_style)})
	}
	cleaned := display_clean(string(entry.text[:]), context.temp_allocator)
	indent := layout.Scalar(0)
	if label != "" {
		indent = BODY_INDENT
	}
	if layout.element(ctx, layout.Element_Desc{
		layout = layout.Layout_Style{
			sizing  = layout.Sizing{width = layout.fit(), height = layout.fit()},
			align   = .Stretch,
			padding = layout.Edges{left = indent, bottom = 1},
		},
	}) {
		if len(cleaned) > 0 {
			body_style := layout_text_style(entry_style(entry.kind))
			body_style.wrap = .Words
			layout.text(ctx, layout.Text_Desc{text = cleaned, style = body_style})
		}
	}
}

// layout_text_style converts a palette style into layout's text style: the RGB
// foreground and the bold distinction. Wrap is the declaration's choice.
layout_text_style :: proc(style: term.Style) -> layout.Text_Style {
	result := layout.Text_Style{size = 1, font = FONT_NORMAL, wrap = .None}
	if rgb, ok := style.foreground.(term.RGB_Color); ok {
		result.color = layout.Color{rgb[0], rgb[1], rgb[2], 255}
	}
	if .Bold in style.modifiers {
		result.font = FONT_BOLD
	}
	return result
}

// term_text_style maps a solved text command back onto the palette: the
// inverse of layout_text_style, so the transcript's styles have one origin.
term_text_style :: proc(style: layout.Text_Style) -> term.Style {
	result := term.Style{
		foreground = term.RGB_Color{style.color[0], style.color[1], style.color[2]},
	}
	if style.font == FONT_BOLD {
		result.modifiers = {.Bold}
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
	if app.run.snap.setup_error != "" {
		append(&lines, Line{text = strings.clone(app.run.snap.setup_error, context.temp_allocator), style = ERROR_TEXT})
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

// entry_label returns the label a transcript entry shows and its style. An
// empty label means the entry has no label row.
entry_label :: proc(kind: Entry_Kind) -> (string, term.Style) {
	switch kind {
	case .User:
		return "[user]", LABEL_STYLE
	case .Assistant:
		return "[agent]", LABEL_STYLE
	case .Tool:
		return "[tool]", LABEL_STYLE
	case .Notice, .Warning, .Error:
	}
	return "", {}
}

entry_style :: proc(kind: Entry_Kind) -> term.Style {
	switch kind {
	case .User:
		return USER_TEXT
	case .Assistant:
		return AGENT_TEXT
	case .Tool:
		return TOOL_TEXT
	case .Notice:
		return NOTICE_TEXT
	case .Warning:
		return WARNING_TEXT
	case .Error:
		return ERROR_TEXT
	}
	return {}
}

// draw_working renders the rule row as the working indicator: dashes, a gap,
// the braille frame, a gap, the label, then the rule continuing after it.
draw_working :: proc(storage: ^Frame_Storage, rect: tui.Cell_Rect, frame_index: int) {
	if rect.height <= 0 || rect.width <= 0 {
		return
	}
	// "──" + gap + spinner + gap + label + gap.
	prefix := 2 + 1 + 1 + 1 + len(WORKING_LABEL) + 1
	if rect.width < prefix + 2 {
		draw_rule(storage, rect)
		return
	}
	tui.fill(&storage.buffer, tui.Cell_Rect{x = rect.x, y = rect.y, width = 2, height = 1}, "─", RULE_STYLE)
	_ = tui.put(&storage.buffer, rect.x + 3, rect.y, spinner_glyph(frame_index), WORKING_SPINNER)
	_, _ = tui.draw_text(&storage.buffer, tui.Cell_Rect{x = rect.x + 5, y = rect.y, width = len(WORKING_LABEL), height = 1}, WORKING_LABEL, WORKING_TEXT)
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

// draw_input draws the prompt and the input line and returns the caret.
draw_input :: proc(app: ^App, storage: ^Frame_Storage, rect: tui.Cell_Rect) -> term.Cursor {
	if rect.height <= 0 || rect.width <= 2 {
		return {}
	}
	_, _ = tui.draw_text(&storage.buffer, tui.Cell_Rect{x = rect.x, y = rect.y, width = 2, height = 1}, "> ", INPUT_PROMPT)
	line := tui.Cell_Rect {
		x      = rect.x + 2,
		y      = rect.y,
		width  = rect.width - 2,
		height = 1,
	}
	return widgets.draw_input(&storage.buffer, line, app.input, INPUT_TEXT)
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
			cache = fmt.tprintf("cache %.0f%%", status.session_hit_rate * 100)
		} else if status.session_cache_present {
			cache = fmt.tprintf("cache %dk", (status.session_cache_read + 512) / 1024)
		}
		left = fmt.tprintf(
			"%dk/%dk | cost %s | %s",
			(status.est_input + 512) / 1024,
			(status.context_window + 512) / 1024,
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
