#+test
package agent

import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/session"
import "nabla:ai"

tool_loop_connection :: ai.Provider_Connection {
	API = .OpenAI_Chat_Completions,
}

tool_loop_workspace :: proc(t: ^testing.T) -> string {
	workspace, err := os.get_working_directory(context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, workspace != "")
	return workspace
}

@(test)
test_build_request_carries_configured_max_output :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.max_output_tokens = 64
	_test_accept(t, chat, "hi")

	prep, prep_err := chat_prepare(chat, tool_loop_connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)
	testing.expect(t, prep.request.Max_Output_Tokens_Present)
	testing.expect_value(t, prep.request.Max_Output_Tokens, 64)
}

@(test)
test_build_request_keeps_reasoning_before_calls :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "run printf ok")

	// The response produced reasoning and then a call. That order is what the
	// next request has to reproduce.
	_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.Reasoning_Entry{id = "rs_1", encrypted = "enc_1"}})
	_test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			created_at_ms = 2_000,
			payload = session.Tool_Call_Entry{call_id = "call_1", name = TOOL_SHELL_NAME, arguments = `{"command":"printf tool-ok"}`},
		},
	)

	prep, prep_err := chat_prepare(chat, tool_loop_connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)

	testing.expect_value(t, len(prep.request.Messages), 4)
	testing.expect_value(t, prep.request.Messages[0].Role, ai.Provider_Role.System)
	testing.expect_value(t, prep.request.Messages[1].Role, ai.Provider_Role.User)
	testing.expect_value(t, prep.request.Messages[2].Role, ai.Provider_Role.Reasoning)
	testing.expect_value(t, prep.request.Messages[2].Reasoning_ID, "rs_1")
	testing.expect_value(t, prep.request.Messages[2].Reasoning_Encrypted, "enc_1")
	testing.expect_value(t, prep.request.Messages[3].Role, ai.Provider_Role.Assistant)
	testing.expect_value(t, len(prep.request.Messages[3].Tool_Calls), 1)
}

@(test)
test_a_stored_result_names_its_call :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	_test_accept(t, chat, "run it")

	call_seq := _test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			created_at_ms = 2_000,
			payload = session.Tool_Call_Entry{call_id = "call_1", name = TOOL_SHELL_NAME, arguments = `{"command":"ls"}`},
		},
	)
	_test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			created_at_ms = 2_001,
			related_seq = call_seq,
			payload = session.Tool_Result_Entry{outcome = .Exited, exit_code = 0, content = `{"status":"exited"}`, origin = .Observed},
		},
	)

	prep, prep_err := chat_prepare(chat, tool_loop_connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)

	// The tool result message carries the call id the call was stored under, and
	// the call and its result travel together in one assistant/tool pair.
	testing.expect_value(t, len(prep.request.Messages), 3)
	testing.expect_value(t, prep.request.Messages[1].Role, ai.Provider_Role.Assistant)
	testing.expect_value(t, len(prep.request.Messages[1].Tool_Calls), 1)
	testing.expect_value(t, prep.request.Messages[1].Tool_Calls[0].ID, "call_1")
	testing.expect_value(t, prep.request.Messages[2].Role, ai.Provider_Role.Tool)
	testing.expect_value(t, prep.request.Messages[2].Tool_Call_ID, "call_1")
}

@(test)
test_effort_selection_validates_levels :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat

	// No levels configured: only the default is selectable.
	testing.expect(t, chat_session_set_effort(chat, ""))
	testing.expect(t, !chat_session_set_effort(chat, "high"))

	append(&chat.effort_levels, strings.clone("low", chat.allocator))
	append(&chat.effort_levels, strings.clone("high", chat.allocator))
	testing.expect(t, chat_session_set_effort(chat, "high"))
	testing.expect_value(t, chat.effort, "high")
	testing.expect(t, !chat_session_set_effort(chat, "max"))
	testing.expect_value(t, chat.effort, "high")
	testing.expect(t, chat_session_set_effort(chat, ""))
	testing.expect_value(t, chat.effort, "")
}

