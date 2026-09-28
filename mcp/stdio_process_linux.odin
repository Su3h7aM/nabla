#+build linux
package mcp

import "core:os"
import "core:sys/linux"
import "core:sys/posix"

// Stdio_Exit_Watch is a descriptor that becomes readable once a server exits, so a
// wait for the server joins the same poll as its pipes. Its zero value watches
// nothing.
Stdio_Exit_Watch :: struct {
	fd:   linux.Fd,
	open: bool,
}

// stdio_exit_watch_open watches the child pid, which must not have been reaped yet.
@(private)
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
stdio_exit_watch_fd :: proc(watch: Stdio_Exit_Watch) -> posix.FD {
	return posix.FD(watch.fd)
}
