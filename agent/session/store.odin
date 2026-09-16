package session

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:time"

import "nabla:db"
import "nabla:db/sqlite"

// DATABASE_NAME is the one file SQLite owns inside the session directory.
DATABASE_NAME :: "sessions.db"

// LOCK_DIRECTORY holds one lock file per session that is claimed for writing.
// The files are never deleted: replacing a locked inode would let two processes
// end up holding what they each believe is the same claim.
LOCK_DIRECTORY :: "locks"

// BUSY_TIMEOUT_MS is how long a write waits for another process to release the
// database lock before it fails. Writes are short, so a short wait is enough.
BUSY_TIMEOUT_MS :: 5_000

// JOURNAL_MODE_ATTEMPTS and JOURNAL_MODE_RETRY bound the retry of the one-time
// switch to write-ahead logging. The switch takes exclusive access to the file,
// and SQLite refuses it outright rather than waiting on the connection's busy
// handler, so a second harness opening the same empty directory at the same
// moment is a refusal rather than a wait. The switch is idempotent, so retrying
// it is safe, and the bound matches how long a busy write would have waited.
JOURNAL_MODE_ATTEMPTS :: 50
JOURNAL_MODE_RETRY :: 100 * time.Millisecond

// PRIVATE_DIRECTORY_PERMISSIONS and PRIVATE_FILE_PERMISSIONS admit the owner
// alone. Session history holds prompts, tool output, and file contents, so
// nothing else on the machine has any business reading it.
PRIVATE_DIRECTORY_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}
PRIVATE_FILE_PERMISSIONS :: os.Permissions{.Read_User, .Write_User}
LOCK_FILE_MODE :: linux.Mode{.IRUSR, .IWUSR}

@(private)
OTHER_ACCESS :: os.Permissions{.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other}

// Store is one open session database and, at most, one session claimed for
// writing. Its zero value is a closed store.
//
// A store is not safe for concurrent use: it owns one SQLite connection, and
// one caller drives it from one thread. The claim is separate from the
// connection and exists to stop a second process from running the same session.
Store :: struct {
	conn:      db.Conn,
	allocator: mem.Allocator,
	directory: string, // owned
	open:      bool,
	// read_only records how the connection was opened. A reader takes no
	// claim and refuses every mutation, so store_open_read_only cannot be
	// used to change a database by accident.
	read_only: bool,
	claim:     Claim, // the session claimed for writing, if any
	// broken records a transaction that could not be discarded. SQLite does not
	// promise that a failed ROLLBACK has ended the transaction, so the
	// connection's transaction state is unknown from then on: every mutation
	// refuses rather than reporting a confusing "a transaction is already open"
	// from the next statement. Reads are unaffected.
	broken:    bool,
}

// Claim is one held writer claim: the advisory lock and the session it names.
// The claim owns its session id.
//
// A claim is a value rather than something the store hides, because a session
// switch briefly needs two of them: the running session stays locked while the
// candidate is taken, so a refused switch cannot leave the running session
// unclaimed. Nothing else holds one, and nothing but a switch holds two.
Claim :: struct {
	allocator: mem.Allocator,
	fd:        linux.Fd,
	held:      bool,
	session:   Session_Id, // owned
}

// claim_acquire takes the writer claim for id. It consults no store and does not
// disturb a claim the caller already holds, which is what lets a switch take the
// candidate while the running session is still claimed. A second process holding
// the same session is refused with .Claimed.
//
// The claim is returned held and owns its session id under allocator; release it
// with claim_release.
claim_acquire :: proc(directory: string, id: Session_Id, allocator: mem.Allocator) -> (claim: Claim, err: Error) {
	if !session_id_valid(id) { return {}, error_make(.Invalid_Argument, "the session id is not a valid id") }

	lock_directory, join_err := filepath.join({directory, LOCK_DIRECTORY}, context.temp_allocator)
	if join_err != nil { return {}, error_make(.Storage, "the lock directory path could not be built") }
	ensure_private_directory(lock_directory) or_return

	lock_path, path_err := filepath.join({lock_directory, fmt.tprintf("%s.lock", string(id))}, context.temp_allocator)
	if path_err != nil { return {}, error_make(.Storage, "the lock path could not be built") }
	lock_cstring, convert_err := strings.clone_to_cstring(lock_path, context.temp_allocator)
	if convert_err != nil { return {}, error_make(.Storage, "the lock path could not be converted") }

	fd, open_errno := linux.open(lock_cstring, {.RDWR, .CREAT, .CLOEXEC}, LOCK_FILE_MODE)
	if open_errno != .NONE {
		return {}, error_make(.Storage, fmt.tprintf("the session lock could not be opened: %v", open_errno))
	}
	if lock_errno := linux.flock(fd, {.EX, .NB}); lock_errno != .NONE {
		linux.close(fd)
		if lock_errno == .EAGAIN || lock_errno == .EACCES {
			return {}, error_make(.Claimed, "another process is running that session")
		}
		return {}, error_make(.Storage, fmt.tprintf("the session lock could not be taken: %v", lock_errno))
	}

	claim = Claim {
		allocator = allocator,
		fd        = fd,
		held      = true,
	}
	claim.session = Session_Id(strings.clone(string(id), allocator))
	if claim.session == "" {
		_ = claim_release(&claim)
		return {}, error_make(.Storage, "the claimed session id could not be recorded")
	}
	return claim, nil
}

