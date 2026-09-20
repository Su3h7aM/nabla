package term

import "core:encoding/base64"
import "core:strings"
import "core:terminal/ansi"
import "core:testing"

// A clipboard write is only as good as its framing: a wrong introducer, a
// missing selector, or unencoded bytes makes the terminal ignore the sequence,
// and nothing about the call reports it. The encoding is therefore asserted
// directly, including a payload whose base64 is not the text itself.
@(test)
test_clipboard_sequence_frames_the_base64_payload :: proc(t: ^testing.T) {
	sequence, sequence_err := _clipboard_sequence("hello, world", context.allocator)
	if !testing.expect_value(t, sequence_err, nil) { return }
	defer delete(sequence, context.allocator)

	prefix := ansi.OSC + ansi.CLIPBOARD + ";c;"
	testing.expect(t, strings.has_prefix(sequence, prefix), "the sequence must open the clipboard write")
	testing.expect(t, strings.has_suffix(sequence, ansi.BEL), "the sequence must be terminated")

	payload := sequence[len(prefix):len(sequence) - len(ansi.BEL)]
	decoded, decode_err := base64.decode(payload, allocator = context.allocator)
	if !testing.expect_value(t, decode_err, nil) { return }
	defer delete(decoded, context.allocator)
	testing.expect_value(t, string(decoded), "hello, world")
}

// Text that carries a newline and a byte above ASCII survives the round trip,
// which is the case a transcript selection always is.
@(test)
test_clipboard_sequence_keeps_the_text_bytes :: proc(t: ^testing.T) {
	original := "first line\nsecond line — ok"
	sequence, sequence_err := _clipboard_sequence(original, context.allocator)
	if !testing.expect_value(t, sequence_err, nil) { return }
	defer delete(sequence, context.allocator)

	prefix := ansi.OSC + ansi.CLIPBOARD + ";c;"
	payload := sequence[len(prefix):len(sequence) - len(ansi.BEL)]
	decoded, decode_err := base64.decode(payload, allocator = context.allocator)
	if !testing.expect_value(t, decode_err, nil) { return }
	defer delete(decoded, context.allocator)
	testing.expect_value(t, string(decoded), original)
}
