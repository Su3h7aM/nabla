#+test
#+private file
package journal

import "core:math"
import "core:testing"

@(test)
test_response_committed_reasoning_tokens_are_presence_aware :: proc(test: ^testing.T) {
	payload: Response_Committed
	err := payload_decode(`{"version":1,"model_resolved":"model","finish":"stop","output_tokens":1}`, &payload, context.temp_allocator)
	if !testing.expect_value(test, err, nil) { return }
	testing.expect(test, payload.reasoning_tokens == nil, "older response records leave reasoning tokens unknown")

	payload = {}
	err = payload_decode(`{"version":1,"reasoning_tokens":0}`, &payload, context.temp_allocator)
	if !testing.expect_value(test, err, nil) { return }
	if value, present := payload.reasoning_tokens.?; present {
		testing.expect_value(test, value, i64(0))
	} else {
		testing.fail_now(test, "a reported zero reasoning count remains present")
	}
}

@(test)
test_payload_decode_rejects_unsupported_and_missing_versions :: proc(test: ^testing.T) {
	corruption_journal: Journal
	session := session_id_create()
	seq := Journal_Seq(37)
	payload: Response_Committed
	unsupported_error := payload_decode(`{"version":2}`, &payload, context.temp_allocator, &corruption_journal, session, seq)
	if !testing.expect(test, error_is(unsupported_error, .Corrupt)) { return }
	testing.expect_value(test, corruption_journal.corrupt.session, session)
	testing.expect_value(test, corruption_journal.corrupt.seq, seq)

	corruption_journal.corrupt = {}
	valid_error := payload_decode(`{"version":1,"model_resolved":"model"}`, &payload, context.temp_allocator)
	if !testing.expect_value(test, valid_error, nil) { return }
	missing_error := payload_decode(`{"model_resolved":"model"}`, &payload, context.temp_allocator)
	testing.expect(test, error_is(missing_error, .Corrupt))
}

// Reads are tested through the public API only, on a journal whose records were
// written through it, so the ordering, the filters, and the tree walk are the
// behaviour the harness gets.

@(test)
test_read_records_filters_and_pages :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	journal: Journal
	_open_journal(test, &journal, directory)
	defer _close_journal(test, &journal)

	session := _create_session(test, &journal, {workspace = "/tmp/project", role = .Main})
	for turn in Turn_Id(1) ..= Turn_Id(2) {
		append_record(&journal, Record{session = session, turn = turn, kind = .Turn_Started}, _Test_Payload{detail = "turn"})
		for call in Call_Id(1) ..= Call_Id(2) {
			append_record(&journal, Record{session = session, turn = turn, call = call, kind = .Tool_Proposed}, _Test_Payload{detail = "call"})
		}
	}
	_commit_ok(test, &journal)

	// The zero filter reads every record of the session, oldest first.
	all, last, all_error := read_records(&journal, Filter{session = session}, 0, 0, context.allocator)
	_expect_ok(test, all_error)
	defer records_destroy(all, context.allocator)
	// The session's own three records, then a turn and two calls per turn.
	testing.expect_value(test, len(all), 3 + 2 * 3)
	testing.expect_value(test, last, all[len(all) - 1].seq)
	for record, index in all {
		if index > 0 { testing.expect(test, record.seq > all[index - 1].seq, "records should be ordered by seq") }
	}

	// A kind set reads only those kinds.
	proposed, proposed_last, proposed_error := read_records(&journal, Filter{session = session, kinds = {.Tool_Proposed}}, 0, 0, context.allocator)
	_expect_ok(test, proposed_error)
	defer records_destroy(proposed, context.allocator)
	testing.expect_value(test, len(proposed), 4)
	testing.expect_value(test, proposed_last, proposed[len(proposed) - 1].seq)

	// A turn and a call narrow further.
	for record in proposed { testing.expect_value(test, record.kind, Record_Kind.Tool_Proposed) }
	turn_two, _, turn_error := read_records(&journal, Filter{session = session, turn = 2}, 0, 0, context.allocator)
	_expect_ok(test, turn_error)
	defer records_destroy(turn_two, context.allocator)
	testing.expect_value(test, len(turn_two), 3)
	call_two, _, call_error := read_records(&journal, Filter{session = session, call = 2}, 0, 0, context.allocator)
	_expect_ok(test, call_error)
	defer records_destroy(call_two, context.allocator)
	testing.expect_value(test, len(call_two), 2)

	// A page stops where it was asked to, and `after` continues from there.
	page, cursor, page_error := read_records(&journal, Filter{session = session}, 0, 2, context.allocator)
	_expect_ok(test, page_error)
	defer records_destroy(page, context.allocator)
	testing.expect_value(test, len(page), 2)
	testing.expect_value(test, cursor, page[1].seq)

	next, next_cursor, next_error := read_records(&journal, Filter{session = session}, cursor, 2, context.allocator)
	_expect_ok(test, next_error)
	defer records_destroy(next, context.allocator)
	testing.expect_value(test, len(next), 2)
	testing.expect(test, next[0].seq > cursor, "the next page starts after the cursor")
	testing.expect_value(test, next_cursor, next[1].seq)

	// No page is the end of the set, and the position stays where it was.
	none, none_cursor, none_error := read_records(&journal, Filter{session = session}, 1_000, 5, context.allocator)
	_expect_ok(test, none_error)
	defer records_destroy(none, context.allocator)
	testing.expect_value(test, len(none), 0)
	testing.expect_value(test, none_cursor, Journal_Seq(1_000))

	// Another session's records are not in this one.
	empty, _, empty_error := read_records(&journal, Filter{session = _absent_session()}, 0, 0, context.allocator)
	_expect_ok(test, empty_error)
	defer records_destroy(empty, context.allocator)
	testing.expect_value(test, len(empty), 0)
}

