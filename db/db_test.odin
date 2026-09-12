#+test
#+private file
package db

import "core:mem"
import "core:testing"

// The lifecycle rules live in this package, not in a backend, so they are
// tested against a backend that does nothing but record what it was asked to
// do. A failure can be injected into any call, which is how the cleanup and
// error-precedence paths get covered without a database.

Fake_Calls :: struct {
	close:    int,
	prepare:  int,
	finalize: int,
	execute:  int,
	next:     int,
	finish:   int,
	begin:    int,
	commit:   int,
	rollback: int,
}

Fake_Conn :: struct {
	calls:         ^Fake_Calls,

	// An injected failure is returned by the matching call and cleared by the
	// test. Keeping this per-connection is what lets the tests run in parallel.
	fail_close:    Error,
	fail_prepare:  Error,
	fail_execute:  Error,
	fail_next:     Error,
	fail_finish:   Error,
	fail_begin:    Error,
	fail_commit:   Error,
	fail_rollback: Error,
}

Fake_Stmt :: struct {
	calls:      ^Fake_Calls,
	conn:       ^Fake_Conn,
	parameters: int,
	columns:    int,
	row:        int,
}

fake_rows := [][]Value{{Value(i64(1)), Value("first")}, {Value(i64(2)), Value("second")}}

FAKE_DRIVER: Driver = {
	close            = fake_close,
	prepare          = fake_prepare,
	finalize         = fake_finalize,
	execute          = fake_execute,
	next             = fake_next,
	execution_finish = fake_finish,
	begin            = fake_begin,
	commit           = fake_commit,
	rollback         = fake_rollback,
}

fake_close :: proc(state: rawptr) -> Error {
	conn := cast(^Fake_Conn)state
	conn.calls.close += 1
	if conn.fail_close != nil { return conn.fail_close }
	free(conn)
	return nil
}

fake_prepare :: proc(state: rawptr, sql: string) -> (rawptr, Error) {
	conn := cast(^Fake_Conn)state
	conn.calls.prepare += 1
	if conn.fail_prepare != nil { return nil, conn.fail_prepare }

	stmt := new(Fake_Stmt)
	stmt^ = Fake_Stmt {
		calls      = conn.calls,
		conn       = conn,
		parameters = 0,
		columns    = 2,
	}
	return rawptr(stmt), nil
}

fake_finalize :: proc(state: rawptr) {
	stmt := cast(^Fake_Stmt)state
	stmt.calls.finalize += 1
	free(stmt)
}

fake_execute :: proc(state: rawptr, args: []Value) -> (rawptr, int, Error) {
	stmt := cast(^Fake_Stmt)state
	stmt.calls.execute += 1
	if stmt.conn.fail_execute != nil { return nil, 0, stmt.conn.fail_execute }
	if len(args) != stmt.parameters {
		return nil, 0, error_make(.Invalid_Argument, 0, "wrong number of parameters")
	}
	return rawptr(stmt), stmt.columns, nil
}

fake_next :: proc(state: rawptr, values: []Value) -> (bool, Error) {
	stmt := cast(^Fake_Stmt)state
	stmt.calls.next += 1
	if stmt.conn.fail_next != nil { return false, stmt.conn.fail_next }
	if stmt.row >= len(fake_rows) { return false, nil }

	for _, i in values {
		values[i] = fake_rows[stmt.row][i]
	}
	stmt.row += 1
	return true, nil
}

fake_finish :: proc(state: rawptr) -> Error {
	stmt := cast(^Fake_Stmt)state
	stmt.calls.finish += 1
	stmt.row = 0
	return stmt.conn.fail_finish
}

fake_begin :: proc(state: rawptr) -> Error {
	conn := cast(^Fake_Conn)state
	conn.calls.begin += 1
	return conn.fail_begin
}

fake_commit :: proc(state: rawptr) -> Error {
	conn := cast(^Fake_Conn)state
	conn.calls.commit += 1
	return conn.fail_commit
}

fake_rollback :: proc(state: rawptr) -> Error {
	conn := cast(^Fake_Conn)state
	conn.calls.rollback += 1
	return conn.fail_rollback
}

_expect_ok :: proc(t: ^testing.T, err: Error) {
	if err != nil {
		local := err
		testing.fail_now(t, error_message(&local))
	}
}

_fake_open :: proc(conn: ^Conn, calls: ^Fake_Calls) -> ^Fake_Conn {
	fake := new(Fake_Conn)
	fake.calls = calls
	assert(conn_init(conn, &FAKE_DRIVER, fake, context.allocator) == nil, "the test handed conn_init an open connection")
	return fake
}

