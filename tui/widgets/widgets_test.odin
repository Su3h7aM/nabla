#+build linux
#+test
#+private file
package widgets

import "core:mem"
import "core:testing"
import "core:time"
import keys "nabla:input"
import "nabla:layout"
import "nabla:term"
import "nabla:text"
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
	testing.expect(t, input_insert(&input, "e\u0301x") == nil)
	testing.expect_value(t, input_text(&input), "e\u0301x")
	testing.expect(t, input_move_left(&input))
	testing.expect(t, input_backspace(&input) or_else false)
	testing.expect_value(t, input_text(&input), "x")

	testing.expect(t, input_move_text_end(&input))
	testing.expect(t, input_insert(&input, "a\nb\tc") == nil)
	testing.expect_value(t, input_text(&input), "xa\nb\tc")

	testing.expect(t, input_move_text_start(&input))
	testing.expect(t, input_delete(&input) or_else false)
	testing.expect_value(t, input_text(&input), "a\nb\tc")
}

@(test)
test_input_insert_sanitizes_untrusted_text :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)

	testing.expect(t, input_insert(&input, "ad") == nil)
	testing.expect(t, input_move_left(&input))
	testing.expect(t, input_insert(&input, "b\r\nc\re\x1b[31m\u0085\x07\xff\x1b[2") == nil)
	testing.expect_value(t, input_text(&input), "ab\nc\ne\uFFFDd")
	testing.expect_value(t, input_cursor(&input), len("ab\nc\ne\uFFFD"))
}

@(test)
test_input_keeps_explicit_newlines :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)
	testing.expect(t, input_insert(&input, "first") == nil)
	testing.expect(t, input_insert_newline(&input) == nil)
	testing.expect(t, input_insert(&input, "second") == nil)
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
	testing.expect(t, input_insert(&input, "one\ntwo\nthree") == nil)

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
	testing.expect(t, input_insert(&wrapped, "abcdefgh") == nil)
	testing.expect(t, input_move_text_start(&wrapped))
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
	testing.expect(t, input_insert(&input, "ab界") == nil)

	// The text is exactly as wide as the rect, so it is one row and the caret has
	// no cell past it to sit in.
	storage: [8]term.Cell
	frame := _frame(storage[:], 4, 1)
	cursor, _ := draw_input(&frame, {width = 4, height = 1}, &input, {})
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
	testing.expect(t, input_insert(&lines, "one\ntwo\nthree") == nil)
	line_storage: [10]term.Cell
	line_frame := _frame(line_storage[:], 5, 2)
	line_cursor, _ := draw_input(&line_frame, {width = 5, height = 2}, &lines, {})
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
	testing.expect(t, input_insert(&input, "ok") == nil)
	cells: [50]term.Cell
	ctx: tui.Context
	if tui.frame(&ctx, layout_result, cells[:]) {
		if tui.element(&ctx, {id = block_id}) {
			if tui.element(&ctx, {id = input_id}) {
				_, draw_error := draw_input(&ctx, &input, {})
				testing.expect(t, draw_error == nil)
			}
		}
	}
	frame, render_error := tui.result(&ctx)
	testing.expect_value(t, render_error, tui.Frame_Error.None)
	testing.expect_value(t, frame.buffer.cells[11].grapheme, "o")
	testing.expect(t, frame.cursor.visible && frame.cursor.placed)
	testing.expect_value(t, frame.cursor.position, term.Position{3, 1})
}

@(test)
test_scroll_follows_or_pins_while_range_grows :: proc(t: ^testing.T) {
	following: Scroll
	scroll_set_range(&following, 10)
	testing.expect_value(t, scroll_offset(following), 10)
	scroll_set_range(&following, 15)
	testing.expect_value(t, scroll_offset(following), 15)

	pinned: Scroll
	scroll_set_range(&pinned, 10)
	scroll_to(&pinned, 4)
	scroll_set_range(&pinned, 15)
	testing.expect_value(t, scroll_offset(pinned), 4)
	scroll_set_range(&pinned, 3)
	testing.expect_value(t, scroll_offset(pinned), 3)
	testing.expect(t, pinned.top == nil)
}

