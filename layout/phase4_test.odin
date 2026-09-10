#+test
#+private file
package layout

import "core:math"
import "core:mem"
import "core:slice"
import "core:testing"

GLYPH_WIDTH :: Scalar(10)
GLYPH_HEIGHT :: Scalar(20)

_measure_monospace :: proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	_, _, _ = user_data, style, request
	width := GLYPH_WIDTH * Scalar(len(text))
	return Measure_Result{size = {width, GLYPH_HEIGHT}, min_size = {width, GLYPH_HEIGHT}, baseline = GLYPH_HEIGHT * 0.8}, .None
}

_phase4_services :: proc() -> Services {
	return Services{measure_text = _measure_monospace, break_text = _ascii_break_fixture}
}

_phase4_config :: proc() -> Options {
	return Options {
		capacities = {
			nodes = 64,
			children = 64,
			clips = 16,
			commands = 128,
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

_expect_close :: proc(t: ^testing.T, actual, expected: Scalar, loc := #caller_location) {
	testing.expectf(t, math.abs(actual - expected) <= SCALAR_TOLERANCE, "expected %.6f, got %.6f", expected, actual, loc = loc)
}

_command_kinds :: proc(frame_result: Frame_Result, allocator := context.allocator) -> []string {
	kinds := make([]string, len(frame_result.commands), allocator)
	for command, index in frame_result.commands {
		switch _ in command.data {
		case Fill_Cmd:
			kinds[index] = "fill"
		case Border_Cmd:
			kinds[index] = "border"
		case Text_Cmd:
			kinds[index] = "text"
		case Image_Cmd:
			kinds[index] = "image"
		case Custom_Cmd:
			kinds[index] = "custom"
		}
	}
	return kinds
}

_handle_of :: proc(frame_result: Frame_Result, identifier: Id) -> Node_Handle {
	for entry in frame_result.id_index {
		if entry.id == identifier {
			return entry.node
		}
	}
	return 0
}

@(test)
test_phase4_intra_node_command_order :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	// A node paints its own surface, then its content, then its children, and
	// closes with its border so descendant overdraw cannot eat the edge.
	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		parent := _panel(120, 120)
		parent.id = id("parent")
		parent.paint = {
			background = {10, 10, 10, 255},
			border = {color = {200, 200, 200, 255}, width = pad_all(2)},
		}
		parent.content = Custom_Content {
			kind = Custom_Kind(7),
		}
		if element(&ui, parent) {
			child := _panel(40, 40)
			child.paint.background = {80, 80, 80, 255}
			content(&ui, child)
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	kinds := _command_kinds(frame_result, context.temp_allocator)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, len(kinds), 4)
	testing.expect_value(t, kinds[0], "fill")
	testing.expect_value(t, kinds[1], "custom")
	testing.expect_value(t, kinds[2], "fill")
	testing.expect_value(t, kinds[3], "border")
}

@(test)
test_phase4_zero_alpha_and_zero_width_emit_nothing :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		transparent := _panel(50, 50)
		transparent.paint = {
			background = {255, 255, 255, 0},
			border = {color = {255, 0, 0, 255}},
		}
		content(&ui, transparent)

		invisible_border := _panel(50, 50)
		invisible_border.paint.border = {
			color = {255, 0, 0, 0},
			width = pad_all(4),
		}
		content(&ui, invisible_border)

		hidden_text := Text_Desc {
			text = "hidden",
			style = {size = 10, color = {255, 255, 255, 0}},
		}
		text(&ui, hidden_text)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 0)
}

