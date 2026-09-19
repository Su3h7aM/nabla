package ai

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "nabla:sse"

expect_event :: proc(t: ^testing.T, event: Provider_Event, $T: typeid) -> T {
	testing.expect(t, event != nil)
	value, ok := event.(T)
	testing.expect(t, ok)
	return value
}

drain_events :: proc(state: ^Provider_Stream_State) -> [dynamic]Provider_Event {
	events := make([dynamic]Provider_Event, 0, context.temp_allocator)
	for {
		event, ok := Provider_Stream_Drain(state)
		if !ok { break }
		append(&events, event)
	}
	return events
}

destroy_events :: proc(events: [dynamic]Provider_Event) {
	for &event in events { Provider_Event_Destroy(&event, context.temp_allocator) }
}

consume :: proc(t: ^testing.T, payload: string, state: ^Provider_Stream_State, expected: int) -> [dynamic]Provider_Event {
	err := Provider_Consume_SSE_Data(payload, state)
	testing.expect_value(t, err, Provider_Stream_Error.None)
	events := drain_events(state)
	testing.expect_value(t, len(events), expected)
	return events
}

request_fixture :: proc(allocator := context.temp_allocator) -> Provider_Request {
	messages := make([]Provider_Message, 2, allocator)
	messages[0] = Provider_Message {
		Role    = .System,
		Content = "Be brief.",
	}
	messages[1] = Provider_Message {
		Role             = .User,
		Content          = "Hi.",
		Cache_Breakpoint = true,
	}
	return Provider_Request {
		API = .OpenAI_Responses,
		Model_Present = true,
		Model = "gpt-5.6",
		Messages_Present = true,
		Messages = messages,
		Max_Output_Tokens_Present = true,
		Max_Output_Tokens = 64,
		Prompt_Cache_Key_Present = true,
		Prompt_Cache_Key = "session-1",
		Prompt_Cache_Options_Present = true,
		Prompt_Cache_Options = Prompt_Cache_Options{Mode_Present = true, Mode = .Explicit, TTL_Present = true, TTL = "30m"},
	}
}

@(test)
test_responses_encode_matches_spec :: proc(t: ^testing.T) {
	request := request_fixture()
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	testing.expect(t, len(body) > 0)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object, ok := value.(json.Object)
	testing.expect(t, ok)
	model, model_present, model_ok := openai_value_string(object, "model")
	testing.expect(t, model_ok && model_present && model == "gpt-5.6")
	limit, limit_present, limit_ok := openai_value_integer(object, "max_output_tokens")
	testing.expect(t, limit_ok && limit_present && limit == 64)
	mode_raw, mode_ok := object["stream"].(json.Boolean)
	testing.expect(t, mode_ok && bool(mode_raw))
	options, options_ok := object["prompt_cache_options"].(json.Object)
	testing.expect(t, options_ok)
	mode, mode_present, mode_value_ok := openai_value_string(options, "mode")
	testing.expect(t, mode_value_ok && mode_present && mode == "explicit")
	input, input_ok := object["input"].(json.Array)
	testing.expect(t, input_ok && len(input) == 2)
	first, first_ok := input[0].(json.Object)
	testing.expect(t, first_ok)
	first_role, _, _ := openai_value_string(first, "role")
	testing.expect_value(t, first_role, "system")
	first_content, _, _ := openai_value_string(first, "content")
	testing.expect_value(t, first_content, "Be brief.")
	second, second_ok := input[1].(json.Object)
	testing.expect(t, second_ok)
	parts, parts_ok := second["content"].(json.Array)
	testing.expect(t, parts_ok && len(parts) == 1)
	part, part_ok := parts[0].(json.Object)
	testing.expect(t, part_ok)
	part_type, _, _ := openai_value_string(part, "type")
	testing.expect_value(t, part_type, "input_text")
	breakpoint, breakpoint_ok := part["prompt_cache_breakpoint"].(json.Object)
	testing.expect(t, breakpoint_ok)
	breakpoint_mode, _, _ := openai_value_string(breakpoint, "mode")
	testing.expect_value(t, breakpoint_mode, "explicit")
}

@(test)
test_responses_websocket_encode_uses_event_envelope_without_http_stream_field :: proc(t: ^testing.T) {
	body, err := openai_responses_encode_websocket_request(request_fixture(), context.temp_allocator)
	if !testing.expect_value(t, err, Provider_Request_Error.None) { return }
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	if !testing.expect_value(t, parse_err, nil) { return }
	defer json.destroy_value(value, context.temp_allocator)
	object, ok := value.(json.Object)
	if !testing.expect(t, ok, "the WebSocket request is not an object") { return }
	event_type, present, valid := openai_value_string(object, "type")
	testing.expect(t, valid && present && event_type == "response.create")
	_, stream_present := object["stream"]
	testing.expect(t, !stream_present, "the WebSocket request carried the HTTP stream field")
	input, input_ok := object["input"].(json.Array)
	testing.expect(t, input_ok && len(input) == 2)
}

