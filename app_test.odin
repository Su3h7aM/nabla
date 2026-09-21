#+test
#+private file
package main

import "core:mem"
import "core:os"
import "core:strings"
import "core:sync/chan"
import "core:testing"
import "core:time"

import "nabla:agent"
import "nabla:ai"
import input "nabla:input"
import "nabla:tui/widgets"

CATALOG_PIPELINE_MODELS_DEV :: `{"test-provider":{"id":"test-provider","models":{"discovered-model":{"id":"discovered-model","limit":{"context":128000,"output":4096},"tool_call":true,"reasoning":true,"reasoning_options":[{"type":"effort","values":["low","high"]}]}}}}`

catalog_pipeline_provider_fetch :: proc(_: rawptr, _: string, _: string, allocator: mem.Allocator) -> ([]u8, bool) {
	body := `{"data":[{"id":"discovered-model"}]}`
	bytes := make([]u8, len(body), allocator)
	copy(bytes, body)
	return bytes, true
}

catalog_pipeline_models_dev_fetch :: proc(_: rawptr, allocator: mem.Allocator) -> ([]u8, bool) {
	bytes := make([]u8, len(CATALOG_PIPELINE_MODELS_DEV), allocator)
	copy(bytes, CATALOG_PIPELINE_MODELS_DEV)
	return bytes, true
}

catalog_pipeline_models_dev_unreachable :: proc(_: rawptr, _: mem.Allocator) -> ([]u8, bool) { return nil, false }

// Catalog_Pipeline_Fixture is the smallest app a refresh runs in: an isolated
// cache directory, one configured provider, and the catalog the startup path
// would have published before any refresh. catalog_pipeline_end releases it.
Catalog_Pipeline_Fixture :: struct {
	app:          App,
	user:         []agent.Catalog_Provider_Source,
	cache:        string,
	previous:     string,
	had_previous: bool,
}

catalog_pipeline_app :: proc(t: ^testing.T) -> Catalog_Pipeline_Fixture {
	fixture: Catalog_Pipeline_Fixture
	cache, cache_err := os.make_directory_temp("", "nabla-catalog-pipeline-*", context.allocator)
	if cache_err != nil { testing.fail_now(t, "could not create a cache directory") }
	fixture.cache = cache
	fixture.previous, fixture.had_previous = os.lookup_env("XDG_CACHE_HOME", context.allocator)
	os.set_env("XDG_CACHE_HOME", cache)

	fixture.user = make([]agent.Catalog_Provider_Source, 1, context.allocator)
	fixture.user[0] = agent.Catalog_Provider_Source {
		id               = "test-provider",
		base_url_present = true,
		base_url         = "http://provider.test/v1",
		api_present      = true,
		api              = "openai_chat_completions",
		api_key_present  = true,
		api_key          = "test-key",
	}
	fixture.app.run.alloc = context.allocator
	fixture.app.catalog_sources = fixture.user
	fixture.app.retired_catalogs.allocator = context.allocator
	initial, initial_err := agent.resolve_catalog(fixture.user, {}, {}, context.allocator)
	if initial_err != agent.Catalog_Error.None { testing.fail_now(t, "the fixture catalog did not resolve") }
	fixture.app.setup.catalog = initial
	return fixture
}

catalog_pipeline_end :: proc(fixture: ^Catalog_Pipeline_Fixture) {
	agent.catalog_destroy(&fixture.app.setup.catalog)
	catalog_retired_destroy(&fixture.app)
	if fixture.had_previous {
		os.set_env("XDG_CACHE_HOME", fixture.previous)
	} else {
		os.unset_env("XDG_CACHE_HOME")
	}
	delete(fixture.previous, context.allocator)
	os.remove_all(fixture.cache)
	delete(fixture.cache, context.allocator)
	delete(fixture.user)
	fixture^ = {}
}

@(test)
test_catalog_refresh_publishes_one_complete_pipeline :: proc(t: ^testing.T) {
	fixture := catalog_pipeline_app(t)
	defer catalog_pipeline_end(&fixture)
	app := &fixture.app

	catalog_refresh_with(app, catalog_pipeline_provider_fetch, catalog_pipeline_models_dev_fetch)

	// Provider discovery must never become a visible stage-two catalog. One
	// revision means the worker published only after Models.dev enriched the model.
	testing.expect_value(t, app.catalog_revision, u64(1))
	model_index, found := agent.catalog_find_model(&app.setup.catalog, "test-provider", "discovered-model")
	if !testing.expect(t, found, "the provider model should be present") { return }
	model := &app.setup.catalog.models[model_index]
	testing.expect_value(t, model.context_window, 128_000)
	testing.expect(t, model.tools_present && model.tools)
	testing.expect_value(t, len(model.thinking.levels), 2)
	testing.expect_value(t, model.thinking.levels[1], "high")
}

