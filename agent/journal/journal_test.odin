#+test
#+private file
package journal

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import "nabla:db"
import "nabla:db/sqlite"

// Another writer holding the database is not a storage failure: the commit reports
// it, keeps its records pending, and the next commit writes them.
@(test)
test_a_busy_commit_keeps_its_records_for_the_next_one :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	holder, writer: Journal
	_open_journal(test, &holder, directory)
	defer _close_journal(test, &holder)
	_open_journal(test, &writer, directory)
	defer _close_journal(test, &writer)
	session := _create_session(test, &writer, {workspace = "/tmp/project", role = .Main})
	_commit_ok(test, &writer)
	// The writer gives up at once instead of waiting out the busy timeout.
	_expect_db_ok(test, db.exec(&writer.connection, "PRAGMA busy_timeout = 0"))

	_expect_db_ok(test, db.exec(&holder.connection, "BEGIN IMMEDIATE"))
	append_record(&writer, Record{session = session, turn = 1, kind = .Turn_Started}, _Test_Payload{detail = "turn"})
	_, busy_error := commit(&writer)
	testing.expect(test, error_is_busy(busy_error), "the commit reports the other writer")
	testing.expect(test, writer.failure == nil, "a busy database latches nothing")
	_expect_db_ok(test, db.rollback(&holder.connection))

	_commit_ok(test, &writer)
	records := _records_of_session(test, &writer, session)
	defer records_destroy(records, context.allocator)
	testing.expect(test, _record_seq_of_kind(records, .Turn_Started) != 0, "the pending record was written by the next commit")
}

@(test)
test_committed_records_survive_a_reopen :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	writer: Journal
	_open_journal(test, &writer, directory)

	// The directory and the database admit the owner alone.
	directory_info, directory_error := os.stat(directory, context.temp_allocator)
	if directory_error != nil { testing.fail_now(test, "the journal directory was not created") }
	testing.expect(test, directory_info.mode & OTHERS_ACCESS == {}, "the journal directory should be owner-only")
	database := fmt.tprintf("%s/%s", directory, DATABASE_NAME)
	database_info, database_error := os.stat(database, context.temp_allocator)
	if database_error != nil { testing.fail_now(test, "the database was not created") }
	testing.expect(test, database_info.mode & OTHERS_ACCESS == {}, "the database should be owner-only")

	session := _create_session(test, &writer, {workspace = "/tmp/project", role = .Main})
	append_record(&writer, Record{session = session, turn = 1, kind = .Turn_Started}, _Test_Payload{detail = "turn"})
	// A process-scope record names no session, so both session columns are
	// absent rather than sixteen zero bytes.
	append_record(&writer, Record{kind = .Run_Started}, _Test_Payload{detail = "run"})
	node_id := append_node(
		&writer,
		Node{session = session, branch = INITIAL_BRANCH, kind = .User, turn = 1},
		_Test_Payload{detail = "prompt"},
		_body("hello there"),
	)
	testing.expect_value(test, node_id, Node_Id(1))
	last := _commit_ok(test, &writer)
	testing.expect(test, last > 0, "a commit should report the seq it wrote")
	_expect_ok(test, close(&writer))

	reader: Journal
	_open_journal(test, &reader, directory, .Read_Only)
	defer _close_journal(test, &reader)

	records := _records_of_session(test, &reader, session)
	defer records_destroy(records, context.allocator)

	// The global order is the order the items were appended in, and a node's
	// node.committed record is part of it.
	expected := [?]Record_Kind{.Session_Created, .Branch_Created, .Turn_Started, .Node_Committed}
	testing.expect_value(test, len(records), len(expected))
	previous := Journal_Seq(0)
	for record, index in records {
		if index < len(expected) { testing.expect_value(test, record.kind, expected[index]) }
		testing.expect(test, record.seq > previous, "records should be in ascending seq order")
		previous = record.seq
		testing.expect_value(test, record.session, session)
		testing.expect_value(test, record.subagent, Session_Id{})
		testing.expect_value(test, record.run, _test_run_id())
		testing.expect(test, len(record.data) > 0, "every record should carry a payload")
	}

	// The process-scope record reads back with the absent session id, so the
	// NULL round-trips as the zero id.
	scoped, _, scoped_error := read_records(&reader, Filter{kinds = {.Run_Started}}, 0, 0, context.allocator)
	_expect_ok(test, scoped_error)
	defer records_destroy(scoped, context.allocator)
	testing.expect_value(test, len(scoped), 1)
	testing.expect_value(test, scoped[0].session, Session_Id{})
	testing.expect_value(test, scoped[0].subagent, Session_Id{})

	committed := _record_seq_of_kind(records, .Node_Committed)
	testing.expect(test, committed > 0, "the node's record should be there")

	ancestry, ancestry_error := read_ancestry(&reader, session, node_id, context.allocator)
	_expect_ok(test, ancestry_error)
	defer nodes_destroy(ancestry, context.allocator)

	testing.expect_value(test, len(ancestry), 1)
	node := ancestry[0]
	testing.expect_value(test, node.id, node_id)
	testing.expect_value(test, node.kind, Node_Kind.User)
	testing.expect_value(test, node.branch, Branch_Id(INITIAL_BRANCH))
	testing.expect_value(test, node.turn, Turn_Id(1))
	testing.expect_value(test, node.parent, Node_Id(0))
	testing.expect_value(test, string(node.body), "hello there")
	testing.expect_value(test, node.seq, committed)

	payload: _Test_Payload
	_decode_payload(test, node.data, &payload)
	testing.expect_value(test, payload.detail, "prompt")
	testing.expect_value(test, payload.version, PAYLOAD_VERSION)
}

