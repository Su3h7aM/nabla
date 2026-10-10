package layout

import "core:hash"
import "core:math"

/*
Declare a text leaf inside the enclosing scope.

Text is a leaf: it never has children, so it is not a scope. Its string is
borrowed and must stay valid and unmodified until the frame result is released.
Measurement and breaking are supplied through the frame's `Services` binding;
they are not retained in `Options`. Declaring text without a configured
`Services.measure_text` fails the frame with `Missing_Text_Measurer`, and a
wrapping text node without `Services.break_text` fails with
`Missing_Text_Breaker`, rather than publishing invented geometry.
*/
text :: proc(ctx: ^Context, #by_ptr desc: Text_Desc, loc := #caller_location) {
	if ctx == nil {
		return
	}
	state := _context_state(ctx)
	if !state._initialized || !state._frame_open || state._frame_error != .None {
		return
	}
	if state._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: measurement callback reentered the active context", loc)
		}
		_append_diagnostic(state, .Measure_Reentered, 0, loc = loc)
		return
	}
	if state._services.measure_text == nil {
		state._frame_error = .Missing_Text_Measurer
		return
	}
	if desc.style.wrap != .None && state._services.break_text == nil {
		state._frame_error = .Missing_Text_Breaker
		return
	}
	element_desc := Element_Desc {
		id = desc.id,
		layout = {sizing = desc.sizing},
		user = desc.user,
	}
	style_diagnostics := 0
	style_values := [3]Scalar{desc.style.size, desc.style.line_height, desc.style.letter_spacing}
	for value in style_values {
		if !_scalar_is_finite(value) || value < 0 {
			style_diagnostics += 1
		}
	}
	runs_valid := _text_runs_valid(desc.text, desc.runs)
	if !runs_valid {
		style_diagnostics += 1
	}
	node, declared := _declare_node(ctx, element_desc, false, loc, style_diagnostics)
	if !declared {
		return
	}

	input := &state._node_inputs[node]
	input.is_text = true
	input.text = desc.text
	input.text_style = desc.style
	input.text_paint = desc.paint
	if runs_valid {
		input.text_runs = desc.runs
	} else {
		_append_diagnostic(state, .Invalid_Text_Runs, node, loc = loc)
	}
	_normalize_nonnegative(state, &input.text_style.size, node, .Y, loc)
	_normalize_nonnegative(state, &input.text_style.line_height, node, .Y, loc)
	_normalize_nonnegative(state, &input.text_style.letter_spacing, node, .X, loc)
	// Folded here, after normalization, so every run measured from this node
	// reuses one hash of the string instead of rehashing a substring per lookup.
	input.text_key = _text_identity_key(state, input^)
	state._nodes[node].flags.is_text = true
}

/*
Report whether runs are empty or have positive lengths summing to the text length.
*/
@(private, require_results)
_text_runs_valid :: proc "contextless" (text: string, runs: []Text_Run) -> bool {
	total := 0
	for run in runs {
		if run.length <= 0 || run.length > len(text) - total {
			return false
		}
		total += run.length
	}
	return len(runs) == 0 || total == len(text)
}

/*
Fold the identity of a text node's content and style into one key.

It names the text's item in the text cache. Runs measured from this node
differ only by which substring they cover, so the per-run key is this value
extended with that substring's offset and length, so a cache lookup costs a
few multiplies rather than a hash over the text.
*/
@(private)
_text_identity_key :: proc(state: ^_Context_State, input: _Node_Input) -> u64 {
	style := input.text_style
	key := u64(FNV64_OFFSET_BASIS)
	key = _hash_index(key, hash.fnv64a(transmute([]byte)input.text))
	key = _hash_index(key, u64(style.font))
	key = _hash_index(key, u64(transmute(u32)style.size))
	key = _hash_index(key, u64(transmute(u32)style.letter_spacing))
	key = _hash_index(key, u64(transmute(u32)style.line_height))
	key = _hash_index(key, u64(style.wrap))
	key = _hash_index(key, u64(state._metrics_generation))
	return key
}

