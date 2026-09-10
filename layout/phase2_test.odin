#+test
#+private file
package layout

import "core:math"
import "core:mem"
import "core:testing"

/*
Deterministic monospace metrics: every rune is `CHARACTER_WIDTH` wide and every
line is `LINE_HEIGHT` tall. This makes wrapping arithmetic exact, so the tests
assert real geometry instead of tolerances around a real font.
*/
CHARACTER_WIDTH :: Scalar(10)
LINE_HEIGHT :: Scalar(20)

Measure_Log :: struct {
	calls:            int,
	requested_widths: [64]Scalar,
	request_count:    int,
}

_measure_monospace :: proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	if user_data != nil {
		log := (^Measure_Log)(user_data)
		log.calls += 1
		if log.request_count < len(log.requested_widths) {
			log.requested_widths[log.request_count] = request.axes[.X].value
			log.request_count += 1
		}
	}
	_ = style
	width := CHARACTER_WIDTH * Scalar(len(text))
	return Measure_Result{size = {width, LINE_HEIGHT}, min_size = {width, LINE_HEIGHT}, baseline = LINE_HEIGHT * 0.8}, .None
}

_measure_failing :: proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	_, _, _, _ = user_data, text, style, request
	return {}, .Invalid_Constraint
}

_custom_measure_failing :: proc(user_data: rawptr, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	_ = user_data
	_ = request
	return {}, .Invalid_Constraint
}

// A malformed breaker: at the end of the text it reports an Optional break
// instead of .None, forever. The EOF contract requires .None when
// piece_end == len(text); the guard must fail the frame rather than let the
// wrapping loop spin on this result.
_break_stalls_at_eof :: proc(
	user_data: rawptr,
	value: string,
	offset: int,
) -> (
	piece_end: int,
	next_offset: int,
	kind: Text_Break_Kind,
	err: Text_Break_Error,
) {
	piece_end = len(value)
	next_offset = len(value)
	kind = .Optional
	err = .None
	return
}

// A malformed breaker: it reports .None before the end of the text. The
// contract allows .None only when piece_end == len(text); an early .None would
// make the wrapping loops treat the remaining text as already consumed and
// publish a successful frame with the suffix silently discarded.
_break_ends_early :: proc(user_data: rawptr, value: string, offset: int) -> (piece_end: int, next_offset: int, kind: Text_Break_Kind, err: Text_Break_Error) {
	piece_end = offset + 2
	next_offset = piece_end + 1
	kind = .None
	err = .None
	return
}

_phase2_services :: proc(log: ^Measure_Log = nil) -> Services {
	return Services{measure_text = _measure_monospace, measure_text_user_data = log, break_text = _ascii_break_fixture}
}

_phase2_config :: proc(log: ^Measure_Log = nil) -> Options {
	return Options {
		capacities = {
			nodes = 64,
			children = 64,
			clips = 16,
			commands = 64,
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

_expect_close :: proc(t: ^testing.T, actual, expected: Scalar) {
	testing.expectf(t, math.abs(actual - expected) <= SCALAR_TOLERANCE, "expected %.6f, got %.6f", expected, actual)
}

_text_lines_of :: proc(ctx: ^Context, node: Node_Handle) -> []_Text_Line_Record {
	state := _context_state(ctx)
	input := state._node_inputs[node]
	return state._text_lines[input.text_line_start:input.text_line_start + input.text_line_count]
}

@(test)
test_phase2_unwrapped_text_block_geometry :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 200}) {
		if element(&ui, Element_Desc{layout = {sizing = {fit(), fit()}}}) {
			text(&ui, Text_Desc{text = "hello world"})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(frame_result.nodes), 3)

	// "hello world" is 11 characters and fits, so it is one line.
	block := frame_result.nodes[2]
	testing.expect(t, block.flags.is_text)
	_expect_close(t, block.outer.size.x, 110)
	_expect_close(t, block.outer.size.y, LINE_HEIGHT)

	lines := _text_lines_of(&ui, 2)
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, lines[0].text, "hello world")
	testing.expect_value(t, lines[0].line, u16(0))
	_expect_close(t, lines[0].baseline, LINE_HEIGHT * 0.8)
	_expect_close(t, lines[0].position.x, 0)
	_expect_close(t, lines[0].position.y, 0)
}

