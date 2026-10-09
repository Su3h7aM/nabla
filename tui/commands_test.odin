#+build linux
#+test
#+private file
package tui

import "core:testing"

import "nabla:layout"
import "nabla:term"
import width_text "nabla:text"

_COMMANDS_TEST_OPTIONS :: layout.Options {
	capacities = {
		nodes = 8,
		children = 8,
		clips = 4,
		commands = 16,
		text_lines = 8,
		measured_words = 16,
		overlays = 1,
		measure_cache = 8,
		id_table = 8,
		depth = 8,
		diagnostics = 8,
	},
}

@(test)
test_draw_commands_paints_fill_border_and_text_into_target :: proc(t: ^testing.T) {
	layout_ctx: layout.Context
	testing.expect_value(t, layout.init(&layout_ctx, _COMMANDS_TEST_OPTIONS), nil)
	defer layout.destroy(&layout_ctx)
	measure_context := Measure_Context {
		profile = width_text.DEFAULT_WIDTH_PROFILE,
	}
	layout.set_services(&layout_ctx, layout_services(&measure_context))

	paints: Paints
	defer delete(paints)
	fill_style := term.Style {
		background = term.Indexed_Color(4),
	}
	fill_paint, _ := paint(&paints, {style = fill_style, fill = "."})
	border_paint, _ := paint(&paints, {border = BORDER_SINGLE})
	text_paint, _ := paint(&paints, {style = {modifiers = {.Bold}}, link = 1})

	if layout.frame(&layout_ctx, {6, 4}) {
		if layout.element(
			&layout_ctx,
			layout.Element_Desc {
				layout = {sizing = {layout.grow(), layout.grow()}, padding = layout.pad_all(1)},
				paint = {background = fill_paint, border = {paint = border_paint, width = layout.pad_all(1)}},
			},
		) {
			layout.text(&layout_ctx, layout.Text_Desc{text = "hi", style = {size = 1, wrap = .None}, paint = text_paint})
			layout.text(&layout_ctx, layout.Text_Desc{text = "xy", style = {size = 1, wrap = .None}})
		}
	}
	solved, layout_error := layout.result(&layout_ctx)
	testing.expect_value(t, layout_error, layout.Frame_Error.None)

	cells: [10 * 6]term.Cell
	buffer: term.Frame_Buffer
	testing.expect(t, init(&buffer, 10, 6, cells[:]))
	target := Cell_Rect {
		x      = 2,
		y      = 1,
		width  = 6,
		height = 4,
	}
	testing.expect_value(t, draw_commands(&buffer, paints[:], solved, target), Draw_Error.None)

	at :: proc(buffer: term.Frame_Buffer, x, y: int) -> term.Cell {
		return buffer.cells[y * buffer.columns + x]
	}
	testing.expect_value(t, at(buffer, 2, 1).grapheme, "┌")
	testing.expect_value(t, at(buffer, 7, 4).grapheme, "┘")
	testing.expect_value(t, at(buffer, 3, 1).grapheme, "─")
	testing.expect_value(t, at(buffer, 2, 2).grapheme, "│")
	testing.expect_value(t, at(buffer, 3, 2).grapheme, "h")
	testing.expect_value(t, at(buffer, 3, 2).link, term.Link_Id(1))
	testing.expect_value(t, at(buffer, 6, 2).grapheme, ".")
	testing.expect_value(t, at(buffer, 1, 1).grapheme, " ")
	testing.expect_value(t, at(buffer, 3, 3).grapheme, ".")
}

@(test)
test_draw_commands_blank_border_glyph_is_space_and_wide_glyph_is_invalid :: proc(t: ^testing.T) {
	layout_ctx: layout.Context
	testing.expect_value(t, layout.init(&layout_ctx, _COMMANDS_TEST_OPTIONS), nil)
	defer layout.destroy(&layout_ctx)

	if layout.frame(&layout_ctx, {3, 3}) {
		_ = layout.element(
			&layout_ctx,
			layout.Element_Desc{layout = {sizing = {layout.grow(), layout.grow()}}, paint = {border = {paint = 1, width = layout.pad_all(1)}}},
		)
	}
	solved, layout_error := layout.result(&layout_ctx)
	testing.expect_value(t, layout_error, layout.Frame_Error.None)

	cells: [3 * 3]term.Cell
	buffer: term.Frame_Buffer
	testing.expect(t, init(&buffer, 3, 3, cells[:]))
	paints: Paints
	defer delete(paints)
	_, _ = paint(&paints, {border = {top_left = "+"}})

	testing.expect_value(t, draw_commands(&buffer, paints[:1], solved, {width = 3, height = 3}), Draw_Error.None)
	testing.expect_value(t, buffer.cells[0].grapheme, "+")
	testing.expect_value(t, buffer.cells[1].grapheme, " ")

	paints[0].border.top_left = "界"
	testing.expect_value(t, draw_commands(&buffer, paints[:1], solved, {width = 3, height = 3}), Draw_Error.Invalid_Border)
}
_and_paint_of_rejects_unknown_ids :: proc(t: ^testing.T) {
	paints: Paints
	defer delete(paints)
	first, first_error := paint(&paints, {})
	testing.expect_value(t, first_error, nil)
	testing.expect_value(t, first, layout.Paint(1))
	_, found := paint_of(paints[:], 0)
	testing.expect(t, !found)
	_, found = paint_of(paints[:], 2)
	testing.expect(t, !found)
}
