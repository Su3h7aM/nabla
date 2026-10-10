#+test
#+private file
package layout

import "core:math"
import "core:slice"
import "core:testing"
import "core:unicode/utf8"

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

// A wrapped text node's horizontal extent is its widest rendered line, not its
// max-content width. content_size.x stays at max-content as the preferred size
// for a later width pass, so diagnosing it as rendered content reports an
// overflow the wrapping already resolved: one bogus diagnostic per text node,
// which fills a bounded diagnostics pool and fails the whole frame.
@(test)
test_wrapped_text_does_not_report_horizontal_overflow :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	set_services(&ctx, _services())
	if frame(&ctx, {400, 400}) {
		if element(&ctx, {layout = {sizing = {fixed(100), fit()}}}) {
			text(&ctx, {text = "aaa bbb ccc ddd"})
		}
	}
	wrapped, wrapped_error := result(&ctx)
	testing.expect_value(t, wrapped_error, Frame_Error.None)
	_expect_close(t, wrapped.nodes[2].scroll_range.x, 0)
	for diagnostic in diagnostics(&ctx) {
		testing.expectf(
			t,
			!(diagnostic.kind == .Overflow && diagnostic.node == 2 && diagnostic.axis == .X),
			"a wrapped text node must not report horizontal overflow",
		)
	}

	// A run the box constrains past its longest unbreakable word still overflows,
	// measured by the widest line rather than by the max-content width.
	set_services(&ctx, _services())
	if frame(&ctx, {400, 400}) {
		if element(&ctx, {layout = {flow = .Column, align = .Stretch, sizing = {fixed(100), fit()}}}) {
			text(&ctx, {text = "aaaaaaaaaaaaaaaaaaaa", sizing = {grow(), fit()}})
		}
	}
	over, over_error := result(&ctx)
	testing.expect_value(t, over_error, Frame_Error.None)
	_expect_close(t, over.nodes[2].scroll_range.x, 100)
	found := false
	for diagnostic in diagnostics(&ctx) {
		if diagnostic.kind == .Overflow && diagnostic.node == 2 && diagnostic.axis == .X {
			found = true
			_expect_close(t, diagnostic.amount, 100)
		}
	}
	testing.expect(t, found, "an unbreakable run wider than the box must report overflow")
}

Service_Calls :: struct {
	measure:  int,
	break_at: int,
	grapheme: int,
}

_measure_counting :: proc(user_data: rawptr, text: string, style: Text_Style, request: Measure_Request) -> (Measure_Result, Measure_Error) {
	(^Service_Calls)(user_data).measure += 1
	return _measure_monospace(nil, text, style, request)
}

_break_counting :: proc(user_data: rawptr, value: string, offset: int) -> (int, int, Text_Break_Kind, Text_Break_Error) {
	(^Service_Calls)(user_data).break_at += 1
	return _break_ascii(nil, value, offset)
}

_grapheme_counting :: proc(user_data: rawptr, value: string, offset: int) -> int {
	(^Service_Calls)(user_data).grapheme += 1
	return _grapheme_rune(nil, value, offset)
}

_counting_services :: proc(calls: ^Service_Calls) -> Services {
	return Services {
		measure_text = _measure_counting,
		measure_text_user_data = calls,
		break_text = _break_counting,
		break_text_user_data = calls,
		grapheme_end = _grapheme_counting,
		grapheme_end_user_data = calls,
	}
}

Sample :: struct {
	text: string,
	wrap: Wrap,
}

// _solve_texts solves one frame of the given texts, stacked in a column of the given width.
_solve_texts :: proc(ctx: ^Context, calls: ^Service_Calls, samples: []Sample, width := Scalar(100)) -> Frame_Error {
	calls^ = {}
	set_services(ctx, _counting_services(calls))
	if frame(ctx, {500, 500}) {
		if element(ctx, {layout = {flow = .Column, align = .Stretch, sizing = {fixed(width), fit()}}}) {
			for sample in samples {
				text(ctx, {text = sample.text, style = {wrap = sample.wrap}, sizing = {grow(), fit()}})
			}
		}
	}
	_, err := result(ctx)
	return err
}

