#+test
package subprocess

import "core:os"
import "core:testing"
import "core:time"

// SUBPROCESS_TEST_BOUND is a deadline no passing test comes near: a wait that ignored its
// condition would end here instead of hanging the suite.
SUBPROCESS_TEST_BOUND :: 10 * time.Second

@(test)
test_command_child_reads_its_input_pipe :: proc(t: ^testing.T) {
	input_read, input_write, input_error := os.pipe()
	if !testing.expect_value(t, input_error, nil) { return }
	defer os.close(input_read)
	output_read, output_write, output_error := os.pipe()
	if output_error != nil { os.close(input_write); testing.expect_value(t, output_error, nil); return }
	defer os.close(output_read)
	message := "child input, not shell syntax: $HOME; exit 1\n"
	count, write_error := os.write(input_write, transmute([]byte)message)
	os.close(input_write)
	testing.expect_value(t, write_error, nil)
	testing.expect_value(t, count, len(message))
	child, spawn, spawn_error := start({argv = {"/bin/cat"}, stdin = input_read, stdout = output_write, stderr = output_write})
	os.close(output_write)
	if !testing.expect_value(t, spawn_error, nil) { return }
	testing.expect_value(t, spawn, Spawn.Started)
	defer child_close(&child)
	buffer: [256]byte
	read_count, read_error := os.read(output_read, buffer[:])
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(buffer[:read_count]), message)
	exited, exit_code, waited := child_reap(&child)
	testing.expect(t, waited)
	testing.expect(t, exited && exit_code == 0)
}

@(test)
test_missing_program_reports_exec_failure_and_leaves_no_child :: proc(t: ^testing.T) {
	output_read, output_write, output_error := os.pipe()
	if !testing.expect_value(t, output_error, nil) { return }
	defer os.close(output_read)
	defer os.close(output_write)
	child, spawn, spawn_error := start({argv = {"/nonexistent/program"}, stdout = output_write, stderr = output_write})
	testing.expect_value(t, spawn, Spawn.Exec_Failed)
	ENOENT :: 2
	testing.expect_value(t, spawn_error, os.Platform_Error(ENOENT))
	// start has already reaped the child, so no pid or descriptor is left to release.
	testing.expect_value(t, child, Child{})
}

@(test)
test_terminate_group_kills_a_tree_that_ignores_sigterm :: proc(t: ^testing.T) {
	output_read, output_write, output_error := os.pipe()
	if !testing.expect_value(t, output_error, nil) { return }
	defer os.close(output_read)
	// The shell and its background sleep both ignore SIGTERM, since ignored dispositions
	// survive exec, so only the SIGKILL to the group can end them.
	script := "trap '' TERM; sleep 60 & echo started; wait"
	child, spawn, spawn_error := start({argv = {"/bin/sh", "-c", script}, stdout = output_write, stderr = output_write})
	os.close(output_write)
	if !testing.expect_value(t, spawn_error, nil) { return }
	testing.expect_value(t, spawn, Spawn.Started)
	defer child_close(&child)
	ready := [1]Poll{{fd = fd(output_read)}}
	deadline := time.tick_add(time.tick_now(), SUBPROCESS_TEST_BOUND)
	if !testing.expect_value(t, poll(ready[:], deadline, true), nil) { _ = terminate_group(&child, 0); return }
	testing.expect(t, ready[0].ready)

	_ = terminate_group(&child, 100 * time.Millisecond)
	testing.expect(t, child.reaped)
	testing.expect(t, !child.exited, "the shell ignored SIGTERM, so a signal ended it")

	// The sleep holds the write end too, so end of stream means no group member is left.
	for {
		buffer: [64]byte
		count, status := read(output_read, buffer[:])
		if status == .Again { continue }
		if !testing.expect_value(t, status, Io.Ok) { return }
		if count == 0 { break }
	}
}
