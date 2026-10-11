#+test
package agent

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "nabla:agent/journal"
import "nabla:search"

// tool_search_cursor_of reads the next_cursor value out of rendered result text.
tool_search_cursor_of :: proc(test: ^testing.T, content: string) -> string {
	marker := "next_cursor: "
	start := strings.index(content, marker)
	if !testing.expect(test, start >= 0, "the result carries a cursor for the next page") { return "" }
	rest := content[start + len(marker):]
	end := strings.index_byte(rest, '\n')
	if !testing.expect(test, end >= 0, "the cursor ends on its line") { return "" }
	return rest[:end]
}

tool_search_write :: proc(test: ^testing.T, tool_test: ^Tool_Test, name, content: string) {
	tool_search_write_in(test, tool_test_workspace(tool_test), name, content)
}

tool_search_write_in :: proc(test: ^testing.T, root, name, content: string) {
	path := strings.concatenate({root, "/", name}, context.temp_allocator)
	directory := path[:strings.last_index_byte(path, '/')]
	if make_error := os.make_directory_all(directory); make_error != nil && make_error != .Exist {
		testing.fail_now(test, "the test directory could not be created")
	}
	if !tool_write_file(test, path, content) { return }
}

// tool_search_touch_root moves the workspace directory's mtime to a fixed past
// instant, so the next query sees the root changed whatever the file system's
// timestamp granularity.
tool_search_touch_root :: proc(test: ^testing.T, tool_test: ^Tool_Test) {
	moved := time.unix(1_000_000_000, 0)
	if os.change_times(tool_test_workspace(tool_test), moved, moved) != nil {
		testing.fail_now(test, "the workspace mtime could not be changed")
	}
}

// Find matches root-relative paths, a lowercase word ignoring case, pages with
// opaque cursors, and never descends into .git or denylisted directories.
@(test)
test_find_lists_paths_pages_with_cursors_and_prunes :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "src/main.odin", "main :: proc() {}\n")
	tool_search_write(test, &tool_test, "src/util.odin", "util :: proc() {}\n")
	tool_search_write(test, &tool_test, "README.md", "notes\n")
	tool_search_write(test, &tool_test, ".git/qqzwt", "config\n")
	tool_search_write(test, &tool_test, "node_modules/qqxwj.js", "dep\n")

	result := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"readme"}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(result.content, "total_matches: 1"), "the lowercase word matches case-insensitively")
	testing.expect(
		test,
		strings.contains(result.content, "\n\n→ Read README.md (best match)\n1 of 1 paths\nREADME.md\n"),
		"the page opens with its header and counts, then the matching path",
	)

	paged := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":".odin","limit":1}`)
	testing.expect_value(test, paged.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(paged.content, "total_matches: 2"), "every match is counted")
	cursor := tool_search_cursor_of(test, paged.content)
	if cursor == "" { return }
	testing.expect(test, !strings.contains(cursor, tool_test_workspace(&tool_test)), "the cursor names no path")
	next_arguments := strings.concatenate({`{"query":".odin","limit":1,"cursor":"`, cursor, `"}`}, context.temp_allocator)
	rest := tool_run(test, &tool_test, TOOL_FIND_NAME, next_arguments)
	testing.expect_value(test, rest.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(rest.content, "total_matches: 2"), "the total survives paging")
	testing.expect(test, !strings.contains(rest.content, "next_cursor"), "the last page carries no cursor")

	// The pruned names share no bytes with the other paths, so a zero result
	// proves the prune rather than a miss: without it both would match exactly.
	hidden := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"qqxwj"}`)
	testing.expect_value(test, hidden.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(hidden.content, "total_matches: 0"), "denylisted directories are never searched")
	testing.expect(test, strings.contains(hidden.content, "denylist: 1 directory"), "the pruned directory is counted")

	untracked := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"qqzwt"}`)
	testing.expect_value(test, untracked.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(untracked.content, "total_matches: 0"), ".git is never searched")
}

