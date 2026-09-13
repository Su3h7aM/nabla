#+test
#+private file
package main

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

	app.run.alloc = context.allocator
	app.setup.alloc = context.allocator
	app.run.snap.entries = make([dynamic]Entry, 0, 4, app.run.alloc)

	if store_err := session.store_open(&app.setup.store, directory); store_err != nil {
		testing.fail_now(t, "store_open failed")
	}
	workspace := strings.clone("/tmp/nabla-app-test", context.allocator)
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
	menu_destroy(&app.menu, app.run.alloc)
	delete(app.setup.workspace, app.setup.alloc)
	os.remove_all(directory)
	delete(directory, context.allocator)
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
