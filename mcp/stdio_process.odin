package mcp

import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

// STDIO_KILL_GRACE bounds how long a server may take to exit on SIGTERM before
// its whole process group is killed outright.
STDIO_KILL_GRACE :: 500 * time.Millisecond

// STDIO_CHILD_SETUP_FAILED is the exit status of a forked child that could not
// prepare its process group, streams, or directory before exec.
@(private)
STDIO_CHILD_SETUP_FAILED :: 1

// STDIO_CHILD_EXEC_FAILED is the exit status of a forked child whose exec failed.
@(private)
STDIO_CHILD_EXEC_FAILED :: 127

// Stdio_Pipes is the parent's end of a spawned server's three streams. Each end
// closes on exec, so no other child the process starts inherits it.
Stdio_Pipes :: struct {
	stdin:  ^os.File,
	stdout: ^os.File,
	stderr: ^os.File,
}

// Stdio_Child tracks one spawned server until it is reaped. exit watches for the
// server's exit and is released with stdio_child_close.
Stdio_Child :: struct {
	pid:    int,
	exit:   Stdio_Exit_Watch,
	reaped: bool,
}

// Stdio_Direction is what a wait on a pipe end waits for.
Stdio_Direction :: enum {
	Read,
	Write,
}

// Stdio_Io is the outcome of one read or write on a non-blocking pipe end.
Stdio_Io :: enum {
	// Ok moved the reported count of bytes; a read of zero bytes is end of stream.
	Ok,
	// Again moved nothing: the end was not ready or a signal interrupted the call.
	Again,
	Failed,
}

// Stdio_Fd is a descriptor as the platform layer names it.
@(private)
Stdio_Fd :: distinct uintptr

// STDIO_POLL_MAX is the most entries one stdio_poll call takes: a pipe end, the
// server's exit watch, and the control's wake.
@(private)
STDIO_POLL_MAX :: 3

// Stdio_Poll_Entry is one descriptor a stdio_poll call waits on. ready is set when
// the descriptor has data, room, end of stream, or an error to report.
@(private)
Stdio_Poll_Entry :: struct {
	fd:        Stdio_Fd,
	direction: Stdio_Direction,
	ready:     bool,
}

// Stdio_Signal is a signal stdio_signal can send.
@(private)
Stdio_Signal :: enum {
	Terminate,
	Kill,
}

// Stdio_Child_Status is what one wait on a child found.
@(private)
Stdio_Child_Status :: enum {
	Running,
	// Exited means the child is reaped, or there was none left to reap.
	Exited,
	Interrupted,
	Failed,
}

@(private)
stdio_fd :: proc(file: ^os.File) -> Stdio_Fd {
	return Stdio_Fd(os.fd(file))
}

// stdio_spawn starts name in its own process group with a pipe on each standard
// stream. argv and envp are already-built, nil-terminated vectors, and directory
// is nil to inherit the parent's; a failure reports the system's reason, including
// what exec gave when the program could not be run.
//
// Odin's os.process_start has no pre-exec hook, so the platform layer forks and
// makes the process group itself.
@(require_results)
stdio_spawn :: proc(name: cstring, argv: [^]cstring, envp: [^]cstring, directory: cstring) -> (pipes: Stdio_Pipes, child: Stdio_Child, err: os.Error) {
	// Each pipe end is closed exactly once on every path out of here, and a close that
	// fails only leaks a descriptor that this procedure cannot report anyway.
	stdin_read, stdin_write := os.pipe() or_return
	defer if err != nil { _ = os.close(stdin_write) }
	defer _ = os.close(stdin_read)
	stdout_read, stdout_write := os.pipe() or_return
	defer if err != nil { _ = os.close(stdout_read) }
	defer _ = os.close(stdout_write)
	stderr_read, stderr_write := os.pipe() or_return
	defer if err != nil { _ = os.close(stderr_read) }
	defer _ = os.close(stderr_write)
	// The setup pipe closes on exec, so a successful exec closes it and the parent
	// reads end of stream. A byte arriving instead is the errno of a failed exec.
	setup_read, setup_write := os.pipe() or_return
	defer _ = os.close(setup_read)

	child_stdin, child_stdout, child_stderr := stdio_fd(stdin_read), stdio_fd(stdout_write), stdio_fd(stderr_write)
	report_fd := stdio_fd(setup_write)
	pid, fork_err := stdio_fork_exec(name, argv, envp, directory, child_stdin, child_stdout, child_stderr, report_fd)
	if fork_err != nil {
		err = fork_err
		_ = os.close(setup_write)
		return
	}
	_ = os.close(setup_write)

	spawned := Stdio_Child {
		pid = pid,
	}
	// The watch is taken before the report is read: the child cannot be reaped
	// before then, so the pid still names it.
	spawned.exit, err = stdio_exit_watch_open(spawned.pid)
	if err != nil {
		stdio_terminate_group(&spawned)
		return
	}
	report: [1]u8
	reported, status := stdio_read(setup_read, report[:])
	for status == .Again {
		reported, status = stdio_read(setup_read, report[:])
	}
	if status == .Ok && reported > 0 {
		stdio_terminate_group(&spawned)
		stdio_child_close(&spawned)
		err = os.Platform_Error(i32(report[0]))
		return
	}
	return Stdio_Pipes{stdin = stdin_write, stdout = stdout_read, stderr = stderr_read}, spawned, nil
}

