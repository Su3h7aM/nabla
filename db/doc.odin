// Package db is a small, synchronous SQL execution layer: connections,
// prepared statements, forward-only result sets, transactions, and a closed set
// of values.
//
// It knows no engine. A backend package, such as `db/sqlite`, implements the
// Driver procedure table and owns the connection state, the SQL dialect, and
// the native error codes. This package owns the lifecycle rules, the value
// model, and the conversion between a row's storage and an Odin value.
//
// # What this package is not
//
// There is no connection pool, no statement cache, no retry, no SQL rewriting,
// and no mapping from a struct to a table. A Conn is one physical connection,
// owned by one caller on one thread. Concurrency is the caller's problem, and so
// is closing what it opened.
//
// SQL is not portable. A `?` parameter in SQLite is `$1` in PostgreSQL, and
// this package does not rewrite either. Write the dialect you are talking to.
//
// # Lifetime
//
// Every acquisition has one release:
//
//	open          -> close
//	prepare       -> statement_close
//	query         -> rows_close
//	begin         -> commit or rollback
//
// A result set is the exception, because it releases itself. Walking a set to
// its end, or hitting an error partway, frees the connection and the statement
// behind it before rows_next returns. rows_close is then only for stopping
// early, and it is still safe to defer next to a loop that runs to the end.
//
// close, statement_close, and query refuse to run over something still open,
// rather than freeing memory another handle still points at or stranding it.
// Every release is safe to defer; releasing an already-released handle does
// nothing.
//
// One connection runs one thing at a time. While a result set is streaming, any
// other use of that connection is refused, so the resource a caller holds stays
// unambiguous. Reaching the end of the set is what gives it back.
//
// A live Conn, Statement, or Rows must not be copied or moved. Its address is
// how the layer knows which handle is open, so pass a pointer and keep it where
// it is for as long as it is open.
//
// # Keeping a row
//
// A row's text and blobs point into the statement that produced them, so they
// last until the next rows_next and no longer. Keeping them means copying them,
// which is the whole price of a row that does not allocate:
//
//	for {
//		values, has_row, err := db.rows_next(&rows)
//		if err != nil { return err }
//		if !has_row { break }
//		id, _ := db.as_string(values[0])
//		append(&sessions, Session{id = strings.clone(id, allocator)})
//	}
//
// An integer or a float is already a copy, so only text and blobs need this.
//
// # Values
//
// Value is a closed union: integers, floats, booleans, text, and blobs, with
// nil standing for SQL NULL. as_i64, as_f64, as_bool, as_string, and as_bytes
// convert one value and refuse anything lossy: NULL into a non-nullable read,
// a float with a fraction into an integer, or an integer outside the target's
// range are errors, not silent truncation.
//
// # Example
//
//	conn: db.Conn
//	defer db.close(&conn)
//	sqlite.open(&conn, {path = "sessions.db", foreign_keys = true}) or_return
//
//	db.exec(&conn, "CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, title TEXT)") or_return
//
//	rows: db.Rows
//	defer db.rows_close(&rows)
//	db.query(&conn, &rows, "SELECT id, title FROM sessions WHERE id = ?", {db.Value("abc")}) or_return
//	for {
//		values, has_row, err := db.rows_next(&rows)
//		if err != nil { return err }
//		if !has_row { break }
//		id, _ := db.as_string(values[0])
//		title, _ := db.as_string(values[1])
//		_, _ = id, title
//	}
package db
