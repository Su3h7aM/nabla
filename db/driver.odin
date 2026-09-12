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
// finalize is the exception: the statement an execution was running on is
// released while that execution is still the active one, because releasing it is
// what ends the execution. It is the last call a backend sees for a statement.
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
	// It reports nothing, so a backend whose finalize can fail has to surface
	// that through execute, next, or execution_finish instead: this package
	// promises a caller that an error seen on one of those calls is the whole
	// story, and it discards whatever finalize would have said. SQLite keeps
	// that promise by always resetting through execution_finish first.
	finalize:         proc(stmt: rawptr),

	// execute binds args to stmt and starts one execution of it. args are
	// borrowed for the duration of the call; a backend must copy or consume
	// them before returning. The returned state is what columns, next, row,
	// and execution_finish run on.
	//
	// A wrong argument count or a value the statement cannot take is reported
	// here rather than left for the first call to next.
	execute:          proc(stmt: rawptr, args: []Value) -> (rows: rawptr, err: Error),

	// columns reports how many columns the execution yields. It is read after
	// the first next has stepped, because a backend may only settle on the
	// result's shape while stepping: SQLite recompiles a statement against a
	// changed schema on its first step, and a count taken before that is the
	// shape of the schema the statement was prepared under.
	columns:          proc(rows: rawptr) -> int,

	// next steps the execution to its following row. It reports false with a
	// nil error at a clean end, and false with an error when the statement
	// failed. It fills nothing.
	next:             proc(rows: rawptr) -> (has_row: bool, err: Error),

	// row copies the row the execution is stopped on into values, which is as
	// long as columns reported for this execution. It runs only for rows a
	// caller asked for, so an execution whose rows are discarded never pays
	// for reading them.
	//
	// Each value is written in the column's own storage class rather than
	// converted, so a value's as_* conversions are the only place a type is
	// decided. A string or blob written here stays borrowed until the next row
	// or the end of the execution.
	row:              proc(rows: rawptr, values: []Value) -> Error,

	// execution_finish ends the execution and returns the statement to its
	// prepared state, releasing any implicit transaction it left open. It is
	// called after the last row, after a failure, and when a caller stops
	// early, so a backend must leave the statement reusable and report any
	// failure it could not report earlier.
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