// Find pages read like fff find: an exact query names its exact match, any
// other top row is a best match, and a partial page trailers its counts with
// the cursor that resumes it.
@(test)
test_find_best_match_header_trailer_and_cursor :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "exact_hit.txt", "hit\n")

	exact := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"exact_hit.txt"}`)
	testing.expect_value(test, exact.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(exact.content, "→ Read exact_hit.txt (exact match!)\n"), "an exact query names its exact match")

	best := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"exact"}`)
	testing.expect_value(test, best.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(best.content, "→ Read exact_hit.txt (best match)\n"), "any other top row is a best match")

	tool_search_write(test, &tool_test, "src/main.odin", "main :: proc() {}\n")
	tool_search_write(test, &tool_test, "src/util.odin", "util :: proc() {}\n")

	paged := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":".odin","limit":1}`)
	testing.expect_value(test, paged.outcome, journal.Tool_Outcome.Success)
	cursor := tool_search_cursor_of(test, paged.content)
	if cursor == "" { return }
	testing.expect(test, strings.contains(paged.content, "1 of 2 paths\n"), "the trailer counts the page")
	testing.expect(
		test,
		strings.contains(paged.content, strings.concatenate({"cursor: ", cursor, "\n"}, context.temp_allocator)),
		"the trailer carries the cursor that resumes the page",
	)

	next_arguments := strings.concatenate({`{"query":".odin","limit":1,"cursor":"`, cursor, `"}`}, context.temp_allocator)
	rest := tool_run(test, &tool_test, TOOL_FIND_NAME, next_arguments)
	testing.expect_value(test, rest.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(rest.content, "1 of 2 paths\nsrc/util.odin\n"), "the next page counts and lists its row")
	testing.expect(test, !strings.contains(rest.content, "cursor:"), "the last page trailers no cursor")
}

// Grep reports line rows with smart case and context lines, and counts
// skipped binary files without failing.
@(test)
test_grep_reports_rows_with_case_and_context :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "a.txt", "hello world\nFoo bar\nHELLO again\n")
	tool_search_write(test, &tool_test, "bin.dat", "ab\x00cd needle\n")

	result := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"hello"}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(result.content, "total_matches: 2"), "smart case folds the match")
	testing.expect(
		test,
		strings.contains(result.content, "\n\n→ Read a.txt (best match)\na.txt\n1: hello world\n3: HELLO again\n"),
		"one header names the file, then one line row per match",
	)
	testing.expect(test, !strings.contains(result.content, "notice:"), "an exact match carries no fallback label")

	with_context := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"Foo","context":1}`)
	testing.expect_value(test, with_context.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(with_context.content, "2: Foo bar"), "the hit row carries its line")
	testing.expect(test, strings.contains(with_context.content, " 1-hello world"), "a nearby line arrives as context without a column")
	testing.expect(test, strings.contains(with_context.content, " 3-HELLO again"), "the trailing context line arrives too")

	binary := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"needle"}`)
	testing.expect_value(test, binary.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(binary.content, "total_matches: 0"), "a binary file is never searched")
	testing.expect(test, strings.contains(binary.content, "skipped: 1 (binary: 1)"), "the skip is counted by reason")
}

// Zero exact matches runs the typo-tolerant fallback once and labels it; the
// label leads the body, so the rows that follow read as what it says.
@(test)
test_search_labels_its_fallback :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "src/main.odin", "package main\nprintf_line :: proc() {}\n")

	lines := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"pritnf"}`)
	testing.expect_value(test, lines.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(lines.content, "notice:"), "the head labels the fallback")
	testing.expect(test, strings.contains(lines.content, "approximate"), "the label says what the rows are")
	body := tool_result_body(lines.content)
	testing.expect(test, strings.index(body, "approximate") < strings.index(body, "→ Read"), "the label precedes the rows")

	paths := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"man.odi"}`)
	testing.expect_value(test, paths.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(paths.content, "notice:"), "the head labels the fallback")
	found := tool_result_body(paths.content)
	testing.expect(test, strings.has_prefix(found, "0 exact matches"), "the body opens with the label")
	testing.expect(test, strings.index(found, "→ Read") > 0, "the paths follow the label")
}

