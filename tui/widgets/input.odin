package widgets

import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import keys "nabla:input"
import "nabla:term"
import "nabla:text"
import "nabla:tui"

// Input is a text editor: text holds the bytes, cursor is a byte offset at a
// grapheme cluster boundary. The text may hold line breaks, so a caller draws it
// through input_lines rather than as one row. The caller owns text: input_init
// pins its allocator, input_destroy releases it.
//
// kill holds the text of the last kill, which input_yank inserts. undo and redo
// hold owned snapshots of the text taken before an edit that starts a new run:
// a run is consecutive edits of one Input_Edit_Kind, and typing ends a run at
// whitespace. Their allocator is the one input_init pinned.
Input :: struct {
	text:      [dynamic]u8,
	cursor:    int,
	kill:      [dynamic]u8,
	undo:      [dynamic]Input_Snapshot,
	redo:      [dynamic]Input_Snapshot,
	last_edit: Input_Edit_Kind,
}

Input_Edit_Kind :: enum {
	None,
	Insert,
	Delete_Back,
	Delete_Forward,
	Other,
}

Input_Snapshot :: struct {
	text:   []u8,
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
	input.kill = make([dynamic]u8, 0, 0, allocator)
	input.undo = make([dynamic]Input_Snapshot, 0, 0, allocator)
	input.redo = make([dynamic]Input_Snapshot, 0, 0, allocator)
}

input_text :: proc(input: ^Input) -> string {
	return string(input.text[:])
}

input_cursor :: proc(input: ^Input) -> int {
	return input.cursor
}

// input_clear empties the text and forgets the undo and redo history; the kill
// slot stays.
input_clear :: proc(input: ^Input) {
	clear(&input.text)
	input.cursor = 0
	_input_snapshots_clear(&input.undo)
	_input_snapshots_clear(&input.redo)
	input.last_edit = .None
}

input_destroy :: proc(input: ^Input) {
	_input_snapshots_clear(&input.undo)
	_input_snapshots_clear(&input.redo)
	delete(input.undo)
	delete(input.redo)
	delete(input.kill)
	delete(input.text)
	input^ = {}
}

// input_insert inserts value at the cursor after text.sanitizer_write's rule: line breaks
// and tabs are kept, CR and CRLF become one line break, escape sequences and other control
// characters are removed, and invalid UTF-8 becomes U+FFFD. It returns an allocation
// failure and leaves the text unchanged.
@(require_results)
input_insert :: proc(input: ^Input, value: string) -> mem.Allocator_Error {
	if len(value) == 0 {
		return nil
	}
	_input_record(input, .Insert) or_return
	_input_insert(input, value) or_return
	if last, _ := utf8.decode_last_rune(input.text[:input.cursor]); unicode.is_space(last) {
		input.last_edit = .None
	}
	return nil
}

@(private)
_input_insert :: proc(input: ^Input, value: string) -> mem.Allocator_Error {
	previous_length := len(input.text)
	sanitizer: text.Sanitizer
	err := text.sanitizer_write(&sanitizer, &input.text, value)
	if err == nil {
		err = text.sanitizer_flush(&sanitizer, &input.text)
	}
	if err != nil {
		resize(&input.text, previous_length)
		return err
	}
	slice.rotate_left(input.text[input.cursor:], previous_length - input.cursor)
	input.cursor += len(input.text) - previous_length
	return nil
}

@(require_results)
input_insert_rune :: proc(input: ^Input, value: rune) -> mem.Allocator_Error {
	encoded, width := utf8.encode_rune(value)
	return input_insert(input, string(encoded[:width]))
}

@(require_results)
input_insert_newline :: proc(input: ^Input) -> mem.Allocator_Error {
	return input_insert(input, "\n")
}