@(test)
test_phase2_word_wrapping_at_resolved_width :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config()), nil)
	defer destroy(&ui)

	// Width 100 fits "aaa bbb" (7 chars = 70) but not "aaa bbb ccc" (110).
	set_services(&ui, _phase2_services())
	if frame(&ui, {400, 400}) {
		if element(&ui, Element_Desc{layout = {sizing = {fixed(100), fit()}}}) {
			text(&ui, Text_Desc{text = "aaa bbb ccc ddd"})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	lines := _text_lines_of(&ui, 2)
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0].text, "aaa bbb")
	testing.expect_value(t, lines[1].text, "ccc ddd")
	testing.expect_value(t, lines[1].line, u16(1))
	_expect_close(t, lines[1].position.y, LINE_HEIGHT)

	// The parent height fits both lines, propagated through its Fit height.
	_expect_close(t, frame_result.nodes[1].outer.size.y, LINE_HEIGHT * 2)
	_expect_close(t, frame_result.nodes[2].outer.size.y, LINE_HEIGHT * 2)
}

@(test)
test_phase2_hard_newlines_and_empty_segments :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		text(&ui, Text_Desc{text = "ab\n\ncd", sizing = {fit(), fit()}})
	}
	_, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	lines := _text_lines_of(&ui, 1)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[0].text, "ab")
	testing.expect_value(t, lines[1].text, "")
	testing.expect_value(t, lines[2].text, "cd")
	_expect_close(t, lines[2].position.y, LINE_HEIGHT * 2)
}

@(test)
test_phase2_wrap_none_overflows_instead_of_shrinking :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		if element(&ui, Element_Desc{layout = {sizing = {fixed(40), fit()}}}) {
			text(&ui, Text_Desc{text = "aaaaaaaa", style = {wrap = .None}, sizing = {grow(), fit()}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// The run is 80 wide inside a 40 wide parent and refuses to compress.
	_expect_close(t, frame_result.nodes[2].outer.size.x, 80)
	testing.expect(t, frame_result.nodes[1].flags.overflow_x)

	lines := _text_lines_of(&ui, 2)
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, lines[0].text, "aaaaaaaa")
}

@(test)
test_phase2_wrap_words_shrinks_to_longest_word :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		if element(&ui, Element_Desc{layout = {sizing = {fixed(30), fit()}}}) {
			text(&ui, Text_Desc{text = "aaaaa bb"})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// The shrink floor is the longest unbreakable run: "aaaaa" is 50 wide.
	_expect_close(t, frame_result.nodes[2].outer.size.x, 50)
	lines := _text_lines_of(&ui, 2)
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0].text, "aaaaa")
	testing.expect_value(t, lines[1].text, "bb")
}

