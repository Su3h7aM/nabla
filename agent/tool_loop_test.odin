#+test
package agent

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

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

	// The agent prompt is the instruction lane, not a turn, so the conversation
	// is the user message and everything the response produced.
	testing.expect(t, prep.request.Instructions_Present)
	testing.expect_value(t, prep.request.Instructions, AGENT_SYSTEM_PROMPT)
	testing.expect_value(t, len(prep.request.Messages), 3)
	testing.expect_value(t, prep.request.Messages[0].Role, ai.Provider_Role.User)
	testing.expect_value(t, prep.request.Messages[1].Role, ai.Provider_Role.Reasoning)
	testing.expect_value(t, prep.request.Messages[1].Reasoning_ID, "rs_1")
	testing.expect_value(t, prep.request.Messages[1].Reasoning_Encrypted, "enc_1")
	testing.expect_value(t, prep.request.Messages[2].Role, ai.Provider_Role.Assistant)
	testing.expect_value(t, len(prep.request.Messages[2].Tool_Calls), 1)
}

@(test)
test_build_request_sets_stable_response_cache_key :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "run printf ok")

	responses := ai.Provider_Connection{API = .OpenAI_Responses}
	prep, prep_err := chat_prepare(chat, responses)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)

	// The cache key is the session id, stable across requests, so related
	// requests route and account together on either OpenAI API.
	testing.expect(t, prep.request.Prompt_Cache_Key_Present)
	testing.expect_value(t, prep.request.Prompt_Cache_Key, string(chat.id))

	chat_prep, chat_err := chat_prepare(chat, tool_loop_connection)
	if chat_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&chat_prep, chat.allocator)
	testing.expect(t, chat_prep.request.Prompt_Cache_Key_Present)
	testing.expect_value(t, chat_prep.request.Prompt_Cache_Key, string(chat.id))
}

// One committed Responses tool turn encodes into a request whose input items sit
// in conversation order: the system prompt first, then the user message, then
// the endpoint's own items for the response, then the tool result. The verbatim
// record is the only copy of the assistant side; projecting it again would send
// the assistant text and the call twice under the same call id.
@(test)
test_build_request_replays_verbatim_response_output_in_order :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "run printf ok")

	responses := ai.Provider_Connection{API = .OpenAI_Responses}
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
			api = "openai_responses",
			config_json = "{}",
			input_json = "{}",
		},
		session.now_ms(),
	)
	if !testing.expect_value(t, begin_err, nil) { return }

	output := `[{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Working."}]},{"type":"function_call","id":"fc_1","call_id":"call_1","name":"shell","arguments":"{}"}]`
	source := chat_session_event_source(chat)
	testing.expect(t, chat_session_feed_response_output(chat, source, output))
	testing.expect(t, chat_session_feed_text(chat, source, "Working."))
	calls := make([]ai.Provider_Tool_Call, 1)
	defer delete(calls)
	calls[0] = ai.Provider_Tool_Call {
		ID        = "call_1",
		Item_ID   = "fc_1",
		Name      = TOOL_SHELL_NAME,
		Arguments = `{"command":"printf tool-ok","working_directory":null,"timeout_ms":null}`,
	}
	testing.expect(t, chat_session_feed_tool_calls(chat, source, calls))

	usages := make([dynamic]Chat_Request_Usage, 0, chat.allocator)
	defer delete(usages)
	chat_commit_response(chat, request_no, .Tool_Call, &usages)
	chat_run_tools(chat, {})
	chat_session_tools_done(chat, chat.active_turn_id, 1)

	prep, prep_err := chat_prepare(chat, responses)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)

	body, encode_err := ai.Provider_Encode_Request(prep.request)
	if !testing.expect_value(t, encode_err, ai.Provider_Request_Error.None) { return }
	defer delete(body)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	if !testing.expect_value(t, parse_err, nil) { return }
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(t, object_ok) { return }

	// The harness replays history itself, so it asks the endpoint to keep none.
	store, store_ok := object["store"].(json.Boolean)
	testing.expect(t, store_ok && !bool(store))

	// The agent prompt is the top-level instruction lane, ahead of the input.
	instructions, instructions_ok := object["instructions"].(json.String)
	testing.expect(t, instructions_ok)
	testing.expect_value(t, string(instructions), AGENT_SYSTEM_PROMPT)

	input, input_ok := object["input"].(json.Array)
	if !testing.expect(t, input_ok) { return }
	if !testing.expect_value(t, len(input), 4) { return }

	first := item_object(t, input, 0)
	role := item_string(first, "role")
	testing.expect_value(t, role, "user")

	// The verbatim items keep their native shape and their position.
	second := item_object(t, input, 1)
	item_type := item_string(second, "type")
	testing.expect_value(t, item_type, "message")
	role = item_string(second, "role")
	testing.expect_value(t, role, "assistant")
	status := item_string(second, "status")
	testing.expect_value(t, status, "completed")

	third, third_ok := input[2].(json.Object)
	if !testing.expect(t, third_ok) { return }
	item_type = item_string(third, "type")
	testing.expect_value(t, item_type, "function_call")
	call_id := item_string(third, "call_id")
	testing.expect_value(t, call_id, "call_1")

	fourth, fourth_ok := input[3].(json.Object)
	if !testing.expect(t, fourth_ok) { return }
	item_type = item_string(fourth, "type")
	testing.expect_value(t, item_type, "function_call_output")
	call_id = item_string(fourth, "call_id")
	testing.expect_value(t, call_id, "call_1")

	// Nothing is sent twice: one assistant message, one function call.
	assistant_messages := 0
	function_calls := 0
	for item in input {
		entry, entry_ok := item.(json.Object)
		if !entry_ok { continue }
		entry_type := item_string(entry, "type")
		entry_role := item_string(entry, "role")
		if entry_type == "function_call" { function_calls += 1 }
		if entry_type == "message" && entry_role == "assistant" { assistant_messages += 1 }
	}
	testing.expect_value(t, assistant_messages, 1)
	testing.expect_value(t, function_calls, 1)
}

