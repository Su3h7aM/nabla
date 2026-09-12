#+build linux
#+test
#+private file
package tui

import "core:testing"
import "nabla:term"
import "nabla:text"

@(test)
test_init_fills_blanks :: proc(t: ^testing.T) {
	storage: [12]term.Cell
	frame: term.Frame_Buffer
	base := term.Style {
		foreground = term.Indexed_Color(3),
	}
	testing.expect(t, init(&frame, 4, 3, storage[:], base))
	testing.expect_value(t, frame.columns, 4)
	testing.expect_value(t, frame.rows, 3)
	testing.expect_value(t, len(frame.cells), 12)
	for cell in frame.cells {
		testing.expect_value(t, cell, term.Cell{grapheme = " ", style = base, width = 1})
	}

	// Undersized storage and negative extents are refused.
	small: [4]term.Cell
	testing.expect(t, !init(&frame, 3, 3, small[:]))
	testing.expect(t, !init(&frame, -1, 2, small[:]))
}

@(test)
test_put_and_fill :: proc(t: ^testing.T) {
	storage: [12]term.Cell
	frame: term.Frame_Buffer
	_ = init(&frame, 4, 3, storage[:])
	style := term.Style {
		foreground = term.Indexed_Color(2),
	}

	testing.expect(t, put(&frame, 1, 1, "x", style))
	testing.expect_value(t, frame.cells[5], term.Cell{grapheme = "x", style = style, width = 1})
	testing.expect(t, !put(&frame, 4, 0, "x", style), "out of bounds")
	testing.expect(t, !put(&frame, 0, 0, "", style), "empty glyph")
	testing.expect(t, !put(&frame, 0, 0, "a\x1b", style), "a control is refused")
	testing.expect(t, !put(&frame, 0, 0, "a\tb", style), "a tab is not one cluster")

	// A wide cluster writes its placeholder, and the pair cannot be placed in
	// the last column.
	testing.expect(t, put(&frame, 2, 0, "界", style))
	testing.expect_value(t, frame.cells[2], term.Cell{grapheme = "界", style = style, width = 2})
	testing.expect_value(t, frame.cells[3], term.Cell{grapheme = "", style = style, width = 0})
	testing.expect(t, !put(&frame, 3, 2, "界", style), "no room for the placeholder")

	testing.expect_value(t, fill(&frame, {x = 0, y = 0, width = 2, height = 2}, "#", style), 4)
	testing.expect_value(t, frame.cells[0].grapheme, "#")
	testing.expect_value(t, frame.cells[5].grapheme, "#")
	// A rect reaching past the grid is clipped.
	testing.expect_value(t, fill(&frame, {x = 3, y = 2, width = 10, height = 10}, "#", style), 1)
	// A wide glyph cannot be filled.
	testing.expect_value(t, fill(&frame, {x = 0, y = 0, width = 2, height = 2}, "界", style), 0)
}

@(test)
test_draw_text_utf8_widths :: proc(t: ^testing.T) {
	storage: [12]term.Cell
	frame: term.Frame_Buffer
	_ = init(&frame, 6, 2, storage[:])
	style := term.Style {
		foreground = term.Indexed_Color(4),
	}

	// An accented cluster is one cell holding both code points.
	written, ok := draw_text(&frame, {x = 0, y = 0, width = 6, height = 1}, "café", style)
	testing.expect(t, ok)
	testing.expect_value(t, written, 4)
	testing.expect_value(t, frame.cells[3], term.Cell{grapheme = "é", style = style, width = 1})

	// A wide character takes two cells: the cluster plus a zero-width
	// placeholder the encoder needs.
	written, ok = draw_text(&frame, {x = 0, y = 1, width = 6, height = 1}, "界a", style)
	testing.expect(t, ok)
	testing.expect_value(t, written, 3)
	testing.expect_value(t, frame.cells[6].grapheme, "界")
	testing.expect_value(t, frame.cells[6].width, u8(2))
	testing.expect_value(t, frame.cells[7].grapheme, "")
	testing.expect_value(t, frame.cells[7].width, u8(0))
	testing.expect_value(t, frame.cells[8].grapheme, "a")

	// A control follows the replace policy: it is dropped, so the call
	// succeeds with the drawable content. Under .Reject the whole call is
	// refused before anything is written.
	dropped_written, dropped_ok := draw_text(&frame, {x = 0, y = 0, width = 6, height = 1}, "a\x1b", style)
	testing.expect(t, dropped_ok)
	testing.expect_value(t, dropped_written, 1)
	testing.expect_value(t, frame.cells[0].grapheme, "a")
	reject := text.Width_Profile {
		tab_width    = 4,
		invalid_text = .Reject,
	}
	bad_written, bad_ok := draw_text(&frame, {x = 0, y = 0, width = 6, height = 1}, "a\x1b", style, reject)
	testing.expect(t, !bad_ok, "a rejected control refuses the call")
	testing.expect_value(t, bad_written, 0)
	tab_written, tab_ok := draw_text(&frame, {x = 0, y = 0, width = 6, height = 1}, "a\tb", style)
	testing.expect(t, tab_ok)
	testing.expect_value(t, tab_written, 5) // a, three spaces to column 4, b
	testing.expect_value(t, frame.cells[1].grapheme, " ")
	testing.expect_value(t, frame.cells[4].grapheme, "b")
	zero_written, zero_ok := draw_text(&frame, {x = 0, y = 0, width = 6, height = 1}, "\u200d", style)
	testing.expect(t, zero_ok)
	testing.expect_value(t, zero_written, 0)
}

