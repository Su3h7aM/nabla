#+test
package agent

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
test_stream_frames_codecs_and_removal :: proc(test: ^testing.T) {
	assistant, assistant_error := stream_encode_assistant(7, 3, transmute([]u8)string("hello"))
	if assistant_error != nil { testing.fail_now(test, "could not encode an assistant payload") }
	defer delete(assistant)
	turn, ordinal, text, assistant_ok := stream_decode_assistant(assistant)
	testing.expect(test, assistant_ok && turn == 7 && ordinal == 3 && string(text) == "hello")
	_, _, _, short_assistant := stream_decode_assistant(assistant[:11])
	testing.expect(test, !short_assistant, "a short assistant payload must not decode")

	output, output_error := stream_encode_tool_output(11, 5, transmute([]u8)string("partial"))
	if output_error != nil { testing.fail_now(test, "could not encode a tool output payload") }
	defer delete(output)
	call, parent_call, chunk, output_ok := stream_decode_tool_output(output)
	testing.expect(test, output_ok && call == 11 && parent_call == 5 && string(chunk) == "partial")
	_, _, _, short_output := stream_decode_tool_output(output[:15])
	testing.expect(test, !short_output, "a short tool output payload must not decode")

	directory, directory_error := os.make_directory_temp("", "nabla-stream-*", context.allocator)
	if directory_error != nil { testing.fail_now(test, "could not create a temporary directory") }
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	path := fmt.tprintf("%s/stream", directory)
	file, open_error := stream_open_writer(path)
	if open_error != nil { testing.fail_now(test, "could not open stream") }
	defer _ = os.close(file)
	if stream_append(file, .Assistant_Text, assistant) != nil { testing.fail_now(test, "could not write frame") }
	if stream_append(file, .Tool_Output, output) != nil { testing.fail_now(test, "could not write frame") }
	partial := [6]u8{u8(Stream_Kind.Assistant_Text), 3, 0, 0, 0, 'x'}
	if _, error := os.write(file, partial[:]); error != nil { testing.fail_now(test, "could not write partial frame") }
	first_kind, first, after_first, first_found, first_error := stream_read(path, 0)
	if first_error != nil || !first_found { testing.fail_now(test, "could not read first frame") }
	defer delete(first)
	testing.expect(test, first_kind == .Assistant_Text && string(first) == string(assistant))
	second_kind, second, offset, second_found, second_error := stream_read(path, after_first)
	if second_error != nil || !second_found { testing.fail_now(test, "could not read second frame") }
	defer delete(second)
	testing.expect(test, second_kind == .Tool_Output && string(second) == string(output))
	_, partial_payload, next, partial_found, partial_error := stream_read(path, offset)
	delete(partial_payload)
	testing.expect(test, partial_error == nil && !partial_found && next == offset, "partial frame must stay unread")
	if _, error := os.write(file, transmute([]u8)string("yz")); error != nil { testing.fail_now(test, "could not finish frame") }
	_, finished, _, finished_found, finished_error := stream_read(path, offset)
	defer delete(finished)
	testing.expect(test, finished_error == nil && finished_found && string(finished) == "xyz")
	testing.expect(test, stream_remove(path) == nil)
	_, missing, _, missing_found, missing_error := stream_read(path, 0)
	delete(missing)
	testing.expect(test, missing_error == nil && !missing_found, "removed stream must be absent")
}
