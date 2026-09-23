#+test
#+private file
package main

import "core:testing"

_sanitize_one :: proc(t: ^testing.T, chunk: string) -> string {
	san: Display_Sanitizer
	cleaned := display_sanitize_chunk(&san, chunk, context.temp_allocator)
	tail := display_sanitize_flush(&san, context.temp_allocator)
	testing.expect_value(t, tail, "")
	return cleaned
}

@(test)
test_sanitize_strips_control_sequences :: proc(t: ^testing.T) {
	// Escape sequences and other control bytes are dropped; tab is kept.
	testing.expect_value(t, _sanitize_one(t, "a\x1b[2K b"), "a b")
	testing.expect_value(t, _sanitize_one(t, "x\x1b]0;title\x07y"), "xy")
	testing.expect_value(t, _sanitize_one(t, "m\x1b[1;32mgreen\x1b[0m."), "mgreen.")
	testing.expect_value(t, _sanitize_one(t, "bell\x07here"), "bellhere")
	testing.expect_value(t, _sanitize_one(t, "del\x7fhere"), "delhere")
	testing.expect_value(t, _sanitize_one(t, "keep\tthis"), "keep\tthis")

	// A carriage return becomes a line feed, whether or not LF follows.
	testing.expect_value(t, _sanitize_one(t, "a\r\nb"), "a\nb")
	testing.expect_value(t, _sanitize_one(t, "a\rb"), "a\nb")

	// An invalid byte becomes the replacement character.
	testing.expect_value(t, _sanitize_one(t, "a\xffi"), "a\uFFFDi")

	// Reject encodings with valid-looking continuation bytes but invalid scalar
	// values. The sanitizer must not pass overlong, surrogate, or out-of-range
	// sequences through as if they were text.
	testing.expect_value(t, _sanitize_one(t, "\xE0\x80\x80"), "\uFFFD\uFFFD\uFFFD")
	testing.expect_value(t, _sanitize_one(t, "\xED\xA0\x80"), "\uFFFD\uFFFD\uFFFD")
	testing.expect_value(t, _sanitize_one(t, "\xF4\x90\x80\x80"), "\uFFFD\uFFFD\uFFFD\uFFFD")

	// A deliberately encoded U+FFFD is valid UTF-8 and remains one rune.
	testing.expect_value(t, _sanitize_one(t, "\xEF\xBF\xBD"), "\uFFFD")
}

@(test)
test_sanitize_state_across_chunks :: proc(t: ^testing.T) {
	// An escape sequence split across chunks is dropped.
	san: Display_Sanitizer
	testing.expect_value(t, display_sanitize_chunk(&san, "a\x1b", context.temp_allocator), "a")
	testing.expect_value(t, display_sanitize_chunk(&san, "[2K b", context.temp_allocator), " b")
	testing.expect_value(t, display_sanitize_flush(&san, context.temp_allocator), "")

	// A multi-byte rune split across chunks is completed.
	split: Display_Sanitizer
	testing.expect_value(t, display_sanitize_chunk(&split, "caf\xc3", context.temp_allocator), "caf")
	testing.expect_value(t, display_sanitize_chunk(&split, "\xa9!", context.temp_allocator), "é!")
	testing.expect_value(t, display_sanitize_flush(&split, context.temp_allocator), "")

	// Flush ends a dangling escape sequence.
	dangling: Display_Sanitizer
	testing.expect_value(t, display_sanitize_chunk(&dangling, "a\x1b[2", context.temp_allocator), "a")
	testing.expect_value(t, display_sanitize_flush(&dangling, context.temp_allocator), "")
}
