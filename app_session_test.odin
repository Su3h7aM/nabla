#+test
#+private file
package main

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent"
import "nabla:agent/session"

// The session commands are the only part of the front-end that owns a store, so
// they are driven here without a terminal: a store, a running session, and the
// snapshot they append to.

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
	for level in app.run.snap.status.effort_levels { delete(level, app.run.alloc) }
	delete(app.run.snap.status.effort_levels)
	menu_destroy(&app.menu, app.run.alloc)
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

// app_session_add creates another session in the store and returns a copy of its
// id, owned by setup.alloc.
app_session_add :: proc(t: ^testing.T, setup: ^Run_Setup, options: session.Create_Options, at_ms: i64) -> session.Session_Id {
	created, err := session.session_create(&setup.store, options, at_ms)
	if err != nil { testing.fail_now(t, "session_create failed") }
	defer session.session_destroy(&created)
	return session.Session_Id(strings.clone(string(created.id), setup.alloc))
}

// app_workspace_make creates a directory a session can claim to have run in.
app_workspace_make :: proc(t: ^testing.T) -> string {
	path, err := os.make_directory_temp("", "nabla-app-other-*", context.allocator)
	if err != nil { testing.fail_now(t, "could not create a temporary directory") }
	return path
}

// app_test_catalog is the smallest catalog apply_selection can resolve: one
// usable provider with a literal credential, and one model that states its
// window and supports tools.
app_test_catalog :: proc(allocator: mem.Allocator) -> agent.Catalog {
	catalog := agent.Catalog {
		allocator = allocator,
	}
	append(
		&catalog.providers,
		agent.Catalog_Provider {
			id = strings.clone("test-provider", allocator),
			base_url = strings.clone("http://127.0.0.1:1", allocator),
			base_url_present = true,
			api = strings.clone("openai_chat_completions", allocator),
			api_present = true,
			api_key = strings.clone("test-key", allocator),
			api_key_present = true,
		},
	)
	append(
		&catalog.models,
		agent.Catalog_Model {
			provider_id = strings.clone("test-provider", allocator),
			id = strings.clone("test-model", allocator),
			context_window = 128_000,
			context_window_present = true,
			max_output_tokens = 4_096,
			max_output_tokens_present = true,
			tools = true,
			tools_present = true,
		},
	)
	return catalog
}

// app_state_isolate points the state directory at a temporary directory, so a
// test that persists a selection cannot touch the user's own state.
app_state_isolate :: proc(t: ^testing.T) -> string {
	state, state_err := os.make_directory_temp("", "nabla-app-state-*", context.allocator)
	if state_err != nil { testing.fail_now(t, "could not create a temporary state directory") }
	os.set_env("XDG_STATE_HOME", state)
	return state
}

app_state_restore :: proc(state: string) {
	os.unset_env("XDG_STATE_HOME")
	os.remove_all(state)
	delete(state, context.allocator)
}

// A launch with nothing to say always starts fresh, so closing and reopening the
// harness in one directory never returns to the conversation that just ended.
@(test)
test_a_launch_without_resume_starts_a_new_session :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	first, first_ok := session_open_target(&app.setup, {kind = .New}, app.setup.workspace)
	if !testing.expect(t, first_ok) { return }
	defer session_target_destroy(&first, app.setup.alloc)
	second, second_ok := session_open_target(&app.setup, {kind = .New}, app.setup.workspace)
	if !testing.expect(t, second_ok) { return }
	defer session_target_destroy(&second, app.setup.alloc)

	testing.expect(t, first.id != second.id, "a second launch must not reuse the first session")
	testing.expect_value(t, first.workspace, app.setup.workspace)
	testing.expect_value(t, second.workspace, app.setup.workspace)
	// Nothing was resumed, so there is no model to fall back to.
	testing.expect_value(t, first.provider, "")
	testing.expect_value(t, first.model, "")
}

