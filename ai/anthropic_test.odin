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
	system, system_present, _ := provider_json_string(object, "system")
	testing.expect(t, system_present)
	testing.expect_value(t, system, "Be brief.")
	bound, bound_present, bound_ok := provider_json_integer(object, "max_tokens")
	testing.expect(t, bound_ok && bound_present)
	testing.expect_value(t, bound, i64(1024))
	mode, mode_ok := object["stream"].(json.Boolean)
	testing.expect(t, mode_ok && bool(mode))
	_, top_level_cache := object["cache_control"]
	testing.expect(t, !top_level_cache, "the breakpoint is on a block, where a gateway's own marker cannot conflict with it")

	messages, messages_ok := object["messages"].(json.Array)
	if !testing.expect(t, messages_ok) { return }
	// Consecutive assistant text and tool calls form one turn between the user
	// prompt and the tool result.
	if !testing.expect_value(t, len(messages), 3) { return }

	first, first_ok := messages[0].(json.Object)
	if !testing.expect(t, first_ok) { return }
	role, _, _ := provider_json_string(first, "role")
	testing.expect_value(t, role, "user")

	// The tool call is a typed block after the text block, with an object input
	// rather than a JSON string.
	third, third_ok := messages[1].(json.Object)
	if !testing.expect(t, third_ok) { return }
	role, _, _ = provider_json_string(third, "role")
	testing.expect_value(t, role, "assistant")
	blocks, blocks_ok := third["content"].(json.Array)
	if !testing.expect(t, blocks_ok && len(blocks) == 2) { return }
	block, block_ok := blocks[1].(json.Object)
	if !testing.expect(t, block_ok) { return }
	block_type, _, _ := provider_json_string(block, "type")
	testing.expect_value(t, block_type, "tool_use")
	call_id, call_id_present, call_id_ok := provider_json_string(block, "id")
	testing.expect(t, call_id_ok && call_id_present)
	testing.expect_value(t, call_id, "toolu_1")
	_, call_cached := block["cache_control"]
	testing.expect(t, !call_cached, "only the last block is a breakpoint")
	name, _, _ := provider_json_string(block, "name")
	testing.expect_value(t, name, "shell")
	input, input_ok := block["input"].(json.Object)
	if !testing.expect(t, input_ok) { return }
	command, _, _ := provider_json_string(input, "command")
	testing.expect_value(t, command, "ls")

	// The result names the call it answers and rides in a user turn.
	fourth, fourth_ok := messages[2].(json.Object)
	if !testing.expect(t, fourth_ok) { return }
	role, _, _ = provider_json_string(fourth, "role")
	testing.expect_value(t, role, "user")
	result_blocks, result_blocks_ok := fourth["content"].(json.Array)
	if !testing.expect(t, result_blocks_ok && len(result_blocks) == 1) { return }
	result_block, result_block_ok := result_blocks[0].(json.Object)
	if !testing.expect(t, result_block_ok) { return }
	block_type, _, _ = provider_json_string(result_block, "type")
	testing.expect_value(t, block_type, "tool_result")
	tool_use_id, _, _ := provider_json_string(result_block, "tool_use_id")
	testing.expect_value(t, tool_use_id, "toolu_1")
	cache, cache_ok := result_block["cache_control"].(json.Object)
	if testing.expect(t, cache_ok, "the last block is the breakpoint") {
		cache_type, _, _ := provider_json_string(cache, "type")
		testing.expect_value(t, cache_type, "ephemeral")
		_, has_ttl := cache["ttl"]
		testing.expect(t, !has_ttl, "the lifetime is left to the API or a gateway on the way")
	}

	tools, tools_ok := object["tools"].(json.Array)
	if !testing.expect(t, tools_ok && len(tools) == 1) { return }
	tool, tool_ok := tools[0].(json.Object)
	if !testing.expect(t, tool_ok) { return }
	_, has_schema := tool["input_schema"]
	testing.expect(t, has_schema, "a tool states its schema, not its parameters")
}