@(test)
test_phase4_empty_custom_content_obeys_the_selected_cull_policy :: proc(t: ^testing.T) {
	all_ui: Context
	testing.expect_value(t, init(&all_ui, _phase4_config()), nil)
	defer destroy(&all_ui)

	visible_config := _phase4_config()
	visible_config.cull = .Visible
	visible_ui: Context
	testing.expect_value(t, init(&visible_ui, visible_config), nil)
	defer destroy(&visible_ui)

	build := proc(ui: ^Context) {
		set_services(ui, _phase4_services())
		if frame(ui, {200, 200}) {
			box := _panel(0, 0)
			box.content = Custom_Content {
				kind = Custom_Kind(7),
			}
			content(ui, box)
		}
	}
	build(&all_ui)
	build(&visible_ui)

	all_result, all_err := result(&all_ui)
	visible_result, visible_err := result(&visible_ui)
	testing.expect_value(t, all_err, Frame_Error.None)
	testing.expect_value(t, visible_err, Frame_Error.None)

	// Custom content is application-defined, so an empty box remains meaningful
	// under `.All`. `.Visible` still removes it because culling is bounds-based.
	testing.expect_value(t, len(all_result.commands), 1)
	_, is_custom := all_result.commands[0].data.(Custom_Cmd)
	testing.expect(t, is_custom)
	testing.expect_value(t, all_result.commands[0].bounds.size, Vec2{})
	testing.expect_value(t, len(visible_result.commands), 0)
}

@(test)
test_phase4_zero_custom_kind_still_emits_a_command :: proc(t: ^testing.T) {
	// `Custom_Kind(0)` is a valid application-defined discriminator, not a
	// suppression signal: absence of custom content is already expressed by the
	// nilable `Content` union carrying no `Custom_Content` variant. Declaring
	// the variant is therefore sufficient to emit, unlike a zero `Image_Handle`
	// which names no image and so cannot be drawn.
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		box := _panel(40, 30)
		box.content = Custom_Content {
			kind = Custom_Kind(0),
			data = nil,
		}
		content(&ui, box)
	}

	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 1)

	custom, is_custom := frame_result.commands[0].data.(Custom_Cmd)
	testing.expect(t, is_custom)
	testing.expect_value(t, custom.kind, Custom_Kind(0))
	testing.expect(t, custom.data == nil)
	testing.expect_value(t, frame_result.commands[0].bounds.size, Vec2{40, 30})
}

@(test)
test_phase4_text_emits_one_command_per_line :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		box := Element_Desc {
			id = id("box"),
			layout = {sizing = {fixed(60), fit()}},
		}
		if element(&ui, box) {
			text(&ui, {text = "aaa bbb ccc", style = {size = 10, color = {255, 255, 255, 255}, wrap = .Words}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	expected := [3]string{"aaa", "bbb", "ccc"}
	lines := 0
	previous_index := u16(0)
	for command in frame_result.commands {
		data, is_text := command.data.(Text_Cmd)
		if !is_text {
			continue
		}
		testing.expect_value(t, data.line, previous_index)
		testing.expect_value(t, data.text, expected[lines])
		_expect_close(t, command.bounds.size.x, GLYPH_WIDTH * 3)
		_expect_close(t, command.bounds.position.y, GLYPH_HEIGHT * Scalar(lines))
		previous_index += 1
		lines += 1
	}
	testing.expect_value(t, lines, 3)
}

@(test)
test_phase4_between_children_fills_each_gap :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	// The rule is centred in the gap the children left and never widens it, so
	// three children produce exactly two rules inside the same 8-unit gaps.
	set_services(&ui, _phase4_services())
	if frame(&ui, {300, 200}) {
		row := Element_Desc {
			id = id("row"),
			layout = {flow = .Row, sizing = {fixed(300), fixed(100)}, gap = 8},
			paint = {border = {color = {255, 255, 255, 255}, between_children = 2}},
		}
		if element(&ui, row) {
			for _ in 0 ..< 3 {
				content(&ui, _panel(40, 40))
			}
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	rules: [dynamic]Render_Command
	defer delete(rules)
	for command in frame_result.commands {
		if _, is_fill := command.data.(Fill_Cmd); is_fill {
			append(&rules, command)
		}
	}
	testing.expect_value(t, len(rules), 2)
	for rule, index in rules {
		_expect_close(t, rule.bounds.size.x, 2)
		_expect_close(t, rule.bounds.size.y, 100)
		// Gap n spans [40n + 8(n-1), 40n + 8n); its centred 2-wide rule starts 3 in.
		_expect_close(t, rule.bounds.position.x, Scalar(40 * (index + 1) + 8 * index + 3))
	}
}

@(test)
test_phase4_between_children_clamps_to_gap :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase4_services())
	if frame(&ui, {300, 200}) {
		column := Element_Desc {
			id = id("column"),
			layout = {flow = .Column, sizing = {fixed(100), fixed(200)}, gap = 4},
			paint = {border = {color = {255, 255, 255, 255}, between_children = 40}},
		}
		if element(&ui, column) {
			content(&ui, _panel(40, 40))
			content(&ui, _panel(40, 40))
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 1)
	_expect_close(t, frame_result.commands[0].bounds.size.y, 4)
	_expect_close(t, frame_result.commands[0].bounds.position.y, 40)
}

@(test)
test_phase4_radius_and_border_are_proportionally_reduced :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	// Every side sums to 200 on a 100-unit box, so one common factor of 0.5
	// applies and the authored 3:1 ratio survives. Border widths overflow only
	// horizontally (120 over 100), yet the same single factor of 5/6 scales the
	// vertical widths too — that is what makes it one factor rather than four.
	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		box := _panel(100, 100)
		box.paint = {
			background = {255, 255, 255, 255},
			radius = {tl = 150, tr = 50, br = 150, bl = 50},
			border = {color = {255, 0, 0, 255}, width = {left = 90, right = 30, top = 12, bottom = 12}},
		}
		content(&ui, box)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 2)

	fill := frame_result.commands[0].data.(Fill_Cmd)
	_expect_close(t, fill.radius.tl, 75)
	_expect_close(t, fill.radius.tr, 25)
	_expect_close(t, fill.radius.br, 75)
	_expect_close(t, fill.radius.bl, 25)

	border := frame_result.commands[1].data.(Border_Cmd)
	_expect_close(t, border.width.left, 75)
	_expect_close(t, border.width.right, 25)
	_expect_close(t, border.width.top, 10)
	_expect_close(t, border.width.bottom, 10)
}

