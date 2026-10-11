package fuzzy

import "core:math/bits"
import "core:mem"
import "core:slice"
import "core:strings"

// Scoring weights. A placed query byte earns MATCH_SCORE, CASE_BONUS when the
// bytes agree exactly, CONSECUTIVE_BONUS when it continues the previous
// byte's run, and the boundary bonus of its candidate position. Candidate
// bytes skipped inside the alignment pay GAP_OPEN for the first byte and
// GAP_EXTEND for each further byte; bytes before the first match and after
// the last are free, as in a local alignment. An edit pays its fixed cost and
// earns no match terms for the query byte it covers. EXACT_BONUS,
// PREFIX_BONUS, and SUBSTRING_BONUS keep the direct tiers above the DP.
MATCH_SCORE :: 16
CASE_BONUS :: 2
CONSECUTIVE_BONUS :: 8
BOUNDARY_START :: 10
BOUNDARY_DELIMITER :: 10
BOUNDARY_CAMEL :: 6
GAP_OPEN :: 10
GAP_EXTEND :: 4
SUBSTITUTION_COST :: 12
DELETION_COST :: 12
TRANSPOSITION_COST :: 20
EXACT_BONUS :: 200
PREFIX_BONUS :: 120
SUBSTRING_BONUS :: 20

// QUERY_BYTES_PER_TYPO is how many query bytes buy one default typo, so
// queries under four bytes tolerate none.
QUERY_BYTES_PER_TYPO :: 4

// PER_BYTE_CEILING is the most one query byte can earn: exact case at a start
// boundary continuing a run. The normalized score divides by it times the
// query length, so one threshold serves every query length.
PER_BYTE_CEILING :: MATCH_SCORE + CASE_BONUS + BOUNDARY_START + CONSECUTIVE_BONUS

// MATCH_THRESHOLD is the lowest normalized score match_kept accepts. A single
// typo of a query of five or more bytes stays above it; scattered bytes stay
// below it.
MATCH_THRESHOLD :: 0.45

// NO_SCORE marks an unreachable DP cell. Real scores stay far above it, so
// max discards it without a validity test on every transition.
NO_SCORE :: -1 << 30

// ROWS_PER_LAYER is the number of rows in Rows.
ROWS_PER_LAYER :: 4

// LCS_MAX_QUERY is the longest query the LCS budget filter handles: one bit
// per query byte in a machine word. Longer queries skip the filter.
LCS_MAX_QUERY :: 64

// Rows are the DP state of one edit count, each row indexed by the number of
// query bytes consumed. Scores end exactly at candidate byte j in current,
// j-1 in previous, and j-2 in before_previous; gap ends in skipped bytes.
// Index 0 is the empty alignment: free to start in layer 0, unreachable
// above it.
Rows :: struct {
	before_previous: []int,
	previous:        []int,
	current:         []int,
	gap:             []int,
}

// Pattern is one compiled query. text holds the owned query bytes in
// original case; case_sensitive is smart case, set when the query holds an
// uppercase byte. max_typos is the edit budget fixed at compile time: a
// candidate needing more edits is not kept. layers holds one Rows per edit
// count from 0 to max_typos, backed by scratch, so scoring allocates nothing.
// lcs_masks[b] has bit i set when candidate byte b equals query byte i under
// the case rule; it stays zero for queries over LCS_MAX_QUERY bytes.
// The zero Pattern matches nothing and destroying it is a no-op.
Pattern :: struct {
	text:           string,
	max_typos:      int,
	case_sensitive: bool,
	layers:         []Rows,
	scratch:        []int,
	lcs_masks:      [256]u64,
}

// Match_Kind names how the candidate placed: the direct tiers, a DP alignment
// that placed every query byte, or one that needed edits. None is a true
// non-match with zero scores.
Match_Kind :: enum {
	None,
	Exact,
	Prefix,
	Substring,
	Subsequence,
	Typo,
}

// Match is one candidate's verdict: how it placed, its raw additive score,
// and the raw score divided by the query's per-byte ceiling, clamped to 0..1.
Match :: struct {
	kind:       Match_Kind,
	score:      int,
	normalized: f32,
}

