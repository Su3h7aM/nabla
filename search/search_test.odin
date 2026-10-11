#+test
package search

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// test_dir creates a per-test scratch directory the test removes before
// returning.
test_dir :: proc(test: ^testing.T) -> string {
	dir, dir_error := os.make_directory_temp("", "search-test-*", context.allocator)
	if !testing.expect(test, dir_error == nil, "the scratch directory is created") {
		return ""
	}
	return dir
}

// test_write creates name under dir with content, creating parents.
test_write :: proc(test: ^testing.T, dir, name, content: string) {
	path := strings.concatenate({dir, "/", name}, context.temp_allocator)
	parent := path[:strings.last_index_byte(path, '/')]
	if make_error := os.make_directory_all(parent); make_error != nil && make_error != .Exist {
		testing.fail_now(test, "the test directory could not be created")
	}
	if write_error := os.write_entire_file(path, content); write_error != nil {
		testing.fail_now(test, "the test file could not be written")
	}
}

// expect_code checks that err is the wanted Error_Code.
expect_code :: proc(test: ^testing.T, err: Error, want: Error_Code, what: string) {
	code, ok := err.(Error_Code)
	if !testing.expect(test, ok, what) {
		return
	}
	testing.expect_value(test, code, want)
}

// A new top-level file appears without a manual rescan: one stat per refresh
// notices the root mtime moved and rewalks once, then later refreshes walk
// nothing while the root sits still.
@(test)
test_refresh_notices_new_top_level_files :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a.txt", "hello\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	refreshed, refresh_error := index_refresh_if_stale(&index)
	if !testing.expect(test, refresh_error == nil, "the fresh check runs") { return }
	testing.expect(test, !refreshed, "an unchanged root walks nothing")

	test_write(test, dir, "new_top.txt", "FRESH_MARKER_LINE\n")
	changed, changed_error := index_refresh_if_stale(&index)
	if !testing.expect(test, changed_error == nil, "the stale check runs") { return }
	testing.expect(test, changed, "a new top-level file rewalks once")

	found, found_error := find(&index, Find_Query{query = "new_top"})
	if !testing.expect(test, found_error == nil, "the new file is searchable") { return }
	defer find_result_destroy(&found, context.allocator)
	testing.expect_value(test, found.total, 1)

	settled, settled_error := index_refresh_if_stale(&index)
	if !testing.expect(test, settled_error == nil, "the settled check runs") { return }
	testing.expect(test, !settled, "a settled root walks nothing")
}

// The default scope descends into nested repositories and indexes hidden
// files, while .git and hidden directories stay pruned. Denylisted
// directories are covered by the skip breakdown test.
@(test)
test_default_scope_descends_into_nested_repos :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "app/main.py", "x\n")
	test_write(test, dir, "app/app.py", "x\n")
	test_write(test, dir, "repos/flask/app.py", "x\n")
	test_write(test, dir, "repos/flask/.git/config", "x\n")
	test_write(test, dir, ".hidden/secret.txt", "x\n")
	test_write(test, dir, ".env", "x\n")
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	found, found_error := find(&index, Find_Query{limit = 0})
	if !testing.expect(test, found_error == nil, "the find runs") { return }
	defer find_result_destroy(&found, context.allocator)
	testing.expect_value(test, found.total, 4)
	for want in ([?]string{"app/main.py", "app/app.py", "repos/flask/app.py", ".env"}) {
		testing.expectf(test, slice.contains(found.files, want), "%q is indexed", want)
	}
}

