#+test
#+private file
package main

import "core:fmt"
import "core:io"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:agent"
import "nabla:agent/journal"
import "nabla:ai"
import "nabla:db"
import "nabla:term"
import "nabla:tui"
import "nabla:tui/widgets"

// The session commands are the only part of the front-end that owns a store, so
// they are driven here without a terminal: a store, a running session, and the
// snapshot they append to.

// app_session_capacity gives a session the budget a resolved model with this window
// and output bound would carry, so a fixture never states the window arithmetic
// itself.
app_session_capacity :: proc(app: ^App, window: int, output := 0) {
	app.setup.session.capacity = agent.model_capacity(agent.Catalog_Model{context_window = window, max_output_tokens = output > 0 ? output : nil})
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

	app.setup.store = new(journal.Journal)
	app.setup.journal_directory = strings.clone(directory, app.setup.alloc)
	app.setup.lock_directory = strings.clone(directory, app.setup.alloc)
	app.setup.run = journal.run_id_create()
	if open_error := journal.open(app.setup.store, directory, directory, app.setup.run, .Read_Write, app.setup.alloc); open_error != nil {
		testing.fail_now(t, "journal.open failed")
	}
	id, create_error := journal.create_session(app.setup.store, {workspace = workspace, role = .Main})
	if create_error != nil { testing.fail_now(t, "could not create the running session") }
	if _, commit_error := journal.commit(app.setup.store); commit_error != nil { testing.fail_now(t, "could not commit the running session") }
	app.setup.workspace = workspace
	tool_error: agent.Tool_Registry_Error
	app.setup.session, tool_error = agent.chat_session_init(app.setup.store, id, journal.INITIAL_BRANCH, 0, workspace, context.allocator)
	if tool_error.kind != .None { testing.fail_now(t, "the tool registry could not be created") }
	app.setup.session.skill_instructions = agent.test_skill_instructions(&app.setup.session)
	return directory
}

app_session_end :: proc(app: ^App, directory: string) {
	journal.records_destroy(app.setup.follow_pending, app.setup.alloc)
	agent.chat_session_destroy(&app.setup.session)
	agent.session_watch_stop(&app.setup.watch)
	_ = session_store_close(app.setup.store, app.setup.alloc)
	app.setup.store = nil
	transcript_destroy(app)
	for &entry in app.run.snap.entries {
		delete(entry.stream)
		if entry.text != nil { delete(entry.text) }
	}
	delete(app.run.snap.entries)
	codemode_pending_clear_locked(app)
	for &row in app.run.snap.sessions {
		delete(row.title, app.run.alloc)
	}
	delete(app.run.snap.sessions)
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
	_ = os.remove_all(app.setup.workspace)
	delete(app.setup.workspace, app.setup.alloc)
	delete(app.setup.resumed_provider, app.setup.alloc)
	delete(app.setup.resumed_model, app.setup.alloc)
	delete(app.setup.resumed_effort, app.setup.alloc)
	delete(app.setup.provider_id, app.setup.alloc)
	delete(app.setup.model_id, app.setup.alloc)
	delete(app.setup.credential, app.setup.alloc)
	delete(app.setup.journal_directory, app.setup.alloc)
	delete(app.setup.lock_directory, app.setup.alloc)
	_ = os.remove_all(directory)
	delete(directory, context.allocator)
}

// attach_setup_destroy releases what run_session_attach built, without the
// catalog teardown an empty setup does not need.
attach_setup_destroy :: proc(setup: ^Run_Setup) {
	journal.records_destroy(setup.follow_pending, setup.alloc)
	agent.chat_session_destroy(&setup.session)
	agent.session_watch_stop(&setup.watch)
	// The launch's own teardown; a close failure changes nothing the test reads.
	_ = run_store_close(setup)
	setup.store = nil
	delete(setup.workspace, setup.alloc)
	delete(setup.resumed_provider, setup.alloc)
	delete(setup.resumed_model, setup.alloc)
	delete(setup.resumed_effort, setup.alloc)
	delete(setup.journal_directory, setup.alloc)
	delete(setup.lock_directory, setup.alloc)
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
	if !testing.expect(t, run_session_attach_test(&first_setup, workspace, Start_Fresh{}, &err_text)) { return }
	first := first_setup.session.session
	app_session_turn(t, &first_setup)
	attach_setup_destroy(&first_setup)

	// Closing and reopening in one directory asks for a fresh conversation. A
	// millisecond apart, because that is the clock the store orders sessions by,
	// and two sessions created in the same one are ordered by id instead.
	time.sleep(2 * time.Millisecond)
	second_setup: Run_Setup
	second_setup.alloc = context.allocator
	defer attach_setup_destroy(&second_setup)
	if !testing.expect(t, run_session_attach_test(&second_setup, workspace, Start_Fresh{}, &err_text)) { return }
	second := second_setup.session.session
	app_session_turn(t, &second_setup)
	attach_setup_destroy(&second_setup)
	testing.expect(t, first != second, "a second launch must start a second session")

	latest_setup: Run_Setup
	latest_setup.alloc = context.allocator
	defer attach_setup_destroy(&latest_setup)
	if !testing.expect(t, run_session_attach_test(&latest_setup, workspace, Start_Resume_Latest{}, &err_text)) { return }
	testing.expect_value(t, latest_setup.session.session, second)
	testing.expect_value(t, latest_setup.workspace, workspace)
	attach_setup_destroy(&latest_setup)

	named_setup: Run_Setup
	named_setup.alloc = context.allocator
	defer attach_setup_destroy(&named_setup)
	first_text: [journal.SESSION_ID_HEX_LENGTH]u8
	if !testing.expect(
		t,
		run_session_attach_test(&named_setup, workspace, Start_Resume_Id(journal.session_id_to_hex(first, first_text[:])), &err_text),
	) { return }
	testing.expect_value(t, named_setup.session.session, first)
	attach_setup_destroy(&named_setup)

	// The running session is the one the launch named, and the store is free
	// again after each teardown.
	missing_setup: Run_Setup
	missing_setup.alloc = context.allocator
	testing.expect(
		t,
		!run_session_attach_test(&missing_setup, workspace, Start_Resume_Id("ffffffffffffffffffffffffffffffff"), &err_text),
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

	if err := selection_record(app.setup.store, "test-provider", "test-model", ""); err != nil {
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
	if err := selection_record(app.setup.store, "gone", "gone", ""); err != nil {
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
	if err := selection_record(app.setup.store, "gone", "gone", ""); err != nil {
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

// app_session_add records a session in a separate journal without disturbing the running claim.
App_Test_Session_Options :: struct {
	workspace: string,
	provider:  string,
	model:     string,
}

app_session_add :: proc(test: ^testing.T, setup: ^Run_Setup, options: App_Test_Session_Options, _: i64) -> journal.Session_Id {
	store := new(journal.Journal, setup.alloc)
	if open_error := journal.open(store, setup.journal_directory, setup.lock_directory, journal.run_id_create(), .Read_Write, setup.alloc); open_error != nil {
		free(store, setup.alloc)
		testing.fail_now(test, "could not open a session journal")
	}
	defer _ = session_store_close(store, setup.alloc)
	id, create_error := journal.create_session(store, {workspace = options.workspace, role = .Main})
	if create_error != nil { testing.fail_now(test, "could not create a session") }
	if options.provider != "" {
		journal.append_record(
			store,
			{kind = .Turn_Started, session = id, branch = journal.INITIAL_BRANCH, turn = 1, provider = options.provider, model = options.model},
			journal.Turn_Started{},
		)
	}
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(test, "could not commit a session") }
	return id
}

app_session_use :: proc(test: ^testing.T, setup: ^Run_Setup, options: App_Test_Session_Options, at_ms: i64) -> journal.Session_Id {
	_ = at_ms
	time.sleep(2 * time.Millisecond)
	return app_session_add(test, setup, options, 0)
}

app_session_count :: proc(test: ^testing.T, setup: ^Run_Setup, workspace: string) -> int {
	sessions, list_error := journal.list_sessions(setup.store, {workspace = workspace, role = .Main}, setup.alloc)
	if !testing.expect(test, list_error == nil) { return -1 }
	defer journal.session_summaries_destroy(sessions, setup.alloc)
	return len(sessions)
}

app_session_turn :: proc(test: ^testing.T, setup: ^Run_Setup) {
	if accepted := agent.chat_session_accept_user(&setup.session, "hello"); accepted != .Accepted {
		testing.fail_now(test, "the prompt was not accepted")
	}
}

app_session_accept :: proc(test: ^testing.T, app: ^App, text: string) {
	accepted := agent.chat_session_accept_user(&app.setup.session, text)
	if !testing.expect_value(test, accepted, agent.Chat_Accept.Accepted) { return }
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { testing.fail_now(test, "could not allocate projection") }
	defer virtual.arena_destroy(&arena)
	projection, load_error := agent.projection_load(app.setup.store, app.setup.session.session, app.setup.session.head, virtual.arena_allocator(&arena))
	if !testing.expect(test, load_error == nil, "the running session's history must still be readable") { return }
	found := false
	for &item in projection.items {
		if user, is_user := item.payload.(agent.Projected_User); is_user && user.text == text { found = true }
	}
	testing.expect(test, found, "the running session must still record history")
}

app_workspace_make :: proc(t: ^testing.T) -> string {
	path, err := os.make_directory_temp("", "nabla-app-other-*", context.allocator)
	if err != nil { testing.fail_now(t, "could not create a temporary directory") }
	return path
}

// app_test_catalog is the smallest catalog selection_install can apply: one
// usable provider with a literal credential, and one model that states its
// window and supports tools. It goes through resolve_catalog rather than filling
// the resolved lists directly, so a fixture cannot diverge from what resolution
// derives from its sources.
app_test_catalog :: proc(allocator: mem.Allocator, base_url := "http://127.0.0.1:1") -> agent.Catalog {
	sources := []agent.Catalog_Provider_Source {
		{
			id = "test-provider",
			base_url = base_url,
			api = "openai_chat_completions",
			api_key = "test-key",
			models = []agent.Catalog_Model_Source{{id = "test-model", context_window = 128_000, max_output_tokens = 4_096, tools = true}},
		},
	}
	catalog, _ := agent.resolve_catalog(sources, {}, {}, allocator)
	return catalog
}

// app_state_isolate points the state and runtime directories at a temporary
// directory, so a test that persists a selection, opens the session database, or
// claims a session cannot touch the user's own files. It returns the previous
// state value, which app_state_restore puts back. The variables are process-wide,
// so tests using this helper run isolated in a child of the test binary (see
// isolate_test.odin), which is also why the runtime value is not restored.
app_state_isolate :: proc(t: ^testing.T) -> (state: string, previous: string, had_previous: bool) {
	directory, directory_err := os.make_directory_temp("", "nabla-app-state-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "could not create a temporary state directory") }
	previous, had_previous = os.lookup_env("XDG_STATE_HOME", context.allocator)
	if os.set_env("XDG_STATE_HOME", directory) != nil { testing.fail_now(t, "could not set the state root") }
	if os.set_env("XDG_RUNTIME_DIR", directory) != nil { testing.fail_now(t, "could not set the runtime root") }
	return directory, previous, had_previous
}

app_state_restore :: proc(state, previous: string, had_previous: bool) {
	// The process is the isolated child this suite runs in, so a restore that fails
	// changes nothing that outlives it.
	if had_previous {
		_ = os.set_env("XDG_STATE_HOME", previous)
	} else {
		_ = os.unset_env("XDG_STATE_HOME")
	}
	delete(previous, context.allocator)
	_ = os.remove_all(state)
	delete(state, context.allocator)
}

// session_open_test opens one target against a captured diagnosis writer, so
// the test run stays quiet and the failure text itself is assertable.
session_open_test :: proc(setup: ^Run_Setup, start: Session_Start, workspace: string, err: ^strings.Builder) -> (Opened_Session, bool) {
	return session_open_test_impl(setup, start, workspace, err)
}

session_open_test_impl :: proc(setup: ^Run_Setup, start: Session_Start, workspace: string, output: ^strings.Builder) -> (Opened_Session, bool) {
	opened, message, ok := session_open(setup, start, workspace)
	if !ok {
		strings.write_string(output, message)
		delete(message, setup.alloc)
	}
	return opened, ok
}

app_session_id_text :: proc(id: journal.Session_Id) -> string {
	buffer: [journal.SESSION_ID_HEX_LENGTH]u8
	return strings.clone(journal.session_id_to_hex(id, buffer[:]), context.temp_allocator)
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

	first, first_ok := session_open_test(&app.setup, Start_Fresh{}, app.setup.workspace, &err_text)
	if !testing.expect(t, first_ok) { return }
	defer opened_session_destroy(&first, app.setup.alloc)
	second, second_ok := session_open_test(&app.setup, Start_Fresh{}, app.setup.workspace, &err_text)
	if !testing.expect(t, second_ok) { return }
	defer opened_session_destroy(&second, app.setup.alloc)

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
	if !testing.expect(t, run_session_attach_test(&setup, workspace, Start_Fresh{}, &err_text)) { return }

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
		_ = os.remove_all(other)
		delete(other, context.allocator)
	}

	// The newest session in the store belongs to another directory, so picking it
	// up here would be the wrong answer. Every session here holds a turn, so none
	// of them is passed over for being empty.
	elder := app_session_use(t, &app.setup, {workspace = app.setup.workspace}, 2_000)
	newest := app_session_use(t, &app.setup, {workspace = app.setup.workspace}, 3_000)
	elsewhere := app_session_use(t, &app.setup, {workspace = other}, 9_000)

	target, ok := session_open_test(&app.setup, Start_Resume_Latest{}, app.setup.workspace, &err_text)
	if !testing.expect(t, ok) { return }
	defer opened_session_destroy(&target, app.setup.alloc)
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
	abandoned := journal.session_id_create()

	target, ok := session_open_test(&app.setup, Start_Resume_Latest{}, app.setup.workspace, &err_text)
	if !testing.expect(t, ok) { return }
	defer opened_session_destroy(&target, app.setup.alloc)
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
		_ = os.remove_all(empty)
		delete(empty, context.allocator)
	}

	// A launch without a prompt has no session row to resume.

	_, ok := session_open_test(&app.setup, Start_Resume_Latest{}, empty, &err_text)
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
		_ = os.remove_all(other)
		delete(other, context.allocator)
	}
	id := app_session_add(t, &app.setup, {workspace = other, provider = "test-provider", model = "test-model"}, 5_000)

	target, ok := session_open_test(&app.setup, Start_Resume_Id(app_session_id_text(id)), app.setup.workspace, &err_text)
	if !testing.expect(t, ok) { return }
	defer opened_session_destroy(&target, app.setup.alloc)
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

	_, missing_ok := session_open_test(&app.setup, Start_Resume_Id("ffffffffffffffffffffffffffffffff"), app.setup.workspace, &err_text)
	testing.expect(t, !missing_ok, "an unknown id must be refused")
	testing.expect(t, strings.contains(strings.to_string(err_text), "does not exist"), "the missing row should be reported")

	_, malformed_ok := session_open_test(&app.setup, Start_Resume_Id("not-a-session"), app.setup.workspace, &err_text)
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
	_ = os.remove_all(gone)
	defer delete(gone, context.allocator)

	running := app.setup.session.session

	testing.expect(t, !session_switch(&app, Start_Resume_Id(app_session_id_text(id))))
	testing.expect_value(t, app.setup.session.session, running)
	testing.expect_value(t, app.setup.store.claimed, running)

	// A refusal costs the running session nothing, so it can still take a prompt.
	app_session_accept(t, &app, "after the refusal")
}

// A front-end that cannot follow, such as a headless run or the ACP server, refuses a
// target another process is running, and the session that was on screen stays usable
// rather than being closed by the attempt.
@(test)
test_a_busy_target_keeps_the_running_session :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	id := app_session_add(t, &app.setup, {workspace = app.setup.workspace}, 7_000)
	running := app.setup.session.session

	// A second store claiming the target is what a second process running it
	// looks like from here.
	other: journal.Journal
	if open_error := journal.open(&other, directory, directory, journal.run_id_create(), .Read_Write, app.setup.alloc);
	   open_error != nil { testing.fail_now(t, "second journal could not open") }
	defer _ = journal.close(&other)
	if _, claim_error := journal.claim(&other, id); claim_error != nil { testing.fail_now(t, "the second journal could not claim the target") }

	testing.expect(t, !session_switch(&app, Start_Resume_Id(app_session_id_text(id))))
	testing.expect_value(t, app.setup.session.session, running)
	testing.expect_value(t, app.setup.store.claimed, running)

	// The refusal must not have disturbed the running session: it is still claimed
	// and still writable, not merely named the same.
	app_session_accept(t, &app, "after the refusal")

	// The running session was never released during the attempt, so another
	// process still cannot take it. A third store holds no claim of its own, so
	// its refusal can only come from the running session being locked.
	prober: journal.Journal
	if open_error := journal.open(&prober, directory, directory, journal.run_id_create(), .Read_Write, app.setup.alloc);
	   open_error != nil { testing.fail_now(t, "third journal could not open") }
	defer _ = journal.close(&prober)
	_, running_claim_error := journal.claim(&prober, running)
	testing.expect_value(t, running_claim_error, journal.Journal_Error.Claimed)
}

// The TUI opens a session another process runs as a follower: it does not claim or
// recover, the session replaces the one on screen, a line it sends is readable by the
// runner, and it never records a selection, which would rewrite the user's default model.
@(test)
test_a_session_another_process_runs_opens_as_a_follower :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.shared_sessions = true
	app.setup.owns_selection = true
	app.setup.catalog = app_test_catalog(app.setup.alloc)
	defer agent.catalog_destroy(&app.setup.catalog)

	id := app_session_add(t, &app.setup, {workspace = app.setup.workspace}, 7_000)
	runner: journal.Journal
	if open_error := journal.open(&runner, directory, directory, journal.run_id_create(), .Read_Write, app.setup.alloc); open_error != nil {
		testing.fail_now(t, "the runner's journal could not open")
	}
	defer _ = journal.close(&runner)
	if _, claim_error := journal.claim(&runner, id); claim_error != nil { testing.fail_now(t, "the runner could not claim the session") }

	testing.expect(t, session_switch(&app, Start_Resume_Id(app_session_id_text(id))))
	testing.expect_value(t, app.setup.session.session, id)
	testing.expect_value(t, app.setup.store.followed, id)
	testing.expect_value(t, app.setup.store.claimed, journal.Session_Id{})
	testing.expect(t, app_following(&app), "the session runs in the other journal")
	refresh_status(&app)
	testing.expect(t, runtime_following(&app), "the front-end is told to show a follower")

	observer := run_observer(&app)
	app_follow_submit(&app, "from the follower", observer)
	lines, lines_error := journal.read_inbox(&runner, id, 0, context.temp_allocator)
	testing.expect(t, lines_error == nil, "the runner could not read its inbox")
	if !testing.expect_value(t, len(lines), 1) { return }
	testing.expect_value(t, string(lines[0].body), "from the follower")
	shown := 0
	for entry in app_entries(&app) {
		if entry.kind == .User && string(entry.text[:]) == "from the follower" { shown += 1 }
	}
	testing.expect_value(t, shown, 1)

	// A selection applies to the follower for display and is never recorded as the user's
	// default.
	testing.expect(t, selection_apply_direct(&app, "test-provider", "test-model", "", true))
	_, recorded, selection_error := selection_latest(app.setup.store, app.setup.alloc)
	testing.expect(t, selection_error == nil, "the selection could not be read")
	testing.expect(t, !recorded, "a follower must not rewrite the default model")

	// What only the runner's process can do is refused with a notice.
	notices := len(app.run.snap.entries)
	stop_turn(&app)
	selection_request(&app, "test-provider", "test-model")
	testing.expect_value(t, len(app.run.snap.entries), notices + 2)
	testing.expect(t, app.run.pending == nil, "a refused model change is not pending")
}

