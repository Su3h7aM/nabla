#+test
#+private file
package main

import "core:fmt"
import "core:io"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:agent"
import "nabla:agent/session"
import "nabla:ai"
import "nabla:tui/widgets"

// The session commands are the only part of the front-end that owns a store, so
// they are driven here without a terminal: a store, a running session, and the
// snapshot they append to.

// app_session_capacity gives a session the budget a resolved model with this window
// and output bound would carry, so a fixture never states the window arithmetic
// itself.
app_session_capacity :: proc(app: ^App, window: int, output := 0) {
	app.setup.session.capacity = agent.model_capacity(
		agent.Catalog_Model{context_window_present = true, context_window = window, max_output_tokens_present = output > 0, max_output_tokens = output},
	)
}

app_session_begin :: proc(t: ^testing.T, app: ^App) -> string {
	directory, directory_err := os.make_directory_temp("", "nabla-app-test-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "could not create a temporary directory") }
	// The workspace has to be a real directory: a switch checks that a session's
	// recorded directory is still usable before opening it.
	workspace, workspace_err := os.make_directory_temp("", "nabla-app-workspace-*", context.allocator)
	if workspace_err != nil { testing.fail_now(t, "could not create a temporary workspace") }

	app.run.alloc = context.allocator
	app.setup.alloc = context.allocator
	app.run.snap.entries = make([dynamic]Entry, 0, 4, app.run.alloc)

	if store_err := session.store_open(&app.setup.store, directory); store_err != nil {
		testing.fail_now(t, "store_open failed")
	}
	created, create_err := session.session_create(&app.setup.store, {workspace = workspace}, 1_000)
	if create_err != nil { testing.fail_now(t, "session_create failed") }
	id := session.Session_Id(strings.clone(string(created.id), context.allocator))
	session.session_destroy(&created)
	if claim_err := session.session_claim(&app.setup.store, id); claim_err != nil {
		testing.fail_now(t, "session_claim failed")
	}
	delete(string(id), context.allocator)

	app.setup.workspace = workspace
	claimed, _ := session.session_claimed(&app.setup.store)
	app.setup.session = agent.chat_session_init(&app.setup.store, claimed, workspace, context.allocator)
	app.setup.session.skill_instructions = agent.test_skill_instructions(&app.setup.session)
	return directory
}

app_session_end :: proc(app: ^App, directory: string) {
	agent.chat_session_destroy(&app.setup.session)
	session.session_release(&app.setup.store)
	session.store_close(&app.setup.store)
	for &entry in app.run.snap.entries {
		if entry.text != nil { delete(entry.text) }
	}
	delete(app.run.snap.entries)
	for &row in app.run.snap.sessions {
		delete(string(row.id), app.run.alloc)
		delete(row.title, app.run.alloc)
	}
	delete(app.run.snap.sessions)
	delete(string(app.run.snap.active_session), app.run.alloc)
	delete(app.run.snap.status.provider_id, app.run.alloc)
	delete(app.run.snap.status.model_id, app.run.alloc)
	delete(app.run.snap.status.effort, app.run.alloc)
	delete(app.run.snap.status.cwd, app.run.alloc)
	for level in app.run.snap.status.effort_levels { delete(level, app.run.alloc) }
	delete(app.run.snap.status.effort_levels)
	delete(app.run.snap.setup_error, app.run.alloc)
	menu_destroy(&app.menu, app.run.alloc)
	// The run's catalog-side state belongs to the same teardown: an endpoint a
	// selection copied, and the refresh snapshots.
	catalog_run_destroy(app)
	os.remove_all(app.setup.workspace)
	delete(app.setup.workspace, app.setup.alloc)
	delete(app.setup.resumed_provider, app.setup.alloc)
	delete(app.setup.resumed_model, app.setup.alloc)
	delete(app.setup.provider_id, app.setup.alloc)
	delete(app.setup.model_id, app.setup.alloc)
	delete(app.setup.credential, app.setup.alloc)
	os.remove_all(directory)
	delete(directory, context.allocator)
}

// attach_setup_destroy releases what run_session_attach built, without the
// catalog teardown an empty setup does not need.
attach_setup_destroy :: proc(setup: ^Run_Setup) {
	agent.chat_session_destroy(&setup.session)
	session.session_release(&setup.store)
	session.store_close(&setup.store)
	_ = run_log_close(setup)
	delete(setup.workspace, setup.alloc)
	delete(setup.resumed_provider, setup.alloc)
	delete(setup.resumed_model, setup.alloc)
	setup^ = {}
}

// The whole open path, as a launch drives it: a new session each time, the
// newest for this directory on a bare resume, and one named session by id.
@(test)
test_a_launch_opens_only_the_session_it_asked_for :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	err_text: strings.Builder
	defer strings.builder_destroy(&err_text)
	state, previous, had_previous := app_state_isolate(t)
	defer app_state_restore(state, previous, had_previous)

	workspace, workspace_err := os.get_working_directory(context.allocator)
	if workspace_err != nil { testing.fail_now(t, "could not read the working directory") }
	defer delete(workspace, context.allocator)

	first_setup: Run_Setup
	first_setup.alloc = context.allocator
	defer attach_setup_destroy(&first_setup)
	if !testing.expect(t, run_session_attach_test(&first_setup, workspace, {kind = .New}, &err_text)) { return }
	first := session.Session_Id(strings.clone(string(first_setup.session.id), context.allocator))
	defer delete(string(first), context.allocator)
	app_session_turn(t, &first_setup)
	attach_setup_destroy(&first_setup)

	// Closing and reopening in one directory asks for a fresh conversation. A
	// millisecond apart, because that is the clock the store orders sessions by,
	// and two sessions created in the same one are ordered by id instead.
	time.sleep(2 * time.Millisecond)
	second_setup: Run_Setup
	second_setup.alloc = context.allocator
	defer attach_setup_destroy(&second_setup)
	if !testing.expect(t, run_session_attach_test(&second_setup, workspace, {kind = .New}, &err_text)) { return }
	second := session.Session_Id(strings.clone(string(second_setup.session.id), context.allocator))
	defer delete(string(second), context.allocator)
	app_session_turn(t, &second_setup)
	attach_setup_destroy(&second_setup)
	testing.expect(t, first != second, "a second launch must start a second session")

	latest_setup: Run_Setup
	latest_setup.alloc = context.allocator
	defer attach_setup_destroy(&latest_setup)
	if !testing.expect(t, run_session_attach_test(&latest_setup, workspace, {kind = .Resume_Latest}, &err_text)) { return }
	testing.expect_value(t, latest_setup.session.id, second)
	testing.expect_value(t, latest_setup.workspace, workspace)
	attach_setup_destroy(&latest_setup)

	named_setup: Run_Setup
	named_setup.alloc = context.allocator
	defer attach_setup_destroy(&named_setup)
	if !testing.expect(t, run_session_attach_test(&named_setup, workspace, {kind = .Resume_Id, id = string(first)}, &err_text)) { return }
	testing.expect_value(t, named_setup.session.id, first)
	attach_setup_destroy(&named_setup)

	// The running session is the one the launch named, and the store is free
	// again after each teardown.
	missing_setup: Run_Setup
	missing_setup.alloc = context.allocator
	testing.expect(
		t,
		!run_session_attach_test(&missing_setup, workspace, {kind = .Resume_Id, id = "00000000000000000000000000000000"}, &err_text),
		"an unknown id must not silently become a new session",
	)
	attach_setup_destroy(&missing_setup)
}