// claim_release drops the writer claim and frees the id it owned. Releasing a
// claim that is not held does nothing, so a zero Claim is safe to release.
claim_release :: proc(claim: ^Claim) -> Error {
	if !claim.held { return nil }
	allocator := claim.allocator
	unlock_errno := linux.flock(claim.fd, {.UN})
	close_errno := linux.close(claim.fd)
	delete(string(claim.session), allocator)
	claim^ = {}
	if unlock_errno != .NONE && unlock_errno != .EINVAL {
		return error_make(.Storage, fmt.tprintf("the session lock could not be released: %v", unlock_errno))
	}
	if close_errno != .NONE {
		return error_make(.Storage, fmt.tprintf("the session lock could not be closed: %v", close_errno))
	}
	return nil
}

// set_journal_mode turns on write-ahead logging and checks that the database
// accepted it. SQLite answers a journal-mode pragma with the mode it ended up in
// and quietly keeps another mode on a filesystem that cannot support WAL, so the
// answer is the only evidence for what this store assumes: readers do not block
// the writer, and a checkpoint does not block readers. Running in `delete` mode
// instead would silently turn every read into a writer-blocking one.
@(private)
set_journal_mode :: proc(store: ^Store) -> Error {
	last: Error
	for attempt in 0 ..< JOURNAL_MODE_ATTEMPTS {
		ready, err := journal_mode_attempt(store)
		if err != nil {
			// Only contention is worth retrying; a refused or damaged database is
			// the callers' to hear about now.
			if error_kind(err) != .Contended { return err }
			last = err
		} else if ready {
			return nil
		}
		if attempt + 1 < JOURNAL_MODE_ATTEMPTS { time.sleep(JOURNAL_MODE_RETRY) }
	}
	if last != nil { return last }
	return error_make(.Storage, "the database did not accept write-ahead logging")
}

// journal_mode_attempt asks for write-ahead logging once and reports whether the
// database is now in it. A pragma that answered with another mode is not an
// error: it is a switch that has not happened yet, because another connection
// held the file.
@(private)
journal_mode_attempt :: proc(store: ^Store) -> (ready: bool, err: Error) {
	rows: db.Rows
	if query_err := db.query(&store.conn, &rows, "PRAGMA journal_mode = WAL"); query_err != nil {
		return false, storage_error("set the journal mode", query_err)
	}
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return false, storage_error("set the journal mode", next_err) }
	if !has_row { return false, error_make(.Storage, "the journal mode was not reported") }
	mode, convert_err := db.as_string(values[0])
	if convert_err != nil { return false, corrupt_error("read the journal mode", convert_err) }
	return strings.equal_fold(mode, "wal"), nil
}