@(test)
test_phase4_image_source_and_tint_are_normalized :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	// A flipped, out-of-range UV rectangle becomes the positive region it
	// overlaps, and a disabled tint is republished as the identity multiplier.
	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		box := _panel(100, 100)
		box.content = Image_Content {
			handle = Image_Handle(3),
			source = {mode = .Normalized, uv = {position = {0.75, 1.5}, size = {-0.5, -2}}},
		}
		content(&ui, box)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 1)

	image := frame_result.commands[0].data.(Image_Cmd)
	testing.expect_value(t, image.tint, Color{255, 255, 255, 255})
	_expect_close(t, image.source.uv.position.x, 0.25)
	_expect_close(t, image.source.uv.size.x, 0.5)
	_expect_close(t, image.source.uv.position.y, 0)
	_expect_close(t, image.source.uv.size.y, 1)
}

@(test)
test_phase4_image_omitted_for_empty_source_or_handle :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		no_handle := _panel(50, 50)
		no_handle.content = Image_Content {
			handle = Image_Handle(0),
		}
		content(&ui, no_handle)

		empty_source := _panel(50, 50)
		empty_source.content = Image_Content {
			handle = Image_Handle(1),
			source = {mode = .Normalized, uv = {position = {0.5, 0}, size = {0, 1}}},
		}
		content(&ui, empty_source)

		clear_tint := _panel(50, 50)
		clear_tint.content = Image_Content {
			handle = Image_Handle(1),
			tint = {enabled = true, color = {255, 255, 255, 0}},
		}
		content(&ui, clear_tint)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 0)
}

@(test)
test_phase4_commands_follow_paint_root_order :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	// A negative-layer overlay paints before the normal root; a layer-0 overlay
	// paints after it, because the normal root was registered first.
	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		normal := _panel(100, 100)
		normal.id = id("normal")
		normal.paint.background = {1, 1, 1, 255}
		content(&ui, normal)

		behind := _panel(50, 50)
		behind.id = id("behind")
		behind.paint.background = {2, 2, 2, 255}
		behind.overlay = {
			attach = .Root,
			layer  = -1,
		}
		content(&ui, behind)

		above := _panel(50, 50)
		above.id = id("above")
		above.paint.background = {3, 3, 3, 255}
		above.overlay = {
			attach = .Root,
			layer  = 0,
		}
		content(&ui, above)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 3)
	testing.expect_value(t, frame_result.commands[0].layer, i16(-1))
	testing.expect_value(t, frame_result.commands[0].node, _handle_of(frame_result, id("behind")))
	testing.expect_value(t, frame_result.commands[1].node, _handle_of(frame_result, id("normal")))
	testing.expect_value(t, frame_result.commands[2].node, _handle_of(frame_result, id("above")))
}

