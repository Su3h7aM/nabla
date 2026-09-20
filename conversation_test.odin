#+test
#+private file
package main

import "core:fmt"
import "core:strings"
import "core:testing"

import "nabla:input"
import "nabla:term"
import "nabla:tui"
import "nabla:tui/widgets"

// The conversation frame pipeline: snapshot entries go in as declarations,
// layout solves the scroll container, and the visible text lines land in the
// grid. These tests assert the geometry the terminal shows, not internal
// pool state.

// conversation_glyph_row reads one row of the grid as text, so expectations
// stay legible in failure messages.
conversation_glyph_row :: proc(storage: ^Frame_Storage, row: int, scratch: []byte) -> string {
	count := 0
	for column in 0 ..< storage.buffer.columns {
		grapheme := storage.buffer.cells[row * storage.buffer.columns + column].grapheme
		if len(grapheme) > 0 {
			scratch[count] = grapheme[0]
		} else {
			scratch[count] = ' '
		}
		count += 1
	}
	return string(scratch[:count])
}

// conversation_render builds the frame buffer at the given size and draws the
// conversation once. The storage owns its cells, so frame_storage_destroy
// releases everything this allocates.
conversation_render :: proc(t: ^testing.T, app: ^App, storage: ^Frame_Storage, cols, rows: int) -> bool {
	if storage.cells != nil {
		delete(storage.cells, context.allocator)
	}
	storage.cells = make([]term.Cell, cols * rows, context.allocator)
	if !tui.init(&storage.buffer, cols, rows, storage.cells) {
		testing.expect(t, false, "frame buffer must initialize")
		return false
	}
	return draw_conversation(app, storage, tui.Cell_Rect{x = 0, y = 0, width = cols, height = rows})
}

@(test)
test_conversation_wraps_user_message_with_background :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	snap_append(app, .User, "hello world this is long enough to wrap")

	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)

	testing.expect(t, conversation_render(t, app, storage, 20, 6), "the conversation frame must solve")

	scratch: [256]byte
	// The band's own padding row, the two wrapped text rows, then the band's other
	// padding row and the blank row that separates entries.
	testing.expect_value(t, conversation_glyph_row(storage, 0, scratch[:]), "                    ")
	testing.expect_value(t, conversation_glyph_row(storage, 1, scratch[:]), "hello world this is ")
	testing.expect_value(t, conversation_glyph_row(storage, 2, scratch[:]), "long enough to wrap ")
	testing.expect_value(t, conversation_glyph_row(storage, 3, scratch[:]), "                    ")

	// Every band row carries the message's background, and the separator row
	// below the band does not.
	testing.expect_value(t, storage.buffer.cells[0].style, USER_TEXT)
	testing.expect_value(t, storage.buffer.cells[19].style, USER_TEXT)
	testing.expect_value(t, storage.buffer.cells[3 * 20].style, USER_TEXT)
	testing.expect_value(t, storage.buffer.cells[4 * 20].style, term.Style{})
}

@(test)
test_conversation_scroll_reveals_older_rows_and_clamps :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	for value in 0 ..< 30 {
		snap_append(app, .Notice, fmt.tprintf("%d", value))
	}

	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)
	scratch: [256]byte

	// The first frame discovers the scrollable range; a scroll set before it
	// has nothing to resolve against and stays at the bottom.
	testing.expect(t, conversation_render(t, app, storage, 20, 10), "the conversation frame must solve")
	testing.expect_value(t, app.conv_scroll_range, 50)

	// Scrolled back by the full range: the viewport sits on the oldest rows,
	// and the newest entries are below the fold.
	app.scroll = 50
	testing.expect(t, conversation_render(t, app, storage, 20, 10), "the scrolled frame must solve")
	testing.expect_value(t, conversation_glyph_row(storage, 0, scratch[:]), "0                   ")
	testing.expect_value(t, conversation_glyph_row(storage, 8, scratch[:]), "4                   ")
	testing.expect_value(t, conversation_glyph_row(storage, 9, scratch[:]), "                    ")

	// A scroll past the range clamps instead of over-scrolling.
	app.scroll = 1000
	testing.expect(t, conversation_render(t, app, storage, 20, 10), "the clamped frame must solve")
	testing.expect_value(t, app.scroll, 50)
	testing.expect_value(t, conversation_glyph_row(storage, 0, scratch[:]), "0                   ")
}

