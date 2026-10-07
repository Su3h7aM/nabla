package main

import "core:mem"
import "core:strconv"
import "core:strings"

import "nabla:markdown"
import "nabla:term"
import "nabla:text"

// Styled_Segment is a borrowed text span and its terminal style in a rendered line.
Styled_Segment :: struct {
	text:  string,
	style: term.Style,
	link:  string,
}

// Markdown_Lines stores segments in reading order and the end index of each line.
Markdown_Lines :: struct {
	segments:  []Styled_Segment,
	line_ends: []int,
}

// markdown_line returns the segments of line index, a view into lines.
markdown_line :: proc(lines: Markdown_Lines, index: int) -> []Styled_Segment {
	start := 0
	if index > 0 { start = lines.line_ends[index - 1] }
	return lines.segments[start:lines.line_ends[index]]
}

// Nabla has no theme, so Markdown styles use only the terminal's default colors,
// ANSI indices 1 to 6, and modifiers, and they follow whatever theme the terminal has.
MARKDOWN_CODE_STYLE :: term.Style {
	foreground = term.Indexed_Color(6),
}
MARKDOWN_LINK_STYLE :: term.Style {
	foreground = term.Indexed_Color(4),
	modifiers  = {.Underline},
}
// MARKDOWN_DIM_STYLE is for decoration: borders, rules, quote bars, info strings, link URLs.
MARKDOWN_DIM_STYLE :: term.Style {
	modifiers = {.Dim},
}
MARKDOWN_CODE_INDENT :: "  "
// MARKDOWN_SPACES and MARKDOWN_RULE_RUN are sliced for padding and rules, so a run of
// either needs no allocation; a longer run is emitted in several pieces.
MARKDOWN_SPACES :: "                                                                "
MARKDOWN_RULE_RUN :: "────────────────"
MARKDOWN_QUOTE_PREFIX :: "│ "
MARKDOWN_BULLET_PREFIX :: "• "
MARKDOWN_ORDERED_SUFFIX :: ". "
// MARKDOWN_TABLE_CELL_PADDING is the columns of space on each side of a table cell.
MARKDOWN_TABLE_CELL_PADDING :: 1
MARKDOWN_LINK_URL_PREFIX :: " ("
MARKDOWN_LINK_URL_SUFFIX :: ")"

// markdown_lines renders source as Markdown into lines no wider than width columns. It
// makes many small allocations from allocator, including list-number text the segments
// point into, and the result has no destroy: pass an arena or the temp allocator and
// free it as a whole. Segment text is otherwise a view into source or a static string,
// so source must outlive the result. The only error is an allocation failure. The
// procedure shares no state and runs on any thread.
@(require_results)
markdown_lines :: proc(source: string, width: int, allocator := context.allocator) -> (lines: Markdown_Lines, err: mem.Allocator_Error) {
	document := markdown.parse(source, allocator) or_return
	defer markdown.destroy(&document)

	renderer := Renderer {
		allocator = allocator,
		segments  = make([dynamic]Styled_Segment, allocator),
		line_ends = make([dynamic]int, allocator),
		current   = make([dynamic]Styled_Segment, allocator),
		word      = make([dynamic]Styled_Segment, allocator),
		spaces    = make([dynamic]Styled_Segment, allocator),
	}
	defer renderer_destroy(&renderer)

	render_blocks(&renderer, document.blocks, max(width, 1), false) or_return
	lines = renderer_finish(&renderer) or_return
	return lines, nil
}

@(private = "file")
Renderer :: struct {
	allocator: mem.Allocator,
	segments:  [dynamic]Styled_Segment,
	line_ends: [dynamic]int,
	// prefixes are the open quotes and list items, outermost first; every line
	// starts with their markers.
	prefixes:  [dynamic]Renderer_Prefix,
	current:   [dynamic]Styled_Segment,
	word:      [dynamic]Styled_Segment,
	spaces:    [dynamic]Styled_Segment,
}

// Renderer_Prefix is the marker an open quote or list item puts at the start of each
// line: first on the item's first line, continuation on every later one.
@(private = "file")
Renderer_Prefix :: struct {
	first:        Styled_Segment,
	continuation: Styled_Segment,
	emitted:      bool,
}

