// Package sqlite is the SQLite backend for `nabla:db`. It is the only package
// that knows SQLite exists: it owns the C bindings, the connection
// configuration, the SQL dialect, and SQLite's result codes.
//
// # Parameters
//
// SQLite uses `?` placeholders. Nothing rewrites SQL for you, so write the
// dialect you are talking to:
//
//	db.exec(&connection, "INSERT INTO log (at, message) VALUES (?, ?)", {db.Value(at), db.Value(text)})
//
// # One statement per call
//
// SQLite's prepare interface compiles only the first statement in a string and
// silently ignores the rest. This backend rejects that rather than run half of
// what you wrote, so a migration script is several calls, not one.
//
// # Configuration
//
// Config holds the two connection settings that have to be right before the
// first statement and would otherwise have to be repeated on every open.
// Everything else SQLite configures with a pragma is ordinary SQL, so it goes
// through db.exec like anything else:
//
//	db.exec(&connection, "PRAGMA journal_mode = WAL") or_return
//
// WAL is persistent, so asking for it once is enough. The other journal modes
// reset with the connection, and busy_timeout and foreign_keys are per
// connection, which is why those two are fields and the journal mode is not.
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
//	db.exec(&connection, "DELETE FROM log WHERE at < ?", {db.Value(cutoff)}) or_return
//	rows: db.Rows
//	db.query(&connection, &rows, "SELECT changes()") or_return
//
// A transaction that reads before it writes is better started as
// "BEGIN IMMEDIATE", which takes the write lock up front instead of failing
// partway through. db.exec runs it and db.commit still ends it, but db.begin
// will refuse, because the transaction is already open either way.
//
// A savepoint is ordinary SQL too, and it turns autocommit off the same way, so
// db.begin refuses while one is open. db.commit and db.rollback end the whole
// transaction, savepoints included; rolling back to a savepoint is a statement
// like any other.
package sqlite