// A result with nothing to show states facts in its preview body, so the
// interface never shows a bare status word: find names its indexed count, grep
// its zero, and neither labels a true non-match.
@(test)
test_search_zero_summaries_state_facts :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "src/main.odin", "package main\n")

	missing := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"zzzqqqx"}`)
	testing.expect_value(test, missing.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(missing.content, "total_matches: 0"), "the head counts the miss")
	testing.expect(test, !strings.contains(missing.content, "notice:"), "a non-matching path query carries no fallback label")
	testing.expect_value(test, tool_result_body(missing.content), "0 results (1 indexed)\n")

	absent := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"zzzqqqx"}`)
	testing.expect_value(test, absent.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(absent.content, "total_matches: 0"), "the head counts the miss")
	testing.expect(test, !strings.contains(absent.content, "notice:"), "a non-match carries no fallback label")
	testing.expect_value(test, tool_result_body(absent.content), "0 matches\n")
}

// A malformed cursor is refused as its field, and an unknown field is refused
// rather than run.
@(test)
test_search_refuses_a_malformed_cursor :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "a.txt", "hello\n")

	malformed := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"hello","cursor":"next"}`)
	testing.expect_value(test, malformed.outcome, journal.Tool_Outcome.Invalid_Arguments)
	testing.expect(test, strings.contains(malformed.content, `field "cursor"`), "the refusal names the cursor field")

	unknown := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"a","offset":2}`)
	testing.expect_value(test, unknown.outcome, journal.Tool_Outcome.Invalid_Arguments)
	testing.expect(test, strings.contains(unknown.content, `field "offset"`), "an undeclared field is refused")
}

// A directory outside the workspace is searched with a one-shot index: every
// call scans it afresh, so a file added below its top level, which no cached
// index would notice, is found by the next call, and a cursor still resumes.
@(test)
test_search_external_root_is_scanned_afresh :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	external, directory_error := os.make_directory_temp("", "nabla-search-ext-*", context.allocator)
	if directory_error != nil { testing.fail_now(test, "could not create an external directory") }
	defer {
		os.remove_all(external)
		delete(external, context.allocator)
	}
	tool_search_write_in(test, external, "hello.txt", "needle here\n")
	tool_search_write_in(test, external, "deep/old.txt", "nothing\n")

	arguments := strings.concatenate({`{"pattern":"needle","root":"`, external, `"}`}, context.temp_allocator)
	first := tool_run(test, &tool_test, TOOL_GREP_NAME, arguments)
	testing.expect_value(test, first.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(first.content, "total_matches: 1"), "the external root is searched")
	testing.expect(
		test,
		strings.contains(first.content, "\n\n→ Read hello.txt (best match)\nhello.txt\n1: needle here\n"),
		"the group names the external file relative to its root",
	)

	tool_search_write_in(test, external, "deep/more.txt", "needle again\n")
	paged_arguments := strings.concatenate({`{"pattern":"needle","limit":1,"root":"`, external, `"}`}, context.temp_allocator)
	paged := tool_run(test, &tool_test, TOOL_GREP_NAME, paged_arguments)
	testing.expect_value(test, paged.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(paged.content, "total_matches: 2"), "the next call sees the file added below the top level")
	cursor := tool_search_cursor_of(test, paged.content)
	if cursor == "" { return }

	resume_arguments := strings.concatenate({`{"pattern":"needle","limit":1,"cursor":"`, cursor, `","root":"`, external, `"}`}, context.temp_allocator)
	resumed := tool_run(test, &tool_test, TOOL_GREP_NAME, resume_arguments)
	testing.expect_value(test, resumed.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(resumed.content, "total_matches: 2"), "a cursor resumes across one-shot calls")

	absent := strings.concatenate({`{"pattern":"needle","root":"`, external, `/gone"}`}, context.temp_allocator)
	refused := tool_run(test, &tool_test, TOOL_GREP_NAME, absent)
	testing.expect_value(test, refused.outcome, journal.Tool_Outcome.Invalid_Arguments)
	testing.expect(test, strings.contains(refused.content, `field "root"`), "a missing root is refused as its field")
}