// The runner's process ends: the follower claims the session, recovery records what the
// runner left open, the transcript on screen stays, and the line the follower sent that
// no turn had read is delivered to the model once. A follower that tries while the runner
// lives stays a follower.
@(test)
test_a_follower_takes_the_session_over_when_the_runner_closes :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	state, previous, had_previous := app_state_isolate(t)
	defer app_state_restore(state, previous, had_previous)

	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if !testing.expectf(t, listen_err == nil, "the stub endpoint could not listen: %v", listen_err) { return }
	defer net.close(listener)
	if block_err := net.set_blocking(listener, false); block_err != nil { testing.fail_now(t, "the stub endpoint could not be made non-blocking") }
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if !testing.expectf(t, endpoint_err == nil, "the stub endpoint could not be read: %v", endpoint_err) { return }

	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.shared_sessions = true
	app.setup.owns_selection = true
	app.setup.catalog = app_test_catalog(app.setup.alloc, fmt.aprintf("http://127.0.0.1:%d", endpoint.port, allocator = context.temp_allocator))
	defer agent.catalog_destroy(&app.setup.catalog)
	app.run.steer = agent.steer_queue_init(app.run.alloc)
	defer agent.steer_queue_destroy(&app.run.steer)

	id := app_session_add(t, &app.setup, {workspace = app.setup.workspace}, 7_000)
	runner: journal.Journal
	if open_error := journal.open(&runner, directory, directory, journal.run_id_create(), .Read_Write, app.setup.alloc); open_error != nil {
		testing.fail_now(t, "the runner's journal could not open")
	}
	defer _ = journal.close(&runner)
	if _, claim_error := journal.claim(&runner, id); claim_error != nil { testing.fail_now(t, "the runner could not claim the session") }
	turn := journal.next_turn(&runner)
	journal.append_record(&runner, {kind = .Turn_Started, session = id, branch = journal.INITIAL_BRANCH, turn = turn}, journal.Turn_Started{})
	question := journal.append_node(
		&runner,
		{session = id, branch = journal.INITIAL_BRANCH, kind = .User, turn = turn},
		journal.User{origin = journal.USER_ORIGIN_NAMES[.Prompt]},
		transmute([]u8)string("the first question"),
	)
	if _, commit_error := journal.commit(&runner); commit_error != nil { testing.fail_now(t, "the runner could not commit") }

	testing.expect(t, session_switch(&app, Start_Resume_Id(app_session_id_text(id))))
	testing.expect(t, app_following(&app), "the session runs in the other journal")
	testing.expect(t, selection_apply_direct(&app, "test-provider", "test-model", "", true))
	observer := run_observer(&app)

	// What the runner commits after the follow began is shown without a restart.
	_ = journal.append_node(
		&runner,
		{session = id, branch = journal.INITIAL_BRANCH, parent = question, kind = .Assistant, turn = turn},
		journal.Assistant{request = 1},
		transmute([]u8)string("an answer"),
	)
	if _, commit_error := journal.commit(&runner); commit_error != nil { testing.fail_now(t, "the runner could not commit") }
	testing.expect(t, app_follow_service(&app, observer), "the runner's answer is new")
	testing.expect(t, app_following(&app), "a claim that fails leaves the process a follower")
	app_follow_submit(&app, "queued line", observer)
	shown := app_entries_count(&app, "queued line")
	testing.expect_value(t, shown, 1)

	serve := Stub_Serve {
		listener = listener,
		response = COMPLETION_RESPONSE,
	}
	server := thread.create(stub_serve_thread, name = "nabla-stub-provider")
	if server == nil { testing.fail_now(t, "the stub thread could not be created") }
	server.data = &serve
	thread.start(server)
	defer {
		thread.join(server)
		thread.destroy(server)
		testing.expect(t, serve.served, "the delivered line's turn never made its request")
	}

	if close_error := journal.close(&runner); close_error != nil { testing.fail_now(t, "the runner's journal did not close") }
	testing.expect(t, app_follow_service(&app, observer), "the claim dropped")
	testing.expect(t, !app_following(&app), "the follower is the runner now")
	testing.expect_value(t, app.setup.store.claimed, id)

	_, recovered, recovered_error := journal.read_latest(app.setup.store, {session = id, kinds = {.Session_Recovered}}, context.temp_allocator)
	testing.expect(t, recovered_error == nil, "the recovery record could not be read")
	testing.expect(t, recovered, "recovery recorded the turn the runner left open")
	// The transcript on screen was kept, and the line shows once though a turn delivered it.
	testing.expect_value(t, app_entries_count(&app, "an answer"), 1)
	testing.expect_value(t, app_entries_count(&app, "queued line"), 1)
	lines, lines_error := journal.read_inbox(app.setup.store, id, 0, context.temp_allocator)
	testing.expect(t, lines_error == nil, "the inbox could not be read")
	if !testing.expect_value(t, len(lines), 1) { return }
	delivered, delivered_error := journal.last_delivered_message(app.setup.store, id)
	testing.expect(t, delivered_error == nil, "the delivered line could not be read")
	testing.expect_value(t, delivered, lines[0].seq)
	_, recorded, selection_error := selection_latest(app.setup.store, app.setup.alloc)
	testing.expect(t, selection_error == nil, "the selection could not be read")
	testing.expect(t, !recorded, "a takeover must not rewrite the default model")
}