// stdio_child_close releases the exit watch. The child must already be reaped.
stdio_child_close :: proc(child: ^Stdio_Child) {
	stdio_exit_watch_close(&child.exit)
}

// stdio_pipes_close closes the parent's ends of a server's streams.
stdio_pipes_close :: proc(pipes: Stdio_Pipes) {
	// The caller is discarding these ends, so a close that fails changes nothing.
	_ = os.close(pipes.stdin)
	_ = os.close(pipes.stdout)
	_ = os.close(pipes.stderr)
}

// stdio_read reads what one pipe end holds into buffer.
@(require_results)
stdio_read :: proc(file: ^os.File, buffer: []u8) -> (count: int, status: Stdio_Io) {
	bytes_read, err := os.read(file, buffer)
	if bytes_read > 0 || err == nil || err == io.Error.EOF { return bytes_read, .Ok }
	return 0, stdio_io_failure(err)
}

// stdio_write writes as much of data as one pipe end accepts.
@(require_results)
stdio_write :: proc(file: ^os.File, data: []u8) -> (count: int, status: Stdio_Io) {
	bytes_written, err := os.write(file, data)
	if bytes_written > 0 || err == nil { return bytes_written, .Ok }
	return 0, stdio_io_failure(err)
}

@(private)
stdio_io_failure :: proc(err: os.Error) -> Stdio_Io {
	if stdio_error_again(err) { return .Again }
	return .Failed
}

// stdio_await_readable blocks until file has data or reaches end of stream, or
// until stop becomes readable, which wins.
@(require_results)
stdio_await_readable :: proc(file: ^os.File, stop: ^os.File) -> (stopped: bool, err: os.Error) {
	entries := [2]Stdio_Poll_Entry{{fd = stdio_fd(file), direction = .Read}, {fd = stdio_fd(stop), direction = .Read}}
	stdio_poll(entries[:], {}, false) or_return
	return entries[1].ready, nil
}

// SIGPIPE is process-wide, but the stdio transport is not. These fields hold the
// saved disposition while at least one stdio server is running. The lock makes
// concurrent starts and stops agree on which one owns the restore.
@(private)
stdio_sigpipe_mutex: sync.Mutex
@(private)
stdio_sigpipe_users: int
@(private)
stdio_sigpipe_previous: Stdio_Signal_State
@(private)
stdio_sigpipe_saved: bool

// stdio_sigpipe_acquire makes a pipe write report EPIPE instead of terminating the
// process, and saves the disposition that was in force before the first stdio server.
@(require_results)
stdio_sigpipe_acquire :: proc() -> os.Error {
	sync.mutex_guard(&stdio_sigpipe_mutex)
	if stdio_sigpipe_users == 0 {
		stdio_sigpipe_ignore(&stdio_sigpipe_previous) or_return
		stdio_sigpipe_saved = true
	}
	stdio_sigpipe_users += 1
	return nil
}

// stdio_sigpipe_release restores the process disposition when the last stdio server
// stops. A failed restore is left to the process owner; the transport must not keep
// a stale reference count and prevent a later owner from trying again.
stdio_sigpipe_release :: proc() {
	sync.mutex_guard(&stdio_sigpipe_mutex)
	if stdio_sigpipe_users == 0 { return }
	stdio_sigpipe_users -= 1
	if stdio_sigpipe_users != 0 || !stdio_sigpipe_saved { return }
	stdio_sigpipe_restore(&stdio_sigpipe_previous)
	stdio_sigpipe_saved = false
}

// stdio_child_poll reaps the child if it has finished, and reports whether it is
// gone. It never blocks.
stdio_child_poll :: proc(child: ^Stdio_Child) -> bool {
	if child.reaped { return true }
	child.reaped = stdio_child_wait(child.pid, false) == .Exited
	return child.reaped
}

// stdio_child_reap blocks until the child is reaped.
stdio_child_reap :: proc(child: ^Stdio_Child) {
	if child.reaped { return }
	for {
		#partial switch stdio_child_wait(child.pid, true) {
		case .Exited:
			child.reaped = true
			return
		case .Interrupted:
		case:
			return
		}
	}
}

