#+build linux
package main

// Multiprocess and multithreaded tests for one session database shared by more
// than one harness process.
//
// This is a single-threaded executable rather than an in-package @(test) suite
// because it forks: fork() into a multi-threaded test runner can deadlock on an
// allocator lock another thread holds. The scenarios that need a process to die
// run first, while this process is still single-threaded; the scenarios that
// need two writers run afterwards on threads.
//
// What the scenarios are evidence for:
//   A a claim is held while its owner lives and is free once it dies
//   B an uncommitted write dies with its writer, and the connection recovers
//   C two processes opening an empty directory at once migrate it exactly once
//   D two processes writing different sessions at once do not interfere
//   E an open survives another process holding the database's write lock
//
// The children run the real store code. Nothing here reaches into internals, so
// what is exercised is exactly what a second harness process does.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:thread"
import "core:time"
import "nabla:agent/session"
import "nabla:db"
import "nabla:db/sqlite"

failures: int

// check records a failed expectation and returns the condition, so a scenario can
// stop on the failure it cannot proceed past. The count is the exit code.
check :: proc(cond: bool, message: string) -> bool {
	if !cond {
		fmt.eprintln("FAIL:", message)
		failures += 1
	}
	return cond
}

// --- process roles ----------------------------------------------------------

// READY_BYTE is what a child writes once it holds what its scenario needs the
// parent to act on.
READY_BYTE :: 'R'

// CHILD_READY_TIMEOUT_MS bounds the wait for a child's first byte, so a child
// that hangs on a lock fails the scenario instead of hanging the gate.
CHILD_READY_TIMEOUT_MS :: 10_000

// Child is a forked process in a scenario role, plus the pipe it reports
// readiness on.
Child :: struct {
	pid:   linux.Pid,
	ready: linux.Fd,
}

// spawn_child forks this process in the named role. The child opens the store,
// claims the session when the role needs one, and reports readiness once it
// holds what its scenario needs the parent to act on. Roles:
//   .Hold     claims the session and waits to be killed
//   .Poison   claims the session and leaves an uncommitted write behind
//   .Releaser holds the database's write lock in rollback mode, gives it up
//             after a bounded wait, and waits to be killed
//
// A child must never be spawned once this process has a connection open: a fork
// copies SQLite's in-memory lock state, and a child that then opens the same
// database works from a lock table that describes another process's locks.
Child_Role :: enum {
	Hold,
	Poison,
	Releaser,
}

spawn_child :: proc(directory: string, id: session.Session_Id, role: Child_Role) -> (child: Child, ok: bool) {
	ready: [2]linux.Fd
	if linux.pipe2(&ready, {.CLOEXEC}) != .NONE { return {}, false }

	pid, fork_errno := linux.fork()
	if fork_errno != .NONE {
		linux.close(ready[0])
		linux.close(ready[1])
		return {}, false
	}
	if pid == 0 {
		linux.close(ready[0])
		child_run(directory, id, role, ready[1])
	}

	linux.close(ready[1])
	return Child{pid = pid, ready = ready[0]}, true
}

// child_run never returns: it is killed while it holds what its scenario needs.
// Nothing here frees or flushes, so the parent sees exactly what the kernel does
// with a process that never got to clean up.
child_run :: proc(directory: string, id: session.Session_Id, role: Child_Role, ready: linux.Fd) -> ! {
	if role == .Releaser {
		// A connection to the database as it exists before any launch has switched
		// it, holding the write lock a launch has to get past.
		path := fmt.aprintf("%s/%s", directory, session.DATABASE_NAME, allocator = context.temp_allocator)
		conn: db.Conn
		if open_err := sqlite.open(&conn, {path = path}); open_err != nil {
			local := open_err
			child_die(ready, 8, db.error_message(&local))
		}
		if db.exec(&conn, "BEGIN IMMEDIATE") != nil { child_die(ready, 9) }
		if !child_signal(ready) { child_die(ready, 6) }
		time.sleep(HOLDER_HOLD)
		_ = db.rollback(&conn)
		linux.pause()
		linux.exit_group(7)
	}

	store: session.Store
	if session.store_open(&store, directory) != nil { child_die(ready, 2) }
	if session.session_claim(&store, id) != nil { child_die(ready, 3) }
	if role == .Poison {
		if db.exec(&store.conn, "BEGIN IMMEDIATE") != nil { child_die(ready, 4) }
		write_args := [?]db.Value{db.Value(POISON_TITLE), db.Value(string(id))}
		if db.exec(&store.conn, "UPDATE sessions SET title = ? WHERE id = ?", write_args[:]) != nil { child_die(ready, 5) }
	}
	if !child_signal(ready) { child_die(ready, 6) }
	linux.pause()
	linux.exit_group(7)
}