// The stored selection is the user's own last choice, so a launch restores it,
// and a second launch that stores another replaces it rather than adding one.
@(test)
test_a_launch_restores_the_stored_selection :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	app.setup.catalog = app_test_catalog(app.setup.alloc)
	defer agent.catalog_destroy(&app.setup.catalog)

	if err := session.selection_save(&app.setup.store, {provider = "test-provider", model = "test-model", effort = ""}); err != nil {
		testing.fail_now(t, "the selection could not be stored")
	}

	testing.expect(t, apply_startup_selection(&app, "", ""))
	testing.expect_value(t, app.setup.session.provider_id, "test-provider")
	testing.expect_value(t, app.setup.session.model_id, "test-model")
}

// A stored selection outranks the model a resumed session recorded, and the
// session's model is the fallback for a launch that has no selection stored.
@(test)
test_the_stored_selection_outranks_the_session_model :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	app.setup.catalog = app_test_catalog(app.setup.alloc)
	defer agent.catalog_destroy(&app.setup.catalog)
	app.setup.resumed_provider = strings.clone("test-provider", app.setup.alloc)
	app.setup.resumed_model = strings.clone("test-model", app.setup.alloc)

	testing.expect(t, apply_startup_selection(&app, "", ""))
	testing.expect_value(t, app.setup.session.model_id, "test-model")

	// Flags are the launch's own instruction and outrank both.
	testing.expect(t, apply_startup_selection(&app, "test-provider", "test-model"))
	testing.expect_value(t, app.setup.session.model_id, "test-model")
}

// A stale selection is not fatal: the session's model is tried, and a launch
// that can resolve nothing continues to the model menu rather than failing.
@(test)
test_a_stale_selection_falls_back_rather_than_failing :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	app.setup.catalog = app_test_catalog(app.setup.alloc)
	defer agent.catalog_destroy(&app.setup.catalog)
	if err := session.selection_save(&app.setup.store, {provider = "gone", model = "gone"}); err != nil {
		testing.fail_now(t, "the selection could not be stored")
	}
	app.setup.resumed_provider = strings.clone("test-provider", app.setup.alloc)
	app.setup.resumed_model = strings.clone("test-model", app.setup.alloc)

	testing.expect(t, apply_startup_selection(&app, "", ""))
	testing.expect_value(t, app.setup.session.model_id, "test-model")
}

// A launch that can resolve nothing is not a failure: no model is selected, so
// the model menu is what opens.
@(test)
test_a_launch_with_nothing_to_resolve_continues_to_the_menu :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	app.setup.catalog = app_test_catalog(app.setup.alloc)
	defer agent.catalog_destroy(&app.setup.catalog)
	if err := session.selection_save(&app.setup.store, {provider = "gone", model = "gone"}); err != nil {
		testing.fail_now(t, "the selection could not be stored")
	}

	testing.expect(t, apply_startup_selection(&app, "", ""))
	testing.expect_value(t, app.setup.model_id, "")
	// Why the stored selection did not apply is recorded for the menu to show.
	testing.expect(t, app.run.snap.setup_error != "")
}

// One flag without the other is a launch mistake, not something to guess at.
@(test)
test_a_half_given_model_flag_is_refused :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	testing.expect(t, !apply_startup_selection(&app, "test-provider", ""))
	testing.expect(t, !apply_startup_selection(&app, "", "test-model"))
}

// app_session_add creates another session in the store and returns a copy of its
// id, owned by setup.alloc.
app_session_add :: proc(t: ^testing.T, setup: ^Run_Setup, options: session.Create_Options, at_ms: i64) -> session.Session_Id {
	created, err := session.session_create(&setup.store, options, at_ms)
	if err != nil { testing.fail_now(t, "session_create failed") }
	defer session.session_destroy(&created)
	return session.Session_Id(strings.clone(string(created.id), setup.alloc))
}

// app_session_use creates a session and records one turn in it, which is what
// makes it a candidate for a bare resume. The turn needs the writer claim, and
// the fixture's own session holds it, so the claim is swapped for the candidate
// and swapped back, the way a running session switch does it.
app_session_use :: proc(t: ^testing.T, setup: ^Run_Setup, options: session.Create_Options, at_ms: i64) -> session.Session_Id {
	created, err := session.session_create(&setup.store, options, at_ms)
	if err != nil { testing.fail_now(t, "session_create failed") }
	defer session.session_destroy(&created)

	displaced, claim_err := session.session_claim_candidate(&setup.store, created.id)
	if claim_err != nil { testing.fail_now(t, "session_claim_candidate failed") }
	if _, turn_err := session.turn_begin(&setup.store, created.id, "hello", .Prompt, at_ms); turn_err != nil {
		testing.fail_now(t, "turn_begin failed")
	}
	if restore_err := session.session_claim_restore(&setup.store, displaced); restore_err != nil {
		testing.fail_now(t, "session_claim_restore failed")
	}
	return session.Session_Id(strings.clone(string(created.id), setup.alloc))
}

// app_session_count is how many sessions the store holds for a directory, which
// is what says whether a launch left anything behind.
app_session_count :: proc(t: ^testing.T, setup: ^Run_Setup, workspace: string) -> int {
	sessions, list_err := session.session_list(&setup.store, {workspace = workspace})
	if !testing.expect(t, list_err == nil) { return -1 }
	defer session.sessions_destroy(sessions)
	return len(sessions)
}

// app_session_turn admits a prompt into the session a setup already holds and
// claims, which is what records the session and makes it a candidate for a bare
// resume. It goes through the same path the front-end uses, because that path is
// what writes the row.
app_session_turn :: proc(t: ^testing.T, setup: ^Run_Setup) {
	if accepted := agent.chat_session_accept_user(&setup.session, "hello", session.now_ms()); accepted != .Accepted {
		testing.fail_now(t, "the prompt was not accepted")
	}
}

// app_session_accept admits a prompt into the running session and checks that it
// was recorded. A refusal that merely leaves the running session's id looking the
// same is not enough: the session has to still be claimed and writable.
app_session_accept :: proc(t: ^testing.T, app: ^App, text: string) {
	accepted := agent.chat_session_accept_user(&app.setup.session, text, session.now_ms())
	if !testing.expect_value(t, accepted, agent.Chat_Accept.Accepted) { return }

	entries, load_err := session.entries_load(&app.setup.store, app.setup.session.id, {}, context.allocator)
	if !testing.expect(t, load_err == nil, "the running session's history must still be readable") { return }
	defer session.entries_destroy(entries, context.allocator)
	found := false
	for &entry in entries {
		if user, is_user := entry.payload.(session.User_Entry); is_user && user.text == text { found = true }
	}
	testing.expect(t, found, "the running session must still record history")
}

