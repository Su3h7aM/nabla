#+test
#+private file
package layout

import "core:mem"
import "core:testing"

_phase3_measure_monospace :: proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	_, _, _, _ = user_data, text, style, request
	width := Scalar(10 * len(text))
	return Measure_Result{size = {width, 20}, min_size = {width, 20}}, .None
}

_phase3_services :: proc() -> Services {
	return Services{measure_text = _phase3_measure_monospace, break_text = _ascii_break_fixture}
}

_phase3_config :: proc() -> Options {
	return Options {
		capacities = {
			nodes = 64,
			children = 64,
			clips = 16,
			commands = 64,
			text_lines = 64,
			measured_words = 512,
			overlays = 16,
			measure_cache = 64,
			id_table = 64,
			depth = 32,
			diagnostics = 32,
			debug_labels = 256,
		},
	}
}

_panel :: proc(width, height: Scalar) -> Element_Desc {
	return Element_Desc{layout = {sizing = {fixed(width), fixed(height)}}}
}

_diagnostic_kinds :: proc(ctx: ^Context) -> (kinds: bit_set[Diagnostic_Kind]) {
	for entry in diagnostics(ctx) {
		kinds += {entry.kind}
	}
	return
}

_handle_of :: proc(frame_result: Frame_Result, identifier: Id) -> Node_Handle {
	for entry in frame_result.id_index {
		if entry.id == identifier {
			return entry.node
		}
	}
	return 0
}

_hit_position :: proc(frame_result: Frame_Result, handle: Node_Handle) -> int {
	for entry, index in frame_result.hit_order {
		if entry == handle {
			return index
		}
	}
	return -1
}

@(test)
test_phase3_clip_table_stores_effective_rectangles :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	// An inner clip that reaches past its clipping ancestor must be cut down to
	// the intersection, because the stored rect is the effective one.
	set_services(&ui, _phase3_services())
	if frame(&ui, {200, 200}) {
		outer := _panel(100, 100)
		outer.id = id("outer")
		outer.layout.padding = pad_all(10)
		outer.clip = {
			axes = {.X, .Y},
		}
		if element(&ui, outer) {
			inner := _panel(200, 200)
			inner.id = id("inner")
			inner.clip = {
				axes = {.X, .Y},
			}
			if element(&ui, inner) {
				content(&ui, {id = id("leaf"), layout = {sizing = {fixed(10), fixed(10)}}})
			}
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.clips), 3)

	testing.expect_value(t, frame_result.clips[0].rect, Rect{size = {200, 200}})

	outer_node := lookup(frame_result, id("outer"))
	testing.expect_value(t, frame_result.clips[1].owner, Node_Handle(1))
	testing.expect_value(t, frame_result.clips[1].parent, Clip_Handle(0))
	testing.expect_value(t, frame_result.clips[1].rect, Rect{position = {10, 10}, size = {80, 80}})
	// A clipping element is bounded by its ancestors, not by its own entry.
	testing.expect_value(t, outer_node.clip, Clip_Handle(0))

	inner_node := lookup(frame_result, id("inner"))
	testing.expect_value(t, inner_node.clip, Clip_Handle(1))
	testing.expect_value(t, frame_result.clips[2].parent, Clip_Handle(1))
	testing.expect_value(t, frame_result.clips[2].rect, Rect{position = {10, 10}, size = {80, 80}})

	leaf := lookup(frame_result, id("leaf"))
	testing.expect_value(t, leaf.clip, Clip_Handle(2))
	testing.expect(t, leaf.flags.visible)
}

