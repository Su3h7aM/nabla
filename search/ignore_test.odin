#+test
package search

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// expect_files checks that indexing root lists exactly the files in want.
expect_files :: proc(test: ^testing.T, root: string, want: []string) {
	index, make_error := index_make(root)
	if !testing.expect(test, make_error == nil, "the index is built") {
		return
	}
	defer index_destroy(&index)
	found, find_error := find(&index, Find_Query{limit = 0})
	if !testing.expect(test, find_error == nil, "the find runs") {
		return
	}
	defer find_result_destroy(&found, context.allocator)
	got := slice.clone(found.files, context.temp_allocator)
	expected := slice.clone(want, context.temp_allocator)
	slice.sort(got)
	slice.sort(expected)
	testing.expectf(test, slice.equal(got, expected), "indexed %v, want %v", got, expected)
}

// test_repo creates a scratch directory that holds a .git directory, so its
// ignore files apply.
test_repo :: proc(test: ^testing.T) -> string {
	dir := test_dir(test)
	if dir != "" {
		test_write(test, dir, ".git/HEAD", "ref: refs/heads/main\n")
	}
	return dir
}

@(test)
test_gitignore_patterns_follow_git_rules :: proc(test: ^testing.T) {
	dir := test_repo(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	for name in ([?]string{"app.log", "sub/deep/x.log", "cache/data.txt", "src/cache/x.txt", "root_only.txt", "docs/readme.md", "cache2/x.txt", "deep/cache2/y.txt", "other/cache2", "a/b.txt", "a/x/y/b.txt", "logs/one.txt", "logs/sub/two.txt", "vendor/keep.txt", "vendor/a.txt"}) {
		test_write(test, dir, name, "x\n")
	}
	kept := [?]string{".gitignore", "keep.log", "sub/keep.log", "docs/cache", "sub/root_only.txt", "docs/sub/notes.md", "a/b.txt.bak", "b.txt", "kept.txt"}
	for name in kept {
		test_write(test, dir, name, "x\n")
	}
	test_write(test, dir, ".gitignore", "*.log\n!keep.log\ncache/\n/root_only.txt\ndocs/*.md\n**/cache2\na/**/b.txt\nlogs/**\nvendor/\n!vendor/keep.txt\n")
	expect_files(test, dir, kept[:])
}

@(test)
test_gitignore_wildcards_and_classes :: proc(test: ^testing.T) {
	dir := test_repo(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	for name in ([?]string{"a.txt", "b.txt", "bx.txt", "cy.txt", "cz.txt", "x.dat", "sub/q.dat"}) {
		test_write(test, dir, name, "x\n")
	}
	kept := [?]string{".gitignore", "c.txt", "dx.txt", "ay.txt", "az.txt", "xy.dat"}
	for name in kept {
		test_write(test, dir, name, "x\n")
	}
	test_write(test, dir, ".gitignore", "[ab].txt\n[a-c]x.txt\n[!ab]y.txt\n[^ab]z.txt\n?.dat\n")
	expect_files(test, dir, kept[:])
}

@(test)
test_gitignore_escapes_comments_and_trailing_spaces :: proc(test: ^testing.T) {
	dir := test_repo(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	for name in ([?]string{"#hash.txt", "!bang.txt", "trail.txt", "space ", "crlf.txt"}) {
		test_write(test, dir, name, "x\n")
	}
	kept := [?]string{".gitignore", "# comment.txt", "space"}
	for name in kept {
		test_write(test, dir, name, "x\n")
	}
	test_write(test, dir, ".gitignore", "# comment.txt\n\n\\#hash.txt\n\\!bang.txt\ntrail.txt   \nspace\\ \ncrlf.txt\r\n")
	expect_files(test, dir, kept[:])
}

@(test)
test_nested_gitignore_overrides_parent :: proc(test: ^testing.T) {
	dir := test_repo(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	for name in ([?]string{"a.tmp", "sub/x.tmp", "sub/n.txt", "sub/deeper/n.txt"}) {
		test_write(test, dir, name, "x\n")
	}
	kept := [?]string{".gitignore", "sub/.gitignore", "sub/keep.tmp", "top.txt", "other/n.txt"}
	for name in kept {
		test_write(test, dir, name, "x\n")
	}
	test_write(test, dir, ".gitignore", "*.tmp\n")
	test_write(test, dir, "sub/.gitignore", "!keep.tmp\n*.txt\n")
	expect_files(test, dir, kept[:])
}

@(test)
test_git_info_exclude_applies_below_gitignore :: proc(test: ^testing.T) {
	dir := test_repo(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "secret.txt", "x\n")
	test_write(test, dir, "sub/secret.txt", "x\n")
	kept := [?]string{".gitignore", "shared.txt", "plain.txt"}
	for name in kept {
		test_write(test, dir, name, "x\n")
	}
	test_write(test, dir, ".git/info/exclude", "secret.txt\nshared.txt\n")
	test_write(test, dir, ".gitignore", "!shared.txt\n")
	expect_files(test, dir, kept[:])
}

@(test)
test_ancestor_ignore_files_apply_to_a_subdirectory_root :: proc(test: ^testing.T) {
	dir := test_repo(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	for name in ([?]string{"sub/pkg/a.log", "sub/pkg/excluded.txt"}) {
		test_write(test, dir, name, "x\n")
	}
	for name in ([?]string{"sub/pkg/keep.log", "sub/pkg/top.txt", "sub/pkg/b.txt"}) {
		test_write(test, dir, name, "x\n")
	}
	root, concat_error := strings.concatenate({dir, "/sub/pkg"}, context.allocator)
	if !testing.expect(test, concat_error == nil, "the root path is built") { return }
	defer delete(root, context.allocator)
	test_write(test, dir, ".gitignore", "*.log\n/top.txt\n")
	test_write(test, dir, ".git/info/exclude", "excluded.txt\n")
	test_write(test, dir, "sub/.gitignore", "!keep.log\n")
	expect_files(test, root, {"keep.log", "top.txt", "b.txt"})
}

@(test)
test_ignore_files_need_a_repository :: proc(test: ^testing.T) {
	dir := test_dir(test)
	if dir == "" { return }
	defer {
		os.remove_all(dir)
		delete(dir, context.allocator)
	}
	test_write(test, dir, "a.log", "x\n")
	test_write(test, dir, "proj/.jj/repo", "x\n")
	test_write(test, dir, "proj/b.out", "x\n")
	test_write(test, dir, "proj/c.log", "x\n")
	test_write(test, dir, ".gitignore", "*.log\n")
	test_write(test, dir, "proj/.gitignore", "*.out\n")
	expect_files(test, dir, {".gitignore", "a.log", "proj/.gitignore", "proj/c.log"})
}