@(test)
test_read_ancestry_follows_a_fork_and_a_checkpoint :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	journal: Journal
	_open_journal(test, &journal, directory)
	defer _close_journal(test, &journal)

	session := _create_session(test, &journal, {workspace = "/tmp/project", role = .Main})
	branch := Branch_Id(INITIAL_BRANCH)

	// Nodes 1..5 form a chain on the first branch.
	head := Node_Id(0)
	for _ in 0 ..< 5 {
		head = append_node(
			&journal,
			Node{session = session, parent = head, branch = branch, kind = .User, turn = 1},
			_Test_Payload{detail = "line"},
			_body("line"),
		)
	}
	testing.expect_value(test, head, Node_Id(5))

	// A checkpoint at the head covers node 2: everything after it is what a
	// projection reads, and nodes 1 and 2 are never loaded.
	checkpoint := append_node(
		&journal,
		Node{session = session, parent = head, branch = branch, kind = .Checkpoint, turn = 1, covers = 2},
		_Test_Payload{detail = "summary"},
		_body("summary"),
	)
	testing.expect_value(test, checkpoint, Node_Id(6))

	// A second branch forks from node 3, and node 3 keeps its place on the
	// first branch.
	fork := append_branch(&journal, 3)
	testing.expect_value(test, fork, Branch_Id(2))
	forked := append_node(&journal, Node{session = session, parent = 3, branch = fork, kind = .User, turn = 2}, _Test_Payload{detail = "fork"}, _body("fork"))
	testing.expect_value(test, forked, Node_Id(7))
	_commit_ok(test, &journal)

	// From the checkpoint: the checkpoint first, then the nodes after the node
	// it covers up to its parent, then the nodes after it up to the head.
	checkpointed, checkpointed_error := read_ancestry(&journal, session, checkpoint, context.allocator)
	_expect_ok(test, checkpointed_error)
	defer nodes_destroy(checkpointed, context.allocator)
	testing.expect_value(test, len(checkpointed), 4)
	testing.expect_value(test, checkpointed[0].id, checkpoint)
	testing.expect_value(test, checkpointed[0].kind, Node_Kind.Checkpoint)
	testing.expect_value(test, checkpointed[0].covers, Node_Id(2))
	expected := [?]Node_Id{6, 3, 4, 5}
	for node, index in checkpointed { testing.expect_value(test, node.id, expected[index]) }

	// A branch forked from before the checkpoint never sees it.
	forked_ancestry, forked_error := read_ancestry(&journal, session, forked, context.allocator)
	_expect_ok(test, forked_error)
	defer nodes_destroy(forked_ancestry, context.allocator)
	testing.expect_value(test, len(forked_ancestry), 4)
	forked_expected := [?]Node_Id{1, 2, 3, 7}
	for node, index in forked_ancestry { testing.expect_value(test, node.id, forked_expected[index]) }

	// Without a checkpoint the walk is the root up to the head, oldest first.
	from_middle, middle_error := read_ancestry(&journal, session, 3, context.allocator)
	_expect_ok(test, middle_error)
	defer nodes_destroy(from_middle, context.allocator)
	testing.expect_value(test, len(from_middle), 3)
	testing.expect_value(test, from_middle[0].id, Node_Id(1))
	testing.expect_value(test, from_middle[2].id, Node_Id(3))

	// No head is no history.
	empty, empty_error := read_ancestry(&journal, session, 0, context.allocator)
	_expect_ok(test, empty_error)
	testing.expect_value(test, len(empty), 0)

	// A head that is not there is a tree this build cannot trust.
	_, missing_error := read_ancestry(&journal, session, 99, context.allocator)
	_expect_error(test, missing_error, .Corrupt)
	testing.expect_value(test, journal.corrupt.session, session)
}

