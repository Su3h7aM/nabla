#+test
#+private file
package layout

import "core:math"
import "core:mem"
import "core:testing"

@(private)
_phase1_config :: proc() -> Options {
	return Options {
		capacities = {
			nodes = 64,
			children = 64,
			clips = 16,
			commands = 64,
			text_lines = 64,
			measured_words = 512,
			overlays = 16,
			measure_cache = 32,
			id_table = 64,
			depth = 32,
			diagnostics = 32,
			debug_labels = 256,
		},
	}
}

@(private)
_expect_scalar_close :: proc(t: ^testing.T, actual, expected: Scalar) {
	testing.expectf(t, math.abs(actual - expected) <= SCALAR_TOLERANCE, "expected %.6f, got %.6f", expected, actual)
}

@(private)
_expect_vec2_close :: proc(t: ^testing.T, actual, expected: Vec2) {
	_expect_scalar_close(t, actual.x, expected.x)
	_expect_scalar_close(t, actual.y, expected.y)
}

@(test)
test_phase1_style_constructors_and_identity_vectors :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Resolved_Node), 96)
	testing.expect_value(t, size_of(Resolved_Clip), 28)
	testing.expect_value(t, size_of(Command_Data), 56)
	testing.expect_value(t, size_of(Render_Command), 88)
	testing.expect_value(t, fit(), Axis_Size{mode = .Fit})
	testing.expect_value(t, fit(2, 8), Axis_Size{mode = .Fit, min = 2, max = 8})
	testing.expect_value(t, grow(), Axis_Size{mode = .Grow, weight = 1})
	testing.expect_value(t, grow(3, 2, 8), Axis_Size{mode = .Grow, min = 2, max = 8, weight = 3})
	testing.expect_value(t, fixed(12), Axis_Size{mode = .Fixed, value = 12})
	testing.expect_value(t, percent(0.25, 5, 50), Axis_Size{mode = .Percent, value = 0.25, min = 5, max = 50})
	testing.expect_value(t, pad_all(4), Edges{4, 4, 4, 4})
	testing.expect_value(t, pad_xy(3, 7), Edges{3, 7, 3, 7})
	testing.expect_value(t, radius_all(6), Radius{6, 6, 6, 6})

	testing.expect_value(t, id(""), Id(0xcbf29ce484222325))
	testing.expect_value(t, id("a"), Id(0xaf63dc4c8601ec8c))
	testing.expect_value(t, id("foobar"), Id(0x85944171f73967e8))
	testing.expect_value(t, id_index("row", 0), Id(0x50c22210c12b2efb))
	testing.expect_value(t, id_index("row", 1), Id(0x31c75b07b63be4da))
	testing.expect_value(t, id_index("row", max(u64)), Id(0x1b251dc1bed66573))
}

@(test)
test_phase1_structural_links_ids_and_lookup :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_config()), nil)
	defer destroy(&ctx)

	identifier_a := id("a")
	identifier_duplicate := id("duplicate")
	identifier_e := id("e")
	if frame(&ctx, {300, 200}) {
		if element(&ctx, {id = identifier_a}) {
			content(&ctx, {id = identifier_duplicate})
			if element(&ctx, {id = identifier_duplicate}) {
				content(&ctx, {})
			}
		}
		content(&ctx, {id = identifier_e})
	}

	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect_value(t, len(frame_result.nodes), 6)
	testing.expect_value(t, frame_result.nodes[0], Resolved_Node{})
	testing.expect_value(t, frame_result.nodes[1].parent, Node_Handle(0))
	testing.expect_value(t, frame_result.nodes[1].first_child, Node_Handle(2))
	testing.expect_value(t, frame_result.nodes[1].next_sibling, Node_Handle(5))
	testing.expect_value(t, frame_result.nodes[1].child_count, u16(2))
	testing.expect_value(t, frame_result.nodes[2].parent, Node_Handle(1))
	testing.expect_value(t, frame_result.nodes[2].next_sibling, Node_Handle(3))
	testing.expect_value(t, frame_result.nodes[3].first_child, Node_Handle(4))
	testing.expect_value(t, frame_result.nodes[4].parent, Node_Handle(3))
	testing.expect_value(t, frame_result.nodes[5].parent, Node_Handle(0))
	testing.expect_value(t, frame_result.nodes[1].flags.depth, u16(0))
	testing.expect_value(t, frame_result.nodes[4].flags.depth, u16(2))

	diagnostic_list := diagnostics(&ctx)
	testing.expect_value(t, len(diagnostic_list), 1)
	testing.expect_value(t, diagnostic_list[0].kind, Diagnostic_Kind.Duplicate_Id)
	testing.expect_value(t, diagnostic_list[0].node, Node_Handle(3))
	testing.expect_value(t, diagnostic_list[0].id, identifier_duplicate)
	testing.expect_value(t, len(frame_result.id_index), 3)
	for index in 1 ..< len(frame_result.id_index) {
		testing.expect(t, u64(frame_result.id_index[index - 1].id) < u64(frame_result.id_index[index].id))
	}
	duplicate_node, found := lookup(frame_result, identifier_duplicate)
	testing.expect(t, found)
	testing.expect_value(t, duplicate_node, frame_result.nodes[2])
	_, found = lookup(frame_result, 0)
	testing.expect(t, !found)
}

