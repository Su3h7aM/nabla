#+test
#+private file
package journal

import "core:math"
import "core:testing"

// Reads are tested through the public API only, on a journal whose records were
// written through it, so the ordering, the filters, and the tree walk are the
// behaviour the harness gets.

@(test)
test_read_records_filters_and_pages :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer _remove_directory(directory)

	j: Journal
	_open_journal(t, &j, directory)
	defer _close_journal(t, &j)

	session := _create_session(t, &j, {workspace = "/tmp/project", role = .Main})
	for turn in Turn_Id(1) ..= Turn_Id(2) {
		append_record(&j, Record{session = session, turn = turn, kind = .Turn_Started}, _Test_Payload{detail = "turn"})
		for call in Call_Id(1) ..= Call_Id(2) {
			append_record(&j, Record{session = session, turn = turn, call = call, kind = .Tool_Proposed}, _Test_Payload{detail = "call"})
		}
	}
	_commit_ok(t, &j)

	// The zero filter reads every record of the session, oldest first.
	all, last, all_err := read_records(&j, Filter{session = session}, 0, 0, context.allocator)
	_expect_ok(t, all_err)
	defer records_destroy(all, context.allocator)
	// The session's own two records, then a turn and two calls per turn.
	testing.expect_value(t, len(all), 2 + 2 * 3)
	testing.expect_value(t, last, all[len(all) - 1].seq)
	for record, i in all {
		if i > 0 { testing.expect(t, record.seq > all[i - 1].seq, "records should be ordered by seq") }
	}

	// A kind set reads only those kinds.
	proposed, proposed_last, proposed_err := read_records(&j, Filter{session = session, kinds = {.Tool_Proposed}}, 0, 0, context.allocator)
	_expect_ok(t, proposed_err)
	defer records_destroy(proposed, context.allocator)
	testing.expect_value(t, len(proposed), 4)
	testing.expect_value(t, proposed_last, proposed[len(proposed) - 1].seq)

	// A turn and a call narrow further.
	for record in proposed { testing.expect_value(t, record.kind, Record_Kind.Tool_Proposed) }
	turn_two, _, turn_err := read_records(&j, Filter{session = session, turn = 2}, 0, 0, context.allocator)
	_expect_ok(t, turn_err)
	defer records_destroy(turn_two, context.allocator)
	testing.expect_value(t, len(turn_two), 3)
	call_two, _, call_err := read_records(&j, Filter{session = session, call = 2}, 0, 0, context.allocator)
	_expect_ok(t, call_err)
	defer records_destroy(call_two, context.allocator)
	testing.expect_value(t, len(call_two), 2)

	// A page stops where it was asked to, and `after` continues from there.
	page, cursor, page_err := read_records(&j, Filter{session = session}, 0, 2, context.allocator)
	_expect_ok(t, page_err)
	defer records_destroy(page, context.allocator)
	testing.expect_value(t, len(page), 2)
	testing.expect_value(t, cursor, page[1].seq)

	next, next_cursor, next_err := read_records(&j, Filter{session = session}, cursor, 2, context.allocator)
	_expect_ok(t, next_err)
	defer records_destroy(next, context.allocator)
	testing.expect_value(t, len(next), 2)
	testing.expect(t, next[0].seq > cursor, "the next page starts after the cursor")
	testing.expect_value(t, next_cursor, next[1].seq)

	// No page is the end of the set, and the position stays where it was.
	none, none_cursor, none_err := read_records(&j, Filter{session = session}, 1_000, 5, context.allocator)
	_expect_ok(t, none_err)
	defer records_destroy(none, context.allocator)
	testing.expect_value(t, len(none), 0)
	testing.expect_value(t, none_cursor, Journal_Seq(1_000))

	// Another session's records are not in this one.
	empty, _, empty_err := read_records(&j, Filter{session = _absent_session()}, 0, 0, context.allocator)
	_expect_ok(t, empty_err)
	defer records_destroy(empty, context.allocator)
	testing.expect_value(t, len(empty), 0)
}

