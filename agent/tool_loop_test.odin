#+test
package agent

import "core:os"
import "core:strings"
import "core:testing"
import "nabla:ai"


tool_loop_connection :: ai.Provider_Connection {
	API = .OpenAI_Chat_Completions,
}

tool_wire_cleanup :: proc(wire: ^[dynamic]ai.Provider_Message, tools: ^[dynamic]ai.Provider_Tool_Def, calls: ^[dynamic][dynamic]ai.Provider_Tool_Call) {
	for &slot in calls { delete(slot) }
	delete(calls^)
	delete(tools^)
	delete(wire^)
}

// tool_loop_begin_request mirrors the control loop: advancing to a request takes
// ownership of an operation, and only then can that operation's events be fed.
tool_loop_begin_request :: proc(session: ^Chat_Session) -> Chat_Effect {
	effect := chat_session_advance(session)
	chat_session_begin_operation(session)
	return effect
}

tool_loop_workspace :: proc(t: ^testing.T) -> string {
	workspace, err := os.get_working_directory(context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, workspace != "")
	return workspace
}

@(test)
test_build_request_carries_configured_max_output :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.max_output_tokens = 64
	testing.expect(t, chat_session_accept_user(&session, "hi"))

	effect := tool_loop_begin_request(&session)
	request, wire, tools_owned, call_lists := chat_build_request(&session, effect.request, tool_loop_connection, "model")
	testing.expect(t, request.Max_Output_Tokens_Present)
	testing.expect_value(t, request.Max_Output_Tokens, 64)
	tool_wire_cleanup(&wire, &tools_owned, &call_lists)
	chat_effect_destroy(&effect)
}

@(test)
test_build_request_keeps_reasoning_before_calls :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.tools_enabled = true
	testing.expect(t, chat_session_accept_user(&session, "run printf ok"))

	effect := tool_loop_begin_request(&session)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Start_Request)
	source := chat_session_event_source(&session)
	testing.expect(t, chat_session_feed_reasoning(&session, source, "rs_1", "enc_1"))
	// A repeated id is the same item, not a second one.
	testing.expect(t, chat_session_feed_reasoning(&session, source, "rs_1", "enc_1"))
	testing.expect(t, !chat_session_feed_reasoning(&session, source, "", "enc"))
	calls := []ai.Provider_Tool_Call {
		{ID = "call_1", Name = TOOL_SHELL_NAME, Arguments = `{"command":"printf tool-ok","working_directory":null,"timeout_ms":null}`},
	}
	testing.expect(t, chat_session_feed_tool_calls(&session, source, calls))

	view := chat_request_view_clone(session.messages[:], 1, context.temp_allocator)
	defer chat_request_view_destroy(&view)
	responses_connection := ai.Provider_Connection {
		API = .OpenAI_Responses,
	}
	request, wire, tools_owned, call_lists := chat_build_request(&session, view, responses_connection, "model-tools")
	testing.expect(t, len(request.Messages) == 4)
	testing.expect(t, request.Messages[0].Role == .System)
	testing.expect(t, request.Messages[1].Role == .User)
	testing.expect(t, request.Messages[2].Role == .Reasoning)
	testing.expect_value(t, request.Messages[2].Reasoning_ID, "rs_1")
	testing.expect_value(t, request.Messages[2].Reasoning_Encrypted, "enc_1")
	testing.expect(t, request.Messages[3].Role == .Assistant)
	testing.expect_value(t, len(request.Messages[3].Tool_Calls), 1)
	tool_wire_cleanup(&wire, &tools_owned, &call_lists)
	chat_effect_destroy(&effect)
}

@(test)
test_effort_selection_validates_levels :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	// No levels configured: only the default is selectable.
	testing.expect(t, chat_session_set_effort(&session, ""))
	testing.expect(t, !chat_session_set_effort(&session, "high"))

	append(&session.effort_levels, strings.clone("low", context.temp_allocator))
	append(&session.effort_levels, strings.clone("high", context.temp_allocator))
	testing.expect(t, chat_session_set_effort(&session, "high"))
	testing.expect_value(t, session.effort, "high")
	testing.expect(t, !chat_session_set_effort(&session, "max"))
	testing.expect_value(t, session.effort, "high")
	testing.expect(t, chat_session_set_effort(&session, ""))
	testing.expect_value(t, session.effort, "")
}

