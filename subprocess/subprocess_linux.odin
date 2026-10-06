#+build linux
package subprocess

import "core:os"
import "core:sys/linux"

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

// The parent may die before prctl, so check its identity after installing the signal.
@(private)
child_bind_parent :: proc "contextless" (parent_pid: linux.Pid) -> bool {
	PR_SET_PDEATHSIG :: 1
	return linux.prctl(PR_SET_PDEATHSIG, uint(linux.Signal.SIGKILL), 0, 0, 0) == .NONE && linux.getppid() == parent_pid
}

// fork_exec forks and runs exec in a new process group, returning the child's pid.
@(private, require_results)
fork_exec :: proc(exec: Exec) -> (pid: int, err: os.Error) {
	input, output, errors, report := linux.Fd(exec.input), linux.Fd(exec.output), linux.Fd(exec.errors), linux.Fd(exec.report)
	argv := exec.argv
	parent_pid := linux.getpid()

	child, fork_errno := linux.fork()
	if fork_errno != .NONE { return 0, os.Platform_Error(fork_errno) }
	if child == 0 {
		if linux.setpgid(0, 0) != .NONE { linux.exit_group(CHILD_SETUP_FAILED) }
		if exec.parent_death && !child_bind_parent(parent_pid) { linux.exit_group(CHILD_SETUP_FAILED) }
		if input >= 0 {
			if _, dup_errno := linux.dup2(input, 0); dup_errno != .NONE { linux.exit_group(CHILD_SETUP_FAILED) }
		} else {
			_ = linux.close(0)
		}
		if _, dup_errno := linux.dup2(output, 1); dup_errno != .NONE { linux.exit_group(CHILD_SETUP_FAILED) }
		if _, dup_errno := linux.dup2(errors, 2); dup_errno != .NONE { linux.exit_group(CHILD_SETUP_FAILED) }
		if exec.directory != nil && linux.chdir(exec.directory) != .NONE { linux.exit_group(CHILD_SETUP_FAILED) }
		exec_errno := linux.execve(argv[0], argv, exec.envp)
		reported := [1]u8{u8(exec_errno)}
		// The parent reads this errno, or an end of stream if the write failed, and reports a
		// start failure either way.
		_, _ = linux.write(report, reported[:])
		linux.exit_group(CHILD_EXEC_FAILED)
	}
	return int(child), nil
}

// exit_watch_open returns a descriptor that becomes readable when the child pid exits. The child
// must not have been reaped yet. A pidfd closes on exec by definition, so no other child
// inherits it.
@(private)
exit_watch_open :: proc(pid: int) -> (watch: Fd, err: os.Error) {
	pidfd, errno := linux.pidfd_open(linux.Pid(pid), {})
	if errno != .NONE { return FD_NONE, os.Platform_Error(errno) }
	return Fd(pidfd), nil
}

@(private)
exit_watch_close :: proc(watch: Fd) {
	// The watch is released for good, so a close that fails changes nothing.
	_ = linux.close(linux.Fd(watch))
}

// poll_wait waits up to timeout_ms milliseconds, or without end when it is negative, and sets
// ready on each entry that is. interrupted reports a signal that ended the wait early.
@(private, require_results)
poll_wait :: proc(entries: []Poll, timeout_ms: i32) -> (interrupted: bool, err: os.Error) {
	if len(entries) > POLL_MAX { return false, os.Platform_Error(.EINVAL) }
	fds: [POLL_MAX]linux.Poll_Fd
	for entry, index in entries {
		fds[index] = {
			fd     = linux.Fd(entry.fd),
			events = {.IN} if entry.direction == .Read else {.OUT},
		}
	}
	_, errno := linux.poll(fds[:len(entries)], timeout_ms)
	if errno == .EINTR { return true, nil }
	if errno != .NONE { return false, os.Platform_Error(errno) }
	for &entry, index in entries { entry.ready = fds[index].revents != {} }
	return false, nil
}

// child_wait reaps the child pid when it has finished, without blocking unless block is set.
// exited is false for a child a signal ended. A wait a signal interrupted is repeated.
@(private)
child_wait :: proc(pid: int, block: bool) -> (wait: Wait, exited: bool, exit_code: int) {
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

// group_signal signals the process group led by pid and reports whether any member received it.
@(private)
group_signal :: proc(pid: int, signal: Group_Signal) -> bool {
	number := linux.Signal.SIGTERM if signal == .Terminate else linux.Signal.SIGKILL
	return linux.kill(-linux.Pid(pid), number) == .NONE
}

// error_again reports whether err from a read or write only needs repeating: the descriptor was
// not ready or a signal interrupted the call.
error_again :: proc(err: os.Error) -> bool {
	errno, is_errno := err.(os.Platform_Error)
	return is_errno && (errno == .EAGAIN || errno == .EINTR)
}
