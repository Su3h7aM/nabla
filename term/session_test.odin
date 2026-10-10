#+build linux
#+test
#+private file
package term

import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"

// The shared session write loop is the one piece of real I/O that can be
// exercised without a tty: pipes reproduce EAGAIN backpressure and a broken
// pipe after a committed prefix deterministically.

// _drain_pipe reads from t.data until it has consumed limit bytes. The
// backpressure test needs a concurrent reader: a full pipe with no reader
// never becomes writable.
_drain_pipe :: proc(worker: ^thread.Thread) {
	drain := cast(^struct {
		fd:    linux.Fd,
		total: int,
		limit: int,
	})worker.data
	buffer := make([]byte, 4096)
	defer delete(buffer)
	for drain.total < drain.limit {
		read_count, errno := linux.read(drain.fd, buffer)
		if errno != .NONE || read_count <= 0 {
			break
		}
		drain.total += int(read_count)
	}
}

// _sigpipe_ignored is a no-op SIGPIPE handler: writing to a pipe whose read
// end closed raises SIGPIPE, and the default disposition would terminate the
// process. With a handler installed the write loop observes EPIPE instead.
_sigpipe_ignored :: proc "c" (sig: linux.Signal) {  }

// _epipe_reader consumes a little from the pipe, then closes the read end so
// the writer observes EPIPE after a committed prefix.
_epipe_reader :: proc(worker: ^thread.Thread) {
	data := cast(^struct {
		fd: linux.Fd,
	})worker.data
	buffer := make([]byte, 4096)
	defer delete(buffer)
	_, _ = linux.read(data.fd, buffer)
	_ = linux.close(data.fd)
}

@(test)
test_session_write_bytes_preserves_the_cause_after_a_committed_prefix :: proc(t: ^testing.T) {
	// A hard write failure after a committed prefix must preserve the
	// underlying cause, not fabricate a stage error.
	action := linux.Sig_Action {
		handler = _sigpipe_ignored,
	}
	previous: linux.Sig_Action
	testing.expect_value(t, linux.rt_sigaction(.SIGPIPE, &action, &previous), linux.Errno.NONE)
	defer linux.rt_sigaction(.SIGPIPE, &previous, nil)

	descriptors: [2]linux.Fd
	if linux.pipe2(&descriptors, {}) != .NONE {
		testing.expect(t, false, "pipe must open")
		return
	}
	defer linux.close(descriptors[0])
	defer linux.close(descriptors[1])

	payload := make([]byte, 256 * 1024)
	defer delete(payload)
	for i in 0 ..< len(payload) {
		payload[i] = 'p'
	}

	reader_data := struct {
		fd: linux.Fd,
	} {
		fd = descriptors[0],
	}
	reader := thread.create(_epipe_reader)
	reader.data = &reader_data
	thread.start(reader)
	defer thread.destroy(reader)

	committed, err := _session_write_bytes(descriptors[1], payload)
	thread.join(reader)

	platform_err, is_platform := err.(Platform_Error)
	testing.expect(t, is_platform, "a broken pipe must preserve its platform cause")
	if is_platform {
		testing.expectf(t, platform_err == .EPIPE, "a broken pipe must report EPIPE, got %v", platform_err)
	}
	testing.expect(t, committed > 0, "bytes committed before the failure must be reported")
}

@(test)
test_session_write_bytes_recovers_from_backpressure :: proc(t: ^testing.T) {
	// The tty is O_NONBLOCK, so control sequences and frames can hit EAGAIN.
	// A full pipe must wait for POLLOUT and complete short writes rather than
	// fail or truncate.
	descriptors: [2]linux.Fd
	if linux.pipe2(&descriptors, {}) != .NONE {
		testing.expect(t, false, "pipe must open")
		return
	}
	defer linux.close(descriptors[0])
	defer linux.close(descriptors[1])

	flags, flags_errno := linux.fcntl_getfl(descriptors[1], .GETFL)
	testing.expect_value(t, flags_errno, linux.Errno.NONE)
	testing.expect_value(t, linux.fcntl_setfl(descriptors[1], .SETFL, flags + {.NONBLOCK}), linux.Errno.NONE)

	payload := make([]byte, 128 * 1024)
	defer delete(payload)
	for i in 0 ..< len(payload) {
		payload[i] = 'x'
	}

	// Fill the pipe so the first helper write hits EAGAIN deterministically.
	chunk := make([]byte, 4096)
	defer delete(chunk)
	for i in 0 ..< len(chunk) {
		chunk[i] = 'y'
	}
	filled := 0
	for {
		written, errno := linux.write(descriptors[1], chunk)
		if errno != .NONE {
			break
		}
		filled += int(written)
	}

	drain := struct {
		fd:    linux.Fd,
		total: int,
		limit: int,
	} {
		fd    = descriptors[0],
		limit = filled + len(payload),
	}
	drain_thread := thread.create(_drain_pipe)
	drain_thread.data = &drain
	thread.start(drain_thread)
	defer thread.destroy(drain_thread)

	committed, err := _session_write_bytes(descriptors[1], payload)
	if err != nil {
		// The loop bailed early: close the write end so the drain's blocked
		// read sees EOF and the join cannot hang.
		_ = linux.close(descriptors[1])
	}
	thread.join(drain_thread)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, committed, len(payload))
	testing.expect_value(t, drain.total, filled + len(payload))
}