@(test)
test_phase2_line_alignment_positions_lines_only :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		if element(&ui, Element_Desc{layout = {sizing = {fixed(100), fit()}}}) {
			text(&ui, Text_Desc{text = "aaa bbbb", style = {align = .End}, sizing = {grow(), fit()}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// One line of 8 characters right-aligned in a 100 wide block.
	_expect_close(t, frame_result.nodes[2].outer.size.x, 100)
	lines := _text_lines_of(&ui, 2)
	testing.expect_value(t, len(lines), 1)
	_expect_close(t, lines[0].position.x, 20)
}

@(test)
test_phase2_explicit_line_height_overrides_metrics :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		text(&ui, Text_Desc{text = "aa bb", style = {line_height = 32}, sizing = {fixed(30), fit()}})
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	_expect_close(t, frame_result.nodes[1].outer.size.y, 64)
	lines := _text_lines_of(&ui, 1)
	testing.expect_value(t, len(lines), 2)
	_expect_close(t, lines[1].position.y, 32)
	_expect_close(t, lines[0].size.y, 32)
}

// Release-mode regression for the EOF contract: in debug builds the contract
// violation is caught by the assert inside _break_text, so this test only runs
// where the frame-error path is the defense. A breaker that reports a non-.None
// kind at the end of the text used to pass the progress guard
// (piece_end == len(text)) and then repeat forever, hanging release builds.
// The frame must fail with Text_Break_Stalled instead of spinning.
when !ODIN_DEBUG {
	@(test)
	test_phase2_breaker_stalled_at_eof_fails_the_frame :: proc(t: ^testing.T) {
		ui: Context
		config := _phase2_config()
		services := _phase2_services()
		services.break_text = _break_stalls_at_eof

		testing.expect_value(t, init(&ui, config), nil)
		defer destroy(&ui)

		set_services(&ui, services)
		if frame(&ui, {100, 100}) {
			text(&ui, Text_Desc{text = "aa bb", style = {wrap = .Words}})
		}
		frame_result, err := result(&ui)
		testing.expect_value(t, err, Frame_Error.Text_Break_Stalled)
		testing.expect_value(t, len(frame_result.nodes), 0)
		testing.expect_value(t, statistics(&ui).frames_failed, u64(1))

		found := false
		for diagnostic in diagnostics(&ui) {
			if diagnostic.kind == .Text_Break_Stalled {
				found = true
			}
		}
		testing.expect(t, found)
	}
}

// Release-mode regression for the reverse EOF direction: a breaker that
// reports .None before the end of the text used to pass the guard and let the
// loops publish a successful frame with the remaining text silently dropped.
// In debug builds the assert inside _break_text catches the violation first, so
// this test only runs where the frame-error path is the defense. The frame must
// fail with Text_Break_Stalled instead of truncating.
when !ODIN_DEBUG {
	@(test)
	test_phase2_breaker_ends_early_fails_the_frame :: proc(t: ^testing.T) {
		ui: Context
		config := _phase2_config()
		services := _phase2_services()
		services.break_text = _break_ends_early

		testing.expect_value(t, init(&ui, config), nil)
		defer destroy(&ui)

		set_services(&ui, services)
		if frame(&ui, {100, 100}) {
			text(&ui, Text_Desc{text = "aa bb", style = {wrap = .Words}})
		}
		frame_result, err := result(&ui)
		testing.expect_value(t, err, Frame_Error.Text_Break_Stalled)
		testing.expect_value(t, len(frame_result.nodes), 0)
		testing.expect_value(t, statistics(&ui).frames_failed, u64(1))

		found := false
		for diagnostic in diagnostics(&ui) {
			if diagnostic.kind == .Text_Break_Stalled {
				found = true
			}
		}
		testing.expect(t, found)
	}
}

@(test)
test_phase2_missing_measurer_fails_the_frame :: proc(t: ^testing.T) {
	ui: Context
	config := _phase2_config()
	services := _phase2_services()
	services.measure_text = nil
	testing.expect_value(t, init(&ui, config), nil)
	defer destroy(&ui)

	set_services(&ui, services)
	if frame(&ui, {100, 100}) {
		text(&ui, Text_Desc{text = "hello"})
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.Missing_Text_Measurer)
	testing.expect_value(t, len(frame_result.nodes), 0)
	testing.expect_value(t, statistics(&ui).frames_failed, u64(1))
}

@(test)
test_phase2_missing_breaker_fails_the_frame :: proc(t: ^testing.T) {
	// The required nil policy: break_text is required exactly where measure_text
	// is. A frame declaring text with a valid measurer but no breaker must fail
	// with Missing_Text_Breaker rather than fall back to ASCII or publish
	// geometry.
	ui: Context
	config := _phase2_config()
	services := _phase2_services()
	services.break_text = nil
	testing.expect_value(t, init(&ui, config), nil)
	defer destroy(&ui)

	set_services(&ui, services)
	if frame(&ui, {100, 100}) {
		text(&ui, Text_Desc{text = "hello"})
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.Missing_Text_Breaker)
	testing.expect_value(t, len(frame_result.nodes), 0)
	testing.expect_value(t, statistics(&ui).frames_failed, u64(1))
}

@(test)
test_phase2_measurement_failure_records_a_diagnostic :: proc(t: ^testing.T) {
	ui: Context
	config := _phase2_config()
	services := _phase2_services()
	services.measure_text = _measure_failing
	testing.expect_value(t, init(&ui, config), nil)
	defer destroy(&ui)

	set_services(&ui, services)
	if frame(&ui, {100, 100}) {
		text(&ui, Text_Desc{text = "hello"})
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.Measure_Failed)
	testing.expect_value(t, len(frame_result.nodes), 0)

	found := false
	for diagnostic in diagnostics(&ui) {
		if diagnostic.kind == .Measure_Failed {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
test_phase2_custom_measurement_failure_fails_the_frame :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase2_services())
	if frame(&ui, {100, 100}) {
		content(&ui, Element_Desc{content = Custom_Content{measure = _custom_measure_failing}})
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.Measure_Failed)
	testing.expect_value(t, len(frame_result.nodes), 0)

	found := false
	for diagnostic in diagnostics(&ui) {
		if diagnostic.kind == .Measure_Failed {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
test_phase2_cache_reuses_measurements_across_frames :: proc(t: ^testing.T) {
	log: Measure_Log
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config(&log)), nil)
	defer destroy(&ui)

	declare :: proc(ui: ^Context, log: ^Measure_Log) {
		set_services(ui, _phase2_services(log))
		if frame(ui, {500, 500}) {
			text(ui, Text_Desc{text = "aaa bbb ccc", sizing = {fixed(100), fit()}})
		}
	}

	declare(&ui, &log)
	_, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	first_frame_calls := log.calls
	testing.expect(t, first_frame_calls > 0)

	declare(&ui, &log)
	_, err = result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, log.calls, first_frame_calls)

	// Explicit invalidation must force a full remeasure.
	invalidate_metrics(&ui, 1)
	declare(&ui, &log)
	_, err = result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect(t, log.calls > first_frame_calls)
}

@(test)
test_phase2_cache_key_separates_wrap_and_line_height :: proc(t: ^testing.T) {
	log: Measure_Log
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config(&log)), nil)
	defer destroy(&ui)

	// Same string and width, differing only in wrap mode and line height: the
	// entries must not collide, so wrapping stays independent per style.
	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		text(&ui, Text_Desc{text = "aaa bbb", style = {wrap = .Words}, sizing = {fixed(40), fit()}})
		text(&ui, Text_Desc{text = "aaa bbb", style = {wrap = .None}, sizing = {fixed(40), fit()}})
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	testing.expect_value(t, len(_text_lines_of(&ui, 1)), 2)
	testing.expect_value(t, len(_text_lines_of(&ui, 2)), 1)
	_expect_close(t, frame_result.nodes[1].outer.size.y, LINE_HEIGHT * 2)
	_expect_close(t, frame_result.nodes[2].outer.size.y, LINE_HEIGHT)
}

