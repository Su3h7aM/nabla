#+build linux
#+test
package tui

import "../term"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

// Screen-level wake regression: a diff write blocked on a full terminal stops
// with .Superseded once a caller wake is readable, forgets the diff snapshot,
// and the retry after draining presents the full frame. The pipe below stands
// in for a full pty output buffer: it reproduces EAGAIN deterministically with
// no terminal involved and no host terminal modified. Every blocked case is
// bounded: the pipe is filled to EAGAIN and the drain reads exactly the filled
// bytes.

@(test)
test_screen_blocked_diff_write_aborts_on_wake_then_presents_full :: proc(t: ^testing.T) {
	pipe: Screen_Pipe
	if !testing.expect(t, screen_pipe_open(&pipe)) { return }
	defer screen_pipe_close(&pipe)
	write_fd := linux.Fd(os.fd(pipe.session.impl.file))
	flags, flags_errno := linux.fcntl_getfl(write_fd, .GETFL)
	if !testing.expect_value(t, flags_errno, linux.Errno.NONE) { return }
	if !testing.expect_value(t, linux.fcntl_setfl(write_fd, .SETFL, flags + {.NONBLOCK}), linux.Errno.NONE) { return }

	screen: Screen
	screen_init(&screen, context.allocator)
	defer screen_destroy(&screen)
	storage: [4096]byte

	// A first full frame succeeds and becomes the snapshot the diff is taken
	// against; the take drains the pipe for the blocked write below.
	if !screen_draw(t, &screen) { return }
	if !testing.expect_value(t, screen_present(&screen, &pipe.session, term.profile_default(), {}), nil) { return }
	_ = screen_pipe_take(&pipe, storage[:])
	_, remembered := screen.previous.?
	if !testing.expect(t, remembered, "a presented frame becomes the snapshot") { return }

	// A changed frame would present as a diff; the full pipe stops its first
	// byte instead.
	if !screen_draw(t, &screen) { return }
	if !testing.expect(t, put(&screen.buffer, 0, 0, "y", {})) { return }
	chunk: [4096]byte
	filled := 0
	for {
		written, errno := linux.write(write_fd, chunk[:])
		if errno != .NONE { break }
		filled += int(written)
	}
	if !testing.expect(t, filled > 0, "pipe must fill to backpressure") { return }

	wake, wake_errno := linux.eventfd(0, {.NONBLOCK})
	if !testing.expect_value(t, wake_errno, linux.Errno.NONE) { return }
	defer linux.close(wake)
	one := u64(1)
	_, _ = linux.write(wake, ([^]u8)(&one)[:size_of(one)])

	wakes := [1]int{int(wake)}
	err := screen_present(&screen, &pipe.session, term.profile_default(), {}, wakes[:])
	testing.expect_value(t, err, term.General_Error.Superseded)
	_, still_remembered := screen.previous.?
	testing.expect(t, !still_remembered, "an aborted write forgets the snapshot so the retry is a full frame")

	// The drain mirrors the loop's wake drain: the retry below runs with no
	// readable wake and a terminal that accepts bytes.
	counter: u64
	_, _ = linux.read(wake, ([^]u8)(&counter)[:size_of(counter)])
	drained := 0
	for drained < filled {
		read_count, read_errno := os.read(pipe.reader, storage[:])
		if read_errno != nil || read_count <= 0 { break }
		drained += read_count
	}
	if !testing.expect(t, drained == filled, "the drain must recover the filled bytes") { return }

	if !testing.expect_value(t, screen_present(&screen, &pipe.session, term.profile_default(), {}), nil) { return }
	full := screen_pipe_take(&pipe, storage[:])
	testing.expect(t, strings.has_prefix(full, term.FRAME_RESET), "the retry after an abort presents the full frame")
	testing.expect(t, strings.contains(full, "y"), "the full retry carries the newest cells")
	_, remembered_again := screen.previous.?
	testing.expect(t, remembered_again, "a presented retry becomes the snapshot again")
}
