#+test
#+private file
package journal

import "core:testing"

import "nabla:db"

// Recovery is tested the way it happens: a journal commits a turn's barriers,
// the process stops without finishing, and the next open of that session closes
// what was left open.

@(test)
test_recovery_closes_an_interrupted_turn :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	// A turn that sent one request and proposed two calls, one of them
	// admitted, plus a Lua execution and a subagent that started.
	writer := _open_journal(test, directory)
	session := _create_session(test, writer, {workspace = "/tmp/project", role = .Main})
	append_record(writer, Record{session = session, turn = 1, kind = .Turn_Started}, _Test_Payload{detail = "turn"})
	append_record(writer, Record{session = session, turn = 1, request = 1, kind = .Request_Sent}, _Test_Payload{detail = "sent"})
	assistant := append_node(writer, Node{session = session, branch = INITIAL_BRANCH, kind = .Assistant, turn = 1}, _Test_Payload{detail = "answer"})
	append_record(writer, Record{session = session, turn = 1, node = assistant, call = 1, kind = .Tool_Proposed}, _Test_Payload{detail = "first call"})
	append_record(writer, Record{session = session, turn = 1, node = assistant, call = 2, kind = .Tool_Proposed}, _Test_Payload{detail = "second call"})
	append_record(writer, Record{session = session, turn = 1, node = assistant, call = 2, kind = .Tool_Admitted}, _Test_Payload{detail = "admitted"})
	append_record(writer, Record{session = session, turn = 1, call = 3, kind = .Lua_Started}, _Test_Payload{detail = "script"})
	child := session_id_create()
	append_record(writer, Record{session = session, turn = 1, call = 4, subagent = child, kind = .Subagent_Started}, Subagent_Started{})
	_commit_ok(test, writer)
	_expect_ok(test, close(writer))

	// The process died there. The next open claims the session and recovers it.
	journal := _open_journal(test, directory)
	defer _close_journal(test, journal)

	counters, claim_error := claim(journal, session)
	_expect_ok(test, claim_error)
	testing.expect_value(test, counters.turn, Turn_Id(1))
	testing.expect_value(test, counters.request, Request_Id(1))
	testing.expect_value(test, counters.call, Call_Id(4))
	testing.expect_value(test, counters.node, assistant)
	testing.expect_value(test, counters.branch, Branch_Id(INITIAL_BRANCH))

	recovery, recover_error := recover(journal)
	_expect_ok(test, recover_error)
	testing.expect_value(test, recovery.turns, 1)
	testing.expect_value(test, recovery.requests, 1)
	testing.expect_value(test, recovery.calls, 4)
	testing.expect_value(test, recovery.results, 1)
	testing.expect_value(test, journal.counters.node, assistant + 1) // the Results node

	// Every record of the session, read back after recovery committed it.
	records := _records_of_session(test, journal, session)
	defer records_destroy(records, context.allocator)

	completed_turns := 0
	interrupted_requests := 0
	completed_tools := 0
	completed_effects := 0
	recovered_records := 0
	for record in records {
		// Only the kinds recovery writes are inspected; the rest of the history
		// is what the writer appended.
		#partial switch record.kind {
		case .Turn_Completed:
			completed_turns += 1
			payload: Turn_Completed
			_decode_payload(test, record.data, &payload)
			testing.expect_value(test, payload.outcome, TURN_OUTCOME_NAMES[.Interrupted])
			testing.expect_value(test, record.turn, Turn_Id(1))
			testing.expect_value(test, record.session, session)
		case .Request_Interrupted:
			interrupted_requests += 1
			payload: Request_Interrupted
			_decode_payload(test, record.data, &payload)
			testing.expect(test, len(payload.detail) > 0, "an interruption names what was found")
			testing.expect_value(test, record.request, Request_Id(1))
		case .Tool_Completed:
			completed_tools += 1
			payload: Tool_Completed
			_decode_payload(test, record.data, &payload)
			// The call that was never admitted did not run; the one that was
			// admitted may have.
			switch record.call {
			case 1:
				testing.expect_value(test, payload.outcome, TOOL_OUTCOME_NAMES[.Not_Executed])
			case 2:
				testing.expect_value(test, payload.outcome, TOOL_OUTCOME_NAMES[.Unknown])
			case:
				testing.fail_now(test, "a tool completion for a call that was not left open")
			}
			testing.expect_value(test, record.node, assistant)
			testing.expect_value(test, record.turn, Turn_Id(1))
		case .Lua_Completed:
			completed_effects += 1
			payload: Call_Completed
			_decode_payload(test, record.data, &payload)
			testing.expect_value(test, payload.outcome, TOOL_OUTCOME_NAMES[.Unknown])
			testing.expect_value(test, record.call, Call_Id(3))
		case .Subagent_Completed:
			completed_effects += 1
			payload: Subagent_Completed
			_decode_payload(test, record.data, &payload)
			// The child never created its session, so it did not run.
			testing.expect_value(test, payload.outcome, TOOL_OUTCOME_NAMES[.Not_Executed])
			testing.expect_value(test, record.call, Call_Id(4))
			testing.expect_value(test, record.subagent, child)
		case .Session_Recovered:
			recovered_records += 1
			payload: Session_Recovered
			_decode_payload(test, record.data, &payload)
			testing.expect_value(test, payload.turns, 1)
			testing.expect_value(test, payload.calls, 4)
			testing.expect_value(test, payload.results, 1)
		case:
		}
	}
	testing.expect_value(test, completed_turns, 1)
	testing.expect_value(test, interrupted_requests, 1)
	testing.expect_value(test, completed_tools, 2)
	testing.expect_value(test, completed_effects, 2)
	testing.expect_value(test, recovered_records, 1)

	// The calls the assistant node proposed have a Results node that answers
	// them, in the order they were proposed.
	branches, branch_error := list_branches(journal, session, context.allocator)
	_expect_ok(test, branch_error)
	defer branch_summaries_destroy(branches, context.allocator)
	testing.expect(test, len(branches) >= 1, "the session has a branch")
	head := branches[0].head
	testing.expect(test, head > assistant, "the Results node is the head")

	ancestry, ancestry_error := read_ancestry(journal, session, head, context.allocator)
	_expect_ok(test, ancestry_error)
	defer nodes_destroy(ancestry, context.allocator)
	testing.expect_value(test, len(ancestry), 2)
	results := ancestry[1]
	testing.expect_value(test, results.kind, Node_Kind.Results)
	testing.expect_value(test, results.parent, assistant)
	testing.expect_value(test, results.branch, Branch_Id(INITIAL_BRANCH))
	testing.expect_value(test, results.turn, Turn_Id(1))
	payload: Results
	_decode_payload(test, results.data, &payload)
	testing.expect_value(test, len(payload.calls), 2)
	testing.expect_value(test, payload.calls[0], Call_Id(1))
	testing.expect_value(test, payload.calls[1], Call_Id(2))

	// Recovery ran once, so a second one has nothing left to record.
	again, again_error := recover(journal)
	_expect_ok(test, again_error)
	testing.expect_value(test, again, Recovery{})

	after := _records_of_session(test, journal, session)
	defer records_destroy(after, context.allocator)
	testing.expect_value(test, len(after), len(records))
}