// pattern_compile copies query into a reusable Pattern, allocated with
// allocator. An empty query compiles to the zero Pattern. max_typos defaults
// to one typo per QUERY_BYTES_PER_TYPO query bytes and is clamped below the
// query length so at least one query byte is placed. The caller
// owns the Pattern and releases it with pattern_destroy.
@(require_results)
pattern_compile :: proc(query: string, max_typos: Maybe(int) = nil, allocator := context.allocator) -> (pattern: Pattern, err: mem.Allocator_Error) {
	if len(query) == 0 {
		return {}, nil
	}
	text := strings.clone(query, allocator) or_return
	defer if err != nil {
		delete(text, allocator)
	}
	typos := clamp(max_typos.? or_else len(query) / QUERY_BYTES_PER_TYPO, 0, len(query) - 1)
	stride := len(query) + 1
	scratch := make([]int, ROWS_PER_LAYER * stride * (typos + 1), allocator) or_return
	defer if err != nil {
		delete(scratch, allocator)
	}
	layers := make([]Rows, typos + 1, allocator) or_return
	rest := scratch
	for &rows in layers {
		rows.before_previous, rest = slice.split_at(rest, stride)
		rows.previous, rest = slice.split_at(rest, stride)
		rows.current, rest = slice.split_at(rest, stride)
		rows.gap, rest = slice.split_at(rest, stride)
	}
	pattern = Pattern {
		text           = text,
		max_typos      = typos,
		case_sensitive = has_upper(text),
		layers         = layers,
		scratch        = scratch,
	}
	if len(text) <= LCS_MAX_QUERY {
		fill_lcs_masks(&pattern)
	}
	return pattern, nil
}

// fill_lcs_masks sets bit i of every byte that equals query byte i under the
// case rule, so a case-insensitive query folds both cases into one mask.
@(private)
fill_lcs_masks :: proc(pattern: ^Pattern) {
	for query_byte, i in transmute([]byte)pattern.text {
		bit := u64(1) << uint(i)
		for value in 0 ..< 256 {
			if bytes_equal(query_byte, byte(value), pattern.case_sensitive) {
				pattern.lcs_masks[value] |= bit
			}
		}
	}
}

// pattern_destroy releases the pattern with allocator, which must be the
// allocator that compiled it, and leaves it zeroed.
pattern_destroy :: proc(pattern: ^Pattern, allocator := context.allocator) {
	delete(pattern.text, allocator)
	delete(pattern.layers, allocator)
	delete(pattern.scratch, allocator)
	pattern^ = {}
}

// match_kept reports whether match is placed and normalized at or above
// MATCH_THRESHOLD.
@(require_results)
match_kept :: proc(match: Match) -> bool {
	return match.kind != .None && match.normalized >= MATCH_THRESHOLD
}

// pattern_match scores candidate against the compiled query. Exact, prefix,
// and substring hits are found directly; the rest run the presence prefilter,
// the LCS budget filter, and then the DP. A true non-match returns zeros
// throughout. It borrows the candidate, allocates nothing, and reuses the
// Pattern's rows, so one Pattern scores on one thread at a time.
@(require_results)
pattern_match :: proc(pattern: ^Pattern, candidate: string) -> Match {
	query_len := len(pattern.text)
	if query_len == 0 || len(candidate) + pattern.max_typos < query_len {
		return {}
	}
	absent, absent_head := count_absent(pattern, candidate)
	if absent > pattern.max_typos {
		return {}
	}
	// A direct hit places every query byte, so one absent byte rules it out.
	if absent == 0 {
		if match, ok := match_direct(pattern, candidate); ok {
			return match
		}
	}
	if !lcs_within_budget(pattern, candidate) {
		return {}
	}
	score, edits := align(pattern, candidate, absent_head)
	if score <= 0 {
		return {}
	}
	kind := Match_Kind.Typo if edits > 0 else Match_Kind.Subsequence
	return Match{kind = kind, score = score, normalized = normalize(score, query_len)}
}

