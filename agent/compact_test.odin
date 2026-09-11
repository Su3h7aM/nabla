#+test
package agent

import "core:strings"
import "core:testing"
import "nabla:ai"

compact_call_message :: proc(id: string, allocator := context.temp_allocator) -> Chat_Message {
	return Chat_Message{role = .Assistant, is_tool_call = true, tool_call = Chat_Tool_Call{id = id, name = "shell", arguments = `{}`}}
}

@(test)
test_compact_seam_keeps_call_runs_together :: proc(t: ^testing.T) {
	messages := []Chat_Message {
		{role = .User, text = "a"},
		compact_call_message("call_1"),
		{role = .Tool, text = `{"status":"exited"}`, tool_call_id = "call_1"},
		{role = .User, text = "b"},
		{role = .Assistant, text = "done"},
	}
	// The tail would split the call from its result, so the seam backs up over
	// the result and stops on the call: the pair stays together in the tail
	// instead of the whole window collapsing into the summary.
	testing.expect_value(t, chat_compact_seam(messages, 0, 3), 1)
	testing.expect_value(t, chat_compact_seam(messages, 0, 1), 4)
	plain := []Chat_Message{{role = .User, text = "a"}, {role = .Assistant, text = "b"}, {role = .User, text = "c"}}
	testing.expect_value(t, chat_compact_seam(plain, 0, 1), 2)
	testing.expect_value(t, chat_compact_seam(plain, 1, 10), 1)
}

@(test)
test_compact_seam_never_lands_inside_a_later_run :: proc(t: ^testing.T) {
	// Two runs in one window: backing only over results stops on call_2, which
	// keeps both runs whole. Backing over the call as well would strand result_1
	// in the tail without call_1.
	runs := []Chat_Message {
		compact_call_message("call_1"),
		{role = .Tool, text = `{"status":"exited"}`, tool_call_id = "call_1"},
		compact_call_message("call_2"),
		{role = .Tool, text = `{"status":"exited"}`, tool_call_id = "call_2"},
	}
	testing.expect_value(t, chat_compact_seam(runs, 0, 1), 2)
	testing.expect_value(t, chat_compact_seam(runs, 0, 3), 0)

	// A seam whose predecessor is a call backs up too, so a multi-call run is
	// never cut between its calls.
	grouped := []Chat_Message {
		{role = .User, text = "ask"},
		compact_call_message("call_1"),
		compact_call_message("call_2"),
		{role = .Tool, text = `{}`, tool_call_id = "call_1"},
		{role = .Tool, text = `{}`, tool_call_id = "call_2"},
	}
	testing.expect_value(t, chat_compact_seam(grouped, 0, 3), 1)
}

// chat_compact_commit is the whole post-compaction window: the summary in front
// of the kept tail. This is the behaviour the model sees, so it is pinned
// directly rather than through a summarization request.
@(test)
test_compact_commit_keeps_the_tail_in_the_active_window :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	testing.expect(t, chat_session_accept_user(&session, "first"))
	for text in ([]string{"early", "middle"}) {
		append(&session.messages, Chat_Message{role = .Assistant, text = chat_clone_string(text, session.allocator)})
	}

	// Summarize everything before the last two messages, which is what
	// compact_active computes when the seam lands ahead of the kept tail.
	chat_compact_commit(&session, len(session.messages) - 2, "earlier work")
	testing.expect_value(t, session.active_start, 1)
	testing.expect_value(t, len(session.messages), 4)

	fresh, request, wire, tools_owned, call_lists := chat_build_from_active(&session, tool_loop_connection, "model")
	defer chat_request_view_destroy(&fresh)
	defer tool_wire_cleanup(&wire, &tools_owned, &call_lists)
	testing.expect_value(t, len(request.Messages), 3)
	testing.expect(t, strings.has_prefix(request.Messages[0].Content, "Summary of the conversation so far:"))
	testing.expect_value(t, request.Messages[1].Content, "early")
	testing.expect_value(t, request.Messages[2].Content, "middle")
}

