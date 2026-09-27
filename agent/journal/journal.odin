package journal

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "nabla:db"
import "nabla:db/sqlite"

// DATABASE_NAME is the one file SQLite owns inside the journal's directory.
DATABASE_NAME :: "journal.db"

// LOCK_DIRECTORY holds one lock file per session claimed for writing. The files
// are never deleted: replacing a locked inode would let two processes end up
// holding what each believes is the same claim.
LOCK_DIRECTORY :: "locks"

// BUSY_TIMEOUT_MS is how long a write waits for another process to release the
// database lock before it fails. Writes are short, so a short wait is enough.
BUSY_TIMEOUT_MS :: 5_000

// PENDING_HEADROOM is how many buffered items a fresh journal's list starts
// with. The batch limits decide how many of them one commit writes, so the list
// grows past this when the harness appends without committing.
PENDING_HEADROOM :: 8

// INITIAL_BRANCH is the branch every session starts on. Branch 0 does not
// exist: a branch's base node is 0 when it forks from the start of the session.
INITIAL_BRANCH :: 1

// PRIVATE_DIRECTORY_PERMISSIONS and PRIVATE_FILE_PERMISSIONS admit the owner
// alone. The journal holds prompts, tool output, and file contents, so nothing
// else on the machine has any business reading it.
PRIVATE_DIRECTORY_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}
PRIVATE_FILE_PERMISSIONS :: os.Permissions{.Read_User, .Write_User}

@(private)
OTHER_ACCESS :: os.Permissions{.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other}

// Open_Mode is whether a journal may write. A reader never claims, migrates, or
// writes, which is what lets a diagnostics command read a session whose harness
// is running.
Open_Mode :: enum {
	Read_Write,
	Read_Only,
}

// Session_Info describes a session being created. workspace is the directory it
// runs in. A delegated session names the session and the call that started it.
Session_Info :: struct {
	workspace:      string,
	role:           Session_Role,
	parent_session: Session_Id,
	parent_call:    Call_Id,
}

// Counters are the highest ids one session has used: turn, request, and call are
// the ids the harness numbers itself, and node and branch are the ids the
// journal allocates. claim loads them, so an owner continues numbering after a
// restart instead of reusing an id.
Counters :: struct {
	turn:    Turn_Id,
	request: Request_Id,
	call:    Call_Id,
	node:    Node_Id,
	branch:  Branch_Id,
}

// Record is one journal fact. The journal fills seq, time_ms, mono_ns, and run;
// the caller fills the correlation columns that exist where the fact was
// observed, and the payload passed to append_record becomes `data`. On read,
// `data` is the stored JSON text and `body` the stored bytes.
//
// Zero means absent for every id, and an absent id is stored as SQL NULL.
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

// Node is one committed conversational step of the session tree. The journal
// fills id and seq and appends the `node.committed` record whose seq is the
// node's; the caller fills the tree position (session, parent, branch, kind,
// turn) and the payload that becomes `data`, and a checkpoint names the node it
// summarises in `covers`.
//
// A fork's first node has parent set to the node it forked from, on any branch.
// Every other node's parent is the previous node on its own branch.
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

// Journal is one open database and at most one session claimed for writing. The
// zero value is a closed journal, safe to close and nothing else.
//
// A journal is used by one thread. It owns its connection, its batch arena, and
// every buffered item's bytes, so it must not be copied or moved while it is
// open: the arena and the connection keep their address.
Journal :: struct {
	conn:          db.Conn,
	allocator:     mem.Allocator,
	directory:     string, // owned; the directory the database lives in
	run:           Run_Id,
	open:          bool,

	// read_only records how the connection was opened. A reader refuses every
	// mutation before it touches the database, so an accidental write is an
	// error rather than a change to the file.
	read_only:     bool,

	// claimed is the session this journal may write for, absent when none is
	// claimed. claim_file is the flock that holds it.
	claimed:       Session_Id,
	claim_file:    ^os.File,
	counters:      Counters,

	// batch owns every byte a buffered item references, so a commit writes what
	// it was given without copying anything the caller lent.
	batch:         virtual.Arena,
	pending:       [dynamic]Pending,
	pending_bytes: int,
	oldest:        time.Tick, // when the oldest buffered item was appended
	last_seq:      Journal_Seq,

	// The insert statements are prepared on the first commit and finalized on
	// close. Preparing once is what makes a batch of a few hundred rows cheap.
	inserts_ready: bool,
	record_stmt:   db.Statement,
	node_stmt:     db.Statement,
	branch_stmt:   db.Statement,
	session_stmt:  db.Statement,
	artifact_stmt: db.Statement,

	// failure latches the first failure that made the journal unable to write
	// and is what every later commit returns. failure_cause keeps the lower
	// error, so the harness can report the database's own message. corrupt
	// names the row that could not be read.
	failure:       Error,
	failure_cause: Error,
	corrupt:       Corruption,
}