@(test)
test_responses_json_event_decoder_completes_outside_sse :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Responses, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	err := Provider_Consume_Event_JSON(`{"type":"response.completed","response":{"id":"resp_123","status":"completed","output":[]}}`, &state)
	if !testing.expect_value(t, err, Provider_Stream_Error.None) { return }
	events := drain_events(&state)
	defer destroy_events(events)
	if !testing.expect_value(t, len(events), 1) { return }
	completed := expect_event(t, events[0], Provider_Completed_Event)
	testing.expect_value(t, completed.Reason, Provider_Finish_Reason.Stop)
	testing.expect_value(t, state.Phase, Provider_Stream_Phase.Completed)
}

@(test)
test_responses_encode_removes_output_status_from_replay :: proc(t: ^testing.T) {
	messages := []Provider_Message {
		{Verbatim_Items = `[{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[]}]`},
		{Role = .User, Content = "Continue."},
	}
	request := Provider_Request {
		API              = .OpenAI_Responses,
		Model_Present    = true,
		Model            = "gpt-5.6",
		Messages_Present = true,
		Messages         = messages,
	}
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object := value.(json.Object)
	input := object["input"].(json.Array)
	replayed := input[0].(json.Object)
	_, status_present := replayed["status"]
	testing.expect(t, !status_present)
	id, id_present, id_ok := openai_value_string(replayed, "id")
	testing.expect(t, id_ok && id_present && id == "msg_1")
}

@(test)
test_responses_validate_rejects_reasoning_without_id :: proc(t: ^testing.T) {
	messages := make([]Provider_Message, 1, context.temp_allocator)
	messages[0] = Provider_Message {
		Role = .Reasoning,
	}
	request := Provider_Request {
		API              = .OpenAI_Responses,
		Model_Present    = true,
		Model            = "gpt-5.6",
		Messages_Present = true,
		Messages         = messages,
	}
	testing.expect_value(t, Provider_Validate_Request(request), Provider_Request_Error.Invalid_Message)
	messages[0].Reasoning_ID = "rs_1"
	testing.expect_value(t, Provider_Validate_Request(request), Provider_Request_Error.None)
}

@(test)
test_responses_encode_effort_and_omission :: proc(t: ^testing.T) {
	messages := make([]Provider_Message, 1, context.temp_allocator)
	messages[0] = Provider_Message {
		Role    = .User,
		Content = "Hi.",
	}
	request := Provider_Request {
		API                      = .OpenAI_Responses,
		Model_Present            = true,
		Model                    = "gpt-5.6",
		Messages_Present         = true,
		Messages                 = messages,
		Reasoning_Effort_Present = true,
		Reasoning_Effort         = "high",
	}
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object := value.(json.Object)
	reasoning, ok := object["reasoning"].(json.Object)
	testing.expect(t, ok)
	effort, _, _ := openai_value_string(reasoning, "effort")
	testing.expect_value(t, effort, "high")

	request.Reasoning_Effort_Present = false
	body, err = Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err = json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object = value.(json.Object)
	_, present := object["reasoning"]
	testing.expect(t, !present)

	request.Reasoning_Effort_Present = true
	request.Reasoning_Effort = ""
	_, err = Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.Invalid_Reasoning_Effort)
}

// The instruction lane is one concept with two encodings: Responses has a
// top-level field for it, Chat Completions has to make it the leading message.
// A conversation never carries it as a turn, so the harness can stop pretending
// a system message is part of the history.
@(test)
test_instructions_encode_per_api :: proc(t: ^testing.T) {
	messages := make([]Provider_Message, 1, context.temp_allocator)
	messages[0] = Provider_Message {
		Role    = .User,
		Content = "Hi.",
	}
	request := Provider_Request {
		API                  = .OpenAI_Responses,
		Model_Present        = true,
		Model                = "gpt-5.6",
		Instructions_Present = true,
		Instructions         = "Be brief.",
		Messages_Present     = true,
		Messages             = messages,
	}

	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	object, object_ok := value.(json.Object)
	if testing.expect(t, object_ok) {
		instructions, _, _ := openai_value_string(object, "instructions")
		testing.expect_value(t, instructions, "Be brief.")
		input, input_ok := object["input"].(json.Array)
		// The lane is not repeated inside the input array.
		testing.expect(t, input_ok && len(input) == 1)
	}
	json.destroy_value(value, context.temp_allocator)

	request.API = .OpenAI_Chat_Completions
	body, err = Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err = json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok = value.(json.Object)
	if !testing.expect(t, object_ok) { return }
	_, inline_instructions := object["instructions"]
	testing.expect(t, !inline_instructions)
	messages_array, messages_ok := object["messages"].(json.Array)
	if !testing.expect(t, messages_ok && len(messages_array) == 2) { return }
	first, first_ok := messages_array[0].(json.Object)
	if !testing.expect(t, first_ok) { return }
	role, _, _ := openai_value_string(first, "role")
	testing.expect_value(t, role, "system")
	content, _, _ := openai_value_string(first, "content")
	testing.expect_value(t, content, "Be brief.")
}

