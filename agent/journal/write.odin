package journal

import "core:crypto/hash"
import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"
import "core:time"

import "nabla:db"

// JOURNAL_BATCH_RECORDS, JOURNAL_BATCH_BYTES, and JOURNAL_BATCH_AGE are when a
// buffered observation stops waiting for a barrier commit. They size memory and
// schedule a write; they never cap what the model may ask for, because a caller
// that needs the record durable calls commit.
JOURNAL_BATCH_RECORDS :: 256
JOURNAL_BATCH_BYTES :: 1 * mem.Megabyte
JOURNAL_BATCH_AGE :: 1 * time.Second

// Pending is one buffered write, in the order it was appended. A Record is
// written as it stands; a Node, Branch_Row, or Session_Row is a table row whose
// position in the global order is the seq of the record appended with it.
@(private)
Pending :: union {
	Record,
	Node,
	Branch_Row,
	Session_Row,
	Artifact_Row,
}

// Branch_Row is the `branches` row of one append_branch, written after the
// branch.created record whose seq it carries.
@(private)
Branch_Row :: struct {
	session:   Session_Id,
	branch:    Branch_Id,
	base_node: Node_Id,
}

// Session_Row is the `sessions` row of one create_session. It owns no seq: the
// position of the session in the global order is the seq of its session.created
// record.
@(private)
Session_Row :: struct {
	session:        Session_Id,
	created_ms:     i64,
	workspace:      string, // the batch arena owns it
	parent_session: Session_Id,
	parent_call:    Call_Id,
	role:           string, // the batch arena owns it
}

// Artifact_Row is the `artifacts` row of one put_artifact: exact bytes and what
// they are. The digest keys it, so storing the same bytes twice writes one row.
@(private)
Artifact_Row :: struct {
	digest:     Digest,
	kind:       string, // the batch arena owns it
	created_ms: i64,
	bytes:      []u8, // the batch arena owns it
}

// append_record buffers one fact. The header's strings are borrowed for the
// call, the payload is marshalled into the journal's batch arena, and the
// record reaches the database at the next commit.
//
// The journal fills seq, time_ms, mono_ns, and run, and ignores those fields in
// the header; the caller fills the correlation columns. The payload struct
// carries the version field `v`, which this call sets to PAYLOAD_VERSION when
// the caller left it zero.
//
// An append has no error to return, so a refused append or a failed encoding
// latches in the journal and surfaces at the next commit.
append_record :: proc(j: ^Journal, header: Record, data: $T, body: []u8 = nil) {
	if append_refused(j, header.session) { return }

	arena := virtual.arena_allocator(&j.batch)
	record := header
	record.run = j.run
	record.time_ms = now_ms()
	record.mono_ns = now_mono_ns()
	record.seq = 0
	// The body is the call's own argument, as it is for a node: a header
	// carries the correlation columns, not content.
	record.body = body

	encoded, encoded_ok := arena_json(j, data, arena)
	if !encoded_ok { return }
	record.data = encoded
	if !arena_record(j, &record, arena) { return }

	push(j, Pending(record), len(record.data) + len(record.body) + record_text_bytes(record))
}

// append_node buffers one committed step of the session tree and the
// `node.committed` record that stamps it, and returns the node id the journal
// allocated for it.
//
// The node's seq is the seq of that record, so the tree and the global order
// agree: a node is exactly as durable as the fact that created it. A node
// belongs to the session this journal claimed, so appending one without a claim
// is refused.
@(require_results)
append_node :: proc(j: ^Journal, node: Node, data: $T, body: []u8 = nil) -> Node_Id {
	if session_id_is_absent(node.session) {
		fail(j, Journal_Error.Not_Claimed)
		return 0
	}
	if append_refused(j, node.session) { return 0 }

	arena := virtual.arena_allocator(&j.batch)
	row := node
	row.id = j.counters.node + 1
	row.seq = 0

	encoded, encoded_ok := arena_json(j, data, arena)
	if !encoded_ok { return 0 }
	row.data = encoded
	row.body, encoded_ok = arena_bytes(j, body, arena)
	if !encoded_ok { return 0 }

	// The record comes first: the row's seq is the seq that insert returns.
	append_record(
		j,
		Record{session = row.session, branch = row.branch, node = row.id, turn = row.turn, kind = .Node_Committed},
		Node_Committed{kind = NODE_KIND_NAMES[row.kind]},
	)
	if j.failure != nil { return 0 }
	j.counters.node = row.id
	push(j, Pending(row), len(row.data) + len(row.body))
	return row.id
}

