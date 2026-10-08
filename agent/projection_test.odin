#+test
#+private file
package agent

import "core:fmt"
import "core:mem/virtual"
import "core:testing"

import "nabla:agent/journal"

@(test)
test_projection_keeps_only_children_of_projected_parents_in_a_long_history :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	store := &fixture.store
	session := fixture.chat.session
	branch := fixture.chat.branch
	excluded := journal.append_node(store, {session = session, branch = branch, kind = .Assistant}, journal.Assistant{request = 1})
	excluded_parent := journal.next_call(store)
	journal.append_record(
		store,
		{kind = .Tool_Proposed, session = session, node = excluded, call = excluded_parent},
		journal.Tool_Proposed{provider_id = "excluded", name = TOOL_CODEMODE_NAME},
		transmute([]u8)string(`{"code":"return 0"}`),
	)
	head := journal.append_node(store, {session = session, branch = branch, kind = .Assistant}, journal.Assistant{request = 2})
	PARENT_CALLS :: 4_000
	last_parent: journal.Call_Id
	for _ in 0 ..< PARENT_CALLS {
		last_parent = journal.next_call(store)
		journal.append_record(
			store,
			{kind = .Tool_Proposed, session = session, node = head, call = last_parent},
			journal.Tool_Proposed{provider_id = fmt.tprintf("call_%d", last_parent), name = TOOL_CODEMODE_NAME},
			transmute([]u8)string(`{"code":"return tools.read({path = \"a.odin\"})"}`),
		)
	}
	parents := [2]journal.Call_Id{excluded_parent, last_parent}
	for parent in parents {
		child := journal.next_call(store)
		journal.append_record(
			store,
			{kind = .Tool_Proposed, session = session, call = child, parent_call = parent},
			journal.Tool_Proposed{provider_id = "child", name = "read"},
			transmute([]u8)string(`{"path":"a.odin"}`),
		)
		journal.append_record(
			store,
			{kind = .Tool_Completed, session = session, call = child, parent_call = parent},
			journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]},
			transmute([]u8)string("ok\n\nhello"),
		)
	}
	if _, error := journal.commit(store); error != nil { testing.fail_now(test, "history commit failed") }
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { testing.fail_now(test, "projection arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	projection, error := projection_load(store, session, head, virtual.arena_allocator(&arena))
	if !testing.expect(test, error == nil, "a long Code Mode history must remain readable") { return }
	testing.expect_value(test, len(projection.items), PARENT_CALLS)
	if !testing.expect_value(test, len(projection.nested), 1) { return }
	testing.expect_value(test, projection.nested[0].parent_call, last_parent)
	testing.expect_value(test, projection.nested[0].name, "read")
	testing.expect_value(test, projection.nested[0].content, "ok\n\nhello")
	testing.expect(test, projection.nested[0].settled, "a child with a completion is settled")
}

// A completion whose Results node is not committed yet answers its call in unanswered, an
// unreadable one is left out without failing the load, and a child that has not completed
// is listed unsettled in proposal order.
@(test)
test_projection_lists_unanswered_calls_and_unsettled_children :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	store := &fixture.store
	session := fixture.chat.session
	head := journal.append_node(store, {session = session, branch = fixture.chat.branch, kind = .Assistant}, journal.Assistant{request = 1})
	answered := journal.next_call(store)
	unreadable := journal.next_call(store)
	script := journal.next_call(store)
	names := [3]string{"shell", "shell", TOOL_CODEMODE_NAME}
	for call, index in ([3]journal.Call_Id{answered, unreadable, script}) {
		journal.append_record(
			store,
			{kind = .Tool_Proposed, session = session, node = head, call = call},
			journal.Tool_Proposed{provider_id = fmt.tprintf("call_%d", call), name = names[index]},
			transmute([]u8)string(`{}`),
		)
	}
	journal.append_record(
		store,
		{kind = .Tool_Completed, session = session, node = head, call = answered},
		journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]},
		transmute([]u8)string("ok"),
	)
	journal.append_record(
		store,
		{kind = .Tool_Completed, session = session, node = head, call = unreadable},
		journal.Tool_Completed{outcome = "no such outcome"},
		transmute([]u8)string("?"),
	)
	children: [2]journal.Call_Id
	for &child in children {
		child = journal.next_call(store)
		journal.append_record(
			store,
			{kind = .Tool_Proposed, session = session, call = child, parent_call = script},
			journal.Tool_Proposed{provider_id = "child", name = "read"},
			transmute([]u8)string(`{"path":"a.odin"}`),
		)
	}
	journal.append_record(
		store,
		{kind = .Tool_Completed, session = session, call = children[1], parent_call = script},
		journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]},
		transmute([]u8)string("ok"),
	)
	if _, error := journal.commit(store); error != nil { testing.fail_now(test, "history commit failed") }
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { testing.fail_now(test, "projection arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	projection, error := projection_load(store, session, head, virtual.arena_allocator(&arena))
	if !testing.expect(test, error == nil, "an unreadable display-only completion must not fail the load") { return }
	if !testing.expect_value(test, len(projection.unanswered), 1) { return }
	testing.expect_value(test, projection.unanswered[0].call, answered)
	if !testing.expect_value(test, len(projection.nested), 2) { return }
	testing.expect_value(test, projection.nested[0].call, children[0])
	testing.expect(test, !projection.nested[0].settled, "a child without a completion is unsettled")
	testing.expect_value(test, projection.nested[1].call, children[1])
	testing.expect(test, projection.nested[1].settled, "a child with a completion is settled")
}

// A window that starts at a Results node whose Assistant node is outside it, and ends at
// an Assistant node whose Results node is outside it, loads: the first Results node's
// calls are skipped and the last Assistant node's calls keep their completions.
@(test)
test_projection_load_nodes_accepts_a_window_cut_through_tool_exchanges :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	store := &fixture.store
	session := fixture.chat.session
	branch := fixture.chat.branch
	exchange_calls: [2]journal.Call_Id
	assistants: [2]journal.Node_Id
	parent := journal.Node_Id(0)
	for index in 0 ..< 2 {
		assistants[index] = journal.append_node(
			store,
			{session = session, parent = parent, branch = branch, kind = .Assistant},
			journal.Assistant{request = journal.Request_Id(index + 1)},
		)
		call := journal.next_call(store)
		exchange_calls[index] = call
		journal.append_record(
			store,
			{kind = .Tool_Proposed, session = session, node = assistants[index], call = call},
			journal.Tool_Proposed{provider_id = fmt.tprintf("call_%d", call), name = "shell"},
			transmute([]u8)string(`{}`),
		)
		journal.append_record(
			store,
			{kind = .Tool_Completed, session = session, node = assistants[index], call = call},
			journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]},
			transmute([]u8)string("ok"),
		)
		if index == 0 {
			parent = journal.append_node(
				store,
				{session = session, parent = assistants[index], branch = branch, kind = .Results},
				journal.Results{calls = {call}},
			)
		} else {
			parent = assistants[index]
		}
	}
	if _, error := journal.commit(store); error != nil { testing.fail_now(test, "history commit failed") }

	// The window is the first Results node and the second Assistant node.
	path, path_error := journal.read_path(store, session, assistants[1], context.allocator)
	if path_error != nil { testing.fail_now(test, "path read failed") }
	defer delete(path)
	if !testing.expect_value(test, len(path), 3) { return }
	window, window_error := journal.read_nodes(store, session, path[1:], context.allocator)
	if window_error != nil { testing.fail_now(test, "window read failed") }
	defer journal.nodes_destroy(window, context.allocator)
	testing.expect_value(test, window[0].kind, journal.Node_Kind.Results)

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { testing.fail_now(test, "projection arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	projection, error := projection_load_nodes(store, session, window, virtual.arena_allocator(&arena))
	if !testing.expect(test, error == nil, "a window cut through tool exchanges must load") { return }
	testing.expect_value(test, projection.head, assistants[1])
	if !testing.expect_value(test, len(projection.items), 1) { return }
	call, is_call := projection.items[0].payload.(Projected_Call)
	testing.expect(test, is_call && call.call == exchange_calls[1], "the call inside the window is kept")
	if !testing.expect_value(test, len(projection.unanswered), 1) { return }
	testing.expect_value(test, projection.unanswered[0].call, exchange_calls[1])
}
