#+test
#+private file
package main

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