@(private = "file", require_results)
renderer_flush_line :: proc(renderer: ^Renderer) -> mem.Allocator_Error {
	for &prefix in renderer.prefixes {
		marker := prefix.continuation if prefix.emitted else prefix.first
		prefix.emitted = true
		append(&renderer.segments, marker) or_return
	}
	append(&renderer.segments, ..renderer.current[:]) or_return
	append(&renderer.line_ends, len(renderer.segments)) or_return
	clear(&renderer.current)
	return nil
}

@(private = "file", require_results)
renderer_segment :: proc(renderer: ^Renderer, value: string, style: term.Style, link: string = "") -> mem.Allocator_Error {
	if value == "" {
		return nil
	}
	_, err := append(&renderer.current, Styled_Segment{text = value, style = style, link = link})
	return err
}

@(private = "file", require_results)
renderer_append_segments :: proc(renderer: ^Renderer, segments: []Styled_Segment) -> mem.Allocator_Error {
	for segment in segments {
		renderer_segment(renderer, segment.text, segment.style, segment.link) or_return
	}
	return nil
}

@(private = "file", require_results)
renderer_spaces :: proc(renderer: ^Renderer, count: int, style: term.Style = {}) -> mem.Allocator_Error {
	return renderer_repeat(renderer, MARKDOWN_SPACES, count, style)
}

// renderer_repeat adds count columns of run, which repeats one single-column
// character, as slices of run.
@(private = "file", require_results)
renderer_repeat :: proc(renderer: ^Renderer, run: string, count: int, style: term.Style) -> mem.Allocator_Error {
	run_columns := text.text_columns(run)
	character_size := len(run) / run_columns
	for remaining := count; remaining > 0; {
		columns := min(remaining, run_columns)
		renderer_segment(renderer, run[:columns * character_size], style) or_return
		remaining -= columns
	}
	return nil
}

@(private = "file")
renderer_destroy :: proc(renderer: ^Renderer) {
	delete(renderer.segments)
	delete(renderer.line_ends)
	delete(renderer.prefixes)
	delete(renderer.current)
	delete(renderer.word)
	delete(renderer.spaces)
	renderer^ = {}
}

@(private = "file", require_results)
renderer_finish :: proc(renderer: ^Renderer) -> (lines: Markdown_Lines, err: mem.Allocator_Error) {
	if len(renderer.current) > 0 || len(renderer.line_ends) == 0 { renderer_flush_line(renderer) or_return }
	lines = Markdown_Lines {
		segments  = renderer.segments[:],
		line_ends = renderer.line_ends[:],
	}
	renderer.segments = {}
	renderer.line_ends = {}
	delete(renderer.current)
	delete(renderer.word)
	delete(renderer.spaces)
	return lines, nil
}

// renderer_blank_line ends the current block with an empty line, unless nothing was
// rendered yet or the last line already is empty.
@(private = "file", require_results)
renderer_blank_line :: proc(renderer: ^Renderer) -> mem.Allocator_Error {
	count := len(renderer.line_ends)
	if count == 0 || len(renderer_line(renderer, count - 1)) == 0 {
		return nil
	}
	return renderer_flush_line(renderer)
}

@(private = "file")
renderer_line :: proc(renderer: ^Renderer, index: int) -> []Styled_Segment {
	return markdown_line(Markdown_Lines{segments = renderer.segments[:], line_ends = renderer.line_ends[:]}, index)
}

@(private = "file", require_results)
render_blocks :: proc(renderer: ^Renderer, blocks: []markdown.Block, width: int, suppress_separators: bool) -> mem.Allocator_Error {
	has_previous := false
	for block in blocks {
		if has_previous && !suppress_separators {
			renderer_blank_line(renderer) or_return
		}
		before := len(renderer.line_ends)
		switch value in block {
		case markdown.Paragraph:
			paragraph_render(renderer, value.spans, width, {}) or_return
		case markdown.Heading:
			modifiers := term.Modifiers{.Bold}
			if value.level <= 2 {
				modifiers |= {.Underline}
			}
			paragraph_render(renderer, value.spans, width, modifiers) or_return
		case markdown.Code_Block:
			render_code_block(renderer, value, width) or_return
		case markdown.Quote:
			quote_prefix := Styled_Segment {
				text  = MARKDOWN_QUOTE_PREFIX,
				style = MARKDOWN_DIM_STYLE,
			}
			append(&renderer.prefixes, Renderer_Prefix{first = quote_prefix, continuation = quote_prefix}) or_return
			render_error := render_blocks(renderer, value.blocks, max(width - text.text_columns(MARKDOWN_QUOTE_PREFIX), 1), false)
			pop(&renderer.prefixes)
			if render_error != nil { return render_error }
		case markdown.List:
			render_list(renderer, value, width) or_return
		case markdown.Table:
			render_table(renderer, value, width) or_return
		case markdown.Thematic_Break:
			renderer_repeat(renderer, MARKDOWN_RULE_RUN, width, MARKDOWN_DIM_STYLE) or_return
			renderer_flush_line(renderer) or_return
		}
		if len(renderer.line_ends) > before {
			has_previous = true
		}
	}
	return nil
}

