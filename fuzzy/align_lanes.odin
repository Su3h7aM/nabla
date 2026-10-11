package fuzzy

import "base:intrinsics"
import "core:simd"

// LANES is the query length the lane-parallel DP handles: lane k holds the
// cell for the query prefix of k + 1 bytes.
LANES :: 16

// LANE_LAYERS is the number of edit layers the lane-parallel DP holds, so it
// handles max_typos below it.
LANE_LAYERS :: 4

// LANE_MAX_CANDIDATE bounds the candidate length the lane-parallel DP takes.
// Its scores are 32-bit, and an unreachable cell loses GAP_EXTEND per byte, so
// a longer candidate could wrap NO_SCORE into the range of real scores.
LANE_MAX_CANDIDATE :: 1 << 24

Lanes :: #simd[LANES]i32

// Lane_Row is one DP row of a layer. Index i + 2 holds the cell for the query
// prefix of i bytes, so lane 0 (i = 1) starts at index 3 and the cells for
// i - 1 and i - 2 are loads at indices 2 and 1.
Lane_Row :: [LANES + 4]i32

// Lane_Layer is the state of one edit count. rows is a ring of three steps:
// the current byte, the byte before, and the one before that.
Lane_Layer :: struct {
	rows: [3]Lane_Row,
	gap:  Lane_Row,
}

@(private = "file", require_results)
splat :: #force_inline proc(value: i32) -> Lanes {
	vector: Lanes = value
	return vector
}

@(private = "file", require_results)
load_lanes :: #force_inline proc(row: ^Lane_Row, start: int) -> Lanes {
	return intrinsics.unaligned_load(cast(^Lanes)&row[start])
}

@(private = "file")
store_lanes :: #force_inline proc(row: ^Lane_Row, start: int, value: Lanes) {
	intrinsics.unaligned_store(cast(^Lanes)&row[start], value)
}

// Comparisons yield unsigned masks; the values are i32, so the masks are
// reinterpreted as lanes of -1 or 0 to share select with them.
@(private = "file", require_results)
equal_mask :: #force_inline proc(left, right: Lanes) -> Lanes {
	return transmute(Lanes)simd.lanes_eq(left, right)
}

@(private = "file", require_results)
at_least_mask :: #force_inline proc(left, right: Lanes) -> Lanes {
	return transmute(Lanes)simd.lanes_ge(left, right)
}

