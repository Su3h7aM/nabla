#+test
#+private file
package main

import "core:os"
import "core:strings"
import "core:sync/chan"
import "core:testing"

import "nabla:agent/journal"
import "nabla:db"
import "nabla:tui/widgets"

queue_test_open :: proc(t: ^testing.T, app: ^App) -> (^journal.Journal, string) {
	directory, err := os.make_directory_temp("", "nabla-queue-test-*", context.allocator)
	if err != nil { testing.fail_now(t, "cannot create directory") }
	owner, open_error := journal.open(directory, directory, journal.run_id_create(), .Read_Write)
	if open_error != nil { testing.fail_now(t, "cannot open owner") }
	session, create_error := journal.create_session(owner, {workspace = directory, role = .Main})
	if create_error != nil { testing.fail_now(t, "cannot create session") }
	if _, commit_error := journal.commit(owner); commit_error != nil { testing.fail_now(t, "cannot commit session") }
	app.queue_journal, open_error = journal.open(directory, directory, journal.run_id_create(), .Read_Write)
	if open_error != nil { testing.fail_now(t, "cannot open queue") }
	app.queue_session = session
	app.run.alloc = context.allocator
	app.setup.alloc = context.allocator
	widgets.input_init(&app.input, context.allocator)
	widgets.history_init(&app.history, context.allocator)
	app.run.work, _ = chan.create_buffered(Work_Chan, WORK_CAPACITY, context.allocator)
	return owner, directory
}

queue_test_close :: proc(app: ^App, owner: ^journal.Journal, directory: string) {
	for &entry in app.run.snap.entries { entry_destroy(&entry) }
	delete(app.run.snap.entries)
	widgets.input_destroy(&app.input)
	widgets.history_destroy(&app.history)
	chan.destroy(&app.run.work)
	_ = journal.close(app.queue_journal)
	_ = journal.close(owner)
	_ = os.remove_all(directory)
	delete(directory)
}

@(test)
test_queue_submit_and_owner_delivery :: proc(t: ^testing.T) {
	app: App
	owner, directory := queue_test_open(t, &app)
	defer queue_test_close(&app, owner, directory)
	texts := [?]string{"during a turn", "idle"}
	for text in texts {
		if !testing.expect(t, widgets.input_insert(&app.input, text) == nil) { return }
		submit(&app)
		entries, err := journal.queue_list(app.queue_journal, app.queue_session, context.allocator)
		if !testing.expect(t, err == nil && len(entries) == 1) { return }
		id := entries[0].id
		testing.expect_value(t, entries[0].text, text)
		journal.queue_entries_destroy(entries, context.allocator)
		records, _, read_error := journal.read_records(owner, {session = app.queue_session, kinds = {.User_Input}}, 0, 0, context.allocator)
		if read_error != nil { testing.fail_now(t, "cannot read records") }
		before := len(records)
		journal.records_destroy(records, context.allocator)
		delivery: journal.Queue_Delivery
		journal.queue_deliver(owner, app.queue_session, id, nil, &delivery)
		if _, err := journal.commit(owner); err != nil { testing.fail_now(t, "cannot deliver") }
		testing.expect(t, delivery.completed && delivery.seq != 0)
		records, _, read_error = journal.read_records(owner, {session = app.queue_session, kinds = {.User_Input}}, 0, 0, context.allocator)
		if read_error != nil { testing.fail_now(t, "cannot read delivered records") }
		testing.expect_value(t, len(records), before + 1)
		journal.records_destroy(records, context.allocator)
	}
}

@(test)
test_busy_queue_keeps_prompt_and_history_survives_reopen :: proc(t: ^testing.T) {
	app: App
	owner, directory := queue_test_open(t, &app)
	defer queue_test_close(&app, owner, directory)
	if err := db.exec(&app.queue_journal.connection, "PRAGMA busy_timeout=0"); err != nil { testing.fail_now(t, "cannot set timeout") }
	if err := db.exec(&owner.connection, "BEGIN IMMEDIATE"); err != nil { testing.fail_now(t, "cannot lock database") }
	if !testing.expect(t, widgets.input_insert(&app.input, "retained") == nil) { return }
	submit(&app)
	testing.expect_value(t, widgets.input_text(&app.input), "retained")
	testing.expect_value(t, len(app.history.entries), 0)
	_, received := chan.try_recv(app.run.work)
	testing.expect(t, !received)
	if testing.expect(t, len(app.run.snap.entries) > 0) {
		warning := app.run.snap.entries[len(app.run.snap.entries) - 1]
		testing.expect_value(t, warning.kind, Entry_Kind.Warning)
		testing.expect(t, strings.contains(string(warning.text[:]), "locked"))
	}
	if err := db.rollback(&owner.connection); err != nil { testing.fail_now(t, "cannot unlock database") }
	before, list_error := journal.queue_list(app.queue_journal, app.queue_session, context.allocator)
	if !testing.expect(t, list_error == nil) { return }
	testing.expect_value(t, len(before), 0)
	journal.queue_entries_destroy(before, context.allocator)
	submit(&app)
	testing.expect_value(t, widgets.input_text(&app.input), "")
	work, ensure_received := chan.try_recv(app.run.work)
	testing.expect(t, ensure_received)
	testing.expect_value(t, work.session, app.queue_session)
	entries, err := journal.queue_list(app.queue_journal, app.queue_session, context.allocator)
	if !testing.expect(t, err == nil && len(entries) == 1) { return }
	defer journal.queue_entries_destroy(entries, context.allocator)
	testing.expect_value(t, entries[0].text, "retained")
	if err := journal.close(app.queue_journal); err != nil { testing.fail_now(t, "cannot close queue") }
	store, open_error := journal.open(directory, directory, journal.run_id_create(), .Read_Write)
	if open_error != nil { testing.fail_now(t, "cannot reopen queue") }
	app.queue_journal = store
	widgets.history_destroy(&app.history)
	widgets.history_init(&app.history, context.allocator)
	app_history_load(&app)
	text, found := widgets.history_previous(&app.history, "")
	testing.expect(t, found)
	testing.expect_value(t, text, "retained")
}
