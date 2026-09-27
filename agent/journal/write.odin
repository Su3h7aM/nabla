package journal

import "core:crypto/hash"
import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:time"

import "nabla:db"

// The batch limits after which buffered observations are committed without
// waiting for a barrier. They size memory, never the work.
JOURNAL_BATCH_RECORDS :: 256
JOURNAL_BATCH_BYTES :: 1 * mem.Megabyte
JOURNAL_BATCH_AGE :: 1 * time.Second

// Pending is one buffered write. A Node or Branch_Row takes the seq of the
// record buffered just before it; a Session_Row and an Artifact_Row have none.
@(private)
Pending :: union {
	Record,
	Node,
	Branch_Row,
	Session_Row,
	Artifact_Row,
}

@(private)
Branch_Row :: struct {
	session:   Session_Id,
	branch:    Branch_Id,
	base_node: Node_Id,
}

@(private)
Session_Row :: struct {
	session:        Session_Id,
	created_ms:     i64,
	workspace:      string,
	parent_session: Session_Id,
	parent_call:    Call_Id,
	role:           string,
}

@(private)
Artifact_Row :: struct {
	digest:     Digest,
	kind:       string,
	created_ms: i64,
	bytes:      []u8,
}

@(private)
Insert :: enum {
	Record,
	Node,
	Branch,
	Session,
	Artifact,
}