/*
Discard every cached measurement and adopt a new metrics generation.

The core cannot observe a font atlas rebuild, a DPI change, or a terminal
resize, so invalidation is explicit. Calling this outside a frame is required;
inside one it is ignored.
*/
invalidate_metrics :: proc(ctx: ^Context, generation: u32) {
	if ctx == nil || !_context_state(ctx)._initialized {
		return
	}
	state := _context_state(ctx)
	if state._frame_open || state._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: invalidate_metrics called during a frame")
		}
		return
	}
	state._metrics_generation = generation
	for &entry in state._measure_cache {
		entry = {}
	}
	state._measure_cache_count = 0
	_text_cache_clear(&state._text_cache)
}

/*
Key a text measurement.

Line breaking is performed by the core over unbounded run measurements, so the
request width is not part of the key: every text measurement is unbounded, and
the resolved width influences which runs are measured rather than their extent.
Every remaining field of the normative key changes the measured result.
*/
@(private, require_results)
_measure_cache_key :: proc(state: ^_Context_State, node: Node_Handle, text: string, request: Measure_Request) -> (key: u64, cacheable: bool) {
	if cap(state._measure_cache) == 0 {
		return 0, false
	}
	input := &state._node_inputs[node]

	// Every run measured from a text node is a substring of that node's text, so
	// the node's precomputed identity plus this run's offset and length names it
	// exactly, without rehashing the bytes.
	offset, within := _run_offset_in(input.text, text)
	if !within {
		return 0, false
	}
	key = _hash_index(input.text_key, u64(offset))
	key = _hash_index(key, u64(len(text)))
	key = _hash_index(key, u64(request.want_baseline))
	if key == 0 {
		key = 1
	}
	return key, true
}

// _run_offset_in returns a borrowed run's offset, rejecting strings outside text.
// An empty run has no address of its own and measures the same anywhere.
@(private, require_results)
_run_offset_in :: proc "contextless" (text, run: string) -> (offset: int, within: bool) {
	if len(run) == 0 {
		return 0, true
	}
	if len(run) > len(text) {
		return 0, false
	}
	base := uintptr(raw_data(text))
	run_base := uintptr(raw_data(run))
	if run_base < base {
		return 0, false
	}
	distance := run_base - base
	if distance > uintptr(len(text) - len(run)) {
		return 0, false
	}
	return int(distance), true
}

@(private)
MEASURE_CACHE_PROBE_LIMIT :: 8

@(private, require_results)
_measure_cache_lookup :: proc(state: ^_Context_State, key: u64) -> (Measure_Result, bool) {
	capacity := cap(state._measure_cache)
	if capacity == 0 {
		return {}, false
	}
	start := int(key % u64(capacity))
	for probe_offset in 0 ..< min(MEASURE_CACHE_PROBE_LIMIT, capacity) {
		slot := (start + probe_offset) % capacity
		entry := &state._measure_cache[slot]
		if !entry.occupied {
			return {}, false
		}
		if entry.key == key {
			entry.generation = state._generation
			return entry.result, true
		}
	}
	return {}, false
}

/*
Insert a measurement, replacing the least recently used slot in the probe run.

The cache is a pure accelerator: a full or contended run simply overwrites the
stalest entry, and a failure to store never changes geometry.
*/
@(private)
_measure_cache_store :: proc(state: ^_Context_State, key: u64, result: Measure_Result) {
	capacity := cap(state._measure_cache)
	if capacity == 0 {
		return
	}
	start := int(key % u64(capacity))
	victim := start
	stalest: u32
	for probe_offset in 0 ..< min(MEASURE_CACHE_PROBE_LIMIT, capacity) {
		slot := (start + probe_offset) % capacity
		entry := state._measure_cache[slot]
		if !entry.occupied || entry.key == key {
			victim = slot
			break
		}
		age := state._generation - entry.generation
		if probe_offset != 0 && age <= stalest {
			continue
		}
		stalest = age
		victim = slot
	}
	if !state._measure_cache[victim].occupied {
		state._measure_cache_count += 1
	}
	state._measure_cache[victim] = _Measure_Cache_Entry {
		key        = key,
		result     = result,
		generation = state._generation,
		occupied   = true,
	}
	_update_high_water(state, .Measure_Cache, state._measure_cache_count)
}

@(private)
_unbounded_request :: proc "contextless" (want_baseline := true) -> Measure_Request {
	return Measure_Request{axes = {.X = {mode = .Unbounded}, .Y = {mode = .Unbounded}}, want_baseline = want_baseline}
}

