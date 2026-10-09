#+build linux
#+test
#+private file
package markdown_view

import "core:strings"
import "core:testing"

import "nabla:layout"
import "nabla:markdown"
import "nabla:term"
import "nabla:text"
import "nabla:tui"

THEME :: Theme {
	code = {foreground = term.Indexed_Color(6)},
	link = {foreground = term.Indexed_Color(4), modifiers = {.Underline}},
	dim = {modifiers = {.Dim}},
	link_schemes = {"https"},
}

Rendered :: struct {
	frame:  layout.Frame_Result,
	paints: tui.Paints,
	links:  [dynamic]string,
	rows:   [dynamic]string,
}

// render declares source into a columns by rows frame and draws it into rows.
render :: proc(t: ^testing.T, rendered: ^Rendered, context_: ^layout.Context, source: string, columns, rows: int, overflow := false) {
	document, parse_error := markdown.parse(source, context.temp_allocator)
	testing.expect_value(t, parse_error, nil)
	measure := tui.Measure_Context {
		profile = text.DEFAULT_WIDTH_PROFILE,
	}
	layout.set_services(context_, tui.layout_services(&measure))
	rendered.paints = make(tui.Paints, context.temp_allocator)
	rendered.links = make([dynamic]string, context.temp_allocator)
	if layout.frame(context_, {layout.Scalar(columns), layout.Scalar(rows)}) {
		if layout.element(context_, layout.Element_Desc{layout = {sizing = {width = layout.grow(), height = layout.grow()}}}) {
			target := Target {
				ctx     = context_,
				paints  = &rendered.paints,
				links   = &rendered.links,
				columns = columns,
			}
			testing.expect_value(t, declare(target, document, THEME), nil)
		}
	}
	frame, frame_error := layout.result(context_)
	testing.expect_value(t, frame_error, layout.Frame_Error.None)
	if !overflow {
		testing.expect_value(t, len(layout.diagnostics(context_)), 0)
	}
	rendered.frame = frame

	cells := make([]term.Cell, columns * rows, context.temp_allocator)
	buffer: term.Frame_Buffer
	testing.expect(t, tui.init(&buffer, columns, rows, cells))
	testing.expect_value(t, tui.draw_commands(&buffer, rendered.paints[:], frame, {width = columns, height = rows}), tui.Draw_Error.None)
	rendered.rows = make([dynamic]string, context.temp_allocator)
	for row in 0 ..< rows {
		line := strings.builder_make(context.temp_allocator)
		for column in 0 ..< columns {
			grapheme := cells[row * columns + column].grapheme
			strings.write_string(&line, grapheme if grapheme != "" else " ")
		}
		append(&rendered.rows, strings.trim_right(strings.to_string(line), " "))
	}
}

new_context :: proc(t: ^testing.T) -> (context_: layout.Context) {
	options := layout.Options {
		capacities = {
			nodes = 256,
			children = 512,
			clips = 16,
			commands = 512,
			text_lines = 256,
			measured_words = 256,
			overlays = 4,
			measure_cache = 256,
			id_table = 16,
			depth = 32,
			diagnostics = 32,
		},
	}
	testing.expect_value(t, layout.init(&context_, options), nil)
	return context_
}

@(test)
test_paragraph_is_one_text_node_with_a_run_per_style :: proc(t: ^testing.T) {
	context_ := new_context(t)
	defer layout.destroy(&context_)
	rendered: Rendered
	render(t, &rendered, &context_, "a **b** `c` [d](https://x.io)", 40, 3)

	pieces := make([dynamic]string, context.temp_allocator)
	paints := make([dynamic]layout.Paint, context.temp_allocator)
	for command in rendered.frame.commands {
		if data, is_text := command.data.(layout.Text_Cmd); is_text {
			append(&pieces, data.text)
			append(&paints, data.paint)
		}
	}
	testing.expect_value(t, strings.join(pieces[:], "|", context.temp_allocator), "a |b| |c| |d| (https://x.io)")
	testing.expect_value(t, len(rendered.links), 1)
	testing.expect_value(t, rendered.links[0], "https://x.io")

	bold, _ := tui.paint_of(rendered.paints[:], paints[1])
	testing.expect(t, .Bold in bold.style.modifiers)
	link, _ := tui.paint_of(rendered.paints[:], paints[5])
	testing.expect_value(t, link.link, term.Link_Id(1))
	suffix, _ := tui.paint_of(rendered.paints[:], paints[6])
	testing.expect_value(t, suffix.link, term.Link_Id(1))
	plain, _ := tui.paint_of(rendered.paints[:], paints[0])
	testing.expect_value(t, plain.link, term.Link_Id(0))

	unsafe: Rendered
	render(t, &unsafe, &context_, "[bad](javascript:alert)", 40, 2)
	testing.expect_value(t, len(unsafe.links), 0)
}

