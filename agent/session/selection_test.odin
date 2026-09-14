#+test
package session

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "nabla:db"
import "nabla:db/sqlite"

// The selection is the one row of state that is not conversation history: a
// launch reads it to restore the model the user last chose, and nothing about it
// is owned by a session.

@(test)
test_a_store_with_no_selection_reports_none :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	selection, found, err := selection_load(&store)
	_expect_ok(t, err)
	testing.expect(t, !found, "a fresh database has no selection")
	_ = selection
}

@(test)
test_a_selection_round_trips_and_is_replaced :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	_expect_ok(t, selection_save(&store, {provider = "proxy", model = "openai/gpt-5.6-luna", effort = "low"}))
	stored, found, err := selection_load(&store)
	_expect_ok(t, err)
	if !testing.expect(t, found) { return }
	testing.expect_value(t, stored.provider, "proxy")
	testing.expect_value(t, stored.model, "openai/gpt-5.6-luna")
	testing.expect_value(t, stored.effort, "low")
	selection_destroy(&stored)

	// An empty effort is the provider default, and a second save replaces the
	// first rather than adding to it.
	_expect_ok(t, selection_save(&store, {provider = "other", model = "m", effort = ""}))
	replaced, replaced_found, replaced_err := selection_load(&store)
	_expect_ok(t, replaced_err)
	if !testing.expect(t, replaced_found) { return }
	testing.expect_value(t, replaced.provider, "other")
	testing.expect_value(t, replaced.effort, "")
	selection_destroy(&replaced)

	count, count_err := scalar_i64(&store, "SELECT COUNT(*) FROM selection", nil)
	_expect_ok(t, count_err)
	testing.expect_value(t, count, i64(1))
}

@(test)
test_a_selection_needs_a_provider_and_a_model :: proc(t: ^testing.T) {
	store: Store
	directory := _open_store(t, &store)
	defer _close_store(&store, directory)

	_expect_error(t, selection_save(&store, {model = "m"}), .Invalid_Argument)
	_expect_error(t, selection_save(&store, {provider = "p"}), .Invalid_Argument)

	_, found, err := selection_load(&store)
	_expect_ok(t, err)
	testing.expect(t, !found, "a refused save must not store anything")
}

@(test)
test_a_selection_needs_an_open_store :: proc(t: ^testing.T) {
	store: Store
	_, _, load_err := selection_load(&store)
	_expect_error(t, load_err, .Invalid_State)
	_expect_error(t, selection_save(&store, {provider = "p", model = "m"}), .Invalid_State)
}

// The selection arrived in schema 2, so a database written by the previous
// version migrates in place and keeps the history it holds.
@(test)
test_a_version_one_database_gains_a_selection_and_keeps_its_history :: proc(t: ^testing.T) {
	test_version_one_migrates_to_current(t)

	// A version-two database -- one that predates the response entry -- migrates
	// in place too: the old rows stay readable and a response entry writes.
	test_version_two_migrates_to_current(t)
}

@(private)
test_version_one_migrates_to_current :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer {
		os.remove_all(directory)
		delete(directory, context.allocator)
	}

	// Build a version-one database by hand: what the previous release wrote.
	{
		conn: db.Conn
		database_path, join_err := filepath.join({directory, DATABASE_NAME}, context.temp_allocator)
		testing.expect(t, join_err == nil)
		if open_err := sqlite.open(&conn, {path = database_path, foreign_keys = true}); open_err != nil {
			local := open_err
			testing.fail_now(t, strings.concatenate({"could not open a version-one database: ", db.error_message(&local)}, context.temp_allocator))
		}
		for statement in MIGRATION_1 {
			_expect_db_ok(t, db.exec(&conn, statement))
		}
		_expect_db_ok(t, db.exec(&conn, "PRAGMA user_version = 1"))
		_expect_db_ok(
			t,
			db.exec(
				&conn,
				"INSERT INTO sessions (id, created_at_ms, updated_at_ms, workspace, title, provider, model, archived_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
				{
					db.Value("0123456789abcdef0123456789abcdef"),
					db.Value(i64(1_000)),
					db.Value(i64(1_000)),
					db.Value("/tmp/project"),
					db.Value("older"),
					db.Value(""),
					db.Value(""),
					db.Value(nil),
				},
			),
		)
		db.close(&conn)
	}

	store: Store
	_expect_ok(t, store_open(&store, directory))
	defer store_close(&store)

	version, version_err := schema_read_version(&store)
	_expect_ok(t, version_err)
	testing.expect_value(t, version, SCHEMA_VERSION)

	// The history the older version wrote is still there.
	sessions, list_err := session_list(&store, {}, context.allocator)
	_expect_ok(t, list_err)
	defer sessions_destroy(sessions, context.allocator)
	if !testing.expect_value(t, len(sessions), 1) { return }
	testing.expect_value(t, sessions[0].title, "older")

	// And the new table is usable.
	_, found, load_err := selection_load(&store)
	_expect_ok(t, load_err)
	testing.expect(t, !found)
	_expect_ok(t, selection_save(&store, {provider = "p", model = "m"}))
}

// test_version_two_migrates_to_current builds a version-two database by hand --
// the shape before the response entry existed -- and checks the migration
// keeps its rows while admitting the new kind.
@(private)
test_version_two_migrates_to_current :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer {
		os.remove_all(directory)
		delete(directory, context.allocator)
	}
	{
		conn: db.Conn
		database_path, join_err := filepath.join({directory, DATABASE_NAME}, context.temp_allocator)
		testing.expect(t, join_err == nil)
		if open_err := sqlite.open(&conn, {path = database_path, foreign_keys = true}); open_err != nil {
			local := open_err
			testing.fail_now(t, strings.concatenate({"could not open a version-two database: ", db.error_message(&local)}, context.temp_allocator))
		}
		for statement in MIGRATION_1 {
			_expect_db_ok(t, db.exec(&conn, statement))
		}
		for statement in MIGRATION_2 {
			_expect_db_ok(t, db.exec(&conn, statement))
		}
		_expect_db_ok(t, db.exec(&conn, "PRAGMA user_version = 2"))
		_expect_db_ok(
			t,
			db.exec(
				&conn,
				"INSERT INTO sessions (id, created_at_ms, updated_at_ms, workspace, title, provider, model, archived_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
				{
					db.Value("0123456789abcdef0123456789abcdef"),
					db.Value(i64(1_000)),
					db.Value(i64(1_000)),
					db.Value("/tmp/project"),
					db.Value("older"),
					db.Value(""),
					db.Value(""),
					db.Value(nil),
				},
			),
		)
		db.close(&conn)
	}

	store: Store
	_expect_ok(t, store_open(&store, directory))
	defer store_close(&store)

	version, version_err := schema_read_version(&store)
	_expect_ok(t, version_err)
	testing.expect_value(t, version, SCHEMA_VERSION)

	sessions, list_err := session_list(&store, {}, context.allocator)
	_expect_ok(t, list_err)
	defer sessions_destroy(sessions, context.allocator)
	if !testing.expect_value(t, len(sessions), 1) { return }
	testing.expect_value(t, sessions[0].title, "older")

	// The migrated database admits the new kind.
	_expect_ok(t, session_claim(&store, sessions[0].id))
	_, append_err := entry_append(&store, sessions[0].id, {created_at_ms = 2_000, payload = Response_Entry{output = `[{"type":"message"}]`}})
	_expect_ok(t, append_err)
}
