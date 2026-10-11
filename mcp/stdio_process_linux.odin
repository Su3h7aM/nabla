#+build linux
package mcp

import "core:os"
import "core:sys/linux"

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