@(test)
test_opening_an_already_open_connection_is_refused :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	_fake_open(&conn, &calls)
	defer close(&conn)

	// The caller of conn_init keeps ownership of the state it passed, so a
	// refused open is the backend's to clean up, not a silent overwrite.
	spare: Fake_Conn
	testing.expect_value(t, error_kind(conn_init(&conn, &FAKE_DRIVER, &spare, context.allocator)), Error_Kind.Invalid_State)
	testing.expect_value(t, calls.close, 0)
	testing.expect_value(t, calls.prepare, 0)
}

@(test)
test_zero_handles_are_already_closed :: proc(t: ^testing.T) {
	// Zero is initialization: an unopened handle is a closed handle, and
	// releasing it does nothing rather than reaching for null state.
	conn: Conn
	stmt: Statement
	rows: Rows
	testing.expect_value(t, close(&conn), nil)
	testing.expect_value(t, statement_close(&stmt), nil)
	testing.expect_value(t, rows_close(&rows), nil)

	testing.expect_value(t, error_kind(exec(&conn, "SELECT 1")), Error_Kind.Invalid_State)
	testing.expect_value(t, error_kind(begin(&conn)), Error_Kind.Invalid_State)
	testing.expect_value(t, error_kind(prepare(&conn, &stmt, "SELECT 1")), Error_Kind.Invalid_State)
	testing.expect_value(t, error_kind(statement_exec(&stmt)), Error_Kind.Invalid_State)

	_, has_row, err := rows_next(&rows)
	testing.expect(t, !has_row, "a closed result set has no rows")
	testing.expect_value(t, error_kind(err), Error_Kind.Invalid_State)
}

@(test)
test_query_owns_the_statement_it_prepares :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	_fake_open(&conn, &calls)
	defer close(&conn)

	rows: Rows
	_expect_ok(t, query(&conn, &rows, "SELECT a, b"))
	testing.expect_value(t, calls.prepare, 1)

	values, has_row, err := rows_next(&rows)
	_expect_ok(t, err)
	testing.expect(t, has_row, "expected a row")
	testing.expect_value(t, len(values), 2)

	// query prepared a statement nobody else holds, so rows_close releases both
	// the execution and the statement, in that order.
	_expect_ok(t, rows_close(&rows))
	testing.expect_value(t, calls.finish, 1)
	testing.expect_value(t, calls.finalize, 1)
}

@(test)
test_statement_query_borrows_the_statement :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	_fake_open(&conn, &calls)
	defer close(&conn)

	stmt: Statement
	_expect_ok(t, prepare(&conn, &stmt, "SELECT a, b"))

	for _ in 0 ..< 2 {
		rows: Rows
		_expect_ok(t, statement_query(&stmt, &rows))
		_, _, _ = rows_next(&rows)
		_expect_ok(t, rows_close(&rows))
	}
	// The statement outlives both executions, so it was never finalized.
	testing.expect_value(t, calls.prepare, 1)
	testing.expect_value(t, calls.finish, 2)
	testing.expect_value(t, calls.finalize, 0)

	_expect_ok(t, statement_close(&stmt))
	testing.expect_value(t, calls.finalize, 1)
}

@(test)
test_rows_next_stops_at_the_end :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	_fake_open(&conn, &calls)
	defer close(&conn)

	rows: Rows
	_expect_ok(t, query(&conn, &rows, "SELECT a, b"))
	defer rows_close(&rows)

	seen := 0
	for {
		values, has_row, err := rows_next(&rows)
		_expect_ok(t, err)
		if !has_row { break }
		seen += 1
		index, _ := as_i64(values[0])
		testing.expect_value(t, index, i64(seen))
	}
	testing.expect_value(t, seen, len(fake_rows))

	// Reading past the end is a mistake, not a second execution: without the
	// guard, a backend that auto-resets would replay the statement.
	_, has_row, err := rows_next(&rows)
	testing.expect(t, !has_row, "an exhausted result set has no rows")
	testing.expect_value(t, error_kind(err), Error_Kind.Invalid_State)
	testing.expect_value(t, calls.next, len(fake_rows) + 1)
}

@(test)
test_an_execution_failure_wins_over_a_cleanup_failure :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	fake := _fake_open(&conn, &calls)
	defer close(&conn)

	fake.fail_next = error_make(.Busy, 5, "the statement is locked")
	fake.fail_finish = error_make(.Backend, 1, "the reset failed")

	err := exec(&conn, "SELECT a, b")
	testing.expect_value(t, error_kind(err), Error_Kind.Busy)

	// The cleanup failure is reported only when nothing earlier went wrong, but
	// the resources are released either way.
	testing.expect_value(t, calls.finish, 1)
	testing.expect_value(t, calls.finalize, 1)
}

