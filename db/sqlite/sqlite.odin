// Package sqlite is the SQLite backend for `nabla:db`. It is the only package
// that knows SQLite exists: it owns the C bindings, the connection
// configuration, the SQL dialect, and SQLite's result codes.
//
// # Parameters
//
// SQLite uses `?` placeholders. Nothing rewrites SQL for you, so write the
// dialect you are talking to:
//
//	db.exec(&conn, "INSERT INTO log (at, message) VALUES (?, ?)", {db.Value(at), db.Value(text)})
//
// # One statement per call
//
// SQLite's prepare interface compiles only the first statement in a string and
// silently ignores the rest. This backend rejects that rather than run half of
// what you wrote, so a migration script is several calls, not one.
//
// # Configuration
//
// Config covers what has to be set before the connection is used. Everything
// else SQLite configures with a pragma is ordinary SQL, so it goes through
// db.exec like anything else:
//
//	db.exec(&conn, "PRAGMA journal_mode = WAL") or_return
//
// A pragma that reports a value is read with db.query. db.exec discards the
// rows a statement produces rather than refusing them, so a pragma that returns
// a row is readable either way.
//
// How many rows an INSERT, UPDATE, or DELETE changed is SQLite's own changes()
// function, which is a value to select rather than a call to make. It reports
// the most recent one of those on the connection, and a SELECT or a DDL
// statement does not overwrite it:
//
//	db.exec(&conn, "DELETE FROM log WHERE at < ?", {db.Value(cutoff)}) or_return
//	rows: db.Rows
//	db.query(&conn, &rows, "SELECT changes()") or_return
//
// A transaction that reads before it writes is better started as
// "BEGIN IMMEDIATE", which takes the write lock up front instead of failing
// partway through. db.exec runs it and db.commit still ends it, but db.begin
// will refuse, because the transaction is already open either way.
package sqlite

import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"

import "nabla:db"

// Config describes one SQLite database to open. Its zero value opens a private
// temporary database and enforces nothing, which is rarely what a caller wants:
// set path and foreign_keys.
Config :: struct {
	// path is the database file. ":memory:" opens a private in-memory database
	// and "" a private temporary one on disk.
	path:            string,

	// busy_timeout_ms is how long SQLite waits for another connection to
	// release a lock before a statement fails with `.Busy`. Zero fails at once.
	// A single-process program that keeps one connection usually wants 0.
	// Values above what SQLite accepts as an int are clamped, not truncated.
	// Negative values are refused.
	busy_timeout_ms: int,

	// foreign_keys enforces REFERENCES clauses. SQLite's own default is off, so
	// a schema that relies on foreign keys is silently unenforced unless this
	// is set.
	foreign_keys:    bool,
}

// Conn is the backend state behind a db.Conn this package opened. It is private
// because nothing outside this package has any business reaching into it.
@(private)
Conn :: struct {
	handle:    ^sqlite3,
	allocator: mem.Allocator,
}

// Stmt is the backend state behind a prepared statement. SQLite keeps an
// execution's cursor, its bindings, and its error state inside the statement,
// so this is also the state db hands back for Rows.
@(private)
Stmt :: struct {
	conn:   ^Conn,
	handle: ^sqlite3_stmt,
}

@(private)
DRIVER: db.Driver = {
	close            = conn_close,
	prepare          = stmt_prepare,
	finalize         = stmt_finalize,
	execute          = stmt_execute,
	columns          = stmt_columns,
	next             = execution_next,
	row              = execution_row,
	execution_finish = execution_finish,
	begin            = conn_begin,
	commit           = conn_commit,
	rollback         = conn_rollback,
}

