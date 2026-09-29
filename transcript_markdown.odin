package main

import "core:mem"
import "core:strings"

import "nabla:markdown"
import "nabla:term"
import "nabla:text"

Styled_Segment :: struct {
	text:  string,
	style: term.Style,
}

@(private = "file")
MAX_INT :: int((u64(1) << (size_of(int) * 8 - 1)) - 1)

// markdown_lines renders Markdown into pre-wrapped terminal lines. Every line
// and segment slice is allocated from allocator; segment text borrows source or
// is static or allocated from allocator. The result lives until allocator is
// freed. Parsing and rendering allocate from allocator, and the parsed tree is
// destroyed before return. The procedure shares no state and runs on any thread.
@(require_results)
markdown_lines :: proc(source: string, width: int, allocator := context.allocator) -> (lines: [][]Styled_Segment, err: mem.Allocator_Error) {
	previous_allocator := context.allocator
	context.allocator = allocator
	defer context.allocator = previous_allocator

	document, parse_error := markdown.parse(source, allocator)
	if parse_error != nil {
		return nil, parse_error
	}
	defer markdown.destroy(&document)

	renderer := Renderer {
		allocator = allocator,
	}
	defer renderer_destroy(&renderer)

	if render_error := render_blocks(&renderer, document.blocks, max(width, 1), false); render_error != nil {
		return nil, render_error
	}
	lines = renderer_finish(&renderer)
	return lines, nil
}

@(private = "file")
Renderer :: struct {
	allocator: mem.Allocator,
	lines:     [dynamic][]Styled_Segment,
	current:   [dynamic]Styled_Segment,
	word:      [dynamic]Styled_Segment,
	spaces:    [dynamic]Styled_Segment,
}

@(private = "file", require_results)
renderer_flush_line :: proc(renderer: ^Renderer) -> mem.Allocator_Error {
	line: []Styled_Segment
	if len(renderer.current) > 0 {
		allocated, allocation_error := make([]Styled_Segment, len(renderer.current), renderer.allocator)
		if allocation_error != nil {
			return allocation_error
		}
		copy(allocated, renderer.current[:])
		line = allocated
	}
	if _, err := append(&renderer.lines, line); err != nil {
		delete(line, renderer.allocator)
		return err
	}
	clear(&renderer.current)
	return nil
}

@(private = "file", require_results)
renderer_segment :: proc(renderer: ^Renderer, value: string, style: term.Style) -> mem.Allocator_Error {
	if value == "" {
		return nil
	}
	_, err := append(&renderer.current, Styled_Segment{text = value, style = style})
	return err
}

@(private = "file", require_results)
renderer_append_segments :: proc(renderer: ^Renderer, segments: []Styled_Segment) -> mem.Allocator_Error {
	for segment in segments {
		renderer_segment(renderer, segment.text, segment.style) or_return
	}
	return nil
}

@(private = "file", require_results)
renderer_spaces :: proc(renderer: ^Renderer, count: int, style: term.Style = {}) -> mem.Allocator_Error {
	if count <= 0 {
		return nil
	}
	value, err := strings.repeat(" ", count, renderer.allocator)
	if err != nil {
		return err
	}
	if err = renderer_segment(renderer, value, style); err != nil {
		delete(value, renderer.allocator)
		return err
	}
	return nil
}

@(private = "file")
renderer_destroy :: proc(renderer: ^Renderer) {
	for line in renderer.lines {
		delete(line, renderer.allocator)
	}
	delete(renderer.lines)
	delete(renderer.current)
	delete(renderer.word)
	delete(renderer.spaces)
	renderer^ = {}
}

@(private = "file")
renderer_finish :: proc(renderer: ^Renderer) -> [][]Styled_Segment {
	lines := renderer.lines[:]
	renderer.lines = {}
	delete(renderer.current)
	delete(renderer.word)
	delete(renderer.spaces)
	return lines
}

@(private = "file", require_results)
renderer_blank_line :: proc(renderer: ^Renderer) -> mem.Allocator_Error {
	if len(renderer.lines) == 0 || len(renderer.lines[len(renderer.lines) - 1]) == 0 {
		return nil
	}
	_, err := append(&renderer.lines, []Styled_Segment{})
	return err
}

