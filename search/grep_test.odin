#+test
package search

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Exact search reports path, line, and byte column with smart case, and
// counts a binary file as skipped without failing.
@(test)
test_grep_reports_rows_with_smart_case_and_skips_binary :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a.txt", "hello world\nFoo bar\nHELLO again\n")
	test_write(test, dir, "bin.dat", "ab\x00cd needle\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	found, found_error := grep(&index, Grep_Query{pattern = "hello"})
	if !testing.expect(test, found_error == nil, "the query runs") { return }
	defer grep_result_destroy(&found, context.allocator)
	testing.expect_value(test, found.total, 2)
	testing.expect_value(test, found.notice, "")
	if testing.expect_value(test, len(found.matches), 2) {
		testing.expect_value(test, found.matches[0], Grep_Match{path = "a.txt", line = 1, col = 1, text = "hello world"})
		testing.expect_value(test, found.matches[1].line, 3)
	}

	sensitive, sensitive_error := grep(&index, Grep_Query{pattern = "FOO"})
	if !testing.expect(test, sensitive_error == nil, "the uppercase query runs") { return }
	defer grep_result_destroy(&sensitive, context.allocator)
	testing.expect_value(test, sensitive.total, 0)
	testing.expect_value(test, sensitive.notice, "")

	binary, binary_error := grep(&index, Grep_Query{pattern = "needle"})
	if !testing.expect(test, binary_error == nil, "the binary query runs") { return }
	defer grep_result_destroy(&binary, context.allocator)
	testing.expect_value(test, binary.total, 0)
	testing.expect_value(test, binary.skipped.binary, 1)
}

// Skip counts cover only the files the glob keeps.
@(test)
test_grep_skip_counts_respect_the_glob :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a.txt", "needle\n")
	test_write(test, dir, "one.dat", "ab\x00needle\n")
	test_write(test, dir, "sub/two.dat", "cd\x00needle\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	wanted := []struct {
		glob:   string,
		binary: int,
	}{{"", 2}, {"*.dat", 2}, {"*.txt", 0}, {"sub/*", 1}}
	for entry in wanted {
		found, found_error := grep(&index, Grep_Query{pattern = "needle", glob = entry.glob})
		if !testing.expect(test, found_error == nil, "the globbed query runs") { continue }
		testing.expectf(test, found.skipped.binary == entry.binary, "glob %q counts %d binary skips, got %d", entry.glob, entry.binary, found.skipped.binary)
		grep_result_destroy(&found, context.allocator)
	}
}

// Plain mode runs the labeled recovery only on zero exact hits: a typo
// recovers approximate rows with a notice, a multi-word pattern broadens, and
// a true non-match stays empty with no notice.
@(test)
test_grep_recovers_zero_hits_with_a_notice :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a.txt", "hello world\n")
	test_write(test, dir, "b.txt", "package main\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	typo, typo_error := grep(&index, Grep_Query{pattern = "hellp"})
	if !testing.expect(test, typo_error == nil, "the typo query runs") { return }
	defer grep_result_destroy(&typo, context.allocator)
	if testing.expect(test, len(typo.matches) > 0, "the typo recovers a row") {
		testing.expect_value(test, typo.matches[0].text, "hello world")
	}
	testing.expect(test, strings.contains(typo.notice, "approximate"), "the typo recovery is labeled")

	broadened, broadened_error := grep(&index, Grep_Query{pattern = "zzz hello"})
	if !testing.expect(test, broadened_error == nil, "the multi-word query runs") { return }
	defer grep_result_destroy(&broadened, context.allocator)
	testing.expect_value(test, broadened.total, 1)
	testing.expect(test, strings.contains(broadened.notice, "broadened"), "the broadening is labeled")

	absent, absent_error := grep(&index, Grep_Query{pattern = "zzzqqqx"})
	if !testing.expect(test, absent_error == nil, "the non-match runs") { return }
	defer grep_result_destroy(&absent, context.allocator)
	testing.expect_value(test, absent.total, 0)
	testing.expect_value(test, absent.notice, "")
}