// open opens the database described by config and publishes it as conn. The
// connection is fully configured before it is returned, so a caller that gets
// no error has a database it can use.
//
// Every allocation the connection makes comes from allocator, which db.close
// hands back to this package.
@(require_results)
open :: proc(conn: ^db.Conn, config: Config, allocator := context.allocator) -> db.Error {
	// Checked before the path reaches SQLite: open_v2 creates the file, so a
	// refused open would otherwise leave a database behind.
	if db.conn_is_open(conn) {
		return db.error_make(.Invalid_State, 0, "connection is already open")
	}
	if config.busy_timeout_ms < 0 {
		return db.error_make(.Invalid_Argument, 0, "busy_timeout_ms cannot be negative")
	}

	if strings.contains_rune(config.path, 0) {
		return db.error_make(.Invalid_Argument, 0, "database path contains a NUL byte")
	}

	state, alloc_err := new(Conn, allocator)
	if alloc_err != nil {
		return db.error_make(.Out_Of_Memory, 0, "connection state allocation failed")
	}
	state.allocator = allocator

	path, path_err := strings.clone_to_cstring(config.path, context.temp_allocator)
	if path_err != nil {
		// A nil filename is a database, not a failure: SQLite opens a private
		// temporary one, so a dropped error here would quietly write somewhere
		// the caller never asked for.
		free(state, allocator)
		return db.error_make(.Out_Of_Memory, 0, "database path allocation failed")
	}
	rc := open_v2(path, &state.handle, c.int(OPEN_READWRITE | OPEN_CREATE), nil)
	if rc != .OK {
		// open_v2 returns a handle even when it fails, and that handle still
		// has to be closed. errmsg is read before that happens.
		err := failure(state.handle, rc)
		if state.handle != nil { close_v2(state.handle) }
		free(state, allocator)
		return err
	}

	if config.busy_timeout_ms > 0 {
		// SQLite takes an int here, so a caller asking for longer than one can
		// express waits as long as it can rather than wrapping around to a
		// short wait.
		ms := min(config.busy_timeout_ms, int(max(c.int)))
		if rc = busy_timeout(state.handle, c.int(ms)); rc != .OK {
			err := failure(state.handle, rc)
			close_v2(state.handle)
			free(state, allocator)
			return err
		}
	}
	if config.foreign_keys {
		if err := run(state, "PRAGMA foreign_keys = ON"); err != nil {
			close_v2(state.handle)
			free(state, allocator)
			return err
		}
	}

	// conn_init refuses a connection that is already open, and on that path the
	// state is still this procedure's to release.
	if err := db.conn_init(conn, &DRIVER, state, allocator); err != nil {
		close_v2(state.handle)
		free(state, allocator)
		return err
	}
	return nil
}

@(private)
conn_close :: proc(state: rawptr) -> db.Error {
	conn := cast(^Conn)state
	if rc := close_v2(conn.handle); rc != .OK {
		// The connection is untouched on failure, so the caller can retry.
		return failure(conn.handle, rc)
	}
	free(conn, conn.allocator)
	return nil
}

@(private)
stmt_prepare :: proc(state: rawptr, sql: string) -> (rawptr, db.Error) {
	conn := cast(^Conn)state
	if len(sql) == 0 {
		return nil, db.error_make(.Invalid_Argument, 0, "SQL is empty")
	}
	if strings.contains_rune(sql, 0) {
		return nil, db.error_make(.Invalid_Argument, 0, "SQL contains a NUL byte")
	}
	if len(sql) > int(max(c.int)) {
		// prepare_v3 takes the length as an int, so anything longer would be
		// truncated into a different statement.
		return nil, db.error_make(.Invalid_Argument, 0, "SQL is longer than the backend can take")
	}

	handle: ^sqlite3_stmt
	tail: cstring
	// nByte is how much of sql SQLite may read, so sql needs no NUL terminator
	// of its own.
	rc := prepare_v3(conn.handle, cstring(raw_data(sql)), c.int(len(sql)), 0, &handle, &tail)
	if rc != .OK {
		return nil, failure(conn.handle, rc)
	}
	if handle == nil {
		// An empty string or a lone comment compiles to no statement at all.
		return nil, db.error_make(.Invalid_Argument, 0, "SQL contains no statement")
	}
	if tail_holds_more_sql(sql, tail) {
		finalize(handle)
		return nil, db.error_make(.Invalid_Argument, 0, "SQL contains more than one statement")
	}

	statement, alloc_err := new(Stmt, conn.allocator)
	if alloc_err != nil {
		finalize(handle)
		return nil, db.error_make(.Out_Of_Memory, 0, "statement allocation failed")
	}
	statement^ = Stmt {
		conn   = conn,
		handle = handle,
	}
	return rawptr(statement), nil
}

// tail_holds_more_sql reports whether anything after the statement prepare_v3
// compiled is another statement, or something SQLite would refuse.
//
// The remainder is scanned rather than handed back to SQLite: preparing it
// would execute pragmas that take effect during compilation, so validating
// input must never have an effect on the connection. The scan accepts what
// SQLite accepts after a complete statement, which is whitespace, statement
// separators, and comments, and refuses everything else. A comment that never
// ends is accepted, which matches how SQLite reads one.
@(private)
tail_holds_more_sql :: proc(sql: string, tail: cstring) -> bool {
	if tail == nil { return false }

	// SAFETY: prepare_v3 documents tail as pointing into the SQL text it was
	// given, so the difference is an offset into sql. A value outside it means
	// the assumption does not hold, and the caller refuses rather than guesses.
	offset := int(transmute(uintptr)tail - uintptr(raw_data(sql)))
	if offset < 0 || offset > len(sql) { return true }

	rest := sql[offset:]
	i := 0
	for i < len(rest) {
		switch rest[i] {
		case ' ', '\t', '\n', '\r', '\f', '\v', ';':
			i += 1
		case '-':
			if i + 1 < len(rest) && rest[i + 1] == '-' {
				// A line comment runs to the end of its line.
				for i < len(rest) && rest[i] != '\n' { i += 1 }
			} else {
				return true
			}
		case '/':
			if i + 1 < len(rest) && rest[i + 1] == '*' {
				i += 2
				for {
					if i + 1 >= len(rest) { return false }
					if rest[i] == '*' && rest[i + 1] == '/' { i += 2; break }
					i += 1
				}
			} else {
				return true
			}
		case:
			return true
		}
	}
	return false
}

