#+test
#+private file
package main

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import "core:thread"

import "nabla:agent"
import "nabla:agent/journal"
import "nabla:tui/widgets"

// The slash-command machinery needs the prompt buffer, a snapshot to report
// into, and the work channel a menu submits through. It needs no terminal.

command_app :: proc(t: ^testing.T, app: ^App) {
	app.run.alloc = context.allocator
	app.setup.alloc = context.allocator
	directory, dir_error := os.make_directory_temp("", "nabla-command-test-*", context.allocator)
	if dir_error != nil { testing.fail_now(t, "cannot create test directory") }
	app.setup.journal_directory = directory
	store, open_error := journal.open(directory, directory, journal.run_id_create(), .Read_Write, context.allocator)
	if open_error != nil { testing.fail_now(t, "cannot open journal") }
	app.queue_journal = store
	session, create_error := journal.create_session(store, {workspace = directory, role = .Main})
	if create_error != nil { testing.fail_now(t, "cannot create session") }
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(t, "cannot commit session") }
	app.queue_session = session
	app.run.snap.entries = make([dynamic]Entry, 0, 4, app.run.alloc)
	app.input = widgets.Input{}
	widgets.input_init(&app.input, app.run.alloc)
	widgets.history_init(&app.history, app.run.alloc)
	app.run.work, _ = chan.create_buffered(Work_Chan, WORK_CAPACITY, app.run.alloc)
}

command_app_end :: proc(app: ^App) {
	_ = journal.close(app.queue_journal)
	_ = os.remove_all(app.setup.journal_directory)
	delete(app.setup.journal_directory)
	menu_destroy(&app.menu, app.run.alloc)
	delete(app.completion_query, app.run.alloc)
	for &entry in app.run.snap.entries {
		if entry.text != nil { delete(entry.text) }
	}
	delete(app.run.snap.entries)
	for &row in app.run.snap.sessions {
		delete(row.title, app.run.alloc)
	}
	delete(app.run.snap.sessions)
	delete(app.run.snap.status.effort, app.run.alloc)
	for level in app.run.snap.status.effort_levels { delete(level, app.run.alloc) }
	delete(app.run.snap.status.effort_levels)
	chan.destroy(&app.run.work)
	widgets.history_destroy(&app.history)
	widgets.input_destroy(&app.input)
}

@(test)
test_compact_is_observed_during_a_turn_without_draining_work :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)
	set_running(&app, true)
	app.setup.session.state = .Requesting
	app.setup.session.compact.state = .Retiring
	for index in 0 ..< WORK_CAPACITY {
		if !testing.expect(t, work_send(&app, {kind = .Status})) { return }
	}
	dispatch_command(&app, "/compact")
	testing.expect(t, sync.atomic_load(&app.run.compact_pending))
	testing.expect(t, len(app.run.snap.entries) == 0, "dispatch must not run a session command on the frontend")
	testing.expect(t, runtime_busy(&app), "asking for compaction must not stop the active turn")
	for index in 0 ..< WORK_CAPACITY {
		work, received := chan.try_recv(app.run.work)
		if !testing.expect(t, received, "observation must leave ordinary work queued") { break }
		testing.expect_value(t, work.kind, Work_Kind.Status)
	}
}

@(test)
test_tab_cycles_every_command :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	testing.expect(t, widgets.input_insert(&app.input, "/") == nil)
	// The ranked order of a bare slash is the library's, so the test checks that
	// one cycle of Tab presses reaches every command once.
	seen: map[string]bool
	defer delete(seen)
	for _ in 0 ..< len(COMMANDS) {
		complete_command(&app)
		name := strings.clone(widgets.input_text(&app.input), context.temp_allocator)
		seen[name] = true
	}
	testing.expect_value(t, len(seen), len(COMMANDS))
}

@(test)
test_tab_completes_a_unique_prefix :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	testing.expect(t, widgets.input_insert(&app.input, "/he") == nil)
	complete_command(&app)
	testing.expect_value(t, widgets.input_text(&app.input), "/help")

	// A capital is a typo rather than a miss.
	widgets.input_clear(&app.input)
	testing.expect(t, widgets.input_insert(&app.input, "/HE") == nil)
	complete_command(&app)
	testing.expect_value(t, widgets.input_text(&app.input), "/help")
}

