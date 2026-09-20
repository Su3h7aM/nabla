package widgets

import "core:strings"
import "core:unicode/utf8"

import "nabla:term"
import "nabla:text"
import "nabla:tui"

// Input is a text editor: text holds the bytes, cursor is a byte offset at a
// grapheme cluster boundary. The text may hold line breaks, so a caller draws it
// through input_lines rather than as one row. The caller owns text: input_init
// pins its allocator, input_destroy releases it.
Input :: struct {
	text:   [dynamic]u8,
	cursor: int,
}

// Input_Line is one drawn row of the text: the bytes it holds and where they
// start and end in the buffer. A row is a logical line, or the part of one that
// fits the width it was measured at, so a caret that moves by row moves through
// what the caller draws.
Input_Line :: struct {
	text:  string,
	start: int,
	end:   int,
}

input_init :: proc(input: ^Input, allocator := context.allocator) {
	input.text = make([dynamic]u8, 0, 0, allocator)
}

input_text :: proc(input: ^Input) -> string {
	return string(input.text[:])
}

input_cursor :: proc(input: ^Input) -> int {
	return input.cursor
}

input_clear :: proc(input: ^Input) {
	clear(&input.text)
	input.cursor = 0
}

input_destroy :: proc(input: ^Input) {
	delete(input.text)
	input^ = {}
}

// input_insert inserts value at the cursor. Line breaks are kept, so a pasted
// block stays a block; every other C0/DEL control is dropped, which reads a CRLF
// pair as the one break it is. Invalid UTF-8 is refused.
input_insert :: proc(input: ^Input, value: string) -> bool {
	if !utf8.valid_string(value) {
		return false
	}
	kept := _input_byte_count(value)
	if kept == 0 {
		return true
	}
	old := len(input.text)
	if err := resize(&input.text, old + kept); err != nil {
		return false
	}
	copy(input.text[input.cursor + kept:], input.text[input.cursor:old])
	written := 0
	for byte in transmute([]byte)value {
		if _input_skip(byte) {
			continue
		}
		input.text[input.cursor + written] = byte
		written += 1
	}
	input.cursor += kept
	return true
}

input_insert_rune :: proc(input: ^Input, value: rune) -> bool {
	encoded, width := utf8.encode_rune(value)
	return input_insert(input, string(encoded[:width]))
}

input_insert_newline :: proc(input: ^Input) -> bool {
	old := len(input.text)
	if err := resize(&input.text, old + 1); err != nil { return false }
	copy(input.text[input.cursor + 1:], input.text[input.cursor:old])
	input.text[input.cursor] = '\n'
	input.cursor += 1
	return true
}

input_backspace :: proc(input: ^Input) -> bool {
	if input.cursor <= 0 {
		return false
	}
	start := text.prev_grapheme_offset(input_text(input), input.cursor)
	_input_remove(input, start, input.cursor)
	input.cursor = start
	return true
}

input_delete :: proc(input: ^Input) -> bool {
	value := input_text(input)
	if input.cursor >= len(value) {
		return false
	}
	_input_remove(input, input.cursor, text.next_grapheme_offset(value, input.cursor))
	return true
}

input_move_left :: proc(input: ^Input) -> bool {
	if input.cursor <= 0 {
		return false
	}
	input.cursor = text.prev_grapheme_offset(input_text(input), input.cursor)
	return true
}

input_move_right :: proc(input: ^Input) -> bool {
	value := input_text(input)
	if input.cursor >= len(value) {
		return false
	}
	input.cursor = text.next_grapheme_offset(value, input.cursor)
	return true
}

input_move_home :: proc(input: ^Input) -> bool {
	if input.cursor == 0 {
		return false
	}
	input.cursor = 0
	return true
}

input_move_end :: proc(input: ^Input) -> bool {
	end := len(input_text(input))
	if input.cursor == end {
		return false
	}
	input.cursor = end
	return true
}

// input_lines splits the text into the rows a caller draws at `width`: a logical
// line, or the part of one that fits, so a long line wraps rather than running
// past the edge. The rows borrow the text and are allocated with the caller's
// temp allocator, because a caller measures and draws them within one frame.
input_lines :: proc(input: ^Input, width: int, profile: text.Width_Profile = text.DEFAULT_WIDTH_PROFILE) -> [dynamic]Input_Line {
	lines := make([dynamic]Input_Line, 0, 8, context.temp_allocator)
	value := input_text(input)
	start := 0
	for {
		rest := value[start:]
		relative_end := strings.index(rest, "\n")
		logical_end := len(value)
		has_newline := relative_end >= 0
		if has_newline { logical_end = start + relative_end }
		if start == logical_end {
			append(&lines, Input_Line{text = "", start = start, end = start})
		} else {
			at := start
			for at < logical_end {
				piece := text.truncate_text(value[at:logical_end], width, profile)
				end := at + len(piece)
				if end == at { end = text.next_grapheme_offset(value, at) }
				append(&lines, Input_Line{text = value[at:end], start = at, end = end})
				at = end
			}
		}
		if !has_newline { break }
		start = logical_end + 1
		if start > len(value) { break }
	}
	return lines
}

