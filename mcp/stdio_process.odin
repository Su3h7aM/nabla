package mcp

import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
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

// stdio_errno is the calling thread's last POSIX error as an os.Error.
@(private)
stdio_errno :: proc() -> os.Error {
	return os.Platform_Error(i32(posix.errno()))
}

@(private)
stdio_fd :: proc(file: ^os.File) -> posix.FD {
	return posix.FD(os.fd(file))
}

// stdio_spawn starts name in its own process group with a pipe on each standard
// stream. argv and envp are already-built, nil-terminated vectors, and directory
// is nil to inherit the parent's. A failure reports the system's reason, including
// the reason exec gave when the program could not be run.
//
// Odin's os.process_start cannot express this: it has no pre-exec hook, so the
// child cannot create its own process group before it execs, and a group kill
// would then miss the server's descendants.
//
// The harness may have other threads, so between fork and exec the child makes
// only async-signal-safe calls: it allocates, locks, and logs nothing, and every
// failure leaves through _exit, which runs no atexit handler and flushes no stdio.
stdio_spawn :: proc(name: cstring, argv: [^]cstring, envp: [^]cstring, directory: cstring) -> (pipes: Stdio_Pipes, child: Stdio_Child, err: os.Error) {
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
	pid := posix.fork()
	if pid == -1 {
		err = stdio_errno()
		_ = os.close(setup_write)
		return
	}
	if pid == 0 {
		if posix.setpgid(0, 0) != .OK { posix._exit(STDIO_CHILD_SETUP_FAILED) }
		if posix.dup2(child_stdin, 0) == -1 { posix._exit(STDIO_CHILD_SETUP_FAILED) }
		if posix.dup2(child_stdout, 1) == -1 { posix._exit(STDIO_CHILD_SETUP_FAILED) }
		if posix.dup2(child_stderr, 2) == -1 { posix._exit(STDIO_CHILD_SETUP_FAILED) }
		if directory != nil && posix.chdir(directory) != .OK { posix._exit(STDIO_CHILD_SETUP_FAILED) }
		posix.execve(name, argv, envp)
		code := [1]u8{u8(posix.errno())}
		_ = posix.write(report_fd, &code[0], len(code))
		posix._exit(STDIO_CHILD_EXEC_FAILED)
	}
	_ = os.close(setup_write)

	spawned := Stdio_Child {
		pid = int(pid),
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
	_ = os.close(pipes.stdin)
	_ = os.close(pipes.stdout)
	_ = os.close(pipes.stderr)
}

// stdio_read reads what one pipe end holds into buffer.
stdio_read :: proc(file: ^os.File, buffer: []u8) -> (count: int, status: Stdio_Io) {
	n := posix.read(stdio_fd(file), raw_data(buffer), uint(len(buffer)))
	if n >= 0 { return n, .Ok }
	return 0, stdio_io_failure()
}

// stdio_write writes as much of data as one pipe end accepts.
stdio_write :: proc(file: ^os.File, data: []u8) -> (count: int, status: Stdio_Io) {
	n := posix.write(stdio_fd(file), raw_data(data), uint(len(data)))
	if n >= 0 { return n, .Ok }
	return 0, stdio_io_failure()
}

@(private)
stdio_io_failure :: proc() -> Stdio_Io {
	#partial switch posix.errno() {
	case .EAGAIN, .EINTR:
		return .Again
	}
	return .Failed
}

// stdio_poll blocks until one of fds is ready or the deadline passes, and never
// wakes on its own otherwise. A signal restarts the wait with the time left.
@(private)
stdio_poll :: proc(fds: []posix.pollfd, deadline: time.Tick, has_deadline: bool) -> os.Error {
	for {
		timeout: i32 = -1
		if has_deadline {
			remaining := time.tick_diff(time.tick_now(), deadline)
			timeout = remaining <= 0 ? 0 : i32(min((remaining + time.Millisecond - 1) / time.Millisecond, time.Duration(max(i32))))
		}
		if posix.poll(raw_data(fds), posix.nfds_t(len(fds)), timeout) != -1 { return nil }
		if posix.errno() != .EINTR { return stdio_errno() }
	}
}

// stdio_await_readable blocks until file has data or reaches end of stream, or
// until stop becomes readable, which wins.
stdio_await_readable :: proc(file: ^os.File, stop: ^os.File) -> (stopped: bool, err: os.Error) {
	fds := [2]posix.pollfd{{fd = stdio_fd(file), events = {.IN}}, {fd = stdio_fd(stop), events = {.IN}}}
	stdio_poll(fds[:], {}, false) or_return
	return fds[1].revents != {}, nil
}

// SIGPIPE is process-wide, but the stdio transport is not. These fields hold the
// saved disposition while at least one stdio server is running. The lock makes
// concurrent starts and stops agree on which one owns the restore.
@(private)
stdio_sigpipe_mutex: sync.Mutex
@(private)
stdio_sigpipe_users: int
@(private)
stdio_sigpipe_previous: posix.sigaction_t
@(private)
stdio_sigpipe_saved: bool

