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
// journal.failure and surfaces at the next commit.
append_record :: proc(journal: ^Journal, header: Record, data: $Payload, body: []u8 = nil) {
	if !writable(journal, header.session) { return }
	record_buffer(journal, header, data, body)
}

// append_input appends a `user.input` record for the followed session and commits
// it, so a nil return means the runner will see the line. Turn and branch stay
// zero: the follower allocates no ids. This is the one append a journal makes
// without a claim. On a busy database the record stays pending and the error is
// returned; the caller commits again and does not append the line a second time.
@(require_results)
append_input :: proc(journal: ^Journal, text: string, origin: User_Origin) -> Error {
	assert(journal.open && !journal.read_only, "appends need a writable journal")
	assert(journal.followed != {}, "append_input needs a followed session")
	if journal.failure != nil { return journal.failure }
	record_buffer(journal, Record{kind = .User_Input, session = journal.followed}, User_Input{origin = USER_ORIGIN_NAMES[origin]}, transmute([]u8)text)
	_, error := commit(journal)
	return error
}

@(private)
record_buffer :: proc(journal: ^Journal, header: Record, data: $Payload, body: []u8) {
	record := header
	record.seq = 0
	record.run = journal.run
	record.time_ms = now_ms()
	record.mono_ns = now_mono_ns()
	record.task = batch_text(journal, header.task)
	record.hook = batch_text(journal, header.hook)
	record.provider = batch_text(journal, header.provider)
	record.model = batch_text(journal, header.model)
	record.data = batch_json(journal, data)
	record.body = batch_bytes(journal, body)
	push(journal, record)
}

// append_node buffers a node of the claimed session and the `node.committed`
// record whose seq it takes, and returns the id allocated for it.
append_node :: proc(journal: ^Journal, node: Node, data: $Payload, body: []u8 = nil) -> Node_Id {
	assert(node.session == journal.claimed && journal.claimed != {}, "a node belongs to the claimed session")
	if !writable(journal, node.session) { return 0 }
	row := node
	row.id = journal.counters.node + 1
	row.seq = 0
	row.data = batch_json(journal, data)
	row.body = batch_bytes(journal, body)
	append_record(
		journal,
		Record{kind = .Node_Committed, session = row.session, branch = row.branch, node = row.id, turn = row.turn},
		Node_Committed{kind = NODE_KIND_NAMES[row.kind]},
	)
	push(journal, row)
	if journal.failure != nil { return 0 }
	journal.counters.node = row.id
	return row.id
}

// append_branch buffers a branch of the claimed session forked at base (0 for
// the start of the session) and returns the id allocated for it.
append_branch :: proc(journal: ^Journal, base: Node_Id) -> Branch_Id {
	assert(journal.claimed != {}, "a branch belongs to the claimed session")
	if !writable(journal, journal.claimed) { return 0 }
	branch := journal.counters.branch + 1
	append_record(journal, Record{kind = .Branch_Created, session = journal.claimed, branch = branch}, Branch_Created{base_node = base})
	push(journal, Branch_Row{session = journal.claimed, branch = branch, base_node = base})
	if journal.failure != nil { return 0 }
	journal.counters.branch = branch
	return branch
}

// put_artifact buffers bytes under their SHA-256 and returns the digest. Storing
// the same bytes twice keeps one row.
put_artifact :: proc(journal: ^Journal, kind: string, bytes: []u8) -> (digest: Digest) {
	hash.hash_bytes_to_buffer(.SHA256, bytes, digest[:])
	if !writable(journal, {}) { return }
	push(journal, Artifact_Row{digest = digest, kind = batch_text(journal, kind), created_ms = now_ms(), bytes = batch_bytes(journal, bytes)})
	return
}

// next_turn, next_request, and next_call allocate the claimed session's next
// harness id, continuing from the counters its claim loaded.
next_turn :: proc(journal: ^Journal) -> Turn_Id {
	assert(journal.claimed != {}, "ids belong to the claimed session")
	journal.counters.turn += 1
	return journal.counters.turn
}

next_request :: proc(journal: ^Journal) -> Request_Id {
	assert(journal.claimed != {}, "ids belong to the claimed session")
	journal.counters.request += 1
	return journal.counters.request
}

next_call :: proc(journal: ^Journal) -> Call_Id {
	assert(journal.claimed != {}, "ids belong to the claimed session")
	journal.counters.call += 1
	return journal.counters.call
}

// commit writes every pending item in one immediate transaction and returns the
// last seq written. A failure rolls back and latches: the journal stops writing.
// The exception is another writer holding the database past the busy timeout:
// nothing was written, so the items stay pending for the next commit and nothing
// latches (error_is_busy tells it apart).
@(require_results)
commit :: proc(journal: ^Journal) -> (Journal_Seq, Error) {
	assert(journal.open && !journal.read_only, "commit needs a writable journal")
	if journal.failure != nil { return journal.last_seq, journal.failure }
	if len(journal.pending) == 0 { return journal.last_seq, nil }

	last, error := write_pending(journal)
	if error_is_busy(error) {
		journal.batch_since = time.tick_now()
		return journal.last_seq, error
	}
	clear(&journal.pending)
	virtual.arena_free_all(&journal.batch)
	if error != nil {
		latch(journal, error)
		return journal.last_seq, journal.failure
	}
	journal.last_seq = last
	// The commit is durable, so a watcher woken by this touch reads it. A failed
	// touch is ignored: it only delays a wake until the next one, and never loses
	// or reorders data.
	if journal.lock_file != nil { _ = claim_file_touch(journal.lock_file) }
	return last, nil
}