// input_cursor_row returns the row the caret is on.
input_cursor_row :: proc(input: ^Input, lines: []Input_Line) -> int {
	cursor := input_cursor(input)
	row := 0
	for line, index in lines {
		if cursor >= line.start && cursor <= line.end { row = index }
	}
	return row
}

// input_move_up moves the caret one drawn row up, and input_move_down one row
// down. The column is kept where the target row reaches it and falls to that
// row's end where it does not, so a caret passing a short row still moves.
input_move_up :: proc(input: ^Input, width: int, profile: text.Width_Profile = text.DEFAULT_WIDTH_PROFILE) -> bool {
	return _input_move_row(input, -1, width, profile)
}

input_move_down :: proc(input: ^Input, width: int, profile: text.Width_Profile = text.DEFAULT_WIDTH_PROFILE) -> bool {
	return _input_move_row(input, 1, width, profile)
}

@(private)
_input_move_row :: proc(input: ^Input, delta, width: int, profile: text.Width_Profile) -> bool {
	lines := input_lines(input, width, profile)
	row := input_cursor_row(input, lines[:])
	target := row + delta
	if target < 0 || target >= len(lines) { return false }
	column := text.text_columns(input_text(input)[lines[row].start:input.cursor], profile)
	input.cursor = _input_row_offset(lines[target], column, profile)
	return true
}

// _input_row_offset returns the offset in line whose column is the closest to
// `column` from the left.
@(private)
_input_row_offset :: proc(line: Input_Line, column: int, profile: text.Width_Profile) -> int {
	at := 0
	for at < len(line.text) {
		next := text.next_grapheme_offset(line.text, at)
		if text.text_columns(line.text[:next], profile) > column { break }
		at = next
	}
	return line.start + at
}

// draw_input draws the text into rect, wrapping at the rect's width and
// scrolling the rows to keep the caret visible, and returns the caret for the
// frame.
draw_input_rect :: proc(
	buffer: ^term.Frame_Buffer,
	rect: tui.Cell_Rect,
	input: ^Input,
	style: term.Style,
	profile: text.Width_Profile = text.DEFAULT_WIDTH_PROFILE,
) -> term.Cursor {
	if rect.width <= 0 || rect.height <= 0 {
		return {}
	}
	lines := input_lines(input, rect.width, profile)
	window := _input_window(input, lines[:], rect, profile)
	for index in window.start ..< min(window.start + rect.height, len(lines)) {
		_, _ = tui.draw_text(buffer, {x = rect.x, y = rect.y + index - window.start, width = rect.width, height = 1}, lines[index].text, style, profile)
	}
	return term.Cursor{visible = true, position = {rect.x + window.column, rect.y + window.row - window.start}, placed = true}
}

// draw_input draws into the active layout box, keeps the caret visible, and
// records the cursor intent on the tui frame.
draw_input_context :: proc(ctx: ^tui.Context, input: ^Input, style: term.Style) -> term.Cursor {
	rect, ok := tui.bounds(ctx)
	if !ok || rect.width <= 0 || rect.height <= 0 {
		return {}
	}
	profile, profile_ok := tui.width_profile(ctx)
	if !profile_ok {
		return {}
	}
	lines := input_lines(input, rect.width, profile)
	window := _input_window(input, lines[:], rect, profile)
	for index in window.start ..< min(window.start + rect.height, len(lines)) {
		_, _ = tui.draw_text_at(ctx, {x = rect.x, y = rect.y + index - window.start, width = rect.width, height = 1}, lines[index].text, style)
	}
	cursor := term.Cursor {
		visible  = true,
		position = {rect.x + window.column, rect.y + window.row - window.start},
		placed   = true,
	}
	_ = tui.set_cursor(ctx, cursor)
	return cursor
}

// _Input_Window is the part of the rows a rect shows, and where the caret falls
// in it. The window follows the caret, so a caret below the rect scrolls the rows
// above it out.
_Input_Window :: struct {
	start:  int,
	row:    int,
	column: int,
}

@(private)
_input_window :: proc(input: ^Input, lines: []Input_Line, rect: tui.Cell_Rect, profile: text.Width_Profile) -> _Input_Window {
	row := input_cursor_row(input, lines)
	start := clamp(row - rect.height + 1, 0, max(len(lines) - rect.height, 0))
	column := text.text_columns(input_text(input)[lines[row].start:input.cursor], profile)
	return {start = start, row = row, column = clamp(column, 0, max(rect.width - 1, 0))}
}

draw_input :: proc {
	draw_input_rect,
	draw_input_context,
}

_input_skip :: proc(byte: u8) -> bool {
	return byte == '\r' || (byte < 0x20 && byte != '\n') || byte == 0x7f
}

_input_byte_count :: proc(value: string) -> int {
	count := 0
	for byte in transmute([]byte)value {
		if !_input_skip(byte) {
			count += 1
		}
	}
	return count
}

_input_remove :: proc(input: ^Input, start, end: int) {
	copy(input.text[start:], input.text[end:])
	resize(&input.text, len(input.text) - (end - start))
}