@(test)
test_session_write_bytes_stops_when_the_wake_is_readable_while_blocked :: proc(t: ^testing.T) {
	// A frame waiting on a terminal that no longer accepts bytes must give up
	// when a resize arrives, and leave the wake unread for its owner.
	descriptors: [2]linux.Fd
	if linux.pipe2(&descriptors, {.NONBLOCK}) != .NONE {
		testing.expect(t, false, "pipe must open")
		return
	}
	defer linux.close(descriptors[0])
	defer linux.close(descriptors[1])
	wake, wake_errno := linux.eventfd(0, {.NONBLOCK})
	if !testing.expect_value(t, wake_errno, linux.Errno.NONE) { return }
	defer linux.close(wake)

	chunk: [4096]byte
	for {
		if _, errno := linux.write(descriptors[1], chunk[:]); errno != .NONE {
			break
		}
	}

	resizer := thread.create(proc(worker: ^thread.Thread) {
		time.sleep(20 * time.Millisecond)
		one := u64(1)
		_, _ = linux.write(cast(linux.Fd)worker.user_index, ([^]u8)(&one)[:size_of(one)])
	})
	resizer.user_index = int(wake)
	thread.start(resizer)
	defer thread.destroy(resizer)

	payload: [64]byte
	committed, err := _session_write_bytes(descriptors[1], payload[:], wake)
	thread.join(resizer)
	testing.expect_value(t, err, General_Error.Superseded)
	testing.expect_value(t, committed, 0)

	counter: u64
	_, read_errno := linux.read(wake, ([^]u8)(&counter)[:size_of(counter)])
	testing.expect_value(t, read_errno, linux.Errno.NONE)
	testing.expect_value(t, counter, 1)
}

@(test)
test_session_write_bytes_does_not_spin_on_a_broken_wake :: proc(t: ^testing.T) {
	// A wake that only reports a hang-up is unusable: the blocked write must fail,
	// not poll it again and again.
	full: [2]linux.Fd
	broken: [2]linux.Fd
	if linux.pipe2(&full, {.NONBLOCK}) != .NONE || linux.pipe2(&broken, {.NONBLOCK}) != .NONE {
		testing.expect(t, false, "pipes must open")
		return
	}
	defer linux.close(full[0])
	defer linux.close(full[1])
	defer linux.close(broken[0])
	chunk: [4096]byte
	for {
		if _, errno := linux.write(full[1], chunk[:]); errno != .NONE {
			break
		}
	}
	_ = linux.close(broken[1])

	payload: [8]byte
	committed, err := _session_write_bytes(full[1], payload[:], broken[0])
	testing.expect_value(t, err, Platform_Error(.EBADF))
	testing.expect_value(t, committed, 0)
}

@(test)
test_session_poll_out_prefers_the_resize_over_a_writable_terminal :: proc(t: ^testing.T) {
	writable: [2]linux.Fd
	if linux.pipe2(&writable, {.NONBLOCK}) != .NONE {
		testing.expect(t, false, "pipe must open")
		return
	}
	defer linux.close(writable[0])
	defer linux.close(writable[1])
	wake, wake_errno := linux.eventfd(0, {.NONBLOCK})
	if !testing.expect_value(t, wake_errno, linux.Errno.NONE) { return }
	defer linux.close(wake)

	testing.expect_value(t, _session_poll_out(writable[1], -1), nil)
	one := u64(1)
	_, _ = linux.write(wake, ([^]u8)(&one)[:size_of(one)])
	testing.expect_value(t, _session_poll_out(writable[1], wake), General_Error.Superseded)
}