@(private = "file", require_results)
render_blocks :: proc(renderer: ^Renderer, blocks: []markdown.Block, width: int, suppress_separators: bool) -> mem.Allocator_Error {
	has_previous := false
	for block in blocks {
		if has_previous && !suppress_separators {
			renderer_blank_line(renderer) or_return
		}
		before := len(renderer.lines)
		switch value in block {
		case markdown.Paragraph:
			paragraph_render(renderer, value.spans, width, {}) or_return
		case markdown.Heading:
			modifiers: term.Modifiers
			modifiers |= {.Bold}
			if value.level <= 2 {
				modifiers |= {.Underline}
			}
			paragraph_render(renderer, value.spans, width, modifiers) or_return
		case markdown.Code_Block:
			render_code_block(renderer, value, width) or_return
		case markdown.Quote:
			start := len(renderer.lines)
			render_blocks(renderer, value.blocks, max(width - 2, 1), false) or_return
			quote_prefix := Styled_Segment {
				text = "│ ",
				style = term.Style{modifiers = {.Dim}},
			}
			render_prefix_lines(renderer, start, quote_prefix, quote_prefix) or_return
		case markdown.List:
			render_list(renderer, value, width) or_return
		case markdown.Table:
			render_table(renderer, value, width) or_return
		case markdown.Thematic_Break:
			line, err := strings.repeat("─", width, renderer.allocator)
			if err != nil {
				return err
			}
			renderer_segment(renderer, line, term.Style{modifiers = {.Dim}}) or_return
			renderer_flush_line(renderer) or_return
		}
		if len(renderer.lines) > before {
			has_previous = true
		}
	}
	return nil
}

@(private = "file", require_results)
paragraph_render :: proc(renderer: ^Renderer, spans: []markdown.Span, width: int, extra: term.Modifiers) -> mem.Allocator_Error {
	start := len(renderer.lines)
	for i := 0; i < len(spans); i += 1 {
		span := spans[i]
		if span.text == "\n" {
			paragraph_place_word(renderer, width) or_return
			clear(&renderer.spaces)
			renderer_flush_line(renderer) or_return
			continue
		}
		style := span_style(span.style, extra)
		paragraph_add_text(renderer, span.text, style, width) or_return
		if .Link in span.style && paragraph_link_group_end(spans, i) && !paragraph_link_text_is_url(spans, i) {
			url_text, err := strings.concatenate({" (", span.url, ")"}, renderer.allocator)
			if err != nil {
				return err
			}
			paragraph_add_text(renderer, url_text, term.Style{modifiers = {.Dim}}, width) or_return
		}
	}
	paragraph_place_word(renderer, width) or_return
	clear(&renderer.spaces)
	if len(renderer.current) > 0 || len(renderer.lines) == start {
		renderer_flush_line(renderer) or_return
	}
	return nil
}

@(private = "file", require_results)
paragraph_add_text :: proc(renderer: ^Renderer, value: string, style: term.Style, width: int) -> mem.Allocator_Error {
	word_start := 0
	offset := 0
	for offset < len(value) {
		end := text.next_grapheme_offset(value, offset)
		if end <= offset {
			end = offset + 1
		}
		if value[offset:end] == " " {
			if word_start < offset {
				if _, err := append(&renderer.word, Styled_Segment{text = value[word_start:offset], style = style}); err != nil {
					return err
				}
			}
			if len(renderer.word) > 0 {
				paragraph_place_word(renderer, width) or_return
			}
			if _, err := append(&renderer.spaces, Styled_Segment{text = value[offset:end], style = style}); err != nil {
				return err
			}
			word_start = end
		}
		offset = end
	}
	if word_start < len(value) {
		if _, err := append(&renderer.word, Styled_Segment{text = value[word_start:], style = style}); err != nil {
			return err
		}
	}
	return nil
}

