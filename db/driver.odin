package db

// Driver is the procedure table a backend implements. This package never names
// a backend type: it holds the table and an opaque state pointer, the same
// shape as core:mem's Allocator.
//
// The layer is synchronous and single-owner. The db package guarantees that a
// connection is idle before it calls prepare, execute, begin, commit, or
// rollback, so a backend never has to defend against reentrancy or a second
// result set. Every state pointer is one the backend produced and still owns.
//
// A backend reports failure with error_make. It may assume the caller checks
// every error and closes what it opened.
Driver :: struct {
	// close releases the connection and everything the backend allocated for
	// it. On failure the state stays valid and the call may be retried.
	close:            proc(state: rawptr) -> Error,

	// prepare compiles sql for the connection. sql is non-empty, holds no NUL
	// byte, and contains exactly one statement: a backend must reject a second
	// one rather than run the first and discard the rest.
	prepare:          proc(conn: rawptr, sql: string) -> (stmt: rawptr, err: Error),

	// finalize releases a prepared statement, whether or not it was executed.
	// It reports nothing: a final failure was already returned by execute,
	// next, or execution_finish.
	finalize:         proc(stmt: rawptr),

	// execute binds args and starts one execution of stmt. args are borrowed
	// for the duration of the call; a backend must copy or consume them before
	// returning. columns is how many columns the execution yields.
	execute:          proc(stmt: rawptr, args: []Value) -> (rows: rawptr, columns: int, err: Error),

	// next advances the execution to its following row and fills values, which
	// is exactly columns long. It reports false with a nil error at a clean
	// end, and false with an error when the statement failed. An empty values
	// slice means the caller does not want the row, which is how exec avoids
	// materializing anything.
	next:             proc(rows: rawptr, values: []Value) -> (has_row: bool, err: Error),

	// execution_finish ends the execution and returns the statement to its
	// prepared state, releasing any implicit transaction it left open.
	execution_finish: proc(rows: rawptr) -> Error,

	// begin starts a transaction. It fails when one is already open, because
	// SQL transactions do not nest.
	begin:            proc(conn: rawptr) -> Error,

	// commit ends the open transaction. It fails when none is open.
	commit:           proc(conn: rawptr) -> Error,

	// rollback discards the open transaction. Rolling back with none open
	// succeeds, so a deferred rollback needs no state of its own.
	rollback:         proc(conn: rawptr) -> Error,
}
