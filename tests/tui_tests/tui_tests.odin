#+build linux
package main

import "nabla:layout"
import "nabla:text"
import "nabla:tty"
import "nabla:tui"

test_init_fills_with_blanks :: proc(t: ^T) {
	storage: [12]tui.Cell
	buffer: tui.Cell_Buffer
	base := tui.Style {
		foreground = tui.Indexed_Color(3),
	}
	expect(t, tui.init(&buffer, 4, 3, storage[:], base))
	expect_value(t, len(buffer.cells), 12)
	for cell in buffer.cells {
		expect_value(t, cell, tui.Cell{grapheme = " ", style = base})
	}
}

test_init_rejects_insufficient_storage :: proc(t: ^T) {
	storage: [4]tui.Cell
	buffer: tui.Cell_Buffer
	expect(t, !tui.init(&buffer, 3, 3, storage[:]))
}

test_init_rejects_negative_extent :: proc(t: ^T) {
	storage: [4]tui.Cell
	buffer: tui.Cell_Buffer
	expect(t, !tui.init(&buffer, -1, 2, storage[:]))
}

test_init_rejects_hostile_dimensions_without_mutation :: proc(t: ^T) {
	storage := [?]tui.Cell{{grapheme = "a"}, {grapheme = "b"}}
	original_storage := storage
	buffer := tui.Cell_Buffer {
		width  = 1,
		height = 1,
		cells  = storage[:1],
	}
	expect(t, !tui.init(&buffer, max(int), 2, storage[:]))
	expect_value(t, buffer.width, 1)
	expect_value(t, buffer.height, 1)
	expect_value(t, len(buffer.cells), 1)
	expect_value(t, buffer.cells[0].grapheme, "a")
	expect_value(t, storage, original_storage)
	expect(t, !tui.init(nil, 1, 1, storage[:]))
}

test_init_accepts_zero_sized_grids :: proc(t: ^T) {
	storage := [?]tui.Cell{{grapheme = "kept"}}
	buffer: tui.Cell_Buffer
	expect(t, tui.init(&buffer, 0, max(int), storage[:]))
	expect_value(t, buffer.width, 0)
	expect_value(t, buffer.height, max(int))
	expect_value(t, len(buffer.cells), 0)
	expect_value(t, storage[0].grapheme, "kept")
}

test_put_is_bounds_checked :: proc(t: ^T) {
	storage: [6]tui.Cell
	buffer: tui.Cell_Buffer
	_ = tui.init(&buffer, 3, 2, storage[:])
	expect(t, tui.put(&buffer, 2, 1, {grapheme = "z"}))
	expect_value(t, buffer.cells[5].grapheme, "z")
	expect(t, !tui.put(&buffer, 3, 0, {grapheme = "z"}))
	expect(t, !tui.put(&buffer, 0, 2, {grapheme = "z"}))
	expect(t, !tui.put(&buffer, -1, 0, {grapheme = "z"}))
}

test_integral_projection_is_exact :: proc(t: ^T) {
	rect, err := tui.project_rect_integral(layout.Rect{position = {2, 1}, size = {5, 1}})
	expect_value(t, err, tui.Projection_Error.None)
	expect_value(t, rect, tui.Cell_Rect{x = 2, y = 1, width = 5, height = 1})
}

test_fractional_geometry_is_rejected_not_rounded :: proc(t: ^T) {
	// Rounding policy is an open question (slice plan, D3). Until it is decided,
	// silently rounding here would bake in an answer, so a fractional box fails.
	fractional := [?]layout.Rect{{position = {0.5, 0}, size = {4, 1}}, {position = {0, 0}, size = {4.25, 1}}}
	for rect in fractional {
		_, err := tui.project_rect_integral(rect)
		expect_value(t, err, tui.Projection_Error.Non_Integral)
	}
}

test_negative_size_is_rejected :: proc(t: ^T) {
	_, err := tui.project_rect_integral(layout.Rect{position = {0, 0}, size = {-1, 2}})
	expect_value(t, err, tui.Projection_Error.Negative_Size)
}

test_fill_writes_only_inside_the_rect :: proc(t: ^T) {
	storage: [20]tui.Cell
	buffer: tui.Cell_Buffer
	_ = tui.init(&buffer, 5, 4, storage[:])
	written := tui.fill(&buffer, {x = 1, y = 1, width = 2, height = 2}, {grapheme = "#"})
	expect_value(t, written, 4)
	expect_value(t, buffer.cells[6].grapheme, "#")
	expect_value(t, buffer.cells[7].grapheme, "#")
	expect_value(t, buffer.cells[11].grapheme, "#")
	expect_value(t, buffer.cells[12].grapheme, "#")
	expect_value(t, buffer.cells[0].grapheme, " ")
	expect_value(t, buffer.cells[8].grapheme, " ")
}

