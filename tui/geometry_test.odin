#+build linux
#+test
#+private file
package tui

import "core:testing"

@(test)
test_rows_split_fixed_and_grow :: proc(t: ^testing.T) {
	area := Cell_Rect {
		x      = 2,
		y      = 3,
		width  = 10,
		height = 10,
	}
	out: [4]Cell_Rect
	// grow, fixed, fixed, grow: the fixed rows consume 2, the two grows
	// share the remaining 8.
	testing.expect(t, rows(area, []int{-1, 1, 1, -1}, out[:]))
	testing.expect_value(t, out[0], Cell_Rect{x = 2, y = 3, width = 10, height = 4})
	testing.expect_value(t, out[1], Cell_Rect{x = 2, y = 7, width = 10, height = 1})
	testing.expect_value(t, out[2], Cell_Rect{x = 2, y = 8, width = 10, height = 1})
	testing.expect_value(t, out[3], Cell_Rect{x = 2, y = 9, width = 10, height = 4})
}

@(test)
test_rows_gives_the_remainder_to_the_last_grow :: proc(t: ^testing.T) {
	area := Cell_Rect {
		width  = 4,
		height = 9,
	}
	out: [4]Cell_Rect
	testing.expect(t, rows(area, []int{-1, 1, 1, -1}, out[:]))
	testing.expect_value(t, out[0].height, 3)
	testing.expect_value(t, out[3].y, 5)
	testing.expect_value(t, out[3].height, 4)
}

@(test)
test_cols_split_fixed_and_grow :: proc(t: ^testing.T) {
	area := Cell_Rect {
		x      = 0,
		y      = 0,
		width  = 20,
		height = 5,
	}
	out: [3]Cell_Rect
	testing.expect(t, cols(area, []int{4, -1, 6}, out[:]))
	testing.expect_value(t, out[0], Cell_Rect{x = 0, y = 0, width = 4, height = 5})
	testing.expect_value(t, out[1], Cell_Rect{x = 4, y = 0, width = 10, height = 5})
	testing.expect_value(t, out[2], Cell_Rect{x = 14, y = 0, width = 6, height = 5})
}

@(test)
test_split_is_all_or_nothing :: proc(t: ^testing.T) {
	area := Cell_Rect {
		width  = 5,
		height = 5,
	}
	out: [2]Cell_Rect

	// Fixed sizes exceed the axis.
	testing.expect(t, !rows(area, []int{4, 4}, out[:]))
	// The output slice is too short for the sizes.
	testing.expect(t, !rows(area, []int{1, 1, 1}, out[:]))
	// A negative extent on either axis is not splittable: the split axis may be
	// fine while the cross axis cannot describe a region.
	testing.expect(t, !cols(Cell_Rect{width = -1, height = 5}, []int{1}, out[:]))
	testing.expect(t, !rows(Cell_Rect{width = 5, height = -1}, []int{1}, out[:]))
	testing.expect(t, !cols(Cell_Rect{width = 5, height = -1}, []int{1}, out[:]))
	// Fixed sizes are compared before they are summed, so a size that would
	// overflow the accumulator is refused rather than wrapped into a fit.
	testing.expect(t, !rows(area, []int{2, max(int)}, out[:]))
	// A failed call writes nothing.
	testing.expect_value(t, out[0], Cell_Rect{})
	testing.expect_value(t, out[1], Cell_Rect{})

	// Leftover space with no grow child stays unused at the end.
	two: [2]Cell_Rect
	testing.expect(t, rows(area, []int{2, 2}, two[:]))
	testing.expect_value(t, two[1].y, 2)
	testing.expect_value(t, two[1].height, 2)
}