// app_entries returns every entry on screen once the window has caught up with the committed head.
app_entries :: proc(app: ^App) -> []^Entry {
	storage := app_frame_storage(40)
	defer frame_storage_destroy(storage)
	app_settle(app, storage, 40)
	return transcript_order(app)
}

app_frame_storage :: proc(rows: int) -> ^Frame_Storage {
	storage := frame_storage_new(context.allocator)
	storage.cells = make([]term.Cell, 80 * rows, context.allocator)
	if !tui.init(&storage.buffer, 80, rows, storage.cells) { return nil }
	return storage
}

// app_settle publishes the committed head and lays the transcript out until the window stops moving.
app_settle :: proc(app: ^App, storage: ^Frame_Storage, rows: int) {
	head_publish(app)
	transcript_sync(app)
	for draw_conversation(app, storage, tui.Cell_Rect{width = 80, height = rows}) && transcript_slide(app) {  }
}

app_window_rows :: proc(app: ^App) -> (rows: int) {
	for entry in app.transcript.entries { rows += entry.rows }
	return rows
}

// app_history_node appends one node of kind User or Assistant after parent.
app_history_node :: proc(app: ^App, parent: journal.Node_Id, kind: journal.Node_Kind, text: string) -> journal.Node_Id {
	chat := &app.setup.session
	header := journal.Node {
		session = chat.session,
		branch  = chat.branch,
		parent  = parent,
		turn    = chat.turn,
		kind    = kind,
	}
	if kind == .User {
		return journal.append_node(app.setup.store, header, journal.User{origin = journal.USER_ORIGIN_NAMES[.Prompt]}, transmute([]u8)text)
	}
	return journal.append_node(app.setup.store, header, journal.Assistant{request = 1}, transmute([]u8)text)
}

// app_history_turns appends exchanges first through last, numbered in their texts, and commits.
app_history_turns :: proc(t: ^testing.T, app: ^App, head: journal.Node_Id, first, last: int) -> journal.Node_Id {
	head := head
	for number in first ..= last {
		head = app_history_node(app, head, .User, fmt.tprintf("question %d", number))
		head = app_history_node(app, head, .Assistant, fmt.tprintf("answer %d", number))
	}
	if _, commit_error := journal.commit(app.setup.store); commit_error != nil { testing.fail_now(t, "the history could not be committed") }
	return head
}

app_has_text :: proc(entries: []Entry, text: string) -> bool {
	for entry in entries {
		if string(entry.text[:]) == text { return true }
	}
	return false
}

SCROLL_ROWS :: 40
SCROLL_PAGE :: SCROLL_ROWS - 3

// Paging up reaches the first prompt of a session far longer than the window, within its budget, and paging down returns to the newest answer.
@(test)
test_scrolling_reaches_the_first_prompt_with_a_bounded_window :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	TURNS :: 80
	_ = app_history_turns(t, &app, 0, 1, TURNS)
	storage := app_frame_storage(SCROLL_ROWS)
	defer frame_storage_destroy(storage)
	app_settle(&app, storage, SCROLL_ROWS)

	budget := (TRANSCRIPT_WINDOW_SCREENS + 2) * SCROLL_ROWS
	testing.expect(t, app.conv_scroll_range > 0, "the newest page fills the screen")
	testing.expect(t, app_has_text(app.transcript.entries[:], fmt.tprintf("answer %d", TURNS)), "the window starts at the newest answer")
	reached := false
	for _ in 0 ..< 400 {
		app.scroll += SCROLL_PAGE
		app_settle(&app, storage, SCROLL_ROWS)
		testing.expect(t, app_window_rows(&app) <= budget, "the window stays within its budget")
		if app_has_text(app.transcript.entries[:], "question 1") {
			reached = true
			break
		}
	}
	testing.expect(t, reached, "paging up reaches the first prompt")
	testing.expect(t, len(app.transcript.entries) < 2 * TURNS, "the window does not hold the whole session")

	for _ in 0 ..< 400 {
		if app.scroll == 0 { break }
		app.scroll = max(app.scroll - SCROLL_PAGE, 0)
		app_settle(&app, storage, SCROLL_ROWS)
		testing.expect(t, app_window_rows(&app) <= budget, "the window stays within its budget")
	}
	testing.expect_value(t, app.scroll, 0)
	testing.expect(t, app_has_text(app.transcript.entries[:], fmt.tprintf("answer %d", TURNS)), "paging down returns to the newest answer")
}

// A prompt before a compaction checkpoint is reachable, and the checkpoint shows as a notice.
@(test)
test_scrolling_reaches_the_prompts_before_a_checkpoint :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	head := app_history_turns(t, &app, 0, 1, 40)
	chat := &app.setup.session
	checkpoint := journal.append_node(
		app.setup.store,
		{session = chat.session, branch = chat.branch, parent = head, turn = chat.turn, kind = .Checkpoint, covers = head},
		journal.Checkpoint{request = 1},
		transmute([]u8)string("a summary"),
	)
	_ = app_history_turns(t, &app, checkpoint, 41, 60)
	storage := app_frame_storage(SCROLL_ROWS)
	defer frame_storage_destroy(storage)
	app_settle(&app, storage, SCROLL_ROWS)

	reached, noticed := false, false
	for _ in 0 ..< 400 {
		app.scroll += SCROLL_PAGE
		app_settle(&app, storage, SCROLL_ROWS)
		noticed ||= app_has_text(app.transcript.entries[:], CHECKPOINT_NOTICE)
		if app_has_text(app.transcript.entries[:], "question 1") {
			reached = true
			break
		}
	}
	testing.expect(t, reached, "the first prompt before the checkpoint is reachable")
	testing.expect(t, noticed, "the checkpoint shows where it happened")
}

// A result with a large picture keeps every entry around it reachable.
@(test)
test_a_large_picture_keeps_every_entry_reachable :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.run.snap.images_enabled = true
	head := app_history_turns(t, &app, 0, 1, 3)
	store := app.setup.store
	chat := &app.setup.session
	head = app_history_node(&app, head, .User, "look at a.png")
	assistant := app_history_node(&app, head, .Assistant, "reading")
	call := journal.next_call(store)
	journal.append_record(
		store,
		{kind = .Tool_Proposed, session = chat.session, branch = chat.branch, node = assistant, turn = chat.turn, call = call},
		journal.Tool_Proposed{provider_id = "call_1", name = "read"},
		transmute([]u8)string(`{"path":"a.png"}`),
	)
	picture := make([]u8, 2 * mem.Megabyte, context.allocator)
	defer delete(picture)
	digest := journal.put_artifact(store, journal.ATTACHMENT_ARTIFACT, picture)
	digest_text: [64]u8
	journal.append_record(
		store,
		{kind = .Tool_Completed, session = chat.session, branch = chat.branch, node = assistant, call = call},
		journal.Tool_Completed {
			outcome = journal.TOOL_OUTCOME_NAMES[.Success],
			attachments = []journal.Attachment {
				{media_type = ai.PROVIDER_MEDIA_TYPES[.PNG], name = "a.png", digest = journal.digest_to_hex(digest, digest_text[:])},
			},
		},
		transmute([]u8)string("ok\n\nread a.png"),
	)
	results := journal.append_node(
		store,
		{session = chat.session, branch = chat.branch, parent = assistant, turn = chat.turn, kind = .Results},
		journal.Results{calls = []journal.Call_Id{call}},
	)
	_ = app_history_node(&app, results, .Assistant, "it is black")
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(t, "the exchange could not be committed") }

	entries := app_entries(&app)
	texts := make([dynamic]string, context.temp_allocator)
	for entry in entries { append(&texts, string(entry.text[:])) }
	for expected in ([]string{"question 1", "answer 3", "look at a.png", "reading", "read\nread a.png", "it is black"}) {
		found := false
		for text in texts { found ||= text == expected }
		testing.expectf(t, found, "%q is reachable", expected)
	}
}

// Live entries give way to their committed form, and a running box settles in place.
@(test)
test_live_entries_give_way_to_their_committed_form :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	chat := &app.setup.session
	store := app.setup.store

	prompt := app_history_node(&app, 0, .User, "list files")
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(t, "the prompt could not be committed") }
	head_publish(&app)
	observer_assistant_begin(&app)
	observer_assistant_text(&app, "streaming")
	entries := app_entries(&app)
	if !testing.expect_value(t, len(entries), 2) { return }
	testing.expect_value(t, string(entries[0].text[:]), "list files")
	testing.expect_value(t, string(entries[1].text[:]), "streaming")

	assistant := app_history_node(&app, prompt, .Assistant, "streaming")
	call := journal.next_call(store)
	arguments := `{"command":"ls"}`
	journal.append_record(
		store,
		{kind = .Tool_Proposed, session = chat.session, branch = chat.branch, node = assistant, turn = chat.turn, call = call},
		journal.Tool_Proposed{provider_id = "call_1", name = "shell"},
		transmute([]u8)arguments,
	)
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(t, "the answer could not be committed") }
	observer_assistant_end(&app)
	head_publish(&app)
	app_observe_call(&app, call, 0, "shell", arguments)
	entries = app_entries(&app)
	if !testing.expect_value(t, len(entries), 3) { return }
	testing.expect_value(t, string(entries[1].text[:]), "streaming")
	testing.expect(t, entries[2].running, "the call runs in the live layer")

	content := "ok\nexit_code: 0\n\nstdout:\nfile\n"
	result := agent.Tool_Result {
		content = content,
		outcome = .Success,
	}
	observer_tool_result(&app, call, 0, "shell", arguments, &result)
	entries = app_entries(&app)
	if !testing.expect_value(t, len(entries), 3) { return }
	testing.expect(t, !entries[2].running, "the box settled in place")

	journal.append_record(
		store,
		{kind = .Tool_Completed, session = chat.session, branch = chat.branch, node = assistant, call = call},
		journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]},
		transmute([]u8)content,
	)
	_ = journal.append_node(
		store,
		{session = chat.session, branch = chat.branch, parent = assistant, turn = chat.turn, kind = .Results},
		journal.Results{calls = []journal.Call_Id{call}},
	)
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(t, "the results could not be committed") }
	entries = app_entries(&app)
	if !testing.expect_value(t, len(entries), 3) { return }
	for entry in entries { testing.expect(t, entry.node != 0, "every entry is the journal's now") }
	testing.expect_value(t, len(app.run.snap.entries), 0)
}

