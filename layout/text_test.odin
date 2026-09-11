#+test
#+private file
package layout

import "core:math"
import "core:testing"

// Deterministic monospace metrics: one cell per byte and one line tall, so
// wrapping arithmetic is exact.
CHARACTER_WIDTH :: Scalar(10)
LINE_HEIGHT :: Scalar(20)

_measure_monospace :: proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	_, _, _ = user_data, style, request
	width := CHARACTER_WIDTH * Scalar(len(text))
	return Measure_Result{size = {width, LINE_HEIGHT}, min_size = {width, LINE_HEIGHT}, baseline = LINE_HEIGHT * 0.8}, .None
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
			if value[index] == '\r' && index + 1 < len(value) && value[index + 1] == '\n' {
				return index, index + 2, .Mandatory, .None
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

_expect_close :: proc(t: ^testing.T, actual, expected: Scalar) {
	testing.expectf(t, math.abs(actual - expected) <= SCALAR_TOLERANCE, "expected %.6f, got %.6f", expected, actual)
}

_text_lines_of :: proc(ctx: ^Context, node: Node_Handle) -> []_Text_Line_Record {
	state := _context_state(ctx)
	input := state._node_inputs[node]
	return state._text_lines[input.text_line_start:input.text_line_start + input.text_line_count]
}

@(test)
test_text_wrapping_and_line_geometry :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	// An unwrapped run measures one line and records its baseline.
	set_services(&ctx, _services())
	if frame(&ctx, {500, 200}) {
		if element(&ctx, {layout = {sizing = {fit(), fit()}}}) {
			text(&ctx, {text = "hello world"})
		}
	}
	unwrapped, unwrapped_error := result(&ctx)
	testing.expect_value(t, unwrapped_error, Frame_Error.None)
	block := unwrapped.nodes[2]
	testing.expect(t, block.flags.is_text)
	_expect_close(t, block.outer.size.x, 110)
	_expect_close(t, block.outer.size.y, LINE_HEIGHT)
	lines := _text_lines_of(&ctx, 2)
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, lines[0].text, "hello world")
	_expect_close(t, lines[0].baseline, LINE_HEIGHT * 0.8)

	// Words wrap greedily at the resolved width.
	set_services(&ctx, _services())
	if frame(&ctx, {400, 400}) {
		if element(&ctx, {layout = {sizing = {fixed(100), fit()}}}) {
			text(&ctx, {text = "aaa bbb ccc ddd"})
		}
	}
	wrapped, wrapped_error := result(&ctx)
	testing.expect_value(t, wrapped_error, Frame_Error.None)
	lines = _text_lines_of(&ctx, 2)
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0].text, "aaa bbb")
	testing.expect_value(t, lines[1].text, "ccc ddd")
	_expect_close(t, wrapped.nodes[1].outer.size.y, LINE_HEIGHT * 2)

	// A block taller than its box exposes the wrapped height as scrollable.
	set_services(&ctx, _services())
	if frame(&ctx, {400, 400}) {
		if element(&ctx, {layout = {flow = .Column, sizing = {fixed(100), fixed(30)}}}) {
			text(&ctx, {text = "aaa bbb ccc", sizing = {grow(), fit()}})
		}
	}
	scrolled, scrolled_error := result(&ctx)
	testing.expect_value(t, scrolled_error, Frame_Error.None)
	testing.expect(t, scrolled.nodes[1].flags.overflow_y)
	_expect_close(t, scrolled.nodes[1].scroll_range.y, LINE_HEIGHT * 2 - 30)

	// A hard break opens a new line, including empty segments; a trailing one
	// leaves an empty final line, and an empty string still occupies one line.
	set_services(&ctx, _services())
	if frame(&ctx, {500, 500}) {
		text(&ctx, {text = "ab\n\ncd", sizing = {fit(), fit()}})
		text(&ctx, {text = "ab\n", sizing = {fit(), fit()}})
		text(&ctx, {text = "", sizing = {fit(), fit()}})
	}
	hard, hard_error := result(&ctx)
	testing.expect_value(t, hard_error, Frame_Error.None)
	lines = _text_lines_of(&ctx, 1)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[0].text, "ab")
	testing.expect_value(t, lines[1].text, "")
	testing.expect_value(t, lines[2].text, "cd")
	testing.expect_value(t, len(_text_lines_of(&ctx, 2)), 2)
	_expect_close(t, hard.nodes[3].outer.size.y, LINE_HEIGHT)

	// Wrap.None overflows instead of shrinking.
	set_services(&ctx, _services())
	if frame(&ctx, {500, 500}) {
		if element(&ctx, {layout = {sizing = {fixed(40), fit()}}}) {
			text(&ctx, {text = "aaaaaaaa", style = {wrap = .None}, sizing = {grow(), fit()}})
		}
	}
	no_wrap, no_wrap_error := result(&ctx)
	testing.expect_value(t, no_wrap_error, Frame_Error.None)
	_expect_close(t, no_wrap.nodes[2].outer.size.x, 80)
	testing.expect(t, no_wrap.nodes[1].flags.overflow_x)

	// Wrap.Words shrinks to the longest unbreakable run.
	set_services(&ctx, _services())
	if frame(&ctx, {500, 500}) {
		if element(&ctx, {layout = {sizing = {fixed(30), fit()}}}) {
			text(&ctx, {text = "aaaaa bb"})
		}
	}
	shrunk, shrunk_error := result(&ctx)
	testing.expect_value(t, shrunk_error, Frame_Error.None)
	_expect_close(t, shrunk.nodes[2].outer.size.x, 50)
	testing.expect_value(t, len(_text_lines_of(&ctx, 2)), 2)

	// Alignment positions lines inside the block.
	set_services(&ctx, _services())
	if frame(&ctx, {500, 500}) {
		if element(&ctx, {layout = {sizing = {fixed(100), fit()}}}) {
			text(&ctx, {text = "aaa bbbb", style = {align = .End}, sizing = {grow(), fit()}})
		}
	}
	aligned, aligned_error := result(&ctx)
	testing.expect_value(t, aligned_error, Frame_Error.None)
	_expect_close(t, aligned.nodes[2].outer.size.x, 100)
	_expect_close(t, _text_lines_of(&ctx, 2)[0].position.x, 20)

	// An explicit line height overrides the metrics for the block and records.
	set_services(&ctx, _services())
	if frame(&ctx, {500, 500}) {
		text(&ctx, {text = "aa bb", style = {line_height = 32}, sizing = {fixed(30), fit()}})
	}
	tall, tall_error := result(&ctx)
	testing.expect_value(t, tall_error, Frame_Error.None)
	_expect_close(t, tall.nodes[1].outer.size.y, 64)
	lines = _text_lines_of(&ctx, 1)
	_expect_close(t, lines[1].position.y, 32)
}