@(private = "file", require_results)
paragraph_place_word :: proc(renderer: ^Renderer, width: int) -> mem.Allocator_Error {
	if len(renderer.word) == 0 {
		return nil
	}
	column := segments_columns(renderer.current[:], 0)
	space_columns := segments_columns(renderer.spaces[:], column)
	word_columns := segments_columns(renderer.word[:], column + space_columns)
	if column > 0 && column + space_columns + word_columns > width {
		renderer_flush_line(renderer) or_return
		clear(&renderer.spaces)
		column = 0
		space_columns = 0
	}
	if column > 0 {
		renderer_append_segments(renderer, renderer.spaces[:]) or_return
	}
	clear(&renderer.spaces)
	column = segments_columns(renderer.current[:], 0)
	word_columns = segments_columns(renderer.word[:], column)
	if column + word_columns <= width {
		renderer_append_segments(renderer, renderer.word[:]) or_return
	} else {
		paragraph_split_word(renderer, renderer.word[:], width) or_return
	}
	clear(&renderer.word)
	return nil
}

@(private = "file", require_results)
paragraph_split_word :: proc(renderer: ^Renderer, word: []Styled_Segment, width: int) -> mem.Allocator_Error {
	if len(renderer.current) > 0 {
		renderer_flush_line(renderer) or_return
	}
	for segment in word {
		offset := 0
		for offset < len(segment.text) {
			end := text.next_grapheme_offset(segment.text, offset)
			if end <= offset {
				end = offset + 1
			}
			grapheme := segment.text[offset:end]
			column := segments_columns(renderer.current[:], 0)
			grapheme_columns := text.text_columns_at(grapheme, column)
			if column > 0 && column + grapheme_columns > width {
				renderer_flush_line(renderer) or_return
			}
			renderer_segment(renderer, grapheme, segment.style) or_return
			offset = end
		}
	}
	return nil
}

@(private = "file")
segments_columns :: proc(segments: []Styled_Segment, start_column: int) -> int {
	column := start_column
	for segment in segments {
		column += text.text_columns_at(segment.text, column)
	}
	return column - start_column
}

@(private = "file")
span_style :: proc(flags: markdown.Style, extra: term.Modifiers) -> term.Style {
	style: term.Style
	if .Strong in flags {
		style.modifiers |= {.Bold}
	}
	if .Emphasis in flags {
		style.modifiers |= {.Italic}
	}
	if .Strikethrough in flags {
		style.modifiers |= {.Strikethrough}
	}
	if .Code in flags {
		style.foreground = term.Indexed_Color(6)
	}
	if .Link in flags {
		style.foreground = term.Indexed_Color(4)
		style.modifiers |= {.Underline}
	}
	style.modifiers |= extra
	return style
}

@(private = "file")
paragraph_link_group_end :: proc(spans: []markdown.Span, index: int) -> bool {
	if index + 1 >= len(spans) {
		return true
	}
	next := spans[index + 1]
	return !(.Link in next.style) || next.url != spans[index].url
}

@(private = "file")
paragraph_link_text_is_url :: proc(spans: []markdown.Span, index: int) -> bool {
	url := spans[index].url
	offset := 0
	for i := index; i < len(spans); i += 1 {
		span := spans[i]
		if !(.Link in span.style) || span.url != url {
			break
		}
		if len(span.text) > len(url) - offset || span.text != url[offset:offset + len(span.text)] {
			return false
		}
		offset += len(span.text)
	}
	return offset == len(url)
}

@(private = "file", require_results)
render_prefix_lines :: proc(renderer: ^Renderer, start: int, first, continuation: Styled_Segment) -> mem.Allocator_Error {
	for index := start; index < len(renderer.lines); index += 1 {
		prefix := continuation
		if index == start {
			prefix = first
		}
		line := renderer.lines[index]
		prefixed, err := make([]Styled_Segment, len(line) + 1, renderer.allocator)
		if err != nil {
			return err
		}
		prefixed[0] = prefix
		copy(prefixed[1:], line)
		delete(line, renderer.allocator)
		renderer.lines[index] = prefixed
	}
	return nil
}

@(private = "file", require_results)
render_code_block :: proc(renderer: ^Renderer, block: markdown.Code_Block, width: int) -> mem.Allocator_Error {
	if block.info != "" {
		render_code_line(renderer, block.info, term.Style{modifiers = {.Dim}}, width) or_return
	}
	style := term.Style {
		foreground = term.Indexed_Color(6),
	}
	for line in block.lines {
		render_code_line(renderer, line, style, width) or_return
	}
	return nil
}