@(test)
test_phase2_reflow_receives_the_resolved_width :: proc(t: ^testing.T) {
	log: Measure_Log
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config(&log)), nil)
	defer destroy(&ui)

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		if element(&ui, Element_Desc{layout = {sizing = {fixed(200), fit()}, padding = pad_all(10)}}) {
			text(&ui, Text_Desc{text = "aa bb cc dd ee ff", sizing = {grow(), fit()}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// The block grows into 180 of inner width; 17 characters would need 170,
	// so it stays on one line and the height does not grow.
	_expect_close(t, frame_result.nodes[2].outer.size.x, 180)
	testing.expect_value(t, len(_text_lines_of(&ui, 2)), 1)
	_expect_close(t, frame_result.nodes[1].outer.size.y, LINE_HEIGHT + 20)
}

@(test)
test_phase2_text_lines_capacity_fails_the_frame :: proc(t: ^testing.T) {
	ui: Context
	config := _phase2_config()
	config.capacities.text_lines = 2
	testing.expect_value(t, init(&ui, config), nil)
	defer destroy(&ui)

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		text(&ui, Text_Desc{text = "a b c d e", sizing = {fixed(10), fit()}})
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.Capacity_Exhausted)
	testing.expect_value(t, len(frame_result.nodes), 0)

	found := false
	for diagnostic in diagnostics(&ui) {
		if diagnostic.kind == .Pool_Exhausted && diagnostic.pool == .Text_Lines {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
test_phase2_text_participates_in_flow_and_scroll_metrics :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		if element(&ui, Element_Desc{layout = {flow = .Column, sizing = {fixed(100), fixed(30)}}}) {
			text(&ui, Text_Desc{text = "aaa bbb ccc", sizing = {grow(), fit()}})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// Two lines of content in a 30 tall box: the block reports the overflow it
	// cannot absorb, and the scroll range exposes the hidden extent.
	block := frame_result.nodes[2]
	_expect_close(t, block.content_size.y, LINE_HEIGHT * 2)
	testing.expect(t, frame_result.nodes[1].flags.overflow_y)
	_expect_close(t, frame_result.nodes[1].scroll_range.y, LINE_HEIGHT * 2 - 30)
}

@(test)
test_phase2_static_flag_keys_on_pointer_identity :: proc(t: ^testing.T) {
	log: Measure_Log
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config(&log)), nil)
	defer destroy(&ui)

	STATIC_TEXT :: "aaa bbb ccc"
	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		text(&ui, Text_Desc{text = STATIC_TEXT, flags = {.Static}, sizing = {fixed(100), fit()}})
	}
	_, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	first_frame_calls := log.calls

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		text(&ui, Text_Desc{text = STATIC_TEXT, flags = {.Static}, sizing = {fixed(100), fit()}})
	}
	_, err = result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, log.calls, first_frame_calls)
}

