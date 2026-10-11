#+test
#+private file
package fuzzy

import "core:math/rand"
import "core:mem"
import "core:strings"
import "core:testing"

// compile_pattern builds a Pattern or fails the test.
compile_pattern :: proc(t: ^testing.T, query: string, max_typos: Maybe(int) = nil) -> Pattern {
	pattern, err := pattern_compile(query, max_typos)
	testing.expect_value(t, err, nil)
	return pattern
}

@(test)
test_true_non_matches_score_clean_zero :: proc(t: ^testing.T) {
	pattern := compile_pattern(t, "hello")
	defer pattern_destroy(&pattern)
	for candidate in ([]string{"", "world", "xyz", "help", "hlo", "taste"}) {
		m := pattern_match(&pattern, candidate)
		testing.expectf(t, m == Match{}, "%q: got %v", candidate, m)
		testing.expect(t, !match_kept(m))
	}
	zero: Pattern
	testing.expect_value(t, pattern_match(&zero, "anything"), Match{})
	pattern_destroy(&zero)
	empty := compile_pattern(t, "")
	testing.expect_value(t, pattern_match(&empty, "anything"), Match{})
}

@(test)
test_tiers_rank_exact_above_prefix_above_boundaries_above_plain :: proc(t: ^testing.T) {
	pattern := compile_pattern(t, "bar")
	defer pattern_destroy(&pattern)
	exact := pattern_match(&pattern, "bar")
	prefix := pattern_match(&pattern, "barista")
	delimited := pattern_match(&pattern, "foo_bar")
	camel := pattern_match(&pattern, "fooBar")
	plain := pattern_match(&pattern, "xbarx")
	testing.expect_value(t, exact.kind, Match_Kind.Exact)
	testing.expect_value(t, prefix.kind, Match_Kind.Prefix)
	testing.expect_value(t, delimited.kind, Match_Kind.Substring)
	testing.expect_value(t, camel.kind, Match_Kind.Substring)
	testing.expect_value(t, plain.kind, Match_Kind.Substring)
	testing.expect_value(t, exact.normalized, 1)
	testing.expect(t, exact.score > prefix.score)
	testing.expect(t, prefix.score > delimited.score)
	testing.expect(t, delimited.score > camel.score)
	testing.expect(t, camel.score > plain.score)
	for m in ([]Match{exact, prefix, delimited, camel, plain}) {
		testing.expect(t, match_kept(m))
	}
}

@(test)
test_single_typos_rank_intended_target_first :: proc(t: ^testing.T) {
	Case :: struct {
		query:    string,
		intended: string,
		rivals:   []string,
	}
	cases := []Case {
		{"confix", "config", {"confg", "collapse of firms in general", "icon", "xyz"}},
		{"helllo", "hello", {"hollow", "help", "hlo", "world"}},
		{"hlelo", "hello", {"hollow", "help", "yellow", "world"}},
		{"searchpaih", "searchpath", {"search_pad_h", "research", "path"}},
		{"hallo", "hello", {"help", "yellow", "world"}},
		{"mello", "hello", {"world", "help", "xyz"}},
		{"ehllo", "hello", {"world", "help", "xyz"}},
		{"xhello", "hello", {"world", "help", "hlo"}},
	}
	for entry in cases {
		pattern := compile_pattern(t, entry.query)
		defer pattern_destroy(&pattern)
		intended := pattern_match(&pattern, entry.intended)
		testing.expectf(t, intended.kind == .Typo && match_kept(intended), "%q vs %q: got %v", entry.query, entry.intended, intended)
		for candidate in entry.rivals {
			rival := pattern_match(&pattern, candidate)
			testing.expectf(
				t,
				intended.score > rival.score,
				"%q: %q scores %d, rival %q scores %d",
				entry.query,
				entry.intended,
				intended.score,
				candidate,
				rival.score,
			)
		}
	}
}

@(test)
test_only_the_first_query_byte_starts_fresh :: proc(t: ^testing.T) {
	pattern := compile_pattern(t, "hello")
	defer pattern_destroy(&pattern)
	far_head := strings.concatenate({"h", strings.repeat("z", 80, context.temp_allocator), "ello"}, context.temp_allocator)
	dropped_head := strings.concatenate({strings.repeat("z", 24, context.temp_allocator), "ello"}, context.temp_allocator)
	for candidate in ([]string{far_head, dropped_head}) {
		m := pattern_match(&pattern, candidate)
		testing.expectf(t, !match_kept(m), "%q: got %v", candidate, m)
	}
}

@(test)
test_scatter_is_not_kept_and_ranks_below_a_typo :: proc(t: ^testing.T) {
	pattern := compile_pattern(t, "hello")
	defer pattern_destroy(&pattern)
	typo := pattern_match(&pattern, "hallo")
	testing.expect(t, match_kept(typo))
	for candidate in ([]string{"h x e x l x l x o", "h--------------------ello"}) {
		scatter := pattern_match(&pattern, candidate)
		testing.expectf(t, !match_kept(scatter), "%q: got %v", candidate, scatter)
		testing.expectf(t, typo.score > scatter.score, "typo %d must outrank %q at %d", typo.score, candidate, scatter.score)
	}
	near := pattern_match(&pattern, "h-ello")
	testing.expectf(t, match_kept(near) && near.kind == .Subsequence, "one skipped byte is a near miss: got %v", near)
}