@(private = "file", require_results)
render_code_line :: proc(renderer: ^Renderer, value: string, style: term.Style, width: int) -> mem.Allocator_Error {
	indent := "  "
	content_width := max(width - text.text_columns(indent), 1)
	if value == "" {
		renderer_segment(renderer, indent, style) or_return
		renderer_flush_line(renderer) or_return
		return nil
	}
	remaining := value
	for len(remaining) > 0 {
		piece := text.truncate_text_at(remaining, content_width, text.text_columns(indent))
		if piece == "" {
			end := text.next_grapheme_offset(remaining, 0)
			if end <= 0 {
				end = 1
			}
			piece = remaining[:end]
		}
		renderer_segment(renderer, indent, style) or_return
		renderer_segment(renderer, piece, style) or_return
		renderer_flush_line(renderer) or_return
		remaining = remaining[len(piece):]
	}
	return nil
}

@(private = "file", require_results)
render_list :: proc(renderer: ^Renderer, list: markdown.List, width: int) -> mem.Allocator_Error {
	number_width := 0
	if list.ordered {
		number := list.start
		for _ in list.items {
			number_width = max(number_width, integer_digits(number))
			if number < MAX_INT {
				number += 1
			}
		}
	}
	number := list.start
	for item, item_index in list.items {
		if item_index > 0 && !list.tight {
			renderer_blank_line(renderer) or_return
		}
		first_text := "• "
		if list.ordered {
			ordered_prefix, prefix_error := ordered_list_prefix(number, number_width, renderer.allocator)
			if prefix_error != nil {
				return prefix_error
			}
			first_text = ordered_prefix
			if number < MAX_INT {
				number += 1
			}
		}
		prefix_width := text.text_columns(first_text)
		continuation, err := strings.repeat(" ", prefix_width, renderer.allocator)
		if err != nil {
			return err
		}
		start := len(renderer.lines)
		render_blocks(renderer, item, max(width - prefix_width, 1), list.tight) or_return
		if len(renderer.lines) == start {
			renderer_flush_line(renderer) or_return
		}
		render_prefix_lines(renderer, start, Styled_Segment{text = first_text}, Styled_Segment{text = continuation}) or_return
	}
	return nil
}

@(private = "file")
integer_digits :: proc(value: int) -> int {
	magnitude := u64(value)
	if value < 0 {
		magnitude = u64(-(value + 1)) + 1
	}
	digits := 1
	for magnitude >= 10 {
		magnitude /= 10
		digits += 1
	}
	if value < 0 {
		digits += 1
	}
	return digits
}

@(private = "file", require_results)
ordered_list_prefix :: proc(value, width: int, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	buffer: [64]byte
	magnitude := u64(value)
	negative := value < 0
	if negative {
		magnitude = u64(-(value + 1)) + 1
	}
	end := len(buffer)
	for {
		buffer[end - 1] = byte(magnitude % 10) + '0'
		end -= 1
		magnitude /= 10
		if magnitude == 0 {
			break
		}
	}
	if negative {
		buffer[end - 1] = '-'
		end -= 1
	}
	number := string(buffer[end:])
	padding, err := strings.repeat(" ", max(width - len(number), 0), allocator)
	if err != nil {
		return "", err
	}
	return strings.concatenate({padding, number, ". "}, allocator)
}

@(private = "file", require_results)
render_table :: proc(renderer: ^Renderer, table: markdown.Table, width: int) -> mem.Allocator_Error {
	column_count := len(table.alignments)
	if column_count == 0 {
		return nil
	}
	widths, err := make([]int, column_count, renderer.allocator)
	if err != nil {
		return err
	}
	defer delete(widths, renderer.allocator)
	for column in 0 ..< column_count {
		widths[column] = cell_columns(table.header[column])
		for row in table.rows {
			widths[column] = max(widths[column], cell_columns(row[column]))
		}
		widths[column] = max(widths[column], 1)
	}
	for table_width(widths) > width {
		widest := -1
		for column in 0 ..< column_count {
			if widths[column] > 1 && (widest < 0 || widths[column] > widths[widest]) {
				widest = column
			}
		}
		if widest < 0 {
			break
		}
		widths[widest] -= 1
	}
	render_table_border(renderer, widths, "┌", "┬", "┐") or_return
	for row_index := 0; row_index <= len(table.rows); row_index += 1 {
		cells := table.header
		is_header := row_index == 0
		if !is_header {
			cells = table.rows[row_index - 1]
		}
		render_table_cells(renderer, cells, table.alignments, widths, is_header) or_return
		if row_index < len(table.rows) {
			render_table_border(renderer, widths, "├", "┼", "┤") or_return
		}
	}
	render_table_border(renderer, widths, "└", "┴", "┘") or_return
	return nil
}

