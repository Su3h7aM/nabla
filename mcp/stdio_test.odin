#+test
package mcp

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
		user_data    = &stop,
		interrupted  = stdio_test_interrupted,
		deadline_at  = time.tick_add(time.tick_now(), STDIO_TEST_BOUND),
		has_deadline = true,
		wake         = stop.wake_read,
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
