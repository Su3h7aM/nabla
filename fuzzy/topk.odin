package fuzzy

import "core:mem"
import "core:slice"

// Match_Hit is one retained candidate: its index in the caller's list, its
// raw score, and its byte length. The length breaks score ties toward the
// compact candidate, because a local alignment leaves bytes outside its
// window unscored and so ties a candidate with one it only extends.
Match_Hit :: struct {
	index:  int,
	score:  int,
	length: int,
}

// Top_K keeps the best K hits seen so far in a min-heap, so a candidate stream
// of any length retains at most K hits. entries is the owned backing; the
// first count slots form the heap.
Top_K :: struct {
	entries: []Match_Hit,
	count:   int,
}

// top_k_make allocates a Top_K retaining up to k hits with allocator. A k at
// or below zero retains nothing and every offer is ignored. The caller owns
// the result and releases it with top_k_destroy.
@(require_results)
top_k_make :: proc(k: int, allocator := context.allocator) -> (top: Top_K, err: mem.Allocator_Error) {
	top.entries = make([]Match_Hit, max(k, 0), allocator) or_return
	return top, nil
}

// top_k_destroy releases the backing with allocator, which must be the
// allocator that made it, and leaves the Top_K zeroed.
top_k_destroy :: proc(top: ^Top_K, allocator := context.allocator) {
	delete(top.entries, allocator)
	top^ = {}
}

// top_k_offer scores candidate and retains it when match_kept and among the
// best K so far; index is the candidate's position in the caller's list. It
// allocates nothing. A full heap admits only a strictly better candidate than
// its worst, so ties keep the earlier index and the result is deterministic.
top_k_offer :: proc(top: ^Top_K, pattern: ^Pattern, index: int, candidate: string) {
	if len(top.entries) == 0 {
		return
	}
	match := pattern_match(pattern, candidate)
	if !match_kept(match) {
		return
	}
	hit := Match_Hit {
		index  = index,
		score  = match.score,
		length = len(candidate),
	}
	if top.count < len(top.entries) {
		top.entries[top.count] = hit
		top.count += 1
		sift_up(top.entries[:top.count], top.count - 1)
	} else if hit_worse(top.entries[0], hit) {
		top.entries[0] = hit
		sift_down(top.entries[:top.count], 0)
	}
}

// top_k_clear empties the retention without releasing the backing, so one
// Top_K serves the next query's stream.
top_k_clear :: proc(top: ^Top_K) {
	top.count = 0
}

// top_k_sorted orders the retained hits in place, best first, and returns
// them as a live slice. Offer again only after top_k_clear: the sorted order
// is not the heap the next offer sifts through.
top_k_sorted :: proc(top: ^Top_K) -> []Match_Hit {
	slice.sort_by(top.entries[:top.count], hit_better)
	return top.entries[:top.count]
}

// match_list scores every candidate and returns the best limit kept hits,
// best first. A limit at or below zero returns none. The caller owns the
// result and releases it with delete and allocator.
@(require_results)
match_list :: proc(pattern: ^Pattern, candidates: []string, limit: int, allocator := context.allocator) -> (hits: []Match_Hit, err: mem.Allocator_Error) {
	top := top_k_make(min(limit, len(candidates)), allocator) or_return
	defer top_k_destroy(&top, allocator)
	for candidate, index in candidates {
		top_k_offer(&top, pattern, index, candidate)
	}
	return slice.clone(top_k_sorted(&top), allocator)
}

// hit_better orders hits best first: higher score, then shorter candidate,
// then earlier index.
@(private, require_results)
hit_better :: proc(first, second: Match_Hit) -> bool {
	if first.score != second.score {
		return first.score > second.score
	}
	if first.length != second.length {
		return first.length < second.length
	}
	return first.index < second.index
}

// hit_worse is hit_better reversed, which puts the worst hit at the heap root.
@(private, require_results)
hit_worse :: proc(first, second: Match_Hit) -> bool {
	return hit_better(second, first)
}

// sift_up restores the heap above at after inserting there.
@(private)
sift_up :: proc(heap: []Match_Hit, at: int) {
	child := at
	for child > 0 {
		parent := (child - 1) / 2
		if !hit_worse(heap[child], heap[parent]) {
			break
		}
		heap[child], heap[parent] = heap[parent], heap[child]
		child = parent
	}
}

// sift_down restores the heap below at after replacing the root.
@(private)
sift_down :: proc(heap: []Match_Hit, at: int) {
	parent := at
	for {
		left := 2 * parent + 1
		if left >= len(heap) {
			break
		}
		worst := left
		if right := left + 1; right < len(heap) && hit_worse(heap[right], heap[left]) {
			worst = right
		}
		if !hit_worse(heap[worst], heap[parent]) {
			break
		}
		heap[parent], heap[worst] = heap[worst], heap[parent]
		parent = worst
	}
}