@(test)
test_chat_encode_effort :: proc(t: ^testing.T) {messages := make([]Provider_Message, 1, context.temp_allocator)
	messages[0] = Provider_Message {
		Role    = .User,
		Content = "Hi.",
	}
	request := Provider_Request {
		API                      = .OpenAI_Chat_Completions,
		Model_Present            = true,
		Model                    = "gpt-5.6",
		Messages_Present         = true,
		Messages                 = messages,
		Reasoning_Effort_Present = true,
		Reasoning_Effort         = "low",
	}
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object := value.(json.Object)
	effort, present, ok := openai_value_string(object, "reasoning_effort")
	testing.expect(t, ok && present)
	testing.expect_value(t, effort, "low")
}

@(test)
test_responses_validate_accepts_cache_fields :: proc(t: ^testing.T) {
	request := request_fixture()
	testing.expect_value(t, Provider_Validate_Request(request), Provider_Request_Error.None)
}

@(test)
test_responses_stream_text_usage_completed :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Responses, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	events := consume(t, `{"type":"response.output_text.delta","delta":"Hello"}`, &state, 1)
	text := expect_event(t, events[0], Provider_Text_Event)
	testing.expect_value(t, text.Text, "Hello")
	destroy_events(events)

	events = consume(
		t,
		strings.concatenate(
			[]string {
				`{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":12000,`,
				`"output_tokens":40,"total_tokens":12040,"input_tokens_details":{"cached_tokens":9000,"cache_write_tokens":3000}}}}`,
			},
			context.temp_allocator,
		),
		&state,
		2,
	)
	usage := expect_event(t, events[0], Provider_Usage_Event)
	testing.expect_value(t, usage.Input_Tokens, 12000)
	testing.expect_value(t, usage.Output_Tokens, 40)
	testing.expect_value(t, usage.Cached_Input_Tokens, 9000)
	testing.expect_value(t, usage.Cache_Write_Tokens, 3000)
	completed := expect_event(t, events[1], Provider_Completed_Event)
	testing.expect_value(t, completed.Reason, Provider_Finish_Reason.Stop)
	testing.expect_value(t, completed.Raw_Output, "")
	destroy_events(events)

	err := Provider_Consume_SSE_Data("[DONE]", &state)
	testing.expect_value(t, err, Provider_Stream_Error.None)
	events = drain_events(&state)
	testing.expect_value(t, len(events), 0)
	err = Provider_Stream_Finish(&state)
	testing.expect_value(t, err, Provider_Stream_Error.None)
	events = drain_events(&state)
	testing.expect_value(t, len(events), 0)
}

@(test)
test_responses_stream_incomplete_failed_tool :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Responses, context.temp_allocator)
	events := consume(t, `{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}`, &state, 1)
	incomplete := expect_event(t, events[0], Provider_Completed_Event)
	testing.expect_value(t, incomplete.Reason, Provider_Finish_Reason.Length)
	testing.expect_value(t, incomplete.Reason_Text, "max_output_tokens")
	destroy_events(events)
	Provider_Stream_Destroy(&state)

	state = Provider_Stream_Start(.OpenAI_Responses, context.temp_allocator)
	events = consume(t, `{"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"boom"}}}`, &state, 1)
	failure := expect_event(t, events[0], Provider_Error_Event)
	testing.expect_value(t, failure.Kind, Provider_Error_Kind.API_Error)
	testing.expect_value(t, failure.Message, "boom")
	testing.expect_value(t, failure.Provider_Code, "server_error")
	destroy_events(events)
	Provider_Stream_Destroy(&state)

	state = Provider_Stream_Start(.OpenAI_Responses, context.temp_allocator)
	events = consume(t, `{"type":"response.output_item.done","output_index":0,"item":{"type":"web_search_call"}}`, &state, 1)
	tool := expect_event(t, events[0], Provider_Error_Event)
	testing.expect_value(t, tool.Kind, Provider_Error_Kind.Unsupported_Tool_Output)
	destroy_events(events)
	Provider_Stream_Destroy(&state)
}