@(test)
test_phase1_local_ids_are_scoped_and_stable :: proc(t: ^testing.T) {
	config := _phase1_config()
	config.debug_labels = true
	ctx: Context
	testing.expect_value(t, init(&ctx, config), nil)
	defer destroy(&ctx)

	first_local: Id
	second_local: Id
	if frame(&ctx, {100, 100}) {
		if element(&ctx, {}) {
			first_local = id_local(&ctx, "button")
			content(&ctx, {id = first_local})
		}
		if element(&ctx, {}) {
			second_local = id_local(&ctx, "button")
			content(&ctx, {id = second_local})
		}
	}
	testing.expect(t, first_local != 0)
	testing.expect(t, second_local != 0)
	testing.expect(t, first_local != second_local)
	first_result, first_error := result(&ctx)
	testing.expect_value(t, first_error, Frame_Error.None)
	_, first_found := lookup(first_result, first_local)
	_, second_found := lookup(first_result, second_local)
	testing.expect(t, first_found && second_found)
	when ODIN_DEBUG {
		testing.expect(t, statistics(&ctx).pool_high_water[.Debug_Labels] > 0)
	}

	repeated_first: Id
	repeated_second: Id
	if frame(&ctx, {100, 100}) {
		if element(&ctx, {}) {
			repeated_first = id_local(&ctx, "button")
		}
		if element(&ctx, {}) {
			repeated_second = id_local(&ctx, "button")
		}
	}
	testing.expect_value(t, repeated_first, first_local)
	testing.expect_value(t, repeated_second, second_local)
}

@(test)
test_phase1_row_and_column_geometry :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_config()), nil)
	defer destroy(&ctx)

	if frame(&ctx, {300, 100}) {
		if element(&ctx, {layout = {flow = .Row, sizing = {width = fixed(300), height = fixed(100)}, padding = pad_xy(10, 20), gap = 5}}) {
			content(&ctx, {layout = {sizing = {width = fixed(50), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = fixed(70), height = fixed(30)}}})
		}
	}
	row_result, row_error := result(&ctx)
	testing.expect_value(t, row_error, Frame_Error.None)
	testing.expect_value(t, row_result.nodes[1].outer, Rect{{0, 0}, {300, 100}})
	testing.expect_value(t, row_result.nodes[1].inner, Rect{{10, 20}, {280, 60}})
	testing.expect_value(t, row_result.nodes[2].outer, Rect{{10, 20}, {50, 20}})
	testing.expect_value(t, row_result.nodes[3].outer, Rect{{65, 20}, {70, 30}})
	testing.expect_value(t, row_result.nodes[1].content_size, Vec2{125, 30})

	if frame(&ctx, {100, 100}) {
		if element(&ctx, {layout = {flow = .Column, padding = pad_all(2), gap = 3}}) {
			content(&ctx, {layout = {sizing = {width = fixed(10), height = fixed(4)}}})
			content(&ctx, {layout = {sizing = {width = fixed(20), height = fixed(6)}}})
		}
	}
	column_result, column_error := result(&ctx)
	testing.expect_value(t, column_error, Frame_Error.None)
	testing.expect_value(t, column_result.nodes[1].outer.size, Vec2{24, 17})
	testing.expect_value(t, column_result.nodes[1].inner.size, Vec2{20, 13})
	testing.expect_value(t, column_result.nodes[1].content_size, Vec2{20, 13})
	testing.expect_value(t, column_result.nodes[2].outer.position, Vec2{2, 2})
	testing.expect_value(t, column_result.nodes[3].outer.position, Vec2{2, 9})
}