/*
Advance text breaking by one piece through the configured seam.

Calls the frame's `Services.break_text` and enforces its contract defensively: a callback that
returns an invalid span, fails to make progress, or mismatches `.None` with the
end of the text would spin the wrapping loop or silently truncate the text, so
a violation fails the frame with a diagnostic instead.
*/
@(private)
_break_text :: proc(state: ^_Context_State, node: Node_Handle, text: string, offset: int) -> (piece_end: int, next_offset: int, kind: Text_Break_Kind) {
	if state._services.break_text == nil {
		state._frame_error = .Missing_Text_Breaker
		return len(text), len(text), .None
	}
	break_error: Text_Break_Error
	piece_end, next_offset, kind, break_error = state._services.break_text(state._services.break_text_user_data, text, offset)
	if break_error != .None {
		state._frame_error = .Invalid_Text
		return len(text), len(text), .None
	}
	valid_span := offset <= piece_end && piece_end <= next_offset && next_offset <= len(text)
	progresses := next_offset > offset || piece_end == len(text)
	// `.None` is the end-of-text result and the end of the text is `.None`: a
	// non-.None at EOF would spin the wrapping loop, and a .None before EOF
	// would make the loops treat the remaining text as consumed and silently
	// discard it.
	eof_contract := (kind == .None) == (piece_end == len(text))
	if !valid_span || !progresses || !eof_contract {
		when ODIN_DEBUG {
			assert(false, "layout: text breaker violated its contract (invalid span, no progress, or .None/EOF mismatch)")
		}
		_append_diagnostic(state, .Text_Break_Stalled, node, loc = state._node_inputs[node].loc)
		state._frame_error = .Text_Break_Stalled
		return len(text), len(text), .None
	}
	return
}

/*
Measure the max-content size and the shrink floor of a text node.

Width is the widest hard segment; the floor is the widest unbreakable run: the
widest grapheme when words or characters may wrap, the whole segment otherwise.
Height is the resolved line height times the hard-segment count, which is the
line count before any soft wrapping.

The measurement is width-independent, so a text whose item is in the text cache
is restored with no service call at all.
*/
@(private)
_measure_text_intrinsic :: proc(state: ^_Context_State, node: Node_Handle) -> Measure_Result {
	input := &state._node_inputs[node]
	cache := &state._text_cache

	summary: _Text_Summary
	input.text_item = _text_cache_find(cache, input.text_key, state._generation)
	if input.text_item != 0 {
		summary = cache.items[input.text_item - 1].summary
	} else {
		recorded: bool
		summary, recorded = _measure_text_summary(state, node)
		if recorded {
			input.text_item = _text_cache_insert(cache, input.text_key, state._generation, summary)
		}
	}
	_update_high_water(state, .Measured_Texts, cache.item_count)
	_update_high_water(state, .Measured_Words, cache.word_peak)

	line_height := f64(input.text_style.line_height)
	if line_height == 0 {
		line_height = summary.natural_line_height
	}
	input.line_height = _finite_scalar(state, node, .Y, line_height, false)

	height := line_height * f64(summary.segment_count)
	return Measure_Result {
		size = {_finite_scalar(state, node, .X, summary.widest, false), _finite_scalar(state, node, .Y, height, false)},
		min_size = {_finite_scalar(state, node, .X, summary.longest_unbreakable, false), _finite_scalar(state, node, .Y, height, false)},
	}
}