// store_open opens the session database in directory, creating the directory
// and the database when they are missing, and brings the schema up to date.
//
// The store owns the connection and the directory path; store_close releases
// both. A refused open leaves nothing behind.
store_open :: proc(store: ^Store, directory: string, allocator := context.allocator) -> (err: Error) {
	if store.open { return error_make(.Invalid_State, "the store is already open") }
	if directory == "" { return error_make(.Invalid_Argument, "the session directory is empty") }

	store.allocator = allocator
	store.directory = strings.clone(directory, allocator)
	store.broken = false
	if store.directory == "" { return error_make(.Storage, "the session directory could not be recorded") }

	succeeded := false
	defer if !succeeded {
		session_release(store)
		db.close(&store.conn)
		delete(store.directory, allocator)
		store.directory = ""
		store.open = false
	}

	ensure_private_directory(store.directory) or_return

	database_path, join_err := filepath.join({store.directory, DATABASE_NAME}, context.temp_allocator)
	if join_err != nil { return error_make(.Storage, "the database path could not be built") }
	ensure_private_file(database_path) or_return

	config := sqlite.Config {
		path            = database_path,
		busy_timeout_ms = BUSY_TIMEOUT_MS,
		foreign_keys    = true,
	}
	if open_err := sqlite.open(&store.conn, config, allocator); open_err != nil {
		return storage_error("open the session database", open_err)
	}

	set_journal_mode(store) or_return
	// FULL is deliberate: a record of intent is what lets an interrupted
	// session be read honestly, and a write volume of a few rows per turn does
	// not make the extra flush matter.
	if err := db.exec(&store.conn, "PRAGMA synchronous = FULL"); err != nil {
		return storage_error("set the synchronous mode", err)
	}

	schema_migrate(store) or_return

	store.open = true
	succeeded = true
	return nil
}

// store_close releases the writer claim, the connection, and the directory
// path. Closing a closed store does nothing.
store_close :: proc(store: ^Store) -> Error {
	if !store.open && store.directory == "" { return nil }
	release_err := session_release(store)
	close_err := db.close(&store.conn)
	delete(store.directory, store.allocator)
	store.directory = ""
	store.open = false
	store.read_only = false
	if release_err != nil { return release_err }
	if close_err != nil { return storage_error("close the session database", close_err) }
	return nil
}

// store_open_read_only opens the session database in directory for reading.
//
// It creates nothing and migrates nothing. The directory, the database file,
// and their permissions have to be exactly what a writer left behind, and the
// schema has to be the version this build reads. A reader takes no writer claim
// and refuses every mutation, so a diagnostics command can read a session whose
// harness is running, and can never change the database it was pointed at.
//
// store_close releases it, exactly as it releases a writable store.
store_open_read_only :: proc(store: ^Store, directory: string, allocator := context.allocator) -> (err: Error) {
	if store.open { return error_make(.Invalid_State, "the store is already open") }
	if directory == "" { return error_make(.Invalid_Argument, "the session directory is empty") }

	store.allocator = allocator
	store.directory = strings.clone(directory, allocator)
	store.broken = false
	store.read_only = true
	if store.directory == "" {
		store.read_only = false
		return error_make(.Storage, "the session directory could not be recorded")
	}

	succeeded := false
	defer if !succeeded {
		db.close(&store.conn)
		delete(store.directory, allocator)
		store.directory = ""
		store.open = false
		store.read_only = false
	}

	ensure_readable_directory(store.directory) or_return

	database_path, join_err := filepath.join({store.directory, DATABASE_NAME}, context.temp_allocator)
	if join_err != nil { return error_make(.Storage, "the database path could not be built") }
	ensure_readable_file(database_path) or_return

	// No journal-mode pragma and no migration: both write, and neither is a
	// reader's to decide. A database in another journal mode is still readable.
	config := sqlite.Config {
		path            = database_path,
		busy_timeout_ms = BUSY_TIMEOUT_MS,
		foreign_keys    = true,
		mode            = .Read_Only,
	}
	if open_err := sqlite.open(&store.conn, config, allocator); open_err != nil {
		return storage_error("open the session database for reading", open_err)
	}

	// The exact version is required rather than merely tolerated: every read
	// procedure names columns, so an older database does not have them and a
	// newer one may have changed them. A writer migrates; a reader only reads.
	version, version_err := schema_read_version(store)
	if version_err != nil { return version_err }
	if version != SCHEMA_VERSION {
		if version > SCHEMA_VERSION {
			return error_make(.Schema_Too_New, fmt.tprintf("the database is at schema %d; this build reads %d", version, SCHEMA_VERSION))
		}
		return error_make(
			.Schema_Unknown,
			fmt.tprintf("the database is at schema %d; reading requires %d, so run the harness once to migrate it", version, SCHEMA_VERSION),
		)
	}

	store.open = true
	succeeded = true
	return nil
}