@(test)
test_phase2_text_allocates_nothing_in_fixed_mode :: proc(t: ^testing.T) {
	config := _phase2_config()
	storage := make([]byte, storage_size(config.capacities))
	defer delete(storage)

	ui: Context
	context.allocator = mem.panic_allocator()
	testing.expect_value(t, init_from_buffer(&ui, config, storage), nil)
	defer destroy(&ui)

	set_services(&ui, _phase2_services())
	if frame(&ui, {300, 300}) {
		if element(&ui, Element_Desc{layout = {sizing = {fixed(60), fit()}}}) {
			text(&ui, Text_Desc{text = "aaa bbb ccc ddd"})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)
	// "aaa bbb" needs 70, so each 30 wide word takes its own line at width 60.
	testing.expect_value(t, len(_text_lines_of(&ui, 2)), 4)
	_expect_close(t, frame_result.nodes[2].outer.size.y, LINE_HEIGHT * 4)
}

@(test)
test_phase2_trailing_newline_yields_a_final_empty_line :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		text(&ui, Text_Desc{text = "ab\n", sizing = {fit(), fit()}})
		text(&ui, Text_Desc{text = "", sizing = {fit(), fit()}})
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// A hard break always opens a new line, so a trailing one leaves an empty
	// line behind and the block keeps its height.
	testing.expect_value(t, len(_text_lines_of(&ui, 1)), 2)
	_expect_close(t, frame_result.nodes[1].outer.size.y, LINE_HEIGHT * 2)

	// The empty string is still one line, not zero.
	testing.expect_value(t, len(_text_lines_of(&ui, 2)), 1)
	_expect_close(t, frame_result.nodes[2].outer.size.y, LINE_HEIGHT)
}