@(test)
test_conversation_follows_the_bottom_when_not_scrolled :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	for value in 0 ..< 30 {
		snap_append(app, .Notice, fmt.tprintf("%d", value))
	}

	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)
	scratch: [256]byte

	testing.expect(t, conversation_render(t, app, storage, 20, 10), "the conversation frame must solve")

	// New entries while pinned to the bottom stay in view; older ones leave.
	snap_append(app, .Notice, "30")
	testing.expect(t, conversation_render(t, app, storage, 20, 10), "the follow-up frame must solve")
	testing.expect_value(t, app.conv_scroll_range, 52)
	testing.expect_value(t, conversation_glyph_row(storage, 8, scratch[:]), "30                  ")
	testing.expect_value(t, conversation_glyph_row(storage, 0, scratch[:]), "26                  ")
}

// A resumed session can carry hundreds of wrapped entries. Every one of them
// must still solve: when a wrapped text node reported its max-content width as
// overflow, one bogus diagnostic per entry filled the frame's bounded
// diagnostics pool and left a resumed session with no frame at all.
@(test)
test_conversation_solves_a_long_transcript :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	for value in 0 ..< 200 {
		snap_append(app, .User, fmt.tprintf("message %d with enough words to wrap across a few columns", value))
	}

	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)

	testing.expect(t, conversation_render(t, app, storage, 40, 20), "a long transcript must still solve")
}

// An unbreakable token wider than the viewport must not widen the conversation.
// Before the root clipped horizontally, one long token set its minimum width, so
// every entry wrapped at that width and was cut off at the terminal edge instead
// of wrapping at the viewport.
@(test)
test_conversation_wraps_after_a_long_unbreakable_token :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	long := strings.repeat("x", 80) or_else ""
	defer delete(long)
	snap_append(app, .Tool, long)
	snap_append(app, .User, "hello world this is long enough to wrap")

	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)
	scratch: [64]byte
	if !testing.expect(t, conversation_render(t, app, storage, 20, 10), "the conversation frame must solve") {
		return
	}

	// The newest entry is at the bottom and wraps at the viewport width, so the
	// sentence continues line by line instead of running on to the token's width
	// and being cut off at the terminal edge. The user band adds its own padding
	// row above the text.
	testing.expect_value(t, conversation_glyph_row(storage, 5, scratch[:]), "hello world this is ")
	testing.expect_value(t, conversation_glyph_row(storage, 6, scratch[:]), "long enough to wrap ")
}

// frame_glyph_column returns the first column of row whose grapheme is glyph,
// or -1 when the row does not carry it.
frame_glyph_column :: proc(storage: ^Frame_Storage, row: int, glyph: string) -> int {
	for column in 0 ..< storage.buffer.columns {
		if storage.buffer.cells[row * storage.buffer.columns + column].grapheme == glyph {
			return column
		}
	}
	return -1
}

// A tool box and the prompt box are the same frame at the same indent: both
// start on the column the conversation's padding leaves them, and both inset
// their content one cell. Only the box outline carries the outcome color, so a
// failed call is marked without tinting the result text.
@(test)
test_tool_box_matches_the_prompt_box :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	widgets.input_init(&app.input, context.allocator)
	defer widgets.input_destroy(&app.input)
	app.columns = 40
	app.rows = 14
	testing.expect(t, widgets.input_insert(&app.input, "prompt"))
	snap_append(app, .Tool, "builtin.shell\nfirst line")
	app.run.snap.entries[0].tool_outcome = .Success

	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)
	_, frame_error := render_frame(app, storage)
	if !testing.expect_value(t, frame_error, Render_Status.None) { return }

	// The tool box sits above the prompt box, so the first corner the frame
	// carries is the tool's and the last is the prompt's.
	tool_row := -1
	prompt_row := -1
	for row in 0 ..< app.rows {
		if frame_glyph_column(storage, row, "╭") < 0 { continue }
		if tool_row < 0 { tool_row = row }
		prompt_row = row
	}
	if !testing.expect(t, tool_row >= 0 && prompt_row > tool_row, "both boxes must be drawn") { return }

	columns := storage.buffer.columns
	tool_border := frame_glyph_column(storage, tool_row, "╭")
	prompt_border := frame_glyph_column(storage, prompt_row, "╭")
	testing.expect_value(t, tool_border, prompt_border)

	// One content row down, the label and the typed text start on one column.
	content_row := tool_row + 1
	testing.expect_value(t, frame_glyph_column(storage, content_row, "f"), frame_glyph_column(storage, prompt_row + 1, "p"))

	// The outline is green for a success and the text between the bars is not.
	testing.expect_value(t, storage.buffer.cells[tool_row * columns + tool_border].style, TOOL_SUCCESS)
	testing.expect_value(t, storage.buffer.cells[content_row * columns + frame_glyph_column(storage, content_row, "│")].style, TOOL_SUCCESS)
	testing.expect_value(t, storage.buffer.cells[content_row * columns + frame_glyph_column(storage, content_row, "f")].style, TOOL_BODY)

	// A failed call draws the same box in the failure color.
	app.run.snap.entries[0].tool_outcome = .Tool_Failed
	_, frame_error = render_frame(app, storage)
	if !testing.expect_value(t, frame_error, Render_Status.None) { return }
	testing.expect_value(t, storage.buffer.cells[tool_row * columns + tool_border].style, TOOL_FAILURE)
}