@(private)
stmt_finalize :: proc(state: rawptr) {
	stmt := cast(^Stmt)state
	finalize(stmt.handle)
	free(stmt, stmt.conn.allocator)
}

@(private)
stmt_execute :: proc(state: rawptr, args: []db.Value) -> (rawptr, db.Error) {
	stmt := cast(^Stmt)state
	if expected := int(bind_parameter_count(stmt.handle)); len(args) != expected {
		scratch: [64]u8
		message := fmt.bprintf(scratch[:], "statement argument count: expected %d, got %d", expected, len(args))
		return nil, db.error_make(.Invalid_Argument, 0, message)
	}
	for arg, i in args {
		if bind_err := bind(stmt, c.int(i + 1), arg); bind_err != nil {
			return nil, bind_err
		}
	}
	// SQLite holds the cursor and the bindings inside the statement, so the
	// statement is the whole execution state.
	return rawptr(stmt), nil
}

// stmt_columns reports how many columns the current execution yields. It is
// read after the first row has been stepped to: SQLite can recompile a
// statement against a changed schema on its first step, and only the count
// from after that is the count the rows ahead actually have.
@(private)
stmt_columns :: proc(state: rawptr) -> int {
	stmt := cast(^Stmt)state
	return int(column_count(stmt.handle))
}

@(private)
bind :: proc(stmt: ^Stmt, index: c.int, value: db.Value) -> db.Error {
	rc: Result_Code
	// SAFETY: SQLITE_TRANSIENT (behaviour = -1) makes SQLite copy every bound
	// buffer before it returns, so nothing bound here has to outlive the call.
	switch v in value {
	case i64:
		rc = bind_int64(stmt.handle, index, v)
	case f64:
		// SQLite has no NaN and stores one as NULL, which would lose the value
		// without saying so. An infinity is a value it can hold, so only NaN is
		// refused; a caller that wants NULL passes nil.
		if math.is_nan(v) {
			return db.error_make(.Invalid_Argument, 0, "NaN has no SQL value; bind nil for NULL")
		}
		rc = bind_double(stmt.handle, index, v)
	case bool:
		rc = bind_int64(stmt.handle, index, 1 if v else 0)
	case string:
		// An empty string is a value, not NULL, and SQLite reads a null
		// pointer as NULL, so the buffer handed over is never null.
		text := raw_data(v)
		if text == nil { text = raw_data(EMPTY_TEXT[:]) }
		rc = bind_text64(stmt.handle, index, cstring(text), sqlite3_uint64(len(v)), {behaviour = -1}, UTF8)
	case []u8:
		blob := raw_data(v)
		if blob == nil { blob = raw_data(EMPTY_TEXT[:]) }
		rc = bind_blob64(stmt.handle, index, blob, sqlite3_uint64(len(v)), {behaviour = -1})
	case:
		rc = bind_null(stmt.handle, index)
	}
	if rc != .OK {
		return failure(stmt.conn.handle, rc)
	}
	return nil
}

@(private)
execution_next :: proc(state: rawptr) -> (has_row: bool, err: db.Error) {
	stmt := cast(^Stmt)state
	rc := step(stmt.handle)
	#partial switch rc {
	case .Row:
		return true, nil
	case .Done:
		return false, nil
	case:
		return false, failure(stmt.conn.handle, rc)
	}
}

// execution_row copies the row the execution is stopped on into values, which
// is as long as stmt_columns reported for this execution.
@(private)
execution_row :: proc(state: rawptr, values: []db.Value) -> db.Error {
	return fill(cast(^Stmt)state, values)
}

@(private)
execution_finish :: proc(state: rawptr) -> db.Error {
	stmt := cast(^Stmt)state
	// reset is where an implicit transaction is committed, so it can fail on a
	// statement that stepped cleanly: an INSERT ... RETURNING that was not
	// walked to the end reports its failure here, not at step.
	if rc := reset(stmt.handle); rc != .OK {
		return failure(stmt.conn.handle, rc)
	}
	return nil
}