@(test)
test_edit_budget_limits_typos :: proc(t: ^testing.T) {
	pattern := compile_pattern(t, "searchpath")
	defer pattern_destroy(&pattern)
	testing.expect_value(t, pattern.max_typos, 2)
	testing.expect(t, match_kept(pattern_match(&pattern, "seerchpaih")))
	three := pattern_match(&pattern, "seerchpxih")
	testing.expectf(t, !match_kept(three), "three edits exceed the budget: got %v", three)
	strict := compile_pattern(t, "hello", 0)
	defer pattern_destroy(&strict)
	testing.expect(t, !match_kept(pattern_match(&strict, "hallo")))
	testing.expect(t, match_kept(pattern_match(&strict, "say hello")))
	short := compile_pattern(t, "abc")
	defer pattern_destroy(&short)
	testing.expect_value(t, short.max_typos, 0)
}

@(test)
test_smart_case_respects_uppercase_queries :: proc(t: ^testing.T) {
	sensitive := compile_pattern(t, "Foo")
	defer pattern_destroy(&sensitive)
	testing.expect(t, sensitive.case_sensitive)
	testing.expect_value(t, pattern_match(&sensitive, "Foo").kind, Match_Kind.Exact)
	for candidate in ([]string{"foo", "FOO"}) {
		testing.expect_value(t, pattern_match(&sensitive, candidate), Match{})
	}
	insensitive := compile_pattern(t, "foo")
	defer pattern_destroy(&insensitive)
	testing.expect(t, !insensitive.case_sensitive)
	for candidate in ([]string{"foo", "FOO", "Foo"}) {
		testing.expect_value(t, pattern_match(&insensitive, candidate).kind, Match_Kind.Exact)
	}
}

@(test)
test_top_k_keeps_the_best_hits_of_a_stream :: proc(t: ^testing.T) {
	pattern := compile_pattern(t, "hello")
	defer pattern_destroy(&pattern)
	top, make_err := top_k_make(3)
	testing.expect_value(t, make_err, nil)
	defer top_k_destroy(&top)
	// Index 0 is the weakest kept row and is evicted by the fourth kept row.
	candidates := []string{"hallo", "hello_world", "world", "hello", "xhellox"}
	for candidate, index in candidates {
		top_k_offer(&top, &pattern, index, candidate)
	}
	testing.expect_value(t, top.count, 3)
	ordered := top_k_sorted(&top)
	testing.expect_value(t, len(ordered), 3)
	testing.expect_value(t, ordered[0].index, 3)
	testing.expect_value(t, ordered[1].index, 1)
	testing.expect_value(t, ordered[2].index, 4)
	top_k_clear(&top)
	testing.expect_value(t, top.count, 0)
}

@(test)
test_equal_scores_rank_the_compact_candidate_first :: proc(t: ^testing.T) {
	pattern := compile_pattern(t, "hallo")
	defer pattern_destroy(&pattern)
	candidates := []string{"hollow", "hello"}
	hits, err := match_list(&pattern, candidates, 2)
	testing.expect_value(t, err, nil)
	defer delete(hits)
	testing.expect_value(t, len(hits), 2)
	testing.expect_value(t, candidates[hits[0].index], "hello")
}

@(test)
test_match_list_returns_kept_hits_best_first :: proc(t: ^testing.T) {
	pattern := compile_pattern(t, "hello")
	defer pattern_destroy(&pattern)
	candidates := []string{"world", "hallo", "xhellox", "hello", "hello_world"}
	hits, err := match_list(&pattern, candidates, 10)
	testing.expect_value(t, err, nil)
	defer delete(hits)
	testing.expect_value(t, len(hits), 4)
	order := [?]int{3, 4, 2, 1}
	for hit, i in hits {
		testing.expect_value(t, hit.index, order[i])
	}
	limited, limited_err := match_list(&pattern, candidates, 1)
	testing.expect_value(t, limited_err, nil)
	defer delete(limited)
	testing.expect_value(t, len(limited), 1)
	testing.expect_value(t, limited[0].index, 3)
	none, none_err := match_list(&pattern, candidates, 0)
	testing.expect_value(t, none_err, nil)
	testing.expect_value(t, len(none), 0)
}

@(test)
test_top_k_with_zero_capacity_ignores_every_offer :: proc(t: ^testing.T) {
	pattern := compile_pattern(t, "hello")
	defer pattern_destroy(&pattern)
	top, make_err := top_k_make(0)
	testing.expect_value(t, make_err, nil)
	defer top_k_destroy(&top)
	top_k_offer(&top, &pattern, 0, "hello")
	testing.expect_value(t, top.count, 0)
	testing.expect_value(t, len(top_k_sorted(&top)), 0)
}

