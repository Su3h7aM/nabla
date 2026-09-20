#+test
#+private file
package main

import "core:fmt"
import "core:strings"
import "core:testing"

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
	testing.expect_value(t, conversation_glyph_row(storage, 0, scratch[:]), "hello world this is ")
	testing.expect_value(t, conversation_glyph_row(storage, 1, scratch[:]), "long enough to wrap ")
	testing.expect_value(t, conversation_glyph_row(storage, 2, scratch[:]), "                    ")

	// User text is the only conversation role drawn on a distinct background.
	testing.expect_value(t, storage.buffer.cells[0].style, USER_TEXT)
	testing.expect_value(t, storage.buffer.cells[19].style, USER_TEXT)
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
	// and being cut off at the terminal edge.
	testing.expect_value(t, conversation_glyph_row(storage, 4, scratch[:]), "hello world this is ")
	testing.expect_value(t, conversation_glyph_row(storage, 5, scratch[:]), "long enough to wrap ")
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