@(test)
test_scroll_by_reports_boundaries :: proc(t: ^testing.T) {
	scroll := Scroll {
		range = 10,
	}
	testing.expect(t, !scroll_by(&scroll, 3))
	testing.expect(t, scroll_by(&scroll, -4))
	testing.expect_value(t, scroll_offset(scroll), 6)
	testing.expect(t, scroll_by(&scroll, -100))
	testing.expect_value(t, scroll_offset(scroll), 0)
	testing.expect(t, !scroll_by(&scroll, -1))
	testing.expect(t, scroll_by(&scroll, 100))
	testing.expect(t, scroll.top == nil)
}

@(test)
test_scroll_reveal_moves_the_least :: proc(t: ^testing.T) {
	testing.expect_value(t, scroll_reveal(5, 4, 6), 5)
	testing.expect_value(t, scroll_reveal(5, 4, 3), 3)
	testing.expect_value(t, scroll_reveal(5, 4, 10), 7)
	testing.expect_value(t, scroll_reveal(5, 4, 6, 3), 5)
	testing.expect_value(t, scroll_reveal(5, 4, 20, 9), 20)
}

@(test)
test_list_select_first_last_page :: proc(t: ^testing.T) {
	state := List_State {
		selected = -1,
	}
	list_select_page(&state, 10, 4)
	testing.expect_value(t, state.selected, 0)
	list_select_page(&state, 10, 4)
	testing.expect_value(t, state.selected, 4)
	list_select_page(&state, 10, 100)
	testing.expect_value(t, state.selected, 9)
	list_select_page(&state, 10, -4)
	testing.expect_value(t, state.selected, 5)
	list_select_first(&state, 10)
	testing.expect_value(t, state.selected, 0)
	list_select_last(&state, 10)
	testing.expect_value(t, state.selected, 9)
	state.selected = -1
	list_select_page(&state, 10, -4)
	testing.expect_value(t, state.selected, 9)
	list_select_last(&state, 0)
	testing.expect_value(t, state.selected, -1)
}

@(test)
test_draw_block_draws_footer_on_bottom_edge_and_truncates_it :: proc(t: ^testing.T) {
	cells: [48]term.Cell
	frame := _frame(cells[:], 12, 4)
	draw_block(&frame, {x = 0, y = 0, width = 12, height = 4}, Block{border = tui.BORDER_ROUNDED, title = "top", footer = "─ 3 more lines ─────"})
	testing.expect_value(t, frame.cells[1].grapheme, "t")
	testing.expect_value(t, frame.cells[3 * 12].grapheme, "╰")
	testing.expect_value(t, frame.cells[3 * 12 + 1].grapheme, "─")
	testing.expect_value(t, frame.cells[3 * 12 + 5].grapheme, "m")
	testing.expect_value(t, frame.cells[3 * 12 + 11].grapheme, "╯")
}

@(test)
test_block_declares_border_title_and_footer_cut_to_the_box :: proc(t: ^testing.T) {
	options := layout.Options {
		capacities = {
			nodes = 16,
			children = 16,
			clips = 8,
			commands = 16,
			text_lines = 8,
			measured_words = 16,
			overlays = 4,
			measure_cache = 8,
			id_table = 8,
			depth = 8,
			diagnostics = 16,
		},
	}
	layout_ctx: layout.Context
	testing.expect_value(t, layout.init(&layout_ctx, options), nil)
	defer layout.destroy(&layout_ctx)
	measure_context := tui.Measure_Context {
		profile = text.DEFAULT_WIDTH_PROFILE,
	}
	layout.set_services(&layout_ctx, tui.layout_services(&measure_context))

	paints: tui.Paints
	defer delete(paints)
	desc := Block_Desc {
		id     = layout.id("box"),
		sizing = {layout.fixed(12), layout.fixed(4)},
		border = tui.BORDER_ROUNDED,
		title  = "─ top ",
		footer = "─ 3 more lines ─────",
	}
	if layout.frame(&layout_ctx, {12, 4}) {
		if block(&layout_ctx, &paints, desc) {
		}
	}
	frame_result, frame_error := layout.result(&layout_ctx)
	testing.expect_value(t, frame_error, layout.Frame_Error.None)

	cells: [48]term.Cell
	frame := _frame(cells[:], 12, 4)
	testing.expect_value(t, tui.draw_commands(&frame, paints[:], frame_result, {width = 12, height = 4}), tui.Draw_Error.None)
	testing.expect_value(t, frame.cells[0].grapheme, "╭")
	testing.expect_value(t, frame.cells[1].grapheme, "─")
	testing.expect_value(t, frame.cells[3].grapheme, "t")
	testing.expect_value(t, frame.cells[11].grapheme, "╮")
	testing.expect_value(t, frame.cells[12].grapheme, "│")
	testing.expect_value(t, frame.cells[2 * 12 + 11].grapheme, "│")
	testing.expect_value(t, frame.cells[3 * 12].grapheme, "╰")
	testing.expect_value(t, frame.cells[3 * 12 + 5].grapheme, "m")
	testing.expect_value(t, frame.cells[3 * 12 + 10].grapheme, "l")
	testing.expect_value(t, frame.cells[3 * 12 + 11].grapheme, "╯")
}

