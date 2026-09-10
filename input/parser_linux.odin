#+build linux
package input

import "base:runtime"
import "core:c"
import "core:io"
import "core:os"
import "core:sys/linux"
import "core:sys/posix"

ESC_DEADLINE_MS :: 50

// read_events polls the file, drains available bytes into the parser, and
// appends the produced events. timeout_ms: 0 = poll once without blocking,
// -1 = block indefinitely, > 0 = block up to timeout_ms. When the parser is
// awaiting a lone ESC, the poll deadline is capped at ESC_DEADLINE_MS; on
// timeout the ESC resolves as an Escape event.
@(require_results)
read_events :: proc(p: ^Parser, file: ^os.File, events: ^[dynamic]Event, timeout_ms: i64 = 0, allocator := context.allocator) -> (count: int, err: Error) {
	start := len(events^)
	fd := posix.FD(os.fd(file))

	first_timeout := timeout_ms
	if parser_escape_pending(p) && (first_timeout < 0 || first_timeout > ESC_DEADLINE_MS) {
		first_timeout = ESC_DEADLINE_MS
	}
	ready, poll_err := input_poll(fd, c.int(first_timeout))
	if poll_err != nil {
		return 0, poll_err
	}
	if ready > 0 {
		if drain_err := input_drain(p, file, events, allocator); drain_err != nil {
			return len(events^) - start, drain_err
		}
	}
	if parser_escape_pending(p) {
		ready, poll_err = input_poll(fd, ESC_DEADLINE_MS)
		if poll_err != nil {
			return len(events^) - start, poll_err
		}
		if ready > 0 {
			if drain_err := input_drain(p, file, events, allocator); drain_err != nil {
				return len(events^) - start, drain_err
			}
		} else {
			if esc_err := parser_resolve_escape(p, events, allocator); esc_err != nil {
				return len(events^) - start, esc_err
			}
		}
	}
	return len(events^) - start, nil
}

input_poll :: proc(fd: posix.FD, timeout: c.int) -> (ready: int, err: Error) {
	for {
		pfd := posix.pollfd {
			fd     = fd,
			events = {.IN, .HUP, .ERR, .NVAL},
		}
		n := posix.poll(&pfd, 1, timeout)
		if n >= 0 {
			return int(n), nil
		}
		if posix.get_errno() == .EINTR {
			continue
		}
		return 0, General_Error.Poll_Failed
	}
}

// input_drain reads until EAGAIN (the Session sets O_NONBLOCK on the tty
// descriptor at open), feeding each chunk to the parser. EOF surfaces as an
// End_Of_Input event; resource failures are errors.
input_drain :: proc(p: ^Parser, file: ^os.File, events: ^[dynamic]Event, allocator: runtime.Allocator) -> Error {
	buffer: [256]u8
	for {
		n, read_err := os.read(file, buffer[:])
		if n > 0 {
			if err := feed(p, buffer[:n], events, allocator); err != nil {
				return err
			}
		}
		if read_err != nil {
			if read_err == io.Error.EOF {
				_ = parser_emit(p, events, End_Of_Input{}, allocator)
				return nil
			}
			if platform, ok := read_err.(os.Platform_Error); ok && platform == linux.Errno.EAGAIN {
				return nil
			}
			return General_Error.Read_Failed
		}
	}
}
