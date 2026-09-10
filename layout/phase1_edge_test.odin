#+test
#+private file
package layout

import "core:math"
import "core:testing"

@(private)
_phase1_edge_config :: proc() -> Options {
	return Options {
		capacities = {
			nodes = 64,
			children = 64,
			clips = 8,
			commands = 8,
			text_lines = 8,
			measured_words = 512,
			overlays = 8,
			measure_cache = 8,
			id_table = 64,
			depth = 16,
			diagnostics = 32,
			debug_labels = 64,
		},
	}
}

@(test)
test_phase1_aspect_propagates_through_fit_ancestors :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_edge_config()), nil)
	defer destroy(&ctx)

	if frame(&ctx, {400, 200}) {
		if element(&ctx, {}) {
			content(&ctx, {layout = {sizing = {width = fixed(200), height = fit()}, aspect = 2}})
		}
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect_value(t, frame_result.nodes[1].outer.size, Vec2{200, 100})
	testing.expect_value(t, frame_result.nodes[2].outer.size, Vec2{200, 100})

	if frame(&ctx, {400, 200}) {
		if element(&ctx, {layout = {sizing = {width = fixed(400), height = fixed(200)}}}) {
			content(&ctx, {layout = {sizing = {width = fit(), height = percent(0.5)}, aspect = 2}})
		}
	}
	frame_result, frame_error = result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect_value(t, frame_result.nodes[2].outer.size, Vec2{200, 100})
	for diagnostic in diagnostics(&ctx) {
		testing.expect(t, diagnostic.kind != .Aspect_Undetermined)
	}

	if frame(&ctx, {400, 200}) {
		if element(&ctx, {layout = {sizing = {width = fixed(100), height = fit()}, aspect = 1}}) {
			content(&ctx, {layout = {sizing = {width = fit(), height = percent(0.5)}, aspect = 2}})
		}
	}
	frame_result, frame_error = result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect_value(t, frame_result.nodes[1].outer.size, Vec2{100, 100})
	testing.expect_value(t, frame_result.nodes[2].outer.size, Vec2{100, 50})
	for diagnostic in diagnostics(&ctx) {
		testing.expect(t, diagnostic.kind != .Percent_Indefinite)
		testing.expect(t, diagnostic.kind != .Aspect_Undetermined)
	}
}

@(test)
test_phase1_cross_axis_shrink_and_overflow :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_edge_config()), nil)
	defer destroy(&ctx)

	if frame(&ctx, {100, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(100), height = fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {width = fixed(10), height = fit()}}, content = Image_Content{intrinsic_size = {10, 40}}})
		}
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect_value(t, frame_result.nodes[2].outer.size.y, Scalar(20))
	testing.expect(t, !frame_result.nodes[1].flags.overflow_y)

	if frame(&ctx, {100, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(100), height = fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {width = fixed(10), height = fixed(40)}}})
		}
	}
	frame_result, frame_error = result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect(t, frame_result.nodes[1].flags.overflow_y)
	has_overflow := false
	for diagnostic in diagnostics(&ctx) {
		if diagnostic.kind == .Overflow && diagnostic.node == 1 && diagnostic.axis == .Y {
			has_overflow = true
			testing.expect_value(t, diagnostic.amount, Scalar(20))
		}
	}
	testing.expect(t, has_overflow)

	if frame(&ctx, {10, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(10), height = fixed(20)}, gap = 20}}) {
			content(&ctx, {layout = {sizing = {width = fixed(0), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = fixed(0), height = fixed(20)}}})
		}
	}
	frame_result, frame_error = result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect(t, frame_result.nodes[1].flags.overflow_x)
	has_gap_overflow := false
	for diagnostic in diagnostics(&ctx) {
		if diagnostic.kind == .Overflow && diagnostic.node == 1 && diagnostic.axis == .X {
			has_gap_overflow = true
			testing.expect_value(t, diagnostic.amount, Scalar(10))
		}
	}
	testing.expect(t, has_gap_overflow)
}

