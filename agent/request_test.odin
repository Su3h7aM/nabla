#+test
package agent

import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "nabla:agent/journal"
import "nabla:ai"

@(private)
request_test_prepare :: proc(test: ^testing.T, chat: ^Chat_Session, connection: ai.Provider_Connection, arena: ^virtual.Arena) -> Chat_Request_Prep {
	if error := virtual.arena_init_growing(arena); error != nil { testing.fail_now(test, "arena initialization failed") }
	preparation, error := chat_prepare(chat, connection, virtual.arena_allocator(arena))
	if error != nil { testing.fail_now(test, "chat_prepare failed") }
	return preparation
}

@(private)
request_test_call :: proc(
	test: ^testing.T,
	chat: ^Chat_Session,
	request: journal.Request_Id,
	identifier, arguments: string,
	outcome := journal.Tool_Outcome.Success,
	item_id := "",
) -> journal.Call_Id {
	call := journal.next_call(chat.store)
	chat_record(
		chat,
		{kind = .Tool_Proposed, node = chat.response_node, request = request, call = call},
		journal.Tool_Proposed{provider_id = identifier, item_id = item_id, name = TOOL_SHELL_NAME},
		transmute([]u8)arguments,
	)
	chat_record(
		chat,
		{kind = .Tool_Admitted, node = chat.response_node, request = request, call = call},
		journal.Tool_Admitted{tool = TOOL_SHELL_NAME},
		transmute([]u8)arguments,
	)
	content := `{"status":"exited"}`
	if outcome == .Tool_Failed { content = `{"status":"tool_failed"}` }
	chat_record(
		chat,
		{kind = .Tool_Completed, node = chat.response_node, request = request, call = call},
		journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[outcome]},
		transmute([]u8)content,
	)
	_test_commit(test, chat)
	chat_node(chat, .Results, journal.Results{calls = []journal.Call_Id{call}})
	_test_commit(test, chat)
	return call
}

@(test)
test_build_request_uses_canonical_tool_names_directly :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	definition := Tool_Definition {
		name         = "FFF_find_files",
		description  = "Find files.",
		input_schema = `{"type":"object"}`,
		execute      = tool_test_dummy_execute,
	}
	if !testing.expect_value(test, tool_registry_add(&chat.tools, definition).kind, Tool_Registry_Error_Kind.None) { return }
	_test_accept(test, chat, "hi")
	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, tool_loop_connection, &arena)
	defer virtual.arena_destroy(&arena)
	found_native := false
	found_mcp := false
	for tool in preparation.request.Tools {
		testing.expect(test, !strings.contains(tool.Name, "."), "provider tool names must not contain dots")
		if tool.Name == TOOL_EDIT_NAME { found_native = true }
		if tool.Name == "FFF_find_files" { found_mcp = true }
	}
	testing.expect(test, found_native, "native tools are advertised")
	testing.expect(test, found_mcp, "MCP tools are advertised")
}

@(test)
test_build_request_carries_configured_max_output :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(test, chat, "hi")
	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, tool_loop_connection, &arena)
	defer virtual.arena_destroy(&arena)
	testing.expect(test, preparation.request.Max_Output_Tokens_Present)
	testing.expect_value(test, preparation.request.Max_Output_Tokens, 64)
}

@(test)
test_build_request_sets_stable_response_cache_key :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "run printf ok")
	connections := [?]ai.Provider_Connection{{API = .OpenAI_Responses}, tool_loop_connection}
	for connection in connections {
		arena: virtual.Arena
		preparation := request_test_prepare(test, chat, connection, &arena)
		testing.expect(test, preparation.request.Prompt_Cache_Key_Present)
		testing.expect_value(test, preparation.request.Prompt_Cache_Key, chat_session_text(chat))
		virtual.arena_destroy(&arena)
	}
}

