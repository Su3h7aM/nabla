package search

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

import "nabla:fuzzy"

// Find_Query is one find call. query is split on whitespace into parts. A
// file is an exact row when every part occurs in its root-relative path as a
// substring, where a part holding an uppercase letter matches case-sensitively
// and any other part ignores case. Only when no file is an exact row does the
// query fall back to typo-tolerant fuzzy rows, where every part must
// fuzzy-match the path. An empty query matches every file. glob keeps only
// paths it matches, tried against the path then the base name; exclude drops
// paths it matches the same way. cursor resumes a previous result's
// next_cursor, or "" for the first page. limit bounds the page, where zero or
// below means every match. frecency, when not nil, reranks rows by the access
// history of their absolute paths and the age of their modification time as of
// now, in unix seconds. All strings and the frecency borrow the caller.
Find_Query :: struct {
	query:    string,
	glob:     string,
	exclude:  string,
	cursor:   string,
	limit:    int,
	frecency: ^Frecency,
	now:      i64,
}

// Find_Result is one find result. files holds one root-relative path per row
// in page order, best first. total counts every match, not just the page.
// next_cursor resumes after the page, or "" when no rows remain. notice labels
// the typo-tolerant fallback the rows are, or "" for exact matches and for a
// true non-match. Everything is owned by the query's allocator.
Find_Result :: struct {
	files:       []string,
	total:       int,
	skipped:     Skip_Breakdown,
	next_cursor: string,
	notice:      string,
}

// find_result_destroy releases a find result allocated with allocator.
find_result_destroy :: proc(result: ^Find_Result, allocator: mem.Allocator) {
	if result == nil {
		return
	}
	for path in result.files {
		delete(path, allocator)
	}
	delete(result.files, allocator)
	if result.next_cursor != "" {
		delete(result.next_cursor, allocator)
	}
	if result.notice != "" {
		delete(result.notice, allocator)
	}
	result^ = Find_Result{}
}

// Find_Hit is one kept row: the file's position in the index and its total
// score.
@(private)
Find_Hit :: struct {
	index: int,
	total: f64,
}

// find runs one find call over the index. Files passing the glob that hold
// every query part as a substring of the root-relative path are the rows. When
// there are none, the files that fuzzy-match every part are the rows and the
// result carries a notice. Rows are ranked by total score descending, then
// shorter path, then path ascending, where a file's score is the average of
// its parts' fuzzy scores, plus the frecency bonus when the query carries
// one: score + score * (access_score + modification_score) / 100. The index is
// borrowed and never walked; the caller owns the result, allocated with
// allocator, and releases it with find_result_destroy. A malformed glob is
// Invalid_Glob, a malformed or foreign cursor Invalid_Cursor, and a cursor
// from before the latest update Stale_Cursor.
@(require_results)
find :: proc(index: ^Index, query: Find_Query, allocator := context.allocator) -> (result: Find_Result, err: Error) {
	if !glob_valid(query.glob) || !glob_valid(query.exclude) {
		return {}, Error(Error_Code.Invalid_Glob)
	}
	offset := cursor_parse(query.cursor, index.root, index.generation, allocator) or_return

	parts := strings.fields(query.query, allocator) or_return
	defer delete(parts, allocator)
	patterns := make([dynamic]fuzzy.Pattern, 0, len(parts), allocator) or_return
	defer {
		for &pattern in patterns {
			fuzzy.pattern_destroy(&pattern, allocator)
		}
		delete(patterns)
	}
	for part in parts {
		pattern := fuzzy.pattern_compile(part, allocator = allocator) or_return
		append(&patterns, pattern)
	}

	hits := make([dynamic]Find_Hit, allocator)
	defer delete(hits)
	find_collect(&hits, index, query, parts, patterns[:], exact = true) or_return
	exact_found := len(hits) > 0
	if !exact_found {
		find_collect(&hits, index, query, parts, patterns[:], exact = false) or_return
	}
	slice.sort_by_with_data(hits[:], find_hit_less, raw_data(index.files))

	start, end, has_more := page_split(len(hits), offset, query.limit)
	files := make([]string, end - start, allocator) or_return
	defer if err != nil {
		for path in files {
			delete(path, allocator)
		}
		delete(files, allocator)
	}
	for hit, i in hits[start:end] {
		files[i] = strings.clone(index.files[hit.index].rel, allocator) or_return
	}
	next_cursor := ""
	if has_more {
		next_cursor = cursor_make(end, index.generation, index.root, allocator) or_return
	}
	defer if err != nil && next_cursor != "" {
		delete(next_cursor, allocator)
	}
	notice := ""
	if !exact_found && len(hits) > 0 {
		notice = fmt.aprintf(
			"0 exact matches for %q; showing %d approximate path matches, typo-tolerant, best first",
			query.query,
			len(hits),
			allocator = allocator,
		)
		if notice == "" {
			return {}, Error(mem.Allocator_Error.Out_Of_Memory)
		}
	}
	return Find_Result{files = files, total = len(hits), skipped = index.skipped, next_cursor = next_cursor, notice = notice}, nil
}

// find_collect appends a hit for every file passing the glob that is an exact
// row, or with exact false a fuzzy row, scored and reranked as find describes.
@(private, require_results)
find_collect :: proc(
	hits: ^[dynamic]Find_Hit,
	index: ^Index,
	query: Find_Query,
	parts: []string,
	patterns: []fuzzy.Pattern,
	exact: bool,
) -> mem.Allocator_Error {
	for file, i in index.files {
		if !glob_keep(query.glob, file.rel) || (query.exclude != "" && glob_keep(query.exclude, file.rel)) {
			continue
		}
		if exact && !find_contains_all(parts, file.rel) {
			continue
		}
		score, kept := find_score(patterns, file.rel, require_kept = !exact)
		if !kept {
			continue
		}
		total := score
		if query.frecency != nil {
			boost := frecency_access_score(query.frecency, file.full, query.now) + modification_score(file.mtime, query.now)
			total += score * boost / 100
		}
		append(hits, Find_Hit{index = i, total = total}) or_return
	}
	return nil
}

// find_contains_all reports whether every part occurs in path, matching
// case-sensitively when the part holds an uppercase letter.
@(private, require_results)
find_contains_all :: proc(parts: []string, path: string) -> bool {
	for part in parts {
		found := strings.index(path, part) if has_upper(part) else fold_index(path, part)
		if found < 0 {
			return false
		}
	}
	return true
}

// find_score averages the fuzzy scores of every pattern against path, where a
// pattern that places nothing scores 0. With require_kept, a pattern that
// fails match_kept makes kept false. No patterns keep every path with score 0.
@(private, require_results)
find_score :: proc(patterns: []fuzzy.Pattern, path: string, require_kept: bool) -> (score: f64, kept: bool) {
	sum := 0
	for &pattern in patterns {
		match := fuzzy.pattern_match(&pattern, path)
		if require_kept && !fuzzy.match_kept(match) {
			return 0, false
		}
		sum += match.score
	}
	if len(patterns) == 0 {
		return 0, true
	}
	return f64(sum) / f64(len(patterns)), true
}

// find_hit_less ranks higher totals first, then shorter paths, then paths in
// ascending order. files is the index's file list.
@(private, require_results)
find_hit_less :: proc(first, second: Find_Hit, files: rawptr) -> bool {
	if first.total != second.total {
		return first.total > second.total
	}
	first_path := ([^]File)(files)[first.index].rel
	second_path := ([^]File)(files)[second.index].rel
	if len(first_path) != len(second_path) {
		return len(first_path) < len(second_path)
	}
	return first_path < second_path
}
