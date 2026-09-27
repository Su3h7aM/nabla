package journal

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "nabla:db"
import "nabla:db/sqlite"

DATABASE_NAME :: "journal.db"

// LOCK_DIRECTORY holds one lock file per claimed session. The files are never
// deleted: replacing a locked inode would let two processes hold one claim.
LOCK_DIRECTORY :: "locks"

// BUSY_TIMEOUT_MS is how long a commit waits for another process's write lock.
BUSY_TIMEOUT_MS :: 5_000

INITIAL_BRANCH :: Branch_Id(1)

PRIVATE_DIRECTORY_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}
PRIVATE_FILE_PERMISSIONS :: os.Permissions{.Read_User, .Write_User}

Open_Mode :: enum {
	Read_Write,
	Read_Only,
}

Session_Info :: struct {
	workspace:      string,
	role:           Session_Role,
	parent_session: Session_Id,
	parent_call:    Call_Id,
}

// Counters are the highest ids a session has used, so an owner continues
// numbering after a restart.
Counters :: struct {
	turn:    Turn_Id,
	request: Request_Id,
	call:    Call_Id,
	node:    Node_Id,
	branch:  Branch_Id,
}

// Record is one journal fact. The journal fills seq, time_ms, mono_ns, run, and
// data; the caller fills kind and the correlation columns known where the fact
// was observed.
Record :: struct {
	seq:         Journal_Seq,
	time_ms:     i64,
	mono_ns:     i64,
	run:         Run_Id,
	kind:        Record_Kind,
	session:     Session_Id,
	branch:      Branch_Id,
	node:        Node_Id,
	turn:        Turn_Id,
	request:     Request_Id,
	attempt:     Attempt_No,
	job:         Job_Id,
	call:        Call_Id,
	parent_call: Call_Id,
	task:        string,
	subagent:    Session_Id,
	hook:        string,
	provider:    string,
	model:       string,
	data:        string,
	body:        []u8,
}

// Node is one committed step of the session tree. The journal fills id, seq,
// and data. parent is the previous node on the branch, or the fork point for a
// branch's first node; covers is set on a Checkpoint only.
Node :: struct {
	session: Session_Id,
	id:      Node_Id,
	parent:  Node_Id,
	branch:  Branch_Id,
	kind:    Node_Kind,
	turn:    Turn_Id,
	covers:  Node_Id,
	seq:     Journal_Seq,
	data:    string,
	body:    []u8,
}

// Corruption names the row a read found damaged.
Corruption :: struct {
	session: Session_Id,
	seq:     Journal_Seq,
}

// Journal is one connection, used by one thread, and at most one claimed
// session. It must not move while open: the connection and arena keep their
// address. The zero value is closed.
Journal :: struct {
	conn:       db.Conn,
	allocator:  mem.Allocator,
	directory:  string, // owned
	run:        Run_Id,
	open:       bool,
	read_only:  bool,
	claimed:    Session_Id,
	claim_file: ^os.File,
	counters:   Counters,

	// batch owns the bytes of every pending item until the commit that writes it.
	batch:      virtual.Arena,
	pending:    [dynamic]Pending,
	oldest:     time.Tick, // when the first pending item was appended
	last_seq:   Journal_Seq,
	inserts:    [Insert]db.Statement, // prepared by the first commit

	// failure is the first failure that stopped the journal from writing. Every
	// later append is dropped and every later commit returns it.
	failure:    Error,
	corrupt:    Corruption,
}

// open opens the journal in directory, creating it private to the user and
// migrating its schema when writable. A read-only journal creates, migrates, and
// writes nothing, and refuses a database at another version.
@(require_results)
open :: proc(j: ^Journal, directory: string, run: Run_Id, mode: Open_Mode, allocator := context.allocator) -> (err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	assert(!j.open, "the journal is already open")
	assert(run != {}, "a journal writes for a run")
	j^ = {
		allocator = allocator,
		run       = run,
		read_only = mode == .Read_Only,
	}
	j.pending.allocator = allocator
	defer if err != nil { _ = close(j) }

	j.directory = strings.clone(directory, allocator) or_return
	path := filepath.join({directory, DATABASE_NAME}, context.temp_allocator) or_return
	if mode == .Read_Write {
		make_private_directory(directory) or_return
		make_private_file(path) or_return
	} else if !os.exists(path) {
		return Journal_Error.Not_Found
	}

	config := sqlite.Config {
		path            = path,
		busy_timeout_ms = BUSY_TIMEOUT_MS,
		mode            = .Read_Only if mode == .Read_Only else .Read_Write_Create,
	}
	sqlite.open(&j.conn, config, allocator) or_return
	if mode == .Read_Write {
		enable_write_ahead_log(j) or_return
		db.exec(&j.conn, "PRAGMA synchronous = FULL") or_return
		schema_migrate(j) or_return
	} else {
		version := schema_version(j) or_return
		if version > SCHEMA_VERSION { return Journal_Error.Schema_Too_New }
		if version != SCHEMA_VERSION { return Journal_Error.Schema_Unknown }
	}

	j.last_seq = Journal_Seq(query_int(j, "SELECT COALESCE(MAX(seq), 0) FROM records", nil) or_return)
	j.open = true
	return nil
}

// close releases the claim, the statements, the connection, and every pending
// item. Pending items are dropped, not committed. Closing a zero journal does nothing.
close :: proc(j: ^Journal) -> Error {
	release_err := release(j)
	for &statement in j.inserts { _ = db.statement_close(&statement) }
	close_err := db.close(&j.conn)
	delete(j.pending)
	virtual.arena_destroy(&j.batch)
	delete(j.directory, j.allocator)
	j^ = {}
	if release_err != nil { return release_err }
	return close_err
}

