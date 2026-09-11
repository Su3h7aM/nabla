#+test
#+private file
// Package-level tests: the public API only, exercising a whole frame rather
// than one procedure.
package layout_test

import "core:mem"
import "core:testing"
import "nabla:layout"

@(private)
_test_options :: proc() -> layout.Options {
	return layout.Options {
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

@(private)
_test_measure :: proc(
	user_data: rawptr,
	text: string,
	style: layout.Text_Style,
	request: layout.Measure_Request,
) -> (
	layout.Measure_Result,
	layout.Measure_Error,
) {
	_, _, _ = user_data, style, request
	width := layout.Scalar(10 * len(text))
	return layout.Measure_Result{size = {width, 20}, min_size = {width, 20}}, .None
}

@(private)
_test_break :: proc(
	user_data: rawptr,
	value: string,
	offset: int,
) -> (
	piece_end: int,
	next_offset: int,
	kind: layout.Text_Break_Kind,
	err: layout.Text_Break_Error,
) {
	_, _ = user_data, offset
	index := offset
	for index < len(value) {
		if value[index] == ' ' || value[index] == '\n' {
			kind = .Optional if value[index] == ' ' else .Mandatory
			next_offset = index + 1
			for next_offset < len(value) && value[next_offset] == ' ' {
				next_offset += 1
			}
			return index, next_offset, kind, .None
		}
		index += 1
	}
	return len(value), len(value), .None, .None
}

@(private)
_test_services :: proc() -> layout.Services {
	return layout.Services{measure_text = _test_measure, break_text = _test_break}
}

@(test)
test_frame_end_to_end :: proc(t: ^testing.T) {
	ctx: layout.Context
	testing.expect_value(t, layout.init(&ctx, _test_options()), nil)
	defer layout.destroy(&ctx)

	layout.set_services(&ctx, _test_services())
	if layout.frame(&ctx, {300, 200}) {
		if layout.element(&ctx, {layout = {flow = .Column, sizing = {layout.grow(), layout.grow()}, padding = layout.pad_all(8), gap = 4}}) {
			layout.content(&ctx, {id = layout.id("header"), layout = {sizing = {layout.grow(), layout.fixed(24)}}})
			if layout.element(&ctx, {id = layout.id("body"), layout = {sizing = {layout.grow(), layout.grow()}}, clip = {axes = {.Y}}}) {
				layout.text(
					&ctx,
					{
						id = layout.id("title"),
						text = "hello world",
						style = {size = 10, color = layout.rgb(255, 255, 255)},
						sizing = {layout.grow(), layout.fit()},
					},
				)
			}
		}
	}
	frame_result, frame_error := layout.result(&ctx)
	testing.expect_value(t, frame_error, layout.Frame_Error.None)

	header, found := layout.lookup(frame_result, layout.id("header"))
	testing.expect(t, found)
	testing.expect_value(t, header.outer.position.x, layout.Scalar(8))
	testing.expect_value(t, header.outer.size.y, layout.Scalar(24))

	title, title_found := layout.lookup(frame_result, layout.id("title"))
	testing.expect(t, title_found)
	testing.expect_value(t, title.outer.size.x, layout.Scalar(284))
	testing.expect(t, title.clip != layout.Clip_Handle(0))
	testing.expect(t, len(frame_result.commands) > 0)

	hit, hit_found := layout.hit_test(frame_result, {10, 40})
	testing.expect(t, hit_found)
	testing.expect_value(t, hit.id, layout.id("title"))
}

@(test)
test_fixed_storage_frame_allocates_nothing :: proc(t: ^testing.T) {
	options := _test_options()
	storage := make([]byte, layout.storage_size(options.capacities))
	defer delete(storage)

	ctx: layout.Context
	testing.expect_value(t, layout.init_from_buffer(&ctx, options, storage), nil)
	defer layout.destroy(&ctx)

	// With caller-owned storage the whole frame, including text wrapping,
	// overlay placement, and command emission, must run without allocating.
	context.allocator = mem.panic_allocator()
	layout.set_services(&ctx, _test_services())
	if layout.frame(&ctx, {300, 200}) {
		if layout.element(&ctx, {layout = {sizing = {layout.grow(), layout.grow()}, padding = layout.pad_all(4)}, clip = {axes = {.Y}}}) {
			layout.content(&ctx, {id = layout.id("box"), layout = {sizing = {layout.fixed(40), layout.fixed(40)}}, paint = {background = layout.rgb(1, 2, 3)}})
			layout.text(&ctx, {text = "aaa bbb ccc", style = {size = 10, color = layout.rgb(255, 255, 255)}, sizing = {layout.grow(), layout.fit()}})
			layout.content(&ctx, {id = layout.id("overlay"), layout = {sizing = {layout.fixed(20), layout.fixed(20)}}, overlay = {attach = .Root}})
		}
	}
	frame_result, frame_error := layout.result(&ctx)
	testing.expect_value(t, frame_error, layout.Frame_Error.None)
	testing.expect(t, len(frame_result.commands) > 0)
}

@(test)
test_overlay_hit_stack_and_visible_commands :: proc(t: ^testing.T) {
	ctx: layout.Context
	testing.expect_value(t, layout.init(&ctx, _test_options()), nil)
	defer layout.destroy(&ctx)

	layout.set_services(&ctx, _test_services())
	if layout.frame(&ctx, {200, 200}) {
		layout.content(&ctx, {id = layout.id("background"), layout = {sizing = {layout.grow(), layout.grow()}}, paint = {background = layout.rgb(1, 1, 1)}})
		layout.content(
			&ctx,
			{
				id = layout.id("modal"),
				layout = {sizing = {layout.fixed(150), layout.fixed(150)}},
				paint = {background = layout.rgb(2, 2, 2)},
				overlay = {attach = .Root, layer = 1},
				hit = .Opaque,
			},
		)
	}
	frame_result, frame_error := layout.result(&ctx)
	testing.expect_value(t, frame_error, layout.Frame_Error.None)

	// The opaque modal is the only hit, so the stack ends there.
	storage: [4]layout.Node_Handle
	hits, complete := layout.hit_stack(frame_result, {10, 10}, storage[:])
	testing.expect(t, complete)
	testing.expect_value(t, len(hits), 1)
	testing.expect_value(t, frame_result.nodes[hits[0]].id, layout.id("modal"))

	// Both commands are still in the stream; culling is a view, not a mutation.
	testing.expect_value(t, len(frame_result.commands), 2)
	painted := 0
	iterator := layout.visible_commands(frame_result, layout.Rect{size = {200, 200}})
	for _ in layout.next_command(&iterator) {
		painted += 1
	}
	testing.expect_value(t, painted, 2)
}