// The fuzzy ranking puts /effort before /detach, which only contains the letter, so "/e" completes to /effort.
@(test)
test_tab_completes_to_the_closest_name :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	testing.expect(t, widgets.input_insert(&app.input, "/e") == nil)
	complete_command(&app)
	testing.expect_value(t, widgets.input_text(&app.input), "/effort")
}

@(test)
test_tab_completes_a_typo :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	testing.expect(t, widgets.input_insert(&app.input, "/modle") == nil)
	complete_command(&app)
	testing.expect_value(t, widgets.input_text(&app.input), "/model")
}

@(test)
test_a_menu_filters_its_choices_as_you_type :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	choices := make([dynamic]Choice, 0, 3, app.run.alloc)
	for label in ([]string{"gpt-4o", "claude-sonnet-4", "o3-mini"}) {
		append(&choices, Choice{label = strings.clone(label, app.run.alloc)})
	}
	testing.expect(t, menu_begin(&app, .Model, "models", choices, false))

	// "sonet" is one byte short of "sonnet", and only the Claude choice is that close.
	for character in "sonet" {
		handle_menu_key(&app, {code = .Character, character = character})
	}
	testing.expect_value(t, menu_visible_count(&app.menu), 1)
	testing.expect_value(t, app.menu.choices[menu_choice_index(&app.menu, 0)].label, "claude-sonnet-4")

	for _ in 0 ..< 5 {
		handle_menu_key(&app, {code = .Backspace})
	}
	testing.expect_value(t, menu_visible_count(&app.menu), 3)
}

@(test)
test_ctrl_r_forces_a_model_catalog_refresh :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	refresh, refresh_error := chan.create_buffered(Catalog_Refresh_Chan, CATALOG_REFRESH_CAPACITY, context.allocator)
	testing.expect(t, refresh_error == nil)
	app.catalog_refresh = refresh
	defer chan.destroy(&app.catalog_refresh)
	app.catalog_worker = thread.create(catalog_test_idle_worker)
	defer thread.destroy(app.catalog_worker)
	testing.expect(t, menu_begin(&app, .Model, "models", {}, false))

	// A refresh was just asked for, so the cooldown is running and a plain request is not sent.
	catalog_refresh_note(&app)
	catalog_refresh_request(&app)
	_, sent := chan.try_recv(app.catalog_refresh)
	testing.expect(t, !sent, "a request inside the cooldown is not sent")

	handle_menu_key(&app, {code = .Character, character = 'r', modifiers = {.Control}})
	_, sent = chan.try_recv(app.catalog_refresh)
	testing.expect(t, sent, "ctrl+r sends a refresh inside the cooldown")
}

catalog_test_idle_worker :: proc(worker: ^thread.Thread) {  }

@(test)
test_tab_indents_a_non_empty_prompt :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	testing.expect(t, widgets.input_insert(&app.input, "note") == nil)
	handle_key(&app, {code = .Tab})
	testing.expect_value(t, widgets.input_text(&app.input), "note\t")
	testing.expect(t, !app.transcript.focused, "Tab in text does not leave the prompt")

	// A command prefix still completes instead of indenting.
	widgets.input_clear(&app.input)
	testing.expect(t, widgets.input_insert(&app.input, "/he") == nil)
	handle_key(&app, {code = .Tab})
	testing.expect_value(t, widgets.input_text(&app.input), "/help")

	widgets.input_clear(&app.input)
	handle_key(&app, {code = .Tab})
	testing.expect_value(t, widgets.input_text(&app.input), "")
	testing.expect(t, app.transcript.focused, "Tab on an empty prompt focuses the transcript")
}

@(test)
test_editing_starts_a_new_cycle :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	testing.expect(t, widgets.input_insert(&app.input, "/") == nil)
	complete_command(&app)
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