// app_entries_count is how many transcript entries carry exactly text.

// app_entries_count is how many transcript entries carry exactly text.
app_entries_count :: proc(app: ^App, text: string) -> int {
	count := 0
	for entry in app_entries(app) {
		if string(entry.text[:]) == text { count += 1 }
	}
	return count
}

Stub_Serve :: struct {
	listener: net.TCP_Socket,
	response: string,
	served:   bool,
}

stub_serve_thread :: proc(thread_handle: ^thread.Thread) {
	serve := cast(^Stub_Serve)thread_handle.data
	serve.served = stub_serve(serve.listener, serve.response)
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

	testing.expect(t, session_switch(&app, Start_Resume_Id(app_session_id_text(id))))
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

	first := app.setup.session.session

	// The first session has one prompt, so a resume has something to replay.
	accepted := agent.chat_session_accept_user(&app.setup.session, "remember me")
	testing.expect_value(t, accepted, agent.Chat_Accept.Accepted)

	testing.expect(t, session_switch(&app, Start_Fresh{}))
	second := app.setup.session.session
	testing.expect(t, first != second, "a new session must be a different session")

	// The new session has no prompt, so it has no row: the list still names only
	// the conversation that was used.
	snapshot_clear(&app)
	session_refresh_rows(&app)
	menu_open_session(&app)
	if !testing.expect_value(t, len(app.menu.choices), 1) { return }
	menu_close(&app)

	snapshot_clear(&app)
	session_resume(&app, app_session_id_text(first)[:8])
	testing.expect_value(t, app.setup.session.session, first)

	// The replayed prompt is what makes a resumed conversation recognisable.
	found := false
	for entry in app_entries(&app) {
		if entry.kind == .User && string(entry.text[:]) == "remember me" { found = true }
	}
	testing.expect(t, found, "resuming should replay the conversation")
}

// A replayed tool call is the box a live turn showed: the call's name, the preview of what
// the tool produced, and the outcome its border is colored by. The outcome line the model
// reads first is not the preview, and a resumed session used to show it as the box's title.
@(test)
test_resume_replays_a_tool_call_as_a_box :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	id := app.setup.session.session

	accepted := agent.chat_session_accept_user(&app.setup.session, "list files")
	if !testing.expect_value(t, accepted, agent.Chat_Accept.Accepted) { return }
	store := app.setup.store
	chat := &app.setup.session
	assistant := journal.append_node(
		store,
		{session = id, branch = chat.branch, parent = chat.head, turn = chat.turn, kind = .Assistant},
		journal.Assistant{request = 1},
	)
	call := journal.next_call(store)
	arguments: string = `{"command":"ls"}`
	content: string = "ok\nexit_code: 3\n\nstdout:\nfirst\nsecond\n"
	journal.append_record(
		store,
		{kind = .Tool_Proposed, session = id, branch = chat.branch, node = assistant, turn = chat.turn, request = 1, call = call},
		journal.Tool_Proposed{provider_id = "call_1", name = "shell"},
		transmute([]u8)arguments,
	)
	journal.append_record(
		store,
		{kind = .Tool_Completed, session = id, branch = chat.branch, node = assistant, call = call},
		journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]},
		transmute([]u8)content,
	)
	_ = journal.append_node(
		store,
		{session = id, branch = chat.branch, parent = assistant, turn = chat.turn, kind = .Results},
		journal.Results{calls = []journal.Call_Id{call}},
	)
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(t, "the tool call could not be recorded") }

	testing.expect(t, session_switch(&app, Start_Fresh{}))
	snapshot_clear(&app)
	session_resume(&app, app_session_id_text(id)[:8])
	testing.expect_value(t, app.setup.session.session, id)

	replayed := false
	for entry in app_entries(&app) {
		if entry.kind != .Tool { continue }
		replayed = true
		testing.expect_value(t, entry.tool_outcome, journal.Tool_Outcome.Success)
		testing.expect_value(t, string(entry.text[:]), "shell\nstdout:\nfirst\nsecond\n")
	}
	testing.expect(t, replayed, "resuming should replay the tool call")
}

// A replayed agent start is the box the live turn showed: the start prompt, not the
// subagent's answer. The live observer and the replay read the same proposed arguments,
// so the two boxes read the same.
@(test)
test_resume_replays_an_agent_start_as_its_prompt :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	id := app.setup.session.session
	accepted := agent.chat_session_accept_user(&app.setup.session, "delegate work")
	if !testing.expect_value(t, accepted, agent.Chat_Accept.Accepted) { return }

	arguments := `{"action":"start","prompt":"inspect the parser","wait":true}`
	answer := "ok\n\nthe parser is fine"
	live := agent.Tool_Result {
		content = answer,
		reason  = "<agent> started",
		outcome = .Success,
	}
	observer_tool_result(&app, 0, 0, "agent", arguments, &live)
	if !testing.expect_value(t, len(app.run.snap.entries), 1) { return }
	live_box := strings.clone(string(app.run.snap.entries[0].text[:]), context.allocator)
	defer delete(live_box, context.allocator)
	testing.expect_value(t, live_box, "agent\ninspect the parser")
	snapshot_clear(&app)

	store := app.setup.store
	chat := &app.setup.session
	assistant := journal.append_node(
		store,
		{session = id, branch = chat.branch, parent = chat.head, turn = chat.turn, kind = .Assistant},
		journal.Assistant{request = 1},
	)
	call := journal.next_call(store)
	journal.append_record(
		store,
		{kind = .Tool_Proposed, session = id, branch = chat.branch, node = assistant, turn = chat.turn, request = 1, call = call},
		journal.Tool_Proposed{provider_id = "call_1", name = "agent"},
		transmute([]u8)arguments,
	)
	journal.append_record(
		store,
		{kind = .Tool_Completed, session = id, branch = chat.branch, node = assistant, call = call},
		journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]},
		transmute([]u8)answer,
	)
	_ = journal.append_node(
		store,
		{session = id, branch = chat.branch, parent = assistant, turn = chat.turn, kind = .Results},
		journal.Results{calls = []journal.Call_Id{call}},
	)
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(t, "the tool call could not be recorded") }

	testing.expect(t, session_switch(&app, Start_Fresh{}))
	snapshot_clear(&app)
	session_resume(&app, app_session_id_text(id)[:8])
	testing.expect_value(t, app.setup.session.session, id)

	replayed := false
	for entry in app_entries(&app) {
		if entry.kind != .Tool { continue }
		replayed = true
		testing.expect_value(t, entry.tool_outcome, journal.Tool_Outcome.Success)
		testing.expect_value(t, string(entry.text[:]), live_box)
	}
	testing.expect(t, replayed, "resuming should replay the agent start")
}

// A failed agent start replays the box the live turn showed: the start prompt and then
// the failure reason, never the prompt alone. The live observer and the replay share
// the procedure that builds the text, so the two boxes read the same.
@(test)
test_resume_replays_a_failed_agent_start_with_its_reason :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	id := app.setup.session.session
	accepted := agent.chat_session_accept_user(&app.setup.session, "delegate work")
	if !testing.expect_value(t, accepted, agent.Chat_Accept.Accepted) { return }

	arguments := `{"action":"start","prompt":"inspect the parser","wait":true}`
	failure := "unknown_model: no such model 'fast'"
	live := agent.Tool_Result {
		content = failure,
		reason  = "unknown model 'fast'",
		outcome = .Unknown,
	}
	observer_tool_result(&app, 0, 0, "agent", arguments, &live)
	if !testing.expect_value(t, len(app.run.snap.entries), 1) { return }
	live_box := strings.clone(string(app.run.snap.entries[0].text[:]), context.allocator)
	defer delete(live_box, context.allocator)
	testing.expect_value(t, live_box, "agent\ninspect the parser\nno such model 'fast'")
	snapshot_clear(&app)

	store := app.setup.store
	chat := &app.setup.session
	assistant := journal.append_node(
		store,
		{session = id, branch = chat.branch, parent = chat.head, turn = chat.turn, kind = .Assistant},
		journal.Assistant{request = 1},
	)
	call := journal.next_call(store)
	journal.append_record(
		store,
		{kind = .Tool_Proposed, session = id, branch = chat.branch, node = assistant, turn = chat.turn, request = 1, call = call},
		journal.Tool_Proposed{provider_id = "call_1", name = "agent"},
		transmute([]u8)arguments,
	)
	journal.append_record(
		store,
		{kind = .Tool_Completed, session = id, branch = chat.branch, node = assistant, call = call},
		journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Unknown]},
		transmute([]u8)failure,
	)
	_ = journal.append_node(
		store,
		{session = id, branch = chat.branch, parent = assistant, turn = chat.turn, kind = .Results},
		journal.Results{calls = []journal.Call_Id{call}},
	)
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(t, "the tool call could not be recorded") }

	testing.expect(t, session_switch(&app, Start_Fresh{}))
	snapshot_clear(&app)
	session_resume(&app, app_session_id_text(id)[:8])
	testing.expect_value(t, app.setup.session.session, id)

	replayed := false
	for entry in app_entries(&app) {
		if entry.kind != .Tool { continue }
		replayed = true
		testing.expect_value(t, entry.tool_outcome, journal.Tool_Outcome.Unknown)
		testing.expect_value(t, string(entry.text[:]), live_box)
	}
	testing.expect(t, replayed, "resuming should replay the failed agent start")
}

// app_observe_call reports a call the harness admitted, as the owner's observer does.
app_observe_call :: proc(app: ^App, call, parent_call: journal.Call_Id, name, arguments: string) {
	observer_tool_call(app, agent.Chat_Tool_Event{call = call, parent_call = parent_call, name = name, arguments = arguments})
}

// A call shows a running box when it is admitted and the same box, finished, when it
// settles: one entry, updated in place with the final text.
@(test)
test_a_tool_box_is_running_until_its_result_settles_it :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	app_observe_call(&app, 3, 0, "shell", `{"command":"ls"}`)
	if !testing.expect_value(t, len(app.run.snap.entries), 1) { return }
	testing.expect(t, app.run.snap.entries[0].running, "an admitted call is running")
	testing.expect_value(t, string(app.run.snap.entries[0].text[:]), "shell\n")

	result := agent.Tool_Result {
		content = "ok\nexit_code: 0\n\nstdout:\nfirst\n",
		outcome = .Success,
	}
	observer_tool_result(&app, 3, 0, "shell", `{"command":"ls"}`, &result)
	if !testing.expect_value(t, len(app.run.snap.entries), 1) { return }
	entry := &app.run.snap.entries[0]
	testing.expect(t, !entry.running, "a settled call is finished")
	testing.expect_value(t, entry.tool_outcome, journal.Tool_Outcome.Success)
	testing.expect_value(t, string(entry.text[:]), "shell\nstdout:\nfirst\n")
}

// Streamed output shows under a running box and is replaced, not kept, by the result.
@(test)
test_a_running_shell_box_shows_streamed_output_until_its_result :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	app_observe_call(&app, 3, 0, "shell", `{"command":"ls"}`)
	observer_tool_output(&app, 3, 0, "one\ntw")
	observer_tool_output(&app, 3, 0, "o\nthree\n")
	if !testing.expect_value(t, len(app.run.snap.entries), 1) { return }
	testing.expect_value(t, string(app.run.snap.entries[0].text[:]), "shell\none\ntwo\nthree\n")
	testing.expect(t, app.run.snap.entries[0].running, "the box still runs")

	result := agent.Tool_Result {
		content = "ok\nexit_code: 0\n\nstdout:\nfirst\n",
		outcome = .Success,
	}
	observer_tool_result(&app, 3, 0, "shell", `{"command":"ls"}`, &result)
	entry := &app.run.snap.entries[0]
	testing.expect(t, !entry.running, "a settled call is finished")
	testing.expect_value(t, string(entry.text[:]), "shell\nstdout:\nfirst\n")
	testing.expect_value(t, len(entry.stream), 0)
}