@(test)
test_recovery_records_nothing_after_a_clean_turn :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	writer := _open_journal(test, directory)
	session := _create_session(test, writer, {workspace = "/tmp/project", role = .Main})
	append_record(writer, Record{session = session, turn = 1, kind = .Turn_Started}, _Test_Payload{detail = "turn"})
	append_record(writer, Record{session = session, turn = 1, request = 1, kind = .Request_Sent}, _Test_Payload{detail = "sent"})
	append_record(writer, Record{session = session, turn = 1, request = 1, kind = .Response_Committed}, _Test_Payload{detail = "answer"})
	append_record(writer, Record{session = session, turn = 1, call = 1, kind = .Tool_Proposed}, _Test_Payload{detail = "call"})
	append_record(writer, Record{session = session, turn = 1, call = 1, kind = .Tool_Admitted}, _Test_Payload{detail = "admit"})
	append_record(writer, Record{session = session, turn = 1, call = 1, kind = .Tool_Completed}, Tool_Completed{outcome = TOOL_OUTCOME_NAMES[.Success]})
	append_record(writer, Record{session = session, turn = 1, call = 2, kind = .Lua_Started}, _Test_Payload{detail = "script"})
	append_record(writer, Record{session = session, turn = 1, call = 2, kind = .Lua_Completed}, Call_Completed{outcome = TOOL_OUTCOME_NAMES[.Success]})
	append_record(writer, Record{session = session, turn = 1, kind = .Turn_Completed}, Turn_Completed{outcome = TURN_OUTCOME_NAMES[.Completed]})
	_commit_ok(test, writer)
	_expect_ok(test, close(writer))

	journal := _open_journal(test, directory)
	defer _close_journal(test, journal)
	_, claim_error := claim(journal, session)
	_expect_ok(test, claim_error)

	before := _records_of_session(test, journal, session)
	defer records_destroy(before, context.allocator)

	recovery, recover_error := recover(journal)
	_expect_ok(test, recover_error)
	testing.expect_value(test, recovery, Recovery{})

	// A session that was closed cleanly has nothing to say, so recovery writes
	// no record at all; the only new record is the claim's own, committed by it.
	after := _records_of_session(test, journal, session)
	defer records_destroy(after, context.allocator)
	testing.expect_value(test, len(after), len(before) + 1)
	for record in after { testing.expect(test, record.kind != Record_Kind.Session_Recovered, "nothing was recovered") }
}

