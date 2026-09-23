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
	options, parse_error := chat_cli_parse({})
	if !testing.expect_value(t, parse_error, Cli_Parse_Error.None) { return }
	testing.expect(t, !options.resume, "no flag means no resume")
	testing.expect_value(t, options.resume_id, "")
}

@(test)
test_bare_resume_asks_for_the_newest_in_the_directory :: proc(t: ^testing.T) {
	options, parse_error := chat_cli_parse({"--resume"})
	if !testing.expect_value(t, parse_error, Cli_Parse_Error.None) { return }
	testing.expect(t, options.resume)
	testing.expect_value(t, options.resume_id, "")
}

@(test)
test_resume_takes_an_id_apart_or_joined :: proc(t: ^testing.T) {
	apart, parse_error := chat_cli_parse({"--resume", "018f2a"})
	if !testing.expect_value(t, parse_error, Cli_Parse_Error.None) { return }
	testing.expect(t, apart.resume)
	testing.expect_value(t, apart.resume_id, "018f2a")

	joined, joined_error := chat_cli_parse({"--resume=018f2a"})
	if !testing.expect_value(t, joined_error, Cli_Parse_Error.None) { return }
	testing.expect(t, joined.resume)
	testing.expect_value(t, joined.resume_id, "018f2a")
}

// A flag after --resume is a flag, not a session id, so the two can be given in
// either order.
@(test)
test_resume_does_not_swallow_a_flag :: proc(t: ^testing.T) {
	options, parse_error := chat_cli_parse({"--resume", "--list"})
	if !testing.expect_value(t, parse_error, Cli_Parse_Error.None) { return }
	testing.expect(t, options.resume)
	testing.expect_value(t, options.resume_id, "")
	testing.expect(t, options.list)

	reversed, reversed_error := chat_cli_parse({"--provider", "p", "--model", "m", "--resume", "abc"})
	if !testing.expect_value(t, reversed_error, Cli_Parse_Error.None) { return }
	testing.expect(t, reversed.resume)
	testing.expect_value(t, reversed.resume_id, "abc")
	testing.expect_value(t, reversed.provider_id, "p")
	testing.expect_value(t, reversed.model_id, "m")
}

@(test)
test_an_unknown_argument_is_refused :: proc(t: ^testing.T) {
	_, parse_error := chat_cli_parse({"--nonsense"})
	testing.expect_value(t, parse_error, Cli_Parse_Error.Unknown_Option)

	_, parse_error = chat_cli_parse({"--config"})
	testing.expect_value(t, parse_error, Cli_Parse_Error.Missing_Value)
}

// A prompt is the whole instruction for a headless run, so both ways of giving a
// flag its value work, and a missing one is a launch mistake rather than a
// request for the interactive harness.
@(test)
test_prompt_is_taken_apart_or_joined :: proc(t: ^testing.T) {
	apart, parse_error := chat_cli_parse({"--prompt", "hello"})
	if !testing.expect_value(t, parse_error, Cli_Parse_Error.None) { return }
	testing.expect_value(t, apart.prompt, "hello")

	joined, joined_error := chat_cli_parse({"--prompt=hello"})
	if !testing.expect_value(t, joined_error, Cli_Parse_Error.None) { return }
	testing.expect_value(t, joined.prompt, "hello")

	// Everything a launch can say at once, in one parse.
	together, together_error := chat_cli_parse({"--config=/tmp/c.lua", "--resume", "abc", "--provider", "p", "--model", "m", "--prompt=go"})
	if !testing.expect_value(t, together_error, Cli_Parse_Error.None) { return }
	testing.expect_value(t, together.config_path, "/tmp/c.lua")
	testing.expect(t, together.resume)
	testing.expect_value(t, together.resume_id, "abc")
	testing.expect_value(t, together.provider_id, "p")
	testing.expect_value(t, together.model_id, "m")
	testing.expect_value(t, together.prompt, "go")
}

@(test)
test_a_prompt_without_a_value_is_refused :: proc(t: ^testing.T) {
	_, parse_error := chat_cli_parse({"--prompt"})
	testing.expect_value(t, parse_error, Cli_Parse_Error.Missing_Value)

	_, parse_error = chat_cli_parse({"--prompt="})
	testing.expect_value(t, parse_error, Cli_Parse_Error.Empty_Prompt)
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
