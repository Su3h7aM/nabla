// Package session stores a session's durable history in SQLite.
//
// A session is one conversational context: a header, the turns the user and the
// harness worked through, the model requests each turn made, and the ordered
// entries that record what was said, what tools were proposed, what the harness
// committed to running, and what came back. SQLite is the authority for all of
// it. Memory holds only the work in flight.
//
// # What this package owns
//
// This package owns the schema, its forward migrations, the write transactions
// that keep a turn consistent, and the queries that read history back. It does
// not own the turn loop, the model client, or tool execution; the harness calls
// into it at the boundaries where something becomes durable.
//
// # Ordering
//
// Entries are ordered by a per-session sequence number, never by a timestamp.
// The sequence is the conversation. Wall-clock times say when something
// happened; they do not say what happened first.
//
// # One writer
//
// A database connection is not safe for concurrent use, so one store owns one
// connection and one caller drives it. On top of that, a session is claimed for
// writing while the harness runs it, so a second process cannot execute the
// same session and interleave its history. Reads do not need the claim.
//
// # Durability
//
// Writes run in short immediate transactions that never span a model request or
// a tool execution. A record of intent is committed before its effect begins,
// which is what makes an interrupted session legible: a call with no dispatch
// never ran, and a dispatch with no result may have run.
package session