test_fill_clips_to_the_buffer :: proc(t: ^T) {
	storage: [12]tui.Cell
	buffer: tui.Cell_Buffer
	_ = tui.init(&buffer, 4, 3, storage[:])
	written := tui.fill(&buffer, {x = 2, y = 2, width = 10, height = 10}, {grapheme = "#"})
	expect_value(t, written, 2)
	written_outside := tui.fill(&buffer, {x = 40, y = 0, width = 2, height = 2}, {grapheme = "#"})
	expect_value(t, written_outside, 0)
}

test_draw_ascii_writes_at_the_rect_origin :: proc(t: ^T) {
	storage: [20]tui.Cell
	buffer: tui.Cell_Buffer
	_ = tui.init(&buffer, 5, 4, storage[:])
	style := tui.Style {
		foreground = tui.Indexed_Color(2),
		modifiers  = {.Bold},
	}
	written, ok := tui.draw_ascii(&buffer, {x = 1, y = 2, width = 4, height = 1}, "hi", style)
	expect(t, ok)
	expect_value(t, written, 2)
	expect_value(t, buffer.cells[11], tui.Cell{grapheme = "h", style = style})
	expect_value(t, buffer.cells[12], tui.Cell{grapheme = "i", style = style})
	expect_value(t, buffer.cells[13].grapheme, " ")
}

test_draw_ascii_truncates_to_the_rect :: proc(t: ^T) {
	storage: [10]tui.Cell
	buffer: tui.Cell_Buffer
	_ = tui.init(&buffer, 5, 2, storage[:])
	written, ok := tui.draw_ascii(&buffer, {x = 0, y = 0, width = 3, height = 1}, "abcdef", {})
	expect(t, ok)
	expect_value(t, written, 3)
	expect_value(t, buffer.cells[3].grapheme, " ")
}

test_draw_ascii_clips_at_the_left_edge_without_shifting_text :: proc(t: ^T) {
	// Columns removed by the clip must consume the matching characters, so the
	// visible remainder stays aligned with the rect rather than sliding left.
	storage: [10]tui.Cell
	buffer: tui.Cell_Buffer
	_ = tui.init(&buffer, 5, 2, storage[:])
	written, ok := tui.draw_ascii(&buffer, {x = -2, y = 0, width = 5, height = 1}, "abcde", {})
	expect(t, ok)
	expect_value(t, written, 3)
	expect_value(t, buffer.cells[0].grapheme, "c")
	expect_value(t, buffer.cells[1].grapheme, "d")
	expect_value(t, buffer.cells[2].grapheme, "e")
}

test_draw_ascii_outside_the_buffer_writes_nothing :: proc(t: ^T) {
	storage: [10]tui.Cell
	buffer: tui.Cell_Buffer
	_ = tui.init(&buffer, 5, 2, storage[:])
	written, ok := tui.draw_ascii(&buffer, {x = 0, y = 9, width = 5, height = 1}, "abc", {})
	expect(t, ok)
	expect_value(t, written, 0)
}

test_draw_ascii_rejects_unrepresentable_text_without_writing :: proc(t: ^T) {
	// Drawing is stricter than measurement on purpose: a substituted glyph would
	// no longer match the width the solver was handed.
	storage: [10]tui.Cell
	buffer: tui.Cell_Buffer
	_ = tui.init(&buffer, 5, 2, storage[:])
	for value in ([?]string{"ca\u00e9", "a\nb", "a\tb"}) {
		written, ok := tui.draw_ascii(&buffer, {x = 0, y = 0, width = 5, height = 1}, value, {})
		expect(t, !ok)
		expect_value(t, written, 0)
	}
	for cell in buffer.cells {
		expect_value(t, cell.grapheme, " ")
	}
}

test_ascii_measurer_reports_cells_to_layout :: proc(t: ^T) {
	measure_context := tui.ASCII_Measure_Context {
		profile = text.DEFAULT_WIDTH_PROFILE,
	}
	result, err := tui.ascii_measure_proc(&measure_context, "hello", {}, {axes = {.X = {mode = .Unbounded}, .Y = {mode = .Unbounded}}})
	expect_value(t, err, layout.Measure_Error.None)
	expect_value(t, result.size, layout.Vec2{5, 1})
}

