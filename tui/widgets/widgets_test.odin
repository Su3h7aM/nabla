#+build linux
#+test
#+private file
package widgets

import "core:testing"
import "nabla:layout"
import "nabla:term"
import "nabla:tui"

_frame :: proc(storage: []term.Cell, columns, rows: int) -> term.Frame_Buffer {
	frame: term.Frame_Buffer
	_ = tui.init(&frame, columns, rows, storage)
	return frame
}

@(test)
test_paragraph_wraps_and_scrolls :: proc(t: ^testing.T) {
	lines := []Text_Line{{value = "hello world"}}
	// The space at the break belongs to the line it followed, so the second row
	// is "world", not a blank row plus "world".
	testing.expect_value(t, paragraph_height(lines, 5), 2)

	storage: [10]term.Cell
	frame := _frame(storage[:], 5, 2)
	rows := draw_paragraph(&frame, {x = 0, y = 0, width = 5, height = 2}, Paragraph{lines = lines})
	testing.expect_value(t, rows, 2)
	testing.expect_value(t, frame.cells[0].grapheme, "h")
	testing.expect_value(t, frame.cells[5].grapheme, "w")

	frame = _frame(storage[:], 5, 2)
	rows = draw_paragraph(&frame, {x = 0, y = 0, width = 5, height = 2}, Paragraph{lines = lines, scroll = 1})
	testing.expect_value(t, rows, 1)
	testing.expect_value(t, frame.cells[0].grapheme, "w")
}

@(test)
test_paragraph_keeps_wide_clusters_whole :: proc(t: ^testing.T) {
	lines := []Text_Line{{value = "abcd界x"}}
	frame_storage: [20]term.Cell
	frame := _frame(frame_storage[:], 5, 4)
	draw_paragraph(&frame, {x = 0, y = 0, width = 5, height = 4}, Paragraph{lines = lines})
	testing.expect_value(t, frame.cells[0].grapheme, "a")
	testing.expect_value(t, frame.cells[5].grapheme, "界")
	testing.expect_value(t, frame.cells[5].width, u8(2))
	testing.expect_value(t, frame.cells[6].grapheme, "")
	testing.expect_value(t, frame.cells[7].grapheme, "x")
}

@(test)
test_list_scrolls_to_keep_the_selection_visible :: proc(t: ^testing.T) {
	items := [?]string{"a", "b", "c", "d", "e"}
	list := List {
		items = items[:],
	}
	state: List_State
	storage: [12]term.Cell
	frame := _frame(storage[:], 4, 3)

	testing.expect_value(t, draw_list(&frame, {width = 4, height = 3}, list, &state), 3)
	testing.expect_value(t, state.offset, 0)

	for _ in 0 ..< 5 {
		list_select_next(&state, len(items))
	}
	testing.expect_value(t, state.selected, 4)
	draw_list(&frame, {width = 4, height = 3}, list, &state)
	testing.expect_value(t, state.offset, 2)
	testing.expect_value(t, frame.cells[0].grapheme, "c")
	testing.expect_value(t, frame.cells[4].grapheme, "d")
}

@(test)
test_input_edits_by_cluster :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)

	// e + combining acute is one cluster; backspace removes the whole cluster.
	testing.expect(t, input_insert(&input, "e\u0301x"))
	testing.expect_value(t, input_text(&input), "e\u0301x")
	testing.expect(t, input_move_left(&input))
	testing.expect(t, input_backspace(&input))
	testing.expect_value(t, input_text(&input), "x")

	testing.expect(t, input_move_end(&input))
	testing.expect(t, input_insert(&input, "a\nb\tc"))
	// The line break is kept and the tab is dropped, so the text keeps the shape
	// it was pasted in.
	testing.expect_value(t, input_text(&input), "xa\nbc")
	testing.expect(t, !input_insert(&input, "\xff"))
	testing.expect_value(t, input_text(&input), "xa\nbc")

	testing.expect(t, input_move_home(&input))
	testing.expect(t, input_delete(&input))
	testing.expect_value(t, input_text(&input), "a\nbc")
}

@(test)
test_input_keeps_explicit_newlines :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)
	testing.expect(t, input_insert(&input, "first"))
	testing.expect(t, input_insert_newline(&input))
	testing.expect(t, input_insert(&input, "second"))
	accounting := "first\nsecond"
	testing.expect_value(t, input_text(&input), accounting)
	testing.expect_value(t, input_cursor(&input), len(accounting))
}