@(test)
test_phase1_percent_grow_alignment_and_justification :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_config()), nil)
	defer destroy(&ctx)

	if frame(&ctx, {200, 100}) {
		if element(&ctx, {layout = {sizing = {width = fixed(200), height = fixed(100)}, gap = 10, align = .Center}}) {
			content(&ctx, {layout = {sizing = {width = percent(0.5), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = fixed(0), height = fixed(30)}}})
		}
	}
	percent_result, percent_error := result(&ctx)
	testing.expect_value(t, percent_error, Frame_Error.None)
	_expect_scalar_close(t, percent_result.nodes[2].outer.size.x, 95)
	_expect_scalar_close(t, percent_result.nodes[2].outer.position.y, 40)
	_expect_scalar_close(t, percent_result.nodes[3].outer.position.y, 35)

	if frame(&ctx, {100, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(100), height = fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {width = grow(1), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = grow(3), height = fixed(20)}}})
		}
	}
	grow_result, grow_error := result(&ctx)
	testing.expect_value(t, grow_error, Frame_Error.None)
	_expect_scalar_close(t, grow_result.nodes[2].outer.size.x, 25)
	_expect_scalar_close(t, grow_result.nodes[3].outer.size.x, 75)

	if frame(&ctx, {100, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(100), height = fixed(20)}, justify = .Space_Evenly}}) {
			content(&ctx, {layout = {sizing = {width = fixed(20), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = fixed(20), height = fixed(20)}}})
		}
	}
	justify_result, justify_error := result(&ctx)
	testing.expect_value(t, justify_error, Frame_Error.None)
	_expect_scalar_close(t, justify_result.nodes[2].outer.position.x, 20)
	_expect_scalar_close(t, justify_result.nodes[3].outer.position.x, 60)
}

@(test)
test_phase1_indefinite_percent_and_bounds_diagnostics :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_config()), nil)
	defer destroy(&ctx)

	if frame(&ctx, {100, 100}) {
		if element(&ctx, {}) {
			content(&ctx, {layout = {sizing = {width = percent(1.5, 30, 10), height = fit()}}, content = Image_Content{intrinsic_size = {20, 10}}})
		}
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	_expect_scalar_close(t, frame_result.nodes[2].outer.size.x, 30)

	has_percent_range := false
	has_percent_indefinite := false
	has_bounds_conflict := false
	for diagnostic in diagnostics(&ctx) {
		#partial switch diagnostic.kind {
		case .Percent_Out_Of_Range:
			has_percent_range = true
		case .Percent_Indefinite:
			has_percent_indefinite = true
		case .Min_Exceeds_Max:
			has_bounds_conflict = true
		case:
		}
	}
	testing.expect(t, has_percent_range)
	testing.expect(t, has_percent_indefinite)
	testing.expect(t, has_bounds_conflict)
}

@(test)
test_phase1_saturation_shrink_overflow_and_stretch :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_config()), nil)
	defer destroy(&ctx)

	if frame(&ctx, {100, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(100), height = fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {width = grow(1, maximum = 20), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = grow(3), height = fixed(20)}}})
		}
	}
	saturated_result, saturated_error := result(&ctx)
	testing.expect_value(t, saturated_error, Frame_Error.None)
	_expect_scalar_close(t, saturated_result.nodes[2].outer.size.x, 20)
	_expect_scalar_close(t, saturated_result.nodes[3].outer.size.x, 80)

	if frame(&ctx, {50, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(50), height = fixed(20)}}}) {
			content(&ctx, {content = Image_Content{intrinsic_size = {40, 20}}})
			content(&ctx, {content = Image_Content{intrinsic_size = {40, 20}}})
		}
	}
	shrink_result, shrink_error := result(&ctx)
	testing.expect_value(t, shrink_error, Frame_Error.None)
	_expect_scalar_close(t, shrink_result.nodes[2].outer.size.x, 25)
	_expect_scalar_close(t, shrink_result.nodes[3].outer.size.x, 25)

	if frame(&ctx, {40, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(40), height = fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {width = grow(1), height = fixed(20)}}, content = Image_Content{intrinsic_size = {40, 20}}})
			content(&ctx, {layout = {sizing = {width = grow(3), height = fixed(20)}}, content = Image_Content{intrinsic_size = {40, 20}}})
		}
	}
	weighted_shrink_result, weighted_shrink_error := result(&ctx)
	testing.expect_value(t, weighted_shrink_error, Frame_Error.None)
	_expect_scalar_close(t, weighted_shrink_result.nodes[2].outer.size.x, 30)
	_expect_scalar_close(t, weighted_shrink_result.nodes[3].outer.size.x, 10)

	if frame(&ctx, {50, 20}) {
		if element(&ctx, {layout = {sizing = {width = fixed(50), height = fixed(20)}}}) {
			content(&ctx, {layout = {sizing = {width = fixed(40), height = fixed(20)}}})
			content(&ctx, {layout = {sizing = {width = fixed(40), height = fixed(20)}}})
		}
	}
	overflow_result, overflow_error := result(&ctx)
	testing.expect_value(t, overflow_error, Frame_Error.None)
	testing.expect(t, overflow_result.nodes[1].flags.overflow_x)
	has_overflow := false
	for diagnostic in diagnostics(&ctx) {
		if diagnostic.kind == .Overflow && diagnostic.node == 1 && diagnostic.axis == .X {
			has_overflow = true
			_expect_scalar_close(t, diagnostic.amount, 30)
		}
	}
	testing.expect(t, has_overflow)

	if frame(&ctx, {100, 100}) {
		if element(&ctx, {layout = {sizing = {width = fixed(100), height = fixed(100)}, align = .Stretch}}) {
			content(&ctx, {layout = {sizing = {width = fixed(20), height = fit()}}, content = Image_Content{intrinsic_size = {20, 30}}})
			content(&ctx, {layout = {sizing = {width = fixed(20), height = fixed(30)}}})
		}
	}
	stretch_result, stretch_error := result(&ctx)
	testing.expect_value(t, stretch_error, Frame_Error.None)
	_expect_scalar_close(t, stretch_result.nodes[2].outer.size.y, 100)
	_expect_scalar_close(t, stretch_result.nodes[3].outer.size.y, 30)
}