@(test)
test_responses_stream_reasoning_replays_with_tools :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Responses, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	// The added event carries no replay data yet; the done item does.
	events := consume(t, `{"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning"}}`, &state, 0)
	events = consume(
		t,
		`{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","encrypted_content":"enc_1","summary":[]}}`,
		&state,
		1,
	)
	reasoning := expect_event(t, events[0], Provider_Reasoning_Event)
	testing.expect_value(t, reasoning.ID, "rs_1")
	testing.expect_value(t, reasoning.Encrypted, "enc_1")
	destroy_events(events)

	events = consume(
		t,
		`{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"shell","arguments":""}}`,
		&state,
		0,
	)
	events = consume(t, `{"type":"response.function_call_arguments.done","output_index":1,"item_id":"fc_1","arguments":"{}"}`, &state, 0)
	events = consume(
		t,
		`{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}`,
		&state,
		2,
	)
	completed := expect_event(t, events[1], Provider_Completed_Event)
	testing.expect_value(t, completed.Reason, Provider_Finish_Reason.Tool_Call)
	testing.expect_value(t, len(completed.Tool_Calls), 1)
	testing.expect_value(t, completed.Tool_Calls[0].ID, "call_1")
	// An empty output array has nothing to replay, so it is reported as no
	// record at all and the harness falls back to its own projection.
	testing.expect_value(t, completed.Raw_Output, "")
	destroy_events(events)
}

@(test)
test_responses_completion_carries_phase_and_raw_output :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Responses, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	_ = consume(
		t,
		`{"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_1","status":"completed","content":[{"type":"output_text","text":"Working.","annotations":[]}],"role":"assistant"}}`,
		&state,
		0,
	)
	events := consume(
		t,
		strings.concatenate(
			[]string {
				`{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","id":"msg_1","status":"completed",`,
				`"content":[{"type":"output_text","text":"Working.","annotations":[]}],"role":"assistant"}],"usage":{"input_tokens":10,`,
				`"output_tokens":5,"total_tokens":15}}}`,
			},
			context.temp_allocator,
		),
		&state,
		2,
	)
	completed := expect_event(t, events[1], Provider_Completed_Event)
	testing.expect_value(t, completed.Reason, Provider_Finish_Reason.Stop)
	// The done item is display-only bookkeeping for the stream; the terminal
	// output array is the replay record, verbatim.
	value, parse_err := json.parse_string(completed.Raw_Output, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	output, output_ok := value.(json.Array)
	testing.expect(t, output_ok && len(output) == 1)
	item, item_ok := output[0].(json.Object)
	testing.expect(t, item_ok)
	item_type, _, _ := openai_value_string(item, "type")
	testing.expect_value(t, item_type, "message")
	destroy_events(events)
}

@(test)
test_responses_encode_replays_reasoning_in_order :: proc(t: ^testing.T) {
	messages := make([]Provider_Message, 3, context.temp_allocator)
	messages[0] = Provider_Message {
		Role    = .User,
		Content = "Inspect the repo.",
	}
	messages[1] = Provider_Message {
		Role                = .Reasoning,
		Reasoning_ID        = "rs_1",
		Reasoning_Encrypted = "enc_1",
	}
	calls := make([]Provider_Tool_Call, 1, context.temp_allocator)
	calls[0] = Provider_Tool_Call {
		ID        = "call_1",
		Item_ID   = "fc_1",
		Name      = "shell",
		Arguments = `{}`,
	}
	messages[2] = Provider_Message {
		Role       = .Assistant,
		Tool_Calls = calls,
	}
	request := Provider_Request {
		API              = .OpenAI_Responses,
		Model_Present    = true,
		Model            = "gpt-5.6",
		Messages_Present = true,
		Messages         = messages,
	}
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object, ok := value.(json.Object)
	testing.expect(t, ok)
	input, input_ok := object["input"].(json.Array)
	testing.expect(t, input_ok && len(input) == 3)
	reasoning_item, reasoning_ok := input[1].(json.Object)
	testing.expect(t, reasoning_ok)
	item_type, _, _ := openai_value_string(reasoning_item, "type")
	testing.expect_value(t, item_type, "reasoning")
	item_id, _, _ := openai_value_string(reasoning_item, "id")
	testing.expect_value(t, item_id, "rs_1")
	encrypted, _, _ := openai_value_string(reasoning_item, "encrypted_content")
	testing.expect_value(t, encrypted, "enc_1")
	// The schema requires summary on a replayed reasoning item; it stays empty.
	summaries, summaries_ok := reasoning_item["summary"]
	testing.expect(t, summaries_ok)
	summaries_array, is_array := summaries.(json.Array)
	testing.expect(t, is_array && len(summaries_array) == 0)
	call_item, call_ok := input[2].(json.Object)
	testing.expect(t, call_ok)
	call_type, _, _ := openai_value_string(call_item, "type")
	testing.expect_value(t, call_type, "function_call")
}

