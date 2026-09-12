package db

// Rows is an open result set: one execution of a prepared statement, walked
// forward one row at a time.
//
// Reaching the end, or failing, releases everything the set holds and returns
// the connection to the caller, so a caller can walk a set to its end without
// closing anything. rows_close is for stopping early, and is safe on a set that
// already ended or never opened.
//
// The zero value is a closed set. A live Rows must not be copied or moved: the
// connection holds its address as the one execution currently running.
Rows :: struct {
	conn:       ^Conn,
	stmt_state: rawptr,
	owns_stmt:  bool,
	state:      rawptr,
	values:     []Value,
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
// the end of the set, and false with an error when the statement failed, so no
// separate deferred error check is needed.
//
// Either of those outcomes ends the set: rows_next releases the execution, and
// frees the connection, before it returns. So the connection is usable again as
// soon as the set is walked to its end, and rows_close afterwards does nothing.
//
// The returned values alias rows and are valid only until the next rows_next or
// rows_close. A string or blob case points into storage the backend overwrites
// for the next row and releases at the end of the set.
@(require_results)
rows_next :: proc(rows: ^Rows) -> (values: []Value, has_row: bool, err: Error) {
	if rows.state == nil {
		return nil, false, error_make(.Invalid_State, 0, "no result set is open")
	}

	row_err: Error
	has_row, row_err = rows.conn.driver.next(rows.state, rows.values)
	if has_row { return rows.values, true, nil }

	// Out of rows, or a statement that failed. Both end the execution, and both
	// can report one more failure on the way out: reset is where SQLite commits
	// an implicit transaction, so a statement that stepped cleanly can still
	// fail here. An error from the row itself is the one worth keeping.
	finish_err := rows.conn.driver.execution_finish(rows.state)
	first := row_err
	if first == nil { first = finish_err }
	rows_release(rows)
	return nil, false, first
}

// rows_release frees everything rows holds and clears it. It runs while the
// connection is still open, which is what lets it reach the allocator.
@(private)
rows_release :: proc(rows: ^Rows) {
	conn := rows.conn
	if conn != nil {
		if rows.owns_stmt && rows.stmt_state != nil {
			conn.driver.finalize(rows.stmt_state)
		}
		if rows.values != nil { delete(rows.values, conn.allocator) }
		if conn.active == rows { conn.active = nil }
	}
	rows^ = {}
}

// rows_drain walks a set to its end, which is how a statement that returns rows
// nobody wants is finished. rows_next releases everything on the way out, so
// there is no close here.
@(private)
rows_drain :: proc(rows: ^Rows) -> Error {
	for {
		_, has_row, err := rows_next(rows)
		if !has_row { return err }
	}
}

// rows_close ends the execution early and releases what rows owns, including
// the statement when query prepared it. Closing a set that already ended, or one
// that was never opened, does nothing.
//
// Stopping short of the end can fail, and that failure is returned, but the
// resources are released either way: an error here never leaves a set to close
// twice.
rows_close :: proc(rows: ^Rows) -> Error {
	conn := rows.conn
	if conn == nil { return nil }

	first: Error
	if rows.state != nil {
		if err := conn.driver.execution_finish(rows.state); err != nil { first = err }
	}
	rows_release(rows)
	return first
}