// fill copies one row out of the statement. The storage class chooses the
// accessor, so nothing this side of the boundary ever converts a value.
//
// It can fail. The text and blob accessors allocate when the column is not
// already stored in the encoding being asked for, and SQLite reports that by
// handing back the same null pointer it uses for a value that is not there;
// errcode is the only thing that tells those two apart.
@(private)
fill :: proc(stmt: ^Stmt, values: []db.Value) -> db.Error {
	for _, i in values {
		column := c.int(i)
		switch column_type(stmt.handle, column) {
		case .Integer:
			values[i] = column_int64(stmt.handle, column)
		case .Float:
			values[i] = column_double(stmt.handle, column)
		case .Text:
			// The pointer is read before the length, the order SQLite documents
			// as the safe one: asking for the pointer is what forces any
			// conversion, so the length after it agrees with it. A null pointer
			// from that call is a failed conversion until errcode says
			// otherwise, and errcode has to be read at once, before anything
			// else touches the connection.
			text := column_text(stmt.handle, column)
			if text == nil {
				if errcode(stmt.conn.handle) == .No_Mem {
					return db.error_make(.Out_Of_Memory, 0, "text column could not be read")
				}
				// The column cannot be NULL here, so nothing behind the pointer
				// means an empty value; len is the truth.
				values[i] = ""
				continue
			}
			values[i] = string(text[:int(column_bytes(stmt.handle, column))])
		case .Blob:
			blob := column_blob(stmt.handle, column)
			if blob == nil {
				if errcode(stmt.conn.handle) == .No_Mem {
					return db.error_make(.Out_Of_Memory, 0, "blob column could not be read")
				}
				values[i] = []u8{}
				continue
			}
			values[i] = ([^]u8)(blob)[:int(column_bytes(stmt.handle, column))]
		case .Null:
			values[i] = nil
		}
	}
	return nil
}

@(private)
conn_begin :: proc(state: rawptr) -> db.Error {
	conn := cast(^Conn)state
	if get_autocommit(conn.handle) == 0 {
		return db.error_make(.Invalid_State, 0, "a transaction is already open")
	}
	return run(conn, "BEGIN")
}

@(private)
conn_commit :: proc(state: rawptr) -> db.Error {
	conn := cast(^Conn)state
	if get_autocommit(conn.handle) != 0 {
		return db.error_make(.Invalid_State, 0, "no transaction is open")
	}
	// A COMMIT that fails with .Busy leaves the transaction open, so the
	// caller can retry it rather than assume it was lost.
	return run(conn, "COMMIT")
}

@(private)
conn_rollback :: proc(state: rawptr) -> db.Error {
	conn := cast(^Conn)state
	if get_autocommit(conn.handle) != 0 {
		// Nothing to undo, which is what a deferred rollback expects.
		return nil
	}
	return run(conn, "ROLLBACK")
}

// run executes one statement this package wrote itself, with no parameters.
@(private)
run :: proc(conn: ^Conn, sql: string) -> db.Error {
	handle: ^sqlite3_stmt
	rc := prepare_v3(conn.handle, cstring(raw_data(sql)), c.int(len(sql)), 0, &handle, nil)
	if rc != .OK {
		return failure(conn.handle, rc)
	}
	if handle == nil { return nil }

	err: db.Error
	if rc = step(handle); rc != .Done {
		err = failure(conn.handle, rc)
	}
	finalize(handle)
	return err
}

// failure builds a db.Error from the connection's current error state. errmsg
// and extended_errcode are read before anything else touches the handle,
// because the next SQLite call can overwrite both.
@(private)
failure :: proc(handle: ^sqlite3, rc: Result_Code) -> db.Error {
	message := ""
	code := c.int(rc)
	if handle != nil {
		message = string(errmsg(handle))
		code = extended_errcode(handle)
	}
	return db.error_make(classify(rc), i32(code), message)
}

// classify maps a result code onto db.Error_Kind. Only the kinds a caller can
// act on are named; everything else keeps its code as .Backend.
@(private)
classify :: proc(rc: Result_Code) -> db.Error_Kind {
	// An extended code carries its primary code in the low byte.
	#partial switch Result_Code(c.int(rc) & 0xFF) {
	case .OK, .Row, .Done:
		return .None
	case .Constraint:
		return .Constraint
	case .Busy:
		// Another connection holds the database file, so the same call can work
		// once that connection finishes.
		return .Busy
	case .Locked:
		// A table inside the database is locked, which needs shared cache. The
		// holder can be this very connection, so unlike Busy, waiting is not
		// guaranteed to help.
		return .Locked
	case .Read_Only:
		return .Read_Only
	case .No_Mem:
		return .Out_Of_Memory
	case .Interrupt:
		return .Interrupted
	case .Misuse:
		return .Invalid_State
	case .Range, .Mismatch, .Too_Big:
		return .Invalid_Argument
	case:
		return .Backend
	}
}

// EMPTY_TEXT is one readable byte, so binding a zero-length string or blob
// hands SQLite a non-null pointer. A null pointer would be read as SQL NULL,
// which is not the same as an empty value.
@(private)
EMPTY_TEXT: [1]u8
