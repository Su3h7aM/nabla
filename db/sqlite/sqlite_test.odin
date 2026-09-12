#+test
#+private file
package sqlite

import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "nabla:db"

CONFIG :: Config {
	path         = ":memory:",
	foreign_keys = true,
}

_expect_ok :: proc(t: ^testing.T, err: db.Error) {
	if err != nil {
		testing.fail_now(t, message_of(err))
	}
}

message_of :: proc(err: db.Error) -> string {
	// error_message borrows the Error it is given, so it needs one that is
	// addressable and outlives the call. A parameter is neither.
	local := err
	return strings.concatenate({"unexpected error: ", db.error_message(&local)}, context.temp_allocator)
}

_expect_failure :: proc(t: ^testing.T, err: db.Error, kind: db.Error_Kind) {
	if err == nil {
		testing.expectf(t, false, "expected a %v failure, got none", kind)
		return
	}
	if actual := db.error_kind(err); actual != kind {
		local := err
		testing.expectf(t, false, "expected %v, got %v: %s", kind, actual, db.error_message(&local))
	}
}

_open :: proc(t: ^testing.T) -> db.Conn {
	conn: db.Conn
	_expect_ok(t, open(&conn, CONFIG))
	return conn
}

_temp_directory :: proc(t: ^testing.T) -> string {
	// An empty dir lets make_directory_temp choose the system temporary
	// directory itself, so nothing here owns that path.
	directory, err := os.make_directory_temp("", "nabla-db-test-*", context.allocator)
	if err != nil { testing.fail_now(t, "could not create a temporary directory") }
	return directory
}

_temp_database :: proc(directory: string) -> string {
	return strings.concatenate({directory, "/test.db"}, context.allocator)
}

@(test)
test_exec_and_query_round_trip :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT, turns INTEGER)"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO sessions VALUES (?, ?, ?)", {db.Value("a"), db.Value("first"), db.Value(3)}))
	_expect_ok(t, db.exec(&conn, "INSERT INTO sessions VALUES (?, ?, ?)", {db.Value("b"), db.Value("second"), db.Value(7)}))

	rows: db.Rows
	_expect_ok(t, db.query(&conn, &rows, "SELECT id, title, turns FROM sessions ORDER BY id"))
	defer db.rows_close(&rows)

	expected := [?]struct {
		id:    string,
		title: string,
		turns: i64,
	}{{"a", "first", 3}, {"b", "second", 7}}

	for want in expected {
		values, has_row, err := db.rows_next(&rows)
		_expect_ok(t, err)
		if !testing.expect(t, has_row, "expected another row") { return }

		id, _ := db.as_string(values[0])
		title, _ := db.as_string(values[1])
		turns, _ := db.as_i64(values[2])
		testing.expect_value(t, id, want.id)
		testing.expect_value(t, title, want.title)
		testing.expect_value(t, turns, want.turns)
	}

	_, has_row, err := db.rows_next(&rows)
	_expect_ok(t, err)
	testing.expect(t, !has_row, "the result set should be exhausted")
}

@(test)
test_null_and_empty_are_distinct :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (a TEXT, b BLOB)"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (NULL, NULL)"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (?, ?)", {db.Value(""), db.Value([]u8{})}))

	rows: db.Rows
	_expect_ok(t, db.query(&conn, &rows, "SELECT a, b FROM t"))
	defer db.rows_close(&rows)

	values, has_row, err := db.rows_next(&rows)
	_expect_ok(t, err)
	if !testing.expect(t, has_row, "expected a row") { return }
	testing.expect(t, values[0] == nil, "NULL text should read back as SQL NULL")
	testing.expect(t, values[1] == nil, "NULL blob should read back as SQL NULL")

	values, has_row, err = db.rows_next(&rows)
	_expect_ok(t, err)
	if !testing.expect(t, has_row, "expected a second row") { return }
	// An empty string and an empty blob are values; neither is NULL.
	testing.expect(t, values[0] != nil, "an empty string must not read back as NULL")
	testing.expect(t, values[1] != nil, "an empty blob must not read back as NULL")

	text, text_err := db.as_string(values[0])
	blob, blob_err := db.as_bytes(values[1])
	_expect_ok(t, text_err)
	_expect_ok(t, blob_err)
	testing.expect_value(t, len(text), 0)
	testing.expect_value(t, len(blob), 0)
}

