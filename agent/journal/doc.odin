// Package journal is the harness's durable execution record.
//
// # What it owns
//
// One SQLite database holds everything the harness commits. Every fact is one
// row in `records`, in global commit order. `nodes` is the session tree those
// facts describe, `branches` names where each branch started, and `sessions`
// holds one row per session. A payload is one level of JSON in `data`, and the
// exact bytes of a prompt or a rendered result are in `body`. This package
// owns no execution type: the harness maps its own types onto these, and the
// journal never imports it.
//
// # One writer per session
//
// A connection belongs to one thread. On top of that, a session is claimed for
// writing with a lock beside the database, so a second process cannot run the
// same session and interleave its history. An append for a session this journal
// has not claimed is refused; a record that belongs to no session, such as
// `run.started`, may be appended with no claim. Frontends and diagnostics open
// a read-only journal, which never claims, migrates, or writes.
//
// # Durability
//
// An append is buffered in memory. Commit writes every buffered item in one
// immediate transaction and returns only once SQLite has it; a caller commits a
// barrier, such as `session.created`, `request.sent`, `tool.admitted`, or
// `tool.completed`, before the effect it names begins. An observation may wait
// for the batch limits (JOURNAL_BATCH_RECORDS, JOURNAL_BATCH_BYTES,
// JOURNAL_BATCH_AGE) and may be lost in a crash; a barrier may not. A failed
// commit latches Storage_Failed: every later append is dropped and every later
// commit returns the failure.
package journal
