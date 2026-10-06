#+build linux
package input

import "base:runtime"
import "core:io"
import "core:os"
import "core:sys/linux"
import "core:time"

ESC_DEADLINE_MS :: 50

// read_events polls the file, drains available bytes into the parser, and
// appends the produced events. timeout_ms: 0 = poll once without blocking,
// -1 = block indefinitely, > 0 = block up to timeout_ms. When the parser is
// awaiting a lone ESC, the poll deadline is capped at ESC_DEADLINE_MS; on
// timeout the ESC resolves as an Escape event.
//
// wake is a descriptor made by wake_make, or -1 for none. A signalled wake, or a
// signal that interrupts the poll, ends the wait with zero events and no error so the
// caller rechecks what it watches. read_events never drains the wake. While a lone
// ESC is pending the wait still lasts until its deadline, which bounds the delay.
@(require_results)
read_events :: proc(
	parser: ^Parser,
	file: ^os.File,
	events: ^[dynamic]Event,
	timeout_ms: i64 = 0,
	wake: int = -1,
	allocator := context.allocator,
) -> (
	count: int,
	err: Error,
) {
	start := len(events^)
	fd := linux.Fd(os.fd(file))

	escape_deadline: time.Tick
	has_escape_deadline := parser_escape_pending(parser)
	if has_escape_deadline {
		escape_deadline = time.tick_add(time.tick_now(), time.Duration(ESC_DEADLINE_MS) * time.Millisecond)
	}
	first_timeout := timeout_ms
	if has_escape_deadline {
		remaining := time.tick_diff(time.tick_now(), escape_deadline)
		remaining_timeout := i64(0)
		if remaining > 0 {
			remaining_timeout = i64((remaining + time.Millisecond - 1) / time.Millisecond)
		}
		if first_timeout < 0 || first_timeout > remaining_timeout {
			first_timeout = remaining_timeout
		}
	}
	tty_ready, interrupted, poll_err := input_poll(fd, linux.Fd(wake), i32(first_timeout))
	if poll_err != nil {
		return 0, poll_err
	}
	if interrupted && !tty_ready && !parser_escape_pending(parser) {
		return 0, nil
	}
	if tty_ready {
		if drain_err := input_drain(parser, file, events, allocator); drain_err != nil {
			return len(events^) - start, drain_err
		}
	}
	if parser_escape_pending(parser) {
		if !has_escape_deadline {
			escape_deadline = time.tick_add(time.tick_now(), time.Duration(ESC_DEADLINE_MS) * time.Millisecond)
			has_escape_deadline = true
		}
		remaining := time.tick_diff(time.tick_now(), escape_deadline)
		remaining_timeout := i32(0)
		if remaining > 0 {
			remaining_timeout = i32((remaining + time.Millisecond - 1) / time.Millisecond)
		}
		tty_ready, interrupted, poll_err = input_poll(fd, -1, remaining_timeout)
		if poll_err != nil {
			return len(events^) - start, poll_err
		}
		if tty_ready {
			if drain_err := input_drain(parser, file, events, allocator); drain_err != nil {
				return len(events^) - start, drain_err
			}
		} else if !interrupted {
			if esc_err := parser_resolve_escape(parser, events, allocator); esc_err != nil {
				return len(events^) - start, esc_err
			}
		}
	}
	return len(events^) - start, nil
}

// input_poll waits once for the tty, and for wake unless it is negative. interrupted
// reports a readable wake or an EINTR: either one asks the caller to look again, so the
// wait is not retried.
@(require_results)
input_poll :: proc(fd, wake: linux.Fd, timeout: i32) -> (tty_ready, interrupted: bool, err: Error) {
	poll_descriptors := [2]linux.Poll_Fd{{fd = fd, events = {.IN, .HUP, .ERR, .NVAL}}, {fd = wake, events = {.IN}}}
	count := 2 if wake >= 0 else 1
	_, errno := linux.poll(poll_descriptors[:count], timeout)
	#partial switch errno {
	case .NONE:
		return poll_descriptors[0].revents != {}, count == 2 && poll_descriptors[1].revents != {}, nil
	case .EINTR:
		return false, true, nil
	}
	return false, false, General_Error.Poll_Failed
}

// input_drain reads until EAGAIN (the Session sets O_NONBLOCK on the tty
// descriptor at open), feeding each chunk to the parser. EOF surfaces as an
// End_Of_Input event; resource failures are errors.
@(require_results)
input_drain :: proc(parser: ^Parser, file: ^os.File, events: ^[dynamic]Event, allocator: runtime.Allocator) -> Error {
	buffer: [256]u8
	for {
		read_count, read_err := os.read(file, buffer[:])
		if read_count > 0 {
			if feed_err := feed(parser, buffer[:read_count], events, allocator); feed_err != nil {
				return feed_err
			}
		}
		if read_err != nil {
			if read_err == io.Error.EOF {
				// The EOF event is the caller's only signal that the tty closed,
				// so a failed append is a read failure, not a silent success.
				if emit_err := parser_emit(parser, events, End_Of_Input{}, allocator); emit_err != nil {
					return emit_err
				}
				return nil
			}
			if platform, ok := read_err.(os.Platform_Error); ok && platform == linux.Errno.EAGAIN {
				return nil
			}
			return General_Error.Read_Failed
		}
	}
}
