#+test
#+private file
package layout

import "core:math"
import "core:testing"

_measure_monospace :: proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	_, _, _ = user_data, style, request
	width := Scalar(10 * len(text))
	return Measure_Result{size = {width, 20}, min_size = {width, 20}, baseline = 16}, .None
}

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

_services :: proc() -> Services {
	return Services{measure_text = _measure_monospace, break_text = _break_ascii}
}

_panel :: proc(width, height: Scalar) -> Element_Desc {
	return Element_Desc{layout = {sizing = {fixed(width), fixed(height)}}}
}

_expect_close :: proc(t: ^testing.T, actual, expected: Scalar) {
	testing.expectf(t, math.abs(actual - expected) <= SCALAR_TOLERANCE, "expected %.6f, got %.6f", expected, actual)
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

@(test)
test_command_order_and_culling :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	// A node paints its own surface, then its content, then its children, and
	// closes with its border so descendant overdraw cannot eat the edge.
	set_services(&ctx, _services())
	if frame(&ctx, {200, 200}) {
		parent := _panel(120, 120)
		parent.id = id("parent")
		parent.paint = {
			background = {10, 10, 10, 255},
			border = {color = {200, 200, 200, 255}, width = pad_all(2)},
		}
		parent.content = Custom_Content {
			kind = Custom_Kind(7),
		}
		if element(&ctx, parent) {
			child := _panel(40, 40)
			child.paint.background = {80, 80, 80, 255}
			content(&ctx, child)
		}
	}
	frame_result, err := result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	kinds := _command_kinds(frame_result, context.temp_allocator)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, len(kinds), 4)
	testing.expect_value(t, kinds[0], "fill")
	testing.expect_value(t, kinds[1], "custom")
	testing.expect_value(t, kinds[2], "fill")
	testing.expect_value(t, kinds[3], "border")

	// Wrapped text publishes one command per line, in line order.
	set_services(&ctx, _services())
	if frame(&ctx, {200, 200}) {
		box := _panel(60, 60)
		box.layout.sizing.height = fit()
		box.id = id("box")
		if element(&ctx, box) {
			text(&ctx, {text = "aaa bbb ccc", style = {size = 10, color = {255, 255, 255, 255}, wrap = .Words}})
		}
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	expected_lines := [3]string{"aaa", "bbb", "ccc"}
	line_index := 0
	for command in frame_result.commands {
		data, is_text := command.data.(Text_Cmd)
		if !is_text {
			continue
		}
		testing.expect_value(t, data.text, expected_lines[line_index])
		testing.expect_value(t, data.line, u16(line_index))
		line_index += 1
	}
	testing.expect_value(t, line_index, 3)

	// Paint roots are atomic and ordered by (layer, declaration): the overlay
	// declared in the middle of the parent's children emits last because its
	// layer is higher.
	if frame(&ctx, {300, 300}) {
		parent := _panel(200, 200)
		parent.id = id("parent")
		parent.paint.background = {1, 1, 1, 255}
		if element(&ctx, parent) {
			first := _panel(20, 20)
			first.paint.background = {2, 2, 2, 255}
			content(&ctx, first)

			floating := _panel(20, 20)
			floating.paint.background = {3, 3, 3, 255}
			floating.overlay = {
				attach = .Parent,
				layer  = 5,
			}
			content(&ctx, floating)

			last := _panel(20, 20)
			last.paint.background = {4, 4, 4, 255}
			content(&ctx, last)
		}
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 4)
	for command, index in frame_result.commands {
		expected := i16(5) if index == 3 else i16(0)
		testing.expect_value(t, command.layer, expected)
	}

	// Cull_Policy.Visible removes commands hidden by their clip but leaves the
	// node table untouched, and the result is a subsequence of the full stream.
	all_ctx: Context
	testing.expect_value(t, init(&all_ctx, _test_options()), nil)
	defer destroy(&all_ctx)
	visible_config := _test_options()
	visible_config.cull = .Visible
	culled_ctx: Context
	testing.expect_value(t, init(&culled_ctx, visible_config), nil)
	defer destroy(&culled_ctx)

	build :: proc(ctx: ^Context) {
		set_services(ctx, _services())
		if frame(ctx, {200, 200}) {
			clipper := _panel(100, 40)
			clipper.id = id("clipper")
			clipper.clip = {
				axes = {.X, .Y},
			}
			if element(ctx, clipper) {
				if element(ctx, {layout = {flow = .Column, sizing = {fixed(100), fit()}}}) {
					for index in 0 ..< 6 {
						row := _panel(100, 40)
						row.paint.background = {u8(index), 0, 0, 255}
						content(ctx, row)
					}
				}
			}
		}
	}
	build(&all_ctx)
	build(&culled_ctx)
	all_result, all_err := result(&all_ctx)
	culled_result, culled_err := result(&culled_ctx)
	testing.expect_value(t, all_err, Frame_Error.None)
	testing.expect_value(t, culled_err, Frame_Error.None)
	testing.expect_value(t, len(all_result.commands), 6)
	testing.expect(t, len(culled_result.commands) < len(all_result.commands))
	testing.expect_value(t, len(culled_result.nodes), len(all_result.nodes))
}

