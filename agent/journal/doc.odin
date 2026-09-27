// Package journal is the harness's durable execution record: one SQLite
// database whose `records` table is the global commit order, with the session
// tree in `nodes` and `branches`, one row per session in `sessions`, and exact
// bytes by digest in `artifacts`. It owns no execution type; the harness maps
// its own onto records and nodes.
//
// A Journal is one connection used by one thread, and writes for at most one
// session, claimed with a lock the kernel drops when the process dies. Appends
// are buffered; commit writes them in one transaction. A caller commits a
// barrier before the effect it names. A failed commit latches: the journal
// writes nothing more.
package journal