@(test)
test_build_request_carries_selected_effort :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	append(&session.effort_levels, strings.clone("high", context.temp_allocator))
	testing.expect(t, chat_session_set_effort(&session, "high"))
	testing.expect(t, chat_session_accept_user(&session, "hi"))

	effect := tool_loop_begin_request(&session)
	request, wire, tools_owned, call_lists := chat_build_request(&session, effect.request, tool_loop_connection, "model")
	testing.expect(t, request.Reasoning_Effort_Present)
	testing.expect_value(t, request.Reasoning_Effort, "high")
	tool_wire_cleanup(&wire, &tools_owned, &call_lists)
	chat_effect_destroy(&effect)

	testing.expect(t, chat_session_set_effort(&session, ""))
	effect = tool_loop_begin_request(&session)
	request, wire, tools_owned, call_lists = chat_build_request(&session, effect.request, tool_loop_connection, "model")
	testing.expect(t, !request.Reasoning_Effort_Present)
	tool_wire_cleanup(&wire, &tools_owned, &call_lists)
	chat_effect_destroy(&effect)
}

@(test)
test_admission_refuses_without_window_or_budget :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	message, admitted := chat_admission_check(&session, 100)
	testing.expect(t, !admitted)
	testing.expect(t, strings.contains(message, "context_window"))

	session.context_window = 500000
	message, admitted = chat_admission_check(&session, 100)
	testing.expect(t, admitted)

	// 490000 estimated plus default reserve plus margin does not fit 500000.
	message, admitted = chat_admission_check(&session, 490000)
	testing.expect(t, !admitted)
	testing.expect(t, strings.contains(message, "exceeds"))
	_ = message
}

@(test)
test_steered_turn_injects_before_request :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.context_window = 500000
	testing.expect(t, chat_session_accept_user(&session, "hi"))

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	testing.expect(t, steer_push(&queue, "steered"))
	quit := false
	steer := Steer_Context {
		queue       = &queue,
		quit        = &quit,
		provider_id = "p",
		model_id    = "m",
	}
	dead := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = "http://127.0.0.1:9/",
	}
	chat_run_turn_steered(&session, dead, "m", {}, &steer)

	found := false
	for message in session.messages {
		if message.role == .User && message.text == "steered" { found = true }
	}
	testing.expect(t, found)
	testing.expect(t, !quit)
	testing.expect_value(t, session.state, Chat_State.Idle)
}

@(test)
test_tool_loop_completes_turn :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.tools_enabled = true
	testing.expect(t, chat_session_accept_user(&session, "run printf ok"))

	effect := tool_loop_begin_request(&session)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Start_Request)
	operation := effect.request.operation
	request, wire, tools_owned, call_lists := chat_build_request(&session, effect.request, tool_loop_connection, "model-tools")
	testing.expect(t, len(request.Tools) == 1)
	testing.expect_value(t, request.Tools[0].Name, TOOL_SHELL_NAME)
	testing.expect(t, len(request.Messages) == 2)
	testing.expect(t, request.Messages[0].Role == .System)
	testing.expect(t, request.Messages[1].Role == .User)
	tool_wire_cleanup(&wire, &tools_owned, &call_lists)
	chat_effect_destroy(&effect)

	calls := []ai.Provider_Tool_Call {
		{ID = "call_1", Name = TOOL_SHELL_NAME, Arguments = `{"command":"printf tool-ok","working_directory":null,"timeout_ms":null}`},
	}
	testing.expect(t, chat_session_feed_tool_calls(&session, chat_session_event_source(&session), calls))

	effect = chat_session_advance(&session)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Run_Tools)
	testing.expect_value(t, effect.turn_id, session.active_turn_id)
	chat_effect_destroy(&effect)

	count := chat_execute_pending(&session, {})
	testing.expect_value(t, count, 1)
	testing.expect(t, chat_session_tools_done(&session, session.active_turn_id, count))
	testing.expect_value(t, len(session.messages), 3)
	testing.expect(t, session.messages[1].is_tool_call)
	testing.expect_value(t, session.messages[2].role, Chat_Role.Tool)
	testing.expect_value(t, session.messages[2].tool_call_id, "call_1")
	testing.expect(t, len(session.messages[2].text) > 0)

	effect = tool_loop_begin_request(&session)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Start_Request)
	testing.expect(t, effect.request.operation == operation + 1)
	request, wire, tools_owned, call_lists = chat_build_request(&session, effect.request, tool_loop_connection, "model-tools")
	testing.expect(t, len(request.Tools) == 1)
	testing.expect(t, len(request.Messages) == 4)
	testing.expect(t, request.Messages[3].Role == .Tool)
	testing.expect_value(t, request.Messages[3].Tool_Call_ID, "call_1")
	tool_wire_cleanup(&wire, &tools_owned, &call_lists)
	chat_effect_destroy(&effect)

	testing.expect(t, chat_session_feed_completion(&session, chat_session_event_source(&session)))
	effect = chat_session_advance(&session)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(t, effect.status, Chat_Terminal_Status.Completed)
	chat_effect_destroy(&effect)
	testing.expect_value(t, session.state, Chat_State.Idle)
}