// A symlinked file and a symlinked directory are not indexed, and grep never
// reads through them.
@(test)
test_symlinks_are_not_indexed_or_followed :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "real.txt", "LINK_MARKER\n")
	test_write(test, dir, "real/inner.txt", "LINK_MARKER\n")
	file_target := strings.concatenate({dir, "/real.txt"}, context.temp_allocator)
	file_link := strings.concatenate({dir, "/link.txt"}, context.temp_allocator)
	dir_target := strings.concatenate({dir, "/real"}, context.temp_allocator)
	dir_link := strings.concatenate({dir, "/linkdir"}, context.temp_allocator)
	if !testing.expect(test, os.symlink(file_target, file_link) == nil, "the file symlink is created") { return }
	if !testing.expect(test, os.symlink(dir_target, dir_link) == nil, "the directory symlink is created") { return }
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	found, found_error := find(&index, Find_Query{limit = 0})
	if !testing.expect(test, found_error == nil, "the find runs") { return }
	defer find_result_destroy(&found, context.allocator)
	testing.expect_value(test, found.total, 2)
	testing.expect(test, slice.contains(found.files, "real.txt"), "the real file is indexed")
	testing.expect(test, slice.contains(found.files, "real/inner.txt"), "the real directory's file is indexed")
	testing.expect_value(test, found.skipped, Skip_Breakdown{})

	content, content_error := grep(&index, Grep_Query{pattern = "LINK_MARKER", limit = 0})
	if !testing.expect(test, content_error == nil, "the grep runs") { return }
	defer grep_result_destroy(&content, context.allocator)
	testing.expect_value(test, content.total, 2)
	for row in content.matches {
		testing.expectf(test, !strings.has_prefix(row.path, "linkdir") && row.path != "link.txt", "%q is not a symlink", row.path)
	}
}

// cursor_test_index indexes three files that both a find for ".txt" and a
// grep for "hello" match once each. The caller cleans up with
// cursor_test_cleanup.
cursor_test_index :: proc(test: ^testing.T) -> (dir: string, index: Index) {
	dir = test_dir(test)
	if dir == "" {
		testing.fail_now(test, "the scratch directory is created")
	}
	test_write(test, dir, "a.txt", "hello\n")
	test_write(test, dir, "b.txt", "hello\n")
	test_write(test, dir, "c.txt", "hello\n")
	made, make_error := index_make(dir)
	if make_error != nil {
		testing.fail_now(test, "the index is built")
	}
	return dir, made
}

cursor_test_cleanup :: proc(dir: string, index: ^Index) {
	index_destroy(index)
	os.remove_all(dir)
	delete(dir, context.allocator)
}

// cursor_test_first returns the cursor of a one-row first page of index. The
// text lives on the temp allocator.
cursor_test_first :: proc(test: ^testing.T, index: ^Index) -> string {
	page, page_error := find(index, Find_Query{query = ".txt", limit = 1})
	if page_error != nil || page.next_cursor == "" {
		testing.fail_now(test, "the first page carries a cursor")
	}
	defer find_result_destroy(&page, context.allocator)
	return strings.clone(page.next_cursor, context.temp_allocator)
}

// expect_cursor_error checks that find and grep both refuse cursor with want.
expect_cursor_error :: proc(test: ^testing.T, index: ^Index, cursor: string, want: Error_Code) {
	found, find_error := find(index, Find_Query{query = ".txt", cursor = cursor})
	find_result_destroy(&found, context.allocator)
	expect_code(test, find_error, want, fmt.tprintf("find refuses cursor %q", cursor))
	content, grep_error := grep(index, Grep_Query{pattern = "hello", cursor = cursor})
	grep_result_destroy(&content, context.allocator)
	expect_code(test, grep_error, want, fmt.tprintf("grep refuses cursor %q", cursor))
}

