#+test
#+private file
package session

import "core:os"
import "core:strings"
import "core:testing"

import "nabla:db"
import "nabla:db/sqlite"

@(test)
test_open_creates_a_private_store :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	directory_info, directory_err := os.stat(directory, context.temp_allocator)
	if directory_err != nil { testing.fail_now(t, "the session directory was not created") }
	testing.expect(t, permissions_are_private(directory_info.mode), "the session directory should be owner-only")

	database := strings.concatenate({directory, "/", DATABASE_NAME}, context.temp_allocator)
	database_info, database_err := os.stat(database, context.temp_allocator)
	if database_err != nil { testing.fail_now(t, "the database was not created") }
	testing.expect(t, permissions_are_private(database_info.mode), "the database should be owner-only")
}

@(test)
test_open_is_idempotent_across_stores :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	store_close(&store)
	defer {
		os.remove_all(directory)
		delete(directory, context.allocator)
	}

	reopened: Store
	_expect_ok(t, store_open(&reopened, directory))
	store_close(&reopened)
}

@(test)
test_create_and_load_round_trip :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	created, create_err := session_create(&store, {workspace = "/tmp/project", title = "first", provider = "openai", model = "gpt-4"}, 1_000)
	_expect_ok(t, create_err)
	defer session_destroy(&created)

	testing.expect_value(t, len(created.id), SESSION_ID_LENGTH)
	testing.expect(t, session_id_valid(created.id), "a created id should validate")
	testing.expect_value(t, created.workspace, "/tmp/project")
	testing.expect_value(t, created.title, "first")
	testing.expect_value(t, created.provider, "openai")
	testing.expect_value(t, created.model, "gpt-4")
	testing.expect_value(t, created.created_at_ms, i64(1_000))
	testing.expect_value(t, created.updated_at_ms, i64(1_000))
	if _, archived := created.archived_at_ms.?; archived { testing.fail_now(t, "a new session is not archived") }

	loaded, load_err := session_load(&store, created.id)
	_expect_ok(t, load_err)
	defer session_destroy(&loaded)
	testing.expect_value(t, loaded.id, created.id)
	testing.expect_value(t, loaded.workspace, "/tmp/project")
	testing.expect_value(t, loaded.title, "first")
	testing.expect_value(t, loaded.provider, "openai")
	testing.expect_value(t, loaded.model, "gpt-4")
	testing.expect_value(t, loaded.created_at_ms, i64(1_000))
}

@(test)
test_two_sessions_get_different_ids :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	first, first_err := session_create(&store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, first_err)
	defer session_destroy(&first)
	second, second_err := session_create(&store, {workspace = "/tmp/project"}, 1_001)
	_expect_ok(t, second_err)
	defer session_destroy(&second)

	testing.expect(t, first.id != second.id, "two sessions should not share an id")
}

@(test)
test_create_rejects_an_empty_workspace :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session, err := session_create(&store, {}, 1_000)
	_expect_error(t, err, .Invalid_Argument)
	session_destroy(&session)
}

@(test)
test_load_reports_a_missing_session :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	_, err := session_load(&store, Session_Id("0123456789abcdef0123456789abcdef"))
	_expect_error(t, err, .Not_Found)
}

