package journal

import "core:fmt"

import "nabla:db"

// SCHEMA_VERSION is the schema this build writes and reads. A database stamped
// with a higher version was written by newer code, and the columns this build
// names may not be the columns it has, so this build refuses rather than guess.
SCHEMA_VERSION :: 1

// The schema is one set of STRICT tables, so a column refuses a value of the
// wrong storage class instead of quietly storing it.
//
// Every table is append-only, and the fact that changes an earlier one is
// another record. `records` is the global order: its rowid is the journal's
// seq. `nodes` is the session tree, `branches` names where each branch forked,
// and `sessions` is one row per session. `artifacts` holds exact bytes a record
// points at by digest.
//
// Identity and correlation are columns, because those are the relationships a
// query uses; content is one level of JSON in `data`, because a payload changes
// shape as the harness grows. An absent id is NULL, and the seq of a node or a
// branch is the seq of the record that created it. A base node of 0 is the
// start of the session rather than an absent value, so the column is NOT NULL.
//
// Each element is one statement: the backend refuses a string holding more than
// one.
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

// migration_statements returns the statements that bring version to version + 1,
// or nil when there is no such migration.
@(private)
migration_statements :: proc(version: int) -> []string {
	if version == 1 { return MIGRATION_1[:] }
	return nil
}

// schema_migrate brings the database up to SCHEMA_VERSION, creating the schema
// when the database is empty. The version it reads and every statement it runs
// are in one immediate transaction, so two processes opening the same database
// cannot both migrate it: the second waits for the write lock and then sees the
// work already done.
@(private)
schema_migrate :: proc(j: ^Journal) -> Error {
	if err := db.exec(&j.conn, "BEGIN IMMEDIATE"); err != nil { return err }
	committed := false
	defer if !committed { _ = db.rollback(&j.conn) }

	version, version_err := schema_read_version(j)
	if version_err != nil { return version_err }
	if version > SCHEMA_VERSION { return Journal_Error.Schema_Too_New }
	if version == 0 {
		empty, empty_err := schema_is_empty(j)
		if empty_err != nil { return empty_err }
		if !empty { return Journal_Error.Schema_Unknown }
	}

	for from := version; from < SCHEMA_VERSION; from += 1 {
		statements := migration_statements(from + 1)
		if statements == nil { return Journal_Error.Schema_Unknown }
		for statement in statements {
			if err := db.exec(&j.conn, statement); err != nil { return err }
		}
		// The version is stamped in the same transaction as the statements it
		// describes, so a failure leaves the database at the version it started
		// from rather than at one whose statements did not all land.
		if err := db.exec(&j.conn, fmt.tprintf("PRAGMA user_version = %d", from + 1)); err != nil { return err }
	}

	if err := db.commit(&j.conn); err != nil { return err }
	committed = true
	return nil
}

// schema_read_version is the version stamped in the database, 0 when nothing
// has been written there yet.
@(private)
schema_read_version :: proc(j: ^Journal) -> (int, Error) {
	rows: db.Rows
	if err := db.query(&j.conn, &rows, "PRAGMA user_version"); err != nil { return 0, err }
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return 0, next_err }
	if !has_row { return 0, Journal_Error.Corrupt }
	version, convert_err := db.as_i64(values[0])
	if convert_err != nil { return 0, convert_err }
	return int(version), nil
}

// schema_is_empty reports whether the database holds no table of its own. A
// database with tables and no version is someone else's, and migrating it would
// mean adding tables to a file this package does not own.
@(private)
schema_is_empty :: proc(j: ^Journal) -> (bool, Error) {
	query := "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
	rows: db.Rows
	if err := db.query(&j.conn, &rows, query); err != nil { return false, err }
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return false, next_err }
	if !has_row { return true, nil }
	count, convert_err := db.as_i64(values[0])
	if convert_err != nil { return false, convert_err }
	return count == 0, nil
}