@(test)
test_scrollbar_thumb_geometry :: proc(t: ^testing.T) {
	testing.expect_value(t, scrollbar_thumb(10, 5, 10, 0), Scrollbar_Thumb{})
	testing.expect_value(t, scrollbar_thumb(10, 10, 10, 0), Scrollbar_Thumb{})
	testing.expect_value(t, scrollbar_thumb(0, 100, 10, 0), Scrollbar_Thumb{})
	// A tiny viewport still gets a one cell thumb.
	testing.expect_value(t, scrollbar_thumb(10, 10000, 1, 0), Scrollbar_Thumb{start = 0, length = 1})
	testing.expect_value(t, scrollbar_thumb(10, 20, 10, 0), Scrollbar_Thumb{start = 0, length = 5})
	testing.expect_value(t, scrollbar_thumb(10, 20, 10, 10), Scrollbar_Thumb{start = 5, length = 5})
	// The end sits at the track's end for any proportions, and offset is clamped.
	testing.expect_value(t, scrollbar_thumb(7, 1001, 13, 988), Scrollbar_Thumb{start = 6, length = 1})
	testing.expect_value(t, scrollbar_thumb(10, 20, 10, 99), Scrollbar_Thumb{start = 5, length = 5})
	testing.expect_value(t, scrollbar_thumb(10, 20, 10, -3), Scrollbar_Thumb{start = 0, length = 5})
}

@(test)
test_scrollbar_draws_thumb_over_track :: proc(t: ^testing.T) {
	storage: [4]term.Cell
	frame := _frame(storage[:], 1, 4)
	draw_scrollbar(&frame, {x = 0, y = 0, width = 1, height = 4}, 8, 4, 4, Scrollbar{track_glyph = "│", thumb_glyph = "█"})
	testing.expect_value(t, frame.cells[0].grapheme, "│")
	testing.expect_value(t, frame.cells[1].grapheme, "│")
	testing.expect_value(t, frame.cells[2].grapheme, "█")
	testing.expect_value(t, frame.cells[3].grapheme, "█")
}

@(test)
test_spinner_frame_advances_and_wraps :: proc(t: ^testing.T) {
	frames := []string{"a", "b", "c"}
	interval := 100 * time.Millisecond
	testing.expect_value(t, spinner_frame(frames, 0, interval), "a")
	testing.expect_value(t, spinner_frame(frames, 250 * time.Millisecond, interval), "c")
	testing.expect_value(t, spinner_frame(frames, 300 * time.Millisecond, interval), "a")
	testing.expect_value(t, spinner_frame(frames, -time.Second, interval), "a")
	testing.expect_value(t, spinner_frame(nil, 0, interval), "")
	testing.expect_value(t, spinner_frame(frames, 0, 0), "")
}