@(test)
test_phase4_roots_are_atomic_in_the_command_stream :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	// The overlay is declared in the middle of the parent's children, so an
	// interleaving emitter would split the normal root around it.
	set_services(&ui, _phase4_services())
	if frame(&ui, {300, 300}) {
		parent := _panel(200, 200)
		parent.id = id("parent")
		parent.paint.background = {1, 1, 1, 255}
		if element(&ui, parent) {
			first := _panel(20, 20)
			first.paint.background = {2, 2, 2, 255}
			content(&ui, first)

			floating := _panel(20, 20)
			floating.paint.background = {3, 3, 3, 255}
			floating.overlay = {
				attach = .Parent,
				layer  = 5,
			}
			content(&ui, floating)

			last := _panel(20, 20)
			last.paint.background = {4, 4, 4, 255}
			content(&ui, last)
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 4)
	for command, index in frame_result.commands {
		expected := i16(5) if index == 3 else i16(0)
		testing.expect_value(t, command.layer, expected)
	}
}

@(test)
test_phase4_commands_carry_the_owning_clip :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	// The clipping element's own paint belongs to the surface its ancestors
	// allowed, so only its descendants carry the new handle.
	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		clipper := _panel(100, 100)
		clipper.id = id("clipper")
		clipper.paint.background = {1, 1, 1, 255}
		clipper.clip = {
			axes = {.X, .Y},
		}
		if element(&ui, clipper) {
			child := _panel(50, 50)
			child.paint.background = {2, 2, 2, 255}
			content(&ui, child)
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 2)
	testing.expect_value(t, frame_result.commands[0].clip, Clip_Handle(0))
	testing.expect_value(t, frame_result.commands[1].clip, Clip_Handle(1))
	testing.expect_value(t, clip_of(frame_result, Clip_Handle(1)).owner, _handle_of(frame_result, id("clipper")))
}

@(test)
test_phase4_cull_visible_is_a_subsequence_with_identical_nodes :: proc(t: ^testing.T) {
	all_ui: Context
	testing.expect_value(t, init(&all_ui, _phase4_config()), nil)
	defer destroy(&all_ui)

	culled_config := _phase4_config()
	culled_config.cull = .Visible
	culled_ui: Context
	testing.expect_value(t, init(&culled_ui, culled_config), nil)
	defer destroy(&culled_ui)

	build :: proc(ui: ^Context) {
		set_services(ui, _phase4_services())
		if frame(ui, {200, 200}) {
			clipper := _panel(100, 40)
			clipper.id = id("clipper")
			clipper.clip = {
				axes = {.X, .Y},
			}
			if element(ui, clipper) {
				column := Element_Desc {
					id = id("column"),
					layout = {flow = .Column, sizing = {fixed(100), fit()}},
				}
				if element(ui, column) {
					for index in 0 ..< 6 {
						row := _panel(100, 40)
						row.id = id_index("row", u64(index))
						row.paint.background = {u8(index), 0, 0, 255}
						content(ui, row)
					}
				}
			}
		}
	}
	build(&all_ui)
	build(&culled_ui)

	all_result, all_err := result(&all_ui)
	culled_result, culled_err := result(&culled_ui)
	testing.expect_value(t, all_err, Frame_Error.None)
	testing.expect_value(t, culled_err, Frame_Error.None)

	testing.expect_value(t, len(all_result.commands), 6)
	testing.expect(t, len(culled_result.commands) < len(all_result.commands))
	testing.expect_value(t, len(culled_result.nodes), len(all_result.nodes))
	for entry, index in all_result.nodes {
		testing.expect_value(t, entry.outer, culled_result.nodes[index].outer)
		testing.expect_value(t, entry.clip, culled_result.nodes[index].clip)
	}

	// Subsequence: every culled command appears in the full stream, in order.
	position := 0
	for command in culled_result.commands {
		for position < len(all_result.commands) && all_result.commands[position].node != command.node {
			position += 1
		}
		testing.expect(t, position < len(all_result.commands))
		position += 1
	}
}

