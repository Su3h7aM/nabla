#+test
package agent

import "core:encoding/json"
import "core:testing"
import "core:time"

import "nabla:agent/session"
import "nabla:ai"

// Only a failure that could plausibly succeed on a second identical attempt is
// retried. A refusal, a bad request, and an unauthenticated peer are not: the
// same bytes would fail the same way, and re-sending them only wastes the turn.
@(test)
test_request_retry_classification :: proc(t: ^testing.T) {
	retryable := [?]ai.Provider_Operation_Error {
		{kind = .Transport},
		{kind = .Stream},
		{kind = .HTTP, status = 408},
		{kind = .HTTP, status = 429},
		{kind = .HTTP, status = 500},
		{kind = .HTTP, status = 503},
	}
	for err in retryable {
		testing.expectf(t, chat_request_retryable(err), "%v with status %d must be retryable", err.kind, err.status)
	}
	terminal := [?]ai.Provider_Operation_Error {
		{kind = .None},
		{kind = .Invalid_Request},
		{kind = .Cancelled},
		{kind = .Timed_Out},
		{kind = .TLS},
		{kind = .HTTP, status = 400},
		{kind = .HTTP, status = 401},
		{kind = .HTTP, status = 403},
		{kind = .HTTP, status = 422},
	}
	for err in terminal {
		testing.expectf(t, !chat_request_retryable(err), "%v with status %d must not be retryable", err.kind, err.status)
	}

	// The delay doubles and stops growing, so a bounded number of attempts is also
	// a bounded wait.
	testing.expect_value(t, chat_retry_delay(1), 500 * time.Millisecond)
	testing.expect_value(t, chat_retry_delay(2), 1 * time.Second)
	testing.expect_value(t, chat_retry_delay(3), 2 * time.Second)
	testing.expect_value(t, chat_retry_delay(9), CHAT_RETRY_MAX_DELAY)
}

// A retry is only invisible to the model while nothing was exposed. Once text or
// a call has been staged, the failure is reported instead of sent again.
@(test)
test_request_retry_needs_an_unexposed_attempt :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	// Admission resets the process-wide cancellation flag, which another test may
	// have left set.
	_test_accept(t, chat, "go")

	transient := ai.Provider_Operation_Error {
		kind = .Transport,
	}
	testing.expect(t, chat_request_may_retry(chat, transient, 1))
	// The last allowed attempt is not followed by another.
	testing.expect(t, !chat_request_may_retry(chat, transient, CHAT_REQUEST_MAX_ATTEMPTS))

	append(&chat.partial_assistant, "half an answer")
	testing.expect(t, !chat_request_may_retry(chat, transient, 1))
	clear(&chat.partial_assistant)

	// The staged call's strings are owned by the session, so the id is cloned
	// the way a response commit clones: chat_pending_calls_clear frees it.
	append(&chat.pending_calls, Chat_Tool_Call{id = chat_clone_string("call_1", chat.allocator)})
	testing.expect(t, !chat_request_may_retry(chat, transient, 1))
	chat_pending_calls_clear(chat)

	chat.pending_response_present = true
	testing.expect(t, !chat_request_may_retry(chat, transient, 1))
	chat.pending_response_present = false
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

	responses := ai.Provider_Connection {
		API = .OpenAI_Responses,
	}
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

	responses := ai.Provider_Connection {
		API = .OpenAI_Responses,
	}
	effect := _test_begin_request(t, chat)
	chat_effect_destroy(&effect)
	request_no, begin_err := session.request_begin(
		chat.store,
		chat.id,
		{turn_no = chat.turn_no, purpose = .Response, provider = "p", model_requested = "m", api = "openai_responses", config_json = "{}", input_json = "{}"},
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
	testing.expect_value(t, chat_session_feed_tool_calls(chat, source, calls), Chat_Notice.None)

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
	_test_append(t, chat, {turn_no = chat.turn_no, request_no = request_no, created_at_ms = 2_000, payload = session.Response_Entry{output = output}})
	_test_append(t, chat, {turn_no = chat.turn_no, request_no = request_no, created_at_ms = 2_001, payload = session.Assistant_Entry{text = "Working."}})
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
			payload = session.Tool_Result_Entry{outcome = .Success, content = `{"status":"exited"}`, origin = .Observed},
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
			payload = session.Tool_Result_Entry{outcome = .Success, content = `{"status":"exited"}`, origin = .Observed},
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
			payload = session.Tool_Result_Entry{outcome = .Success, content = `{"status":"exited"}`, origin = .Observed},
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

// A cached prefix only helps if the bytes the provider renders do not change
// between requests. This rebuilds a request from an unchanged conversation and
// requires the same bytes, then appends a turn and requires every earlier item to
// be unchanged, for all three APIs. Each API gets its own conversation, because
// appending a second user turn in a row is itself a normalization the encoders
// are allowed to collapse.
@(test)
test_a_request_rebuilds_identically_and_only_appends :: proc(t: ^testing.T) {
	connections := [?]ai.Provider_Connection{{API = .OpenAI_Chat_Completions}, {API = .OpenAI_Responses}, {API = .Anthropic_Messages}}
	for connection in connections {
		fixture: Chat_Test
		chat_test_begin(t, &fixture, tool_loop_workspace(t))
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
				payload = session.Tool_Result_Entry{outcome = .Success, content = `{"status":"exited"}`, origin = .Observed},
			},
		)
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_002, payload = session.Assistant_Entry{text = "done"}})
		// A native Responses output replays verbatim, so it is the path most able
		// to move bytes if the encoder is not stable.
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

		first := encode_request_body(t, chat, connection)
		second := encode_request_body(t, chat, connection)
		testing.expectf(t, second == first, "an unchanged conversation must encode to the same bytes for %v", connection.API)

		// A later turn grows the conversation. Everything already sent has to come
		// back byte for byte, or the provider sees a different prefix and re-reads
		// it whether or not it is cached.
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_004, payload = session.User_Entry{text = "and again", origin = .Prompt}})
		grown := encode_request_body(t, chat, connection)
		before := encoded_items(t, first)
		after := encoded_items(t, grown)
		if testing.expectf(t, len(after) > len(before), "the grown request should carry more items for %v", connection.API) {
			for item, i in before {
				if !testing.expectf(t, after[i] == item, "item %d changed for %v", i, connection.API) { break }
			}
		}

		delete(first)
		delete(second)
		delete(grown)
		chat_test_end(t, &fixture)
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
