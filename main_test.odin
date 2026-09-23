#+test
#+private file
package main

import "core:io"
import "core:testing"

// A launch says which session to open through the command line, so the three
// shapes -- nothing, --resume, and --resume with an id -- are the whole contract
// and are worth pinning down without a terminal.

@(test)
test_launch_without_resume_asks_for_a_new_session :: proc(t: ^testing.T) {
	options, ok := chat_cli_parse({})
	if !testing.expect(t, ok) { return }
	testing.expect(t, !options.resume, "no flag means no resume")
	testing.expect_value(t, options.resume_id, "")
}

@(test)
test_bare_resume_asks_for_the_newest_in_the_directory :: proc(t: ^testing.T) {
	options, ok := chat_cli_parse({"--resume"})
	if !testing.expect(t, ok) { return }
	testing.expect(t, options.resume)
	testing.expect_value(t, options.resume_id, "")
}

@(test)
test_resume_takes_an_id_apart_or_joined :: proc(t: ^testing.T) {
	apart, apart_ok := chat_cli_parse({"--resume", "018f2a"})
	if !testing.expect(t, apart_ok) { return }
	testing.expect(t, apart.resume)
	testing.expect_value(t, apart.resume_id, "018f2a")

	joined, joined_ok := chat_cli_parse({"--resume=018f2a"})
	if !testing.expect(t, joined_ok) { return }
	testing.expect(t, joined.resume)
	testing.expect_value(t, joined.resume_id, "018f2a")
}

// A flag after --resume is a flag, not a session id, so the two can be given in
// either order.
@(test)
test_resume_does_not_swallow_a_flag :: proc(t: ^testing.T) {
	options, ok := chat_cli_parse({"--resume", "--list"})
	if !testing.expect(t, ok) { return }
	testing.expect(t, options.resume)
	testing.expect_value(t, options.resume_id, "")
	testing.expect(t, options.list)

	reversed, reversed_ok := chat_cli_parse({"--provider", "p", "--model", "m", "--resume", "abc"})
	if !testing.expect(t, reversed_ok) { return }
	testing.expect(t, reversed.resume)
	testing.expect_value(t, reversed.resume_id, "abc")
	testing.expect_value(t, reversed.provider_id, "p")
	testing.expect_value(t, reversed.model_id, "m")
}

@(test)
test_an_unknown_argument_is_refused :: proc(t: ^testing.T) {
	_, ok := chat_cli_parse({"--nonsense"})
	testing.expect(t, !ok, "an unknown flag must stop the launch")

	_, value_missing_ok := chat_cli_parse({"--config"})
	testing.expect(t, !value_missing_ok, "a flag without its value must stop the launch")
}

// A prompt is the whole instruction for a headless run, so both ways of giving a
// flag its value work, and a missing one is a launch mistake rather than a
// request for the interactive harness.
@(test)
test_prompt_is_taken_apart_or_joined :: proc(t: ^testing.T) {
	apart, apart_ok := chat_cli_parse({"--prompt", "hello"})
	if !testing.expect(t, apart_ok) { return }
	testing.expect_value(t, apart.prompt, "hello")

	joined, joined_ok := chat_cli_parse({"--prompt=hello"})
	if !testing.expect(t, joined_ok) { return }
	testing.expect_value(t, joined.prompt, "hello")

	// Everything a launch can say at once, in one parse.
	together, together_ok := chat_cli_parse({"--config=/tmp/c.lua", "--resume", "abc", "--provider", "p", "--model", "m", "--prompt=go"})
	if !testing.expect(t, together_ok) { return }
	testing.expect_value(t, together.config_path, "/tmp/c.lua")
	testing.expect(t, together.resume)
	testing.expect_value(t, together.resume_id, "abc")
	testing.expect_value(t, together.provider_id, "p")
	testing.expect_value(t, together.model_id, "m")
	testing.expect_value(t, together.prompt, "go")
}

@(test)
test_a_prompt_without_a_value_is_refused :: proc(t: ^testing.T) {
	_, missing_ok := chat_cli_parse({"--prompt"})
	testing.expect(t, !missing_ok, "a prompt flag without a value must stop the launch")

	_, empty_ok := chat_cli_parse({"--prompt="})
	testing.expect(t, !empty_ok, "an empty prompt is a mistake, not a headless run")
}

headless_test_closed_stream :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
	if mode == .Write { return 0, io.Error(.Closed) }
	return 0, .Unsupported
}

@(test)
test_headless_output_latches_a_closed_answer_writer :: proc(t: ^testing.T) {
	out := Headless_Output {
		answer = io.Writer{procedure = headless_test_closed_stream},
	}
	headless_assistant_text(rawptr(&out), "hello")
	headless_assistant_end(rawptr(&out))
	testing.expect(t, out.write_failed, "a closed answer writer must not look successful")
}
