package db

// Rows is an open result set: one execution of a prepared statement, walked
// forward one row at a time.
//
// It owns the execution state and the value buffer behind rows_next, and it
// borrows the statement it runs. When query prepared that statement for it,
// rows_close releases it too.
//
// The zero value is a closed set, so rows_close needs no guard. A live Rows
// must not be copied or moved while it is open: the connection holds its address
// as the one result set currently running.
Rows :: struct {
	conn:       ^Conn,
	stmt_state: rawptr,
	owns_stmt:  bool,
	state:      rawptr,
	values:     []Value,
	done:       bool,
}

// rows_execute starts one execution of the statement already prepared for rows.
// materialize decides whether the caller gets the row values; exec passes false
// so a statement that returns rows nobody asked for costs no buffer.
//
// On failure rows is left closed.
@(private)
rows_execute :: proc(rows: ^Rows, args: []Value, materialize: bool) -> Error {
	conn := rows.conn
	state, columns, err := conn.driver.execute(rows.stmt_state, args)
	if err != nil { return err }

	rows.state = state
	if materialize && columns > 0 {
		values, alloc_err := make([]Value, columns, conn.allocator)
		if alloc_err != nil {
			conn.driver.execution_finish(state)
			rows.state = nil
			return error_make(.Out_Of_Memory, 0, "row buffer allocation failed")
		}
		rows.values = values
	}
	conn.active = rows
	return nil
}

// rows_next advances rows to its next row. It reports false with a nil error at
// the end of the set, and false with an error when execution failed, so no
// separate deferred error check is needed.
//
// The returned values alias rows, are valid until the next rows_next or
// rows_close, and are read-only. A value's string or blob case points into
// backend storage that the next row overwrites.
rows_next :: proc(rows: ^Rows) -> (values: []Value, has_row: bool, err: Error) {
	if rows.state == nil {
		return nil, false, error_make(.Invalid_State, 0, "no result set is open")
	}
	if rows.done {
		return nil, false, error_make(.Invalid_State, 0, "result set is exhausted")
	}
	has_row, err = rows.conn.driver.next(rows.state, rows.values)
	if !has_row { rows.done = true }
	return rows.values, has_row, err
}

// rows_drain walks a set to its end and closes it, which is how a statement
// that returns rows nobody wants is finished. The first failure wins; the
// resources are released either way.
@(private)
rows_drain :: proc(rows: ^Rows) -> Error {
	first: Error
	for {
		_, has_row, err := rows_next(rows)
		if err != nil {
			first = err
			break
		}
		if !has_row { break }
	}
	close_err := rows_close(rows)
	if first != nil { return first }
	return close_err
}

// rows_close ends the execution and releases what rows owns, including the
// statement when query prepared it. Closing a closed set does nothing.
//
// A failure from the backend is returned, but the resources are released
// regardless: an error here does not leave a set to close twice.
rows_close :: proc(rows: ^Rows) -> Error {
	conn := rows.conn
	if conn == nil { return nil }

	first: Error
	if rows.state != nil {
		if err := conn.driver.execution_finish(rows.state); err != nil {
			first = err
		}
	}
	if rows.owns_stmt && rows.stmt_state != nil {
		conn.driver.finalize(rows.stmt_state)
	}
	if rows.values != nil {
		delete(rows.values, conn.allocator)
	}
	if conn.active == rows { conn.active = nil }
	rows^ = {}
	return first
}
