package subprocess

import "base:runtime"
import "core:io"
import "core:os"
import "core:strings"
import "core:time"

// KILL_GRACE is how long terminate_group lets a child exit on SIGTERM before it sends SIGKILL.
KILL_GRACE :: 500 * time.Millisecond

// POLL_MAX is the most entries one poll call takes.
POLL_MAX :: 8

// CHILD_SETUP_FAILED is the exit status of a forked child that could not prepare its process
// group, streams, or directory before exec.
@(private)
CHILD_SETUP_FAILED :: 1

// CHILD_EXEC_FAILED is the exit status of a forked child whose exec failed, the status a shell
// reports for a command it cannot run.
@(private)
CHILD_EXEC_FAILED :: 127

// Fd is an operating-system descriptor number, the neutral form of what os.fd reports.
Fd :: distinct int

// FD_NONE names no descriptor.
FD_NONE :: Fd(-1)

// fd returns the descriptor of file.
fd :: proc(file: ^os.File) -> Fd {
	return Fd(os.fd(file))
}

// Exec describes the command a forked child runs. argv and envp end in a nil entry. report is the
// descriptor the child writes one errno byte to when exec fails.
@(private)
Exec :: struct {
	argv:         [^]cstring,
	envp:         [^]cstring,
	directory:    cstring,
	input:        Fd,
	output:       Fd,
	errors:       Fd,
	report:       Fd,
	parent_death: bool,
}

// Desc describes the program a child runs.
Desc :: struct {
	// argv holds the program and its arguments. argv[0] is executed as given, with no search of
	// PATH, and must exist.
	argv:         []string,
	// environment is the complete KEY=VALUE environment of the child. Nil is an empty one; pass
	// the result of os.environ to inherit.
	environment:  []string,
	// directory is where the child starts. The empty string keeps the parent's.
	directory:    string,
	// stdin is what the child reads. Nil closes the child's standard input.
	stdin:        ^os.File,
	// stdout and stderr are what the child writes. Both are required.
	stdout:       ^os.File,
	stderr:       ^os.File,
	// parent_death asks the system to kill the child when the thread that started it exits.
	// Linux only.
	parent_death: bool,
}

// Spawn is how far a start got. Only Exec_Failed proves the program never ran, which is what
// lets a caller try another program without running a command twice.
Spawn :: enum {
	Started,
	Exec_Failed,
	Failed,
}

// Child tracks one started program until it is reaped. The exit state is recorded the first
// time it is observed, because a wait may reap the child while its pipes are still being read.
// exited is false for a child a signal ended. exit is a descriptor that becomes readable once the
// child exits; it is valid while exit_open is set and is released with child_close. The zero
// value is no child.
Child :: struct {
	pid:          int,
	exit:         Fd,
	exit_open:    bool,
	reaped:       bool,
	status_known: bool,
	exited:       bool,
	exit_code:    int,
}

// Wait is what a wait on a child found. Running also covers a wait the system refused, which
// leaves the child's state unknown.
@(private)
Wait :: enum {
	Running,
	Finished,
	Gone,
}

// Group_Signal is the signal sent to a process group.
@(private)
Group_Signal :: enum {
	Terminate,
	Kill,
}

