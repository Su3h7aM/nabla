#+test
package search

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// find_test_index writes each name under a fresh scratch directory with empty
// content and indexes it. The caller removes the directory with
// find_test_cleanup.
find_test_index :: proc(test: ^testing.T, names: []string) -> (dir: string, index: Index) {
	dir = test_dir(test)
	if dir == "" {
		testing.fail_now(test, "the scratch directory is created")
	}
	for name in names {
		test_write(test, dir, name, "\n")
	}
	made, make_error := index_make(dir)
	if make_error != nil {
		testing.fail_now(test, "the index is built")
	}
	return dir, made
}

find_test_cleanup :: proc(dir: string, index: ^Index) {
	index_destroy(index)
	os.remove_all(dir)
	delete(dir, context.allocator)
}

// find_test_run runs one find and returns its result, failing the test when
// the call errors.
find_test_run :: proc(test: ^testing.T, index: ^Index, query: Find_Query) -> Find_Result {
	result, err := find(index, query)
	if err != nil {
		testing.fail_now(test, "the find runs")
	}
	return result
}

// Exact substring hits are the only rows when any exist: a typo of the same
// name stays out, a whole-path hit outranks a longer path holding it, and case
// is ignored unless the query holds an uppercase letter.
@(test)
test_find_returns_only_exact_hits_when_any_exist :: proc(test: ^testing.T) {
	dir, index := find_test_index(test, {"parsel.odin", "src/parser.odin", "parser.odin", "Parser.md", "notes.md"})
	defer find_test_cleanup(dir, &index)

	found := find_test_run(test, &index, {query = "parser.odin"})
	defer find_result_destroy(&found, context.allocator)
	if testing.expect_value(test, len(found.files), 2) {
		testing.expect_value(test, found.files[0], "parser.odin")
		testing.expect_value(test, found.files[1], "src/parser.odin")
	}
	testing.expect_value(test, found.total, 2)
	testing.expect_value(test, found.notice, "")

	folded := find_test_run(test, &index, {query = "parser"})
	defer find_result_destroy(&folded, context.allocator)
	testing.expect_value(test, folded.total, 3)
	testing.expect_value(test, folded.notice, "")

	sensitive := find_test_run(test, &index, {query = "Parser"})
	defer find_result_destroy(&sensitive, context.allocator)
	if testing.expect_value(test, len(sensitive.files), 1) {
		testing.expect_value(test, sensitive.files[0], "Parser.md")
	}
	testing.expect_value(test, sensitive.notice, "")
}

// With no exact hit, a typo falls back to labeled fuzzy rows, and scattered
// bytes find nothing and carry no label.
@(test)
test_find_falls_back_to_typos_only_without_exact_hits :: proc(test: ^testing.T) {
	dir, index := find_test_index(test, {"src/main.odin", "src/util.odin", "docs/guide.md"})
	defer find_test_cleanup(dir, &index)

	typo := find_test_run(test, &index, {query = "src/mian.odin"})
	defer find_result_destroy(&typo, context.allocator)
	if testing.expect(test, len(typo.files) > 0, "the typo resolves") {
		testing.expect_value(test, typo.files[0], "src/main.odin")
	}
	testing.expect(test, strings.contains(typo.notice, "approximate"), "the fallback is labeled")
	testing.expect_value(test, typo.total, len(typo.files))

	absent := find_test_run(test, &index, {query = "zzzqqqx"})
	defer find_result_destroy(&absent, context.allocator)
	testing.expect_value(test, absent.total, 0)
	testing.expect_value(test, len(absent.files), 0)
	testing.expect_value(test, absent.next_cursor, "")
	testing.expect_value(test, absent.notice, "")
}

// Every part of a multi-word query must occur in the path, in any order.
@(test)
test_find_requires_every_word :: proc(test: ^testing.T) {
	dir, index := find_test_index(test, {"src/main.odin", "src/util.odin", "docs/main.md"})
	defer find_test_cleanup(dir, &index)

	found := find_test_run(test, &index, {query = "src main"})
	defer find_result_destroy(&found, context.allocator)
	if testing.expect_value(test, len(found.files), 1) {
		testing.expect_value(test, found.files[0], "src/main.odin")
	}
	testing.expect_value(test, found.notice, "")

	reversed := find_test_run(test, &index, {query = "main src"})
	defer find_result_destroy(&reversed, context.allocator)
	if testing.expect_value(test, len(reversed.files), 1) {
		testing.expect_value(test, reversed.files[0], "src/main.odin")
	}
}

// Two exact hits that score alike rank by path without frecency, and the one
// with recorded accesses ranks first with it.
@(test)
test_find_reranks_with_frecency :: proc(test: ^testing.T) {
	dir, index := find_test_index(test, {"one/target.txt", "two/target.txt"})
	defer find_test_cleanup(dir, &index)
	now := time.to_unix_seconds(time.now())

	plain := find_test_run(test, &index, {query = "target"})
	defer find_result_destroy(&plain, context.allocator)
	if testing.expect_value(test, len(plain.files), 2) {
		testing.expect_value(test, plain.files[0], "one/target.txt")
	}

	frecency: Frecency
	open_error := frecency_open(&frecency, "", now)
	defer frecency_destroy(&frecency)
	testing.expect_value(test, open_error, nil)
	for file in index.files {
		if file.rel == "two/target.txt" {
			testing.expect_value(test, frecency_record(&frecency, file.full, now), nil)
		}
	}
	ranked := find_test_run(test, &index, {query = "target", frecency = &frecency, now = now})
	defer find_result_destroy(&ranked, context.allocator)
	if testing.expect_value(test, len(ranked.files), 2) {
		testing.expect_value(test, ranked.files[0], "two/target.txt")
		testing.expect_value(test, ranked.files[1], "one/target.txt")
	}
}

