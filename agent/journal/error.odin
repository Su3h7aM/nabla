package journal

import "core:encoding/json"
import "core:mem"
import "core:os"

import "nabla:db"

// Journal_Error is a failure this package itself reports. Its zero value is
// success, so Error composes with or_return, or_else, and or_break.
Journal_Error :: enum {
	None,
	// The call does not fit the journal's lifecycle: it is on a closed journal
	// or on an open one, or an argument the storage needs is missing.
	Invalid_State,
	// This journal already holds a session for writing, or another process
	// holds the session the caller asked for.
	Claimed,
	// No session with that id exists in the journal.
	Not_Found,
	// The journal holds no session for writing, so an append naming one would
	// write outside the session this journal owns.
	Not_Claimed,
	// The journal is open for reading, and a read-only journal never writes.
	Read_Only,
	// The database was written by newer code. Running this build against it
	// would lose columns it does not know about, so it refuses.
	Schema_Too_New,
	// The database is not at the version this build reads: it is older than the
	// schema, or it holds tables this package did not create.
	Schema_Unknown,
	// Stored data does not have the shape the schema promises. The journal
	// keeps the session and seq of the offending row in `corrupt`.
	Corrupt,
	// A commit could not be written, so intent can no longer be recorded before
	// the effect it names. This failure latches: later appends are dropped and
	// later commits return it. The cause is kept in `failure_cause`. It also
	// reports storage that cannot meet what the journal assumes, such as a
	// database that will not accept write-ahead logging.
	Storage_Failed,
}

// Error is what every fallible procedure in this package returns. It carries
// the journal's own failure or the lower-level failure that caused it, so a
// caller can report the database, filesystem, or encoder message unchanged.
Error :: union #shared_nil {
	Journal_Error,
	db.Error,
	os.Error,
	mem.Allocator_Error,
	json.Marshal_Error,
}

// Corruption names the row whose stored data could not be read. It is what the
// harness reports alongside `.Corrupt`: a seq alone does not say which session
// the damaged row belongs to.
Corruption :: struct {
	session: Session_Id,
	seq:     Journal_Seq,
}

// error_is reports whether err is this package's own error of that kind. A
// failure from the database, the filesystem, the allocator, or the encoder is
// never one of these, so a caller checks for a composed failure by switching on
// the error instead.
error_is :: proc(err: Error, kind: Journal_Error) -> bool {
	local := err
	own, is_own := local.(Journal_Error)
	return is_own && own == kind
}
