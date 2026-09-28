#+test
#+private file
package acp

import "core:testing"

@(test)
test_frame_chunk_boundaries_and_multiple_frames :: proc(t: ^testing.T) {
	decoder, decoder_error := frame_decoder_init()
	testing.expect(t, decoder_error == nil)
	defer frame_decoder_destroy(&decoder)
	frames: [dynamic]string
	defer frame_strings_destroy(&frames)

	// Two newline-delimited frames, fed so that a boundary lands inside a chunk.
	wire := "{\"jsonrpc\":\"2.0\",\"method\":\"one\"}\n{\"jsonrpc\":\"2.0\",\"method\":\"two\"}\n"
	testing.expect_value(t, frame_decoder_feed(&decoder, transmute([]u8)wire[:10], &frames), Frame_Error.None)
	testing.expect_value(t, frame_decoder_feed(&decoder, transmute([]u8)wire[10:34], &frames), Frame_Error.None)
	testing.expect_value(t, frame_decoder_feed(&decoder, transmute([]u8)wire[34:], &frames), Frame_Error.None)
	testing.expect_value(t, len(frames), 2)
	testing.expect_value(t, frames[0], "{\"jsonrpc\":\"2.0\",\"method\":\"one\"}")
	testing.expect_value(t, frames[1], "{\"jsonrpc\":\"2.0\",\"method\":\"two\"}")
}

@(test)
test_frame_larger_than_a_chunk_arrives_whole :: proc(t: ^testing.T) {
	decoder, decoder_error := frame_decoder_init()
	testing.expect(t, decoder_error == nil)
	defer frame_decoder_destroy(&decoder)
	frames: [dynamic]string
	defer frame_strings_destroy(&frames)

	// A frame that spans many chunks, and is far larger than any read: nothing truncates
	// it and nothing refuses it.
	wire := make([]u8, 300 * 1024 + 1)
	defer delete(wire)
	for i in 0 ..< len(wire) - 1 { wire[i] = 'a' }
	wire[len(wire) - 1] = '\n'
	for offset := 0; offset < len(wire); offset += 16 * 1024 {
		end := min(offset + 16 * 1024, len(wire))
		testing.expect_value(t, frame_decoder_feed(&decoder, wire[offset:end], &frames), Frame_Error.None)
	}
	testing.expect_value(t, len(frames), 1)
	testing.expect_value(t, len(frames[0]), len(wire) - 1)
	testing.expect_value(t, frames[0], string(wire[:len(wire) - 1]))
}

@(test)
test_frame_invalid_utf8 :: proc(t: ^testing.T) {
	decoder, decoder_error := frame_decoder_init()
	testing.expect(t, decoder_error == nil)
	defer frame_decoder_destroy(&decoder)
	frames: [dynamic]string
	defer frame_strings_destroy(&frames)

	testing.expect_value(t, frame_decoder_feed(&decoder, []byte{0xff, '\n'}, &frames), Frame_Error.Invalid_UTF8)
}