@(test)
test_build_request_replays_verbatim_response_output_in_order :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "run printf ok")
	request := journal.next_request(chat.store)
	output := `[{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Working."}]},{"type":"function_call","id":"fc_1","call_id":"call_1","name":"shell","arguments":"{\"command\":\"printf tool-ok\"}"}]`
	_test_response(test, chat, request, "Working.", output, .OpenAI_Responses)
	request_test_call(test, chat, request, "call_1", `{"command":"printf tool-ok"}`, .Success, "fc_1")
	connection := ai.Provider_Connection {
		API = .OpenAI_Responses,
	}
	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, connection, &arena)
	defer virtual.arena_destroy(&arena)
	body, encode_error := ai.Provider_Encode_Request(preparation.request)
	if !testing.expect_value(test, encode_error, ai.Provider_Request_Error.None) { return }
	defer delete(body)
	value, parse_error := json.parse_string(body, .JSON, true, context.temp_allocator)
	if !testing.expect_value(test, parse_error, nil) { return }
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(test, object_ok) { return }
	stored, stored_ok := object["store"].(json.Boolean)
	testing.expect(test, stored_ok && !bool(stored))
	instructions, instructions_ok := object["instructions"].(json.String)
	if testing.expect(test, instructions_ok) { testing.expect_value(test, string(instructions), AGENT_SYSTEM_PROMPT) }
	input, input_ok := object["input"].(json.Array)
	if !testing.expect(test, input_ok) || !testing.expect_value(test, len(input), 4) { return }
	first := item_object(test, input, 0)
	testing.expect_value(test, item_string(first, "role"), "user")
	second := item_object(test, input, 1)
	testing.expect_value(test, item_string(second, "type"), "message")
	testing.expect_value(test, item_string(second, "role"), "assistant")
	_, status_present := second["status"]
	testing.expect(test, !status_present)
	third := item_object(test, input, 2)
	testing.expect_value(test, item_string(third, "type"), "function_call")
	testing.expect_value(test, item_string(third, "call_id"), "call_1")
	fourth := item_object(test, input, 3)
	testing.expect_value(test, item_string(fourth, "type"), "function_call_output")
	testing.expect_value(test, item_string(fourth, "call_id"), "call_1")
}

@(test)
test_response_replay_requires_matching_api_family :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "run printf tool-ok")
	request := journal.next_request(chat.store)
	output := `[{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Working."}]},{"type":"function_call","id":"fc_1","call_id":"call_1","name":"shell","arguments":"{\"command\":\"printf tool-ok\"}"}]`
	_test_response(test, chat, request, "Working.", output, .OpenAI_Responses)
	request_test_call(test, chat, request, "call_1", `{"command":"printf tool-ok"}`, .Success, "fc_1")

	connection := ai.Provider_Connection {
		API = .Anthropic_Messages,
	}
	chat.model_api = connection.API
	anthropic_arena: virtual.Arena
	anthropic := request_test_prepare(test, chat, connection, &anthropic_arena)
	defer virtual.arena_destroy(&anthropic_arena)
	// Another API's items are not this endpoint's to refuse: the response goes as text and calls.
	testing.expect_value(test, anthropic.replay_refused, 0)
	text_present := false
	call_present := false
	result_present := false
	for message in anthropic.request.Messages {
		text_present = text_present || message.Content == "Working."
		result_present = result_present || (message.Role == .Tool && message.Tool_Call_ID == "call_1")
		for call in message.Tool_Calls {
			call_present = call_present || call.ID == "call_1"
		}
		testing.expect_value(test, message.Verbatim_Items, "")
	}
	testing.expect(test, text_present, "the neutral projection keeps the response text")
	testing.expect(test, call_present, "the neutral projection keeps the tool call")
	testing.expect(test, result_present, "the neutral projection keeps the tool result")
	request_test_expect_encoded_order(test, anthropic.request, connection.API)

	connection.API = .OpenAI_Responses
	chat.model_api = connection.API
	responses_arena: virtual.Arena
	responses := request_test_prepare(test, chat, connection, &responses_arena)
	defer virtual.arena_destroy(&responses_arena)
	if !testing.expect_value(test, responses.replay_refused, 0) { return }
	verbatim_present := false
	for message in responses.request.Messages {
		verbatim_present = verbatim_present || message.Verbatim_Items == output
	}
	testing.expect(test, verbatim_present, "the original API family replays its native response")
	request_test_expect_encoded_order(test, responses.request, connection.API)
}

