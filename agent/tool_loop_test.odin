#+test
package agent

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "nabla:agent/session"
import "nabla:ai"

// item_object and item_string read the encoded request body the way a provider
// would: by item type, role, and field. They exist so a test can assert wire
// order and absence of duplicates instead of asserting a struct it built itself.
@(private)
item_object :: proc(t: ^testing.T, items: json.Array, index: int) -> json.Object {
	object, ok := items[index].(json.Object)
	testing.expect(t, ok)
	return object
}

@(private)
item_string :: proc(object: json.Object, key: string) -> string {
	value, present := object[key]
	if !present { return "" }
	text, ok := value.(json.String)
	if !ok { return "" }
	return string(text)
}

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
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
	testing.expect_value(t, result.origin, session.Tool_Result_Origin.Observed)
	testing.expect(t, strings.contains(result.content, "tool-ok"), "the model-visible result should carry the output")

	for entry in entries[2:] {
		related, present := entry.related_seq.?
		if !testing.expect(t, present, "a dispatch and result must name their call") { return }
		testing.expect_value(t, related, call_seq)
	}
}

@(test)
test_invalid_arguments_get_a_dispatch_and_result :: proc(t: ^testing.T) {
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
	// Dispatch records the effective arguments before execution. The result then
	// records that validation refused the call before any effect.
	if !testing.expect_value(t, len(entries), 4) { return }
	testing.expect_value(t, entries[1].kind, session.Entry_Kind.Tool_Call)
	testing.expect_value(t, entries[2].kind, session.Entry_Kind.Tool_Dispatch)
	testing.expect_value(t, entries[3].kind, session.Entry_Kind.Tool_Result)
	result, is_result := entries[3].payload.(session.Tool_Result_Entry)
	if !testing.expect(t, is_result, "the last entry should be a result") { return }
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Invalid_Arguments)
}

@(test)
test_malformed_arguments_are_rejected_and_replayed :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat.max_output_tokens = 4096
	_test_accept(t, chat, "malformed call")

	// The provider delivered a call whose argument document never parses. Nothing
	// runs, the model is told what is wrong, and the turn keeps going.
	_test_stage_call(t, chat, "call_bad", `{"command":`)
	count := chat_run_tools(chat, {})
	testing.expect_value(t, count, 1)
	testing.expect(t, chat_session_tools_done(chat, chat.active_turn_id, count))
	testing.expect_value(t, chat.state, Chat_State.Preparing)

	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	if !testing.expect_value(t, len(entries), 3) { return }
	result, is_result := entries[2].payload.(session.Tool_Result_Entry)
	if !testing.expect(t, is_result, "a rejected call still gets a result") { return }
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Invalid_Arguments)
	testing.expect(t, strings.contains(result.content, `"kind":"syntax"`), "the result names the defect")

	// The proposal must never reach the wire: an endpoint refuses tool arguments it
	// cannot parse, and one unsendable request would poison every request after it.
	// The refusal is spoken in the call's place, for every API family.
	apis := []ai.API_Kind{.OpenAI_Chat_Completions, .OpenAI_Responses, .Anthropic_Messages}
	for api in apis {
		prep, prep_err := chat_prepare(chat, {API = api})
		if !testing.expectf(t, prep_err == nil, "%v must build a request", api) { continue }
		body, encode_err := ai.Provider_Encode_Request(prep.request)
		testing.expectf(t, encode_err == ai.Provider_Request_Error.None, "%v must encode a refused call", api)
		testing.expectf(t, !strings.contains(body, `{\"command\":`), "%v must not carry the malformed proposal", api)
		testing.expectf(t, strings.contains(body, "was refused before it ran"), "%v must say the call did not run", api)
		delete(body)
		chat_request_prep_destroy(&prep, chat.allocator)
	}
}

