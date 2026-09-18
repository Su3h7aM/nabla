#+test
#+private file
package main

import "core:fmt"
import "core:testing"

import "nabla:term"
import "nabla:tui"

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
test_conversation_wraps_bodies_under_their_label :: proc(t: ^testing.T) {
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
	testing.expect_value(t, conversation_glyph_row(storage, 0, scratch[:]), "[user]              ")
	testing.expect_value(t, conversation_glyph_row(storage, 1, scratch[:]), "  hello world this  ")
	testing.expect_value(t, conversation_glyph_row(storage, 2, scratch[:]), "  is long enough to ")
	testing.expect_value(t, conversation_glyph_row(storage, 3, scratch[:]), "  wrap              ")
	testing.expect_value(t, conversation_glyph_row(storage, 4, scratch[:]), "                    ")

	// The label keeps the palette's bold amber through the layout round trip.
	testing.expect_value(t, storage.buffer.cells[0].style, LABEL_STYLE)
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