// app_workspace_make creates a directory a session can claim to have run in.
app_workspace_make :: proc(t: ^testing.T) -> string {
	path, err := os.make_directory_temp("", "nabla-app-other-*", context.allocator)
	if err != nil { testing.fail_now(t, "could not create a temporary directory") }
	return path
}

// app_test_catalog is the smallest catalog apply_selection can resolve: one
// usable provider with a literal credential, and one model that states its
// window and supports tools. It goes through resolve_catalog rather than filling
// the resolved lists directly, so a fixture cannot diverge from what resolution
// derives from its sources.
app_test_catalog :: proc(allocator: mem.Allocator) -> agent.Catalog {
	sources := []agent.Catalog_Provider_Source {
		{
			id = "test-provider",
			base_url_present = true,
			base_url = "http://127.0.0.1:1",
			api_present = true,
			api = "openai_chat_completions",
			api_key_present = true,
			api_key = "test-key",
			models = []agent.Catalog_Model_Source {
				{
					id = "test-model",
					context_window_present = true,
					context_window = 128_000,
					max_output_tokens_present = true,
					max_output_tokens = 4_096,
					tools_present = true,
					tools = true,
				},
			},
		},
	}
	catalog, _ := agent.resolve_catalog(sources, {}, {}, allocator)
	return catalog
}

// app_state_isolate points the state directory at a temporary directory, so a
// test that persists a selection or opens the session database cannot touch the
// user's own state. It returns the previous value, which app_state_restore puts
// back. The variable is process-wide, so tests using this helper run isolated
// in a child of the test binary (see isolate_test.odin).
app_state_isolate :: proc(t: ^testing.T) -> (state: string, previous: string, had_previous: bool) {
	directory, directory_err := os.make_directory_temp("", "nabla-app-state-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "could not create a temporary state directory") }
	previous, had_previous = os.lookup_env("XDG_STATE_HOME", context.allocator)
	os.set_env("XDG_STATE_HOME", directory)
	return directory, previous, had_previous
}

app_state_restore :: proc(state, previous: string, had_previous: bool) {
	if had_previous {
		os.set_env("XDG_STATE_HOME", previous)
	} else {
		os.unset_env("XDG_STATE_HOME")
	}
	delete(previous, context.allocator)
	os.remove_all(state)
	delete(state, context.allocator)
}

// session_open_test opens one target against a captured diagnosis writer, so
// the test run stays quiet and the failure text itself is assertable.
session_open_test :: proc(setup: ^Run_Setup, start: Session_Start, workspace: string, err: ^strings.Builder) -> (Session_Target, bool) {
	return session_open_target(setup, start, workspace, strings.to_writer(err))
}

// run_session_attach_test attaches one launch against a captured diagnosis
// writer, for the same reason.
run_session_attach_test :: proc(setup: ^Run_Setup, workspace: string, start: Session_Start, err: ^strings.Builder) -> bool {
	return run_session_attach(setup, workspace, start, strings.to_writer(err))
}

// A launch with nothing to say always starts fresh, so closing and reopening the
// harness in one directory never returns to the conversation that just ended.
@(test)
test_a_launch_without_resume_starts_a_new_session :: proc(t: ^testing.T) {
	err_text: strings.Builder
	defer strings.builder_destroy(&err_text)
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	first, first_ok := session_open_test(&app.setup, {kind = .New}, app.setup.workspace, &err_text)
	if !testing.expect(t, first_ok) { return }
	defer session_target_destroy(&first, app.setup.alloc)
	second, second_ok := session_open_test(&app.setup, {kind = .New}, app.setup.workspace, &err_text)
	if !testing.expect(t, second_ok) { return }
	defer session_target_destroy(&second, app.setup.alloc)

	testing.expect(t, first.id != second.id, "a second launch must not reuse the first session")
	testing.expect_value(t, first.workspace, app.setup.workspace)
	testing.expect_value(t, second.workspace, app.setup.workspace)
	// Nothing was resumed, so there is no model to fall back to.
	testing.expect_value(t, first.provider, "")
	testing.expect_value(t, first.model, "")
}

// A session is recorded by its first prompt, not by the launch. Opening the
// harness in a directory and closing it without typing leaves nothing behind: no
// row, nothing to list, and nothing for a later resume to find.
@(test)
test_a_launch_that_is_never_prompted_leaves_no_session :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	err_text: strings.Builder
	defer strings.builder_destroy(&err_text)
	state, previous, had_previous := app_state_isolate(t)
	defer app_state_restore(state, previous, had_previous)

	workspace, workspace_err := os.get_working_directory(context.allocator)
	if workspace_err != nil { testing.fail_now(t, "could not read the working directory") }
	defer delete(workspace, context.allocator)

	setup: Run_Setup
	setup.alloc = context.allocator
	defer attach_setup_destroy(&setup)
	if !testing.expect(t, run_session_attach_test(&setup, workspace, {kind = .New}, &err_text)) { return }

	// Choosing a model or an effort is not interaction, and neither is stored with
	// the session, so a launch that only did that has nothing in the store.
	testing.expect_value(t, app_session_count(t, &setup, workspace), 0)

	// The first prompt is what records it, whether or not a request follows.
	app_session_turn(t, &setup)
	testing.expect_value(t, app_session_count(t, &setup, workspace), 1)
}

// A bare --resume is scoped to the directory it is run from, and the newest
// session in that directory is the one it opens.
@(test)
test_resume_latest_is_scoped_to_the_directory :: proc(t: ^testing.T) {
	err_text: strings.Builder
	defer strings.builder_destroy(&err_text)
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	other := app_workspace_make(t)
	defer {
		os.remove_all(other)
		delete(other, context.allocator)
	}

	// The newest session in the store belongs to another directory, so picking it
	// up here would be the wrong answer. Every session here holds a turn, so none
	// of them is passed over for being empty.
	elder := app_session_use(t, &app.setup, {workspace = app.setup.workspace}, 2_000)
	defer delete(string(elder), app.setup.alloc)
	newest := app_session_use(t, &app.setup, {workspace = app.setup.workspace}, 3_000)
	defer delete(string(newest), app.setup.alloc)
	elsewhere := app_session_use(t, &app.setup, {workspace = other}, 9_000)
	defer delete(string(elsewhere), app.setup.alloc)

	target, ok := session_open_test(&app.setup, {kind = .Resume_Latest}, app.setup.workspace, &err_text)
	if !testing.expect(t, ok) { return }
	defer session_target_destroy(&target, app.setup.alloc)
	testing.expect_value(t, target.id, newest)
	testing.expect(t, target.id != elsewhere, "a resume must not leave the directory")
	testing.expect_value(t, target.workspace, app.setup.workspace)
}