// A refresh that acquires nothing must leave the enrichment the catalog already
// has: a request that failed cannot take reasoning controls away from a model.
@(test)
test_catalog_refresh_keeps_the_enrichment_a_failed_request_could_not_replace :: proc(t: ^testing.T) {
	fixture := catalog_pipeline_app(t)
	defer catalog_pipeline_end(&fixture)
	app := &fixture.app

	catalog_refresh_with(app, catalog_pipeline_provider_fetch, catalog_pipeline_models_dev_fetch)

	// A stray document in the cache, and a models.dev that cannot be reached.
	path, path_err := agent.models_dev_cache_path(context.temp_allocator)
	if !testing.expect_value(t, path_err, agent.Models_Dev_Error.None) { return }
	stray := `{"stray":{"id":"stray","models":{"stray/model":{"id":"stray/model"}}}}`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)stray) == nil)

	catalog_refresh_with(app, catalog_pipeline_provider_fetch, catalog_pipeline_models_dev_unreachable)

	model_index, found := agent.catalog_find_model(&app.setup.catalog, "test-provider", "discovered-model")
	if !testing.expect(t, found, "the model stays in the catalog") { return }
	testing.expect_value(t, len(app.setup.catalog.models[model_index].thinking.levels), 2)
}

@(test)
test_catalog_source_merge_keeps_providers_missing_from_a_refresh :: proc(t: ^testing.T) {
	allocator := context.allocator
	current: [dynamic]agent.Catalog_Provider_Source
	current.allocator = allocator
	first_models := make([]agent.Catalog_Model_Source, 1, allocator)
	first_models[0].id = strings.clone("old", allocator)
	second_models := make([]agent.Catalog_Model_Source, 1, allocator)
	second_models[0].id = strings.clone("kept", allocator)
	append(&current, agent.Catalog_Provider_Source{id = strings.clone("first", allocator), models = first_models})
	append(&current, agent.Catalog_Provider_Source{id = strings.clone("second", allocator), models = second_models})
	incoming: [dynamic]agent.Catalog_Provider_Source
	incoming.allocator = allocator
	incoming_models := make([]agent.Catalog_Model_Source, 1, allocator)
	incoming_models[0].id = strings.clone("new", allocator)
	append(&incoming, agent.Catalog_Provider_Source{id = strings.clone("first", allocator), models = incoming_models})
	defer agent.catalog_sources_destroy(&current, allocator)

	catalog_sources_merge(&current, &incoming, allocator)
	testing.expect_value(t, len(current), 2)
	testing.expect_value(t, current[0].models[0].id, "new")
	testing.expect_value(t, current[1].models[0].id, "kept")
	testing.expect_value(t, len(incoming), 0)
}

@(test)
test_working_duration_changes_units_at_boundaries :: proc(t: ^testing.T) {
	cases := []struct {
		seconds:  i64,
		expected: string,
	}{{-1, "0s"}, {0, "0s"}, {59, "59s"}, {60, "1m 0s"}, {61, "1m 1s"}, {3599, "59m 59s"}, {3600, "1h 0m 0s"}, {3661, "1h 1m 1s"}, {36000, "10h 0m 0s"}}
	for test_case in cases {
		testing.expect_value(t, working_duration(test_case.seconds), test_case.expected)
	}
}

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

	enqueue(&app, .Prompt, "queued before the stop")
	stop_runtime(&app)
	enqueue(&app, .Prompt, "refused after the stop")
	testing.expect(t, runtime_stopping(&app))

	queued, ok := chan.recv(app.run.work)
	if !testing.expect(t, ok) { return }
	testing.expect_value(t, queued.text, "queued before the stop")
	work_destroy(&app, queued)

	_, more := chan.try_recv(app.run.work)
	testing.expect(t, !more, "nothing may be accepted after the runtime stops")
}