// The edits below that return (changed, err) report changed false when there was
// nothing to edit, and an allocation failure as err with the text unchanged.
input_backspace :: proc(input: ^Input) -> (changed: bool, err: mem.Allocator_Error) {
	if input.cursor <= 0 {
		return false, nil
	}
	start := text.prev_grapheme_offset(input_text(input), input.cursor)
	_input_record(input, .Delete_Back) or_return
	_input_remove(input, start, input.cursor)
	input.cursor = start
	return true, nil
}

input_delete :: proc(input: ^Input) -> (changed: bool, err: mem.Allocator_Error) {
	value := input_text(input)
	if input.cursor >= len(value) {
		return false, nil
	}
	_input_record(input, .Delete_Forward) or_return
	_input_remove(input, input.cursor, text.next_grapheme_offset(value, input.cursor))
	return true, nil
}

input_move_word_left :: proc(input: ^Input) -> bool {
	start := text.word_previous_offset(input_text(input), input.cursor)
	moved := start != input.cursor
	input.cursor = start
	input.last_edit = .None
	return moved
}

input_move_word_right :: proc(input: ^Input) -> bool {
	end := text.word_next_offset(input_text(input), input.cursor)
	moved := end != input.cursor
	input.cursor = end
	input.last_edit = .None
	return moved
}

// input_delete_word_back, input_kill_to_end and input_kill_to_start remove text
// and store it in the kill slot, replacing the previous kill. They return changed
// false when there is nothing to remove, and an allocation failure as err with the
// text unchanged. The kill ends at the line: input_kill_to_end at the end of a line
// removes the line break, and input_kill_to_start stops after the previous one.
input_delete_word_back :: proc(input: ^Input) -> (changed: bool, err: mem.Allocator_Error) {
	return _input_kill(input, text.word_previous_offset(input_text(input), input.cursor), input.cursor)
}

input_kill_to_end :: proc(input: ^Input) -> (changed: bool, err: mem.Allocator_Error) {
	value := input_text(input)
	end := len(value)
	if relative := strings.index_byte(value[input.cursor:], '\n'); relative >= 0 {
		end = input.cursor + max(relative, 1)
	}
	return _input_kill(input, input.cursor, end)
}

input_kill_to_start :: proc(input: ^Input) -> (changed: bool, err: mem.Allocator_Error) {
	start := strings.last_index_byte(input_text(input)[:input.cursor], '\n') + 1
	return _input_kill(input, start, input.cursor)
}

// input_yank inserts the kill slot at the cursor. It returns changed false when
// the slot is empty, and an allocation failure as err.
input_yank :: proc(input: ^Input) -> (changed: bool, err: mem.Allocator_Error) {
	if len(input.kill) == 0 {
		return false, nil
	}
	_input_record(input, .Other) or_return
	_input_insert(input, string(input.kill[:])) or_return
	return true, nil
}

// input_undo restores the text and cursor taken before the last run of edits,
// and input_redo returns to the state input_undo left. Both return changed false
// when there is nothing to restore, and an allocation failure as err.
input_undo :: proc(input: ^Input) -> (changed: bool, err: mem.Allocator_Error) {
	return _input_restore(input, &input.undo, &input.redo)
}

input_redo :: proc(input: ^Input) -> (changed: bool, err: mem.Allocator_Error) {
	return _input_restore(input, &input.redo, &input.undo)
}

input_move_left :: proc(input: ^Input) -> bool {
	if input.cursor <= 0 {
		return false
	}
	input.cursor = text.prev_grapheme_offset(input_text(input), input.cursor)
	input.last_edit = .None
	return true
}

input_move_right :: proc(input: ^Input) -> bool {
	value := input_text(input)
	if input.cursor >= len(value) {
		return false
	}
	input.cursor = text.next_grapheme_offset(value, input.cursor)
	input.last_edit = .None
	return true
}

input_move_home :: proc(input: ^Input) -> bool {
	if input.cursor == 0 {
		return false
	}
	input.cursor = 0
	input.last_edit = .None
	return true
}

input_move_end :: proc(input: ^Input) -> bool {
	end := len(input_text(input))
	if input.cursor == end {
		return false
	}
	input.cursor = end
	input.last_edit = .None
	return true
}