// HOLDER_HOLD is how long a releasing child keeps the write lock. It is long
// enough that an open which does not retry will meet it and short enough that the
// retry does not have to wait out the whole busy timeout.
HOLDER_HOLD :: 300 * time.Millisecond

// wait_child_ready reports whether the child reached the point its scenario needs.
// It closes the pipe either way. A child that died instead of reporting leaves a
// closed pipe, and one that hung is bounded by the readiness timeout.
wait_child_ready :: proc(child: ^Child) -> bool {
	ready := wait_for_ready(child.ready)
	linux.close(child.ready)
	child.ready = 0
	return ready
}

// child_dispose kills and reaps a child that is no longer needed.
child_dispose :: proc(child: Child) {
	if child.ready != 0 { linux.close(child.ready) }
	kill_and_reap(child.pid)
}

// POISON_TITLE is the title a poisoned child writes without committing. The
// parent looks for it to prove the write did not survive.
POISON_TITLE :: "uncommitted"

// child_die reports a child failure on stderr and leaves without running any
// handler that could touch the parent's copied state.
child_die :: proc(ready: linux.Fd, code: i32, detail: string = "") -> ! {
	if detail != "" {
		fmt.eprintln("child: step", code, "failed:", detail)
	} else {
		fmt.eprintln("child: step", code, "failed")
	}
	linux.close(ready)
	linux.exit_group(code)
}

// child_signal tells the parent that the child holds what its scenario needs.
child_signal :: proc(ready: linux.Fd) -> bool {
	byte := [1]u8{READY_BYTE}
	_, write_errno := linux.write(ready, byte[:])
	return write_errno == .NONE
}

// wait_for_ready waits for the child's first byte within the bound.
wait_for_ready :: proc(ready: linux.Fd) -> bool {
	fds := [1]linux.Poll_Fd{{fd = ready, events = {.IN}}}
	ready_count, poll_errno := linux.poll(fds[:], CHILD_READY_TIMEOUT_MS)
	if poll_errno != .NONE || ready_count <= 0 { return false }
	byte: [1]u8
	read_count, read_errno := linux.read(ready, byte[:])
	return read_errno == .NONE && read_count == 1 && byte[0] == READY_BYTE
}

kill_and_reap :: proc(pid: linux.Pid) {
	_ = linux.kill(pid, .SIGKILL)
	status: u32
	for {
		reaped, wait_errno := linux.wait4(pid, &status, {}, nil)
		if reaped == pid { return }
		if wait_errno == .EINTR { continue }
		return
	}
}

// --- shared helpers ---------------------------------------------------------

// make_session creates a session in store and returns an owned copy of its id.
make_session :: proc(store: ^session.Store, options: session.Create_Options, at_ms: i64) -> (id: session.Session_Id, ok: bool) {
	created, create_err := session.session_create(store, options, at_ms)
	if create_err != nil { return "", false }
	id = session.Session_Id(strings.clone(string(created.id), context.allocator))
	session.session_destroy(&created)
	return id, true
}

// fresh_directory names a directory beneath parent that no store has opened yet.
fresh_directory :: proc(parent, name: string) -> string {
	return fmt.aprintf("%s/%s", parent, name, allocator = context.allocator)
}

// --- A: a claim belongs to a live owner -------------------------------------