@(test)
test_responses_encode_skips_unreplayable_reasoning :: proc(t: ^testing.T) {
	// A reasoning item the endpoint returned without encrypted content cannot
	// satisfy the request schema (it wants encrypted_content or a summary), so
	// it is skipped rather than sent.
	messages := make([]Provider_Message, 2, context.temp_allocator)
	messages[0] = Provider_Message {
		Role         = .Reasoning,
		Reasoning_ID = "rs_1",
	}
	messages[1] = Provider_Message {
		Role    = .Assistant,
		Content = "Done.",
	}
	request := Provider_Request {
		API              = .OpenAI_Responses,
		Model_Present    = true,
		Model            = "gpt-5.6",
		Messages_Present = true,
		Messages         = messages,
	}
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object, ok := value.(json.Object)
	testing.expect(t, ok)
	input, input_ok := object["input"].(json.Array)
	testing.expect(t, input_ok && len(input) == 1)
	only, only_ok := input[0].(json.Object)
	testing.expect(t, only_ok)
	role, _, _ := openai_value_string(only, "role")
	testing.expect_value(t, role, "assistant")
}

@(test)
test_responses_stream_function_call_roundtrip :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Responses, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	events := consume(
		t,
		`{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"shell","arguments":""}}`,
		&state,
		0,
	)
	events = consume(t, `{"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"X"}`, &state, 0)
	events = consume(t, `{"type":"response.function_call_arguments.done","output_index":0,"item_id":"fc_1","arguments":"{}"}`, &state, 0)
	events = consume(
		t,
		strings.concatenate(
			[]string {
				`{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":100,`,
				`"output_tokens":10,"total_tokens":110,"input_tokens_details":{"cached_tokens":40,"cache_write_tokens":0}}}}`,
			},
			context.temp_allocator,
		),
		&state,
		2,
	)
	usage := expect_event(t, events[0], Provider_Usage_Event)
	testing.expect_value(t, usage.Cached_Input_Tokens, 40)
	completed := expect_event(t, events[1], Provider_Completed_Event)
	testing.expect_value(t, completed.Reason, Provider_Finish_Reason.Tool_Call)
	testing.expect(t, len(completed.Tool_Calls) == 1)
	testing.expect_value(t, completed.Tool_Calls[0].ID, "call_1")
	testing.expect_value(t, completed.Tool_Calls[0].Item_ID, "fc_1")
	testing.expect_value(t, completed.Tool_Calls[0].Name, "shell")
	testing.expect_value(t, completed.Tool_Calls[0].Arguments, "{}")
	destroy_events(events)
}

@(test)
test_responses_failure_with_usage :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Responses, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	events := consume(
		t,
		strings.concatenate(
			[]string {
				`{"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"boom"},`,
				`"usage":{"input_tokens":5,"output_tokens":0,"total_tokens":5}}}`,
			},
			context.temp_allocator,
		),
		&state,
		2,
	)
	usage := expect_event(t, events[0], Provider_Usage_Event)
	testing.expect_value(t, usage.Input_Tokens, 5)
	failure := expect_event(t, events[1], Provider_Error_Event)
	testing.expect_value(t, failure.Kind, Provider_Error_Kind.API_Error)
	testing.expect_value(t, failure.Message, "boom")
	destroy_events(events)
}

@(test)
test_responses_malformed_terminal_yields_error_only :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Responses, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	err := Provider_Consume_SSE_Data(`{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":"bad"}}}`, &state)
	testing.expect_value(t, err, Provider_Stream_Error.Malformed_Event)
	events := drain_events(&state)
	testing.expect_value(t, len(events), 1)
	failure := expect_event(t, events[0], Provider_Error_Event)
	testing.expect_value(t, failure.Kind, Provider_Error_Kind.Invalid_Data)
	destroy_events(events)
}

@(test)
test_chat_stream_tool_call_roundtrip :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	frag_a := `{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_9","function":{"name":"shell","arguments":"{}"}}]},"role":"assistant"}]}`
	frag_b := `{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":""}}]},"role":"assistant"}]}`
	events := consume(t, frag_a, &state, 0)
	events = consume(t, frag_b, &state, 0)
	events = consume(t, `{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}`, &state, 1)
	completed := expect_event(t, events[0], Provider_Completed_Event)
	testing.expect_value(t, completed.Reason, Provider_Finish_Reason.Tool_Call)
	testing.expect(t, len(completed.Tool_Calls) == 1)
	testing.expect_value(t, completed.Tool_Calls[0].ID, "call_9")
	testing.expect_value(t, completed.Tool_Calls[0].Name, "shell")
	destroy_events(events)
}

