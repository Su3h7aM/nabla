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
	node, declared := _declare_node(ctx, element_desc, false, loc, style_diagnostics)
	if !declared {
		return
	}

	input := &state._node_inputs[node]
	input.is_text = true
	input.text = desc.text
	input.text_style = desc.style
	input.text_flags = desc.flags
	_normalize_nonnegative(state, &input.text_style.size, node, .Y, loc)
	_normalize_nonnegative(state, &input.text_style.line_height, node, .Y, loc)
	_normalize_nonnegative(state, &input.text_style.letter_spacing, node, .X, loc)
	// Folded here, after normalization, so every run measured from this node
	// reuses one hash of the string instead of rehashing a substring per lookup.
	input.text_key = _text_identity_key(state, input^)
	state._nodes[node].flags.is_text = true
}

/*
Fold the identity of a text node's content and style into one key.

Runs measured from this node differ only by which substring they cover, so the
per-run key is this value extended with that substring's offset and length. That
keeps a cache lookup proportional to the key size rather than to the text: with
a hash over each candidate substring instead, wrapping a paragraph spent more
time hashing bytes than the measurement callback it was avoiding.
*/
@(private)
_text_identity_key :: proc(state: ^_Context_State, input: _Node_Input) -> u64 {
	style := input.text_style
	key := u64(FNV64_OFFSET_BASIS)
	if .Static in input.text_flags {
		key = _hash_index(key, u64(uintptr(raw_data(input.text))))
		key = _hash_index(key, u64(len(input.text)))
		// Pointer identity is only sound while the buffer really is immortal, so
		// debug builds fold the content in too: a reused buffer then changes the
		// key instead of silently reusing a stale measurement.
		when ODIN_DEBUG {
			key = _hash_index(key, hash.fnv64a(transmute([]byte)input.text))
		}
	} else {
		key = _hash_index(key, hash.fnv64a(transmute([]byte)input.text))
	}
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
}

/*
Key a text measurement.

Line breaking is performed by the core over unbounded run measurements, so the
request width is not part of the key: every text measurement is unbounded, and
the resolved width influences which runs are measured rather than their extent.
Every remaining field of the normative key changes the measured result.
*/
@(private)
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

/*
Locate a measured run inside its node's text.

Runs handed to the measurer are always slices of the node's own string, so the
offset is pointer arithmetic rather than a search. A run that does not lie
within the node's text has no stable identity relative to it and is reported as
not cacheable, which keeps the key sound if a future caller measures a string
from elsewhere.
*/
@(private)
_run_offset_in :: proc "contextless" (text, run: string) -> (offset: int, within: bool) {
	if len(run) > len(text) {
		return 0, false
	}
	base := uintptr(raw_data(text))
	run_base := uintptr(raw_data(run))
	if run_base < base {
		return 0, false
	}
	offset = int(run_base - base)
	if offset + len(run) > len(text) {
		return 0, false
	}
	return offset, true
}

@(private)
MEASURE_CACHE_PROBE_LIMIT :: 8

@(private)
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