// An invalid expression searches literally and says so; a valid expression
// with no hit never runs the typo recovery.
@(test)
test_grep_regex_invalid_falls_back_to_literal :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a.txt", "call f([x]) here\nhello world\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	broken, broken_error := grep(&index, Grep_Query{pattern = "([", mode = .Regex})
	if !testing.expect(test, broken_error == nil, "the broken expression still runs") { return }
	defer grep_result_destroy(&broken, context.allocator)
	testing.expect_value(test, broken.total, 1)
	testing.expect(test, strings.contains(broken.notice, "regular expression"), "the literal repair is labeled")

	missed, missed_error := grep(&index, Grep_Query{pattern = "hellp+", mode = .Regex})
	if !testing.expect(test, missed_error == nil, "the valid expression runs") { return }
	defer grep_result_destroy(&missed, context.allocator)
	testing.expect_value(test, missed.total, 0)
	testing.expect_value(test, missed.notice, "")
}

// Files mode lists one path per file with a hit, in path order.
@(test)
test_grep_files_mode_lists_matching_files :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a.txt", "hello world\nhello again\n")
	test_write(test, dir, "b.txt", "goodbye\n")
	test_write(test, dir, "sub/c.txt", "hello again\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	listed, listed_error := grep(&index, Grep_Query{pattern = "hello", output = .Files_With_Matches})
	if !testing.expect(test, listed_error == nil, "the files query runs") { return }
	defer grep_result_destroy(&listed, context.allocator)
	testing.expect_value(test, listed.total, 2)
	testing.expect_value(test, len(listed.matches), 0)
	if testing.expect_value(test, len(listed.files), 2) {
		testing.expect_value(test, listed.files[0], "a.txt")
		testing.expect_value(test, listed.files[1], "sub/c.txt")
	}
}

// Context lines surround each hit without a column, and overlapping context
// is one row.
@(test)
test_grep_context_lines_surround_hits_once :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a.txt", "one\ntwo\nneedle\nfour\nfive\nneedle\nseven\neight\nnine\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	found, found_error := grep(&index, Grep_Query{pattern = "needle", context_lines = 1})
	if !testing.expect(test, found_error == nil, "the context query runs") { return }
	defer grep_result_destroy(&found, context.allocator)
	testing.expect_value(test, found.total, 6)
	lines := []int{2, 3, 4, 5, 6, 7}
	if testing.expect_value(test, len(found.matches), len(lines)) {
		for row, i in found.matches {
			testing.expect_value(test, row.line, lines[i])
			testing.expect_value(test, row.is_context, row.line != 3 && row.line != 6)
			testing.expect_value(test, row.col != 0, row.line == 3 || row.line == 6)
		}
		testing.expect_value(test, found.matches[0].text, "two")
	}
}

// Paging in global row order covers every row exactly once across files,
// including pages that start or end inside a file's context.
@(test)
test_grep_paging_covers_every_row_once :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a.txt", "needle 1\nx\nneedle 2\nneedle 3\n")
	test_write(test, dir, "b.txt", "none here\n")
	test_write(test, dir, "c.txt", "y\nneedle 4\nz\n")
	test_write(test, dir, "d/e.txt", "needle 5\nneedle 6\nneedle 7\nw\nv\nneedle 8\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	for context_lines in 0 ..= 1 {
		whole, whole_error := grep(&index, Grep_Query{pattern = "needle", context_lines = context_lines})
		if !testing.expect(test, whole_error == nil, "the whole query runs") { return }
		defer grep_result_destroy(&whole, context.allocator)
		testing.expect_value(test, whole.total, len(whole.matches))
		for limit in 1 ..= 5 {
			cursor := ""
			seen := 0
			for {
				page, page_error := grep(&index, Grep_Query{pattern = "needle", context_lines = context_lines, limit = limit, cursor = cursor})
				if !testing.expect(test, page_error == nil, "the page runs") { return }
				testing.expect_value(test, page.total, whole.total)
				for row in page.matches {
					if seen < len(whole.matches) {
						testing.expect_value(test, row, whole.matches[seen])
					}
					seen += 1
				}
				next := strings.clone(page.next_cursor, context.temp_allocator)
				grep_result_destroy(&page, context.allocator)
				if next == "" {
					break
				}
				cursor = next
			}
			testing.expectf(test, seen == whole.total, "context %d limit %d pages %d of %d rows", context_lines, limit, seen, whole.total)
		}
	}
}