// Only a word shaped like a command name is a command; a path is a prompt, and an unknown command stays in the prompt.
@(test)
test_a_leading_path_is_a_prompt_and_an_unknown_command_stays :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	if !testing.expect(t, widgets.input_insert(&app.input, "/tmp/shot.png what is this?") == nil) { return }
	submit(&app)
	entries, err := journal.queue_list(app.queue_journal, app.queue_session, app.run.alloc)
	if !testing.expect(t, err == nil && len(entries) == 1) { return }
	defer journal.queue_entries_destroy(entries, app.run.alloc)
	testing.expect_value(t, entries[0].text, "/tmp/shot.png what is this?")
	_, _ = chan.try_recv(app.run.work)
	for entry in app.run.snap.entries {
		testing.expect(t, entry.kind != .Notice, "a path is not an unknown command")
	}

	if !testing.expect(t, widgets.input_insert(&app.input, "/hepl") == nil) { return }
	submit(&app)
	testing.expect_value(t, widgets.input_text(&app.input), "/hepl")
	_, queued := chan.try_recv(app.run.work)
	testing.expect(t, !queued, "an unknown command is not sent")
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
	testing.expect_value(t, app.menu.list.selected, 2)

	// The default choice means no level, which is how the agent reads it.
	app.menu.list.selected = 0
	menu_submit(&app)
	work, received := chan.try_recv(app.run.work)
	if !testing.expect(t, received, "the choice should become work") { return }
	defer delete(work.text, app.run.alloc)
	testing.expect_value(t, work.kind, Work_Kind.Effort)
	testing.expect_value(t, work.text, "")
}

@(test)
test_session_menu_choices_become_resume_work :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	// The worker owns the store, so the menu shows the list it published.
	first_id, first_valid := journal.session_id_parse("0123456789abcdef0123456789abcdef")
	second_id, second_valid := journal.session_id_parse("fedcba9876543210fedcba9876543210")
	if !testing.expect(t, first_valid && second_valid) { return }
	append(&app.run.snap.sessions, Session_Row{id = first_id, title = strings.clone("first task", app.run.alloc)})
	append(&app.run.snap.sessions, Session_Row{id = second_id, title = strings.clone("second task", app.run.alloc)})

	dispatch_command(&app, "/resume")
	testing.expect(t, app.menu_open)
	if !testing.expect_value(t, len(app.menu.choices), 2) { return }
	testing.expect_value(t, app.menu.choices[1].label, "second task")
	// The id is shown only to tell two untitled sessions apart; it is not typed.
	testing.expect_value(t, app.menu.choices[1].detail, "fedcba98")

	app.menu.list.selected = 1
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

// Escape and ctrl+c close an open menu alike, and quit the startup chooser alike.
@(test)
test_ctrl_c_and_escape_close_a_menu_the_same_way :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	dispatch_command(&app, "/effort")
	handle_menu_key(&app, {code = .Character, character = 'c', modifiers = {.Control}})
	testing.expect(t, !app.menu_open && !app.quit, "ctrl+c returns to the prompt like escape")

	app.menu_open = true
	app.menu.required = true
	handle_menu_key(&app, {code = .Character, character = 'c', modifiers = {.Control}})
	testing.expect(t, app.quit, "ctrl+c quits the startup chooser like escape")
}

// The up arrow walks back through the prompts submitted this run, newest first.
// A slash command reaches dispatch_command and is not a prompt, so it never
// enters the history: two commands around one prompt leave one entry. What a
// recall shows is ordinary input, so it can be edited before it is sent again.
@(test)
test_up_arrow_walks_prompt_history :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)
	app.columns = 40

	// The example: two commands around one prompt, and only the prompt counts.
	sequence := [?]string{"/help", "Explain how this works", "/help"}
	for typed in sequence {
		if !testing.expect(t, widgets.input_insert(&app.input, typed) == nil) { return }
		submit(&app)
	}
	if !testing.expect_value(t, len(app.history.entries), 1) { return }

	// One step back shows the only prompt, and there is nowhere further back.
	handle_key(&app, {code = .Up})
	testing.expect_value(t, widgets.input_text(&app.input), "Explain how this works")
	handle_key(&app, {code = .Up})
	testing.expect_value(t, widgets.input_text(&app.input), "Explain how this works")

	// The recalled prompt is edited like anything typed...
	handle_key(&app, {code = .Backspace})
	testing.expect_value(t, widgets.input_text(&app.input), "Explain how this work")

	// ...and down steps forward again, past the newest entry to a fresh line.
	handle_key(&app, {code = .Down})
	testing.expect_value(t, widgets.input_text(&app.input), "")

	// A prompt recalled, edited, and sent enters history like any other.
	handle_key(&app, {code = .Up})
	handle_key(&app, {code = .Backspace})
	submit(&app)
	if !testing.expect_value(t, len(app.history.entries), 2) { return }
	handle_key(&app, {code = .Up})
	testing.expect_value(t, widgets.input_text(&app.input), "Explain how this work")

	// The prompts went to the worker queue; release what they carry.
	for {
		work, received := chan.try_recv(app.run.work)
		if !received { break }
		work_destroy(&app, work)
	}
}

