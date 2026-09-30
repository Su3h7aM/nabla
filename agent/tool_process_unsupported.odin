#+build !linux
package agent

import "core:io"
import "core:os"

// Targets without the process-group backend report every spawn as unsupported, so the
// portable tool surface exists everywhere and fails explicitly.

@(private, require_results)
tool_fork_exec :: proc(exec: Tool_Exec) -> (pid: int, err: os.Error) {
	return 0, io.Error.Unsupported
}

@(private)
tool_exit_watch_open :: proc(pid: int) -> (watch: Tool_Exit_Watch, err: os.Error) {
	return {}, io.Error.Unsupported
}

@(private)
tool_exit_watch_close :: proc(watch: ^Tool_Exit_Watch) {
	watch^ = {}
}

@(private, require_results)
tool_poll_wait :: proc(fds: []Tool_Poll, timeout_ms: i32) -> (interrupted: bool, err: os.Error) {
	return false, io.Error.Unsupported
}

@(private)
tool_child_wait :: proc(pid: int, block: bool) -> (wait: Tool_Wait, exited: bool, exit_code: int) {
	return .Gone, false, 0
}

@(private)
tool_group_signal :: proc(pid: int, signal: Tool_Group_Signal) -> bool {
	return false
}

@(private)
tool_error_again :: proc(err: os.Error) -> bool {
	return false
}