// append_branch forks a new branch in the claimed session and returns the
// branch id the journal allocated for it. base is the node the branch starts
// from, 0 for a branch from the start of the session.
@(require_results)
append_branch :: proc(j: ^Journal, base: Node_Id) -> Branch_Id {
	if session_id_is_absent(j.claimed) {
		fail(j, Journal_Error.Not_Claimed)
		return 0
	}
	if append_refused(j, j.claimed) { return 0 }
	j.counters.branch += 1
	push_branch(j, j.claimed, j.counters.branch, base)
	return j.counters.branch
}

// put_artifact buffers exact bytes for a record to point at by digest: a
// prompt, an instruction set, a rendered result, a captured stream. The digest
// is the SHA-256 of the bytes, and it is what read_artifact reads them back by.
//
// The insert ignores a digest the table already holds, so storing the same
// bytes twice writes one row. The row reaches the database at the next commit,
// with the same latching as append_record: a refused or failed append surfaces
// at that commit, and the returned digest is absent.
//
// A read of a digest that was buffered but not committed does not see it.
@(require_results)
put_artifact :: proc(j: ^Journal, kind: string, bytes: []u8) -> Digest {
	if append_refused(j, Session_Id{}) { return {} }
	if kind == "" {
		fail(j, Journal_Error.Invalid_State)
		return {}
	}

	arena := virtual.arena_allocator(&j.batch)
	row := Artifact_Row {
		digest     = digest_of(bytes),
		created_ms = now_ms(),
	}
	kind_text, kind_ok := arena_text(j, kind, arena)
	if !kind_ok { return {} }
	body, body_ok := arena_bytes(j, bytes, arena)
	if !body_ok { return {} }
	row.kind = kind_text
	row.bytes = body
	push(j, Pending(row), len(row.kind) + len(row.bytes))
	return row.digest
}

// commit writes every buffered item in one immediate transaction and returns
// the last seq written. Committing with nothing buffered opens no transaction
// and returns the seq the database was last at.
//
// The transaction is all or nothing. A failure rolls it back and latches
// Storage_Failed with the database's own error kept in failure_cause; from then
// on every append is dropped and every commit returns that failure.
@(require_results)
commit :: proc(j: ^Journal) -> (Journal_Seq, Error) {
	if j.failure != nil { return j.last_seq, j.failure }
	if !j.open { return j.last_seq, Journal_Error.Invalid_State }
	if j.read_only { return j.last_seq, Journal_Error.Read_Only }
	if len(j.pending) == 0 { return j.last_seq, nil }

	if prepare_err := prepare_inserts(j); prepare_err != nil { return fail_commit(j, prepare_err) }
	if err := db.exec(&j.conn, "BEGIN IMMEDIATE"); err != nil { return fail_commit(j, err) }
	committed := false
	defer if !committed {
		// A rollback that itself fails leaves the transaction state unknown.
		// The failure is already latched, so nothing writes again, but reads
		// keep working: a transaction left open is still readable.
		_ = db.rollback(&j.conn)
	}

	last := j.last_seq
	for i in 0 ..< len(j.pending) {
		switch value in j.pending[i] {
		case Record:
			seq, record_err := insert_record(j, value)
			if record_err != nil { return fail_commit(j, record_err) }
			last = seq
		case Node:
			// The node row follows the node.committed record appended with it,
			// so the seq just written is the node's.
			if node_err := insert_node(j, value, last); node_err != nil { return fail_commit(j, node_err) }
		case Branch_Row:
			if branch_err := insert_branch(j, value, last); branch_err != nil { return fail_commit(j, branch_err) }
		case Session_Row:
			if session_err := insert_session(j, value); session_err != nil { return fail_commit(j, session_err) }
		case Artifact_Row:
			if artifact_err := insert_artifact(j, value); artifact_err != nil { return fail_commit(j, artifact_err) }
		}
	}

	if err := db.commit(&j.conn); err != nil { return fail_commit(j, err) }
	committed = true

	j.last_seq = last
	clear(&j.pending)
	j.pending_bytes = 0
	j.oldest = {}
	virtual.arena_free_all(&j.batch)
	return last, nil
}