// A process that dies holding a session's claim must not leave the session
// claimed: the kernel releases the lock when its owner goes, so a later harness
// can pick the session up.
scenario_claim_survives_owner_death :: proc(parent: string) {
	at_start := failures
	directory := fresh_directory(parent, "claim")
	defer delete(directory, context.allocator)

	owner: session.Store
	if open_err := session.store_open(&owner, directory); open_err != nil {
		check(false, "the owning store could not be opened")
		return
	}
	id, created := make_session(&owner, {workspace = "/tmp/project"}, 1_000)
	session.store_close(&owner)
	if !check(created, "the session could not be created") { return }
	defer delete(string(id), context.allocator)

	child, spawned := spawn_child(directory, id, .Hold)
	if !check(spawned, "the holding child could not be started") { return }
	if !check(wait_child_ready(&child), "the holding child never held the claim") {
		child_dispose(child)
		return
	}

	probe: session.Store
	if open_err := session.store_open(&probe, directory); open_err != nil {
		check(false, "the probing store could not be opened")
		child_dispose(child)
		return
	}
	defer session.store_close(&probe)

	// While the child lives, the claim is not available to anyone else.
	check(session.error_kind(session.session_claim(&probe, id)) == .Claimed, "a live owner's claim must refuse another process")

	child_dispose(child)

	claim_err := session.session_claim(&probe, id)
	if check(claim_err == nil, "a claim must be free once its owner dies") {
		loaded, load_err := session.session_load(&probe, id)
		check(load_err == nil, "the session must still be readable after its owner died")
		if load_err == nil { session.session_destroy(&loaded) }
		session.session_release(&probe)
	}
	if failures == at_start { fmt.println("ok: a claim is free once its owner dies") }
}

// --- B: an uncommitted write dies with its writer ---------------------------

// A writer killed inside a transaction must leave nothing of it behind: the rows
// are invisible to the next process, and the session can be written again.
scenario_uncommitted_write_is_rolled_back :: proc(parent: string) {
	at_start := failures
	directory := fresh_directory(parent, "poison")
	defer delete(directory, context.allocator)

	original: session.Store
	if open_err := session.store_open(&original, directory); open_err != nil {
		check(false, "the store could not be opened")
		return
	}
	id, created := make_session(&original, {workspace = "/tmp/project", title = "before"}, 1_000)
	session.store_close(&original)
	if !check(created, "the session could not be created") { return }
	defer delete(string(id), context.allocator)

	child, spawned := spawn_child(directory, id, .Poison)
	if !check(spawned, "the poisoning child could not be started") { return }
	if !check(wait_child_ready(&child), "the poisoning child never left its write behind") {
		child_dispose(child)
		return
	}
	child_dispose(child)

	after: session.Store
	if open_err := session.store_open(&after, directory); open_err != nil {
		check(false, "the store could not be reopened after the writer died")
		return
	}
	defer session.store_close(&after)
	if !check(session.session_claim(&after, id) == nil, "the session must be claimable after its writer died") { return }
	defer session.session_release(&after)

	loaded, load_err := session.session_load(&after, id)
	check(load_err == nil, "the session must be readable after its writer died")
	if load_err == nil {
		check(loaded.title == "before", "an uncommitted write must not survive its writer")
		session.session_destroy(&loaded)
	}
	// Recovery happened on open, so the connection takes writes again.
	check(session.session_set_title(&after, id, "after") == nil, "the session must accept a write after recovery")
	if failures == at_start { fmt.println("ok: an uncommitted write dies with its writer") }
}

// --- C: concurrent first open ------------------------------------------------

Open_Attempt :: struct {
	directory: string,
	store:     session.Store,
	err:       session.Error,
}

open_attempt_run :: proc(thread_handle: ^thread.Thread) {
	attempt := cast(^Open_Attempt)thread_handle.data
	attempt.err = session.store_open(&attempt.store, attempt.directory)
}