// stdio_sigpipe_acquire makes a pipe write report EPIPE instead of terminating the
// process, and saves the disposition that was in force before the first stdio server.
stdio_sigpipe_acquire :: proc() -> os.Error {
	sync.mutex_guard(&stdio_sigpipe_mutex)
	if stdio_sigpipe_users == 0 {
		action := posix.sigaction_t {
			sa_handler = auto_cast posix.SIG_IGN,
		}
		if posix.sigaction(.SIGPIPE, &action, &stdio_sigpipe_previous) != .OK { return stdio_errno() }
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
	_ = posix.sigaction(.SIGPIPE, &stdio_sigpipe_previous, nil)
	stdio_sigpipe_saved = false
}

// stdio_set_nonblocking makes a pipe end usable from a poll loop, so reading and
// writing can observe cancellation instead of blocking through it.
stdio_set_nonblocking :: proc(file: ^os.File) -> os.Error {
	fd := stdio_fd(file)
	flags := posix.fcntl(fd, .GETFL)
	if flags == -1 { return stdio_errno() }
	if posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK) == -1 { return stdio_errno() }
	return nil
}

// stdio_child_poll reaps the child if it has finished, and reports whether it is
// gone. It never blocks.
stdio_child_poll :: proc(child: ^Stdio_Child) -> bool {
	if child.reaped { return true }
	status: i32
	reaped := posix.waitpid(posix.pid_t(child.pid), &status, {.NOHANG})
	// No child left to wait for means it was already reaped.
	if int(reaped) == child.pid || (reaped == -1 && posix.errno() == .ECHILD) { child.reaped = true }
	return child.reaped
}

// stdio_child_reap blocks until the child is reaped.
stdio_child_reap :: proc(child: ^Stdio_Child) {
	if child.reaped { return }
	status: i32
	for {
		if int(posix.waitpid(posix.pid_t(child.pid), &status, {})) == child.pid { break }
		errno := posix.errno()
		if errno == .ECHILD { break }
		if errno != .EINTR { return }
	}
	child.reaped = true
}

// stdio_child_await blocks until the child exits or deadline passes, and reaps it
// if it exited.
stdio_child_await :: proc(child: ^Stdio_Child, deadline: time.Tick) {
	if !child.exit.open { return }
	for !stdio_child_poll(child) && time.tick_diff(time.tick_now(), deadline) > 0 {
		fds := [1]posix.pollfd{{fd = stdio_exit_watch_fd(child.exit), events = {.IN}}}
		if stdio_poll(fds[:], deadline, true) != nil { return }
	}
}

// stdio_terminate_group asks the whole tree to stop, waits up to the grace period
// for the server to exit, then kills whatever of the group is left and reaps the
// server. A server that ignores SIGTERM is why the escalation exists; the server's
// own children are why the signals go to the group.
stdio_terminate_group :: proc(child: ^Stdio_Child) {
	if child.pid <= 0 { return }
	group := posix.pid_t(child.pid)
	_ = posix.killpg(group, .SIGTERM)
	stdio_child_await(child, time.tick_add(time.tick_now(), STDIO_KILL_GRACE))
	_ = posix.killpg(group, .SIGKILL)
	if !child.reaped { _ = posix.kill(group, .SIGKILL) }
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
stdio_wait :: proc(file: ^os.File, direction: Stdio_Direction, child: ^Stdio_Child, control: Control) -> (result: Stdio_Wait, stop: Stop, err: os.Error) {
	for {
		if stop = control_stop(control); stop != .None { return .Stopped, stop, nil }
		fds: [3]posix.pollfd
		fds[0] = {
			fd     = stdio_fd(file),
			events = {.IN} if direction == .Read else {.OUT},
		}
		count := 1
		if child.exit.open {
			fds[count] = {
				fd     = stdio_exit_watch_fd(child.exit),
				events = {.IN},
			}
			count += 1
		}
		if control.wake != nil {
			fds[count] = {
				fd     = stdio_fd(control.wake),
				events = {.IN},
			}
			count += 1
		}
		if err = stdio_poll(fds[:count], control.deadline_at, control.has_deadline); err != nil { return .Failed, .None, err }
		if fds[0].revents != {} { return .Ready, .None, nil }
		if stdio_child_poll(child) { return .Server_Gone, .None, nil }
	}
}

// stdio_alloc_vectors builds the nil-terminated argv and envp vectors a spawn
// needs. It is called before the fork, where allocating is still safe, and the
// result is released with stdio_destroy_vectors.
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
	argv = make([]cstring, len(arguments) + 2, allocator)
	argv[0], ok = strings_clone_cstring(name, allocator)
	if !ok { return nil, nil, false }
	for argument, index in arguments {
		value: cstring
		value, ok = strings_clone_cstring(argument, allocator)
		if !ok { return nil, nil, false }
		argv[index + 1] = value
	}
	argv[len(arguments) + 1] = nil

	envp = make([]cstring, len(environment) + 1, allocator)
	for entry, index in environment {
		pair := strings.concatenate({entry.name, "=", entry.value}, allocator)
		value: cstring
		value, ok = strings_clone_cstring(pair, allocator)
		delete(pair, allocator)
		if !ok { return nil, nil, false }
		envp[index] = value
	}
	envp[len(environment)] = nil
	return argv, envp, true
}

@(private)
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
