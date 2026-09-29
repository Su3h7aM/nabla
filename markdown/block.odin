package markdown

import "base:runtime"
import "core:mem"

// parse reads source as Markdown and returns its document. Every slice is
// allocated from allocator and freed by destroy. Every string is a view into
// source, which must outlive the document. The only error is allocation failure;
// on failure, nothing remains allocated.
@(require_results)
parse :: proc(source: string, allocator := context.allocator) -> (document: Document, err: mem.Allocator_Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	lines := make([dynamic]string, context.temp_allocator) or_return
	start := 0
	for index := 0; index <= len(source); index += 1 {
		if index < len(source) && source[index] != '\n' {
			continue
		}
		line := source[start:index]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		append(&lines, line) or_return
		start = index + 1
	}

	blocks := parse_blocks(lines[:], allocator) or_return
	document = Document {
		blocks    = blocks,
		allocator = allocator,
	}
	return
}

@(private, require_results)
parse_blocks :: proc(lines: []string, allocator: mem.Allocator) -> (result: []Block, err: mem.Allocator_Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	blocks := make([dynamic]Block, allocator) or_return
	defer if err != nil {
		blocks_destroy(blocks[:], allocator)
	}

	index := 0
	for index < len(lines) {
		line := lines[index]
		if is_blank(line) {
			index += 1
			continue
		}

		content, indent := block_content(line)
		block: Block
		_, _, _, fence := fence_open(content)
		level, heading, is_heading := atx_heading(content)
		_, is_list := list_marker(line)
		switch {
		case indent >= 4:
			block, index = parse_indented_code(lines, index, allocator) or_return
		case fence:
			block, index = parse_fence(lines, index, allocator) or_return
		case thematic_break(content):
			block = Thematic_Break{}
			index += 1
		case is_heading:
			spans := parse_inlines({heading}, allocator) or_return
			block = Heading {
				level = level,
				spans = spans,
			}
			index += 1
		case quote_opener(line):
			block, index = parse_quote(lines, index, allocator) or_return
		case is_list:
			block, index = parse_list(lines, index, allocator) or_return
		case table_starts(lines, index):
			block, index = parse_table(lines, index, allocator) or_return
		case:
			block, index = parse_paragraph(lines, index, allocator) or_return
		}
		append_block(&blocks, block, allocator) or_return
	}

	result = blocks[:]
	return
}

@(private, require_results)
append_block :: proc(blocks: ^[dynamic]Block, block: Block, allocator: mem.Allocator) -> mem.Allocator_Error {
	_, err := append(blocks, block)
	if err != nil {
		block_destroy(block, allocator)
	}
	return err
}

@(private, require_results)
parse_fence :: proc(lines: []string, start: int, allocator: mem.Allocator) -> (block: Block, next_index: int, err: mem.Allocator_Error) {
	opening, indent := block_content(lines[start])
	character, minimum, info, _ := fence_open(opening)
	code := make([dynamic]string, allocator) or_return
	defer if err != nil {
		delete(code)
	}

	index := start + 1
	for index < len(lines) {
		line := lines[index]
		closing, closing_indent := block_content(line)
		if closing_indent <= 3 && fence_close(closing, character, minimum) {
			index += 1
			break
		}
		append(&code, strip_columns(line, indent)) or_return
		index += 1
	}

	block = Code_Block {
		info  = info,
		lines = code[:],
	}
	next_index = index
	return
}

@(private, require_results)
parse_indented_code :: proc(lines: []string, start: int, allocator: mem.Allocator) -> (block: Block, next_index: int, err: mem.Allocator_Error) {
	code := make([dynamic]string, allocator) or_return
	defer if err != nil {
		delete(code)
	}

	index := start
	last_nonblank := 0
	for index < len(lines) {
		line := lines[index]
		if !is_blank(line) && indentation(line) < 4 {
			break
		}
		append(&code, strip_columns(line, 4)) or_return
		if !is_blank(line) {
			last_nonblank = len(code)
		}
		index += 1
	}
	// Shortening the code slice cannot allocate.
	_ = resize(&code, last_nonblank)
	block = Code_Block {
		lines = code[:],
	}
	next_index = index
	return
}