@(test)
test_build_request_carries_selected_effort :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	append(&chat.effort_levels, strings.clone("high", chat.allocator))
	testing.expect(t, chat_session_set_effort(chat, "high"))
	_test_accept(t, chat, "hi")

	prep, prep_err := chat_prepare(chat, tool_loop_connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	testing.expect(t, prep.request.Reasoning_Effort_Present)
	testing.expect_value(t, prep.request.Reasoning_Effort, "high")
	chat_request_prep_destroy(&prep, chat.allocator)

	testing.expect(t, chat_session_set_effort(chat, ""))
	prep, prep_err = chat_prepare(chat, tool_loop_connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)
	testing.expect(t, !prep.request.Reasoning_Effort_Present)
}

@(test)
test_admission_refuses_without_window_or_budget :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat

	message, admitted := chat_admission_check(chat, 100)
	testing.expect(t, !admitted)
	testing.expect(t, strings.contains(message, "context_window"))

	chat.context_window = 500000
	_, admitted = chat_admission_check(chat, 100)
	testing.expect(t, admitted)

	// 490000 estimated plus default reserve plus margin does not fit 500000.
	message, admitted = chat_admission_check(chat, 490000)
	testing.expect(t, !admitted)
	testing.expect(t, strings.contains(message, "exceeds"))
	_ = message
}

@(test)
test_steered_line_is_recorded_before_the_request :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.context_window = 500000
	_test_accept(t, chat, "hi")

	// Steering is admitted at a request boundary and recorded as a user entry in
	// the turn that is already running.
	testing.expect(t, chat_session_steer(chat, "steered", session.now_ms()))

	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	found := false
	for entry in ctx.entries {
		if user, is_user := entry.payload.(session.User_Entry); is_user && user.text == "steered" {
			found = true
			testing.expect_value(t, user.origin, session.User_Origin.Steering)
		}
	}
	testing.expect(t, found, "the steering line should be part of the context")
}

@(test)
test_tool_calls_are_recorded_then_run :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "run printf ok")

	// The response committed a call; the driver now runs it. The call entry, the
	// dispatch, and the result are three separate records.
	call_seq := _test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			created_at_ms = 2_000,
			payload = session.Tool_Call_Entry {
				call_id = "call_1",
				name = TOOL_SHELL_NAME,
				arguments = `{"command":"printf tool-ok","working_directory":null,"timeout_ms":null}`,
			},
		},
	)
	append(
		&chat.pending_calls,
		Chat_Tool_Call {
			id = chat_clone_string("call_1", chat.allocator),
			name = chat_clone_string(TOOL_SHELL_NAME, chat.allocator),
			arguments = chat_clone_string(`{"command":"printf tool-ok","working_directory":null,"timeout_ms":null}`, chat.allocator),
			seq = call_seq,
		},
	)
	chat.state = .Executing_Tools

	count := chat_run_tools(chat, {})
	testing.expect_value(t, count, 1)
	testing.expect(t, chat_session_tools_done(chat, chat.active_turn_id, count))

	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	if !testing.expect_value(t, len(entries), 4) { return }
	testing.expect_value(t, entries[0].kind, session.Entry_Kind.User)
	testing.expect_value(t, entries[1].kind, session.Entry_Kind.Tool_Call)
	testing.expect_value(t, entries[2].kind, session.Entry_Kind.Tool_Dispatch)
	testing.expect_value(t, entries[3].kind, session.Entry_Kind.Tool_Result)

	dispatch, is_dispatch := entries[2].payload.(session.Tool_Dispatch_Entry)
	if !testing.expect(t, is_dispatch, "the third entry should be a dispatch") { return }
	testing.expect_value(t, dispatch.tool, TOOL_SHELL_NAME)

	result, is_result := entries[3].payload.(session.Tool_Result_Entry)
	if !testing.expect(t, is_result, "the fourth entry should be a result") { return }
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Exited)
	testing.expect_value(t, result.origin, session.Tool_Result_Origin.Observed)
	testing.expect(t, strings.contains(result.content, "tool-ok"), "the model-visible result should carry the output")

	for entry in entries[2:] {
		related, present := entry.related_seq.?
		if !testing.expect(t, present, "a dispatch and result must name their call") { return }
		testing.expect_value(t, related, call_seq)
	}
}

