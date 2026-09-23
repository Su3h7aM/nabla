package mcp

import "core:mem"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:time"

// STDIO_KILL_GRACE bounds how long a server may take to exit on SIGTERM before
// its whole process group is killed outright.
STDIO_KILL_GRACE :: 500 * time.Millisecond

// Stdio_Pipes is the parent's end of a spawned server's three streams.
Stdio_Pipes :: struct {
	stdin:  linux.Fd,
	stdout: linux.Fd,
	stderr: linux.Fd,
}

// Stdio_Child tracks one spawned server. The exit status is recorded the first
// time it is observed, so a caller that polls cannot lose it.
Stdio_Child :: struct {
	pid:    int,
	reaped: bool,
	status: u32,
}

// stdio_spawn starts name in its own process group with a pipe on each standard
// stream. argv and envp are already-built, nil-terminated vectors, and directory
// is nil to inherit the parent's.
//
// Odin's os.process_start cannot express this: it has no pre-exec hook, so the
// child cannot create its own process group before it execs, and a group kill
// would then miss the server's descendants.
//
// The child calls nothing that allocates, locks, logs, or enters the runtime:
// every call below is a raw syscall, and every failure path leaves through
// exit_group, which runs no atexit handler and flushes no stdio. The harness may
// have other threads, so none of that would be safe after a fork.
stdio_spawn :: proc(name: cstring, argv: [^]cstring, envp: [^]cstring, directory: cstring) -> (pipes: Stdio_Pipes, child: Stdio_Child, ok: bool) {
	stdin_pipe, stdout_pipe, stderr_pipe, setup: [2]linux.Fd
	if linux.pipe2(&stdin_pipe, {.CLOEXEC}) != .NONE { return {}, {}, false }
	if linux.pipe2(&stdout_pipe, {.CLOEXEC}) != .NONE {
		stdio_close_pair(stdin_pipe)
		return {}, {}, false
	}
	if linux.pipe2(&stderr_pipe, {.CLOEXEC}) != .NONE {
		stdio_close_pair(stdin_pipe)
		stdio_close_pair(stdout_pipe)
		return {}, {}, false
	}
	// The setup pipe is close-on-exec, so a successful exec closes it and the
	// parent reads end of stream. A byte arriving instead is the one thing a failed
	// exec can report.
	if linux.pipe2(&setup, {.CLOEXEC}) != .NONE {
		stdio_close_pair(stdin_pipe)
		stdio_close_pair(stdout_pipe)
		stdio_close_pair(stderr_pipe)
		return {}, {}, false
	}

	pid, fork_errno := linux.fork()
	if fork_errno != .NONE {
		stdio_close_pair(stdin_pipe)
		stdio_close_pair(stdout_pipe)
		stdio_close_pair(stderr_pipe)
		stdio_close_pair(setup)
		return {}, {}, false
	}
	if pid == 0 {
		if linux.setpgid(0, 0) != .NONE { linux.exit_group(1) }
		_ = linux.close(stdin_pipe[1])
		if _, dup_errno := linux.dup2(stdin_pipe[0], 0); dup_errno != .NONE { linux.exit_group(1) }
		_ = linux.close(stdin_pipe[0])
		_ = linux.close(stdout_pipe[0])
		if _, dup_errno := linux.dup2(stdout_pipe[1], 1); dup_errno != .NONE { linux.exit_group(1) }
		_ = linux.close(stdout_pipe[1])
		_ = linux.close(stderr_pipe[0])
		if _, dup_errno := linux.dup2(stderr_pipe[1], 2); dup_errno != .NONE { linux.exit_group(1) }
		_ = linux.close(stderr_pipe[1])
		_ = linux.close(setup[0])
		if directory != nil && linux.chdir(directory) != .NONE { linux.exit_group(1) }
		exec_errno := linux.execve(name, argv, envp)
		code := [1]u8{u8(exec_errno)}
		_, _ = linux.write(setup[1], code[:])
		linux.exit_group(127)
	}

	_ = linux.close(stdin_pipe[0])
	_ = linux.close(stdout_pipe[1])
	_ = linux.close(stderr_pipe[1])
	_ = linux.close(setup[1])

	report: [1]u8
	reported, _ := linux.read(setup[0], report[:])
	_ = linux.close(setup[0])
	if reported > 0 {
		spawned := Stdio_Child {
			pid = int(pid),
		}
		_ = linux.close(stdin_pipe[1])
		_ = linux.close(stdout_pipe[0])
		_ = linux.close(stderr_pipe[0])
		stdio_terminate_group(&spawned)
		return {}, {}, false
	}

	return Stdio_Pipes{stdin = stdin_pipe[1], stdout = stdout_pipe[0], stderr = stderr_pipe[0]}, Stdio_Child{pid = int(pid)}, true
}

@(private)
stdio_close_pair :: proc(pair: [2]linux.Fd) {
	_ = linux.close(pair[0])
	_ = linux.close(pair[1])
}

// SIGPIPE is process-wide, but the stdio transport is not. These fields hold the
// saved disposition while at least one stdio server is running. The lock makes
// concurrent starts and stops agree on which one owns the restore.
stdio_sigpipe_mutex: sync.Mutex
stdio_sigpipe_users: int
stdio_sigpipe_previous: linux.Sig_Action
stdio_sigpipe_saved: bool