/*
Measure a text node through the services.

Words are recorded with their advances in the text cache's word pool so wrapping
can pack lines by summing, rather than measuring every word a second time.
`recorded` is false when the summary cannot be cached: the frame failed, or the
word pool cannot hold the text, in which case no word is retained.
*/
@(private)
_measure_text_summary :: proc(state: ^_Context_State, node: Node_Handle) -> (summary: _Text_Summary, recorded: bool) {
	input := &state._node_inputs[node]
	cache := &state._text_cache
	text := input.text
	wrap := input.text_style.wrap

	cacheable := len(cache.buckets) > 0
	recording := cacheable && wrap != .None && len(cache.words) > 0
	word_tail: i32
	segment_measured: Measure_Result

	// The line a one-segment Words text packs into: from its first word to its
	// last, with the fit decision replayed in the order wrapping makes it.
	first_word_start, previous_end: int
	segment_words, first_segment_words := 0, 0
	line_running, line_fit: f64

	// Wrap.None never calls the breaker: the whole string is one segment,
	// measured once, which preserves the historical whole-string behavior
	// (including the measurer error it provokes when no measurer is set).
	if wrap == .None {
		segment_measured = _measure_text_uncached(state, node, text)
		summary.widest = f64(segment_measured.size.x)
		summary.longest_unbreakable = f64(segment_measured.size.x)
		summary.natural_line_height = f64(segment_measured.size.y)
		summary.segment_count = 1
	} else {
		offset := 0
		segment_start := 0
		for {
			piece_end, next_offset, kind := _break_text(state, node, text, offset)
			if state._frame_error != .None {
				break
			}
			// A non-empty piece is a word when words may wrap.
			if wrap == .Words && piece_end > offset {
				word_measured := _measure_text_uncached(state, node, text[offset:piece_end])
				summary.longest_unbreakable = math.max(summary.longest_unbreakable, _widest_grapheme(state, node, offset, piece_end))
				summary.natural_line_height = math.max(summary.natural_line_height, f64(word_measured.size.y))

				if recording {
					previous_tail := word_tail
					record := _text_cache_append_word(cache, &summary, &word_tail)
					if record == nil {
						// Out of room: the text is measured again next frame.
						// Geometry is unchanged either way, so this is not a frame error.
						recording = false
					} else {
						record^ = _Measured_Word {
							offset = i32(offset),
							span = {length = u32(piece_end - offset)},
							width = word_measured.size.x,
							segment = i32(summary.segment_count),
						}
						// The separator of the previous word is the whole gap up
						// to this word, however many break pieces it holds, so its
						// advance is measured once here.
						gap_width: f64
						if segment_words > 0 {
							previous := &cache.words[previous_tail - 1]
							if gap := text[previous_end:offset]; len(gap) > 0 {
								previous.separator_width = _measure_text_uncached(state, node, gap).size.x
							}
							gap_width = f64(previous.separator_width)
						}
						if summary.segment_count == 0 {
							word_width := f64(word_measured.size.x)
							if first_segment_words == 0 {
								first_word_start = offset
								line_running = word_width
								line_fit = word_width
							} else {
								line_fit = math.max(line_fit, line_running + gap_width + word_width)
								line_running += gap_width + word_width
							}
							first_segment_words += 1
						}
						previous_end = piece_end
						segment_words += 1
					}
				}
			}
			// A hard segment ends at the piece a Mandatory (or None) separator
			// follows. Measure it as one unit: widest, natural line height, and
			// the shrink floor when words do not wrap.
			if kind == .Mandatory || kind == .None {
				segment_measured = _measure_text_uncached(state, node, text[segment_start:piece_end])
				summary.widest = math.max(summary.widest, f64(segment_measured.size.x))
				summary.natural_line_height = math.max(summary.natural_line_height, f64(segment_measured.size.y))
				// A segment is one record unless it has words of its own.
				if recording && (wrap != .Words || segment_words == 0) {
					record := _text_cache_append_word(cache, &summary, &word_tail)
					if record == nil {
						recording = false
					} else {
						record^ = _Measured_Word {
							offset = i32(segment_start),
							span = {length = u32(piece_end - segment_start), wordless = wrap == .Words},
							width = segment_measured.size.x,
							baseline = segment_measured.baseline,
							segment = i32(summary.segment_count),
						}
					}
				}
				segment_words = 0
				if wrap == .Characters {
					summary.longest_unbreakable = math.max(summary.longest_unbreakable, _widest_grapheme(state, node, segment_start, piece_end))
				} else if wrap != .Words {
					summary.longest_unbreakable = math.max(summary.longest_unbreakable, f64(segment_measured.size.x))
				}
				segment_start = next_offset
				summary.segment_count += 1
				if kind == .None {
					break
				}
			}
			offset = next_offset
		}
	}

	recorded = cacheable && (wrap == .None || recording) && state._frame_error == .None
	if !recorded {
		_text_cache_free_words(cache, summary.word_head)
		summary.word_head = 0
		summary.word_count = 0
		return summary, false
	}

	if summary.segment_count == 1 {
		summary.line_end = len(text)
		summary.line_width = segment_measured.size.x
		summary.line_baseline = segment_measured.baseline
		if wrap == .Characters {
			summary.line_fit_width = summary.widest
		}
		if wrap == .Words && first_segment_words > 0 {
			summary.line_start = first_word_start
			summary.line_end = previous_end
			summary.line_fit_width = line_fit
			if summary.line_start != 0 || summary.line_end != len(text) {
				line_measured := _measure_text_uncached(state, node, text[summary.line_start:summary.line_end])
				summary.line_width = line_measured.size.x
				summary.line_baseline = line_measured.baseline
				if state._frame_error != .None {
					_text_cache_free_words(cache, summary.word_head)
					summary.word_head = 0
					summary.word_count = 0
					return summary, false
				}
			}
		}
	}
	return summary, true
}