@(test)
test_phase1_indefinite_percent_shrinks_as_fit :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_edge_config()), nil)
	defer destroy(&ctx)

	if frame(&ctx, {100, 20}) {
		if element(&ctx, {layout = {sizing = {width = fit(maximum = 50), height = fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {width = percent(0.5), height = fixed(20)}}, content = Image_Content{intrinsic_size = {80, 20}}})
		}
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect_value(t, frame_result.nodes[1].outer.size.x, Scalar(50))
	testing.expect_value(t, frame_result.nodes[2].outer.size.x, Scalar(50))
	testing.expect(t, !frame_result.nodes[1].flags.overflow_x)
	has_indefinite_percent := false
	for diagnostic in diagnostics(&ctx) {
		if diagnostic.kind == .Percent_Indefinite {
			has_indefinite_percent = true
		}
	}
	testing.expect(t, has_indefinite_percent)
}

@(test)
test_phase1_grow_on_an_indefinite_axis_is_diagnosed :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_edge_config()), nil)
	defer destroy(&ctx)

	// A Grow child on the main axis of a Fit parent cannot express its intent:
	// Fit sizes from intrinsic content, and there is no available space to grow
	// into. Both references collapse it silently; this pins the diagnostic that
	// closes that silence, symmetric with Percent_Indefinite.
	if frame(&ctx, {200, 20}) {
		if element(&ctx, {layout = {flow = .Row, sizing = {fit(), fit()}}}) {
			content(&ctx, {layout = {sizing = {grow(), fixed(10)}}})
		}
	}
	_, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	has_indefinite_grow := false
	for diagnostic in diagnostics(&ctx) {
		if diagnostic.kind == .Grow_Indefinite && diagnostic.node == 2 && diagnostic.axis == .X {
			has_indefinite_grow = true
		}
	}
	testing.expect(t, has_indefinite_grow)
}

@(test)
test_phase1_grow_under_a_definite_parent_is_not_diagnosed :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_edge_config()), nil)
	defer destroy(&ctx)

	// The diagnostic is scoped to indefinite (Fit) parents: Grow under a Fixed
	// parent resolves against available space and must stay quiet.
	if frame(&ctx, {200, 20}) {
		if element(&ctx, {layout = {flow = .Row, sizing = {fixed(200), fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {grow(), fixed(10)}}})
		}
	}
	_, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	for diagnostic in diagnostics(&ctx) {
		testing.expect(t, diagnostic.kind != .Grow_Indefinite)
	}
}

@(test)
test_phase1_resolved_shrink_clears_intrinsic_overflow :: proc(t: ^testing.T) {
	config := _phase1_edge_config()
	config.capacities.diagnostics = 1
	ctx: Context
	testing.expect_value(t, init(&ctx, config), nil)
	defer destroy(&ctx)
	maximum := Scalar(math.F32_MAX)

	if frame(&ctx, {maximum, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(maximum), height = fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {width = fit(), height = fixed(20)}}, content = Image_Content{intrinsic_size = {maximum, 20}}})
			content(&ctx, {layout = {sizing = {width = fit(), height = fixed(20)}}, content = Image_Content{intrinsic_size = {maximum, 20}}})
		}
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect(t, !frame_result.nodes[1].flags.overflow_x)
	testing.expect_value(t, len(diagnostics(&ctx)), 0)
}

@(private)
_Height_Measure_Tracker :: struct {
	saw_exact_height: bool,
}

@(private)
_measure_from_height :: proc(user: rawptr, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	tracker := (^_Height_Measure_Tracker)(user)
	if request.axes[.Y].mode == .Exact {
		tracker.saw_exact_height = true
		height := request.axes[.Y].value
		return Measure_Result{size = {height * 2, height}, min_size = {1, 1}}, .None
	}
	if request.axes[.X].mode == .Exact {
		return Measure_Result{size = {request.axes[.X].value, 10}, min_size = {1, 1}}, .None
	}
	return Measure_Result{size = {5, 5}, min_size = {1, 1}}, .None
}

@(test)
test_phase1_custom_measurement_uses_exact_height :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_edge_config()), nil)
	defer destroy(&ctx)
	tracker: _Height_Measure_Tracker

	if frame(&ctx, {400, 200}) {
		content(&ctx, {layout = {sizing = {width = fit(), height = fixed(100)}}, content = Custom_Content{data = &tracker, measure = _measure_from_height}})
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect(t, tracker.saw_exact_height)
	testing.expect_value(t, frame_result.nodes[1].outer.size, Vec2{200, 100})
}