// lcs_within_budget reports whether candidate can hold an alignment within
// the edit budget. Every edit leaves at least one query byte in order in the
// candidate: a substitution or deletion drops one byte, and a transposition
// drops one of its two, which still matches. So an alignment within
// max_typos edits implies LCS(query, candidate) >= len(query) - max_typos.
// The LCS length comes from the bit-parallel recurrence of Allison-Dix and
// Hyyro: bit i of v is zero when query byte i extends the common subsequence.
// Queries over LCS_MAX_QUERY bytes always pass.
@(private, require_results)
lcs_within_budget :: proc(pattern: ^Pattern, candidate: string) -> bool {
	query_len := len(pattern.text)
	if query_len > LCS_MAX_QUERY {
		return true
	}
	v := ~u64(0)
	for value in transmute([]byte)candidate {
		u := v & pattern.lcs_masks[value]
		v = (v + u) | (v - u)
	}
	query_mask := ~u64(0) >> uint(LCS_MAX_QUERY - query_len)
	return int(bits.count_ones(~v & query_mask)) >= query_len - pattern.max_typos
}

// match_direct finds the exact, prefix, or best substring placement of the
// whole query in candidate.
@(private, require_results)
match_direct :: proc(pattern: ^Pattern, candidate: string) -> (match: Match, ok: bool) {
	query_len := len(pattern.text)
	if len(candidate) < query_len {
		return {}, false
	}
	if fold_equal(pattern.text, candidate[:query_len], pattern.case_sensitive) {
		kind, bonus := Match_Kind.Prefix, PREFIX_BONUS
		if len(candidate) == query_len {
			kind, bonus = .Exact, EXACT_BONUS
		}
		score := bonus + window_score(pattern.text, candidate, 0)
		return Match{kind = kind, score = score, normalized = normalize(score, query_len)}, true
	}
	best := NO_SCORE
	for start in 1 ..= len(candidate) - query_len {
		if fold_equal(pattern.text, candidate[start:][:query_len], pattern.case_sensitive) {
			best = max(best, SUBSTRING_BONUS + window_score(pattern.text, candidate, start))
		}
	}
	if best == NO_SCORE {
		return {}, false
	}
	return Match{kind = .Substring, score = best, normalized = normalize(best, query_len)}, true
}

// window_score is the raw score of the query placed as one run at start.
@(private, require_results)
window_score :: proc(query, candidate: string, start: int) -> int {
	run := candidate[start:][:len(query)]
	return len(query) * MATCH_SCORE + count_exact_case(query, run) * CASE_BONUS + (len(query) - 1) * CONSECUTIVE_BONUS + boundary_bonus_at(candidate, start)
}

// normalize maps score onto the 0..1 scale of the query's per-byte ceiling.
@(private, require_results)
normalize :: proc(score, query_len: int) -> f32 {
	return clamp(f32(score) / f32(PER_BYTE_CEILING * query_len), 0, 1)
}

// count_absent counts query bytes with no equal byte anywhere in candidate,
// and how many of them lead the query. Each needs an edit, so more than
// max_typos rules the candidate out before the DP runs.
@(private, require_results)
count_absent :: proc(pattern: ^Pattern, candidate: string) -> (absent, absent_head: int) {
	present: [256]bool
	for value in transmute([]byte)candidate {
		present[fold_for(value, pattern.case_sensitive)] = true
	}
	for value in transmute([]byte)pattern.text {
		if present[fold_for(value, pattern.case_sensitive)] {
			break
		}
		absent_head += 1
	}
	for value in transmute([]byte)pattern.text {
		if !present[fold_for(value, pattern.case_sensitive)] {
			absent += 1
		}
	}
	return absent, absent_head
}

// align runs the DP over candidate through the lane-parallel form when the
// query, budget, and candidate fit it, and through align_scalar otherwise.
// Both return the same score and edits.
@(private, require_results)
align :: proc(pattern: ^Pattern, candidate: string, absent_head: int) -> (score, edits: int) {
	if len(pattern.text) <= LANES && pattern.max_typos < LANE_LAYERS && len(candidate) <= LANE_MAX_CANDIDATE {
		return align_lanes(pattern, candidate, absent_head)
	}
	return align_scalar(pattern, candidate, absent_head)
}