@(test)
test_row_values_stay_valid_across_columns :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (a TEXT, b TEXT, c BLOB)"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (?, ?, ?)", {db.Value("first"), db.Value("second"), db.Value([]u8{1, 2, 3})}))

	rows: db.Rows
	_expect_ok(t, db.query(&conn, &rows, "SELECT a, b, c FROM t"))
	defer db.rows_close(&rows)

	values, has_row, err := db.rows_next(&rows)
	_expect_ok(t, err)
	if !testing.expect(t, has_row, "expected a row") { return }

	// Reading the later columns must not move the storage the earlier ones
	// point at, so read all three and only then look at them.
	first, _ := db.as_string(values[0])
	second, _ := db.as_string(values[1])
	blob, _ := db.as_bytes(values[2])
	testing.expect_value(t, first, "first")
	testing.expect_value(t, second, "second")
	testing.expect_value(t, len(blob), 3)
	testing.expect_value(t, blob[2], u8(3))
}

@(test)
test_prepared_statement_rebinds_every_execution :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (value INTEGER)"))

	stmt: db.Statement
	_expect_ok(t, db.prepare(&conn, &stmt, "INSERT INTO t VALUES (?)"))
	defer db.statement_close(&stmt)

	for value in ([?]i64{1, 2, 3}) {
		_expect_ok(t, db.statement_exec(&stmt, {db.Value(value)}))
	}

	rows: db.Rows
	_expect_ok(t, db.query(&conn, &rows, "SELECT sum(value), count(*) FROM t"))
	defer db.rows_close(&rows)

	values, has_row, err := db.rows_next(&rows)
	_expect_ok(t, err)
	if !testing.expect(t, has_row, "expected a row") { return }
	total, _ := db.as_i64(values[0])
	count, _ := db.as_i64(values[1])
	testing.expect_value(t, total, i64(6))
	testing.expect_value(t, count, i64(3))
}

@(test)
test_arity_is_checked_before_binding :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	stmt: db.Statement
	_expect_ok(t, db.prepare(&conn, &stmt, "SELECT ? + ?"))
	defer db.statement_close(&stmt)

	// A mismatch must not silently read the missing parameter as NULL.
	_expect_failure(t, db.statement_exec(&stmt, {db.Value(1)}), .Invalid_Argument)
	_expect_ok(t, db.statement_exec(&stmt, {db.Value(1), db.Value(2)}))
}

@(test)
test_one_statement_per_call :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	// SQLite compiles only the first statement and drops the rest, so the
	// backend refuses rather than run half of what was written.
	_expect_failure(t, db.exec(&conn, "SELECT 1; SELECT 2"), .Invalid_Argument)
	_expect_failure(t, db.exec(&conn, "CREATE TABLE t (a INTEGER); DROP TABLE t"), .Invalid_Argument)
	_expect_failure(t, db.exec(&conn, ""), .Invalid_Argument)
	_expect_failure(t, db.exec(&conn, "-- nothing here"), .Invalid_Argument)

	_expect_ok(t, db.exec(&conn, "SELECT 1"))
	_expect_ok(t, db.exec(&conn, "SELECT 1;"))
	_expect_ok(t, db.exec(&conn, "  SELECT 1 ; \n\t"))
	_expect_ok(t, db.exec(&conn, "SELECT 1\n"))
}

@(test)
test_sql_can_contain_a_semicolon_inside_a_literal :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	// The terminator check looks past the compiled statement, not for a ';',
	// so a semicolon inside a string is part of the statement.
	rows: db.Rows
	_expect_ok(t, db.query(&conn, &rows, "SELECT ';'"))
	defer db.rows_close(&rows)

	values, has_row, err := db.rows_next(&rows)
	_expect_ok(t, err)
	if !testing.expect(t, has_row, "expected a row") { return }
	text, _ := db.as_string(values[0])
	testing.expect_value(t, text, ";")
}

