package db

// MAX_ERROR_MESSAGE bounds the diagnostic text a Failure carries. A longer
// backend message is cut short and Failure.truncated records that.
MAX_ERROR_MESSAGE :: 128

// Error_Kind classifies a failure so a caller can decide what to do without
// knowing a native error code. The backend's own code is always kept in
// Failure.code, so classification never hides detail.
Error_Kind :: enum {
	None,
	// The call does not fit the handle's lifecycle: a closed connection, an
	// operation while a result set is open, or a row read past the end.
	Invalid_State,
	// The arguments are unusable: empty SQL, more than one statement, a NUL
	// byte inside SQL or text, or a wrong number of bind parameters.
	Invalid_Argument,
	// A conversion was handed a value of a different type.
	Type_Mismatch,
	// A conversion was handed SQL NULL where a value is required.
	Null_Value,
	// A conversion would have lost information.
	Out_Of_Range,
	// A UNIQUE, NOT NULL, CHECK, or FOREIGN KEY constraint rejected the row.
	Constraint,
	// Another connection holds a lock, or the database is being written by
	// someone else. The same call may work after the other side finishes.
	Busy,
	// A lock inside this connection or its transaction is in the way, so
	// running the same call again will fail the same way. Kept apart from
	// Busy because the advice differs: Busy is worth waiting on, Locked is not.
	Locked,
	// The database or the file was opened read-only.
	Read_Only,
	Out_Of_Memory,
	Interrupted,
	// The backend reported a failure that none of the other kinds describe.
	Backend,
}

// Failure is what an Error carries: a classification, the backend's own code,
// and the diagnostic text. The message is stored inline, so a Failure owns
// nothing, survives the connection that produced it, and can be copied and
// logged like any other value.
Failure :: struct {
	kind:        Error_Kind,
	code:        i32,
	message_len: int,
	truncated:   bool,
	message:     [MAX_ERROR_MESSAGE]u8,
}

// Error is what every fallible procedure in this package returns. Its zero
// value is nil, which is success, so Error composes with or_return, or_else,
// and or_break.
Error :: union {
	Failure,
}

// error_make builds an Error from a classification, a native code, and a
// message. code is 0 when the backend has none to report. Backends call this to
// report their own failures; the message is truncated to MAX_ERROR_MESSAGE.
error_make :: proc(kind: Error_Kind, code: i32, message: string) -> Error {
	failure := Failure {
		kind = kind,
		code = code,
	}
	length := min(len(message), MAX_ERROR_MESSAGE)
	copy(failure.message[:length], message[:length])
	failure.message_len = length
	failure.truncated = length < len(message)
	return failure
}

// error_kind returns the classification of err, or .None when err is nil.
error_kind :: proc(err: Error) -> Error_Kind {
	failure, _ := err.(Failure)
	return failure.kind
}

// error_message returns the diagnostic text of err, or "" when err is nil. The
// result aliases err, so it stays valid exactly as long as err does, and err has
// to be addressable: the message is stored inside the error. An error held in a
// by-value parameter has no address, so copy it into a local first.
error_message :: proc(err: ^Error) -> string {
	if err^ == nil { return "" }
	// Error has a single variant, so a non-nil Error is a Failure and the
	// assertion cannot fail.
	failure := &err^.(Failure)
	return string(failure.message[:failure.message_len])
}