// The same entries on Chat Completions have no native items to replay, so the
// portable projection carries the assistant side. A session moved between APIs
// must not lose its text or its calls.
@(test)
test_chat_completions_projects_entries_a_response_entry_covers :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "run printf ok")

	// A real request row, because entries carry a foreign key to it. The same
	// request number on every entry is what makes the coverage check meaningful:
	// on Chat Completions the verbatim record must not suppress the projection.
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

	output := `[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Working."}]},{"type":"function_call","call_id":"call_1","name":"shell","arguments":"{}"}]`
	_test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			request_no = request_no,
			created_at_ms = 2_000,
			payload = session.Response_Entry{output = output},
		},
	)
	_test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			request_no = request_no,
			created_at_ms = 2_001,
			payload = session.Assistant_Entry{text = "Working."},
		},
	)
	call_seq := _test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			request_no = request_no,
			created_at_ms = 2_002,
			payload = session.Tool_Call_Entry{call_id = "call_1", name = TOOL_SHELL_NAME, arguments = `{"command":"ls"}`},
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
			payload = session.Tool_Result_Entry{outcome = .Exited, exit_code = 0, content = `{"status":"exited"}`, origin = .Observed},
		},
	)

	prep, prep_err := chat_prepare(chat, tool_loop_connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)

	// The agent prompt is the instruction lane, so the conversation is the user
	// message, the assistant text, the assistant calls, and the tool result.
	testing.expect(t, prep.request.Instructions_Present)
	testing.expect_value(t, prep.request.Instructions, AGENT_SYSTEM_PROMPT)
	if !testing.expect_value(t, len(prep.request.Messages), 4) { return }
	testing.expect_value(t, prep.request.Messages[1].Role, ai.Provider_Role.Assistant)
	testing.expect_value(t, prep.request.Messages[1].Content, "Working.")
	testing.expect_value(t, len(prep.request.Messages[2].Tool_Calls), 1)
	testing.expect_value(t, prep.request.Messages[2].Tool_Calls[0].ID, "call_1")
	testing.expect_value(t, prep.request.Messages[3].Tool_Call_ID, "call_1")
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
	// No request finished, so there is no token accounting yet. The status must
	// say what it knows -- nothing -- instead of a confident zero.
	testing.expect(t, strings.contains(report, "cache"), "the cache line should be reported")
	testing.expect(t, strings.contains(report, "input 0 in 0"), "no finished request means no measured input")
	// The age counts from creation and includes the time the harness was closed,
	// so it is labelled as age rather than as time spent working.
	testing.expect(t, strings.contains(report, "age"), "the age should be labelled")
	testing.expect(t, !strings.contains(report, "running"), "the age is not time spent working")
}