@(test)
test_a_repaired_call_is_replayed_as_what_ran :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "repaired call")

	// A raw newline inside the command string: the repair escapes it, so the
	// proposal and what ran are different bytes.
	_test_stage_call(t, chat, "call_fix", "{\"command\":\"echo hello\n\",\"working_directory\":null,\"timeout_ms\":null}")
	count := chat_run_tools(chat, {})
	testing.expect_value(t, count, 1)
	testing.expect(t, chat_session_tools_done(chat, chat.active_turn_id, count))

	prep, prep_err := chat_prepare(chat, {API = .OpenAI_Chat_Completions})
	if !testing.expect_value(t, prep_err, nil) { return }
	defer chat_request_prep_destroy(&prep, chat.allocator)

	seen := false
	for message in prep.wire {
		for call in message.Tool_Calls {
			seen = true
			testing.expect(t, !strings.contains(call.Arguments, "\n"), "the repair is what the provider is told")
			testing.expect(t, strings.contains(call.Arguments, "echo hello"), "the command survives the repair")
		}
	}
	testing.expect(t, seen, "a repaired call is still replayed as a call")
}

@(test)
test_a_response_with_an_unparseable_call_is_not_replayed_verbatim :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat.max_output_tokens = 4096
	_test_accept(t, chat, "native malformed call")
	effect := _test_begin_request(t, chat)
	chat_effect_destroy(&effect)
	request_no, begin_err := session.request_begin(
		chat.store,
		chat.id,
		{turn_no = chat.turn_no, purpose = .Response, provider = "p", model_requested = "m", api = "openai_responses", config_json = "{}", input_json = "{}"},
		session.now_ms(),
	)
	if !testing.expect_value(t, begin_err, nil) { return }

	// A native Responses output whose function_call carries arguments that do not
	// parse. Replaying it verbatim is exactly what the endpoint refuses, so the
	// response has to fall back to the projection, which can say it correctly.
	output := `[{\"type\":\"message\",\"id\":\"msg_1\",\"status\":\"completed\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"trying\"}]},{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_v\",\"name\":\"shell\",\"arguments\":\"{\\\"command\\\": not_a_number}\"}]`
	_test_append(t, chat, {turn_no = chat.turn_no, request_no = request_no, created_at_ms = 2_000, payload = session.Response_Entry{output = output}})
	_test_append(t, chat, {turn_no = chat.turn_no, request_no = request_no, created_at_ms = 2_001, payload = session.Assistant_Entry{text = "trying"}})
	call_seq := _test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			request_no = request_no,
			created_at_ms = 2_002,
			payload = session.Tool_Call_Entry{call_id = "call_v", item_id = "fc_1", name = TOOL_SHELL_NAME, arguments = `{\"command\": not_a_number}`},
		},
	)
	_test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			request_no = request_no,
			created_at_ms = 2_003,
			related_seq = call_seq,
			payload = session.Tool_Result_Entry {
				outcome = .Invalid_Arguments,
				error = "the arguments are not valid JSON",
				content = `{\"status\":\"invalid_arguments\"}`,
				origin = .Observed,
			},
		},
	)

	prep, prep_err := chat_prepare(chat, {API = .OpenAI_Responses})
	if !testing.expect_value(t, prep_err, nil) { return }
	defer chat_request_prep_destroy(&prep, chat.allocator)
	body, encode_err := ai.Provider_Encode_Request(prep.request)
	if !testing.expect_value(t, encode_err, ai.Provider_Request_Error.None) { return }
	defer delete(body)

	testing.expect(t, !strings.contains(body, `{\"command\":`), "the native record must not be replayed as it stands")
	testing.expect(t, strings.contains(body, "was refused before it ran"), "the refusal is spoken instead")
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
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Unavailable)
	testing.expect(t, strings.contains(result.content, "nope"), "the result names the tool the model asked for")
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

// The Messages API needs an output bound, its system prompt in its own field, and
// tool calls and results as typed content blocks. The harness projection is
// provider-neutral, so the adapter is what has to shape it, and this checks the
// two fit together.