// A cursor is plain text that names no path, and each page's cursor resumes
// the next page, in find and in grep.
@(test)
test_cursor_resumes_the_next_page :: proc(test: ^testing.T) {
	dir, index := cursor_test_index(test)
	defer cursor_test_cleanup(dir, &index)

	cursor := cursor_test_first(test, &index)
	testing.expect_value(test, len(strings.split(cursor, ".", context.temp_allocator)), 3)
	testing.expect(test, !strings.contains(cursor, dir), "the cursor names no path")

	first, first_error := find(&index, Find_Query{query = ".txt", limit = 1})
	if !testing.expect(test, first_error == nil, "the first find page runs") { return }
	defer find_result_destroy(&first, context.allocator)
	second, second_error := find(&index, Find_Query{query = ".txt", limit = 1, cursor = cursor})
	if !testing.expect(test, second_error == nil, "the find cursor resumes") { return }
	defer find_result_destroy(&second, context.allocator)
	testing.expect_value(test, second.total, 3)
	if testing.expect_value(test, len(second.files), 1) && testing.expect_value(test, len(first.files), 1) {
		testing.expect(test, first.files[0] != second.files[0], "the second page holds another row")
	}

	content_first, content_first_error := grep(&index, Grep_Query{pattern = "hello", limit = 1})
	if !testing.expect(test, content_first_error == nil, "the first grep page runs") { return }
	defer grep_result_destroy(&content_first, context.allocator)
	content_second, content_second_error := grep(&index, Grep_Query{pattern = "hello", limit = 1, cursor = content_first.next_cursor})
	if !testing.expect(test, content_second_error == nil, "the grep cursor resumes") { return }
	defer grep_result_destroy(&content_second, context.allocator)
	if testing.expect_value(test, len(content_second.matches), 1) && testing.expect_value(test, len(content_first.matches), 1) {
		testing.expect(test, content_first.matches[0].path != content_second.matches[0].path, "the second page holds another row")
	}
}

// A cursor that is not exactly "<generation>.<offset>.<hash>" in canonical
// form is Invalid_Cursor, including numbers past the int range, which must
// not panic.
@(test)
test_cursor_rejects_malformed_text :: proc(test: ^testing.T) {
	dir, index := cursor_test_index(test)
	defer cursor_test_cleanup(dir, &index)

	valid := cursor_test_first(test, &index)
	fields := strings.split(valid, ".", context.temp_allocator)
	if !testing.expect_value(test, len(fields), 3) { return }
	generation, offset, hash := fields[0], fields[1], fields[2]
	testing.expect_value(test, len(hash), 16)

	rejected := make([dynamic]string, context.temp_allocator)
	append(
		&rejected,
		fmt.tprintf("%s.9223372036854775808.%s", generation, hash), // offset overflows int
		fmt.tprintf("9223372036854775808.%s.%s", offset, hash), // generation overflows int
		fmt.tprintf("%s.99999999999999999999.%s", generation, hash), // offset overflows u64
		fmt.tprintf("%s.%s", generation, offset), // missing hash
		fmt.tprintf("%s.%s.", generation, offset), // empty hash
		fmt.tprintf("%s..%s", generation, hash), // empty offset
		generation,
		fmt.tprintf("%s.%s.%s.0", generation, offset, hash), // extra field
		fmt.tprintf("0%s.%s.%s", generation, offset, hash), // leading zero
		fmt.tprintf("%s.0%s.%s", generation, offset, hash),
		fmt.tprintf("+%s.%s.%s", generation, offset, hash), // sign
		fmt.tprintf("%s.+5.%s", generation, hash),
		fmt.tprintf("%s.-1.%s", generation, hash),
		fmt.tprintf("%s.%s.%s", generation, offset, hash[:15]), // short hash
		fmt.tprintf("%s.%s.A%s", generation, offset, hash[1:]), // uppercase hash; the canonical hash is lowercase hex
		fmt.tprintf(" %s", valid), // whitespace and quotes
		fmt.tprintf("%s ", valid),
		fmt.tprintf("%s\n", valid),
		fmt.tprintf("%q", valid),
	)
	for cursor in rejected {
		expect_cursor_error(test, &index, cursor, .Invalid_Cursor)
	}
}

// A cursor issued for one root is Invalid_Cursor for another, even at the same
// generation.
@(test)
test_cursor_from_another_root_is_invalid :: proc(test: ^testing.T) {
	dir, index := cursor_test_index(test)
	defer cursor_test_cleanup(dir, &index)
	other_dir, other := cursor_test_index(test)
	defer cursor_test_cleanup(other_dir, &other)

	expect_cursor_error(test, &other, cursor_test_first(test, &index), .Invalid_Cursor)
}