@(test)
test_chat_text_finish_usage_one_payload :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	events := consume(
		t,
		`{"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":2,"total_tokens":9}}`,
		&state,
		3,
	)
	text := expect_event(t, events[0], Provider_Text_Event)
	testing.expect_value(t, text.Text, "Hi")
	usage := expect_event(t, events[1], Provider_Usage_Event)
	testing.expect_value(t, usage.Input_Tokens, 7)
	completed := expect_event(t, events[2], Provider_Completed_Event)
	testing.expect_value(t, completed.Reason, Provider_Finish_Reason.Stop)
	destroy_events(events)
}

@(test)
test_chat_multiple_calls_text_completion :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	_ = consume(
		t,
		`{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"shell","arguments":"{"}},{"index":1,"id":"call_b","function":{"name":"shell","arguments":"{"}}]}}]}`,
		&state,
		0,
	)
	events := consume(
		t,
		strings.concatenate(
			[]string {
				`{"choices":[{"index":0,"delta":{"content":"done","tool_calls":[{"index":0,"function":{"arguments":"}"}},`,
				`{"index":1,"function":{"arguments":"}"}}]},"finish_reason":"tool_calls"}],`,
				`"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}`,
			},
			context.temp_allocator,
		),
		&state,
		3,
	)
	text := expect_event(t, events[0], Provider_Text_Event)
	testing.expect_value(t, text.Text, "done")
	usage := expect_event(t, events[1], Provider_Usage_Event)
	testing.expect_value(t, usage.Output_Tokens, 2)
	completed := expect_event(t, events[2], Provider_Completed_Event)
	testing.expect_value(t, completed.Reason, Provider_Finish_Reason.Tool_Call)
	testing.expect(t, len(completed.Tool_Calls) == 2)
	testing.expect_value(t, completed.Tool_Calls[0].Arguments, "{}")
	testing.expect_value(t, completed.Tool_Calls[1].Arguments, "{}")
	destroy_events(events)
}

@(test)
test_chat_usage_only_after_completion :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	events := consume(t, `{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`, &state, 1)
	destroy_events(events)
	events = consume(t, `{"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}`, &state, 1)
	usage := expect_event(t, events[0], Provider_Usage_Event)
	testing.expect_value(t, usage.Input_Tokens, 3)
	testing.expect_value(t, usage.Output_Tokens, 1)
	destroy_events(events)
}

@(test)
test_chat_cache_write_without_cached_tokens :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	events := consume(
		t,
		`{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":1,"total_tokens":10,"prompt_tokens_details":{"cache_write_tokens":9}}}`,
		&state,
		2,
	)
	usage := expect_event(t, events[0], Provider_Usage_Event)
	testing.expect_value(t, usage.Input_Tokens, 9)
	testing.expect(t, !usage.Cached_Input_Tokens_Present)
	testing.expect(t, usage.Cache_Write_Tokens_Present)
	testing.expect_value(t, usage.Cache_Write_Tokens, 9)
	destroy_events(events)
}

@(test)
test_chat_malformed_trailing_field_discards_text :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	err := Provider_Consume_SSE_Data(`{"choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":123}]}`, &state)
	testing.expect_value(t, err, Provider_Stream_Error.Malformed_Event)
	events := drain_events(&state)
	testing.expect_value(t, len(events), 1)
	failure := expect_event(t, events[0], Provider_Error_Event)
	testing.expect_value(t, failure.Kind, Provider_Error_Kind.Invalid_Data)
	destroy_events(events)
}

@(test)
test_chat_extra_choices_rejected :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	err := Provider_Consume_SSE_Data(`{"choices":[{"index":0,"delta":{"content":"a"}},{"index":1,"delta":{"content":"b"}}]}`, &state)
	testing.expect_value(t, err, Provider_Stream_Error.Malformed_Event)
	events := drain_events(&state)
	testing.expect_value(t, len(events), 1)
	_ = expect_event(t, events[0], Provider_Error_Event)
	destroy_events(events)
}

@(test)
test_chat_bare_sentinel_is_truncation :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	err := Provider_Consume_SSE_Data("[DONE]", &state)
	testing.expect_value(t, err, Provider_Stream_Error.Stream_Truncated)
	events := drain_events(&state)
	testing.expect_value(t, len(events), 1)
	failure := expect_event(t, events[0], Provider_Error_Event)
	testing.expect_value(t, failure.Kind, Provider_Error_Kind.Stream_Truncated)
	destroy_events(events)
}

@(test)
test_chat_premature_eof_is_truncation :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	events := consume(t, `{"choices":[{"index":0,"delta":{"content":"hi"}}]}`, &state, 1)
	destroy_events(events)
	err := Provider_Stream_Finish(&state)
	testing.expect_value(t, err, Provider_Stream_Error.Stream_Truncated)
	events = drain_events(&state)
	testing.expect_value(t, len(events), 1)
	_ = expect_event(t, events[0], Provider_Error_Event)
	destroy_events(events)
}