// Output that arrives after the box settled, by result or by the end of the turn, is dropped.
@(test)
test_streamed_output_after_a_box_settles_is_dropped :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	app_observe_call(&app, 3, 0, "shell", `{"command":"ls"}`)
	app_observe_call(&app, 4, 0, "shell", `{"command":"ls"}`)
	observer_tool_output(&app, 4, 0, "late\n")
	result := agent.Tool_Result {
		content = "ok\nexit_code: 0\n\nstdout:\nfirst\n",
		outcome = .Success,
	}
	observer_tool_result(&app, 3, 0, "shell", `{"command":"ls"}`, &result)
	observer_turn_finished(&app)
	if !testing.expect_value(t, len(app.run.snap.entries), 2) { return }
	settled := string(app.run.snap.entries[0].text[:])
	unknown := string(app.run.snap.entries[1].text[:])
	testing.expect_value(t, unknown, "shell\n")

	observer_tool_output(&app, 3, 0, "after result\n")
	observer_tool_output(&app, 4, 0, "after turn\n")
	testing.expect_value(t, string(app.run.snap.entries[0].text[:]), settled)
	testing.expect_value(t, string(app.run.snap.entries[1].text[:]), unknown)
	testing.expect_value(t, len(app.run.snap.entries[0].stream) + len(app.run.snap.entries[1].stream), 0)
}

// The outer box of a script lists each inner call as it starts and settles, and each
// inner call has its own box, after the outer one, in the order it was admitted.
@(test)
test_a_codemode_box_follows_its_inner_calls_as_they_run :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	outer_arguments := `{"code":"return tools.read({path = \"a.odin\"})"}`
	inner_arguments := `{"path":"a.odin"}`
	app_observe_call(&app, 7, 0, "codemode", outer_arguments)
	if !testing.expect_value(t, len(app.run.snap.entries), 1) { return }
	testing.expect_value(t, string(app.run.snap.entries[0].text[:]), "codemode\nreturn tools.read({path = \"a.odin\"})\n\n")

	app_observe_call(&app, 8, 7, "read", inner_arguments)
	if !testing.expect_value(t, len(app.run.snap.entries), 2) { return }
	testing.expect_value(t, string(app.run.snap.entries[0].text[:]), "codemode\nreturn tools.read({path = \"a.odin\"})\n\n… read {\"path\":\"a.odin\"}\n\n")
	testing.expect_value(t, string(app.run.snap.entries[1].text[:]), "codemode · read\n")
	testing.expect(t, app.run.snap.entries[0].running && app.run.snap.entries[1].running, "both boxes run")

	inner_result := agent.Tool_Result {
		content = "ok\n\nhello",
		outcome = .Success,
	}
	observer_tool_result(&app, 8, 7, "read", inner_arguments, &inner_result)
	if !testing.expect_value(t, len(app.run.snap.entries), 2) { return }
	testing.expect_value(t, string(app.run.snap.entries[0].text[:]), "codemode\nreturn tools.read({path = \"a.odin\"})\n\n✓ read {\"path\":\"a.odin\"}\n\n")
	testing.expect_value(t, string(app.run.snap.entries[1].text[:]), "codemode · read\nhello")
	testing.expect(t, app.run.snap.entries[0].running && !app.run.snap.entries[1].running, "only the script still runs")

	outer_result := agent.Tool_Result {
		content = "ok\nvalue: 1\n\nfinished",
		outcome = .Success,
	}
	observer_tool_result(&app, 7, 0, "codemode", outer_arguments, &outer_result)
	if !testing.expect_value(t, len(app.run.snap.entries), 2) { return }
	testing.expect_value(
		t,
		string(app.run.snap.entries[0].text[:]),
		"codemode\nreturn tools.read({path = \"a.odin\"})\n\n✓ read {\"path\":\"a.odin\"}\n\nfinished",
	)
	testing.expect(t, !app.run.snap.entries[0].running, "the finished script is not running")
	testing.expect_value(t, len(app.run.codemode_pending), 0)
}

// A Code Mode run shows the script and one line per inner call, and each inner call
// keeps its own box titled for the script that ran it. A direct call keeps its own
// title. The live observer and the replay share the text and the order, so resuming
// shows the same boxes the turn showed.
@(test)
test_resume_replays_codemode_boxes_like_the_live_turn :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	id := app.setup.session.session
	accepted := agent.chat_session_accept_user(&app.setup.session, "run a script")
	if !testing.expect_value(t, accepted, agent.Chat_Accept.Accepted) { return }

	outer_arguments := `{"code":"return tools.read({path = \"a.odin\"})"}`
	read_arguments := `{"path":"a.odin"}`
	shell_arguments := `{"command":"exit 1"}`
	direct_arguments := `{"path":"b.odin"}`
	read_content := "ok\npath: a.odin\n\ncontent:\nhello\n"
	shell_content := "error tool_failed: exit 1 failed"
	outer_content := "ok\nvalue: 1\n\n1\n"

	read_result := agent.Tool_Result {
		content = read_content,
		outcome = .Success,
	}
	shell_result := agent.Tool_Result {
		content = shell_content,
		reason  = "exit 1 failed",
		outcome = .Tool_Failed,
	}
	outer_result := agent.Tool_Result {
		content = outer_content,
		outcome = .Success,
	}
	direct_result := agent.Tool_Result {
		content = read_content,
		outcome = .Success,
	}
	// The response's calls are admitted together; the script's calls follow once it runs.
	app_observe_call(&app, 7, 0, "codemode", outer_arguments)
	app_observe_call(&app, 10, 0, "read", direct_arguments)
	app_observe_call(&app, 8, 7, "read", read_arguments)
	app_observe_call(&app, 9, 7, "shell", shell_arguments)
	observer_tool_result(&app, 8, 7, "read", read_arguments, &read_result)
	observer_tool_result(&app, 9, 7, "shell", shell_arguments, &shell_result)
	observer_tool_result(&app, 7, 0, "codemode", outer_arguments, &outer_result)
	observer_tool_result(&app, 10, 0, "read", direct_arguments, &direct_result)
	if !testing.expect_value(t, len(app.run.snap.entries), 4) { return }

	expected_kinds := [4]Entry_Kind{.Codemode, .Tool, .Codemode, .Codemode}
	expected_outcomes := [4]journal.Tool_Outcome{.Success, .Success, .Success, .Tool_Failed}
	expected_texts := [4]string {
		"codemode\nreturn tools.read({path = \"a.odin\"})\n\n✓ read {\"path\":\"a.odin\"}\n✗ shell {\"command\":\"exit 1\"}\n\n1\n",
		"read\ncontent:\nhello\n",
		"codemode · read\ncontent:\nhello\n",
		"codemode · shell\nexit 1 failed",
	}
	for index in 0 ..< 4 {
		entry := &app.run.snap.entries[index]
		testing.expect_value(t, entry.kind, expected_kinds[index])
		testing.expect(t, !entry.running, "every call settled")
		testing.expect_value(t, entry.tool_outcome, expected_outcomes[index])
		testing.expect_value(t, string(entry.text[:]), expected_texts[index])
	}
	live_boxes := make([dynamic]string, 0, 4, context.allocator)
	defer {
		for box in live_boxes { delete(box, context.allocator) }
		delete(live_boxes)
	}
	for entry in app_entries(&app) {
		if entry.kind != .Codemode && entry.kind != .Tool { continue }
		append(&live_boxes, strings.clone(string(entry.text[:]), context.allocator))
	}
	snapshot_clear(&app)

	store := app.setup.store
	chat := &app.setup.session
	assistant := journal.append_node(
		store,
		{session = id, branch = chat.branch, parent = chat.head, turn = chat.turn, kind = .Assistant},
		journal.Assistant{request = 1},
	)
	outer := journal.next_call(store)
	journal.append_record(
		store,
		{kind = .Tool_Proposed, session = id, branch = chat.branch, node = assistant, turn = chat.turn, request = 1, call = outer},
		journal.Tool_Proposed{provider_id = "call_1", name = "codemode"},
		transmute([]u8)outer_arguments,
	)
	direct := journal.next_call(store)
	journal.append_record(
		store,
		{kind = .Tool_Proposed, session = id, branch = chat.branch, node = assistant, turn = chat.turn, request = 1, call = direct},
		journal.Tool_Proposed{provider_id = "call_2", name = "read"},
		transmute([]u8)direct_arguments,
	)
	read := journal.next_call(store)
	journal.append_record(
		store,
		{kind = .Tool_Proposed, session = id, branch = chat.branch, node = 0, turn = chat.turn, request = 1, call = read, parent_call = outer},
		journal.Tool_Proposed{provider_id = "call_1/1", name = "read"},
		transmute([]u8)read_arguments,
	)
	shell := journal.next_call(store)
	journal.append_record(
		store,
		{kind = .Tool_Proposed, session = id, branch = chat.branch, node = 0, turn = chat.turn, request = 1, call = shell, parent_call = outer},
		journal.Tool_Proposed{provider_id = "call_1/2", name = "shell"},
		transmute([]u8)shell_arguments,
	)
	journal.append_record(
		store,
		{kind = .Tool_Completed, session = id, branch = chat.branch, node = 0, turn = chat.turn, call = read, parent_call = outer},
		journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]},
		transmute([]u8)read_content,
	)
	journal.append_record(
		store,
		{kind = .Tool_Completed, session = id, branch = chat.branch, node = 0, turn = chat.turn, call = shell, parent_call = outer},
		journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Tool_Failed]},
		transmute([]u8)shell_content,
	)
	journal.append_record(
		store,
		{kind = .Tool_Completed, session = id, branch = chat.branch, node = assistant, call = outer},
		journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]},
		transmute([]u8)outer_content,
	)
	journal.append_record(
		store,
		{kind = .Tool_Completed, session = id, branch = chat.branch, node = assistant, call = direct},
		journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]},
		transmute([]u8)read_content,
	)
	_ = journal.append_node(
		store,
		{session = id, branch = chat.branch, parent = assistant, turn = chat.turn, kind = .Results},
		journal.Results{calls = []journal.Call_Id{outer, direct}},
	)
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(t, "the tool calls could not be recorded") }
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { testing.fail_now(t, "projection allocation failed") }
	defer virtual.arena_destroy(&arena)
	_, head, head_error := journal.session_head(store, id)
	if head_error != nil { testing.fail_now(t, "session head read failed") }
	projection, projection_error := agent.projection_load(store, id, head, virtual.arena_allocator(&arena))
	if !testing.expect(t, projection_error == nil) { return }
	testing.expect_value(t, len(projection.nested), 2)
	for item in projection.items {
		if call, ok := item.payload.(agent.Projected_Call);
		   ok { testing.expect(t, call.parent_call == 0, "children must not enter the provider conversation") }
		if result, ok := item.payload.(agent.Projected_Result); ok { testing.expect(t, result.parent_call == 0, "child results must remain display-only") }
	}

	testing.expect(t, session_switch(&app, Start_Fresh{}))
	snapshot_clear(&app)
	session_resume(&app, app_session_id_text(id)[:8])
	testing.expect_value(t, app.setup.session.session, id)

	boxes := make([dynamic]^Entry, 0, 4, context.allocator)
	defer delete(boxes)
	for entry in app_entries(&app) {
		if entry.kind != .Codemode && entry.kind != .Tool { continue }
		append(&boxes, entry)
	}
	if !testing.expect_value(t, len(boxes), 4) { return }
	for index in 0 ..< 4 {
		entry := boxes[index]
		testing.expect_value(t, entry.kind, expected_kinds[index])
		testing.expect_value(t, entry.tool_outcome, expected_outcomes[index])
		testing.expect_value(t, string(entry.text[:]), live_boxes[index])
		testing.expect_value(t, string(entry.text[:]), expected_texts[index])
	}
}