@(test)
test_read_ancestry_follows_a_fork_and_a_checkpoint :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer _remove_directory(directory)

	j: Journal
	_open_journal(t, &j, directory)
	defer _close_journal(t, &j)

	session := _create_session(t, &j, {workspace = "/tmp/project", role = .Main})
	branch := Branch_Id(INITIAL_BRANCH)

	// Nodes 1..5 form a chain on the first branch.
	head := Node_Id(0)
	for _ in 0 ..< 5 {
		head = append_node(&j, Node{session = session, parent = head, branch = branch, kind = .User, turn = 1}, _Test_Payload{detail = "line"}, _body("line"))
	}
	testing.expect_value(t, head, Node_Id(5))

	// A checkpoint at the head covers node 2: everything after it is what a
	// projection reads, and nodes 1 and 2 are never loaded.
	checkpoint := append_node(
		&j,
		Node{session = session, parent = head, branch = branch, kind = .Checkpoint, turn = 1, covers = 2},
		_Test_Payload{detail = "summary"},
		_body("summary"),
	)
	testing.expect_value(t, checkpoint, Node_Id(6))

	// A second branch forks from node 3, and node 3 keeps its place on the
	// first branch.
	fork := append_branch(&j, 3)
	testing.expect_value(t, fork, Branch_Id(2))
	forked := append_node(&j, Node{session = session, parent = 3, branch = fork, kind = .User, turn = 2}, _Test_Payload{detail = "fork"}, _body("fork"))
	testing.expect_value(t, forked, Node_Id(7))
	_commit_ok(t, &j)

	// From the checkpoint: the checkpoint first, then the nodes after the node
	// it covers up to its parent, then the nodes after it up to the head.
	checkpointed, checkpointed_err := read_ancestry(&j, session, checkpoint, context.allocator)
	_expect_ok(t, checkpointed_err)
	defer nodes_destroy(checkpointed, context.allocator)
	testing.expect_value(t, len(checkpointed), 4)
	testing.expect_value(t, checkpointed[0].id, checkpoint)
	testing.expect_value(t, checkpointed[0].kind, Node_Kind.Checkpoint)
	testing.expect_value(t, checkpointed[0].covers, Node_Id(2))
	expected := [?]Node_Id{6, 3, 4, 5}
	for node, i in checkpointed { testing.expect_value(t, node.id, expected[i]) }

	// A branch forked from before the checkpoint never sees it.
	forked_ancestry, forked_err := read_ancestry(&j, session, forked, context.allocator)
	_expect_ok(t, forked_err)
	defer nodes_destroy(forked_ancestry, context.allocator)
	testing.expect_value(t, len(forked_ancestry), 4)
	forked_expected := [?]Node_Id{1, 2, 3, 7}
	for node, i in forked_ancestry { testing.expect_value(t, node.id, forked_expected[i]) }

	// Without a checkpoint the walk is the root up to the head, oldest first.
	from_middle, middle_err := read_ancestry(&j, session, 3, context.allocator)
	_expect_ok(t, middle_err)
	defer nodes_destroy(from_middle, context.allocator)
	testing.expect_value(t, len(from_middle), 3)
	testing.expect_value(t, from_middle[0].id, Node_Id(1))
	testing.expect_value(t, from_middle[2].id, Node_Id(3))

	// No head is no history.
	empty, empty_err := read_ancestry(&j, session, 0, context.allocator)
	_expect_ok(t, empty_err)
	testing.expect_value(t, len(empty), 0)

	// A head that is not there is a tree this build cannot trust.
	_, missing_err := read_ancestry(&j, session, 99, context.allocator)
	_expect_error(t, missing_err, .Corrupt)
	testing.expect_value(t, j.corrupt.session, session)
}

