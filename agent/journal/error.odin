package journal

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import "nabla:db"

Journal_Error :: enum {
	None,
	// Another journal holds the session's writer claim.
	Claimed,
	// The session, or a read-only journal's database, does not exist.
	Not_Found,
	// The database was written by a newer build.
	Schema_Too_New,
	// The database is at another version or holds tables this package did not create.
	Schema_Unknown,
	// A stored row does not have the shape the schema promises; see Journal.corrupt.
	Corrupt,
	// The storage cannot keep the durability the journal assumes, such as a
	// filesystem that refuses write-ahead logging.
	Storage_Failed,
}

// Error is the journal's own failure or the lower one it passes through
// unchanged, so the harness can report the database or filesystem message.
Error :: union #shared_nil {
	Journal_Error,
	db.Error,
	os.Error,
	mem.Allocator_Error,
	json.Marshal_Error,
}

// error_is reports whether error is this package's own error of that kind.
@(require_results)
error_is :: proc(error: Error, kind: Journal_Error) -> bool {
	own, is_own := error.(Journal_Error)
	return is_own && own == kind
}

// error_is_busy reports whether error is another writer holding the database
// longer than the busy timeout, which a later attempt may get past.
@(require_results)
error_is_busy :: proc(error: Error) -> bool {
	database, is_database := error.(db.Error)
	return is_database && db.error_kind(database) == .Busy
}

JOURNAL_ERROR_TEXT := [Journal_Error]string {
	.None           = "no error",
	.Claimed        = "another process holds the session",
	.Not_Found      = "the session or journal does not exist",
	.Schema_Too_New = "the journal was written by a newer version",
	.Schema_Unknown = "the journal has an unknown schema",
	.Corrupt        = "the journal holds damaged data",
	.Storage_Failed = "the storage cannot keep the journal durable",
}

// error_text describes error for a person, in allocator.
@(require_results)
error_text :: proc(error: Error, allocator := context.allocator) -> string {
	switch value in error {
	case Journal_Error:
		return fmt.aprint(JOURNAL_ERROR_TEXT[value], allocator = allocator)
	case db.Error:
		return fmt.aprintf("database error: %s", db.error_message(value), allocator = allocator)
	case os.Error:
		return fmt.aprintf("filesystem error: %s", os.error_string(value), allocator = allocator)
	case mem.Allocator_Error:
		return fmt.aprintf("allocation failed: %v", value, allocator = allocator)
	case json.Marshal_Error:
		return fmt.aprintf("a record could not be encoded: %v", value, allocator = allocator)
	}
	return fmt.aprint("no error", allocator = allocator)
}

// A database error the journal returns borrows the text of the connection that
// failed: it is valid until the journal's connection closes, and nobody
// releases it. The latched failure is a copy in the
// journal's allocator, valid until close. The errors open and close return
// outlive the connection, so they are copied into the calling thread's temp
// allocator.

// error_detach copies the text of a database error into the temp allocator, for
// an error that must outlive the connection it came from.
@(private)
error_detach :: proc(error: Error) -> Error {
	database, is_database := error.(db.Error)
	if !is_database { return error }
	failure, _ := database.(db.Failure)
	copied, clone_error := strings.clone(failure.message, context.temp_allocator)
	if clone_error != nil { return db.error_make(failure.kind, failure.code, "") }
	return db.error_make(failure.kind, failure.code, copied)
}

// latch keeps the first failure that stops journal from writing.
@(private)
latch :: proc(journal: ^Journal, error: Error) {
	if journal.failure != nil { return }
	journal.failure = error
	if database, is_database := error.(db.Error); is_database {
		failure, _ := database.(db.Failure)
		journal.failure = db.error_clone(failure.kind, failure.code, failure.message, journal.allocator)
	}
}

// error_release frees the message of a latched database error and sets error to
// nil; any other error owns nothing.
@(private)
error_release :: proc(error: ^Error) {
	if database, is_database := error.(db.Error); is_database {
		db.error_destroy(&database)
	}
	error^ = nil
}
