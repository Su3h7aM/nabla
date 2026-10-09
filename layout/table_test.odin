#+test
#+private file
package layout

import "core:math"
import "core:testing"

_measure_monospace :: proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	_, _, _ = user_data, style, request
	width := Scalar(10) * Scalar(len(text))
	return Measure_Result{size = {width, 20}, min_size = {width, 20}, baseline = 16}, .None
}

_break_ascii :: proc(user_data: rawptr, value: string, offset: int) -> (piece_end: int, next_offset: int, kind: Text_Break_Kind, err: Text_Break_Error) {
	_ = user_data
	for index in offset ..< len(value) {
		if value[index] == ' ' {
			return index, index + 1, .Optional, .None
		}
	}
	return len(value), len(value), .None, .None
}

_services :: proc() -> Services {
	return Services{measure_text = _measure_monospace, break_text = _break_ascii}
}

_expect_close :: proc(t: ^testing.T, actual, expected: Scalar) {
	testing.expectf(t, math.abs(actual - expected) <= SCALAR_TOLERANCE, "expected %.6f, got %.6f", expected, actual)
}

// Cells are elements holding one text node; ids are "c<row><column>".
_declare_cell :: proc(ctx: ^Context, row, column: int, value: string) {
	cell_id := id("c") + Id(row * 10 + column)
	if element(ctx, {id = cell_id, layout = {cell = true, flow = .Column, align = .Stretch}}) {
		text(ctx, {text = value})
	}
}

_cell_rect :: proc(t: ^testing.T, frame_result: Frame_Result, row, column: int) -> Rect {
	node, found := lookup(frame_result, id("c") + Id(row * 10 + column))
	testing.expect(t, found)
	return node.outer
}

@(test)
test_table_columns_align_across_rows :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	columns := []Column_Desc{{width = fit()}, {width = fit()}}
	set_services(&ctx, _services())
	if frame(&ctx, {400, 100}) {
		if table(&ctx, {}, columns) {
			if table_row(&ctx, {layout = {align = .Stretch}}) {
				_declare_cell(&ctx, 0, 0, "aa")
				_declare_cell(&ctx, 0, 1, "b")
			}
			if table_row(&ctx, {layout = {align = .Stretch}}) {
				_declare_cell(&ctx, 1, 0, "cccc")
				_declare_cell(&ctx, 1, 1, "dd")
			}
		}
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	testing.expect_value(t, len(diagnostics(&ctx)), 0)
	for row in 0 ..< 2 {
		testing.expect_value(t, _cell_rect(t, frame_result, row, 0).position.x, 0)
		testing.expect_value(t, _cell_rect(t, frame_result, row, 0).size.x, 40)
		testing.expect_value(t, _cell_rect(t, frame_result, row, 1).position.x, 40)
		testing.expect_value(t, _cell_rect(t, frame_result, row, 1).size.x, 20)
	}
}

@(test)
test_table_grow_column_takes_remaining_width :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	columns := []Column_Desc{{width = fit()}, {width = grow()}, {width = grow(3, 0, 50)}}
	set_services(&ctx, _services())
	if frame(&ctx, {400, 100}) {
		if table(&ctx, {layout = {sizing = {width = fixed(200), height = fit()}}}, columns) {
			if table_row(&ctx, {layout = {align = .Stretch}}) {
				_declare_cell(&ctx, 0, 0, "aaaa")
				_declare_cell(&ctx, 0, 1, "b")
				_declare_cell(&ctx, 0, 2, "c")
			}
		}
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	// 200 - 40 - 10 - 10 = 140 spare; the weight 3 column stops at 50 and the
	// other grow column takes the rest.
	_expect_close(t, _cell_rect(t, frame_result, 0, 0).size.x, 40)
	_expect_close(t, _cell_rect(t, frame_result, 0, 2).size.x, 50)
	_expect_close(t, _cell_rect(t, frame_result, 0, 1).size.x, 110)
	_expect_close(t, _cell_rect(t, frame_result, 0, 2).position.x, 150)
}

@(test)
test_table_shrinks_wrapping_columns_in_proportion_to_slack :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	// Column widths ask 110 (floor 30), 70 (floor 30) and 10 (cannot wrap).
	columns := []Column_Desc{{width = fit()}, {width = fit()}, {width = fit()}}
	set_services(&ctx, _services())
	if frame(&ctx, {400, 100}) {
		if table(&ctx, {layout = {sizing = {width = fixed(110), height = fit()}}}, columns) {
			if table_row(&ctx, {layout = {align = .Stretch}}) {
				_declare_cell(&ctx, 0, 0, "aaa bbb ccc")
				_declare_cell(&ctx, 0, 1, "ddd eee")
				_declare_cell(&ctx, 0, 2, "x")
			}
			if table_row(&ctx, {layout = {align = .Stretch}}) {
				_declare_cell(&ctx, 1, 0, "a")
				_declare_cell(&ctx, 1, 1, "d")
				_declare_cell(&ctx, 1, 2, "x")
			}
		}
	}
	frame_result, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	// 190 asked for 110: slack 80 + 40 gives up 110 * 2/3 ... deficit 80 over
	// slack 120, so the columns lose 53.33 and 26.67 and the last keeps 10.
	_expect_close(t, _cell_rect(t, frame_result, 0, 0).size.x, 110 - 80 * 80.0 / 120)
	_expect_close(t, _cell_rect(t, frame_result, 0, 1).size.x, 70 - 40 * 80.0 / 120)
	_expect_close(t, _cell_rect(t, frame_result, 0, 2).size.x, 10)
	_expect_close(t, _cell_rect(t, frame_result, 1, 1).position.x, _cell_rect(t, frame_result, 0, 1).position.x)
	// Wrapped text makes the first row taller than the second.
	testing.expect(t, _cell_rect(t, frame_result, 0, 0).size.y > _cell_rect(t, frame_result, 1, 0).size.y)
	testing.expect_value(t, _cell_rect(t, frame_result, 0, 2).size.y, _cell_rect(t, frame_result, 0, 0).size.y)
}

@(test)
test_table_row_cell_count_mismatch_is_diagnosed :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	columns := []Column_Desc{{width = fit()}, {width = fit()}}
	set_services(&ctx, _services())
	if frame(&ctx, {400, 100}) {
		if table(&ctx, {}, columns) {
			if table_row(&ctx, {}) {
				_declare_cell(&ctx, 0, 0, "a")
				_declare_cell(&ctx, 0, 1, "b")
			}
			if table_row(&ctx, {}) {
				_declare_cell(&ctx, 1, 0, "a")
			}
		}
	}
	_, frame_error := result(&ctx)
	testing.expect_value(t, frame_error, Frame_Error.None)
	found := 0
	for diagnostic in diagnostics(&ctx) {
		if diagnostic.kind == .Table_Cell_Count {
			found += 1
			testing.expect_value(t, diagnostic.node, Node_Handle(7))
			testing.expect_value(t, diagnostic.amount, 1)
		}
	}
	testing.expect_value(t, found, 1)
}