// input_key applies one key press to the text and reports whether input
// binds it. A bound key is handled even when it changes nothing, such as Left
// at the start. Up and Down are handled only when the caret moves between the
// rows drawn at width, so a caller can use them for history. An edit that
// cannot allocate leaves the text unchanged and returns the error. Release
// events and keys with a modifier other than the ones a binding names are not
// handled.
input_key :: proc(input: ^Input, key: keys.Key_Event, width: int, profile: text.Width_Profile) -> (handled: bool, err: mem.Allocator_Error) {
	if key.kind == .Release || .Super in key.modifiers {
		return false, nil
	}
	control := .Control in key.modifiers
	alt := .Alt in key.modifiers
	shift := .Shift in key.modifiers
	bare := !control && !alt
	switch key.code {
	case .Left:
		if control || alt {
			_ = input_move_word_left(input)
		} else {
			_ = input_move_left(input)
		}
	case .Right:
		if control || alt {
			_ = input_move_word_right(input)
		} else {
			_ = input_move_right(input)
		}
	case .Home:
		_ = input_move_home(input)
	case .End:
		_ = input_move_end(input)
	case .Up:
		return bare && input_move_up(input, width, profile), nil
	case .Down:
		return bare && input_move_down(input, width, profile), nil
	case .Backspace:
		if control {
			return false, nil
		}
		if alt {
			_ = input_delete_word_back(input) or_return
		} else {
			_ = input_backspace(input) or_return
		}
	case .Delete:
		if !bare {
			return false, nil
		}
		_ = input_delete(input) or_return
	case .Enter:
		if control || !(shift || alt) {
			return false, nil
		}
		input_insert_newline(input) or_return
	case .Character:
		return _input_key_character(input, key)
	case .Tab, .Escape, .Page_Up, .Page_Down, .Insert, .F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8, .F9, .F10, .F11, .F12:
		return false, nil
	}
	return true, nil
}

@(private)
_input_key_character :: proc(input: ^Input, key: keys.Key_Event) -> (handled: bool, err: mem.Allocator_Error) {
	control := .Control in key.modifiers
	alt := .Alt in key.modifiers
	shift := .Shift in key.modifiers
	switch {
	case control && !alt:
		switch unicode.to_lower(key.character) {
		case 'a':
			_ = input_move_home(input)
		case 'e':
			_ = input_move_end(input)
		case 'h':
			_ = input_backspace(input) or_return
		case 'w':
			_ = input_delete_word_back(input) or_return
		case 'k':
			_ = input_kill_to_end(input) or_return
		case 'u':
			_ = input_kill_to_start(input) or_return
		case 'y':
			_ = input_yank(input) or_return
		case 'z':
			if shift {
				_ = input_redo(input) or_return
			} else {
				_ = input_undo(input) or_return
			}
		case:
			return false, nil
		}
	case alt && !control:
		switch key.character {
		case 'b':
			_ = input_move_word_left(input)
		case 'f':
			_ = input_move_word_right(input)
		case:
			return false, nil
		}
	case !control && !alt:
		if key.character < 0x20 || key.character == 0x7f {
			return false, nil
		}
		input_insert_rune(input, key.character) or_return
	case:
		return false, nil
	}
	return true, nil
}