@(test)
test_anthropic_request_replays_thinking_before_projected_content_and_calls :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "run printf ok")
	request := journal.next_request(chat.store)
	output := `[{"type":"thinking","thinking":"Check the command.","signature":"sig_1"}]`
	_test_response(test, chat, request, "Working.", output, .Anthropic_Messages)
	request_test_call(test, chat, request, "toolu_1", `{"command":"printf tool-ok"}`)
	connection := ai.Provider_Connection {
		API      = .Anthropic_Messages,
		Endpoint = "https://api.anthropic.com",
	}
	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, connection, &arena)
	defer virtual.arena_destroy(&arena)
	if !testing.expect_value(test, len(preparation.request.Messages), 5) { return }
	testing.expect_value(test, preparation.request.Messages[1].Verbatim_Items, output)
	testing.expect_value(test, preparation.request.Messages[2].Content, "Working.")
	if !testing.expect_value(test, len(preparation.request.Messages[3].Tool_Calls), 1) { return }

	body, encode_error := ai.Provider_Encode_Request(preparation.request)
	if !testing.expect_value(test, encode_error, ai.Provider_Request_Error.None) { return }
	defer delete(body)
	value, parse_error := json.parse_string(body, .JSON, true, context.temp_allocator)
	if !testing.expect_value(test, parse_error, nil) { return }
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(test, object_ok) { return }
	messages, messages_ok := object["messages"].(json.Array)
	if !testing.expect(test, messages_ok && len(messages) == 3) { return }
	assistant := item_object(test, messages, 1)
	if !testing.expect_value(test, item_string(assistant, "role"), "assistant") { return }
	blocks, blocks_ok := assistant["content"].(json.Array)
	if !testing.expect(test, blocks_ok && len(blocks) == 3) { return }
	thinking := item_object(test, blocks, 0)
	testing.expect_value(test, item_string(thinking, "type"), "thinking")
	testing.expect_value(test, item_string(thinking, "thinking"), "Check the command.")
	testing.expect_value(test, item_string(thinking, "signature"), "sig_1")
	text := item_object(test, blocks, 1)
	testing.expect_value(test, item_string(text, "type"), "text")
	testing.expect_value(test, item_string(text, "text"), "Working.")
	call := item_object(test, blocks, 2)
	testing.expect_value(test, item_string(call, "type"), "tool_use")
	testing.expect_value(test, item_string(call, "id"), "toolu_1")
}

@(test)
test_chat_completions_projects_entries_a_response_entry_covers :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "run printf ok")
	request := journal.next_request(chat.store)
	output := `[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Working."}]},{"type":"function_call","call_id":"call_1","name":"shell","arguments":"{\"command\":\"ls\"}"}]`
	_test_response(test, chat, request, "Working.", output)
	request_test_call(test, chat, request, "call_1", `{"command":"ls"}`)
	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, tool_loop_connection, &arena)
	defer virtual.arena_destroy(&arena)
	testing.expect(test, preparation.request.Instructions_Present)
	testing.expect_value(test, preparation.request.Instructions, AGENT_SYSTEM_PROMPT)
	if !testing.expect_value(test, len(preparation.request.Messages), 4) { return }
	testing.expect_value(test, preparation.request.Messages[1].Content, "Working.")
	testing.expect_value(test, preparation.request.Messages[2].Tool_Calls[0].ID, "call_1")
	testing.expect_value(test, preparation.request.Messages[3].Tool_Call_ID, "call_1")
}

@(test)
test_a_stored_result_names_its_call :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "run it")
	request := journal.next_request(chat.store)
	_test_response(test, chat, request, "")
	request_test_call(test, chat, request, "call_1", `{"command":"ls"}`)
	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, tool_loop_connection, &arena)
	defer virtual.arena_destroy(&arena)
	if !testing.expect_value(test, len(preparation.request.Messages), 3) { return }
	testing.expect_value(test, preparation.request.Messages[1].Tool_Calls[0].ID, "call_1")
	testing.expect_value(test, preparation.request.Messages[2].Role, ai.Provider_Role.Tool)
	testing.expect_value(test, preparation.request.Messages[2].Tool_Call_ID, "call_1")
}