// flush_due commits when the buffered observations have waited long enough or
// grown large enough. The caller's clock is passed in, so one owner run uses
// one reading of the time. A journal with nothing buffered commits nothing.
@(require_results)
flush_due :: proc(j: ^Journal, now: time.Tick) -> Error {
	if j.failure != nil { return j.failure }
	if len(j.pending) == 0 { return nil }
	if len(j.pending) < JOURNAL_BATCH_RECORDS && j.pending_bytes < JOURNAL_BATCH_BYTES {
		if time.tick_diff(j.oldest, now) < JOURNAL_BATCH_AGE { return nil }
	}
	_, commit_err := commit(j)
	return commit_err
}

// flush_deadline is when the oldest buffered item is due, or nil when nothing
// is buffered. It is a deadline the owner waits until, never a poll.
flush_deadline :: proc(j: ^Journal) -> Maybe(time.Tick) {
	if len(j.pending) == 0 { return nil }
	return time.tick_add(j.oldest, JOURNAL_BATCH_AGE)
}

// --- buffering --------------------------------------------------------------

// append_refused reports whether an item must be dropped before it is built,
// and latches why. A record may name the claimed session or no session at all:
// a process-scope fact such as run.started belongs to no session and is written
// without a claim. Anything else would write outside the session this journal
// owns.
@(private)
append_refused :: proc(j: ^Journal, session: Session_Id) -> bool {
	if j.failure != nil { return true }
	if !j.open {
		fail(j, Journal_Error.Invalid_State)
		return true
	}
	if j.read_only {
		fail(j, Journal_Error.Read_Only)
		return true
	}
	if !session_id_is_absent(session) && session != j.claimed {
		fail(j, Journal_Error.Not_Claimed)
		return true
	}
	return false
}

// fail latches the first failure. Later ones are consequences of it, so the
// cause the journal keeps is the one that broke it.
@(private)
fail :: proc(j: ^Journal, cause: Error) {
	if j.failure != nil { return }
	j.failure = cause
	j.failure_cause = cause
}

// fail_commit latches a commit that could not be written and reports it. The
// caller has rolled the transaction back, so the journal's position is the last
// seq that landed.
@(private)
fail_commit :: proc(j: ^Journal, cause: Error) -> (Journal_Seq, Error) {
	j.failure = Journal_Error.Storage_Failed
	j.failure_cause = cause
	// Nothing buffered can be written again, so the batch is dropped and the
	// memory it held is released at the next commit or at close.
	clear(&j.pending)
	j.pending_bytes = 0
	j.oldest = {}
	virtual.arena_free_all(&j.batch)
	return j.last_seq, j.failure
}

// push adds one buffered item and counts the bytes it contributes to the batch.
@(private)
push :: proc(j: ^Journal, item: Pending, bytes: int) {
	appended, append_err := append(&j.pending, item)
	if append_err != nil {
		fail(j, append_err)
		return
	}
	if appended != 1 { return }
	if len(j.pending) == 1 { j.oldest = time.tick_now() }
	j.pending_bytes += bytes
}

// arena_json marshals one payload into the batch arena, with the payload's
// version set to PAYLOAD_VERSION when the caller left it zero.
@(private)
arena_json :: proc(j: ^Journal, payload: $T, arena: mem.Allocator) -> (string, bool) {
	versioned := payload
	if versioned.v == 0 { versioned.v = PAYLOAD_VERSION }
	encoded, marshal_err := json.marshal(versioned, allocator = arena)
	if marshal_err != nil {
		fail(j, marshal_err)
		return "", false
	}
	return string(encoded), true
}

// arena_text copies text into the arena, so the journal owns it once the call
// that lent it returns. The empty text is copied as itself.
@(private)
arena_text :: proc(j: ^Journal, text: string, arena: mem.Allocator) -> (string, bool) {
	if text == "" { return "", true }
	buffer, alloc_err := mem.alloc_bytes(len(text), 1, arena)
	if alloc_err != nil {
		fail(j, alloc_err)
		return "", false
	}
	mem.copy(raw_data(buffer), raw_data(text), len(text))
	return string(buffer), true
}

// arena_bytes copies body into the arena. A zero-length body is stored as
// absent.
@(private)
arena_bytes :: proc(j: ^Journal, body: []u8, arena: mem.Allocator) -> ([]u8, bool) {
	if len(body) == 0 { return nil, true }
	buffer, alloc_err := mem.alloc_bytes(len(body), 1, arena)
	if alloc_err != nil {
		fail(j, alloc_err)
		return nil, false
	}
	copy(buffer, body)
	return buffer, true
}