// A user message is a band across the whole terminal, so it reads as a message
// rather than as a block sitting inside the conversation's indent. The indent is
// the band's own padding: the text starts one cell in, the band's last cell is
// empty, and a band row sits above and below the text.
@(test)
test_user_message_band_spans_the_terminal_width :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	app.columns = 24
	app.rows = 12
	snap_append(app, .User, "hello")

	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)
	_, frame_error := render_frame(app, storage)
	if !testing.expect_value(t, frame_error, Render_Status.None) { return }

	columns := storage.buffer.columns
	text_row := -1
	for row in 0 ..< app.rows {
		if storage.buffer.cells[row * columns + 1].grapheme == "h" {
			text_row = row
			break
		}
	}
	if !testing.expect(t, text_row > 0 && text_row + 1 < app.rows, "the user message must be drawn") { return }

	for row in text_row - 1 ..= text_row + 1 {
		testing.expect_value(t, storage.buffer.cells[row * columns].style, USER_TEXT)
		testing.expect_value(t, storage.buffer.cells[row * columns + columns - 1].style, USER_TEXT)
	}
	testing.expect_value(t, storage.buffer.cells[text_row * columns].grapheme, " ")
	testing.expect_value(t, storage.buffer.cells[text_row * columns + 1].grapheme, "h")
	testing.expect_value(t, storage.buffer.cells[(text_row - 1) * columns].grapheme, " ")
	testing.expect_value(t, storage.buffer.cells[(text_row + 1) * columns].grapheme, " ")
}

// conversation_glyph_text reads one row of the grid keeping whole graphemes, so
// a row that carries a multi-byte border glyph can still be searched.
conversation_glyph_text :: proc(storage: ^Frame_Storage, row: int, scratch: []byte) -> string {
	count := 0
	for column in 0 ..< storage.buffer.columns {
		grapheme := storage.buffer.cells[row * storage.buffer.columns + column].grapheme
		if len(grapheme) == 0 {
			scratch[count] = ' '
			count += 1
			continue
		}
		if count + len(grapheme) > len(scratch) { break }
		copy(scratch[count:], grapheme)
		count += len(grapheme)
	}
	return string(scratch[:count])
}

// conversation_row_with returns the first row whose text contains needle, or -1.
conversation_row_with :: proc(storage: ^Frame_Storage, needle: string) -> int {
	scratch: [4096]byte
	for row in 0 ..< storage.buffer.rows {
		if strings.contains(conversation_glyph_text(storage, row, scratch[:]), needle) { return row }
	}
	return -1
}

// tool_result_fixture builds a tool box body of `lines` numbered lines.
tool_result_fixture :: proc(lines: int, scratch: []byte) -> string {
	count := 0
	for line in 1 ..= lines {
		piece := fmt.bprintf(scratch[count:], "line %d\n", line)
		count += len(piece)
	}
	return string(scratch[:count])
}