@(test)
test_command_normalization :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	// Transparent paint and invisible text emit nothing; a zero custom kind is
	// still a valid discriminator and emits.
	set_services(&ctx, _services())
	if frame(&ctx, {200, 200}) {
		transparent := _panel(50, 50)
		transparent.paint = {
			background = {255, 255, 255, 0},
			border = {color = {255, 0, 0, 255}},
		}
		content(&ctx, transparent)

		invisible_border := _panel(50, 50)
		invisible_border.paint.border = {
			color = {255, 0, 0, 0},
			width = pad_all(4),
		}
		content(&ctx, invisible_border)

		text(&ctx, {text = "hidden", style = {size = 10, color = {255, 255, 255, 0}}})

		custom := _panel(40, 30)
		custom.content = Custom_Content {
			kind = Custom_Kind(0),
		}
		content(&ctx, custom)
	}
	frame_result, err := result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 1)
	testing.expect_value(t, frame_result.commands[0].data.(Custom_Cmd).kind, Custom_Kind(0))

	// A flipped, out-of-range UV rectangle becomes the region it overlaps, and
	// a disabled tint is republished as the identity multiplier.
	if frame(&ctx, {200, 200}) {
		box := _panel(100, 100)
		box.content = Image_Content {
			handle = Image_Handle(3),
			source = {mode = .Normalized, uv = {position = {0.75, 1.5}, size = {-0.5, -2}}},
		}
		content(&ctx, box)

		no_handle := _panel(50, 50)
		no_handle.content = Image_Content {
			handle = Image_Handle(0),
		}
		content(&ctx, no_handle)

		clear_tint := _panel(50, 50)
		clear_tint.content = Image_Content {
			handle = Image_Handle(1),
			tint = {enabled = true, color = {255, 255, 255, 0}},
		}
		content(&ctx, clear_tint)
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 1)
	image := frame_result.commands[0].data.(Image_Cmd)
	testing.expect_value(t, image.tint, Color{255, 255, 255, 255})
	_expect_close(t, image.source.uv.position.x, 0.25)
	_expect_close(t, image.source.uv.size.x, 0.5)
	_expect_close(t, image.source.uv.position.y, 0)
	_expect_close(t, image.source.uv.size.y, 1)

	// Radii and border widths are reduced by one common factor so their
	// proportions survive; `-0` never reaches a command.
	if frame(&ctx, {200, 200}) {
		box := _panel(100, 100)
		box.paint = {
			background = {255, 255, 255, 255},
			radius = {tl = 150, tr = 50, br = 150, bl = 50},
			border = {color = {255, 0, 0, 255}, width = {left = 90, right = 30, top = 12, bottom = 12}},
		}
		content(&ctx, box)
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.commands), 2)
	fill := frame_result.commands[0].data.(Fill_Cmd)
	_expect_close(t, fill.radius.tl, 75)
	_expect_close(t, fill.radius.tr, 25)
	border := frame_result.commands[1].data.(Border_Cmd)
	_expect_close(t, border.width.left, 75)
	_expect_close(t, border.width.right, 25)
	_expect_close(t, border.width.top, 10)

	// Between-children rules sit centred in each gap the placed children left.
	if frame(&ctx, {300, 200}) {
		row := Element_Desc {
			id = id("row"),
			layout = {flow = .Row, sizing = {fixed(300), fixed(100)}, gap = 8},
			paint = {border = {color = {255, 255, 255, 255}, between_children = 2}},
		}
		if element(&ctx, row) {
			for _ in 0 ..< 3 {
				content(&ctx, _panel(40, 40))
			}
		}
	}
	frame_result, err = result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	rules := 0
	for command in frame_result.commands {
		if _, is_fill := command.data.(Fill_Cmd); is_fill {
			_expect_close(t, command.bounds.size.x, 2)
			_expect_close(t, command.bounds.position.x, Scalar(43 + rules * 48))
			rules += 1
		}
	}
	testing.expect_value(t, rules, 2)
}
