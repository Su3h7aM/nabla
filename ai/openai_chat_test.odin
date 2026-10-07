#+test
package ai

import "core:encoding/json"
import "core:testing"

@(test)
test_chat_stream_error_uses_error_type_fallback :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)

	err := Provider_Consume_SSE_Data(`{"error":{"code":"unknown_code","type":"server_error","message":"provider failed"}}`, &state)
	if !testing.expect_value(t, err, Provider_Stream_Error.None) { return }
	event, drained := Provider_Stream_Drain(&state)
	if !testing.expect(t, drained) { return }
	defer Provider_Event_Destroy(&event, context.temp_allocator)
	failure, is_failure := event.(Provider_Error_Event)
	if !testing.expect(t, is_failure) { return }
	class := provider_classify_failure(
		Provider_Evidence {
			api = .OpenAI_Chat_Completions,
			kind = .Stream,
			event = failure.Kind,
			rejection = {code = failure.Provider_Code, message = failure.Message},
		},
	)
	testing.expect_value(t, class, Provider_Failure_Class.Provider_Unavailable)
}

@(test)
test_chat_tool_calls_follow_wire_index :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	err := Provider_Consume_SSE_Data(
		`{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_1","function":{"name":"second","arguments":"{}"}},{"index":0,"id":"call_0","function":{"name":"first","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}`,
		&state,
	)
	if !testing.expect_value(t, err, Provider_Stream_Error.None) { return }
	event, drained := Provider_Stream_Drain(&state)
	if !testing.expect(t, drained) { return }
	defer Provider_Event_Destroy(&event, context.temp_allocator)
	completed, is_completed := event.(Provider_Completed_Event)
	if !testing.expect(t, is_completed) { return }
	if !testing.expect_value(t, len(completed.Tool_Calls), 2) { return }
	testing.expect_value(t, completed.Tool_Calls[0].ID, "call_0")
	testing.expect_value(t, completed.Tool_Calls[0].Name, "first")
	testing.expect_value(t, completed.Tool_Calls[1].ID, "call_1")
	testing.expect_value(t, completed.Tool_Calls[1].Name, "second")
}

@(test)
test_chat_stream_delivers_refusal_delta_as_text :: proc(t: ^testing.T) {
	state := Provider_Stream_Start(.OpenAI_Chat_Completions, context.temp_allocator)
	defer Provider_Stream_Destroy(&state)
	err := Provider_Consume_SSE_Data(`{"choices":[{"delta":{"refusal":"I cannot help with that."},"finish_reason":null}]}`, &state)
	if !testing.expect_value(t, err, Provider_Stream_Error.None) { return }
	event, drained := Provider_Stream_Drain(&state)
	if !testing.expect(t, drained) { return }
	defer Provider_Event_Destroy(&event, context.temp_allocator)
	text, is_text := event.(Provider_Text_Event)
	if !testing.expect(t, is_text) { return }
	testing.expect_value(t, text.Text, "I cannot help with that.")
}

@(test)
test_chat_tool_only_assistant_omits_content :: proc(t: ^testing.T) {
	request := Provider_Request {
		API              = .OpenAI_Chat_Completions,
		Model_Present    = true,
		Model            = "gpt-5.6",
		Messages_Present = true,
		Messages         = []Provider_Message{{Role = .Assistant, Tool_Calls = []Provider_Tool_Call{{ID = "call_1", Name = "shell", Arguments = "{}"}}}},
	}
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	if !testing.expect_value(t, err, Provider_Request_Error.None) { return }
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	if !testing.expect_value(t, parse_err, nil) { return }
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(t, object_ok) { return }
	messages, messages_ok := object["messages"].(json.Array)
	if !testing.expect(t, messages_ok && len(messages) == 1) { return }
	assistant, assistant_ok := messages[0].(json.Object)
	if !testing.expect(t, assistant_ok) { return }
	_, content_present := assistant["content"]
	testing.expect(t, !content_present)
	_, tool_calls_present := assistant["tool_calls"]
	testing.expect(t, tool_calls_present)
}

@(test)
test_chat_encode_keeps_prompt_cache_options_ttl :: proc(t: ^testing.T) {
	request := Provider_Request {
		API = .OpenAI_Chat_Completions,
		Model_Present = true,
		Model = "gpt-5.6",
		Messages_Present = true,
		Messages = []Provider_Message{{Role = .User, Content = "Hi."}},
		Prompt_Cache_Options_Present = true,
		Prompt_Cache_Options = Prompt_Cache_Options{Mode_Present = true, Mode = .Implicit, TTL_Present = true, TTL = "30m"},
	}
	body, err := Provider_Encode_Request(request, context.temp_allocator)
	if !testing.expect_value(t, err, Provider_Request_Error.None) { return }
	value, parse_err := json.parse_string(body, .JSON, true, context.temp_allocator)
	if !testing.expect_value(t, parse_err, nil) { return }
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(t, object_ok) { return }
	options, options_ok := object["prompt_cache_options"].(json.Object)
	if !testing.expect(t, options_ok) { return }
	ttl, ttl_present, ttl_ok := provider_json_string(options, "ttl")
	testing.expect(t, ttl_ok && ttl_present && ttl == "30m")
	_, retention_present := object["prompt_cache_retention"]
	testing.expect(t, !retention_present)
}