@(test)
test_build_request_starts_at_active_window :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	testing.expect(t, chat_session_accept_user(&session, "first"))
	effect := tool_loop_begin_request(&session)
	chat_effect_destroy(&effect)
	testing.expect(t, chat_session_feed_completion(&session, chat_session_event_source(&session)))
	finish := chat_session_advance(&session)
	testing.expect_value(t, finish.kind, Chat_Effect_Kind.Turn_Finished)
	chat_effect_destroy(&finish)
	testing.expect(t, chat_session_accept_user(&session, "second"))

	session.active_start = len(session.messages) - 1
	effect = tool_loop_begin_request(&session)
	request, wire, tools_owned, call_lists := chat_build_request(&session, effect.request, tool_loop_connection, "model")
	testing.expect_value(t, len(request.Messages), 1)
	testing.expect_value(t, request.Messages[0].Content, "second")
	tool_wire_cleanup(&wire, &tools_owned, &call_lists)
	chat_effect_destroy(&effect)
}

@(test)
test_build_compact_request_has_no_tools :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.tools_enabled = true
	testing.expect(t, chat_session_accept_user(&session, "first"))

	effect := tool_loop_begin_request(&session)
	request, wire, tools_owned, call_lists := chat_build_request(&session, effect.request, tool_loop_connection, "model", true)
	testing.expect_value(t, len(request.Tools), 0)
	testing.expect(t, request.Max_Output_Tokens_Present)
	testing.expect_value(t, request.Max_Output_Tokens, CHAT_COMPACT_MAX_OUTPUT)
	testing.expect(t, !request.Reasoning_Effort_Present)
	testing.expect(t, len(request.Messages) == 2)
	testing.expect(t, request.Messages[0].Role == .System)
	testing.expect_value(t, request.Messages[1].Content, "first")
	tool_wire_cleanup(&wire, &tools_owned, &call_lists)
	chat_effect_destroy(&effect)
}

@(test)
test_rebuild_after_compact_uses_committed_history :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	testing.expect(t, chat_session_accept_user(&session, "first"))
	stale := chat_request_view_clone(session.messages[:], 0, context.temp_allocator)
	defer chat_request_view_destroy(&stale)

	// A committed compaction installs the summary ahead of the kept tail.
	chat_compact_commit(&session, len(session.messages), "old stuff")

	stale_request, stale_wire, stale_tools, stale_calls := chat_build_request(&session, stale, tool_loop_connection, "model")
	testing.expect_value(t, ai.Provider_Validate_Request(stale_request), ai.Provider_Request_Error.Missing_Messages)
	tool_wire_cleanup(&stale_wire, &stale_tools, &stale_calls)

	fresh, request, wire, tools_owned, call_lists := chat_build_from_active(&session, tool_loop_connection, "model")
	testing.expect_value(t, ai.Provider_Validate_Request(request), ai.Provider_Request_Error.None)
	testing.expect_value(t, len(request.Messages), 1)
	testing.expect(t, strings.has_prefix(request.Messages[0].Content, "Summary of the conversation so far:"))
	tool_wire_cleanup(&wire, &tools_owned, &call_lists)
	chat_request_view_destroy(&fresh)
}

@(test)
test_compact_failure_leaves_history_untouched :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.context_window = 500000
	testing.expect(t, chat_session_accept_user(&session, "first"))
	dead := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = "http://127.0.0.1:9/",
	}

	testing.expect(t, !chat_command_compact(&session, {}, dead, "m", nil))
	testing.expect_value(t, len(session.messages), 1)
	testing.expect_value(t, session.active_start, 0)
}

@(test)
test_auto_compact_runs_once_per_turn :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	dead := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = "http://127.0.0.1:9/",
	}

	// No window configured: never attempt, so no transport is touched.
	testing.expect(t, !chat_maybe_auto_compact(&session, {}, dead, "m", nil))

	session.context_window = 500000
	testing.expect(t, chat_session_accept_user(&session, "first"))
	session.auto_compacted_turn = session.active_turn_id
	testing.expect(t, !chat_maybe_auto_compact(&session, {}, dead, "m", nil))
	testing.expect_value(t, session.requests_made, 0)
}