// open opens or creates the journal in directory and brings its schema up to
// date. The run id names the process run every record written here belongs to.
//
// A writable open creates the directory as 0700 and the database as 0600. A
// read-only open creates nothing, migrates nothing, and refuses a database that
// is not at the version this build reads.
//
// The journal owns the connection, the directory path, and the batch arena;
// close releases them. A refused open leaves nothing behind.
@(require_results)
open :: proc(j: ^Journal, directory: string, run: Run_Id, mode: Open_Mode, allocator := context.allocator) -> Error {
	if j.open { return Journal_Error.Invalid_State }
	if directory == "" { return Journal_Error.Invalid_State }
	if run_id_is_absent(run) { return Journal_Error.Invalid_State }

	j.allocator = allocator
	j.run = run
	j.read_only = mode == .Read_Only
	j.directory = strings.clone(directory, allocator)
	if j.directory == "" { return mem.Allocator_Error.Out_Of_Memory }
	if arena_err := virtual.arena_init_growing(&j.batch); arena_err != nil {
		delete(j.directory, allocator)
		j^ = {}
		return arena_err
	}
	pending, pending_err := make([dynamic]Pending, 0, PENDING_HEADROOM, allocator)
	j.pending = pending
	if pending_err != nil {
		virtual.arena_destroy(&j.batch)
		delete(j.directory, allocator)
		j^ = {}
		return pending_err
	}

	succeeded := false
	defer if !succeeded {
		_ = db.close(&j.conn)
		clear(&j.pending)
		delete(j.pending)
		virtual.arena_destroy(&j.batch)
		delete(j.directory, allocator)
		j^ = {}
	}

	if mode == .Read_Only {
		open_readable(j) or_return
	} else {
		open_writable(j) or_return
	}

	// The position a commit that writes nothing reports is the last seq the
	// database holds, not zero.
	last, last_err := read_last_seq(j)
	if last_err != nil { return last_err }
	j.last_seq = last

	j.open = true
	succeeded = true
	return nil
}

// close finalizes the prepared statements, releases any claim, closes the
// connection, and destroys the batch arena. Closing a zero journal, or one
// already closed, does nothing.
@(require_results)
close :: proc(j: ^Journal) -> Error {
	if !j.open && j.directory == "" { return nil }

	release_err := release(j)
	statement_err: Error
	// Every statement is closed, prepared or not: closing a statement that was
	// never prepared does nothing, and a commit that failed partway through
	// preparing them leaves some behind.
	if err := db.statement_close(&j.record_stmt); err != nil { statement_err = err }
	if err := db.statement_close(&j.node_stmt); err != nil && statement_err == nil { statement_err = err }
	if err := db.statement_close(&j.branch_stmt); err != nil && statement_err == nil { statement_err = err }
	if err := db.statement_close(&j.session_stmt); err != nil && statement_err == nil { statement_err = err }
	if err := db.statement_close(&j.artifact_stmt); err != nil && statement_err == nil { statement_err = err }
	connection_err := db.close(&j.conn)

	clear(&j.pending)
	delete(j.pending)
	virtual.arena_destroy(&j.batch)
	delete(j.directory, j.allocator)
	j^ = {}

	first := release_err
	if first == nil { first = statement_err }
	if first == nil { first = connection_err }
	return first
}

// claim takes the writer claim for s and returns the ids it has used, so the
// caller continues numbering where the last run stopped. A second claim on this
// journal, or a claim another process holds, is refused with .Claimed, and a
// session the journal does not have is refused with .Not_Found.
//
// The claim is a flock on a file beside the database, so the kernel drops it
// when the process dies. Release it with release.
@(require_results)
claim :: proc(j: ^Journal, s: Session_Id) -> (Counters, Error) {
	if !j.open { return {}, Journal_Error.Invalid_State }
	if j.read_only { return {}, Journal_Error.Read_Only }
	if !session_id_is_absent(j.claimed) { return {}, Journal_Error.Claimed }
	if session_id_is_absent(s) { return {}, Journal_Error.Not_Found }

	// A session that is not in the journal is refused before a lock file for it
	// is created.
	exists, exists_err := session_exists(j, s)
	if exists_err != nil { return {}, exists_err }
	if !exists { return {}, Journal_Error.Not_Found }

	counters, counters_err := load_counters(j, s)
	if counters_err != nil { return {}, counters_err }
	if claim_err := take_claim(j, s); claim_err != nil { return {}, claim_err }
	j.counters = counters
	return counters, nil
}