// align_scalar runs the DP over candidate and returns the best score that consumes
// the whole query and the edits that score used, or NO_SCORE when no
// alignment fits the budget. Each layer holds the alignments with exactly
// that many edits, so the budget is exact. Only the first query byte starts
// fresh anywhere. An edit that covers the head of the query must land on a
// word boundary, and a substituted or deleted head byte must be one of the
// absent_head leading bytes the candidate lacks, so a query cannot drop its
// head to match the middle of a word or give up a byte it could place.
@(private, require_results)
align_scalar :: proc(pattern: ^Pattern, candidate: string, absent_head: int) -> (score, edits: int) {
	slice.fill(pattern.scratch, NO_SCORE)
	pattern.layers[0].before_previous[0] = 0
	pattern.layers[0].previous[0] = 0
	pattern.layers[0].current[0] = 0
	score = NO_SCORE
	column: Column
	for j in 0 ..< len(candidate) {
		column = Column {
			value             = candidate[j],
			previous_value    = candidate[j - 1] if j > 0 else 0,
			boundary          = boundary_bonus_at(candidate, j),
			previous_boundary = column.boundary,
			has_previous      = j > 0,
		}
		for &rows, edit in pattern.layers {
			below := &pattern.layers[edit - 1] if edit > 0 else nil
			for i in 1 ..= len(pattern.text) {
				rows.current[i] = cell_score(pattern, &rows, below, column, edit, i, absent_head)
			}
		}
		// Gaps advance after every layer read them: a substitution reads the
		// layer below as of the previous byte.
		for &rows, edit in pattern.layers {
			for i in 1 ..= len(pattern.text) {
				rows.gap[i] = max(rows.gap[i] - GAP_EXTEND, rows.previous[i] - GAP_OPEN)
			}
			if rows.current[len(pattern.text)] > score {
				score, edits = rows.current[len(pattern.text)], edit
			}
			rows.before_previous, rows.previous, rows.current = rows.previous, rows.current, rows.before_previous
		}
	}
	return score, edits
}

// Column is the candidate-side input of one DP step: byte j, the byte before
// it, and their boundary bonuses, computed once per byte instead of per cell.
Column :: struct {
	value:             byte,
	previous_value:    byte,
	boundary:          int,
	previous_boundary: int,
	has_previous:      bool,
}

// cell_score is the best score of query[:i] ending at the column's byte with
// exactly edit edits: a match, or one edit applied on top of below, the layer
// of edit - 1 (nil for edit 0), both advanced to this column.
@(private, require_results)
cell_score :: proc(pattern: ^Pattern, rows, below: ^Rows, column: Column, edit, i, absent_head: int) -> int {
	query_byte, candidate_byte := pattern.text[i - 1], column.value
	boundary := column.boundary
	cell := NO_SCORE
	if bytes_equal(query_byte, candidate_byte, pattern.case_sensitive) {
		consecutive := CONSECUTIVE_BONUS if i > 1 else 0
		restart := NO_SCORE
		if i > 1 && edit == i - 1 && boundary > 0 && absent_head >= edit {
			restart = -DELETION_COST * edit
		}
		earned := MATCH_SCORE + boundary + case_bonus(query_byte, candidate_byte)
		cell = max(rows.previous[i - 1] + consecutive, rows.gap[i - 1], restart) + earned
	}
	if edit == 0 {
		return cell
	}
	if sub_consumable(query_byte, candidate_byte, pattern.case_sensitive) && (i > 1 || (boundary > 0 && absent_head > 0)) {
		cell = max(cell, max(below.previous[i - 1], below.gap[i - 1]) - SUBSTITUTION_COST)
	}
	if i < 2 {
		return cell
	}
	cell = max(cell, below.current[i - 1] - DELETION_COST)
	if column.has_previous {
		first, second := pattern.text[i - 2], pattern.text[i - 1]
		first_boundary := column.previous_boundary
		if bytes_equal(first, candidate_byte, pattern.case_sensitive) &&
		   bytes_equal(second, column.previous_value, pattern.case_sensitive) &&
		   (i > 2 || first_boundary > 0) {
			runs := 2 if i > 2 else 1
			earned := 2 * MATCH_SCORE + runs * CONSECUTIVE_BONUS + first_boundary + boundary
			earned += case_bonus(first, candidate_byte) + case_bonus(second, column.previous_value) - TRANSPOSITION_COST
			cell = max(cell, below.before_previous[i - 2] + earned)
		}
	}
	return cell
}