// Two processes opening the same empty directory at once must end with one
// schema, not two migrations racing. The store that loses the write lock waits
// and then sees the work already done.
scenario_concurrent_first_open :: proc(parent: string) {
	at_start := failures
	directory := fresh_directory(parent, "fresh")
	defer delete(directory, context.allocator)

	first: Open_Attempt
	second: Open_Attempt
	first.directory = directory
	second.directory = directory

	first_thread := thread.create(open_attempt_run, name = "nabla-open-first")
	second_thread := thread.create(open_attempt_run, name = "nabla-open-second")
	if first_thread == nil || second_thread == nil {
		check(false, "the opening threads could not be created")
		return
	}
	first_thread.data = &first
	second_thread.data = &second
	thread.start(first_thread)
	thread.start(second_thread)
	thread.join(first_thread)
	thread.join(second_thread)
	thread.destroy(first_thread)
	thread.destroy(second_thread)

	check_open_attempt(&first, "first")
	check_open_attempt(&second, "second")

	// Both stores are usable on the one schema that was created.
	attempts := [2]^Open_Attempt{&first, &second}
	for attempt, index in attempts {
		if attempt.err != nil { continue }
		created, create_err := session.session_create(&attempt.store, {workspace = "/tmp/project"}, i64(1_000 + index))
		check(create_err == nil, "a store opened in the race must be able to create a session")
		if create_err == nil { session.session_destroy(&created) }
		session.store_close(&attempt.store)
	}
	if failures == at_start { fmt.println("ok: two processes open an empty database at once") }
}

// check_open_attempt reports why one side of the opening race failed, with the
// kind and the detail the store produced.
check_open_attempt :: proc(attempt: ^Open_Attempt, which: string) {
	if attempt.err == nil { return }
	local := attempt.err
	check(false, fmt.tprintf("the %s concurrent open failed (%v): %s", which, session.error_kind(attempt.err), session.error_detail(&local)))
}

// --- D: concurrent writes to different sessions ------------------------------

WRITE_ROUNDS :: 25

Writer :: struct {
	directory: string,
	id:        session.Session_Id,
	text:      string,
	store:     session.Store,
	failure:   string, // "" when every write landed
}

writer_run :: proc(thread_handle: ^thread.Thread) {
	writer := cast(^Writer)thread_handle.data
	if session.store_open(&writer.store, writer.directory) != nil {
		writer.failure = "store_open failed"
		return
	}
	defer session.store_close(&writer.store)
	if session.session_claim(&writer.store, writer.id) != nil {
		writer.failure = "session_claim failed"
		return
	}
	defer session.session_release(&writer.store)

	for _ in 0 ..< WRITE_ROUNDS {
		entry := session.New_Entry {
			created_at_ms = session.now_ms(),
			payload = session.User_Entry{text = writer.text, origin = .Prompt},
		}
		if _, append_err := session.entry_append(&writer.store, writer.id, entry); append_err != nil {
			writer.failure = "entry_append failed"
			return
		}
	}
}

// Two processes writing different sessions at the same time must both land.
// The database serializes the writes; the per-session claim and the MAX+1
// sequence taken inside the write transaction keep the two histories apart.
scenario_concurrent_different_sessions :: proc(parent: string) {
	at_start := failures
	directory := fresh_directory(parent, "writers")
	defer delete(directory, context.allocator)

	setup: session.Store
	if open_err := session.store_open(&setup, directory); open_err != nil {
		check(false, "the setup store could not be opened")
		return
	}
	first_id, first_created := make_session(&setup, {workspace = "/tmp/project"}, 1_000)
	second_id, second_created := make_session(&setup, {workspace = "/tmp/project"}, 2_000)
	session.store_close(&setup)
	if !check(first_created && second_created, "the sessions could not be created") { return }
	defer delete(string(first_id), context.allocator)
	defer delete(string(second_id), context.allocator)

	first := Writer {
		directory = directory,
		id        = first_id,
		text      = "first",
	}
	second := Writer {
		directory = directory,
		id        = second_id,
		text      = "second",
	}
	first_thread := thread.create(writer_run, name = "nabla-writer-first")
	second_thread := thread.create(writer_run, name = "nabla-writer-second")
	if first_thread == nil || second_thread == nil {
		check(false, "the writing threads could not be created")
		return
	}
	first_thread.data = &first
	second_thread.data = &second
	thread.start(first_thread)
	thread.start(second_thread)
	thread.join(first_thread)
	thread.join(second_thread)
	thread.destroy(first_thread)
	thread.destroy(second_thread)

	check(first.failure == "", fmt.tprintf("the first writer failed: %s", first.failure))
	check(second.failure == "", fmt.tprintf("the second writer failed: %s", second.failure))

	check_writer_history(directory, first_id, first.text)
	check_writer_history(directory, second_id, second.text)
	if failures == at_start { fmt.println("ok: two processes write different sessions at once") }
}