// Opening the harness without --resume and closing it without typing creates a
// session that was never used. It is newer than the conversation beside it, and
// a later bare resume must still open the conversation.
@(test)
test_resume_latest_skips_a_session_that_was_never_used :: proc(t: ^testing.T) {
	err_text: strings.Builder
	defer strings.builder_destroy(&err_text)
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	conversation := app_session_use(t, &app.setup, {workspace = app.setup.workspace}, 2_000)
	defer delete(string(conversation), app.setup.alloc)
	abandoned := app_session_add(t, &app.setup, {workspace = app.setup.workspace}, 3_000)
	defer delete(string(abandoned), app.setup.alloc)

	target, ok := session_open_test(&app.setup, {kind = .Resume_Latest}, app.setup.workspace, &err_text)
	if !testing.expect(t, ok) { return }
	defer session_target_destroy(&target, app.setup.alloc)
	testing.expect_value(t, target.id, conversation)
	testing.expect(t, target.id != abandoned, "a session that was never used must not be resumed")
}

// Nothing to resume is a refusal, not a fresh session in disguise.
@(test)
test_resume_latest_refuses_an_empty_directory :: proc(t: ^testing.T) {
	err_text: strings.Builder
	defer strings.builder_destroy(&err_text)
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	empty := app_workspace_make(t)
	defer {
		os.remove_all(empty)
		delete(empty, context.allocator)
	}

	// A session in that directory that was never used leaves nothing to resume.
	abandoned := app_session_add(t, &app.setup, {workspace = empty}, 4_000)
	defer delete(string(abandoned), app.setup.alloc)

	_, ok := session_open_test(&app.setup, {kind = .Resume_Latest}, empty, &err_text)
	testing.expect(t, !ok, "a resume with nothing to resume must fail")
	testing.expect(t, strings.contains(strings.to_string(err_text), "nothing to resume"), "the absence should be reported")
}

// An explicit id opens that session, and the session's own directory is what the
// continuation runs in.
@(test)
test_resume_by_id_leaves_the_launch_directory_behind :: proc(t: ^testing.T) {
	err_text: strings.Builder
	defer strings.builder_destroy(&err_text)
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	other := app_workspace_make(t)
	defer {
		os.remove_all(other)
		delete(other, context.allocator)
	}
	id := app_session_add(t, &app.setup, {workspace = other, provider = "test-provider", model = "test-model"}, 5_000)
	defer delete(string(id), app.setup.alloc)

	target, ok := session_open_test(&app.setup, {kind = .Resume_Id, id = string(id)}, app.setup.workspace, &err_text)
	if !testing.expect(t, ok) { return }
	defer session_target_destroy(&target, app.setup.alloc)
	testing.expect_value(t, target.id, id)
	testing.expect_value(t, target.workspace, other)
	testing.expect_value(t, target.provider, "test-provider")
	testing.expect_value(t, target.model, "test-model")
}

@(test)
test_resume_by_id_refuses_what_it_cannot_open :: proc(t: ^testing.T) {
	err_text: strings.Builder
	defer strings.builder_destroy(&err_text)
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	_, missing_ok := session_open_test(&app.setup, {kind = .Resume_Id, id = "00000000000000000000000000000000"}, app.setup.workspace, &err_text)
	testing.expect(t, !missing_ok, "an unknown id must be refused")
	testing.expect(t, strings.contains(strings.to_string(err_text), "cannot open session"), "the missing row should be reported")

	_, malformed_ok := session_open_test(&app.setup, {kind = .Resume_Id, id = "not-a-session"}, app.setup.workspace, &err_text)
	testing.expect(t, !malformed_ok, "a malformed id must be refused")
	testing.expect(t, strings.contains(strings.to_string(err_text), "not a session id"), "the malformed id should be reported")
}

// The target is checked before anything is given up, so a session from a
// directory that no longer exists cannot cost the running one.
@(test)
test_a_switch_to_a_missing_directory_keeps_the_running_session :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	gone := app_workspace_make(t)
	id := app_session_add(t, &app.setup, {workspace = gone}, 6_000)
	defer delete(string(id), app.setup.alloc)
	os.remove_all(gone)
	defer delete(gone, context.allocator)

	running := session.Session_Id(strings.clone(string(app.setup.session.id), context.allocator))
	defer delete(string(running), context.allocator)

	testing.expect(t, !session_switch(&app, id))
	testing.expect_value(t, app.setup.session.id, running)
	claimed, held := session.session_claimed(&app.setup.store)
	if !testing.expect(t, held, "the running session must stay claimed") { return }
	testing.expect_value(t, claimed, running)

	// A refusal costs the running session nothing, so it can still take a prompt.
	app_session_accept(t, &app, "after the refusal")
}

// A target another process is running is refused, and the session that was on
// screen stays usable rather than being closed by the attempt.
@(test)
test_a_busy_target_keeps_the_running_session :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	id := app_session_add(t, &app.setup, {workspace = app.setup.workspace}, 7_000)
	defer delete(string(id), app.setup.alloc)
	running := session.Session_Id(strings.clone(string(app.setup.session.id), context.allocator))
	defer delete(string(running), context.allocator)

	// A second store claiming the target is what a second process running it
	// looks like from here.
	other: session.Store
	if err := session.store_open(&other, directory); err != nil { testing.fail_now(t, "second store_open failed") }
	defer session.store_close(&other)
	if err := session.session_claim(&other, id); err != nil { testing.fail_now(t, "the second store could not claim the target") }

	testing.expect(t, !session_switch(&app, id))
	testing.expect_value(t, app.setup.session.id, running)
	claimed, held := session.session_claimed(&app.setup.store)
	if !testing.expect(t, held, "the running session must stay claimed") { return }
	testing.expect_value(t, claimed, running)

	// The refusal must not have disturbed the running session: it is still claimed
	// and still writable, not merely named the same.
	app_session_accept(t, &app, "after the refusal")

	// The running session was never released during the attempt, so another
	// process still cannot take it. A third store holds no claim of its own, so
	// its refusal can only come from the running session being locked.
	prober: session.Store
	if err := session.store_open(&prober, directory); err != nil { testing.fail_now(t, "third store_open failed") }
	defer session.store_close(&prober)
	running_claim_err := session.session_claim(&prober, running)
	testing.expect(t, session.error_kind(running_claim_err) == session.Error_Kind.Claimed, "a refused switch must not have released the running session")
}

// Resuming has to leave the conversation able to send, so the model the session
// recorded is applied to the running session. The selection lives in the store,
// so the fixture's own store is all the test needs.
@(test)
test_a_switch_applies_the_model_the_session_recorded :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	app.setup.catalog = app_test_catalog(app.setup.alloc)
	defer agent.catalog_destroy(&app.setup.catalog)

	id := app_session_add(t, &app.setup, {workspace = app.setup.workspace, provider = "test-provider", model = "test-model"}, 8_000)
	defer delete(string(id), app.setup.alloc)

	testing.expect(t, session_switch(&app, id))
	testing.expect_value(t, app.setup.session.provider_id, "test-provider")
	testing.expect_value(t, app.setup.session.model_id, "test-model")
	testing.expect_value(t, app.setup.session.capacity.window, 128_000)
	testing.expect(t, app.setup.session.tools_enabled, "the model states that it supports tools")
	// The connection follows the selection, or the next request would go to the
	// model that was running before the switch.
	testing.expect_value(t, app.run.connection.Endpoint, "http://127.0.0.1:1")
}

