package session

// MAX_ERROR_DETAIL bounds the diagnostic text a Failure carries, so an error is
// a value that owns nothing and can be copied and logged like any other. A
// longer message is cut short.
MAX_ERROR_DETAIL :: 160

// Error_Kind classifies a failure. The zero value is success, so Error composes
// with or_return, or_else, and or_break.
Error_Kind :: enum {
	None,
	// The arguments do not describe a valid operation, or the store is in the
	// wrong state for it.
	Invalid_Argument,
	// No session with that id exists.
	Not_Found,
	// Another process holds the session's writer claim.
	Busy,
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
	// The store is closed, or a writer claim is held that the call does not own.
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