// Lines across a 64 KB chunk boundary, a line longer than a chunk, CRLF, and
// a last line without a newline all come back whole, with the carriage
// return stripped.
@(test)
test_grep_reads_lines_across_chunks_crlf_and_no_trailing_newline :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	content: strings.Builder
	strings.builder_init(&content, context.allocator)
	defer strings.builder_destroy(&content)
	wanted_lines := make([dynamic]int, context.temp_allocator)
	wanted_texts := make([dynamic]string, context.temp_allocator)
	line_count := 0
	add :: proc(content: ^strings.Builder, lines: ^[dynamic]int, texts: ^[dynamic]string, count: ^int, text, ending: string) {
		count^ += 1
		strings.write_string(content, text)
		strings.write_string(content, ending)
		if strings.contains(text, "needle") {
			append(lines, count^)
			append(texts, text)
		}
	}
	add(&content, &wanted_lines, &wanted_texts, &line_count, "first needle", "\r\n")
	for strings.builder_len(content) < CHUNK_LEN - 6 {
		add(&content, &wanted_lines, &wanted_texts, &line_count, "pad", "\n")
	}
	add(&content, &wanted_lines, &wanted_texts, &line_count, "straddles the chunk boundary needle", "\n")
	long := strings.concatenate({strings.repeat("x", 3 * CHUNK_LEN + 5, context.temp_allocator), " needle end"}, context.temp_allocator)
	add(&content, &wanted_lines, &wanted_texts, &line_count, long, "\n")
	add(&content, &wanted_lines, &wanted_texts, &line_count, "crlf needle", "\r\n")
	add(&content, &wanted_lines, &wanted_texts, &line_count, "last needle", "")
	test_write(test, dir, "a.txt", strings.to_string(content))
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	found, found_error := grep(&index, Grep_Query{pattern = "needle", limit = 0})
	if !testing.expect(test, found_error == nil, "the query runs") { return }
	defer grep_result_destroy(&found, context.allocator)
	testing.expect_value(test, found.skipped, Skip_Breakdown{})
	if testing.expect_value(test, len(found.matches), len(wanted_lines)) {
		for row, i in found.matches {
			testing.expect_value(test, row.line, wanted_lines[i])
			testing.expect(test, row.text == wanted_texts[i], "the line text is whole")
		}
	}
}

// With a frecency the files accessed recently are searched first; without
// one they follow path order.
@(test)
test_grep_frecency_orders_accessed_files_first :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a.txt", "needle\n")
	test_write(test, dir, "b.txt", "needle\n")
	test_write(test, dir, "c.txt", "needle\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	// Far past every file's mtime, so only the access score separates them.
	now := time.to_unix_seconds(time.now()) + 365 * 24 * 60 * 60
	frecency: Frecency
	if !testing.expect(test, frecency_open(&frecency, "", now) == nil, "the frecency opens") { return }
	defer frecency_destroy(&frecency)
	for file in index.files {
		if file.rel == "c.txt" {
			testing.expect(test, frecency_record(&frecency, file.full, now) == nil, "the access is recorded")
		}
	}

	plain, plain_error := grep(&index, Grep_Query{pattern = "needle", output = .Files_With_Matches})
	if !testing.expect(test, plain_error == nil, "the path-order query runs") { return }
	defer grep_result_destroy(&plain, context.allocator)
	ranked, ranked_error := grep(&index, Grep_Query{pattern = "needle", output = .Files_With_Matches, frecency = &frecency, now = now})
	if !testing.expect(test, ranked_error == nil, "the frecency query runs") { return }
	defer grep_result_destroy(&ranked, context.allocator)
	if testing.expect_value(test, len(plain.files), 3) {
		testing.expect_value(test, plain.files[0], "a.txt")
	}
	if testing.expect_value(test, len(ranked.files), 3) {
		testing.expect_value(test, ranked.files[0], "c.txt")
		testing.expect_value(test, ranked.files[1], "a.txt")
		testing.expect_value(test, ranked.files[2], "b.txt")
	}
}