@(test)
test_new_and_resume_switch_and_replay :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	first := session.Session_Id(strings.clone(string(app.setup.session.id), context.allocator))
	defer delete(string(first), context.allocator)

	// The first session has one prompt, so a resume has something to replay.
	accepted := agent.chat_session_accept_user(&app.setup.session, "remember me", session.now_ms())
	testing.expect_value(t, accepted, agent.Chat_Accept.Accepted)

	testing.expect(t, session_start_new(&app))
	second := session.Session_Id(strings.clone(string(app.setup.session.id), context.allocator))
	defer delete(string(second), context.allocator)
	testing.expect(t, first != second, "a new session must be a different session")

	// The new session has no prompt, so it has no row: the list still names only
	// the conversation that was used.
	snapshot_clear(&app)
	session_refresh_rows(&app)
	menu_open_session(&app)
	if !testing.expect_value(t, len(app.menu.choices), 1) { return }
	menu_close(&app)

	snapshot_clear(&app)
	session_resume(&app, string(first)[:8])
	testing.expect_value(t, app.setup.session.id, first)

	// The replayed prompt is what makes a resumed conversation recognisable.
	found := false
	for &entry in app.run.snap.entries {
		if entry.kind == .User && string(entry.text[:]) == "remember me" { found = true }
	}
	testing.expect(t, found, "resuming should replay the conversation")
}

// A replayed tool call is the box a live turn showed: the call's name, the
// preview of what the tool produced, and the outcome its border is colored by.
// The model-facing envelope is not the preview, and a resumed session used to
// show it as the box's title.
@(test)
test_resume_replays_a_tool_call_as_a_box :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	id := session.Session_Id(strings.clone(string(app.setup.session.id), context.allocator))
	defer delete(string(id), context.allocator)

	accepted := agent.chat_session_accept_user(&app.setup.session, "list files", session.now_ms())
	if !testing.expect_value(t, accepted, agent.Chat_Accept.Accepted) { return }
	request_no, request_err := session.request_begin(
		&app.setup.store,
		app.setup.session.id,
		{
			turn_no = app.setup.session.turn_no,
			purpose = .Response,
			provider = "test-provider",
			model_requested = "test-model",
			api = "openai_chat_completions",
			config_json = "{}",
			input_json = "{}",
		},
		session.now_ms(),
	)
	if !testing.expect(t, request_err == nil, "the request must be recorded") { return }

	call_seq, call_err := session.entry_append(
		&app.setup.store,
		app.setup.session.id,
		{
			turn_no = app.setup.session.turn_no,
			request_no = request_no,
			created_at_ms = 2_000,
			payload = session.Tool_Call_Entry{call_id = "call_1", name = "builtin_shell", arguments = `{"command":"ls"}`},
		},
	)
	if !testing.expect(t, call_err == nil, "the call entry must be recorded") { return }
	_, result_err := session.entry_append(
		&app.setup.store,
		app.setup.session.id,
		{
			turn_no = app.setup.session.turn_no,
			request_no = request_no,
			created_at_ms = 2_001,
			related_seq = call_seq,
			payload = session.Tool_Result_Entry {
				outcome = .Success,
				content = `{"status":"success","message":"","data":{"stdout":"first\nsecond\n","stderr":""}}`,
				origin = .Observed,
			},
		},
	)
	if !testing.expect(t, result_err == nil, "the result entry must be recorded") { return }

	testing.expect(t, session_start_new(&app))
	snapshot_clear(&app)
	session_resume(&app, string(id)[:8])
	testing.expect_value(t, app.setup.session.id, id)

	replayed := false
	for &entry in app.run.snap.entries {
		if entry.kind != .Tool { continue }
		replayed = true
		testing.expect_value(t, entry.tool_outcome, session.Tool_Outcome.Success)
		testing.expect_value(t, string(entry.text[:]), "builtin_shell\nfirst\nsecond\n")
	}
	testing.expect(t, replayed, "resuming should replay the tool call")
}

@(test)
test_resume_refuses_an_unknown_reference :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	before := app.setup.session.id
	session_resume(&app, "zzzzzzzz")
	testing.expect_value(t, app.setup.session.id, before)
	testing.expect(t, len(app.run.snap.entries) > 0, "the refusal should be reported")
}

// A stopped runtime abandons what is queued rather than running it: the worker
// observes the stop before the command is started, so a shutdown never begins a
// turn nobody will see through. The command is queued and the stop is set before
// the worker exists, which is what makes the abandonment deterministic.
@(test)
test_a_stopped_worker_abandons_queued_work :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	channel, channel_err := chan.create_buffered(Work_Chan, 4, app.run.alloc)
	if channel_err != nil { testing.fail_now(t, "the work channel could not be created") }
	app.run.work = channel

	worker := thread.create(run_worker, name = "nabla-test-worker")
	if worker == nil { testing.fail_now(t, "the worker could not be created") }
	worker.data = &app

	enqueue(&app, .Prompt, "must not run")
	stop_runtime(&app)
	thread.start(worker)
	// Closing the queue is what lets the worker finish draining it and return.
	chan.close(&app.run.work)
	thread.join(worker)
	thread.destroy(worker)
	app.run.worker = nil
	chan.destroy(&app.run.work)

	// Nothing ran: the session is idle and its history is empty.
	testing.expect_value(t, agent.chat_session_state(&app.setup.session), agent.Chat_State.Idle)
	entries, load_err := session.entries_load(&app.setup.store, app.setup.session.id, {}, context.allocator)
	if !testing.expect(t, load_err == nil, "the session's history must be readable") { return }
	defer session.entries_destroy(entries, context.allocator)
	testing.expect_value(t, len(entries), 0)
}

// --- a headless turn, end to end ---------------------------------------------

// COMPLETION_RESPONSE is one complete OpenAI chat-completions stream: a text
// delta and a stop.
COMPLETION_RESPONSE ::
	"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n" +
	"data: {\"choices\":[{\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}\n\n" +
	"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" +
	"data: [DONE]\n\n"

// STUB_BOUND bounds the wait for a turn's request, so a turn that never connects
// fails the test rather than hanging it.
STUB_BOUND :: 10 * time.Second

// stub_serve answers the one request a turn makes. The listener is non-blocking,
// so the wait for that request is bounded rather than an accept this test could
// never interrupt.
stub_serve :: proc(listener: net.TCP_Socket, response: string) -> bool {
	deadline := time.tick_add(time.tick_now(), STUB_BOUND)
	for {
		socket, _, accept_err := net.accept_tcp(listener)
		if accept_err == nil {
			defer net.close(socket)
			if !stub_read_request(socket) { return false }
			if _, send_err := net.send_tcp(socket, transmute([]byte)response); send_err != nil { return false }
			return true
		}
		if accept_err != .Would_Block { return false }
		if time.tick_since(deadline) >= 0 { return false }
		time.sleep(2 * time.Millisecond)
	}
}