// A bare --resume is scoped to the directory it is run from, and the newest
// session in that directory is the one it opens.
@(test)
test_resume_latest_is_scoped_to_the_directory :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	other := app_workspace_make(t)
	defer {
		os.remove_all(other)
		delete(other, context.allocator)
	}

	// The newest session in the store belongs to another directory, so picking it
	// up here would be the wrong answer.
	elder := app_session_add(t, &app.setup, {workspace = app.setup.workspace}, 2_000)
	defer delete(string(elder), app.setup.alloc)
	newest := app_session_add(t, &app.setup, {workspace = app.setup.workspace}, 3_000)
	defer delete(string(newest), app.setup.alloc)
	elsewhere := app_session_add(t, &app.setup, {workspace = other}, 9_000)
	defer delete(string(elsewhere), app.setup.alloc)

	target, ok := session_open_target(&app.setup, {kind = .Resume_Latest}, app.setup.workspace)
	if !testing.expect(t, ok) { return }
	defer session_target_destroy(&target, app.setup.alloc)
	testing.expect_value(t, target.id, newest)
	testing.expect(t, target.id != elsewhere, "a resume must not leave the directory")
	testing.expect_value(t, target.workspace, app.setup.workspace)
}

// Nothing to resume is a refusal, not a fresh session in disguise.
@(test)
test_resume_latest_refuses_an_empty_directory :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	empty := app_workspace_make(t)
	defer {
		os.remove_all(empty)
		delete(empty, context.allocator)
	}

	_, ok := session_open_target(&app.setup, {kind = .Resume_Latest}, empty)
	testing.expect(t, !ok, "a resume with nothing to resume must fail")
}

// An explicit id opens that session, and the session's own directory is what the
// continuation runs in.
@(test)
test_resume_by_id_leaves_the_launch_directory_behind :: proc(t: ^testing.T) {
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

	target, ok := session_open_target(&app.setup, {kind = .Resume_Id, id = string(id)}, app.setup.workspace)
	if !testing.expect(t, ok) { return }
	defer session_target_destroy(&target, app.setup.alloc)
	testing.expect_value(t, target.id, id)
	testing.expect_value(t, target.workspace, other)
	testing.expect_value(t, target.provider, "test-provider")
	testing.expect_value(t, target.model, "test-model")
}

@(test)
test_resume_by_id_refuses_what_it_cannot_open :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	_, missing_ok := session_open_target(&app.setup, {kind = .Resume_Id, id = "00000000000000000000000000000000"}, app.setup.workspace)
	testing.expect(t, !missing_ok, "an unknown id must be refused")

	_, malformed_ok := session_open_target(&app.setup, {kind = .Resume_Id, id = "not-a-session"}, app.setup.workspace)
	testing.expect(t, !malformed_ok, "a malformed id must be refused")
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
	if !testing.expect(t, held, "the running session must be reclaimed") { return }
	testing.expect_value(t, claimed, running)
}

// Resuming has to leave the conversation able to send, so the model the session
// recorded is applied to the running session.
@(test)
test_a_switch_applies_the_model_the_session_recorded :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	state := app_state_isolate(t)
	defer app_state_restore(state)

	app.setup.catalog = app_test_catalog(app.setup.alloc)
	defer agent.catalog_destroy(&app.setup.catalog)

	id := app_session_add(t, &app.setup, {workspace = app.setup.workspace, provider = "test-provider", model = "test-model"}, 8_000)
	defer delete(string(id), app.setup.alloc)

	testing.expect(t, session_switch(&app, id))
	testing.expect_value(t, app.setup.session.provider_id, "test-provider")
	testing.expect_value(t, app.setup.session.model_id, "test-model")
	testing.expect_value(t, app.setup.session.context_window, 128_000)
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

	snapshot_clear(&app)
	session_refresh_rows(&app)
	menu_open_session(&app)
	if !testing.expect_value(t, len(app.menu.choices), 2) { return }
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
