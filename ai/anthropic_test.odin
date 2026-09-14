package ai

import "core:encoding/json"
import "core:strings"
import "core:testing"

// The Messages API shares the request contract but not the wire shape, so these
// tests pin the shape rather than the struct: a system prompt in its own field,
// tool calls and results as typed content blocks, and input usage that counts
// what the cache served.

anthropic_test_request :: proc(allocator := context.temp_allocator) -> Provider_Request {
	calls := make([]Provider_Tool_Call, 1, allocator)
	calls[0] = Provider_Tool_Call {
		ID        = "toolu_1",
		Name      = "shell",
		Arguments = `{"command":"ls"}`,
	}
	messages := make([]Provider_Message, 4, allocator)
	messages[0] = Provider_Message {
		Role    = .User,
		Content = "run it",
	}
	messages[1] = Provider_Message {
		Role    = .Assistant,
		Content = "Working.",
	}
	messages[2] = Provider_Message {
		Role       = .Assistant,
		Tool_Calls = calls,
	}
	messages[3] = Provider_Message {
		Role         = .Tool,
		Content      = `{"status":"exited"}`,
		Tool_Call_ID = "toolu_1",
	}
	tools := make([]Provider_Tool_Def, 1, allocator)
	tools[0] = Provider_Tool_Def {
		Name            = "shell",
		Description     = "Run a command.",
		Parameters_JSON = `{"type":"object","properties":{"command":{"type":"string"}},"required":["command"],"additionalProperties":false}`,
	}
	return Provider_Request {
		API = .Anthropic_Messages,
		Model_Present = true,
		Model = "claude-sonnet-5",
		Instructions_Present = true,
		Instructions = "Be brief.",
		Messages_Present = true,
		Messages = messages,
		Tools = tools,
		Max_Output_Tokens_Present = true,
		Max_Output_Tokens = 1024,
		Cache_Request_Present = true,
		Cache_Request = true,
	}
}

@(test)
test_anthropic_encode_request_shape :: proc(t: ^testing.T) {
	request := anthropic_test_request()
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(t, object_ok) { return }

	// The instruction lane is its own top-level field, not a message turn.
	system, system_present, _ := openai_value_string(object, "system")
	testing.expect(t, system_present)
	testing.expect_value(t, system, "Be brief.")
	bound, bound_present, bound_ok := openai_value_integer(object, "max_tokens")
	testing.expect(t, bound_ok && bound_present)
	testing.expect_value(t, bound, i64(1024))
	mode, mode_ok := object["stream"].(json.Boolean)
	testing.expect(t, mode_ok && bool(mode))
	cache, cache_ok := object["cache_control"].(json.Object)
	testing.expect(t, cache_ok)
	cache_type, _, _ := openai_value_string(cache, "type")
	testing.expect_value(t, cache_type, "ephemeral")

	messages, messages_ok := object["messages"].(json.Array)
	if !testing.expect(t, messages_ok) { return }
	// user, assistant text, assistant tool call, user tool result: the two
	// assistant turns and the result turn are each their own message.
	if !testing.expect_value(t, len(messages), 4) { return }

	first, first_ok := messages[0].(json.Object)
	if !testing.expect(t, first_ok) { return }
	role, _, _ := openai_value_string(first, "role")
	testing.expect_value(t, role, "user")

	// The tool call is a typed block whose input is an object, not a JSON string.
	third, third_ok := messages[2].(json.Object)
	if !testing.expect(t, third_ok) { return }
	role, _, _ = openai_value_string(third, "role")
	testing.expect_value(t, role, "assistant")
	blocks, blocks_ok := third["content"].(json.Array)
	if !testing.expect(t, blocks_ok && len(blocks) == 1) { return }
	block, block_ok := blocks[0].(json.Object)
	if !testing.expect(t, block_ok) { return }
	block_type, _, _ := openai_value_string(block, "type")
	testing.expect_value(t, block_type, "tool_use")
	name, _, _ := openai_value_string(block, "name")
	testing.expect_value(t, name, "shell")
	input, input_ok := block["input"].(json.Object)
	if !testing.expect(t, input_ok) { return }
	command, _, _ := openai_value_string(input, "command")
	testing.expect_value(t, command, "ls")

	// The result names the call it answers and rides in a user turn.
	fourth, fourth_ok := messages[3].(json.Object)
	if !testing.expect(t, fourth_ok) { return }
	role, _, _ = openai_value_string(fourth, "role")
	testing.expect_value(t, role, "user")
	result_blocks, result_blocks_ok := fourth["content"].(json.Array)
	if !testing.expect(t, result_blocks_ok && len(result_blocks) == 1) { return }
	result_block, result_block_ok := result_blocks[0].(json.Object)
	if !testing.expect(t, result_block_ok) { return }
	block_type, _, _ = openai_value_string(result_block, "type")
	testing.expect_value(t, block_type, "tool_result")
	tool_use_id, _, _ := openai_value_string(result_block, "tool_use_id")
	testing.expect_value(t, tool_use_id, "toolu_1")

	tools, tools_ok := object["tools"].(json.Array)
	if !testing.expect(t, tools_ok && len(tools) == 1) { return }
	tool, tool_ok := tools[0].(json.Object)
	if !testing.expect(t, tool_ok) { return }
	_, has_schema := tool["input_schema"]
	testing.expect(t, has_schema, "a tool states its schema, not its parameters")
}

@(test)
test_anthropic_encode_requires_an_output_bound :: proc(t: ^testing.T) {
	request := anthropic_test_request()
	request.Max_Output_Tokens_Present = false
	_, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.Missing_Max_Output_Tokens)
}