@(test)
test_transaction_commit_and_rollback :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (value INTEGER)"))

	_expect_ok(t, db.begin(&conn))
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (1)"))
	_expect_ok(t, db.rollback(&conn))

	_expect_ok(t, db.begin(&conn))
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (2)"))
	_expect_ok(t, db.commit(&conn))

	// A rollback with nothing open is what a deferred rollback does.
	_expect_ok(t, db.rollback(&conn))

	rows: db.Rows
	_expect_ok(t, db.query(&conn, &rows, "SELECT value FROM t"))
	defer db.rows_close(&rows)

	values, has_row, err := db.rows_next(&rows)
	_expect_ok(t, err)
	if !testing.expect(t, has_row, "expected a row") { return }
	value, _ := db.as_i64(values[0])
	testing.expect_value(t, value, i64(2))

	_, has_row, err = db.rows_next(&rows)
	_expect_ok(t, err)
	testing.expect(t, !has_row, "the rolled-back row should be gone")
}

@(test)
test_transaction_misuse_is_refused :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_failure(t, db.commit(&conn), .Invalid_State)

	_expect_ok(t, db.begin(&conn))
	defer db.rollback(&conn)
	_expect_failure(t, db.begin(&conn), .Invalid_State)
}

@(test)
test_result_set_holds_the_connection :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (value INTEGER)"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (1)"))

	rows: db.Rows
	_expect_ok(t, db.query(&conn, &rows, "SELECT value FROM t"))

	// One thing at a time: the connection belongs to the open result set.
	_expect_failure(t, db.exec(&conn, "SELECT 1"), .Invalid_State)
	_expect_failure(t, db.begin(&conn), .Invalid_State)
	_expect_failure(t, db.close(&conn), .Invalid_State)

	_expect_ok(t, db.rows_close(&rows))
	_expect_ok(t, db.exec(&conn, "SELECT 1"))
}

@(test)
test_statement_holds_the_connection :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	stmt: db.Statement
	_expect_ok(t, db.prepare(&conn, &stmt, "SELECT 1"))

	// A live statement points into the connection's state, so the connection
	// will not free it from under the statement.
	_expect_failure(t, db.close(&conn), .Invalid_State)

	_expect_ok(t, db.statement_close(&stmt))
	_expect_ok(t, db.close(&conn))
}

@(test)
test_a_locked_database_reports_busy :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer delete(directory)
	defer os.remove_all(directory)
	path := _temp_database(directory)
	defer delete(path)

	first: db.Conn
	_expect_ok(t, open(&first, {path = path}))
	defer db.close(&first)

	second: db.Conn
	_expect_ok(t, open(&second, {path = path}))
	defer db.close(&second)

	_expect_ok(t, db.exec(&first, "CREATE TABLE t (value INTEGER)"))

	// BEGIN is deferred, so the write lock arrives with the INSERT and stays
	// until the transaction ends.
	_expect_ok(t, db.begin(&first))
	_expect_ok(t, db.exec(&first, "INSERT INTO t VALUES (1)"))

	// No busy timeout on the second connection, so it fails at once instead of
	// waiting for a lock the first connection will not release yet.
	_expect_failure(t, db.exec(&second, "INSERT INTO t VALUES (2)"), .Busy)

	_expect_ok(t, db.rollback(&first))
	_expect_ok(t, db.exec(&second, "INSERT INTO t VALUES (2)"))
}

@(test)
test_constraint_failures_are_classified :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (1, 1)"))

	_expect_failure(t, db.exec(&conn, "INSERT INTO t VALUES (1, 1)"), .Constraint)
	_expect_failure(t, db.exec(&conn, "INSERT INTO t VALUES (2, NULL)"), .Constraint)
	_expect_failure(t, db.exec(&conn, "INSERT INTO t (nope) VALUES (1)"), .Backend)
}

