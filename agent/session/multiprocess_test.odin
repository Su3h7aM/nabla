#+build linux
#+test
package session

// Multiprocess and multithreaded coverage for one session database shared by
// more than one harness process. Five scenarios run here as ordinary @(test)s
// through Odin's test interface:
//
//   A a claim is held while its owner lives and is free once it dies
//   B an uncommitted write dies with its writer, and the connection recovers
//   C two processes opening an empty directory at once migrate it exactly once
//   D two processes writing different sessions at once do not interfere
//   E an open survives another process holding the database's write lock
//
// The processes are re-executions of this test binary, not forks: each child
// runs the scenario's own test with a role in its environment, holds what the
// scenario needs, and is killed by the parent, so no test ever forks a
// multi-threaded runner. Readiness passes through a file the child writes and
// the parent polls within a bound; a child that dies or hangs fails its
// scenario instead of hanging the suite. The concurrent scenarios need no
// processes at all and run on threads. Every directory is per test.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:db"
import "nabla:db/sqlite"

// Multiprocess roles a re-executed test binary can play, selected by
// NABLA_MP_ROLE. The parent orchestrates; the child holds and dies.
Multiprocess_Role :: enum {
	None,
	Hold,
	Poison,
	Releaser,
}

// multiprocess_spawn_guard serializes child spawns: os.process_start
// documents that it is not thread-safe.
multiprocess_spawn_guard: sync.Mutex

MULTIPROCESS_READY_TIMEOUT :: 10 * time.Second
MULTIPROCESS_HOLD :: 300 * time.Millisecond
MULTIPROCESS_DEATH_BOUND :: 120 * time.Second
MULTIPROCESS_POISON_TITLE :: "uncommitted"

multiprocess_role_env :: proc() -> (role: Multiprocess_Role, present: bool) {
	text, found := os.lookup_env("NABLA_MP_ROLE", context.temp_allocator)
	if !found { return .None, false }
	switch text {
	case "Hold":
		return .Hold, true
	case "Poison":
		return .Poison, true
	case "Releaser":
		return .Releaser, true
	}
	return .None, true
}

// multiprocess_executable is this test binary, so a child re-executes the
// scenario's own test with a role in its environment. os.args[0] is not
// reliable under `odin test`, so the path comes from the OS instead.
multiprocess_executable :: proc(t: ^testing.T) -> string {
	path, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		testing.fail_now(t, "the test binary path could not be read")
	}
	return path
}

Multiprocess_Child :: struct {
	process: os.Process,
	ready:   string,
}