// session_create records a new session and returns its header. The session is
// not claimed for writing; call session_claim before recording anything in it.
//
// The returned Session owns its strings under allocator.
session_create :: proc(store: ^Store, options: Create_Options, at_ms: i64, allocator := context.allocator) -> (session: Session, err: Error) {
	require_writable(store) or_return
	if options.workspace == "" { return {}, error_make(.Invalid_Argument, "the workspace is empty") }
	if at_ms <= 0 { return {}, error_make(.Invalid_Argument, "the creation time is not a timestamp") }

	session = Session {
		id            = session_id_create(allocator),
		created_at_ms = at_ms,
		updated_at_ms = at_ms,
		workspace     = strings.clone(options.workspace, allocator),
		title         = strings.clone(options.title, allocator),
		provider      = strings.clone(options.provider, allocator),
		model         = strings.clone(options.model, allocator),
	}
	if session.id == "" { return {}, error_make(.Storage, "a session id could not be created") }
	if record_err := session_record(store, session); record_err != nil {
		session_destroy(&session, allocator)
		return {}, record_err
	}
	return session, nil
}

// session_record writes a session header that has no row yet, and leaves a
// session that already has one exactly as it is.
//
// A launch holds a new session in memory and records nothing, so the first
// prompt is what gives the session a row: a launch opened and closed without one
// leaves nothing behind, and there is nothing for a later resume to find. Every
// turn, request, and entry is a foreign key into that row, so recording it is
// also what makes the session a candidate for a resume.
session_record :: proc(store: ^Store, session: Session) -> Error {
	require_writable(store) or_return
	if !session_id_valid(session.id) { return error_make(.Invalid_Argument, "the session id is not a valid id") }
	if session.workspace == "" { return error_make(.Invalid_Argument, "a session needs a workspace") }
	if session.created_at_ms <= 0 { return error_make(.Invalid_Argument, "a session needs a creation time") }
	if session.updated_at_ms < session.created_at_ms {
		return error_make(.Invalid_Argument, "a session cannot record activity before it was created")
	}

	args := [?]db.Value {
		db.Value(string(session.id)),
		db.Value(session.created_at_ms),
		db.Value(session.updated_at_ms),
		db.Value(session.workspace),
		db.Value(session.title),
		db.Value(session.provider),
		db.Value(session.model),
		db.Value(nil),
	}
	if err := db.exec(&store.conn, SESSION_INSERT_IF_ABSENT, args[:]); err != nil {
		return storage_error("record the session", err)
	}
	return nil
}

// session_load reads one session header. The result owns its strings under
// allocator.
session_load :: proc(store: ^Store, id: Session_Id, allocator := context.allocator) -> (Session, Error) {
	if !store.open { return {}, error_make(.Invalid_State, "the store is closed") }

	rows: db.Rows
	if err := db.query(&store.conn, &rows, SESSION_SELECT_ONE, {db.Value(string(id))}); err != nil {
		return {}, storage_error("load session", err)
	}
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return {}, storage_error("load session", next_err) }
	if !has_row { return {}, error_make(.Not_Found, "no session has that id") }
	return session_scan(values, allocator)
}

