package journal

import "base:runtime"
import "core:fmt"

import "nabla:db"

// SCHEMA_VERSION is the schema this build writes and reads. A database stamped
// with a higher version was written by newer code, and the columns this build
// names may not be the columns it has, so this build refuses rather than guess.
SCHEMA_VERSION :: 1

// Every table is append-only and STRICT. The rowid of `records` is the global
// seq; a node or branch takes the seq of the record that created it. An absent
// id is NULL. Each element is one statement, as the backend requires.
@(private)
MIGRATION_1 := [?]string {
	`CREATE TABLE records (
		seq         INTEGER PRIMARY KEY,
		time_ms     INTEGER NOT NULL,
		mono_ns     INTEGER NOT NULL,
		run         BLOB NOT NULL CHECK (length(run) = 16),
		kind        TEXT NOT NULL,
		session     BLOB CHECK (session IS NULL OR length(session) = 16),
		branch      INTEGER,
		node        INTEGER,
		turn        INTEGER,
		request     INTEGER,
		attempt     INTEGER,
		job         INTEGER,
		call        INTEGER,
		parent_call INTEGER,
		task        TEXT,
		subagent    BLOB CHECK (subagent IS NULL OR length(subagent) = 16),
		hook        TEXT,
		provider    TEXT,
		model       TEXT,
		data        TEXT NOT NULL,
		body        BLOB
	) STRICT`,
	`CREATE INDEX records_session_seq ON records (session, seq)`,
	`CREATE INDEX records_session_call ON records (session, call) WHERE call IS NOT NULL`,
	`CREATE INDEX records_session_kind_seq ON records (session, kind, seq)`,
	`CREATE INDEX records_session_node ON records (session, node) WHERE node IS NOT NULL`,
	`CREATE INDEX records_session_request ON records (session, request) WHERE request IS NOT NULL`,
	`CREATE TABLE nodes (
		session BLOB NOT NULL CHECK (length(session) = 16),
		node    INTEGER NOT NULL,
		parent  INTEGER,
		branch  INTEGER NOT NULL,
		kind    TEXT NOT NULL,
		turn    INTEGER,
		covers  INTEGER,
		seq     INTEGER NOT NULL,
		data    TEXT NOT NULL,
		body    BLOB,
		PRIMARY KEY (session, node)
	) STRICT`,
	`CREATE INDEX nodes_session_branch_node ON nodes (session, branch, node)`,
	`CREATE TABLE branches (
		session   BLOB NOT NULL CHECK (length(session) = 16),
		branch    INTEGER NOT NULL,
		base_node INTEGER NOT NULL,
		seq       INTEGER NOT NULL,
		PRIMARY KEY (session, branch)
	) STRICT`,
	`CREATE TABLE sessions (
		session        BLOB NOT NULL PRIMARY KEY CHECK (length(session) = 16),
		created_ms     INTEGER NOT NULL CHECK (created_ms > 0),
		workspace      TEXT NOT NULL CHECK (length(workspace) > 0),
		parent_session BLOB CHECK (parent_session IS NULL OR length(parent_session) = 16),
		parent_call    INTEGER,
		role           TEXT NOT NULL CHECK (role IN ('main', 'subagent'))
	) STRICT`,
	`CREATE TABLE artifacts (
		digest     BLOB PRIMARY KEY,
		kind       TEXT NOT NULL,
		created_ms INTEGER NOT NULL,
		bytes      BLOB
	) STRICT`,
}

// schema_migrate creates the schema of an empty database inside one immediate
// transaction, so two processes opening one database never both migrate it.
@(private, require_results)
schema_migrate :: proc(journal: ^Journal) -> (error: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	db.exec(&journal.connection, "BEGIN IMMEDIATE") or_return
	// The rollback is teardown for a failure already on its way out.
	defer if error != nil { _ = db.rollback(&journal.connection) }

	version := schema_version(journal) or_return
	if version > SCHEMA_VERSION { return Journal_Error.Schema_Too_New }
	if version == 0 {
		// Tables without a version belong to someone else.
		tables := query_int(journal, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'", nil) or_return
		if tables != 0 { return Journal_Error.Schema_Unknown }
		for statement in MIGRATION_1 { db.exec(&journal.connection, statement) or_return }
		db.exec(&journal.connection, fmt.tprintf("PRAGMA user_version = %d", SCHEMA_VERSION)) or_return
	}
	return db.commit(&journal.connection)
}

@(private, require_results)
schema_version :: proc(journal: ^Journal) -> (int, Error) {
	version, error := query_int(journal, "PRAGMA user_version", nil)
	return int(version), error
}
