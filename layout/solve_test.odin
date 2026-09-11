#+test
#+private file
package layout

import "core:math"
import "core:testing"

_expect_close :: proc(t: ^testing.T, actual, expected: Scalar) {
	testing.expectf(t, math.abs(actual - expected) <= SCALAR_TOLERANCE, "expected %.6f, got %.6f", expected, actual)
}

_expect_vec2_close :: proc(t: ^testing.T, actual, expected: Vec2) {
	_expect_close(t, actual.x, expected.x)
	_expect_close(t, actual.y, expected.y)
}

_has_diagnostic :: proc(ctx: ^Context, kind: Diagnostic_Kind) -> bool {
	for diagnostic in diagnostics(ctx) {
		if diagnostic.kind == kind {
			return true
		}
	}
	return false
}

@(test)
test_flow_sizing_and_alignment :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	// Padding and gap shrink the content box; children flow along the main axis.
	if frame(&ctx, {300, 100}) {
		if element(&ctx, {layout = {flow = .Row, sizing = {width = fixed(300), height = fixed(100)}, padding = pad_xy(10, 20), gap = 5}}) {
			content(&ctx, {layout = {sizing = {width = fixed(50), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = fixed(70), height = fixed(30)}}})
		}
	}
	row_result, row_error := result(&ctx)
	testing.expect_value(t, row_error, Frame_Error.None)
	testing.expect_value(t, row_result.nodes[1].inner, Rect{{10, 20}, {280, 60}})
	testing.expect_value(t, row_result.nodes[2].outer, Rect{{10, 20}, {50, 20}})
	testing.expect_value(t, row_result.nodes[3].outer, Rect{{65, 20}, {70, 30}})

	if frame(&ctx, {100, 100}) {
		if element(&ctx, {layout = {flow = .Column, padding = pad_all(2), gap = 3}}) {
			content(&ctx, {layout = {sizing = {width = fixed(10), height = fixed(4)}}})
			content(&ctx, {layout = {sizing = {width = fixed(20), height = fixed(6)}}})
		}
	}
	column_result, column_error := result(&ctx)
	testing.expect_value(t, column_error, Frame_Error.None)
	testing.expect_value(t, column_result.nodes[1].outer.size, Vec2{24, 17})
	testing.expect_value(t, column_result.nodes[2].outer.position, Vec2{2, 2})
	testing.expect_value(t, column_result.nodes[3].outer.position, Vec2{2, 9})

	// Grow shares the main axis by weight; Percent resolves against the
	// parent's content box.
	if frame(&ctx, {200, 100}) {
		if element(&ctx, {layout = {sizing = {width = fixed(200), height = fixed(100)}, gap = 10, align = .Center}}) {
			content(&ctx, {layout = {sizing = {width = percent(0.5), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = grow(3), height = fixed(30)}}})
		}
	}
	sizing_result, sizing_error := result(&ctx)
	testing.expect_value(t, sizing_error, Frame_Error.None)
	_expect_close(t, sizing_result.nodes[2].outer.size.x, 95)
	_expect_close(t, sizing_result.nodes[2].outer.position.y, 40)
	_expect_close(t, sizing_result.nodes[3].outer.position.y, 35)

	// Justify distributes main-axis space; Stretch fills the cross axis for
	// non-fixed children only.
	if frame(&ctx, {100, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(100), height = fixed(20)}, justify = .Space_Evenly}}) {
			content(&ctx, {layout = {sizing = {width = fixed(20), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = fixed(20), height = fixed(20)}}})
		}
	}
	justify_result, justify_error := result(&ctx)
	testing.expect_value(t, justify_error, Frame_Error.None)
	_expect_close(t, justify_result.nodes[2].outer.position.x, 20)
	_expect_close(t, justify_result.nodes[3].outer.position.x, 60)

	if frame(&ctx, {100, 100}) {
		if element(&ctx, {layout = {sizing = {width = fixed(100), height = fixed(100)}, align = .Stretch}}) {
			content(&ctx, {layout = {sizing = {width = fixed(20), height = fit()}}, content = Image_Content{intrinsic_size = {20, 30}}})
			content(&ctx, {layout = {sizing = {width = fixed(20), height = fixed(30)}}})
		}
	}
	stretch_result, stretch_error := result(&ctx)
	testing.expect_value(t, stretch_error, Frame_Error.None)
	_expect_close(t, stretch_result.nodes[2].outer.size.y, 100)
	_expect_close(t, stretch_result.nodes[3].outer.size.y, 30)

	// A declared aspect derives the missing axis and propagates through a
	// content-sized ancestor.
	if frame(&ctx, {400, 200}) {
		if element(&ctx, {}) {
			content(&ctx, {layout = {sizing = {width = fixed(200), height = fit()}, aspect = 2}})
		}
	}
	aspect_result, aspect_error := result(&ctx)
	testing.expect_value(t, aspect_error, Frame_Error.None)
	_expect_vec2_close(t, aspect_result.nodes[1].outer.size, {200, 100})
	_expect_vec2_close(t, aspect_result.nodes[2].outer.size, {200, 100})
}