/*
Return the end of the grapheme at `offset` through the configured seam.

A callback that returns an end outside `(offset, len(text)]` would spin the
splitting loop, so a violation fails the frame like a stalled breaker.
*/
@(private)
_grapheme_end :: proc(state: ^_Context_State, node: Node_Handle, text: string, offset: int) -> int {
	end := state._services.grapheme_end(state._services.grapheme_end_user_data, text, offset)
	if end <= offset || end > len(text) {
		when ODIN_DEBUG {
			assert(false, "layout: grapheme_end violated its contract (end outside (offset, len(text)])")
		}
		_append_diagnostic(state, .Text_Break_Stalled, node, loc = state._node_inputs[node].loc)
		state._frame_error = .Text_Break_Stalled
		return len(text)
	}
	return end
}

/*
Measure the widest grapheme in `text[start:end]` of a text node, or the whole
run when no `Services.grapheme_end` is set.
*/
@(private, require_results)
_widest_grapheme :: proc(state: ^_Context_State, node: Node_Handle, start, end: int) -> f64 {
	input := &state._node_inputs[node]
	if state._services.grapheme_end == nil {
		return f64(_measure_text_uncached(state, node, input.text[start:end]).size.x)
	}
	widest: f64
	for offset := start; offset < end; {
		next := _grapheme_end(state, node, input.text[:end], offset)
		if state._frame_error != .None {
			break
		}
		widest = math.max(widest, f64(_measure_text_uncached(state, node, input.text[offset:next]).size.x))
		offset = next
	}
	return widest
}

/*
Emit full lines from the front of `text[start:end]` until the remainder fits.

Each line holds the most graphemes that fit `available`, and at least one. The
remainder starts at `rest` and is left to the caller, so it can continue with
the next word. Without `Services.grapheme_end`, or when the remainder is one
grapheme, nothing is split. Returns false when the frame failed.
*/
@(private, require_results)
_split_wide_run :: proc(state: ^_Context_State, node: Node_Handle, start, end: int, available: f64) -> (rest: int, rest_width: f64, ok: bool) {
	input := &state._node_inputs[node]
	rest = start
	for {
		rest_width = f64(_measure_text_run_cached(state, node, input.text[rest:end], _unbounded_request()).size.x)
		if rest_width <= available || state._services.grapheme_end == nil {
			return rest, rest_width, true
		}
		cut := _grapheme_end(state, node, input.text[:end], rest)
		for cut < end && state._frame_error == .None {
			next := _grapheme_end(state, node, input.text[:end], cut)
			if state._frame_error != .None || f64(_measure_text_run_cached(state, node, input.text[rest:next], _unbounded_request()).size.x) > available {
				break
			}
			cut = next
		}
		if state._frame_error != .None {
			return rest, rest_width, false
		}
		if cut >= end {
			return rest, rest_width, true
		}
		if _, appended := _append_text_line(state, node, input.text[rest:cut], input.text_line_count); !appended {
			return rest, rest_width, false
		}
		input.text_line_count += 1
		rest = cut
	}
}

@(private, require_results)
_append_text_line :: proc(state: ^_Context_State, node: Node_Handle, line: string, line_index: int) -> (Vec2, bool) {
	measured := _measure_text_run_cached(state, node, line, _unbounded_request())
	return _push_text_line(state, node, line, measured.size.x, measured.baseline, line_index)
}