@(test)
test_chat_completion_without_sentinel_is_clean :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	events := consume(t, `{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`, &state, 1)
	destroy_events(events)
	err := Provider_Stream_Finish(&state)
	testing.expect_value(t, err, Provider_Stream_Error.None)
	testing.expect_value(t, state.Phase, Provider_Stream_Phase.Done)
	events = drain_events(&state)
	testing.expect_value(t, len(events), 0)
}

@(test)
test_chat_duplicate_completion_rejected :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	events := consume(t, `{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`, &state, 1)
	destroy_events(events)
	err := Provider_Consume_SSE_Data(`{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`, &state)
	testing.expect_value(t, err, Provider_Stream_Error.Malformed_Event)
	events = drain_events(&state)
	testing.expect_value(t, len(events), 1)
	_ = expect_event(t, events[0], Provider_Error_Event)
	destroy_events(events)
}

@(test)
test_chat_data_after_termination_rejected :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	events := consume(t, `{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`, &state, 1)
	destroy_events(events)
	err := Provider_Consume_SSE_Data("[DONE]", &state)
	testing.expect_value(t, err, Provider_Stream_Error.None)
	err = Provider_Consume_SSE_Data(`{"choices":[{"index":0,"delta":{"content":"more"}}]}`, &state)
	testing.expect_value(t, err, Provider_Stream_Error.Malformed_Event)
	events = drain_events(&state)
	testing.expect_value(t, len(events), 1)
	_ = expect_event(t, events[0], Provider_Error_Event)
	destroy_events(events)
}

@(test)
test_undrained_events_destroyed_with_stream :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.allocator)
	err := Provider_Consume_SSE_Data(
		`{"choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`,
		&state,
	)
	testing.expect_value(t, err, Provider_Stream_Error.None)
	testing.expect_value(t, state.Batch_Count, 3)
	// Destroying without draining must release every staged payload.
	Provider_Stream_Destroy(&state)
}

@(test)
test_batch_not_drained_rejected :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	err := Provider_Consume_SSE_Data(`{"choices":[{"index":0,"delta":{"content":"a"}}]}`, &state)
	testing.expect_value(t, err, Provider_Stream_Error.None)
	testing.expect_value(t, state.Batch_Count, 1)
	err = Provider_Consume_SSE_Data(`{"choices":[{"index":0,"delta":{"content":"b"}}]}`, &state)
	testing.expect_value(t, err, Provider_Stream_Error.Batch_Not_Drained)
	events := drain_events(&state)
	testing.expect_value(t, len(events), 1)
	text := expect_event(t, events[0], Provider_Text_Event)
	testing.expect_value(t, text.Text, "a")
	destroy_events(events)
}

Test_Record :: struct {
	sequence: [dynamic]string,
}

test_record_callback :: proc(user_data: rawptr, event: Provider_Event) {
	record := cast(^Test_Record)user_data
	description := ""
	#partial switch value in event {
	case Provider_Text_Event:
		description = fmt.aprintf("text:%s", value.Text, allocator = context.temp_allocator)
	case Provider_Usage_Event:
		description = fmt.aprintf("usage:%d:%d", value.Input_Tokens, value.Output_Tokens, allocator = context.temp_allocator)
	case Provider_Completed_Event:
		description = fmt.aprintf("completed:%d", len(value.Tool_Calls), allocator = context.temp_allocator)
	case Provider_Error_Event:
		description = fmt.aprintf("error:%d", int(value.Kind), allocator = context.temp_allocator)
	}
	append(&record.sequence, description)
}

run_request_chunks :: proc(api: API_Kind, chunks: []string) -> [dynamic]string {
	record := Test_Record {
		sequence = make([dynamic]string, 0, context.temp_allocator),
	}
	state := Provider_Request_Stream_State {
		stream    = Provider_Stream_Start(api, context.temp_allocator),
		api       = api,
		user_data = &record,
		callback  = test_record_callback,
		allocator = context.temp_allocator,
	}
	sse.parser_init(&state.parser, provider_sse_event, &state, allocator = context.temp_allocator)
	defer sse.parser_destroy(&state.parser)
	defer Provider_Event_Destroy(&state.completion, context.temp_allocator)
	defer Provider_Stream_Destroy(&state.stream)
	for chunk in chunks {
		sse.parser_feed(&state.parser, transmute([]u8)chunk)
	}
	sse.parser_finish(&state.parser)
	stream_err := Provider_Stream_Finish(&state.stream)
	provider_drain_events(&state)
	if stream_err != .None && !state.failed {
		provider_emit_error(&state, .Stream_Truncated, provider_stream_error_text(stream_err))
	}
	if !state.failed && state.stream.Phase == .Done && state.completion != nil {
		provider_deliver(&state, state.completion)
		state.completion = nil
	}
	return record.sequence
}

