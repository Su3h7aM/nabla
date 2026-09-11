#+build linux
package main

// tui_frame.odin draws the three-region screen and presents it.
//
// Shape of the frame, top to bottom: the conversation grows, then a rule,
// the input line, another rule, and a two-line footer (working directory,
// then usage on the left with provider/model/effort on the right). The
// rules and the footer split follow the Pi TUI, which is the visual
// reference for this screen.
//
// The screen is a thin projection of runtime state: the conversation comes
// from the runtime snapshot, the footer from the runtime status block.
// Nothing here owns conversation state.
//
// Text policy stays conservative: every byte is drawn through the
// sanitizer, and anything that is not printable ASCII becomes a
// placeholder, so untrusted model or tool output can never emit a terminal
// control sequence.

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

import "nabla:layout"
import "nabla:term"
import "nabla:tui"
import widgets "nabla:widgets"

// TUI_MAX_CELLS bounds the frame budget. Larger terminals simply skip the
// frame; the terminal keeps its previous contents.
TUI_MAX_CELLS :: 256 * 128

// Fixed rows below the conversation: rule, input, rule, cwd, status.
TUI_FOOTER_ROWS :: 5

// The palette follows the dark theme of the reference TUI: amber labels,
// muted lavender rules, and grey body text.
RULE_STYLE :: tui.Style {
	foreground = tui.RGB_Color{150, 130, 165},
}
LABEL_STYLE :: tui.Style {
	foreground = tui.RGB_Color{240, 198, 116},
	modifiers  = {.Bold},
}
USER_TEXT :: tui.Style {
	foreground = tui.RGB_Color{228, 228, 234},
}
AGENT_TEXT :: tui.Style {
	foreground = tui.RGB_Color{205, 205, 212},
}
TOOL_TEXT :: tui.Style {
	foreground = tui.RGB_Color{138, 138, 148},
}
NOTICE_TEXT :: tui.Style {
	foreground = tui.RGB_Color{129, 162, 190},
}
WARNING_TEXT :: tui.Style {
	foreground = tui.RGB_Color{240, 198, 116},
}
ERROR_TEXT :: tui.Style {
	foreground = tui.RGB_Color{204, 102, 102},
}
INPUT_TEXT :: tui.Style {
	foreground = tui.RGB_Color{228, 228, 234},
}
INPUT_PROMPT :: tui.Style {
	foreground = tui.RGB_Color{129, 162, 190},
	modifiers  = {.Bold},
}
TITLE_STYLE :: tui.Style {
	foreground = tui.RGB_Color{228, 228, 234},
	modifiers  = {.Bold},
}
HINT_STYLE :: tui.Style {
	foreground = tui.RGB_Color{140, 140, 146},
}
FOOTER_TEXT :: tui.Style {
	foreground = tui.RGB_Color{205, 205, 212},
}
FOOTER_MUTED :: tui.Style {
	foreground = tui.RGB_Color{110, 110, 118},
}

// BODY_INDENT is how far message bodies sit under their label, matching the
// reference layout.
BODY_INDENT :: 2

// Line is one wrapped display line: text is borrowed from frame scratch and
// lives until the frame is presented.
Line :: struct {
	text:   string,
	style:  tui.Style,
	indent: int,
}

TUI_CAPACITIES :: layout.Capacities {
	nodes          = 16,
	children       = 16,
	clips          = 4,
	commands       = 64,
	text_lines     = 8,
	measured_words = 16,
	overlays       = 1,
	measure_cache  = 8,
	id_table       = 16,
	depth          = 8,
	diagnostics    = 8,
	debug_labels   = 0,
}

Render_Status :: enum u8 {
	None,
	Too_Small,
	Layout_Failed,
	Buffer_Too_Small,
}

// Frame_Storage is the caller-owned frame budget: layout storage plus the
// logical and terminal cell grids and the presentation scratch, all sized to
// the current viewport.
Frame_Storage :: struct {
	ctx:            layout.Context,
	layout_storage: [262144]byte,
	cells:          []tui.Cell,
	frame_cells:    []term.Cell,
	buffer:         tui.Cell_Buffer,
	frame:          term.Frame_Buffer,
	output:         []byte,
	alloc:          mem.Allocator,
}

frame_storage_new :: proc(alloc := context.allocator) -> ^Frame_Storage {
	storage := new(Frame_Storage, alloc)
	storage.alloc = alloc
	return storage
}

frame_storage_destroy :: proc(storage: ^Frame_Storage) {
	if storage.cells != nil { delete(storage.cells, storage.alloc) }
	if storage.frame_cells != nil { delete(storage.frame_cells, storage.alloc) }
	if storage.output != nil { delete(storage.output, storage.alloc) }
	free(storage, storage.alloc)
}