// A cursor from before a rescan is stale: reusing it is refused as the cursor
// field, naming the expectation and the received value.
@(test)
test_search_stale_cursor_refused_after_rescan :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "a.txt", "hello\n")
	tool_search_write(test, &tool_test, "b.txt", "hello\n")

	paged := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"hello","limit":1}`)
	testing.expect_value(test, paged.outcome, journal.Tool_Outcome.Success)
	cursor := tool_search_cursor_of(test, paged.content)
	if cursor == "" { return }

	tool_search_touch_root(test, &tool_test)

	next_arguments := strings.concatenate({`{"pattern":"hello","limit":1,"cursor":"`, cursor, `"}`}, context.temp_allocator)
	stale := tool_run(test, &tool_test, TOOL_GREP_NAME, next_arguments)
	testing.expect_value(test, stale.outcome, journal.Tool_Outcome.Invalid_Arguments)
	testing.expect(test, strings.contains(stale.content, `field "cursor"`), "the refusal names the cursor field")
	testing.expect(test, strings.contains(stale.content, "generation"), "the refusal names the expectation")
	testing.expect(test, strings.contains(stale.content, cursor), "the refusal names the received value")
}

// A new top-level file appears without a manual rescan: the next query
// rescans on the moved root mtime.
@(test)
test_search_refresh_notices_new_top_level_files :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "a.txt", "hello\n")

	first := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"a.txt"}`)
	testing.expect_value(test, first.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(first.content, "total_matches: 1"), "the first query searches the workspace")

	tool_search_write(test, &tool_test, "new_top.txt", "hello\n")
	tool_search_touch_root(test, &tool_test)
	second := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"new_top"}`)
	testing.expect_value(test, second.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(second.content, "total_matches: 1"), "the new top-level file is found")
}

// The find `pattern` alias reads as `query` when the query is blank, is
// reported as a repair when it is used or ignored, and a blank query is
// refused.
@(test)
test_find_pattern_alias_is_reported :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "src/main.odin", "main :: proc() {}\n")
	tool_search_write(test, &tool_test, "src/util.odin", "util :: proc() {}\n")

	used := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"pattern":"main"}`)
	testing.expect_value(test, used.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(used.content, "total_matches: 1"), "the alias matches like the query")
	testing.expect(test, strings.contains(used.content, "repaired:"), "the alias use is reported")
	testing.expect(test, strings.contains(used.content, "field_alias"), "the repair names the alias")

	ignored := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"main","pattern":"util"}`)
	testing.expect_value(test, ignored.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(ignored.content, "src/main.odin"), "the query wins")
	testing.expect(test, !strings.contains(ignored.content, "src/util.odin"), "the ignored alias is not searched")
	testing.expect(test, strings.contains(ignored.content, "field_alias"), "the ignored alias is reported too")

	plain := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"main"}`)
	testing.expect_value(test, plain.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, !strings.contains(plain.content, "repaired:"), "the canonical field is not a repair")

	blank := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"  "}`)
	testing.expect_value(test, blank.outcome, journal.Tool_Outcome.Invalid_Arguments)
	testing.expect(test, strings.contains(blank.content, `field "query"`), "a blank query is refused as its field")
}

// Only the empty grep pattern is refused: whitespace is text to look for, and
// a whitespace pattern with no hit still finishes.
@(test)
test_grep_whitespace_pattern_is_text :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "a.txt", "x  y\nplain\n")

	spaces := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"  "}`)
	testing.expect_value(test, spaces.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(spaces.content, "total_matches: 1"), "the whitespace is matched literally")
	testing.expect(test, strings.contains(spaces.content, "1: x  y"), "the row carries the line")

	absent := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"     "}`)
	testing.expect_value(test, absent.outcome, journal.Tool_Outcome.Success)

	empty := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":""}`)
	testing.expect_value(test, empty.outcome, journal.Tool_Outcome.Invalid_Arguments)
	testing.expect(test, strings.contains(empty.content, `field "pattern"`), "the empty pattern is refused as its field")
}

