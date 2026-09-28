package agent

import "core:io"
import "core:os"
import "core:sys/linux"

// SOCKET_CLOSE_ON_EXEC is SOCK_CLOEXEC, which Linux takes in the socket type argument.
@(private = "file")
SOCKET_CLOSE_ON_EXEC :: 0o2000000

// Acp_Input is the agent's stdin: one end of a socket pair, so a write to an agent that
// exited fails with EPIPE instead of raising SIGPIPE in this process.
@(private)
Acp_Input :: struct {
	ours:   linux.Fd,
	theirs: ^os.File, // for the child's stdin; closed once the child has it
	open:   bool,
}

@(private, require_results)
acp_input_open :: proc() -> (input: Acp_Input, ok: bool) {
	pair: [2]linux.Fd
	socket_type := transmute(linux.Socket_Type)(int(linux.Socket_Type.STREAM) | SOCKET_CLOSE_ON_EXEC)
	if linux.socketpair(.UNIX, socket_type, .HOPOPT, &pair) != .NONE { return {}, false }
	input = {
		ours   = pair[0],
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
acp_input_close :: proc(input: ^Acp_Input) {
	if input.theirs != nil { _ = os.close(input.theirs) }
	if input.open { _ = linux.close(input.ours) }
	input^ = {}
}

@(private)
acp_input_writer :: proc(input: ^Acp_Input) -> io.Writer {
	return io.Stream{procedure = acp_input_stream, data = input}
}

@(private = "file", require_results)
acp_input_stream :: proc(stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	input := cast(^Acp_Input)stream_data
	#partial switch mode {
	case .Write:
		for int(n) < len(p) {
			sent, errno := linux.send(input.ours, p[n:], {.NOSIGNAL})
			if errno == .EINTR { continue }
			if errno != .NONE { return n, .Unexpected_EOF }
			n += i64(sent)
		}
		return n, nil
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Unsupported
}