@(test)
test_phase3_axis_specific_clip_preserves_the_other_axis :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {300, 300}) {
		scroller := _panel(100, 50)
		scroller.id = id("scroller")
		scroller.clip = {
			axes = {.Y},
		}
		if element(&ui, scroller) {
			content(&ui, {id = id("tall"), layout = {sizing = {fixed(100), fixed(400)}}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.clips), 2)

	clip := frame_result.clips[1]
	testing.expect_value(t, clip.axes, Axis_Set{.Y})
	// Y comes from the element, X stays at the inherited viewport range.
	testing.expect_value(t, clip.rect, Rect{size = {300, 50}})

	tall := lookup(frame_result, id("tall"))
	testing.expect(t, tall.flags.visible)
	testing.expect(t, tall.flags.clipped)
}

@(test)
test_phase3_empty_clip_hides_without_changing_geometry :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {200, 200}) {
		collapsed := _panel(0, 0)
		collapsed.id = id("collapsed")
		collapsed.clip = {
			axes = {.X, .Y},
		}
		if element(&ui, collapsed) {
			content(&ui, {id = id("hidden"), layout = {sizing = {fixed(50), fixed(50)}}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	testing.expect_value(t, frame_result.clips[1].rect.size, Vec2{})
	hidden := lookup(frame_result, id("hidden"))
	testing.expect(t, !hidden.flags.visible)
	// Visibility is not geometry: the hidden child keeps its full size.
	testing.expect_value(t, hidden.outer.size, Vec2{50, 50})
}

@(test)
test_phase3_scroll_offset_displaces_descendants_only :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {300, 300}) {
		scroller := _panel(100, 100)
		scroller.id = id("scroller")
		scroller.layout.flow = .Column
		scroller.clip = {
			axes   = {.Y},
			offset = {0, 30},
		}
		if element(&ui, scroller) {
			content(&ui, {id = id("first"), layout = {sizing = {fixed(100), fixed(80)}}})
			content(&ui, {id = id("second"), layout = {sizing = {fixed(100), fixed(80)}}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	scroller := lookup(frame_result, id("scroller"))
	// The clipping element itself never moves and never resizes.
	testing.expect_value(t, scroller.outer, Rect{size = {100, 100}})
	testing.expect_value(t, scroller.content_size, Vec2{100, 160})
	testing.expect_value(t, scroller.scroll_range, Vec2{0, 60})
	testing.expect_value(t, scroller.scroll_offset, Vec2{0, 30})

	testing.expect_value(t, lookup(frame_result, id("first")).outer.position, Vec2{0, -30})
	testing.expect_value(t, lookup(frame_result, id("second")).outer.position, Vec2{0, 50})
	// The offset is inside the legal range, so nothing is reported.
	testing.expect(t, .Overflow not_in _diagnostic_kinds(&ui))
}

@(test)
test_phase3_out_of_range_scroll_is_applied_and_diagnosed :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {300, 300}) {
		scroller := _panel(100, 100)
		scroller.id = id("scroller")
		scroller.clip = {
			axes   = {.Y},
			offset = {0, 500},
		}
		if element(&ui, scroller) {
			content(&ui, {id = id("child"), layout = {sizing = {fixed(100), fixed(120)}}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// The core clamps nothing: the over-scrolled result is exact and reported.
	testing.expect_value(t, lookup(frame_result, id("scroller")).scroll_offset, Vec2{0, 500})
	testing.expect_value(t, lookup(frame_result, id("child")).outer.position, Vec2{0, -500})
	testing.expect(t, .Overflow in _diagnostic_kinds(&ui))
}

@(test)
test_phase3_nested_scroll_offsets_accumulate :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		outer := _panel(200, 200)
		outer.clip = {
			axes   = {.X, .Y},
			offset = {10, 20},
		}
		if element(&ui, outer) {
			inner := _panel(150, 150)
			inner.id = id("inner")
			inner.clip = {
				axes   = {.X, .Y},
				offset = {5, 5},
			}
			if element(&ui, inner) {
				content(&ui, {id = id("leaf"), layout = {sizing = {fixed(10), fixed(10)}}})
			}
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	testing.expect_value(t, lookup(frame_result, id("inner")).outer.position, Vec2{-10, -20})
	testing.expect_value(t, lookup(frame_result, id("leaf")).outer.position, Vec2{-15, -25})
}

@(test)
test_phase3_overlay_leaves_normal_flow :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		row := Element_Desc {
			layout = {sizing = {grow(), fixed(100)}},
		}
		if element(&ui, row) {
			content(&ui, {id = id("left"), layout = {sizing = {grow(), grow()}}})
			overlay := _panel(50, 50)
			overlay.id = id("overlay")
			overlay.overlay = {
				attach = .Root,
			}
			content(&ui, overlay)
			content(&ui, {id = id("right"), layout = {sizing = {grow(), grow()}}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// The overlay consumes no space, so the two growing siblings split the row.
	testing.expect_value(t, lookup(frame_result, id("left")).outer, Rect{size = {200, 100}})
	testing.expect_value(t, lookup(frame_result, id("right")).outer, Rect{position = {200, 0}, size = {200, 100}})

	overlay := lookup(frame_result, id("overlay"))
	testing.expect(t, overlay.flags.is_overlay)
	// Lexical structure survives: the overlay is still a published child.
	testing.expect_value(t, overlay.parent, Node_Handle(1))
	testing.expect_value(t, frame_result.nodes[1].child_count, u16(3))
}

@(test)
test_phase3_overlay_attaches_to_element_target :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		anchor := _panel(100, 40)
		anchor.id = id("anchor")
		anchor.layout.padding = pad_all(20)
		if element(&ui, anchor) {
			// Declared before its target to prove forward references resolve.
			menu := _panel(60, 30)
			menu.id = id("menu")
			menu.overlay = {
				attach       = .Element,
				target       = id("target"),
				self_point   = .Left_Top,
				target_point = .Left_Bottom,
				offset       = {5, 5},
			}
			content(&ui, menu)
			content(&ui, {id = id("target"), layout = {sizing = {fixed(60), fixed(40)}}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	target := lookup(frame_result, id("target"))
	testing.expect_value(t, target.outer, Rect{position = {20, 20}, size = {60, 40}})

	menu := lookup(frame_result, id("menu"))
	testing.expect_value(t, menu.outer, Rect{position = {25, 65}, size = {60, 30}})
	testing.expect(t, .Missing_Overlay_Target not_in _diagnostic_kinds(&ui))
}

@(test)
test_phase3_overlay_grows_against_its_attach_target :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		host := _panel(200, 100)
		host.id = id("host")
		if element(&ui, host) {
			sheet := Element_Desc {
				id = id("sheet"),
				layout = {sizing = {grow(), percent(0.5)}},
				overlay = {attach = .Parent},
			}
			content(&ui, sheet)
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// Both modes resolve against the target's border box, not the viewport.
	testing.expect_value(t, lookup(frame_result, id("sheet")).outer, Rect{size = {200, 50}})
}

@(test)
test_phase3_fit_overlay_sizes_to_its_own_content :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		menu := Element_Desc {
			id = id("menu"),
			layout = {flow = .Column, sizing = {fit(), fit()}, padding = pad_all(4), gap = 2},
			overlay = {attach = .Root},
		}
		if element(&ui, menu) {
			content(&ui, {layout = {sizing = {fixed(90), fixed(20)}}})
			content(&ui, {layout = {sizing = {fixed(70), fixed(20)}}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// A `Fit` overlay ignores its target entirely and wraps its own content.
	testing.expect_value(t, lookup(frame_result, id("menu")).outer.size, Vec2{98, 50})
}

@(test)
test_phase3_overlay_expand_inflates_only_the_root_box :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		halo := _panel(100, 100)
		halo.id = id("halo")
		halo.overlay = {
			attach       = .Root,
			self_point   = .Left_Top,
			target_point = .Left_Top,
			expand       = {10, 5},
		}
		if element(&ui, halo) {
			content(&ui, {id = id("inside"), layout = {sizing = {fixed(20), fixed(20)}}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	testing.expect_value(t, lookup(frame_result, id("halo")).outer, Rect{position = {-10, -5}, size = {120, 110}})
	// Descendants were placed before expansion and are unaffected by it.
	testing.expect_value(t, lookup(frame_result, id("inside")).outer, Rect{size = {20, 20}})
}

@(test)
test_phase3_overlay_follows_scrolled_target :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		scroller := _panel(200, 100)
		scroller.layout.flow = .Column
		scroller.clip = {
			axes   = {.Y},
			offset = {0, 40},
		}
		if element(&ui, scroller) {
			content(&ui, {id = id("row"), layout = {sizing = {fixed(200), fixed(80)}}})
			content(&ui, {layout = {sizing = {fixed(200), fixed(80)}}})
		}
		badge := _panel(20, 20)
		badge.id = id("badge")
		badge.overlay = {
			attach       = .Element,
			target       = id("row"),
			self_point   = .Left_Top,
			target_point = .Left_Top,
		}
		content(&ui, badge)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// Attachment reads the target's final, scroll-displaced box.
	testing.expect_value(t, lookup(frame_result, id("row")).outer.position, Vec2{0, -40})
	testing.expect_value(t, lookup(frame_result, id("badge")).outer.position, Vec2{0, -40})
}

@(test)
test_phase3_overlay_clip_to_attached_parent :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		window := _panel(100, 100)
		window.clip = {
			axes = {.X, .Y},
		}
		if element(&ui, window) {
			content(&ui, {id = id("anchor"), layout = {sizing = {fixed(40), fixed(40)}}})
		}
		bounded := _panel(30, 30)
		bounded.id = id("bounded")
		bounded.overlay = {
			attach  = .Element,
			target  = id("anchor"),
			clip_to = .Attached_Parent,
		}
		content(&ui, bounded)

		free := _panel(30, 30)
		free.id = id("free")
		free.overlay = {
			attach = .Element,
			target = id("anchor"),
		}
		content(&ui, free)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	anchor := lookup(frame_result, id("anchor"))
	testing.expect_value(t, lookup(frame_result, id("bounded")).clip, anchor.clip)
	testing.expect_value(t, lookup(frame_result, id("free")).clip, Clip_Handle(0))
}

@(test)
test_phase3_missing_overlay_target_falls_back_to_root :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		if element(&ui, Element_Desc{layout = {sizing = {fixed(100), fixed(100)}, padding = pad_all(25)}}) {
			lost := Element_Desc {
				id = id("lost"),
				layout = {sizing = {grow(), fixed(10)}},
				overlay = {attach = .Element, target = id("absent"), target_point = .Center_Center, self_point = .Center_Center},
			}
			content(&ui, lost)
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect(t, .Missing_Overlay_Target in _diagnostic_kinds(&ui))

	// The fallback is the viewport, so the grow width is the viewport width.
	testing.expect_value(t, lookup(frame_result, id("lost")).outer, Rect{position = {0, 195}, size = {400, 10}})
}

@(test)
test_phase3_overlay_dependency_cycle_is_diagnosed :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		first := _panel(40, 40)
		first.id = id("first")
		first.overlay = {
			attach = .Element,
			target = id("second"),
		}
		content(&ui, first)

		second := _panel(40, 40)
		second.id = id("second")
		second.overlay = {
			attach = .Element,
			target = id("first"),
		}
		content(&ui, second)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	cycle_reports := 0
	for entry in diagnostics(&ui) {
		if entry.kind == .Overlay_Dependency_Cycle {
			cycle_reports += 1
		}
	}
	// Every root in the cycle is reported, and every one falls back to the root.
	testing.expect_value(t, cycle_reports, 2)
	testing.expect_value(t, lookup(frame_result, id("first")).outer.position, Vec2{})
	testing.expect_value(t, lookup(frame_result, id("second")).outer.position, Vec2{})
}

@(test)
test_phase3_self_referencing_overlay_is_diagnosed :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		loop := _panel(40, 40)
		loop.id = id("loop")
		loop.overlay = {
			attach = .Element,
			target = id("loop"),
			offset = {5, 5},
		}
		content(&ui, loop)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect(t, .Overlay_Dependency_Cycle in _diagnostic_kinds(&ui))
	testing.expect_value(t, lookup(frame_result, id("loop")).outer.position, Vec2{5, 5})
}

@(test)
test_phase3_cycle_does_not_detach_roots_that_only_lead_into_it :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		// `tail` depends on a cycle without being part of it, so it keeps its
		// attachment while only the two cycle members fall back.
		tail := _panel(10, 10)
		tail.id = id("tail")
		tail.overlay = {
			attach = .Element,
			target = id("cycle_a"),
		}
		content(&ui, tail)

		first := _panel(40, 40)
		first.id = id("cycle_a")
		first.overlay = {
			attach = .Element,
			target = id("cycle_b"),
			offset = {100, 100},
		}
		content(&ui, first)

		second := _panel(40, 40)
		second.id = id("cycle_b")
		second.overlay = {
			attach = .Element,
			target = id("cycle_a"),
		}
		content(&ui, second)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	cycle_reports := 0
	for entry in diagnostics(&ui) {
		if entry.kind == .Overlay_Dependency_Cycle {
			cycle_reports += 1
		}
	}
	testing.expect_value(t, cycle_reports, 2)
	testing.expect_value(t, lookup(frame_result, id("cycle_a")).outer.position, Vec2{100, 100})
	testing.expect_value(t, lookup(frame_result, id("tail")).outer.position, Vec2{100, 100})
}

@(test)
test_phase3_paint_roots_carry_absolute_layers :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		behind := _panel(50, 50)
		behind.id = id("behind")
		behind.overlay = {
			attach = .Root,
			layer  = -1,
		}
		content(&ui, behind)

		above := _panel(50, 50)
		above.id = id("above")
		above.overlay = {
			attach = .Root,
			layer  = 3,
		}
		if element(&ui, above) {
			// A nested overlay starts its own root at its own absolute layer.
			nested := _panel(10, 10)
			nested.id = id("nested")
			nested.overlay = {
				attach = .Parent,
				layer  = 1,
			}
			content(&ui, nested)
			content(&ui, {id = id("normal"), layout = {sizing = {fixed(10), fixed(10)}}})
		}
		content(&ui, {id = id("base"), layout = {sizing = {fixed(10), fixed(10)}}})
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	testing.expect_value(t, lookup(frame_result, id("base")).layer, i16(0))
	testing.expect_value(t, lookup(frame_result, id("behind")).layer, i16(-1))
	testing.expect_value(t, lookup(frame_result, id("above")).layer, i16(3))
	testing.expect_value(t, lookup(frame_result, id("nested")).layer, i16(1))
	// Descendants inherit their paint root's layer; they never create one.
	testing.expect_value(t, lookup(frame_result, id("normal")).layer, i16(3))
}

@(test)
test_phase3_hit_order_is_front_to_back :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		panel := Element_Desc {
			id = id("panel"),
			layout = {sizing = {grow(), grow()}},
		}
		if element(&ui, panel) {
			content(&ui, {id = id("earlier"), layout = {sizing = {fixed(10), fixed(10)}}})
			if element(&ui, Element_Desc{id = id("later"), layout = {sizing = {fixed(10), fixed(10)}}}) {
				content(&ui, {id = id("child"), layout = {sizing = {fixed(5), fixed(5)}}})
			}
		}
		below := _panel(20, 20)
		below.id = id("below")
		below.overlay = {
			attach = .Root,
			layer  = -2,
		}
		content(&ui, below)

		modal := _panel(20, 20)
		modal.id = id("modal")
		modal.overlay = {
			attach = .Root,
			layer  = 5,
		}
		content(&ui, modal)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	// Every node appears exactly once, sentinel excluded.
	testing.expect_value(t, len(frame_result.hit_order), len(frame_result.nodes) - 1)

	positions := [6]int {
		_hit_position(frame_result, _handle_of(frame_result, id("modal"))),
		_hit_position(frame_result, _handle_of(frame_result, id("child"))),
		_hit_position(frame_result, _handle_of(frame_result, id("later"))),
		_hit_position(frame_result, _handle_of(frame_result, id("earlier"))),
		_hit_position(frame_result, _handle_of(frame_result, id("panel"))),
		_hit_position(frame_result, _handle_of(frame_result, id("below"))),
	}
	// Highest overlay first, then descendants before ancestors and later
	// siblings before earlier ones, then the below-normal overlay last.
	for index in 1 ..< len(positions) {
		testing.expectf(t, positions[index - 1] < positions[index], "hit order %v is not front-to-back", positions)
	}
}

@(test)
test_phase3_passthrough_nodes_stay_in_hit_order :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {200, 200}) {
		container := Element_Desc {
			id = id("container"),
			layout = {sizing = {grow(), grow()}},
			hit = .Passthrough,
		}
		if element(&ui, container) {
			content(&ui, {id = id("button"), layout = {sizing = {fixed(50), fixed(20)}}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// Eligibility is a flag, not an omission: order still contains the node.
	testing.expect(t, !lookup(frame_result, id("container")).flags.hit_testable)
	testing.expect(t, lookup(frame_result, id("button")).flags.hit_testable)
	testing.expect(t, _hit_position(frame_result, _handle_of(frame_result, id("container"))) >= 0)
}

@(test)
test_phase3_clip_pool_exhaustion_fails_the_frame :: proc(t: ^testing.T) {
	config := _phase3_config()
	config.capacities.clips = 2
	ui: Context
	testing.expect_value(t, init(&ui, config), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {200, 200}) {
		first := _panel(100, 100)
		first.clip = {
			axes = {.X, .Y},
		}
		if element(&ui, first) {
			second := _panel(50, 50)
			second.clip = {
				axes = {.X, .Y},
			}
			content(&ui, second)
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.Capacity_Exhausted)
	testing.expect_value(t, len(frame_result.nodes), 0)
	testing.expect_value(t, len(frame_result.clips), 0)
	testing.expect_value(t, diagnostics(&ui)[len(diagnostics(&ui)) - 1].pool, Pool_Id.Clips)
}

@(test)
test_phase3_text_lines_follow_world_displacement :: proc(t: ^testing.T) {
	config := _phase3_config()
	services := _phase3_services()
	services.measure_text = proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
		_, _, _ = user_data, style, request
		width := Scalar(10 * len(text))
		return Measure_Result{size = {width, 20}, min_size = {width, 20}}, .None
	}
	ui: Context
	testing.expect_value(t, init(&ui, config), nil)
	defer destroy(&ui)

	set_services(&ui, services)
	if frame(&ui, {400, 400}) {
		scroller := _panel(200, 40)
		scroller.clip = {
			axes   = {.Y},
			offset = {0, 15},
		}
		if element(&ui, scroller) {
			text(&ui, Text_Desc{id = id("label"), text = "one\ntwo"})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	label := lookup(frame_result, id("label"))
	testing.expect_value(t, label.outer.position, Vec2{0, -15})
	// Line records are world-space, so they move with the block they belong to.
	state := _context_state(&ui)
	input := state._node_inputs[_handle_of(frame_result, id("label"))]
	lines := state._text_lines[input.text_line_start:input.text_line_start + input.text_line_count]
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0].position, Vec2{0, -15})
	testing.expect_value(t, lines[1].position, Vec2{0, 5})
}

@(test)
test_phase3_clip_handles_follow_root_placement_order :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	// The overlay is declared first but belongs to a later paint root, so its
	// clip entry is allocated after both normal-tree clips.
	set_services(&ui, _phase3_services())
	if frame(&ui, {400, 400}) {
		floating := _panel(60, 60)
		floating.id = id("floating")
		floating.clip = {
			axes = {.X, .Y},
		}
		floating.overlay = {
			attach = .Root,
		}
		content(&ui, floating)

		first := _panel(100, 100)
		first.id = id("first")
		first.clip = {
			axes = {.X, .Y},
		}
		if element(&ui, first) {
			second := _panel(50, 50)
			second.id = id("second")
			second.clip = {
				axes = {.X},
			}
			content(&ui, second)
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.clips), 4)

	testing.expect_value(t, frame_result.clips[1].owner, _handle_of(frame_result, id("first")))
	testing.expect_value(t, frame_result.clips[2].owner, _handle_of(frame_result, id("second")))
	testing.expect_value(t, frame_result.clips[3].owner, _handle_of(frame_result, id("floating")))
}

@(test)
test_phase3_duplicate_clip_rectangles_stay_distinct :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase3_services())
	if frame(&ui, {200, 200}) {
		outer := _panel(100, 100)
		outer.id = id("outer")
		outer.clip = {
			axes = {.X, .Y},
		}
		if element(&ui, outer) {
			inner := _panel(100, 100)
			inner.id = id("inner")
			inner.clip = {
				axes = {.X, .Y},
			}
			content(&ui, inner)
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// Identical rectangles are still two semantic entries: there is no interning.
	testing.expect_value(t, len(frame_result.clips), 3)
	testing.expect_value(t, frame_result.clips[1].rect, frame_result.clips[2].rect)
	testing.expect(t, frame_result.clips[1].owner != frame_result.clips[2].owner)
}

@(test)
test_phase3_placement_is_allocation_free_and_repeatable :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase3_config()), nil)
	defer destroy(&ui)

	build :: proc(ui: ^Context) {
		set_services(ui, _phase3_services())
		if frame(ui, {300, 300}) {
			scroller := _panel(120, 60)
			scroller.id = id("scroller")
			scroller.clip = {
				axes   = {.X, .Y},
				offset = {5, 5},
			}
			if element(ui, scroller) {
				content(ui, {id = id("wide"), layout = {sizing = {fixed(400), fixed(400)}}})
			}
			tip := _panel(30, 15)
			tip.id = id("tip")
			tip.overlay = {
				attach       = .Element,
				target       = id("scroller"),
				target_point = .Right_Bottom,
				layer        = 2,
			}
			content(ui, tip)
		}
	}

	build(&ui)
	first, first_error := result(&ui)
	testing.expect_value(t, first_error, Frame_Error.None)
	first_clips := len(first.clips)
	first_tip := lookup(first, id("tip"))
	first_order := len(first.hit_order)

	{
		context.allocator = mem.panic_allocator()
		build(&ui)
	}
	second, second_error := result(&ui)
	testing.expect_value(t, second_error, Frame_Error.None)
	// Deterministic allocation gives an identical table and identical geometry.
	testing.expect_value(t, len(second.clips), first_clips)
	testing.expect_value(t, len(second.hit_order), first_order)
	testing.expect_value(t, lookup(second, id("tip")).outer, first_tip.outer)
	testing.expect_value(t, lookup(second, id("tip")).clip, first_tip.clip)
}

@(private = "file")
_wrap_measured_bytes: int

@(test)
test_phase3_word_wrap_measurement_cost_is_linear :: proc(t: ^testing.T) {
	// Wrapping accumulates per-word advances, so the bytes handed to the
	// measurement callback grow with the text length. Measuring each candidate
	// prefix instead would remeasure every earlier word on the line, making the
	// cost grow with the square of the words per line.
	measure_bytes := proc(words: int) -> int {
		config := _phase3_config()
		config.capacities.text_lines = 4 * words + 16
		config.capacities.measure_cache = 0
		services := _phase3_services()
		services.measure_text = proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
			_, _, _ = user_data, style, request
			_wrap_measured_bytes += len(text)
			width := Scalar(10 * len(text))
			return Measure_Result{size = {width, 20}, min_size = {width, 20}}, .None
		}

		builder := make([dynamic]byte)
		defer delete(builder)
		for index in 0 ..< words {
			if index > 0 {
				append(&builder, ' ')
			}
			append(&builder, "word")
		}
		paragraph := string(builder[:])

		ui: Context
		if init(&ui, config) != nil {
			return -1
		}
		defer destroy(&ui)

		_wrap_measured_bytes = 0
		set_services(&ui, services)
		if frame(&ui, {100000, 400}) {
			text(&ui, Text_Desc{text = paragraph, style = {wrap = .Words}})
		}
		if _, err := result(&ui); err != .None {
			return -1
		}
		return _wrap_measured_bytes
	}

	// The paragraph is one line at this width, which is the worst case for
	// prefix remeasurement: every word extends the same candidate line.
	small := measure_bytes(100)
	large := measure_bytes(400)
	testing.expect(t, small > 0)
	testing.expect(t, large > 0)

	// Quadrupling the word count must not grow the work by much more than four
	// times. Prefix remeasurement grew it by roughly sixteen.
	testing.expect(t, large <= small * 6, "word-wrap measurement cost is superlinear in the number of words")
}

@(test)
test_phase3_measure_cache_distinguishes_runs_by_offset :: proc(t: ^testing.T) {
	// The cache key names a run by its offset and length inside the node's text
	// rather than by hashing the run's bytes, so the offset must stay in the key.
	// This measurer exposes it being dropped: width depends on the run's first
	// byte, so "bb" is three times wider than the equal-length "aa" around it.
	config := _phase3_config()
	services := _phase3_services()
	services.measure_text = proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
		_, _, _ = user_data, style, request
		per_character := Scalar(10)
		if len(text) > 0 && text[0] == 'b' {
			per_character = 30
		}
		width := Scalar(len(text)) * per_character
		return Measure_Result{size = {width, 20}, min_size = {width, 20}}, .None
	}
	ui: Context
	testing.expect_value(t, init(&ui, config), nil)
	defer destroy(&ui)

	set_services(&ui, services)
	if frame(&ui, {100, 400}) {
		if element(&ui, {layout = {flow = .Column, sizing = {grow(), grow()}}}) {
			text(
				&ui,
				Text_Desc{id = id("offsets"), text = "aa bb aa", style = {size = 16, color = {255, 255, 255, 255}, wrap = .Words}, sizing = {grow(), fit()}},
			)
		}
	}

	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	state := _context_state(&ui)
	input := state._node_inputs[_handle_of(frame_result, id("offsets"))]
	lines := state._text_lines[input.text_line_start:input.text_line_start + input.text_line_count]

	// Wrapping accumulates advances: "aa" is 20, the separator 10, and "bb" 60,
	// so the line reaches 90 of the 100 available and the trailing "aa" wraps.
	// Were the middle word keyed as the "aa" at another offset it would measure
	// 20 rather than 60, and all three words would fit on one line.
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0].text, "aa bb")
	testing.expect_value(t, lines[1].text, "aa")
}

@(test)
test_phase3_measure_cache_distinguishes_runs_by_style :: proc(t: ^testing.T) {
	// Two nodes with identical text, so identical offsets and lengths. Only the
	// style differs, so the node's own identity must be part of the key.
	config := _phase3_config()
	services := _phase3_services()
	services.measure_text = proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
		_, _ = user_data, request
		size := style.size if style.size > 0 else 16
		width := Scalar(f64(len(text)) * 10.0 * f64(size) / 16.0)
		return Measure_Result{size = {width, 20}, min_size = {width, 20}}, .None
	}
	ui: Context
	testing.expect_value(t, init(&ui, config), nil)
	defer destroy(&ui)

	set_services(&ui, services)
	if frame(&ui, {400, 400}) {
		if element(&ui, {layout = {flow = .Column, sizing = {grow(), grow()}}}) {
			text(&ui, Text_Desc{id = id("small"), text = "aa bb", style = {size = 16, color = {255, 255, 255, 255}, wrap = .Words}, sizing = {fit(), fit()}})
			text(&ui, Text_Desc{id = id("large"), text = "aa bb", style = {size = 32, color = {255, 255, 255, 255}, wrap = .Words}, sizing = {fit(), fit()}})
		}
	}

	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	small := lookup(frame_result, id("small"))
	large := lookup(frame_result, id("large"))
	// Reusing the smaller node's cached runs would make these equal.
	testing.expect_value(t, small.inner.size.x, Scalar(50))
	testing.expect_value(t, large.inner.size.x, Scalar(100))
}

@(test)
test_phase3_word_records_match_the_measuring_path :: proc(t: ^testing.T) {
	// Wrapping has two implementations: one that reuses the advances recorded
	// during intrinsic sizing, and one that measures words itself when no word
	// pool is configured or the pool overflowed. They must publish identical
	// geometry, so this drives both over the same inputs and compares.
	measure :: proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
		_, _ = user_data, request
		// Per-character widths vary so a word's identity, not just its length,
		// affects the result.
		width: f64
		lines := 1
		for index in 0 ..< len(text) {
			if text[index] == '\n' {
				lines += 1
				continue
			}
			width += 4.0 + f64(text[index] % 7)
		}
		size := style.size if style.size > 0 else 16
		scale := f64(size) / 16.0
		return Measure_Result {
				size = {Scalar(width * scale), Scalar(f64(lines) * 16.0 * scale)},
				min_size = {Scalar(width * scale), Scalar(f64(lines) * 16.0 * scale)},
			},
			.None
	}

	samples := [?]string {
		"",
		" ",
		"\n",
		"hello world",
		"hello  world",
		"  leading",
		"trailing  ",
		"one\ntwo",
		"one\n\ntwo",
		"a\r\nb",
		"\n\n\n",
		"word\n",
		"\nword",
		"the quick brown fox jumps over the lazy dog again and again",
	}
	widths := [?]Scalar{20, 45, 90, 160, 400}
	wraps := [?]Wrap{.Words, .Newlines, .None}

	for sample in samples {
		for width in widths {
			for wrap in wraps {
				build :: proc(
					word_capacity: int,
					sample: string,
					width: Scalar,
					wrap: Wrap,
					measurer: Text_Measure_Proc,
				) -> (
					[]Render_Command,
					Frame_Error,
					Context,
				) {
					config := _phase3_config()
					config.capacities.measured_words = word_capacity
					services := _phase3_services()
					services.measure_text = measurer
					ui: Context
					if init(&ui, config) != nil {
						return nil, .Not_Initialized, ui
					}
					set_services(&ui, services)
					if frame(&ui, {width, 4000}) {
						if element(&ui, {layout = {flow = .Column, sizing = {grow(), grow()}}}) {
							text(&ui, Text_Desc{text = sample, style = {size = 16, color = {255, 255, 255, 255}, wrap = wrap}, sizing = {grow(), fit()}})
						}
					}
					frame_result, err := result(&ui)
					return frame_result.commands, err, ui
				}

				// 512 records is ample; 0 disables recording and forces the
				// measuring path.
				fast_commands, fast_err, fast_ui := build(512, sample, width, wrap, measure)
				slow_commands, slow_err, slow_ui := build(0, sample, width, wrap, measure)
				defer destroy(&fast_ui)
				defer destroy(&slow_ui)

				testing.expect_value(t, fast_err, slow_err)
				testing.expect_value(t, len(fast_commands), len(slow_commands))
				if len(fast_commands) != len(slow_commands) {
					continue
				}
				for index in 0 ..< len(fast_commands) {
					testing.expect_value(t, fast_commands[index].bounds, slow_commands[index].bounds)
					fast_text, fast_is_text := fast_commands[index].data.(Text_Cmd)
					slow_text, slow_is_text := slow_commands[index].data.(Text_Cmd)
					testing.expect_value(t, fast_is_text, slow_is_text)
					if fast_is_text && slow_is_text {
						testing.expect_value(t, fast_text.text, slow_text.text)
						testing.expect_value(t, fast_text.line, slow_text.line)
					}
				}
			}
		}
	}
}