@(test)
test_scoring_and_selection_allocate_nothing_per_candidate :: proc(t: ^testing.T) {
	pattern := compile_pattern(t, "hello")
	defer pattern_destroy(&pattern)
	top, make_err := top_k_make(8)
	testing.expect_value(t, make_err, nil)
	defer top_k_destroy(&top)
	pool := []string{"hello", "hallo", "world", "xyz", "hollow", "h x e x l x l x o"}
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator = mem.tracking_allocator(&tracker)
	before := tracker.total_allocation_count
	for i in 0 ..< 1000 {
		top_k_offer(&top, &pattern, i, pool[i % len(pool)])
	}
	testing.expect(t, len(top_k_sorted(&top)) > 0)
	testing.expect_value(t, tracker.total_allocation_count, before)
}

// perturb_query returns the query with a few random edits and random padding,
// so many candidates sit near the edit budget.
perturb_query :: proc(query: string, allocator := context.allocator) -> string {
	alphabet := "abcdehlopqrstwz_/.-ARSP"
	builder := strings.builder_make(allocator)
	for _ in 0 ..< rand.int_max(4) {
		strings.write_byte(&builder, alphabet[rand.int_max(len(alphabet))])
	}
	bytes := make([dynamic]byte, 0, len(query) + 8, context.temp_allocator)
	append(&bytes, query)
	for _ in 0 ..< rand.int_max(5) {
		at := rand.int_max(len(bytes))
		switch rand.int_max(5) {
		case 0:
			bytes[at] = alphabet[rand.int_max(len(alphabet))]
		case 1:
			if len(bytes) > 1 {
				ordered_remove(&bytes, at)
			}
		case 2:
			inject_at(&bytes, at, alphabet[rand.int_max(len(alphabet))])
		case 3:
			if at + 1 < len(bytes) {
				bytes[at], bytes[at + 1] = bytes[at + 1], bytes[at]
			}
		case 4:
			bytes[at] ~= 'a' - 'A'
		}
	}
	strings.write_bytes(&builder, bytes[:])
	for _ in 0 ..< rand.int_max(4) {
		strings.write_byte(&builder, alphabet[rand.int_max(len(alphabet))])
	}
	return strings.to_string(builder)
}

@(test)
test_lcs_filter_never_rejects_a_candidate_the_dp_aligns :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(0x5eed)
	context.random_generator = rand.default_random_generator(&state)
	Case :: struct {
		query:     string,
		max_typos: Maybe(int),
	}
	cases := []Case{{"hello", nil}, {"hello", 3}, {"parser", nil}, {"allocatr", nil}, {"dir_walker", nil}, {"SearchPath", nil}, {"searchpath", 4}}
	rejected := 0
	for entry in cases {
		pattern := compile_pattern(t, entry.query, entry.max_typos)
		defer pattern_destroy(&pattern)
		for _ in 0 ..< 400 {
			candidate := perturb_query(entry.query, context.temp_allocator)
			absent, absent_head := count_absent(&pattern, candidate)
			if absent > pattern.max_typos {
				continue
			}
			passes := lcs_within_budget(&pattern, candidate)
			rejected += 0 if passes else 1
			score, _ := align(&pattern, candidate, absent_head)
			if score > NO_SCORE / 2 {
				testing.expectf(t, passes, "%q vs %q: DP aligns with score %d but the filter rejects it", entry.query, candidate, score)
			}
		}
	}
	testing.expect(t, rejected > 0, "the filter must reject some candidates for the test to mean anything")
}

@(test)
test_lane_dp_matches_the_scalar_dp :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(0x1a4e)
	context.random_generator = rand.default_random_generator(&state)
	Case :: struct {
		query:     string,
		max_typos: Maybe(int),
	}
	cases := []Case {
		{"x", nil},
		{"hello", nil},
		{"hello", 1},
		{"hello", 3},
		{"parser", nil},
		{"Parser", 2},
		{"dir_walker", nil},
		{"searchpath", 3},
		{"SearchPath", nil},
		{"abcdefghijklmnop", 3},
	}
	for entry in cases {
		pattern := compile_pattern(t, entry.query, entry.max_typos)
		defer pattern_destroy(&pattern)
		for _ in 0 ..< 500 {
			candidate := perturb_query(entry.query, context.temp_allocator)
			_, absent_head := count_absent(&pattern, candidate)
			scalar_score, scalar_edits := align_scalar(&pattern, candidate, absent_head)
			lane_score, lane_edits := align_lanes(&pattern, candidate, absent_head)
			// Scores at or below zero are a non-match whatever their edits.
			if scalar_score > 0 || lane_score > 0 {
				testing.expectf(
					t,
					scalar_score == lane_score && scalar_edits == lane_edits,
					"%q vs %q: scalar (%d, %d), lanes (%d, %d)",
					entry.query,
					candidate,
					scalar_score,
					scalar_edits,
					lane_score,
					lane_edits,
				)
			}
		}
	}
}