test_ascii_measurer_clamps_to_available_width :: proc(t: ^T) {
	measure_context := tui.ASCII_Measure_Context {
		profile = text.DEFAULT_WIDTH_PROFILE,
	}
	request := layout.Measure_Request {
		axes = {.X = {mode = .At_Most, value = 4}, .Y = {mode = .Unbounded}},
	}
	result, err := tui.ascii_measure_proc(&measure_context, "hello world", {}, request)
	expect_value(t, err, layout.Measure_Error.None)
	expect_value(t, result.size, layout.Vec2{4, 1})
}

test_ascii_measurer_treats_negative_width_as_unbounded :: proc(t: ^T) {
	measure_context := tui.ASCII_Measure_Context {
		profile = text.DEFAULT_WIDTH_PROFILE,
	}
	result, err := tui.ascii_measure_proc(&measure_context, "hello", {}, {axes = {.X = {mode = .Unbounded}, .Y = {mode = .Unbounded}}})
	expect_value(t, err, layout.Measure_Error.None)
	expect_value(t, result.size, layout.Vec2{5, 1})
}

test_ascii_measurer_without_context_is_unavailable :: proc(t: ^T) {
	result, err := tui.ascii_measure_proc(nil, "hello", {}, {axes = {.X = {mode = .Unbounded}, .Y = {mode = .Unbounded}}})
	expect_value(t, err, layout.Measure_Error.Invalid_Text)
	expect_value(t, result, layout.Measure_Result{})
}

test_ascii_measurer_surfaces_rejected_text :: proc(t: ^T) {
	profile := text.DEFAULT_WIDTH_PROFILE
	profile.invalid_text = .Reject
	measure_context := tui.ASCII_Measure_Context {
		profile = profile,
	}
	_, err := tui.ascii_measure_proc(&measure_context, "caf\u00e9", {}, {axes = {.X = {mode = .Unbounded}, .Y = {mode = .Unbounded}}})
	expect_value(t, err, layout.Measure_Error.Invalid_Text)
}

test_style_maps_to_the_terminal_vocabulary :: proc(t: ^T) {
	style := tui.Style {
		foreground = tui.RGB_Color{10, 20, 30},
		background = tui.Indexed_Color(7),
		modifiers  = {.Bold, .Underline},
	}
	mapped := tui.presentation_style(style)
	expect_value(t, mapped.foreground, tty.Color(tty.RGB_Color{10, 20, 30}))
	expect_value(t, mapped.background, tty.Color(tty.Indexed_Color(7)))
	expect_value(t, mapped.modifiers, tty.Modifiers{.Bold, .Underline})
}

test_every_modifier_maps_to_a_distinct_counterpart :: proc(t: ^T) {
	// A collision here would mean two tui modifiers collapse into one terminal
	// modifier, which the total mapping exists to prevent.
	seen: tty.Modifiers
	for modifier in tui.Modifier {
		mapped := tui.presentation_modifier(modifier)
		expect(t, mapped not_in seen, "modifiers must map one to one")
		seen += {mapped}
	}
}

test_unset_and_default_colors_are_distinguished :: proc(t: ^T) {
	// nil means "inherit whatever is there"; tui.Default_Color means "reset to the
	// terminal default". Collapsing them would lose an authored reset.
	expect_value(t, tui.presentation_color(nil), tty.Color(nil))
	expect_value(t, tui.presentation_color(tui.Default_Color{}), tty.Color(tty.Default_Color{}))
}

test_build_frame_is_a_full_redraw :: proc(t: ^T) {
	storage: [6]tui.Cell
	buffer: tui.Cell_Buffer
	_ = tui.init(&buffer, 3, 2, storage[:])
	tui.put(&buffer, 1, 1, {grapheme = "x"})

	cells: [8]tty.Cell
	frame, ok := tui.build_frame(buffer, cells[:])
	expect(t, ok, "build_frame must succeed with sufficient storage")
	expect_value(t, frame.columns, 3)
	expect_value(t, frame.rows, 2)
	// (1,1) in a 3-wide buffer is index 4.
	expect_value(t, frame.cells[4].grapheme, "x")
	expect_value(t, frame.cells[0].grapheme, " ")
}