// input_lines splits the text into the rows a caller draws at `width`: a logical
// line, or the part of one that fits, so a long line wraps rather than running
// past the edge. The rows borrow the text and are allocated with the caller's
// temp allocator, because a caller measures and draws them within one frame.
//
// On an allocation failure it returns the rows produced so far together with
// the allocator error. The caller must draw none of them: a short row list is a
// wrong one, not a shorter view.
@(require_results)
input_lines :: proc(
	input: ^Input,
	width: int,
	profile: text.Width_Profile = text.DEFAULT_WIDTH_PROFILE,
) -> (
	lines: [dynamic]Input_Line,
	err: mem.Allocator_Error,
) {
	lines = make([dynamic]Input_Line, 0, 8, context.temp_allocator)
	value := input_text(input)
	start := 0
	for {
		rest := value[start:]
		relative_end := strings.index(rest, "\n")
		logical_end := len(value)
		has_newline := relative_end >= 0
		if has_newline {
			logical_end = start + relative_end
		}
		if start == logical_end {
			if _, append_err := append(&lines, Input_Line{text = "", start = start, end = start}); append_err != nil {
				return lines, append_err
			}
		} else {
			offset := start
			for offset < logical_end {
				piece := text.truncate_text(value[offset:logical_end], width, profile)
				end := offset + len(piece)
				if end == offset {
					end = text.next_grapheme_offset(value, offset)
				}
				if _, append_err := append(&lines, Input_Line{text = value[offset:end], start = offset, end = end}); append_err != nil {
					return lines, append_err
				}
				offset = end
			}
		}
		if !has_newline {
			break
		}
		start = logical_end + 1
		if start > len(value) {
			break
		}
	}
	return lines, nil
}