@(test)
test_invalid_arguments_get_a_result_without_a_dispatch :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "bad call")

	call_seq := _test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			created_at_ms = 2_000,
			payload = session.Tool_Call_Entry{call_id = "call_bad", name = TOOL_SHELL_NAME, arguments = `{"command":""}`},
		},
	)
	append(
		&chat.pending_calls,
		Chat_Tool_Call {
			id = chat_clone_string("call_bad", chat.allocator),
			name = chat_clone_string(TOOL_SHELL_NAME, chat.allocator),
			arguments = chat_clone_string(`{"command":""}`, chat.allocator),
			seq = call_seq,
		},
	)
	chat.state = .Executing_Tools

	count := chat_run_tools(chat, {})
	testing.expect_value(t, count, 1)
	chat_session_tools_done(chat, chat.active_turn_id, count)

	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	// A rejected call never ran, so there is no dispatch: the prompt, the call, and
	// the result that explains why nothing happened.
	if !testing.expect_value(t, len(entries), 3) { return }
	testing.expect_value(t, entries[1].kind, session.Entry_Kind.Tool_Call)
	testing.expect_value(t, entries[2].kind, session.Entry_Kind.Tool_Result)
	result, is_result := entries[2].payload.(session.Tool_Result_Entry)
	if !testing.expect(t, is_result, "the second entry should be a result") { return }
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Invalid_Arguments)
}

@(test)
test_unknown_tool_is_reported_not_run :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "mystery")

	call_seq := _test_append(
		t,
		chat,
		{turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.Tool_Call_Entry{call_id = "call_x", name = "nope", arguments = "{}"}},
	)
	append(
		&chat.pending_calls,
		Chat_Tool_Call {
			id = chat_clone_string("call_x", chat.allocator),
			name = chat_clone_string("nope", chat.allocator),
			arguments = chat_clone_string("{}", chat.allocator),
			seq = call_seq,
		},
	)
	chat.state = .Executing_Tools

	count := chat_run_tools(chat, {})
	testing.expect_value(t, count, 1)
	chat_session_tools_done(chat, chat.active_turn_id, count)

	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	result, is_result := entries[len(entries) - 1].payload.(session.Tool_Result_Entry)
	if !testing.expect(t, is_result, "the last entry should be a result") { return }
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Invalid_Arguments)
}

@(test)
test_tool_loop_budget_exhausts :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "loop")
	chat.requests_made = TOOL_MAX_REQUESTS_PER_TURN

	done := chat_run_turn(chat, tool_loop_connection, {})
	testing.expect(t, !done)

	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	// The turn is closed as a failure, and the prompt it admitted stays.
	if !testing.expect_value(t, len(entries), 1) { return }
	testing.expect_value(t, entries[0].kind, session.Entry_Kind.User)
}

@(test)
test_the_first_prompt_names_the_session :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat

	// The title is the first line of the prompt that opened the session.
	_test_accept(t, chat, "explain the parser\nand then stop")
	header, header_err := session.session_load(chat.store, chat.id, context.allocator)
	if header_err != nil { testing.fail_now(t, "session_load failed") }
	testing.expect_value(t, header.title, "explain the parser")
	session.session_destroy(&header)

	effect := _test_begin_request(t, chat)
	chat_effect_destroy(&effect)
	testing.expect(t, chat_session_feed_completion(chat, chat_session_event_source(chat)))
	finish := _test_settle(t, chat)
	chat_effect_destroy(&finish)

	// A later turn leaves the name alone.
	_test_accept(t, chat, "something else")
	reloaded, reload_err := session.session_load(chat.store, chat.id, context.allocator)
	if reload_err != nil { testing.fail_now(t, "session_load failed") }
	defer session.session_destroy(&reloaded)
	testing.expect_value(t, reloaded.title, "explain the parser")
}

