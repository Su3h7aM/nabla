#+build linux
package agent

import "core:os"
import "core:sys/linux"

// TOOL_POLL_MAX is the most descriptors one wait takes, the largest set any caller builds.
@(private = "file")
TOOL_POLL_MAX :: 8

// The parent may die before prctl, so check its identity after installing the signal.
@(private = "file")
tool_child_bind_parent :: proc "contextless" (parent_pid: linux.Pid) -> bool {
	PR_SET_PDEATHSIG :: 1
	return linux.prctl(PR_SET_PDEATHSIG, uint(linux.Signal.SIGKILL), 0, 0, 0) == .NONE && linux.getppid() == parent_pid
}

// tool_fork_exec forks and runs exec in a new process group, returning the child's pid.
// Odin's os.process_start cannot do this: it has no pre-exec hook, so the group has to be
// made by the child itself. Between fork and exec the child makes only raw system calls:
// it allocates, locks, and logs nothing, and every failure leaves through exit_group, which
// runs no atexit handler and flushes no stdio. A failed exec writes one errno byte to
// exec.report. The descriptors of exec must close on exec, as those of os.pipe do.
@(private, require_results)
tool_fork_exec :: proc(exec: Tool_Exec) -> (pid: int, err: os.Error) {
	input, output, errors, report := linux.Fd(exec.input), linux.Fd(exec.output), linux.Fd(exec.errors), linux.Fd(exec.report)
	argv, envp, directory := raw_data(exec.argv), raw_data(exec.envp), exec.directory
	parent_pid := linux.getpid()

	child, fork_errno := linux.fork()
	if fork_errno != .NONE { return 0, os.Platform_Error(fork_errno) }
	if child == 0 {
		if linux.setpgid(0, 0) != .NONE { linux.exit_group(TOOL_CHILD_SETUP_FAILED) }
		if exec.parent_death && !tool_child_bind_parent(parent_pid) { linux.exit_group(TOOL_CHILD_SETUP_FAILED) }
		if input >= 0 {
			if _, dup_errno := linux.dup2(input, 0); dup_errno != .NONE { linux.exit_group(TOOL_CHILD_SETUP_FAILED) }
		} else {
			_ = linux.close(0)
		}
		if _, dup_errno := linux.dup2(output, 1); dup_errno != .NONE { linux.exit_group(TOOL_CHILD_SETUP_FAILED) }
		if _, dup_errno := linux.dup2(errors, 2); dup_errno != .NONE { linux.exit_group(TOOL_CHILD_SETUP_FAILED) }
		if linux.chdir(directory) != .NONE { linux.exit_group(TOOL_CHILD_SETUP_FAILED) }
		exec_errno := linux.execve(argv[0], argv, envp)
		reported := [1]u8{u8(exec_errno)}
		_, _ = linux.write(report, reported[:])
		linux.exit_group(TOOL_CHILD_EXEC_FAILED)
	}
	return int(child), nil
}

// tool_exit_watch_open watches the child pid, which must not have been reaped yet.
@(private)
tool_exit_watch_open :: proc(pid: int) -> (watch: Tool_Exit_Watch, err: os.Error) {
	fd, errno := linux.pidfd_open(linux.Pid(pid), {})
	if errno != .NONE { return {}, os.Platform_Error(errno) }
	return {fd = Tool_Fd(fd), open = true}, nil
}

@(private)
tool_exit_watch_close :: proc(watch: ^Tool_Exit_Watch) {
	if watch.open { _ = linux.close(linux.Fd(watch.fd)) }
	watch^ = {}
}

// tool_poll_wait waits up to timeout_ms milliseconds, or without end when it is negative,
// for one of fds to become readable, and sets ready on each that did. interrupted reports a
// signal that ended the wait early, which leaves the caller to wait again.
@(private, require_results)
tool_poll_wait :: proc(fds: []Tool_Poll, timeout_ms: i32) -> (interrupted: bool, err: os.Error) {
	if len(fds) > TOOL_POLL_MAX { return false, os.Platform_Error(.EINVAL) }
	entries: [TOOL_POLL_MAX]linux.Poll_Fd
	for entry, index in fds {entries[index] = {
			fd     = linux.Fd(entry.fd),
			events = {.IN},
		}}
	_, errno := linux.poll(entries[:len(fds)], timeout_ms)
	if errno == .EINTR { return true, nil }
	if errno != .NONE { return false, os.Platform_Error(errno) }
	for &entry, index in fds { entry.ready = entries[index].revents != {} }
	return false, nil
}

// tool_child_wait reaps the child pid when it has finished, without blocking unless block
// is set. exited is false for a child a signal ended. A wait a signal interrupted is
// repeated.
@(private)
tool_child_wait :: proc(pid: int, block: bool) -> (wait: Tool_Wait, exited: bool, exit_code: int) {
	options: linux.Wait_Options
	if !block { options = {.WNOHANG} }
	for {
		status: u32
		reaped, errno := linux.wait4(linux.Pid(pid), &status, options, nil)
		#partial switch errno {
		case .NONE:
			if int(reaped) != pid { return .Running, false, 0 }
			exited = linux.WIFEXITED(status)
			if exited { exit_code = int(linux.WEXITSTATUS(status)) }
			return .Finished, exited, exit_code
		case .ECHILD:
			return .Gone, false, 0
		case .EINTR:
			if !block { return .Running, false, 0 }
		case:
			return .Running, false, 0
		}
	}
}

// tool_group_signal signals the process group led by pid and reports whether any member
// received it.
@(private)
tool_group_signal :: proc(pid: int, signal: Tool_Group_Signal) -> bool {
	number := linux.Signal.SIGTERM if signal == .Terminate else linux.Signal.SIGKILL
	return linux.kill(-linux.Pid(pid), number) == .NONE
}

// tool_error_again reports whether err is a read that only needs repeating: the descriptor
// was not ready or a signal interrupted the call.
@(private)
tool_error_again :: proc(err: os.Error) -> bool {
	errno, is_errno := err.(os.Platform_Error)
	return is_errno && (errno == .EAGAIN || errno == .EINTR)
}