// A cursor from before index_update is Stale_Cursor, and a fresh one works.
@(test)
test_cursor_from_before_update_is_stale :: proc(test: ^testing.T) {
	dir, index := cursor_test_index(test)
	defer cursor_test_cleanup(dir, &index)

	aged := cursor_test_first(test, &index)
	_, update_error := index_update(&index)
	if !testing.expect(test, update_error == nil, "the rescan runs") { return }
	expect_cursor_error(test, &index, aged, .Stale_Cursor)

	fresh := cursor_test_first(test, &index)
	resumed, resumed_error := find(&index, Find_Query{query = ".txt", limit = 1, cursor = fresh})
	testing.expect_value(test, resumed_error, nil)
	find_result_destroy(&resumed, context.allocator)
}

// An offset at or past the end is an empty page that keeps the total and
// carries no next cursor, even at the largest int.
@(test)
test_cursor_offset_past_the_end_is_an_empty_page :: proc(test: ^testing.T) {
	dir, index := cursor_test_index(test)
	defer cursor_test_cleanup(dir, &index)

	fields := strings.split(cursor_test_first(test, &index), ".", context.temp_allocator)
	if !testing.expect_value(test, len(fields), 3) { return }
	for offset in ([?]string{"3", "99", "9223372036854775807"}) {
		cursor := fmt.tprintf("%s.%s.%s", fields[0], offset, fields[2])
		found, find_error := find(&index, Find_Query{query = ".txt", cursor = cursor})
		if testing.expect_value(test, find_error, nil) {
			testing.expect_value(test, found.total, 3)
			testing.expect_value(test, len(found.files), 0)
			testing.expect_value(test, found.next_cursor, "")
		}
		find_result_destroy(&found, context.allocator)
		content, grep_error := grep(&index, Grep_Query{pattern = "hello", cursor = cursor})
		if testing.expect_value(test, grep_error, nil) {
			testing.expect_value(test, content.total, 3)
			testing.expect_value(test, len(content.matches), 0)
			testing.expect_value(test, content.next_cursor, "")
		}
		grep_result_destroy(&content, context.allocator)
	}
}

// Skips are counted by cause: binary files, oversized files, and pruned
// denylist directories each land in their own counter, and the file total is
// their sum. Find still lists oversized files by path; only grep skips them.
@(test)
test_skip_breakdown_names_reasons :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a.txt", "needle here\n")
	test_write(test, dir, "bin.dat", "ab\x00cd needle\n")
	test_write(test, dir, "node_modules/dep.js", "needle here\n")
	big := make([]byte, GREP_MAX_FILE_SIZE + 1024, context.allocator)
	defer delete(big, context.allocator)
	for &byte in big {
		byte = 'x'
	}
	marker := "needle here\n"
	for i in 0 ..< len(marker) {
		big[i] = marker[i]
		big[len(big) - len(marker) + i] = marker[i]
	}
	big_path := strings.concatenate({dir, "/big.dat"}, context.temp_allocator)
	if write_error := os.write_entire_file(big_path, big); write_error != nil {
		testing.fail_now(test, "the oversized file could not be written")
	}
	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)

	content, content_error := grep(&index, Grep_Query{pattern = "needle", limit = 0})
	if !testing.expect(test, content_error == nil, "the grep runs") { return }
	defer grep_result_destroy(&content, context.allocator)
	testing.expect_value(test, content.total, 1)
	if testing.expect_value(test, len(content.matches), 1) {
		testing.expect_value(test, content.matches[0].path, "a.txt")
	}
	testing.expect_value(test, content.skipped.binary, 1)
	testing.expect_value(test, content.skipped.oversize, 1)
	testing.expect_value(test, content.skipped.denylist, 1)
	testing.expect_value(test, skip_files_total(content.skipped), 2)

	listed, listed_error := find(&index, Find_Query{query = "big.dat"})
	if !testing.expect(test, listed_error == nil, "the find runs") { return }
	defer find_result_destroy(&listed, context.allocator)
	testing.expect_value(test, listed.total, 1)
	testing.expect_value(test, listed.skipped.oversize, 0)

	pruned, pruned_error := find(&index, Find_Query{query = "dep.js"})
	if !testing.expect(test, pruned_error == nil, "the pruned query runs") { return }
	defer find_result_destroy(&pruned, context.allocator)
	testing.expect_value(test, pruned.total, 0)
	testing.expect_value(test, pruned.skipped.denylist, 1)
}

