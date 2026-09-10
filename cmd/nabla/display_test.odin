package main

import "core:testing"

sanitize_one :: proc(t: ^testing.T, chunk: string) -> string {
	san := Display_Sanitizer{}
	cleaned := display_sanitize_chunk(&san, chunk, context.temp_allocator)
	tail := display_sanitize_flush(&san, context.temp_allocator)
	testing.expect_value(t, tail, "")
	return cleaned
}

@(test)
test_sanitize_drops_escape_sequences :: proc(t: ^testing.T) {
	testing.expect_value(t, sanitize_one(t, "a\x1b[2K b"), "a b")
	testing.expect_value(t, sanitize_one(t, "x\x1b]0;title\x07y"), "xy")
	testing.expect_value(t, sanitize_one(t, "m\x1b[1;32mgreen\x1b[0m."), "mgreen.")
	testing.expect_value(t, sanitize_one(t, "bell\x07here"), "bellhere")
	testing.expect_value(t, sanitize_one(t, "del\x7fhere"), "delhere")
	testing.expect_value(t, sanitize_one(t, "keep\tthis"), "keep\tthis")
}

@(test)
test_sanitize_handles_carriage_returns :: proc(t: ^testing.T) {
	testing.expect_value(t, sanitize_one(t, "a\r\nb"), "a\nb")
	testing.expect_value(t, sanitize_one(t, "a\rb"), "a\nb")
}

@(test)
test_sanitize_keeps_state_across_chunks :: proc(t: ^testing.T) {
	san := Display_Sanitizer{}
	first := display_sanitize_chunk(&san, "a\x1b", context.temp_allocator)
	testing.expect_value(t, first, "a")
	second := display_sanitize_chunk(&san, "[2K b", context.temp_allocator)
	testing.expect_value(t, second, " b")
	tail := display_sanitize_flush(&san, context.temp_allocator)
	testing.expect_value(t, tail, "")
}

@(test)
test_sanitize_completes_split_runes :: proc(t: ^testing.T) {
	san := Display_Sanitizer{}
	first := display_sanitize_chunk(&san, "caf\xc3", context.temp_allocator)
	testing.expect_value(t, first, "caf")
	second := display_sanitize_chunk(&san, "\xa9!", context.temp_allocator)
	testing.expect_value(t, second, "é!")
	tail := display_sanitize_flush(&san, context.temp_allocator)
	testing.expect_value(t, tail, "")
}

@(test)
test_sanitize_replaces_invalid_bytes :: proc(t: ^testing.T) {
	testing.expect_value(t, sanitize_one(t, "a\xffi"), "a�i")
}

@(test)
test_sanitize_flush_ends_dangling_state :: proc(t: ^testing.T) {
	san := Display_Sanitizer{}
	first := display_sanitize_chunk(&san, "a\x1b[2", context.temp_allocator)
	testing.expect_value(t, first, "a")
	tail := display_sanitize_flush(&san, context.temp_allocator)
	testing.expect_value(t, tail, "")
}
