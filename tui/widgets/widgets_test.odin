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
	testing.expect_value(t, input_text(&input), "xabc")
	testing.expect(t, !input_insert(&input, "\xff"))
	testing.expect_value(t, input_text(&input), "xabc")

	testing.expect(t, input_move_home(&input))
	testing.expect(t, input_delete(&input))
	testing.expect_value(t, input_text(&input), "abc")
}

@(test)
test_input_caret_tracks_the_visible_window :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)
	testing.expect(t, input_insert(&input, "ab界"))

	storage: [8]term.Cell
	frame := _frame(storage[:], 4, 1)
	cursor := draw_input(&frame, {width = 4, height = 1}, input, {})
	testing.expect(t, cursor.visible)
	testing.expect_value(t, cursor.position, term.Position{3, 0})
	testing.expect_value(t, frame.cells[0].grapheme, "b")
	testing.expect_value(t, frame.cells[1].grapheme, "界")
	testing.expect_value(t, frame.cells[1].width, u8(2))

	// A wide cluster that would fill the last cell is scrolled out, so the caret
	// has a free cell after the text.
	wide: Input
	input_init(&wide)
	defer input_destroy(&wide)
	testing.expect(t, input_insert(&wide, "界a"))
	wide_storage: [4]term.Cell
	wide_frame := _frame(wide_storage[:], 3, 1)
	wide_cursor := draw_input(&wide_frame, {width = 3, height = 1}, wide, {})
	testing.expect_value(t, wide_cursor.position, term.Position{1, 0})
	testing.expect_value(t, wide_frame.cells[0].grapheme, "a")
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
	paragraph_id := layout.Id(2)
	input_id := layout.Id(3)
	if layout.frame(&layout_ctx, {10, 5}) {
		if layout.element(
			&layout_ctx,
			layout.Element_Desc{id = block_id, layout = {flow = .Column, sizing = {layout.grow(), layout.grow()}, padding = layout.pad_all(1)}},
		) {
			layout.content(&layout_ctx, layout.Element_Desc{id = paragraph_id, layout = {sizing = {layout.fixed(8), layout.fixed(2)}}})
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
			if tui.element(&ctx, {id = paragraph_id}) {
				draw_paragraph(&ctx, Paragraph{lines = []Text_Line{{value = "hello world"}}})
			}
			if tui.element(&ctx, {id = input_id}) {
				draw_input(&ctx, input, {})
			}
		}
	}
	frame, render_error := tui.result(&ctx)
	testing.expect_value(t, render_error, tui.Frame_Error.None)
	testing.expect_value(t, frame.buffer.cells[0].grapheme, "┌")
	testing.expect_value(t, frame.buffer.cells[11].grapheme, "h")
	testing.expect_value(t, frame.buffer.cells[21].grapheme, "w")
	testing.expect_value(t, frame.buffer.cells[31].grapheme, "o")
	testing.expect(t, frame.cursor.visible && frame.cursor.placed)
	testing.expect_value(t, frame.cursor.position, term.Position{3, 3})
}

@(test)
test_block_draws_its_border_and_inner_area :: proc(t: ^testing.T) {
	block := Block {
		border = BORDER_SINGLE,
		title  = "hi",
	}
	rect := tui.Cell_Rect {
		width  = 10,
		height = 4,
	}

	storage: [40]term.Cell
	frame := _frame(storage[:], 10, 4)
	draw_block(&frame, rect, block)
	testing.expect_value(t, frame.cells[0].grapheme, "┌")
	testing.expect_value(t, frame.cells[9].grapheme, "┐")
	testing.expect_value(t, frame.cells[30].grapheme, "└")
	testing.expect_value(t, frame.cells[1].grapheme, "h")
	testing.expect_value(t, frame.cells[2].grapheme, "i")
	testing.expect_value(t, frame.cells[10].grapheme, "│")
}