@(test)
test_status_reports_what_the_session_already_knows :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.context_window = 200_000
	chat.max_output_tokens = 4_096
	chat.tools_enabled = true
	_test_accept(t, chat, "explain the parser")

	log := Status_Log {
		buffer = strings.builder_make(context.temp_allocator),
	}
	defer strings.builder_destroy(&log.buffer)
	observer := Chat_Observer {
		user_data = &log,
		message   = status_log_message,
	}
	chat_notice_status(chat, observer, session.now_ms())

	report := strings.to_string(log.buffer)
	testing.expect(t, strings.contains(report, "explain the parser"), "the session's own title should be reported")
	testing.expect(t, strings.contains(report, chat.workspace), "the working directory should be reported")
	testing.expect(t, strings.contains(report, "test-provider / test-model"), "the model should be reported")
	testing.expect(t, strings.contains(report, "200000 window"), "the context budget should be reported")
	testing.expect(t, strings.contains(report, "shell"), "the tool set should be reported")
	// The age counts from creation and includes the time the harness was closed,
	// so it is labelled as age rather than as time spent working.
	testing.expect(t, strings.contains(report, "age"), "the age should be labelled")
	testing.expect(t, !strings.contains(report, "running"), "the age is not time spent working")
}

@(test)
test_age_text_reads_in_two_units :: proc(t: ^testing.T) {
	testing.expect_value(t, chat_age_text(5_000), "5s")
	testing.expect_value(t, chat_age_text(90_000), "1m 30s")
	testing.expect_value(t, chat_age_text(3 * 3_600_000 + 5 * 60_000), "3h 5m")
	testing.expect_value(t, chat_age_text(2 * 86_400_000 + 3 * 3_600_000), "2d 3h")
}

// A response commits its tool calls and then the harness dispatches them. A
// process that dies between those two writes leaves a call with neither a
// dispatch nor a result, and recovery has to close it, because the provider is
// sent the call and its result together.
@(test)
test_a_recovered_call_reaches_the_model_answered :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat.context_window = 200_000
	_test_accept(t, chat, "run it")
	_test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			created_at_ms = 2_000,
			payload = session.Tool_Call_Entry{call_id = "call_1", name = TOOL_SHELL_NAME, arguments = `{"command":"echo hi"}`},
		},
	)

	recovery, recover_err := session.session_recover(
		chat.store,
		chat.id,
		{at_ms = session.now_ms(), recovered_content = TOOL_RECOVERED_RESULT, unexecuted_content = TOOL_UNEXECUTED_RESULT},
	)
	if recover_err != nil { testing.fail_now(t, "recovery failed") }
	testing.expect_value(t, recovery.unexecuted_calls, 1)

	prep, prep_err := chat_prepare(chat, tool_loop_connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)

	// The call and its recovered result are adjacent, and the result names the
	// call it answers.
	calls_opened := 0
	answered := false
	call_id := ""
	for message in prep.wire {
		if len(message.Tool_Calls) > 0 {
			calls_opened += 1
			call_id = message.Tool_Calls[0].ID
		}
		if message.Role == .Tool && strings.contains(message.Content, `"status":"not_executed"`) {
			answered = true
			testing.expect_value(t, message.Tool_Call_ID, call_id)
		}
	}
	testing.expect_value(t, calls_opened, 1)
	testing.expect(t, answered, "the recovered call must reach the model with a result")
}

@(test)
test_usage_is_collected_per_request :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat

	usages := make([dynamic]Chat_Request_Usage, 0, context.temp_allocator)
	defer delete(usages)
	runtime := Chat_Runtime_Context {
		chat      = chat,
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

	// The last measurement wins, and a field the provider never sent stays absent.
	total := chat_request_usage(&usages, 0)
	if value, present := total.input.?; present {
		testing.expect_value(t, value, i64(12100))
	} else {
		testing.fail_now(t, "reported input tokens should be recorded")
	}
	if _, present := total.cache_write.?; present {
		testing.fail_now(t, "an unreported measurement must stay unknown")
	}
}