@(test)
test_foreign_keys_are_enforced_when_requested :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE parent (id INTEGER PRIMARY KEY)"))
	_expect_ok(t, db.exec(&conn, "CREATE TABLE child (id INTEGER REFERENCES parent(id))"))

	_expect_failure(t, db.exec(&conn, "INSERT INTO child VALUES (1)"), .Constraint)
	_expect_ok(t, db.exec(&conn, "INSERT INTO parent VALUES (1)"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO child VALUES (1)"))
}

@(test)
test_foreign_keys_stay_off_by_default :: proc(t: ^testing.T) {
	conn: db.Conn
	_expect_ok(t, open(&conn, {path = ":memory:"}))
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE parent (id INTEGER PRIMARY KEY)"))
	_expect_ok(t, db.exec(&conn, "CREATE TABLE child (id INTEGER REFERENCES parent(id))"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO child VALUES (1)"))
}

@(test)
test_every_allocation_is_returned :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	ambient := context.allocator
	defer context.allocator = ambient
	context.allocator = mem.tracking_allocator(&track)

	conn: db.Conn
	_expect_ok(t, open(&conn, CONFIG))

	// A second open on the same connection has to release the handle and state
	// it built, which the leak check below proves it did.
	if err := open(&conn, CONFIG); err == nil {
		testing.fail_now(t, "opening an open connection should be refused")
	}

	stmt: db.Statement
	_expect_ok(t, db.prepare(&conn, &stmt, "SELECT ?"))

	rows: db.Rows
	_expect_ok(t, db.statement_query(&stmt, &rows, {db.Value(1)}))
	if _, _, err := db.rows_next(&rows); err != nil { testing.fail_now(t, "unexpected error") }
	_expect_ok(t, db.rows_close(&rows))
	_expect_ok(t, db.statement_close(&stmt))
	_expect_ok(t, db.close(&conn))

	for _, entry in track.allocation_map {
		testing.expectf(t, false, "leaked %d bytes allocated at %v", entry.size, entry.location)
	}
}

@(test)
test_walking_a_result_set_frees_the_connection :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (value INTEGER)"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (1)"))

	rows: db.Rows
	_expect_ok(t, db.query(&conn, &rows, "SELECT value FROM t"))
	for {
		_, has_row, err := db.rows_next(&rows)
		_expect_ok(t, err)
		if !has_row { break }
	}

	// The end of the set returned the connection, so the next statement runs
	// without anything being closed first.
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (2)"))

	testing.expect_value(t, _count(&conn), i64(2))

	// And a set that already ended closes without touching the statement again.
	_expect_ok(t, db.rows_close(&rows))
}

@(test)
test_stopping_short_of_the_end_frees_the_connection :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (value INTEGER)"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (1), (2), (3)"))

	rows: db.Rows
	_expect_ok(t, db.query(&conn, &rows, "SELECT value FROM t"))
	_, has_row, err := db.rows_next(&rows)
	_expect_ok(t, err)
	testing.expect(t, has_row, "expected a row")

	// One row out of three, then a close: the reset has to leave the statement
	// and the connection usable.
	_expect_ok(t, db.rows_close(&rows))
	_expect_ok(t, db.exec(&conn, "SELECT 1"))

	// The same for a borrowed statement, which has to stay prepared.
	stmt: db.Statement
	_expect_ok(t, db.prepare(&conn, &stmt, "SELECT value FROM t"))
	defer db.statement_close(&stmt)

	for _ in 0 ..< 2 {
		_expect_ok(t, db.statement_query(&stmt, &rows))
		_, _, row_err := db.rows_next(&rows)
		_expect_ok(t, row_err)
		_expect_ok(t, db.rows_close(&rows))
	}
}