@(test)
test_read_ancestry_refuses_a_parent_that_is_not_there :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	journal: Journal
	_open_journal(test, &journal, directory)
	defer _close_journal(test, &journal)

	session := _create_session(test, &journal, {workspace = "/tmp/project", role = .Main})
	// A node whose parent was never committed: the tree claims a node that is
	// not in it.
	orphan := append_node(&journal, Node{session = session, parent = 42, branch = INITIAL_BRANCH, kind = .User}, _Test_Payload{detail = "orphan"})
	orphan_seq := _commit_ok(test, &journal)

	_, error := read_ancestry(&journal, session, orphan, context.allocator)
	_expect_error(test, error, .Corrupt)
	testing.expect_value(test, journal.corrupt.session, session)
	testing.expect_value(test, journal.corrupt.seq, orphan_seq)
}

@(test)
test_list_sessions_and_branches :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	journal: Journal
	_open_journal(test, &journal, directory)
	defer _close_journal(test, &journal)

	first := _create_session(test, &journal, {workspace = "/tmp/one", role = .Main})
	append_record(&journal, Record{session = first, kind = .Session_Titled}, Session_Titled{title = "the first"})
	user := append_node(&journal, Node{session = first, branch = INITIAL_BRANCH, kind = .User, turn = 1}, _Test_Payload{detail = "prompt"}, _body("hello"))
	second_branch := append_branch(&journal, user)
	second_user := append_node(
		&journal,
		Node{session = first, parent = user, branch = second_branch, kind = .User, turn = 2},
		_Test_Payload{detail = "steering"},
		_body("another"),
	)
	_commit_ok(test, &journal)

	_expect_ok(test, release(&journal))
	second := _create_session(test, &journal, {workspace = "/tmp/two", role = .Subagent, parent_session = first, parent_call = 9})
	_commit_ok(test, &journal)

	summaries, list_error := list_sessions(&journal, {}, context.allocator)
	_expect_ok(test, list_error)
	defer session_summaries_destroy(summaries, context.allocator)
	testing.expect_value(test, len(summaries), 2)
	testing.expect_value(test, summaries[0].id, second) // the newest activity first
	testing.expect_value(test, summaries[0].workspace, "/tmp/two")
	testing.expect_value(test, summaries[0].title, "")
	testing.expect_value(test, summaries[1].id, first)
	testing.expect_value(test, summaries[1].workspace, "/tmp/one")
	testing.expect_value(test, summaries[1].title, "the first")
	testing.expect(test, summaries[1].last_seq > 0, "a session that holds records has activity")

	// A page continues below the last seq of the previous one.
	paged, paged_error := list_sessions(&journal, {before = summaries[0].last_seq}, context.allocator)
	_expect_ok(test, paged_error)
	defer session_summaries_destroy(paged, context.allocator)
	testing.expect_value(test, len(paged), 1)
	testing.expect_value(test, paged[0].id, first)

	by_workspace, workspace_error := list_sessions(&journal, {workspace = "/tmp/two"}, context.allocator)
	_expect_ok(test, workspace_error)
	defer session_summaries_destroy(by_workspace, context.allocator)
	testing.expect_value(test, len(by_workspace), 1)
	testing.expect_value(test, by_workspace[0].id, second)

	by_role, role_error := list_sessions(&journal, {role = Session_Role.Subagent, limit = 1}, context.allocator)
	_expect_ok(test, role_error)
	defer session_summaries_destroy(by_role, context.allocator)
	testing.expect_value(test, len(by_role), 1)
	testing.expect_value(test, by_role[0].id, second)
	testing.expect_value(test, by_role[0].parent_session, first)
	testing.expect_value(test, by_role[0].parent_call, Call_Id(9))

	branches, branch_error := list_branches(&journal, first, context.allocator)
	_expect_ok(test, branch_error)
	defer branch_summaries_destroy(branches, context.allocator)
	testing.expect_value(test, len(branches), 2)
	testing.expect_value(test, branches[0].id, Branch_Id(INITIAL_BRANCH))
	testing.expect_value(test, branches[0].base_node, Node_Id(0))
	testing.expect_value(test, branches[0].head, user)
	testing.expect_value(test, branches[0].last_user_text, "hello")
	testing.expect_value(test, branches[1].id, second_branch)
	testing.expect_value(test, branches[1].base_node, user)
	testing.expect_value(test, branches[1].head, second_user)
	testing.expect_value(test, branches[1].last_user_text, "another")
	testing.expect(test, branches[1].seq > branches[0].seq, "branches are ordered as they were created")
}