@(test)
test_table_aligns_columns_and_shrinks_to_width :: proc(t: ^testing.T) {
	context_ := new_context(t)
	defer layout.destroy(&context_)
	rendered: Rendered
	render(t, &rendered, &context_, "| Name | N |\n| - | -: |\n| apple | 9 |", 20, 7)
	testing.expect_value(
		t,
		strings.join(rendered.rows[:], "\n", context.temp_allocator),
		"┌───────┬───┐\n│ Name  │ N │\n├───────┼───┤\n│ apple │ 9 │\n└───────┴───┘\n\n",
	)

	narrow: Rendered
	render(t, &narrow, &context_, "| firstlong | secondlong |\n| --- | --- |\n| abcdefgh | ijklmnop |", 16, 12)
	for row in narrow.rows {
		testing.expect(t, text.text_columns(row) <= 16)
	}
	testing.expect_value(
		t,
		strings.trim_right(strings.join(narrow.rows[:], "\n", context.temp_allocator), "\n"),
		"┌──────┬───────┐\n│ firs │ secon │\n│ tlon │ dlong │\n│ g    │       │\n├──────┼───────┤\n│ abcd │ ijklm │\n│ efgh │ nop   │\n└──────┴───────┘",
	)
}

@(test)
test_list_items_carry_their_markers :: proc(t: ^testing.T) {
	context_ := new_context(t)
	defer layout.destroy(&context_)
	rendered: Rendered
	render(t, &rendered, &context_, "9. first\n10. second\n    - child\n11. third", 20, 5)
	testing.expect_value(t, strings.join(rendered.rows[:], "\n", context.temp_allocator), " 9. first\n10. second\n    • child\n11. third\n")
}

@(test)
test_quote_has_a_bar_and_wraps_inside_it :: proc(t: ^testing.T) {
	context_ := new_context(t)
	defer layout.destroy(&context_)
	rendered: Rendered
	render(t, &rendered, &context_, "> quoted text\n> continues", 12, 4)
	testing.expect_value(t, strings.join(rendered.rows[:], "\n", context.temp_allocator), "│ quoted\n│ text\n│ continues\n")
}

@(test)
test_code_block_is_inset_and_keeps_blank_lines :: proc(t: ^testing.T) {
	context_ := new_context(t)
	defer layout.destroy(&context_)
	rendered: Rendered
	render(t, &rendered, &context_, "```odin\na\n\nb\n```", 10, 5)
	testing.expect_value(t, strings.join(rendered.rows[:], "\n", context.temp_allocator), "  odin\n  a\n\n  b\n")
}

@(test)
test_code_block_keeps_indentation_and_splits_long_lines :: proc(t: ^testing.T) {
	context_ := new_context(t)
	defer layout.destroy(&context_)
	rendered: Rendered
	render(t, &rendered, &context_, "```\nif x {\n    y  =  1\n}\nabcdefghijkl\n```", 10, 6)
	testing.expect_value(t, strings.join(rendered.rows[:], "\n", context.temp_allocator), "  if x {\n      y  =\n    1\n  }\n  abcdefgh\n  ijkl")

	url: Rendered
	render(t, &url, &context_, "see https://example.com/long", 10, 4)
	testing.expect_value(t, strings.join(url.rows[:], "\n", context.temp_allocator), "see\nhttps://ex\nample.com/\nlong")
}