// A tool result taller than the box's window is a preview, and the box says so:
// the bottom border counts the rows the window is holding back, and the window
// shows the first of them.
@(test)
test_tool_box_window_says_what_it_hides :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	app.columns = 40
	app.rows = 20
	scratch: [8192]byte
	body := tool_result_fixture(25, scratch[:])
	snap_append(app, .Tool, fmt.tprintf("builtin.shell\n%s", body))
	app.run.snap.entries[0].tool_outcome = .Success

	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)
	_, frame_error := render_frame(app, storage)
	if !testing.expect_value(t, frame_error, Render_Status.None) { return }

	// The name is on the top border, the window's ten rows are under it, and the
	// count is on the bottom border.
	testing.expect_value(t, conversation_row_with(storage, "builtin.shell"), 0)
	testing.expect_value(t, conversation_row_with(storage, "line 1"), 1)
	testing.expect_value(t, conversation_row_with(storage, "line 10"), 10)
	testing.expect_value(t, conversation_row_with(storage, "↓ 15 more lines"), 11)
	testing.expect_value(t, conversation_row_with(storage, "line 11"), -1)
}

// Scrolling a tool box moves the window through the result, and the border keeps
// saying which side the hidden rows are on. An offset past the end is clamped to
// the last window, so a wheel that runs away cannot scroll into blank rows.
@(test)
test_tool_box_window_scrolls_and_clamps :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	app.columns = 40
	app.rows = 20
	scratch: [8192]byte
	body := tool_result_fixture(25, scratch[:])
	snap_append(app, .Tool, fmt.tprintf("builtin.shell\n%s", body))
	app.run.snap.entries[0].tool_outcome = .Success

	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)
	_, frame_error := render_frame(app, storage)
	if !testing.expect_value(t, frame_error, Render_Status.None) { return }

	app.run.snap.entries[0].tool_scroll = 10
	_, frame_error = render_frame(app, storage)
	if !testing.expect_value(t, frame_error, Render_Status.None) { return }
	testing.expect_value(t, conversation_row_with(storage, "line 11"), 1)
	testing.expect_value(t, conversation_row_with(storage, "line 20"), 10)
	testing.expect_value(t, conversation_row_with(storage, "↑ 10 · ↓ 5 lines"), 11)
	testing.expect_value(t, conversation_row_with(storage, "line 21"), -1)
	// The label sits inside the border, so the box's right edge stays where the
	// top border put it however wide the count is.
	testing.expect_value(t, frame_glyph_column(storage, 11, "╯"), frame_glyph_column(storage, 0, "╮"))

	app.run.snap.entries[0].tool_scroll = 1000
	_, frame_error = render_frame(app, storage)
	if !testing.expect_value(t, frame_error, Render_Status.None) { return }
	testing.expect_value(t, app.run.snap.entries[0].tool_scroll, 15)
	testing.expect_value(t, conversation_row_with(storage, "line 16"), 1)
	testing.expect_value(t, conversation_row_with(storage, "line 25"), 10)
	testing.expect_value(t, conversation_row_with(storage, "↑ 15 more lines"), 11)
}

// A result that fits the window is not a preview: the bottom border stays a
// plain rule, because a count there would claim rows that do not exist.
@(test)
test_tool_box_window_without_hidden_rows_has_no_label :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	app.columns = 40
	app.rows = 20
	scratch: [8192]byte
	body := tool_result_fixture(3, scratch[:])
	snap_append(app, .Tool, fmt.tprintf("builtin.shell\n%s", body))
	app.run.snap.entries[0].tool_outcome = .Success

	storage := frame_storage_new(context.allocator)
	defer frame_storage_destroy(storage)
	_, frame_error := render_frame(app, storage)
	if !testing.expect_value(t, frame_error, Render_Status.None) { return }

	testing.expect_value(t, conversation_row_with(storage, "line 3"), 3)
	testing.expect_value(t, conversation_row_with(storage, "more lines"), -1)
	// A short result gets a short box: the bottom border closes right under the
	// last row it has rather than reserving the window's full height.
	testing.expect_value(t, conversation_row_with(storage, "╰"), 4)
}