@(test)
test_list_orders_by_activity_and_pages :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	ids: [4]Session_Id
	for &id, i in ids {
		session, err := session_create(&store, {workspace = "/tmp/project"}, i64(1_000 + i * 1_000))
		_expect_ok(t, err)
		// The array owns its own copy, because the session it came from is about
		// to be destroyed.
		id = Session_Id(strings.clone(string(session.id), context.allocator))
		session_destroy(&session)
	}
	defer for id in ids { delete(string(id), context.allocator) }

	// One session elsewhere must not appear in a workspace listing.
	other, other_err := session_create(&store, {workspace = "/tmp/other"}, 10_000)
	_expect_ok(t, other_err)
	defer session_destroy(&other)

	all, all_err := session_list(&store, {})
	_expect_ok(t, all_err)
	defer sessions_destroy(all)
	if !testing.expect_value(t, len(all), 5) { return }
	testing.expect_value(t, all[0].id, other.id)
	testing.expect_value(t, all[1].id, ids[3])
	testing.expect_value(t, all[4].id, ids[0])

	project, project_err := session_list(&store, {workspace = "/tmp/project"})
	_expect_ok(t, project_err)
	defer sessions_destroy(project)
	testing.expect_value(t, len(project), 4)

	first_page, first_err := session_list(&store, {workspace = "/tmp/project", limit = 2})
	_expect_ok(t, first_err)
	defer sessions_destroy(first_page)
	if !testing.expect_value(t, len(first_page), 2) { return }
	testing.expect_value(t, first_page[0].id, ids[3])
	testing.expect_value(t, first_page[1].id, ids[2])

	cursor := Session_Cursor {
		updated_at_ms = first_page[len(first_page) - 1].updated_at_ms,
		id            = first_page[len(first_page) - 1].id,
	}
	second_page, second_err := session_list(&store, {workspace = "/tmp/project", limit = 2, after = cursor})
	_expect_ok(t, second_err)
	defer sessions_destroy(second_page)
	if !testing.expect_value(t, len(second_page), 2) { return }
	testing.expect_value(t, second_page[0].id, ids[1])
	testing.expect_value(t, second_page[1].id, ids[0])
}

// Creating a session writes its row and nothing else, so a listing filtered to
// used sessions has to read what the session recorded. The abandoned session
// here is newer than the used one, which is the order a bare resume sees.
@(test)
test_list_can_skip_sessions_that_were_never_used :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	used, used_err := session_create(&store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, used_err)
	defer session_destroy(&used)
	_expect_ok(t, session_claim(&store, used.id))
	_, turn_err := turn_begin(&store, used.id, "hello", .Prompt, 2_000)
	_expect_ok(t, turn_err)
	_expect_ok(t, session_release(&store))

	abandoned, abandoned_err := session_create(&store, {workspace = "/tmp/project"}, 3_000)
	_expect_ok(t, abandoned_err)
	defer session_destroy(&abandoned)

	every, every_err := session_list(&store, {workspace = "/tmp/project"})
	_expect_ok(t, every_err)
	defer sessions_destroy(every)
	if !testing.expect_value(t, len(every), 2) { return }
	testing.expect_value(t, every[0].id, abandoned.id)

	// A limit of one is what the bare resume asks for, and the filter has to be
	// applied before the limit for it to matter.
	used_only, used_only_err := session_list(&store, {workspace = "/tmp/project", limit = 1, used_only = true})
	_expect_ok(t, used_only_err)
	defer sessions_destroy(used_only)
	if !testing.expect_value(t, len(used_only), 1) { return }
	testing.expect_value(t, used_only[0].id, used.id)
}

// A header is not a session until it is recorded. The harness holds a new session
// in memory and records it from the first prompt, so this is the step that decides
// whether a launch leaves anything behind.
@(test)
test_record_is_what_puts_a_session_in_the_store :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	pending := Session {
		id            = session_id_create(context.allocator),
		created_at_ms = 1_000,
		updated_at_ms = 1_000,
		workspace     = strings.clone("/tmp/project", context.allocator),
	}
	defer session_destroy(&pending)

	// A header that was never recorded has no row to load.
	_, missing_err := session_load(&store, pending.id)
	_expect_error(t, missing_err, .Not_Found)

	_expect_ok(t, session_record(&store, pending))
	recorded, recorded_err := session_load(&store, pending.id)
	_expect_ok(t, recorded_err)
	defer session_destroy(&recorded)
	testing.expect_value(t, recorded.created_at_ms, i64(1_000))
	testing.expect_value(t, recorded.workspace, "/tmp/project")

	// Recording again describes the same session, so the row that exists wins and
	// the later header changes nothing.
	later := pending
	later.created_at_ms = 5_000
	later.updated_at_ms = 5_000
	later.workspace = "/tmp/elsewhere"
	later.title = "later"
	_expect_ok(t, session_record(&store, later))

	again, again_err := session_load(&store, pending.id)
	_expect_ok(t, again_err)
	defer session_destroy(&again)
	testing.expect_value(t, again.created_at_ms, i64(1_000))
	testing.expect_value(t, again.workspace, "/tmp/project")
	testing.expect_value(t, again.title, "")

	all, all_err := session_list(&store, {workspace = "/tmp/project"})
	_expect_ok(t, all_err)
	defer sessions_destroy(all)
	testing.expect_value(t, len(all), 1)
}

