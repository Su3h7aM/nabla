package journal

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"

import "nabla:db"

// SCHEMA_VERSION is the schema this build writes and reads. A database stamped
// with a higher version was written by newer code, and the columns this build
// names may not be the columns it has, so this build refuses rather than guess.
SCHEMA_VERSION :: 1

// Every table is append-only and STRICT. The rowid of `records` is the global
// seq. `records.kind` and `nodes.kind` are the integer codes of Record_Kind and
// Node_Kind. `data` holds the JSON payload. `session.titled` also writes
// `record_session_titled`. Assistant and Checkpoint nodes also write
// `node_assistant` and `node_checkpoint`. User nodes also write `node_user`
// and `node_attachment`. Results nodes also write `node_result_call`. The other
// families still have only the JSON.
// An absent id is NULL.
// Each element is one statement, as the backend requires. Foreign keys are
// declared and not enforced until the connection turns them on.
@(private)
SCHEMA := [?]string {
	`CREATE TABLE sessions (
		session        BLOB PRIMARY KEY CHECK (length(session) = 16),
		created_ms     INTEGER NOT NULL CHECK (created_ms > 0),
		workspace      TEXT NOT NULL CHECK (length(workspace) > 0),
		parent_session BLOB CHECK (parent_session IS NULL OR length(parent_session) = 16)
		                 REFERENCES sessions(session) DEFERRABLE INITIALLY DEFERRED,
		parent_call    INTEGER CHECK (parent_call IS NULL OR parent_call > 0),
		role           INTEGER NOT NULL CHECK (role IN (0, 1))
	) STRICT`,
	`CREATE TABLE artifacts (
		digest     BLOB PRIMARY KEY CHECK (length(digest) = 32),
		kind       TEXT NOT NULL CHECK (length(kind) > 0),
		created_ms INTEGER NOT NULL,
		bytes      BLOB
	) STRICT`,
	`CREATE TABLE records (
		seq         INTEGER PRIMARY KEY,
		time_ms     INTEGER NOT NULL,
		mono_ns     INTEGER NOT NULL,
		run         BLOB NOT NULL CHECK (length(run) = 16),
		kind        INTEGER NOT NULL CHECK (kind BETWEEN 0 AND 44),
		session     BLOB CHECK (session IS NULL OR length(session) = 16),
		branch      INTEGER CHECK (branch IS NULL OR branch > 0),
		node        INTEGER CHECK (node IS NULL OR node > 0),
		turn        INTEGER CHECK (turn IS NULL OR turn > 0),
		request     INTEGER CHECK (request IS NULL OR request > 0),
		attempt     INTEGER CHECK (attempt IS NULL OR attempt > 0),
		call        INTEGER CHECK (call IS NULL OR call > 0),
		parent_call INTEGER CHECK (parent_call IS NULL OR parent_call > 0),
		subagent    BLOB CHECK (subagent IS NULL OR length(subagent) = 16),
		provider    TEXT,
		model       TEXT,
		body        BLOB,
		data        TEXT NOT NULL,
		FOREIGN KEY (session) REFERENCES sessions(session) DEFERRABLE INITIALLY DEFERRED,
		FOREIGN KEY (session, branch) REFERENCES branches(session, branch) DEFERRABLE INITIALLY DEFERRED,
		FOREIGN KEY (session, node) REFERENCES nodes(session, node) DEFERRABLE INITIALLY DEFERRED
	) STRICT`,
	`CREATE TABLE branches (
		session   BLOB NOT NULL CHECK (length(session) = 16) REFERENCES sessions(session),
		branch    INTEGER NOT NULL CHECK (branch > 0),
		base_node INTEGER NOT NULL CHECK (base_node >= 0),
		seq       INTEGER NOT NULL REFERENCES records(seq),
		PRIMARY KEY (session, branch)
	) STRICT`,
	`CREATE TABLE nodes (
		session BLOB NOT NULL CHECK (length(session) = 16) REFERENCES sessions(session),
		node    INTEGER NOT NULL CHECK (node > 0),
		parent  INTEGER CHECK (parent IS NULL OR parent > 0),
		branch  INTEGER NOT NULL CHECK (branch > 0),
		kind    INTEGER NOT NULL CHECK (kind BETWEEN 0 AND 5),
		turn    INTEGER CHECK (turn IS NULL OR turn > 0),
		covers  INTEGER CHECK (covers IS NULL OR covers > 0),
		seq     INTEGER NOT NULL REFERENCES records(seq),
		data    TEXT NOT NULL,
		body    BLOB,
		PRIMARY KEY (session, node),
		FOREIGN KEY (session, branch) REFERENCES branches(session, branch),
		FOREIGN KEY (session, covers) REFERENCES nodes(session, node) DEFERRABLE INITIALLY DEFERRED
	) STRICT`,
	`CREATE TABLE record_run_started (
		seq INTEGER PRIMARY KEY REFERENCES records(seq),
		pid INTEGER NOT NULL CHECK (pid > 0)
	) STRICT`,
	`CREATE TABLE record_session_titled (
		seq   INTEGER PRIMARY KEY REFERENCES records(seq),
		title TEXT NOT NULL CHECK (length(title) > 0)
	) STRICT`,
	`CREATE TABLE record_session_recovered (
		seq      INTEGER PRIMARY KEY REFERENCES records(seq),
		turns    INTEGER NOT NULL CHECK (turns >= 0),
		requests INTEGER NOT NULL CHECK (requests >= 0),
		calls    INTEGER NOT NULL CHECK (calls >= 0),
		results  INTEGER NOT NULL CHECK (results >= 0)
	) STRICT`,
	`CREATE TABLE record_session_claimed (
		seq     INTEGER PRIMARY KEY REFERENCES records(seq),
		resumed INTEGER NOT NULL CHECK (resumed IN (0, 1))
	) STRICT`,
	`CREATE TABLE record_environment (
		seq          INTEGER PRIMARY KEY REFERENCES records(seq),
		instructions TEXT
	) STRICT`,
	`CREATE TABLE record_environment_server (
		seq                  INTEGER NOT NULL REFERENCES record_environment(seq),
		ordinal              INTEGER NOT NULL CHECK (ordinal >= 0),
		id                   TEXT NOT NULL CHECK (length(id) > 0),
		executable           TEXT NOT NULL CHECK (length(executable) > 0),
		working_directory    TEXT,
		discovery_timeout_ms INTEGER NOT NULL,
		call_timeout_ms      INTEGER NOT NULL,
		PRIMARY KEY (seq, ordinal)
	) STRICT`,
	`CREATE TABLE record_environment_argument (
		seq            INTEGER NOT NULL,
		server_ordinal INTEGER NOT NULL,
		ordinal        INTEGER NOT NULL CHECK (ordinal >= 0),
		argument       TEXT NOT NULL,
		PRIMARY KEY (seq, server_ordinal, ordinal),
		FOREIGN KEY (seq, server_ordinal) REFERENCES record_environment_server(seq, ordinal)
	) STRICT`,
	`CREATE TABLE record_environment_variable (
		seq            INTEGER NOT NULL,
		server_ordinal INTEGER NOT NULL,
		ordinal        INTEGER NOT NULL CHECK (ordinal >= 0),
		name           TEXT NOT NULL CHECK (length(name) > 0),
		value          TEXT,
		PRIMARY KEY (seq, server_ordinal, ordinal),
		FOREIGN KEY (seq, server_ordinal) REFERENCES record_environment_server(seq, ordinal)
	) STRICT`,
	`CREATE TABLE record_environment_tool (
		seq            INTEGER NOT NULL,
		server_ordinal INTEGER NOT NULL,
		ordinal        INTEGER NOT NULL CHECK (ordinal >= 0),
		remote_name    TEXT NOT NULL CHECK (length(remote_name) > 0),
		name           TEXT,
		enabled        INTEGER NOT NULL CHECK (enabled IN (0, 1)),
		PRIMARY KEY (seq, server_ordinal, ordinal),
		FOREIGN KEY (seq, server_ordinal) REFERENCES record_environment_server(seq, ordinal)
	) STRICT`,
	`CREATE TABLE record_user_input (
		seq    INTEGER PRIMARY KEY REFERENCES records(seq),
		origin INTEGER NOT NULL CHECK (origin BETWEEN 0 AND 4)
	) STRICT`,
	`CREATE TABLE record_turn_started (
		seq          INTEGER PRIMARY KEY REFERENCES records(seq),
		instructions BLOB NOT NULL CHECK (length(instructions) = 32) REFERENCES artifacts(digest),
		manifest     BLOB NOT NULL CHECK (length(manifest) = 32) REFERENCES artifacts(digest),
		effort       TEXT
	) STRICT`,
	`CREATE TABLE record_turn_completed (
		seq     INTEGER PRIMARY KEY REFERENCES records(seq),
		outcome INTEGER NOT NULL CHECK (outcome BETWEEN 0 AND 3),
		detail  TEXT,
		reason  TEXT,
		cause   TEXT
	) STRICT`,
	`CREATE TABLE record_request_prepared (
		seq            INTEGER PRIMARY KEY REFERENCES records(seq),
		purpose        INTEGER NOT NULL CHECK (purpose IN (0, 1)),
		api            TEXT NOT NULL CHECK (length(api) > 0),
		transport      TEXT NOT NULL CHECK (length(transport) > 0),
		estimate       INTEGER NOT NULL,
		context_window INTEGER NOT NULL,
		messages       INTEGER NOT NULL CHECK (messages >= 0),
		tools          INTEGER NOT NULL CHECK (tools >= 0),
		replay_refused INTEGER NOT NULL CHECK (replay_refused >= 0)
	) STRICT`,
	`CREATE TABLE record_request_admitted (
		seq                 INTEGER PRIMARY KEY REFERENCES records(seq),
		decision            INTEGER NOT NULL CHECK (decision BETWEEN 0 AND 2),
		estimate            INTEGER NOT NULL,
		context_window      INTEGER NOT NULL,
		instructions_tokens INTEGER NOT NULL,
		tools_tokens        INTEGER NOT NULL,
		conversation_tokens INTEGER NOT NULL
	) STRICT`,
	`CREATE TABLE record_request_sent (
		seq         INTEGER PRIMARY KEY REFERENCES records(seq),
		purpose     INTEGER NOT NULL CHECK (purpose IN (0, 1)),
		api         TEXT NOT NULL CHECK (length(api) > 0),
		recovery    TEXT NOT NULL CHECK (length(recovery) > 0),
		body_digest BLOB CHECK (body_digest IS NULL OR length(body_digest) = 32),
		body_bytes  INTEGER NOT NULL CHECK (body_bytes >= 0)
	) STRICT`,
	`CREATE TABLE record_response (
		seq                INTEGER PRIMARY KEY REFERENCES records(seq),
		api                TEXT NOT NULL CHECK (length(api) > 0),
		model_resolved     TEXT,
		finish             INTEGER NOT NULL CHECK (finish BETWEEN 0 AND 5),
		input_tokens       INTEGER,
		output_tokens      INTEGER,
		reasoning_tokens   INTEGER,
		cache_read_tokens  INTEGER,
		cache_write_tokens INTEGER,
		cost               REAL
	) STRICT`,
	`CREATE TABLE record_response_rejected (
		seq                 INTEGER PRIMARY KEY REFERENCES records(seq),
		kind                TEXT,
		failure_class       TEXT,
		status              INTEGER NOT NULL,
		provider_code       TEXT,
		provider_request_id TEXT,
		retry_after_ms      INTEGER,
		retry_directive     TEXT,
		transport_cause     TEXT,
		text_exposed        INTEGER NOT NULL CHECK (text_exposed IN (0, 1)),
		completion_accepted INTEGER NOT NULL CHECK (completion_accepted IN (0, 1)),
		recovery            TEXT,
		delay_ms            INTEGER NOT NULL,
		detail              TEXT,
		input_tokens        INTEGER,
		output_tokens       INTEGER,
		reasoning_tokens    INTEGER,
		cache_read_tokens   INTEGER,
		cache_write_tokens  INTEGER,
		cost                REAL
	) STRICT`,
	`CREATE TABLE record_request_interrupted (
		seq                INTEGER PRIMARY KEY REFERENCES records(seq),
		detail             TEXT,
		input_tokens       INTEGER,
		output_tokens      INTEGER,
		reasoning_tokens   INTEGER,
		cache_read_tokens  INTEGER,
		cache_write_tokens INTEGER,
		cost               REAL
	) STRICT`,
	`CREATE TABLE record_retry_scheduled (
		seq          INTEGER PRIMARY KEY REFERENCES records(seq),
		purpose      INTEGER NOT NULL CHECK (purpose IN (0, 1)),
		reason       TEXT NOT NULL CHECK (length(reason) > 0),
		next_attempt INTEGER NOT NULL CHECK (next_attempt > 0),
		delay_ms     INTEGER NOT NULL CHECK (delay_ms >= 0)
	) STRICT`,
	`CREATE TABLE record_retry_completed (
		seq     INTEGER PRIMARY KEY REFERENCES records(seq),
		purpose INTEGER NOT NULL CHECK (purpose IN (0, 1)),
		outcome INTEGER NOT NULL CHECK (outcome IN (0, 1))
	) STRICT`,
	`CREATE TABLE record_tool_proposed (
		seq         INTEGER PRIMARY KEY REFERENCES records(seq),
		provider_id TEXT NOT NULL CHECK (length(provider_id) > 0),
		item_id     TEXT,
		name        TEXT NOT NULL CHECK (length(name) > 0)
	) STRICT`,
	`CREATE TABLE record_tool_admitted (
		seq        INTEGER PRIMARY KEY REFERENCES records(seq),
		tool       TEXT NOT NULL CHECK (length(tool) > 0),
		background INTEGER NOT NULL CHECK (background IN (0, 1))
	) STRICT`,
	`CREATE TABLE record_tool_repair (
		seq     INTEGER NOT NULL REFERENCES record_tool_admitted(seq),
		ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
		repair  TEXT NOT NULL CHECK (length(repair) > 0),
		PRIMARY KEY (seq, ordinal)
	) STRICT`,
	`CREATE TABLE record_tool_started (
		seq  INTEGER PRIMARY KEY REFERENCES records(seq),
		tool TEXT NOT NULL CHECK (length(tool) > 0)
	) STRICT`,
	`CREATE TABLE record_completion (
		seq     INTEGER PRIMARY KEY REFERENCES records(seq),
		outcome INTEGER NOT NULL CHECK (outcome BETWEEN 0 AND 9),
		detail  TEXT,
		tool    TEXT
	) STRICT`,
	`CREATE TABLE record_attachment (
		seq        INTEGER NOT NULL REFERENCES records(seq),
		ordinal    INTEGER NOT NULL CHECK (ordinal >= 0),
		media_type TEXT NOT NULL CHECK (length(media_type) > 0),
		name       TEXT NOT NULL,
		digest     BLOB NOT NULL CHECK (length(digest) = 32) REFERENCES artifacts(digest),
		PRIMARY KEY (seq, ordinal)
	) STRICT`,
	`CREATE TABLE record_subagent_started (
		seq        INTEGER PRIMARY KEY REFERENCES records(seq),
		name       TEXT NOT NULL CHECK (length(name) > 0),
		program    TEXT,
		provider   TEXT,
		model      TEXT,
		effort     TEXT,
		background INTEGER NOT NULL CHECK (background IN (0, 1))
	) STRICT`,
	`CREATE TABLE record_subagent_completed (
		seq         INTEGER PRIMARY KEY REFERENCES records(seq),
		outcome     INTEGER NOT NULL CHECK (outcome BETWEEN 0 AND 9),
		detail      TEXT,
		name        TEXT,
		acp_session TEXT,
		acp_after   INTEGER CHECK (acp_after IS NULL OR acp_after > 0),
		acp_model   TEXT,
		acp_effort  TEXT
	) STRICT`,
	`CREATE TABLE record_subagent_message (
		seq  INTEGER PRIMARY KEY REFERENCES records(seq),
		name TEXT
	) STRICT`,
	`CREATE TABLE record_compaction_started (
		seq           INTEGER PRIMARY KEY REFERENCES records(seq),
		trigger       TEXT NOT NULL CHECK (length(trigger) > 0),
		covers        INTEGER NOT NULL CHECK (covers > 0),
		head_estimate INTEGER NOT NULL
	) STRICT`,
	`CREATE TABLE record_runtime_message (
		seq   INTEGER PRIMARY KEY REFERENCES records(seq),
		level INTEGER NOT NULL CHECK (level IN (0, 1)),
		text  TEXT NOT NULL CHECK (length(text) > 0)
	) STRICT`,
	`CREATE TABLE record_job_abandoned (
		seq         INTEGER PRIMARY KEY REFERENCES records(seq),
		job         INTEGER NOT NULL CHECK (job BETWEEN 0 AND 3),
		waited_ms   INTEGER NOT NULL CHECK (waited_ms >= 0),
		patience_ms INTEGER NOT NULL CHECK (patience_ms >= 0)
	) STRICT`,
	`CREATE TABLE record_job_reclaimed (
		seq INTEGER PRIMARY KEY REFERENCES records(seq),
		job INTEGER NOT NULL CHECK (job BETWEEN 0 AND 3)
	) STRICT`,
	`CREATE TABLE record_selection_changed (
		seq    INTEGER PRIMARY KEY REFERENCES records(seq),
		effort TEXT
	) STRICT`,
	`CREATE TABLE record_selection_fit (
		seq            INTEGER PRIMARY KEY REFERENCES records(seq),
		api            TEXT NOT NULL CHECK (length(api) > 0),
		recheck        INTEGER NOT NULL CHECK (recheck IN (0, 1)),
		decision       INTEGER NOT NULL CHECK (decision BETWEEN 0 AND 2),
		estimate       INTEGER NOT NULL,
		context_window INTEGER NOT NULL,
		reason         TEXT
	) STRICT`,
	`CREATE TABLE record_selection_applied (
		seq    INTEGER PRIMARY KEY REFERENCES records(seq),
		api    TEXT NOT NULL CHECK (length(api) > 0),
		effort TEXT
	) STRICT`,
	`CREATE TABLE record_user_command (
		seq      INTEGER PRIMARY KEY REFERENCES records(seq),
		kind     INTEGER NOT NULL CHECK (kind BETWEEN 0 AND 4),
		provider TEXT,
		model    TEXT,
		level    TEXT
	) STRICT`,
	`CREATE TABLE record_command_applied (
		seq     INTEGER PRIMARY KEY REFERENCES records(seq),
		command INTEGER NOT NULL REFERENCES records(seq),
		outcome INTEGER NOT NULL CHECK (outcome IN (0, 1)),
		reason  TEXT
	) STRICT`,
	`CREATE TABLE node_user (
		session BLOB NOT NULL,
		node    INTEGER NOT NULL,
		origin  INTEGER NOT NULL CHECK (origin BETWEEN 0 AND 4),
		message INTEGER CHECK (message IS NULL OR message > 0) REFERENCES records(seq),
		PRIMARY KEY (session, node),
		FOREIGN KEY (session, node) REFERENCES nodes(session, node)
	) STRICT`,
	`CREATE TABLE node_assistant (
		session BLOB NOT NULL,
		node    INTEGER NOT NULL,
		request INTEGER NOT NULL CHECK (request > 0),
		partial INTEGER NOT NULL CHECK (partial IN (0, 1)),
		PRIMARY KEY (session, node),
		FOREIGN KEY (session, node) REFERENCES nodes(session, node)
	) STRICT`,
	`CREATE TABLE node_checkpoint (
		session BLOB NOT NULL,
		node    INTEGER NOT NULL,
		request INTEGER NOT NULL CHECK (request > 0),
		PRIMARY KEY (session, node),
		FOREIGN KEY (session, node) REFERENCES nodes(session, node)
	) STRICT`,
	`CREATE TABLE node_result_call (
		session BLOB NOT NULL,
		node    INTEGER NOT NULL,
		ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
		call    INTEGER NOT NULL CHECK (call > 0),
		PRIMARY KEY (session, node, ordinal),
		FOREIGN KEY (session, node) REFERENCES nodes(session, node)
	) STRICT`,
	`CREATE TABLE node_attachment (
		session    BLOB NOT NULL,
		node       INTEGER NOT NULL,
		ordinal    INTEGER NOT NULL CHECK (ordinal >= 0),
		media_type TEXT NOT NULL CHECK (length(media_type) > 0),
		name       TEXT NOT NULL,
		digest     BLOB NOT NULL CHECK (length(digest) = 32) REFERENCES artifacts(digest),
		PRIMARY KEY (session, node, ordinal),
		FOREIGN KEY (session, node) REFERENCES nodes(session, node)
	) STRICT`,
	`CREATE INDEX records_session_seq ON records (session, seq) WHERE session IS NOT NULL`,
	`CREATE INDEX records_session_kind_seq ON records (session, kind, seq)`,
	`CREATE INDEX records_session_node_seq ON records (session, node, seq) WHERE node IS NOT NULL`,
	`CREATE INDEX records_session_call_seq ON records (session, call, seq) WHERE call IS NOT NULL`,
	`CREATE INDEX records_session_request ON records (session, request, attempt) WHERE request IS NOT NULL`,
	`CREATE INDEX records_session_parent_call ON records (session, parent_call, seq) WHERE parent_call IS NOT NULL`,
	`CREATE INDEX nodes_session_branch_node ON nodes (session, branch, node)`,
	`CREATE INDEX nodes_session_kind_node ON nodes (session, kind, node)`,
	`CREATE INDEX nodes_session_turn_kind ON nodes (session, turn, kind) WHERE turn IS NOT NULL`,
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
		for statement in SCHEMA { db.exec(&journal.connection, statement) or_return }
		names := record_names_sql() or_return
		db.exec(&journal.connection, names) or_return
		db.exec(&journal.connection, fmt.tprintf("PRAGMA user_version = %d", SCHEMA_VERSION)) or_return
	}
	return db.commit(&journal.connection)
}

// record_names_sql is a read-only view that maps records.kind to its dotted
// name. The VALUES list is the enum, so a renamed kind cannot leave the view
// behind. The text is temp-allocated and lives until the caller's temp reset.
@(private)
record_names_sql :: proc() -> (sql: string, error: mem.Allocator_Error) {
	builder := strings.builder_make(context.temp_allocator) or_return
	strings.write_string(
		&builder,
		"CREATE VIEW record_names AS SELECT records.seq, names.name, records.* FROM records JOIN (SELECT column1 AS code, column2 AS name FROM (VALUES ",
	)
	separator := ""
	for kind in Record_Kind {
		strings.write_string(&builder, separator)
		fmt.sbprintf(&builder, "(%d, '%s')", int(kind), RECORD_KIND_NAMES[kind])
		separator = ", "
	}
	strings.write_string(&builder, ")) AS names ON names.code = records.kind")
	return strings.to_string(builder), nil
}

@(private, require_results)
schema_version :: proc(journal: ^Journal) -> (int, Error) {
	version, error := query_int(journal, "PRAGMA user_version", nil)
	return int(version), error
}