Width is the widest hard segment; the floor is the longest unbreakable run,
which is the longest word when words may wrap and the whole segment otherwise.
Height is the resolved line height times the hard-segment count, which is the
line count before any soft wrapping.
*/
@(private)
_measure_text_intrinsic :: proc(state: ^_Context_State, node: Node_Handle) -> Measure_Result {
	input := &state._node_inputs[node]
	text := input.text
	wrap := input.text_style.wrap

	widest: f64
	longest_unbreakable: f64
	natural_line_height: f64
	segment_count := 0

	// Words measured here are recorded with their advances so wrapping can pack
	// lines by summing, rather than measuring every word a second time. The
	// records are dropped wholesale if the pool cannot hold them, which costs
	// speed and nothing else.
	input.word_start = len(state._measured_words)
	input.word_count = 0
	recording := wrap == .Words && cap(state._measured_words) > 0

	// Wrap.None never calls the breaker: the whole string is one segment,
	// measured once, which preserves the historical whole-string behavior
	// (including the measurer error it provokes when no measurer is set).
	if wrap == .None {
		measured := _measure_text_run_cached(state, node, text, _unbounded_request())
		widest = math.max(widest, f64(measured.size.x))
		longest_unbreakable = math.max(longest_unbreakable, f64(measured.size.x))
		natural_line_height = math.max(natural_line_height, f64(measured.size.y))
		segment_count = 1
	} else {
		offset := 0
		segment_start := 0
		segment_index := 0
		for {
			piece_end, next_offset, kind := _break_text(state, node, text, offset)
			if state._frame_error != .None {
				break
			}
			// A non-empty piece is a word when words may wrap.
			if wrap == .Words && piece_end > offset {
				word := text[offset:piece_end]
				word_measured := _measure_text_run_cached(state, node, word, _unbounded_request())
				longest_unbreakable = math.max(longest_unbreakable, f64(word_measured.size.x))
				natural_line_height = math.max(natural_line_height, f64(word_measured.size.y))

				if recording {
					// The separator is the whitespace between this word and the
					// next, so its advance is measured once here alongside the
					// word itself. A Mandatory separator is a line terminator
					// that belongs to the break, not to the word.
					separator_end := piece_end
					separator_width: Scalar
					if kind == .Optional && next_offset > piece_end {
						separator := text[piece_end:next_offset]
						separator_end = next_offset
						separator_width = _measure_text_run_cached(state, node, separator, _unbounded_request()).size.x
					}
					record := _Measured_Word {
						offset          = i32(offset),
						length          = i32(piece_end - offset),
						separator_end   = i32(separator_end),
						width           = word_measured.size.x,
						separator_width = separator_width,
						height          = word_measured.size.y,
						segment         = i32(segment_index),
					}
					if !_try_append(&state._measured_words, record) {
						// Out of room: fall back to measuring during wrapping.
						// Geometry is unchanged either way, so this is not a frame error.
						recording = false
						input.word_count = 0
					} else {
						input.word_count += 1
					}
				}
			}
			// A hard segment ends at the piece a Mandatory (or None) separator
			// follows. Measure it as one unit: widest, natural line height, and
			// the shrink floor when words do not wrap.
			if kind == .Mandatory || kind == .None {
				segment := text[segment_start:piece_end]
				measured := _measure_text_run_cached(state, node, segment, _unbounded_request())
				widest = math.max(widest, f64(measured.size.x))
				natural_line_height = math.max(natural_line_height, f64(measured.size.y))
				if wrap != .Words {
					longest_unbreakable = math.max(longest_unbreakable, f64(measured.size.x))
				}
				segment_start = next_offset
				segment_index += 1
				segment_count += 1
				if kind == .None {
					break
				}
			}
			offset = next_offset
		}
	}
	if !recording {
		input.word_count = 0
	}
	input.segment_count = segment_count
	_update_high_water(state, .Measured_Words, len(state._measured_words))

	line_height := f64(input.text_style.line_height)
	if line_height == 0 {
		line_height = natural_line_height
	}
	input.line_height = _finite_scalar(state, node, .Y, line_height, false)

	height := line_height * f64(segment_count)
	return Measure_Result {
		size = {_finite_scalar(state, node, .X, widest, false), _finite_scalar(state, node, .Y, height, false)},
		min_size = {_finite_scalar(state, node, .X, longest_unbreakable, false), _finite_scalar(state, node, .Y, height, false)},
	}
}

