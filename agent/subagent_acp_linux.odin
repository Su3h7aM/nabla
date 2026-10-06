#+build linux
package agent

import "core:os"
import "core:strings"
import "core:sys/linux"

// SOCKET_CLOSE_ON_EXEC is SOCK_CLOEXEC, which Linux takes in the socket type argument.
@(private = "file")
SOCKET_CLOSE_ON_EXEC :: 0o2000000

// acp_input_open makes the agent's stdin: one end of a socket pair, so a write to an agent
// that exited fails with EPIPE instead of raising SIGPIPE in this process.
@(private, require_results)
acp_input_open :: proc() -> (input: ACP_Input, ok: bool) {
	pair: [2]linux.Fd
	socket_type := transmute(linux.Socket_Type)(int(linux.Socket_Type.STREAM) | SOCKET_CLOSE_ON_EXEC)
	if linux.socketpair(.UNIX, socket_type, .HOPOPT, &pair) != .NONE { return {}, false }
	input = {
		ours   = Tool_Fd(pair[0]),
		theirs = os.new_file(uintptr(pair[1]), "acp-stdin"),
		open   = true,
	}
	if input.theirs == nil {
		// No file wraps the pair, so both ends are abandoned descriptors.
		_ = linux.close(pair[0])
		_ = linux.close(pair[1])
		return {}, false
	}
	return input, true
}

// acp_input_close closes this side, which the agent reads as the end of its input. Releasing
// the descriptors is teardown: a close that fails changes nothing about the input ending.
@(private)
acp_input_close :: proc(input: ^ACP_Input) {
	if input.theirs != nil { _ = os.close(input.theirs) }
	if input.open { _ = linux.close(linux.Fd(input.ours)) }
	input^ = {}
}

// acp_input_send writes p to the agent without raising SIGPIPE and reports how many bytes
// were taken. A send a signal interrupted is repeated.
@(private)
acp_input_send :: proc(input: ^ACP_Input, p: []byte) -> (n: int, ok: bool) {
	for n < len(p) {
		sent, errno := linux.send(linux.Fd(input.ours), p[n:], {.NOSIGNAL})
		if errno == .EINTR { continue }
		if errno != .NONE { return n, false }
		n += sent
	}
	return n, true
}

// subagent_executable reports whether the calling user can execute path, which is not a directory.
@(private, require_results)
subagent_executable :: proc(path: string) -> bool {
	text, clone_error := strings.clone_to_cstring(path, context.temp_allocator)
	if clone_error != nil { return false }
	return linux.access(text, linux.X_OK) == .NONE && !os.is_dir(path)
}