@(test)
test_input_word_motion_and_deletion :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)

	testing.expect(t, input_insert(&input, "foo bar.baz") == nil)
	testing.expect(t, input_move_word_left(&input))
	testing.expect_value(t, input_cursor(&input), len("foo bar."))
	testing.expect(t, input_move_word_left(&input))
	testing.expect(t, input_move_word_left(&input))
	testing.expect_value(t, input_cursor(&input), len("foo "))
	testing.expect(t, input_move_word_right(&input))
	testing.expect_value(t, input_cursor(&input), len("foo bar"))

	testing.expect(t, input_delete_word_back(&input) or_else false)
	testing.expect_value(t, input_text(&input), "foo .baz")
	testing.expect_value(t, string(input.kill[:]), "bar")
	testing.expect(t, input_move_text_start(&input))
	testing.expect(t, !(input_delete_word_back(&input) or_else false))
	testing.expect(t, !input_move_word_left(&input))
}

@(test)
test_input_kill_and_yank :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)

	testing.expect(t, !(input_yank(&input) or_else false))
	testing.expect(t, input_insert(&input, "one two\nthree") == nil)
	testing.expect(t, input_kill_to_start(&input) or_else false)
	testing.expect_value(t, input_text(&input), "one two\n")
	testing.expect(t, !(input_kill_to_start(&input) or_else false))
	testing.expect(t, input_move_text_start(&input))
	testing.expect(t, input_move_word_right(&input))
	testing.expect(t, input_kill_to_end(&input) or_else false)
	testing.expect_value(t, input_text(&input), "one\n")
	testing.expect_value(t, string(input.kill[:]), " two")
	testing.expect(t, input_kill_to_end(&input) or_else false)
	testing.expect_value(t, input_text(&input), "one")
	testing.expect(t, !(input_kill_to_end(&input) or_else false))
	testing.expect(t, input_yank(&input) or_else false)
	testing.expect_value(t, input_text(&input), "one\n")
	testing.expect_value(t, input_cursor(&input), 4)
}

@(test)
test_input_undo_groups_runs_and_redo_clears_on_edit :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)

	testing.expect(t, !(input_undo(&input) or_else false))
	testing.expect(t, !(input_redo(&input) or_else false))
	for part in ([]string{"a", "b", " ", "c", "d"}) {
		testing.expect(t, input_insert(&input, part) == nil)
	}
	testing.expect(t, input_backspace(&input) or_else false)
	testing.expect(t, input_backspace(&input) or_else false)
	testing.expect(t, input_delete_word_back(&input) or_else false)
	testing.expect_value(t, input_text(&input), "")

	testing.expect(t, input_undo(&input) or_else false)
	testing.expect_value(t, input_text(&input), "ab ")
	testing.expect(t, input_undo(&input) or_else false)
	testing.expect_value(t, input_text(&input), "ab cd")
	testing.expect(t, input_undo(&input) or_else false)
	testing.expect_value(t, input_text(&input), "ab ")
	testing.expect_value(t, input_cursor(&input), 3)
	testing.expect(t, input_undo(&input) or_else false)
	testing.expect_value(t, input_text(&input), "")
	testing.expect(t, !(input_undo(&input) or_else false))

	testing.expect(t, input_redo(&input) or_else false)
	testing.expect_value(t, input_text(&input), "ab ")
	testing.expect(t, input_redo(&input) or_else false)
	testing.expect_value(t, input_text(&input), "ab cd")

	testing.expect(t, input_undo(&input) or_else false)
	testing.expect(t, input_insert(&input, "x") == nil)
	testing.expect(t, !(input_redo(&input) or_else false))
}

@(test)
test_input_undo_steps_split_at_motion_and_kills :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)

	testing.expect(t, input_insert(&input, "ab") == nil)
	testing.expect(t, input_move_left(&input))
	testing.expect(t, input_insert(&input, "x") == nil)
	testing.expect_value(t, input_text(&input), "axb")
	testing.expect(t, input_undo(&input) or_else false)
	testing.expect_value(t, input_text(&input), "ab")

	testing.expect(t, input_move_text_end(&input))
	testing.expect(t, input_kill_to_start(&input) or_else false)
	testing.expect(t, input_yank(&input) or_else false)
	testing.expect(t, input_yank(&input) or_else false)
	testing.expect_value(t, input_text(&input), "abab")
	testing.expect(t, input_undo(&input) or_else false)
	testing.expect_value(t, input_text(&input), "ab")
	testing.expect(t, input_undo(&input) or_else false)
	testing.expect_value(t, input_text(&input), "")
	testing.expect(t, input_undo(&input) or_else false)
	testing.expect_value(t, input_text(&input), "ab")
}