@(private)
_Measure_Tracker :: struct {
	calls: int,
}

@(private)
_test_custom_measure :: proc(user: rawptr, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	tracker := (^_Measure_Tracker)(user)
	tracker.calls += 1
	if request.axes[.X].mode == .Exact {
		return Measure_Result{size = {request.axes[.X].value, 20}, min_size = {5, 5}}, .None
	}
	return Measure_Result{size = {30, 10}, min_size = {5, 5}}, .None
}

@(test)
test_phase1_custom_measurement_and_aspect :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _phase1_config()), nil)
	defer destroy(&ctx)
	tracker: _Measure_Tracker

	if frame(&ctx, {400, 200}) {
		content(&ctx, {content = Custom_Content{data = &tracker, measure = _test_custom_measure}})
		content(&ctx, {layout = {sizing = {width = fixed(200), height = fit()}, aspect = 2}})
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect_value(t, tracker.calls, 2)
	_expect_vec2_close(t, frame_result.nodes[1].outer.size, {30, 20})
	_expect_vec2_close(t, frame_result.nodes[2].outer.size, {200, 100})
}

@(test)
test_phase1_publication_is_transactional_and_allocation_free :: proc(t: ^testing.T) {
	config := _phase1_config()
	config.capacities.overlays = 0
	ctx: Context
	testing.expect_value(t, init(&ctx, config), nil)
	defer destroy(&ctx)

	before, before_error := result(&ctx)
	testing.expect_value(t, before_error, Frame_Error.No_Completed_Frame)
	testing.expect_value(t, len(before.nodes), 0)

	{
		context.allocator = mem.panic_allocator()
		if frame(&ctx, {100, 100}) {
			if element(&ctx, {id = id("root"), layout = {sizing = {width = fixed(100), height = fixed(100)}}}) {
				content(&ctx, {layout = {sizing = {width = grow(), height = grow()}}})
			}
		}
	}
	first_result, first_error := result(&ctx)
	testing.expect_value(t, first_error, Frame_Error.None)
	testing.expect_value(t, first_result.generation, u32(1))
	testing.expect_value(t, len(first_result.nodes), 3)
	testing.expect_value(t, len(first_result.clips), 1)
	testing.expect_value(t, first_result.clips[0].rect, Rect{size = {100, 100}})
	testing.expect_value(t, first_result.clips[0].axes, Axis_Set{.X, .Y})

	if frame(&ctx, {100, 100}) {
		if element(&ctx, {overlay = {attach = .Root}}) {
		}
	}
	failed_result, failed_error := result(&ctx)
	testing.expect_value(t, failed_error, Frame_Error.Capacity_Exhausted)
	testing.expect_value(t, len(failed_result.nodes), 0)
	testing.expect_value(t, len(failed_result.id_index), 0)
}