// A glob the matcher cannot read, including a malformed tail that parsing a
// short name never reaches, is refused as its field; a valid glob filters.
@(test)
test_search_glob_validation :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "src/a.odin", "needle\n")
	tool_search_write(test, &tool_test, "notes/a.txt", "needle\n")

	for glob in ([]string{"[a", "src/[", "a["}) {
		find_arguments := strings.concatenate({`{"query":"a","glob":"`, glob, `"}`}, context.temp_allocator)
		found := tool_run(test, &tool_test, TOOL_FIND_NAME, find_arguments)
		testing.expectf(test, found.outcome == .Invalid_Arguments, "find accepted the glob %q", glob)
		testing.expectf(test, strings.contains(found.content, `field "glob"`), "find did not name the glob field for %q", glob)

		grep_arguments := strings.concatenate({`{"pattern":"needle","glob":"`, glob, `"}`}, context.temp_allocator)
		grepped := tool_run(test, &tool_test, TOOL_GREP_NAME, grep_arguments)
		testing.expectf(test, grepped.outcome == .Invalid_Arguments, "grep accepted the glob %q", glob)
		testing.expectf(test, strings.contains(grepped.content, `field "glob"`), "grep did not name the glob field for %q", glob)
	}

	filtered := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"a","glob":"*.odin"}`)
	testing.expect_value(test, filtered.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(filtered.content, "total_matches: 1"), "a valid glob keeps only its paths")
	testing.expect(test, strings.contains(filtered.content, "src/a.odin"), "the kept path is listed")
}

// Zero or a negative limit returns every match.
@(test)
test_find_nonpositive_limit_returns_every_match :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "src/main.odin", "main :: proc() {}\n")
	tool_search_write(test, &tool_test, "src/util.odin", "util :: proc() {}\n")

	for limit in ([]string{"0", "-1"}) {
		arguments := strings.concatenate({`{"query":".odin","limit":`, limit, `}`}, context.temp_allocator)
		result := tool_run(test, &tool_test, TOOL_FIND_NAME, arguments)
		testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
		testing.expectf(test, strings.contains(result.content, "2 of 2 paths\nsrc/main.odin\nsrc/util.odin\n"), "limit %s lists every match", limit)
		testing.expectf(test, !strings.contains(result.content, "next_cursor"), "limit %s leaves no cursor", limit)
	}
}

// Regex mode matches patterns as regular expressions, and an invalid
// expression falls back to a literal search with a notice naming the pattern.
@(test)
test_grep_regex_mode_with_literal_fallback :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "a.txt", "hello world\n[value] here\n")

	expression := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"h.llo","mode":"regex"}`)
	testing.expect_value(test, expression.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(expression.content, "total_matches: 1"), "the expression matches")
	testing.expect(test, strings.contains(expression.content, "1: hello world"), "the row carries its line")
	testing.expect(test, !strings.contains(expression.content, "notice:"), "a valid expression carries no repair label")

	literal := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"h.llo"}`)
	testing.expect_value(test, literal.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(literal.content, "total_matches: 1"), "plain mode finds the fuzzy fallback")
	testing.expect(test, strings.contains(literal.content, "approximate"), "plain mode reads the pattern literally, so the rows are approximate")

	invalid := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"[value","mode":"regex"}`)
	testing.expect_value(test, invalid.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(invalid.content, "total_matches: 1"), "the invalid expression searches literally")
	testing.expect(test, strings.contains(invalid.content, "2: [value] here"), "the literal match is reported")
	testing.expect(test, strings.contains(invalid.content, "notice:"), "the fallback is labeled")
	testing.expect(test, strings.contains(invalid.content, "not a valid regular expression"), "the notice names the error")
	testing.expect(test, strings.has_prefix(tool_result_body(invalid.content), "pattern"), "the label leads the body")

	unknown := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"hello","mode":"fuzzy"}`)
	testing.expect_value(test, unknown.outcome, journal.Tool_Outcome.Invalid_Arguments)
	testing.expect(test, strings.contains(unknown.content, `field "mode"`), "an unknown mode is refused as its field")
}

// Case folds smart by default; "sensitive" keeps case and "insensitive" folds
// it. An exact match carries no notice, so a labeled fallback proves the
// pattern did not fold.
@(test)
test_grep_case_modes :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "a.txt", "Hello World\n")

	smart := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"hello"}`)
	testing.expect_value(test, smart.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(smart.content, "total_matches: 1"), "a lowercase pattern folds by default")
	testing.expect(test, !strings.contains(smart.content, "notice:"), "an exact match carries no fallback label")

	exact := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"Hello","case":"sensitive"}`)
	testing.expect_value(test, exact.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(exact.content, "total_matches: 1"), "the sensitive pattern matches its case")
	testing.expect(test, !strings.contains(exact.content, "notice:"), "an exact match carries no fallback label")

	folded := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"HELLO","case":"insensitive"}`)
	testing.expect_value(test, folded.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(folded.content, "total_matches: 1"), "the insensitive pattern folds case")
	testing.expect(test, !strings.contains(folded.content, "notice:"), "an exact match carries no fallback label")

	literal := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"hello","case":"sensitive"}`)
	testing.expect_value(test, literal.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(literal.content, "notice:"), "a sensitive miss falls back instead of folding")

	unknown := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"hello","case":"folding"}`)
	testing.expect_value(test, unknown.outcome, journal.Tool_Outcome.Invalid_Arguments)
	testing.expect(test, strings.contains(unknown.content, `field "case"`), "an unknown case is refused as its field")
}

