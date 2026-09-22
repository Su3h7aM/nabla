#+test
#+private
package sqlite

import "base:runtime"

import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "nabla:db"


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
test_a_refused_open_leaves_no_database_behind :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer delete(directory)
	defer os.remove_all(directory)
	path := _temp_database(directory)
	defer delete(path)

	conn := _open(t)
	defer db.close(&conn)

	// The refusal happens before SQLite sees the path, so the file a refused
	// open would have created is still not there.
	_expect_failure(t, open(&conn, {path = path}), .Invalid_State)
	testing.expect(t, !os.exists(path), "a refused open must not create the file")
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

@(test)
test_numeric_extremes_round_trip :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (v)"))

	integers := [?]i64{math.min(i64), math.max(i64), -1, 0}
	floats := [?]f64{math.max(f64), math.min(f64), math.inf_f64(1), math.inf_f64(-1), 0.5}
	for value in integers { _expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (?)", {db.Value(value)})) }
	for value in floats { _expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (?)", {db.Value(value)})) }

	rows: db.Rows
	_expect_ok(t, db.query(&conn, &rows, "SELECT v FROM t ORDER BY rowid"))
	defer db.rows_close(&rows)

	for want in integers {
		values, has_row, err := db.rows_next(&rows)
		_expect_ok(t, err)
		if !testing.expect(t, has_row, "expected an integer row") { return }
		got, _ := db.as_i64(values[0])
		testing.expect_value(t, got, want)
	}
	for want in floats {
		values, has_row, err := db.rows_next(&rows)
		_expect_ok(t, err)
		if !testing.expect(t, has_row, "expected a float row") { return }
		got, got_err := db.as_f64(values[0])
		_expect_ok(t, got_err)
		testing.expect_value(t, got, want)
	}
}

@(test)
test_a_not_a_number_is_refused_rather_than_stored_as_null :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (v)"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (?)", {db.Value(f64(1))}))

	// SQLite stores a NaN as NULL, so accepting one would quietly turn a
	// computed value into a missing one.
	_expect_failure(t, db.exec(&conn, "INSERT INTO t VALUES (?)", {db.Value(math.nan_f64())}), .Invalid_Argument)

	// Nil is how a caller says NULL.
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (?)", {db.Value(nil)}))

	rows: db.Rows
	_expect_ok(t, db.query(&conn, &rows, "SELECT v FROM t ORDER BY rowid"))
	defer db.rows_close(&rows)

	values, has_row, err := db.rows_next(&rows)
	_expect_ok(t, err)
	if !testing.expect(t, has_row, "expected the first row") { return }
	first, _ := db.as_f64(values[0])
	testing.expect_value(t, first, f64(1))

	values, has_row, err = db.rows_next(&rows)
	_expect_ok(t, err)
	if !testing.expect(t, has_row, "expected the second row") { return }
	testing.expect(t, values[0] == nil, "the bound NULL should read back as SQL NULL")
}

@(test)
test_a_pragma_that_reports_a_value_is_readable :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer delete(directory)
	defer os.remove_all(directory)
	path := _temp_database(directory)
	defer delete(path)

	conn: db.Conn
	_expect_ok(t, open(&conn, {path = path, busy_timeout_ms = 1000}))
	defer db.close(&conn)

	// The journal mode is not part of Config. It is a pragma, which is ordinary
	// SQL, and exec runs one without minding that it answers with a row.
	_expect_ok(t, db.exec(&conn, "PRAGMA journal_mode = WAL"))

	rows: db.Rows
	defer db.rows_close(&rows)
	_expect_ok(t, db.query(&conn, &rows, "PRAGMA journal_mode"))

	mode, has_row, err := db.rows_next(&rows)
	_expect_ok(t, err)
	if !testing.expect(t, has_row, "PRAGMA journal_mode should report its value") { return }
	text, text_err := db.as_string(mode[0])
	_expect_ok(t, text_err)
	testing.expect_value(t, text, "wal")

	// Reading one row leaves the set open, which is what holds the connection.
	_expect_ok(t, db.rows_close(&rows))

	// A journal mode outlives the connection that set it, so the setting is the
	// file's from here on.
	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (value INTEGER)"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (1)"))
}

@(test)
test_changed_rows_are_readable_as_a_value :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (v INTEGER)"))

	// changes() is SQLite's own count of the most recent INSERT, UPDATE, or
	// DELETE, so a caller reads it as a value instead of through an API.
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (1), (2), (3)"))
	testing.expect_value(t, _scalar_i64(t, &conn, "SELECT changes()"), i64(3))

	_expect_ok(t, db.exec(&conn, "DELETE FROM t WHERE v > 1"))
	testing.expect_value(t, _scalar_i64(t, &conn, "SELECT changes()"), i64(2))

	// A statement that reads does not overwrite the count, so the delete is
	// still the answer after a select or a schema change.
	_expect_ok(t, db.exec(&conn, "SELECT count(*) FROM t"))
	testing.expect_value(t, _scalar_i64(t, &conn, "SELECT changes()"), i64(2))
}