// has_upper reports whether text holds an ASCII uppercase byte, which makes a
// query case-sensitive.
@(private, require_results)
has_upper :: proc(text: string) -> bool {
	for value in transmute([]byte)text {
		if value >= 'A' && value <= 'Z' {
			return true
		}
	}
	return false
}

// fold_byte lowercases one ASCII byte; other bytes pass through.
@(private, require_results)
fold_byte :: #force_inline proc(value: byte) -> byte {
	if value >= 'A' && value <= 'Z' {
		return value + ('a' - 'A')
	}
	return value
}

// fold_for returns value as the query's case rule compares it.
@(private, require_results)
fold_for :: #force_inline proc(value: byte, case_sensitive: bool) -> byte {
	return value if case_sensitive else fold_byte(value)
}

// bytes_equal reports whether two bytes match under the case rule. Non-ASCII
// bytes match only themselves.
@(private, require_results)
bytes_equal :: #force_inline proc(query_byte, candidate_byte: byte, case_sensitive: bool) -> bool {
	return fold_for(query_byte, case_sensitive) == fold_for(candidate_byte, case_sensitive)
}

// sub_consumable reports whether the candidate byte may stand in for the
// query byte as a substitution: the bytes differ, and not by case alone under
// a case-sensitive query, which must not repair into its case twin.
@(private, require_results)
sub_consumable :: #force_inline proc(query_byte, candidate_byte: byte, case_sensitive: bool) -> bool {
	if query_byte == candidate_byte {
		return false
	}
	return !case_sensitive || fold_byte(query_byte) != fold_byte(candidate_byte)
}

// case_bonus rewards a byte-identical placement.
@(private, require_results)
case_bonus :: #force_inline proc(query_byte, candidate_byte: byte) -> int {
	return CASE_BONUS if query_byte == candidate_byte else 0
}

// fold_equal reports whether two equal-length strings match bytewise under
// the case rule.
@(private, require_results)
fold_equal :: proc(query, candidate: string, case_sensitive: bool) -> bool {
	if len(query) != len(candidate) {
		return false
	}
	for i in 0 ..< len(query) {
		if !bytes_equal(query[i], candidate[i], case_sensitive) {
			return false
		}
	}
	return true
}

// count_exact_case counts byte-identical positions in two equal-length
// strings.
@(private, require_results)
count_exact_case :: proc(query, candidate: string) -> (count: int) {
	for i in 0 ..< len(query) {
		if query[i] == candidate[i] {
			count += 1
		}
	}
	return count
}

// is_delimiter reports whether a byte ends a word for boundary bonuses.
@(private, require_results)
is_delimiter :: proc(value: byte) -> bool {
	switch value {
	case '/', '\\', '_', '-', '.', ' ', ':':
		return true
	}
	return false
}

// boundary_bonus_at rewards a placement at the candidate start, after a
// delimiter, and at a lower-to-upper camel hump.
@(private, require_results)
boundary_bonus_at :: proc(candidate: string, j: int) -> int {
	if j == 0 {
		return BOUNDARY_START
	}
	previous, current := candidate[j - 1], candidate[j]
	if is_delimiter(previous) {
		return BOUNDARY_DELIMITER
	}
	if previous >= 'a' && previous <= 'z' && current >= 'A' && current <= 'Z' {
		return BOUNDARY_CAMEL
	}
	return 0
}