// input_cursor_row returns the row the caret is on.
input_cursor_row :: proc(input: ^Input, lines: []Input_Line) -> int {
	cursor := input_cursor(input)
	row := 0
	for line, index in lines {
		if cursor >= line.start && cursor <= line.end {
			row = index
		}
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
	lines, lines_error := input_lines(input, width, profile)
	if lines_error != nil {
		return false
	}
	row := input_cursor_row(input, lines[:])
	target := row + delta
	if target < 0 || target >= len(lines) {
		return false
	}
	column := text.text_columns(input_text(input)[lines[row].start:input.cursor], profile)
	input.cursor = _input_row_offset(lines[target], column, profile)
	input.last_edit = .None
	return true
}

// _input_row_offset returns the offset in line whose column is the closest to
// `column` from the left.
@(private)
_input_row_offset :: proc(line: Input_Line, column: int, profile: text.Width_Profile) -> int {
	offset := 0
	for offset < len(line.text) {
		next := text.next_grapheme_offset(line.text, offset)
		if text.text_columns(line.text[:next], profile) > column {
			break
		}
		offset = next
	}
	return line.start + offset
}

// draw_input_rect draws the text into rect, wrapping at the rect's width and
// scrolling the rows to keep the caret visible, and returns the caret for the
// frame. A failed row list returns the allocator error and draws nothing.
@(require_results)
draw_input_rect :: proc(
	buffer: ^term.Frame_Buffer,
	rect: tui.Cell_Rect,
	input: ^Input,
	style: term.Style,
	profile: text.Width_Profile = text.DEFAULT_WIDTH_PROFILE,
) -> (
	cursor: term.Cursor,
	err: mem.Allocator_Error,
) {
	if rect.width <= 0 || rect.height <= 0 {
		return {}, nil
	}
	lines, lines_error := input_lines(input, rect.width, profile)
	if lines_error != nil {
		return {}, lines_error
	}
	window := _input_window(input, lines[:], rect, profile)
	for index in window.start ..< min(window.start + rect.height, len(lines)) {
		_, _ = tui.draw_text(buffer, {x = rect.x, y = rect.y + index - window.start, width = rect.width, height = 1}, lines[index].text, style, profile)
	}
	return term.Cursor{visible = true, position = {rect.x + window.column, rect.y + window.row - window.start}, placed = true}, nil
}

// draw_input_context draws into the active layout box, keeps the caret visible,
// and records the cursor intent on the tui frame. A failed row list returns the
// allocator error and draws nothing.
@(require_results)
draw_input_context :: proc(ctx: ^tui.Context, input: ^Input, style: term.Style) -> (cursor: term.Cursor, err: mem.Allocator_Error) {
	rect, ok := tui.bounds(ctx)
	if !ok || rect.width <= 0 || rect.height <= 0 {
		return {}, nil
	}
	profile, profile_ok := tui.width_profile(ctx)
	if !profile_ok {
		return {}, nil
	}
	lines, lines_error := input_lines(input, rect.width, profile)
	if lines_error != nil {
		return {}, lines_error
	}
	window := _input_window(input, lines[:], rect, profile)
	for index in window.start ..< min(window.start + rect.height, len(lines)) {
		_, _ = tui.draw_text_at(ctx, {x = rect.x, y = rect.y + index - window.start, width = rect.width, height = 1}, lines[index].text, style)
	}
	cursor = term.Cursor {
		visible  = true,
		position = {rect.x + window.column, rect.y + window.row - window.start},
		placed   = true,
	}
	// A refused cursor (an out-of-bounds caret, or a frame that already failed)
	// is recorded on the frame, which tui.result reports, so the refusal is not
	// swallowed here.
	_ = tui.set_cursor(ctx, cursor)
	return cursor, nil
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
	start := scroll_reveal(0, rect.height, row)
	column := text.text_columns(input_text(input)[lines[row].start:input.cursor], profile)
	return {start = start, row = row, column = clamp(column, 0, max(rect.width - 1, 0))}
}

draw_input :: proc {
	draw_input_rect,
	draw_input_context,
}

@(private)
_input_kill :: proc(input: ^Input, start, end: int) -> (changed: bool, err: mem.Allocator_Error) {
	if start >= end {
		return false, nil
	}
	_input_record(input, .Other) or_return
	clear(&input.kill)
	if _, err = append(&input.kill, ..input.text[start:end]); err != nil {
		clear(&input.kill)
		return false, err
	}
	_input_remove(input, start, end)
	input.cursor = start
	return true, nil
}

// _input_record is called before an edit: it pushes a snapshot when the edit
// starts a new run (every kill, yank and word delete is its own run), and drops
// the redo history. It returns an
// allocation failure, and the edit must not happen.
@(private)
_input_record :: proc(input: ^Input, kind: Input_Edit_Kind) -> (err: mem.Allocator_Error) {
	if kind != input.last_edit || kind == .Other {
		snapshot := _input_snapshot(input) or_return
		if _, err = append(&input.undo, snapshot); err != nil {
			delete(snapshot.text, input.text.allocator)
			return err
		}
	}
	_input_snapshots_clear(&input.redo)
	input.last_edit = kind
	return nil
}

@(private)
_input_snapshot :: proc(input: ^Input) -> (snapshot: Input_Snapshot, err: mem.Allocator_Error) {
	cloned := slice.clone(input.text[:], input.text.allocator) or_return
	return {text = cloned, cursor = input.cursor}, nil
}

// _input_restore pops the newest snapshot of from into the input and pushes the
// state it replaces onto to.
@(private)
_input_restore :: proc(input: ^Input, from, to: ^[dynamic]Input_Snapshot) -> (changed: bool, err: mem.Allocator_Error) {
	if len(from) == 0 {
		return false, nil
	}
	replaced := _input_snapshot(input) or_return
	restored := from[len(from) - 1]
	if _, err = append(to, replaced); err != nil {
		delete(replaced.text, input.text.allocator)
		return false, err
	}
	if err = resize(&input.text, len(restored.text)); err != nil {
		pop(to)
		delete(replaced.text, input.text.allocator)
		return false, err
	}
	pop(from)
	copy(input.text[:], restored.text)
	input.cursor = restored.cursor
	input.last_edit = .None
	delete(restored.text, input.text.allocator)
	return true, nil
}

@(private)
_input_snapshots_clear :: proc(snapshots: ^[dynamic]Input_Snapshot) {
	for snapshot in snapshots[:] {
		delete(snapshot.text, snapshots.allocator)
	}
	clear(snapshots)
}

// _input_remove deletes [start, end). The asserted span makes the resize a
// shrink, which cannot allocate.
_input_remove :: proc(input: ^Input, start, end: int) {
	assert(start >= 0 && end >= start && end <= len(input.text))
	copy(input.text[start:], input.text[end:])
	resize(&input.text, len(input.text) - (end - start))
}