@(private, require_results)
parse_quote :: proc(lines: []string, start: int, allocator: mem.Allocator) -> (block: Block, next_index: int, err: mem.Allocator_Error) {
	quote_lines := make([dynamic]string, context.temp_allocator) or_return
	index := start
	fence: Fence_State
	for index < len(lines) {
		line := lines[index]
		if content, ok := quote_content(line); ok {
			append(&quote_lines, content) or_return
			fence_update(&fence, content)
			index += 1
			continue
		}
		if is_blank(line) || len(quote_lines) == 0 {
			break
		}
		previous := quote_lines[len(quote_lines) - 1]
		if is_blank(previous) || fence.character != 0 || starts_block(previous) || starts_block(line) {
			break
		}
		append(&quote_lines, trim_leading(line)) or_return
		fence_update(&fence, quote_lines[len(quote_lines) - 1])
		index += 1
	}

	blocks := parse_blocks(quote_lines[:], allocator) or_return
	block = Quote {
		blocks = blocks,
	}
	next_index = index
	return
}

@(private, require_results)
parse_list :: proc(lines: []string, start: int, allocator: mem.Allocator) -> (block: Block, next_index: int, err: mem.Allocator_Error) {
	first, _ := list_marker(lines[start])
	items := make([dynamic][]Block, allocator) or_return
	defer if err != nil {
		items_destroy(items[:], allocator)
	}
	tight := true
	index := start

	for index < len(lines) {
		marker, ok := list_marker(lines[index])
		if !ok || !same_list(first, marker) {
			break
		}
		item_lines := make([dynamic]string, context.temp_allocator) or_return
		item_content := lines[index][marker.content_start:]
		append(&item_lines, item_content) or_return
		content_indent := marker.content_indent
		fence: Fence_State
		fence_update(&fence, item_content)
		cursor := index + 1
		pending_blanks := 0

		for cursor < len(lines) {
			line := lines[cursor]
			if is_blank(line) {
				if fence.character != 0 {
					append(&item_lines, "") or_return
					cursor += 1
					continue
				}
				pending_blanks += 1
				cursor += 1
				continue
			}

			next_marker, is_marker := list_marker(line)
			if is_marker && next_marker.indent == first.indent {
				break
			}

			if indentation(line) >= content_indent {
				if pending_blanks > 0 {
					tight = false
					for blank_index := 0; blank_index < pending_blanks; blank_index += 1 {
						append(&item_lines, "") or_return
					}
					pending_blanks = 0
				}
				content := strip_columns(line, content_indent)
				append(&item_lines, content) or_return
				fence_update(&fence, content)
				cursor += 1
				continue
			}

			// a paragraph continues lazily only across no blank line
			previous := item_lines[len(item_lines) - 1]
			if pending_blanks == 0 && !is_blank(previous) && fence.character == 0 && !starts_block(line) {
				content := trim_leading(line)
				append(&item_lines, content) or_return
				fence_update(&fence, content)
				cursor += 1
				continue
			}
			break
		}

		item_blocks := parse_blocks(item_lines[:], allocator) or_return
		if _, append_err := append(&items, item_blocks); append_err != nil {
			blocks_destroy(item_blocks, allocator)
			return {}, 0, append_err
		}
		index = cursor
		if cursor == len(lines) {
			break
		}
		next_marker, is_marker := list_marker(lines[cursor])
		if !is_marker || !same_list(first, next_marker) {
			break
		}
		if pending_blanks > 0 {
			tight = false
		}
	}

	block = List {
		items   = items[:],
		start   = first.number,
		ordered = first.ordered,
		tight   = tight,
	}
	next_index = index
	return
}

@(private, require_results)
parse_paragraph :: proc(lines: []string, start: int, allocator: mem.Allocator) -> (block: Block, next_index: int, err: mem.Allocator_Error) {
	paragraph := make([dynamic]string, context.temp_allocator) or_return
	index := start
	level := 0

	for index < len(lines) && !is_blank(lines[index]) {
		line := lines[index]
		if len(paragraph) > 0 {
			if heading_level := setext_level(line); heading_level != 0 {
				level = heading_level
				index += 1
				break
			}
			if starts_block(line) || table_starts(lines, index) {
				break
			}
		}
		append(&paragraph, trim_leading(line)) or_return
		index += 1
	}

	spans := parse_inlines(paragraph[:], allocator) or_return
	if level != 0 {
		block = Heading {
			level = level,
			spans = spans,
		}
	} else {
		block = Paragraph {
			spans = spans,
		}
	}
	next_index = index
	return
}

