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
	// The tail would split the call from its result, so the seam backs up
	// over both instead of honoring the keep count.
	testing.expect_value(t, chat_compact_seam(messages, 0, 3), 0)
	testing.expect_value(t, chat_compact_seam(messages, 0, 1), 4)
	plain := []Chat_Message{{role = .User, text = "a"}, {role = .Assistant, text = "b"}, {role = .User, text = "c"}}
	testing.expect_value(t, chat_compact_seam(plain, 0, 1), 2)
	testing.expect_value(t, chat_compact_seam(plain, 1, 10), 1)
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

	session.active_start = 2
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

	// A committed compaction appends the summary past the snapshot's end.
	append(&session.messages, Chat_Message{role = .Assistant, text = "Summary of the conversation so far:\nold stuff"})
	session.active_start = len(session.messages) - 1

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