// stub_read_request reads a whole request, headers and body. Closing a socket
// that still holds unread data sends RST, which would turn the response into a
// truncation the transport reports as a stream failure.
stub_read_request :: proc(socket: net.TCP_Socket) -> bool {
	request: [dynamic]u8
	defer delete(request)
	scratch: [4096]u8
	header_end := -1
	body_length := 0
	for {
		if header_end < 0 {
			if index := strings.index(string(request[:]), "\r\n\r\n"); index >= 0 {
				header_end = index + 4
				body_length = stub_content_length(string(request[:index]))
			}
		}
		if header_end >= 0 && len(request) >= header_end + body_length { return true }
		read, read_err := net.recv_tcp(socket, scratch[:])
		if read_err != nil || read <= 0 { return false }
		append(&request, ..scratch[:read])
	}
}

// stub_content_length finds the request body's size. A request without a
// Content-Length has no body.
stub_content_length :: proc(headers: string) -> int {
	rest := headers
	for {
		line_end := strings.index(rest, "\r\n")
		line := rest if line_end < 0 else rest[:line_end]
		if colon := strings.index_byte(line, ':'); colon > 0 {
			if strings.equal_fold(strings.trim_space(line[:colon]), "content-length") {
				length, _ := strconv.parse_int(strings.trim_space(line[colon + 1:]), 10)
				return length
			}
		}
		if line_end < 0 { return 0 }
		rest = rest[line_end + 2:]
	}
	return 0
}

// Turn_Run is one headless turn on its own thread, so the test thread is free to
// answer the request the turn makes.
Turn_Run :: struct {
	app:       ^App,
	prompt:    string,
	out:       ^Headless_Output,
	completed: bool,
}

headless_turn_run :: proc(thread_handle: ^thread.Thread) {
	run := cast(^Turn_Run)thread_handle.data
	run.completed = run_prompt_turn(run.app, run.prompt, run.out)
}

// A headless run is the interactive one without a terminal, so a turn driven
// through it has to reach a provider, decode the stream, record the turn, and
// report the answer. A stub endpoint on loopback is what lets that run end to
// end: the same code path, without a paid model.
@(test)
test_a_headless_turn_answers_against_an_endpoint :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if !testing.expectf(t, listen_err == nil, "the stub endpoint could not listen: %v", listen_err) { return }
	defer net.close(listener)
	if block_err := net.set_blocking(listener, false); block_err != nil {
		testing.fail_now(t, "the stub endpoint could not be made non-blocking")
	}
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if !testing.expectf(t, endpoint_err == nil, "the stub endpoint could not be read: %v", endpoint_err) { return }

	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	// The chat is configured the way apply_selection would leave it, because this
	// test is about the turn rather than about choosing a model.
	app.setup.session.provider_id = strings.clone("test-provider", app.setup.session.allocator)
	app.setup.session.model_id = strings.clone("test-model", app.setup.session.allocator)
	app_session_capacity(&app, 128_000)
	app.run.connection = ai.Provider_Connection {
		API        = .OpenAI_Chat_Completions,
		Endpoint   = fmt.aprintf("http://127.0.0.1:%d", endpoint.port, allocator = context.temp_allocator),
		Credential = "test-key",
	}

	answer: strings.Builder
	out := Headless_Output {
		answer = strings.to_writer(&answer),
	}
	run := Turn_Run {
		app    = &app,
		prompt = "hello",
		out    = &out,
	}
	worker := thread.create(headless_turn_run, name = "nabla-headless-turn")
	if worker == nil { testing.fail_now(t, "the turn thread could not be created") }
	worker.data = &run
	thread.start(worker)

	served := stub_serve(listener, COMPLETION_RESPONSE)
	thread.join(worker)
	thread.destroy(worker)

	if !testing.expect(t, served, "the turn never made its request") { return }
	if !testing.expect(t, run.completed, "the turn should complete") { return }
	// The answer is the model's text and one trailing newline, and nothing else.
	testing.expect_value(t, strings.to_string(answer), "hello\n")
}

// Input typed while a turn is running is queued for the next request boundary
// instead of being dropped or starting a second turn. The front-end's own input
// path puts it in the queue; the agent drains it where it is safe.
@(test)
test_input_during_a_turn_is_steered_not_dropped :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.run.steer = agent.steer_queue_init(app.run.alloc)
	defer agent.steer_queue_destroy(&app.run.steer)
	app.run.work, _ = chan.create_buffered(Work_Chan, WORK_CAPACITY, app.run.alloc)
	defer chan.destroy(&app.run.work)
	app.input = widgets.Input{}
	widgets.input_init(&app.input, app.run.alloc)
	defer widgets.input_destroy(&app.input)
	// Both lines below are prompts, so submit stores them in the recall history.
	defer history_destroy(&app)

	// A running turn takes the line as steering.
	set_running(&app, true)
	testing.expect(t, widgets.input_insert(&app.input, "use the other file"))
	submit(&app)
	line, queued := agent.steer_pop(&app.run.steer)
	if !testing.expect(t, queued, "a line typed during a turn should be queued") { return }
	testing.expect_value(t, line, "use the other file")
	agent.steer_line_free(&app.run.steer, line)

	// The same text on an idle session is a new turn, so it goes to the worker.
	set_running(&app, false)
	testing.expect(t, widgets.input_insert(&app.input, "hello"))
	submit(&app)
	_, still_queued := agent.steer_pop(&app.run.steer)
	testing.expect(t, !still_queued, "an idle prompt is not steering")
	work, has_work := chan.recv(app.run.work)
	if !testing.expect(t, has_work, "an idle prompt should reach the worker") { return }
	testing.expect_value(t, work.kind, Work_Kind.Prompt)
	testing.expect_value(t, work.text, "hello")
	work_destroy(&app, work)
}

// The Messages API answers with a different event stream, so a turn has to reach
// the same place through the adapter: encode, stream, decode, record, and report
// the answer. The stub ignores the path, so this also exercises the endpoint
// suffix and the key header the provider layer adds.
@(test)
test_a_headless_turn_answers_against_an_anthropic_endpoint :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if !testing.expectf(t, listen_err == nil, "the stub endpoint could not listen: %v", listen_err) { return }
	defer net.close(listener)
	if block_err := net.set_blocking(listener, false); block_err != nil {
		testing.fail_now(t, "the stub endpoint could not be made non-blocking")
	}
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if !testing.expectf(t, endpoint_err == nil, "the stub endpoint could not be read: %v", endpoint_err) { return }

	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.session.provider_id = strings.clone("anthropic", app.setup.session.allocator)
	app.setup.session.model_id = strings.clone("claude-sonnet-5", app.setup.session.allocator)
	app_session_capacity(&app, 200_000, 1024)
	app.run.connection = ai.Provider_Connection {
		API        = .Anthropic_Messages,
		Endpoint   = fmt.aprintf("http://127.0.0.1:%d", endpoint.port, allocator = context.temp_allocator),
		Credential = "test-key",
	}

	answer: strings.Builder
	out := Headless_Output {
		answer = strings.to_writer(&answer),
	}
	run := Turn_Run {
		app    = &app,
		prompt = "hello",
		out    = &out,
	}
	worker := thread.create(headless_turn_run, name = "nabla-anthropic-turn")
	if worker == nil { testing.fail_now(t, "the turn thread could not be created") }
	worker.data = &run
	thread.start(worker)

	served := stub_serve(listener, ANTHROPIC_COMPLETION_RESPONSE)
	thread.join(worker)
	thread.destroy(worker)

	if !testing.expect(t, served, "the turn never made its request") { return }
	if !testing.expect(t, run.completed, "the turn should complete") { return }
	testing.expect_value(t, strings.to_string(answer), "hello\n")

	// The turn recorded the usage the adapter normalized, so the cache accounting
	// sees a total rather than only the uncached part.
	request, request_err := session.request_load(&app.setup.store, app.setup.session.id, 1)
	if !testing.expect_value(t, request_err, nil) { return }
	defer session.request_destroy(&request)
	if input, present := request.usage.input.?; testing.expect(t, present) {
		testing.expect_value(t, input, i64(1050))
	}
	if read, present := request.usage.cache_read.?; testing.expect(t, present) {
		testing.expect_value(t, read, i64(900))
	}
}

