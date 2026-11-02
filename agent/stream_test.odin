#+test
package agent

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
test_stream_frames_and_removal :: proc(test: ^testing.T) {
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
	if stream_append(file, .Assistant_Text, transmute([]u8)string("first")) != nil { testing.fail_now(test, "could not write frame") }
	partial := [6]u8{u8(Stream_Kind.Assistant_Text), 3, 0, 0, 0, 'x'}
	if _, error := os.write(file, partial[:]); error != nil { testing.fail_now(test, "could not write partial frame") }
	kind, payload, offset, found, read_error := stream_read(path, 0)
	if read_error != nil || !found { testing.fail_now(test, "could not read first frame") }
	defer delete(payload)
	testing.expect(test, kind == .Assistant_Text && string(payload) == "first")
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

@(test)
test_stream_payload_codecs_round_trip :: proc(test: ^testing.T) {
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

	directory, directory_error := os.make_directory_temp("", "nabla-stream-payload-*", context.allocator)
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
	partial := [6]u8{u8(Stream_Kind.Tool_Output), 4, 0, 0, 0, 'x'}
	if _, error := os.write(file, partial[:]); error != nil { testing.fail_now(test, "could not write partial frame") }
	kind, payload, offset, found, read_error := stream_read(path, 0)
	if read_error != nil || !found { testing.fail_now(test, "could not read the frame") }
	defer delete(payload)
	testing.expect(test, kind == .Assistant_Text && string(payload) == string(assistant))
	_, partial_payload, next, partial_found, partial_error := stream_read(path, offset)
	delete(partial_payload)
	testing.expect(test, partial_error == nil && !partial_found && next == offset, "partial frame must stay unread")
}
