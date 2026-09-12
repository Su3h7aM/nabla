package widgets

import "core:unicode/utf8"

import "nabla:term"
import "nabla:text"
import "nabla:tui"

// Input is a single-line text editor: text holds the bytes, cursor is a byte
// offset at a grapheme cluster boundary. The caller owns text: input_init pins
// its allocator, input_destroy releases it.
Input :: struct {
	text:   [dynamic]u8,
	cursor: int,
}

input_init :: proc(input: ^Input, allocator := context.allocator) {
	input.text = make([dynamic]u8, 0, 0, allocator)
}

input_text :: proc(input: ^Input) -> string {
	return string(input.text[:])
}

input_clear :: proc(input: ^Input) {
	clear(&input.text)
	input.cursor = 0
}

input_destroy :: proc(input: ^Input) {
	delete(input.text)
	input^ = {}
}

// input_insert inserts value at the cursor. Line terminators and C0/DEL
// controls are dropped, so the input always holds one printable line; invalid
// UTF-8 is refused.
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

// draw_input draws the text into rect, scrolling horizontally to keep the
// cursor visible, and returns the caret for the frame.
draw_input :: proc(
	buffer: ^term.Frame_Buffer,
	rect: tui.Cell_Rect,
	input: Input,
	style: term.Style,
	profile: text.Width_Profile = text.DEFAULT_WIDTH_PROFILE,
) -> term.Cursor {
	if rect.width <= 0 || rect.height <= 0 {
		return {}
	}
	value := string(input.text[:])
	cursor_columns := text.text_columns(value[:input.cursor], profile)
	offset := 0
	if cursor_columns >= rect.width {
		offset = cursor_columns - rect.width + 1
	}
	start := _scrolled_prefix(value, offset, profile)
	used := text.text_columns(start, profile)
	_, _ = tui.draw_text(buffer, {x = rect.x, y = rect.y, width = rect.width, height = 1}, value[len(start):], style, profile)
	column := clamp(rect.x + cursor_columns - used, rect.x, rect.x + rect.width - 1)
	return term.Cursor{visible = true, position = {column, rect.y}, placed = true}
}

// _scrolled_prefix returns the shortest prefix to hide so the rest is scrolled
// past at least columns cells, rounded up to a cluster boundary. Rounding up
// leaves room for the caret; rounding down can leave a wide cluster filling the
// last cell, which no coordinate clamp can fix.
_scrolled_prefix :: proc(value: string, columns: int, profile: text.Width_Profile) -> string {
	if columns <= 0 {
		return ""
	}
	scrolled := 0
	it := text.display_iterator_make(value, profile)
	for {
		cluster, status := text.display_next(&it)
		if status != .OK {
			return value
		}
		scrolled += cluster.width
		if scrolled >= columns {
			return value[:cluster.end]
		}
	}
}

_input_skip :: proc(byte: u8) -> bool {
	return byte == '\r' || byte == '\n' || byte < 0x20 || byte == 0x7f
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
