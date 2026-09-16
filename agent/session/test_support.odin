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

// _open_claimed_session creates a session and takes its writer claim, which is
// the state every history suite starts from.
@(private)
_open_claimed_session :: proc(t: ^testing.T, store: ^Store) -> Session {
	session, create_err := session_create(store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, create_err)
	_expect_ok(t, session_claim(store, session.id))
	return session
}

// _expect_os_ok checks a filesystem call a test needs to set up its own state.
// It is separate from _expect_ok because os.Error and session.Error are
// distinct types and neither converts to the other.
@(private)
_expect_os_ok :: proc(t: ^testing.T, err: os.Error) {
	if err != nil { testing.fail_now(t, strings.concatenate({"unexpected filesystem error: ", os.error_string(err)}, context.temp_allocator)) }
}