// session_list returns sessions newest activity first. The result is owned by
// the caller; release it with sessions_destroy.
session_list :: proc(store: ^Store, options: List_Options, allocator := context.allocator) -> ([]Session, Error) {
	if !store.open { return nil, error_make(.Invalid_State, "the store is closed") }

	limit := options.limit
	if limit <= 0 { limit = SESSION_LIST_DEFAULT_LIMIT }
	if limit > SESSION_LIST_MAX_LIMIT { limit = SESSION_LIST_MAX_LIMIT }

	// The filter is assembled rather than parameterized with flags, because a
	// flag turns an index-usable predicate into one the planner cannot use.
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, SESSION_SELECT_LIST)
	args := make([dynamic]db.Value, 0, 6, context.temp_allocator)

	if !options.include_archived {
		strings.write_string(&builder, " AND archived_at_ms IS NULL")
	}
	if options.workspace != "" {
		strings.write_string(&builder, " AND workspace = ?")
		append(&args, db.Value(options.workspace))
	}
	if options.used_only {
		strings.write_string(&builder, SESSION_USED_ONLY)
	}
	if cursor, has_cursor := options.after.?; has_cursor {
		strings.write_string(&builder, " AND (updated_at_ms < ? OR (updated_at_ms = ? AND id < ?))")
		append(&args, db.Value(cursor.updated_at_ms))
		append(&args, db.Value(cursor.updated_at_ms))
		append(&args, db.Value(string(cursor.id)))
	}
	strings.write_string(&builder, " ORDER BY updated_at_ms DESC, id DESC LIMIT ?")
	append(&args, db.Value(i64(limit)))

	rows: db.Rows
	if err := db.query(&store.conn, &rows, strings.to_string(builder), args[:]); err != nil {
		return nil, storage_error("list sessions", err)
	}
	defer db.rows_close(&rows)

	sessions := make([dynamic]Session, 0, limit, allocator)
	complete := false
	defer if !complete { sessions_destroy(sessions[:], allocator) }

	for {
		values, has_row, next_err := db.rows_next(&rows)
		if next_err != nil { return nil, storage_error("list sessions", next_err) }
		if !has_row { break }
		session, scan_err := session_scan(values, allocator)
		if scan_err != nil { return nil, scan_err }
		append(&sessions, session)
	}
	complete = true
	return sessions[:], nil
}

// session_claim takes the writer claim for a session so the harness can run it.
// Only one session may be claimed at a time, and a second process claiming the
// same session is refused with .Claimed.
//
// Taking a claim creates a lock file, so a read-only store is refused before
// anything on disk is touched.
session_claim :: proc(store: ^Store, id: Session_Id) -> Error {
	require_writable(store) or_return
	if store.claim.held { return error_make(.Invalid_State, "another session is already claimed for writing") }
	if !session_id_valid(id) { return error_make(.Invalid_Argument, "the session id is not a valid id") }

	// Verify the session exists before taking the claim, so a stale id does not
	// leave a lock file behind for a session that is gone.
	session, load_err := session_load(store, id, context.temp_allocator)
	if load_err != nil { return load_err }
	session_destroy(&session, context.temp_allocator)

	claim, claim_err := claim_acquire(store.directory, id, store.allocator)
	if claim_err != nil { return claim_err }
	store.claim = claim
	return nil
}

// session_claim_candidate takes the claim for id in place of the one the store
// holds, returning the claim it displaced. The displaced claim stays held, so
// the running session remains locked while the candidate is settled.
//
// A switch is finished by releasing the displaced claim, or abandoned with
// session_claim_restore, which releases the candidate and puts the displaced
// claim back. A refusal leaves the store holding exactly the claim it held
// before.
session_claim_candidate :: proc(store: ^Store, id: Session_Id) -> (displaced: Claim, err: Error) {
	require_writable(store) or_return
	displaced = store.claim
	store.claim = {}
	candidate, claim_err := claim_acquire(store.directory, id, store.allocator)
	if claim_err != nil {
		store.claim = displaced
		return {}, claim_err
	}
	store.claim = candidate
	return displaced, nil
}

// session_claim_restore abandons a switch: the candidate is released and the
// displaced claim becomes the store's again. The store is left holding the claim
// it held before the switch started, even when releasing the candidate fails.
session_claim_restore :: proc(store: ^Store, displaced: Claim) -> Error {
	err := claim_release(&store.claim)
	store.claim = displaced
	return err
}

// session_release drops the writer claim. Releasing when nothing is claimed
// does nothing.
session_release :: proc(store: ^Store) -> Error {
	return claim_release(&store.claim)
}

// session_claimed reports which session the store holds for writing.
session_claimed :: proc(store: ^Store) -> (Session_Id, bool) {
	if !store.claim.held { return "", false }
	return store.claim.session, true
}

// session_set_title names a claimed session.
session_set_title :: proc(store: ^Store, id: Session_Id, title: string) -> Error {
	require_claim(store, id) or_return
	args := [?]db.Value{db.Value(title), db.Value(string(id))}
	if err := db.exec(&store.conn, "UPDATE sessions SET title = ? WHERE id = ?", args[:]); err != nil {
		return storage_error("name session", err)
	}
	return nil
}