@(private = "file", require_results)
paragraph_render :: proc(renderer: ^Renderer, spans: []markdown.Span, width: int, extra: term.Modifiers) -> mem.Allocator_Error {
	start := len(renderer.line_ends)
	for i := 0; i < len(spans); i += 1 {
		span := spans[i]
		if span.text == "\n" {
			paragraph_place_word(renderer, width) or_return
			clear(&renderer.spaces)
			renderer_flush_line(renderer) or_return
			continue
		}
		style := span_style(span.style, extra)
		link := span.url if .Link in span.style && safe_link_url(span.url) else ""
		paragraph_add_text(renderer, span.text, style, width, link) or_return
		if .Link in span.style && paragraph_link_group_end(spans, i) && !paragraph_link_text_is_url(spans, i) {
			paragraph_add_text(renderer, MARKDOWN_LINK_URL_PREFIX, MARKDOWN_DIM_STYLE, width, link) or_return
			paragraph_add_text(renderer, span.url, MARKDOWN_DIM_STYLE, width, link) or_return
			paragraph_add_text(renderer, MARKDOWN_LINK_URL_SUFFIX, MARKDOWN_DIM_STYLE, width, link) or_return
		}
	}
	paragraph_place_word(renderer, width) or_return
	clear(&renderer.spaces)
	if len(renderer.current) > 0 || len(renderer.line_ends) == start {
		renderer_flush_line(renderer) or_return
	}
	return nil
}