@(test)
test_a_writable_open_narrows_wide_permissions :: proc(test: ^testing.T) {
	// The modes a default umask leaves on a directory and a database file.
	WIDE_DIRECTORY_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}
	WIDE_FILE_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}

	directory := _temp_directory(test)
	defer _remove_directory(directory)

	journal_directory := fmt.tprintf("%s/journal", directory)
	database := fmt.tprintf("%s/%s", journal_directory, DATABASE_NAME)
	_expect_ok(test, os.make_directory(journal_directory, WIDE_DIRECTORY_PERMISSIONS))
	_expect_ok(test, os.chmod(journal_directory, WIDE_DIRECTORY_PERMISSIONS))
	created, create_error := os.open(database, {.Read, .Write, .Create}, WIDE_FILE_PERMISSIONS)
	if create_error != nil { testing.fail_now(test, "the database file could not be created") }
	_expect_ok(test, os.chmod(database, WIDE_FILE_PERMISSIONS))
	_expect_ok(test, os.close(created))

	journal: Journal
	_open_journal(test, &journal, journal_directory)
	_close_journal(test, &journal)

	directory_info, directory_error := os.stat(journal_directory, context.allocator)
	if directory_error != nil { testing.fail_now(test, "the journal directory was not found") }
	defer os.file_info_delete(directory_info, context.allocator)
	testing.expect_value(test, directory_info.mode, PRIVATE_DIRECTORY_PERMISSIONS)

	database_info, database_error := os.stat(database, context.allocator)
	if database_error != nil { testing.fail_now(test, "the database was not found") }
	defer os.file_info_delete(database_info, context.allocator)
	testing.expect_value(test, database_info.mode, PRIVATE_FILE_PERMISSIONS)
}

@(test)
test_buffered_records_are_invisible_until_a_commit :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	writer: Journal
	_open_journal(test, &writer, directory)
	defer _close_journal(test, &writer)

	session := _create_session(test, &writer, {workspace = "/tmp/project", role = .Main})
	for _ in 0 ..< 3 {
		append_record(&writer, Record{session = session, kind = .Runtime_Message}, _Test_Payload{detail = "buffered"})
	}

	reader: Journal
	_open_journal(test, &reader, directory, .Read_Only)
	defer _close_journal(test, &reader)

	expect_records :: proc(test: ^testing.T, journal: ^Journal, session: Session_Id, want: int, what: string) {
		records, _, error := read_records(journal, Filter{session = session}, 0, 0, context.allocator)
		_expect_ok(test, error)
		defer records_destroy(records, context.allocator)
		testing.expectf(test, len(records) == want, "%s: expected %d records, read %d", what, want, len(records))
	}

	// The session created here holds its own two records before the first
	// observation is buffered.
	SESSION_RECORDS :: 2

	expect_records(test, &reader, session, 0, "before any commit")

	// Neither the record count nor the age limit has been reached.
	_expect_ok(test, flush_due(&writer, time.tick_now()))
	expect_records(test, &reader, session, 0, "after a flush that is not due")

	deadline, has_deadline := flush_deadline(&writer).?
	testing.expect(test, has_deadline, "a buffered batch has a deadline")
	_expect_ok(test, flush_due(&writer, time.tick_add(deadline, time.Second)))
	expect_records(test, &reader, session, SESSION_RECORDS + 3, "after the age limit")

	// The batch record limit commits on its own, with no barrier.
	for _ in 0 ..< JOURNAL_BATCH_RECORDS {
		append_record(&writer, Record{session = session, kind = .Runtime_Message}, _Test_Payload{detail = "bulk"})
	}
	testing.expect_value(test, flush_deadline(&writer) != nil, true)
	_expect_ok(test, flush_due(&writer, time.tick_now()))
	expect_records(test, &reader, session, SESSION_RECORDS + 3 + JOURNAL_BATCH_RECORDS, "after the record limit")

	testing.expect_value(test, flush_deadline(&writer) == nil, true)
}

