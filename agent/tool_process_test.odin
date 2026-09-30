package agent

import "core:os"
import "core:testing"

@(test)
test_tool_stream_keeps_utf8_sequences_split_across_chunks :: proc(t: ^testing.T) {
	stream: Tool_Stream
	kept, allocation_error := make([dynamic]u8, context.allocator)
	if !testing.expect_value(t, allocation_error, nil) { return }
	stream.kept = kept
	defer delete(stream.kept)

	first := []u8{0xC3}
	second := []u8{0xA9}
	if !testing.expect_value(t, tool_stream_take(&stream, first), nil) { return }
	if !testing.expect_value(t, tool_stream_take(&stream, second), nil) { return }
	if !testing.expect_value(t, tool_stream_finish(&stream), nil) { return }
	testing.expect_value(t, string(stream.kept[:]), "é")
}

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
	exited, exit_code, waited := tool_child_reap(&child)
	testing.expect(t, waited)
	testing.expect(t, exited && exit_code == 0)
}