ANTHROPIC_COMPLETION_RESPONSE ::
	"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n" +
	"event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":900,\"cache_creation_input_tokens\":50,\"output_tokens\":1}}}\n\n" +
	"event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" +
	"event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\n" +
	"event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n" +
	"event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n" +
	"event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

// --- tool refresh -------------------------------------------------------------

// A binding outlives the discovery page that named its remote tool, so it keeps its
// own copy rather than borrowing the page's allocation.
@(test)
test_mcp_binding_owns_remote_name :: proc(t: ^testing.T) {
	remote_name := strings.clone("find_files", context.allocator)
	binding := mcp_binding_make(nil, "fff", remote_name, context.allocator)
	defer mcp_binding_destroy(binding, context.allocator)

	testing.expect(t, raw_data(binding.remote_name) != raw_data(remote_name), "the binding must not borrow the discovery string")
	delete(remote_name, context.allocator)
	testing.expect_value(t, binding.remote_name, "find_files")
}

// A server that cannot be started contributes no tools and is reported once, and the
// native tools are still installed. That is what keeps a broken server from costing
// the user the tools that have nothing to do with it.
@(test)
test_refresh_degrades_to_native_tools_when_a_server_is_unusable :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	directory := app_session_begin(t, app)

	servers := make([]agent.MCP_Server_Config, 1, context.allocator)
	servers[0] = agent.MCP_Server_Config {
		id = strings.clone("broken", context.allocator),
		stdio = {executable = strings.clone("/nonexistent/nabla-no-such-server", context.allocator)},
		tools = make([]agent.MCP_Tool_Config, 1, context.allocator),
		discovery_timeout = time.Second,
		call_timeout = time.Second,
	}
	servers[0].tools[0] = {
		remote_name = strings.clone("read.file", context.allocator),
		name        = strings.clone("read", context.allocator),
		enabled     = true,
	}
	app.setup.mcp_servers = servers
	app.setup.mcp = mcp_runtime_make(servers, context.allocator)
	_, log_error := agent.log_open(&app.setup.log, {directory = directory, enabled = true, lowest = .Debug})
	if log_error != nil {
		testing.fail_now(t, "could not open diagnostics")
	}
	defer _ = agent.log_close(&app.setup.log)
	// The refresh records against whatever logger is installed, so the test installs
	// the one the run would have installed in its own scope.
	app.setup.log_binding = agent.Log_Binding {
		sink = &app.setup.log,
	}
	context.logger = agent.log_logger(&app.setup.log_binding)
	// The registry borrows the runtime's bindings, so the session goes first and the
	// clients second. The directory belongs to app_session_end.
	defer {
		app_session_end(app, directory)
		mcp_runtime_destroy(&app.setup.mcp)
		agent.mcp_server_config_destroy(&servers[0], context.allocator)
		delete(servers, context.allocator)
	}

	warning := app_tools_refresh(app)
	testing.expect(t, strings.contains(warning, "broken"), "the unusable server is named")
	testing.expect(t, strings.contains(warning, "could not be started"), "the reason is given")

	// The registry was replaced anyway, with the native tools and nothing from the
	// server that failed.
	_, native_present := agent.tool_registry_find(&app.setup.session.tools, agent.TOOL_SHELL_NAME)
	testing.expect(t, native_present, "the native tools survive a broken server")
	_, remote_present := agent.tool_registry_find(&app.setup.session.tools, "broken_read")
	testing.expect(t, !remote_present, "an unreachable server contributes no tools")

	output_text: strings.Builder
	defer strings.builder_destroy(&output_text)
	output := Diagnostics_Output {
		writer = strings.to_writer(&output_text),
	}
	summary := agent.log_read_session(directory, app.setup.session.id, &output, diagnostics_visit)
	testing.expect_value(t, summary.records, 2)
	testing.expect(t, strings.contains(strings.to_string(output_text), `"installed":true`))
	testing.expect(t, strings.contains(strings.to_string(output_text), `"unavailable_servers":1`))
	testing.expect(t, strings.contains(strings.to_string(output_text), `"accepted":0`))
}

// With nothing configured, refresh has nothing to do and says nothing.
@(test)
test_refresh_without_servers_is_silent :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	directory := app_session_begin(t, app)
	defer app_session_end(app, directory)

	testing.expect_value(t, app_tools_refresh(app), "")
	_, present := agent.tool_registry_find(&app.setup.session.tools, agent.TOOL_READ_NAME)
	testing.expect(t, present, "the session keeps the native tools it started with")
}

// Session_Log_Text collects the records one session left, read back through the
// public reader, so the lifecycle assertions below hold the reader to what the
// writer produced rather than to a file layout the test also chose.
Session_Log_Text :: struct {
	builder: strings.Builder,
}

session_log_visit :: proc(user_data: rawptr, _: string, line: string) -> bool {
	text := cast(^Session_Log_Text)user_data
	strings.write_string(&text.builder, line)
	strings.write_byte(&text.builder, '\n')
	return true
}

app_session_log_text :: proc(t: ^testing.T, logs_root: string, id: session.Session_Id) -> strings.Builder {
	collector := Session_Log_Text {
		builder = strings.builder_make(context.allocator),
	}
	summary := agent.log_read_session(logs_root, id, &collector, session_log_visit)
	testing.expectf(t, summary.cannot_read == 0, "the log should be readable")
	testing.expectf(t, summary.records_skipped == 0, "every line the reader saw should parse")
	return collector.builder
}