// check_writer_history reads one session back and checks that it holds exactly
// its own writer's rounds, in order, and none of the other writer's.
check_writer_history :: proc(directory: string, id: session.Session_Id, text: string) {
	store: session.Store
	if open_err := session.store_open(&store, directory); open_err != nil {
		check(false, "the reading store could not be opened")
		return
	}
	defer session.store_close(&store)

	entries, load_err := session.entries_load(&store, id, {limit = WRITE_ROUNDS * 2}, context.allocator)
	if !check(load_err == nil, "the written history could not be read back") { return }
	defer session.entries_destroy(entries, context.allocator)

	check(len(entries) == WRITE_ROUNDS, fmt.tprintf("a session wrote %d entries, expected %d", len(entries), WRITE_ROUNDS))
	previous: session.Seq
	for &entry in entries {
		check(entry.seq > previous, "a session's sequence must increase")
		previous = entry.seq
		user, is_user := entry.payload.(session.User_Entry)
		if !check(is_user, "a written entry must be a user entry") { continue }
		check(user.text == text, "a session must hold only its own writer's entries")
	}
}

// --- E: the journal-mode switch waits out a write lock -----------------------

// The switch to write-ahead logging takes exclusive access to the file, and
// SQLite refuses it rather than waiting on the connection's busy handler. A
// launch that meets another process writing must therefore retry instead of
// failing. A child holds the database's write lock and gives it up shortly; the
// open has to survive the refusal.
scenario_journal_switch_waits_out_a_writer :: proc(parent: string) {
	at_start := failures
	directory := fresh_directory(parent, "wal-switch")
	defer delete(directory, context.allocator)

	// The child creates the database, so this process has no connection open when
	// it forks.
	if make_err := os.make_directory_all(directory, {.Read_User, .Write_User, .Execute_User}); make_err != nil && make_err != .Exist {
		check(false, "the scenario directory could not be created")
		return
	}
	child, spawned := spawn_child(directory, "", .Releaser)
	if !check(spawned, "the releasing child could not be started") { return }
	if !check(wait_child_ready(&child), "the releasing child never took the write lock") {
		child_dispose(child)
		return
	}

	// The child holds the write lock and gives it up partway through the open.
	loaded: session.Store
	if open_err := session.store_open(&loaded, directory); open_err != nil {
		local := open_err
		check(false, fmt.tprintf("opening while another process held the file failed (%v): %s", session.error_kind(open_err), session.error_detail(&local)))
	} else {
		session.store_close(&loaded)
	}
	child_dispose(child)
	if failures == at_start { fmt.println("ok: opening waits out another process's write lock") }
}

// --- parent -----------------------------------------------------------------

run_parent :: proc() -> int {
	parent, parent_err := os.make_directory_temp("", "nabla-multiprocess-*", context.allocator)
	if parent_err != nil {
		fmt.eprintln("FAIL: a temporary directory could not be created")
		return 1
	}
	defer {
		os.remove_all(parent)
		delete(parent, context.allocator)
	}

	// The process-death scenarios run first: forking is only safe while this
	// process is still single-threaded.
	scenario_claim_survives_owner_death(parent)
	scenario_uncommitted_write_is_rolled_back(parent)
	scenario_journal_switch_waits_out_a_writer(parent)

	// The concurrent scenarios need more than one writer at once.
	scenario_concurrent_first_open(parent)
	scenario_concurrent_different_sessions(parent)

	if failures > 0 {
		fmt.eprintln("multiprocess: failed:", failures)
		return 1
	}
	fmt.println("multiprocess: ok")
	return 0
}

main :: proc() {
	os.exit(run_parent())
}