@(test)
test_anthropic_request_is_shaped_by_its_adapter :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 1024)
	_test_accept(test, chat, "run printf ok")
	request := journal.next_request(chat.store)
	_test_response(test, chat, request, "")
	request_test_call(test, chat, request, "toolu_1", `{"command":"ls","working_directory":null,"timeout_ms":null}`, .Success, "tu_1")
	connection := ai.Provider_Connection {
		API      = .Anthropic_Messages,
		Endpoint = "https://api.anthropic.com",
	}
	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, connection, &arena)
	defer virtual.arena_destroy(&arena)
	body, encode_error := ai.Provider_Encode_Request(preparation.request)
	if !testing.expect_value(test, encode_error, ai.Provider_Request_Error.None) { return }
	defer delete(body)
	value, parse_error := json.parse_string(body, .JSON, true, context.temp_allocator)
	if !testing.expect_value(test, parse_error, nil) { return }
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(test, object_ok) { return }
	testing.expect_value(test, item_string(object, "system"), AGENT_SYSTEM_PROMPT)
	if bound, present, valid := bound_of(object, "max_tokens"); testing.expect(test, valid && present) { testing.expect_value(test, bound, i64(1024)) }
	messages, messages_ok := object["messages"].(json.Array)
	if !testing.expect(test, messages_ok) || !testing.expect_value(test, len(messages), 3) { return }
	call_turn := item_object(test, messages, 1)
	testing.expect_value(test, item_string(call_turn, "role"), "assistant")
	call_blocks, call_blocks_ok := call_turn["content"].(json.Array)
	if !testing.expect(test, call_blocks_ok && len(call_blocks) == 1) { return }
	call_block := item_object(test, call_blocks, 0)
	testing.expect_value(test, item_string(call_block, "type"), "tool_use")
	testing.expect_value(test, item_string(call_block, "name"), "shell")
	result_turn := item_object(test, messages, 2)
	result_blocks, result_blocks_ok := result_turn["content"].(json.Array)
	if !testing.expect(test, result_blocks_ok && len(result_blocks) == 1) { return }
	result_block := item_object(test, result_blocks, 0)
	testing.expect_value(test, item_string(result_block, "type"), "tool_result")
	testing.expect_value(test, item_string(result_block, "tool_use_id"), "toolu_1")
	_, cached := result_block["cache_control"]
	testing.expect(test, cached, "the last block carries the conversation's cache breakpoint")
}

@(test)
test_tool_failed_sets_the_provider_error_marker :: proc(test: ^testing.T) {
	outcomes := [?]journal.Tool_Outcome{.Success, .Tool_Failed}
	for outcome in outcomes {
		fixture: Chat_Test
		chat_test_begin(test, &fixture, tool_loop_workspace(test))
		chat := &fixture.chat
		chat.tools_enabled = true
		chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 1024)
		_test_accept(test, chat, "run it")
		request := journal.next_request(chat.store)
		_test_response(test, chat, request, "")
		request_test_call(test, chat, request, "toolu_1", `{"command":"exit 3","working_directory":null,"timeout_ms":null}`, outcome, "tu_1")
		connection := ai.Provider_Connection {
			API      = .Anthropic_Messages,
			Endpoint = "https://api.anthropic.com",
		}
		body := encode_request_body(test, chat, connection)
		value, parse_error := json.parse_string(body, .JSON, true, context.temp_allocator)
		if testing.expect_value(test, parse_error, nil) {
			object, object_ok := value.(json.Object)
			if testing.expect(test, object_ok) {
				messages, messages_ok := object["messages"].(json.Array)
				if testing.expect(test, messages_ok && len(messages) == 3) {
					result_turn := item_object(test, messages, 2)
					blocks, blocks_ok := result_turn["content"].(json.Array)
					if testing.expect(test, blocks_ok && len(blocks) == 1) {
						block := item_object(test, blocks, 0)
						_, has_marker := block["is_error"]
						testing.expect(test, has_marker == (outcome == .Tool_Failed))
					}
				}
			}
			json.destroy_value(value, context.temp_allocator)
		}
		delete(body)
		chat_test_end(test, &fixture)
	}
}

@(private)
bound_of :: proc(object: json.Object, key: string) -> (value: i64, present: bool, valid: bool) {
	raw, exists := object[key]
	if !exists { return 0, false, true }
	if _, is_null := raw.(json.Null); is_null { return 0, false, true }
	integer, is_integer := raw.(json.Integer)
	if !is_integer { return 0, true, false }
	return i64(integer), true, true
}

@(private)
encode_request_body :: proc(test: ^testing.T, chat: ^Chat_Session, connection: ai.Provider_Connection) -> string {
	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, connection, &arena)
	body, encode_error := ai.Provider_Encode_Request(preparation.request)
	virtual.arena_destroy(&arena)
	if !testing.expect_value(test, encode_error, ai.Provider_Request_Error.None) { return "" }
	return body
}

