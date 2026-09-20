#+build linux
#+test
#+private file
package tui

import "core:testing"

import "nabla:layout"
import "nabla:term"
import width_text "nabla:text"

_SCOPE_TEST_OPTIONS :: layout.Options {
	capacities = {
		nodes = 8,
		children = 8,
		clips = 4,
		commands = 8,
		text_lines = 8,
		measured_words = 16,
		overlays = 1,
		measure_cache = 8,
		id_table = 8,
		depth = 8,
		diagnostics = 8,
	},
}

_SCOPE_PARENT_ID :: layout.Id(1)
_SCOPE_CHILD_ID :: layout.Id(2)

_scope_layout_result :: proc(t: ^testing.T, ctx: ^layout.Context) -> layout.Frame_Result {
	init_error := layout.init(ctx, _SCOPE_TEST_OPTIONS)
	testing.expect_value(t, init_error, nil)
	if init_error != nil {
		return {}
	}
	if layout.frame(ctx, {8, 4}) {
		if layout.element(
			ctx,
			layout.Element_Desc {
				id = _SCOPE_PARENT_ID,
				layout = {sizing = {layout.grow(), layout.grow()}, padding = layout.pad_all(1)},
				clip = {axes = {.X, .Y}},
			},
		) {
			layout.content(ctx, layout.Element_Desc{id = _SCOPE_CHILD_ID, layout = {sizing = {layout.fixed(8), layout.fixed(1)}}})
		}
	}
	frame_result, frame_error := layout.result(ctx)
	testing.expect_value(t, frame_error, layout.Frame_Error.None)
	return frame_result
}

@(test)
test_scoped_rendering_uses_layout_boxes_and_clips :: proc(t: ^testing.T) {
	layout_ctx: layout.Context
	frame_result := _scope_layout_result(t, &layout_ctx)
	defer layout.destroy(&layout_ctx)

	cells: [32]term.Cell
	ctx: Context
	if frame(&ctx, frame_result, cells[:]) {
		if element(&ctx, {id = _SCOPE_PARENT_ID}) {
			testing.expect_value(t, fill(&ctx, ".", {}), 32)
			if element(&ctx, {id = _SCOPE_CHILD_ID}) {
				written, ok := draw_text(&ctx, "abcdefgh", {})
				testing.expect(t, ok)
				testing.expect_value(t, written, 6)
			}
		}
	}
	rendered, render_error := result(&ctx)
	testing.expect_value(t, render_error, Frame_Error.None)
	row := rendered.buffer.cells[8:16]
	expected := [?]string{".", "a", "b", "c", "d", "e", "f", "."}
	for value, index in expected {
		testing.expect_value(t, row[index].grapheme, value)
	}
}

_run_scoped_early_return :: proc(ctx: ^Context, frame_result: layout.Frame_Result, cells: []term.Cell) {
	if frame(ctx, frame_result, cells) {
		if element(ctx, {id = _SCOPE_PARENT_ID}) {
			return
		}
	}
}

@(test)
test_text_draws_layout_wrapped_lines :: proc(t: ^testing.T) {
	layout_ctx: layout.Context
	testing.expect_value(t, layout.init(&layout_ctx, _SCOPE_TEST_OPTIONS), nil)
	defer layout.destroy(&layout_ctx)
	measure_context := Measure_Context {
		profile = width_text.DEFAULT_WIDTH_PROFILE,
	}
	layout.set_services(&layout_ctx, {measure_text = measure_proc, measure_text_user_data = &measure_context, break_text = break_proc})
	parent_id := layout.Id(10)
	text_id := layout.Id(11)
	if layout.frame(&layout_ctx, {5, 2}) {
		if layout.element(&layout_ctx, layout.Element_Desc{id = parent_id, layout = {flow = .Column, sizing = {layout.grow(), layout.grow()}}}) {
			layout.text(
				&layout_ctx,
				layout.Text_Desc {
					id = text_id,
					text = "hello world",
					style = {size = 1, color = {255, 255, 255, 255}, line_height = 1, wrap = .Words},
					sizing = {layout.grow(), layout.fit()},
				},
			)
		}
	}
	layout_result, layout_error := layout.result(&layout_ctx)
	testing.expect_value(t, layout_error, layout.Frame_Error.None)

	cells: [10]term.Cell
	ctx: Context
	if frame(&ctx, layout_result, cells[:]) {
		if element(&ctx, {id = parent_id}) {
			if element(&ctx, {id = text_id}) {
				written, ok := text(&ctx, {})
				testing.expect(t, ok)
				testing.expect_value(t, written, 10)
			}
		}
	}
	rendered, render_error := result(&ctx)
	testing.expect_value(t, render_error, Frame_Error.None)
	testing.expect_value(t, rendered.buffer.cells[0].grapheme, "h")
	testing.expect_value(t, rendered.buffer.cells[5].grapheme, "w")
}

@(test)
test_scoped_rendering_balances_early_return :: proc(t: ^testing.T) {
	layout_ctx: layout.Context
	frame_result := _scope_layout_result(t, &layout_ctx)
	defer layout.destroy(&layout_ctx)

	cells: [32]term.Cell
	ctx: Context
	_run_scoped_early_return(&ctx, frame_result, cells[:])
	_, render_error := result(&ctx)
	testing.expect_value(t, render_error, Frame_Error.None)
}

@(test)
test_scoped_rendering_reports_frame_setup_errors :: proc(t: ^testing.T) {
	layout_ctx: layout.Context
	frame_result := _scope_layout_result(t, &layout_ctx)
	defer layout.destroy(&layout_ctx)

	cells: [1]term.Cell
	ctx: Context
	entered := frame(&ctx, frame_result, cells[:])
	testing.expect(t, !entered)
	_, render_error := result(&ctx)
	testing.expect_value(t, render_error, Frame_Error.Buffer_Too_Small)
}