// A response the harness cannot use does not end the turn. Nothing runs, the
// harness records why, and the state machine goes back to preparing a request so
// the model can correct itself.
@(test)
test_unusable_response_becomes_feedback_not_a_failure :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "duplicate calls")

	effect := _test_begin_request(t, chat)
	chat_effect_destroy(&effect)
	request_no, begin_err := session.request_begin(
		chat.store,
		chat.id,
		{
			turn_no = chat.turn_no,
			purpose = .Response,
			provider = "p",
			model_requested = "m",
			api = "openai_chat_completions",
			config_json = "{}",
			input_json = "{}",
		},
		session.now_ms(),
	)
	if !testing.expect_value(t, begin_err, nil) { return }

	// Two calls under one id: the harness will not pick a winner, so it runs
	// neither and says so.
	source := chat_session_event_source(chat)
	calls := []ai.Provider_Tool_Call {
		{ID = "call_1", Name = TOOL_SHELL_NAME, Arguments = `{"command":"a","working_directory":null,"timeout_ms":null}`},
		{ID = "call_1", Name = TOOL_SHELL_NAME, Arguments = `{"command":"b","working_directory":null,"timeout_ms":null}`},
	}
	testing.expect_value(t, chat_session_feed_tool_calls(chat, source, calls), Chat_Notice.Duplicate_Call_ID)
	testing.expect(t, chat_session_note_notice(chat, source, .Duplicate_Call_ID))
	testing.expect_value(t, chat.state, Chat_State.Preparing)

	usages := make([dynamic]Chat_Request_Usage, 0, chat.allocator)
	defer delete(usages)
	chat_commit_response(chat, request_no, .Tool_Call, &usages)
	chat_session_retire_operation(chat)

	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	// The prompt and the harness explanation; no call and no result were recorded.
	if !testing.expect_value(t, len(entries), 2) { return }
	notice, is_notice := entries[1].payload.(session.User_Entry)
	if !testing.expect(t, is_notice, "the harness explanation is conversation") { return }
	testing.expect_value(t, notice.origin, session.User_Origin.Harness)
	testing.expect(t, strings.contains(notice.text, "own id"), "the explanation names the defect")
	testing.expect_value(t, chat.state, Chat_State.Preparing)

	// The next step is another request, not a stop.
	next := chat_session_advance(chat)
	defer chat_effect_destroy(&next)
	testing.expect_value(t, next.kind, Chat_Effect_Kind.Start_Request)
}

// --- result envelope guarantees -------------------------------------------------

// tool_loop_rogue_execute violates the result contract: it reports success with
// content that is not a result envelope. Dispatch must replace it rather than
// store it.
tool_loop_rogue_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	return Tool_Result {
		call_id = strings.clone(ctx.call_id, ctx.allocator),
		outcome = .Success,
		reason = strings.clone("rogue", ctx.allocator),
		content = strings.clone("not json", ctx.allocator),
		allocator = ctx.allocator,
	}
}

// An unavailable tool never executes, and what is stored for it is still a
// valid envelope whose status names the outcome.
@(test)
test_unavailable_tool_records_a_valid_envelope :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	result := tool_run(t, &test, "no_such_tool", `{}`)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Unavailable)
	tool_test_envelope_matches(t, result.content, .Unavailable, `no tool named "no_such_tool" is available`)
}

// A result that violates the contract is replaced with valid bounded feedback,
// and the observed outcome is preserved.
@(test)
test_result_contract_violation_is_replaced_in_dispatch :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	rogue := Tool_Definition {
		name         = "rogue_tool",
		description  = "A tool that returns content outside the result contract.",
		input_schema = `{"type":"object"}`,
		execute      = tool_loop_rogue_execute,
	}
	if !testing.expect_value(t, tool_registry_add(&test.fixture.chat.tools, rogue).kind, Tool_Registry_Error_Kind.None) { return }

	result := tool_run(t, &test, "rogue_tool", `{}`)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
	tool_test_envelope_matches(t, result.content, .Success, TOOL_RESULT_REPLACED_MALFORMED)
}