@(test)
test_anthropic_encode_normalizes_tool_ids_consistently :: proc(t: ^testing.T) {
	request := anthropic_test_request()
	request.Messages[2].Tool_Calls[0].ID = "call_abc|fc_1"
	request.Messages[3].Tool_Call_ID = "call_abc|fc_1"
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(t, object_ok) { return }
	messages, messages_ok := object["messages"].(json.Array)
	if !testing.expect(t, messages_ok && len(messages) == 3) { return }
	assistant, assistant_ok := messages[1].(json.Object)
	if !testing.expect(t, assistant_ok) { return }
	blocks, blocks_ok := assistant["content"].(json.Array)
	if !testing.expect(t, blocks_ok && len(blocks) == 2) { return }
	tool_use, tool_use_ok := blocks[1].(json.Object)
	if !testing.expect(t, tool_use_ok) { return }
	call_id, call_id_present, call_id_ok := provider_json_string(tool_use, "id")
	if !testing.expect(t, call_id_ok && call_id_present) { return }
	result_turn, result_turn_ok := messages[2].(json.Object)
	if !testing.expect(t, result_turn_ok) { return }
	result_blocks, result_blocks_ok := result_turn["content"].(json.Array)
	if !testing.expect(t, result_blocks_ok && len(result_blocks) == 1) { return }
	tool_result, tool_result_ok := result_blocks[0].(json.Object)
	if !testing.expect(t, tool_result_ok) { return }
	result_id, result_id_present, result_id_ok := provider_json_string(tool_result, "tool_use_id")
	if !testing.expect(t, result_id_ok && result_id_present) { return }
	testing.expect_value(t, result_id, call_id)
	testing.expect(t, call_id != "call_abc|fc_1")
	hash_separator := len(call_id) - 17
	if testing.expect(t, hash_separator >= 0) {
		testing.expect_value(t, call_id[hash_separator], byte('_'))
		for digit in transmute([]byte)call_id[hash_separator + 1:] {
			valid_hex_digit := (digit >= '0' && digit <= '9') || (digit >= 'a' && digit <= 'f')
			testing.expect(t, valid_hex_digit, "the normalized id ends in 16 hexadecimal digits")
		}
	}
	for value in transmute([]byte)call_id {
		valid := (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || (value >= '0' && value <= '9') || value == '_' || value == '-'
		testing.expect(t, valid, "the normalized tool id matches the Messages API pattern")
	}
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
	testing.expect(t, !strings.contains(body, "cache_control"), "a one-off request must not pay for a cache write")
}

@(test)
test_anthropic_encode_adaptive_thinking_beside_effort :: proc(t: ^testing.T) {
	request := anthropic_test_request()
	request.Reasoning_Effort_Present = true
	request.Reasoning_Effort = "high"
	request.Adaptive_Thinking = true
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	testing.expect(t, strings.contains(body, `"thinking":{"type":"adaptive"}`))
	testing.expect(t, strings.contains(body, `"output_config":{"effort":"high"}`))

	request.Adaptive_Thinking = false
	body, err = Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	testing.expect(t, !strings.contains(body, `"thinking"`), "a request without adaptive thinking leaves the model's default")
}

@(test)
test_anthropic_encode_marks_a_single_text_turn :: proc(t: ^testing.T) {
	request := anthropic_test_request()
	request.Messages = request.Messages[:1]
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(t, object_ok) { return }
	messages, messages_ok := object["messages"].(json.Array)
	if !testing.expect(t, messages_ok && len(messages) == 1) { return }
	turn, turn_ok := messages[0].(json.Object)
	if !testing.expect(t, turn_ok) { return }
	// The plain string form has no place for a breakpoint, so the turn is written as its block.
	blocks, blocks_ok := turn["content"].(json.Array)
	if !testing.expect(t, blocks_ok && len(blocks) == 1) { return }
	block, block_ok := blocks[0].(json.Object)
	if !testing.expect(t, block_ok) { return }
	_, cached := block["cache_control"]
	testing.expect(t, cached)
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

// A response that filled the context window is a different stop from one that reached the
// output limit: the first is cured by making room, the second by asking for less.
@(test)
test_anthropic_stream_stop_reasons_distinguish_the_context_window :: proc(t: ^testing.T) {
	Stop :: struct {
		wire:   string,
		reason: Provider_Finish_Reason,
	}
	stops := [?]Stop{{"max_tokens", .Length}, {"model_context_window_exceeded", .Context_Window}}
	for stop in stops {
		state := Provider_Stream_Start(.Anthropic_Messages, context.temp_allocator)
		defer Provider_Stream_Destroy(&state)
		data := strings.concatenate({`{"type":"message_delta","delta":{"stop_reason":"`, stop.wire, `"}}`}, context.temp_allocator)
		events := consume(t, data, &state, 1)
		completed := expect_event(t, events[0], Provider_Completed_Event)
		testing.expect_value(t, completed.Reason, stop.reason)
		testing.expect_value(t, completed.Reason_Text, stop.wire)
		destroy_events(events)
	}
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
test_anthropic_stream_thinking_replays_before_tool_use :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.Anthropic_Messages, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)

	events := consume(t, `{"type":"content_block_start","index":0,"content_block":{"type":"fallback"}}`, &state, 0)
	destroy_events(events)
	events = consume(t, `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"discard this boundary marker"}}`, &state, 0)
	destroy_events(events)
	events = consume(t, `{"type":"content_block_stop","index":0}`, &state, 0)
	destroy_events(events)

	events = consume(t, `{"type":"content_block_start","index":1,"content_block":{"type":"thinking","thinking":""}}`, &state, 0)
	destroy_events(events)
	events = consume(t, `{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"Need inspect \"the source\".\n"}}`, &state, 0)
	destroy_events(events)
	events = consume(t, `{"type":"content_block_delta","index":1,"delta":{"type":"signature_delta","signature":"sig_"}}`, &state, 0)
	destroy_events(events)
	events = consume(t, `{"type":"content_block_delta","index":1,"delta":{"type":"signature_delta","signature":"abc"}}`, &state, 0)
	destroy_events(events)
	events = consume(t, `{"type":"content_block_stop","index":1}`, &state, 0)
	destroy_events(events)

	events = consume(t, `{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"shell","input":{}}}`, &state, 0)
	destroy_events(events)
	events = consume(t, `{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"ls\"}"}}`, &state, 0)
	destroy_events(events)
	events = consume(t, `{"type":"content_block_stop","index":2}`, &state, 0)
	destroy_events(events)
	events = consume(t, `{"type":"message_delta","delta":{"stop_reason":"tool_use"}}`, &state, 1)
	completed := expect_event(t, events[0], Provider_Completed_Event)
	if !testing.expect_value(t, completed.Reason, Provider_Finish_Reason.Tool_Call) { destroy_events(events); return }
	if !testing.expect_value(t, len(completed.Tool_Calls), 1) { destroy_events(events); return }
	testing.expect_value(t, completed.Raw_Output, `[{"type":"thinking","thinking":"Need inspect \"the source\".\n","signature":"sig_abc"}]`)
	testing.expect_value(t, completed.Tool_Calls[0].ID, "toolu_1")
	testing.expect_value(t, completed.Tool_Calls[0].Name, "shell")
	testing.expect_value(t, completed.Tool_Calls[0].Arguments, `{"command":"ls"}`)

	request_messages := make([]Provider_Message, 3, context.temp_allocator)
	request_messages[0] = Provider_Message {
		Role    = .User,
		Content = "run it",
	}
	request_messages[1] = Provider_Message {
		Role           = .Assistant,
		Content        = "Running the command.",
		Tool_Calls     = completed.Tool_Calls,
		Verbatim_Items = completed.Raw_Output,
	}
	request_messages[2] = Provider_Message {
		Role         = .Tool,
		Content      = "done",
		Tool_Call_ID = completed.Tool_Calls[0].ID,
	}
	request := Provider_Request {
		API                       = .Anthropic_Messages,
		Model_Present             = true,
		Model                     = "claude-sonnet-5",
		Messages_Present          = true,
		Messages                  = request_messages,
		Max_Output_Tokens_Present = true,
		Max_Output_Tokens         = 256,
	}
	body, encode_error := Provider_Encode_Request(request, context.temp_allocator)
	if !testing.expect_value(t, encode_error, Provider_Request_Error.None) { destroy_events(events); return }
	value, parse_error := json.parse_string(body, .JSON, true, context.temp_allocator)
	if !testing.expect_value(t, parse_error, nil) { destroy_events(events); return }
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(t, object_ok) { destroy_events(events); return }
	wire_messages, messages_ok := object["messages"].(json.Array)
	if !testing.expect(t, messages_ok && len(wire_messages) == 3) { destroy_events(events); return }
	assistant, assistant_ok := wire_messages[1].(json.Object)
	if !testing.expect(t, assistant_ok) { destroy_events(events); return }
	blocks, blocks_ok := assistant["content"].(json.Array)
	if !testing.expect(t, blocks_ok && len(blocks) == 3) { destroy_events(events); return }
	thinking_block, thinking_ok := blocks[0].(json.Object)
	if !testing.expect(t, thinking_ok && len(thinking_block) == 3) { destroy_events(events); return }
	block_type, _, _ := provider_json_string(thinking_block, "type")
	thinking, _, _ := provider_json_string(thinking_block, "thinking")
	signature, _, _ := provider_json_string(thinking_block, "signature")
	testing.expect_value(t, block_type, ANTHROPIC_BLOCK_THINKING)
	testing.expect_value(t, thinking, "Need inspect \"the source\".\n")
	testing.expect_value(t, signature, "sig_abc")
	text_block, text_ok := blocks[1].(json.Object)
	if !testing.expect(t, text_ok) { destroy_events(events); return }
	block_type, _, _ = provider_json_string(text_block, "type")
	testing.expect_value(t, block_type, ANTHROPIC_BLOCK_TEXT)
	text, _, _ := provider_json_string(text_block, "text")
	testing.expect_value(t, text, "Running the command.")
	tool_block, tool_ok := blocks[2].(json.Object)
	if !testing.expect(t, tool_ok) { destroy_events(events); return }
	block_type, _, _ = provider_json_string(tool_block, "type")
	testing.expect_value(t, block_type, ANTHROPIC_BLOCK_TOOL_USE)
	testing.expect_value(t, len(tool_block), 4)
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

@(test)
test_anthropic_spend_limit_detail_classification :: proc(t: ^testing.T) {
	body_text := `{"error":{"type":"rate_limit_error","message":"You have reached your API usage limits","details":{"error_code":"enforced_spend_limit_reached"}}}`
	body := transmute([]u8)body_text
	rejection, parse_error := provider_rejection_parse(.Anthropic_Messages, body, context.allocator)
	if !testing.expect_value(t, parse_error, nil) { return }
	defer provider_rejection_destroy(&rejection, context.allocator)
	testing.expect_value(t, rejection.detail_code, "enforced_spend_limit_reached")
	class := provider_classify_failure(Provider_Evidence{api = .Anthropic_Messages, kind = .HTTP, head_seen = true, status = 429, rejection = rejection})
	testing.expect_value(t, class, Provider_Failure_Class.Quota)

	stream := Provider_Stream_Start(.Anthropic_Messages, context.allocator)
	defer Provider_Stream_Destroy(&stream)
	stream_error := Provider_Consume_SSE_Data(
		`{"type":"error","error":{"type":"rate_limit_error","message":"limit","details":{"error_code":"enforced_spend_limit_reached"}}}`,
		&stream,
	)
	if !testing.expect_value(t, stream_error, Provider_Stream_Error.None) { return }
	operation := Provider_Request_Stream_State {
		api       = .Anthropic_Messages,
		allocator = context.allocator,
	}
	defer provider_state_release(&operation)
	event, drained := Provider_Stream_Drain(&stream)
	if !testing.expect(t, drained) { return }
	provider_accept_event(&operation, event)
	testing.expect_value(t, operation.rejection.detail_code, "enforced_spend_limit_reached")
	stream_class := provider_classify_failure(
		Provider_Evidence{api = .Anthropic_Messages, kind = .Stream, event = Provider_Error_Kind.API_Error, rejection = operation.rejection},
	)
	testing.expect_value(t, stream_class, Provider_Failure_Class.Quota)
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
	role, _, _ := provider_json_string(first, "role")
	testing.expect_value(t, role, "user")
	content, _, _ := provider_json_string(first, "content")
	testing.expect(t, strings.has_prefix(content, "Summary of the conversation so far:"))
}
