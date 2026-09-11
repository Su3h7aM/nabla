#+build linux
#+test
#+private file
package tui

import "core:testing"

@(test)
test_fill_clips_to_the_grid :: proc(t: ^testing.T) {
	storage: [20]Cell
	buffer: Cell_Buffer
	_ = init(&buffer, 5, 4, storage[:])
	written := fill(&buffer, {x = 1, y = 1, width = 2, height = 2}, {grapheme = "#"})
	testing.expect_value(t, written, 4)
	testing.expect_value(t, buffer.cells[6].grapheme, "#")
	testing.expect_value(t, buffer.cells[7].grapheme, "#")
	testing.expect_value(t, buffer.cells[11].grapheme, "#")
	testing.expect_value(t, buffer.cells[12].grapheme, "#")
	testing.expect_value(t, buffer.cells[0].grapheme, " ")
	testing.expect_value(t, buffer.cells[8].grapheme, " ")

	// A rect reaching past the grid is clipped; one entirely outside writes
	// nothing.
	clip_storage: [12]Cell
	clip_buffer: Cell_Buffer
	_ = init(&clip_buffer, 4, 3, clip_storage[:])
	testing.expect_value(t, fill(&clip_buffer, {x = 2, y = 2, width = 10, height = 10}, {grapheme = "#"}), 2)
	testing.expect_value(t, fill(&clip_buffer, {x = 40, y = 0, width = 2, height = 2}, {grapheme = "#"}), 0)
}

@(test)
test_draw_ascii_writes_and_clips :: proc(t: ^testing.T) {
	storage: [20]Cell
	buffer: Cell_Buffer
	_ = init(&buffer, 5, 4, storage[:])
	style := Style {
		foreground = Indexed_Color(2),
		modifiers  = {.Bold},
	}
	written, ok := draw_ascii(&buffer, {x = 1, y = 2, width = 4, height = 1}, "hi", style)
	testing.expect(t, ok)
	testing.expect_value(t, written, 2)
	testing.expect_value(t, buffer.cells[11], Cell{grapheme = "h", style = style})
	testing.expect_value(t, buffer.cells[12], Cell{grapheme = "i", style = style})
	testing.expect_value(t, buffer.cells[13].grapheme, " ")

	// Drawing truncates to the rect.
	truncate_storage: [10]Cell
	truncate_buffer: Cell_Buffer
	_ = init(&truncate_buffer, 5, 2, truncate_storage[:])
	truncated, truncate_ok := draw_ascii(&truncate_buffer, {x = 0, y = 0, width = 3, height = 1}, "abcdef", {})
	testing.expect(t, truncate_ok)
	testing.expect_value(t, truncated, 3)
	testing.expect_value(t, truncate_buffer.cells[3].grapheme, " ")

	// Columns removed by a left-edge clip consume the matching characters, so
	// the visible remainder stays aligned with the rect.
	clip_storage: [10]Cell
	clip_buffer: Cell_Buffer
	_ = init(&clip_buffer, 5, 2, clip_storage[:])
	clipped, clip_ok := draw_ascii(&clip_buffer, {x = -2, y = 0, width = 5, height = 1}, "abcde", {})
	testing.expect(t, clip_ok)
	testing.expect_value(t, clipped, 3)
	testing.expect_value(t, clip_buffer.cells[0].grapheme, "c")
	testing.expect_value(t, clip_buffer.cells[1].grapheme, "d")
	testing.expect_value(t, clip_buffer.cells[2].grapheme, "e")

	// A rect outside the buffer writes nothing.
	outside_storage: [10]Cell
	outside_buffer: Cell_Buffer
	_ = init(&outside_buffer, 5, 2, outside_storage[:])
	outside, outside_ok := draw_ascii(&outside_buffer, {x = 0, y = 9, width = 5, height = 1}, "abc", {})
	testing.expect(t, outside_ok)
	testing.expect_value(t, outside, 0)
}

@(test)
test_draw_ascii_rejects_unrepresentable_text :: proc(t: ^testing.T) {
	// Drawing is stricter than measurement on purpose: a substituted glyph
	// would no longer match the width the solver was handed.
	storage: [10]Cell
	buffer: Cell_Buffer
	_ = init(&buffer, 5, 2, storage[:])
	for value in ([?]string{"ca\u00e9", "a\nb", "a\tb"}) {
		written, ok := draw_ascii(&buffer, {x = 0, y = 0, width = 5, height = 1}, value, {})
		testing.expect(t, !ok)
		testing.expect_value(t, written, 0)
	}
	for cell in buffer.cells {
		testing.expect_value(t, cell.grapheme, " ")
	}
}