// stdio_sigpipe_acquire makes a pipe write report EPIPE instead of terminating the
// process, and saves the disposition that was in force before the first stdio server.
stdio_sigpipe_acquire :: proc(previous: ^linux.Sig_Action) -> bool {
	sync.mutex_lock(&stdio_sigpipe_mutex)
	defer sync.mutex_unlock(&stdio_sigpipe_mutex)
	if stdio_sigpipe_users == 0 {
		action := linux.Sig_Action {
			special = .SIG_IGN,
		}
		old: linux.Sig_Action
		if linux.rt_sigaction(.SIGPIPE, &action, &old) != .NONE { return false }
		stdio_sigpipe_previous = old
		stdio_sigpipe_saved = true
		previous^ = old
	}
	stdio_sigpipe_users += 1
	return true
}

// stdio_sigpipe_release restores the process disposition when the last stdio server
// stops. A failed restore is left to the process owner; the transport must not keep
// a stale reference count and prevent a later owner from trying again.
stdio_sigpipe_release :: proc() {
	sync.mutex_lock(&stdio_sigpipe_mutex)
	defer sync.mutex_unlock(&stdio_sigpipe_mutex)
	if stdio_sigpipe_users == 0 { return }
	stdio_sigpipe_users -= 1
	if stdio_sigpipe_users != 0 || !stdio_sigpipe_saved { return }
	_ = linux.rt_sigaction(.SIGPIPE, &stdio_sigpipe_previous, nil)
	stdio_sigpipe_saved = false
}

// stdio_set_nonblocking makes a pipe end usable from a poll loop, so reading and
// writing can observe cancellation instead of blocking through it.
stdio_set_nonblocking :: proc(fd: linux.Fd) -> bool {
	flags, get_errno := linux.fcntl_getfl(fd, linux.F_GETFL)
	if get_errno != .NONE { return false }
	return linux.fcntl_setfl(fd, linux.F_SETFL, flags + {.NONBLOCK}) == .NONE
}

// stdio_child_poll reaps the child if it has finished, and reports whether it is
// gone. It never blocks.
stdio_child_poll :: proc(child: ^Stdio_Child) -> bool {
	if child.reaped { return true }
	status: u32
	reaped, wait_errno := linux.wait4(linux.Pid(child.pid), &status, {.WNOHANG}, nil)
	if reaped == linux.Pid(child.pid) {
		child.reaped = true
		child.status = status
		return true
	}
	// No child left to wait for: it was already reaped.
	if wait_errno == .ECHILD { child.reaped = true }
	return child.reaped
}

// stdio_child_reap blocks until the child is reaped.
stdio_child_reap :: proc(child: ^Stdio_Child) {
	if child.reaped { return }
	status: u32
	for {
		reaped, wait_errno := linux.wait4(linux.Pid(child.pid), &status, {}, nil)
		if reaped == linux.Pid(child.pid) { break }
		if wait_errno == .ECHILD {
			child.reaped = true
			return
		}
		if wait_errno != .EINTR { return }
	}
	child.reaped = true
	child.status = status
}

// stdio_terminate_group asks the whole tree to stop, escalates to SIGKILL once the
// grace period expires, and reaps the direct child. A server that ignores SIGTERM
// is why the escalation exists; the server's own children are why the group does.
stdio_terminate_group :: proc(child: ^Stdio_Child) {
	if child.pid <= 0 { return }
	if stdio_group_gone(child.pid) { return }
	stdio_signal_group(child.pid, false)
	grace := time.tick_add(time.tick_now(), STDIO_KILL_GRACE)
	for time.tick_since(grace) < 0 {
		_ = stdio_child_poll(child)
		if stdio_group_gone(child.pid) { return }
		time.sleep(5 * time.Millisecond)
	}
	stdio_signal_group(child.pid, true)
	stdio_child_reap(child)
}

@(private)
stdio_group_gone :: proc(pid: int) -> bool {
	if pid <= 0 { return true }
	return linux.kill(linux.Pid(-pid), linux.Signal(0)) == .ESRCH
}

@(private)
stdio_signal_group :: proc(pid: int, kill: bool) {
	signal: linux.Signal = .SIGKILL if kill else .SIGTERM
	_ = linux.kill(linux.Pid(-pid), signal)
}

// stdio_wait waits until fd is ready for the requested events. It reports a stop
// rather than blocking through one, and treats a poll error as "not ready" so the
// following read or write reports the real failure.
stdio_wait :: proc(fd: linux.Fd, events: linux.Fd_Poll_Events, control: Control) -> (ready: bool, stop: Stop) {
	for {
		if stop = control_stop(control); stop != .None { return false, stop }
		fds := [1]linux.Poll_Fd{{fd = fd, events = events}}
		count, poll_errno := linux.poll(fds[:], STDIO_POLL_SLICE_MS)
		if poll_errno == .EINTR { continue }
		if poll_errno != .NONE { return false, .None }
		if count > 0 { return true, .None }
	}
}

// Stdio_Poll_Slice is how long one poll waits before re-checking cancellation and
// the deadline. A short slice is what keeps a cancel prompt.
STDIO_POLL_SLICE_MS :: 20

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