@(private, require_results)
_push_text_line :: proc(state: ^_Context_State, node: Node_Handle, line: string, width, baseline: Scalar, line_index: int) -> (Vec2, bool) {
	size := Vec2{width, state._node_inputs[node].line_height}
	if line_index > int(max(u16)) {
		_latch_capacity_error(state, .Text_Lines, state._node_inputs[node].loc)
		return size, false
	}
	record := _Text_Line_Record {
		text     = line,
		size     = size,
		line     = u16(line_index),
		baseline = baseline,
	}
	if !_try_append(&state._text_lines, record) {
		_latch_capacity_error(state, .Text_Lines, state._node_inputs[node].loc)
		return size, false
	}
	_update_high_water(state, .Text_Lines, len(state._text_lines))
	return size, true
}

/*
Break one text node into lines at its resolved width.

Greedy word packing, as in every practical line breaker: a word that does not
fit starts a new line, and a word too wide for an empty line is split at
grapheme boundaries (or overflows when no grapheme service is set).
`Wrap.Characters` splits each hard segment the same way without regard to
whitespace. `Wrap.Newlines` and `Wrap.None` never break inside a hard segment.
*/
@(private, require_results)
_wrap_text_node :: proc(state: ^_Context_State, node: Node_Handle) -> bool {
	input := &state._node_inputs[node]
	input.text_line_start = len(state._text_lines)
	input.text_line_count = 0

	available := f64(state._nodes[node].inner.size.x)
	wrap := input.text_style.wrap
	widest: f64

	if input.text_item != 0 {
		summary := state._text_cache.items[input.text_item - 1].summary
		if summary.segment_count == 1 && summary.line_fit_width <= available {
			return _wrap_text_node_single_line(state, node, summary)
		}
		if summary.word_count > 0 {
			if wrap == .Words {
				return _wrap_text_node_from_records(state, node, available)
			}
			return _wrap_text_node_from_segments(state, node, summary, available)
		}
	}

	if wrap == .None {
		// Wrap.None never calls the breaker: the whole string is one line.
		size, appended := _append_text_line(state, node, input.text, input.text_line_count)
		if !appended {
			return false
		}
		input.text_line_count += 1
		widest = math.max(widest, f64(size.x))
	} else if wrap != .Words {
		// Wrap.Newlines: one line per hard segment; Wrap.Characters: one or more.
		offset := 0
		segment_start := 0
		for {
			piece_end, next_offset, kind := _break_text(state, node, input.text, offset)
			if state._frame_error != .None {
				return false
			}
			if kind == .Mandatory || kind == .None {
				line_start := segment_start
				if wrap == .Characters {
					rest, _, split := _split_wide_run(state, node, segment_start, piece_end, available)
					if !split {
						return false
					}
					line_start = rest
				}
				size, appended := _append_text_line(state, node, input.text[line_start:piece_end], input.text_line_count)
				if !appended {
					return false
				}
				input.text_line_count += 1
				widest = math.max(widest, f64(size.x))
				if kind == .None {
					break
				}
				segment_start = next_offset
			}
			offset = next_offset
		}
	} else {
		// Wrap.Words without recorded words: pack pieces within each hard
		// segment, tracking the segment boundary at every Mandatory break.
		offset := 0
		segment_start := 0
		segment_lines := 0
		line_start := -1
		line_end := 0
		// Summed advance width of the words and separators already on the line.
		// The fit decision accumulates per word so a line of k words costs k
		// measurements; measuring each candidate prefix instead would remeasure
		// every earlier word on the line and cost O(k * line_bytes).
		line_width: f64
		for {
			piece_end, next_offset, kind := _break_text(state, node, input.text, offset)
			if state._frame_error != .None {
				return false
			}
			if piece_end > offset {
				word_start := offset
				word_end := piece_end
				word_width := f64(_measure_text_run_cached(state, node, input.text[word_start:word_end], _unbounded_request()).size.x)

				if line_start >= 0 {
					// The separator is measured rather than assumed, because its
					// advance depends on the font and on how many spaces it holds.
					separator_width: f64
					if separator := input.text[line_end:word_start]; len(separator) > 0 {
						separator_width = f64(_measure_text_run_cached(state, node, separator, _unbounded_request()).size.x)
					}
					if line_width + separator_width + word_width > available {
						size, appended := _append_text_line(state, node, input.text[line_start:line_end], input.text_line_count)
						if !appended {
							return false
						}
						input.text_line_count += 1
						segment_lines += 1
						widest = math.max(widest, f64(size.x))
						line_start = -1
					} else {
						line_width += separator_width + word_width
						line_end = word_end
					}
				}
				if line_start < 0 {
					line_start = word_start
					line_end = word_end
					line_width = word_width
					if line_width > available {
						rest, rest_width, split := _split_wide_run(state, node, word_start, word_end, available)
						if !split {
							return false
						}
						line_start = rest
						line_width = rest_width
					}
				}
			}
			if kind == .Mandatory || kind == .None {
				if line_start >= 0 {
					size, appended := _append_text_line(state, node, input.text[line_start:line_end], input.text_line_count)
					if !appended {
						return false
					}
					input.text_line_count += 1
					segment_lines += 1
					widest = math.max(widest, f64(size.x))
				}
				// A hard segment always occupies at least one line, even when it holds no words.
				if segment_lines == 0 {
					size, appended := _append_text_line(state, node, input.text[segment_start:piece_end], input.text_line_count)
					if !appended {
						return false
					}
					input.text_line_count += 1
					widest = math.max(widest, f64(size.x))
				}
				if kind == .None {
					break
				}
				segment_start = next_offset
				segment_lines = 0
				line_start = -1
				line_end = 0
				line_width = 0
			}
			offset = next_offset
		}
	}

	// `content_size.x` stays at max-content: replacing it with the wrapped width
	// would make the next width pass see a narrower preferred size and prevent
	// the node from re-expanding into space that later became available.
	_ = widest
	_set_text_block_height(state, node)
	return true
}

