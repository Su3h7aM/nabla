#+test
#+private file
package main

import "core:strings"
import "core:testing"

@(test)
test_codemode_arguments_preview_is_a_bounded_utf8_line :: proc(t: ^testing.T) {
	testing.expect_value(t, codemode_arguments_preview(" \tfirst\u2003\n\u00a0 second\r "), "first second")
	testing.expect_value(t, codemode_arguments_preview("a\xffb"), "a\uFFFDb")
	prefix: [79]u8
	for &byte in prefix { byte = 'a' }
	testing.expect_value(
		t,
		codemode_arguments_preview(strings.concatenate({string(prefix[:]), "é"}, context.temp_allocator)),
		strings.concatenate({string(prefix[:]), "…"}, context.temp_allocator),
	)
	huge := make([]u8, 1_000_000, context.temp_allocator)
	for &byte in huge { byte = 'x' }
	testing.expect_value(t, codemode_arguments_preview(string(huge)), strings.concatenate({string(huge[:80]), "…"}, context.temp_allocator))
}

_sanitize_one :: proc(t: ^testing.T, chunk: string) -> string {
	sanitizer: Display_Sanitizer
	cleaned := display_sanitize_chunk(&sanitizer, chunk, context.temp_allocator)
	tail := display_sanitize_flush(&sanitizer, context.temp_allocator)
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
	sanitizer: Display_Sanitizer
	testing.expect_value(t, display_sanitize_chunk(&sanitizer, "a\x1b", context.temp_allocator), "a")
	testing.expect_value(t, display_sanitize_chunk(&sanitizer, "[2K b", context.temp_allocator), " b")
	testing.expect_value(t, display_sanitize_flush(&sanitizer, context.temp_allocator), "")

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

@(test)
test_retry_display_names_the_omitted_optional_feature :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		retry_display_text({failure_class = .Invalid_Request, reason = .Adaptive_Thinking_Refused, next_attempt = 2}),
		"the endpoint refused the request; sending it again without adaptive thinking in case that caused it; retrying in 0.0s (attempt 2)",
	)
	testing.expect_value(
		t,
		retry_display_text({failure_class = .Invalid_Request, reason = .Cache_Hints_Refused, next_attempt = 2}),
		"the endpoint refused the request; sending it again without its cache hints in case they caused it; retrying in 0.0s (attempt 2)",
	)
}

@(test)
test_agent_start_entry_shows_only_the_prompt :: proc(t: ^testing.T) {
	content := "ok\nexit_code: 3\n\nstdout:\nfirst\nsecond\n"
	preview := "shell\nstdout:\nfirst\nsecond\n"
	start := `{"action":"start","prompt":"inspect the parser"}`
	testing.expect_value(t, tool_entry_text(tool_display_call("agent", start), content, "success", .Success), "agent\ninspect the parser")

	// A stop call and any other tool show the result preview, never the arguments.
	testing.expect_value(
		t,
		tool_entry_text(tool_display_call("agent", `{"action":"stop","agent":"agent-1"}`), content, "success", .Success),
		"agent\nstdout:\nfirst\nsecond\n",
	)
	testing.expect_value(t, tool_entry_text(tool_display_call("shell", start), content, "success", .Success), preview)

	// A start without a usable prompt falls back to the box other calls show: a
	// missing, null, malformed, or mistyped prompt is no prompt.
	without_prompt := []string {
		`{"action":"start"}`,
		`{"action":"start","prompt":null}`,
		`{"action":"start","prompt":42}`,
		`{"action":"start","prompt":" \n"}`,
		`{"action":"start","prompt":`,
		`not json`,
	}
	for arguments in without_prompt {
		testing.expect_value(t, tool_entry_text(tool_display_call("agent", arguments), content, "success", .Success), "agent\nstdout:\nfirst\nsecond\n")
	}
	// With no prompt and no result body, the box is the outcome fallback.
	testing.expect_value(t, tool_entry_text(tool_display_call("agent", `{"action":"start"}`), "", "success", .Success), "agent\nsuccess")

	// A failed start shows the prompt and then the failure reason: the body of the
	// rendered result, or the outcome fallback when the result has no body.
	testing.expect_value(
		t,
		tool_entry_text(tool_display_call("agent", start), "unknown_model: no such model", "unknown", .Unknown),
		"agent\ninspect the parser\nno such model",
	)
	testing.expect_value(
		t,
		tool_entry_text(tool_display_call("agent", start), "unknown", "unknown model", .Unknown),
		"agent\ninspect the parser\nunknown model",
	)
}
