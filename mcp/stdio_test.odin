#+test
package mcp

import "core:mem"
import "core:strings"
import "core:testing"

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