@(private = "file")
table_width :: proc(widths: []int) -> int {
	width := 1 + len(widths) * 3
	for value in widths {
		width += value
	}
	return width
}

@(private = "file")
cell_columns :: proc(spans: []markdown.Span) -> int {
	column := 0
	widest := 0
	for span in spans {
		if span.text == "\n" {
			widest = max(widest, column)
			column = 0
			continue
		}
		column += text.text_columns_at(span.text, column)
	}
	return max(widest, column)
}

@(private = "file", require_results)
render_table_border :: proc(renderer: ^Renderer, widths: []int, left, middle, right: string) -> mem.Allocator_Error {
	style := term.Style {
		modifiers = {.Dim},
	}
	renderer_segment(renderer, left, style) or_return
	for column_width, column in widths {
		line, err := strings.repeat("─", column_width + 2, renderer.allocator)
		if err != nil {
			return err
		}
		renderer_segment(renderer, line, style) or_return
		if column + 1 == len(widths) {
			renderer_segment(renderer, right, style) or_return
		} else {
			renderer_segment(renderer, middle, style) or_return
		}
	}
	renderer_flush_line(renderer) or_return
	return nil
}

@(private = "file", require_results)
render_table_cells :: proc(renderer: ^Renderer, cells: []markdown.Cell, alignments: []markdown.Alignment, widths: []int, header: bool) -> mem.Allocator_Error {
	rendered: [dynamic]Renderer
	defer rendered_cells_destroy(&rendered)
	for cell, column in cells {
		cell_renderer := Renderer {
			allocator = renderer.allocator,
		}
		extra: term.Modifiers
		if header {
			extra |= {.Bold}
		}
		if render_error := paragraph_render(&cell_renderer, cell, widths[column], extra); render_error != nil {
			renderer_destroy(&cell_renderer)
			return render_error
		}
		if _, err := append(&rendered, cell_renderer); err != nil {
			renderer_destroy(&cell_renderer)
			return err
		}
	}
	row_height := 1
	for cell_renderer in rendered {
		row_height = max(row_height, len(cell_renderer.lines))
	}
	for row := 0; row < row_height; row += 1 {
		renderer_segment(renderer, "│", term.Style{modifiers = {.Dim}}) or_return
		for column in 0 ..< len(widths) {
			renderer_spaces(renderer, 1) or_return
			line: []Styled_Segment
			if row < len(rendered[column].lines) {
				line = rendered[column].lines[row]
			}
			padding := max(widths[column] - segments_columns(line, 0), 0)
			left_padding, right_padding := table_alignment_padding(alignments[column], padding)
			renderer_spaces(renderer, left_padding) or_return
			renderer_append_segments(renderer, line) or_return
			renderer_spaces(renderer, right_padding) or_return
			renderer_spaces(renderer, 1) or_return
			renderer_segment(renderer, "│", term.Style{modifiers = {.Dim}}) or_return
		}
		renderer_flush_line(renderer) or_return
	}
	return nil
}

@(private = "file")
table_alignment_padding :: proc(alignment: markdown.Alignment, padding: int) -> (left, right: int) {
	switch alignment {
	case .Right:
		return padding, 0
	case .Center:
		left = padding / 2
		return left, padding - left
	case .None, .Left:
		return 0, padding
	}
	return 0, padding
}

@(private = "file")
rendered_cells_destroy :: proc(cells: ^[dynamic]Renderer) {
	for &cell in cells {
		renderer_destroy(&cell)
	}
	delete(cells^)
	cells^ = {}
}
