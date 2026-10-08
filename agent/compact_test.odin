#+test
package agent

import "core:mem/virtual"
import "core:testing"

import "nabla:agent/journal"
import "nabla:ai"

compact_call_item :: proc(node: journal.Node_Id, request: journal.Request_Id = 0) -> Projection_Item {
	return {
		node = node,
		request = request,
		payload = Projected_Call{call = journal.Call_Id(node), provider_id = "call_1", name = TOOL_SHELL_NAME, proposed = "{}", admitted = "{}"},
	}
}

compact_result_item :: proc(node: journal.Node_Id, request: journal.Request_Id = 0) -> Projection_Item {
	return {node = node, request = request, payload = Projected_Result{call = journal.Call_Id(node), outcome = .Success, content = "{}"}}
}

compact_user_item :: proc(node: journal.Node_Id, text: string) -> Projection_Item {
	return {node = node, payload = Projected_User{text = text, origin = .Prompt}}
}

@(test)
test_compact_seam_keeps_call_runs_together :: proc(test: ^testing.T) {
	items := []Projection_Item {
		compact_user_item(1, "a"),
		compact_call_item(2),
		compact_result_item(3),
		compact_user_item(4, "b"),
		{node = 5, payload = Projected_Assistant{text = "done"}},
	}
	testing.expect_value(test, chat_compact_seam(items, 3), 1)
	testing.expect_value(test, chat_compact_seam(items, 1), 4)
	plain := []Projection_Item{compact_user_item(1, "a"), {node = 2, payload = Projected_Assistant{text = "b"}}, compact_user_item(3, "c")}
	testing.expect_value(test, chat_compact_seam(plain, 1), 2)
}

@(test)
test_compact_seam_never_lands_inside_a_later_run :: proc(test: ^testing.T) {
	runs := []Projection_Item{compact_call_item(1), compact_result_item(2), compact_call_item(3), compact_result_item(4)}
	testing.expect_value(test, chat_compact_seam(runs, 1), 2)
	testing.expect_value(test, chat_compact_seam(runs, 3), 0)

	grouped := []Projection_Item{compact_user_item(1, "ask"), compact_call_item(2), compact_call_item(3), compact_result_item(4), compact_result_item(5)}
	testing.expect_value(test, chat_compact_seam(grouped, 3), 1)
}

@(test)
test_compact_seam_keeps_one_responses_request_together :: proc(test: ^testing.T) {
	request := journal.Request_Id(1)
	items := []Projection_Item {
		compact_user_item(1, "ask"),
		{node = 2, request = request, payload = Projected_Response{output = `[{"type":"function_call","call_id":"call_1","name":"shell","arguments":"{}"}]`}},
		compact_call_item(2, request),
		compact_result_item(3, request),
		compact_user_item(4, "next"),
	}
	testing.expect_value(test, chat_compact_seam(items, 2), 1)
	with_text := []Projection_Item {
		compact_user_item(1, "ask"),
		{node = 2, request = request, payload = Projected_Response{output = `[]`}},
		{node = 2, request = request, payload = Projected_Assistant{text = "working"}},
		compact_call_item(2, request),
		compact_result_item(3, request),
	}
	testing.expect_value(test, chat_compact_seam(with_text, 2), 1)
}

@(test)
test_a_summary_opens_the_request_before_the_kept_tail :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)

	items := []Projection_Item{compact_user_item(1, "kept question"), {node = 2, payload = Projected_Assistant{text = "kept answer"}}}
	prep: Chat_Request_Prep
	_ = chat_build_request_into(chat, &prep, items, "earlier work", tool_loop_connection, "", virtual.arena_allocator(&arena))
	testing.expect_value(test, len(prep.request.Messages), 3)
	testing.expect_value(test, prep.request.Messages[0].Role, ai.Provider_Role.User)
	testing.expect_value(test, prep.request.Messages[0].Content, "earlier work")
	testing.expect_value(test, prep.request.Messages[1].Content, "kept question")
	testing.expect_value(test, prep.request.Messages[2].Content, "kept answer")
}

@(test)
test_a_partial_answer_is_never_sent :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)

	_test_user(test, chat, "question", .Prompt)
	partial := "half an ans"
	chat_node(chat, .Assistant, journal.Assistant{partial = true}, transmute([]u8)partial)
	_test_commit(test, chat)
	projection := _test_projection(test, chat, &arena)
	prep: Chat_Request_Prep
	_ = chat_build_request_into(chat, &prep, projection.items, projection.summary, tool_loop_connection, "", virtual.arena_allocator(&arena))
	testing.expect_value(test, len(prep.request.Messages), 1)
	testing.expect_value(test, prep.request.Messages[0].Content, "question")
}

@(test)
test_a_compaction_request_shares_the_conversation_prefix :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW)
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)

	items := []Projection_Item{compact_user_item(1, "first")}
	prep: Chat_Request_Prep
	_ = chat_build_request_into(chat, &prep, items, "", tool_loop_connection, CHAT_COMPACT_DIRECTIVE, virtual.arena_allocator(&arena))

	testing.expect(test, prep.request.Instructions_Present)
	testing.expect_value(test, prep.request.Instructions, AGENT_SYSTEM_PROMPT)
	testing.expect(test, len(prep.request.Tools) > 0, "a compaction request keeps the conversation's tools")
	testing.expect_value(test, prep.request.Prompt_Cache_Key, chat_session_text(chat))
	testing.expect(test, prep.request.Max_Output_Tokens_Present)
	testing.expect_value(test, prep.request.Max_Output_Tokens, chat.capacity.model_max_output)
	if !testing.expect_value(test, len(prep.request.Messages), 2) { return }
	testing.expect_value(test, prep.request.Messages[0].Content, "first")
	testing.expect_value(test, prep.request.Messages[1].Content, CHAT_COMPACT_DIRECTIVE)
}

@(test)
test_a_provider_overflow_promotes_a_running_summary :: proc(test: ^testing.T) {
	testing.expect(test, compact_trigger_explicit(.Provider_Overflow), "a refused payload installs as soon as it can")

	running := Compact_Control {
		state   = .Running,
		trigger = .Pressure,
	}
	testing.expect_value(test, compact_request_intent(&running, .Provider_Overflow), Compact_Request_Result.Already_Scheduled)
	testing.expect_value(test, running.trigger, Compact_Trigger.Provider_Overflow)

	idle: Compact_Control
	testing.expect_value(test, compact_request_intent(&idle, .Provider_Overflow), Compact_Request_Result.Scheduled)
	testing.expect_value(test, idle.pending, Compact_Trigger.Provider_Overflow)
}
