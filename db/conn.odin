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

// connection_is_open reports whether connection already holds backend state. A
// backend checks it before it allocates state or touches a database, so a
// refused open leaves nothing behind.
connection_is_open :: proc(connection: ^Conn) -> bool {
	return connection.state != nil
}

// connection_init publishes an open backend connection as a Conn. A backend calls it
// from its own open procedure, once the connection is usable and configured.
//
// It fails when connection is already open. The caller keeps ownership of state on
// failure, so it has to release it rather than hand it over.
//
// state stays the backend's to release: close calls driver.close, which must
// free it. allocator is the one the backend used and the one this package uses
// for row buffers, so the whole connection has a single owner for its memory.
connection_init :: proc(connection: ^Conn, driver: ^Driver, state: rawptr, allocator: mem.Allocator) -> Error {
	if connection_is_open(connection) {
		return error_make(.Invalid_State, 0, "connection is already open")
	}
	connection.driver = driver
	connection.state = state
	connection.allocator = allocator
	return nil
}

// connection_idle reports whether connection is open and running nothing.
@(private)
connection_idle :: proc(connection: ^Conn) -> Error {
	if connection.state == nil {
		return error_make(.Invalid_State, 0, "connection is closed")
	}
	if connection.active != nil {
		return error_make(.Invalid_State, 0, "a result set is still open")
	}
	return nil
}

// close releases the connection and its backend state. A statement or result set
// derived from it has to be closed first: close refuses and leaves the
// connection usable rather than free state a live handle still points at. An
// open transaction is connection state, not a handle, so close rolls it back.
// Closing a closed connection does nothing.
close :: proc(connection: ^Conn) -> Error {
	if connection.state == nil { return nil }
	if connection.active != nil {
		return error_make(.Invalid_State, 0, "a result set is still open")
	}
	if connection.statements != nil {
		return error_make(.Invalid_State, 0, "a prepared statement is still open")
	}
	if err := connection.driver.close(connection.state); err != nil {
		return err
	}
	connection^ = {}
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
exec :: proc(connection: ^Conn, sql: string, arguments: []Value = nil) -> Error {
	state, err := statement_prepare(connection, sql)
	if err != nil { return err }
	statement := Statement {
		connection = connection,
		state      = state,
	}
	exec_err := statement_exec(&statement, arguments)
	connection.driver.finalize(state)
	return exec_err
}

// query prepares sql, runs it with arguments, and leaves the result set open in
// rows. The statement query prepares is released when the set ends or is
// closed; the caller never sees it.
//
// rows must be a closed set: query refuses to overwrite one that is still open,
// because nothing else would be left to close it. It must also stay where it is
// and must not be copied while the set is open.
@(require_results)
query :: proc(connection: ^Conn, rows: ^Rows, sql: string, arguments: []Value = nil) -> Error {
	if rows.connection != nil {
		return error_make(.Invalid_State, 0, "the result set passed in is still open")
	}

	state, err := statement_prepare(connection, sql)
	if err != nil { return err }

	rows^ = Rows {
		connection      = connection,
		statement_state = state,
		owns_statement  = true,
	}
	if exec_err := rows_execute(rows, arguments, true); exec_err != nil {
		connection.driver.finalize(state)
		rows^ = {}
		return exec_err
	}
	return nil
}

// begin starts a transaction on connection. Everything run on the connection belongs
// to it until commit or rollback.
//
// A transaction is connection state, not a handle: statements prepared before
// begin keep working inside it, and there is nothing extra to close. begin
// fails when a transaction is already open.
@(require_results)
begin :: proc(connection: ^Conn) -> Error {
	connection_idle(connection) or_return
	return connection.driver.begin(connection.state)
}

// commit ends the open transaction on connection and makes its work permanent.
// Committing with no transaction open is an error, because it means the caller
// has lost track of the connection's state.
@(require_results)
commit :: proc(connection: ^Conn) -> Error {
	connection_idle(connection) or_return
	return connection.driver.commit(connection.state)
}

// rollback discards the open transaction on connection. Rolling back with no
// transaction open succeeds, so `defer rollback(&connection)` needs no bookkeeping,
// and rollback is not require_results for the same reason.
rollback :: proc(connection: ^Conn) -> Error {
	connection_idle(connection) or_return
	return connection.driver.rollback(connection.state)
}
