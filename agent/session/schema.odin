package session

import "core:fmt"

import "nabla:db"

// SCHEMA_VERSION is the version this package writes. A database at a higher
// version was written by newer code, and this package refuses it rather than
// risk losing columns it does not know about.
SCHEMA_VERSION :: 2

// The schema is deliberately small. Identity, order, ownership, and
// correlation are columns, because those are the relationships the database has
// to enforce or query. Content is a typed JSON payload, because it changes shape
// as the harness grows and has no relational structure worth enforcing.
//
// STRICT tables are used so a column refuses a value of the wrong storage class
// instead of quietly storing it.
//
// Each migration element is one statement: the backend refuses a string holding
// more than one.
@(private)
MIGRATION_1 := [?]string {
	`CREATE TABLE sessions (
		id             TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 32),
		created_at_ms  INTEGER NOT NULL CHECK (created_at_ms > 0),
		updated_at_ms  INTEGER NOT NULL CHECK (updated_at_ms >= created_at_ms),
		workspace      TEXT NOT NULL CHECK (length(workspace) > 0),
		title          TEXT NOT NULL DEFAULT '',
		provider       TEXT NOT NULL DEFAULT '',
		model          TEXT NOT NULL DEFAULT '',
		archived_at_ms INTEGER CHECK (archived_at_ms IS NULL OR archived_at_ms >= created_at_ms)
	) STRICT`,
	`CREATE INDEX sessions_recent ON sessions (updated_at_ms DESC, id DESC)`,
	`CREATE INDEX sessions_workspace ON sessions (workspace, updated_at_ms DESC)`,
	`CREATE TABLE turns (
		session_id     TEXT NOT NULL,
		turn_no        INTEGER NOT NULL CHECK (turn_no > 0),
		started_at_ms  INTEGER NOT NULL CHECK (started_at_ms > 0),
		finished_at_ms INTEGER CHECK (finished_at_ms IS NULL OR finished_at_ms >= started_at_ms),
		status         TEXT NOT NULL CHECK (status IN ('running', 'completed', 'failed', 'cancelled', 'interrupted')),
		error_json     TEXT,
		PRIMARY KEY (session_id, turn_no),
		FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE,
		CHECK ((status = 'running' AND finished_at_ms IS NULL) OR (status <> 'running' AND finished_at_ms IS NOT NULL))
	) STRICT`,
	`CREATE UNIQUE INDEX turns_running ON turns (session_id) WHERE status = 'running'`,
	`CREATE TABLE requests (
		session_id         TEXT NOT NULL,
		request_no         INTEGER NOT NULL CHECK (request_no > 0),
		turn_no            INTEGER,
		purpose            TEXT NOT NULL CHECK (purpose IN ('response', 'compaction')),
		started_at_ms      INTEGER NOT NULL CHECK (started_at_ms > 0),
		finished_at_ms     INTEGER CHECK (finished_at_ms IS NULL OR finished_at_ms >= started_at_ms),
		status             TEXT NOT NULL CHECK (status IN ('running', 'completed', 'failed', 'cancelled', 'interrupted')),
		provider           TEXT NOT NULL,
		model_requested    TEXT NOT NULL,
		model_resolved     TEXT,
		api                TEXT NOT NULL,
		config_json        TEXT NOT NULL,
		input_json         TEXT NOT NULL,
		response_json      TEXT,
		error_json         TEXT,
		input_tokens       INTEGER CHECK (input_tokens IS NULL OR input_tokens >= 0),
		output_tokens      INTEGER CHECK (output_tokens IS NULL OR output_tokens >= 0),
		cache_read_tokens  INTEGER CHECK (cache_read_tokens IS NULL OR cache_read_tokens >= 0),
		cache_write_tokens INTEGER CHECK (cache_write_tokens IS NULL OR cache_write_tokens >= 0),
		PRIMARY KEY (session_id, request_no),
		FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE,
		FOREIGN KEY (session_id, turn_no) REFERENCES turns (session_id, turn_no),
		CHECK ((status = 'running' AND finished_at_ms IS NULL) OR (status <> 'running' AND finished_at_ms IS NOT NULL)),
		CHECK (purpose <> 'response' OR turn_no IS NOT NULL)
	) STRICT`,
	`CREATE INDEX requests_turn ON requests (session_id, turn_no, request_no)`,
	`CREATE TABLE entries (
		session_id    TEXT NOT NULL,
		seq           INTEGER NOT NULL CHECK (seq > 0),
		turn_no       INTEGER,
		request_no    INTEGER,
		created_at_ms INTEGER NOT NULL CHECK (created_at_ms > 0),
		kind          TEXT NOT NULL CHECK (kind IN ('user', 'assistant', 'reasoning', 'tool_call', 'tool_dispatch', 'tool_result', 'checkpoint')),
		related_seq   INTEGER,
		payload_json  TEXT NOT NULL,
		PRIMARY KEY (session_id, seq),
		FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE,
		FOREIGN KEY (session_id, turn_no) REFERENCES turns (session_id, turn_no),
		FOREIGN KEY (session_id, request_no) REFERENCES requests (session_id, request_no),
		FOREIGN KEY (session_id, related_seq) REFERENCES entries (session_id, seq),
		CHECK ((kind IN ('tool_dispatch', 'tool_result') AND related_seq IS NOT NULL) OR (kind NOT IN ('tool_dispatch', 'tool_result') AND related_seq IS NULL)),
		CHECK (related_seq IS NULL OR related_seq < seq)
	) STRICT`,
	`CREATE INDEX entries_turn ON entries (session_id, turn_no, seq)`,
	`CREATE INDEX entries_request ON entries (session_id, request_no, seq)`,
	`CREATE INDEX entries_kind ON entries (session_id, kind, seq)`,
	`CREATE UNIQUE INDEX entries_dispatch ON entries (session_id, related_seq) WHERE kind = 'tool_dispatch'`,
	`CREATE UNIQUE INDEX entries_result ON entries (session_id, related_seq) WHERE kind = 'tool_result'`,
}