@(test)
test_phase4_visible_commands_filters_without_touching_nodes :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase4_services())
	if frame(&ui, {400, 400}) {
		column := Element_Desc {
			id = id("column"),
			layout = {flow = .Column, sizing = {fixed(100), fit()}},
		}
		if element(&ui, column) {
			for index in 0 ..< 4 {
				row := _panel(100, 100)
				row.id = id_index("row", u64(index))
				row.paint.background = {255, 255, 255, 255}
				content(&ui, row)
			}
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 4)

	iterator := visible_commands(frame_result, Rect{position = {0, 0}, size = {100, 150}})
	seen := 0
	last_index := -1
	for command, index in next_command(&iterator) {
		testing.expect(t, index > last_index)
		last_index = index
		testing.expect_value(t, command.bounds.position.y, Scalar(100 * seen))
		seen += 1
	}
	testing.expect_value(t, seen, 2)
	testing.expect_value(t, len(frame_result.commands), 4)

	empty_iterator := visible_commands(frame_result, Rect{position = {0, 0}, size = {0, 150}})
	empty_count := 0
	for _ in next_command(&empty_iterator) {
		empty_count += 1
	}
	testing.expect_value(t, empty_count, 0)
}

@(test)
test_phase4_hit_test_returns_the_front_most_eligible_node :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		background := _panel(200, 200)
		background.id = id("background")
		if element(&ui, background) {
			child := _panel(100, 100)
			child.id = id("child")
			content(&ui, child)
		}
		floating := _panel(50, 50)
		floating.id = id("floating")
		floating.overlay = {
			attach = .Root,
			layer  = 1,
		}
		content(&ui, floating)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	front, hit := hit_test(frame_result, {10, 10})
	testing.expect(t, hit)
	testing.expect_value(t, front.id, id("floating"))

	inner, inner_hit := hit_test(frame_result, {80, 80})
	testing.expect(t, inner_hit)
	testing.expect_value(t, inner.id, id("child"))

	outer, outer_hit := hit_test(frame_result, {150, 150})
	testing.expect(t, outer_hit)
	testing.expect_value(t, outer.id, id("background"))

	_, missed := hit_test(frame_result, {400, 400})
	testing.expect(t, !missed)
}

@(test)
test_phase4_hit_test_skips_passthrough_and_clipped_nodes :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	// The child is laid out inside its parent but scrolled out of the clip, so
	// it stays in `hit_order` and is rejected by the clip test alone.
	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		clipper := _panel(100, 40)
		clipper.id = id("clipper")
		clipper.hit = .Passthrough
		clipper.clip = {
			axes   = {.Y},
			offset = {0, 40},
		}
		if element(&ui, clipper) {
			column := Element_Desc {
				id = id("column"),
				layout = {flow = .Column, sizing = {fixed(100), fit()}},
			}
			if element(&ui, column) {
				first := _panel(100, 40)
				first.id = id("first")
				content(&ui, first)
				second := _panel(100, 40)
				second.id = id("second")
				content(&ui, second)
			}
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	clipper_handle := _handle_of(frame_result, id("clipper"))
	testing.expect(t, slice.contains(frame_result.hit_order, clipper_handle))
	testing.expect(t, !frame_result.nodes[clipper_handle].flags.hit_testable)

	front, hit := hit_test(frame_result, {50, 20})
	testing.expect(t, hit)
	testing.expect_value(t, front.id, id("second"))
}