// Every mode and output releases all it allocated: nothing is left on the
// allocator once the results are destroyed.
@(test)
test_grep_releases_everything_it_allocates :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	for i in 0 ..< 6 {
		name := strings.concatenate({"f", string([]byte{byte('0' + i)}), ".txt"}, context.temp_allocator)
		test_write(test, dir, name, "alpha\nprintf_line :: proc() {}\nbeta needle\ngamma\n")
	}
	// The index walk and the workers allocate from several threads; the
	// tracker locks its own state.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	index, make_error := index_make(dir, allocator)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)
	baseline := len(track.allocation_map)

	queries := []Grep_Query {
		{pattern = "needle", context_lines = 1, limit = 4},
		{pattern = "needle", output = .Files_With_Matches, limit = 2},
		{pattern = "nee+dle", mode = .Regex, limit = 3},
		{pattern = "([", mode = .Regex},
		{pattern = "pritnf", limit = 3},
		{pattern = "pritnf", output = .Files_With_Matches},
		{pattern = "zzz needle"},
		{pattern = "needle", limit = 1, cursor = ""},
	}
	for query in queries {
		found, found_error := grep(&index, query, allocator)
		testing.expect_value(test, found_error, nil)
		grep_result_destroy(&found, allocator)
	}
	testing.expect_value(test, len(track.allocation_map), baseline)
}

// typo_corpus plants seven files with distinctive names and lines for the
// recovery tests below. It returns the scratch directory, owned by the test
// allocator.
typo_targets := []string{"src/main.odin", "src/util.odin", "docs/guide.md", "lib/net/http.odin", "lib/net/tcp.odin", "assets/logo.png", "README.md"}

typo_lines := []string {
	"package main\nprintf_line :: proc() {}\n",
	"package main\nutility_proc :: proc() {}\n",
	"# guide\nread the manual here\n",
	"package net\nhttp_serve :: proc() {}\n",
	"package net\ntcp_dial :: proc() {}\n",
	"binary-ish logo bytes as text\n",
	"# readme\nhello world\n",
}

// test_typo_corpus builds the planted corpus and its index. The caller owns
// both and destroys them.
test_typo_corpus :: proc(test: ^testing.T) -> (dir: string, index: Index) {
	made, dir_error := os.make_directory_temp("", "search-typo-*", context.allocator)
	if dir_error != nil {
		testing.fail_now(test, "the scratch directory is created")
	}
	for target, i in typo_targets {
		test_write(test, made, target, typo_lines[i])
	}
	built, make_error := index_make(made)
	if make_error != nil {
		testing.fail_now(test, "the index is built")
	}
	return made, built
}

// Eighteen single-character typo queries over the corpus lock the content
// recovery rate per class: three per line over six lines. Every entry
// below is one edit from its target; the counts assert how many rank that
// target first.

// typo_bench_hit is one content benchmark query: the typo, the path whose
// line must rank first, the word that line holds, and the typo class.
typo_bench_hit :: struct {
	query: string,
	path:  string,
	word:  string,
	class: string,
}