@(test)
test_resume_refuses_an_unknown_reference :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	before := app.setup.session.session
	session_resume(&app, "zzzzzzzz")
	testing.expect_value(t, app.setup.session.session, before)
	testing.expect(t, len(app.run.snap.entries) > 0, "the refusal should be reported")
}

// An idle worker sleeps on the owner wake and not in the queue, so closing the queue and
// signaling the wake is what ends it, with nothing else to wake it.
@(test)
test_an_idle_worker_leaves_when_the_queue_closes :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	channel, channel_err := chan.create_buffered(Work_Chan, 4, app.run.alloc)
	if channel_err != nil { testing.fail_now(t, "the work channel could not be created") }
	app.run.work = channel
	worker := thread.create(run_worker, name = "nabla-test-worker")
	if worker == nil { testing.fail_now(t, "the worker could not be created") }
	worker.data = &app
	thread.start(worker)

	chan.close(&app.run.work)
	agent.owner_wake_signal()
	thread.join(worker)
	thread.destroy(worker)
	chan.destroy(&app.run.work)
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
	entries, _, load_err := journal.read_records(app.setup.store, {session = app.setup.session.session, kinds = {.Node_Committed}}, 0, 0, context.allocator)
	if !testing.expect(t, load_err == nil, "the session's history must be readable") { return }
	defer journal.records_destroy(entries, context.allocator)
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
	// The chat is configured the way selection_install would leave it, because this
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
	defer strings.builder_destroy(&answer)
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
	// The price a resolved selection would carry, so the turn prices the usage it
	// commits from the session's own copy.
	app.setup.session.cost = agent.Catalog_Cost {
		input       = 3,
		output      = 15,
		cache_read  = 0.3,
		cache_write = 3.75,
	}
	app.run.connection = ai.Provider_Connection {
		API        = .Anthropic_Messages,
		Endpoint   = fmt.aprintf("http://127.0.0.1:%d", endpoint.port, allocator = context.temp_allocator),
		Credential = "test-key",
	}

	answer: strings.Builder
	defer strings.builder_destroy(&answer)
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
	totals, usage_error := journal.usage_totals(app.setup.store, app.setup.session.session)
	if !testing.expect_value(t, usage_error, nil) { return }
	testing.expect_value(t, totals.requests, 1)
	testing.expect_value(t, totals.input, i64(1050))
	testing.expect_value(t, totals.cache_read, i64(900))
	testing.expect_value(t, totals.priced_requests, 1)
	// The input total is 100 uncached, 900 read, and 50 written tokens, and the
	// response reported 3 output tokens: 100*3 + 900*0.3 + 50*3.75 + 3*15 dollars
	// per million tokens.
	testing.expectf(t, math.abs(totals.cost - 0.0008025) < 1e-12, "expected $0.0008025, got %v", totals.cost)
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
	binding, binding_ok := mcp_binding_make(nil, "fff", remote_name, context.allocator)
	if !binding_ok { testing.fail_now(t, "the MCP binding could not be created") }
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
	mcp_ok: bool
	app.setup.mcp, mcp_ok = mcp_runtime_make(servers, context.allocator)
	if !mcp_ok { testing.fail_now(t, "the MCP runtime could not be created") }
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

@(test)
test_a_launch_records_its_run_and_the_claims_of_its_sessions :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	err_text: strings.Builder
	defer strings.builder_destroy(&err_text)
	state, previous, had_previous := app_state_isolate(t)
	defer app_state_restore(state, previous, had_previous)

	workspace, workspace_err := os.get_working_directory(context.allocator)
	if workspace_err != nil { testing.fail_now(t, "could not read the working directory") }
	defer delete(workspace, context.allocator)

	// The first launch starts a session, which its first prompt creates and claims.
	first_setup: Run_Setup
	first_setup.alloc = context.allocator
	defer attach_setup_destroy(&first_setup)
	if !testing.expect(t, run_session_attach_test(&first_setup, workspace, Start_Fresh{}, &err_text)) { return }
	session := first_setup.session.session
	first_run := first_setup.run
	directory, clone_error := strings.clone(first_setup.journal_directory, context.temp_allocator)
	if !testing.expect_value(t, clone_error, nil) { return }
	app_session_turn(t, &first_setup)
	attach_setup_destroy(&first_setup)

	// The second launch resumes it, which claims it when the launch takes it.
	second_setup: Run_Setup
	second_setup.alloc = context.allocator
	defer attach_setup_destroy(&second_setup)
	if !testing.expect(t, run_session_attach_test(&second_setup, workspace, Start_Resume_Latest{}, &err_text)) { return }
	second_run := second_setup.run
	attach_setup_destroy(&second_setup)
	testing.expect(t, first_run != second_run, "each launch is a run of its own")

	reader: journal.Journal
	if open_error := journal.open(&reader, directory, "", journal.run_id_create(), .Read_Only, context.allocator); open_error != nil {
		testing.fail_now(t, "the journal could not be opened for reading")
	}
	defer _ = journal.close(&reader)
	records, _, read_error := journal.read_records(
		&reader,
		{kinds = {.Run_Started, .Session_Claimed, .Run_Finished, .Session_Released}},
		0,
		0,
		context.temp_allocator,
	)
	if !testing.expect_value(t, read_error, nil) { return }

	// Each launch opens its run, claims the session, ends its run, and the journal close releases the session.
	expected := [?]journal.Record_Kind{.Run_Started, .Session_Claimed, .Run_Finished, .Session_Released}
	if !testing.expect_value(t, len(records), 2 * len(expected)) { return }
	for record, index in records {
		testing.expect_value(t, record.kind, expected[index % len(expected)])
		testing.expect_value(t, record.run, first_run if index < len(expected) else second_run)
		is_run_record := record.kind == .Run_Started || record.kind == .Run_Finished
		testing.expect_value(t, record.session, journal.Session_Id{} if is_run_record else session)
	}

	started: journal.Run_Started
	testing.expect_value(t, journal.payload_decode(records[0].data, &started, context.temp_allocator), nil)
	testing.expect_value(t, started.pid, int(os.get_pid()))
	claimed: journal.Session_Claimed
	testing.expect_value(t, journal.payload_decode(records[1].data, &claimed, context.temp_allocator), nil)
	testing.expect(t, !claimed.resumed, "a session the launch created is not a resumed one")
	testing.expect_value(t, journal.payload_decode(records[5].data, &claimed, context.temp_allocator), nil)
	testing.expect(t, claimed.resumed, "a session an earlier launch left is a resumed one")
}

@(test)
test_catalog_refresh_enriches_the_active_selection :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.owns_selection = true

	user := []agent.Catalog_Provider_Source{{id = "test-provider", base_url = "http://127.0.0.1:1", api = "openai_chat_completions", api_key = "test-key"}}
	provider := []agent.Catalog_Provider_Source{{id = "test-provider", models = []agent.Catalog_Model_Source{{id = "discovered-model"}}}}
	models_dev := []agent.Catalog_Provider_Source {
		{
			id = "test-provider",
			models = []agent.Catalog_Model_Source {
				{
					id = "discovered-model",
					context_window = 128_000,
					max_output_tokens = 4_096,
					tools = true,
					thinking = agent.Catalog_Thinking_Source{present = true, supported = true, levels = []string{"low", "high"}},
				},
			},
		},
	}

	stage_two, stage_two_err := agent.resolve_catalog(user, provider, {}, app.setup.alloc)
	if !testing.expect_value(t, stage_two_err, agent.Catalog_Error.None) { return }
	app.setup.catalog = stage_two
	testing.expect(t, selection_apply_direct(&app, "test-provider", "discovered-model", "", true))
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

// A fitting model switch is applied only after its fit decision and applied identity
// are committed, while a refusal leaves the active connection untouched.
app_test_switch_catalog :: proc(allocator: mem.Allocator, target_window: int) -> agent.Catalog {
	sources := []agent.Catalog_Provider_Source {
		{
			id = "test-provider",
			base_url = "http://127.0.0.1:1",
			api = "openai_chat_completions",
			api_key = "test-key",
			models = []agent.Catalog_Model_Source {
				{id = "test-model", context_window = 128_000, max_output_tokens = 4_096, tools = true},
				{id = "target-model", api = "openai_responses", context_window = target_window, max_output_tokens = 4_096, tools = true},
			},
		},
	}
	catalog, _ := agent.resolve_catalog(sources, {}, {}, allocator)
	return catalog
}

app_test_selection_request :: proc(app: ^App, provider, model: string) {
	provider_copy := strings.clone(provider, app.run.alloc)
	model_copy := strings.clone(model, app.run.alloc)
	app.run.pending = Pending_Selection {
		provider = provider_copy,
		model    = model_copy,
	}
}

@(test)
test_mid_session_selection_refusal_keeps_the_active_model :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.owns_selection = true
	app.setup.catalog = app_test_switch_catalog(app.setup.alloc, 8)
	defer agent.catalog_destroy(&app.setup.catalog)
	app.setup.session.catalog = app_catalog_ref(&app)
	if !testing.expect(t, selection_apply_direct(&app, "test-provider", "test-model", "", false)) { return }
	previous_api := app.run.connection.API
	app_test_selection_request(&app, "test-provider", "target-model")
	testing.expect(t, !app_selection_service(&app))
	testing.expect_value(t, app.setup.model_id, "test-model")
	testing.expect_value(t, app.run.connection.API, previous_api)
	testing.expect(t, strings.contains(app.run.snap.setup_error, "target"), "the refusal must explain why the switch did not run")
}

@(test)
test_mid_session_selection_commits_the_fitting_target_before_publish :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.owns_selection = true
	app.setup.catalog = app_test_switch_catalog(app.setup.alloc, 128_000)
	defer agent.catalog_destroy(&app.setup.catalog)
	app.setup.session.catalog = app_catalog_ref(&app)
	if !testing.expect(t, selection_apply_direct(&app, "test-provider", "test-model", "", false)) { return }
	app_test_selection_request(&app, "test-provider", "target-model")
	if !testing.expect(t, app_selection_service(&app), "a fitting selection should install at the safe boundary") { return }
	testing.expect_value(t, app.setup.model_id, "target-model")
	testing.expect_value(t, app.run.connection.API, ai.API_Kind.OpenAI_Responses)
	record, found, read_error := journal.read_latest(app.setup.store, {session = app.setup.session.session, kinds = {.Selection_Applied}}, context.allocator)
	if !testing.expect(t, read_error == nil && found, "the installed selection must be durable before publishing success") { return }
	defer journal.record_destroy(&record, context.allocator)
	applied: journal.Selection_Applied
	if !testing.expect_value(t, journal.payload_decode(record.data, &applied, context.temp_allocator), nil) { return }
	testing.expect_value(t, applied.provider, "test-provider")
	testing.expect_value(t, applied.model, "target-model")
	testing.expect_value(t, applied.api, agent.chat_api_name(ai.API_Kind.OpenAI_Responses))
}