// _set_text_block_height sizes the block to its emitted lines. The height is a
// hard floor: shrinking it would clip lines.
@(private)
_set_text_block_height :: proc(state: ^_Context_State, node: Node_Handle) {
	input := &state._node_inputs[node]
	block_height := f64(input.line_height) * f64(input.text_line_count)
	input.content_size.y = _finite_scalar(state, node, .Y, block_height, false)
	input.content_minimum.y = input.content_size.y
}

/*
Emit the one line a text of a single hard segment fits on, from its summary.

The summary holds the line's range, size, and baseline, so the line needs no
breaking and no measurement.
*/
@(private, require_results)
_wrap_text_node_single_line :: proc(state: ^_Context_State, node: Node_Handle, summary: _Text_Summary) -> bool {
	input := &state._node_inputs[node]
	if _, appended := _push_text_line(state, node, input.text[summary.line_start:summary.line_end], summary.line_width, summary.line_baseline, 0); !appended {
		return false
	}
	input.text_line_count = 1
	_set_text_block_height(state, node)
	return true
}

/*
Emit one line per cached hard segment of a Newlines or Characters text.

A segment that fits, or any segment of a Newlines text, becomes a line from its
record alone. A Characters segment wider than `available` is split at grapheme
boundaries first.
*/
@(private, require_results)
_wrap_text_node_from_segments :: proc(state: ^_Context_State, node: Node_Handle, summary: _Text_Summary, available: f64) -> bool {
	input := &state._node_inputs[node]
	for handle := summary.word_head; handle != 0; {
		record := state._text_cache.words[handle - 1]
		handle = record.next
		start := int(record.offset)
		end := start + int(record.span.length)
		appended: bool
		if input.text_style.wrap == .Characters && f64(record.width) > available {
			rest, _, split := _split_wide_run(state, node, start, end, available)
			if !split {
				return false
			}
			_, appended = _append_text_line(state, node, input.text[rest:end], input.text_line_count)
		} else {
			_, appended = _push_text_line(state, node, input.text[start:end], record.width, record.baseline, input.text_line_count)
		}
		if !appended {
			return false
		}
		input.text_line_count += 1
	}
	_set_text_block_height(state, node)
	return true
}

