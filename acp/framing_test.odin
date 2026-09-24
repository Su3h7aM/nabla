#+test
#+private file
package acp

import "core:testing"

@(test)
test_frame_chunk_boundaries_and_multiple_frames :: proc(t: ^testing.T) {
	decoder, decoder_error := frame_decoder_init(128)
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
test_frame_oversized_and_invalid_utf8 :: proc(t: ^testing.T) {
	frames: [dynamic]string
	defer frame_strings_destroy(&frames)

	// A frame larger than the configured bound is rejected.
	decoder, decoder_error := frame_decoder_init(4)
	testing.expect(t, decoder_error == nil)
	testing.expect_value(t, frame_decoder_feed(&decoder, transmute([]u8)string("12345"), &frames), Frame_Error.Frame_Too_Large)
	frame_decoder_destroy(&decoder)

	// A frame that is not valid UTF-8 is rejected.
	decoder, decoder_error = frame_decoder_init(4)
	testing.expect(t, decoder_error == nil)
	testing.expect_value(t, frame_decoder_feed(&decoder, []byte{0xff, '\n'}, &frames), Frame_Error.Invalid_UTF8)
	frame_decoder_destroy(&decoder)
}

@(test)
test_frame_budget_matches_buzz_line_limit :: proc(t: ^testing.T) {
	// Buzz reads ACP lines up to 10,000,000 bytes; a tighter bound here would cut
	// Buzz's own messages off, a looser one would waste the comparison.
	testing.expect_value(t, MAX_FRAME_BYTES, 10_000_000)
}