// Submitting a prompt follows the bottom from wherever the transcript was scrolled; a slash command leaves the scroll alone.
@(test)
test_submitting_a_prompt_jumps_to_the_bottom :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)
	widgets.scroll_set_range(&app.conversation_scroll, 100)

	widgets.scroll_to(&app.conversation_scroll, 10)
	if !testing.expect(t, widgets.input_insert(&app.input, "/help") == nil) { return }
	submit(&app)
	testing.expect_value(t, app.conversation_scroll.top, Maybe(int)(10))

	if !testing.expect(t, widgets.input_insert(&app.input, "Explain how this works") == nil) { return }
	submit(&app)
	testing.expect(t, app.conversation_scroll.top == nil, "a submitted prompt follows the bottom")

	for {
		work, received := chan.try_recv(app.run.work)
		if !received { break }
		work_destroy(&app, work)
	}
}

// The line being typed is not a submitted prompt, so an up arrow that walks
// into history must not destroy it: leaving the fresh line keeps what it
// holds, and stepping forward past the newest entry puts it back exactly as it
// was. The draft stays out of the stored prompts.
@(test)
test_history_keeps_the_line_being_typed :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)
	// Wide enough that neither line wraps, so the up arrow walks history
	// instead of moving the caret between rows.
	app.columns = 80

	// One submitted prompt for the history to hold.
	if !testing.expect(t, widgets.input_insert(&app.input, "Explain how this works") == nil) { return }
	submit(&app)
	if !testing.expect_value(t, len(app.history.entries), 1) { return }

	// The user starts composing, then a stray up arrow walks into history.
	draft := "Write a detailed explanation about..."
	if !testing.expect(t, widgets.input_insert(&app.input, draft) == nil) { return }
	handle_key(&app, {code = .Up})
	testing.expect_value(t, widgets.input_text(&app.input), "Explain how this works")

	// Down returns to exactly what was being typed...
	handle_key(&app, {code = .Down})
	testing.expect_value(t, widgets.input_text(&app.input), draft)

	// ...the draft never entered history itself...
	testing.expect_value(t, len(app.history.entries), 1)

	// ...and the next walk finds the same single entry.
	handle_key(&app, {code = .Up})
	testing.expect_value(t, widgets.input_text(&app.input), "Explain how this works")

	// The prompt submit entered the worker queue; release what it carries.
	for {
		work, received := chan.try_recv(app.run.work)
		if !received { break }
		work_destroy(&app, work)
	}
}

// A large paste shows as a marker in the prompt, and the line that is sent and kept in the
// history carries the whole text.
@(test)
test_submit_sends_the_text_a_paste_marker_stands_for :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)
	set_running(&app, false)

	pasted := "one\ntwo\nthree\nfour\nfive\nsix"
	paste_insert(&app, pasted)
	testing.expect(t, strings.has_prefix(widgets.input_text(&app.input), "[Pasted text #1"))
	testing.expect(t, widgets.input_insert(&app.input, " done") == nil)
	submit(&app)

	entries, err := journal.queue_list(app.queue_journal, app.queue_session, app.run.alloc)
	if !testing.expect(t, err == nil && len(entries) == 1) { return }
	defer journal.queue_entries_destroy(entries, app.run.alloc)
	testing.expect_value(t, entries[0].text, "one\ntwo\nthree\nfour\nfive\nsix done")
	testing.expect_value(t, widgets.input_text(&app.input), "")
	recalled, found := widgets.history_previous(&app.history, "")
	testing.expect(t, found)
	testing.expect_value(t, recalled, "one\ntwo\nthree\nfour\nfive\nsix done")
}

