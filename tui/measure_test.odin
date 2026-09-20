#+build linux
#+test
#+private file
package tui

import "core:testing"
import "nabla:layout"
import "nabla:text"

@(test)
test_measure_proc_counts_cells :: proc(t: ^testing.T) {
	measure_context := Measure_Context {
		profile = text.DEFAULT_WIDTH_PROFILE,
	}
	unbounded := layout.Measure_Request {
		axes = {.X = {mode = .Unbounded}, .Y = {mode = .Unbounded}},
	}

	services := layout_services(&measure_context)
	// An accented cluster is one cell and a wide character is two.
	result, err := services.measure_text(services.measure_text_user_data, "café", {}, unbounded)
	testing.expect_value(t, err, layout.Measure_Error.None)
	testing.expect_value(t, result.size, layout.Vec2{4, 1})

	result, err = measure_proc(&measure_context, "e\u0301界", {}, unbounded)
	testing.expect_value(t, err, layout.Measure_Error.None)
	testing.expect_value(t, result.size, layout.Vec2{3, 1})

	// A nil context makes the measurer unavailable.
	_, nil_err := measure_proc(nil, "hello", {}, unbounded)
	testing.expect_value(t, nil_err, layout.Measure_Error.Invalid_Text)
}

@(test)
test_break_proc_maps_break_kinds :: proc(t: ^testing.T) {
	piece_end, next_offset, kind, err := break_proc(nil, "aaa bbb", 0)
	testing.expect_value(t, err, layout.Text_Break_Error.None)
	testing.expect_value(t, piece_end, 3)
	testing.expect_value(t, next_offset, 4)
	testing.expect_value(t, kind, layout.Text_Break_Kind.Optional)
}
