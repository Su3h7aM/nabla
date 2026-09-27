#+test
#+private file
package journal

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
