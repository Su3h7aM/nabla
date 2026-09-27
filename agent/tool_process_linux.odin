#+build linux
package agent

import "core:os"
import "core:sys/linux"
import "core:sys/posix"

// The parent may die before prctl, so check its identity after installing the signal.
@(private)
tool_child_bind_parent :: proc "contextless" (parent_pid: posix.pid_t) -> bool {
	PR_SET_PDEATHSIG :: 1
	return linux.prctl(PR_SET_PDEATHSIG, uint(posix.SIGKILL), 0, 0, 0) == .NONE && posix.getppid() == parent_pid
}

// Tool_Exit_Watch is a descriptor that becomes readable once a child exits, so a
// wait for the child joins the same poll as its pipes. Its zero value watches
// nothing.
Tool_Exit_Watch :: struct {
	fd:   linux.Fd,
	open: bool,
}

// tool_exit_watch_open watches the child pid, which must not have been reaped yet.
@(private)
tool_exit_watch_open :: proc(pid: int) -> (watch: Tool_Exit_Watch, err: os.Error) {
	fd, errno := linux.pidfd_open(linux.Pid(pid), {})
	if errno != .NONE { return {}, os.Platform_Error(errno) }
	return {fd = linux.Fd(fd), open = true}, nil
}

@(private)
tool_exit_watch_close :: proc(watch: ^Tool_Exit_Watch) {
	if watch.open { _ = linux.close(watch.fd) }
	watch^ = {}
}

@(private)
tool_exit_watch_fd :: proc(watch: Tool_Exit_Watch) -> posix.FD {
	return posix.FD(watch.fd)
}
