package agent

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

