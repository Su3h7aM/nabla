#+build !linux
package mcp

import "core:io"
import "core:os"
import "core:time"

// Stdio_Exit_Watch has no backing on targets without a stdio backend. Its zero
// value watches nothing.
Stdio_Exit_Watch :: struct {
	open: bool,
}

@(private)
Stdio_Signal_State :: struct {}

@(private, require_results)
stdio_exit_watch_open :: proc(pid: int) -> (watch: Stdio_Exit_Watch, err: os.Error) {
	return {}, io.Error.Unsupported
}

@(private)
stdio_exit_watch_close :: proc(watch: ^Stdio_Exit_Watch) {
	watch^ = {}
}

@(private)
stdio_exit_watch_fd :: proc(watch: Stdio_Exit_Watch) -> Stdio_Fd {
	return 0
}

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
	return 0, io.Error.Unsupported
}

@(private)
stdio_error_again :: proc(err: os.Error) -> bool {
	return false
}

@(private, require_results)
stdio_poll :: proc(entries: []Stdio_Poll_Entry, deadline: time.Tick, has_deadline: bool) -> os.Error {
	return io.Error.Unsupported
}

@(private, require_results)
stdio_sigpipe_ignore :: proc(previous: ^Stdio_Signal_State) -> os.Error {
	return io.Error.Unsupported
}

@(private)
stdio_sigpipe_restore :: proc(previous: ^Stdio_Signal_State) {  }

@(private, require_results)
stdio_set_nonblocking :: proc(file: ^os.File) -> os.Error {
	return io.Error.Unsupported
}

@(private)
stdio_child_wait :: proc(pid: int, block: bool) -> Stdio_Child_Status {
	return .Failed
}

@(private)
stdio_signal :: proc(pid: int, signal: Stdio_Signal, group: bool) {  }