@(test)
test_phase2_tabs_and_carriage_returns_are_break_opportunities :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config()), nil)
	defer destroy(&ui)

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		text(&ui, Text_Desc{text = "aaa\tbbb", sizing = {fixed(40), fit()}})
		// A carriage return must not glue itself to the preceding word.
		text(&ui, Text_Desc{text = "aaa\r\nbb", sizing = {fit(), fit()}})
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	tabbed := _text_lines_of(&ui, 1)
	testing.expect_value(t, len(tabbed), 2)
	testing.expect_value(t, tabbed[0].text, "aaa")
	testing.expect_value(t, tabbed[1].text, "bbb")

	// Line one measures "aaa" (30), not "aaa\r" (40).
	_expect_close(t, frame_result.nodes[2].outer.size.x, 30)
}

@(test)
test_phase2_failed_measurement_is_never_cached :: proc(t: ^testing.T) {
	ui: Context
	config := _phase2_config()
	services := _phase2_services()
	services.measure_text = _measure_failing
	testing.expect_value(t, init(&ui, config), nil)
	defer destroy(&ui)

	count_failures :: proc(ui: ^Context) -> int {
		count := 0
		for diagnostic in diagnostics(ui) {
			if diagnostic.kind == .Measure_Failed {
				count += 1
			}
		}
		return count
	}

	set_services(&ui, services)
	if frame(&ui, {200, 200}) {
		text(&ui, Text_Desc{text = "hello"})
	}
	_, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.Measure_Failed)
	first := count_failures(&ui)
	testing.expect(t, first > 0)

	// A cached failure would make the second frame silently succeed.
	set_services(&ui, services)
	if frame(&ui, {200, 200}) {
		text(&ui, Text_Desc{text = "hello"})
	}
	_, err = result(&ui)
	testing.expect_value(t, err, Frame_Error.Measure_Failed)
	testing.expect_value(t, count_failures(&ui), first)
}

@(test)
test_phase2_wrapped_width_does_not_narrow_a_later_pass :: proc(t: ^testing.T) {
	ui: Context
	testing.expect_value(t, init(&ui, _phase2_config()), nil)
	defer destroy(&ui)

	// A custom leaf whose height measurement forces the second X pass; the text
	// sibling must be re-measured from its max-content width, not from the
	// narrower width it wrapped to in the first pass.
	measure_square :: proc(user: rawptr, request: Measure_Request) -> (Measure_Result, Measure_Error) {
		_ = user
		if request.axes[.Y].mode == .Exact {
			return Measure_Result{size = {request.axes[.Y].value, request.axes[.Y].value}}, .None
		}
		return Measure_Result{size = {20, 20}}, .None
	}

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		if element(&ui, Element_Desc{layout = {flow = .Column, sizing = {fit(), fixed(200)}}}) {
			content(&ui, Element_Desc{layout = {sizing = {fit(), fixed(40)}}, content = Custom_Content{measure = measure_square}})
			text(&ui, Text_Desc{text = "aaa bbb ccc"})
		}
	}
	frame_result, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.None)

	// Max-content width of the whole run is 110 and nothing constrains it.
	_expect_close(t, frame_result.nodes[3].outer.size.x, 110)
	testing.expect_value(t, len(_text_lines_of(&ui, 3)), 1)
}

@(test)
test_phase2_line_index_overflow_fails_the_frame :: proc(t: ^testing.T) {
	ui: Context
	config := _phase2_config()
	config.capacities.text_lines = 70000
	config.capacities.nodes = 8
	config.capacities.children = 8
	testing.expect_value(t, init(&ui, config), nil)
	defer destroy(&ui)

	// One hard break per character produces more lines than a u16 index can name.
	line_count :: 65600
	buffer := make([]byte, line_count * 2)
	defer delete(buffer)
	for index in 0 ..< line_count {
		buffer[index * 2] = 'a'
		buffer[index * 2 + 1] = '\n'
	}

	set_services(&ui, _phase2_services())
	if frame(&ui, {500, 500}) {
		text(&ui, Text_Desc{text = string(buffer), sizing = {fit(), fit()}})
	}
	_, err := result(&ui)
	testing.expect_value(t, err, Frame_Error.Capacity_Exhausted)
}