@(test)
test_tool_loop_invalid_args_continues :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.tools_enabled = true
	testing.expect(t, chat_session_accept_user(&session, "bad call"))

	effect := tool_loop_begin_request(&session)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Start_Request)
	chat_effect_destroy(&effect)
	calls := []ai.Provider_Tool_Call{{ID = "call_bad", Name = TOOL_SHELL_NAME, Arguments = `{"command":"","working_directory":null,"timeout_ms":null}`}}
	testing.expect(t, chat_session_feed_tool_calls(&session, chat_session_event_source(&session), calls))
	effect = chat_session_advance(&session)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Run_Tools)
	chat_effect_destroy(&effect)

	count := chat_execute_pending(&session, {})
	testing.expect_value(t, count, 1)
	testing.expect(t, chat_session_tools_done(&session, session.active_turn_id, count))
	testing.expect_value(t, session.messages[2].role, Chat_Role.Tool)
	testing.expect_value(t, session.messages[2].tool_call_id, "call_bad")
	testing.expect(t, len(session.messages[2].text) > 0)

	effect = tool_loop_begin_request(&session)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Start_Request)
	chat_effect_destroy(&effect)
	testing.expect(t, chat_session_feed_completion(&session, chat_session_event_source(&session)))
	effect = chat_session_advance(&session)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(t, effect.status, Chat_Terminal_Status.Completed)
	chat_effect_destroy(&effect)
}

@(test)
test_tool_loop_nonzero_exit_continues :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.tools_enabled = true
	testing.expect(t, chat_session_accept_user(&session, "fail please"))

	effect := tool_loop_begin_request(&session)
	chat_effect_destroy(&effect)
	calls := []ai.Provider_Tool_Call{{ID = "call_fail", Name = TOOL_SHELL_NAME, Arguments = `{"command":"exit 3","working_directory":null,"timeout_ms":null}`}}
	testing.expect(t, chat_session_feed_tool_calls(&session, chat_session_event_source(&session), calls))
	effect = chat_session_advance(&session)
	chat_effect_destroy(&effect)
	count := chat_execute_pending(&session, {})
	testing.expect_value(t, count, 1)
	testing.expect(t, chat_session_tools_done(&session, session.active_turn_id, count))
	testing.expect_value(t, session.messages[2].tool_call_id, "call_fail")

	effect = tool_loop_begin_request(&session)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Start_Request)
	chat_effect_destroy(&effect)
	testing.expect(t, chat_session_feed_completion(&session, chat_session_event_source(&session)))
	effect = chat_session_advance(&session)
	testing.expect_value(t, effect.status, Chat_Terminal_Status.Completed)
	chat_effect_destroy(&effect)
}

@(test)
test_tool_loop_unknown_tool_reports_error :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.tools_enabled = true
	testing.expect(t, chat_session_accept_user(&session, "mystery"))

	effect := tool_loop_begin_request(&session)
	chat_effect_destroy(&effect)
	calls := []ai.Provider_Tool_Call{{ID = "call_x", Name = "nope", Arguments = `{}`}}
	testing.expect(t, chat_session_feed_tool_calls(&session, chat_session_event_source(&session), calls))
	effect = chat_session_advance(&session)
	chat_effect_destroy(&effect)
	count := chat_execute_pending(&session, {})
	testing.expect_value(t, count, 1)
	testing.expect(t, chat_session_tools_done(&session, session.active_turn_id, count))
	testing.expect_value(t, session.messages[2].tool_call_id, "call_x")
	testing.expect(t, len(session.messages[2].text) > 0)
}

@(test)
test_tool_loop_budget_exhausts :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.tools_enabled = true
	testing.expect(t, chat_session_accept_user(&session, "loop"))
	session.requests_made = TOOL_MAX_REQUESTS_PER_TURN
	done := chat_run_turn(&session, tool_loop_connection, "model-tools", {})
	testing.expect(t, !done)
	testing.expect_value(t, session.state, Chat_State.Idle)
}

@(test)
test_tool_loop_reports_usage_per_request :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	usages := make([dynamic]Chat_Request_Usage, 0, context.temp_allocator)
	defer delete(usages)
	runtime := Chat_Runtime_Context {
		session   = &session,
		usage_log = &usages,
	}
	chat_provider_event(
		&runtime,
		ai.Provider_Usage_Event{Input_Tokens = 12000, Input_Tokens_Present = true, Cached_Input_Tokens = 9000, Cached_Input_Tokens_Present = true},
	)
	chat_provider_event(
		&runtime,
		ai.Provider_Usage_Event{Input_Tokens = 12100, Input_Tokens_Present = true, Cached_Input_Tokens = 11800, Cached_Input_Tokens_Present = true},
	)
	testing.expect_value(t, len(usages), 2)
	testing.expect_value(t, usages[0].usage.Cached_Input_Tokens, 9000)
	testing.expect_value(t, usages[1].usage.Cached_Input_Tokens, 11800)
}