// The conversation a projection reads is built here the way the harness builds
// it: the bytes the model sees in node bodies, and the facts around them in
// records correlated by node, request, and call.
@(test)
test_a_conversation_reads_back_the_way_a_projection_walks_it :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	journal: Journal
	_open_journal(test, &journal, directory)
	defer _close_journal(test, &journal)

	session := _create_session(test, &journal, {workspace = "/tmp/project", role = .Main})

	// The instructions each turn ran with are artifacts, and the turn names the
	// one it used by digest.
	first_instructions := _body("Be terse. Prefer the builtin tools.")
	second_instructions := _body("Be terse.")
	first_digest := put_artifact(&journal, "instructions", first_instructions)
	second_digest := put_artifact(&journal, "instructions", second_instructions)
	// The same bytes are one artifact, however often they are stored.
	testing.expect_value(test, put_artifact(&journal, "instructions_copy", first_instructions), first_digest)
	first_hex: [DIGEST_HEX_LENGTH]u8
	second_hex: [DIGEST_HEX_LENGTH]u8
	append_record(
		&journal,
		Record{session = session, turn = 1, kind = .Turn_Started},
		Turn_Started{instructions = digest_to_hex(first_digest, first_hex[:]), model = "gpt-5", effort = "high"},
	)
	user := append_node(
		&journal,
		Node{session = session, branch = INITIAL_BRANCH, kind = .User, turn = 1},
		User{origin = USER_ORIGIN_NAMES[.Prompt]},
		_body("what is in this directory?"),
	)
	append_record(
		&journal,
		Record{session = session, turn = 1, request = 1, kind = .Request_Sent},
		Request_Sent{purpose = REQUEST_PURPOSE_NAMES[.Response], api = "responses", model_requested = "gpt-5"},
	)
	assistant := append_node(
		&journal,
		Node{session = session, parent = user, branch = INITIAL_BRANCH, kind = .Assistant, turn = 1},
		Assistant{request = 1},
		_body("let me look"),
	)

	// Two calls: one whose argument document was repaired, one that was not.
	append_record(
		&journal,
		Record{session = session, turn = 1, request = 1, node = assistant, call = 1, kind = .Tool_Proposed},
		Tool_Proposed{provider_id = "openai", item_id = "item_1", name = "read"},
		_body(`{"path": "a.txt",}`),
	)
	append_record(
		&journal,
		Record{session = session, turn = 1, request = 1, node = assistant, call = 1, kind = .Tool_Admitted},
		Tool_Admitted{tool = "read", repairs = {"a comma followed the last object member"}},
		_body(`{"path":"a.txt"}`),
	)
	append_record(
		&journal,
		Record{session = session, turn = 1, request = 1, node = assistant, call = 1, kind = .Tool_Completed},
		Tool_Completed{outcome = TOOL_OUTCOME_NAMES[.Success], detail = "read a.txt"},
		_body("ok\n\nhello"),
	)
	append_record(
		&journal,
		Record{session = session, turn = 1, request = 1, node = assistant, call = 2, kind = .Tool_Proposed},
		Tool_Proposed{provider_id = "openai", item_id = "item_2", name = "grep"},
		_body(`{"pattern": "hello"}`),
	)
	append_record(
		&journal,
		Record{session = session, turn = 1, request = 1, node = assistant, call = 2, kind = .Tool_Admitted},
		Tool_Admitted{tool = "grep"},
		_body(`{"pattern": "hello"}`),
	)
	append_record(
		&journal,
		Record{session = session, turn = 1, request = 1, node = assistant, call = 2, kind = .Tool_Completed},
		Tool_Completed{outcome = TOOL_OUTCOME_NAMES[.Success], detail = "grep hello"},
		_body("ok\n\na.txt:1:hello"),
	)
	// A Lua child's call carries its parent call and no node, so a projection
	// over Assistant nodes never reads it, though its kind is one it selects.
	append_record(
		&journal,
		Record{session = session, turn = 1, request = 1, call = 3, parent_call = 1, kind = .Tool_Proposed},
		Tool_Proposed{name = "grep"},
		_body(`{"pattern": "hello"}`),
	)
	append_record(
		&journal,
		Record{session = session, turn = 1, request = 1, node = assistant, kind = .Response_Committed},
		Response_Committed {
			model_resolved = "gpt-5-2026",
			finish = RESPONSE_FINISH_NAMES[.Tool_Call],
			input_tokens = 100,
			output_tokens = 20,
			cache_read_tokens = 40,
			cache_write_tokens = 5,
		},
		_body(`[{"type":"function_call","id":"item_1"}]`),
	)
	results := append_node(
		&journal,
		Node{session = session, parent = assistant, branch = INITIAL_BRANCH, kind = .Results, turn = 1},
		Results{calls = {Call_Id(1), Call_Id(2)}},
		_body("two results"),
	)

	// A second turn answers the first, and it reports no cache write.
	append_record(
		&journal,
		Record{session = session, turn = 2, kind = .Turn_Started},
		Turn_Started{instructions = digest_to_hex(second_digest, second_hex[:]), model = "gpt-5", effort = "low"},
	)
	second_user := append_node(
		&journal,
		Node{session = session, parent = results, branch = INITIAL_BRANCH, kind = .User, turn = 2},
		User{origin = USER_ORIGIN_NAMES[.Steering]},
		_body("now summarize"),
	)
	append_record(
		&journal,
		Record{session = session, turn = 2, request = 2, kind = .Request_Sent},
		Request_Sent{purpose = REQUEST_PURPOSE_NAMES[.Response], api = "responses", model_requested = "gpt-5"},
	)
	second_assistant := append_node(
		&journal,
		Node{session = session, parent = second_user, branch = INITIAL_BRANCH, kind = .Assistant, turn = 2},
		Assistant{request = 2},
		_body("a.txt holds hello"),
	)
	append_record(
		&journal,
		Record{session = session, turn = 2, request = 2, node = second_assistant, kind = .Response_Committed},
		Response_Committed {
			model_resolved = "gpt-5-2026",
			finish = RESPONSE_FINISH_NAMES[.Stop],
			input_tokens = 200,
			output_tokens = 30,
			cache_read_tokens = 150,
			cost = 0.25,
		},
	)

	// Two selections: the process-wide default, then the one this session
	// changed to.
	append_record(&journal, Record{kind = .Selection_Changed}, Selection_Changed{provider = "anthropic", model = "claude-opus"})
	append_record(&journal, Record{session = session, kind = .Selection_Changed}, Selection_Changed{provider = "openai", model = "gpt-5", effort = "high"})
	_commit_ok(test, &journal)

	// An artifact reads back by the digest its record names.
	stored, stored_found, stored_error := read_artifact(&journal, second_digest, context.allocator)
	_expect_ok(test, stored_error)
	defer delete(stored, context.allocator)
	testing.expect(test, stored_found, "a committed artifact should be there")
	testing.expect_value(test, string(stored), string(second_instructions))

	unknown_digest := Digest{}
	unknown_digest[0] = 1
	_, unknown_found, unknown_error := read_artifact(&journal, unknown_digest, context.allocator)
	_expect_ok(test, unknown_error)
	testing.expect(test, !unknown_found, "an artifact that was never stored is not found")

	// The projection starts where the session is: its active branch and head.
	branch, head, head_error := session_head(&journal, session)
	_expect_ok(test, head_error)
	testing.expect_value(test, branch, Branch_Id(INITIAL_BRANCH))
	testing.expect_value(test, head, second_assistant)

	ancestry, ancestry_error := read_ancestry(&journal, session, head, context.allocator)
	_expect_ok(test, ancestry_error)
	defer nodes_destroy(ancestry, context.allocator)
	expected_kinds := [?]Node_Kind{.User, .Assistant, .Results, .User, .Assistant}
	expected_bodies := [?]string{"what is in this directory?", "let me look", "two results", "now summarize", "a.txt holds hello"}
	testing.expect_value(test, len(ancestry), len(expected_kinds))
	for node, index in ancestry {
		testing.expect_value(test, node.kind, expected_kinds[index])
		testing.expect_value(test, string(node.body), expected_bodies[index])
	}

	// A projection over the Assistant nodes reads their facts back in order.
	projection, _, projection_error := read_records(
		&journal,
		Filter {
			session = session,
			nodes = []Node_Id{assistant, second_assistant},
			kinds = {.Tool_Proposed, .Tool_Admitted, .Tool_Completed, .Response_Committed},
		},
		0,
		0,
		context.allocator,
	)
	_expect_ok(test, projection_error)
	defer records_destroy(projection, context.allocator)
	projected_kinds := [?]Record_Kind {
		.Tool_Proposed,
		.Tool_Admitted,
		.Tool_Completed,
		.Tool_Proposed,
		.Tool_Admitted,
		.Tool_Completed,
		.Response_Committed,
		.Response_Committed,
	}
	projected_bodies := [?]string {
		`{"path": "a.txt",}`,
		`{"path":"a.txt"}`,
		"ok\n\nhello",
		`{"pattern": "hello"}`,
		`{"pattern": "hello"}`,
		"ok\n\na.txt:1:hello",
		`[{"type":"function_call","id":"item_1"}]`,
		"",
	}
	testing.expect_value(test, len(projection), len(projected_kinds))
	for record, index in projection {
		testing.expect_value(test, record.kind, projected_kinds[index])
		testing.expect_value(test, string(record.body), projected_bodies[index])
	}
	// Each call's records name the Assistant node that proposed it and the
	// request the response belongs to.
	for record in projection[:6] {
		testing.expect_value(test, record.node, assistant)
		testing.expect_value(test, record.request, Request_Id(1))
		testing.expect_value(test, record.turn, Turn_Id(1))
	}
	testing.expect_value(test, projection[0].call, Call_Id(1))
	testing.expect_value(test, projection[3].call, Call_Id(2))
	testing.expect_value(test, projection[6].node, assistant)
	testing.expect_value(test, projection[7].node, second_assistant)
	testing.expect_value(test, projection[6].request, Request_Id(1))
	testing.expect_value(test, projection[7].request, Request_Id(2))

	// The Lua child's call is not in the projection, and is read back by the
	// call it belongs to.
	child_records, _, child_error := read_records(&journal, Filter{session = session, call = 3}, 0, 0, context.allocator)
	_expect_ok(test, child_error)
	defer records_destroy(child_records, context.allocator)
	testing.expect_value(test, len(child_records), 1)
	testing.expect_value(test, child_records[0].parent_call, Call_Id(1))
	testing.expect_value(test, child_records[0].node, Node_Id(0))

	// One call's records read back through the call correlation too.
	call_records, _, call_error := read_records(&journal, Filter{session = session, call = 2}, 0, 0, context.allocator)
	_expect_ok(test, call_error)
	defer records_destroy(call_records, context.allocator)
	testing.expect_value(test, len(call_records), 3)

	// The payloads carry what a projection needs to rebuild the exchange.
	proposed: Tool_Proposed
	_decode_payload(test, projection[0].data, &proposed)
	testing.expect_value(test, proposed.name, "read")
	testing.expect_value(test, proposed.item_id, "item_1")
	admitted: Tool_Admitted
	_decode_payload(test, projection[1].data, &admitted)
	testing.expect_value(test, admitted.tool, "read")
	testing.expect_value(test, len(admitted.repairs), 1)
	completed: Tool_Completed
	_decode_payload(test, projection[2].data, &completed)
	committed: Response_Committed
	_decode_payload(test, projection[6].data, &committed)
	testing.expect_value(test, committed.finish, RESPONSE_FINISH_NAMES[.Tool_Call])
	testing.expect_value(test, committed.cache_write_tokens.?, 5)
	answer: Assistant
	_decode_payload(test, ancestry[1].data, &answer)
	testing.expect_value(test, answer.request, Request_Id(1))
	summary: Assistant
	_decode_payload(test, ancestry[4].data, &summary)
	testing.expect(test, !summary.partial, "a response that committed whole is not partial")
	prompt: User
	_decode_payload(test, ancestry[0].data, &prompt)
	testing.expect_value(test, prompt.origin, USER_ORIGIN_NAMES[.Prompt])
	steered: User
	_decode_payload(test, ancestry[3].data, &steered)
	testing.expect_value(test, steered.origin, USER_ORIGIN_NAMES[.Steering])

	// A count the provider never reported is not a zero in the totals, and a
	// response without a cache write count still measures the hit rate.
	totals, totals_error := usage_totals(&journal, session)
	_expect_ok(test, totals_error)
	testing.expect_value(test, totals.requests, 2)
	testing.expect_value(test, totals.paired_requests, 2)
	testing.expect_value(test, totals.input, 300)
	testing.expect_value(test, totals.output, 50)
	testing.expect_value(test, totals.cache_read, 190)
	testing.expect_value(test, totals.cache_write, 5)
	testing.expect_value(test, totals.paired_input, 300)
	testing.expect_value(test, totals.paired_read, 190)
	// Only the second response was priced, so the total is its cost alone and the
	// priced count says the total covers one of the two.
	testing.expect_value(test, totals.cost, 0.25)
	testing.expect_value(test, totals.priced_requests, 1)
	rate, rate_measured := cache_hit_rate(totals)
	testing.expect(test, rate_measured, "the paired requests report a hit rate")
	testing.expectf(test, math.abs(rate - 190.0 / 300.0) < 1e-9, "expected a hit rate of 190/300, got %v", rate)
	coverage, coverage_measured := cache_coverage(totals)
	testing.expect(test, coverage_measured, "the paired requests report a coverage")
	testing.expectf(test, math.abs(coverage - 1.0) < 1e-9, "expected full coverage, got %v", coverage)

	// The latest record of a kind is the one that stands.
	latest, latest_found, latest_error := read_latest(&journal, Filter{session = session, kinds = {.Selection_Changed}}, context.allocator)
	_expect_ok(test, latest_error)
	defer record_destroy(&latest, context.allocator)
	testing.expect(test, latest_found, "the session changed its selection")
	testing.expect_value(test, latest.session, session)
	selection: Selection_Changed
	_decode_payload(test, latest.data, &selection)
	testing.expect_value(test, selection.provider, "openai")
	testing.expect_value(test, selection.model, "gpt-5")
	testing.expect_value(test, selection.effort, "high")

	// The instructions of the latest turn are its digest, and the artifact it
	// names is what that turn ran with.
	started, started_found, started_error := read_latest(&journal, Filter{session = session, kinds = {.Turn_Started}}, context.allocator)
	_expect_ok(test, started_error)
	defer record_destroy(&started, context.allocator)
	testing.expect(test, started_found, "the session started a turn")
	testing.expect_value(test, started.turn, Turn_Id(2))
	turn: Turn_Started
	_decode_payload(test, started.data, &turn)
	digest, digest_ok := digest_from_hex(turn.instructions)
	testing.expect(test, digest_ok, "a stored instruction digest parses")
	testing.expect_value(test, digest, second_digest)
	testing.expect_value(test, turn.model, "gpt-5")
	testing.expect_value(test, turn.effort, "low")

	// Nothing matched is not an error, and it is not a record.
	_, empty_found, empty_error := read_latest(&journal, Filter{session = session, kinds = {.Session_Recovered}}, context.allocator)
	_expect_ok(test, empty_error)
	testing.expect(test, !empty_found, "a session that never recovered has no such record")

	// Selecting a branch moves the head to it, and a branch that holds no node
	// yet is at the node it forked from.
	fork := append_branch(&journal, user)
	append_record(&journal, Record{session = session, branch = fork, kind = .Branch_Selected}, Branch_Selected{})
	_commit_ok(test, &journal)
	forked_branch, forked_head, forked_error := session_head(&journal, session)
	_expect_ok(test, forked_error)
	testing.expect_value(test, forked_branch, fork)
	testing.expect_value(test, forked_head, user)

	forked := append_node(
		&journal,
		Node{session = session, parent = user, branch = fork, kind = .User, turn = 3},
		User{origin = USER_ORIGIN_NAMES[.Harness]},
		_body("try again"),
	)
	_commit_ok(test, &journal)
	_, moved_head, moved_error := session_head(&journal, session)
	_expect_ok(test, moved_error)
	testing.expect_value(test, moved_head, forked)
}