@(test)
test_claim_is_exclusive :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session, create_err := session_create(&store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, create_err)
	defer session_destroy(&session)

	_expect_ok(t, session_claim(&store, session.id))
	// A second claim from the same store is refused before it reaches the file.
	_expect_error(t, session_claim(&store, session.id), .Invalid_State)
	claimed, held := session_claimed(&store)
	testing.expect(t, held, "the session should be reported as claimed")
	testing.expect_value(t, claimed, session.id)

	_expect_ok(t, session_release(&store))
	_, still_held := session_claimed(&store)
	testing.expect(t, !still_held, "the claim should be gone after release")
	_expect_ok(t, session_claim(&store, session.id))
	_expect_ok(t, session_release(&store))
}

@(test)
test_claim_refuses_a_missing_session :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	_expect_error(t, session_claim(&store, Session_Id("0123456789abcdef0123456789abcdef")), .Not_Found)
}

@(test)
test_a_second_store_cannot_claim_the_same_session :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session, create_err := session_create(&store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, create_err)
	defer session_destroy(&session)

	_expect_ok(t, session_claim(&store, session.id))
	defer session_release(&store)

	second: Store
	_expect_ok(t, store_open(&second, directory))
	defer store_close(&second)

	_expect_error(t, session_claim(&second, session.id), .Claimed)

	// Releasing the first claim lets the second store take it.
	_expect_ok(t, session_release(&store))
	second_claim_err := session_claim(&second, session.id)
	_expect_ok(t, second_claim_err)
	session_release(&second)
}

// The store assumes write-ahead logging: readers do not block the writer, and a
// checkpoint does not block readers. An open store is checked against the mode
// SQLite actually reported, so this pins the invariant the open path enforces.
@(test)
test_an_open_store_runs_in_write_ahead_logging :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	rows: db.Rows
	_expect_db_ok(t, db.query(&store.conn, &rows, "PRAGMA journal_mode"))
	defer db.rows_close(&rows)
	values, has_row, next_err := db.rows_next(&rows)
	_expect_db_ok(t, next_err)
	if !testing.expect(t, has_row, "the journal mode should be reported") { return }
	mode, convert_err := db.as_string(values[0])
	_expect_db_ok(t, convert_err)
	testing.expect(t, strings.equal_fold(mode, "wal"), "the store must run in write-ahead logging mode")
}

// The kind a caller sees is what tells it whether to retry, to fix its
// arguments, or to report a database that could not work. That mapping is a
// contract, so it is pinned rather than left to the call sites.
@(test)
test_storage_failures_keep_the_kind_a_caller_can_act_on :: proc(t: ^testing.T) {
	cases := []struct {
		backend: db.Error_Kind,
		kind:    Error_Kind,
	} {
		{.Constraint, .Constraint},
		{.Busy, .Contended},
		{.Busy_Snapshot, .Stale_Snapshot},
		{.Backend, .Storage},
		{.Read_Only, .Storage},
		{.Out_Of_Memory, .Storage},
		{.Interrupted, .Storage},
	}
	for c in cases {
		err := storage_error("write", db.error_make(c.backend, 7, "backend detail"))
		if !testing.expectf(t, error_kind(err) == c.kind, "%v should map to %v, got %v", c.backend, c.kind, error_kind(err)) { continue }
		// The backend's own words travel with the classification.
		local := err
		testing.expect(t, strings.contains(error_detail(&local), "backend detail"), "the backend detail must survive the mapping")
	}
}

// A store whose failed write could not be rolled back must refuse later writes
// rather than writing into a transaction nothing will commit. The trigger is a
// rare I/O path, so the policy is what is exercised by setting the state the
// failed rollback would have set.
@(test)
test_a_broken_transaction_state_refuses_writes_but_not_reads :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session, create_err := session_create(&store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, create_err)
	defer session_destroy(&session)
	_expect_ok(t, session_claim(&store, session.id))

	store.broken = true

	// A claiming mutation and a claim-free write are both refused, because both
	// depend on the connection's transaction state.
	_expect_error(t, session_set_title(&store, session.id, "named"), .Invalid_State)
	_expect_error(t, selection_save(&store, {provider = "p", model = "m"}), .Invalid_State)

	// Reads do not depend on transaction state, so they keep working: the session
	// is still inspectable after a failed write.
	loaded, load_err := session_load(&store, session.id)
	_expect_ok(t, load_err)
	defer session_destroy(&loaded)
	testing.expect_value(t, loaded.id, session.id)
}