test_build_frame_refuses_undersized_storage :: proc(t: ^T) {
	storage: [6]tui.Cell
	buffer: tui.Cell_Buffer
	_ = tui.init(&buffer, 3, 2, storage[:])

	cells: [4]tty.Cell
	_, ok := tui.build_frame(buffer, cells[:])
	expect(t, !ok, "undersized storage must be refused")
}

test_build_frame_rejects_malformed_buffers_without_writing :: proc(t: ^T) {
	logical_cells: [3]tui.Cell
	buffer := tui.Cell_Buffer {
		width  = 2,
		height = 2,
		cells  = logical_cells[:],
	}
	terminal_cells := [?]tty.Cell{{grapheme = "kept", width = 1}, {}, {}, {}}
	original := terminal_cells

	_, ok := tui.build_frame(buffer, terminal_cells[:])
	expect(t, !ok)
	expect_value(t, terminal_cells, original)
}

// The C5 cross-check: layout's wrapping is driven by the real text/ breaker via
// tui.ascii_break_proc, so a frame must split lines exactly as the ASCII rules
// dictate. The layout package's own tests exercise the same rules through a
// local fixture; this test proves the two implementations agree where both are
// visible. Content_size.y is the block height = line_count * line_height.
test_ascii_break_proc_reproduces_fixture_wrapping_geometry :: proc(t: ^T) {
	measure_context := tui.ASCII_Measure_Context {
		profile = text.DEFAULT_WIDTH_PROFILE,
	}
	storage: [17135]byte
	ui: layout.Context

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
	expect_value(t, layout.init_from_buffer(&ui, config, storage[:]), nil)
	defer layout.destroy(&ui)

	// "aaa bbb" is 7 characters. At width 70 one line fits; at width 3, two.
	layout.set_services(&ui, {measure_text = tui.ascii_measure_proc, measure_text_user_data = &measure_context, break_text = tui.ascii_break_proc})
	if layout.frame(&ui, {70, 100}) {
		layout.text(&ui, layout.Text_Desc{text = "aaa bbb", style = {wrap = .Words, size = 16}, sizing = {layout.grow(), layout.fit()}})
	}
	result, err := layout.result(&ui)
	expect_value(t, err, layout.Frame_Error.None)
	node, ok := layout.node(result, layout.Node_Handle(1))
	expect(t, ok)
	// One line: content_size.y = 1 * line_height = 1.
	expect_value(t, node.content_size.y, layout.Scalar(1))

	// A width below the longest word forces a line break.
	layout.set_services(&ui, {measure_text = tui.ascii_measure_proc, measure_text_user_data = &measure_context, break_text = tui.ascii_break_proc})
	if layout.frame(&ui, {3, 100}) {
		layout.text(&ui, layout.Text_Desc{text = "aaa bbb", style = {wrap = .Words, size = 16}, sizing = {layout.grow(), layout.fit()}})
	}
	result, err = layout.result(&ui)
	expect_value(t, err, layout.Frame_Error.None)
	node, ok = layout.node(result, layout.Node_Handle(1))
	expect(t, ok)
	// Two lines: content_size.y = 2 * line_height = 2.
	expect_value(t, node.content_size.y, layout.Scalar(2))

	// CRLF collapses — "aaa\r\nbb" is two words in two hard segments.
	layout.set_services(&ui, {measure_text = tui.ascii_measure_proc, measure_text_user_data = &measure_context, break_text = tui.ascii_break_proc})
	if layout.frame(&ui, {100, 100}) {
		layout.text(&ui, layout.Text_Desc{text = "aaa\r\nbb", style = {wrap = .Words, size = 16}, sizing = {layout.grow(), layout.fit()}})
	}
	result, err = layout.result(&ui)
	expect_value(t, err, layout.Frame_Error.None)
	node, ok = layout.node(result, layout.Node_Handle(1))
	expect(t, ok)
	expect_value(t, node.content_size.y, layout.Scalar(2))

	// Wrap.None returns the whole string as one line regardless of width.
	layout.set_services(&ui, {measure_text = tui.ascii_measure_proc, measure_text_user_data = &measure_context, break_text = tui.ascii_break_proc})
	if layout.frame(&ui, {5, 100}) {
		layout.text(&ui, layout.Text_Desc{text = "aaabbbccc", style = {wrap = .None, size = 16}, sizing = {layout.grow(), layout.fit()}})
	}
	result, err = layout.result(&ui)
	expect_value(t, err, layout.Frame_Error.None)
	node, ok = layout.node(result, layout.Node_Handle(1))
	expect(t, ok)
	expect_value(t, node.content_size.y, layout.Scalar(1))
}
