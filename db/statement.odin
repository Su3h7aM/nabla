package db

// Statement is a compiled SQL statement belonging to one connection. Prepare it
// once and run it as often as needed; each execution binds the arguments it is
// given, so nothing bound outlives the call that bound it.
//
// The zero value is a closed statement. A live Statement must not be copied or
// moved: the connection keeps its address in a list of what it still owns.
Statement :: struct {
	conn:  ^Conn,
	next:  ^Statement,
	state: rawptr,
}

// statement_prepare compiles sql for an idle connection. It ties the statement
// into the connection's list of live statements and reports the backend state.
@(private)
statement_prepare :: proc(conn: ^Conn, sql: string) -> (state: rawptr, err: Error) {
	conn_idle(conn) or_return
	return conn.driver.prepare(conn.state, sql)
}

// statement_link and statement_unlink keep the connection's list of live
// statements. close refuses to run while the list is non-empty.
@(private)
statement_link :: proc(stmt: ^Statement) {
	stmt.next = stmt.conn.statements
	stmt.conn.statements = stmt
}

@(private)
statement_unlink :: proc(stmt: ^Statement) {
	link := &stmt.conn.statements
	for link^ != nil {
		if link^ == stmt {
			link^ = stmt.next
			return
		}
		link = &link^.next
	}
}

// prepare compiles sql into stmt for repeated execution. sql holds exactly one
// statement and no NUL byte.
//
// Pair prepare with statement_close. A prepared statement belongs to one
// connection and stops being usable when that connection closes, which close
// enforces by refusing to run first.
prepare :: proc(conn: ^Conn, stmt: ^Statement, sql: string) -> Error {
	state, err := statement_prepare(conn, sql)
	if err != nil { return err }
	stmt^ = Statement {
		conn  = conn,
		state = state,
	}
	statement_link(stmt)
	return nil
}

// statement_close releases stmt. A result set opened from it has to be closed
// first. Closing a closed statement does nothing.
statement_close :: proc(stmt: ^Statement) -> Error {
	if stmt.state == nil { return nil }
	if stmt.conn.active != nil {
		return error_make(.Invalid_State, 0, "a result set is still open")
	}
	stmt.conn.driver.finalize(stmt.state)
	statement_unlink(stmt)
	stmt^ = {}
	return nil
}

// statement_exec runs stmt with args to completion, discarding any rows it
// produces. The statement stays prepared and ready for the next call.
statement_exec :: proc(stmt: ^Statement, args: []Value = nil) -> Error {
	if stmt.state == nil {
		return error_make(.Invalid_State, 0, "statement is closed")
	}
	conn_idle(stmt.conn) or_return

	rows := Rows {
		conn       = stmt.conn,
		stmt_state = stmt.state,
	}
	if err := rows_execute(&rows, args, false); err != nil {
		return err
	}
	return rows_drain(&rows)
}

// statement_query runs stmt with args and leaves the result set open in rows.
// The statement is borrowed, not owned: it stays prepared and rows_close leaves
// it that way.
statement_query :: proc(stmt: ^Statement, rows: ^Rows, args: []Value = nil) -> Error {
	if stmt.state == nil {
		return error_make(.Invalid_State, 0, "statement is closed")
	}
	conn_idle(stmt.conn) or_return

	rows^ = Rows {
		conn       = stmt.conn,
		stmt_state = stmt.state,
	}
	if err := rows_execute(rows, args, true); err != nil {
		rows^ = {}
		return err
	}
	return nil
}