// _geometry_of copies what a solve published: node rectangles and every text line.
_geometry_of :: proc(ctx: ^Context) -> (nodes: []Resolved_Node, lines: []_Text_Line_Record) {
	frame_result, _ := result(ctx)
	return slice.clone(frame_result.nodes), slice.clone(_context_state(ctx)._text_lines[:])
}

@(test)
test_unchanged_text_costs_no_service_calls_on_later_frames :: proc(t: ^testing.T) {
	options := _test_options()
	options.capacities.nodes = 64
	options.capacities.children = 64
	options.capacities.commands = 256
	options.capacities.text_lines = 256
	options.capacities.measure_cache = 256
	ctx: Context
	testing.expect_value(t, init(&ctx, options), nil)
	defer destroy(&ctx)

	// Wrapped, one line, padded, hard segments, characters, and unwrapped text.
	texts := []Sample {
		{"aaa bbb ccc ddd", .Words},
		{"one two", .Words},
		{"  pad  ", .Words},
		{"ab\n\ncd", .Words},
		{"xyz", .Characters},
		{"kept", .None},
		{"x\ny", .Newlines},
		{"p\n\nq", .Characters},
	}
	calls: Service_Calls

	testing.expect_value(t, _solve_texts(&ctx, &calls, texts), Frame_Error.None)
	testing.expect(t, calls.measure > 0 && calls.break_at > 0 && calls.grapheme > 0)
	first_nodes, first_lines := _geometry_of(&ctx)
	defer delete(first_nodes)
	defer delete(first_lines)
	testing.expect_value(t, len(_text_lines_of(&ctx, 2)), 2)
	testing.expect_value(t, _text_lines_of(&ctx, 4)[0].text, "pad")

	testing.expect_value(t, _solve_texts(&ctx, &calls, texts), Frame_Error.None)
	testing.expect_value(t, calls, Service_Calls{})
	second_nodes, second_lines := _geometry_of(&ctx)
	defer delete(second_nodes)
	defer delete(second_lines)
	testing.expect(t, slice.equal(first_nodes, second_nodes))
	testing.expect(t, slice.equal(first_lines, second_lines))

	invalidate_metrics(&ctx, 1)
	testing.expect_value(t, _solve_texts(&ctx, &calls, texts), Frame_Error.None)
	testing.expect(t, calls.measure > 0)

	// The cached paths place every line exactly where a context with no text
	// cache does, including words wider than the box and padded or empty lines.
	uncached_options := options
	uncached_options.capacities.measured_texts = 0
	uncached: Context
	testing.expect_value(t, init(&uncached, uncached_options), nil)
	defer destroy(&uncached)
	varied := []Sample {
		{"aaaa bbbb cccc dddd", .Words},
		{"abcdefghijklmnopqrstuvwxyz é", .Words},
		{" lead and trail ", .Words},
		{"  ", .Words},
		{"", .Words},
		{"a\n\nb c", .Words},
		{"a\n  \nb", .Words},
		{"a  b", .Words},
		{"  a   b  ", .Words},
		{"  \t", .Words},
		{"abcdefghijklmnopqrstuvwxyz é", .Characters},
		{"two\nlines", .Newlines},
		{"ab\nabcdefghijklmnopqrstuvwxyz\n", .Characters},
		{"kept whole and wider than the box", .None},
	}
	for width in ([?]Scalar{100, 30}) {
		testing.expect_value(t, _solve_texts(&ctx, &calls, varied, width), Frame_Error.None)
		cached_nodes, cached_lines := _geometry_of(&ctx)
		defer delete(cached_nodes)
		defer delete(cached_lines)
		testing.expect_value(t, _solve_texts(&uncached, &calls, varied, width), Frame_Error.None)
		plain_nodes, plain_lines := _geometry_of(&uncached)
		defer delete(plain_nodes)
		defer delete(plain_lines)
		testing.expect(t, slice.equal(cached_nodes, plain_nodes))
		testing.expect(t, slice.equal(cached_lines, plain_lines))
	}
}