/*
Break a text node into lines using the advances in its cached words.

Intrinsic sizing already measured every word to find the shrink floor, so
packing lines here needs no measurement at all, just a running sum over the
records and one line measurement per emitted line. Line breaking is identical
to the measuring path: greedy packing, a word too wide for an empty line
occupies that line alone, and a hard segment without words is one line holding
the segment as written.
*/
@(private, require_results)
_wrap_text_node_from_records :: proc(state: ^_Context_State, node: Node_Handle, available: f64) -> bool {
	input := &state._node_inputs[node]
	summary := state._text_cache.items[input.text_item - 1].summary

	line_start := -1
	line_end := 0
	line_width: f64
	segment := i32(0)
	// Advance of the gap after the previous word, which a word joining the
	// line pays before its own.
	previous_separator: f64

	flush_line :: proc(state: ^_Context_State, node: Node_Handle, text: string) -> bool {
		input := &state._node_inputs[node]
		_, appended := _append_text_line(state, node, text, input.text_line_count)
		if !appended {
			return false
		}
		input.text_line_count += 1
		return true
	}

	for handle := summary.word_head; handle != 0; {
		record := state._text_cache.words[handle - 1]
		handle = record.next

		// A new hard segment always starts a new line, because a newline is a
		// break the wrapper may not undo.
		if record.segment != segment {
			if line_start >= 0 {
				if !flush_line(state, node, input.text[line_start:line_end]) {
					return false
				}
				line_start = -1
			}
			segment = record.segment
		}

		start := int(record.offset)
		word_end := start + int(record.span.length)
		if record.span.wordless {
			_, appended := _push_text_line(state, node, input.text[start:word_end], record.width, record.baseline, input.text_line_count)
			if !appended {
				return false
			}
			input.text_line_count += 1
			continue
		}
		if line_start >= 0 {
			if line_width + previous_separator + f64(record.width) > available {
				if !flush_line(state, node, input.text[line_start:line_end]) {
					return false
				}
				line_start = -1
			} else {
				line_width += previous_separator + f64(record.width)
				line_end = word_end
			}
		}
		if line_start < 0 {
			line_start = start
			line_end = word_end
			line_width = f64(record.width)
			if line_width > available {
				rest, rest_width, split := _split_wide_run(state, node, line_start, word_end, available)
				if !split {
					return false
				}
				line_start = rest
				line_width = rest_width
			}
		}
		previous_separator = f64(record.separator_width)
	}

	if line_start >= 0 {
		if !flush_line(state, node, input.text[line_start:line_end]) {
			return false
		}
	}
	_set_text_block_height(state, node)
	return true
}

@(private, require_results)
_wrap_text_nodes :: proc(state: ^_Context_State) -> bool {
	changed := false
	clear(&state._text_lines)
	for node_index in 1 ..< len(state._node_inputs) {
		node := Node_Handle(node_index)
		input := &state._node_inputs[node]
		if !input.is_text {
			continue
		}
		previous := input.content_size
		if !_wrap_text_node(state, node) {
			return changed
		}
		if state._node_inputs[node].content_size != previous {
			changed = true
		}
	}
	return changed
}

/*
Position the resolved lines of every text node inside its content box.

Line alignment is a purely visual placement of each line within the block and
never changes the block geometry the solver already published.
*/
@(private)
_place_text_lines :: proc(state: ^_Context_State) {
	for node_index in 1 ..< len(state._node_inputs) {
		input := &state._node_inputs[node_index]
		if !input.is_text || input.text_line_count == 0 {
			continue
		}
		node := Node_Handle(node_index)
		resolved := &state._nodes[node]
		resolved.content_size = input.content_size
		box := resolved.inner
		widest_line: f64
		for line_index in 0 ..< input.text_line_count {
			record := &state._text_lines[input.text_line_start + line_index]
			widest_line = math.max(widest_line, f64(record.size.x))
			leading: f64
			switch input.text_style.align {
			case .Start:
			case .Center:
				leading = (f64(box.size.x) - f64(record.size.x)) / 2
			case .End:
				leading = f64(box.size.x) - f64(record.size.x)
			}
			record.position = Vec2 {
				_finite_scalar(state, node, .X, f64(box.position.x) + math.max(leading, 0)),
				_finite_scalar(state, node, .Y, f64(box.position.y) + f64(input.line_height) * f64(line_index)),
			}
		}
		// Horizontal extent is the widest wrapped line, not the max-content
		// width: content_size.x stays at max-content as the preferred size for a
		// later width pass, and reporting it as rendered content would diagnose
		// an overflow the wrapping already resolved.
		horizontal_overflow := widest_line - f64(resolved.inner.size.x)
		resolved.scroll_range = Vec2 {
			_finite_scalar(state, node, .X, math.max(horizontal_overflow, 0)),
			_finite_scalar(state, node, .Y, math.max(f64(input.content_size.y) - f64(resolved.inner.size.y), 0)),
		}
		_record_overflow(state, node, .X, horizontal_overflow)
		_record_overflow(state, node, .Y, f64(input.content_size.y) - f64(resolved.inner.size.y))
	}
}
