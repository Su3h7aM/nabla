#+build linux
#+test
#+private file
package term

import "core:os"
import "core:sys/linux"
import "core:testing"

// Final behavior of the generic write wakes: a blocked terminal write stops
// with .Superseded once any watched fd is readable, reports what it committed,
// and leaves every watched fd unread for its owner; a write with no wakes
// runs to the end. The pipe below stands in for a full pty output buffer: it
// reproduces EAGAIN deterministically with no terminal involved and no host
// terminal modified. Every blocked case is bounded: the pipe is filled to
// EAGAIN, and each drain reads exactly the filled bytes. Image writes are
// deliberately unwatched and always run to the end; only ordinary frame
// writes take caller wakes.

// _wake_pipe_open fills a pipe to backpressure and returns its ends with the
// write end nonblocking. The caller closes both fds.
_wake_pipe_open :: proc(t: ^testing.T, filled: ^int) -> (reader, writer: ^os.File, ok: bool) {
	read_end, write_end, pipe_err := os.pipe()
	if !testing.expect_value(t, pipe_err, nil) {
		return nil, nil, false
	}
	write_fd := linux.Fd(os.fd(write_end))
	flags, flags_errno := linux.fcntl_getfl(write_fd, .GETFL)
	if !testing.expect_value(t, flags_errno, linux.Errno.NONE) ||
	   !testing.expect_value(t, linux.fcntl_setfl(write_fd, .SETFL, flags + {.NONBLOCK}), linux.Errno.NONE) {
		os.close(read_end)
		os.close(write_end)
		return nil, nil, false
	}
	chunk := make([]byte, 4096)
	defer delete(chunk)
	for i in 0 ..< len(chunk) {
		chunk[i] = 'y'
	}
	for {
		written, errno := linux.write(write_fd, chunk)
		if errno != .NONE {
			break
		}
		filled^ += int(written)
	}
	if !testing.expect(t, filled^ > 0, "pipe must fill to backpressure") {
		os.close(read_end)
		os.close(write_end)
		return nil, nil, false
	}
	return read_end, write_end, true
}

// _wake_eventfd_open returns a signaled eventfd: the generic stand-in for a
// caller wake that is readable while a write waits.
_wake_eventfd_open :: proc(t: ^testing.T) -> (wake: int, ok: bool) {
	fd, wake_errno := linux.eventfd(0, {.NONBLOCK})
	if !testing.expect_value(t, wake_errno, linux.Errno.NONE) {
		return -1, false
	}
	one := u64(1)
	_, _ = linux.write(fd, ([^]u8)(&one)[:size_of(one)])
	return int(fd), true
}

_wake_eventfd_close :: proc(wake: int) {
	_ = linux.close(linux.Fd(wake))
}

// _wake_session_open borrows a pipe write end as a session: enough of a
// terminal for the write loop, with no termios or modes involved.
_wake_session_open :: proc(writer: ^os.File) -> Session {
	return Session{opened = true, impl = Session_Impl{file = writer}}
}

@(test)
test_present_aborts_blocked_write_on_caller_wake :: proc(t: ^testing.T) {
	// Final behavior: a frame write that cannot proceed stops with
	// .Superseded once a caller wake is readable, reports its committed
	// prefix, and leaves the wake unread for its owner. No thread or sleep:
	// the wake is signaled before the call, so the abort is deterministic.
	filled := 0
	reader, writer, ok := _wake_pipe_open(t, &filled)
	if !ok {
		return
	}
	defer os.close(reader)
	defer os.close(writer)

	wake, wake_ok := _wake_eventfd_open(t)
	if !wake_ok {
		return
	}
	defer _wake_eventfd_close(wake)

	session := _wake_session_open(writer)
	buffer := Frame_Buffer {
		columns = 2,
		rows    = 1,
		cells   = []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}},
	}
	required, size_err := encoded_size(buffer, profile_default(), {})
	if !testing.expect_value(t, size_err, nil) {
		return
	}
	scratch := make([]byte, required)
	defer delete(scratch)

	wakes := [1]int{wake}
	committed, reported, err := present(&session, buffer, profile_default(), {}, scratch, nil, wakes[:])
	testing.expect_value(t, err, General_Error.Superseded)
	testing.expect(t, committed == 0, "a full pipe must commit nothing before the abort")
	testing.expect(t, reported == required, "the aborted frame must still report its full size")

	counter: u64
	_, read_errno := linux.read(linux.Fd(wake), ([^]u8)(&counter)[:size_of(counter)])
	testing.expect_value(t, read_errno, linux.Errno.NONE)
	testing.expect(t, counter == 1, "the abort must not consume the caller's wake")
}