@(test)
test_a_switch_records_the_claim_and_the_release :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	// The launch's logger is installed in the test's own scope, which is what the
	// adoption path records against.
	logs_root, root_err := os.make_directory_temp("", "nabla-app-log-*", context.allocator)
	defer {
		os.remove_all(logs_root)
		delete(logs_root, context.allocator)
	}
	_, open_err := agent.log_open(&app.setup.log, {directory = logs_root, enabled = true, lowest = .Info}, app.setup.alloc)
	if open_err != nil { testing.fail_now(t, "the log could not be opened") }
	defer _ = agent.log_close(&app.setup.log)
	app.setup.log_binding = agent.Log_Binding {
		sink = &app.setup.log,
	}
	context.logger = agent.log_logger(&app.setup.log_binding)

	first := session.Session_Id(strings.clone(string(app.setup.session.id), context.allocator))
	defer delete(string(first), context.allocator)

	// A new session displaces the running one, so both facts belong in the record.
	testing.expect(t, session_start_new(&app))
	second := session.Session_Id(strings.clone(string(app.setup.session.id), context.allocator))
	defer delete(string(second), context.allocator)
	testing.expect(t, first != second, "a new session must be a different session")

	second_builder := app_session_log_text(t, logs_root, second)
	defer strings.builder_destroy(&second_builder)
	second_text := strings.to_string(second_builder)
	testing.expect(t, strings.contains(second_text, `"event":"session.claimed"`), "the new claim is recorded")
	testing.expect(t, strings.contains(second_text, `"resumed":false`), "a fresh session is not a resume")

	first_builder := app_session_log_text(t, logs_root, first)
	defer strings.builder_destroy(&first_builder)
	first_text := strings.to_string(first_builder)
	testing.expect(t, strings.contains(first_text, `"event":"session.released"`), "the replaced session's release is recorded")
}

@(test)
test_the_mcp_lifecycle_records_name_the_server_instance :: proc(t: ^testing.T) {
	// The process boundary is covered by the mcp stdio harness, which forks a real
	// server. What this holds is the record contract: the fields a reader depends on
	// and the names they are written by.
	logs_root, root_err := os.make_directory_temp("", "nabla-app-mcp-log-*", context.allocator)
	defer {
		os.remove_all(logs_root)
		delete(logs_root, context.allocator)
	}
	log_record: agent.Log
	_, open_err := agent.log_open(&log_record, {directory = logs_root, enabled = true, lowest = .Info}, context.allocator)
	if open_err != nil { testing.fail_now(t, "the log could not be opened") }
	defer _ = agent.log_close(&log_record)

	// The refresh records against the session it changes, so the binding carries one
	// and the reader can find the records again.
	session_id := session.Session_Id("00112233445566778899aabbccddeeff")
	binding := agent.Log_Binding {
		sink = &log_record,
		correlation = agent.Log_Correlation{session_id = session_id},
	}
	context.logger = agent.log_logger(&binding)

	log_mcp_started("files", 2)
	log_mcp_negotiated("files", 2, {version = .V2026_07_28, server_name = "stub", server_version = "1", tools_supported = true})
	log_mcp_stopped("files", 2, "restart")

	builder := app_session_log_text(t, logs_root, session_id)
	defer strings.builder_destroy(&builder)
	text := strings.to_string(builder)
	testing.expect(t, strings.contains(text, `"event":"mcp.started"`), "the launch is recorded")
	testing.expect(t, strings.contains(text, `"event":"mcp.negotiated"`), "the negotiation is recorded")
	testing.expect(t, strings.contains(text, `"event":"mcp.stopped"`), "the stop is recorded")
	testing.expect(t, strings.contains(text, `"server_instance":2`), "the launch counter identifies the instance")
	testing.expect(t, strings.contains(text, `"revision":"`), "the negotiated revision is recorded")
	testing.expect(t, strings.contains(text, `"tools_supported":true`), "the capability answer is recorded")
	testing.expect(t, strings.contains(text, `"reason":"restart"`), "the stop names why it stopped")
}

@(test)
test_catalog_refresh_enriches_the_active_selection :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.owns_selection = true

	user := []agent.Catalog_Provider_Source {
		{
			id = "test-provider",
			base_url_present = true,
			base_url = "http://127.0.0.1:1",
			api_present = true,
			api = "openai_chat_completions",
			api_key_present = true,
			api_key = "test-key",
		},
	}
	provider := []agent.Catalog_Provider_Source{{id = "test-provider", models = []agent.Catalog_Model_Source{{id = "discovered-model"}}}}
	models_dev := []agent.Catalog_Provider_Source {
		{
			id = "test-provider",
			models = []agent.Catalog_Model_Source {
				{
					id = "discovered-model",
					context_window_present = true,
					context_window = 128_000,
					max_output_tokens_present = true,
					max_output_tokens = 4_096,
					tools_present = true,
					tools = true,
					thinking = agent.Catalog_Thinking_Source {
						present = true,
						supported_present = true,
						supported = true,
						levels_present = true,
						levels = []string{"low", "high"},
					},
				},
			},
		},
	}

	stage_two, stage_two_err := agent.resolve_catalog(user, provider, {}, app.setup.alloc)
	if !testing.expect_value(t, stage_two_err, agent.Catalog_Error.None) { return }
	app.setup.catalog = stage_two
	testing.expect(t, apply_selection(&app, "test-provider", "discovered-model", ""))
	testing.expect_value(t, len(app.setup.session.effort_levels), 0)
	notices := len(app.run.snap.entries)

	stage_three, stage_three_err := agent.resolve_catalog(user, provider, models_dev, app.setup.alloc)
	if !testing.expect_value(t, stage_three_err, agent.Catalog_Error.None) { return }
	old := app.setup.catalog
	app.setup.catalog = stage_three
	app.catalog_revision = 1
	catalog_selection_sync(&app)
	agent.catalog_destroy(&old)
	defer agent.catalog_destroy(&app.setup.catalog)

	testing.expect_value(t, len(app.setup.session.effort_levels), 2)
	testing.expect_value(t, app.setup.session.effort_levels[0], "low")
	testing.expect(t, app.setup.session.tools_enabled)
	testing.expect_value(t, app.run.snap.status.context_window, 128_000)
	testing.expect_value(t, len(app.run.snap.status.effort_levels), 2)
	testing.expect_value(t, len(app.run.snap.entries), notices)
}

// A selection the user asks for is recorded, not applied: the turn owns the session
// until its next request boundary, so the choice waits in run state for whichever
// boundary reaches it first, and only that one installs it.
@(test)
test_a_requested_selection_waits_for_a_boundary_and_installs_once :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.catalog = app_test_catalog(app.setup.alloc)
	defer agent.catalog_destroy(&app.setup.catalog)
	app.run.work, _ = chan.create_buffered(Work_Chan, WORK_CAPACITY, app.run.alloc)
	defer chan.destroy(&app.run.work)

	testing.expect(t, apply_selection(&app, "test-provider", "test-model", ""))
	selection_request(&app, "test-provider", "test-model")
	testing.expect(t, app.run.pending.present, "a requested selection waits for a boundary")
	// The wake is what an idle worker blocks on; the choice itself is not in it.
	wake, queued := chan.recv(app.run.work)
	if !testing.expect(t, queued, "requesting a selection wakes the worker") { return }
	testing.expect_value(t, wake.kind, Work_Kind.Model)
	work_destroy(&app, wake)

	testing.expect(t, apply_pending_selection(&app), "the first boundary installs the selection")
	testing.expect(t, !apply_pending_selection(&app), "a later boundary has nothing left to install")
}