// release drops the writer claim. Releasing when nothing is claimed does
// nothing, so the call is safe on a journal that never claimed.
@(require_results)
release :: proc(j: ^Journal) -> Error {
	if j.claim_file == nil {
		j.claimed = Session_Id{}
		return nil
	}
	unlock_err := claim_lock_drop(j.claim_file)
	close_err := os.close(j.claim_file)
	j.claim_file = nil
	j.claimed = Session_Id{}
	if unlock_err != nil { return unlock_err }
	return close_err
}

// create_session records a new session, claims it for writing, and buffers its
// row, its `session.created` record, and its initial branch. The caller commits.
//
// A session is claimed for writing from the moment it exists, so the caller
// that creates it is its only writer. The returned id is absent, with the
// error, when nothing could be created.
@(require_results)
create_session :: proc(j: ^Journal, info: Session_Info) -> (Session_Id, Error) {
	if !j.open { return {}, Journal_Error.Invalid_State }
	if j.read_only { return {}, Journal_Error.Read_Only }
	if !session_id_is_absent(j.claimed) { return {}, Journal_Error.Claimed }
	if j.failure != nil { return {}, j.failure }
	if info.workspace == "" { return {}, Journal_Error.Invalid_State }

	id := session_id_create()
	if session_id_is_absent(id) { return {}, Journal_Error.Storage_Failed }
	if claim_err := take_claim(j, id); claim_err != nil { return {}, claim_err }
	j.counters = Counters {
		branch = INITIAL_BRANCH,
	}

	parent_text := ""
	if !session_id_is_absent(info.parent_session) {
		parent_hex: [SESSION_ID_HEX_LENGTH]u8
		parent_text = session_id_to_hex(info.parent_session, parent_hex[:])
	}
	role_name := SESSION_ROLE_NAMES[info.role]
	append_record(
		j,
		Record{session = id, branch = INITIAL_BRANCH, kind = .Session_Created},
		Session_Created{workspace = info.workspace, role = role_name, parent_session = parent_text, parent_call = info.parent_call},
	)
	push_session_row(
		j,
		Session_Row {
			session = id,
			created_ms = now_ms(),
			workspace = info.workspace,
			parent_session = info.parent_session,
			parent_call = info.parent_call,
			role = role_name,
		},
	)
	push_branch(j, id, INITIAL_BRANCH, 0)
	if j.failure != nil {
		// The session exists on disk only once the caller commits, and no part
		// of it could be buffered, so the caller has to hear about it now.
		// The claim and the counters it loaded are dropped with it: a later
		// create_session starts from a journal with no session claimed.
		cause := j.failure
		_ = release(j)
		j.counters = {}
		return {}, cause
	}
	return id, nil
}

// --- opening ----------------------------------------------------------------

// open_writable creates the directory and the database when they are missing
// and migrates the schema to this build's version.
@(private)
open_writable :: proc(j: ^Journal) -> Error {
	ensure_private_directory(j.directory) or_return
	database_path, join_err := filepath.join({j.directory, DATABASE_NAME}, context.temp_allocator)
	if join_err != nil { return join_err }
	ensure_private_file(database_path) or_return

	config := sqlite.Config {
		path            = database_path,
		busy_timeout_ms = BUSY_TIMEOUT_MS,
		foreign_keys    = true,
	}
	if open_err := sqlite.open(&j.conn, config, j.allocator); open_err != nil { return open_err }

	set_journal_mode(j) or_return
	// FULL is deliberate: a record of intent is what lets an interrupted
	// session be read honestly, and a write volume of a few rows per turn does
	// not make the extra flush matter.
	if err := db.exec(&j.conn, "PRAGMA synchronous = FULL"); err != nil { return err }
	return schema_migrate(j)
}