@(test)
test_phase4_hit_stack_is_front_to_back_and_opaque_terminates :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		background := _panel(200, 200)
		background.id = id("background")
		if element(&ui, background) {
			middle := _panel(150, 150)
			middle.id = id("middle")
			if element(&ui, middle) {
				front := _panel(100, 100)
				front.id = id("front")
				content(&ui, front)
			}
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	storage: [8]Node_Handle
	stack, complete := hit_stack(frame_result, {50, 50}, storage[:])
	testing.expect_value(t, len(stack), 3)
	testing.expect(t, complete)
	testing.expect_value(t, frame_result.nodes[stack[0]].id, id("front"))
	testing.expect_value(t, frame_result.nodes[stack[1]].id, id("middle"))
	testing.expect_value(t, frame_result.nodes[stack[2]].id, id("background"))

	modal_ui: Context
	testing.expect_value(t, init(&modal_ui, _phase4_config()), nil)
	defer destroy(&modal_ui)
	set_services(&modal_ui, _phase4_services())
	if frame(&modal_ui, {200, 200}) {
		background := _panel(200, 200)
		background.id = id("background")
		content(&modal_ui, background)
		modal := _panel(150, 150)
		modal.id = id("modal")
		modal.hit = .Opaque
		modal.overlay = {
			attach = .Root,
			layer  = 1,
		}
		content(&modal_ui, modal)
	}
	modal_result, modal_err := result(&modal_ui)
	testing.expect_value(t, modal_err, Frame_Error.None)
	testing.expect(t, modal_result.nodes[_handle_of(modal_result, id("modal"))].flags.hit_opaque)

	modal_stack, modal_complete := hit_stack(modal_result, {50, 50}, storage[:])
	testing.expect_value(t, len(modal_stack), 1)
	testing.expect(t, modal_complete)
	testing.expect_value(t, modal_result.nodes[modal_stack[0]].id, id("modal"))

	invalid_clip := clip_of(modal_result, Clip_Handle(9999))
	testing.expect_value(t, invalid_clip, clip_of(modal_result, Clip_Handle(0)))
}

@(test)
test_phase4_hit_stack_is_distinct_from_ancestor_path :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	// The overlay overlaps a sibling subtree it is not descended from, so the
	// overlap stack and the structural chain must disagree.
	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		root := _panel(200, 200)
		root.id = id("root")
		if element(&ui, root) {
			left := _panel(200, 200)
			left.id = id("left")
			content(&ui, left)

			floating := _panel(60, 60)
			floating.id = id("floating")
			floating.overlay = {
				attach = .Root,
				layer  = 1,
			}
			content(&ui, floating)
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	storage: [8]Node_Handle
	stack, complete := hit_stack(frame_result, {10, 10}, storage[:])
	testing.expect_value(t, len(stack), 3)
	testing.expect(t, complete)
	testing.expect_value(t, frame_result.nodes[stack[0]].id, id("floating"))
	testing.expect_value(t, frame_result.nodes[stack[1]].id, id("left"))
	testing.expect_value(t, frame_result.nodes[stack[2]].id, id("root"))

	path_storage: [8]Node_Handle
	path, path_complete, path_found := ancestor_path(frame_result, _handle_of(frame_result, id("floating")), path_storage[:])
	testing.expect(t, path_complete)
	testing.expect(t, path_found)
	testing.expect_value(t, len(path), 2)
	testing.expect_value(t, frame_result.nodes[path[0]].id, id("floating"))
	testing.expect_value(t, frame_result.nodes[path[1]].id, id("root"))
}

@(test)
test_phase4_hit_stack_respects_caller_storage :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		outer := _panel(200, 200)
		outer.id = id("outer")
		if element(&ui, outer) {
			middle := _panel(150, 150)
			if element(&ui, middle) {
				content(&ui, _panel(100, 100))
			}
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	storage: [1]Node_Handle
	stack, complete := hit_stack(frame_result, {10, 10}, storage[:])
	testing.expect_value(t, len(stack), 1)
	testing.expect(t, !complete)

	empty, empty_complete := hit_stack(frame_result, {10, 10}, nil)
	testing.expect_value(t, len(empty), 0)
	testing.expect(t, !empty_complete)

	miss, miss_complete := hit_stack(frame_result, {400, 400}, nil)
	testing.expect_value(t, len(miss), 0)
	testing.expect(t, miss_complete)
}

@(test)
test_phase4_ancestor_path_reports_capacity_and_invalid_target :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		root := _panel(200, 200)
		root.id = id("root")
		if element(&ui, root) {
			child := _panel(150, 150)
			child.id = id("child")
			if element(&ui, child) {
				target := _panel(100, 100)
				target.id = id("target")
				content(&ui, target)
			}
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	target_handle := _handle_of(frame_result, id("target"))
	short_storage: [1]Node_Handle
	short_path, short_complete, short_found := ancestor_path(frame_result, target_handle, short_storage[:])
	testing.expect(t, short_found)
	testing.expect(t, !short_complete)
	testing.expect_value(t, len(short_path), 1)
	testing.expect_value(t, frame_result.nodes[short_path[0]].id, id("target"))

	full_storage: [8]Node_Handle
	full_path, full_complete, full_found := ancestor_path(frame_result, target_handle, full_storage[:])
	testing.expect(t, full_found)
	testing.expect(t, full_complete)
	testing.expect_value(t, len(full_path), 3)
	testing.expect_value(t, frame_result.nodes[full_path[0]].id, id("target"))
	testing.expect_value(t, frame_result.nodes[full_path[1]].id, id("child"))
	testing.expect_value(t, frame_result.nodes[full_path[2]].id, id("root"))

	invalid_path, invalid_complete, invalid_found := ancestor_path(frame_result, Node_Handle(999), nil)
	testing.expect_value(t, len(invalid_path), 0)
	testing.expect(t, invalid_complete)
	testing.expect(t, !invalid_found)
}

