package journal

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"

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
error_is :: proc(error: Error, kind: Journal_Error) -> bool {
	own, is_own := error.(Journal_Error)
	return is_own && own == kind
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
error_text :: proc(error: Error, allocator := context.allocator) -> string {
	switch value in error {
	case Journal_Error:
		return fmt.aprint(JOURNAL_ERROR_TEXT[value], allocator = allocator)
	case db.Error:
		local := value
		return fmt.aprintf("database error: %s", db.error_message(&local), allocator = allocator)
	case os.Error:
		return fmt.aprintf("filesystem error: %s", os.error_string(value), allocator = allocator)
	case mem.Allocator_Error:
		return fmt.aprintf("allocation failed: %v", value, allocator = allocator)
	case json.Marshal_Error:
		return fmt.aprintf("a record could not be encoded: %v", value, allocator = allocator)
	}
	return fmt.aprint("no error", allocator = allocator)
}