// claim takes the writer claim for s and returns the ids it has used.
@(require_results)
claim :: proc(j: ^Journal, s: Session_Id) -> (counters: Counters, err: Error) {
	assert(j.open && !j.read_only, "claim needs a writable journal")
	assert(j.claimed == {}, "the journal already holds a claim")
	take_claim(j, s) or_return
	defer if err != nil { _ = release(j) }

	exists: bool
	counters, exists = load_counters(j, s) or_return
	if !exists { return {}, Journal_Error.Not_Found }
	j.counters = counters
	return counters, nil
}

// release drops the writer claim, if any.
release :: proc(j: ^Journal) -> Error {
	file := j.claim_file
	j.claim_file = nil
	j.claimed = {}
	j.counters = {}
	if file == nil { return nil }
	unlock_err := claim_lock_drop(file)
	close_err := os.close(file)
	if unlock_err != nil { return unlock_err }
	return close_err
}

// create_session claims a new session and buffers its row, `session.created`,
// and its initial branch. The session exists once the caller commits.
@(require_results)
create_session :: proc(j: ^Journal, info: Session_Info) -> (id: Session_Id, err: Error) {
	assert(j.open && !j.read_only, "create_session needs a writable journal")
	assert(j.claimed == {}, "the journal already holds a claim")
	assert(info.workspace != "", "a session runs in a workspace")
	if j.failure != nil { return {}, j.failure }

	id = session_id_create()
	take_claim(j, id) or_return

	parent_hex: [SESSION_ID_HEX_LENGTH]u8
	parent := ""
	if info.parent_session != {} { parent = session_id_to_hex(info.parent_session, parent_hex[:]) }
	role := SESSION_ROLE_NAMES[info.role]
	append_record(
		j,
		Record{kind = .Session_Created, session = id, branch = INITIAL_BRANCH},
		Session_Created{workspace = info.workspace, role = role, parent_session = parent, parent_call = info.parent_call},
	)
	push(
		j,
		Session_Row {
			session = id,
			created_ms = now_ms(),
			workspace = batch_text(j, info.workspace),
			parent_session = info.parent_session,
			parent_call = info.parent_call,
			role = role,
		},
	)
	_ = append_branch(j, 0)
	if j.failure != nil {
		_ = release(j)
		return {}, j.failure
	}
	return id, nil
}

@(private)
make_private_directory :: proc(path: string) -> Error {
	err := os.make_directory_all(path, PRIVATE_DIRECTORY_PERMISSIONS)
	if err != nil && err != .Exist { return err }
	return nil
}

// make_private_file creates path owner-only before SQLite opens it, since SQLite
// gives its write-ahead log the database file's permissions.
@(private)
make_private_file :: proc(path: string) -> Error {
	file := os.open(path, {.Read, .Write, .Create}, PRIVATE_FILE_PERMISSIONS) or_return
	return os.close(file)
}

// enable_write_ahead_log checks the answer, because SQLite keeps another mode
// on a filesystem that cannot support WAL.
@(private)
enable_write_ahead_log :: proc(j: ^Journal) -> (err: Error) {
	rows: db.Rows
	defer db.rows_close(&rows)
	row := query_first(j, &rows, "PRAGMA journal_mode = WAL", nil) or_return
	mode := row_view(&row)
	if row.err != nil { return row.err }
	if !strings.equal_fold(mode, "wal") { return Journal_Error.Storage_Failed }
	return nil
}

// take_claim flocks the session's lock file, which the kernel releases when the
// process dies.
@(private)
take_claim :: proc(j: ^Journal, session: Session_Id) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	directory := filepath.join({j.directory, LOCK_DIRECTORY}, context.temp_allocator) or_return
	make_private_directory(directory) or_return
	hex: [SESSION_ID_HEX_LENGTH]u8
	name := fmt.tprintf("%s.lock", session_id_to_hex(session, hex[:]))
	path := filepath.join({directory, name}, context.temp_allocator) or_return

	file := os.open(path, {.Read, .Write, .Create}, PRIVATE_FILE_PERMISSIONS) or_return
	held_elsewhere, lock_err := claim_lock_take(file)
	if lock_err != nil || held_elsewhere {
		_ = os.close(file)
		if lock_err != nil { return lock_err }
		return Journal_Error.Claimed
	}
	j.claimed = session
	j.claim_file = file
	j.counters = {}
	return nil
}

@(private)
COUNTERS_QUERY :: `SELECT
	EXISTS (SELECT 1 FROM sessions WHERE session = ?1),
	COALESCE((SELECT MAX(turn) FROM records WHERE session = ?1), 0),
	COALESCE((SELECT MAX(request) FROM records WHERE session = ?1), 0),
	COALESCE((SELECT MAX(call) FROM records WHERE session = ?1), 0),
	COALESCE((SELECT MAX(node) FROM nodes WHERE session = ?1), 0),
	COALESCE((SELECT MAX(branch) FROM branches WHERE session = ?1), 0)`

@(private)
load_counters :: proc(j: ^Journal, s: Session_Id) -> (counters: Counters, exists: bool, err: Error) {
	session := s
	rows: db.Rows
	defer db.rows_close(&rows)
	row := query_first(j, &rows, COUNTERS_QUERY, {db.Value(session[:])}) or_return
	exists = row_int(&row) != 0
	counters.turn = Turn_Id(row_int(&row))
	counters.request = Request_Id(row_int(&row))
	counters.call = Call_Id(row_int(&row))
	counters.node = Node_Id(row_int(&row))
	counters.branch = Branch_Id(row_int(&row))
	return counters, exists, row.err
}