@(test)
test_draw_text_truncates_at_the_rect_edge :: proc(t: ^testing.T) {
	storage: [16]term.Cell
	frame: term.Frame_Buffer
	_ = init(&frame, 4, 4, storage[:])

	// A wide cluster cannot be split into a one-cell rect; it is truncated.
	written, ok := draw_text(&frame, {x = 0, y = 0, width = 1, height = 1}, "界", {})
	testing.expect(t, ok)
	testing.expect_value(t, written, 0)
	testing.expect_value(t, frame.cells[0].grapheme, " ")

	// The last row is drawn like any other: a wide cluster may span the final
	// two columns, because the session disables autowrap.
	written, ok = draw_text(&frame, {x = 0, y = 3, width = 4, height = 1}, "ab界", {})
	testing.expect(t, ok)
	testing.expect_value(t, written, 4)
	testing.expect_value(t, frame.cells[14].grapheme, "界")
	testing.expect_value(t, frame.cells[15].grapheme, "")
}

@(test)
test_overwriting_half_a_wide_cluster_repairs_the_pair :: proc(t: ^testing.T) {
	storage: [16]term.Cell
	frame: term.Frame_Buffer
	_ = init(&frame, 4, 4, storage[:])
	style := term.Style {
		foreground = term.Indexed_Color(1),
	}

	// Overwrite the left half: the orphaned placeholder becomes a blank, not a
	// width-0 cell the encoder would reject.
	_, _ = draw_text(&frame, {x = 0, y = 0, width = 4, height = 1}, "ab界", style)
	testing.expect_value(t, frame.cells[2].width, u8(2))
	testing.expect(t, put(&frame, 2, 0, "x", style))
	testing.expect_value(t, frame.cells[2], term.Cell{grapheme = "x", style = style, width = 1})
	testing.expect_value(t, frame.cells[3], term.Cell{grapheme = " ", style = style, width = 1})

	// Overwrite the placeholder: the orphaned wide half becomes a blank.
	_, _ = draw_text(&frame, {x = 0, y = 1, width = 4, height = 1}, "界", style)
	testing.expect_value(t, frame.cells[5].width, u8(0))
	testing.expect(t, put(&frame, 1, 1, "y", style))
	testing.expect_value(t, frame.cells[4], term.Cell{grapheme = " ", style = style, width = 1})
	testing.expect_value(t, frame.cells[5], term.Cell{grapheme = "y", style = style, width = 1})

	// A fill over a wide cluster blanks both halves.
	_, _ = draw_text(&frame, {x = 0, y = 2, width = 4, height = 1}, "界a", style)
	testing.expect_value(t, fill(&frame, {x = 0, y = 2, width = 2, height = 1}, "#", style), 2)
	testing.expect_value(t, frame.cells[8], term.Cell{grapheme = "#", style = style, width = 1})
	testing.expect_value(t, frame.cells[9], term.Cell{grapheme = "#", style = style, width = 1})

	// Writing a wide cluster over two width-1 cells is fine, and the grid
	// invariant holds everywhere.
	_, _ = draw_text(&frame, {x = 0, y = 3, width = 4, height = 1}, "abcd", style)
	testing.expect(t, put(&frame, 2, 3, "界", style))
	testing.expect_value(t, frame.cells[14].width, u8(2))
	testing.expect_value(t, frame.cells[15].width, u8(0))

	for index in 0 ..< len(frame.cells) {
		cell := frame.cells[index]
		switch cell.width {
		case 0:
			testing.expect(t, index % 4 != 0 && frame.cells[index - 1].width == 2, "orphan placeholder")
			testing.expect_value(t, len(cell.grapheme), 0)
		case 1:
			testing.expect(t, len(cell.grapheme) > 0)
		case 2:
			testing.expect(t, index % 4 < 3 && frame.cells[index + 1].width == 0, "unpaired wide cell")
		case:
			testing.expect(t, false, "unrepresentable width")
		}
	}
}

@(test)
test_a_hand_built_grid_is_rejected_before_indexing :: proc(t: ^testing.T) {
	// A Frame_Buffer whose slice cannot hold its grid is refused rather than
	// indexed out of bounds.
	storage: [4]term.Cell
	frame := term.Frame_Buffer {
		columns = 4,
		rows    = 4,
		cells   = storage[:],
	}
	testing.expect(t, !put(&frame, 0, 0, "x", {}))
	testing.expect_value(t, fill(&frame, {width = 4, height = 4}, "#", {}), 0)
	testing.expect_value(t, len(frame.cells), 4)
}