@(test)
test_cleanup_failure_alone_is_reported :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	fake := _fake_open(&conn, &calls)
	defer close(&conn)

	fake.fail_finish = error_make(.Busy, 5, "the reset is locked")

	err := exec(&conn, "SELECT a, b")
	testing.expect_value(t, error_kind(err), Error_Kind.Busy)
	testing.expect_value(t, calls.finalize, 1)
}

@(test)
test_a_failed_query_leaves_nothing_open :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	fake := _fake_open(&conn, &calls)
	defer close(&conn)

	fake.fail_execute = error_make(.Constraint, 19, "no")

	rows: Rows
	testing.expect(t, query(&conn, &rows, "INSERT") != nil, "the query should have failed")
	// The statement prepared on the way to the failure was released, so the
	// connection is free for the next caller.
	testing.expect_value(t, calls.finalize, 1)

	fake.fail_execute = nil
	testing.expect_value(t, error_kind(exec(&conn, "SELECT a, b")), Error_Kind.None)
}

@(test)
test_a_closed_connection_is_not_touched_by_the_backend :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	_fake_open(&conn, &calls)

	_expect_ok(t, close(&conn))
	testing.expect_value(t, calls.close, 1)

	// Releasing an already-released connection must not call the backend twice.
	_expect_ok(t, close(&conn))
	testing.expect_value(t, calls.close, 1)
}

@(test)
test_transactions_reach_the_backend :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	fake := _fake_open(&conn, &calls)
	defer close(&conn)

	_expect_ok(t, begin(&conn))
	_expect_ok(t, commit(&conn))
	_expect_ok(t, rollback(&conn))
	testing.expect_value(t, calls.begin, 1)
	testing.expect_value(t, calls.commit, 1)
	testing.expect_value(t, calls.rollback, 1)

	// A failure from the backend is what the caller sees, unchanged.
	fake.fail_commit = error_make(.Busy, 5, "commit is locked")
	testing.expect_value(t, error_kind(commit(&conn)), Error_Kind.Busy)
}

@(test)
test_value_conversions_are_lossless_or_refused :: proc(t: ^testing.T) {
	integer, integer_err := as_i64(Value(i64(7)))
	_expect_ok(t, integer_err)
	testing.expect_value(t, integer, i64(7))

	whole, whole_err := as_i64(Value(f64(7)))
	_expect_ok(t, whole_err)
	testing.expect_value(t, whole, i64(7))

	truthy, truthy_err := as_bool(Value(i64(1)))
	_expect_ok(t, truthy_err)
	testing.expect(t, truthy, "1 should read as true")

	from_bool, from_bool_err := as_i64(Value(true))
	_expect_ok(t, from_bool_err)
	testing.expect_value(t, from_bool, i64(1))

	text, text_err := as_string(Value("hello"))
	_expect_ok(t, text_err)
	testing.expect_value(t, text, "hello")

	blob, blob_err := as_bytes(Value([]u8{1, 2}))
	_expect_ok(t, blob_err)
	testing.expect_value(t, len(blob), 2)

	// NULL is not a zero value in disguise.
	_, null_err := as_i64(Value(nil))
	testing.expect_value(t, error_kind(null_err), Error_Kind.Null_Value)
	_, null_text_err := as_string(Value(nil))
	testing.expect_value(t, error_kind(null_text_err), Error_Kind.Null_Value)

	// A fraction does not become a truncated integer.
	_, fraction_err := as_i64(Value(f64(1.5)))
	testing.expect_value(t, error_kind(fraction_err), Error_Kind.Out_Of_Range)

	// An integer too large for a float is refused rather than rounded.
	_, precision_err := as_f64(Value(i64(1) << 53 + 1))
	testing.expect_value(t, error_kind(precision_err), Error_Kind.Out_Of_Range)

	// Text and blobs are not numbers, and neither is interchangeable with the
	// other.
	_, number_err := as_i64(Value("7"))
	testing.expect_value(t, error_kind(number_err), Error_Kind.Type_Mismatch)
	_, mismatch_err := as_string(Value([]u8{'a'}))
	testing.expect_value(t, error_kind(mismatch_err), Error_Kind.Type_Mismatch)
	_, boolean_err := as_bool(Value(i64(2)))
	testing.expect_value(t, error_kind(boolean_err), Error_Kind.Out_Of_Range)
}