// flush_due commits once the pending items reach a batch limit.
@(require_results)
flush_due :: proc(journal: ^Journal, now: time.Tick) -> Error {
	if len(journal.pending) == 0 { return journal.failure }
	full := len(journal.pending) >= JOURNAL_BATCH_RECORDS || journal.batch.total_used >= JOURNAL_BATCH_BYTES
	if !full && time.tick_diff(journal.batch_since, now) < JOURNAL_BATCH_AGE { return nil }
	_, error := commit(journal)
	return error
}

// flush_deadline is when the pending batch is due, nil when none is. Busy commits restart its batch age.
flush_deadline :: proc(journal: ^Journal) -> Maybe(time.Tick) {
	if len(journal.pending) == 0 { return nil }
	return time.tick_add(journal.batch_since, JOURNAL_BATCH_AGE)
}

@(private, require_results)
write_pending :: proc(journal: ^Journal) -> (last: Journal_Seq, error: Error) {
	for &statement, insert in journal.inserts {
		if statement.connection == nil { db.prepare(&journal.connection, &statement, INSERT_SQL[insert]) or_return }
	}
	db.exec(&journal.connection, "BEGIN IMMEDIATE") or_return
	// A busy failure keeps the items pending for the next commit, which needs this
	// transaction gone; if it stays open, the rollback failure is the one to latch.
	defer if error != nil {
		if rollback_error := db.rollback(&journal.connection); rollback_error != nil && error_is_busy(error) { error = rollback_error }
	}

	last = journal.last_seq
	for &item in journal.pending {
		switch &row in item {
		case Record:
			last = insert_record(journal, &row) or_return
		case Node:
			arguments := [10]db.Value {
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
			db.statement_exec(&journal.inserts[.Node], arguments[:]) or_return
		case Branch_Row:
			arguments := [4]db.Value{id_or_null(&row.session), db.Value(i64(row.branch)), db.Value(i64(row.base_node)), db.Value(i64(last))}
			db.statement_exec(&journal.inserts[.Branch], arguments[:]) or_return
		case Session_Row:
			arguments := [6]db.Value {
				id_or_null(&row.session),
				db.Value(row.created_ms),
				db.Value(row.workspace),
				id_or_null(&row.parent_session),
				int_or_null(row.parent_call),
				db.Value(row.role),
			}
			db.statement_exec(&journal.inserts[.Session], arguments[:]) or_return
		case Artifact_Row:
			arguments := [4]db.Value{db.Value(row.digest[:]), db.Value(row.kind), db.Value(row.created_ms), db.Value(row.bytes)}
			db.statement_exec(&journal.inserts[.Artifact], arguments[:]) or_return
		}
	}
	db.commit(&journal.connection) or_return
	return last, nil
}

@(private, require_results)
insert_record :: proc(journal: ^Journal, row: ^Record) -> (seq: Journal_Seq, error: Error) {
	arguments := [20]db.Value {
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
	defer {
		close_error := db.rows_close(&rows)
		if error == nil { error = close_error }
	}
	db.statement_query(&journal.inserts[.Record], &rows, arguments[:]) or_return
	values, has_row := db.rows_next(&rows) or_return
	if !has_row { return 0, Journal_Error.Corrupt }
	return Journal_Seq(db.as_i64(values[0]) or_return), nil
}

// writable reports whether an append may be buffered. Writing through a
// read-only journal or for another session is a programming error.
@(private, require_results)
writable :: proc(journal: ^Journal, session: Session_Id) -> bool {
	assert(journal.open && !journal.read_only, "appends need a writable journal")
	assert(session == {} || session == journal.claimed, "appends name the claimed session or none")
	return journal.failure == nil
}

@(private)
push :: proc(journal: ^Journal, item: Pending) {
	if journal.failure != nil { return }
	if _, error := append(&journal.pending, item); error != nil {
		latch(journal, error)
		return
	}
	if len(journal.pending) == 1 { journal.batch_since = time.tick_now() }
}

// batch_text, batch_bytes, and batch_json copy into the batch arena and latch an
// allocation or encoding failure.
@(private)
batch_text :: proc(journal: ^Journal, text: string) -> string {
	copied, error := strings.clone(text, virtual.arena_allocator(&journal.batch))
	if error != nil && journal.failure == nil { latch(journal, error) }
	return copied
}

@(private)
batch_bytes :: proc(journal: ^Journal, bytes: []u8) -> []u8 {
	if len(bytes) == 0 { return nil }
	copied, error := slice.clone(bytes, virtual.arena_allocator(&journal.batch))
	if error != nil && journal.failure == nil { latch(journal, error) }
	return copied
}

@(private)
batch_json :: proc(journal: ^Journal, payload: $Payload) -> string {
	versioned := payload
	if versioned.version == 0 { versioned.version = PAYLOAD_VERSION }
	encoded, error := json.marshal(versioned, allocator = virtual.arena_allocator(&journal.batch))
	if error != nil && journal.failure == nil { latch(journal, error) }
	return string(encoded)
}

@(private)
int_or_null :: proc(value: $Integer) -> db.Value {
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
