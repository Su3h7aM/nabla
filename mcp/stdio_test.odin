#+test
package mcp

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// STDIO_TEST_BOUND is a deadline no passing test comes near: a wait that ignored
// its wake ends here as a timeout instead of hanging the suite.
STDIO_TEST_BOUND :: 10 * time.Second

// Stdio_Test_Stop is a caller's stop: a flag, and the pipe that wakes a sleeping
// transport when the flag is set.
Stdio_Test_Stop :: struct {
	requested:  bool,
	wake_read:  ^os.File,
	wake_write: ^os.File,
}

stdio_test_interrupted :: proc(user_data: rawptr) -> bool {
	return sync.atomic_load(&(cast(^Stdio_Test_Stop)user_data).requested)
}

// STDIO_TEST_SETTLE gives the reader time to fall asleep before the stop, so the
// test exercises the wake rather than the check before the wait.
STDIO_TEST_SETTLE :: 50 * time.Millisecond

stdio_test_request_stop :: proc(stop: ^Stdio_Test_Stop) {
	time.sleep(STDIO_TEST_SETTLE)
	sync.atomic_store(&stop.requested, true)
	_ = os.close(stop.wake_write)
}

@(test)
test_stdio_write_line_rejects_short_allocation_before_io :: proc(t: ^testing.T) {
	stdio: Stdio
	stdio.started = true
	stdio.allocator = mem.nil_allocator()
	stdio.out.allocator = mem.nil_allocator()

	err := stdio_write_line(&stdio, "request", {})
	defer error_destroy(&err, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.Out_Of_Memory)
	testing.expect_value(t, err.delivery, Delivery_State.Not_Delivered)
}

// Two messages that arrive in one read are framed apart: the second read returns the second
// message alone, not the bytes the first read already returned.
@(test)
test_stdio_frames_two_messages_from_one_read :: proc(t: ^testing.T) {
	stdio: Stdio
	stdio.started = true
	stdio.allocator = context.allocator
	stdio.line = make([dynamic]u8, context.allocator)
	defer delete(stdio.line)
	text := "one\ntwo\n"
	append(&stdio.line, ..transmute([]u8)text)

	first, first_error := stdio_read_line(&stdio, {})
	defer error_destroy(&first_error, context.allocator)
	testing.expect_value(t, first_error.kind, Error_Kind.None)
	testing.expect_value(t, string(first), "one")

	second, second_error := stdio_read_line(&stdio, {})
	defer error_destroy(&second_error, context.allocator)
	testing.expect_value(t, second_error.kind, Error_Kind.None)
	testing.expect_value(t, string(second), "two")
}

// A server is a program with a pipe on each stream: a line written to cat comes
// back unchanged.
@(test)
test_stdio_round_trips_a_line_through_a_server :: proc(t: ^testing.T) {
	stdio: Stdio
	err := stdio_start(&stdio, {executable = "/bin/cat"})
	defer stdio_stop(&stdio)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { error_destroy(&err); return }
	write_error := stdio_write_line(&stdio, "ping", {})
	defer error_destroy(&write_error)
	testing.expect_value(t, write_error.kind, Error_Kind.None)
	line, read_error := stdio_read_line(&stdio, {})
	defer error_destroy(&read_error)
	testing.expect_value(t, read_error.kind, Error_Kind.None)
	testing.expect_value(t, string(line), "ping")
}

// A read that sleeps on a silent server ends when another thread stops it, without
// waiting for the server or the deadline.
@(test)
test_stdio_read_wakes_for_a_stop :: proc(t: ^testing.T) {
	stdio: Stdio
	err := stdio_start(&stdio, {executable = "/bin/cat"})
	defer stdio_stop(&stdio)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { error_destroy(&err); return }

	stop: Stdio_Test_Stop
	pipe_err: os.Error
	stop.wake_read, stop.wake_write, pipe_err = os.pipe()
	if !testing.expect_value(t, pipe_err, nil) { return }
	defer os.close(stop.wake_read)
	stopper := thread.create_and_start_with_poly_data(&stop, stdio_test_request_stop)
	defer thread.destroy(stopper)

	control := Control {
		user_data   = &stop,
		interrupted = stdio_test_interrupted,
		deadline    = time.tick_add(time.tick_now(), STDIO_TEST_BOUND),
		wake        = stop.wake_read,
	}
	_, read_error := stdio_read_line(&stdio, control)
	defer error_destroy(&read_error)
	thread.join(stopper)
	testing.expect_value(t, read_error.kind, Error_Kind.Cancelled)
}

// A program that cannot be run is reported with the reason exec gave.
@(test)
test_stdio_start_reports_why_a_server_did_not_start :: proc(t: ^testing.T) {
	stdio: Stdio
	err := stdio_start(&stdio, {executable = "/nonexistent/mcp-server"})
	defer error_destroy(&err)
	testing.expect_value(t, err.kind, Error_Kind.Spawn_Failed)
	testing.expect(t, strings.contains(err.message, "could not be started: "), err.message)
	testing.expect(t, !stdio.started)
}

// A server can live for a whole session and write to standard error without end, so
// the transport keeps only its most recent bytes. The tail holds the end of the
// stream and nothing older, whatever the server wrote before it.
@(test)
test_stdio_retains_only_the_most_recent_stderr :: proc(t: ^testing.T) {
	marker := "the end"
	server := fmt.tprintf(`head -c %d /dev/zero | tr '\000' x 1>&2; printf '%s' 1>&2`, MAX_STDERR_TAIL_BYTES + 4096, marker)
	stdio: Stdio
	start_error := stdio_start(&stdio, {executable = "/bin/sh", arguments = {"-c", server}})
	defer stdio_stop(&stdio)
	if !testing.expect_value(t, start_error.kind, Error_Kind.None) { error_destroy(&start_error); return }
	error_destroy(&start_error)

	expected := fmt.tprintf("%s%s", strings.repeat("x", MAX_STDERR_TAIL_BYTES - len(marker), context.temp_allocator), marker)
	// The drain runs on its own thread, so the test waits for the server's end of
	// stream to be read. Only the end of the stream is ever visible, and the marker
	// arrives with it, so the wait is for that end.
	wait_start := time.tick_now()
	found := false
	retained := 0
	for !found {
		sync.mutex_lock(&stdio.stderr_mutex)
		found = string(stdio.stderr_tail[:]) == expected
		retained = len(stdio.stderr_tail)
		sync.mutex_unlock(&stdio.stderr_mutex)
		if found { break }
		if time.tick_since(wait_start) > STDIO_TEST_BOUND { break }
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, found, "the tail must hold the most recent %d bytes of standard error, not %d", MAX_STDERR_TAIL_BYTES, retained)
}
