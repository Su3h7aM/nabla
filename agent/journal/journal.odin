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

// BUSY_TIMEOUT_MS is how long a commit waits for another process's write lock.
BUSY_TIMEOUT_MS :: 5_000

INITIAL_BRANCH :: Branch_Id(1)

PRIVATE_DIRECTORY_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}
PRIVATE_FILE_PERMISSIONS :: os.Permissions{.Read_User, .Write_User}

Open_Mode :: enum {
	Read_Write,
	Read_Only,
}

New_Session :: struct {
	id:             Session_Id, // zero creates a fresh id
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

// Journal is one connection and at most one claimed session. One thread uses it
// at a time; ownership passes to another thread only while no result set or
// transaction is open, and the thread that hands it off stops using it. It must
// not move while open: the connection and arena keep their address. The zero
// value is closed.
Journal :: struct {
	connection:  db.Conn,
	allocator:   mem.Allocator,
	directory:   string, // owned
	// locks holds one lock file per claimed or followed session, owned. The files
	// are never deleted: replacing a locked inode would let two processes hold one
	// claim.
	locks:       string,
	run:         Run_Id,
	open:        bool,
	read_only:   bool,
	claimed:     Session_Id,
	// followed is the session another process claimed, which this journal watches
	// and appends `user.input` for. It is never set together with claimed.
	followed:    Session_Id,
	// lock_file is the descriptor of the claimed or followed session's lock file.
	// A follower holds it without the flock, so try_claim retries on it.
	lock_file:   ^os.File,
	counters:    Counters,

	// batch owns the bytes of every pending item until the commit that writes it.
	batch:       virtual.Arena,
	pending:     [dynamic]Pending,
	batch_since: time.Tick, // when this pending batch started or its last busy commit returned
	last_seq:    Journal_Seq,
	inserts:     [Insert]db.Statement, // prepared by the first commit

	// failure is the first failure that stopped the journal from writing. Every
	// later append is dropped and every later commit returns it.
	failure:     Error,
	corrupt:     Corruption,
}

// open opens the journal in directory, creating it private to the user and
// migrating its schema when writable. A writable journal takes its claims on lock
// files in locks, created private to the user when a claim needs it. A read-only
// journal ignores locks, creates, migrates, and writes nothing, and refuses a
// database at another version.
@(require_results)
open :: proc(journal: ^Journal, directory, locks: string, run: Run_Id, mode: Open_Mode, allocator := context.allocator) -> (error: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	assert(!journal.open, "the journal is already open")
	assert(run != {}, "a journal writes for a run")
	assert(mode == .Read_Only || locks != "", "a writable journal claims sessions on lock files")
	journal^ = {
		allocator = allocator,
		run       = run,
		read_only = mode == .Read_Only,
	}
	journal.pending.allocator = allocator
	// A failed open tears down what it built; that teardown's own failure
	// changes nothing, because the open error is what the caller needs.
	defer if error != nil { _ = close(journal) }

	virtual.arena_init_growing(&journal.batch) or_return
	journal.directory = strings.clone(directory, allocator) or_return
	if mode == .Read_Write { journal.locks = strings.clone(locks, allocator) or_return }
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
	sqlite.open(&journal.connection, config, allocator) or_return
	if mode == .Read_Write {
		enable_write_ahead_log(journal) or_return
		db.exec(&journal.connection, "PRAGMA synchronous = FULL") or_return
		schema_migrate(journal) or_return
	} else {
		version := schema_version(journal) or_return
		if version > SCHEMA_VERSION { return Journal_Error.Schema_Too_New }
		if version != SCHEMA_VERSION { return Journal_Error.Schema_Unknown }
	}

	journal.last_seq = Journal_Seq(query_int(journal, "SELECT COALESCE(MAX(seq), 0) FROM records", nil) or_return)
	journal.open = true
	return nil
}

// close records `session.released` for a held claim and commits it with every
// pending item, then releases the claim, the statements, and the connection.
// The first failure wins and cleanup continues: a commit failure is returned
// only when releasing the claim and closing the connection succeed. A journal
// that is read-only, not open, holds no claim, or has latched a failure writes
// nothing, and its pending items are dropped. Closing a zero journal does nothing.
@(require_results)
close :: proc(journal: ^Journal) -> Error {
	commit_error: Error
	if journal.open && !journal.read_only && journal.claimed != {} && journal.failure == nil {
		append_record(journal, Record{kind = .Session_Released, session = journal.claimed}, Session_Released{})
		_, commit_error = commit(journal)
	}
	release_error := release(journal)
	// A statement that refuses to close stays on the connection's list, and the
	// connection close below is what reports it.
	for &statement in journal.inserts { _ = db.statement_close(&statement) }
	close_error := db.close(&journal.connection)
	delete(journal.pending)
	virtual.arena_destroy(&journal.batch)
	delete(journal.directory, journal.allocator)
	delete(journal.locks, journal.allocator)
	journal^ = {}
	if release_error != nil { return release_error }
	if close_error != nil { return close_error }
	return commit_error
}

// claim takes the writer claim for session and returns the ids it has used.
@(require_results)
claim :: proc(journal: ^Journal, session: Session_Id) -> (counters: Counters, error: Error) {
	assert(journal.open && !journal.read_only, "claim needs a writable journal")
	assert(journal.claimed == {} && journal.followed == {}, "the journal already holds a session")
	take_claim(journal, session) or_return
	// Dropping the claim is teardown; the load error is what the caller needs.
	defer if error != nil { _ = release(journal) }
	return claim_enter(journal, session)
}

// follow opens the lock file of a session another process claimed and keeps the
// descriptor without taking the flock, so the journal follows the session: it
// appends `user.input` for it through append_input and retries the claim through
// try_claim. Following needs no claim to be held elsewhere, and a session that
// is not claimed anywhere can be followed too.
@(require_results)
follow :: proc(journal: ^Journal, session: Session_Id) -> Error {
	assert(journal.open && !journal.read_only, "follow needs a writable journal")
	assert(journal.claimed == {} && journal.followed == {}, "the journal already holds a session")
	journal.lock_file = lock_open(journal, session) or_return
	journal.followed = session
	return nil
}

// try_claim retries the flock without waiting on the descriptor follow kept, so
// no close event reaches the other watchers of the lock file. On success the
// journal holds the claim exactly as claim leaves it and returns the ids the
// session has used. It returns Claimed while another process holds the claim,
// and any other failure; the journal stays a follower then.
@(require_results)
try_claim :: proc(journal: ^Journal) -> (counters: Counters, error: Error) {
	assert(journal.open && !journal.read_only, "try_claim needs a writable journal")
	assert(journal.followed != {}, "try_claim needs a followed session")
	held_elsewhere, lock_error := claim_lock_take(journal.lock_file)
	if lock_error != nil { return {}, lock_error }
	if held_elsewhere { return {}, Journal_Error.Claimed }

	session := journal.followed
	journal.claimed = session
	journal.followed = {}
	journal.counters = {}
	defer if error != nil {
		// The lock is let go again and the journal follows as before; the load
		// error is what the caller needs.
		_ = claim_lock_drop(journal.lock_file)
		journal.claimed = {}
		journal.followed = session
	}
	return claim_enter(journal, session)
}

// release drops the writer claim or the follow, if any.
@(require_results)
release :: proc(journal: ^Journal) -> Error {
	file := journal.lock_file
	was_claimed := journal.claimed != {}
	journal.lock_file = nil
	journal.claimed = {}
	journal.followed = {}
	journal.counters = {}
	if file == nil { return nil }
	unlock_error: os.Error
	if was_claimed { unlock_error = claim_lock_drop(file) }
	close_error := os.close(file)
	if unlock_error != nil { return unlock_error }
	return close_error
}

// create_session claims a new session and buffers its row, `session.created`,
// and its initial branch. The session exists once the caller commits.
@(require_results)
create_session :: proc(journal: ^Journal, new_session: New_Session) -> (id: Session_Id, error: Error) {
	assert(journal.open && !journal.read_only, "create_session needs a writable journal")
	assert(journal.claimed == {} && journal.followed == {}, "the journal already holds a session")
	assert(new_session.workspace != "", "a session runs in a workspace")
	if journal.failure != nil { return {}, journal.failure }

	id = new_session.id
	if id == {} { id = session_id_create() }
	take_claim(journal, id) or_return

	parent_hex: [SESSION_ID_HEX_LENGTH]u8
	parent := ""
	if new_session.parent_session != {} { parent = session_id_to_hex(new_session.parent_session, parent_hex[:]) }
	role := SESSION_ROLE_NAMES[new_session.role]
	append_record(
		journal,
		Record{kind = .Session_Created, session = id, branch = INITIAL_BRANCH},
		Session_Created{workspace = new_session.workspace, role = role, parent_session = parent, parent_call = new_session.parent_call},
	)
	append_record(journal, Record{kind = .Session_Claimed, session = id}, Session_Claimed{resumed = false})
	push(
		journal,
		Session_Row {
			session = id,
			created_ms = now_ms(),
			workspace = batch_text(journal, new_session.workspace),
			parent_session = new_session.parent_session,
			parent_call = new_session.parent_call,
			role = role,
		},
	)
	// The initial branch is the one this call creates; a failure latches below.
	_ = append_branch(journal, 0)
	if journal.failure != nil {
		// Dropping the claim is teardown; the latch is what the caller needs.
		_ = release(journal)
		return {}, journal.failure
	}
	return id, nil
}

// make_private_directory creates path owner-only, and narrows an existing one
// whose mode is wider.
@(private, require_results)
make_private_directory :: proc(path: string) -> Error {
	error := os.make_directory_all(path, PRIVATE_DIRECTORY_PERMISSIONS)
	if error != nil && error != .Exist { return error }
	return os.chmod(path, PRIVATE_DIRECTORY_PERMISSIONS)
}

// make_private_file creates path owner-only, or narrows an existing one, before
// SQLite opens it, since SQLite gives its write-ahead log the same permissions.
@(private, require_results)
make_private_file :: proc(path: string) -> Error {
	file := os.open(path, {.Read, .Write, .Create}, PRIVATE_FILE_PERMISSIONS) or_return
	chmod_error := os.fchmod(file, PRIVATE_FILE_PERMISSIONS)
	close_error := os.close(file)
	if chmod_error != nil { return chmod_error }
	return close_error
}

// enable_write_ahead_log checks the answer, because SQLite keeps another mode
// on a filesystem that cannot support WAL.
@(private, require_results)
enable_write_ahead_log :: proc(journal: ^Journal) -> (error: Error) {
	rows: db.Rows
	defer _ = db.rows_close(&rows) // The row is already read; only releasing the set is left.
	row := query_first(journal, &rows, "PRAGMA journal_mode = WAL", nil) or_return
	mode := row_view(&row)
	if row.error != nil { return row.error }
	if !strings.equal_fold(mode, "wal") { return Journal_Error.Storage_Failed }
	return nil
}

// lock_open opens the session's lock file, creating it, and pins it against
// periodic clean-up of its directory. The caller owns the file.
@(private, require_results)
lock_open :: proc(journal: ^Journal, session: Session_Id) -> (file: ^os.File, error: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	make_private_directory(journal.locks) or_return
	hex_text: [SESSION_ID_HEX_LENGTH]u8
	name := fmt.tprintf("%s.lock", session_id_to_hex(session, hex_text[:]))
	path := filepath.join({journal.locks, name}, context.temp_allocator) or_return

	file = os.open(path, {.Read, .Write, .Create}, PRIVATE_FILE_PERMISSIONS) or_return
	if pin_error := claim_file_pin(file); pin_error != nil {
		// The file is abandoned; the pin failure is what the caller needs.
		_ = os.close(file)
		return nil, pin_error
	}
	return file, nil
}

// take_claim flocks the session's lock file, which the kernel releases when the
// process dies.
@(private, require_results)
take_claim :: proc(journal: ^Journal, session: Session_Id) -> Error {
	file := lock_open(journal, session) or_return
	held_elsewhere, lock_error := claim_lock_take(file)
	if lock_error != nil || held_elsewhere {
		// The file is abandoned; the lock outcome is what the caller needs.
		_ = os.close(file)
		if lock_error != nil { return lock_error }
		return Journal_Error.Claimed
	}
	journal.claimed = session
	journal.lock_file = file
	journal.counters = {}
	return nil
}

// claim_enter loads the ids the claimed session has used and records
// `session.claimed`. The caller has set journal.claimed and undoes it on failure.
@(private, require_results)
claim_enter :: proc(journal: ^Journal, session: Session_Id) -> (counters: Counters, error: Error) {
	exists: bool
	counters, exists = load_counters(journal, session) or_return
	if !exists { return {}, Journal_Error.Not_Found }
	journal.counters = counters
	append_record(journal, Record{kind = .Session_Claimed, session = session}, Session_Claimed{resumed = true})
	return counters, nil
}

@(private)
COUNTERS_QUERY :: `SELECT
	EXISTS (SELECT 1 FROM sessions WHERE session = ?1),
	COALESCE((SELECT MAX(turn) FROM records WHERE session = ?1), 0),
	COALESCE((SELECT MAX(request) FROM records WHERE session = ?1), 0),
	COALESCE((SELECT MAX(call) FROM records WHERE session = ?1), 0),
	COALESCE((SELECT MAX(node) FROM nodes WHERE session = ?1), 0),
	COALESCE((SELECT MAX(branch) FROM branches WHERE session = ?1), 0)`

@(private, require_results)
load_counters :: proc(journal: ^Journal, session: Session_Id) -> (counters: Counters, exists: bool, error: Error) {
	session := session
	rows: db.Rows
	defer _ = db.rows_close(&rows) // The row is already read; only releasing the set is left.
	row := query_first(journal, &rows, COUNTERS_QUERY, {db.Value(session[:])}) or_return
	exists = row_int(&row) != 0
	counters.turn = Turn_Id(row_int(&row))
	counters.request = Request_Id(row_int(&row))
	counters.call = Call_Id(row_int(&row))
	counters.node = Node_Id(row_int(&row))
	counters.branch = Branch_Id(row_int(&row))
	return counters, exists, row.error
}
