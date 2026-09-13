#+test
#+private file
package main

import "core:strings"
import "core:sync/chan"
import "core:testing"

import "nabla:agent/session"
import "nabla:tui/widgets"

// The slash-command machinery needs the prompt buffer, a snapshot to report
// into, and the work channel a menu submits through. It needs no terminal.

command_app :: proc(t: ^testing.T, app: ^App) {
	app.run.alloc = context.allocator
	app.setup.alloc = context.allocator
	app.run.snap.entries = make([dynamic]Entry, 0, 4, app.run.alloc)
	app.input = widgets.Input{}
	widgets.input_init(&app.input, app.run.alloc)
	app.run.work, _ = chan.create_buffered(Work_Chan, WORK_CAPACITY, app.run.alloc)
}

command_app_end :: proc(app: ^App) {
	menu_destroy(&app.menu, app.run.alloc)
	delete(app.completion_query, app.run.alloc)
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
	delete(app.run.snap.status.effort, app.run.alloc)
	for level in app.run.snap.status.effort_levels { delete(level, app.run.alloc) }
	delete(app.run.snap.status.effort_levels)
	chan.destroy(&app.run.work)
	widgets.input_destroy(&app.input)
}

@(test)
test_tab_cycles_every_command :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	testing.expect(t, widgets.input_insert(&app.input, "/"))
	for step in 0 ..< len(COMMANDS) {
		complete_command(&app)
		testing.expect_value(t, widgets.input_text(&app.input), COMMANDS[step].name)
	}
	// The cycle wraps rather than stopping at the end.
	complete_command(&app)
	testing.expect_value(t, widgets.input_text(&app.input), COMMANDS[0].name)
}

@(test)
test_tab_completes_a_unique_prefix :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	testing.expect(t, widgets.input_insert(&app.input, "/he"))
	complete_command(&app)
	testing.expect_value(t, widgets.input_text(&app.input), "/help")

	// A capital is a typo rather than a miss.
	widgets.input_clear(&app.input)
	testing.expect(t, widgets.input_insert(&app.input, "/HE"))
	complete_command(&app)
	testing.expect_value(t, widgets.input_text(&app.input), "/help")
}

@(test)
test_editing_starts_a_new_cycle :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	testing.expect(t, widgets.input_insert(&app.input, "/"))
	complete_command(&app)
	complete_command(&app)
	testing.expect_value(t, widgets.input_text(&app.input), "/help")

	// Backspace is an edit, so the cycle ends. The next Tab matches what is left on
	// screen ("hel", which is only /help) instead of continuing the old one, which
	// would have reached /new.
	handle_key(&app, {code = .Backspace})
	testing.expect_value(t, widgets.input_text(&app.input), "/hel")
	complete_command(&app)
	testing.expect_value(t, widgets.input_text(&app.input), "/help")
}

@(test)
test_help_lists_every_command :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	dispatch_command(&app, "/help")
	help := strings.builder_make(context.temp_allocator)
	for &entry in app.run.snap.entries {
		strings.write_string(&help, string(entry.text[:]))
		strings.write_byte(&help, '\n')
	}
	text := strings.to_string(help)
	for command in COMMANDS {
		testing.expectf(t, strings.contains(text, command.name), "%s is missing from the help", command.name)
		testing.expectf(t, strings.contains(text, command.summary), "%s has no summary in the help", command.name)
	}
}

@(test)
test_an_unknown_command_is_reported :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	dispatch_command(&app, "/nope")
	if !testing.expect_value(t, len(app.run.snap.entries), 1) { return }
	entry := &app.run.snap.entries[0]
	testing.expect_value(t, entry.kind, Entry_Kind.Notice)
	testing.expect(t, strings.contains(string(entry.text[:]), "/nope"), "the refusal should name what was typed")
	testing.expect(t, !app.menu_open, "an unknown command opens nothing")
}