@(private, require_results)
parse_table :: proc(lines: []string, start: int, allocator: mem.Allocator) -> (block: Block, next_index: int, err: mem.Allocator_Error) {
	alignments := make([dynamic]Alignment, allocator) or_return
	rows: [dynamic][]Cell
	header: []Cell
	defer if err != nil {
		delete(alignments)
		cells_destroy(header, allocator)
		rows_destroy(rows[:], allocator)
	}
	rows = make([dynamic][]Cell, allocator) or_return

	header_text := split_table_row(lines[start]) or_return
	delimiter_text := split_table_row(lines[start + 1]) or_return
	for cell in delimiter_text {
		alignment, ok := delimiter_alignment(cell)
		assert(ok)
		append(&alignments, alignment) or_return
	}
	header = parse_table_cells(header_text[:], len(alignments), allocator) or_return

	index := start + 2
	for index < len(lines) {
		line := lines[index]
		if is_blank(line) || starts_block(line) || !has_pipe(line) {
			break
		}
		row_text := split_table_row(line) or_return
		row := parse_table_cells(row_text[:], len(alignments), allocator) or_return
		if _, append_err := append(&rows, row); append_err != nil {
			cells_destroy(row, allocator)
			return {}, 0, append_err
		}
		index += 1
	}

	block = Table {
		alignments = alignments[:],
		header     = header,
		rows       = rows[:],
	}
	next_index = index
	return
}

@(private, require_results)
parse_table_cells :: proc(text: []string, columns: int, allocator: mem.Allocator) -> (result: []Cell, err: mem.Allocator_Error) {
	cells := make([dynamic]Cell, allocator) or_return
	defer if err != nil {
		cells_destroy(cells[:], allocator)
	}

	for index := 0; index < columns; index += 1 {
		cell: Cell
		if index < len(text) && len(text[index]) > 0 {
			cell = parse_inlines({text[index]}, allocator) or_return
		}
		if _, append_err := append(&cells, cell); append_err != nil {
			delete(cell, allocator)
			return nil, append_err
		}
	}
	result = cells[:]
	return
}

@(private)
starts_block :: proc(line: string) -> bool {
	content, indent := block_content(line)
	if indent > 3 {
		return false
	}
	if _, _, _, ok := fence_open(content); ok {
		return true
	}
	if _, _, ok := atx_heading(content); ok || thematic_break(content) || quote_opener(line) {
		return true
	}
	marker, ok := list_marker(line)
	if !ok || len(line[marker.content_start:]) == 0 {
		return false
	}
	return !marker.ordered || marker.number == 1
}

@(private)
block_content :: proc(line: string) -> (content: string, indent: int) {
	indent = indentation(line)
	content = strip_columns(line, indent)
	return
}

@(private)
indentation :: proc(line: string) -> int {
	columns := 0
	for character in line {
		if character == ' ' {
			columns += 1
		} else if character == '\t' {
			columns = (columns / 4 + 1) * 4
		} else {
			break
		}
	}
	return columns
}

@(private)
strip_columns :: proc(line: string, columns: int) -> string {
	position, measured := 0, 0
	for position < len(line) && measured < columns {
		if line[position] == ' ' {
			measured += 1
		} else if line[position] == '\t' {
			measured = (measured / 4 + 1) * 4
		} else {
			break
		}
		position += 1
	}
	return line[position:]
}

@(private)
trim_leading :: proc(line: string) -> string {
	return strip_columns(line, indentation(line))
}

@(private)
is_blank :: proc(line: string) -> bool {
	for character in line {
		if character != ' ' && character != '\t' {
			return false
		}
	}
	return true
}

@(private)
trim_space :: proc(value: string) -> string {
	start, end := 0, len(value)
	for start < end && (value[start] == ' ' || value[start] == '\t') {
		start += 1
	}
	for end > start && (value[end - 1] == ' ' || value[end - 1] == '\t') {
		end -= 1
	}
	return value[start:end]
}

