#+test
package session

// Helpers shared by this package's test files. They are package-private rather
// than file-private so every suite can use one definition, and the file only
// compiles under `odin test`.

import "core:os"
import "core:strings"
import "core:testing"

import "nabla:db"

@(private)
_expect_ok :: proc(t: ^testing.T, err: Error) {
	if err == nil { return }
	local := err
	testing.fail_now(t, strings.concatenate({"unexpected error: ", error_detail(&local)}, context.temp_allocator))
}

@(private)
_expect_error :: proc(t: ^testing.T, err: Error, kind: Error_Kind) {
	if err == nil {
		testing.expectf(t, false, "expected a %v failure, got none", kind)
		return
	}
	if actual := error_kind(err); actual != kind {
		local := err
		testing.expectf(t, false, "expected %v, got %v: %s", kind, actual, error_detail(&local))
	}
}

@(private)
_expect_db_ok :: proc(t: ^testing.T, err: db.Error) {
	if err != nil {
		local := err
		testing.fail_now(t, strings.concatenate({"unexpected database error: ", db.error_message(&local)}, context.temp_allocator))
	}
}

@(private)
_temp_directory :: proc(t: ^testing.T) -> string {
	directory, err := os.make_directory_temp("", "nabla-session-test-*", context.allocator)
	if err != nil { testing.fail_now(t, "could not create a temporary directory") }
	return directory
}

@(private)
_open_store :: proc(t: ^testing.T, store: ^Store) -> string {
	directory := _temp_directory(t)
	_expect_ok(t, store_open(store, directory))
	return directory
}

@(private)
_close_store :: proc(store: ^Store, directory: string) {
	store_close(store)
	os.remove_all(directory)
	delete(directory, context.allocator)
}
