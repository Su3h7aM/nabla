#+test
#+private file
package text

import "core:testing"

@(test)
test_sanitize_text_applies_the_rule :: proc(t: ^testing.T) {
	Case :: struct {
		name:  string,
		input: string,
		want:  string,
	}
	cases := []Case {
		{"plain text, tab and newline are kept", "a\tb\nc é界", "a\tb\nc é界"},
		{"CRLF and lone CR become LF", "a\r\nb\rc\r\r\nd", "a\nb\nc\n\nd"},
		{"other C0 and DEL are removed", "a\x00b\x01c\x07d\x08e\x7ff", "abcdef"},
		{"C1 controls are removed", "a\u0080b\u0085c\u009fd", "abcd"},
		{"CSI is removed whole", "a\x1b[1;31mred\x1b[0m\x1b[2 q!", "ared!"},
		{"C1 CSI is removed whole", "a\u009b31mb", "ab"},
		{"OSC ends at BEL", "a\x1b]0;title\x07b", "ab"},
		{"OSC ends at ST", "a\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\b", "alinkb"},
		{"C1 OSC is removed whole", "a\u009d0;title\x07b", "ab"},
		{"two-byte and charset escapes are removed", "a\x1bMb\x1b(Bc", "abc"},
		{"a control after ESC is kept as text", "a\x1b\nb", "a\nb"},
		{"an unterminated sequence is dropped at the end", "a\x1b[31", "a"},
		{"an unterminated OSC is dropped at the end", "a\x1b]0;title", "a"},
		{"each rejected byte becomes U+FFFD", "a\xffb\xc3(c\xe2\x82d\xed\xa0\x80", "a\ufffdb\ufffd(c\ufffd\ufffdd\ufffd\ufffd\ufffd"},
		{"a real U+FFFD is kept", "a\ufffdb", "a\ufffdb"},
		{"a rune cut off by the end becomes U+FFFD", "a\xe2\x82", "a\ufffd\ufffd"},
	}
	for c in cases {
		got, err := sanitize_text(c.input, context.temp_allocator)
		testing.expect_value(t, err, nil)
		testing.expectf(t, got == c.want, "%s: got %q, want %q", c.name, got, c.want)
	}
}

@(test)
test_sanitizer_result_does_not_depend_on_chunk_boundaries :: proc(t: ^testing.T) {
	input := "a\xc3\xa9\r\nb\x1b]0;ti\xe2\x82\xactle\x07c\x1b[1;3\x31m\xe4\xb8\x96\xff\xe2d\x1b\\"
	want, want_err := sanitize_text(input, context.temp_allocator)
	testing.expect_value(t, want_err, nil)
	testing.expect(t, len(want) > 0)

	for split in 0 ..= len(input) {
		sanitizer: Sanitizer
		buffer := make([dynamic]u8, context.temp_allocator)
		testing.expect_value(t, sanitizer_write(&sanitizer, &buffer, input[:split]), nil)
		testing.expect_value(t, sanitizer_write(&sanitizer, &buffer, input[split:]), nil)
		testing.expect_value(t, sanitizer_flush(&sanitizer, &buffer), nil)
		testing.expectf(t, string(buffer[:]) == want, "split at %d: got %q, want %q", split, string(buffer[:]), want)
	}

	sanitizer: Sanitizer
	buffer := make([dynamic]u8, context.temp_allocator)
	for i in 0 ..< len(input) {
		testing.expect_value(t, sanitizer_write(&sanitizer, &buffer, input[i:i + 1]), nil)
	}
	testing.expect_value(t, sanitizer_flush(&sanitizer, &buffer), nil)
	testing.expectf(t, string(buffer[:]) == want, "byte by byte: got %q, want %q", string(buffer[:]), want)
}