@(test)
test_read_ancestry_refuses_a_parent_that_is_not_there :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer _remove_directory(directory)

	j: Journal
	_open_journal(t, &j, directory)
	defer _close_journal(t, &j)

	session := _create_session(t, &j, {workspace = "/tmp/project", role = .Main})
	// A node whose parent was never committed: the tree claims a node that is
	// not in it.
	orphan := append_node(&j, Node{session = session, parent = 42, branch = INITIAL_BRANCH, kind = .User}, _Test_Payload{detail = "orphan"})
	_commit_ok(t, &j)

	_, err := read_ancestry(&j, session, orphan, context.allocator)
	_expect_error(t, err, .Corrupt)
	testing.expect_value(t, j.corrupt.session, session)
}

@(test)
test_list_sessions_and_branches :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer _remove_directory(directory)

	j: Journal
	_open_journal(t, &j, directory)
	defer _close_journal(t, &j)

	first := _create_session(t, &j, {workspace = "/tmp/one", role = .Main})
	append_record(&j, Record{session = first, kind = .Session_Titled}, Session_Titled{title = "the first"})
	user := append_node(&j, Node{session = first, branch = INITIAL_BRANCH, kind = .User, turn = 1}, _Test_Payload{detail = "prompt"}, _body("hello"))
	second_branch := append_branch(&j, user)
	second_user := append_node(
		&j,
		Node{session = first, parent = user, branch = second_branch, kind = .User, turn = 2},
		_Test_Payload{detail = "steering"},
		_body("another"),
	)
	_commit_ok(t, &j)

	_expect_ok(t, release(&j))
	second := _create_session(t, &j, {workspace = "/tmp/two", role = .Subagent, parent_session = first, parent_call = 9})
	_commit_ok(t, &j)

	summaries, list_err := list_sessions(&j, {}, context.allocator)
	_expect_ok(t, list_err)
	defer session_summaries_destroy(summaries, context.allocator)
	testing.expect_value(t, len(summaries), 2)
	testing.expect_value(t, summaries[0].id, second) // the newest activity first
	testing.expect_value(t, summaries[0].workspace, "/tmp/two")
	testing.expect_value(t, summaries[0].title, "")
	testing.expect_value(t, summaries[1].id, first)
	testing.expect_value(t, summaries[1].workspace, "/tmp/one")
	testing.expect_value(t, summaries[1].title, "the first")
	testing.expect(t, summaries[1].last_seq > 0, "a session that holds records has activity")

	// A page continues below the last seq of the previous one.
	paged, paged_err := list_sessions(&j, {before = summaries[0].last_seq}, context.allocator)
	_expect_ok(t, paged_err)
	defer session_summaries_destroy(paged, context.allocator)
	testing.expect_value(t, len(paged), 1)
	testing.expect_value(t, paged[0].id, first)

	by_workspace, workspace_err := list_sessions(&j, {workspace = "/tmp/two"}, context.allocator)
	_expect_ok(t, workspace_err)
	defer session_summaries_destroy(by_workspace, context.allocator)
	testing.expect_value(t, len(by_workspace), 1)
	testing.expect_value(t, by_workspace[0].id, second)

	by_role, role_err := list_sessions(&j, {role = Session_Role.Subagent, limit = 1}, context.allocator)
	_expect_ok(t, role_err)
	defer session_summaries_destroy(by_role, context.allocator)
	testing.expect_value(t, len(by_role), 1)
	testing.expect_value(t, by_role[0].id, second)
	testing.expect_value(t, by_role[0].parent_session, first)
	testing.expect_value(t, by_role[0].parent_call, Call_Id(9))

	branches, branch_err := list_branches(&j, first, context.allocator)
	_expect_ok(t, branch_err)
	defer branch_summaries_destroy(branches, context.allocator)
	testing.expect_value(t, len(branches), 2)
	testing.expect_value(t, branches[0].id, Branch_Id(INITIAL_BRANCH))
	testing.expect_value(t, branches[0].base_node, Node_Id(0))
	testing.expect_value(t, branches[0].head, user)
	testing.expect_value(t, branches[0].last_user_text, "hello")
	testing.expect_value(t, branches[1].id, second_branch)
	testing.expect_value(t, branches[1].base_node, user)
	testing.expect_value(t, branches[1].head, second_user)
	testing.expect_value(t, branches[1].last_user_text, "another")
	testing.expect(t, branches[1].seq > branches[0].seq, "branches are ordered as they were created")
}