typo_bench_content := []typo_bench_hit {
	{"printg", "src/main.odin", "printf", "sub"},
	{"print", "src/main.odin", "printf", "del"},
	{"rpintf", "src/main.odin", "printf", "swap"},
	{"utlity", "src/util.odin", "utility", "del"},
	{"utilify", "src/util.odin", "utility", "sub"},
	{"utiilty", "src/util.odin", "utility", "swap"},
	{"manuak", "docs/guide.md", "manual", "sub"},
	{"manua", "docs/guide.md", "manual", "del"},
	{"amnual", "docs/guide.md", "manual", "swap"},
	{"http_serxe", "lib/net/http.odin", "http_serve", "sub"},
	{"http_sere", "lib/net/http.odin", "http_serve", "del"},
	{"http_sevre", "lib/net/http.odin", "http_serve", "swap"},
	{"tcp_tial", "lib/net/tcp.odin", "tcp_dial", "sub"},
	{"tcp_dia", "lib/net/tcp.odin", "tcp_dial", "del"},
	{"tcp_dail", "lib/net/tcp.odin", "tcp_dial", "swap"},
	{"binqry", "assets/logo.png", "binary", "sub"},
	{"binay", "assets/logo.png", "binary", "del"},
	{"binray", "assets/logo.png", "binary", "swap"},
}

// bench_count_first bumps the class counter for a benchmark query whose
// target ranks first.
bench_count_first :: proc(class: string, sub, del, swap: ^int) {
	switch class {
	case "sub":
		sub^ += 1
	case "del":
		del^ += 1
	case "swap":
		swap^ += 1
	}
}