// arena_record copies every string and byte the caller lent into the arena. The
// encoded payload is already there, so it is not copied again.
@(private)
arena_record :: proc(j: ^Journal, record: ^Record, arena: mem.Allocator) -> bool {
	fields := [4]^string{&record.task, &record.hook, &record.provider, &record.model}
	for field in fields {
		copied, copied_ok := arena_text(j, field^, arena)
		if !copied_ok { return false }
		field^ = copied
	}
	body, body_ok := arena_bytes(j, record.body, arena)
	if !body_ok { return false }
	record.body = body
	return true
}

// record_text_bytes is how many bytes of a record's own text the batch holds.
@(private)
record_text_bytes :: proc(record: Record) -> int {
	return len(record.task) + len(record.hook) + len(record.provider) + len(record.model)
}

// push_branch buffers one branch and the branch.created record that stamps it.
// The record comes first: the row's seq is the seq that insert returns.
@(private)
push_branch :: proc(j: ^Journal, session: Session_Id, branch: Branch_Id, base: Node_Id) {
	append_record(j, Record{session = session, branch = branch, kind = .Branch_Created}, Branch_Created{base_node = base})
	if j.failure != nil { return }
	push(j, Pending(Branch_Row{session = session, branch = branch, base_node = base}), 0)
}

// push_session_row buffers one session row. It carries no seq, so the record
// that created the session is its position in the global order.
@(private)
push_session_row :: proc(j: ^Journal, row: Session_Row) {
	arena := virtual.arena_allocator(&j.batch)
	session := row
	workspace, workspace_ok := arena_text(j, session.workspace, arena)
	if !workspace_ok { return }
	role, role_ok := arena_text(j, session.role, arena)
	if !role_ok { return }
	session.workspace = workspace
	session.role = role
	push(j, Pending(session), len(session.workspace) + len(session.role))
}

// --- writing ----------------------------------------------------------------

// prepare_inserts compiles the statements one commit uses, once per journal.
@(private)
prepare_inserts :: proc(j: ^Journal) -> Error {
	if j.inserts_ready { return nil }
	db.prepare(&j.conn, &j.record_stmt, RECORD_INSERT) or_return
	db.prepare(&j.conn, &j.node_stmt, NODE_INSERT) or_return
	db.prepare(&j.conn, &j.branch_stmt, BRANCH_INSERT) or_return
	db.prepare(&j.conn, &j.session_stmt, SESSION_INSERT) or_return
	db.prepare(&j.conn, &j.artifact_stmt, ARTIFACT_INSERT) or_return
	j.inserts_ready = true
	return nil
}

@(private)
RECORD_INSERT :: `INSERT INTO records (time_ms, mono_ns, run, kind, session, branch, node, turn, request, attempt, job, call, parent_call, task, subagent, hook, provider, model, data, body) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING seq`

