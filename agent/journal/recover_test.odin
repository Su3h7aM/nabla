#+test
#+private file
package journal

import "core:testing"

// Recovery is tested the way it happens: a journal commits a turn's barriers,
// the process stops without finishing, and the next open of that session closes
// what was left open.

@(test)
test_recovery_closes_an_interrupted_turn :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer _remove_directory(directory)

	// A turn that sent one request and proposed two calls, one of them
	// admitted, plus a Lua execution that started.
	writer: Journal
	_open_journal(t, &writer, directory)
	session := _create_session(t, &writer, {workspace = "/tmp/project", role = .Main})
	append_record(&writer, Record{session = session, turn = 1, kind = .Turn_Started}, _Test_Payload{detail = "turn"})
	append_record(&writer, Record{session = session, turn = 1, request = 1, kind = .Request_Sent}, _Test_Payload{detail = "sent"})
	assistant := append_node(&writer, Node{session = session, branch = INITIAL_BRANCH, kind = .Assistant, turn = 1}, _Test_Payload{detail = "answer"})
	append_record(&writer, Record{session = session, turn = 1, node = assistant, call = 1, kind = .Tool_Proposed}, _Test_Payload{detail = "first call"})
	append_record(&writer, Record{session = session, turn = 1, node = assistant, call = 2, kind = .Tool_Proposed}, _Test_Payload{detail = "second call"})
	append_record(&writer, Record{session = session, turn = 1, node = assistant, call = 2, kind = .Tool_Admitted}, _Test_Payload{detail = "admitted"})
	append_record(&writer, Record{session = session, turn = 1, call = 3, kind = .Lua_Started}, _Test_Payload{detail = "script"})
	_commit_ok(t, &writer)
	_expect_ok(t, close(&writer))

	// The process died there. The next open claims the session and recovers it.
	j: Journal
	_open_journal(t, &j, directory)
	defer _close_journal(t, &j)

	counters, claim_err := claim(&j, session)
	_expect_ok(t, claim_err)
	testing.expect_value(t, counters.turn, Turn_Id(1))
	testing.expect_value(t, counters.request, Request_Id(1))
	testing.expect_value(t, counters.call, Call_Id(3))
	testing.expect_value(t, counters.node, assistant)
	testing.expect_value(t, counters.branch, Branch_Id(INITIAL_BRANCH))

	recovery, recover_err := recover(&j)
	_expect_ok(t, recover_err)
	testing.expect_value(t, recovery.turns, 1)
	testing.expect_value(t, recovery.requests, 1)
	testing.expect_value(t, recovery.calls, 3)
	testing.expect_value(t, recovery.results, 1)
	testing.expect_value(t, j.counters.node, assistant + 1) // the Results node

	// Every record of the session, read back after recovery committed it.
	records := _records_of_session(t, &j, session)
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
			_decode_payload(t, record.data, &payload)
			testing.expect_value(t, payload.outcome, TURN_OUTCOME_NAMES[.Interrupted])
			testing.expect_value(t, record.turn, Turn_Id(1))
			testing.expect_value(t, record.session, session)
		case .Request_Interrupted:
			interrupted_requests += 1
			payload: Request_Interrupted
			_decode_payload(t, record.data, &payload)
			testing.expect(t, len(payload.detail) > 0, "an interruption names what was found")
			testing.expect_value(t, record.request, Request_Id(1))
		case .Tool_Completed:
			completed_tools += 1
			payload: Tool_Completed
			_decode_payload(t, record.data, &payload)
			// The call that was never admitted did not run; the one that was
			// admitted may have.
			switch record.call {
			case 1:
				testing.expect_value(t, payload.outcome, TOOL_OUTCOME_NAMES[.Not_Executed])
			case 2:
				testing.expect_value(t, payload.outcome, TOOL_OUTCOME_NAMES[.Unknown])
			case:
				testing.fail_now(t, "a tool completion for a call that was not left open")
			}
			testing.expect_value(t, record.node, assistant)
			testing.expect_value(t, record.turn, Turn_Id(1))
		case .Lua_Completed:
			completed_effects += 1
			payload: Call_Completed
			_decode_payload(t, record.data, &payload)
			testing.expect_value(t, payload.outcome, TOOL_OUTCOME_NAMES[.Unknown])
			testing.expect_value(t, record.call, Call_Id(3))
		case .Session_Recovered:
			recovered_records += 1
			payload: Session_Recovered
			_decode_payload(t, record.data, &payload)
			testing.expect_value(t, payload.turns, 1)
			testing.expect_value(t, payload.calls, 3)
			testing.expect_value(t, payload.results, 1)
		case:
		}
	}
	testing.expect_value(t, completed_turns, 1)
	testing.expect_value(t, interrupted_requests, 1)
	testing.expect_value(t, completed_tools, 2)
	testing.expect_value(t, completed_effects, 1)
	testing.expect_value(t, recovered_records, 1)

	// The calls the assistant node proposed have a Results node that answers
	// them, in the order they were proposed.
	branches, branch_err := list_branches(&j, session, context.allocator)
	_expect_ok(t, branch_err)
	defer branch_summaries_destroy(branches, context.allocator)
	testing.expect(t, len(branches) >= 1, "the session has a branch")
	head := branches[0].head
	testing.expect(t, head > assistant, "the Results node is the head")

	ancestry, ancestry_err := read_ancestry(&j, session, head, context.allocator)
	_expect_ok(t, ancestry_err)
	defer nodes_destroy(ancestry, context.allocator)
	testing.expect_value(t, len(ancestry), 2)
	results := ancestry[1]
	testing.expect_value(t, results.kind, Node_Kind.Results)
	testing.expect_value(t, results.parent, assistant)
	testing.expect_value(t, results.branch, Branch_Id(INITIAL_BRANCH))
	testing.expect_value(t, results.turn, Turn_Id(1))
	payload: Results
	_decode_payload(t, results.data, &payload)
	testing.expect_value(t, len(payload.calls), 2)
	testing.expect_value(t, payload.calls[0], Call_Id(1))
	testing.expect_value(t, payload.calls[1], Call_Id(2))

	// Recovery ran once, so a second one has nothing left to record.
	again, again_err := recover(&j)
	_expect_ok(t, again_err)
	testing.expect_value(t, again, Recovery{})

	after := _records_of_session(t, &j, session)
	defer records_destroy(after, context.allocator)
	testing.expect_value(t, len(after), len(records))
}

