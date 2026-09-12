#+test
#+private file
package main

import "core:testing"

import "nabla:agent"
import "nabla:tui/widgets"

// ctrl_c_app builds the minimum an interrupt reads: the prompt buffer and whether
// a request is running.
ctrl_c_app :: proc(t: ^testing.T, text: string, running: bool) -> App {
	app: App
	app.run.alloc = context.allocator
	widgets.input_init(&app.input, context.allocator)
	testing.expect(t, widgets.input_insert(&app.input, text))
	app.run.snap.status.running = running
	return app
}

// The checks are sequential in one test because the cancellation token is
// process-wide, and reading it from concurrent tests would race.
@(test)
test_ctrl_c_resolves_by_prompt_state :: proc(t: ^testing.T) {
	agent.chat_cancel_reset()
	defer agent.chat_cancel_reset()

	// Text in the prompt is discarded first, whether or not a request is running,
	// and nothing else may happen: no cancel, no exit.
	for running in ([]bool{false, true}) {
		app := ctrl_c_app(t, "half-written", running)
		interrupt(&app)
		testing.expect_value(t, widgets.input_text(&app.input), "")
		testing.expect(t, !app.quit)
		testing.expect(t, !app.cancel_seen)
		testing.expect(t, !agent.chat_cancel_requested())
		widgets.input_destroy(&app.input)
	}

	// The order the presses arrive in: the first clears the prompt, and only the
	// next one cancels the request that is still running.
	sequence := ctrl_c_app(t, "composing a prompt", true)
	defer widgets.input_destroy(&sequence.input)
	interrupt(&sequence)
	testing.expect_value(t, widgets.input_text(&sequence.input), "")
	testing.expect(t, !agent.chat_cancel_requested())
	testing.expect(t, !sequence.cancel_seen)
	testing.expect(t, !sequence.quit)

	interrupt(&sequence)
	testing.expect(t, agent.chat_cancel_requested())
	testing.expect(t, sequence.cancel_seen)
	testing.expect(t, !sequence.quit)

	// An empty prompt with a request running cancels it, and the cancel is
	// remembered as this front-end's own so the retirement that follows ends the
	// turn rather than the session.
	running := ctrl_c_app(t, "", true)
	defer widgets.input_destroy(&running.input)
	interrupt(&running)
	testing.expect(t, running.cancel_seen)
	testing.expect(t, !running.quit)

	// An empty prompt with nothing running exits.
	idle := ctrl_c_app(t, "", false)
	defer widgets.input_destroy(&idle.input)
	interrupt(&idle)
	testing.expect(t, idle.quit)
	testing.expect(t, !idle.cancel_seen)
}