@(private)
_measure_with_intrinsic_floor :: proc(user: rawptr, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	_ = user
	if request.axes[.Y].mode == .Exact {
		return Measure_Result{size = {40, request.axes[.Y].value}, min_size = {1, 1}}, .None
	}
	if request.axes[.X].mode == .Exact {
		return Measure_Result{size = {request.axes[.X].value, 10}, min_size = {1, 1}}, .None
	}
	return Measure_Result{size = {40, 10}, min_size = {30, 1}}, .None
}

@(test)
test_phase1_constrained_measurement_preserves_intrinsic_floor :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_edge_config()), nil)
	defer destroy(&ctx)

	if frame(&ctx, {20, 10}) {
		if element(&ctx, {layout = {sizing = {width = fixed(20), height = fixed(10)}}}) {
			content(&ctx, {layout = {sizing = {width = fit(), height = fixed(10)}}, content = Custom_Content{measure = _measure_with_intrinsic_floor}})
		}
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect_value(t, frame_result.nodes[2].outer.size.x, Scalar(30))
	testing.expect(t, frame_result.nodes[1].flags.overflow_x)
}

@(private)
_measure_with_invalid_height :: proc(user: rawptr, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	_ = user
	_ = request
	return Measure_Result{size = {30, -1}, min_size = {5, 5}, baseline = -1}, .None
}

@(test)
test_phase1_measurement_clamps_only_invalid_components :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_edge_config()), nil)
	defer destroy(&ctx)

	if frame(&ctx, {100, 100}) {
		content(&ctx, {content = Custom_Content{measure = _measure_with_invalid_height}})
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect_value(t, frame_result.nodes[1].outer.size.x, Scalar(30))
	testing.expect_value(t, frame_result.nodes[1].outer.size.y, Scalar(0))
	has_measure_failure := false
	for diagnostic in diagnostics(&ctx) {
		if diagnostic.kind == .Measure_Failed {
			has_measure_failure = true
		}
	}
	testing.expect(t, has_measure_failure)
}

@(test)
test_phase1_required_diagnostic_exhaustion_fails_frame :: proc(t: ^testing.T) {
	config := _phase1_edge_config()
	config.capacities.diagnostics = 1
	ctx: Context
	testing.expect_value(t, init(&ctx, config), nil)
	defer destroy(&ctx)
	identifier := id("duplicate")

	if frame(&ctx, {100, 100}) {
		content(&ctx, {id = identifier})
		content(&ctx, {id = identifier})
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.Capacity_Exhausted)
	testing.expect_value(t, len(frame_result.nodes), 0)
	diagnostic_list := diagnostics(&ctx)
	testing.expect_value(t, len(diagnostic_list), 1)
	testing.expect_value(t, diagnostic_list[0].kind, Diagnostic_Kind.Pool_Exhausted)
	testing.expect_value(t, diagnostic_list[0].pool, Pool_Id.Diagnostics)
}

@(test)
test_phase1_distribution_correction_and_finite_publication :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_edge_config()), nil)
	defer destroy(&ctx)

	if frame(&ctx, {100_000_000, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(100_000_000), height = fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {width = grow(), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = grow(), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = grow(), height = fixed(20)}}})
		}
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	published_sum := f64(frame_result.nodes[2].outer.size.x) + f64(frame_result.nodes[3].outer.size.x) + f64(frame_result.nodes[4].outer.size.x)
	testing.expect(t, math.abs(published_sum - 100_000_000) <= f64(SCALAR_TOLERANCE))

	maximum := Scalar(math.F32_MAX)
	if frame(&ctx, {maximum, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(maximum), height = fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {width = fixed(maximum), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = fixed(maximum), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = fixed(maximum), height = fixed(20)}}})
		}
	}
	frame_result, frame_error = result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	for resolved_node in frame_result.nodes {
		values := [8]Scalar {
			resolved_node.outer.position.x,
			resolved_node.outer.position.y,
			resolved_node.outer.size.x,
			resolved_node.outer.size.y,
			resolved_node.inner.position.x,
			resolved_node.inner.position.y,
			resolved_node.content_size.x,
			resolved_node.content_size.y,
		}
		for value in values {
			testing.expect(t, !math.is_nan(value) && !math.is_inf(value))
		}
	}
}