// A delegation is coordinated through records alone: each side has its own
// connection, as it would on its own thread, and a message is delivered exactly
// once because its delivery commits with the node that carries it.
@(test)
test_delegation_messages_are_delivered_once :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	parent_journal, child_journal: Journal
	_open_journal(test, &parent_journal, directory)
	defer _close_journal(test, &parent_journal)
	_open_journal(test, &child_journal, directory)
	defer _close_journal(test, &child_journal)

	parent := _create_session(test, &parent_journal, {workspace = "/tmp/project", role = .Main})
	call := next_call(&parent_journal)
	child := session_id_create()
	append_record(
		&parent_journal,
		Record{session = parent, call = call, subagent = child, kind = .Subagent_Started},
		Subagent_Started{model = "gpt-5", effort = "low"},
	)
	_commit_ok(test, &parent_journal)
	testing.expect_value(
		test,
		_create_session(test, &child_journal, {id = child, workspace = "/tmp/project", role = .Subagent, parent_session = parent, parent_call = call}),
		child,
	)
	_commit_ok(test, &child_journal)

	children, children_error := list_sessions(&parent_journal, {parent = parent}, context.allocator)
	_expect_ok(test, children_error)
	defer session_summaries_destroy(children, context.allocator)
	testing.expect_value(test, len(children), 1)
	testing.expect_value(test, children[0].id, child)
	testing.expect_value(test, children[0].parent_call, call)

	append_record(&parent_journal, Record{session = parent, subagent = child, kind = .Subagent_Message}, Subagent_Message{}, _body("check the tests"))
	_commit_ok(test, &parent_journal)

	delivered, delivered_error := last_delivered_message(&child_journal, child)
	_expect_ok(test, delivered_error)
	testing.expect_value(test, delivered, Journal_Seq(0))
	messages, messages_error := read_inbox(&child_journal, child, delivered, context.allocator)
	_expect_ok(test, messages_error)
	defer records_destroy(messages, context.allocator)
	testing.expect_value(test, len(messages), 1)
	testing.expect_value(test, string(messages[0].body), "check the tests")
	// The parent's own message to the child is not in the parent's inbox.
	sent, sent_error := read_inbox(&parent_journal, parent, 0, context.allocator)
	_expect_ok(test, sent_error)
	defer records_destroy(sent, context.allocator)
	testing.expect_value(test, len(sent), 0)

	_ = append_node(
		&child_journal,
		Node{session = child, branch = INITIAL_BRANCH, kind = .User, turn = 1},
		User{origin = USER_ORIGIN_NAMES[.Agent], message = messages[0].seq},
		messages[0].body,
	)
	_commit_ok(test, &child_journal)

	// After the delivery commits, resuming from the delivered seq finds nothing,
	// which is what a restarted child would see.
	resumed, resumed_error := last_delivered_message(&child_journal, child)
	_expect_ok(test, resumed_error)
	testing.expect_value(test, resumed, messages[0].seq)
	pending, pending_error := read_inbox(&child_journal, child, resumed, context.allocator)
	_expect_ok(test, pending_error)
	defer records_destroy(pending, context.allocator)
	testing.expect_value(test, len(pending), 0)

	// The child's reply is its own record, which the parent reads from the child's session.
	append_record(&child_journal, Record{session = child, subagent = child, kind = .Subagent_Message}, Subagent_Message{}, _body("done"))
	_commit_ok(test, &child_journal)
	replies, replies_error := read_inbox(&parent_journal, parent, 0, context.allocator)
	_expect_ok(test, replies_error)
	defer records_destroy(replies, context.allocator)
	testing.expect_value(test, len(replies), 1)
	testing.expect_value(test, string(replies[0].body), "done")
	// The child does not read its own reply back.
	own, own_error := read_inbox(&child_journal, child, resumed, context.allocator)
	_expect_ok(test, own_error)
	defer records_destroy(own, context.allocator)
	testing.expect_value(test, len(own), 0)
}