@(private = "file", require_results)
paragraph_add_text :: proc(renderer: ^Renderer, value: string, style: term.Style, width: int, link: string = "") -> mem.Allocator_Error {
	word_start := 0
	offset := 0
	for offset < len(value) {
		end := text.next_grapheme_offset(value, offset)
		if end <= offset {
			end = offset + 1
		}
		if value[offset:end] == " " {
			if word_start < offset {
				if _, err := append(&renderer.word, Styled_Segment{text = value[word_start:offset], style = style, link = link}); err != nil {
					return err
				}
			}
			if len(renderer.word) > 0 {
				paragraph_place_word(renderer, width) or_return
			}
			if _, err := append(&renderer.spaces, Styled_Segment{text = value[offset:end], style = style, link = link}); err != nil {
				return err
			}
			word_start = end
		}
		offset = end
	}
	if word_start < len(value) {
		if _, err := append(&renderer.word, Styled_Segment{text = value[word_start:], style = style, link = link}); err != nil {
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
			renderer_segment(renderer, grapheme, segment.style, segment.link) or_return
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
		style.foreground = MARKDOWN_CODE_STYLE.foreground
	}
	if .Link in flags {
		style.foreground = MARKDOWN_LINK_STYLE.foreground
		style.modifiers |= MARKDOWN_LINK_STYLE.modifiers
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
render_code_block :: proc(renderer: ^Renderer, block: markdown.Code_Block, width: int) -> mem.Allocator_Error {
	if block.info != "" {
		render_code_line(renderer, block.info, MARKDOWN_DIM_STYLE, width) or_return
	}
	for line in block.lines {
		render_code_line(renderer, line, MARKDOWN_CODE_STYLE, width) or_return
	}
	return nil
}

@(private = "file", require_results)
render_code_line :: proc(renderer: ^Renderer, value: string, style: term.Style, width: int) -> mem.Allocator_Error {
	indent := MARKDOWN_CODE_INDENT
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
			buffer: [ORDERED_NUMBER_BUFFER]byte
			number_width = max(number_width, len(strconv.write_int(buffer[:], i64(number), 10)))
			number += 1
		}
	}
	number := list.start
	for item, item_index in list.items {
		if item_index > 0 && !list.tight {
			renderer_blank_line(renderer) or_return
		}
		first_text := MARKDOWN_BULLET_PREFIX
		if list.ordered {
			first_text = ordered_list_prefix(number, number_width, renderer.allocator) or_return
			number += 1
		}
		prefix_width := text.text_columns(first_text)
		// A marker is at most nine digits and its suffix, so the blank continuation
		// always fits in MARKDOWN_SPACES.
		spaces := MARKDOWN_SPACES
		marker := Renderer_Prefix {
			first = Styled_Segment{text = first_text},
			continuation = Styled_Segment{text = spaces[:prefix_width]},
		}
		append(&renderer.prefixes, marker) or_return
		start := len(renderer.line_ends)
		render_error := render_blocks(renderer, item, max(width - prefix_width, 1), list.tight)
		pop(&renderer.prefixes)
		if render_error != nil { return render_error }
		if len(renderer.line_ends) == start {
			renderer_flush_line(renderer) or_return
		}
	}
	return nil
}

// ordered_list_prefix formats an item number right-aligned in width digits, followed by
// the marker suffix, into allocator.
@(private = "file", require_results)
ordered_list_prefix :: proc(value, width: int, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	buffer: [ORDERED_NUMBER_BUFFER]byte
	number := strconv.write_int(buffer[:], i64(value), 10)
	spaces := MARKDOWN_SPACES
	padding := spaces[:clamp(width - len(number), 0, len(spaces))]
	return strings.concatenate({padding, number, MARKDOWN_ORDERED_SUFFIX}, allocator)
}

// ORDERED_NUMBER_BUFFER holds any i64 in decimal with its sign.
@(private = "file")
ORDERED_NUMBER_BUFFER :: 20

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
	width := 1 + len(widths) * (2 * MARKDOWN_TABLE_CELL_PADDING + 1)
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
	style := MARKDOWN_DIM_STYLE
	renderer_segment(renderer, left, style) or_return
	for column_width, column in widths {
		renderer_repeat(renderer, MARKDOWN_RULE_RUN, column_width + 2 * MARKDOWN_TABLE_CELL_PADDING, style) or_return
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
	rendered := make([dynamic]Renderer, renderer.allocator)
	defer rendered_cells_destroy(&rendered)
	for cell, column in cells {
		cell_renderer := Renderer {
			allocator = renderer.allocator,
			segments  = make([dynamic]Styled_Segment, renderer.allocator),
			line_ends = make([dynamic]int, renderer.allocator),
			current   = make([dynamic]Styled_Segment, renderer.allocator),
			word      = make([dynamic]Styled_Segment, renderer.allocator),
			spaces    = make([dynamic]Styled_Segment, renderer.allocator),
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
		row_height = max(row_height, len(cell_renderer.line_ends))
	}
	for row := 0; row < row_height; row += 1 {
		renderer_segment(renderer, "│", MARKDOWN_DIM_STYLE) or_return
		for column in 0 ..< len(widths) {
			renderer_spaces(renderer, MARKDOWN_TABLE_CELL_PADDING) or_return
			line: []Styled_Segment
			if row < len(rendered[column].line_ends) {
				line = renderer_line(&rendered[column], row)
			}
			padding := max(widths[column] - segments_columns(line, 0), 0)
			left_padding, right_padding := table_alignment_padding(alignments[column], padding)
			renderer_spaces(renderer, left_padding) or_return
			renderer_append_segments(renderer, line) or_return
			renderer_spaces(renderer, right_padding) or_return
			renderer_spaces(renderer, MARKDOWN_TABLE_CELL_PADDING) or_return
			renderer_segment(renderer, "│", MARKDOWN_DIM_STYLE) or_return
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

// LINK_SCHEMES are the destinations a click may open. Links come from model output, so
// schemes that run or read something locally (file, javascript, custom handlers) stay text.
@(private = "file")
LINK_SCHEMES :: [?]string{"http", "https", "mailto"}

// safe_link_url reports whether url may become a terminal hyperlink: an allowed scheme,
// and only printable ASCII, so the URL cannot end the escape sequence carrying it.
@(private = "file")
safe_link_url :: proc(url: string) -> bool {
	colon := strings.index_byte(url, ':')
	if colon < 0 { return false }
	allowed := false
	for scheme in LINK_SCHEMES {
		allowed ||= strings.equal_fold(url[:colon], scheme)
	}
	if !allowed { return false }
	for character in transmute([]u8)url {
		if character < '!' || character > '~' { return false }
	}
	return true
}