@(test)
test_anthropic_encode_omits_cache_when_not_requested :: proc(t: ^testing.T) {
	request := anthropic_test_request()
	request.Cache_Request = false
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(t, object_ok) { return }
	_, present := object["cache_control"]
	testing.expect(t, !present, "a one-off request must not pay for a cache write")
}

@(test)
test_anthropic_stream_text_and_usage :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.Anthropic_Messages, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)

	events := consume(
		t,
		`{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":50,"output_tokens":1}}}`,
		&state,
		1,
	)
	usage := expect_event(t, events[0], Provider_Usage_Event)
	// The total is what the harness measures a hit rate against: what was served
	// plus what was not.
	testing.expect_value(t, usage.Input_Tokens, i64(1050))
	testing.expect_value(t, usage.Cached_Input_Tokens, i64(900))
	testing.expect_value(t, usage.Cache_Write_Tokens, i64(50))
	destroy_events(events)

	events = consume(t, `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`, &state, 0)
	events = consume(t, `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}`, &state, 1)
	text := expect_event(t, events[0], Provider_Text_Event)
	testing.expect_value(t, text.Text, "Hello")
	destroy_events(events)

	events = consume(t, `{"type":"content_block_stop","index":0}`, &state, 0)
	events = consume(t, `{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}`, &state, 2)
	delta_usage := expect_event(t, events[0], Provider_Usage_Event)
	testing.expect_value(t, delta_usage.Output_Tokens, i64(12))
	completed := expect_event(t, events[1], Provider_Completed_Event)
	testing.expect_value(t, completed.Reason, Provider_Finish_Reason.Stop)
	testing.expect_value(t, completed.Reason_Text, "end_turn")
	destroy_events(events)

	events = consume(t, `{"type":"message_stop"}`, &state, 0)
	err := Provider_Stream_Finish(&state)
	testing.expect_value(t, err, Provider_Stream_Error.None)
}

@(test)
test_anthropic_stream_tool_use_arguments :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.Anthropic_Messages, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)

	events := consume(t, `{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"shell","input":{}}}`, &state, 0)
	// The block index counts every block, so a call after a text block still maps
	// to the first call slot.
	events = consume(t, `{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":"}}`, &state, 0)
	events = consume(t, `{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"ls\"}"}}`, &state, 0)
	events = consume(t, `{"type":"content_block_stop","index":0}`, &state, 0)
	events = consume(t, `{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}`, &state, 2)
	completed := expect_event(t, events[1], Provider_Completed_Event)
	testing.expect_value(t, completed.Reason, Provider_Finish_Reason.Tool_Call)
	if !testing.expect_value(t, len(completed.Tool_Calls), 1) { return }
	testing.expect_value(t, completed.Tool_Calls[0].ID, "toolu_1")
	testing.expect_value(t, completed.Tool_Calls[0].Name, "shell")
	testing.expect_value(t, completed.Tool_Calls[0].Arguments, `{"command":"ls"}`)
	testing.expect_value(t, completed.Raw_Output, "")
	destroy_events(events)
}

@(test)
test_anthropic_stream_rejects_unfinished_calls :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.Anthropic_Messages, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)

	_ = consume(t, `{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"shell","input":{}}}`, &state, 0)
	// The decoder reports the defect rather than treating the turn as finished, so
	// the error is read directly instead of through the success-only helper.
	err := Provider_Consume_SSE_Data(`{"type":"message_delta","delta":{"stop_reason":"end_turn"}}`, &state)
	testing.expect(t, err != Provider_Stream_Error.None, "an unfinished call must fail the stream")
	events := drain_events(&state)
	if !testing.expect_value(t, len(events), 1) { return }
	failure := expect_event(t, events[0], Provider_Error_Event)
	testing.expect_value(t, failure.Kind, Provider_Error_Kind.Invalid_Data)
	testing.expect_value(t, state.Phase, Provider_Stream_Phase.Failed)
	destroy_events(events)
}

@(test)
test_anthropic_stream_error_event :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.Anthropic_Messages, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)

	events := consume(t, `{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}`, &state, 1)
	failure := expect_event(t, events[0], Provider_Error_Event)
	testing.expect_value(t, failure.Kind, Provider_Error_Kind.API_Error)
	testing.expect_value(t, failure.Message, "overloaded")
	testing.expect_value(t, failure.Provider_Code, "overloaded_error")
	destroy_events(events)
}

// A checkpoint summary is projected as an assistant turn, which is how the
// OpenAI APIs carry it, but this API opens a conversation with a user turn. The
// adapter is where that difference belongs.
@(test)
test_anthropic_opens_with_a_user_turn_for_a_summary :: proc(t: ^testing.T) {
	request := Provider_Request {
		API                       = .Anthropic_Messages,
		Model_Present             = true,
		Model                     = "claude-sonnet-5",
		Instructions_Present      = true,
		Instructions              = "Be brief.",
		Messages_Present          = true,
		Max_Output_Tokens_Present = true,
		Max_Output_Tokens         = 256,
	}
	messages := make([]Provider_Message, 2, context.temp_allocator)
	messages[0] = Provider_Message {
		Role    = .Assistant,
		Content = "Summary of the conversation so far:\nworked on it",
	}
	messages[1] = Provider_Message {
		Role    = .User,
		Content = "continue",
	}
	request.Messages = messages

	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(t, object_ok) { return }
	encoded, encoded_ok := object["messages"].(json.Array)
	if !testing.expect(t, encoded_ok && len(encoded) == 2) { return }
	first, first_ok := encoded[0].(json.Object)
	if !testing.expect(t, first_ok) { return }
	role, _, _ := openai_value_string(first, "role")
	testing.expect_value(t, role, "user")
	content, _, _ := openai_value_string(first, "content")
	testing.expect(t, strings.has_prefix(content, "Summary of the conversation so far:"))
}
