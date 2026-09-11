#+test
#+private file
package layout

import "core:testing"

_handle_of :: proc(frame_result: Frame_Result, identifier: Id) -> Node_Handle {
	for entry in frame_result.id_index {
		if entry.id == identifier {
			return entry.node
		}
	}
	return 0
}

_panel :: proc(width, height: Scalar) -> Element_Desc {
	return Element_Desc{layout = {sizing = {fixed(width), fixed(height)}}}
}

_diagnostic_kinds :: proc(ctx: ^Context) -> bit_set[Diagnostic_Kind] {
	kinds: bit_set[Diagnostic_Kind]
	for entry in diagnostics(ctx) {
		kinds += {entry.kind}
	}
	return kinds
}

@(test)
test_clip_intersection_and_scroll_displacement :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	// An inner clip that reaches past its clipping ancestor is cut down to the
	// intersection, and a clipping element is itself bounded by its ancestors.
	if frame(&ctx, {200, 200}) {
		outer := _panel(100, 100)
		outer.id = id("outer")
		outer.layout.padding = pad_all(10)
		outer.clip = {
			axes = {.X, .Y},
		}
		if element(&ctx, outer) {
			inner := _panel(200, 200)
			inner.id = id("inner")
			inner.clip = {
				axes = {.X, .Y},
			}
			if element(&ctx, inner) {
				content(&ctx, {id = id("leaf"), layout = {sizing = {fixed(10), fixed(10)}}})
			}
		}
	}
	frame_result, err := result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.clips), 3)
	testing.expect_value(t, frame_result.clips[1].owner, Node_Handle(1))
	testing.expect_value(t, frame_result.clips[1].parent, Clip_Handle(0))
	testing.expect_value(t, frame_result.clips[1].rect, Rect{position = {10, 10}, size = {80, 80}})
	testing.expect_value(t, lookup(frame_result, id("outer")).clip, Clip_Handle(0))
	testing.expect_value(t, lookup(frame_result, id("leaf")).clip, Clip_Handle(2))

	// An axis-specific clip constrains only that axis.
	if frame(&ctx, {300, 300}) {
		scroller := _panel(100, 50)
		scroller.id = id("scroller")
		scroller.clip = {
			axes = {.Y},
		}
		if element(&ctx, scroller) {
			content(&ctx, {id = id("tall"), layout = {sizing = {fixed(100), fixed(400)}}})
		}
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, frame_result.clips[1].axes, Axis_Set{.Y})
	testing.expect_value(t, frame_result.clips[1].rect, Rect{size = {300, 50}})

	// An empty clip hides descendants without changing their geometry.
	if frame(&ctx, {200, 200}) {
		collapsed := _panel(0, 0)
		collapsed.id = id("collapsed")
		collapsed.clip = {
			axes = {.X, .Y},
		}
		if element(&ctx, collapsed) {
			content(&ctx, {id = id("hidden"), layout = {sizing = {fixed(50), fixed(50)}}})
		}
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	hidden := lookup(frame_result, id("hidden"))
	testing.expect(t, !hidden.flags.visible)
	testing.expect_value(t, hidden.outer.size, Vec2{50, 50})

	// The clipping element never moves; the offset displaces its descendants
	// and exposes the legal range.
	if frame(&ctx, {300, 300}) {
		scroller := _panel(100, 100)
		scroller.id = id("scroller")
		scroller.layout.flow = .Column
		scroller.clip = {
			axes   = {.Y},
			offset = {0, 30},
		}
		if element(&ctx, scroller) {
			content(&ctx, {id = id("first"), layout = {sizing = {fixed(100), fixed(80)}}})
			content(&ctx, {id = id("second"), layout = {sizing = {fixed(100), fixed(80)}}})
		}
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	scroller := lookup(frame_result, id("scroller"))
	testing.expect_value(t, scroller.scroll_range, Vec2{0, 60})
	testing.expect_value(t, scroller.scroll_offset, Vec2{0, 30})
	testing.expect_value(t, lookup(frame_result, id("first")).outer.position, Vec2{0, -30})
	testing.expect_value(t, lookup(frame_result, id("second")).outer.position, Vec2{0, 50})
	testing.expect(t, .Overflow not_in _diagnostic_kinds(&ctx))

	// An offset outside the legal range is applied exactly and reported, never
	// clamped by the core.
	if frame(&ctx, {300, 300}) {
		scroller := _panel(100, 100)
		scroller.id = id("scroller")
		scroller.clip = {
			axes   = {.Y},
			offset = {0, 500},
		}
		if element(&ctx, scroller) {
			content(&ctx, {id = id("child"), layout = {sizing = {fixed(100), fixed(120)}}})
		}
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, lookup(frame_result, id("child")).outer.position, Vec2{0, -500})
	testing.expect(t, .Overflow in _diagnostic_kinds(&ctx))
}

@(test)
test_overlays_layers_and_attachment :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	// An overlay consumes no normal-flow space but remains a lexical child,
	// and its Grow/Percent sizes resolve against the attach target.
	if frame(&ctx, {400, 400}) {
		if element(&ctx, {layout = {sizing = {grow(), fixed(100)}}}) {
			content(&ctx, {id = id("left"), layout = {sizing = {grow(), grow()}}})
			overlay := Element_Desc {
				id = id("overlay"),
				layout = {sizing = {grow(), percent(0.5)}},
				overlay = {attach = .Parent},
			}
			content(&ctx, overlay)
			content(&ctx, {id = id("right"), layout = {sizing = {grow(), grow()}}})
		}
	}
	frame_result, err := result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, lookup(frame_result, id("left")).outer, Rect{size = {200, 100}})
	testing.expect_value(t, lookup(frame_result, id("right")).outer, Rect{position = {200, 0}, size = {200, 100}})
	// Grow against the target makes the overlay fill it; Percent(0.5) on the
	// cross axis resolves against the same box.
	testing.expect_value(t, lookup(frame_result, id("overlay")).outer, Rect{size = {400, 50}})
	testing.expect(t, lookup(frame_result, id("overlay")).flags.is_overlay)
	testing.expect_value(t, frame_result.nodes[1].child_count, u16(3))

	// Attachment reads the target's final box, and a forward reference resolves
	// after declaration closes. Expand inflates only the root's box.
	if frame(&ctx, {400, 400}) {
		anchor := _panel(100, 40)
		anchor.id = id("anchor")
		anchor.layout.padding = pad_all(20)
		if element(&ctx, anchor) {
			menu := _panel(60, 30)
			menu.id = id("menu")
			menu.overlay = {
				attach       = .Element,
				target       = id("target"),
				self_point   = .Left_Top,
				target_point = .Left_Bottom,
				offset       = {5, 5},
				expand       = {10, 5},
			}
			content(&ctx, menu)
			content(&ctx, {id = id("target"), layout = {sizing = {fixed(60), fixed(40)}}})
		}
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, lookup(frame_result, id("target")).outer, Rect{position = {20, 20}, size = {60, 40}})
	testing.expect_value(t, lookup(frame_result, id("menu")).outer, Rect{position = {15, 60}, size = {80, 40}})

	// A missing target falls back to the viewport and is diagnosed.
	if frame(&ctx, {400, 400}) {
		lost := Element_Desc {
			id = id("lost"),
			layout = {sizing = {grow(), fixed(10)}},
			overlay = {attach = .Element, target = id("absent")},
		}
		content(&ctx, lost)
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect(t, .Missing_Overlay_Target in _diagnostic_kinds(&ctx))
	testing.expect_value(t, lookup(frame_result, id("lost")).outer.size.x, 400)

	// Every root in a dependency cycle is diagnosed and falls back to the
	// viewport; a root that merely leads into the cycle keeps its attachment.
	if frame(&ctx, {400, 400}) {
		tail := _panel(10, 10)
		tail.id = id("tail")
		tail.overlay = {
			attach = .Element,
			target = id("cycle_a"),
		}
		content(&ctx, tail)

		first := _panel(40, 40)
		first.id = id("cycle_a")
		first.overlay = {
			attach = .Element,
			target = id("cycle_b"),
			offset = {100, 100},
		}
		content(&ctx, first)

		second := _panel(40, 40)
		second.id = id("cycle_b")
		second.overlay = {
			attach = .Element,
			target = id("cycle_a"),
		}
		content(&ctx, second)
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, lookup(frame_result, id("cycle_a")).outer.position, Vec2{100, 100})
	testing.expect_value(t, lookup(frame_result, id("tail")).outer.position, Vec2{100, 100})

	// A root declared first but placed later gets its clip entry later, and a
	// root's layer is absolute while its descendants inherit it.
	if frame(&ctx, {400, 400}) {
		floating := _panel(60, 60)
		floating.id = id("floating")
		floating.clip = {
			axes = {.X, .Y},
		}
		floating.overlay = {
			attach = .Root,
			layer  = -1,
		}
		content(&ctx, floating)

		above := _panel(50, 50)
		above.id = id("above")
		above.overlay = {
			attach = .Root,
			layer  = 3,
		}
		if element(&ctx, above) {
			nested := _panel(10, 10)
			nested.id = id("nested")
			nested.overlay = {
				attach = .Parent,
				layer  = 1,
			}
			content(&ctx, nested)
			content(&ctx, {id = id("normal"), layout = {sizing = {fixed(10), fixed(10)}}})
		}

		first := _panel(100, 100)
		first.id = id("first")
		first.clip = {
			axes = {.X, .Y},
		}
		if element(&ctx, first) {
			second := _panel(50, 50)
			second.id = id("second")
			second.clip = {
				axes = {.X},
			}
			content(&ctx, second)
		}
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, lookup(frame_result, id("floating")).layer, i16(-1))
	testing.expect_value(t, lookup(frame_result, id("above")).layer, i16(3))
	testing.expect_value(t, lookup(frame_result, id("nested")).layer, i16(1))
	testing.expect_value(t, lookup(frame_result, id("normal")).layer, i16(3))
	testing.expect_value(t, len(frame_result.clips), 4)
	testing.expect_value(t, frame_result.clips[1].owner, _handle_of(frame_result, id("first")))
	testing.expect_value(t, frame_result.clips[3].owner, _handle_of(frame_result, id("floating")))
}
