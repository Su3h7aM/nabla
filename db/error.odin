package db

import "core:mem"

// Error_Kind classifies a failure so a caller can decide what to do without
// knowing a native error code. The backend's own code is always kept in
// Failure.code, so classification never hides detail.
Error_Kind :: enum {
	None,
	// The call does not fit the handle's lifecycle: a closed connection, an
	// operation while a result set is open, or a row read past the end.
	Invalid_State,
	// The arguments are unusable: empty SQL, more than one statement, a NUL
	// byte inside SQL or text, a wrong number of bind parameters, or a value
	// too large for the backend to hold.
	Invalid_Argument,
	// A conversion was handed a value of a different type.
	Type_Mismatch,
	// A conversion was handed SQL NULL where a value is required.
	Null_Value,
	// A conversion would have lost information.
	Out_Of_Range,
	// A UNIQUE, NOT NULL, CHECK, or FOREIGN KEY constraint rejected the row.
	Constraint,
	// Another connection holds the file or is writing to it, so the same call
	// may work once that connection finishes.
	Busy,
	// A WAL connection tried to write from a snapshot another connection has
	// already moved past. Running the same call again cannot help: the caller
	// rolls the transaction back and starts it over.
	Busy_Snapshot,
	// The database or the file was opened read-only.
	Read_Only,
	Out_Of_Memory,
	Interrupted,
	// The backend reported a failure that none of the other kinds describe.
	Backend,
}

// Failure is what an Error carries: a classification, the backend's own code,
// and the full diagnostic text, with no length limit.
//
// message is a view: static data, or text the connection that failed owns,
// valid until the connection is closed. Nothing releases it. A holder that keeps
// the error longer clones it with error_clone and releases the copy with
// error_destroy. allocator is the allocator of such a copy, and zero for a view.
Failure :: struct {
	kind:      Error_Kind,
	code:      i32,
	message:   string,
	allocator: mem.Allocator,
}

// Error is what every fallible procedure in this package returns. Its zero
// value is nil, which is success, so Error composes with or_return, or_else,
// and or_break.
Error :: union {
	Failure,
}

// error_make builds an Error from a classification, a native code, and a
// message. code is 0 when the backend has none to report. The Error borrows
// message and allocates nothing, so message has to outlive every copy of the
// Error: pass a string literal, or text the backend's connection keeps.
@(require_results)
error_make :: proc(kind: Error_Kind, code: i32, message: string) -> Error {
	return Failure{kind = kind, code = code, message = message}
}

// error_clone builds an Error that owns a copy of message, allocated with
// allocator, for a holder that keeps an error past the close of its
// connection. The holder releases the copy with error_destroy.
//
// If the copy cannot be allocated the Error keeps its kind and code and carries
// an empty message, so a failure never turns into success.
@(require_results)
error_clone :: proc(kind: Error_Kind, code: i32, message: string, allocator: mem.Allocator) -> Error {
	copied, alloc_err := mem.alloc_bytes_non_zeroed(len(message), 1, allocator)
	if alloc_err != nil {
		return Failure{kind = kind, code = code}
	}
	copy(copied, message)
	return Failure{kind = kind, code = code, message = string(copied), allocator = allocator}
}

// error_destroy releases the message err owns and sets err to nil. It does
// nothing for nil or for an Error whose message is borrowed. Every copy of the
// Error shares the one message, so destroy it once and drop the other copies.
error_destroy :: proc(err: ^Error) {
	failure, ok := err.(Failure)
	if ok && failure.allocator.procedure != nil {
		delete(failure.message, failure.allocator)
	}
	err^ = nil
}

// error_kind returns the classification of err, or .None when err is nil.
error_kind :: proc(err: Error) -> Error_Kind {
	failure, _ := err.(Failure)
	return failure.kind
}

// error_message returns the full diagnostic text of err, or "" when err is nil.
// The result is a view of the message err holds, valid until err is destroyed.
// Clone it to keep it longer.
error_message :: proc(err: Error) -> string {
	failure, _ := err.(Failure)
	return failure.message
}