// Navigation skips a disabled catalog entry and lands on the next enabled row,
// so a disabled model can never be selected.
@(test)
test_model_menu_navigation_skips_a_disabled_model :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	choices := make([dynamic]Choice, 0, 3, app.run.alloc)
	append(
		&choices,
		Choice {
			label = strings.clone("a", app.run.alloc),
			detail = strings.clone("p", app.run.alloc),
			action = Model_Choice{provider_id = strings.clone("p", app.run.alloc), model_id = strings.clone("a", app.run.alloc)},
		},
	)
	append(
		&choices,
		Choice {
			label = strings.clone("b", app.run.alloc),
			detail = strings.clone("p", app.run.alloc),
			disabled = true,
			action = Model_Choice{provider_id = strings.clone("p", app.run.alloc), model_id = strings.clone("b", app.run.alloc)},
		},
	)
	append(
		&choices,
		Choice {
			label = strings.clone("c", app.run.alloc),
			detail = strings.clone("p", app.run.alloc),
			action = Model_Choice{provider_id = strings.clone("p", app.run.alloc), model_id = strings.clone("c", app.run.alloc)},
		},
	)
	if !testing.expect(t, menu_begin(&app, .Model, "models", choices, false)) { return }
	testing.expect_value(t, app.menu.list.selected, 0)

	handle_menu_key(&app, {code = .Down})
	testing.expect_value(t, app.menu.list.selected, 2)
	handle_menu_key(&app, {code = .Up})
	testing.expect_value(t, app.menu.list.selected, 0)
}

// Shift with an arrow reaches a disabled model, so Ctrl+D can stage it back on,
// and Enter on it does nothing: a disabled model is never submitted.
@(test)
test_model_menu_shift_arrow_reaches_a_disabled_model :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	choices := make([dynamic]Choice, 0, 3, app.run.alloc)
	append(
		&choices,
		Choice {
			label = strings.clone("a", app.run.alloc),
			action = Model_Choice{provider_id = strings.clone("p", app.run.alloc), model_id = strings.clone("a", app.run.alloc)},
		},
	)
	append(
		&choices,
		Choice {
			label = strings.clone("b", app.run.alloc),
			disabled = true,
			action = Model_Choice{provider_id = strings.clone("p", app.run.alloc), model_id = strings.clone("b", app.run.alloc)},
		},
	)
	append(
		&choices,
		Choice {
			label = strings.clone("c", app.run.alloc),
			action = Model_Choice{provider_id = strings.clone("p", app.run.alloc), model_id = strings.clone("c", app.run.alloc)},
		},
	)
	if !testing.expect(t, menu_begin(&app, .Model, "models", choices, false)) { return }

	handle_menu_key(&app, {code = .Down})
	testing.expect_value(t, app.menu.list.selected, 2)
	handle_menu_key(&app, {code = .Up, modifiers = {.Shift}})
	testing.expect_value(t, app.menu.list.selected, 1)
	handle_menu_key(&app, {code = .Enter})
	testing.expect(t, app.menu_open)
	handle_menu_key(&app, {code = .Character, character = 'd', modifiers = {.Control}})
	testing.expect(t, len(app.menu.staged) == 1 && !app.menu.staged[0].disabled)
}