@(test)
test_errors_carry_their_message_without_owning_memory :: proc(t: ^testing.T) {
	err := error_make(.Constraint, 2067, "UNIQUE constraint failed: sessions.id")

	testing.expect_value(t, error_kind(err), Error_Kind.Constraint)
	failure, ok := err.(Failure)
	testing.expect(t, ok, "an error of this package is always a Failure")
	testing.expect_value(t, failure.code, i32(2067))
	testing.expect_value(t, error_message(&err), "UNIQUE constraint failed: sessions.id")
	testing.expect(t, !failure.truncated, "a short message is not truncated")

	// The message lives inside the error, so it survives whatever produced it.
	copied := err
	testing.expect_value(t, error_message(&copied), "UNIQUE constraint failed: sessions.id")
}

@(test)
test_a_long_message_is_cut_short_and_marked :: proc(t: ^testing.T) {
	long: [MAX_ERROR_MESSAGE + 64]u8
	for i in 0 ..< len(long) { long[i] = 'x' }

	err := error_make(.Backend, 1, string(long[:]))
	failure, _ := err.(Failure)
	testing.expect(t, failure.truncated, "a message past the buffer must be marked")
	testing.expect_value(t, len(error_message(&err)), MAX_ERROR_MESSAGE)
}

@(test)
test_the_end_of_a_result_set_frees_the_connection :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	_fake_open(&conn, &calls)
	defer close(&conn)

	rows: Rows
	_expect_ok(t, query(&conn, &rows, "SELECT a, b"))

	seen := 0
	for {
		_, has_row, err := rows_next(&rows)
		_expect_ok(t, err)
		if !has_row { break }
		seen += 1
	}
	testing.expect_value(t, seen, len(fake_rows))

	// The set gave back everything it held on the way out: the execution and
	// the statement it owns. Nothing is left for rows_close to do.
	testing.expect_value(t, calls.finish, 1)
	testing.expect_value(t, calls.finalize, 1)

	finished := calls.finish
	finalized := calls.finalize
	_expect_ok(t, exec(&conn, "SELECT a, b"))
	testing.expect_value(t, calls.finish, finished + 1)
	testing.expect_value(t, calls.finalize, finalized + 1)

	// rows_close on a set that already ended does nothing at all.
	finished = calls.finish
	finalized = calls.finalize
	_expect_ok(t, rows_close(&rows))
	testing.expect_value(t, calls.finish, finished)
	testing.expect_value(t, calls.finalize, finalized)
}

@(test)
test_a_finished_result_set_can_hold_the_next_one :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	_fake_open(&conn, &calls)
	defer close(&conn)

	rows: Rows
	_expect_ok(t, query(&conn, &rows, "SELECT a, b"))
	for {
		_, has_row, err := rows_next(&rows)
		_expect_ok(t, err)
		if !has_row { break }
	}

	// A set that reached its end holds nothing, so the same Rows is closed as
	// far as query is concerned.
	_expect_ok(t, query(&conn, &rows, "SELECT a, b"))
	_, has_row, err := rows_next(&rows)
	_expect_ok(t, err)
	testing.expect(t, has_row, "expected the second query to produce a row")

	_expect_ok(t, rows_close(&rows))
	testing.expect_value(t, calls.finalize, 2)
}

@(test)
test_a_row_failure_ends_the_set_and_frees_the_connection :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	fake := _fake_open(&conn, &calls)
	defer close(&conn)

	fake.fail_next = error_make(.Busy, 5, "the row could not be read")

	rows: Rows
	_expect_ok(t, query(&conn, &rows, "SELECT a, b"))

	_, has_row, err := rows_next(&rows)
	testing.expect(t, !has_row, "a failed row is not a row")
	testing.expect_value(t, error_kind(err), Error_Kind.Busy)

	// Failing is still an end: the execution and the owned statement are gone,
	// so the connection is free even though nothing was closed.
	testing.expect_value(t, calls.finish, 1)
	testing.expect_value(t, calls.finalize, 1)
	_expect_ok(t, begin(&conn))
	_expect_ok(t, rollback(&conn))
}

@(test)
test_a_borrowed_statement_survives_a_failed_set :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	fake := _fake_open(&conn, &calls)
	defer close(&conn)

	stmt: Statement
	_expect_ok(t, prepare(&conn, &stmt, "SELECT a, b"))
	defer statement_close(&stmt)

	fake.fail_next = error_make(.Busy, 5, "the row could not be read")

	rows: Rows
	_expect_ok(t, statement_query(&stmt, &rows))
	_, _, err := rows_next(&rows)
	testing.expect_value(t, error_kind(err), Error_Kind.Busy)
	testing.expect_value(t, calls.finalize, 0)

	// The statement belongs to the caller, so a set that failed leaves it
	// prepared rather than releasing it.
	fake.fail_next = nil
	_expect_ok(t, statement_query(&stmt, &rows))
	_, has_row, row_err := rows_next(&rows)
	_expect_ok(t, row_err)
	testing.expect(t, has_row, "the statement should run again")
	_expect_ok(t, rows_close(&rows))
	testing.expect_value(t, calls.finalize, 0)
}