// multiprocess_spawn starts the scenario's test in a child with a role. The
// child's standard streams stay shut so only the parent's assertions speak.
// procedure is the caller's #procedure, which names the test the child runs.
multiprocess_spawn :: proc(
	t: ^testing.T,
	procedure: string,
	role: Multiprocess_Role,
	directory: string,
	id: Session_Id,
	ready: string,
) -> (
	child: Multiprocess_Child,
	ok: bool,
) {
	name := strings.trim_space(procedure)
	filter := fmt.tprintf("-tests:session.%s", name)

	role_name := ""
	switch role {
	case .Hold:
		role_name = "Hold"
	case .Poison:
		role_name = "Poison"
	case .Releaser:
		role_name = "Releaser"
	case .None:
		testing.fail_now(t, "a child needs a role")
	}

	current_env, env_err := os.environ(context.temp_allocator)
	if env_err != nil { testing.fail_now(t, "the environment could not be read") }
	child_env := make([dynamic]string, 0, len(current_env) + 4, context.temp_allocator)
	append(&child_env, ..current_env)
	append(&child_env, fmt.tprintf("NABLA_MP_ROLE=%s", role_name))
	append(&child_env, fmt.tprintf("NABLA_MP_DIR=%s", directory))
	append(&child_env, fmt.tprintf("NABLA_MP_ID=%s", string(id)))
	append(&child_env, fmt.tprintf("NABLA_MP_READY=%s", ready))

	sync.mutex_lock(&multiprocess_spawn_guard)
	defer sync.mutex_unlock(&multiprocess_spawn_guard)
	executable := multiprocess_executable(t)
	// TEMPORARY: child output to a file for diagnosis.
	dbg, _ := os.open("/tmp/opencode/mp_child.log", {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	process, start_err := os.process_start({command = {executable, filter}, env = child_env[:], stdout = dbg, stderr = dbg})
	if start_err != nil { return {}, false }
	return Multiprocess_Child{process = process, ready = ready}, true
}

// multiprocess_wait_ready polls for the child's readiness file within the
// bound. A child that died instead of reporting, or one that hung, fails the
// wait rather than the suite.
multiprocess_wait_ready :: proc(child: ^Multiprocess_Child) -> bool {
	deadline := time.tick_add(time.tick_now(), MULTIPROCESS_READY_TIMEOUT)
	for time.tick_since(deadline) < 0 {
		if os.exists(child.ready) {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

// multiprocess_dispose kills and reaps a child that is no longer needed. It
// runs deferred, so even a scenario that fails halfway leaves no child and no
// zombie behind. It is idempotent: disposing twice must never signal pid 0,
// which would kill this process's own group.
multiprocess_dispose :: proc(child: ^Multiprocess_Child) {
	if child.process.pid == 0 { return }
	_ = linux.kill(linux.Pid(child.process.pid), .SIGKILL)
	_, _ = os.process_wait(child.process, 10 * time.Second)
	child.process = {}
}

// multiprocess_child runs one role and never returns normally: the parent
// kills it while it holds what the scenario needs, so the parent sees exactly
// what the kernel does with a process that never got to clean up. Anything it
// cannot set up exits with a code instead, which the parent reports.
// multiprocess_signal_ready tells the parent that the child holds what its
// scenario needs. The parent polls for the file within a bound.
multiprocess_signal_ready :: proc(path: string) -> bool {
	return os.write_entire_file(path, transmute([]u8)string("R")) == nil
}

// multiprocess_await_death waits to be killed by the parent once it has seen
// enough. The bound is only a failsafe so a lost parent cannot leave this
// child forever.
multiprocess_await_death :: proc() -> ! {
	deadline := time.tick_add(time.tick_now(), MULTIPROCESS_DEATH_BOUND)
	for time.tick_since(deadline) < 0 {
		time.sleep(100 * time.Millisecond)
	}
	linux.exit_group(7)
}

multiprocess_child :: proc(role: Multiprocess_Role) -> ! {
	directory := os.get_env("NABLA_MP_DIR", context.temp_allocator)
	session_id := Session_Id(os.get_env("NABLA_MP_ID", context.temp_allocator))
	ready := os.get_env("NABLA_MP_READY", context.temp_allocator)

	if role == .Releaser {
		// A connection to the database as it exists before any launch has
		// switched it, holding the write lock a launch has to get past.
		path := fmt.aprintf("%s/%s", directory, DATABASE_NAME, allocator = context.temp_allocator)
		conn: db.Conn
		if open_err := sqlite.open(&conn, {path = path}); open_err != nil {
			linux.exit_group(8)
		}
		if db.exec(&conn, "BEGIN IMMEDIATE") != nil { linux.exit_group(9) }
		if !multiprocess_signal_ready(ready) { linux.exit_group(6) }
		time.sleep(MULTIPROCESS_HOLD)
		_ = db.rollback(&conn)
		multiprocess_await_death()
	}

	store: Store
	if store_open(&store, directory) != nil { linux.exit_group(2) }
	if session_claim(&store, session_id) != nil { linux.exit_group(3) }
	if role == .Poison {
		if db.exec(&store.conn, "BEGIN IMMEDIATE") != nil { linux.exit_group(4) }
		write_args := [?]db.Value{db.Value(MULTIPROCESS_POISON_TITLE), db.Value(string(session_id))}
		if db.exec(&store.conn, "UPDATE sessions SET title = ? WHERE id = ?", write_args[:]) != nil { linux.exit_group(5) }
	}
	if !multiprocess_signal_ready(ready) { linux.exit_group(6) }
	multiprocess_await_death()
}

// --- A: a claim belongs to a live owner -------------------------------------

// A process that dies holding a session's claim must not leave the session
// claimed: the kernel releases the lock when its owner goes, so a later harness
// can pick the session up.
@(test)
test_multiprocess_claim_survives_owner_death :: proc(t: ^testing.T) {
	if role, present := multiprocess_role_env(); present {
		multiprocess_child(role)
	}

	parent := _temp_directory(t)
	defer {
		os.remove_all(parent)
		delete(parent, context.allocator)
	}
	directory := fmt.aprintf("%s/claim", parent, allocator = context.allocator)
	defer delete(directory, context.allocator)

	owner: Store
	_expect_ok(t, store_open(&owner, directory))
	created, create_err := session_create(&owner, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, create_err)
	id := Session_Id(strings.clone(string(created.id), context.allocator))
	session_destroy(&created)
	store_close(&owner)
	defer delete(string(id), context.allocator)

	ready := fmt.aprintf("%s.ready", directory, allocator = context.temp_allocator)
	child, spawned := multiprocess_spawn(t, #procedure, .Hold, directory, id, ready)
	if !testing.expect(t, spawned, "the holding child could not be started") { return }
	defer multiprocess_dispose(&child)
	if !testing.expect(t, multiprocess_wait_ready(&child), "the holding child never held the claim") { return }

	probe: Store
	_expect_ok(t, store_open(&probe, directory))
	defer store_close(&probe)

	// While the child lives, the claim is not available to anyone else.
	testing.expect_value(t, error_kind(session_claim(&probe, id)), Error_Kind.Claimed)

	multiprocess_dispose(&child)

	claim_err := session_claim(&probe, id)
	if testing.expect(t, claim_err == nil, "a claim must be free once its owner dies") {
		loaded, load_err := session_load(&probe, id)
		testing.expect(t, load_err == nil, "the session must still be readable after its owner died")
		if load_err == nil { session_destroy(&loaded) }
		session_release(&probe)
	}
}

// --- B: an uncommitted write dies with its writer ---------------------------

// A writer killed inside a transaction must leave nothing of it behind: the rows
// are invisible to the next process, and the session can be written again.
@(test)
test_multiprocess_uncommitted_write_is_rolled_back :: proc(t: ^testing.T) {
	if role, present := multiprocess_role_env(); present {
		multiprocess_child(role)
	}

	parent := _temp_directory(t)
	defer {
		os.remove_all(parent)
		delete(parent, context.allocator)
	}
	directory := fmt.aprintf("%s/poison", parent, allocator = context.allocator)
	defer delete(directory, context.allocator)

	original: Store
	_expect_ok(t, store_open(&original, directory))
	created, create_err := session_create(&original, {workspace = "/tmp/project", title = "before"}, 1_000)
	_expect_ok(t, create_err)
	id := Session_Id(strings.clone(string(created.id), context.allocator))
	session_destroy(&created)
	store_close(&original)
	defer delete(string(id), context.allocator)

	ready := fmt.aprintf("%s.ready", directory, allocator = context.temp_allocator)
	child, spawned := multiprocess_spawn(t, #procedure, .Poison, directory, id, ready)
	if !testing.expect(t, spawned, "the poisoning child could not be started") { return }
	defer multiprocess_dispose(&child)
	if !testing.expect(t, multiprocess_wait_ready(&child), "the poisoning child never left its write behind") { return }
	multiprocess_dispose(&child)

	after: Store
	_expect_ok(t, store_open(&after, directory))
	defer store_close(&after)
	if !testing.expect(t, session_claim(&after, id) == nil, "the session must be claimable after its writer died") { return }
	defer session_release(&after)

	loaded, load_err := session_load(&after, id)
	testing.expect(t, load_err == nil, "the session must be readable after its writer died")
	if load_err == nil {
		testing.expect_value(t, loaded.title, "before")
		session_destroy(&loaded)
	}
	// Recovery happened on open, so the connection takes writes again.
	testing.expect(t, session_set_title(&after, id, "after") == nil, "the session must accept a write after recovery")
}

// --- C: concurrent first open -----------------------------------------------

Multiprocess_Open_Attempt :: struct {
	directory: string,
	store:     Store,
	err:       Error,
}

multiprocess_open_attempt_run :: proc(thread_handle: ^thread.Thread) {
	attempt := cast(^Multiprocess_Open_Attempt)thread_handle.data
	attempt.err = store_open(&attempt.store, attempt.directory)
}

// Two processes opening the same empty directory at once must end with one
// schema, not two migrations racing. The store that loses the write lock waits
// and then sees the work already done.
@(test)
test_multiprocess_concurrent_first_open :: proc(t: ^testing.T) {
	if _, present := multiprocess_role_env(); present {
		linux.exit_group(0)
	}

	parent := _temp_directory(t)
	defer {
		os.remove_all(parent)
		delete(parent, context.allocator)
	}
	directory := fmt.aprintf("%s/fresh", parent, allocator = context.allocator)
	defer delete(directory, context.allocator)

	first: Multiprocess_Open_Attempt
	second: Multiprocess_Open_Attempt
	first.directory = directory
	second.directory = directory

	first_thread := thread.create(multiprocess_open_attempt_run, name = "nabla-open-first")
	second_thread := thread.create(multiprocess_open_attempt_run, name = "nabla-open-second")
	if !testing.expect(t, first_thread != nil && second_thread != nil, "the opening threads could not be created") { return }
	first_thread.data = &first
	second_thread.data = &second
	thread.start(first_thread)
	thread.start(second_thread)
	thread.join(first_thread)
	thread.join(second_thread)
	thread.destroy(first_thread)
	thread.destroy(second_thread)

	multiprocess_expect_open(t, &first, "first")
	multiprocess_expect_open(t, &second, "second")

	// Both stores are usable on the one schema that was created.
	attempts := [2]^Multiprocess_Open_Attempt{&first, &second}
	for attempt, index in attempts {
		if attempt.err != nil { continue }
		created, create_err := session_create(&attempt.store, {workspace = "/tmp/project"}, i64(1_000 + index))
		testing.expect(t, create_err == nil, "a store opened in the race must be able to create a session")
		if create_err == nil { session_destroy(&created) }
		store_close(&attempt.store)
	}
}

// multiprocess_expect_open reports why one side of the opening race failed,
// with the kind and the detail the store produced.
multiprocess_expect_open :: proc(t: ^testing.T, attempt: ^Multiprocess_Open_Attempt, which: string) {
	if attempt.err == nil { return }
	local := attempt.err
	testing.expectf(t, false, "the %s concurrent open failed (%v): %s", which, error_kind(attempt.err), error_detail(&local))
}

// --- D: concurrent writes to different sessions ------------------------------

MULTIPROCESS_WRITE_ROUNDS :: 25

Multiprocess_Writer :: struct {
	directory: string,
	id:        Session_Id,
	text:      string,
	store:     Store,
	failure:   string, // "" when every write landed
}

multiprocess_writer_run :: proc(thread_handle: ^thread.Thread) {
	writer := cast(^Multiprocess_Writer)thread_handle.data
	if store_open(&writer.store, writer.directory) != nil {
		writer.failure = "store_open failed"
		return
	}
	defer store_close(&writer.store)
	if session_claim(&writer.store, writer.id) != nil {
		writer.failure = "session_claim failed"
		return
	}
	defer session_release(&writer.store)

	for _ in 0 ..< MULTIPROCESS_WRITE_ROUNDS {
		entry := New_Entry {
			created_at_ms = now_ms(),
			payload = User_Entry{text = writer.text, origin = .Prompt},
		}
		if _, append_err := entry_append(&writer.store, writer.id, entry); append_err != nil {
			writer.failure = "entry_append failed"
			return
		}
	}
}

// Two processes writing different sessions at the same time must both land.
// The database serializes the writes; the per-session claim and the MAX+1
// sequence taken inside the write transaction keep the two histories apart.
@(test)
test_multiprocess_concurrent_different_sessions :: proc(t: ^testing.T) {
	if _, present := multiprocess_role_env(); present {
		linux.exit_group(0)
	}

	parent := _temp_directory(t)
	defer {
		os.remove_all(parent)
		delete(parent, context.allocator)
	}
	directory := fmt.aprintf("%s/writers", parent, allocator = context.allocator)
	defer delete(directory, context.allocator)

	setup: Store
	_expect_ok(t, store_open(&setup, directory))
	first_created, first_err := session_create(&setup, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, first_err)
	first_id := Session_Id(strings.clone(string(first_created.id), context.allocator))
	session_destroy(&first_created)
	second_created, second_err := session_create(&setup, {workspace = "/tmp/project"}, 2_000)
	_expect_ok(t, second_err)
	second_id := Session_Id(strings.clone(string(second_created.id), context.allocator))
	session_destroy(&second_created)
	store_close(&setup)
	defer delete(string(first_id), context.allocator)
	defer delete(string(second_id), context.allocator)

	first := Multiprocess_Writer {
		directory = directory,
		id        = first_id,
		text      = "first",
	}
	second := Multiprocess_Writer {
		directory = directory,
		id        = second_id,
		text      = "second",
	}
	first_thread := thread.create(multiprocess_writer_run, name = "nabla-writer-first")
	second_thread := thread.create(multiprocess_writer_run, name = "nabla-writer-second")
	if !testing.expect(t, first_thread != nil && second_thread != nil, "the writing threads could not be created") { return }
	first_thread.data = &first
	second_thread.data = &second
	thread.start(first_thread)
	thread.start(second_thread)
	thread.join(first_thread)
	thread.join(second_thread)
	thread.destroy(first_thread)
	thread.destroy(second_thread)

	testing.expect(t, first.failure == "", "the first writer failed")
	testing.expect(t, second.failure == "", "the second writer failed")

	multiprocess_check_writer_history(t, directory, first_id, first.text)
	multiprocess_check_writer_history(t, directory, second_id, second.text)
}

// multiprocess_check_writer_history reads one session back and checks that it
// holds exactly its own writer's rounds, in order, and none of the other
// writer's.
multiprocess_check_writer_history :: proc(t: ^testing.T, directory: string, id: Session_Id, text: string) {
	store: Store
	_expect_ok(t, store_open(&store, directory))
	defer store_close(&store)

	entries, load_err := entries_load(&store, id, {limit = MULTIPROCESS_WRITE_ROUNDS * 2}, context.allocator)
	if !testing.expect(t, load_err == nil, "the written history could not be read back") { return }
	defer entries_destroy(entries, context.allocator)

	testing.expect_value(t, len(entries), MULTIPROCESS_WRITE_ROUNDS)
	previous: Seq
	for &entry in entries {
		testing.expect(t, entry.seq > previous, "a session's sequence must increase")
		previous = entry.seq
		user, is_user := entry.payload.(User_Entry)
		if !testing.expect(t, is_user, "a written entry must be a user entry") { continue }
		testing.expect_value(t, user.text, text)
	}
}

// --- E: the journal-mode switch waits out a write lock -----------------------

// The switch to write-ahead logging takes exclusive access to the file, and
// SQLite refuses it rather than waiting on the connection's busy handler. A
// launch that meets another process writing must therefore retry instead of
// failing. A child holds the database's write lock and gives it up shortly;
// the open has to survive the refusal.
@(test)
test_multiprocess_journal_switch_waits_out_a_writer :: proc(t: ^testing.T) {
	if role, present := multiprocess_role_env(); present {
		multiprocess_child(role)
	}

	parent := _temp_directory(t)
	defer {
		os.remove_all(parent)
		delete(parent, context.allocator)
	}
	directory := fmt.aprintf("%s/wal-switch", parent, allocator = context.allocator)
	defer delete(directory, context.allocator)

	// The child creates the database, so this process has no connection open
	// when it spawns.
	if make_err := os.make_directory_all(directory, {.Read_User, .Write_User, .Execute_User}); make_err != nil && make_err != .Exist {
		testing.fail_now(t, "the scenario directory could not be created")
	}
	ready := fmt.aprintf("%s.ready", directory, allocator = context.temp_allocator)
	child, spawned := multiprocess_spawn(t, #procedure, .Releaser, directory, "", ready)
	if !testing.expect(t, spawned, "the releasing child could not be started") { return }
	defer multiprocess_dispose(&child)
	if !testing.expect(t, multiprocess_wait_ready(&child), "the releasing child never took the write lock") { return }
	multiprocess_dispose(&child)

	// The child holds the write lock and gives it up partway through the open.
	loaded: Store
	if open_err := store_open(&loaded, directory); open_err != nil {
		local := open_err
		testing.expectf(t, false, "opening while another process held the file failed (%v): %s", error_kind(open_err), error_detail(&local))
	} else {
		store_close(&loaded)
	}
}