@(test)
test_a_request_rebuilds_identically_and_only_appends :: proc(test: ^testing.T) {
	connections := [?]ai.Provider_Connection{{API = .OpenAI_Chat_Completions}, {API = .OpenAI_Responses}, {API = .Anthropic_Messages}}
	for connection in connections {
		fixture: Chat_Test
		chat_test_begin(test, &fixture, tool_loop_workspace(test))
		chat := &fixture.chat
		chat.tools_enabled = true
		chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 1024)
		_test_accept(test, chat, "run printf ok")
		request := journal.next_request(chat.store)
		output := `[{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Working.","annotations":[]}]},{"type":"function_call","id":"fc_1","call_id":"call_1","name":"shell","arguments":"{\"command\":\"ls\"}"}]`
		if connection.API == .Anthropic_Messages {
			output = `[{"type":"thinking","thinking":"Checking the command.","signature":"sig_1"}]`
		}
		_test_response(test, chat, request, "Working.", output, connection.API)
		request_test_call(test, chat, request, "call_1", `{"command":"ls"}`, .Success, "fc_1")
		// A finished answer follows the result, so the next user line is a message of its own
		// on every API rather than joining the result's user turn on Anthropic.
		_test_response(test, chat, journal.next_request(chat.store), "done")
		first := encode_request_body(test, chat, connection)
		second := encode_request_body(test, chat, connection)
		testing.expectf(test, second == first, "unchanged request changed for %v", connection.API)
		_test_user(test, chat, "and again")
		grown := encode_request_body(test, chat, connection)
		before := encoded_items(test, first)
		after := encoded_items(test, grown)
		// The cache breakpoint sits on the last block and moves forward as the conversation
		// grows. It is not content, so the items are compared without it.
		if testing.expectf(test, len(after) > len(before), "request did not grow for %v", connection.API) {
			for item, index in before { if !testing.expectf(test, after[index] == item, "item %d changed for %v", index, connection.API) { break } }
		}
		delete(first)
		delete(second)
		delete(grown)
		chat_test_end(test, &fixture)
	}
}

@(test)
test_request_encoding_survives_api_switches_during_a_tool_call :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 1024)
	_test_accept(test, chat, "run printf api-cycle")

	connections := [?]ai.Provider_Connection {
		{API = .Anthropic_Messages},
		{API = .OpenAI_Responses},
		{API = .OpenAI_Chat_Completions},
		{API = .Anthropic_Messages},
	}
	call_ids := [?]string{"toolu_1", "call_2", "call_3"}
	call_item_ids := [?]string{"tu_1", "fc_2", ""}
	response_texts := [?]string{"First answer.", "Second answer.", "Third answer."}
	tool_arguments := `{"command":"printf api-cycle"}`
	result_content := "completed api-cycle call"
	for connection, index in connections {
		chat.model_api = connection.API
		request_test_encode_session(test, chat, connection)
		if index == len(connections) - 1 { break }

		request := journal.next_request(chat.store)
		output := ""
		if connection.API == .Anthropic_Messages {
			output = `[{"type":"thinking","thinking":"Keep this thought.","signature":"sig_1"}]`
		} else if connection.API == .OpenAI_Responses {
			output = `[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Second answer."}]}]`
		}
		_test_response(test, chat, request, response_texts[index], output, connection.API)
		call := journal.next_call(chat.store)
		chat_record(
			chat,
			{kind = .Tool_Proposed, node = chat.response_node, request = request, call = call},
			journal.Tool_Proposed{provider_id = call_ids[index], item_id = call_item_ids[index], name = TOOL_SHELL_NAME},
			transmute([]u8)tool_arguments,
		)
		chat_record(
			chat,
			{kind = .Tool_Admitted, node = chat.response_node, request = request, call = call},
			journal.Tool_Admitted{tool = TOOL_SHELL_NAME},
			transmute([]u8)tool_arguments,
		)
		_test_commit(test, chat)

		// The first tool call remains in flight while the selected API changes.
		if index == 0 { chat.model_api = connections[index + 1].API }
		chat_record(
			chat,
			{kind = .Tool_Completed, node = chat.response_node, request = request, call = call},
			journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]},
			transmute([]u8)result_content,
		)
		_test_commit(test, chat)
		chat_node(chat, .Results, journal.Results{calls = []journal.Call_Id{call}})
		_test_commit(test, chat)
	}
}

