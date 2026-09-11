#+test
#+private file
package layout

import "core:testing"

_break_ascii :: proc(user_data: rawptr, value: string, offset: int) -> (piece_end: int, next_offset: int, kind: Text_Break_Kind, err: Text_Break_Error) {
	_, _ = user_data, offset
	index := offset
	for index < len(value) {
		switch value[index] {
		case ' ', '\t', '\r', '\n':
			if value[index] == '\n' {
				return index, index + 1, .Mandatory, .None
			}
			return index, index + 1, .Optional, .None
		}
		index += 1
	}
	return len(value), len(value), .None, .None
}

_Measure_Requests :: struct {
	saw_exact_width:  bool,
	saw_exact_height: bool,
}

_measure_answering_constraints :: proc(user: rawptr, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	tracker := (^_Measure_Requests)(user)
	if request.axes[.X].mode == .Exact {
		tracker.saw_exact_width = true
		return Measure_Result{size = {request.axes[.X].value, 20}, min_size = {5, 5}}, .None
	}
	if request.axes[.Y].mode == .Exact {
		tracker.saw_exact_height = true
		height := request.axes[.Y].value
		return Measure_Result{size = {height * 2, height}, min_size = {1, 1}}, .None
	}
	return Measure_Result{size = {30, 10}, min_size = {5, 5}}, .None
}

_measure_invalid_components :: proc(user: rawptr, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	_, _ = user, request
	return Measure_Result{size = {30, -1}, min_size = {5, 5}, baseline = -1}, .None
}

@(test)
test_custom_measure_receives_constraints :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)
	tracker: _Measure_Requests

	// A width-fixed leaf is measured again at its resolved width, a height-fixed
	// leaf at its resolved height; both see the intrinsic request first.
	if frame(&ctx, {400, 200}) {
		content(
			&ctx,
			{layout = {sizing = {width = fixed(100), height = fit()}}, content = Custom_Content{data = &tracker, measure = _measure_answering_constraints}},
		)
		content(
			&ctx,
			{layout = {sizing = {width = fit(), height = fixed(50)}}, content = Custom_Content{data = &tracker, measure = _measure_answering_constraints}},
		)
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect(t, tracker.saw_exact_width && tracker.saw_exact_height)
	testing.expect_value(t, frame_result.nodes[1].outer.size, Vec2{100, 20})
	testing.expect_value(t, frame_result.nodes[2].outer.size, Vec2{100, 50})

	// An invalid component is clamped without moving the valid ones.
	if frame(&ctx, {100, 100}) {
		content(&ctx, {content = Custom_Content{measure = _measure_invalid_components}})
	}
	frame_result, frame_error = result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect_value(t, frame_result.nodes[1].outer.size, Vec2{30, 0})
	found := false
	for diagnostic in diagnostics(&ctx) {
		if diagnostic.kind == .Measure_Failed {
			found = true
		}
	}
	testing.expect(t, found)
}

_measure_failing_custom :: proc(user: rawptr, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	_, _ = user, request
	return {}, .Invalid_Constraint
}

_measure_failing_text :: proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	_, _, _, _ = user_data, text, style, request
	return {}, .Invalid_Constraint
}

@(test)
test_measurement_failure_fails_the_frame :: proc(t: ^testing.T) {
	// A custom leaf that fails to measure fails the frame with no partial
	// result.
	{
		ctx: Context
		testing.expect_value(t, init(&ctx, _test_options()), nil)
		defer destroy(&ctx)
		if frame(&ctx, {100, 100}) {
			content(&ctx, {content = Custom_Content{measure = _measure_failing_custom}})
		}
		frame_result, frame_error := result(&ctx)
		testing.expect_value(t, frame_error, Frame_Error.Measure_Failed)
		testing.expect_value(t, len(frame_result.nodes), 0)
	}

	// A text measurer that fails does the same.
	{
		ctx: Context
		services := Services {
			measure_text = _measure_failing_text,
			break_text   = _break_ascii,
		}
		testing.expect_value(t, init(&ctx, _test_options()), nil)
		defer destroy(&ctx)
		set_services(&ctx, services)
		if frame(&ctx, {100, 100}) {
			text(&ctx, {text = "hello"})
		}
		frame_result, frame_error := result(&ctx)
		testing.expect_value(t, frame_error, Frame_Error.Measure_Failed)
		testing.expect_value(t, len(frame_result.nodes), 0)
	}
}