// stdio_child_await blocks until the child exits or deadline passes, and reaps it
// if it exited.
stdio_child_await :: proc(child: ^Stdio_Child, deadline: time.Tick) {
	if !child.exit.open { return }
	for !stdio_child_poll(child) && time.tick_diff(time.tick_now(), deadline) > 0 {
		entries := [1]Stdio_Poll_Entry{{fd = stdio_exit_watch_fd(child.exit), direction = .Read}}
		if stdio_poll(entries[:], deadline, true) != nil { return }
	}
}

// stdio_terminate_group asks the whole tree to stop, waits up to the grace period
// for the server to exit, then kills whatever of the group is left and reaps the
// server. A server that ignores SIGTERM is why the escalation exists; the server's
// own children are why the signals go to the group.
stdio_terminate_group :: proc(child: ^Stdio_Child) {
	if child.pid <= 0 { return }
	// The child is awaited and reaped below whatever these signals did, so a signal
	// that cannot be delivered changes nothing.
	stdio_signal(child.pid, .Terminate, true)
	stdio_child_await(child, time.tick_add(time.tick_now(), STDIO_KILL_GRACE))
	stdio_signal(child.pid, .Kill, true)
	if !child.reaped { stdio_signal(child.pid, .Kill, false) }
	stdio_child_reap(child)
}

// Stdio_Wait is what ended a wait on a pipe end.
Stdio_Wait :: enum {
	Ready,
	// Server_Gone means the pipe is not ready and the server has exited.
	Server_Gone,
	Stopped,
	Failed,
}

// stdio_wait sleeps until a pipe end is ready, the server exits, the control's wake
// is signalled, or its deadline passes. stop says why a Stopped wait ended, and err
// why a Failed one did.
@(require_results)
stdio_wait :: proc(file: ^os.File, direction: Stdio_Direction, child: ^Stdio_Child, control: Control) -> (result: Stdio_Wait, stop: Stop, err: os.Error) {
	for {
		if stop = control_stop(control); stop != .None { return .Stopped, stop, nil }
		entries: [STDIO_POLL_MAX]Stdio_Poll_Entry
		entries[0] = {
			fd        = stdio_fd(file),
			direction = direction,
		}
		count := 1
		if child.exit.open {
			entries[count] = {
				fd = stdio_exit_watch_fd(child.exit),
			}
			count += 1
		}
		if control.wake != nil {
			entries[count] = {
				fd = stdio_fd(control.wake),
			}
			count += 1
		}
		if err = stdio_poll(entries[:count], control.deadline_at, control.has_deadline); err != nil { return .Failed, .None, err }
		if entries[0].ready { return .Ready, .None, nil }
		if stdio_child_poll(child) { return .Server_Gone, .None, nil }
	}
}

// stdio_alloc_vectors builds the nil-terminated argv and envp vectors a spawn
// needs. It is called before the fork, where allocating is still safe, and the
// result is released with stdio_destroy_vectors.
@(require_results)
stdio_alloc_vectors :: proc(
	name: string,
	arguments: []string,
	environment: []Environment_Entry,
	allocator: mem.Allocator,
) -> (
	argv: []cstring,
	envp: []cstring,
	ok: bool,
) {
	argument_vector: []cstring
	environment_vector: []cstring
	failed := true
	defer if failed { stdio_destroy_vectors(argument_vector, environment_vector, allocator) }

	vectors_error: mem.Allocator_Error
	argument_vector, vectors_error = make([]cstring, len(arguments) + 2, allocator)
	if vectors_error != nil { return nil, nil, false }
	argument_vector[0], ok = strings_clone_cstring(name, allocator)
	if !ok { return nil, nil, false }
	for argument, index in arguments {
		value: cstring
		value, ok = strings_clone_cstring(argument, allocator)
		if !ok { return nil, nil, false }
		argument_vector[index + 1] = value
	}
	argument_vector[len(arguments) + 1] = nil

	environment_vector, vectors_error = make([]cstring, len(environment) + 1, allocator)
	if vectors_error != nil { return nil, nil, false }
	for entry, index in environment {
		pair, pair_error := strings.concatenate({entry.name, "=", entry.value}, allocator)
		if pair_error != nil { return nil, nil, false }
		value: cstring
		value, ok = strings_clone_cstring(pair, allocator)
		delete(pair, allocator)
		if !ok { return nil, nil, false }
		environment_vector[index] = value
	}
	environment_vector[len(environment)] = nil
	failed = false
	return argument_vector, environment_vector, true
}

@(private, require_results)
strings_clone_cstring :: proc(value: string, allocator: mem.Allocator) -> (cstring, bool) {
	text, err := strings.clone_to_cstring(value, allocator)
	return text, err == nil
}

stdio_destroy_vectors :: proc(argv, envp: []cstring, allocator: mem.Allocator) {
	for value in argv { delete(value, allocator) }
	delete(argv, allocator)
	for value in envp { delete(value, allocator) }
	delete(envp, allocator)
}