// MIGRATION_2 adds the selection: the serving identity a launch restores. It is
// not conversation history, so it belongs to no session and is not ordered; the
// single-row constraint is what says there is exactly one of it.
@(private)
MIGRATION_2 := [?]string {
	`CREATE TABLE selection (
		id       INTEGER PRIMARY KEY CHECK (id = 1),
		provider TEXT NOT NULL CHECK (length(provider) > 0),
		model    TEXT NOT NULL CHECK (length(model) > 0),
		effort   TEXT NOT NULL DEFAULT ''
	) STRICT`,
}

// migration_statements returns the statements that bring version to
// version + 1, or nil when there is no such migration.
@(private)
migration_statements :: proc(version: int) -> []string {
	switch version {
	case 1:
		return MIGRATION_1[:]
	case 2:
		return MIGRATION_2[:]
	}
	return nil
}

// schema_migrate brings the database up to SCHEMA_VERSION, creating the schema
// when the database is empty. The version it read and every statement it runs
// are in one immediate transaction, so two processes opening the same database
// cannot both migrate it: the second waits for the write lock and then sees the
// work already done.
schema_migrate :: proc(store: ^Store) -> Error {
	if err := db.exec(&store.conn, "BEGIN IMMEDIATE"); err != nil {
		return storage_error("begin migration", err)
	}
	committed := false
	defer if !committed { db.rollback(&store.conn) }

	version, version_err := schema_read_version(store)
	if version_err != nil { return version_err }
	if version > SCHEMA_VERSION {
		return error_make(.Schema_Too_New, fmt.tprintf("the database is at schema %d; this build writes %d", version, SCHEMA_VERSION))
	}
	if version == 0 {
		empty, empty_err := schema_is_empty(store)
		if empty_err != nil { return empty_err }
		if !empty {
			return error_make(.Schema_Unknown, "the database holds tables this package did not create")
		}
	}

	for from := version; from < SCHEMA_VERSION; from += 1 {
		statements := migration_statements(from + 1)
		if statements == nil {
			return error_make(.Storage, fmt.tprintf("no migration writes schema %d", from + 1))
		}
		for statement in statements {
			if err := db.exec(&store.conn, statement); err != nil {
				return storage_error(fmt.tprintf("apply schema %d", from + 1), err)
			}
		}
		// The version is stamped in the same transaction as the statements it
		// describes, so a failure leaves the database at the version it started
		// from rather than at one whose statements did not all land.
		if err := db.exec(&store.conn, fmt.tprintf("PRAGMA user_version = %d", from + 1)); err != nil {
			return storage_error("stamp schema version", err)
		}
	}

	if err := db.commit(&store.conn); err != nil {
		return storage_error("commit migration", err)
	}
	committed = true
	return nil
}

@(private)
schema_read_version :: proc(store: ^Store) -> (int, Error) {
	rows: db.Rows
	if err := db.query(&store.conn, &rows, "PRAGMA user_version"); err != nil {
		return 0, storage_error("read schema version", err)
	}
	defer db.rows_close(&rows)
	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return 0, storage_error("read schema version", next_err) }
	if !has_row { return 0, error_make(.Corrupt, "PRAGMA user_version returned no row") }
	version, convert_err := db.as_i64(values[0])
	if convert_err != nil { return 0, corrupt_error("read schema version", convert_err) }
	return int(version), nil
}

@(private)
schema_is_empty :: proc(store: ^Store) -> (bool, Error) {
	rows: db.Rows
	query := "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
	if err := db.query(&store.conn, &rows, query); err != nil {
		return false, storage_error("inspect database", err)
	}
	defer db.rows_close(&rows)
	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return false, storage_error("inspect database", next_err) }
	if !has_row { return true, nil }
	count, convert_err := db.as_i64(values[0])
	if convert_err != nil { return false, corrupt_error("inspect database", convert_err) }
	return count == 0, nil
}