// An unreadable directory is counted and skipped, and the files beside it and
// after it in walk order stay indexed, both below the top level and at it.
@(test)
test_unreadable_directory_does_not_hide_later_files :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a/one.txt", "1\n")
	test_write(test, dir, "a/locked/hidden.txt", "x\n")
	test_write(test, dir, "a/two.txt", "2\n")
	test_write(test, dir, "b/three.txt", "3\n")
	test_write(test, dir, "locked/hidden.txt", "x\n")
	test_write(test, dir, "z/four.txt", "4\n")
	test_write(test, dir, "top.txt", "5\n")
	locked := [?]string{"a/locked", "locked"}
	for name in locked {
		path := strings.concatenate({dir, "/", name}, context.temp_allocator)
		if !testing.expect(test, os.change_mode(path, {}) == nil, "the directory is locked") { return }
	}
	defer for name in locked {
		path := strings.concatenate({dir, "/", name}, context.temp_allocator)
		_ = os.change_mode(path, os.perm_number(0o755))
	}
	probe, probe_error := os.open(strings.concatenate({dir, "/locked"}, context.temp_allocator))
	if probe_error == nil {
		// A process that bypasses permission bits cannot fail this open.
		os.close(probe)
		return
	}

	index, make_error := index_make(dir)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	defer index_destroy(&index)
	found, found_error := find(&index, Find_Query{limit = 0})
	if !testing.expect(test, found_error == nil, "the find runs") { return }
	defer find_result_destroy(&found, context.allocator)
	testing.expect_value(test, found.skipped.unreadable, 2)
	want := [?]string{"a/one.txt", "a/two.txt", "b/three.txt", "top.txt", "z/four.txt"}
	testing.expect_value(test, found.total, len(want))
	for name in want {
		testing.expectf(test, slice.contains(found.files, name), "%q is indexed", name)
	}
}

// An index holds exactly two allocations of its allocator, through the scan
// and an update, and queries retain nothing per call. The walk uses the
// allocator only on the calling thread. find is single-threaded; grep's
// workers share the allocator and are covered by
// test_grep_releases_everything_it_allocates.
@(test)
test_index_holds_two_allocations_and_queries_retain_none :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	for i in 0 ..< 24 {
		for j in 0 ..< 6 {
			test_write(test, dir, fmt.tprintf("dir%d/sub%d/file%d.txt", i, j, i * j), "content\n")
		}
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	index, make_error := index_make(dir, allocator)
	if !testing.expect(test, make_error == nil, "the index is built") { return }
	testing.expect_value(test, len(track.allocation_map), 2)
	_, update_error := index_update(&index)
	testing.expect_value(test, update_error, nil)
	testing.expect_value(test, len(track.allocation_map), 2)

	for _ in 0 ..< 30 {
		found, found_error := find(&index, Find_Query{query = "file", limit = 10}, allocator)
		if testing.expect_value(test, found_error, nil) {
			testing.expect_value(test, found.total, 24 * 6)
		}
		find_result_destroy(&found, allocator)
		missing, missing_error := find(&index, Find_Query{query = "aaabbbccc", limit = 0}, allocator)
		testing.expect_value(test, missing_error, nil)
		find_result_destroy(&missing, allocator)
	}
	testing.expect_value(test, len(track.allocation_map), 2)
	index_destroy(&index)
	testing.expect_value(test, len(track.allocation_map), 0)
}

// A glob is valid only when the whole pattern parses, including the part a
// name never reaches.
@(test)
test_glob_valid_reads_the_whole_pattern :: proc(test: ^testing.T) {
	valid := [?]string{"", "*", "*.odin", "src/*/main.?", "[abc]", "[a-z]x", "[^a-c]", "a\\[", "\\*", "[\\]]"}
	for glob in valid {
		testing.expectf(test, glob_valid(glob), "%q is valid", glob)
	}
	invalid := [?]string{"src/[", "a[", "[a", "[]", "[^]", "[a-]", "[-a]", "[a-", "[a-z", "a\\"}
	for glob in invalid {
		testing.expectf(test, !glob_valid(glob), "%q is invalid", glob)
	}
}