@(test)
test_typo_benchmark_content_queries_rank_first :: proc(test: ^testing.T) {
	dir, index := test_typo_corpus(test)
	defer {
		index_destroy(&index)
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	testing.expect_value(test, len(typo_bench_content), 18)
	sub_first, del_first, swap_first := 0, 0, 0
	labeled := 0
	for hit in typo_bench_content {
		found, found_error := grep(&index, Grep_Query{pattern = hit.query, limit = 5})
		if !testing.expect(test, found_error == nil, "the content query runs") { continue }
		if found.notice != "" {
			labeled += 1
			testing.expect(test, strings.contains(found.notice, "approximate"), "the fallback is labeled")
		}
		if len(found.matches) > 0 && found.matches[0].path == hit.path && strings.contains(found.matches[0].text, hit.word) {
			bench_count_first(hit.class, &sub_first, &del_first, &swap_first)
		} else {
			testing.expectf(test, false, "%s %q resolves first, want %s holding %q", hit.class, hit.query, hit.path, hit.word)
		}
		grep_result_destroy(&found, context.allocator)
	}
	testing.expect_value(test, sub_first, 6)
	testing.expect_value(test, del_first, 6)
	testing.expect_value(test, swap_first, 6)
	// Three deletion variants are exact substrings of their targets
	// ("print" of "printf", "manua" of "manual", "tcp_dia" of "tcp_dial"),
	// so they resolve on the exact path with no label; the other 15 run
	// the labeled recovery.
	testing.expect_value(test, labeled, 15)
}

// A file admitted by a kept line but whose path the final fuzzy matcher
// rejects is released exactly once in Files_With_Matches mode, for the
// same single-owner reason as the content rows above.
@(test)
test_grep_fallback_files_mode_frees_rejected_paths_once :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	// print.odin's path stays close enough to keep while note.txt's path is
	// rejected, so the run exercises both the winner and the loser cleanup.
	test_write(test, dir, "print.odin", "printf_line :: proc() {}\n")
	test_write(test, dir, "note.txt", "printf_line :: proc() {}\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)
	found, found_error := grep(&index, Grep_Query{pattern = "printx", output = .Files_With_Matches, limit = 5})
	if !testing.expect(test, found_error == nil, "the typo query runs") { return }
	defer grep_result_destroy(&found, context.allocator)
	testing.expect(test, strings.contains(found.notice, "approximate"), "the fallback is labeled")
	if testing.expect(test, len(found.files) > 0, "a kept path resolves") {
		testing.expect(test, found.files[0] == "print.odin", "the closest path ranks first")
	}
}

// The labeled recovery never exceeds one page: a noisy fallback is bounded
// even where scattered bytes pass the gates.
@(test)
test_fallback_rows_bounded_to_one_page :: proc(test: ^testing.T) {
	dir, index := test_typo_corpus(test)
	defer {
		index_destroy(&index)
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	content, content_error := grep(&index, Grep_Query{pattern = "pritnf", limit = 0})
	if !testing.expect(test, content_error == nil, "the content typo runs") { return }
	defer grep_result_destroy(&content, context.allocator)
	testing.expect(test, content.total > 0, "the typo resolves")
	testing.expect(test, content.total <= APPROX_CAP, "the recovery never exceeds one page")
	testing.expect(test, strings.contains(content.notice, "approximate"), "the fallback is labeled")
}

// want_row is one expected grep row: path, 1-based line, 1-based byte
// column, and line text.
want_row :: struct {
	path: string,
	line: int,
	col:  int,
	text: string,
}

// Six regular expressions match ripgrep line for line on a planted corpus:
// path, line, column, and text of every matching line. The expectations
// below were read off `rg --column --line-number` over the same file, and
// the queries run case-sensitive like ripgrep's default; one row covers one
// line at its first match column.
@(test)
test_grep_regex_parity_six_patterns :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "code.txt", "hello world\nfoo bar 123\nsay (hi) again\nabc123def\nHello HELLO hello\nprice: $42.00\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	patterns := []string{"^hello", "world$", `\(hi\)`, "foo|bar", "[0-9]+", "h.llo"}
	wanted := [][]want_row {
		{{"code.txt", 1, 1, "hello world"}},
		{{"code.txt", 1, 7, "hello world"}},
		{{"code.txt", 3, 5, "say (hi) again"}},
		{{"code.txt", 2, 1, "foo bar 123"}},
		{{"code.txt", 2, 9, "foo bar 123"}, {"code.txt", 4, 4, "abc123def"}, {"code.txt", 6, 9, "price: $42.00"}},
		{{"code.txt", 1, 1, "hello world"}, {"code.txt", 5, 13, "Hello HELLO hello"}},
	}
	for pattern, i in patterns {
		found, found_error := grep(&index, Grep_Query{pattern = pattern, mode = .Regex, sensitivity = .Sensitive, limit = 0})
		if !testing.expect(test, found_error == nil, "the expression runs") { continue }
		testing.expect_value(test, found.notice, "")
		if !testing.expect_value(test, len(found.matches), len(wanted[i])) {
			grep_result_destroy(&found, context.allocator)
			continue
		}
		for row, j in found.matches {
			testing.expect_value(test, row.path, wanted[i][j].path)
			testing.expect_value(test, row.line, wanted[i][j].line)
			testing.expect_value(test, row.col, wanted[i][j].col)
			testing.expect_value(test, row.text, wanted[i][j].text)
		}
		grep_result_destroy(&found, context.allocator)
	}
}

// The regex gate keeps only lines holding a literal every match holds, so a
// literal taken from a token a quantifier or a count makes optional would
// drop matches. Each pattern below must find exactly the lines the
// expression matches.
@(test)
test_grep_regex_gate_keeps_every_match :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a.txt", "abbc\ncolor\ncolour\n\u00E9\u00E9x\nx\naab\nfoo(bar)\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	cases := []struct {
		pattern: string,
		lines:   []int,
	} {
		{"ab+c", {1}},
		{"colou?r", {2, 3}},
		{"\u00E9*x", {4, 5}},
		{"a{2}b", {6}},
		{"(co|ab)lo", {2, 3}},
		{`foo\(bar\)`, {7}},
		{"[a]b+", {1, 6}},
		{"a|x", {1, 4, 5, 6, 7}},
	}
	for entry in cases {
		found, found_error := grep(&index, Grep_Query{pattern = entry.pattern, mode = .Regex})
		if !testing.expect(test, found_error == nil, "the expression runs") { continue }
		defer grep_result_destroy(&found, context.allocator)
		testing.expect_value(test, found.notice, "")
		if testing.expect_value(test, len(found.matches), len(entry.lines)) {
			for row, i in found.matches {
				testing.expect_value(test, row.line, entry.lines[i])
			}
		}
	}
}

