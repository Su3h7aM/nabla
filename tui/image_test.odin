#+build linux
#+test
#+private file
package tui

import "core:testing"
import "nabla:term"

@(test)
test_draw_image_fills_placeholders :: proc(t: ^testing.T) {
	storage: [6 * 4]term.Cell
	frame: term.Frame_Buffer
	_ = init(&frame, 6, 4, storage[:])

	testing.expect_value(t, draw_image(&frame, {x = 1, y = 1, width = 3, height = 2}, 0x010203), 6)
	style := term.Style {
		foreground = term.RGB_Color{1, 2, 3},
	}
	for row in 1 ..< 3 {
		testing.expect_value(t, frame.cells[row * 6 + 1], term.Cell{grapheme = term.graphics_placeholder_rows[row - 1], style = style, width = 1})
		testing.expect_value(t, frame.cells[row * 6 + 2], term.Cell{grapheme = term.GRAPHICS_PLACEHOLDER, style = style, width = 1})
		testing.expect_value(t, frame.cells[row * 6 + 3], term.Cell{grapheme = term.GRAPHICS_PLACEHOLDER, style = style, width = 1})
	}
	testing.expect_value(t, frame.cells[0].grapheme, " ")
	testing.expect_value(t, frame.cells[1 * 6 + 4].grapheme, " ")
	testing.expect_value(t, frame.cells[3 * 6 + 1].grapheme, " ")
}

@(test)
test_draw_image_clips :: proc(t: ^testing.T) {
	storage: [6 * 4]term.Cell
	frame: term.Frame_Buffer
	_ = init(&frame, 6, 4, storage[:])

	// Past the right and bottom edges only the visible part is drawn.
	testing.expect_value(t, draw_image(&frame, {x = 4, y = 3, width = 5, height = 5}, 1), 2)
	// Above the top the rows keep their image index.
	_ = init(&frame, 6, 4, storage[:])
	testing.expect_value(t, draw_image(&frame, {x = 0, y = -1, width = 2, height = 3}, 1), 4)
	testing.expect_value(t, frame.cells[0].grapheme, term.graphics_placeholder_rows[1])
	// A clipped left edge would show the wrong columns, so it draws nothing.
	_ = init(&frame, 6, 4, storage[:])
	testing.expect_value(t, draw_image(&frame, {x = -1, y = 0, width = 3, height = 2}, 1), 0)
	// Zero and out-of-range ids are no image.
	testing.expect_value(t, draw_image(&frame, {x = 0, y = 0, width = 2, height = 2}, 0), 0)
	testing.expect_value(t, draw_image(&frame, {x = 0, y = 0, width = 2, height = 2}, term.IMAGE_ID_LIMIT), 0)
	for cell in frame.cells {
		testing.expect_value(t, cell.grapheme, " ")
	}
}