@(test)
test_phase4_children_iterates_declaration_order_including_overlays :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		parent := _panel(200, 200)
		parent.id = id("parent")
		if element(&ui, parent) {
			first := _panel(10, 10)
			first.id = id("first")
			content(&ui, first)

			floating := _panel(10, 10)
			floating.id = id("floating")
			floating.overlay = {
				attach = .Root,
				layer  = 1,
			}
			content(&ui, floating)

			last := _panel(10, 10)
			last.id = id("last")
			content(&ui, last)
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	expected := [3]Id{id("first"), id("floating"), id("last")}
	iterator := children(frame_result, _handle_of(frame_result, id("parent")))
	seen := 0
	for child, handle in next_child(&iterator) {
		testing.expect(t, handle != 0)
		testing.expect_value(t, child.id, expected[seen])
		seen += 1
	}
	testing.expect_value(t, seen, 3)

	leaf := children(frame_result, _handle_of(frame_result, id("first")))
	_, _, has_child := next_child(&leaf)
	testing.expect(t, !has_child)
}

@(test)
test_phase4_clip_of_falls_back_to_the_viewport :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 150}) {
		content(&ui, _panel(10, 10))
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	viewport := clip_of(frame_result, Clip_Handle(0))
	testing.expect_value(t, viewport.rect, Rect{size = {200, 150}})
	testing.expect_value(t, clip_of(frame_result, Clip_Handle(99)), viewport)
}


@(test)
test_phase4_command_pool_exhaustion_fails_transactionally :: proc(t: ^testing.T) {
	config := _phase4_config()
	config.capacities.commands = 2
	ui: Context
	testing.expect_value(t, init(&ui, config), nil)
	defer destroy(&ui)

	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		for _ in 0 ..< 6 {
			box := _panel(10, 10)
			box.paint.background = {255, 255, 255, 255}
			content(&ui, box)
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.Capacity_Exhausted)
	testing.expect_value(t, len(frame_result.commands), 0)
	testing.expect_value(t, len(frame_result.nodes), 0)

	exhausted := false
	for entry in diagnostics(&ui) {
		if entry.kind == .Pool_Exhausted && entry.pool == .Commands {
			exhausted = true
		}
	}
	testing.expect(t, exhausted)
}