// start runs desc in a new process group led by the child. Every descriptor in desc must close
// on exec, as those of os.pipe do; the child installs its own on standard input, output, and
// error. The caller keeps ownership of the files and closes its copies of the child's ends.
//
// On Started the caller owns child and must end it with terminate_group or child_reap, then
// release it with child_close. On Exec_Failed err is the reason exec gave, and the child has been
// reaped, so there is nothing to close. On Failed err is the system's reason and nothing is left
// running.
//
// It allocates from context.temp_allocator before the fork and nothing after it. Between fork and
// exec the child makes only raw system calls, because the process may have other threads, and
// every failure leaves through exit_group, which runs no atexit handler and flushes no stdio.
// Concurrent calls are safe.
@(require_results)
start :: proc(desc: Desc) -> (child: Child, spawn: Spawn, err: os.Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if len(desc.argv) == 0 { return {}, .Failed, os.General_Error.Invalid_Command }
	if desc.stdout == nil || desc.stderr == nil { return {}, .Failed, os.General_Error.Invalid_File }
	argv, argv_error := cstring_vector(desc.argv, context.temp_allocator)
	if argv_error != nil { return {}, .Failed, argv_error }
	envp, envp_error := cstring_vector(desc.environment, context.temp_allocator)
	if envp_error != nil { return {}, .Failed, envp_error }
	directory: cstring
	if desc.directory != "" {
		clone_error: runtime.Allocator_Error
		directory, clone_error = strings.clone_to_cstring(desc.directory, context.temp_allocator)
		if clone_error != nil { return {}, .Failed, clone_error }
	}

	// The report pipe carries one fact back to the parent: whether the program started. It
	// closes on exec, so a successful exec closes the child's write end and the parent reads end
	// of stream, while a failed one lets the child write its errno first.
	report_read, report_write, pipe_error := os.pipe()
	if pipe_error != nil { return {}, .Failed, pipe_error }
	defer _ = os.close(report_read)
	input := FD_NONE
	if desc.stdin != nil { input = fd(desc.stdin) }
	pid, fork_error := fork_exec(
		{
			argv = raw_data(argv),
			envp = raw_data(envp),
			directory = directory,
			input = input,
			output = fd(desc.stdout),
			errors = fd(desc.stderr),
			report = fd(report_write),
			parent_death = desc.parent_death,
		},
	)
	_ = os.close(report_write)
	if fork_error != nil { return {}, .Failed, fork_error }
	child.pid = pid

	// The watch is taken before the report is read: the child cannot be reaped before then, so
	// the pid still names it.
	child.exit, err = exit_watch_open(pid)
	if err != nil {
		terminate_group(&child)
		return {}, .Failed, err
	}
	child.exit_open = true

	reported: [1]u8
	count, status := read(report_read, reported[:])
	for status == .Again {
		count, status = read(report_read, reported[:])
	}
	// Only the report says the exec failed. End of stream means the child exec'd or died before
	// it could report, and a failed read says nothing either; in both cases the program may have
	// run, so the child counts as started and the caller waits for it like any other.
	if status != .Ok || count == 0 { return child, .Started, nil }

	// The child never became the program. Reap it here, so it leaves no zombie and no pid a
	// caller could mistake for a running program.
	_, _, _ = child_reap(&child)
	child_close(&child)
	return {}, .Exec_Failed, os.Platform_Error(i32(reported[0]))
}

// cstring_vector returns the nil-terminated vector exec takes, with each string cloned.
@(private, require_results)
cstring_vector :: proc(strs: []string, allocator: runtime.Allocator) -> (vector: []cstring, err: runtime.Allocator_Error) {
	vector = make([]cstring, len(strs) + 1, allocator) or_return
	for text, index in strs {
		vector[index] = strings.clone_to_cstring(text, allocator) or_return
	}
	return vector, nil
}

// child_close releases the exit descriptor. The child must already be reaped. Closing a child
// that has none is a no-op.
child_close :: proc(child: ^Child) {
	if child.exit_open { exit_watch_close(child.exit) }
	child.exit, child.exit_open = 0, false
}

// child_record keeps the exit state a wait reported.
@(private)
child_record :: proc(child: ^Child, exited: bool, exit_code: int) {
	child.reaped = true
	child.status_known = true
	child.exited = exited
	if exited { child.exit_code = exit_code }
}

// child_poll reports whether the child has finished, reaping it if it has. It never blocks.
@(require_results)
child_poll :: proc(child: ^Child) -> bool {
	if child.reaped { return true }
	switch wait, exited, exit_code := child_wait(child.pid, false); wait {
	case .Finished:
		child_record(child, exited, exit_code)
	case .Gone:
		// No child left to wait for: it was already reaped.
		child.reaped = true
	case .Running:
	}
	return child.reaped
}