// open_readable verifies a database a writer left behind. It takes no claim,
// creates nothing, and requires exactly the version this build reads: every read
// names columns, so an older database does not have them and a newer one may
// have changed them.
@(private)
open_readable :: proc(j: ^Journal) -> Error {
	ensure_readable_directory(j.directory) or_return
	database_path, join_err := filepath.join({j.directory, DATABASE_NAME}, context.temp_allocator)
	if join_err != nil { return join_err }
	ensure_readable_file(database_path) or_return

	config := sqlite.Config {
		path            = database_path,
		busy_timeout_ms = BUSY_TIMEOUT_MS,
		foreign_keys    = true,
		mode            = .Read_Only,
	}
	if open_err := sqlite.open(&j.conn, config, j.allocator); open_err != nil { return open_err }

	version, version_err := schema_read_version(j)
	if version_err != nil { return version_err }
	if version > SCHEMA_VERSION { return Journal_Error.Schema_Too_New }
	if version != SCHEMA_VERSION { return Journal_Error.Schema_Unknown }
	return nil
}

// set_journal_mode turns on write-ahead logging and checks that the database
// accepted it: SQLite answers the pragma with the mode it ended up in and
// quietly keeps another mode on a filesystem that cannot support WAL, while
// this connection assumes readers do not block the writer.
@(private)
set_journal_mode :: proc(j: ^Journal) -> Error {
	rows: db.Rows
	if err := db.query(&j.conn, &rows, "PRAGMA journal_mode = WAL"); err != nil { return err }
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return next_err }
	if !has_row { return Journal_Error.Corrupt }
	mode, convert_err := db.as_string(values[0])
	if convert_err != nil { return convert_err }
	if !strings.equal_fold(mode, "wal") { return Journal_Error.Storage_Failed }
	return nil
}

// read_last_seq is the highest seq the database holds, 0 when it holds none.
@(private)
read_last_seq :: proc(j: ^Journal) -> (Journal_Seq, Error) {
	return read_scalar(j, "SELECT COALESCE((SELECT MAX(seq) FROM records), 0)", nil)
}

// read_scalar runs one query with one row and returns its first column as an
// integer.
@(private)
read_scalar :: proc(j: ^Journal, query: string, args: []db.Value) -> (Journal_Seq, Error) {
	rows: db.Rows
	if err := db.query(&j.conn, &rows, query, args); err != nil { return 0, err }
	defer db.rows_close(&rows)
	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return 0, next_err }
	if !has_row { return 0, Journal_Error.Corrupt }
	number, convert_err := db.as_i64(values[0])
	if convert_err != nil { return 0, convert_err }
	return Journal_Seq(number), nil
}

// --- claims and counters ----------------------------------------------------

// take_claim takes the writer claim on session: a lock file beside the database
// that the kernel releases when the process dies. A second journal holding the
// same session is refused with .Claimed.
@(private)
take_claim :: proc(j: ^Journal, session: Session_Id) -> Error {
	if !session_id_is_absent(j.claimed) { return Journal_Error.Claimed }

	lock_directory, join_err := filepath.join({j.directory, LOCK_DIRECTORY}, context.temp_allocator)
	if join_err != nil { return join_err }
	ensure_private_directory(lock_directory) or_return

	hex: [SESSION_ID_HEX_LENGTH]u8
	name := fmt.tprintf("%s.lock", session_id_to_hex(session, hex[:]))
	path, path_err := filepath.join({lock_directory, name}, context.temp_allocator)
	if path_err != nil { return path_err }

	file, file_err := os.open(path, {.Read, .Write, .Create}, PRIVATE_FILE_PERMISSIONS)
	if file_err != nil { return file_err }
	held_elsewhere, lock_err := claim_lock_take(file)
	if lock_err != nil || held_elsewhere {
		_ = os.close(file)
		if held_elsewhere { return Journal_Error.Claimed }
		return lock_err
	}

	j.claimed = session
	j.claim_file = file
	return nil
}

// session_exists reports whether the journal holds a row for s.
@(private)
session_exists :: proc(j: ^Journal, s: Session_Id) -> (bool, Error) {
	session := s
	rows: db.Rows
	if err := db.query(&j.conn, &rows, "SELECT 1 FROM sessions WHERE session = ?", {db.Value(session[:])}); err != nil {
		return false, err
	}
	defer db.rows_close(&rows)
	_, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return false, next_err }
	return has_row, nil
}

