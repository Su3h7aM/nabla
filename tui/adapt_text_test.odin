#+build linux
#+test
#+private file
package tui

import "core:testing"
import "nabla:layout"
import "nabla:text"

@(test)
test_ascii_measure_proc_reports_cells :: proc(t: ^testing.T) {
	measure_context := ASCII_Measure_Context {
		profile = text.DEFAULT_WIDTH_PROFILE,
	}
	unbounded := layout.Measure_Request {
		axes = {.X = {mode = .Unbounded}, .Y = {mode = .Unbounded}},
	}
	result, err := ascii_measure_proc(&measure_context, "hello", {}, unbounded)
	testing.expect_value(t, err, layout.Measure_Error.None)
	testing.expect_value(t, result.size, layout.Vec2{5, 1})

	// An At_Most request clamps the report to the available width.
	clamped_request := layout.Measure_Request {
		axes = {.X = {mode = .At_Most, value = 4}, .Y = {mode = .Unbounded}},
	}
	result, err = ascii_measure_proc(&measure_context, "hello world", {}, clamped_request)
	testing.expect_value(t, err, layout.Measure_Error.None)
	testing.expect_value(t, result.size, layout.Vec2{4, 1})
}

@(test)
test_ascii_measure_proc_rejects_unavailable_or_invalid_input :: proc(t: ^testing.T) {
	unbounded := layout.Measure_Request {
		axes = {.X = {mode = .Unbounded}, .Y = {mode = .Unbounded}},
	}

	// A nil context makes the measurer unavailable.
	result, err := ascii_measure_proc(nil, "hello", {}, unbounded)
	testing.expect_value(t, err, layout.Measure_Error.Invalid_Text)
	testing.expect_value(t, result, layout.Measure_Result{})

	// A .Reject profile refuses text it cannot represent.
	profile := text.DEFAULT_WIDTH_PROFILE
	profile.invalid_text = .Reject
	measure_context := ASCII_Measure_Context {
		profile = profile,
	}
	_, reject_err := ascii_measure_proc(&measure_context, "café", {}, unbounded)
	testing.expect_value(t, reject_err, layout.Measure_Error.Invalid_Text)
}