@(test)
test_preparing_over_a_live_statement_is_refused :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	_fake_open(&conn, &calls)
	defer close(&conn)

	stmt: Statement
	_expect_ok(t, prepare(&conn, &stmt, "SELECT 1"))
	testing.expect_value(t, calls.prepare, 1)

	// Preparing over a live statement would leak the state behind it and leave
	// the connection's list pointing at the old one.
	testing.expect_value(t, error_kind(prepare(&conn, &stmt, "SELECT 2")), Error_Kind.Invalid_State)
	testing.expect_value(t, calls.prepare, 1)

	_expect_ok(t, statement_close(&stmt))
	_expect_ok(t, prepare(&conn, &stmt, "SELECT 2"))
	testing.expect_value(t, calls.prepare, 2)
	_expect_ok(t, statement_close(&stmt))
}

@(test)
test_a_live_result_set_is_not_overwritten :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	_fake_open(&conn, &calls)
	defer close(&conn)

	rows: Rows
	_expect_ok(t, query(&conn, &rows, "SELECT a, b"))
	testing.expect_value(t, calls.prepare, 1)

	// Overwriting would strand the first set's statement and row buffer, so the
	// second query never reaches the backend.
	testing.expect_value(t, error_kind(query(&conn, &rows, "SELECT a, b")), Error_Kind.Invalid_State)
	testing.expect_value(t, calls.prepare, 1)

	_expect_ok(t, rows_close(&rows))
	_expect_ok(t, query(&conn, &rows, "SELECT a, b"))
	testing.expect_value(t, calls.prepare, 2)
	_expect_ok(t, rows_close(&rows))
}

@(test)
test_a_statement_is_not_queried_over_a_live_result_set :: proc(t: ^testing.T) {
	calls: Fake_Calls
	conn: Conn
	_fake_open(&conn, &calls)
	defer close(&conn)

	stmt: Statement
	_expect_ok(t, prepare(&conn, &stmt, "SELECT a, b"))
	defer statement_close(&stmt)

	rows: Rows
	_expect_ok(t, statement_query(&stmt, &rows))

	// The connection is busy, and the output object is taken. Either refusal
	// leaves the set that is running untouched.
	testing.expect_value(t, error_kind(statement_query(&stmt, &rows)), Error_Kind.Invalid_State)
	testing.expect_value(t, calls.execute, 1)

	other: Rows
	testing.expect_value(t, error_kind(statement_query(&stmt, &other)), Error_Kind.Invalid_State)
	testing.expect_value(t, calls.execute, 1)

	_expect_ok(t, rows_close(&rows))
	_expect_ok(t, statement_query(&stmt, &other))
	_expect_ok(t, rows_close(&other))
}

@(test)
test_the_lifecycle_frees_every_allocation_exactly_once :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	ambient := context.allocator
	defer context.allocator = ambient
	context.allocator = mem.tracking_allocator(&track)

	calls: Fake_Calls
	conn: Conn
	_fake_open(&conn, &calls)

	stmt: Statement
	_expect_ok(t, prepare(&conn, &stmt, "SELECT a, b"))

	// A borrowed statement outlives the set that runs on it, so the set has to
	// release the execution without releasing the statement.
	rows: Rows
	_expect_ok(t, statement_query(&stmt, &rows))
	for {
		_, has_row, err := rows_next(&rows)
		_expect_ok(t, err)
		if !has_row { break }
	}
	_expect_ok(t, statement_close(&stmt))

	// A set that query compiled owns its statement, so stopping short has to
	// release both.
	owned: Rows
	_expect_ok(t, query(&conn, &owned, "SELECT a, b"))
	_, _, _ = rows_next(&owned)
	_expect_ok(t, rows_close(&owned))

	_expect_ok(t, close(&conn))

	// Freeing backend state twice panics inside the tracking allocator, so
	// reaching this point already means every release ran once. What is left to
	// check is that none of them was skipped.
	for _, entry in track.allocation_map {
		testing.expectf(t, false, "leaked %d bytes allocated at %v", entry.size, entry.location)
	}
}
