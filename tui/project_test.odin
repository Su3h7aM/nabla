#+build linux
#+test
#+private file
package tui

import "core:testing"
import "nabla:layout"

@(test)
test_project_rect_integral :: proc(t: ^testing.T) {
	rect, err := project_rect_integral(layout.Rect{position = {2, 1}, size = {5, 1}})
	testing.expect_value(t, err, Projection_Error.None)
	testing.expect_value(t, rect, Cell_Rect{x = 2, y = 1, width = 5, height = 1})

	// Fractional geometry is rejected rather than rounded: the rounding policy
	// is undecided, and silently picking one would bake it in.
	for fractional in ([?]layout.Rect{{position = {0.5, 0}, size = {4, 1}}, {position = {0, 0}, size = {4.25, 1}}}) {
		_, fractional_err := project_rect_integral(fractional)
		testing.expect_value(t, fractional_err, Projection_Error.Non_Integral)
	}

	_, negative_err := project_rect_integral(layout.Rect{position = {0, 0}, size = {-1, 2}})
	testing.expect_value(t, negative_err, Projection_Error.Negative_Size)
}
