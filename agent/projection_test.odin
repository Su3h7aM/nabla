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
}