// Paging with the cursor of each page visits every row exactly once, in the
// order of one unpaged call.
@(test)
test_find_pages_cover_every_row_once :: proc(test: ^testing.T) {
	names := []string{"a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "sub/f.txt", "sub/g.txt"}
	dir, index := find_test_index(test, names)
	defer find_test_cleanup(dir, &index)

	whole := find_test_run(test, &index, {query = ".txt"})
	defer find_result_destroy(&whole, context.allocator)
	testing.expect_value(test, whole.total, len(names))

	seen: [dynamic]string
	defer {
		for path in seen {
			delete(path, context.allocator)
		}
		delete(seen)
	}
	cursor := ""
	defer if cursor != "" {
		delete(cursor, context.allocator)
	}
	for {
		page := find_test_run(test, &index, {query = ".txt", limit = 3, cursor = cursor})
		testing.expect_value(test, page.total, len(names))
		for path in page.files {
			cloned, clone_error := strings.clone(path, context.allocator)
			testing.expect_value(test, clone_error, nil)
			append(&seen, cloned)
		}
		next := page.next_cursor
		page.next_cursor = ""
		find_result_destroy(&page, context.allocator)
		if cursor != "" {
			delete(cursor, context.allocator)
		}
		cursor = next
		if cursor == "" {
			break
		}
	}
	if testing.expect_value(test, len(seen), len(whole.files)) {
		for path, i in seen {
			testing.expect_value(test, path, whole.files[i])
		}
	}
}

// glob keeps matching paths, exclude drops matching paths, and an unreadable
// glob is refused.
@(test)
test_find_filters_by_glob_and_exclude :: proc(test: ^testing.T) {
	dir, index := find_test_index(test, {"src/main.odin", "src/main.md", "docs/main.md"})
	defer find_test_cleanup(dir, &index)

	globbed := find_test_run(test, &index, {query = "main", glob = "*.odin"})
	defer find_result_destroy(&globbed, context.allocator)
	if testing.expect_value(test, len(globbed.files), 1) {
		testing.expect_value(test, globbed.files[0], "src/main.odin")
	}

	excluded := find_test_run(test, &index, {query = "main", glob = "*.md", exclude = "docs/*"})
	defer find_result_destroy(&excluded, context.allocator)
	if testing.expect_value(test, len(excluded.files), 1) {
		testing.expect_value(test, excluded.files[0], "src/main.md")
	}

	_, glob_error := find(&index, Find_Query{query = "main", glob = "["})
	expect_code(test, glob_error, .Invalid_Glob, "an unreadable glob is invalid")
}

// Single-character deletions, substitutions, and swaps of real paths fall
// back to their target as the first labeled row.
@(test)
test_find_ranks_single_typos_first :: proc(test: ^testing.T) {
	targets := []string{"src/main.odin", "src/util.odin", "docs/guide.md", "lib/net/http.odin", "lib/net/tcp.odin", "assets/logo.png", "README.md"}
	dir, index := find_test_index(test, targets)
	defer find_test_cleanup(dir, &index)

	typos := [][2]string {
		{"src/nain.odin", "src/main.odin"},
		{"src/man.odin", "src/main.odin"},
		{"src/mian.odin", "src/main.odin"},
		{"src/vtil.odin", "src/util.odin"},
		{"src/utl.odin", "src/util.odin"},
		{"src/utli.odin", "src/util.odin"},
		{"docs/fuide.md", "docs/guide.md"},
		{"docs/gude.md", "docs/guide.md"},
		{"docs/guied.md", "docs/guide.md"},
		{"lib/net/bttp.odin", "lib/net/http.odin"},
		{"lib/net/htp.odin", "lib/net/http.odin"},
		{"lib/net/htpt.odin", "lib/net/http.odin"},
		{"lib/net/tcx.odin", "lib/net/tcp.odin"},
		{"lib/net/tc.odin", "lib/net/tcp.odin"},
		{"lib/net/tpc.odin", "lib/net/tcp.odin"},
		{"assets/lopo.png", "assets/logo.png"},
		{"assets/log.png", "assets/logo.png"},
		{"assets/loog.png", "assets/logo.png"},
		{"REACME.md", "README.md"},
		{"READM.md", "README.md"},
		{"REDAME.md", "README.md"},
	}
	for typo in typos {
		found := find_test_run(test, &index, {query = typo[0], limit = 5})
		defer find_result_destroy(&found, context.allocator)
		if testing.expectf(test, len(found.files) > 0, "%q resolves", typo[0]) {
			testing.expectf(test, found.files[0] == typo[1], "%q resolves first to %q, got %q", typo[0], typo[1], found.files[0])
			testing.expectf(test, strings.contains(found.notice, "approximate"), "%q is labeled", typo[0])
		}
	}
}