@(test)
test_text_measurement_cache_and_missing_services :: proc(t: ^testing.T) {
	calls := 0
	counter := &calls
	measure_counting :: proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
		(^int)(user_data)^ += 1
		return _measure_monospace(nil, text, style, request)
	}

	// Measurements are reused across frames until metrics are invalidated.
	ctx: Context
	services := _services()
	services.measure_text = measure_counting
	services.measure_text_user_data = counter
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	declare :: proc(ctx: ^Context, services: Services) {
		set_services(ctx, services)
		if frame(ctx, {500, 500}) {
			text(ctx, {text = "aaa bbb ccc", sizing = {fixed(100), fit()}})
		}
	}

	declare(&ctx, services)
	_, first_error := result(&ctx)
	testing.expect_value(t, first_error, Frame_Error.None)
	first_calls := calls
	testing.expect(t, first_calls > 0)

	declare(&ctx, services)
	_, second_error := result(&ctx)
	testing.expect_value(t, second_error, Frame_Error.None)
	testing.expect_value(t, calls, first_calls)

	invalidate_metrics(&ctx, 1)
	declare(&ctx, services)
	_, third_error := result(&ctx)
	testing.expect_value(t, third_error, Frame_Error.None)
	testing.expect(t, calls > first_calls)

	// The seams are required where they are needed: no measurer means no
	// geometry, and a wrapping node with no breaker must not fall back.
	{
		ctx_missing: Context
		missing := _services()
		missing.measure_text = nil
		testing.expect_value(t, init(&ctx_missing, _test_options()), nil)
		defer destroy(&ctx_missing)
		set_services(&ctx_missing, missing)
		if frame(&ctx_missing, {100, 100}) {
			text(&ctx_missing, {text = "hello"})
		}
		frame_result, frame_error := result(&ctx_missing)
		testing.expect_value(t, frame_error, Frame_Error.Missing_Text_Measurer)
		testing.expect_value(t, len(frame_result.nodes), 0)
	}
	{
		ctx_missing: Context
		missing := _services()
		missing.break_text = nil
		testing.expect_value(t, init(&ctx_missing, _test_options()), nil)
		defer destroy(&ctx_missing)
		set_services(&ctx_missing, missing)
		if frame(&ctx_missing, {100, 100}) {
			text(&ctx_missing, {text = "hello"})
		}
		frame_result, frame_error := result(&ctx_missing)
		testing.expect_value(t, frame_error, Frame_Error.Missing_Text_Breaker)
		testing.expect_value(t, len(frame_result.nodes), 0)
	}
}