@(test)
test_resume_restores_an_installed_selection_without_a_later_turn :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.catalog = app_test_switch_catalog(app.setup.alloc, 128_000)
	defer agent.catalog_destroy(&app.setup.catalog)
	app.setup.session.catalog = app_catalog_ref(&app)
	if !testing.expect(t, selection_apply_direct(&app, "test-provider", "test-model", "", false)) { return }
	app_test_selection_request(&app, "test-provider", "target-model")
	if !testing.expect(t, app_selection_service(&app)) { return }
	session := app.setup.session.session
	if !testing.expect(t, session_switch(&app, Start_Fresh{})) { return }
	if !testing.expect(t, selection_apply_direct(&app, "test-provider", "test-model", "", false)) { return }
	if !testing.expect(t, session_switch(&app, Start_Resume_Id(app_session_id_text(session)))) { return }
	testing.expect_value(t, app.setup.session.model_id, "target-model")
	testing.expect_value(t, app.run.connection.API, ai.API_Kind.OpenAI_Responses)
}

// Follow_Runner is the claimant's worker thread: it waits for a line in its session's
// inbox and runs the turn that delivers it, as the runner's own worker does.
Follow_Runner :: struct {
	chat:       ^agent.Chat_Session,
	connection: ai.Provider_Connection,
	completed:  bool,
}

follow_runner_thread :: proc(thread_handle: ^thread.Thread) {
	runner := cast(^Follow_Runner)thread_handle.data
	deadline := time.tick_add(time.tick_now(), STUB_BOUND)
	for {
		lines, read_error := journal.read_inbox(runner.chat.store, runner.chat.session, 0, context.temp_allocator)
		waiting := read_error == nil && len(lines) > 0
		free_all(context.temp_allocator)
		if waiting { break }
		if time.tick_since(deadline) >= 0 { return }
		time.sleep(2 * time.Millisecond)
	}
	if agent.chat_session_accept_user(runner.chat, "") != .Accepted { return }
	runner.completed = agent.chat_turn_drive(runner.chat, runner.connection, agent.chat_retry_policy_default(), {}, nil, nil)
}

// A headless resume of a session another process runs sends its line to the runner and
// returns the answer of the turn that delivered it: the runner commits the turn through a
// stub endpoint, and the follower, which runs nothing itself, is woken by the commits.
@(test)
test_a_headless_follower_returns_the_answer_of_the_turn_that_delivered_its_line :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if !testing.expectf(t, listen_err == nil, "the stub endpoint could not listen: %v", listen_err) { return }
	defer net.close(listener)
	if block_err := net.set_blocking(listener, false); block_err != nil { testing.fail_now(t, "the stub endpoint could not be made non-blocking") }
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if !testing.expectf(t, endpoint_err == nil, "the stub endpoint could not be read: %v", endpoint_err) { return }

	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.shared_sessions = true
	app.setup.catalog = app_test_catalog(app.setup.alloc)
	defer agent.catalog_destroy(&app.setup.catalog)

	id := app_session_add(t, &app.setup, {workspace = app.setup.workspace}, 7_000)
	runner_store: journal.Journal
	if open_error := journal.open(&runner_store, directory, directory, journal.run_id_create(), .Read_Write, app.setup.alloc); open_error != nil {
		testing.fail_now(t, "the runner's journal could not open")
	}
	defer _ = journal.close(&runner_store)
	if _, claim_error := journal.claim(&runner_store, id); claim_error != nil { testing.fail_now(t, "the runner could not claim the session") }
	chat, tool_error := agent.chat_session_init(&runner_store, id, journal.INITIAL_BRANCH, 0, app.setup.workspace, context.allocator)
	if tool_error.kind != .None { testing.fail_now(t, "the runner's tool registry could not be created") }
	defer agent.chat_session_destroy(&chat)
	chat.skill_instructions = agent.test_skill_instructions(&chat)
	chat.provider_id = strings.clone("test-provider", chat.allocator)
	chat.model_id = strings.clone("test-model", chat.allocator)
	chat.capacity = agent.model_capacity(agent.Catalog_Model{context_window = 128_000})
	runner := Follow_Runner {
		chat = &chat,
		connection = {
			API = .OpenAI_Chat_Completions,
			Endpoint = fmt.aprintf("http://127.0.0.1:%d", endpoint.port, allocator = context.allocator),
			Credential = "test-key",
		},
	}
	defer delete(runner.connection.Endpoint, context.allocator)

	if !testing.expect(t, session_switch(&app, Start_Resume_Id(app_session_id_text(id)))) { return }
	if !testing.expect(t, app_following(&app), "the session runs in the other journal") { return }

	serve := Stub_Serve {
		listener = listener,
		response = COMPLETION_RESPONSE,
	}
	server := thread.create(stub_serve_thread, name = "nabla-stub-provider")
	if server == nil { testing.fail_now(t, "the stub thread could not be created") }
	server.data = &serve
	thread.start(server)
	runner_thread := thread.create(follow_runner_thread, name = "nabla-follow-runner")
	if runner_thread == nil { testing.fail_now(t, "the runner thread could not be created") }
	runner_thread.data = &runner
	thread.start(runner_thread)
	defer {
		thread.join(runner_thread)
		thread.destroy(runner_thread)
		thread.join(server)
		thread.destroy(server)
		testing.expect(t, serve.served, "the runner's turn never made its request")
		testing.expect(t, runner.completed, "the runner's turn should complete")
	}

	answer: strings.Builder
	defer strings.builder_destroy(&answer)
	out := Headless_Output {
		answer = strings.to_writer(&answer),
	}
	testing.expect(t, run_prompt_follow(&app, "from the follower", &out), "the followed turn should complete")
	testing.expect_value(t, strings.to_string(answer), "hello\n")
	testing.expect(t, app_following(&app), "a follower never takes the session")
}

@(test)
test_follower_attachment_replays_captured_pending_input_once :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.shared_sessions = true
	id := app_session_add(t, &app.setup, {workspace = app.setup.workspace}, 7_000)
	runner: journal.Journal
	if error := journal.open(&runner, directory, directory, journal.run_id_create(), .Read_Write, app.setup.alloc);
	   error != nil { testing.fail_now(t, "runner open failed") }
	defer _ = journal.close(&runner)
	if _, error := journal.claim(&runner, id); error != nil { testing.fail_now(t, "runner claim failed") }
	sender: journal.Journal
	if error := journal.open(&sender, directory, directory, journal.run_id_create(), .Read_Write, app.setup.alloc);
	   error != nil { testing.fail_now(t, "sender open failed") }
	defer _ = journal.close(&sender)
	if error := journal.follow(&sender, id); error != nil { testing.fail_now(t, "sender follow failed") }
	if error := journal.append_input(&sender, "captured pending line", .Prompt); error != nil { testing.fail_now(t, "input failed") }
	waiting, error := journal.read_inbox(&runner, id, 0, context.temp_allocator)
	if !testing.expect(t, error == nil && len(waiting) == 1) { return }
	opened, message, ok := session_open(&app.setup, Start_Resume_Id(app_session_id_text(id)), app.setup.workspace)
	defer delete(message, app.setup.alloc)
	defer opened_session_destroy(&opened, app.setup.alloc)
	if !testing.expect(t, ok) { return }
	_, head, head_error := journal.session_head(&runner, id)
	if !testing.expect(t, head_error == nil) { return }
	_ = journal.append_node(
		&runner,
		{session = id, branch = journal.INITIAL_BRANCH, parent = head, kind = .User},
		journal.User{origin = journal.USER_ORIGIN_NAMES[.Prompt], message = waiting[0].seq},
		transmute([]u8)string("captured pending line"),
	)
	if _, error := journal.commit(&runner); error != nil { testing.fail_now(t, "delivery failed") }
	if !testing.expect(t, session_install(&app.setup, &opened) == "") { return }
	session_opened_show(&app)
	_ = app_follow_poll(&app, run_observer(&app))
	testing.expect_value(t, app_entries_count(&app, "captured pending line"), 1)
	testing.expect_value(t, len(app.setup.follow_pending), 0)
}

// A turn that ends with calls still running settles their boxes as unknown, and the script's
// running inner lines with them.
@(test)
test_a_finished_turn_settles_the_boxes_still_running :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	app_observe_call(&app, 7, 0, "codemode", `{"code":"return tools.read({path = \"a.odin\"})"}`)
	app_observe_call(&app, 8, 7, "read", `{"path":"a.odin"}`)
	observer_turn_finished(&app)
	if !testing.expect_value(t, len(app.run.snap.entries), 2) { return }
	for entry in app_entries(&app) {
		testing.expect(t, !entry.running, "no box runs after the turn")
		testing.expect_value(t, entry.tool_outcome, journal.Tool_Outcome.Unknown)
	}
	testing.expect(t, strings.contains(string(app.run.snap.entries[0].text[:]), "✗ read"), "the running line settled as unknown")
	testing.expect_value(t, len(app.run.codemode_pending), 0)
}

// An inner result that arrives after its script settled leaves the script's box as it was
// and creates no pending record.
@(test)
test_an_inner_result_after_the_script_settled_changes_nothing :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	outer_arguments := `{"code":"return 1"}`
	app_observe_call(&app, 7, 0, "codemode", outer_arguments)
	outer_result := agent.Tool_Result {
		content = "ok\nvalue: 1\n\n1",
		outcome = .Success,
	}
	observer_tool_result(&app, 7, 0, "codemode", outer_arguments, &outer_result)
	settled := strings.clone(string(app.run.snap.entries[0].text[:]), context.allocator)
	defer delete(settled, context.allocator)

	inner_result := agent.Tool_Result {
		content = "ok\n\nhello",
		outcome = .Success,
	}
	observer_tool_result(&app, 8, 7, "read", `{"path":"a.odin"}`, &inner_result)
	testing.expect_value(t, string(app.run.snap.entries[0].text[:]), settled)
	testing.expect_value(t, len(app.run.codemode_pending), 0)
}

// A completion the replay already showed, read again by the poll, does not add a second box.
@(test)
test_a_follower_does_not_repeat_a_result_the_replay_showed :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.shared_sessions = true
	id := app_session_add(t, &app.setup, {workspace = app.setup.workspace}, 7_000)
	runner: journal.Journal
	if error := journal.open(&runner, directory, directory, journal.run_id_create(), .Read_Write, app.setup.alloc);
	   error != nil { testing.fail_now(t, "runner open failed") }
	defer _ = journal.close(&runner)
	if _, error := journal.claim(&runner, id); error != nil { testing.fail_now(t, "runner claim failed") }
	chat, tool_error := agent.chat_session_init(&runner, id, journal.INITIAL_BRANCH, 0, app.setup.workspace, context.allocator)
	if tool_error.kind != .None { testing.fail_now(t, "runner initialization failed") }
	defer agent.chat_session_destroy(&chat)
	chat.skill_instructions = agent.test_skill_instructions(&chat)
	if agent.chat_session_accept_user(&chat, "list files") != .Accepted { testing.fail_now(t, "runner prompt failed") }
	assistant := journal.append_node(
		&runner,
		{session = id, branch = chat.branch, parent = chat.head, turn = chat.turn, kind = .Assistant},
		journal.Assistant{request = 1},
	)
	call := journal.next_call(&runner)
	journal.append_record(
		&runner,
		{kind = .Tool_Proposed, session = id, branch = chat.branch, node = assistant, turn = chat.turn, call = call},
		journal.Tool_Proposed{provider_id = "first", name = "shell"},
		transmute([]u8)string(`{"command":"ls"}`),
	)
	journal.append_record(
		&runner,
		{kind = .Tool_Completed, session = id, branch = chat.branch, node = assistant, turn = chat.turn, call = call},
		journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]},
		transmute([]u8)string("ok\nexit_code: 0\n\nstdout:\nfile\n"),
	)
	if _, error := journal.commit(&runner); error != nil { testing.fail_now(t, "commit failed") }
	if !testing.expect(t, session_switch(&app, Start_Resume_Id(app_session_id_text(id)))) { return }
	session_opened_show(&app)

	// The poll position sits before the completion, as when the journal moved after the
	// follow started but before the replay read it.
	completed, _, read_error := journal.read_records(app.setup.store, {session = id, kinds = {.Tool_Completed}}, 0, 0, context.temp_allocator)
	if !testing.expect(t, read_error == nil && len(completed) == 1) { return }
	app.setup.follow.last = completed[0].seq - 1
	_ = app_follow_poll(&app, run_observer(&app))
	boxes := 0
	for entry in app_entries(&app) {
		if entry.kind != .Tool { continue }
		boxes += 1
		testing.expect(t, !entry.running, "the replayed result is finished")
	}
	testing.expect_value(t, boxes, 1)
}

