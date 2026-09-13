package session

// MAX_ERROR_DETAIL bounds the diagnostic text a Failure carries, so an error is
// a value that owns nothing and can be copied and logged like any other. A
// longer message is cut short.
MAX_ERROR_DETAIL :: 160

// Error_Kind classifies a failure. The zero value is success, so Error composes
// with or_return, or_else, and or_break. The kinds tell a caller what it can do:
// .Claimed and .Contended are contention, .Stale_Snapshot is a transaction that
// must be restarted, .Constraint is a rejected row, and .Storage is a database
// that could not work.
Error_Kind :: enum {
	None,
	// The arguments do not describe a valid operation, or the store is in the
	// wrong state for it.
	Invalid_Argument,
	// No session with that id exists.
	Not_Found,
	// Another process holds the session's writer claim.
	Claimed,
	// Another connection held the database's write lock for longer than the busy
	// timeout allowed. The same call can succeed once that writer finishes.
	Contended,
	// A write was attempted from a WAL snapshot another connection had already
	// moved past. Running the same call again cannot help: the caller rolls the
	// transaction back and reads the current state before retrying.
	Stale_Snapshot,
	// A UNIQUE, NOT NULL, CHECK, or FOREIGN KEY constraint rejected the row.
	Constraint,
	// The database could not be opened, configured, read, or written.
	Storage,
	// The database was written by a newer version of this schema. Running the
	// older code against it would lose data, so it refuses instead.
	Schema_Too_New,
	// The database file holds tables this package did not create.
	Schema_Unknown,
	// Stored data does not have the shape the schema promises.
	Corrupt,
	// A payload could not be encoded for storage.
	Encode,
	// The store is closed, a writer claim is held that the call does not own, or
	// a failed transaction could not be discarded.
	Invalid_State,
}

// Failure is what an Error carries: a classification and a bounded detail
// string. It owns nothing and survives the store that produced it.
Failure :: struct {
	kind:       Error_Kind,
	detail_len: int,
	detail:     [MAX_ERROR_DETAIL]u8,
}

// Error is what every fallible procedure in this package returns. Its zero
// value is nil, which is success.
Error :: union {
	Failure,
}

error_make :: proc(kind: Error_Kind, detail: string) -> Error {
	failure := Failure {
		kind = kind,
	}
	length := min(len(detail), MAX_ERROR_DETAIL)
	copy(failure.detail[:length], detail[:length])
	failure.detail_len = length
	return failure
}

// error_kind returns the classification of err, or .None when err is nil.
error_kind :: proc(err: Error) -> Error_Kind {
	failure, ok := err.(Failure)
	if !ok { return .None }
	return failure.kind
}

// error_detail returns the diagnostic text of err, or "" when err is nil. The
// result aliases err, so err has to be addressable and outlive the call.
error_detail :: proc(err: ^Error) -> string {
	if err^ == nil { return "" }
	failure := &err^.(Failure)
	return string(failure.detail[:failure.detail_len])
}