// Up and down move by the rows the caller draws, not by logical lines. A row the
// caret passes that is shorter than the column it came from puts the caret at
// that row's end, and a wrapped line is walked row by row.
@(test)
test_input_moves_between_drawn_rows :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)
	testing.expect(t, input_insert(&input, "one\ntwo\nthree"))

	// The caret starts at the end of the last row. Moving up keeps the column
	// where the row reaches it, and "two" is too short, so the caret falls to its
	// end instead of a column the row does not have.
	testing.expect(t, input_move_up(&input, 5))
	testing.expect_value(t, input_cursor(&input), len("one\ntwo"))
	testing.expect(t, input_move_down(&input, 5))
	testing.expect_value(t, input_cursor(&input), len("one\ntwo\n") + len("thr"))
	testing.expect(t, !input_move_down(&input, 5), "the last row has no row below it")

	// Up again lands on the same end, and the first row has no row above it.
	testing.expect(t, input_move_up(&input, 5))
	testing.expect_value(t, input_cursor(&input), len("one\ntwo"))
	testing.expect(t, input_move_up(&input, 5))
	testing.expect_value(t, input_cursor(&input), len("one"))
	testing.expect(t, !input_move_up(&input, 5), "the first row has no row above it")

	// A wrapped line is several rows, so the caret walks it row by row.
	wrapped: Input
	input_init(&wrapped)
	defer input_destroy(&wrapped)
	testing.expect(t, input_insert(&wrapped, "abcdefgh"))
	testing.expect(t, input_move_home(&wrapped))
	testing.expect(t, input_move_down(&wrapped, 3))
	testing.expect_value(t, input_cursor(&wrapped), 3)
	testing.expect(t, input_move_down(&wrapped, 3))
	testing.expect_value(t, input_cursor(&wrapped), 6)
	testing.expect(t, !input_move_down(&wrapped, 3), "the last row has no row below it")
	testing.expect(t, input_move_up(&wrapped, 3))
	testing.expect_value(t, input_cursor(&wrapped), 3)
}

// The caret's row is what the window follows: a caret below the rect scrolls the
// rows above it out, and a row wider than the rect wraps instead of running past
// the edge.
@(test)
test_input_caret_tracks_the_visible_window :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)
	testing.expect(t, input_insert(&input, "ab界"))

	// The text is exactly as wide as the rect, so it is one row and the caret has
	// no cell past it to sit in.
	storage: [8]term.Cell
	frame := _frame(storage[:], 4, 1)
	cursor := draw_input(&frame, {width = 4, height = 1}, &input, {})
	testing.expect(t, cursor.visible)
	testing.expect_value(t, cursor.position, term.Position{3, 0})
	testing.expect_value(t, frame.cells[0].grapheme, "a")
	testing.expect_value(t, frame.cells[1].grapheme, "b")
	testing.expect_value(t, frame.cells[2].grapheme, "界")
	testing.expect_value(t, frame.cells[2].width, u8(2))

	// A two-row window keeps the caret's row in view, so the rows above it scroll
	// out rather than the caret leaving the rect.
	lines: Input
	input_init(&lines)
	defer input_destroy(&lines)
	testing.expect(t, input_insert(&lines, "one\ntwo\nthree"))
	line_storage: [10]term.Cell
	line_frame := _frame(line_storage[:], 5, 2)
	line_cursor := draw_input(&line_frame, {width = 5, height = 2}, &lines, {})
	testing.expect_value(t, line_cursor.position, term.Position{4, 1})
	testing.expect_value(t, line_frame.cells[0].grapheme, "t")
	testing.expect_value(t, line_frame.cells[5].grapheme, "t")
	testing.expect_value(t, line_frame.cells[9].grapheme, "e")
}

@(test)
test_widgets_draw_through_scoped_layout_boxes :: proc(t: ^testing.T) {
	options := layout.Options {
		capacities = {
			nodes = 8,
			children = 8,
			clips = 2,
			commands = 1,
			text_lines = 1,
			measured_words = 1,
			overlays = 1,
			measure_cache = 1,
			id_table = 8,
			depth = 8,
			diagnostics = 8,
		},
	}
	layout_ctx: layout.Context
	testing.expect_value(t, layout.init(&layout_ctx, options), nil)
	defer layout.destroy(&layout_ctx)
	block_id := layout.Id(1)
	input_id := layout.Id(2)
	if layout.frame(&layout_ctx, {10, 5}) {
		if layout.element(
			&layout_ctx,
			layout.Element_Desc{id = block_id, layout = {flow = .Column, sizing = {layout.grow(), layout.grow()}, padding = layout.pad_all(1)}},
		) {
			layout.content(&layout_ctx, layout.Element_Desc{id = input_id, layout = {sizing = {layout.fixed(8), layout.fixed(1)}}})
		}
	}
	layout_result, layout_error := layout.result(&layout_ctx)
	testing.expect_value(t, layout_error, layout.Frame_Error.None)

	input: Input
	input_init(&input)
	defer input_destroy(&input)
	testing.expect(t, input_insert(&input, "ok"))
	cells: [50]term.Cell
	ctx: tui.Context
	if tui.frame(&ctx, layout_result, cells[:]) {
		if tui.element(&ctx, {id = block_id}) {
			draw_block(&ctx, Block{border = BORDER_SINGLE})
			if tui.element(&ctx, {id = input_id}) {
				draw_input(&ctx, &input, {})
			}
		}
	}
	frame, render_error := tui.result(&ctx)
	testing.expect_value(t, render_error, tui.Frame_Error.None)
	testing.expect_value(t, frame.buffer.cells[0].grapheme, "┌")
	testing.expect_value(t, frame.buffer.cells[11].grapheme, "o")
	testing.expect(t, frame.cursor.visible && frame.cursor.placed)
	testing.expect_value(t, frame.cursor.position, term.Position{3, 1})
}