// Files_with_matches lists one path per file with a hit instead of per-line
// rows.
@(test)
test_grep_files_with_matches_lists_paths :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "a.txt", "needle once\nneedle twice\n")
	tool_search_write(test, &tool_test, "b.txt", "a needle here\n")
	tool_search_write(test, &tool_test, "c.txt", "nothing here\n")

	result := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"needle","output_mode":"files_with_matches"}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(result.content, "total_matches: 2"), "one match per file is counted")
	testing.expect(test, strings.contains(result.content, "\n\na.txt\nb.txt\n"), "one path per file is listed")
	testing.expect(test, !strings.contains(result.content, "c.txt"), "a file without a hit is absent")

	unknown := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"needle","output_mode":"files"}`)
	testing.expect_value(test, unknown.outcome, journal.Tool_Outcome.Invalid_Arguments)
	testing.expect(test, strings.contains(unknown.content, `field "output_mode"`), "an unknown output mode is refused as its field")
}

// The default scope descends into nested repositories: files under a nested
// directory match, while .git contents stay pruned, so a default zero is
// trustworthy. A relative root searches below the workspace, with paths
// relative to it.
@(test)
test_search_default_scope_descends_into_nested_repos :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "app.py", "NESTED_SCOPE_MARKER\n")
	tool_search_write(test, &tool_test, "repos/flask/app.py", "NESTED_SCOPE_MARKER\n")
	tool_search_write(test, &tool_test, "repos/flask/.git/config", "NESTED_SCOPE_MARKER\n")

	paths := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"app.py"}`)
	testing.expect_value(test, paths.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(paths.content, "total_matches: 2"), "the nested repository file is listed")
	testing.expect(test, strings.contains(paths.content, "repos/flask/app.py"), "the nested path is shown")

	content := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"NESTED_SCOPE_MARKER"}`)
	testing.expect_value(test, content.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(content.content, "total_matches: 2"), "the nested repository is searched")
	testing.expect(test, strings.contains(content.content, "→ Read app.py (best match)"), "the header names the top file")
	testing.expect(test, strings.contains(content.content, "repos/flask/app.py\n1: NESTED_SCOPE_MARKER"), "the nested group is shown")
	testing.expect(test, strings.contains(content.content, "--\nrepos/flask/app.py"), "the groups are separated")
	testing.expect(test, !strings.contains(content.content, ".git"), "the nested .git directory is never searched")

	below := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"app.py","root":"repos"}`)
	testing.expect_value(test, below.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(below.content, "total_matches: 1"), "a relative root narrows the search")
	testing.expect(test, strings.contains(below.content, "flask/app.py"), "paths are relative to the root")
	testing.expect(test, !strings.contains(below.content, "repos/flask"), "the root prefix is not repeated")
}