// child_reap blocks until the child is reaped and reports its exit state. A process killed by a
// signal did not exit, so exited is false. waited is false when the system refused the wait or
// the child was already gone, and the exit state is then unknown.
child_reap :: proc(child: ^Child) -> (exited: bool, exit_code: int, waited: bool) {
	if child.reaped { return child.exited, child.exit_code, child.status_known }
	switch wait, child_exited, child_exit_code := child_wait(child.pid, true); wait {
	case .Finished:
		child_record(child, child_exited, child_exit_code)
		return child.exited, child.exit_code, true
	case .Gone:
		child.reaped = true
	case .Running:
	}
	return false, 0, false
}

// child_await blocks until the child exits or deadline passes, and reaps it if it exited.
child_await :: proc(child: ^Child, deadline: time.Tick) {
	if !child.exit_open { return }
	for !child_poll(child) && time.tick_diff(time.tick_now(), deadline) > 0 {
		entries := [1]Poll{{fd = child.exit}}
		if poll(entries[:], deadline, true) != nil { return }
	}
}

// terminate_group asks the whole group to stop, waits up to grace for the child to exit, then
// kills whatever of the group is left and reaps the child. It returns true when group members
// were signalled after the child itself had already been reaped, which means a background
// process outlived it; those members get a second grace before the kill. Signals that cannot
// be delivered are not reported, because the child is reaped whatever they did. It blocks for at
// most two graces.
terminate_group :: proc(child: ^Child, grace := KILL_GRACE) -> bool {
	if child.pid <= 0 { return false }
	term_sent := group_signal(child.pid, .Terminate)
	was_reaped := child.reaped
	child_await(child, time.tick_add(time.tick_now(), grace))
	if was_reaped && term_sent {
		// A reaped leader cannot keep its group alive, so a successful group signal means a
		// background member remains.
		no_entries: []Poll
		_ = poll(no_entries, time.tick_add(time.tick_now(), grace), true)
	}
	_ = group_signal(child.pid, .Kill)
	if !child.reaped { _ = os.process_kill({pid = child.pid}) }
	_, _, _ = child_reap(child)
	return was_reaped && term_sent
}

// Direction is what a wait on a descriptor waits for.
Direction :: enum {
	Read,
	Write,
}

// Poll is one descriptor of a readiness wait. ready is set by poll when the descriptor has data,
// has room, reached its end, or failed, so the matching read or write will not block.
Poll :: struct {
	fd:        Fd,
	direction: Direction,
	ready:     bool,
}

// poll blocks until one of entries is ready, or until deadline when has_deadline is set, and
// never wakes on its own otherwise. A signal restarts the wait with the time left. It takes at
// most POLL_MAX entries, a contract of the caller, and returns EINVAL for more.
@(require_results)
poll :: proc(entries: []Poll, deadline: time.Tick, has_deadline: bool) -> os.Error {
	for {
		timeout: i32 = -1
		if has_deadline {
			remaining := time.tick_diff(time.tick_now(), deadline)
			timeout = remaining <= 0 ? 0 : i32(min((remaining + time.Millisecond - 1) / time.Millisecond, time.Duration(max(i32))))
		}
		interrupted, err := poll_wait(entries, timeout)
		if !interrupted { return err }
	}
}

// Io is the outcome of one read on a pipe end.
Io :: enum {
	// Ok read the reported count of bytes; zero bytes is end of stream.
	Ok,
	// Again read nothing: the end was not ready or a signal interrupted the call.
	Again,
	Failed,
}

// read reads what one pipe end holds into buffer.
@(require_results)
read :: proc(file: ^os.File, buffer: []u8) -> (count: int, status: Io) {
	bytes_read, err := os.read(file, buffer)
	if bytes_read > 0 || err == nil || err == io.Error.EOF { return bytes_read, .Ok }
	if error_again(err) { return 0, .Again }
	return 0, .Failed
}