@(test)
test_a_session_has_one_writer_at_a_time :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	first: Journal
	_open_journal(test, &first, directory)
	session := _create_session(test, &first, {workspace = "/tmp/project", role = .Main})
	_commit_ok(test, &first)

	// A second journal cannot take the session the first one holds.
	second: Journal
	_open_journal(test, &second, directory)
	_, claim_error := claim(&second, session)
	_expect_error(test, claim_error, .Claimed)
	other := _create_session(test, &second, {workspace = "/tmp/other", role = .Main})
	_commit_ok(test, &second)

	// An id the journal does not hold is not a claim to take.
	third: Journal
	_open_journal(test, &third, directory)
	_, missing_error := claim(&third, _absent_session())
	_expect_error(test, missing_error, .Not_Found)

	// Releasing the first writer lets another take over, and the ids it reads
	// back continue where the session stopped.
	node_id := append_node(&first, Node{session = session, branch = INITIAL_BRANCH, kind = .User, turn = 1}, _Test_Payload{detail = "first writer"})
	testing.expect_value(test, node_id, Node_Id(1))
	append_record(&first, Record{session = session, turn = 1, kind = .Turn_Started}, _Test_Payload{detail = "turn"})
	branch_id := append_branch(&first, node_id)
	testing.expect_value(test, branch_id, Branch_Id(2))
	_commit_ok(test, &first)
	_expect_ok(test, release(&first))
	_expect_ok(test, close(&first))

	_expect_ok(test, close(&second))
	_expect_ok(test, close(&third))

	resumed: Journal
	_open_journal(test, &resumed, directory)
	defer _close_journal(test, &resumed)
	counters, resumed_error := claim(&resumed, session)
	_expect_ok(test, resumed_error)
	testing.expect_value(test, counters.node, Node_Id(1))
	testing.expect_value(test, counters.branch, Branch_Id(2))
	testing.expect_value(test, counters.turn, Turn_Id(1))
	testing.expect_value(test, counters.request, Request_Id(0))
	testing.expect_value(test, counters.call, Call_Id(0))

	next := append_node(&resumed, Node{session = session, branch = INITIAL_BRANCH, kind = .Assistant}, _Test_Payload{detail = "second writer"})
	testing.expect_value(test, next, Node_Id(2))
	_commit_ok(test, &resumed)

	testing.expect(test, other != session, "each session has its own id")
}

@(test)
test_a_failed_commit_latches_and_drops_appends :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	journal: Journal
	_open_journal(test, &journal, directory)
	defer _close_journal(test, &journal)

	session := _create_session(test, &journal, {workspace = "/tmp/project", role = .Main})
	node_id := append_node(&journal, Node{session = session, branch = INITIAL_BRANCH, kind = .User}, _Test_Payload{detail = "first"})
	testing.expect_value(test, node_id, Node_Id(1))
	_commit_ok(test, &journal)

	// The next node reuses the id already committed, which the primary key of
	// nodes refuses. A journal only hands out ids that have not been used, so
	// this is the injected storage failure the latch has to survive.
	journal.counters.node = 0
	duplicate := append_node(&journal, Node{session = session, branch = INITIAL_BRANCH, kind = .User}, _Test_Payload{detail = "second"})
	testing.expect_value(test, duplicate, Node_Id(1))

	_, commit_error := commit(&journal)
	// The database's own error is returned and latched, so the harness can report why.
	cause, is_database := commit_error.(db.Error)
	testing.expect(test, is_database, "a failed commit should keep the database's error")
	if is_database {
		message := db.error_message(&cause)
		testing.expect(test, len(message) > 0, "the database's message should be kept")
	}

	// Nothing buffered can be written again, so the batch is dropped, every
	// later append is dropped, and every later commit reports the latch.
	testing.expect_value(test, len(journal.pending), 0)
	append_record(&journal, Record{session = session, kind = .Runtime_Message}, _Test_Payload{detail = "dropped"})
	testing.expect_value(test, len(journal.pending), 0)
	_, again_error := commit(&journal)
	testing.expect(test, again_error == commit_error, "a later commit returns the latched failure")

	// What was committed before the failure is still readable.
	records := _records_of_session(test, &journal, session)
	defer records_destroy(records, context.allocator)
	testing.expect_value(test, len(records), 3)
}