@(private)
_append_text_line :: proc(state: ^_Context_State, node: Node_Handle, line: string, line_index: int) -> (Vec2, bool) {
	measured := _measure_text_run_cached(state, node, line, _unbounded_request())
	size := Vec2{measured.size.x, state._node_inputs[node].line_height}
	if line_index > int(max(u16)) {
		_latch_capacity_error(state, .Text_Lines, state._node_inputs[node].loc)
		return size, false
	}
	record := _Text_Line_Record {
		text     = line,
		size     = size,
		line     = u16(line_index),
		baseline = measured.baseline,
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
fit starts a new line, and a word too wide for an empty line occupies that line
alone and overflows. `Wrap.Newlines` and `Wrap.None` never break inside a hard
segment.
*/
@(private)
_wrap_text_node :: proc(state: ^_Context_State, node: Node_Handle) -> bool {
	input := &state._node_inputs[node]
	input.text_line_start = len(state._text_lines)
	input.text_line_count = 0

	available := f64(state._nodes[node].inner.size.x)
	wrap := input.text_style.wrap
	widest: f64

	if input.word_count > 0 {
		return _wrap_text_node_from_records(state, node, available)
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
		// Wrap.Newlines: one line per hard segment.
		offset := 0
		segment_start := 0
		for {
			piece_end, next_offset, kind := _break_text(state, node, input.text, offset)
			if state._frame_error != .None {
				return false
			}
			if kind == .Mandatory || kind == .None {
				size, appended := _append_text_line(state, node, input.text[segment_start:piece_end], input.text_line_count)
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
	block_height := f64(input.line_height) * f64(input.text_line_count)
	input.content_size.y = _finite_scalar(state, node, .Y, block_height, false)
	// The wrapped block height is a hard floor: shrinking height would clip lines.
	input.content_minimum.y = input.content_size.y
	return true
}

/*
Break a text node into lines using the advances recorded at intrinsic sizing.

The fast path, and the reason it exists: intrinsic sizing already measured every
word to find the shrink floor, so packing lines needs no measurement at all —
just a running sum over the records and one line measurement per emitted line.
Measuring words again here instead made text roughly three cache lookups per
word, which is what put this library behind Clay on wrapping.

Line breaking is identical to the measuring path: greedy packing, a word too
wide for an empty line occupies that line alone, and a hard segment always
occupies at least one line.
*/
@(private)
_wrap_text_node_from_records :: proc(state: ^_Context_State, node: Node_Handle, available: f64) -> bool {
	input := &state._node_inputs[node]
	words := state._measured_words[input.word_start:input.word_start + input.word_count]

	line_start := -1
	line_end := 0
	line_width: f64
	segment := i32(0)
	segment_lines := 0

	flush_line :: proc(state: ^_Context_State, node: Node_Handle, text: string) -> bool {
		input := &state._node_inputs[node]
		_, appended := _append_text_line(state, node, text, input.text_line_count)
		if !appended {
			return false
		}
		input.text_line_count += 1
		return true
	}

	for record, index in words {
		// A new hard segment always starts a new line, because a newline is a
		// break the wrapper may not undo.
		if record.segment != segment {
			if line_start >= 0 {
				if !flush_line(state, node, input.text[line_start:line_end]) {
					return false
				}
				segment_lines += 1
			}
			if segment_lines == 0 {
				// The previous segment held no words at all, so it still owes a
				// line: an empty one.
				if !flush_line(state, node, "") {
					return false
				}
			}
			for empty in segment + 1 ..< record.segment {
				_ = empty
				if !flush_line(state, node, "") {
					return false
				}
			}
			segment = record.segment
			segment_lines = 0
			line_start = -1
			line_width = 0
		}

		word_end := int(record.offset) + int(record.length)
		if line_start >= 0 {
			previous := words[index - 1]
			if line_width + f64(previous.separator_width) + f64(record.width) > available {
				if !flush_line(state, node, input.text[line_start:line_end]) {
					return false
				}
				segment_lines += 1
				line_start = -1
			} else {
				line_width += f64(previous.separator_width) + f64(record.width)
				line_end = word_end
				continue
			}
		}
		line_start = int(record.offset)
		line_end = word_end
		line_width = f64(record.width)
	}

	if line_start >= 0 {
		if !flush_line(state, node, input.text[line_start:line_end]) {
			return false
		}
		segment_lines += 1
	}
	if segment_lines == 0 {
		if !flush_line(state, node, "") {
			return false
		}
	}
	// Segments after the last word carry no words of their own but still occupy
	// a line each.
	for trailing in int(segment) + 1 ..< input.segment_count {
		_ = trailing
		if !flush_line(state, node, "") {
			return false
		}
	}

	block_height := f64(input.line_height) * f64(input.text_line_count)
	input.content_size.y = _finite_scalar(state, node, .Y, block_height, false)
	input.content_minimum.y = input.content_size.y
	return true
}

@(private)
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