@(test)
test_a_write_transaction_can_begin_immediately :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer delete(directory)
	defer os.remove_all(directory)
	path := _temp_database(directory)
	defer delete(path)

	writer: db.Conn
	_expect_ok(t, open(&writer, {path = path}))
	defer db.close(&writer)

	other: db.Conn
	_expect_ok(t, open(&other, {path = path}))
	defer db.close(&other)

	_expect_ok(t, db.exec(&writer, "CREATE TABLE t (v INTEGER)"))

	// BEGIN IMMEDIATE takes the write lock at once, so the failure lands on the
	// statement that asked for it rather than somewhere later in the work.
	_expect_ok(t, db.exec(&writer, "BEGIN IMMEDIATE"))
	_expect_failure(t, db.exec(&other, "INSERT INTO t VALUES (1)"), .Busy)

	// db.begin refuses while one is open, because the connection is in a
	// transaction either way that transaction was started.
	_expect_failure(t, db.begin(&writer), .Invalid_State)

	_expect_ok(t, db.exec(&writer, "INSERT INTO t VALUES (1)"))
	_expect_ok(t, db.commit(&writer))

	// And it is free again once the transaction is over.
	testing.expect_value(t, _scalar_i64(t, &writer, "SELECT changes()"), i64(1))
}

@(test)
test_a_savepoint_is_ordinary_sql :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (value INTEGER)"))
	_expect_ok(t, db.exec(&conn, "SAVEPOINT outer"))

	// A savepoint turns autocommit off, so db.begin sees a transaction open
	// exactly as it does after a BEGIN.
	_expect_failure(t, db.begin(&conn), .Invalid_State)

	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (1)"))
	_expect_ok(t, db.exec(&conn, "SAVEPOINT inner"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (2)"))
	_expect_ok(t, db.exec(&conn, "ROLLBACK TO inner"))
	_expect_ok(t, db.exec(&conn, "RELEASE inner"))

	// The commit ends the outer savepoint transaction and keeps the row that
	// was still inside it.
	_expect_ok(t, db.commit(&conn))
	testing.expect_value(t, _count(&conn), i64(1))
}

// _scalar_i64 runs a statement, reads its one column of one row, and closes the
// set. It is a test-local stand-in for reading a single value.
_scalar_i64 :: proc(t: ^testing.T, conn: ^db.Conn, sql: string) -> i64 {
	rows: db.Rows
	_expect_ok(t, db.query(conn, &rows, sql))
	defer db.rows_close(&rows)

	values, has_row, err := db.rows_next(&rows)
	_expect_ok(t, err)
	if !testing.expect(t, has_row, "expected a row") { return 0 }
	value, value_err := db.as_i64(values[0])
	_expect_ok(t, value_err)
	return value
}

@(test)
test_a_failed_path_allocation_does_not_open_a_database :: proc(t: ^testing.T) {
	// The path is handed to SQLite as a C string, and making one allocates. If
	// that allocation failed quietly, SQLite would be handed a null filename
	// and open a private temporary database instead of the one asked for.
	ambient := context.temp_allocator
	defer context.temp_allocator = ambient
	context.temp_allocator = mem.Allocator {
		procedure = failing_allocate,
	}

	conn: db.Conn
	_expect_failure(t, open(&conn, {path = "nabla-should-not-exist.db"}), .Out_Of_Memory)

	// The refusal happened before anything was published, so the handle is
	// still closed.
	testing.expect_value(t, db.error_kind(db.exec(&conn, "SELECT 1")), db.Error_Kind.Invalid_State)
}

failing_allocate :: proc(
	_: rawptr,
	_: mem.Allocator_Mode,
	_, _: int,
	_: rawptr,
	_: int,
	_: runtime.Source_Code_Location = #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	return nil, .Out_Of_Memory
}

@(test)
test_rejecting_trailing_sql_has_no_effect :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	testing.expect(t, _foreign_keys(&conn), "the test connection starts with foreign keys on")

	// Some pragmas run while a statement is compiled, so the refused tail of a
	// multi-statement string must never reach the compiler.
	_expect_failure(t, db.exec(&conn, "SELECT 1; PRAGMA foreign_keys = OFF"), .Invalid_Argument)
	testing.expect(t, _foreign_keys(&conn), "refused input must not change the connection")

	_expect_failure(t, db.exec(&conn, "SELECT 1; CREATE TABLE sneaky (x)"), .Invalid_Argument)
	_expect_failure(t, db.exec(&conn, "INSERT INTO sneaky VALUES (1)"), .Backend)
}

_foreign_keys :: proc(conn: ^db.Conn) -> bool {
	rows: db.Rows
	if db.query(conn, &rows, "PRAGMA foreign_keys") != nil { return false }
	defer db.rows_close(&rows)

	values, has_row, err := db.rows_next(&rows)
	if err != nil || !has_row { return false }
	on, _ := db.as_bool(values[0])
	return on
}

