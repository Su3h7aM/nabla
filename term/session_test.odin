#+build linux
#+test
#+private file
package term

import "core:c"
import "core:sys/posix"
import "core:testing"
import "core:thread"

// The shared session write loop is the one piece of real I/O that can be
// exercised without a tty: pipes reproduce EAGAIN backpressure and a broken
// pipe after a committed prefix deterministically.

// _drain_pipe reads from t.data until it has consumed limit bytes. The
// backpressure test needs a concurrent reader: a full pipe with no reader
// never becomes writable.
_drain_pipe :: proc(worker: ^thread.Thread) {
	drain := cast(^struct {
		fd:    posix.FD,
		total: int,
		limit: int,
	})worker.data
	buffer := make([]byte, 4096)
	defer delete(buffer)
	for drain.total < drain.limit {
		read_count := posix.read(drain.fd, raw_data(buffer), c.size_t(len(buffer)))
		if read_count <= 0 {
			break
		}
		drain.total += int(read_count)
	}
}

// _sigpipe_ignored is a no-op SIGPIPE handler: writing to a pipe whose read
// end closed raises SIGPIPE, and the default disposition would terminate the
// process. With a handler installed the write loop observes EPIPE instead.
_sigpipe_ignored :: proc "c" (sig: posix.Signal) {  }

// _epipe_reader consumes a little from the pipe, then closes the read end so
// the writer observes EPIPE after a committed prefix.
_epipe_reader :: proc(worker: ^thread.Thread) {
	data := cast(^struct {
		fd: posix.FD,
	})worker.data
	buffer := make([]byte, 4096)
	defer delete(buffer)
	posix.read(data.fd, raw_data(buffer), c.size_t(len(buffer)))
	posix.close(data.fd)
}

@(test)
test_session_write_bytes_preserves_the_cause_after_a_committed_prefix :: proc(t: ^testing.T) {
	// A hard write failure after a committed prefix must preserve the
	// underlying cause, not fabricate a stage error.
	action := posix.sigaction_t {
		sa_handler = _sigpipe_ignored,
	}
	previous: posix.sigaction_t
	posix.sigaction(posix.Signal(posix.SIGPIPE), &action, &previous)
	defer posix.sigaction(posix.Signal(posix.SIGPIPE), &previous, nil)

	descriptors: [2]posix.FD
	if posix.pipe(&descriptors) != .OK {
		testing.expect(t, false, "pipe must open")
		return
	}
	defer posix.close(descriptors[0])
	defer posix.close(descriptors[1])

	payload := make([]byte, 256 * 1024)
	defer delete(payload)
	for i in 0 ..< len(payload) {
		payload[i] = 'p'
	}

	reader_data := struct {
		fd: posix.FD,
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
	descriptors: [2]posix.FD
	if posix.pipe(&descriptors) != .OK {
		testing.expect(t, false, "pipe must open")
		return
	}
	defer posix.close(descriptors[0])
	defer posix.close(descriptors[1])

	flags := posix.fcntl(descriptors[1], .GETFL)
	posix.fcntl(descriptors[1], .SETFL, flags | c.int(posix.O_NONBLOCK))

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
		written := posix.write(descriptors[1], raw_data(chunk), c.size_t(len(chunk)))
		if written < 0 {
			break
		}
		filled += int(written)
	}

	drain := struct {
		fd:    posix.FD,
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
		posix.close(descriptors[1])
	}
	thread.join(drain_thread)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, committed, len(payload))
	testing.expect_value(t, drain.total, filled + len(payload))
}