@(test)
test_busy_follower_input_retries_once_and_keeps_order :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.shared_sessions = true
	id := app_session_add(t, &app.setup, {workspace = app.setup.workspace}, 7_000)
	runner: journal.Journal
	if error := journal.open(&runner, directory, directory, journal.run_id_create(), .Read_Write, app.setup.alloc);
	   error != nil { testing.fail_now(t, "runner open failed") }
	defer _ = journal.close(&runner)
	if _, error := journal.claim(&runner, id); error != nil { testing.fail_now(t, "runner claim failed") }
	if !testing.expect(t, session_switch(&app, Start_Resume_Id(app_session_id_text(id)))) { return }
	if error := db.exec(&app.setup.store.connection, "PRAGMA busy_timeout=0"); error != nil { testing.fail_now(t, "busy timeout failed") }
	if error := db.exec(&runner.connection, "BEGIN IMMEDIATE"); error != nil { testing.fail_now(t, "writer begin failed") }
	defer _ = db.rollback(&runner.connection)
	observer := run_observer(&app)
	app_follow_submit(&app, "first pending line", observer)
	app_follow_submit(&app, "second pending line", observer)
	testing.expect_value(t, app_entries_count(&app, "first pending line"), 0)
	testing.expect(t, app.setup.follow_input_busy)
	deadline, present := journal.flush_deadline(app.setup.store).?
	testing.expect(t, present && time.tick_diff(time.tick_now(), deadline) > 0, "Busy must rearm a future deadline")
	if error := db.rollback(&runner.connection); error != nil { testing.fail_now(t, "writer release failed") }
	_ = app_follow_service(&app, observer)
	_ = app_follow_service(&app, observer)
	testing.expect_value(t, app_entries_count(&app, "first pending line"), 1)
	testing.expect_value(t, app_entries_count(&app, "second pending line"), 1)
	waiting, error := journal.read_inbox(&runner, id, 0, context.temp_allocator)
	testing.expect(t, error == nil)
	if !testing.expect_value(t, len(waiting), 2) { return }
	testing.expect_value(t, string(waiting[0].body), "first pending line")
	testing.expect_value(t, string(waiting[1].body), "second pending line")
}

@(test)
test_busy_takeover_retries_only_on_new_submit :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.shared_sessions = true
	id := app_session_add(t, &app.setup, {workspace = app.setup.workspace}, 7_000)
	runner: journal.Journal
	if error := journal.open(&runner, directory, directory, journal.run_id_create(), .Read_Write, app.setup.alloc);
	   error != nil { testing.fail_now(t, "runner open failed") }
	defer _ = journal.close(&runner)
	if _, error := journal.claim(&runner, id); error != nil { testing.fail_now(t, "runner claim failed") }
	if !testing.expect(t, session_switch(&app, Start_Resume_Id(app_session_id_text(id)))) { return }
	if error := db.exec(&app.setup.store.connection, "PRAGMA busy_timeout=0"); error != nil { testing.fail_now(t, "busy timeout failed") }
	if error := db.exec(&runner.connection, "BEGIN IMMEDIATE"); error != nil { testing.fail_now(t, "writer begin failed") }
	defer _ = db.rollback(&runner.connection)
	observer := run_observer(&app)
	app_follow_submit(&app, "retained during takeover", observer)
	if error := journal.release(&runner); error != nil { testing.fail_now(t, "runner release failed") }
	_ = app_follow_service(&app, observer)
	testing.expect(t, app.setup.takeover_failed && app.setup.takeover_retryable && app_following(&app))
	if error := db.rollback(&runner.connection); error != nil { testing.fail_now(t, "writer release failed") }
	_ = app_follow_service(&app, observer)
	testing.expect(t, app_following(&app), "release wake must not retry the failed takeover")
	app_follow_submit(&app, "explicit retry", observer)
	_ = app_follow_service(&app, observer)
	testing.expect(t, !app_following(&app), "a new submission retries transient takeover failure")
	testing.expect_value(t, app_entries_count(&app, "retained during takeover"), 1)
	testing.expect_value(t, app_entries_count(&app, "explicit retry"), 1)
}

@(test)
test_takeover_shows_input_first_committed_by_recovery :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	app.setup.shared_sessions = true
	id := app_session_add(t, &app.setup, {workspace = app.setup.workspace}, 7_000)
	runner: journal.Journal
	if error := journal.open(&runner, directory, directory, journal.run_id_create(), .Read_Write, app.setup.alloc);
	   error != nil { testing.fail_now(t, "runner open failed") }
	defer _ = journal.close(&runner)
	if _, error := journal.claim(&runner, id); error != nil { testing.fail_now(t, "runner claim failed") }
	if !testing.expect(t, session_switch(&app, Start_Resume_Id(app_session_id_text(id)))) { return }
	if error := db.exec(&app.setup.store.connection, "PRAGMA busy_timeout=0"); error != nil { testing.fail_now(t, "busy timeout failed") }
	if error := db.exec(&runner.connection, "BEGIN IMMEDIATE"); error != nil { testing.fail_now(t, "writer begin failed") }
	defer _ = db.rollback(&runner.connection)
	observer := run_observer(&app)
	app_follow_submit(&app, "first committed in recovery", observer)
	if error := db.rollback(&runner.connection); error != nil { testing.fail_now(t, "writer release failed") }
	if error := journal.release(&runner); error != nil { testing.fail_now(t, "runner release failed") }
	if _, error := journal.try_claim(app.setup.store); error != nil { testing.fail_now(t, "takeover claim failed") }
	app_takeover(&app, observer)
	testing.expect(t, !app_following(&app))
	testing.expect_value(t, app_entries_count(&app, "first committed in recovery"), 1)
}

// A subagent's session opened by its id is the agent its orchestrator ran: it takes the role
// instructions with the instruction its parent recorded, and the tools without the ones that
// manage subagents. The menu lists it under its parent with the name the parent gave it.
@(test)
test_opening_a_child_session_installs_the_subagent_role :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)
	parent := app.setup.session.session
	child := journal.session_id_create()
	journal.append_record(
		app.setup.store,
		{kind = .Subagent_Started, session = parent, branch = journal.INITIAL_BRANCH, call = 1, subagent = child},
		journal.Subagent_Started{name = "agent-1", background = true},
		transmute([]u8)string("Review the parser."),
	)
	if _, commit_error := journal.commit(app.setup.store); commit_error != nil { testing.fail_now(t, "the delegation could not be committed") }
	child_store: journal.Journal
	if open_error := journal.open(&child_store, directory, directory, journal.run_id_create(), .Read_Write, app.setup.alloc); open_error != nil {
		testing.fail_now(t, "the child's journal could not be opened")
	}
	_, create_error := journal.create_session(
		&child_store,
		{id = child, workspace = app.setup.workspace, role = .Subagent, parent_session = parent, parent_call = 1},
	)
	if create_error != nil { testing.fail_now(t, "the child's session could not be created") }
	if _, commit_error := journal.commit(&child_store); commit_error != nil { testing.fail_now(t, "the child's session could not be committed") }
	_ = journal.close(&child_store)

	snapshot_clear(&app)
	session_refresh_rows(&app)
	if !testing.expect_value(t, len(app.run.snap.sessions), 2) { return }
	testing.expect_value(t, app.run.snap.sessions[0].id, parent)
	testing.expect_value(t, app.run.snap.sessions[1].id, child)
	testing.expect(t, app.run.snap.sessions[1].child)
	testing.expect_value(t, app.run.snap.sessions[1].title, "agent-1")

	// A prefix of the child's id resumes it like any session's.
	snapshot_clear(&app)
	session_resume(&app, app_session_id_text(child)[:8])
	if !testing.expect_value(t, app.setup.session.session, child) { return }
	session := &app.setup.session
	testing.expect_value(t, session.role, journal.Session_Role.Subagent)
	testing.expect(t, strings.has_prefix(session.role_instructions, agent.SUBAGENT_ROLE), "the child has the subagent role")
	testing.expect(t, strings.has_suffix(session.role_instructions, "Review the parser."), "the child has the instruction its parent gave it")
	testing.expect(t, session.team == nil, "a subagent starts no subagents")
	readable := false
	can_message := false
	for definition in session.tools.definitions {
		testing.expect(t, definition.kind != .Agents, definition.name)
		if definition.name == agent.TOOL_READ_NAME { readable = true }
		if definition.name == agent.TOOL_AGENT_NAME {
			can_message = true
			testing.expect(t, strings.contains(definition.input_schema, `"enum":["message"]`), "the child can only message its orchestrator")
		}
	}
	testing.expect(t, readable, "the child keeps the parent's other tools")
	testing.expect(t, can_message, "the child keeps orchestrator messaging")
}

// app_entry_kind is the kind of the entry carrying exactly text.
app_entry_kind :: proc(app: ^App, text: string) -> (kind: Entry_Kind, found: bool) {
	for entry in app_entries(app) {
		if string(entry.text[:]) == text { return entry.kind, true }
	}
	return .Notice, false
}

// A text another agent sent shows as its own kind of entry, live and replayed: the
// observer maps an .Agent origin to .Subagent, and so does the replay of the User
// node the delivery committed.
@(test)
test_agent_origin_text_shows_as_a_subagent_entry_live_and_replayed :: proc(t: ^testing.T) {
	app: App
	directory := app_session_begin(t, &app)
	defer app_session_end(&app, directory)

	observer_user_text(&app, "agent-1 answered\nforty-two", .Agent)
	observer_user_text(&app, "a prompt", .Prompt)
	kind, found := app_entry_kind(&app, "agent-1 answered\nforty-two")
	testing.expect(t, found, "the live agent text shows")
	testing.expect_value(t, kind, Entry_Kind.Subagent)
	kind, found = app_entry_kind(&app, "a prompt")
	testing.expect(t, found, "the live prompt shows")
	testing.expect_value(t, kind, Entry_Kind.User)

	// Another process's line with an .Agent origin is what a subagent's report
	// looks like on the wire; accepting it delivers a User node of that origin.
	sender: journal.Journal
	if error := journal.open(&sender, directory, directory, journal.run_id_create(), .Read_Write); error != nil {
		testing.fail_now(t, "the sender journal did not open")
	}
	defer _ = journal.close(&sender)
	if error := journal.follow(&sender, app.setup.session.session); error != nil { testing.fail_now(t, "the sender could not follow") }
	if error := journal.append_input(&sender, "agent-1 asks\nwhat next", .Agent); error != nil { testing.fail_now(t, "the agent line was not accepted") }
	accepted := agent.chat_session_accept_message(&app.setup.session, "", .Agent, run_observer(&app))
	if !testing.expect_value(t, accepted, agent.Chat_Accept.Accepted) { return }
	kind, found = app_entry_kind(&app, "agent-1 asks\nwhat next")
	testing.expect(t, found, "the delivered agent text shows")
	testing.expect_value(t, kind, Entry_Kind.Subagent)

	snapshot_clear(&app)
	session_opened_show(&app)
	kind, found = app_entry_kind(&app, "agent-1 asks\nwhat next")
	testing.expect(t, found, "the replayed agent text shows")
	testing.expect_value(t, kind, Entry_Kind.Subagent)
}