// A tool box shows what the call produced, not the envelope the model reads: the
// preview is taken from the result's data and its JSON escapes are decoded.
@(test)
test_tool_display_preview_extracts_and_decodes_shell_output :: proc(t: ^testing.T) {
	content := `{"status":"success","message":"done","data":{"stdout":"first\nsecond\n","stderr":""}}`
	testing.expect_value(t, tool_display_preview(content), "first\nsecond\n")
	testing.expect_value(t, tool_entry_text("builtin_shell", content, "success"), "builtin_shell\nfirst\nsecond\n")
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

	app.run.snap.status.working_since = time.tick_now()
	obs_retry_scheduled(&app, {next_attempt = 2, max_attempts = 3, failure_class = ai.Provider_Failure_Class.Rate_Limited, delay = 2 * time.Second})
	testing.expect(t, app.run.snap.status.retry_present, "the front-end is waiting for a retry")
	testing.expect_value(t, app.run.snap.status.retry_next, 2)
	testing.expect_value(t, app.run.snap.status.retry_max, 3)
	// One notice per scheduled retry, in the transcript the user reads.
	if testing.expect_value(t, len(app.run.snap.entries), 1) {
		testing.expect_value(t, app.run.snap.entries[0].kind, Entry_Kind.Notice)
	}
	testing.expect(t, strings.has_prefix(working_label(&app), "Working for "), "the indicator keeps the turn timer during a retry")

	clear_retry(&app)
	testing.expect(t, !app.run.snap.status.retry_present, "the send that followed clears the retry")
	testing.expect(t, strings.has_prefix(working_label(&app), "Working for "), "clearing retry state does not reset the turn timer")
}

// Input the user queued while a turn ran, and the turn ended before a request boundary
// could apply it, is still their text. It goes back to the prompt for an explicit submit
// rather than starting a turn of its own, and it does not stay in the queue for a later
// boundary to apply as well.
@(test)
test_unapplied_steering_returns_to_the_prompt :: proc(t: ^testing.T) {
	app: App
	app.run.alloc = context.allocator
	app.run.steer = agent.steer_queue_init(app.run.alloc)
	defer {
		agent.steer_queue_destroy(&app.run.steer)
		snapshot_clear(&app)
		delete(app.run.snap.entries)
		widgets.input_destroy(&app.input)
	}
	widgets.input_init(&app.input, app.run.alloc)

	testing.expect(t, agent.steer_push(&app.run.steer, "check the logs"))
	testing.expect(t, agent.steer_push(&app.run.steer, "and the config"))
	restore_steering(&app)

	testing.expect_value(t, widgets.input_text(&app.input), "check the logs\nand the config")
	if !testing.expect_value(t, len(app.run.snap.entries), 1) { return }
	testing.expect_value(t, app.run.snap.entries[0].kind, Entry_Kind.Notice)
	testing.expect_value(t, agent.steer_clear(&app.run.steer), 0)
}

// A pasted block keeps its line breaks, so a multi-line paste stays the block it
// was. CR and CRLF are read as the one break they mean and the other controls are
// still dropped.
@(test)
test_paste_keeps_line_breaks :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.run.alloc = context.allocator
	widgets.input_init(&app.input, context.allocator)
	defer widgets.input_destroy(&app.input)

	paste_insert(app, "first\r\nsecond\nthird\tend\x07")
	testing.expect_value(t, widgets.input_text(&app.input), "first\nsecond\nthirdend")
}

// The arrow keys move the caret between the prompt's rows, so a multi-line prompt
// can be edited without leaving the keyboard. The column is kept where the row
// reaches it and falls to that row's end where it does not.
@(test)
test_arrow_keys_move_between_prompt_rows :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.run.alloc = context.allocator
	app.columns = 40
	widgets.input_init(&app.input, context.allocator)
	defer widgets.input_destroy(&app.input)

	paste_insert(app, "one\ntwo\nthree")
	testing.expect_value(t, widgets.input_cursor(&app.input), len("one\ntwo\nthree"))

	handle_key(app, input.Key_Event{code = .Up})
	testing.expect_value(t, widgets.input_cursor(&app.input), len("one\ntwo"))
	handle_key(app, input.Key_Event{code = .Up})
	testing.expect_value(t, widgets.input_cursor(&app.input), len("one"))
	handle_key(app, input.Key_Event{code = .Down})
	testing.expect_value(t, widgets.input_cursor(&app.input), len("one\ntwo"))
}