// The conversation a projection reads is built here the way the harness builds
// it: the bytes the model sees in node bodies, and the facts around them in
// records correlated by node, request, and call.
@(test)
test_a_conversation_reads_back_the_way_a_projection_walks_it :: proc(t: ^testing.T) {
	directory := _temp_directory(t)
	defer _remove_directory(directory)

	j: Journal
	_open_journal(t, &j, directory)
	defer _close_journal(t, &j)

	session := _create_session(t, &j, {workspace = "/tmp/project", role = .Main})

	// The instructions each turn ran with are artifacts, and the turn names the
	// one it used by digest.
	first_instructions := _body("Be terse. Prefer the builtin tools.")
	second_instructions := _body("Be terse.")
	first_digest := put_artifact(&j, "instructions", first_instructions)
	second_digest := put_artifact(&j, "instructions", second_instructions)
	// The same bytes are one artifact, however often they are stored.
	testing.expect_value(t, put_artifact(&j, "instructions_copy", first_instructions), first_digest)
	first_hex: [DIGEST_HEX_LENGTH]u8
	second_hex: [DIGEST_HEX_LENGTH]u8
	append_record(
		&j,
		Record{session = session, turn = 1, kind = .Turn_Started},
		Turn_Started{instructions = digest_to_hex(first_digest, first_hex[:]), model = "gpt-5", effort = "high"},
	)
	user := append_node(
		&j,
		Node{session = session, branch = INITIAL_BRANCH, kind = .User, turn = 1},
		User{origin = USER_ORIGIN_NAMES[.Prompt]},
		_body("what is in this directory?"),
	)
	append_record(
		&j,
		Record{session = session, turn = 1, request = 1, kind = .Request_Sent},
		Request_Sent{purpose = REQUEST_PURPOSE_NAMES[.Response], api = "responses", model_requested = "gpt-5"},
	)
	assistant := append_node(
		&j,
		Node{session = session, parent = user, branch = INITIAL_BRANCH, kind = .Assistant, turn = 1},
		Assistant{request = 1, reasoning = []Reasoning_Item{{id = "rs_1", encrypted = "opaque"}}},
		_body("let me look"),
	)

	// Two calls: one whose argument document was repaired, one that was not.
	append_record(
		&j,
		Record{session = session, turn = 1, request = 1, node = assistant, call = 1, kind = .Tool_Proposed},
		Tool_Proposed{provider_id = "openai", item_id = "item_1", name = "read"},
		_body(`{"path": "a.txt",}`),
	)
	append_record(
		&j,
		Record{session = session, turn = 1, request = 1, node = assistant, call = 1, kind = .Tool_Admitted},
		Tool_Admitted{tool = "read", repairs = {"a comma followed the last object member"}},
		_body(`{"path":"a.txt"}`),
	)
	append_record(
		&j,
		Record{session = session, turn = 1, request = 1, node = assistant, call = 1, kind = .Tool_Completed},
		Tool_Completed{outcome = TOOL_OUTCOME_NAMES[.Success], detail = "read a.txt", origin = "builtin_read"},
		_body("ok\n\nhello"),
	)
	append_record(
		&j,
		Record{session = session, turn = 1, request = 1, node = assistant, call = 2, kind = .Tool_Proposed},
		Tool_Proposed{provider_id = "openai", item_id = "item_2", name = "grep"},
		_body(`{"pattern": "hello"}`),
	)
	append_record(
		&j,
		Record{session = session, turn = 1, request = 1, node = assistant, call = 2, kind = .Tool_Admitted},
		Tool_Admitted{tool = "grep"},
		_body(`{"pattern": "hello"}`),
	)
	append_record(
		&j,
		Record{session = session, turn = 1, request = 1, node = assistant, call = 2, kind = .Tool_Completed},
		Tool_Completed{outcome = TOOL_OUTCOME_NAMES[.Success], detail = "grep hello", origin = "builtin_grep"},
		_body("ok\n\na.txt:1:hello"),
	)
	// A Lua child's call carries its parent call and no node, so a projection
	// over Assistant nodes never reads it, though its kind is one it selects.
	append_record(
		&j,
		Record{session = session, turn = 1, request = 1, call = 3, parent_call = 1, kind = .Tool_Proposed},
		Tool_Proposed{name = "grep"},
		_body(`{"pattern": "hello"}`),
	)
	append_record(
		&j,
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
		&j,
		Node{session = session, parent = assistant, branch = INITIAL_BRANCH, kind = .Results, turn = 1},
		Results{calls = {Call_Id(1), Call_Id(2)}},
		_body("two results"),
	)

	// A second turn answers the first, and it reports no cache write.
	append_record(
		&j,
		Record{session = session, turn = 2, kind = .Turn_Started},
		Turn_Started{instructions = digest_to_hex(second_digest, second_hex[:]), model = "gpt-5", effort = "low"},
	)
	second_user := append_node(
		&j,
		Node{session = session, parent = results, branch = INITIAL_BRANCH, kind = .User, turn = 2},
		User{origin = USER_ORIGIN_NAMES[.Steering]},
		_body("now summarize"),
	)
	append_record(
		&j,
		Record{session = session, turn = 2, request = 2, kind = .Request_Sent},
		Request_Sent{purpose = REQUEST_PURPOSE_NAMES[.Response], api = "responses", model_requested = "gpt-5"},
	)
	second_assistant := append_node(
		&j,
		Node{session = session, parent = second_user, branch = INITIAL_BRANCH, kind = .Assistant, turn = 2},
		Assistant{request = 2},
		_body("a.txt holds hello"),
	)
	append_record(
		&j,
		Record{session = session, turn = 2, request = 2, node = second_assistant, kind = .Response_Committed},
		Response_Committed {
			model_resolved = "gpt-5-2026",
			finish = RESPONSE_FINISH_NAMES[.Stop],
			input_tokens = 200,
			output_tokens = 30,
			cache_read_tokens = 150,
		},
	)

	// Two selections: the process-wide default, then the one this session
	// changed to.
	append_record(&j, Record{kind = .Selection_Changed}, Selection_Changed{provider = "anthropic", model = "claude-opus"})
	append_record(&j, Record{session = session, kind = .Selection_Changed}, Selection_Changed{provider = "openai", model = "gpt-5", effort = "high"})
	_commit_ok(t, &j)

	// An artifact reads back by the digest its record names.
	stored, stored_found, stored_err := read_artifact(&j, second_digest, context.allocator)
	_expect_ok(t, stored_err)
	defer delete(stored, context.allocator)
	testing.expect(t, stored_found, "a committed artifact should be there")
	testing.expect_value(t, string(stored), string(second_instructions))

	unknown_digest := Digest{}
	unknown_digest[0] = 1
	_, unknown_found, unknown_err := read_artifact(&j, unknown_digest, context.allocator)
	_expect_ok(t, unknown_err)
	testing.expect(t, !unknown_found, "an artifact that was never stored is not found")

	// The projection starts where the session is: its active branch and head.
	branch, head, head_err := session_head(&j, session)
	_expect_ok(t, head_err)
	testing.expect_value(t, branch, Branch_Id(INITIAL_BRANCH))
	testing.expect_value(t, head, second_assistant)

	ancestry, ancestry_err := read_ancestry(&j, session, head, context.allocator)
	_expect_ok(t, ancestry_err)
	defer nodes_destroy(ancestry, context.allocator)
	expected_kinds := [?]Node_Kind{.User, .Assistant, .Results, .User, .Assistant}
	expected_bodies := [?]string{"what is in this directory?", "let me look", "two results", "now summarize", "a.txt holds hello"}
	testing.expect_value(t, len(ancestry), len(expected_kinds))
	for node, i in ancestry {
		testing.expect_value(t, node.kind, expected_kinds[i])
		testing.expect_value(t, string(node.body), expected_bodies[i])
	}

	// A projection over the Assistant nodes reads their facts back in order.
	projection, _, projection_err := read_records(
		&j,
		Filter {
			session = session,
			nodes = []Node_Id{assistant, second_assistant},
			kinds = {.Tool_Proposed, .Tool_Admitted, .Tool_Completed, .Response_Committed},
		},
		0,
		0,
		context.allocator,
	)
	_expect_ok(t, projection_err)
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
	testing.expect_value(t, len(projection), len(projected_kinds))
	for record, i in projection {
		testing.expect_value(t, record.kind, projected_kinds[i])
		testing.expect_value(t, string(record.body), projected_bodies[i])
	}
	// Each call's records name the Assistant node that proposed it and the
	// request the response belongs to.
	for record in projection[:6] {
		testing.expect_value(t, record.node, assistant)
		testing.expect_value(t, record.request, Request_Id(1))
		testing.expect_value(t, record.turn, Turn_Id(1))
	}
	testing.expect_value(t, projection[0].call, Call_Id(1))
	testing.expect_value(t, projection[3].call, Call_Id(2))
	testing.expect_value(t, projection[6].node, assistant)
	testing.expect_value(t, projection[7].node, second_assistant)
	testing.expect_value(t, projection[6].request, Request_Id(1))
	testing.expect_value(t, projection[7].request, Request_Id(2))

	// The Lua child's call is not in the projection, and is read back by the
	// call it belongs to.
	child_records, _, child_err := read_records(&j, Filter{session = session, call = 3}, 0, 0, context.allocator)
	_expect_ok(t, child_err)
	defer records_destroy(child_records, context.allocator)
	testing.expect_value(t, len(child_records), 1)
	testing.expect_value(t, child_records[0].parent_call, Call_Id(1))
	testing.expect_value(t, child_records[0].node, Node_Id(0))

	// One call's records read back through the call correlation too.
	call_records, _, call_err := read_records(&j, Filter{session = session, call = 2}, 0, 0, context.allocator)
	_expect_ok(t, call_err)
	defer records_destroy(call_records, context.allocator)
	testing.expect_value(t, len(call_records), 3)

	// The payloads carry what a projection needs to rebuild the exchange.
	proposed: Tool_Proposed
	_decode_payload(t, projection[0].data, &proposed)
	testing.expect_value(t, proposed.name, "read")
	testing.expect_value(t, proposed.item_id, "item_1")
	admitted: Tool_Admitted
	_decode_payload(t, projection[1].data, &admitted)
	testing.expect_value(t, admitted.tool, "read")
	testing.expect_value(t, len(admitted.repairs), 1)
	completed: Tool_Completed
	_decode_payload(t, projection[2].data, &completed)
	testing.expect_value(t, completed.origin, "builtin_read")
	committed: Response_Committed
	_decode_payload(t, projection[6].data, &committed)
	testing.expect_value(t, committed.finish, RESPONSE_FINISH_NAMES[.Tool_Call])
	testing.expect_value(t, committed.cache_write_tokens.?, 5)
	answer: Assistant
	_decode_payload(t, ancestry[1].data, &answer)
	testing.expect_value(t, answer.request, Request_Id(1))
	testing.expect_value(t, len(answer.reasoning), 1)
	testing.expect_value(t, answer.reasoning[0].encrypted, "opaque")
	summary: Assistant
	_decode_payload(t, ancestry[4].data, &summary)
	testing.expect(t, !summary.partial, "a response that committed whole is not partial")
	prompt: User
	_decode_payload(t, ancestry[0].data, &prompt)
	testing.expect_value(t, prompt.origin, USER_ORIGIN_NAMES[.Prompt])
	steered: User
	_decode_payload(t, ancestry[3].data, &steered)
	testing.expect_value(t, steered.origin, USER_ORIGIN_NAMES[.Steering])

	// A count the provider never reported is not a zero in the totals.
	totals, totals_err := usage_totals(&j, session)
	_expect_ok(t, totals_err)
	testing.expect_value(t, totals.requests, 2)
	testing.expect_value(t, totals.paired_requests, 1)
	testing.expect_value(t, totals.input, 300)
	testing.expect_value(t, totals.output, 50)
	testing.expect_value(t, totals.cache_read, 190)
	testing.expect_value(t, totals.cache_write, 5)
	testing.expect_value(t, totals.paired_input, 100)
	testing.expect_value(t, totals.paired_read, 40)
	rate, rate_measured := cache_hit_rate(totals)
	testing.expect(t, rate_measured, "the paired requests report a hit rate")
	testing.expectf(t, math.abs(rate - 0.4) < 1e-9, "expected a hit rate of 0.4, got %v", rate)
	coverage, coverage_measured := cache_coverage(totals)
	testing.expect(t, coverage_measured, "the paired requests report a coverage")
	testing.expectf(t, math.abs(coverage - 1.0 / 3.0) < 1e-9, "expected a coverage of a third, got %v", coverage)

	// The latest record of a kind is the one that stands.
	latest, latest_found, latest_err := read_latest(&j, Filter{session = session, kinds = {.Selection_Changed}}, context.allocator)
	_expect_ok(t, latest_err)
	defer record_destroy(&latest, context.allocator)
	testing.expect(t, latest_found, "the session changed its selection")
	testing.expect_value(t, latest.session, session)
	selection: Selection_Changed
	_decode_payload(t, latest.data, &selection)
	testing.expect_value(t, selection.provider, "openai")
	testing.expect_value(t, selection.model, "gpt-5")
	testing.expect_value(t, selection.effort, "high")

	// The instructions of the latest turn are its digest, and the artifact it
	// names is what that turn ran with.
	started, started_found, started_err := read_latest(&j, Filter{session = session, kinds = {.Turn_Started}}, context.allocator)
	_expect_ok(t, started_err)
	defer record_destroy(&started, context.allocator)
	testing.expect(t, started_found, "the session started a turn")
	testing.expect_value(t, started.turn, Turn_Id(2))
	turn: Turn_Started
	_decode_payload(t, started.data, &turn)
	digest, digest_ok := digest_from_hex(turn.instructions)
	testing.expect(t, digest_ok, "a stored instruction digest parses")
	testing.expect_value(t, digest, second_digest)
	testing.expect_value(t, turn.model, "gpt-5")
	testing.expect_value(t, turn.effort, "low")

	// Nothing matched is not an error, and it is not a record.
	_, empty_found, empty_err := read_latest(&j, Filter{session = session, kinds = {.Session_Recovered}}, context.allocator)
	_expect_ok(t, empty_err)
	testing.expect(t, !empty_found, "a session that never recovered has no such record")

	// Selecting a branch moves the head to it, and a branch that holds no node
	// yet is at the node it forked from.
	fork := append_branch(&j, user)
	append_record(&j, Record{session = session, branch = fork, kind = .Branch_Selected}, Branch_Selected{})
	_commit_ok(t, &j)
	forked_branch, forked_head, forked_err := session_head(&j, session)
	_expect_ok(t, forked_err)
	testing.expect_value(t, forked_branch, fork)
	testing.expect_value(t, forked_head, user)

	forked := append_node(
		&j,
		Node{session = session, parent = user, branch = fork, kind = .User, turn = 3},
		User{origin = USER_ORIGIN_NAMES[.Harness]},
		_body("try again"),
	)
	_commit_ok(t, &j)
	_, moved_head, moved_err := session_head(&j, session)
	_expect_ok(t, moved_err)
	testing.expect_value(t, moved_head, forked)
}