// Grep groups matches by file under one header naming the top file, with a
// separator between groups.
@(test)
test_grep_groups_matches_by_file_with_header :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "b.txt", "needle twice\nnothing\nneedle again\n")
	tool_search_write(test, &tool_test, "a.txt", "a needle here\n")
	tool_search_write(test, &tool_test, "c.txt", "nothing here\n")

	result := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"needle"}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(result.content, "total_matches: 3"), "every match is counted")
	testing.expect(
		test,
		strings.contains(result.content, "\n\n→ Read a.txt (best match)\na.txt\n1: a needle here\n--\nb.txt\n1: needle twice\n3: needle again\n"),
		"the header names the top file and each group lists its line rows",
	)
	testing.expect(test, !strings.contains(result.content, "c.txt"), "a file without a hit has no group")
}

// Context lines render beside their hit with a dash, and file groups stay
// separated while context is on.
@(test)
test_grep_context_rows_grouped_with_separators :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "a.txt", "before one\nneedle one\nafter one\n")
	tool_search_write(test, &tool_test, "b.txt", "before two\nneedle two\nafter two\n")

	result := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"needle","context":1}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(
		test,
		strings.contains(result.content, "a.txt\n 1-before one\n2: needle one\n 3-after one\n--\nb.txt\n 1-before two\n2: needle two\n 3-after two\n"),
		"each group shows its hit with dashed context rows around it",
	)
}

// An overlong match line is windowed around the hit, and its full line is
// kept in the file the result names.
@(test)
test_grep_windows_long_lines_and_spills_full_text :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	pad := strings.repeat("x", 400, context.temp_allocator)
	line := strings.concatenate({pad, "needle", pad}, context.temp_allocator)
	tool_search_write(test, &tool_test, "long.txt", strings.concatenate({line, "\nshort needle line\n"}, context.temp_allocator))

	result := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"needle"}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(result.content, "total_matches: 2"), "both lines match")
	testing.expect(test, strings.contains(result.content, "…"), "the overlong line is cut")
	testing.expect(test, strings.contains(result.content, "needle"), "the window keeps the hit")
	testing.expect(test, !strings.contains(result.content, line), "the full line is not in the preview")

	marker := "full_lines_in: "
	start := strings.index(result.content, marker)
	if !testing.expect(test, start >= 0, "the preview names the kept file") { return }
	rest := result.content[start + len(marker):]
	end := strings.index_byte(rest, '\n')
	if !testing.expect(test, end >= 0, "the file name ends on its line") { return }
	kept, read_error := os.read_entire_file(rest[:end], context.temp_allocator)
	if !testing.expect(test, read_error == nil, "the kept file is readable") { return }
	testing.expect(test, strings.contains(string(kept), line), "the kept file holds the full line")
}