// session_set_title_if_untitled names a claimed session when it has no title
// yet. It never overwrites a title, so the first prompt names a session and a
// later one leaves it alone.
session_set_title_if_untitled :: proc(store: ^Store, id: Session_Id, title: string) -> Error {
	require_claim(store, id) or_return
	if title == "" { return nil }
	args := [?]db.Value{db.Value(title), db.Value(string(id))}
	if err := db.exec(&store.conn, "UPDATE sessions SET title = ? WHERE id = ? AND title = ''", args[:]); err != nil {
		return storage_error("name session", err)
	}
	return nil
}

// session_set_model records the provider and model a later turn should start
// from. It is the session's default, not evidence about any earlier request:
// each request keeps its own record of what it actually used.
session_set_model :: proc(store: ^Store, id: Session_Id, provider, model: string) -> Error {
	require_claim(store, id) or_return
	args := [?]db.Value{db.Value(provider), db.Value(model), db.Value(string(id))}
	if err := db.exec(&store.conn, "UPDATE sessions SET provider = ?, model = ? WHERE id = ?", args[:]); err != nil {
		return storage_error("record session model", err)
	}
	return nil
}

// session_touch records activity, which is what orders the session listing.
// Archiving does not touch a session: hiding it is not conversation activity.
session_touch :: proc(store: ^Store, id: Session_Id, at_ms: i64) -> Error {
	require_claim(store, id) or_return
	return touch_session(store, id, at_ms)
}

// session_archive hides a claimed session from ordinary listings while keeping
// every byte of it. It is reversible with session_unarchive.
session_archive :: proc(store: ^Store, id: Session_Id, at_ms: i64) -> Error {
	require_claim(store, id) or_return
	args := [?]db.Value{db.Value(at_ms), db.Value(string(id))}
	if err := db.exec(&store.conn, "UPDATE sessions SET archived_at_ms = ? WHERE id = ?", args[:]); err != nil {
		return storage_error("archive session", err)
	}
	return nil
}

// session_unarchive returns a claimed session to ordinary listings.
session_unarchive :: proc(store: ^Store, id: Session_Id) -> Error {
	require_claim(store, id) or_return
	if err := db.exec(&store.conn, "UPDATE sessions SET archived_at_ms = NULL WHERE id = ?", {db.Value(string(id))}); err != nil {
		return storage_error("unarchive session", err)
	}
	return nil
}

// session_delete removes a claimed session and everything hanging off it, then
// releases the claim. Deletion is not secure erasure: SQLite free pages, the
// write-ahead log, and the storage device can all keep copies.
session_delete :: proc(store: ^Store, id: Session_Id) -> Error {
	require_claim(store, id) or_return

	if err := db.exec(&store.conn, "BEGIN IMMEDIATE"); err != nil {
		return storage_error("begin session deletion", err)
	}
	committed := false
	defer if !committed { abandon_transaction(store) }
	if err := db.exec(&store.conn, "DELETE FROM sessions WHERE id = ?", {db.Value(string(id))}); err != nil {
		return storage_error("delete session", err)
	}
	if err := db.commit(&store.conn); err != nil {
		return storage_error("commit session deletion", err)
	}
	committed = true

	// The claim pointed at a row that no longer exists.
	return session_release(store)
}

// --- rows -------------------------------------------------------------------

@(private)
SESSION_INSERT :: `INSERT INTO sessions (id, created_at_ms, updated_at_ms, workspace, title, provider, model, archived_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`

// A session that already has a row keeps it: the header a later write brings
// describes the same session rather than a new one.
@(private)
SESSION_INSERT_IF_ABSENT :: SESSION_INSERT + ` ON CONFLICT (id) DO NOTHING`

@(private)
SESSION_COLUMNS :: `id, created_at_ms, updated_at_ms, workspace, title, provider, model, archived_at_ms`

@(private)
SESSION_SELECT_ONE :: `SELECT ` + SESSION_COLUMNS + ` FROM sessions WHERE id = ?`

@(private)
SESSION_SELECT_LIST :: `SELECT ` + SESSION_COLUMNS + ` FROM sessions WHERE 1 = 1`

// SESSION_USED_ONLY keeps the sessions that hold work. A session's row is written
// by its first prompt, so a row with nothing under it is a prompt whose turn did
// not land; only what hangs off the row tells the two apart. Each subquery is a
// primary-key lookup.
@(private)
SESSION_USED_ONLY :: ` AND (EXISTS (SELECT 1 FROM turns WHERE turns.session_id = sessions.id) OR EXISTS (SELECT 1 FROM requests WHERE requests.session_id = sessions.id) OR EXISTS (SELECT 1 FROM entries WHERE entries.session_id = sessions.id))`

