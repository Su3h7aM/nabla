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

// Frame_Storage is the caller-owned frame budget: the cell grid backing and
// the presentation scratch, sized to the current viewport.
Frame_Storage :: struct {
	cells:  []term.Cell,
	buffer: term.Frame_Buffer,
	output: []byte,
	alloc:  mem.Allocator,
}

frame_storage_new :: proc(alloc := context.allocator) -> ^Frame_Storage {
	storage := new(Frame_Storage, alloc)
	storage.alloc = alloc
	return storage
}

frame_storage_destroy :: proc(storage: ^Frame_Storage) {
	if storage.cells != nil { delete(storage.cells, storage.alloc) }
	if storage.output != nil { delete(storage.output, storage.alloc) }
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
// terminal. It takes the runtime mutex and releases it only after the
// terminal write, because the frame borrows grapheme strings from the
// snapshot.
present_frame :: proc(app: ^App, storage: ^Frame_Storage) {
	// Frame scratch is temp-allocated; the previous frame was already
	// presented, so its borrows are dead and the pool can be recycled.
	free_all(context.temp_allocator)
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	cursor, err := render_frame(app, storage)
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

	if app.picking {
		draw_picker(app, storage, conv_rect)
		draw_input_hint(app, storage, input_rect)
	} else {
		draw_conversation(app, storage, conv_rect)
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

// draw_conversation renders the transcript: an amber label per entry, its
// body indented under it, and a blank line between entries. An empty
// transcript shows the startup hint instead.
draw_conversation :: proc(app: ^App, storage: ^Frame_Storage, rect: tui.Cell_Rect) {
	if rect.height <= 0 || rect.width <= 0 {
		return
	}
	lines := make([dynamic]Line, 0, 64, context.temp_allocator)
	if len(app.run.snap.entries) == 0 {
		append(&lines, Line{text = "nabla", style = TITLE_STYLE})
		append(&lines, Line{text = "escape interrupt | ctrl+c/ctrl+d quit | /model | /effort | /compact", style = HINT_STYLE})
	} else {
		for &entry in app.run.snap.entries {
			emit_entry(&entry, rect.width, &lines)
		}
	}
	total := len(lines)
	if total == 0 {
		return
	}
	visible := rect.height
	scroll_max := total - visible
	if scroll_max < 0 {
		scroll_max = 0
	}
	scroll := app.scroll
	if scroll > scroll_max {
		scroll = scroll_max
	}
	start := total - visible - scroll
	if start < 0 {
		start = 0
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

// draw_picker renders the model picker: a title, the last selection error if
// any, and one line per offered model grouped under its provider, with the
// cursor kept visible in a scrolling window.
draw_picker :: proc(app: ^App, storage: ^Frame_Storage, rect: tui.Cell_Rect) {
	if rect.height <= 0 || rect.width <= 0 {
		return
	}
	lines := make([dynamic]Line, 0, 64, context.temp_allocator)
	append(&lines, Line{text = "Select a model", style = TITLE_STYLE})
	if app.run.snap.setup_error != "" {
		append(&lines, Line{text = app.run.snap.setup_error, style = ERROR_TEXT})
	}
	entries := make([dynamic]Picker_Entry, 0, 16, context.temp_allocator)
	picker_entries(app, &entries)
	cursor := app.picker_cursor
	if cursor >= len(entries) {
		cursor = max(len(entries) - 1, 0)
	}
	current_provider := ""
	for entry, index in entries {
		if entry.provider_id != current_provider {
			current_provider = entry.provider_id
			append(&lines, Line{text = fmt.tprintf("[%s]", current_provider), style = LABEL_STYLE})
		}
		if index == cursor {
			append(&lines, Line{text = fmt.tprintf("> %s", entry.model_id), style = PICKED_STYLE})
		} else {
			append(&lines, Line{text = entry.model_id, style = HINT_STYLE, indent = 2})
		}
	}
	total := len(lines)
	if total == 0 {
		return
	}
	// The cursor's line must stay inside the window.
	cursor_line := picker_cursor_line(app, cursor, &lines)
	visible := rect.height
	if cursor_line < app.picker_top {
		app.picker_top = cursor_line
	}
	if cursor_line >= app.picker_top + visible {
		app.picker_top = cursor_line - visible + 1
	}
	start := app.picker_top
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

// picker_cursor_line finds the rendered line of the cursor entry.
picker_cursor_line :: proc(app: ^App, cursor: int, lines: ^[dynamic]Line) -> int {
	entries := make([dynamic]Picker_Entry, 0, 16, context.temp_allocator)
	picker_entries(app, &entries)
	line_index := 1
	current_provider := ""
	for entry, index in entries {
		if entry.provider_id != current_provider {
			current_provider = entry.provider_id
			line_index += 1
		}
		if index == cursor {
			return line_index
		}
		line_index += 1
	}
	return min(line_index, len(lines^) - 1)
}

// draw_input_hint replaces the prompt with the picker's keys while it is open.
// The startup chooser cannot be escaped, so the hint names quitting there and
// cancelling elsewhere.
draw_input_hint :: proc(app: ^App, storage: ^Frame_Storage, rect: tui.Cell_Rect) {
	if rect.height <= 0 || rect.width <= 0 {
		return
	}
	hint := "up/down move | enter select | esc cancel"
	if app.picker_initial {
		hint = "up/down move | enter select | esc quit"
	}
	_, _ = tui.draw_text(&storage.buffer, rect, hint, HINT_STYLE)
}

// emit_entry turns one conversation entry into a label plus wrapped body
// lines, followed by a blank line for the spacing between blocks.
emit_entry :: proc(entry: ^Entry, width: int, out: ^[dynamic]Line) {
	if width <= 0 {
		return
	}
	label, label_style := entry_label(entry.kind)
	indent := 0
	if label != "" {
		append(out, Line{text = label, style = label_style})
		indent = BODY_INDENT
	}
	cleaned := display_clean(string(entry.text[:]), context.temp_allocator)
	wrap_text(cleaned, max(width - indent, 1), indent, entry_style(entry.kind), out)
	append(out, Line{style = {}})
}

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

// wrap_text splits sanitized text into wrapped lines. Paragraphs wrap on
// spaces; the text policy (nabla:text) expands tabs at their line column and
// drops undrawable clusters, so the measured line and the drawn line agree.
wrap_text :: proc(value: string, width: int, indent: int, style: term.Style, out: ^[dynamic]Line) {
	pos := 0
	for {
		nl := strings.index_byte(value[pos:], '\n')
		para := value[pos:]
		if nl >= 0 {
			para = value[pos:pos + nl]
		}
		if nl != 0 {
			emit_paragraph(para, width, indent, style, out)
		} else {
			append(out, Line{style = style, indent = indent})
		}
		if nl < 0 {
			break
		}
		pos += nl + 1
	}
}

emit_paragraph :: proc(para: string, width: int, indent: int, style: term.Style, out: ^[dynamic]Line) {
	if len(para) == 0 {
		return
	}
	word := strings.builder_make(0, 0, context.temp_allocator)
	words := make([dynamic]string, 0, 8, context.temp_allocator)
	flush_word :: proc(word: ^strings.Builder, words: ^[dynamic]string) {
		if strings.builder_len(word^) > 0 {
			append(words, strings.clone(strings.to_string(word^), context.temp_allocator))
			strings.builder_reset(word)
		}
	}
	for r in para {
		switch {
		case r == ' ':
			flush_word(&word, &words)
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f):
		// A control code point never reaches a cell; the sanitizer already
		// dropped escape sequences, and the policy drops the rest at draw
		// time, so it is not part of a word here either. A tab is kept: the
		// policy expands it against its column.
		case:
			strings.write_rune(&word, r)
		}
	}
	flush_word(&word, &words)
	if len(words) == 0 {
		append(out, Line{style = style, indent = indent})
		return
	}
	line_buf := strings.builder_make(0, 0, context.temp_allocator)
	col := 0
	for w in words {
		// Measure the word where it lands: a tab's width depends on the
		// column, so the line is wrapped in the same columns it will draw in.
		if col > 0 && col + 1 + text.text_columns_at(w, col + 1) > width {
			append(out, Line{text = strings.clone(strings.to_string(line_buf), context.temp_allocator), style = style, indent = indent})
			strings.builder_reset(&line_buf)
			col = 0
		}
		if col > 0 {
			strings.write_byte(&line_buf, ' ')
			col += 1
		}
		strings.write_string(&line_buf, w)
		col += text.text_columns_at(w, col)
	}
	append(out, Line{text = strings.clone(strings.to_string(line_buf), context.temp_allocator), style = style, indent = indent})
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
		_, _ = tui.draw_text(&storage.buffer, cwd_rect, directory, FOOTER_TEXT)
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
		left = fmt.tprintf("%dk/%dk | cost %s", (status.est_input + 512) / 1024, (status.context_window + 512) / 1024, cost)
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