@(test)
test_present_retry_after_supersede_recovers_full_frame :: proc(t: ^testing.T) {
	// Recovery contract: after a .Superseded abort, draining the terminal and
	// presenting the full frame again lands it whole.
	filled := 0
	reader, writer, ok := _wake_pipe_open(t, &filled)
	if !ok {
		return
	}
	defer os.close(reader)
	defer os.close(writer)

	session := _wake_session_open(writer)
	buffer := Frame_Buffer {
		columns = 2,
		rows    = 1,
		cells   = []Cell{{grapheme = "a", width = 1}, {grapheme = "b", width = 1}},
	}
	required, size_err := encoded_size(buffer, profile_default(), {})
	if !testing.expect_value(t, size_err, nil) {
		return
	}
	scratch := make([]byte, required)
	defer delete(scratch)

	// Resize-only abort through the established path: the wake stands in for
	// a newer frame the caller would render next.
	wake, wake_ok := _wake_eventfd_open(t)
	if !wake_ok {
		return
	}
	defer _wake_eventfd_close(wake)
	wakes := [1]int{wake}
	_, _, abort_err := present(&session, buffer, profile_default(), {}, scratch, nil, wakes[:])
	testing.expect_value(t, abort_err, General_Error.Superseded)

	drain := make([]byte, 4096)
	defer delete(drain)
	total := 0
	for total < filled {
		read_count, errno := os.read(reader, drain)
		if errno != nil || read_count <= 0 {
			break
		}
		total += read_count
	}
	testing.expect(t, total == filled, "the drain must recover the filled bytes")

	committed, reported, err := present(&session, buffer, profile_default(), {}, scratch)
	testing.expect_value(t, err, nil)
	testing.expect(t, committed == reported && reported == required, "the retried full frame must land whole")
}

@(test)
test_poll_out_watches_every_wake_position :: proc(t: ^testing.T) {
	// One case per wake position, including the slice elements: only the
	// tested wake is readable while the terminal stays writable, so the wait
	// must end with .Superseded from that wake. A dropped slice element fails
	// its own case with nil instead of hanging: the writable terminal always
	// lets the poll return.
	reader, writer, pipe_err := os.pipe()
	if !testing.expect(t, pipe_err == nil, "pipe must open") {
		return
	}
	defer os.close(reader)
	defer os.close(writer)
	fd := linux.Fd(os.fd(writer))

	wakes := [3]linux.Fd{}
	for i in 0 ..< len(wakes) {
		eventfd, wake_errno := linux.eventfd(0, {.NONBLOCK})
		if !testing.expect_value(t, wake_errno, linux.Errno.NONE) {
			for j in 0 ..< i {
				_ = linux.close(wakes[j])
			}
			return
		}
		wakes[i] = eventfd
	}
	defer linux.close(wakes[0])
	defer linux.close(wakes[1])
	defer linux.close(wakes[2])
	one := u64(1)
	for i in 0 ..< len(wakes) {
		_, _ = linux.write(wakes[i], ([^]u8)(&one)[:size_of(one)])
		err := _session_poll_out(fd, linux.Fd(-1), wakes[:])
		testing.expect_value(t, err, General_Error.Superseded)
		counter: u64
		_, read_errno := linux.read(wakes[i], ([^]u8)(&counter)[:size_of(counter)])
		testing.expect_value(t, read_errno, linux.Errno.NONE)
		testing.expect(t, counter == 1, "the wait must not consume the caller's wake")
	}
}