ensure_frame :: proc(storage: ^Frame_Storage, cols, rows: int) -> bool {
	need := cols * rows
	if need > TUI_MAX_CELLS {
		return false
	}
	if len(storage.cells) < need {
		if storage.cells != nil { delete(storage.cells, storage.alloc) }
		storage.cells = make([]tui.Cell, need, storage.alloc)
	}
	if len(storage.frame_cells) < need {
		if storage.frame_cells != nil { delete(storage.frame_cells, storage.alloc) }
		storage.frame_cells = make([]term.Cell, need, storage.alloc)
	}
	output_need := need * 80
	if len(storage.output) < output_need {
		if storage.output != nil { delete(storage.output, storage.alloc) }
		storage.output = make([]byte, output_need, storage.alloc)
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
	frame, cursor, err := render_frame(app, storage)
	if err != .None {
		return
	}
	_, _, present_err := term.present(app.terminal, frame, term.profile_default(), cursor, storage.output)
	if present_err != nil {
		fmt.eprintln("nabla: present:", present_err)
	}
}

// render_frame composes one frame from the current snapshot. The caller
// holds the runtime mutex.
render_frame :: proc(app: ^App, storage: ^Frame_Storage) -> (frame: term.Frame_Buffer, cursor: term.Cursor_Intent, err: Render_Status) {
	cols, rows := app.columns, app.rows
	if cols <= 0 || rows <= 0 {
		return {}, nil, .None
	}
	if rows < TUI_FOOTER_ROWS + 1 {
		return {}, nil, .Too_Small
	}
	if !ensure_frame(storage, cols, rows) {
		return {}, nil, .Too_Small
	}

	config := layout.Options {
		capacities = TUI_CAPACITIES,
	}
	if layout.storage_size(config.capacities) > len(storage.layout_storage) {
		return {}, nil, .Too_Small
	}
	layout.destroy(&storage.ctx)
	if layout.init_from_buffer(&storage.ctx, config, storage.layout_storage[:]) != nil {
		return {}, nil, .Layout_Failed
	}
	viewport := layout.Vec2{layout.Scalar(cols), layout.Scalar(rows)}
	if layout.frame(&storage.ctx, viewport) {
		root := widgets.container_desc(widgets.Container{id = layout.id("root"), style = {flow = .Column, sizing = {layout.grow(), layout.grow()}}})
		if layout.element(&storage.ctx, root) {
			regions := [TUI_FOOTER_ROWS + 1]struct {
				name: string,
				size: layout.Axis_Size,
			} {
				{"conv", layout.grow()},
				{"rule-top", layout.fixed(1)},
				{"input", layout.fixed(1)},
				{"rule-bottom", layout.fixed(1)},
				{"cwd", layout.fixed(1)},
				{"status", layout.fixed(1)},
			}
			for region in regions {
				layout.content(
					&storage.ctx,
					widgets.container_desc(widgets.Container{id = layout.id(region.name), style = {sizing = {layout.grow(), region.size}}}),
				)
			}
		}
	}
	frame_result, frame_err := layout.result(&storage.ctx)
	if frame_err != .None {
		return {}, nil, .Layout_Failed
	}
	if !tui.init(&storage.buffer, cols, rows, storage.cells) {
		return {}, nil, .Buffer_Too_Small
	}
	conv_rect := region_rect(frame_result, "conv")
	rule_top_rect := region_rect(frame_result, "rule-top")
	input_rect := region_rect(frame_result, "input")
	rule_bottom_rect := region_rect(frame_result, "rule-bottom")
	cwd_rect := region_rect(frame_result, "cwd")
	status_rect := region_rect(frame_result, "status")

	if conv_rect.width <= 0 && input_rect.width <= 0 {
		return {}, nil, .Layout_Failed
	}

	draw_conversation(app, storage, conv_rect)
	draw_rule(storage, rule_top_rect)
	caret := draw_input(app, storage, input_rect)
	draw_rule(storage, rule_bottom_rect)
	draw_footer(app, storage, cwd_rect, status_rect)

	built, built_ok := tui.build_frame(storage.buffer, storage.frame_cells)
	if !built_ok {
		return {}, nil, .Buffer_Too_Small
	}
	storage.frame = built
	return built, caret, .None
}

// region_rect projects a declared region to cells; a missing or
// non-integral region yields the zero rect.
region_rect :: proc(frame_result: layout.Frame_Result, name: string) -> tui.Cell_Rect {
	node, found := layout.lookup(frame_result, layout.id(name))
	if !found {
		return {}
	}
	rect, projection_err := tui.project_rect_integral(node.outer)
	if projection_err != .None {
		return {}
	}
	return rect
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
		append(&lines, Line{text = "escape clear | ctrl+c cancel/quit | /model | /effort | /compact", style = HINT_STYLE})
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
		_, _ = tui.draw_ascii(&storage.buffer, row, line.text, line.style)
	}
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

entry_label :: proc(kind: Entry_Kind) -> (string, tui.Style) {
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

entry_style :: proc(kind: Entry_Kind) -> tui.Style {
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

// wrap_text splits sanitized text into wrapped lines. Tabs expand to four
// spaces, line breaks split paragraphs, and anything that is not printable
// ASCII becomes a placeholder. Paragraphs wrap on spaces.
wrap_text :: proc(text: string, width: int, indent: int, style: tui.Style, out: ^[dynamic]Line) {
	pos := 0
	for {
		nl := strings.index_byte(text[pos:], '\n')
		para := text[pos:]
		if nl >= 0 {
			para = text[pos:pos + nl]
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

emit_paragraph :: proc(para: string, width: int, indent: int, style: tui.Style, out: ^[dynamic]Line) {
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
		case r == '\t':
			strings.write_string(&word, "    ")
		case r >= 0x20 && r <= 0x7e:
			strings.write_byte(&word, u8(r))
		case:
			strings.write_byte(&word, '?')
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
		if col > 0 && col + 1 + len(w) > width {
			append(out, Line{text = strings.clone(strings.to_string(line_buf), context.temp_allocator), style = style, indent = indent})
			strings.builder_reset(&line_buf)
			col = 0
		}
		if col > 0 {
			strings.write_byte(&line_buf, ' ')
			col += 1
		}
		strings.write_string(&line_buf, w)
		col += len(w)
	}
	append(out, Line{text = strings.clone(strings.to_string(line_buf), context.temp_allocator), style = style, indent = indent})
}

// draw_rule paints one horizontal rule across the row.
draw_rule :: proc(storage: ^Frame_Storage, rect: tui.Cell_Rect) {
	if rect.height <= 0 || rect.width <= 0 {
		return
	}
	rule, repeat_err := strings.repeat("-", rect.width, context.temp_allocator)
	if repeat_err != nil {
		return
	}
	_, _ = tui.draw_ascii(&storage.buffer, rect, rule, RULE_STYLE)
}

// draw_input draws the prompt and the visible part of the input line and
// returns where the caret goes.
draw_input :: proc(app: ^App, storage: ^Frame_Storage, rect: tui.Cell_Rect) -> term.Cursor_Intent {
	if rect.height <= 0 || rect.width <= 0 {
		return nil
	}
	_, _ = tui.draw_ascii(&storage.buffer, {x = rect.x, y = rect.y, width = 2, height = 1}, "> ", INPUT_PROMPT)
	avail := rect.width - 2
	if avail < 0 {
		avail = 0
	}
	text_x := rect.x + 2
	content := string(app.line[:])
	hstart := 0
	if app.cursor > avail - 1 {
		hstart = app.cursor - avail + 1
	}
	if hstart > len(content) {
		hstart = len(content)
	}
	if avail > 0 {
		_, _ = tui.draw_ascii(&storage.buffer, {x = text_x, y = rect.y, width = avail, height = 1}, content[hstart:], INPUT_TEXT)
	}
	caret_col := text_x + (app.cursor - hstart)
	if caret_col > rect.x + rect.width - 1 {
		caret_col = rect.x + rect.width - 1
	}
	return term.Position{x = caret_col, y = rect.y}
}

// draw_footer paints the two footer rows: the working directory, then the
// usage and cost on the left with provider, model, and effort on the right.
draw_footer :: proc(app: ^App, storage: ^Frame_Storage, cwd_rect, status_rect: tui.Cell_Rect) {
	if cwd_rect.height > 0 && cwd_rect.width > 0 {
		directory := shorten_home(app, app.run.snap.status.cwd)
		if len(directory) > cwd_rect.width {
			directory = directory[:cwd_rect.width]
		}
		_, _ = tui.draw_ascii(&storage.buffer, cwd_rect, directory, FOOTER_TEXT)
	}
	if status_rect.height <= 0 || status_rect.width <= 0 {
		return
	}
	status := &app.run.snap.status
	cost := "-"
	if status.cost_present {
		cost = fmt.tprintf("$%.2f", status.cost)
	}
	left := fmt.tprintf("%dk/%dk | cost %s", (status.est_input + 512) / 1024, (status.context_window + 512) / 1024, cost)
	right := fmt.tprintf("(%s) %s", status.provider_id, status.model_id)
	if effort_text := strings.trim_space(status.effort); effort_text != "" {
		right = fmt.tprintf("%s | %s", right, effort_text)
	}
	// The frame encoder reserves the terminal's bottom-right cell, and this
	// is the last row, so the footer keeps one column clear.
	usable := status_rect.width - 1
	if usable <= 0 {
		return
	}
	if len(left) > usable {
		left = left[:usable]
	}
	_, _ = tui.draw_ascii(&storage.buffer, status_rect, left, FOOTER_MUTED)
	if len(right) >= usable {
		return
	}
	right_rect := tui.Cell_Rect {
		x      = status_rect.x + usable - len(right),
		y      = status_rect.y,
		width  = len(right),
		height = 1,
	}
	_, _ = tui.draw_ascii(&storage.buffer, right_rect, right, FOOTER_TEXT)
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