@(test)
test_text_larger_than_the_word_pool_shows_as_a_full_pool_until_raised :: proc(t: ^testing.T) {
	options := _test_options()
	options.capacities.measured_words = 3
	ctx: Context
	testing.expect_value(t, init(&ctx, options), nil)
	defer destroy(&ctx)

	calls: Service_Calls
	long := []Sample{{"aaa bbb ccc ddd eee", .Words}}
	testing.expect_value(t, _solve_texts(&ctx, &calls, long), Frame_Error.None)
	testing.expect_value(t, statistics(&ctx).pool_high_water[.Measured_Words], 3)
	testing.expect_value(t, _context_state(&ctx)._text_cache.word_count, 0)

	// Once the pool is raised the text is cached and later frames cost nothing.
	testing.expect_value(t, reserve(&ctx, Capacities{measured_words = 16}), nil)
	testing.expect_value(t, _solve_texts(&ctx, &calls, long), Frame_Error.None)
	testing.expect_value(t, _solve_texts(&ctx, &calls, long), Frame_Error.None)
	testing.expect_value(t, calls, Service_Calls{})
}

@(test)
test_unused_text_is_evicted_after_three_solves_and_its_words_reused :: proc(t: ^testing.T) {
	// The pools hold exactly one text of three words.
	options := _test_options()
	options.capacities.measured_words = 3
	options.capacities.measured_texts = 2
	ctx: Context
	testing.expect_value(t, init(&ctx, options), nil)
	defer destroy(&ctx)
	cache := &_context_state(&ctx)._text_cache

	calls: Service_Calls
	first := []Sample{{"aaa bbb ccc", .Words}}
	second := []Sample{{"ddd eee fff", .Words}}
	testing.expect_value(t, _solve_texts(&ctx, &calls, first), Frame_Error.None)
	testing.expect_value(t, cache.word_count, 3)

	// While the first text is young the second finds no room: it is measured
	// again each frame, correctly and without a frame error.
	for _ in 0 ..< 2 {
		testing.expect_value(t, _solve_texts(&ctx, &calls, second), Frame_Error.None)
		testing.expect(t, calls.measure > 0 && calls.break_at > 0)
		testing.expect_value(t, len(_text_lines_of(&ctx, 2)), 2)
		testing.expect_value(t, cache.item_count, 1)
	}

	// Three solves after its last use the first text is freed by the probe, and
	// the second takes over its words.
	testing.expect_value(t, _solve_texts(&ctx, &calls, second), Frame_Error.None)
	testing.expect_value(t, cache.item_count, 1)
	testing.expect_value(t, cache.word_count, 3)
	testing.expect_value(t, _solve_texts(&ctx, &calls, second), Frame_Error.None)
	testing.expect_value(t, calls, Service_Calls{})
	testing.expect_value(t, len(_text_lines_of(&ctx, 2)), 2)
}

@(test)
test_missing_text_services_fail_the_frame :: proc(t: ^testing.T) {
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

@(test)
test_text_runs_wrap_mid_run :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	// "aaa bbb ccc" wraps at 70 into "aaa bbb" and "ccc". The second run spans
	// "a bbb", and the unpainted third run " c" crosses the line break.
	runs := []Text_Run{{length = 2, paint = 1}, {length = 5, paint = 2}, {length = 2, paint = 0}, {length = 2, paint = 3}}
	set_services(&ctx, _services())
	if frame(&ctx, {400, 400}) {
		text(&ctx, {text = "aaa bbb ccc", runs = runs, paint = 9, style = {wrap = .Words}, sizing = {fixed(70), fit()}})
	}
	frame_result, err := result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(diagnostics(&ctx)), 0)

	Segment :: struct {
		text:  string,
		paint: Paint,
		x:     Scalar,
		line:  u16,
	}
	expected := []Segment{{"aa", 1, 0, 0}, {"a bbb", 2, 20, 0}, {"cc", 3, 10, 1}}
	index := 0
	for command in frame_result.commands {
		data, is_text := command.data.(Text_Cmd)
		if !is_text {
			continue
		}
		testing.expect(t, index < len(expected))
		if index < len(expected) {
			testing.expect_value(t, data.text, expected[index].text)
			testing.expect_value(t, data.paint, expected[index].paint)
			testing.expect_value(t, data.line, expected[index].line)
			_expect_close(t, command.bounds.position.x, expected[index].x)
			_expect_close(t, command.bounds.size.x, CHARACTER_WIDTH * Scalar(len(expected[index].text)))
		}
		index += 1
	}
	testing.expect_value(t, index, len(expected))
}