// align_lanes returns the same score and edits as align_scalar for a query of
// at most LANES bytes, a budget below LANE_LAYERS, and a candidate of at most
// LANE_MAX_CANDIDATE bytes. For one candidate byte a cell depends only on the
// previous bytes' rows and on the layer below at this byte, so all query
// positions of a layer advance together, one vector operation per recurrence
// term. It uses the stack, not the Pattern's scratch.
@(private, require_results)
align_lanes :: proc(pattern: ^Pattern, candidate: string, absent_head: int) -> (score, edits: int) {
	query_len := len(pattern.text)
	case_sensitive := pattern.case_sensitive

	position := Lanes{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	zero := splat(0)
	all_ones := splat(-1)
	no_score := splat(NO_SCORE)
	from_second := at_least_mask(position, splat(2))
	from_third := at_least_mask(position, splat(3))
	consecutive_bonus := simd.select(from_second, splat(CONSECUTIVE_BONUS), zero)
	transposed_runs := simd.select(from_third, splat(2 * CONSECUTIVE_BONUS), splat(CONSECUTIVE_BONUS))
	// A deletion that drops the whole query head restarts at position edit + 1.
	restarts: [LANE_LAYERS]Lanes
	for edit in 1 ..< LANE_LAYERS {
		restarts[edit] = simd.select(equal_mask(position, splat(i32(edit) + 1)), splat(-DELETION_COST * i32(edit)), no_score)
	}

	// Padding lanes hold -1, which no candidate byte equals.
	query_raw, query_fold: Lane_Row = -1, -1
	for value, i in transmute([]byte)pattern.text {
		query_raw[i + 3] = i32(value)
		query_fold[i + 3] = i32(fold_byte(value))
	}
	second_raw, second_fold := load_lanes(&query_raw, 3), load_lanes(&query_fold, 3)
	first_raw, first_fold := load_lanes(&query_raw, 2), load_lanes(&query_fold, 2)

	layers: [LANE_LAYERS]Lane_Layer
	for &layer in layers[:pattern.max_typos + 1] {
		for &row in layer.rows {
			row = NO_SCORE
		}
		layer.gap = NO_SCORE
	}
	for &row in layers[0].rows {
		row[2] = 0
	}

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
		current, previous, before_previous := j % 3, (j + 2) % 3, (j + 1) % 3

		raw_value, fold_value := splat(i32(column.value)), splat(i32(fold_byte(column.value)))
		raw_equal, folded_equal := equal_mask(second_raw, raw_value), equal_mask(second_fold, fold_value)
		match := raw_equal if case_sensitive else folded_equal
		earned := splat(MATCH_SCORE + i32(column.boundary)) + simd.select(raw_equal, splat(CASE_BONUS), zero)

		// A substitution must change the byte, and under a case-sensitive query
		// a case twin is not a change.
		changed := simd.select(raw_equal, zero, all_ones)
		if case_sensitive {
			changed = simd.select(folded_equal, zero, changed)
		}
		head_substitutes := column.boundary > 0 && absent_head > 0
		substitutable := changed if head_substitutes else simd.select(from_second, changed, zero)

		transposable, transposed_earned: Lanes
		if column.has_previous {
			previous_raw, previous_fold := splat(i32(column.previous_value)), splat(i32(fold_byte(column.previous_value)))
			first_raw_equal, first_fold_equal := equal_mask(first_raw, raw_value), equal_mask(first_fold, fold_value)
			second_raw_equal, second_fold_equal := equal_mask(second_raw, previous_raw), equal_mask(second_fold, previous_fold)
			first_match := first_raw_equal if case_sensitive else first_fold_equal
			second_match := second_raw_equal if case_sensitive else second_fold_equal
			// Query position 2 may swap only after a boundary; later ones always.
			swap_allowed := from_second if column.previous_boundary > 0 else from_third
			transposable = simd.select(swap_allowed, simd.select(first_match, second_match, zero), zero)
			case_bonuses := simd.select(first_raw_equal, splat(CASE_BONUS), zero) + simd.select(second_raw_equal, splat(CASE_BONUS), zero)
			transposed_earned =
				splat(2 * MATCH_SCORE + i32(column.previous_boundary) + i32(column.boundary) - TRANSPOSITION_COST) + transposed_runs + case_bonuses
		}

		for &layer, edit in layers[:pattern.max_typos + 1] {
			diagonal := simd.max(load_lanes(&layer.rows[previous], 2) + consecutive_bonus, load_lanes(&layer.gap, 2))
			if edit > 0 && column.boundary > 0 && absent_head >= edit {
				diagonal = simd.max(diagonal, restarts[edit])
			}
			cell := simd.select(match, diagonal + earned, no_score)
			if edit > 0 {
				below := &layers[edit - 1]
				substitution := simd.max(load_lanes(&below.rows[previous], 2), load_lanes(&below.gap, 2)) - splat(SUBSTITUTION_COST)
				cell = simd.max(cell, simd.select(substitutable, substitution, no_score))
				deletion := load_lanes(&below.rows[current], 2) - splat(DELETION_COST)
				cell = simd.max(cell, simd.select(from_second, deletion, no_score))
				if column.has_previous {
					transposition := load_lanes(&below.rows[before_previous], 1) + transposed_earned
					cell = simd.max(cell, simd.select(transposable, transposition, no_score))
				}
			}
			store_lanes(&layer.rows[current], 3, cell)
		}

		// Gaps advance after every layer read them, as in align_scalar.
		for &layer, edit in layers[:pattern.max_typos + 1] {
			gap := simd.max(load_lanes(&layer.gap, 3) - splat(GAP_EXTEND), load_lanes(&layer.rows[previous], 3) - splat(GAP_OPEN))
			store_lanes(&layer.gap, 3, gap)
			if cell := int(layer.rows[current][query_len + 2]); cell > score {
				score, edits = cell, edit
			}
		}
	}
	return score, edits
}
