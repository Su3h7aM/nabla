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