@(test)
test_recovery_records_nothing_after_a_clean_turn :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer _remove_directory(directory)

	writer: Journal
	_open_journal(t, &writer, directory)
	session := _create_session(t, &writer, {workspace = "/tmp/project", role = .Main})
	append_record(&writer, Record{session = session, turn = 1, kind = .Turn_Started}, _Test_Payload{detail = "turn"})
	append_record(&writer, Record{session = session, turn = 1, request = 1, kind = .Request_Sent}, _Test_Payload{detail = "sent"})
	append_record(&writer, Record{session = session, turn = 1, request = 1, kind = .Response_Committed}, _Test_Payload{detail = "answer"})
	append_record(&writer, Record{session = session, turn = 1, call = 1, kind = .Tool_Proposed}, _Test_Payload{detail = "call"})
	append_record(&writer, Record{session = session, turn = 1, call = 1, kind = .Tool_Admitted}, _Test_Payload{detail = "admit"})
	append_record(&writer, Record{session = session, turn = 1, call = 1, kind = .Tool_Completed}, Tool_Completed{outcome = TOOL_OUTCOME_NAMES[.Success]})
	append_record(&writer, Record{session = session, turn = 1, call = 2, kind = .Lua_Started}, _Test_Payload{detail = "script"})
	append_record(&writer, Record{session = session, turn = 1, call = 2, kind = .Lua_Completed}, Call_Completed{outcome = TOOL_OUTCOME_NAMES[.Success]})
	append_record(&writer, Record{session = session, turn = 1, kind = .Turn_Completed}, Turn_Completed{outcome = TURN_OUTCOME_NAMES[.Completed]})
	_commit_ok(t, &writer)
	_expect_ok(t, close(&writer))

	j: Journal
	_open_journal(t, &j, directory)
	defer _close_journal(t, &j)
	_, claim_err := claim(&j, session)
	_expect_ok(t, claim_err)

	before := _records_of_session(t, &j, session)
	defer records_destroy(before, context.allocator)

	recovery, recover_err := recover(&j)
	_expect_ok(t, recover_err)
	testing.expect_value(t, recovery, Recovery{})

	// A session that was closed cleanly has nothing to say, so recovery writes
	// no record at all.
	after := _records_of_session(t, &j, session)
	defer records_destroy(after, context.allocator)
	testing.expect_value(t, len(after), len(before))
	for record in after { testing.expect(t, record.kind != Record_Kind.Session_Recovered, "nothing was recovered") }
}