@(private)
fence_open :: proc(line: string) -> (character: u8, length: int, info: string, ok: bool) {
	if len(line) < 3 || line[0] != '`' && line[0] != '~' {
		return
	}
	character = line[0]
	for length < len(line) && line[length] == character {
		length += 1
	}
	if length < 3 {
		return 0, 0, "", false
	}
	info = trim_space(line[length:])
	if character == '`' {
		for value in info {
			if value == '`' {
				return 0, 0, "", false
			}
		}
	}
	return character, length, info, true
}

@(private)
fence_close :: proc(line: string, character: u8, minimum: int) -> bool {
	count := 0
	for count < len(line) && line[count] == character {
		count += 1
	}
	if count < minimum {
		return false
	}
	for value in line[count:] {
		if value != ' ' && value != '\t' {
			return false
		}
	}
	return true
}

@(private)
Fence_State :: struct {
	character: u8,
	length:    int,
}

@(private)
fence_update :: proc(state: ^Fence_State, line: string) {
	content, indent := block_content(line)
	if state.character != 0 {
		if indent <= 3 && fence_close(content, state.character, state.length) {
			state^ = {}
		}
		return
	}
	if character, length, _, ok := fence_open(content); ok && indent <= 3 {
		state^ = Fence_State {
			character = character,
			length    = length,
		}
	}
}

@(private)
thematic_break :: proc(line: string) -> bool {
	character: u8
	count := 0
	for value in line {
		if value == ' ' || value == '\t' {
			continue
		}
		if value != '-' && value != '*' && value != '_' {
			return false
		}
		if character == 0 {
			character = u8(value)
		} else if character != u8(value) {
			return false
		}
		count += 1
	}
	return count >= 3
}

@(private)
atx_heading :: proc(line: string) -> (level: int, content: string, ok: bool) {
	for level < len(line) && line[level] == '#' {
		level += 1
	}
	if level == 0 || level > 6 || level < len(line) && line[level] != ' ' && line[level] != '\t' {
		return 0, "", false
	}
	content = trim_space(line[level:])
	end := len(content)
	for end > 0 && content[end - 1] == '#' {
		end -= 1
	}
	if end < len(content) && (end == 0 || content[end - 1] == ' ' || content[end - 1] == '\t') {
		content = trim_space(content[:end])
	}
	return level, content, true
}

@(private)
setext_level :: proc(line: string) -> int {
	content, indent := block_content(line)
	content = trim_space(content)
	if indent > 3 || len(content) == 0 {
		return 0
	}
	character := content[0]
	if character != '=' && character != '-' {
		return 0
	}
	for value in content {
		if u8(value) != character {
			return 0
		}
	}
	if character == '=' {
		return 1
	}
	return 2
}

@(private)
quote_opener :: proc(line: string) -> bool {
	content, indent := block_content(line)
	return indent <= 3 && len(content) > 0 && content[0] == '>'
}

// quote_content returns the line inside a block quote marker, without the
// marker and the one space that may follow it.
@(private)
quote_content :: proc(line: string) -> (content: string, ok: bool) {
	if !quote_opener(line) {
		return
	}
	content, _ = block_content(line)
	content = content[1:]
	if len(content) > 0 && content[0] == ' ' {
		content = content[1:]
	}
	return content, true
}

@(private)
List_Marker :: struct {
	indent:         int,
	content_indent: int,
	content_start:  int,
	character:      u8,
	number:         int,
	ordered:        bool,
}

@(private)
list_marker :: proc(line: string) -> (marker: List_Marker, ok: bool) {
	content, indent := block_content(line)
	if indent > 3 || len(content) == 0 {
		return
	}
	marker_end := 0
	ordered := false
	number := 0
	if content[0] == '-' || content[0] == '+' || content[0] == '*' {
		marker_end = 1
	} else if content[0] >= '0' && content[0] <= '9' {
		for marker_end < len(content) && content[marker_end] >= '0' && content[marker_end] <= '9' {
			marker_end += 1
		}
		if marker_end > 9 || marker_end >= len(content) || content[marker_end] != '.' && content[marker_end] != ')' {
			return
		}
		for digit in content[:marker_end] {
			number = number * 10 + int(digit - '0')
		}
		marker_end += 1
		ordered = true
	} else {
		return
	}
	if marker_end < len(content) && content[marker_end] != ' ' && content[marker_end] != '\t' {
		return
	}

	end_column := indent + marker_end
	content_start := marker_end
	spacing := 0
	for content_start < len(content) && (content[content_start] == ' ' || content[content_start] == '\t') {
		if content[content_start] == ' ' {
			end_column += 1
		} else {
			end_column = (end_column / 4 + 1) * 4
		}
		content_start += 1
		spacing = end_column - (indent + marker_end)
	}
	content_indent := indent + marker_end + 1
	if content_start < len(content) && spacing >= 1 && spacing <= 4 {
		content_indent = end_column
	}
	prefix_bytes := len(line) - len(content)
	marker = List_Marker {
		indent         = indent,
		content_indent = content_indent,
		content_start  = prefix_bytes + content_start,
		character      = u8(content[marker_end - 1]),
		number         = number,
		ordered        = ordered,
	}
	return marker, true
}