@(private)
session_scan :: proc(values: []db.Value, allocator: mem.Allocator) -> (session: Session, err: Error) {
	complete := false
	defer if !complete { session_destroy(&session, allocator) }

	id, id_err := db.as_string(values[0])
	if id_err != nil { return {}, corrupt_error("read session id", id_err) }
	created_at_ms, created_err := db.as_i64(values[1])
	if created_err != nil { return {}, corrupt_error("read session creation time", created_err) }
	updated_at_ms, updated_err := db.as_i64(values[2])
	if updated_err != nil { return {}, corrupt_error("read session activity time", updated_err) }
	workspace, workspace_err := db.as_string(values[3])
	if workspace_err != nil { return {}, corrupt_error("read session workspace", workspace_err) }
	title, title_err := db.as_string(values[4])
	if title_err != nil { return {}, corrupt_error("read session title", title_err) }
	provider, provider_err := db.as_string(values[5])
	if provider_err != nil { return {}, corrupt_error("read session provider", provider_err) }
	model, model_err := db.as_string(values[6])
	if model_err != nil { return {}, corrupt_error("read session model", model_err) }
	archived_at_ms, archived_err := read_optional_i64(values[7])
	if archived_err != nil { return {}, corrupt_error("read session archive time", archived_err) }

	session = Session {
		id             = Session_Id(strings.clone(id, allocator)),
		created_at_ms  = created_at_ms,
		updated_at_ms  = updated_at_ms,
		workspace      = strings.clone(workspace, allocator),
		title          = strings.clone(title, allocator),
		provider       = strings.clone(provider, allocator),
		model          = strings.clone(model, allocator),
		archived_at_ms = archived_at_ms,
	}
	complete = true
	return session, nil
}

// --- supporting -------------------------------------------------------------

// require_writable reports whether the store can run a statement whose outcome
// depends on its transaction state: it must be open, writable, and free of a
// failed transaction that was left undiscarded.
@(private)
require_writable :: proc(store: ^Store) -> Error {
	if !store.open { return error_make(.Invalid_State, "the store is closed") }
	if store.read_only { return error_make(.Invalid_State, "the store is open for reading only") }
	if store.broken { return error_make(.Invalid_State, "a failed write could not be rolled back, so this store cannot be written to again") }
	return nil
}

@(private)
require_claim :: proc(store: ^Store, id: Session_Id) -> Error {
	require_writable(store) or_return
	if !store.claim.held { return error_make(.Invalid_State, "no session is claimed for writing") }
	if store.claim.session != id { return error_make(.Invalid_State, "a different session is claimed for writing") }
	return nil
}

// abandon_transaction discards the transaction a failed operation left open. A
// rollback that itself fails leaves SQLite's transaction state unknown: the
// documentation points at get_autocommit to tell which course it took. The store
// is marked broken and refuses later mutations rather than writing into a
// transaction nothing will commit.
@(private)
abandon_transaction :: proc(store: ^Store) {
	if err := db.rollback(&store.conn); err != nil {
		store.broken = true
	}
}

@(private)
read_optional_i64 :: proc(value: db.Value) -> (Maybe(i64), db.Error) {
	if value == nil { return nil, nil }
	number, err := db.as_i64(value)
	if err != nil { return nil, err }
	return number, nil
}

@(private)
db_failure :: proc(kind: Error_Kind, what: string, err: db.Error) -> Error {
	local := err
	message := db.error_message(&local)
	if message == "" { return error_make(kind, what) }
	return error_make(kind, fmt.tprintf("%s: %s", what, message))
}

@(private)
storage_error :: proc(what: string, err: db.Error) -> Error {
	// A rejected row is the database telling the caller the write was not
	// allowed, and contention is another process telling the caller to try again.
	// Neither is a database that could not work, so all three keep their own kind
	// rather than being folded into .Storage.
	#partial switch db.error_kind(err) {
	case .Constraint:
		return db_failure(.Constraint, what, err)
	case .Busy:
		return db_failure(.Contended, what, err)
	case .Busy_Snapshot:
		return db_failure(.Stale_Snapshot, what, err)
	case:
	}
	return db_failure(.Storage, what, err)
}

