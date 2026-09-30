#+build linux
package mcp

import "core:os"
import "core:sys/linux"
import "core:time"

// Stdio_Exit_Watch is a descriptor that becomes readable once a server exits, so a
// wait for the server joins the same poll as its pipes. Its zero value watches
// nothing.
Stdio_Exit_Watch :: struct {
	fd:   linux.Fd,
	open: bool,
}

// Stdio_Signal_State is the saved disposition of SIGPIPE.
@(private)
Stdio_Signal_State :: linux.Sig_Action

// stdio_exit_watch_open watches the child pid, which must not have been reaped yet.
@(private, require_results)
stdio_exit_watch_open :: proc(pid: int) -> (watch: Stdio_Exit_Watch, err: os.Error) {
	fd, errno := linux.pidfd_open(linux.Pid(pid), {})
	if errno != .NONE { return {}, os.Platform_Error(errno) }
	return {fd = linux.Fd(fd), open = true}, nil
}

@(private)
stdio_exit_watch_close :: proc(watch: ^Stdio_Exit_Watch) {
	if watch.open {
		// The watch is released for good, so a close that fails changes nothing.
		_ = linux.close(watch.fd)
	}
	watch^ = {}
}

@(private)
stdio_exit_watch_fd :: proc(watch: Stdio_Exit_Watch) -> Stdio_Fd {
	return Stdio_Fd(watch.fd)
}

// stdio_fork_exec starts name in its own process group with the four descriptors
// installed as standard input, output, and error and as the exec report pipe. A
// failed exec writes its errno byte to report. It returns the child's pid.
//
// The harness may have other threads, so between fork and exec the child makes only
// raw system calls, allocates nothing, and leaves through exit_group.
@(private, require_results)
stdio_fork_exec :: proc(
	name: cstring,
	argv: [^]cstring,
	envp: [^]cstring,
	directory: cstring,
	child_stdin, child_stdout, child_stderr, report: Stdio_Fd,
) -> (
	pid: int,
	err: os.Error,
) {
	child, fork_errno := linux.fork()
	if fork_errno != .NONE { return 0, os.Platform_Error(fork_errno) }
	if child == 0 {
		if linux.setpgid(0, 0) != .NONE { linux.exit_group(STDIO_CHILD_SETUP_FAILED) }
		if _, dup_errno := linux.dup2(linux.Fd(child_stdin), 0); dup_errno != .NONE { linux.exit_group(STDIO_CHILD_SETUP_FAILED) }
		if _, dup_errno := linux.dup2(linux.Fd(child_stdout), 1); dup_errno != .NONE { linux.exit_group(STDIO_CHILD_SETUP_FAILED) }
		if _, dup_errno := linux.dup2(linux.Fd(child_stderr), 2); dup_errno != .NONE { linux.exit_group(STDIO_CHILD_SETUP_FAILED) }
		if directory != nil && linux.chdir(directory) != .NONE { linux.exit_group(STDIO_CHILD_SETUP_FAILED) }
		exec_errno := linux.execve(name, argv, envp)
		code := [1]u8{u8(exec_errno)}
		// The parent reads this errno, or an end of stream if the write failed, and
		// reports a spawn failure either way.
		_, _ = linux.write(linux.Fd(report), code[:])
		linux.exit_group(STDIO_CHILD_EXEC_FAILED)
	}
	return int(child), nil
}

// stdio_error_again reports whether err from a read or write means nothing moved
// because the end was not ready or a signal interrupted the call.
@(private)
stdio_error_again :: proc(err: os.Error) -> bool {
	platform_error, is_platform := err.(os.Platform_Error)
	if !is_platform { return false }
	#partial switch linux.Errno(platform_error) {
	case .EAGAIN, .EINTR:
		return true
	}
	return false
}

// stdio_poll blocks until one of entries is ready or the deadline passes, and never
// wakes on its own otherwise. A signal restarts the wait with the time left.
@(private, require_results)
stdio_poll :: proc(entries: []Stdio_Poll_Entry, deadline: time.Tick, has_deadline: bool) -> os.Error {
	fds: [STDIO_POLL_MAX]linux.Poll_Fd
	assert(len(entries) <= STDIO_POLL_MAX)
	for entry, index in entries {
		fds[index] = {
			fd     = linux.Fd(entry.fd),
			events = {.IN} if entry.direction == .Read else {.OUT},
		}
	}
	for {
		timeout: i32 = -1
		if has_deadline {
			remaining := time.tick_diff(time.tick_now(), deadline)
			timeout = remaining <= 0 ? 0 : i32(min((remaining + time.Millisecond - 1) / time.Millisecond, time.Duration(max(i32))))
		}
		_, errno := linux.poll(fds[:len(entries)], timeout)
		#partial switch errno {
		case .NONE:
			for &entry, index in entries { entry.ready = fds[index].revents != {} }
			return nil
		case .EINTR:
		case:
			return os.Platform_Error(errno)
		}
	}
}

// stdio_sigpipe_ignore makes a pipe write report EPIPE instead of terminating the
// process, and saves the previous disposition in previous.
@(private, require_results)
stdio_sigpipe_ignore :: proc(previous: ^Stdio_Signal_State) -> os.Error {
	action := linux.Sig_Action {
		special = .SIG_IGN,
	}
	// On x86_64 rt_sigaction adds the restorer flag and sigreturn itself.
	if errno := linux.rt_sigaction(.SIGPIPE, &action, previous); errno != .NONE { return os.Platform_Error(errno) }
	return nil
}

// stdio_sigpipe_restore reinstates a disposition saved by stdio_sigpipe_ignore. A
// failed restore is left to the process owner.
@(private)
stdio_sigpipe_restore :: proc(previous: ^Stdio_Signal_State) {
	_ = linux.rt_sigaction(.SIGPIPE, previous, nil)
}

// stdio_set_nonblocking makes a pipe end usable from a poll loop, so reading and
// writing can observe cancellation instead of blocking through it.
@(private, require_results)
stdio_set_nonblocking :: proc(file: ^os.File) -> os.Error {
	fd := linux.Fd(os.fd(file))
	flags, get_errno := linux.fcntl_getfl(fd, .GETFL)
	if get_errno != .NONE { return os.Platform_Error(get_errno) }
	if set_errno := linux.fcntl_setfl(fd, .SETFL, flags + {.NONBLOCK}); set_errno != .NONE { return os.Platform_Error(set_errno) }
	return nil
}

// stdio_child_wait reaps the child pid if it has exited, blocking only when block
// is set.
@(private)
stdio_child_wait :: proc(pid: int, block: bool) -> Stdio_Child_Status {
	status: u32
	reaped, errno := linux.wait4(linux.Pid(pid), &status, {} if block else {.WNOHANG}, nil)
	// No child left to wait for means it was already reaped.
	if int(reaped) == pid || errno == .ECHILD { return .Exited }
	#partial switch errno {
	case .NONE:
		return .Running
	case .EINTR:
		return .Interrupted
	}
	return .Failed
}

// stdio_signal sends signal to the process pid, or to its whole process group.
// A signal that cannot be delivered is not reported.
@(private)
stdio_signal :: proc(pid: int, signal: Stdio_Signal, group: bool) {
	target := linux.Pid(pid)
	if group { target = -target }
	_ = linux.kill(target, .SIGTERM if signal == .Terminate else .SIGKILL)
}