@(private)
same_list :: proc(first, next: List_Marker) -> bool {
	return first.indent == next.indent && first.ordered == next.ordered && first.character == next.character
}

@(private)
table_starts :: proc(lines: []string, index: int) -> bool {
	if index + 1 >= len(lines) || indentation(lines[index]) > 3 || is_blank(lines[index]) || is_blank(lines[index + 1]) {
		return false
	}
	delimiter_count, has_delimiter := table_delimiter_count(lines[index + 1])
	return has_delimiter && delimiter_count == table_row_cell_count(lines[index])
}

@(private)
table_row_content :: proc(line: string) -> string {
	content := trim_space(line)
	if len(content) > 0 && content[0] == '|' {
		content = content[1:]
	}
	if len(content) > 0 && content[len(content) - 1] == '|' && !escaped_pipe(content, len(content) - 1) {
		content = content[:len(content) - 1]
	}
	return content
}

@(private)
escaped_pipe :: proc(line: string, position: int) -> bool {
	backslashes := 0
	for index := position - 1; index >= 0 && line[index] == '\\'; index -= 1 {
		backslashes += 1
	}
	return backslashes % 2 == 1
}

@(private)
table_row_cell_count :: proc(line: string) -> int {
	content := table_row_content(line)
	count := 1
	for index := 0; index < len(content); index += 1 {
		if content[index] == '|' && !escaped_pipe(content, index) {
			count += 1
		}
	}
	return count
}

@(private)
table_delimiter_count :: proc(line: string) -> (count: int, has_delimiter: bool) {
	content := table_row_content(line)
	start := 0
	for index := 0; index <= len(content); index += 1 {
		if index < len(content) && (content[index] != '|' || escaped_pipe(content, index)) {
			continue
		}
		if _, ok := delimiter_alignment(trim_space(content[start:index])); !ok {
			return 0, false
		}
		count += 1
		if index < len(content) {
			start = index + 1
		}
	}
	for index := 0; index < len(line); index += 1 {
		if line[index] == '|' && !escaped_pipe(line, index) {
			has_delimiter = true
			break
		}
	}
	return
}

@(private)
delimiter_alignment :: proc(cell: string) -> (alignment: Alignment, ok: bool) {
	value := trim_space(cell)
	left := len(value) > 0 && value[0] == ':'
	right := len(value) > 0 && value[len(value) - 1] == ':'
	start, end := 0, len(value)
	if left {
		start += 1
	}
	if right {
		end -= 1
	}
	if start == end {
		return .None, false
	}
	for index := start; index < end; index += 1 {
		if value[index] != '-' {
			return .None, false
		}
	}
	if left && right {
		return .Center, true
	}
	if left {
		return .Left, true
	}
	if right {
		return .Right, true
	}
	return .None, true
}

@(private)
has_pipe :: proc(line: string) -> bool {
	for value in line {
		if value == '|' {
			return true
		}
	}
	return false
}

@(private, require_results)
split_table_row :: proc(line: string) -> (cells: [dynamic]string, err: mem.Allocator_Error) {
	cells = make([dynamic]string, context.temp_allocator) or_return
	content := table_row_content(line)
	start := 0
	for index := 0; index <= len(content); index += 1 {
		if index < len(content) && (content[index] != '|' || escaped_pipe(content, index)) {
			continue
		}
		append(&cells, trim_space(content[start:index])) or_return
		start = index + 1
	}
	return
}
