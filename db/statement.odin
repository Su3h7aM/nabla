package db

// Statement is a compiled SQL statement belonging to one connection. Prepare it
// once and run it as often as needed; each execution binds the arguments it is
// given, so nothing bound outlives the call that bound it.
//
// The zero value is a closed statement. A live Statement must not be copied or
// moved: the connection keeps its address in a list of what it still owns.
Statement :: struct {
	connection: ^Conn,
	next:       ^Statement,
	state:      rawptr,
}

// statement_prepare compiles sql for an idle connection. It ties the statement
// into the connection's list of live statements and reports the backend state.
@(private, require_results)
statement_prepare :: proc(connection: ^Conn, sql: string) -> (state: rawptr, err: Error) {
	connection_idle(connection) or_return
	return connection.driver.prepare(connection.state, sql)
}

// statement_link and statement_unlink keep the connection's list of live
// statements. close refuses to run while the list is non-empty.
@(private)
statement_link :: proc(statement: ^Statement) {
	statement.next = statement.connection.statements
	statement.connection.statements = statement
}

@(private)
statement_unlink :: proc(statement: ^Statement) {
	link := &statement.connection.statements
	for link^ != nil {
		if link^ == statement {
			link^ = statement.next
			return
		}
		link = &link^.next
	}
}

// prepare compiles sql into statement for repeated execution. sql holds exactly
// one statement and no NUL byte.
//
// statement must be closed, so preparing over a live one is refused rather than
// silently leaking the state behind it. Pair prepare with statement_close. A
// prepared statement belongs to one connection and stops being usable when that
// connection closes, which close enforces by refusing to run first.
@(require_results)
prepare :: proc(connection: ^Conn, statement: ^Statement, sql: string) -> Error {
	if statement.state != nil {
		return error_make(.Invalid_State, 0, "the statement passed in is already prepared")
	}
	state, err := statement_prepare(connection, sql)
	if err != nil { return err }
	statement^ = Statement {
		connection = connection,
		state      = state,
	}
	statement_link(statement)
	return nil
}

// statement_close releases a prepared statement and its backend state. A result
// set opened from it has to be closed first. Closing a closed statement does
// nothing.
@(require_results)
statement_close :: proc(statement: ^Statement) -> Error {
	if statement.state == nil { return nil }
	if statement.connection.active != nil {
		return error_make(.Invalid_State, 0, "a result set is still open on the connection")
	}
	statement.connection.driver.finalize(statement.state)
	statement_unlink(statement)
	statement^ = {}
	return nil
}

// statement_exec runs the statement with arguments to completion, discarding any
// rows it produces. The statement stays prepared and ready for the next call.
@(require_results)
statement_exec :: proc(statement: ^Statement, arguments: []Value = nil) -> Error {
	if statement.state == nil {
		return error_make(.Invalid_State, 0, "statement is closed")
	}
	connection_idle(statement.connection) or_return

	rows := Rows {
		connection      = statement.connection,
		statement_state = statement.state,
	}
	if err := rows_execute(&rows, arguments, false); err != nil {
		return err
	}
	return rows_drain(&rows)
}

// statement_query runs the statement with arguments and leaves the result set
// open in rows. The statement is borrowed, not owned: it stays prepared and the
// end of the set leaves it that way.
//
// rows must be a closed set: statement_query refuses to overwrite one that is
// still open, because nothing else would be left to close it.
@(require_results)
statement_query :: proc(statement: ^Statement, rows: ^Rows, arguments: []Value = nil) -> Error {
	if statement.state == nil {
		return error_make(.Invalid_State, 0, "statement is closed")
	}
	if rows.connection != nil {
		return error_make(.Invalid_State, 0, "the result set passed in is still open")
	}
	connection_idle(statement.connection) or_return

	rows^ = Rows {
		connection      = statement.connection,
		statement_state = statement.state,
	}
	if err := rows_execute(rows, arguments, true); err != nil {
		rows^ = {}
		return err
	}
	return nil
}