@(test)
test_prepared_columns_follow_the_schema_the_rows_come_from :: proc(t: ^testing.T) {
	conn := _open(t)
	defer db.close(&conn)

	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (a INTEGER)"))
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (1)"))

	stmt: db.Statement
	_expect_ok(t, db.prepare(&conn, &stmt, "SELECT * FROM t"))
	defer db.statement_close(&stmt)

	// SELECT * changes meaning with the table, and SQLite recompiles a
	// statement against the new schema when it first steps. The columns a set
	// reports have to be the ones its rows actually have.
	_expect_ok(t, db.exec(&conn, "ALTER TABLE t ADD COLUMN b INTEGER DEFAULT 2"))

	rows: db.Rows
	_expect_ok(t, db.statement_query(&stmt, &rows))
	values, has_row, err := db.rows_next(&rows)
	_expect_ok(t, err)
	testing.expect(t, has_row, "expected a row")
	testing.expect_value(t, len(values), 2)
	b, b_err := db.as_i64(values[1])
	_expect_ok(t, b_err)
	testing.expect_value(t, b, i64(2))
	_expect_ok(t, db.rows_close(&rows))

	// The same in the other direction: the table has one column again, and a
	// buffer sized for two would hand back a NULL that is not there.
	_expect_ok(t, db.exec(&conn, "ALTER TABLE t DROP COLUMN b"))

	shrunk: db.Rows
	_expect_ok(t, db.statement_query(&stmt, &shrunk))
	shrunk_values, shrunk_row, shrunk_err := db.rows_next(&shrunk)
	_expect_ok(t, shrunk_err)
	testing.expect(t, shrunk_row, "expected a row")
	testing.expect_value(t, len(shrunk_values), 1)
	a, a_err := db.as_i64(shrunk_values[0])
	_expect_ok(t, a_err)
	testing.expect_value(t, a, i64(1))
	_expect_ok(t, db.rows_close(&shrunk))
}

@(test)
test_a_column_that_cannot_be_read_reports_out_of_memory :: proc(t: ^testing.T) {
	// The heap limit that forces a column read to fail belongs to the whole
	// process, so the scenario runs in a child of this same test binary,
	// filtered down to the child case, instead of racing every other test's
	// allocations. In this process the test is a no-op.
	if len(os.get_env("NABLA_DB_OOM_CHILD", context.temp_allocator)) > 0 {
		_read_column_with_no_memory_left(t)
		return
	}

	binary := os.args[0]
	current_env, env_err := os.environ(context.temp_allocator)
	if env_err != nil { testing.fail_now(t, "could not read the environment") }
	child_env := make([dynamic]string, 0, len(current_env) + 1, context.temp_allocator)
	append(&child_env, ..current_env)
	append(&child_env, "NABLA_DB_OOM_CHILD=1")

	state, _, stderr, process_err := os.process_exec(
		{command = {binary, "-tests:sqlite.test_a_column_that_cannot_be_read_reports_out_of_memory"}, env = child_env[:]},
		context.temp_allocator,
	)
	if process_err != nil { testing.fail_now(t, "could not run the child test binary") }
	testing.expectf(t, state.exit_code == 0, "the child run failed:\n%s", string(stderr))
}

_read_column_with_no_memory_left :: proc(t: ^testing.T) {
	conn: db.Conn
	_expect_ok(t, open(&conn, {path = ":memory:"}))
	defer db.close(&conn)

	// The encoding has to be chosen before the schema exists. Every text value
	// is then stored as UTF-16, and reading one has to convert, which is the
	// one read in this backend that can fail.
	_expect_ok(t, db.exec(&conn, "PRAGMA encoding = 'UTF-16le'"))
	_expect_ok(t, db.exec(&conn, "CREATE TABLE t (v TEXT)"))
	text := strings.repeat("x", 1000)
	defer delete(text)
	_expect_ok(t, db.exec(&conn, "INSERT INTO t VALUES (?), (?)", {db.Value(text), db.Value(text)}))

	rows: db.Rows
	_expect_ok(t, db.query(&conn, &rows, "SELECT v FROM t"))

	// The first row is stepped to and read with memory to spare, so that the
	// only allocation between this point and the next read is its conversion.
	_, has_row, first_err := db.rows_next(&rows)
	_expect_ok(t, first_err)
	testing.expect(t, has_row, "expected the first row")

	// A heap limit at the memory in use leaves nothing for the next
	// conversion, which SQLite reports as the same null pointer it uses for a
	// value that is not there.
	hard_heap_limit64(memory_used())
	_, _, err := db.rows_next(&rows)
	hard_heap_limit64(0)

	testing.expect(t, err != nil, "the second row should not have been readable")
	testing.expect_value(t, db.error_kind(err), db.Error_Kind.Out_Of_Memory)
	_expect_ok(t, db.rows_close(&rows))
}