// A switch claims the candidate while the running session is still held, so both
// are locked until the switch commits or is restored. That is what keeps a refused
// switch from handing the running session to another process.
@(test)
test_a_switch_holds_both_sessions_until_it_commits :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	running, running_err := session_create(&store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, running_err)
	defer session_destroy(&running)
	target, target_err := session_create(&store, {workspace = "/tmp/project"}, 2_000)
	_expect_ok(t, target_err)
	defer session_destroy(&target)

	_expect_ok(t, session_claim(&store, running.id))

	second: Store
	_expect_ok(t, store_open(&second, directory))
	defer store_close(&second)

	displaced, candidate_err := session_claim_candidate(&store, target.id)
	_expect_ok(t, candidate_err)

	// Both are locked, and the store now names the candidate.
	claimed, held := session_claimed(&store)
	testing.expect(t, held, "the candidate should be the store's claim")
	testing.expect_value(t, claimed, target.id)
	_expect_error(t, session_claim(&second, running.id), .Claimed)
	_expect_error(t, session_claim(&second, target.id), .Claimed)

	// Committing releases the running session and keeps the candidate.
	_expect_ok(t, claim_release(&displaced))
	_expect_ok(t, session_claim(&second, running.id))
	_expect_ok(t, session_release(&second))
	_expect_error(t, session_claim(&second, target.id), .Claimed)
}

// A candidate another process holds is refused without disturbing the running
// session, and a switch that is abandoned puts the running claim back.
@(test)
test_a_refused_or_restored_switch_keeps_the_running_claim :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	running, running_err := session_create(&store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, running_err)
	defer session_destroy(&running)
	target, target_err := session_create(&store, {workspace = "/tmp/project"}, 2_000)
	_expect_ok(t, target_err)
	defer session_destroy(&target)

	_expect_ok(t, session_claim(&store, running.id))

	second: Store
	_expect_ok(t, store_open(&second, directory))
	defer store_close(&second)
	_expect_ok(t, session_claim(&second, target.id))

	// The refusal leaves the store claiming exactly what it claimed before, and the
	// running session is still writable.
	_, candidate_err := session_claim_candidate(&store, target.id)
	_expect_error(t, candidate_err, .Claimed)
	claimed, held := session_claimed(&store)
	testing.expect(t, held, "the running session must still be claimed")
	testing.expect_value(t, claimed, running.id)
	_expect_ok(t, session_set_title(&store, running.id, "still mine"))

	// A candidate that was claimed and then abandoned is released, and the running
	// claim is back in the store.
	_expect_ok(t, session_release(&second))
	displaced, claim_err := session_claim_candidate(&store, target.id)
	_expect_ok(t, claim_err)
	_expect_ok(t, session_claim_restore(&store, displaced))
	claimed, held = session_claimed(&store)
	testing.expect(t, held, "restoring must put the running claim back")
	testing.expect_value(t, claimed, running.id)
	_expect_ok(t, session_set_title(&store, running.id, "still mine"))
	_expect_error(t, session_set_title(&store, target.id, "not mine"), .Invalid_State)
}

@(test)
test_archive_hides_and_unarchive_restores :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session, create_err := session_create(&store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, create_err)
	defer session_destroy(&session)
	_expect_ok(t, session_claim(&store, session.id))
	defer session_release(&store)

	_expect_ok(t, session_archive(&store, session.id, 2_000))

	visible, visible_err := session_list(&store, {})
	_expect_ok(t, visible_err)
	testing.expect_value(t, len(visible), 0)
	sessions_destroy(visible)

	everything, everything_err := session_list(&store, {include_archived = true})
	_expect_ok(t, everything_err)
	if !testing.expect_value(t, len(everything), 1) { return }
	if archived_at, archived := everything[0].archived_at_ms.?; archived {
		testing.expect_value(t, archived_at, i64(2_000))
	} else {
		testing.fail_now(t, "the archived session should carry its archive time")
	}
	sessions_destroy(everything)

	_expect_ok(t, session_unarchive(&store, session.id))
	restored, restored_err := session_list(&store, {})
	_expect_ok(t, restored_err)
	testing.expect_value(t, len(restored), 1)
	sessions_destroy(restored)
}

