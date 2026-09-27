package agent

import "core:os"
import "core:sys/posix"
import "core:testing"

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
	child, spawn, spawn_error := tool_spawn_command({"/bin/cat"}, ".", input_read, output_write, output_write, true)
	os.close(output_write)
	if !testing.expect_value(t, spawn_error, nil) { return }
	testing.expect_value(t, spawn, Tool_Spawn.Started)
	defer tool_child_close(&child)
	buffer: [256]byte
	read_count, read_error := os.read(output_read, buffer[:])
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(buffer[:read_count]), message)
	status: i32
	waited := posix.waitpid(posix.pid_t(child.pid), &status, {})
	testing.expect_value(t, int(waited), child.pid)
	tool_child_record(&child, status)
	testing.expect(t, child.exited && child.exit_code == 0)
}
