package db

import "core:mem"

// Conn is one open database connection. It is the root of every other handle:
// statements, result sets, and transactions all belong to it.
//
// A Conn is not safe for concurrent or reentrant use. One caller owns it on one
// thread, and it runs one operation at a time. Moving it between threads is an
// ownership handoff, and the allocator it was opened with has to allow it.
//
// The zero value is a closed connection, so a Conn only needs initialization
// once and close is safe to call afterwards. It must not be copied while it is
// open.
Conn :: struct {
	driver:     ^Driver,
	state:      rawptr,
	allocator:  mem.Allocator,

	// active is the result set currently holding the connection, if any. The
	// connection runs nothing else until it is closed.
	active:     ^Rows,

	// statements is every prepared statement that has not been closed. close
	// refuses to run while the list is non-empty, so a statement never
	// outlives the state it points at.
	statements: ^Statement,
}

// conn_is_open reports whether conn already holds a connection. A backend
// checks it before it allocates state or touches a database, so a refused open
// leaves nothing behind.
conn_is_open :: proc(conn: ^Conn) -> bool {
	return conn.state != nil
}

// conn_init publishes an open backend connection as a Conn. A backend calls it
// from its own open procedure, once the connection is usable and configured.
//
// It fails when conn is already open. The caller keeps ownership of state on
// failure, so it has to release it rather than hand it over.
//
// state stays the backend's to release: close calls driver.close, which must
// free it. allocator is the one the backend used and the one this package uses
// for row buffers, so the whole connection has a single owner for its memory.
conn_init :: proc(conn: ^Conn, driver: ^Driver, state: rawptr, allocator: mem.Allocator) -> Error {
	if conn_is_open(conn) {
		return error_make(.Invalid_State, 0, "connection is already open")
	}
	conn.driver = driver
	conn.state = state
	conn.allocator = allocator
	return nil
}

// conn_idle reports whether conn is open and running nothing.
@(private)
conn_idle :: proc(conn: ^Conn) -> Error {
	if conn.state == nil {
		return error_make(.Invalid_State, 0, "connection is closed")
	}
	if conn.active != nil {
		return error_make(.Invalid_State, 0, "a result set is still open")
	}
	return nil
}

// close releases conn and its backend state. A statement or result set derived
// from it has to be closed first: close refuses and leaves conn usable rather
// than free state a live handle still points at. An open transaction is
// connection state, not a handle, so close rolls it back. Closing a closed
// connection does nothing.
close :: proc(conn: ^Conn) -> Error {
	if conn.state == nil { return nil }
	if conn.active != nil {
		return error_make(.Invalid_State, 0, "a result set is still open")
	}
	if conn.statements != nil {
		return error_make(.Invalid_State, 0, "a prepared statement is still open")
	}
	if err := conn.driver.close(conn.state); err != nil {
		return err
	}
	conn^ = {}
	return nil
}

// exec runs sql to completion and discards any rows it produces. Use query when
// the rows matter.
//
// sql holds exactly one statement and no NUL byte. A second statement is an
// error rather than a silent no-op.
//
// exec compiles sql every call. A loop that runs the same statement repeatedly
// wants prepare once and statement_exec, inside a transaction if it writes.
@(require_results)
exec :: proc(conn: ^Conn, sql: string, args: []Value = nil) -> Error {
	state, err := statement_prepare(conn, sql)
	if err != nil { return err }
	stmt := Statement {
		conn  = conn,
		state = state,
	}
	exec_err := statement_exec(&stmt, args)
	conn.driver.finalize(state)
	return exec_err
}

// query prepares sql, runs it with args, and leaves the result set open in
// rows. The statement query prepares is released when the set ends or is
// closed; the caller never sees it.
//
// rows must be a closed set: query refuses to overwrite one that is still open,
// because nothing else would be left to close it. It must also stay where it is
// and must not be copied while the set is open.
@(require_results)
query :: proc(conn: ^Conn, rows: ^Rows, sql: string, args: []Value = nil) -> Error {
	if rows.conn != nil {
		return error_make(.Invalid_State, 0, "the result set passed in is still open")
	}

	state, err := statement_prepare(conn, sql)
	if err != nil { return err }

	rows^ = Rows {
		conn       = conn,
		stmt_state = state,
		owns_stmt  = true,
	}
	if exec_err := rows_execute(rows, args, true); exec_err != nil {
		conn.driver.finalize(state)
		rows^ = {}
		return exec_err
	}
	return nil
}

// begin starts a transaction on conn. Everything run on the connection belongs
// to it until commit or rollback.
//
// A transaction is connection state, not a handle: statements prepared before
// begin keep working inside it, and there is nothing extra to close. begin
// fails when a transaction is already open.
@(require_results)
begin :: proc(conn: ^Conn) -> Error {
	conn_idle(conn) or_return
	return conn.driver.begin(conn.state)
}

// commit ends the open transaction on conn and makes its work permanent.
// Committing with no transaction open is an error, because it means the caller
// has lost track of the connection's state.
@(require_results)
commit :: proc(conn: ^Conn) -> Error {
	conn_idle(conn) or_return
	return conn.driver.commit(conn.state)
}

// rollback discards the open transaction on conn. Rolling back with no
// transaction open succeeds, so `defer rollback(&conn)` needs no bookkeeping,
// and rollback is not require_results for the same reason.
rollback :: proc(conn: ^Conn) -> Error {
	conn_idle(conn) or_return
	return conn.driver.rollback(conn.state)
}