@(test)
test_mutations_require_the_claim :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session, create_err := session_create(&store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, create_err)
	defer session_destroy(&session)

	_expect_error(t, session_set_title(&store, session.id, "named"), .Invalid_State)
	_expect_error(t, session_archive(&store, session.id, 2_000), .Invalid_State)
	_expect_error(t, session_delete(&store, session.id), .Invalid_State)

	_expect_ok(t, session_claim(&store, session.id))
	// A different session cannot be mutated through this claim.
	other, other_err := session_create(&store, {workspace = "/tmp/project"}, 1_500)
	_expect_ok(t, other_err)
	defer session_destroy(&other)
	_expect_error(t, session_set_title(&store, other.id, "named"), .Invalid_State)
	_expect_ok(t, session_release(&store))
}

@(test)
test_a_title_is_derived_once :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session := _open_claimed_session(t, &store)
	defer session_destroy(&session)

	_expect_ok(t, session_set_title_if_untitled(&store, session.id, "first prompt"))
	_expect_ok(t, session_set_title_if_untitled(&store, session.id, "second prompt"))

	loaded, load_err := session_load(&store, session.id)
	_expect_ok(t, load_err)
	defer session_destroy(&loaded)
	testing.expect_value(t, loaded.title, "first prompt")
}

@(test)
test_set_title_and_model_then_touch :: proc(t: ^testing.T) {store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session, create_err := session_create(&store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, create_err)
	defer session_destroy(&session)
	_expect_ok(t, session_claim(&store, session.id))
	defer session_release(&store)

	_expect_ok(t, session_set_title(&store, session.id, "explain the parser"))
	_expect_ok(t, session_set_model(&store, session.id, "anthropic", "claude"))
	_expect_ok(t, session_touch(&store, session.id, 5_000))

	loaded, load_err := session_load(&store, session.id)
	_expect_ok(t, load_err)
	defer session_destroy(&loaded)
	testing.expect_value(t, loaded.title, "explain the parser")
	testing.expect_value(t, loaded.provider, "anthropic")
	testing.expect_value(t, loaded.model, "claude")
	testing.expect_value(t, loaded.updated_at_ms, i64(5_000))
}

@(test)
test_delete_removes_the_session_and_releases_the_claim :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	session, create_err := session_create(&store, {workspace = "/tmp/project"}, 1_000)
	_expect_ok(t, create_err)
	defer session_destroy(&session)
	_expect_ok(t, session_claim(&store, session.id))

	_expect_ok(t, session_delete(&store, session.id))
	_, held := session_claimed(&store)
	testing.expect(t, !held, "deleting the claimed session should release the claim")

	_, load_err := session_load(&store, session.id)
	_expect_error(t, load_err, .Not_Found)

	remaining, list_err := session_list(&store, {})
	_expect_ok(t, list_err)
	testing.expect_value(t, len(remaining), 0)
	sessions_destroy(remaining)
}

@(test)
test_refuses_a_foreign_database :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer {
		os.remove_all(directory)
		delete(directory, context.allocator)
	}

	database := strings.concatenate({directory, "/", DATABASE_NAME}, context.temp_allocator)
	conn: db.Conn
	_expect_db_ok(t, sqlite.open(&conn, {path = database}))
	_expect_db_ok(t, db.exec(&conn, "CREATE TABLE someone_elses (a TEXT)"))
	_expect_db_ok(t, db.close(&conn))

	store: Store
	err := store_open(&store, directory)
	_expect_error(t, err, .Schema_Unknown)
	store_close(&store)
}

@(test)
test_refuses_a_newer_schema :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer {
		os.remove_all(directory)
		delete(directory, context.allocator)
	}

	database := strings.concatenate({directory, "/", DATABASE_NAME}, context.temp_allocator)
	conn: db.Conn
	_expect_db_ok(t, sqlite.open(&conn, {path = database}))
	_expect_db_ok(t, db.exec(&conn, "PRAGMA user_version = 99"))
	_expect_db_ok(t, db.close(&conn))

	store: Store
	err := store_open(&store, directory)
	_expect_error(t, err, .Schema_Too_New)
	store_close(&store)
}
