#+test
#+private file
package layout

import "core:testing"

@(test)
test_style_constructors_and_colors :: proc(t: ^testing.T) {
	testing.expect_value(t, fit(), Axis_Size{mode = .Fit})
	testing.expect_value(t, fit(2, 8), Axis_Size{mode = .Fit, min = 2, max = 8})
	testing.expect_value(t, grow(), Axis_Size{mode = .Grow, weight = 1})
	testing.expect_value(t, grow(3, 2, 8), Axis_Size{mode = .Grow, min = 2, max = 8, weight = 3})
	testing.expect_value(t, fixed(12), Axis_Size{mode = .Fixed, value = 12})
	testing.expect_value(t, percent(0.25, 5, 50), Axis_Size{mode = .Percent, value = 0.25, min = 5, max = 50})
	testing.expect_value(t, pad_all(4), Edges{4, 4, 4, 4})
	testing.expect_value(t, pad_xy(3, 7), Edges{3, 7, 3, 7})
	testing.expect_value(t, radius_all(6), Radius{6, 6, 6, 6})

	testing.expect_value(t, rgb(10, 20, 30), Color{10, 20, 30, 255})
	testing.expect_value(t, rgba(10, 20, 30, 40), Color{10, 20, 30, 40})
	testing.expect_value(t, gray(128), Color{128, 128, 128, 255})
	testing.expect_value(t, opaque(rgba(10, 20, 30, 40)), Color{10, 20, 30, 255})
	testing.expect_value(t, with_alpha(rgb(10, 20, 30), 40), Color{10, 20, 30, 40})
	testing.expect_value(t, mix(rgb(0, 0, 0), rgb(100, 200, 40), 0.5), Color{50, 100, 20, 255})
}