@(test)
test_input_key_dispatches_bindings :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)

	for character in "foo bar" {
		testing.expect(t, input_key(&input, {code = .Character, character = character}, 20, text.DEFAULT_WIDTH_PROFILE) or_else false)
	}
	testing.expect(t, input_key(&input, {code = .Character, character = 'w', modifiers = {.Control}}, 20, text.DEFAULT_WIDTH_PROFILE) or_else false)
	testing.expect_value(t, input_text(&input), "foo ")
	testing.expect(t, input_key(&input, {code = .Character, character = 'z', modifiers = {.Control}}, 20, text.DEFAULT_WIDTH_PROFILE) or_else false)
	testing.expect_value(t, input_text(&input), "foo bar")
	testing.expect(t, input_key(&input, {code = .Character, character = 'a', modifiers = {.Control}}, 20, text.DEFAULT_WIDTH_PROFILE) or_else false)
	testing.expect_value(t, input_cursor(&input), 0)
	testing.expect(t, input_key(&input, {code = .Enter, modifiers = {.Alt}}, 20, text.DEFAULT_WIDTH_PROFILE) or_else false)
	testing.expect_value(t, input_text(&input), "\nfoo bar")

	testing.expect(t, !(input_key(&input, {code = .Enter}, 20, text.DEFAULT_WIDTH_PROFILE) or_else false), "plain Enter belongs to the caller")
	testing.expect(t, !(input_key(&input, {code = .Character, character = 'x', modifiers = {.Control, .Alt}}, 20, text.DEFAULT_WIDTH_PROFILE) or_else false))
	testing.expect(t, !(input_key(&input, {code = .Character, character = 'x', kind = .Release}, 20, text.DEFAULT_WIDTH_PROFILE) or_else false))
	testing.expect(t, input_key(&input, {code = .Up}, 20, text.DEFAULT_WIDTH_PROFILE) or_else false)
	testing.expect(t, !(input_key(&input, {code = .Up}, 20, text.DEFAULT_WIDTH_PROFILE) or_else false), "no row above the first")
	testing.expect(t, input_key(&input, {code = .Down}, 20, text.DEFAULT_WIDTH_PROFILE) or_else false)
	testing.expect(t, !(input_key(&input, {code = .Down}, 20, text.DEFAULT_WIDTH_PROFILE) or_else false), "no row below the last")
}

@(test)
test_input_home_end_move_by_row :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)

	// Rows at width 3: "abc", "def", "g", then "xy" after the line break.
	testing.expect(t, input_insert(&input, "abcdefg\nxy") == nil)
	profile := text.DEFAULT_WIDTH_PROFILE
	testing.expect(t, input_move_home(&input, 3))
	testing.expect_value(t, input_cursor(&input), len("abcdefg\n"))
	testing.expect(t, !input_move_home(&input, 3))
	testing.expect(t, input_move_end(&input, 3))
	testing.expect_value(t, input_cursor(&input), len("abcdefg\nxy"))

	// A wrapped row ends on its last character, so the caret stays on that row.
	testing.expect(t, input_move_up(&input, 3))
	testing.expect(t, input_move_up(&input, 3))
	testing.expect(t, input_key(&input, {code = .Home}, 3, profile) or_else false)
	testing.expect_value(t, input_cursor(&input), len("abc"))
	testing.expect(t, input_key(&input, {code = .End}, 3, profile) or_else false)
	testing.expect_value(t, input_cursor(&input), len("abcde"))
	testing.expect(t, input_key(&input, {code = .Home, modifiers = {.Control}}, 3, profile) or_else false)
	testing.expect_value(t, input_cursor(&input), 0)
	testing.expect(t, input_key(&input, {code = .End, modifiers = {.Control}}, 3, profile) or_else false)
	testing.expect_value(t, input_cursor(&input), len("abcdefg\nxy"))
}

