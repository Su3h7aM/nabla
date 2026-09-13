package session

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"

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
	lock_fd:   linux.Fd,
	lock_open: bool,
	session:   Session_Id, // owned; the session claimed for writing
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

	if err := db.exec(&store.conn, "PRAGMA journal_mode = WAL"); err != nil {
		return storage_error("set the journal mode", err)
	}
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
	if release_err != nil { return release_err }
	if close_err != nil { return storage_error("close the session database", close_err) }
	return nil
}

// session_create inserts a new session and returns its header. The session is
// not claimed for writing; call session_claim before recording anything in it.
//
// The returned Session owns its strings under allocator.
session_create :: proc(store: ^Store, options: Create_Options, at_ms: i64, allocator := context.allocator) -> (session: Session, err: Error) {
	if !store.open { return {}, error_make(.Invalid_State, "the store is closed") }
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

	created := false
	defer if !created { session_destroy(&session, allocator) }

	if err := db.exec(&store.conn, "BEGIN IMMEDIATE"); err != nil {
		return {}, storage_error("begin session creation", err)
	}
	committed := false
	defer if !committed { db.rollback(&store.conn) }

	insert_args := [?]db.Value {
		db.Value(string(session.id)),
		db.Value(session.created_at_ms),
		db.Value(session.updated_at_ms),
		db.Value(session.workspace),
		db.Value(session.title),
		db.Value(session.provider),
		db.Value(session.model),
		db.Value(nil),
	}
	if err := db.exec(&store.conn, SESSION_INSERT, insert_args[:]); err != nil {
		return {}, storage_error("create session", err)
	}
	if err := db.commit(&store.conn); err != nil {
		return {}, storage_error("commit session creation", err)
	}
	committed = true
	created = true
	return session, nil
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
// same session is refused with .Busy.
session_claim :: proc(store: ^Store, id: Session_Id) -> Error {
	if !store.open { return error_make(.Invalid_State, "the store is closed") }
	if store.lock_open { return error_make(.Invalid_State, "another session is already claimed for writing") }
	if !session_id_valid(id) { return error_make(.Invalid_Argument, "the session id is not a valid id") }

	// Verify the session exists before taking the claim, so a stale id does not
	// leave a lock file behind for a session that is gone.
	session, load_err := session_load(store, id, context.temp_allocator)
	if load_err != nil { return load_err }
	session_destroy(&session, context.temp_allocator)

	if store.lock_open { return error_make(.Invalid_State, "another session is already claimed for writing") }

	lock_directory, join_err := filepath.join({store.directory, LOCK_DIRECTORY}, context.temp_allocator)
	if join_err != nil { return error_make(.Storage, "the lock directory path could not be built") }
	ensure_private_directory(lock_directory) or_return

	lock_path, path_err := filepath.join({lock_directory, fmt.tprintf("%s.lock", string(id))}, context.temp_allocator)
	if path_err != nil { return error_make(.Storage, "the lock path could not be built") }
	lock_cstring, convert_err := strings.clone_to_cstring(lock_path, context.temp_allocator)
	if convert_err != nil { return error_make(.Storage, "the lock path could not be converted") }

	fd, open_errno := linux.open(lock_cstring, {.RDWR, .CREAT, .CLOEXEC}, LOCK_FILE_MODE)
	if open_errno != .NONE {
		return error_make(.Storage, fmt.tprintf("the session lock could not be opened: %v", open_errno))
	}
	if lock_errno := linux.flock(fd, {.EX, .NB}); lock_errno != .NONE {
		linux.close(fd)
		if lock_errno == .EAGAIN || lock_errno == .EACCES {
			return error_make(.Busy, "another process is running that session")
		}
		return error_make(.Storage, fmt.tprintf("the session lock could not be taken: %v", lock_errno))
	}

	store.session = Session_Id(strings.clone(string(id), store.allocator))
	if store.session == "" {
		linux.flock(fd, {.UN})
		linux.close(fd)
		return error_make(.Storage, "the claimed session id could not be recorded")
	}
	store.lock_fd = fd
	store.lock_open = true
	return nil
}

// session_release drops the writer claim. Releasing when nothing is claimed
// does nothing.
session_release :: proc(store: ^Store) -> Error {
	if !store.lock_open { return nil }
	unlock_errno := linux.flock(store.lock_fd, {.UN})
	close_errno := linux.close(store.lock_fd)
	store.lock_fd = 0
	store.lock_open = false
	delete(string(store.session), store.allocator)
	store.session = ""
	if unlock_errno != .NONE && unlock_errno != .EINVAL {
		return error_make(.Storage, fmt.tprintf("the session lock could not be released: %v", unlock_errno))
	}
	if close_errno != .NONE {
		return error_make(.Storage, fmt.tprintf("the session lock could not be closed: %v", close_errno))
	}
	return nil
}

// session_claimed reports which session the store holds for writing.
session_claimed :: proc(store: ^Store) -> (Session_Id, bool) {
	if !store.lock_open { return "", false }
	return store.session, true
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
	args := [?]db.Value{db.Value(at_ms), db.Value(string(id))}
	if err := db.exec(&store.conn, "UPDATE sessions SET updated_at_ms = ? WHERE id = ?", args[:]); err != nil {
		return storage_error("record session activity", err)
	}
	return nil
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
	defer if !committed { db.rollback(&store.conn) }
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

@(private)
SESSION_COLUMNS :: `id, created_at_ms, updated_at_ms, workspace, title, provider, model, archived_at_ms`

@(private)
SESSION_SELECT_ONE :: `SELECT ` + SESSION_COLUMNS + ` FROM sessions WHERE id = ?`

@(private)
SESSION_SELECT_LIST :: `SELECT ` + SESSION_COLUMNS + ` FROM sessions WHERE 1 = 1`

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

@(private)
require_claim :: proc(store: ^Store, id: Session_Id) -> Error {
	if !store.open { return error_make(.Invalid_State, "the store is closed") }
	if !store.lock_open { return error_make(.Invalid_State, "no session is claimed for writing") }
	if store.session != id { return error_make(.Invalid_State, "a different session is claimed for writing") }
	return nil
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