// The regex prefilter decides nothing: lines the literal passes but the
// expression rejects stay out, lines the literal skips stay out only when
// the expression would reject them too, and totals match the unfiltered run.
@(test)
test_regex_prefilter_keeps_regex_totals :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	// The middle line holds the literal but fails the expression; the last
	// line holds neither. The third line passes the gate through "code" but
	// the expression rejects it; the fifth line carries the escaped dot.
	test_write(test, dir, "a.txt", "error code: 5\nerrorful decode\nencode this\nnothing here\nv1.2 ready\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	found, found_error := grep(&index, Grep_Query{pattern = "err.*code", mode = .Regex})
	if !testing.expect(test, found_error == nil, "the regex query runs") { return }
	defer grep_result_destroy(&found, context.allocator)
	testing.expect_value(test, found.total, 2)
	testing.expect_value(test, found.notice, "")
	if testing.expect_value(test, len(found.matches), 2) {
		testing.expect_value(test, found.matches[0].line, 1)
		testing.expect_value(test, found.matches[0].text, "error code: 5")
		testing.expect_value(test, found.matches[1].line, 2)
	}

	dotted, dotted_error := grep(&index, Grep_Query{pattern = `\.`, mode = .Regex})
	if !testing.expect(test, dotted_error == nil, "the escaped query runs") { return }
	defer grep_result_destroy(&dotted, context.allocator)
	testing.expect_value(test, dotted.total, 1)
	testing.expect_value(test, dotted.notice, "")
	if testing.expect_value(test, len(dotted.matches), 1) {
		testing.expect_value(test, dotted.matches[0].line, 5)
	}
}

// Smart case folds Unicode simple-fold orbits: a lowercase ASCII pattern
// matches the Kelvin sign (U+212A) and the long s (U+017F), and a pattern
// with an uppercase letter stays case-sensitive.
@(test)
test_grep_smart_case_folds_kelvin_and_long_s :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a.txt", "300 \u212A here\n\u017Fystem call\nnothing\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	kelvin, kelvin_error := grep(&index, Grep_Query{pattern = "k"})
	if !testing.expect(test, kelvin_error == nil, "the k query runs") { return }
	defer grep_result_destroy(&kelvin, context.allocator)
	testing.expect_value(test, kelvin.notice, "")
	if testing.expect_value(test, len(kelvin.matches), 1) {
		testing.expect_value(test, kelvin.matches[0].line, 1)
		testing.expect_value(test, kelvin.matches[0].col, 5)
	}

	long_s, long_s_error := grep(&index, Grep_Query{pattern = "system"})
	if !testing.expect(test, long_s_error == nil, "the system query runs") { return }
	defer grep_result_destroy(&long_s, context.allocator)
	testing.expect_value(test, long_s.notice, "")
	if testing.expect_value(test, len(long_s.matches), 1) {
		testing.expect_value(test, long_s.matches[0].line, 2)
		testing.expect_value(test, long_s.matches[0].col, 1)
	}

	sensitive, sensitive_error := grep(&index, Grep_Query{pattern = "K", output = .Files_With_Matches})
	if !testing.expect(test, sensitive_error == nil, "the K query runs") { return }
	defer grep_result_destroy(&sensitive, context.allocator)
	testing.expect_value(test, len(sensitive.files), 0)
}