@(test)
test_effort_menu_offers_the_default_and_every_level :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	append(&app.run.snap.status.effort_levels, strings.clone("low", app.run.alloc))
	append(&app.run.snap.status.effort_levels, strings.clone("high", app.run.alloc))
	app.run.snap.status.effort = strings.clone("high", app.run.alloc)

	dispatch_command(&app, "/effort")
	testing.expect(t, app.menu_open)
	if !testing.expect_value(t, len(app.menu.choices), 3) { return }
	testing.expect_value(t, app.menu.choices[0].label, "provider default")
	testing.expect_value(t, app.menu.choices[2].label, "high")
	// The menu opens where the user already is.
	testing.expect_value(t, app.menu.cursor, 2)

	// The default choice means no level, which is how the agent reads it.
	app.menu.cursor = 0
	menu_submit(&app)
	work, received := chan.try_recv(app.run.work)
	if !testing.expect(t, received, "the choice should become work") { return }
	defer delete(work.text, app.run.alloc)
	testing.expect_value(t, work.kind, Work_Kind.Effort)
	testing.expect_value(t, work.text, "")
}

@(test)
test_the_session_menu_opens_where_the_worker_is :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	append(
		&app.run.snap.sessions,
		Session_Row {
			id = session.Session_Id(strings.clone("0123456789abcdef0123456789abcdef", app.run.alloc)),
			title = strings.clone("first task", app.run.alloc),
		},
	)
	append(
		&app.run.snap.sessions,
		Session_Row {
			id = session.Session_Id(strings.clone("fedcba9876543210fedcba9876543210", app.run.alloc)),
			title = strings.clone("second task", app.run.alloc),
		},
	)
	// The worker publishes which session it is running, because the menu must not
	// read the running session itself.
	app.run.snap.active_session = session.Session_Id(strings.clone("fedcba9876543210fedcba9876543210", app.run.alloc))

	menu_open_session(&app)
	defer menu_close(&app)
	if !testing.expect_value(t, len(app.menu.choices), 2) { return }
	testing.expect_value(t, app.menu.cursor, 1)
}

@(test)
test_session_menu_choices_become_resume_work :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	// The worker owns the store, so the menu shows the list it published.
	append(
		&app.run.snap.sessions,
		Session_Row {
			id = session.Session_Id(strings.clone("0123456789abcdef0123456789abcdef", app.run.alloc)),
			title = strings.clone("first task", app.run.alloc),
		},
	)
	append(
		&app.run.snap.sessions,
		Session_Row {
			id = session.Session_Id(strings.clone("fedcba9876543210fedcba9876543210", app.run.alloc)),
			title = strings.clone("second task", app.run.alloc),
		},
	)

	dispatch_command(&app, "/resume")
	testing.expect(t, app.menu_open)
	if !testing.expect_value(t, len(app.menu.choices), 2) { return }
	testing.expect_value(t, app.menu.choices[1].label, "second task")
	// The id is shown only to tell two untitled sessions apart; it is not typed.
	testing.expect_value(t, app.menu.choices[1].detail, "fedcba98")

	app.menu.cursor = 1
	menu_submit(&app)
	testing.expect(t, !app.menu_open, "a menu opened from the prompt closes on submit")
	work, received := chan.try_recv(app.run.work)
	if !testing.expect(t, received, "the choice should become work") { return }
	defer delete(work.text, app.run.alloc)
	testing.expect_value(t, work.kind, Work_Kind.Resume_Session)
	testing.expect_value(t, work.text, "fedcba9876543210fedcba9876543210")
}

@(test)
test_a_menu_can_be_cancelled_but_the_chooser_cannot :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	dispatch_command(&app, "/effort")
	testing.expect(t, app.menu_open)
	handle_menu_key(&app, {code = .Escape})
	testing.expect(t, !app.menu_open, "escape returns to the prompt")
	testing.expect(t, !app.quit)

	// The startup chooser has nothing to fall back to, so escape quits.
	app.menu_open = true
	app.menu.required = true
	handle_menu_key(&app, {code = .Escape})
	testing.expect(t, app.quit)
}