// Ctrl+D stages a disabled flag in memory only, and Ctrl+S writes it to the
// configuration, other fields intact, then clears the staged list. Esc before
// Ctrl+S writes nothing.
@(test)
test_model_menu_ctrl_d_then_ctrl_s_writes_the_disabled_flag :: proc(t: ^testing.T) {
	app: App
	command_app(t, &app)
	defer command_app_end(&app)

	directory, directory_err := os.make_directory_temp("", "nabla-model-menu-*", context.allocator)
	if !testing.expect(t, directory_err == nil) { return }
	defer os.remove_all(directory)
	defer delete(directory, context.allocator)
	path, _ := filepath.join([]string{directory, "config.lua"}, context.temp_allocator)
	source := `return {
	providers = {
		acme = {
			base_url = "https://api.acme.test",
			api = "openai_chat_completions",
			api_key = "ACME_KEY",
			models = {
				chat = { context_window = 100000 },
				mini = { thinking = false },
			},
		},
	},
}
`
	if !testing.expect(t, os.write_entire_file(path, transmute([]u8)source) == nil) { return }
	app.config_path = strings.clone(path, context.allocator)
	defer delete(app.config_path, context.allocator)

	// The first publication comes from the same refresh a Ctrl+S takes, so the
	// fixture needs no hand-built catalog.
	defer agent.catalog_destroy(&app.setup.catalog)
	defer catalog_run_destroy(&app)
	catalog_refresh_with(&app, command_test_provider_unreachable, command_test_models_dev_unreachable)
	app.setup.configured = make([dynamic]string, 0, 1, app.run.alloc)
	append(&app.setup.configured, strings.clone("acme", app.run.alloc))
	defer {
		for id in app.setup.configured { delete(id, app.run.alloc) }
		delete(app.setup.configured)
	}

	menu_open_model(&app)
	if !testing.expect(t, app.menu_open) { return }
	testing.expect_value(t, len(app.menu.choices), 2)
	testing.expect_value(t, app.menu.list.selected, 0)

	handle_menu_key(&app, {code = .Down})
	handle_menu_key(&app, {code = .Character, character = 'd', modifiers = {.Control}})
	testing.expect_value(t, len(app.menu.staged), 1)
	// Staging alone writes nothing.
	before, before_err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, before_err == nil) { return }
	testing.expect(t, string(before) == source, "staging must not write the configuration")

	handle_menu_key(&app, {code = .Character, character = 's', modifiers = {.Control}})
	testing.expect_value(t, len(app.menu.staged), 0)
	testing.expect(t, app.menu_open)

	after, after_err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, after_err == nil) { return }
	testing.expect(t, strings.contains(string(after), "disabled = true"), "the save should state disabled = true")
	testing.expect(t, strings.contains(string(after), "context_window = 100000"), "other fields stay intact")

	// The save asks the refresh for a new catalog, and the refresh reloads
	// the file first, so the disabled flag reaches the menu row without a
	// restart. The close and reopen proves the same on a fresh list.
	catalog_refresh_with(&app, command_test_provider_unreachable, command_test_models_dev_unreachable)
	menu_rebuild_open_model(&app)
	testing.expect(t, string(after) != "")
	testing.expect_value(t, len(app.menu.choices), 2)
	disabled_rows := 0
	for choice in app.menu.choices {
		if choice.disabled { disabled_rows += 1 }
	}
	testing.expect_value(t, disabled_rows, 1)
	handle_menu_key(&app, {code = .Escape})
	testing.expect(t, !app.menu_open)
	menu_open_model(&app)
	disabled_rows = 0
	for choice in app.menu.choices {
		if choice.disabled { disabled_rows += 1 }
	}
	testing.expect_value(t, disabled_rows, 1)

	// Esc discards a staged change before any save.
	handle_menu_key(&app, {code = .Character, character = 'd', modifiers = {.Control}})
	testing.expect_value(t, len(app.menu.staged), 1)
	before_discard, discard_err := os.read_entire_file(path, context.allocator)
	if !testing.expect(t, discard_err == nil) { return }
	handle_menu_key(&app, {code = .Escape})
	testing.expect(t, !app.menu_open)
	testing.expect_value(t, len(app.menu.staged), 0)
	after_discard, after_discard_err := os.read_entire_file(path, context.allocator)
	if !testing.expect(t, after_discard_err == nil) { return }
	testing.expect(t, string(after_discard) == string(before_discard), "esc before save writes nothing")
	delete(before_discard, context.allocator)
	delete(after_discard, context.allocator)
}

// The refresh must fail on both stages so the menu keeps the catalog it published.
command_test_provider_unreachable :: proc(_: rawptr, _: string, _: string, _: mem.Allocator) -> ([]u8, bool) { return nil, false }

command_test_models_dev_unreachable :: proc(_: ^bool, _: mem.Allocator) -> ([]u8, bool) { return nil, false }