@(test)
test_status_reports_finished_request_usage :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	_test_accept(t, chat, "report the usage")
	turn, present := chat.turn_no.?
	if !present { testing.fail_now(t, "accepting the prompt should open a turn") }

	request, request_err := session.request_begin(
		chat.store,
		chat.id,
		{turn_no = turn, purpose = .Response, provider = "p", model_requested = "m", api = "a", config_json = "{}", input_json = "{}"},
		session.now_ms(),
	)
	if request_err != nil { testing.fail_now(t, "the usage request should begin") }
	finish := session.Request_Finish {
		outcome = .Completed,
		usage   = session.Usage{input = 100, output = 10, cache_read = 90, cache_write = 10},
		at_ms   = session.now_ms(),
	}
	if finish_err := session.request_finish(chat.store, chat.id, request, finish); finish_err != nil {
		testing.fail_now(t, "the usage request should finish")
	}

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
	testing.expect(t, strings.contains(report, "input 100 in 1"), "finished requests are the usage totals")
	testing.expect(t, strings.contains(report, "read 90 in 1"), "reported cache reads are summed")
	testing.expect(t, strings.contains(report, "write 10 in 1"), "reported cache writes are summed")
	testing.expect(t, strings.contains(report, "90.0% hit"), "90 of 100 input tokens is a 90% hit rate")
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

// The Messages API needs an output bound, its system prompt in its own field, and
// tool calls and results as typed content blocks. The harness projection is
// provider-neutral, so the adapter is what has to shape it, and this checks the
// two fit together.
@(test)
test_anthropic_request_is_shaped_by_its_adapter :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat.max_output_tokens = 1024
	_test_accept(t, chat, "run printf ok")

	call_seq := _test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			created_at_ms = 2_000,
			payload = session.Tool_Call_Entry {
				call_id = "toolu_1",
				item_id = "tu_1",
				name = TOOL_SHELL_NAME,
				arguments = `{"command":"ls","working_directory":null,"timeout_ms":null}`,
			},
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

	anthropic := ai.Provider_Connection {
		API      = .Anthropic_Messages,
		Endpoint = "https://api.anthropic.com",
	}
	prep, prep_err := chat_prepare(chat, anthropic)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)

	body, encode_err := ai.Provider_Encode_Request(prep.request)
	if !testing.expect_value(t, encode_err, ai.Provider_Request_Error.None) { return }
	defer delete(body)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	if !testing.expect_value(t, parse_err, nil) { return }
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(t, object_ok) { return }

	system := item_string(object, "system")
	testing.expect_value(t, system, AGENT_SYSTEM_PROMPT)
	if bound, present, ok := bound_of(object, "max_tokens"); testing.expect(t, ok && present) {
		testing.expect_value(t, bound, i64(1024))
	}
	_, cached := object["cache_control"]
	testing.expect(t, cached, "a conversation request asks the provider to cache its prefix")

	messages, messages_ok := object["messages"].(json.Array)
	if !testing.expect(t, messages_ok) { return }
	// user, assistant tool call, user tool result.
	if !testing.expect_value(t, len(messages), 3) { return }
	call_turn := item_object(t, messages, 1)
	testing.expect_value(t, item_string(call_turn, "role"), "assistant")
	call_blocks, call_blocks_ok := call_turn["content"].(json.Array)
	if !testing.expect(t, call_blocks_ok && len(call_blocks) == 1) { return }
	call_block := item_object(t, call_blocks, 0)
	testing.expect_value(t, item_string(call_block, "type"), "tool_use")
	testing.expect_value(t, item_string(call_block, "name"), TOOL_SHELL_NAME)

	result_turn := item_object(t, messages, 2)
	testing.expect_value(t, item_string(result_turn, "role"), "user")
	result_blocks, result_blocks_ok := result_turn["content"].(json.Array)
	if !testing.expect(t, result_blocks_ok && len(result_blocks) == 1) { return }
	result_block := item_object(t, result_blocks, 0)
	testing.expect_value(t, item_string(result_block, "type"), "tool_result")
	testing.expect_value(t, item_string(result_block, "tool_use_id"), "toolu_1")
}