// The wheel belongs to the box under the pointer: over a tool box it moves that
// box's window and leaves the transcript alone, and over anything else it
// scrolls the transcript as it always did.
@(test)
test_wheel_scrolls_the_tool_box_under_the_pointer :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	app.columns = 40
	app.rows = 20
	scratch: [8192]byte
	snap_append(app, .Notice, "notice")
	body := tool_result_fixture(25, scratch[:])
	snap_append(app, .Tool, fmt.tprintf("builtin.shell\n%s", body))
	app.run.snap.entries[1].tool_outcome = .Success

	// The wheel asks the frame that is on screen, so the app's own storage is the
	// one it has to be rendered into.
	app.storage = frame_storage_new(context.allocator)
	defer frame_storage_destroy(app.storage)
	_, frame_error := render_frame(app, app.storage)
	if !testing.expect_value(t, frame_error, Render_Status.None) { return }

	box_row := conversation_row_with(app.storage, "builtin.shell")
	notice_row := conversation_row_with(app.storage, "notice")
	if !testing.expect(t, box_row >= 0 && notice_row >= 0, "both entries must be drawn") { return }

	// The terminal reports mouse cells one-based, so the frame's row and column
	// each gain one.
	box_column := frame_glyph_column(app.storage, box_row, "╭")
	wheel_scroll(app, input.Mouse_Event{button = .Wheel_Down, x = box_column + 2, y = box_row + 2})
	testing.expect_value(t, app.run.snap.entries[1].tool_scroll, MOUSE_WHEEL_LINES)
	testing.expect_value(t, app.scroll, 0)

	wheel_scroll(app, input.Mouse_Event{button = .Wheel_Up, x = box_column + 2, y = box_row + 2})
	testing.expect_value(t, app.run.snap.entries[1].tool_scroll, 0)

	wheel_scroll(app, input.Mouse_Event{button = .Wheel_Up, x = box_column + 2, y = notice_row + 1})
	testing.expect_value(t, app.run.snap.entries[1].tool_scroll, 0)
	testing.expect_value(t, app.scroll, MOUSE_WHEEL_LINES)
}

// A tool box owns the wheel only while it can move the way the wheel asks. At its
// first or last row the report belongs to the transcript behind it, so scrolling
// over a box never traps the pointer inside the box.
@(test)
test_wheel_falls_through_a_tool_box_at_its_boundary :: proc(t: ^testing.T) {
	app := new(App)
	defer {
		snapshot_destroy(app)
		free(app)
	}
	app.run.alloc = context.allocator
	app.columns = 40
	app.rows = 20
	scratch: [8192]byte
	body := tool_result_fixture(25, scratch[:])
	snap_append(app, .Tool, fmt.tprintf("builtin.shell\n%s", body))
	app.run.snap.entries[0].tool_outcome = .Success

	app.storage = frame_storage_new(context.allocator)
	defer frame_storage_destroy(app.storage)
	_, frame_error := render_frame(app, app.storage)
	if !testing.expect_value(t, frame_error, Render_Status.None) { return }

	// The frame resolved what the window can hold, which is what the wheel asks
	// before it decides who owns the report.
	entry := &app.run.snap.entries[0]
	testing.expect_value(t, entry.tool_scroll_max, 15)
	box_row := conversation_row_with(app.storage, "builtin.shell")
	box_column := frame_glyph_column(app.storage, box_row, "╭")
	report := input.Mouse_Event {
		button = .Wheel_Up,
		x      = box_column + 2,
		y      = box_row + 2,
	}

	// At the first row there is nothing above to show, so the transcript scrolls.
	entry.tool_scroll = 0
	app.scroll = 0
	wheel_scroll(app, report)
	testing.expect_value(t, entry.tool_scroll, 0)
	testing.expect_value(t, app.scroll, MOUSE_WHEEL_LINES)

	// At the last row there is nothing below, so the transcript scrolls back.
	entry.tool_scroll = entry.tool_scroll_max
	app.scroll = 10
	report.button = .Wheel_Down
	wheel_scroll(app, report)
	testing.expect_value(t, entry.tool_scroll, entry.tool_scroll_max)
	testing.expect_value(t, app.scroll, 10 - MOUSE_WHEEL_LINES)

	// In the middle the box still has rows either way, so it keeps the report.
	entry.tool_scroll = 5
	app.scroll = 10
	wheel_scroll(app, report)
	testing.expect_value(t, entry.tool_scroll, 5 + MOUSE_WHEEL_LINES)
	testing.expect_value(t, app.scroll, 10)
}