@(test)
test_open_refuses_a_database_this_build_does_not_read :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	// A database this package created, stamped with a version from the future.
	created: Journal
	_open_journal(test, &created, directory)
	_expect_ok(test, close(&created))

	database_path := fmt.tprintf("%s/%s", directory, DATABASE_NAME)
	connection: db.Conn
	_expect_db_ok(test, sqlite.open(&connection, {path = database_path}))
	_expect_db_ok(test, db.exec(&connection, "PRAGMA user_version = 99"))
	_expect_db_ok(test, db.close(&connection))

	refused: Journal
	_expect_error(test, open(&refused, directory, directory, _test_run_id(), .Read_Write), .Schema_Too_New)
	testing.expect(test, !refused.open, "a refused open leaves a closed journal")
	_expect_error(test, open(&refused, directory, directory, _test_run_id(), .Read_Only), .Schema_Too_New)

	// A database someone else wrote holds no version this package can read.
	foreign_directory := _temp_directory(test)
	defer _remove_directory(foreign_directory)
	foreign_path := fmt.tprintf("%s/%s", foreign_directory, DATABASE_NAME)
	file, file_error := os.open(foreign_path, {.Read, .Write, .Create}, PRIVATE_FILE_PERMISSIONS)
	if file_error != nil { testing.fail_now(test, "could not create a database file") }
	_expect_ok(test, os.close(file))

	foreign_connection: db.Conn
	_expect_db_ok(test, sqlite.open(&foreign_connection, {path = foreign_path}))
	_expect_db_ok(test, db.exec(&foreign_connection, "CREATE TABLE foreign_table (x INTEGER)"))
	_expect_db_ok(test, db.close(&foreign_connection))

	_expect_error(test, open(&refused, foreign_directory, foreign_directory, _test_run_id(), .Read_Write), .Schema_Unknown)
	_expect_error(test, open(&refused, foreign_directory, foreign_directory, _test_run_id(), .Read_Only), .Schema_Unknown)

	// A reader creates nothing, so a directory with no journal is .Not_Found.
	empty_directory := _temp_directory(test)
	defer _remove_directory(empty_directory)
	_expect_error(test, open(&refused, empty_directory, empty_directory, _test_run_id(), .Read_Only), .Not_Found)
}

@(test)
test_a_session_created_here_is_claimed_and_numbered :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	journal: Journal
	_open_journal(test, &journal, directory)
	defer _close_journal(test, &journal)

	parent := _create_session(test, &journal, {workspace = "/tmp/project", role = .Main})
	testing.expect(test, parent != {}, "a created session has an id")
	testing.expect_value(test, journal.claimed, parent)
	testing.expect_value(test, journal.counters.branch, Branch_Id(INITIAL_BRANCH))
	_commit_ok(test, &journal)
	_expect_ok(test, release(&journal))

	child := _create_session(test, &journal, {workspace = "/tmp/other", role = .Subagent, parent_session = parent, parent_call = 7})
	_commit_ok(test, &journal)

	// The hex form of an id is what a lock file and a message use.
	hex_text: [SESSION_ID_HEX_LENGTH]u8
	text := session_id_to_hex(child, hex_text[:])
	testing.expect_value(test, len(text), SESSION_ID_HEX_LENGTH)
	parsed, parsed_ok := session_id_parse(text)
	testing.expect(test, parsed_ok, "a rendered id should parse")
	testing.expect_value(test, parsed, child)
	_, bad_parse := session_id_parse(text[:len(text) - 1])
	testing.expect(test, !bad_parse, "a short id should not parse")
	run := run_id_create()
	testing.expect(test, run != {}, "a run id should be created")
	testing.expect(test, run != _test_run_id(), "run ids should be drawn fresh")

	summaries, list_error := list_sessions(&journal, {}, context.allocator)
	_expect_ok(test, list_error)
	defer session_summaries_destroy(summaries, context.allocator)
	testing.expect_value(test, len(summaries), 2)
	testing.expect_value(test, summaries[0].id, child)
	testing.expect_value(test, summaries[0].role, Session_Role.Subagent)
	testing.expect_value(test, summaries[0].parent_session, parent)
	testing.expect_value(test, summaries[0].parent_call, Call_Id(7))
	testing.expect_value(test, summaries[0].title, "")
	testing.expect_value(test, summaries[1].id, parent)
}