@(private)
bound_of :: proc(object: json.Object, key: string) -> (value: i64, present: bool, ok: bool) {
	raw, exists := object[key]
	if !exists { return 0, false, true }
	if _, is_null := raw.(json.Null); is_null { return 0, false, true }
	integer, is_integer := raw.(json.Integer)
	if !is_integer { return 0, true, false }
	return i64(integer), true, true
}

// Everything a provider cache can do rests on one property of the harness: a
// request built from the same conversation is identical every time, and appending
// a turn leaves every earlier item exactly where it was. Breakpoint placement and
// cache keys cannot compensate for a rebuild that moves a byte, so this pins the
// property for all three APIs at once.
@(test)
test_a_request_rebuilds_identically_and_only_appends :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat.max_output_tokens = 1024
	_test_accept(t, chat, "run printf ok")
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
	_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_002, payload = session.Assistant_Entry{text = "done"}})
	// A native Responses output replays verbatim, so it is the path most able to
	// move bytes if the encoder is not stable.
	_test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			created_at_ms = 2_003,
			payload = session.Response_Entry {
				output = `[{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Working.","annotations":[]}]},{"type":"function_call","id":"fc_1","call_id":"call_2","name":"shell","arguments":"{}"}]`,
			},
		},
	)

	for connection in ([?]ai.Provider_Connection {
		{API = .OpenAI_Chat_Completions},
		{API = .OpenAI_Responses},
		{API = .Anthropic_Messages},
	}) {
		first := encode_request_body(t, chat, connection)
		defer delete(first)
		second := encode_request_body(t, chat, connection)
		defer delete(second)
		testing.expectf(t, second == first, "an unchanged conversation must encode to the same bytes for %v", connection.API)

		// A later turn grows the conversation. Everything already sent has to come
		// back byte for byte, or the provider sees a different prefix and re-reads
		// it whether or not it is cached.
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_003, payload = session.User_Entry{text = "and again", origin = .Prompt}})
		grown := encode_request_body(t, chat, connection)
		defer delete(grown)
		before := encoded_items(t, first)
		after := encoded_items(t, grown)
		if !testing.expectf(t, len(after) > len(before), "the grown request should carry more items for %v", connection.API) { continue }
		for item, i in before {
			if !testing.expectf(t, after[i] == item, "item %d changed for %v", i, connection.API) { break }
		}
	}
}

@(private)
encode_request_body :: proc(t: ^testing.T, chat: ^Chat_Session, connection: ai.Provider_Connection) -> string {
	prep, prep_err := chat_prepare(chat, connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)
	body, encode_err := ai.Provider_Encode_Request(prep.request)
	if !testing.expect_value(t, encode_err, ai.Provider_Request_Error.None) { return "" }
	return body
}

// encoded_items returns the conversation array of an encoded request as text, one
// entry per item, so a prefix can be compared without depending on object key
// order.
@(private)
encoded_items :: proc(t: ^testing.T, body: string) -> []string {
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	if !testing.expect_value(t, parse_err, nil) { return nil }
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(t, object_ok) { return nil }
	array, array_ok := object["input"].(json.Array)
	if !array_ok {
		array, array_ok = object["messages"].(json.Array)
	}
	if !testing.expect(t, array_ok) { return nil }
	items := make([]string, len(array), context.temp_allocator)
	for item, i in array {
		// The same key order the encoder used, so equality here is equality of the
		// bytes the provider would receive.
		text, unparse_err := json.unparse(item, {sort_maps_by_key = true}, context.temp_allocator)
		if !testing.expect_value(t, unparse_err, nil) { return nil }
		items[i] = text
	}
	return items
}
