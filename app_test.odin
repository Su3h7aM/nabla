#+test
#+private file
package main

import "core:sync/chan"
import "core:testing"
import "core:time"

import "nabla:agent"
import "nabla:ai"
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

// A stopped runtime refuses new work at the front-end, so a command typed while
// the harness is shutting down is dropped rather than queued for a worker that
// will abandon it.
@(test)
test_stopping_refuses_queued_work :: proc(t: ^testing.T) {
	app: App
	app.run.alloc = context.allocator
	channel, channel_err := chan.create_buffered(Work_Chan, 4, app.run.alloc)
	if channel_err != nil { testing.fail_now(t, "the work channel could not be created") }
	app.run.work = channel
	defer chan.destroy(&app.run.work)

	enqueue(&app, .Prompt, "", "queued before the stop")
	stop_runtime(&app)
	enqueue(&app, .Prompt, "", "refused after the stop")
	testing.expect(t, runtime_stopping(&app))

	queued, ok := chan.recv(app.run.work)
	if !testing.expect(t, ok) { return }
	testing.expect_value(t, queued.text, "queued before the stop")
	work_destroy(&app, queued)

	_, more := chan.try_recv(app.run.work)
	testing.expect(t, !more, "nothing may be accepted after the runtime stops")
}

// A scheduled retry is what the working indicator shows, and the send that follows is what
// clears it: the indicator cannot keep claiming a wait that is over.
@(test)
test_a_scheduled_retry_is_shown_until_the_send_clears_it :: proc(t: ^testing.T) {
	app: App
	app.run.alloc = context.allocator
	defer {
		snapshot_clear(&app)
		delete(app.run.snap.entries)
	}

	obs_retry_scheduled(&app, {next_attempt = 2, max_attempts = 3, failure_class = ai.Provider_Failure_Class.Rate_Limited, delay = 2 * time.Second})
	testing.expect(t, app.run.snap.status.retry_present, "the front-end is waiting for a retry")
	testing.expect_value(t, app.run.snap.status.retry_next, 2)
	testing.expect_value(t, app.run.snap.status.retry_max, 3)
	// One notice per scheduled retry, in the transcript the user reads.
	if testing.expect_value(t, len(app.run.snap.entries), 1) {
		testing.expect_value(t, app.run.snap.entries[0].kind, Entry_Kind.Notice)
	}
	testing.expect(t, working_label(&app) != WORKING_LABEL, "the indicator says the turn is waiting for a retry")

	clear_retry(&app)
	testing.expect(t, !app.run.snap.status.retry_present, "the send that followed clears the retry")
	testing.expect_value(t, working_label(&app), WORKING_LABEL)
}