// Cancellation that lands after the dispatch was recorded but before execution
// begins means the call never started: the intent is durable, the effect is
// Not_Executed. An expired turn deadline reaches this window even though the
// pre-dispatch check only observes interruption.
@(test)
test_cancel_after_dispatch_is_not_executed :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	test.fixture.chat.turn_deadline = ai.deadline_in(-time.Second)
	result := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"echo hi"}`)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Not_Executed)
}

// --- execution context policy -------------------------------------------------

// The probe records the policy and binding dispatch handed to one execution.
// Package-level storage is how a shared executor reports back through a
// signature that returns only a result; tests run serially, and every case
// overwrites the previous observation before asserting on it.
tool_policy_seen_default: time.Duration
tool_policy_seen_maximum: time.Duration
tool_policy_seen_backend: rawptr

// tool_policy_probe_execute is an adapter-style shared executor: one procedure
// serving many definitions, reading its bounds and binding from the context
// rather than from a definition it cannot name.
tool_policy_probe_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	tool_policy_seen_default = ctx.timeouts.default
	tool_policy_seen_maximum = ctx.timeouts.maximum
	tool_policy_seen_backend = ctx.backend
	return tool_result_success(ctx, Tool_Empty{}, "probed")
}

// One executor serves two definitions with different policies and bindings.
// Dispatch must hand each call the policy of the definition that was resolved
// for it, so no policy needs duplicating into adapter state.
@(test)
test_shared_executor_sees_definition_policy :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	marker_one: u8 = 1
	marker_two: u8 = 2
	first := Tool_Definition {
		name = "probe_first",
		description = "First probe tool.",
		input_schema = `{"type":"object"}`,
		timeouts = {default = 5 * time.Second, maximum = 10 * time.Second},
		execute = tool_policy_probe_execute,
		backend = &marker_one,
	}
	second := Tool_Definition {
		name = "probe_second",
		description = "Second probe tool.",
		input_schema = `{"type":"object"}`,
		timeouts = {default = 30 * time.Second, maximum = 60 * time.Second},
		execute = tool_policy_probe_execute,
		backend = &marker_two,
	}
	if !testing.expect_value(t, tool_registry_add(&test.fixture.chat.tools, first).kind, Tool_Registry_Error_Kind.None) { return }
	if !testing.expect_value(t, tool_registry_add(&test.fixture.chat.tools, second).kind, Tool_Registry_Error_Kind.None) { return }

	first_result := tool_run(t, &test, "probe_first", `{}`)
	testing.expect_value(t, first_result.outcome, session.Tool_Outcome.Success)
	testing.expect_value(t, tool_policy_seen_default, 5 * time.Second)
	testing.expect_value(t, tool_policy_seen_maximum, 10 * time.Second)
	testing.expect(t, tool_policy_seen_backend == &marker_one, "the first call carries the first binding")

	second_result := tool_run(t, &test, "probe_second", `{}`)
	testing.expect_value(t, second_result.outcome, session.Tool_Outcome.Success)
	testing.expect_value(t, tool_policy_seen_default, 30 * time.Second)
	testing.expect_value(t, tool_policy_seen_maximum, 60 * time.Second)
	testing.expect(t, tool_policy_seen_backend == &marker_two, "the second call carries the second binding")
}

// Every dispatch path stores a valid envelope: the unknown tool, the refused
// arguments, the cancellation before dispatch, and the cancellation after the
// dispatch was recorded. Finalization sits once before storage rather than in
// the execute path, so results that never reach a definition cross it too.
@(test)
test_every_dispatch_path_stores_a_valid_envelope :: proc(t: ^testing.T) {
	{
		test: Tool_Test
		tool_test_begin(t, &test)
		defer tool_test_end(t, &test)

		result := tool_run(t, &test, "no_such_tool", `{}`)
		testing.expect_value(t, result.outcome, session.Tool_Outcome.Unavailable)
		testing.expect(t, tool_result_valid(result.outcome, result.content), "an unknown tool stores a valid envelope")
	}
	{
		test: Tool_Test
		tool_test_begin(t, &test)
		defer tool_test_end(t, &test)

		result := tool_run(t, &test, TOOL_SHELL_NAME, `{"a":1} trailing`)
		testing.expect_value(t, result.outcome, session.Tool_Outcome.Invalid_Arguments)
		testing.expect(t, tool_result_valid(result.outcome, result.content), "refused arguments store a valid envelope")
	}
	{
		test: Tool_Test
		tool_test_begin(t, &test)
		defer tool_test_end(t, &test)

		chat_cancel_request()
		defer chat_cancel_reset()
		result := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"echo hi"}`)
		testing.expect_value(t, result.outcome, session.Tool_Outcome.Not_Executed)
		testing.expect(t, tool_result_valid(result.outcome, result.content), "a cancellation before dispatch stores a valid envelope")
	}
	{
		test: Tool_Test
		tool_test_begin(t, &test)
		defer tool_test_end(t, &test)

		test.fixture.chat.turn_deadline = ai.deadline_in(-time.Second)
		result := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"echo hi"}`)
		testing.expect_value(t, result.outcome, session.Tool_Outcome.Not_Executed)
		testing.expect(t, tool_result_valid(result.outcome, result.content), "a cancellation after dispatch stores a valid envelope")
	}
}