@(test)
test_recovery_that_fails_after_staging_writes_nothing :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	writer := _open_journal(test, directory)
	session := _create_session(test, writer, {workspace = "/tmp/project", role = .Main})
	append_record(writer, Record{session = session, turn = 1, kind = .Turn_Started}, _Test_Payload{detail = "turn"})
	_commit_ok(test, writer)
	_expect_ok(test, close(writer))

	journal := _open_journal(test, directory)
	_, claim_error := claim(journal, session)
	_expect_ok(test, claim_error)

	// The open turn is staged first; the query for unanswered calls then fails
	// because its table is gone.
	_expect_db_ok(test, db.exec(&journal.connection, "DROP TABLE nodes"))
	_, recover_error := recover(journal)
	testing.expect(test, recover_error != nil, "recovery fails")
	testing.expect(test, journal.failure != nil, "the failure latches")
	_expect_ok(test, close(journal))

	reader := _open_journal(test, directory, .Read_Only)
	defer _close_journal(test, reader)
	records := _records_of_session(test, reader, session)
	defer records_destroy(records, context.allocator)
	for record in records {
		testing.expect(test, record.kind != .Turn_Completed && record.kind != .Session_Recovered, "recovery wrote nothing")
	}
}

// A delegation the process left open is settled by what is known of its child: a native
// child with no session never started, and one with a session, like an ACP child, which has
// none, may have taken effect. A background child's outcome waits in its parent's inbox, a
// blocking child's does not, and recovering again writes nothing.
@(test)
test_recovery_settles_delegations_by_whether_the_child_started :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	writer, child_writer: ^Journal
	writer = _open_journal(test, directory)
	child_writer = _open_journal(test, directory)
	parent := _create_session(test, writer, {workspace = "/tmp/project", role = .Main})
	Child :: struct {
		id:         Session_Id,
		call:       Call_Id,
		program:    string,
		background: bool,
	}
	children := [?]Child {
		{id = session_id_create(), call = 1, background = true}, // has a session
		{id = session_id_create(), call = 2, background = true}, // never created one
		{id = session_id_create(), call = 3, background = false}, // blocking, never created one
		{id = session_id_create(), call = 4, program = "acp", background = true}, // no Nabla session
	}
	for child in children {
		append_record(writer, Record{session = parent, call = child.call, kind = .Tool_Admitted}, _Test_Payload{detail = "spawn"})
		append_record(
			writer,
			Record{session = parent, call = child.call, subagent = child.id, kind = .Subagent_Started},
			Subagent_Started{program = child.program, background = child.background},
		)
		append_record(writer, Record{session = parent, call = child.call, kind = .Tool_Completed}, Tool_Completed{outcome = TOOL_OUTCOME_NAMES[.Success]})
	}
	_commit_ok(test, writer)
	_ = _create_session(test, child_writer, {id = children[0].id, workspace = "/tmp/project", role = .Subagent, parent_session = parent, parent_call = 1})
	_commit_ok(test, child_writer)
	_expect_ok(test, close(writer))

	journal := _open_journal(test, directory)
	defer _close_journal(test, journal)
	_, claim_error := claim(journal, parent)
	_expect_ok(test, claim_error)
	recovery, recover_error := recover(journal)
	_expect_ok(test, recover_error)
	testing.expect_value(test, recovery.calls, 4)

	expected := [?]string{TOOL_OUTCOME_NAMES[.Unknown], TOOL_OUTCOME_NAMES[.Not_Executed], TOOL_OUTCOME_NAMES[.Not_Executed], TOOL_OUTCOME_NAMES[.Unknown]}
	records, _, records_error := read_records(journal, Filter{session = parent, kinds = {.Subagent_Completed}}, 0, 0, context.allocator)
	_expect_ok(test, records_error)
	defer records_destroy(records, context.allocator)
	if !testing.expect_value(test, len(records), 4) { return }
	for record, index in records {
		payload: Subagent_Completed
		_decode_payload(test, record.data, &payload)
		testing.expect_value(test, payload.outcome, expected[index])
		testing.expect_value(test, record.subagent, children[index].id)
	}

	inbox, inbox_error := read_inbox(journal, parent, 0, context.allocator)
	_expect_ok(test, inbox_error)
	defer records_destroy(inbox, context.allocator)
	if !testing.expect_value(test, len(inbox), 3) { return }
	testing.expect_value(test, inbox[0].subagent, children[0].id)
	testing.expect_value(test, inbox[1].subagent, children[1].id)
	testing.expect_value(test, inbox[2].subagent, children[3].id)

	again, again_error := recover(journal)
	_expect_ok(test, again_error)
	testing.expect_value(test, again, Recovery{})
	_close_journal(test, child_writer)
}