@(test)
test_text_and_blobs_round_trip_byte_for_byte :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (a TEXT, b BLOB)"))

	// Every binding carries a length, so an embedded NUL survives and a blob is
	// never read as text.
	text := "h\u00e9llo\x00world"
	blob: [1024]u8
	for i in 0 ..< len(blob) { blob[i] = u8(i % 256) }

	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (?, ?)", {db.Value(text), db.Value(blob[:])}))

	rows: db.Rows
	_expect_ok(t, db.query(&conn, &rows, "SELECT a, b FROM t"))
	defer db.rows_close(&rows)

	values, has_row, err := db.rows_next(&rows)
	_expect_ok(t, err)
	if !testing.expect(t, has_row, "expected a row") { return }

	got_text, text_err := db.as_string(values[0])
	got_blob, blob_err := db.as_bytes(values[1])
	_expect_ok(t, text_err)
	_expect_ok(t, blob_err)
	testing.expect_value(t, got_text, text)
	testing.expect_value(t, len(got_blob), len(blob))
	testing.expect(t, slice.equal(got_blob, blob[:]), "the blob should come back unchanged")
}

@(test)
test_a_statement_survives_a_rejected_row :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (id INTEGER PRIMARY KEY)"))

	stmt: db.Statement
	_expect_ok(t, db.prepare(&conn, &stmt, "INSERT INTO t VALUES (?)"))
	defer db.statement_close(&stmt)

	_expect_ok(t, db.statement_exec(&stmt, {db.Value(i64(1))}))

	// A failed step leaves the statement owing a reset, which the drain does
	// before it reports. Reusing it afterwards is the whole point of preparing.
	_expect_failure(t, db.statement_exec(&stmt, {db.Value(i64(1))}), .Constraint)
	_expect_ok(t, db.statement_exec(&stmt, {db.Value(i64(2))}))

	// One rejected row does not end the transaction it was written in.
	_expect_ok(t, db.begin(&conn))
	defer db.rollback(&conn)

	_expect_failure(t, db.statement_exec(&stmt, {db.Value(i64(2))}), .Constraint)
	_expect_ok(t, db.statement_exec(&stmt, {db.Value(i64(3))}))
}

@(test)
test_a_connection_can_be_closed_and_opened_again :: proc(t: ^testing.T) {
	conn: db.Conn
	_expect_ok(t, open(&conn, CONFIG))
	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (value INTEGER)"))
	_expect_ok(t, db.close(&conn))

	// close cleared the handle, so the same Conn can hold a new connection.
	// This one is a fresh in-memory database, which is why the table is gone.
	_expect_ok(t, open(&conn, CONFIG))
	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (value INTEGER)"))
	_expect_ok(t, db.close(&conn))

	// Releasing a released connection is still nothing to do.
	_expect_ok(t, db.close(&conn))
}

@(test)
test_another_connection_sees_only_committed_work :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer delete(directory)
	defer os.remove_all(directory)
	path := _temp_database(directory)
	defer delete(path)

	writer: db.Conn
	_expect_ok(t, open(&writer, {path = path}))
	defer db.close(&writer)

	reader: db.Conn
	_expect_ok(t, open(&reader, {path = path}))
	defer db.close(&reader)

	_expect_ok(t, db.exec(&writer, "CREATE TABLE t (value INTEGER)"))

	_expect_ok(t, db.begin(&writer))
	_expect_ok(t, db.exec(&writer, "INSERT INTO t VALUES (1)"))

	// The other connection reads the table it can see, which does not include
	// a transaction that has not committed yet.
	testing.expect_value(t, _count(&reader), i64(0))

	_expect_ok(t, db.commit(&writer))
	testing.expect_value(t, _count(&reader), i64(1))
}

// _count returns the one integer a count of the table produces, or -1 when the
// query did not produce one. It is a test-local reading of one column, and it
// closes its result set: leaving one open would hold a read transaction, which
// stops another connection from committing.
_count :: proc(conn: ^db.Conn) -> i64 {
	rows: db.Rows
	if db.query(conn, &rows, "SELECT count(*) FROM t") != nil { return -1 }
	defer db.rows_close(&rows)

	values, has_row, err := db.rows_next(&rows)
	if err != nil || !has_row { return -1 }
	count, _ := db.as_i64(values[0])
	return count
}
