#+build linux
package mcp

import "core:os"
import "core:sys/linux"

// Stdio_Signal_State is the saved disposition of SIGPIPE.
@(private)
Stdio_Signal_State :: linux.Sig_Action

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