// The trailer breaks skipped files into named reasons and counts pruned
// denylist directories beside the total.
@(test)
test_grep_skip_breakdown_names_reasons :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "a.txt", "needle here\n")
	tool_search_write(test, &tool_test, "bin.dat", "ab\x00cd needle\n")
	tool_search_write(test, &tool_test, "node_modules/dep.js", "needle here\n")
	big := make([]byte, search.GREP_MAX_FILE_SIZE + 1024, context.allocator)
	defer delete(big, context.allocator)
	for &byte in big {
		byte = 'x'
	}
	marker := "needle here\n"
	for i in 0 ..< len(marker) {
		big[i] = marker[i]
	}
	tool_search_write(test, &tool_test, "big.dat", string(big))

	result := tool_run(test, &tool_test, TOOL_GREP_NAME, `{"pattern":"needle"}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(result.content, "total_matches: 1"), "only the searchable file matches")
	testing.expect(test, strings.contains(result.content, "skipped: 2 (binary: 1, oversize: 1)"), "skipped files are broken down by reason")
	testing.expect(test, strings.contains(result.content, "denylist: 1 directory"), "the pruned directory is counted beside the total")
}

// tool_search_make_log_directory returns a fresh temporary directory for
// frecency logs. The caller removes it.
tool_search_make_log_directory :: proc(test: ^testing.T) -> string {
	directory, directory_error := os.make_directory_temp("", "nabla-frecency-test-*", context.allocator)
	if directory_error != nil { testing.fail_now(test, "could not create a temporary log directory") }
	return directory
}

// Two siblings match a query equally, so the path order decides until the agent
// reads one: then find ranks the file the agent touched first.
@(test)
test_find_ranks_a_read_file_above_its_sibling :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	tool_search_write(test, &tool_test, "match_a.txt", "a\n")
	tool_search_write(test, &tool_test, "match_b.txt", "b\n")

	before := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"match"}`)
	testing.expect(test, strings.contains(before.content, "→ Read match_a.txt"), "without an access the path order decides")

	read := tool_run(test, &tool_test, TOOL_READ_NAME, `{"path":"match_b.txt"}`)
	testing.expect_value(test, read.outcome, journal.Tool_Outcome.Success)
	after := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"match"}`)
	testing.expect(test, strings.contains(after.content, "→ Read match_b.txt"), "the file the agent read ranks first")
}

// The accesses of a session are replayed from the workspace's log when the
// next session opens it.
@(test)
test_frecency_survives_a_session_reopen :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat

	log_directory := tool_search_make_log_directory(test)
	defer {
		os.remove_all(log_directory)
		delete(log_directory, context.allocator)
	}
	now := time.to_unix_seconds(time.now())

	tool_search_write(test, &tool_test, "match_a.txt", "a\n")
	tool_search_write(test, &tool_test, "match_b.txt", "b\n")

	if !testing.expect_value(test, search_cache_frecency_open(chat.search_cache, log_directory, now), nil) { return }
	read := tool_run(test, &tool_test, TOOL_READ_NAME, `{"path":"match_b.txt"}`)
	testing.expect_value(test, read.outcome, journal.Tool_Outcome.Success)

	search_cache_destroy(chat.search_cache)
	reopened, make_error := search_cache_make(tool_test_workspace(&tool_test), os.heap_allocator())
	if !testing.expect_value(test, make_error, nil) {
		chat.search_cache = nil
		return
	}
	chat.search_cache = reopened
	testing.expect_value(test, search_cache_frecency_open(reopened, log_directory, now), nil)

	found := tool_run(test, &tool_test, TOOL_FIND_NAME, `{"query":"match"}`)
	testing.expect(test, strings.contains(found.content, "→ Read match_b.txt"), "the earlier session's read still ranks the file first")
}