@(private)
request_test_encode_session :: proc(test: ^testing.T, chat: ^Chat_Session, connection: ai.Provider_Connection) {
	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, connection, &arena)
	defer virtual.arena_destroy(&arena)
	request_test_expect_encoded_order(test, preparation.request, connection.API)
}

@(private)
request_test_expect_encoded_order :: proc(test: ^testing.T, request: ai.Provider_Request, api: ai.API_Kind) {
	body, encode_error := ai.Provider_Encode_Request(request)
	if !testing.expect_value(test, encode_error, ai.Provider_Request_Error.None) { return }
	defer delete(body)
	for message, result_index in request.Messages {
		if message.Role != .Tool { continue }
		call_precedes_result := false
		for prior_message in request.Messages[:result_index] {
			for call in prior_message.Tool_Calls {
				if call.ID == message.Tool_Call_ID { call_precedes_result = true }
			}
			if api == .OpenAI_Responses && prior_message.Verbatim_Items != "" {
				calls, readable := ai.Provider_Replay_Read(prior_message.Verbatim_Items, context.temp_allocator)
				if readable {
					for call in calls {
						if call.ID == message.Tool_Call_ID { call_precedes_result = true }
					}
				}
			}
		}
		testing.expectf(test, call_precedes_result, "tool result %s follows its call", message.Tool_Call_ID)
	}
}

@(private)
encoded_items :: proc(test: ^testing.T, body: string) -> []string {
	value, parse_error := json.parse_string(body, .JSON, true, context.temp_allocator)
	if !testing.expect_value(test, parse_error, nil) { return nil }
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(test, object_ok) { return nil }
	array, array_ok := object["input"].(json.Array)
	if !array_ok { array, array_ok = object["messages"].(json.Array) }
	if !testing.expect(test, array_ok) { return nil }
	items := make([]string, len(array), context.temp_allocator)
	for &item, index in array {
		if message, message_ok := &item.(json.Object); message_ok {
			if blocks, blocks_ok := message["content"].(json.Array); blocks_ok {
				for &block in blocks {
					if fields, fields_ok := &block.(json.Object); fields_ok { delete_key(fields, "cache_control") }
				}
				// A single text block is the string form the turn takes when it is not the breakpoint.
				if len(blocks) == 1 {
					if fields, fields_ok := blocks[0].(json.Object); fields_ok && len(fields) == 2 {
						if text, text_ok := fields["text"].(json.String); text_ok { message["content"] = text }
					}
				}
			}
		}
		text, unparse_error := json.unparse(item, {sort_maps_by_key = true}, context.temp_allocator)
		if !testing.expect_value(test, unparse_error, nil) { return nil }
		items[index] = text
	}
	return items
}

@(private)
Request_Event_Counter :: struct {
	prepared: int,
	finished: int,
}

@(private)
request_event_observer :: proc(counter: ^Request_Event_Counter) -> Chat_Observer {
	return {user_data = counter, request_prepared = request_event_prepared, request_finished = request_event_finished}
}

@(private)
request_event_prepared :: proc(user_data: rawptr) {
	counter := cast(^Request_Event_Counter)user_data
	counter.prepared += 1
}

@(private)
request_event_finished :: proc(user_data: rawptr) {
	counter := cast(^Request_Event_Counter)user_data
	counter.finished += 1
}

@(test)
test_every_request_reports_itself_while_the_turn_runs :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)
	_test_accept(test, chat, "first")
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = "ftp://not-a-provider",
	}
	usages := make([dynamic]Chat_Request_Usage, 0, chat.allocator)
	defer delete(usages)
	counter: Request_Event_Counter
	observer := request_event_observer(&counter)
	_test_perform_request(test, chat, connection, test_retry_policy(), observer, &usages)
	testing.expect_value(test, counter.prepared, 1)
	testing.expect_value(test, counter.finished, 1)
	chat.state = .Preparing
	_test_perform_request(test, chat, connection, test_retry_policy(), observer, &usages)
	testing.expect_value(test, counter.prepared, 2)
	testing.expect_value(test, counter.finished, 2)
}