@(test)
test_invalid_text_runs_fall_back_to_paint :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	invalid := [][]Text_Run{{{length = 3, paint = 1}}, {{length = 0, paint = 1}, {length = 5, paint = 2}}, {{length = 9, paint = 1}}}
	for runs in invalid {
		set_services(&ctx, _services())
		if frame(&ctx, {400, 400}) {
			text(&ctx, {text = "hello", runs = runs, paint = 9})
		}
		frame_result, err := result(&ctx)
		testing.expect_value(t, err, Frame_Error.None)
		found := 0
		for entry in diagnostics(&ctx) {
			if entry.kind == .Invalid_Text_Runs {
				found += 1
			}
		}
		testing.expect_value(t, found, 1)
		texts := 0
		for command in frame_result.commands {
			if data, is_text := command.data.(Text_Cmd); is_text {
				texts += 1
				testing.expect_value(t, data.text, "hello")
				testing.expect_value(t, data.paint, Paint(9))
			}
		}
		testing.expect_value(t, texts, 1)
	}
}

_grapheme_rune :: proc(user_data: rawptr, value: string, offset: int) -> int {
	_ = user_data
	_, size := utf8.decode_rune_in_string(value[offset:])
	return offset + size
}

_services_with_graphemes :: proc() -> Services {
	services := _services()
	services.grapheme_end = _grapheme_rune
	return services
}

@(test)
test_wide_word_splits_at_grapheme_boundaries :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	set_services(&ctx, _services_with_graphemes())
	if frame(&ctx, {400, 400}) {
		if element(&ctx, {layout = {sizing = {fixed(30), fit()}}}) {
			text(&ctx, {text = "ab abcdefgh é", sizing = {grow(), fit()}})
		}
	}
	split, split_error := result(&ctx)
	testing.expect_value(t, split_error, Frame_Error.None)
	testing.expect_value(t, len(diagnostics(&ctx)), 0)
	lines := _text_lines_of(&ctx, 2)
	expected := [?]string{"ab", "abc", "def", "gh", "é"}
	testing.expect_value(t, len(lines), len(expected))
	for line, index in lines {
		testing.expect_value(t, line.text, expected[index])
	}
	// The floor is one grapheme, so the text shrinks to the fixed width.
	_expect_close(t, split.nodes[2].outer.size.x, 30)
}

@(test)
test_characters_keeps_spaces_and_breaks_at_graphemes :: proc(t: ^testing.T) {
	ctx: Context
	testing.expect_value(t, init(&ctx, _test_options()), nil)
	defer destroy(&ctx)

	set_services(&ctx, _services_with_graphemes())
	if frame(&ctx, {400, 400}) {
		if element(&ctx, {layout = {sizing = {fixed(50), fit()}}}) {
			text(&ctx, {text = "  a  b\n    x\n\nabcdefghé", style = {wrap = .Characters}, sizing = {grow(), fit()}})
		}
	}
	_, err := result(&ctx)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, len(diagnostics(&ctx)), 0)
	lines := _text_lines_of(&ctx, 2)
	expected := [?]string{"  a  ", "b", "    x", "", "abcde", "fghé"}
	testing.expect_value(t, len(lines), len(expected))
	for line, index in lines {
		testing.expect_value(t, line.text, expected[index])
	}
}