@(private)
corrupt_error :: proc(what: string, err: db.Error) -> Error {
	return db_failure(.Corrupt, what, err)
}

@(private)
permissions_are_private :: proc(mode: os.Permissions) -> bool {
	return card(mode & OTHER_ACCESS) == 0
}

// ensure_private_directory creates path when it is missing and restricts an
// existing directory to its owner. The store owns this directory, so a
// directory other users can read is tightened rather than refused.
@(private)
ensure_private_directory :: proc(path: string) -> Error {
	if info, stat_err := os.lstat(path, context.temp_allocator); stat_err == nil {
		if info.type != .Directory {
			return error_make(.Invalid_Argument, fmt.tprintf("%s is not a directory", path))
		}
		if permissions_are_private(info.mode) { return nil }
		if chmod_err := os.chmod(path, PRIVATE_DIRECTORY_PERMISSIONS); chmod_err != nil {
			return error_make(.Storage, fmt.tprintf("%s could not be restricted to its owner: %v", path, chmod_err))
		}
		return nil
	}
	make_err := os.make_directory_all(path, PRIVATE_DIRECTORY_PERMISSIONS)
	if make_err != nil && make_err != .Exist {
		return error_make(.Storage, fmt.tprintf("%s could not be created: %v", path, make_err))
	}
	return nil
}

// ensure_private_file creates path when it is missing and restricts an existing
// file to its owner. Creating the database before SQLite does is what gives it
// owner-only permissions; SQLite gives the write-ahead log the database file's
// permissions.
@(private)
ensure_private_file :: proc(path: string) -> Error {
	if info, stat_err := os.lstat(path, context.temp_allocator); stat_err == nil {
		return restrict_private_file(path, info)
	}
	file, open_err := os.open(path, {.Read, .Write, .Create, .Excl}, PRIVATE_FILE_PERMISSIONS)
	if open_err == nil {
		os.close(file)
		return nil
	}
	if open_err == .Exist {
		// Another process created it between the two calls; check what landed.
		info, stat_err := os.lstat(path, context.temp_allocator)
		if stat_err != nil { return error_make(.Storage, fmt.tprintf("%s could not be examined", path)) }
		return restrict_private_file(path, info)
	}
	return error_make(.Storage, fmt.tprintf("%s could not be created: %v", path, open_err))
}

@(private)
restrict_private_file :: proc(path: string, info: os.File_Info) -> Error {
	if info.type != .Regular {
		return error_make(.Invalid_Argument, fmt.tprintf("%s is not a regular file", path))
	}
	if permissions_are_private(info.mode) { return nil }
	if chmod_err := os.chmod(path, PRIVATE_FILE_PERMISSIONS); chmod_err != nil {
		return error_make(.Storage, fmt.tprintf("%s could not be restricted to its owner: %v", path, chmod_err))
	}
	return nil
}

// ensure_readable_directory verifies that path is the directory a writer left
// behind. Unlike the writer's own check it repairs nothing: a reader has no
// business creating a store or loosening what it found, so a missing
// directory, a symlink, or a directory other users can read is refused rather
// than fixed.
@(private)
ensure_readable_directory :: proc(path: string) -> Error {
	info, stat_err := os.lstat(path, context.temp_allocator)
	if stat_err != nil {
		return error_make(.Not_Found, fmt.tprintf("%s could not be examined: %v", path, stat_err))
	}
	if info.type != .Directory {
		return error_make(.Invalid_Argument, fmt.tprintf("%s is not a directory", path))
	}
	if !permissions_are_private(info.mode) {
		return error_make(.Invalid_Argument, fmt.tprintf("%s is readable by other users", path))
	}
	return nil
}

// ensure_readable_file verifies that path is the database a writer left behind.
// A missing file is .Not_Found rather than a file this call would create.
@(private)
ensure_readable_file :: proc(path: string) -> Error {
	info, stat_err := os.lstat(path, context.temp_allocator)
	if stat_err != nil {
		return error_make(.Not_Found, fmt.tprintf("%s could not be examined: %v", path, stat_err))
	}
	if info.type != .Regular {
		return error_make(.Invalid_Argument, fmt.tprintf("%s is not a regular file", path))
	}
	if !permissions_are_private(info.mode) {
		return error_make(.Invalid_Argument, fmt.tprintf("%s is readable by other users", path))
	}
	return nil
}