// load_counters reads the highest ids one session has used.
@(private)
load_counters :: proc(j: ^Journal, s: Session_Id) -> (Counters, Error) {
	session := s
	query := `SELECT
		COALESCE((SELECT MAX(turn) FROM records WHERE session = ?), 0),
		COALESCE((SELECT MAX(request) FROM records WHERE session = ?), 0),
		COALESCE((SELECT MAX(call) FROM records WHERE session = ?), 0),
		COALESCE((SELECT MAX(node) FROM nodes WHERE session = ?), 0),
		COALESCE((SELECT MAX(branch) FROM branches WHERE session = ?), 0)`
	args: [5]db.Value
	for i in 0 ..< len(args) {
		args[i] = db.Value(session[:])
	}

	rows: db.Rows
	if err := db.query(&j.conn, &rows, query, args[:]); err != nil { return {}, err }
	defer db.rows_close(&rows)
	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return {}, next_err }
	if !has_row { return {}, Journal_Error.Corrupt }

	turn, turn_err := db.as_i64(values[0])
	if turn_err != nil { return {}, turn_err }
	request, request_err := db.as_i64(values[1])
	if request_err != nil { return {}, request_err }
	call, call_err := db.as_i64(values[2])
	if call_err != nil { return {}, call_err }
	node, node_err := db.as_i64(values[3])
	if node_err != nil { return {}, node_err }
	branch, branch_err := db.as_i64(values[4])
	if branch_err != nil { return {}, branch_err }

	return Counters{turn = Turn_Id(turn), request = Request_Id(request), call = Call_Id(call), node = Node_Id(node), branch = Branch_Id(branch)}, nil
}

// --- filesystem -------------------------------------------------------------

// ensure_private_directory creates path when it is missing and restricts an
// existing directory to its owner. The journal owns this directory, so a
// directory other users can read is tightened rather than refused.
@(private)
ensure_private_directory :: proc(path: string) -> Error {
	if info, stat_err := os.lstat(path, context.temp_allocator); stat_err == nil {
		if info.type != .Directory { return Journal_Error.Invalid_State }
		if permissions_are_private(info.mode) { return nil }
		if chmod_err := os.chmod(path, PRIVATE_DIRECTORY_PERMISSIONS); chmod_err != nil { return chmod_err }
		return nil
	}
	make_err := os.make_directory_all(path, PRIVATE_DIRECTORY_PERMISSIONS)
	if make_err != nil && make_err != .Exist { return make_err }
	return nil
}

// ensure_private_file creates path when it is missing and restricts an existing
// file to its owner. Creating the database before SQLite does is what gives it
// owner-only permissions, and SQLite gives the write-ahead log the database
// file's permissions.
@(private)
ensure_private_file :: proc(path: string) -> Error {
	if info, stat_err := os.lstat(path, context.temp_allocator); stat_err == nil {
		return restrict_private_file(path, info)
	}
	file, open_err := os.open(path, {.Read, .Write, .Create, .Excl}, PRIVATE_FILE_PERMISSIONS)
	if open_err == nil {
		_ = os.close(file)
		return nil
	}
	if open_err == .Exist {
		// Another process created it between the two calls; check what landed.
		info, stat_err := os.lstat(path, context.temp_allocator)
		if stat_err != nil { return stat_err }
		return restrict_private_file(path, info)
	}
	return open_err
}

@(private)
restrict_private_file :: proc(path: string, info: os.File_Info) -> Error {
	if info.type != .Regular { return Journal_Error.Invalid_State }
	if permissions_are_private(info.mode) { return nil }
	if chmod_err := os.chmod(path, PRIVATE_FILE_PERMISSIONS); chmod_err != nil { return chmod_err }
	return nil
}

// ensure_readable_directory checks that path is the directory a writer left
// behind. A reader has no business creating a journal or loosening what it
// found, so a missing directory, a symlink, or a directory other users can read
// is refused rather than fixed.
@(private)
ensure_readable_directory :: proc(path: string) -> Error {
	info, stat_err := os.lstat(path, context.temp_allocator)
	if stat_err != nil { return Journal_Error.Not_Found }
	if info.type != .Directory { return Journal_Error.Invalid_State }
	if !permissions_are_private(info.mode) { return Journal_Error.Invalid_State }
	return nil
}

// ensure_readable_file checks that path is the database a writer left behind. A
// missing file is .Not_Found rather than a file this call would create.
@(private)
ensure_readable_file :: proc(path: string) -> Error {
	info, stat_err := os.lstat(path, context.temp_allocator)
	if stat_err != nil { return Journal_Error.Not_Found }
	if info.type != .Regular { return Journal_Error.Invalid_State }
	if !permissions_are_private(info.mode) { return Journal_Error.Invalid_State }
	return nil
}

@(private)
permissions_are_private :: proc(mode: os.Permissions) -> bool {
	return card(mode & OTHER_ACCESS) == 0
}