// A line a session accepted is pending until a User node names its seq. The journal alone
// carries that fact, so a reopened session finds the same lines, and finds none twice.
@(test)
test_accepted_input_stays_pending_until_a_node_delivers_it :: proc(test: ^testing.T) {
	directory := _temp_directory(test)
	defer _remove_directory(directory)

	writer: Journal
	_open_journal(test, &writer, directory)
	session := _create_session(test, &writer, {workspace = "/tmp/project", role = .Main})
	append_record(&writer, Record{session = session, kind = .User_Input}, User_Input{origin = USER_ORIGIN_NAMES[.Steering]}, _body("check the logs"))
	append_record(&writer, Record{session = session, kind = .User_Input}, User_Input{origin = USER_ORIGIN_NAMES[.Steering]}, _body("and the config"))
	_commit_ok(test, &writer)
	// The process ends here, before either line was delivered.
	_expect_ok(test, close(&writer))

	reopened: Journal
	_open_journal(test, &reopened, directory)
	_, claim_error := claim(&reopened, session)
	_expect_ok(test, claim_error)
	_, recover_error := recover(&reopened)
	_expect_ok(test, recover_error)
	delivered, delivered_error := last_delivered_message(&reopened, session)
	_expect_ok(test, delivered_error)
	pending, pending_error := read_inbox(&reopened, session, delivered, context.allocator)
	_expect_ok(test, pending_error)
	if !testing.expect_value(test, len(pending), 2) {
		records_destroy(pending, context.allocator)
		_close_journal(test, &reopened)
		return
	}
	testing.expect_value(test, string(pending[0].body), "check the logs")
	testing.expect_value(test, string(pending[1].body), "and the config")

	// Delivering both commits their nodes with the seqs they name.
	for record in pending {
		_ = append_node(
			&reopened,
			Node{session = session, branch = INITIAL_BRANCH, kind = .User, turn = 1},
			User{origin = USER_ORIGIN_NAMES[.Steering], message = record.seq},
			record.body,
		)
	}
	last := pending[1].seq
	records_destroy(pending, context.allocator)
	_commit_ok(test, &reopened)
	_close_journal(test, &reopened)

	again: Journal
	_open_journal(test, &again, directory)
	defer _close_journal(test, &again)
	_, again_claim_error := claim(&again, session)
	_expect_ok(test, again_claim_error)
	_, again_recover_error := recover(&again)
	_expect_ok(test, again_recover_error)
	resumed, resumed_error := last_delivered_message(&again, session)
	_expect_ok(test, resumed_error)
	testing.expect_value(test, resumed, last)
	remaining, remaining_error := read_inbox(&again, session, resumed, context.allocator)
	_expect_ok(test, remaining_error)
	defer records_destroy(remaining, context.allocator)
	testing.expect_value(test, len(remaining), 0)
}