@(private)
NODE_INSERT :: `INSERT INTO nodes (session, node, parent, branch, kind, turn, covers, seq, data, body) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

@(private)
BRANCH_INSERT :: `INSERT INTO branches (session, branch, base_node, seq) VALUES (?, ?, ?, ?)`

@(private)
SESSION_INSERT :: `INSERT INTO sessions (session, created_ms, workspace, parent_session, parent_call, role) VALUES (?, ?, ?, ?, ?, ?)`

@(private)
ARTIFACT_INSERT :: `INSERT OR IGNORE INTO artifacts (digest, kind, created_ms, bytes) VALUES (?, ?, ?, ?)`

// insert_record writes one record and returns the seq SQLite assigned it.
@(private)
insert_record :: proc(j: ^Journal, record: Record) -> (Journal_Seq, Error) {
	// The arguments borrow the row, so the row has to be the one address here.
	row := record
	args := [20]db.Value {
		db.Value(row.time_ms),
		db.Value(row.mono_ns),
		db.Value(row.run[:]),
		db.Value(RECORD_KIND_NAMES[row.kind]),
		session_or_null(&row.session),
		id_or_null(row.branch),
		id_or_null(row.node),
		id_or_null(row.turn),
		id_or_null(row.request),
		id_or_null(row.attempt),
		id_or_null(row.job),
		id_or_null(row.call),
		id_or_null(row.parent_call),
		text_or_null(row.task),
		session_or_null(&row.subagent),
		text_or_null(row.hook),
		text_or_null(row.provider),
		text_or_null(row.model),
		db.Value(row.data),
		bytes_or_null(row.body),
	}
	seq, seq_err := insert_returning_seq(j, &j.record_stmt, args[:])
	if seq_err != nil { return 0, seq_err }
	return seq, nil
}

// insert_node writes one node row. Its seq is the seq of the node.committed
// record that was written immediately before it.
@(private)
insert_node :: proc(j: ^Journal, node: Node, seq: Journal_Seq) -> Error {
	row := node
	args := [10]db.Value {
		db.Value(row.session[:]),
		db.Value(i64(row.id)),
		id_or_null(row.parent),
		db.Value(i64(row.branch)),
		db.Value(NODE_KIND_NAMES[row.kind]),
		id_or_null(row.turn),
		id_or_null(row.covers),
		db.Value(i64(seq)),
		db.Value(row.data),
		bytes_or_null(row.body),
	}
	return db.statement_exec(&j.node_stmt, args[:])
}

// insert_branch writes one branch row. Its seq is the seq of the branch.created
// record that was written immediately before it.
@(private)
insert_branch :: proc(j: ^Journal, branch: Branch_Row, seq: Journal_Seq) -> Error {
	row := branch
	args := [4]db.Value{db.Value(row.session[:]), db.Value(i64(row.branch)), db.Value(i64(row.base_node)), db.Value(i64(seq))}
	return db.statement_exec(&j.branch_stmt, args[:])
}

// insert_session writes one session row.
@(private)
insert_session :: proc(j: ^Journal, session: Session_Row) -> Error {
	row := session
	args := [6]db.Value {
		db.Value(row.session[:]),
		db.Value(row.created_ms),
		db.Value(row.workspace),
		session_or_null(&row.parent_session),
		id_or_null(row.parent_call),
		db.Value(row.role),
	}
	return db.statement_exec(&j.session_stmt, args[:])
}

// insert_artifact writes one artifact row. The digest is the primary key, so
// the same bytes stored twice leave one row behind.
@(private)
insert_artifact :: proc(j: ^Journal, artifact: Artifact_Row) -> Error {
	row := artifact
	args := [4]db.Value{db.Value(row.digest[:]), db.Value(row.kind), db.Value(row.created_ms), db.Value(row.bytes)}
	return db.statement_exec(&j.artifact_stmt, args[:])
}

// digest_of is the SHA-256 of the bytes an artifact holds, which is the key it
// is stored and read back under.
@(private)
digest_of :: proc(bytes: []u8) -> Digest {
	digest: Digest
	hash.hash_bytes_to_buffer(.SHA256, bytes, digest[:])
	return digest
}

// insert_returning_seq runs one insert that reports the seq SQLite assigned it.
@(private)
insert_returning_seq :: proc(j: ^Journal, stmt: ^db.Statement, args: []db.Value) -> (Journal_Seq, Error) {
	rows: db.Rows
	if err := db.statement_query(stmt, &rows, args); err != nil { return 0, err }
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return 0, next_err }
	if !has_row { return 0, Journal_Error.Corrupt }
	seq, convert_err := db.as_i64(values[0])
	if convert_err != nil { return 0, convert_err }
	return Journal_Seq(seq), nil
}

// id_or_null is an id column's value: the id, or absent when zero.
@(private)
id_or_null :: proc(value: $T) -> db.Value {
	if value == 0 { return nil }
	return db.Value(i64(value))
}

// session_or_null is a session column's value: the id, or absent when zero.
@(private)
session_or_null :: proc(id: ^Session_Id) -> db.Value {
	if session_id_is_absent(id^) { return nil }
	return db.Value(id[:])
}

// text_or_null is a text column's value: the text, or absent when empty.
@(private)
text_or_null :: proc(text: string) -> db.Value {
	if text == "" { return nil }
	return db.Value(text)
}

// bytes_or_null is a blob column's value: the bytes, or absent when empty.
@(private)
bytes_or_null :: proc(body: []u8) -> db.Value {
	if len(body) == 0 { return nil }
	return db.Value(body)
}

// now_ms is the wall clock the journal records with, and now_mono_ns the
// monotonic clock, which orders two records the wall clock cannot. Both are
// taken once per append.
@(private)
now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

@(private)
now_mono_ns :: proc() -> i64 {
	// A tick measures from an arbitrary origin; the difference from the zero
	// tick is its reading in nanoseconds.
	return time.duration_nanoseconds(time.tick_diff(time.Tick{}, time.tick_now()))
}