chunk_text :: proc(text: string, width: int) -> []string {
	chunks := make([dynamic]string, 0, context.temp_allocator)
	for index := 0; index < len(text); index += width {
		end := index + width
		if end > len(text) { end = len(text) }
		append(&chunks, text[index:end])
	}
	return chunks[:]
}

sequences_equal :: proc(a, b: [dynamic]string) -> bool {
	if len(a) != len(b) { return false }
	for index in 0 ..< len(a) { if a[index] != b[index] { return false } }
	return true
}

@(test)
test_request_callback_sequence_stable_across_fragmentation :: proc(t: ^testing.T) {
	chat := strings.concatenate(
		[]string {
			"data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"}}]}\n\n",
			"data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"shell\",\"arguments\":\"{}\"}}]}}]}\n\n",
			"data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
			"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}\n\n",
			"data: [DONE]\n\n",
		},
		context.temp_allocator,
	)
	whole := run_request_chunks(.OpenAI_Chat_Completions, []string{chat})
	testing.expect_value(t, len(whole), 3)
	testing.expect_value(t, whole[0], "text:Hello")
	testing.expect_value(t, whole[1], "usage:10:5")
	testing.expect_value(t, whole[2], "completed:1")
	bytewise := run_request_chunks(.OpenAI_Chat_Completions, chunk_text(chat, 1))
	testing.expect(t, sequences_equal(whole, bytewise))
	sevens := run_request_chunks(.OpenAI_Chat_Completions, chunk_text(chat, 7))
	testing.expect(t, sequences_equal(whole, sevens))
}

@(test)
test_responses_request_sequence_stable_across_fragmentation :: proc(t: ^testing.T) {
	responses := strings.concatenate(
		[]string {
			"event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}\n\n",
			"event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":4,\"output_tokens\":2,\"total_tokens\":6}}}\n\n",
		},
		context.temp_allocator,
	)
	whole := run_request_chunks(.OpenAI_Responses, []string{responses})
	testing.expect_value(t, len(whole), 3)
	testing.expect_value(t, whole[0], "text:Hi")
	testing.expect_value(t, whole[1], "usage:4:2")
	testing.expect_value(t, whole[2], "completed:0")
	bytewise := run_request_chunks(.OpenAI_Responses, chunk_text(responses, 1))
	testing.expect(t, sequences_equal(whole, bytewise))
	split := run_request_chunks(.OpenAI_Responses, chunk_text(responses, 5))
	testing.expect(t, sequences_equal(whole, split))
}

@(test)
test_request_failure_suppresses_retained_completion :: proc(t: ^testing.T) {
	chat := strings.concatenate(
		[]string{"data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n", "data: {not json}\n\n"},
		context.temp_allocator,
	)
	// The completion is retained, then a parsing failure arrives before the
	// transport finishes: the completion must be suppressed and only the
	// error callback delivered.
	whole := run_request_chunks(.OpenAI_Chat_Completions, []string{chat})
	testing.expect_value(t, len(whole), 1)
	testing.expect_value(t, whole[0], "error:0")
}

// The provider boundary no longer judges the argument document; the agent does,
// and it compares decoded keys. The schema check stays here because the
// request encoder still requires an object-shaped schema.
@(test)
test_tool_args_reject_duplicates :: proc(t: ^testing.T) {
	testing.expect(t, openai_tool_schema_valid(`{"type":"object","properties":{},"required":[],"additionalProperties":false}`))
	testing.expect(t, !openai_tool_schema_valid(`[1]`))
}

// The output bound goes out in the field every current model accepts. The older
// max_tokens spelling is deprecated and the reasoning models reject it, so a
// request that used it would fail on exactly the models that need a bound most.
@(test)
test_chat_encode_output_bound_uses_the_current_field :: proc(t: ^testing.T) {
	messages := make([]Provider_Message, 1, context.temp_allocator)
	messages[0] = Provider_Message {
		Role    = .User,
		Content = "Hi.",
	}
	request := Provider_Request {
		API                       = .OpenAI_Chat_Completions,
		Model_Present             = true,
		Model                     = "gpt-5.6",
		Messages_Present          = true,
		Messages                  = messages,
		Max_Output_Tokens_Present = true,
		Max_Output_Tokens         = 64,
	}
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	testing.expect_value(t, err, Provider_Request_Error.None)
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(t, object_ok) { return }
	bound, present, bound_ok := openai_value_integer(object, "max_completion_tokens")
	testing.expect(t, bound_ok && present)
	testing.expect_value(t, bound, i64(64))
	_, deprecated := object["max_tokens"]
	testing.expect(t, !deprecated, "the deprecated field must not be sent")
}
