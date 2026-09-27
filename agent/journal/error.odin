package journal

import "core:encoding/json"
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
