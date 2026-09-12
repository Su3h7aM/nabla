#+test
#+private file
// Package-level test for the text seam: layout's wrapping driven by the real
// `text`/`tui` breaker instead of the layout package's local fixture. It lives
// here because only `layout/test` can import layout, text, and tui together.
package layout_test

import "core:testing"
import "nabla:layout"
import "nabla:text"
import "nabla:tui"

@(private)
_wrapped_height :: proc(
	t: ^testing.T,
	ui: ^layout.Context,
	measure_context: ^tui.Measure_Context,
	viewport: layout.Vec2,
	body: string,
	style: layout.Text_Style,
) -> layout.Scalar {
	layout.set_services(ui, {measure_text = tui.measure_proc, measure_text_user_data = measure_context, break_text = tui.break_proc})
	if layout.frame(ui, viewport) {
		layout.text(ui, layout.Text_Desc{text = body, style = style, sizing = {layout.grow(), layout.fit()}})
	}
	frame_result, frame_error := layout.result(ui)
	testing.expect_value(t, frame_error, layout.Frame_Error.None)
	node, found := layout.node(frame_result, layout.Node_Handle(1))
	testing.expect(t, found)
	return node.content_size.y
}

@(test)
test_break_proc_reproduces_fixture_wrapping_geometry :: proc(t: ^testing.T) {
	measure_context := tui.Measure_Context {
		profile = text.DEFAULT_WIDTH_PROFILE,
	}
	config := layout.Options {
		capacities = {
			nodes = 16,
			children = 16,
			clips = 4,
			commands = 16,
			text_lines = 16,
			measured_words = 64,
			overlays = 4,
			measure_cache = 16,
			id_table = 16,
			depth = 8,
			diagnostics = 8,
			debug_labels = 32,
		},
	}
	storage := make([]byte, layout.storage_size(config.capacities))
	defer delete(storage)

	ui: layout.Context
	testing.expect_value(t, layout.init_from_buffer(&ui, config, storage), nil)
	defer layout.destroy(&ui)

	// Block height is line count times line height: "aaa bbb" fits on one line
	// at width 70, needs two below its longest word, CRLF is a hard break, and
	// Wrap.None never breaks.
	words := layout.Text_Style {
		wrap = .Words,
		size = 16,
	}
	testing.expect_value(t, _wrapped_height(t, &ui, &measure_context, {70, 100}, "aaa bbb", words), layout.Scalar(1))
	testing.expect_value(t, _wrapped_height(t, &ui, &measure_context, {3, 100}, "aaa bbb", words), layout.Scalar(2))
	testing.expect_value(t, _wrapped_height(t, &ui, &measure_context, {100, 100}, "aaa\r\nbb", words), layout.Scalar(2))
	testing.expect_value(t, _wrapped_height(t, &ui, &measure_context, {5, 100}, "aaabbbccc", {wrap = .None, size = 16}), layout.Scalar(1))
}