@(test)
test_phase4_emission_allocates_nothing_in_fixed_mode :: proc(t: ^testing.T) {
	config := _phase4_config()
	storage := make([]byte, storage_size(config.capacities))
	defer delete(storage)

	ui: Context
	testing.expect_value(t, init_from_buffer(&ui, config, storage), nil)
	defer destroy(&ui)

	context.allocator = mem.panic_allocator()
	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		panel := _panel(100, 100)
		panel.id = id("panel")
		panel.paint = {
			background = {1, 1, 1, 255},
			radius = radius_all(4),
			border = {color = {2, 2, 2, 255}, width = pad_all(1), between_children = 1},
		}
		panel.clip = {
			axes = {.Y},
		}
		if element(&ui, panel) {
			content(&ui, _panel(20, 20))
			content(&ui, _panel(20, 20))
			text(&ui, {text = "abc def", style = {size = 10, color = {255, 255, 255, 255}, wrap = .Words}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect(t, len(frame_result.commands) > 0)

	storage_high_water := statistics(&ui).pool_high_water[.Commands]
	testing.expect_value(t, storage_high_water, len(frame_result.commands))
}

@(test)
test_phase4_visible_commands_ignores_the_effective_clip :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	// Culling tests bounds alone. A command hidden by an empty clip is still
	// emitted under `Cull_Policy.All` so a retained backend can see that it
	// exists and is hidden, and filtering it here would defeat that.
	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		clipper := Element_Desc {
			id = id("clipper"),
			layout = {sizing = {fixed(0), fixed(0)}},
			clip = {axes = {.X, .Y}},
		}
		if element(&ui, clipper) {
			hidden := _panel(50, 50)
			hidden.id = id("hidden")
			hidden.paint.background = {255, 255, 255, 255}
			content(&ui, hidden)
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 1)

	hidden_handle := _handle_of(frame_result, id("hidden"))
	testing.expect(t, !frame_result.nodes[hidden_handle].flags.visible)
	testing.expect_value(t, clip_of(frame_result, frame_result.commands[0].clip).rect.size, Vec2{})

	iterator := visible_commands(frame_result, Rect{size = {200, 200}})
	seen := 0
	for _ in next_command(&iterator) {
		seen += 1
	}
	testing.expect_value(t, seen, 1)
}

@(test)
test_phase4_visible_commands_culls_against_an_offset_region :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	// The supplied rectangle is an arbitrary world-space region and need not
	// have any relationship to a clip.
	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		near := _panel(50, 50)
		near.paint.background = {255, 255, 255, 255}
		content(&ui, near)

		far := _panel(100, 100)
		far.id = id("far")
		far.paint.background = {255, 0, 0, 255}
		far.overlay = {
			attach = .Root,
			offset = {1000, 1000},
			layer  = 1,
		}
		content(&ui, far)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	iterator := visible_commands(frame_result, Rect{position = {1000, 1000}, size = {100, 100}})
	seen := 0
	for command in next_command(&iterator) {
		testing.expect_value(t, command.node, _handle_of(frame_result, id("far")))
		seen += 1
	}
	testing.expect_value(t, seen, 1)
}

@(test)
test_phase4_between_children_rules_follow_scroll_on_both_axes :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	// A rule separates the children it sits between, so it has to move with
	// them on the cross axis too, not stay pinned to the container's own box.
	set_services(&ui, _phase4_services())
	if frame(&ui, {300, 300}) {
		list := Element_Desc {
			id = id("list"),
			layout = {flow = .Row, sizing = {fixed(200), fixed(100)}, gap = 10},
			paint = {border = {color = {255, 255, 255, 255}, between_children = 2}},
			clip = {axes = {.X, .Y}, offset = {0, 30}},
		}
		if element(&ui, list) {
			content(&ui, _panel(60, 200))
			content(&ui, _panel(60, 200))
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 1)

	rule := frame_result.commands[0].bounds
	children_top := frame_result.nodes[_handle_of(frame_result, id("list"))].first_child
	_expect_close(t, rule.position.y, frame_result.nodes[children_top].outer.position.y)
	_expect_close(t, rule.position.y, -30)
	_expect_close(t, rule.position.x, 64)
	_expect_close(t, rule.size.x, 2)
}

@(test)
test_phase4_negative_zero_never_reaches_a_command :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase4_config()), nil)
	defer destroy(&ui)

	// `-0` compares equal to `+0`, so only the bit pattern proves it was
	// normalized before publication, as §1.4 requires.
	negative_zero := Scalar(-0.0)
	testing.expect_value(t, transmute(u32)negative_zero, u32(0x8000_0000))

	set_services(&ui, _phase4_services())
	if frame(&ui, {200, 200}) {
		box := _panel(100, 100)
		box.paint = {
			background = {255, 255, 255, 255},
			radius = {tl = negative_zero, tr = 4, br = negative_zero, bl = 4},
			border = {color = {255, 0, 0, 255}, width = {left = 2, top = negative_zero, right = negative_zero, bottom = 2}},
		}
		content(&ui, box)
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 2)

	fill := frame_result.commands[0].data.(Fill_Cmd)
	testing.expect_value(t, transmute(u32)fill.radius.tl, u32(0))
	testing.expect_value(t, transmute(u32)fill.radius.br, u32(0))

	border := frame_result.commands[1].data.(Border_Cmd)
	testing.expect_value(t, transmute(u32)border.width.top, u32(0))
	testing.expect_value(t, transmute(u32)border.width.right, u32(0))
	testing.expect_value(t, transmute(u32)border.radius.tl, u32(0))
}