@(test)
test_overflow_and_indefinite_diagnostics :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	// Two fixed children that cannot fit report the flag, the amount, and the
	// axis.
	if frame(&ctx, {50, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(50), height = fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {width = fixed(40), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = fixed(40), height = fixed(20)}}})
		}
	}
	overflow_result, overflow_error := result(&ctx)
	testing.expect_value(t, overflow_error, Frame_Error.None)
	testing.expect(t, overflow_result.nodes[1].flags.overflow_x)
	found := false
	for diagnostic in diagnostics(&ctx) {
		if diagnostic.kind == .Overflow && diagnostic.node == 1 && diagnostic.axis == .X {
			found = true
			_expect_close(t, diagnostic.amount, 30)
		}
	}
	testing.expect(t, found)

	// Out-of-range Percent is clamped to the unit interval and a min above a
	// max collapses without moving the good lower bound.
	if frame(&ctx, {100, 100}) {
		if element(&ctx, {}) {
			content(&ctx, {layout = {sizing = {width = percent(1.5, 30, 10), height = fit()}}, content = Image_Content{intrinsic_size = {20, 10}}})
		}
	}
	invalid_result, invalid_error := result(&ctx)
	testing.expect_value(t, invalid_error, Frame_Error.None)
	_expect_close(t, invalid_result.nodes[2].outer.size.x, 30)
	testing.expect(t, _has_diagnostic(&ctx, .Percent_Out_Of_Range))
	testing.expect(t, _has_diagnostic(&ctx, .Min_Exceeds_Max))

	// Percent on an indefinite axis shrinks as Fit and says so rather than
	// guessing.
	if frame(&ctx, {100, 20}) {
		if element(&ctx, {layout = {sizing = {width = fit(maximum = 50), height = fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {width = percent(0.5), height = fixed(20)}}, content = Image_Content{intrinsic_size = {80, 20}}})
		}
	}
	percent_result, percent_error := result(&ctx)
	testing.expect_value(t, percent_error, Frame_Error.None)
	_expect_close(t, percent_result.nodes[2].outer.size.x, 50)
	testing.expect(t, _has_diagnostic(&ctx, .Percent_Indefinite))

	// Grow under a content-sized parent has no space to grow into and is
	// diagnosed; under a definite parent it resolves and stays quiet.
	if frame(&ctx, {200, 20}) {
		if element(&ctx, {layout = {flow = .Row, sizing = {fit(), fit()}}}) {
			content(&ctx, {layout = {sizing = {grow(), fixed(10)}}})
		}
	}
	_, indefinite_error := result(&ctx)
	testing.expect_value(t, indefinite_error, Frame_Error.None)
	found_indefinite_grow := false
	for diagnostic in diagnostics(&ctx) {
		if diagnostic.kind == .Grow_Indefinite && diagnostic.node == 2 && diagnostic.axis == .X {
			found_indefinite_grow = true
		}
	}
	testing.expect(t, found_indefinite_grow)

	if frame(&ctx, {200, 20}) {
		if element(&ctx, {layout = {flow = .Row, sizing = {fixed(200), fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {grow(), fixed(10)}}})
		}
	}
	_, definite_error := result(&ctx)
	testing.expect_value(t, definite_error, Frame_Error.None)
	testing.expect(t, !_has_diagnostic(&ctx, .Grow_Indefinite))
}
