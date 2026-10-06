#+build !linux
package subprocess

import "core:io"
import "core:os"

// Targets without the process-group backend report every start as unsupported, so the portable
// surface exists everywhere and fails explicitly.

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

@(private, require_results)
fork_exec :: proc(exec: Exec) -> (pid: int, err: os.Error) {
	return 0, io.Error.Unsupported
}

@(private)
exit_watch_open :: proc(pid: int) -> (watch: Fd, err: os.Error) {
	return FD_NONE, io.Error.Unsupported
}

@(private)
exit_watch_close :: proc(watch: Fd) {  }

@(private, require_results)
poll_wait :: proc(entries: []Poll, timeout_ms: i32) -> (interrupted: bool, err: os.Error) {
	return false, io.Error.Unsupported
}

@(private)
child_wait :: proc(pid: int, block: bool) -> (wait: Wait, exited: bool, exit_code: int) {
	return .Gone, false, 0
}

@(private)
group_signal :: proc(pid: int, signal: Group_Signal) -> bool {
	return false
}

// error_again reports whether err from a read or write only needs repeating.
error_again :: proc(err: os.Error) -> bool {
	return false
}