@(private)
INSERT_SQL := [Insert]string {
	.Record   = `INSERT INTO records (time_ms, mono_ns, run, kind, session, branch, node, turn, request, attempt, job, call, parent_call, task, subagent, hook, provider, model, data, body) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING seq`,
	.Node     = `INSERT INTO nodes (session, node, parent, branch, kind, turn, covers, seq, data, body) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
	.Branch   = `INSERT INTO branches (session, branch, base_node, seq) VALUES (?, ?, ?, ?)`,
	.Session  = `INSERT INTO sessions (session, created_ms, workspace, parent_session, parent_call, role) VALUES (?, ?, ?, ?, ?, ?)`,
	.Artifact = `INSERT OR IGNORE INTO artifacts (digest, kind, created_ms, bytes) VALUES (?, ?, ?, ?)`,
}

// append_record buffers one fact for the next commit. The header's strings and
// body are copied, so they are borrowed only for the call. A failure latches in
// j.failure and surfaces at the next commit.
append_record :: proc(j: ^Journal, header: Record, data: $T, body: []u8 = nil) {
	if !writable(j, header.session) { return }
	record := header
	record.seq = 0
	record.run = j.run
	record.time_ms = now_ms()
	record.mono_ns = now_mono_ns()
	record.task = batch_text(j, header.task)
	record.hook = batch_text(j, header.hook)
	record.provider = batch_text(j, header.provider)
	record.model = batch_text(j, header.model)
	record.data = batch_json(j, data)
	record.body = batch_bytes(j, body)
	push(j, record)
}

// append_node buffers a node of the claimed session and the `node.committed`
// record whose seq it takes, and returns the id allocated for it.
append_node :: proc(j: ^Journal, node: Node, data: $T, body: []u8 = nil) -> Node_Id {
	assert(node.session == j.claimed && j.claimed != {}, "a node belongs to the claimed session")
	if !writable(j, node.session) { return 0 }
	row := node
	row.id = j.counters.node + 1
	row.seq = 0
	row.data = batch_json(j, data)
	row.body = batch_bytes(j, body)
	append_record(
		j,
		Record{kind = .Node_Committed, session = row.session, branch = row.branch, node = row.id, turn = row.turn},
		Node_Committed{kind = NODE_KIND_NAMES[row.kind]},
	)
	push(j, row)
	if j.failure != nil { return 0 }
	j.counters.node = row.id
	return row.id
}

// append_branch buffers a branch of the claimed session forked at base (0 for
// the start of the session) and returns the id allocated for it.
append_branch :: proc(j: ^Journal, base: Node_Id) -> Branch_Id {
	assert(j.claimed != {}, "a branch belongs to the claimed session")
	if !writable(j, j.claimed) { return 0 }
	branch := j.counters.branch + 1
	append_record(j, Record{kind = .Branch_Created, session = j.claimed, branch = branch}, Branch_Created{base_node = base})
	push(j, Branch_Row{session = j.claimed, branch = branch, base_node = base})
	if j.failure != nil { return 0 }
	j.counters.branch = branch
	return branch
}

// put_artifact buffers bytes under their SHA-256 and returns the digest. Storing
// the same bytes twice keeps one row.
put_artifact :: proc(j: ^Journal, kind: string, bytes: []u8) -> (digest: Digest) {
	hash.hash_bytes_to_buffer(.SHA256, bytes, digest[:])
	if !writable(j, {}) { return }
	push(j, Artifact_Row{digest = digest, kind = batch_text(j, kind), created_ms = now_ms(), bytes = batch_bytes(j, bytes)})
	return
}

// commit writes every pending item in one immediate transaction and returns the
// last seq written. A failure rolls back and latches: the journal stops writing.
@(require_results)
commit :: proc(j: ^Journal) -> (Journal_Seq, Error) {
	assert(j.open && !j.read_only, "commit needs a writable journal")
	if j.failure != nil { return j.last_seq, j.failure }
	if len(j.pending) == 0 { return j.last_seq, nil }

	last, err := write_pending(j)
	clear(&j.pending)
	virtual.arena_free_all(&j.batch)
	if err != nil {
		j.failure = err
		return j.last_seq, err
	}
	j.last_seq = last
	return last, nil
}

// flush_due commits once the pending items reach a batch limit.
@(require_results)
flush_due :: proc(j: ^Journal, now: time.Tick) -> Error {
	if len(j.pending) == 0 { return j.failure }
	full := len(j.pending) >= JOURNAL_BATCH_RECORDS || j.batch.total_used >= JOURNAL_BATCH_BYTES
	if !full && time.tick_diff(j.oldest, now) < JOURNAL_BATCH_AGE { return nil }
	_, err := commit(j)
	return err
}

// flush_deadline is when the oldest pending item is due, nil when none is.
flush_deadline :: proc(j: ^Journal) -> Maybe(time.Tick) {
	if len(j.pending) == 0 { return nil }
	return time.tick_add(j.oldest, JOURNAL_BATCH_AGE)
}

@(private)
write_pending :: proc(j: ^Journal) -> (last: Journal_Seq, err: Error) {
	for &statement, insert in j.inserts {
		if statement.conn == nil { db.prepare(&j.conn, &statement, INSERT_SQL[insert]) or_return }
	}
	db.exec(&j.conn, "BEGIN IMMEDIATE") or_return
	defer if err != nil { _ = db.rollback(&j.conn) }

	last = j.last_seq
	for &item in j.pending {
		switch &row in item {
		case Record:
			last = insert_record(j, &row) or_return
		case Node:
			args := [10]db.Value {
				id_or_null(&row.session),
				db.Value(i64(row.id)),
				int_or_null(row.parent),
				db.Value(i64(row.branch)),
				db.Value(NODE_KIND_NAMES[row.kind]),
				int_or_null(row.turn),
				int_or_null(row.covers),
				db.Value(i64(last)),
				db.Value(row.data),
				bytes_or_null(row.body),
			}
			db.statement_exec(&j.inserts[.Node], args[:]) or_return
		case Branch_Row:
			args := [4]db.Value{id_or_null(&row.session), db.Value(i64(row.branch)), db.Value(i64(row.base_node)), db.Value(i64(last))}
			db.statement_exec(&j.inserts[.Branch], args[:]) or_return
		case Session_Row:
			args := [6]db.Value {
				id_or_null(&row.session),
				db.Value(row.created_ms),
				db.Value(row.workspace),
				id_or_null(&row.parent_session),
				int_or_null(row.parent_call),
				db.Value(row.role),
			}
			db.statement_exec(&j.inserts[.Session], args[:]) or_return
		case Artifact_Row:
			args := [4]db.Value{db.Value(row.digest[:]), db.Value(row.kind), db.Value(row.created_ms), db.Value(row.bytes)}
			db.statement_exec(&j.inserts[.Artifact], args[:]) or_return
		}
	}
	db.commit(&j.conn) or_return
	return last, nil
}

@(private)
insert_record :: proc(j: ^Journal, row: ^Record) -> (seq: Journal_Seq, err: Error) {
	args := [20]db.Value {
		db.Value(row.time_ms),
		db.Value(row.mono_ns),
		db.Value(row.run[:]),
		db.Value(RECORD_KIND_NAMES[row.kind]),
		id_or_null(&row.session),
		int_or_null(row.branch),
		int_or_null(row.node),
		int_or_null(row.turn),
		int_or_null(row.request),
		int_or_null(row.attempt),
		int_or_null(row.job),
		int_or_null(row.call),
		int_or_null(row.parent_call),
		text_or_null(row.task),
		id_or_null(&row.subagent),
		text_or_null(row.hook),
		text_or_null(row.provider),
		text_or_null(row.model),
		db.Value(row.data),
		bytes_or_null(row.body),
	}
	rows: db.Rows
	defer db.rows_close(&rows)
	db.statement_query(&j.inserts[.Record], &rows, args[:]) or_return
	values, has_row := db.rows_next(&rows) or_return
	if !has_row { return 0, Journal_Error.Corrupt }
	return Journal_Seq(db.as_i64(values[0]) or_return), nil
}

// writable reports whether an append may be buffered. Writing through a
// read-only journal or for another session is a programming error.
@(private)
writable :: proc(j: ^Journal, session: Session_Id) -> bool {
	assert(j.open && !j.read_only, "appends need a writable journal")
	assert(session == {} || session == j.claimed, "appends name the claimed session or none")
	return j.failure == nil
}

@(private)
push :: proc(j: ^Journal, item: Pending) {
	if j.failure != nil { return }
	if _, err := append(&j.pending, item); err != nil {
		j.failure = err
		return
	}
	if len(j.pending) == 1 { j.oldest = time.tick_now() }
}

// batch_text, batch_bytes, and batch_json copy into the batch arena and latch an
// allocation or encoding failure.
@(private)
batch_text :: proc(j: ^Journal, text: string) -> string {
	copied, err := strings.clone(text, virtual.arena_allocator(&j.batch))
	if err != nil && j.failure == nil { j.failure = err }
	return copied
}

@(private)
batch_bytes :: proc(j: ^Journal, bytes: []u8) -> []u8 {
	if len(bytes) == 0 { return nil }
	copied, err := slice.clone(bytes, virtual.arena_allocator(&j.batch))
	if err != nil && j.failure == nil { j.failure = err }
	return copied
}

@(private)
batch_json :: proc(j: ^Journal, payload: $T) -> string {
	versioned := payload
	if versioned.v == 0 { versioned.v = PAYLOAD_VERSION }
	encoded, err := json.marshal(versioned, allocator = virtual.arena_allocator(&j.batch))
	if err != nil && j.failure == nil { j.failure = err }
	return string(encoded)
}

@(private)
int_or_null :: proc(value: $T) -> db.Value {
	if value == 0 { return nil }
	return db.Value(i64(value))
}

@(private)
text_or_null :: proc(text: string) -> db.Value {
	if text == "" { return nil }
	return db.Value(text)
}

// id_or_null binds a borrowed id, so the id must outlive the statement.
@(private)
id_or_null :: proc(id: ^Session_Id) -> db.Value {
	if id^ == {} { return nil }
	return db.Value(id[:])
}

@(private)
bytes_or_null :: proc(bytes: []u8) -> db.Value {
	if len(bytes) == 0 { return nil }
	return db.Value(bytes)
}

@(private)
now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

@(private)
now_mono_ns :: proc() -> i64 {
	return i64(time.tick_diff(time.Tick{}, time.tick_now()))
}