@(test)
test_history_keeps_the_draft :: proc(t: ^testing.T) {
	history: History
	history_init(&history)
	defer history_destroy(&history)

	_, ok := history_previous(&history, "draft")
	testing.expect(t, !ok, "an empty history has nothing to recall")
	testing.expect(t, history_push(&history, "one"))
	testing.expect(t, history_push(&history, "two"))

	entry: string
	entry, ok = history_previous(&history, "draft")
	testing.expect(t, ok)
	testing.expect_value(t, entry, "two")
	entry, _ = history_previous(&history, "ignored")
	testing.expect_value(t, entry, "one")
	_, ok = history_previous(&history, "ignored")
	testing.expect(t, !ok, "nothing older than the first entry")

	entry, _ = history_next(&history)
	testing.expect_value(t, entry, "two")
	entry, ok = history_next(&history)
	testing.expect(t, ok)
	testing.expect_value(t, entry, "draft")
	_, ok = history_next(&history)
	testing.expect(t, !ok, "not browsing past the draft")

	_, _ = history_previous(&history, "again")
	history_reset(&history)
	entry, _ = history_previous(&history, "fresh")
	testing.expect_value(t, entry, "two")
	entry, _ = history_next(&history)
	testing.expect_value(t, entry, "fresh")
}

@(test)
test_input_draw_allocation_failure_leaves_the_frame_unchanged :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)
	storage: [1]term.Cell
	frame := _frame(storage[:], 1, 1)
	if !testing.expect(t, tui.put(&frame, 0, 0, "x", {})) { return }

	backing: [1]byte
	arena: mem.Arena
	mem.arena_init(&arena, backing[:])
	context.temp_allocator = mem.arena_allocator(&arena)
	_, err := draw_input_rect(&frame, {width = 1, height = 1}, &input, {})
	testing.expect_value(t, err, mem.Allocator_Error.Out_Of_Memory)
	testing.expect_value(t, storage[0].grapheme, "x")
}

// A paste of more than PASTE_COLLAPSE_LINES lines becomes a marker; pasting the same text
// right after it expands it in place, and a different text adds a second marker.
@(test)
test_input_paste_collapses_large_text_and_expands_on_repeat :: proc(t: ^testing.T) {
	input: Input
	input_init(&input)
	defer input_destroy(&input)

	five := "1\n2\n3\n4\n5"
	six := "1\n2\n3\n4\n5\n6"
	testing.expect(t, input_paste(&input, five) == nil)
	testing.expect_value(t, input_text(&input), five)
	input_clear(&input)

	testing.expect(t, input_paste(&input, six) == nil)
	testing.expect_value(t, input_text(&input), "[Pasted text #1 +6 lines]")
	testing.expect(t, input_insert(&input, " tail") == nil)
	expanded, err := input_expanded(&input)
	defer delete(expanded)
	testing.expect(t, err == nil)
	testing.expect_value(t, expanded, "1\n2\n3\n4\n5\n6 tail")

	// A different text does not expand the marker before the caret.
	input_clear(&input)
	testing.expect(t, input_paste(&input, six) == nil)
	testing.expect(t, input_paste(&input, "a\nb\nc\nd\ne\nf\ng") == nil)
	testing.expect_value(t, input_text(&input), "[Pasted text #1 +6 lines][Pasted text #2 +7 lines]")

	// The same text after its marker expands it, as one undo step.
	input_clear(&input)
	testing.expect(t, input_paste(&input, six) == nil)
	testing.expect(t, input_paste(&input, six) == nil)
	testing.expect_value(t, input_text(&input), six)
	testing.expect_value(t, input_cursor(&input), len(six))
	testing.expect(t, input_undo(&input) or_else false)
	testing.expect_value(t, input_text(&input), "[Pasted text #1 +6 lines]")

	// A marker edited by hand is literal text, and a whole marker is deleted at once.
	input_clear(&input)
	testing.expect(t, input_paste(&input, six) == nil)
	testing.expect(t, input_move_left(&input))
	testing.expect(t, input_delete(&input) or_else false)
	edited, edited_err := input_expanded(&input)
	defer delete(edited)
	testing.expect(t, edited_err == nil)
	testing.expect_value(t, edited, "[Pasted text #1 +6 lines")
	input_clear(&input)
	testing.expect(t, input_paste(&input, six) == nil)
	testing.expect(t, input_backspace(&input) or_else false)
	testing.expect_value(t, input_text(&input), "")
}
