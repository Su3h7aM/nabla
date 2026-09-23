package ai

import "core:encoding/json"
import "core:strings"

// openai_chat_encode_request writes one Chat Completions request body. A body is
// bytes: each string the request carries is written through its slot in the cache, so
// the part of the conversation that did not change since the last request is copied
// rather than written again.
openai_chat_encode_request :: proc(
	request: Provider_Request,
	cache: ^Provider_Encode_Cache,
	allocator := context.allocator,
) -> (
	string,
	Provider_Request_Error,
) {
	if err := Provider_Validate_Request(request); err != .None { return "", err }
	cursor := encode_cursor(cache, allocator)
	body := encode_body_make(&cursor, allocator)
	defer strings.builder_destroy(&body)

	// Fields are written in the order the standard library's writer sorts them in, so a
	// body is the bytes a parsed request would be written as, and the same conversation
	// writes the same bytes in any process.
	first := true
	encode_write_raw(&body, "{")
	if request.Max_Output_Tokens_Present {
		// The output bound is sent in the field every current model accepts. The older
		// `max_tokens` spelling is deprecated and is rejected outright by the reasoning
		// models, so there is no model for which it is the right choice.
		encode_write_field(&body, &first, "max_completion_tokens")
		encode_write_int(&body, request.Max_Output_Tokens)
	}
	encode_write_field(&body, &first, "messages")
	encode_write_raw(&body, "[")
	item_first := true
	if request.Instructions_Present {
		// Chat Completions has no instruction field, so the lane becomes the leading
		// message it does understand. It is emitted here rather than carried in
		// request.Messages, because an instruction is not a conversation turn.
		if !item_first { strings.write_byte(&body, ',') }
		item_first = false
		field_first := true
		encode_write_raw(&body, "{")
		encode_write_field(&body, &field_first, "content")
		encode_write_text(&cursor, &body, request.Instructions)
		encode_write_field(&body, &field_first, "role")
		encode_write_literal_string(&body, "system")
		encode_write_raw(&body, "}")
	}
	for message in request.Messages {
		// Chat Completions has no reasoning input; reasoning continuity is
		// a Responses replay contract, so these items are dropped here.
		if message.Role == .Reasoning { continue }
		if !item_first { strings.write_byte(&body, ',') }
		item_first = false
		field_first := true
		encode_write_raw(&body, "{")
		if message.Cache_Breakpoint {
			encode_write_field(&body, &field_first, "content")
			encode_write_raw(&body, "[{")
			part_first := true
			encode_write_field(&body, &part_first, "prompt_cache_breakpoint")
			encode_write_raw(&body, "{")
			breakpoint_first := true
			encode_write_field(&body, &breakpoint_first, "mode")
			encode_write_literal_string(&body, "explicit")
			encode_write_raw(&body, "}")
			encode_write_field(&body, &part_first, "text")
			encode_write_text(&cursor, &body, message.Content)
			encode_write_field(&body, &part_first, "type")
			encode_write_literal_string(&body, "text")
			encode_write_raw(&body, "}]")
		} else {
			encode_write_field(&body, &field_first, "content")
			encode_write_text(&cursor, &body, message.Content)
		}
		encode_write_field(&body, &field_first, "role")
		encode_write_literal_string(&body, openai_role_name(message.Role))
		if message.Role == .Tool {
			encode_write_field(&body, &field_first, "tool_call_id")
			encode_write_text(&cursor, &body, message.Tool_Call_ID)
		}
		if message.Role == .Assistant && len(message.Tool_Calls) > 0 {
			encode_write_field(&body, &field_first, "tool_calls")
			encode_write_raw(&body, "[")
			for call, index in message.Tool_Calls {
				if index > 0 { strings.write_byte(&body, ',') }
				call_first := true
				encode_write_raw(&body, "{")
				encode_write_field(&body, &call_first, "function")
				encode_write_raw(&body, "{")
				function_first := true
				encode_write_field(&body, &function_first, "arguments")
				encode_write_text(&cursor, &body, call.Arguments)
				encode_write_field(&body, &function_first, "name")
				encode_write_text(&cursor, &body, call.Name)
				encode_write_raw(&body, "}")
				encode_write_field(&body, &call_first, "id")
				encode_write_text(&cursor, &body, call.ID)
				encode_write_field(&body, &call_first, "type")
				encode_write_literal_string(&body, "function")
				encode_write_raw(&body, "}")
			}
			encode_write_raw(&body, "]")
		}
		encode_write_raw(&body, "}")
	}
	encode_write_raw(&body, "]")
	encode_write_field(&body, &first, "model")
	encode_write_text(&cursor, &body, request.Model)
	if request.Prompt_Cache_Key_Present {
		encode_write_field(&body, &first, "prompt_cache_key")
		encode_write_text(&cursor, &body, request.Prompt_Cache_Key)
	}
	if request.Prompt_Cache_Options_Present {
		encode_write_field(&body, &first, "prompt_cache_options")
		encode_write_raw(&body, "{")
		options_first := true
		if request.Prompt_Cache_Options.Mode_Present {
			mode := "implicit"
			if request.Prompt_Cache_Options.Mode == .Explicit { mode = "explicit" }
			encode_write_field(&body, &options_first, "mode")
			encode_write_literal_string(&body, mode)
		}
		if request.Prompt_Cache_Options.TTL_Present {
			encode_write_field(&body, &options_first, "ttl")
			encode_write_literal_string(&body, request.Prompt_Cache_Options.TTL)
		}
		encode_write_raw(&body, "}")
	}
	if request.Prompt_Cache_Retention_Present {
		encode_write_field(&body, &first, "prompt_cache_retention")
		encode_write_text(&cursor, &body, request.Prompt_Cache_Retention)
	}
	if request.Reasoning_Effort_Present {
		encode_write_field(&body, &first, "reasoning_effort")
		encode_write_text(&cursor, &body, request.Reasoning_Effort)
	}
	if request.Store_Response_Present {
		encode_write_field(&body, &first, "store")
		encode_write_bool(&body, request.Store_Response)
	}
	encode_write_field(&body, &first, "stream")
	encode_write_bool(&body, true)
	encode_write_field(&body, &first, "stream_options")
	encode_write_raw(&body, "{")
	usage_first := true
	encode_write_field(&body, &usage_first, "include_usage")
	encode_write_bool(&body, true)
	encode_write_raw(&body, "}")
	if len(request.Tools) > 0 {
		encode_write_field(&body, &first, "tools")
		encode_write_raw(&body, "[")
		for tool, index in request.Tools {
			if index > 0 { strings.write_byte(&body, ',') }
			tool_first := true
			encode_write_raw(&body, "{")
			encode_write_field(&body, &tool_first, "function")
			encode_write_raw(&body, "{")
			function_first := true
			encode_write_field(&body, &function_first, "description")
			encode_write_text(&cursor, &body, tool.Description)
			encode_write_field(&body, &function_first, "name")
			encode_write_text(&cursor, &body, tool.Name)
			// A tool's parameters are the one part of a request that is JSON inside JSON:
			// the schema text is read once and the bytes are kept with the request's other
			// texts.
			if !openai_tool_parameters_write(&cursor, &body, &function_first, tool.Parameters_JSON) {
				return "", .Invalid_Tools
			}
			encode_write_raw(&body, "}")
			encode_write_field(&body, &tool_first, "type")
			encode_write_literal_string(&body, "function")
			encode_write_raw(&body, "}")
		}
		encode_write_raw(&body, "]")
	}
	encode_write_raw(&body, "}")
	encode_finish(&cursor)
	encode_body_store(&cursor, &body)
	return strings.clone(strings.to_string(body), allocator), .None
}

openai_chat_calls_open :: proc(state: ^Provider_Stream_State) -> bool {
	for &fragment in state.Tool_Fragments {
		if fragment.Present { return true }
	}
	return false
}

// A single Chat payload can carry text, usage, and a finish reason. Decode the
// whole object first, then stage events in that order so a malformed trailing
// field never exposes a partial batch.
openai_chat_consume_sse_data :: proc(payload: string, state: ^Provider_Stream_State) -> Provider_Stream_Error {
	if state == nil || state^.API != .OpenAI_Chat_Completions { return .Invalid_State }
	if payload == "[DONE]" {
		switch state.Phase {
		case .Open:
			return provider_stream_fail(state, .Stream_Truncated, "stream ended before completion", .Stream_Truncated)
		case .Completed:
			state.Phase = .Done
			return .None
		case .Done, .Failed:
			return .None
		}
	}
	if state^.Phase == .Done || state^.Phase == .Failed {
		return provider_stream_fail(state, .Invalid_Data, "data received after termination")
	}
	value, parse_err := json.parse_string(payload, .JSON, true, state.Allocator)
	if parse_err != nil { return provider_stream_fail(state, .Invalid_Data, "malformed provider stream JSON", .Invalid_JSON) }
	defer json.destroy_value(value, state.Allocator)
	object, object_ok := value.(json.Object)
	if !object_ok { return provider_stream_fail(state, .Invalid_Data, "stream event is not an object") }
	if api_error, is_error := openai_parse_api_error(object, state.Allocator); is_error {
		provider_stream_batch_clear(state)
		provider_stream_push(state, api_error)
		state.Phase = .Failed
		return .None
	}
	// Usage is parsed up front so it can be staged before a completion in the
	// same payload.
	raw_usage, usage_present := object["usage"]
	if _, is_null := raw_usage.(json.Null); is_null { usage_present = false }
	usage := Provider_Usage_Event{}
	if usage_present {
		usage_object, usage_ok := raw_usage.(json.Object)
		if !usage_ok { return provider_stream_fail(state, .Invalid_Data, "usage is not an object") }
		usage.Input_Tokens, usage.Input_Tokens_Present, usage_ok = openai_value_integer(usage_object, "prompt_tokens")
		if !usage_ok { return provider_stream_fail(state, .Invalid_Data, "invalid prompt_tokens") }
		usage.Output_Tokens, usage.Output_Tokens_Present, usage_ok = openai_value_integer(usage_object, "completion_tokens")
		if !usage_ok { return provider_stream_fail(state, .Invalid_Data, "invalid completion_tokens") }
		usage.Total_Tokens, usage.Total_Tokens_Present, usage_ok = openai_value_integer(usage_object, "total_tokens")
		if !usage_ok { return provider_stream_fail(state, .Invalid_Data, "invalid total_tokens") }
		if raw_details, details_present := usage_object["prompt_tokens_details"]; details_present {
			if _, details_is_null := raw_details.(json.Null); !details_is_null {
				details, details_ok := raw_details.(json.Object)
				if !details_ok { return provider_stream_fail(state, .Invalid_Data, "invalid prompt_tokens_details") }
				if raw_cached, cached_present := details["cached_tokens"]; cached_present {
					if _, cached_is_null := raw_cached.(json.Null); !cached_is_null {
						usage.Cached_Input_Tokens, usage.Cached_Input_Tokens_Present, details_ok = openai_value_integer(details, "cached_tokens")
						if !details_ok || usage.Cached_Input_Tokens < 0 { return provider_stream_fail(state, .Invalid_Data, "invalid cached_tokens") }
					}
				}
				if raw_write, write_present := details["cache_write_tokens"]; write_present {
					if _, write_is_null := raw_write.(json.Null); !write_is_null {
						usage.Cache_Write_Tokens, usage.Cache_Write_Tokens_Present, details_ok = openai_value_integer(details, "cache_write_tokens")
						if !details_ok || usage.Cache_Write_Tokens < 0 { return provider_stream_fail(state, .Invalid_Data, "invalid cache_write_tokens") }
					}
				}
			}
		}
	}
	raw_choices, choices_present := object["choices"]
	if !choices_present && !usage_present { return provider_stream_fail(state, .Invalid_Data, "event has no choices or usage") }
	choices: json.Array
	if choices_present {
		if _, is_null := raw_choices.(json.Null); !is_null {
			choices_ok: bool
			choices, choices_ok = raw_choices.(json.Array)
			if !choices_ok { return provider_stream_fail(state, .Invalid_Data, "choices is not an array") }
		}
	}
	if len(choices) > 1 { return provider_stream_fail(state, .Invalid_Data, "multiple choices are unsupported") }
	text_content := ""
	text_present := false
	tools_present := false
	reason := ""
	reason_present := false
	if len(choices) == 1 {
		choice, choice_ok := choices[0].(json.Object)
		if !choice_ok { return provider_stream_fail(state, .Invalid_Data, "choice is not an object") }
		raw_delta, delta_present := choice["delta"]
		if !delta_present { return provider_stream_fail(state, .Invalid_Data, "choice has no delta") }
		delta, delta_ok := raw_delta.(json.Object)
		if !delta_ok { return provider_stream_fail(state, .Invalid_Data, "delta is not an object") }
		if raw_tools, tools_field_present := delta["tool_calls"]; tools_field_present {
			if _, tools_field_is_null := raw_tools.(json.Null); !tools_field_is_null {
				tools, tools_ok := raw_tools.(json.Array)
				if !tools_ok { return provider_stream_fail(state, .Invalid_Data, "tool_calls is not an array") }
				tools_present = len(tools) > 0
				for entry in tools {
					fragment_delta, fragment_ok := entry.(json.Object)
					if !fragment_ok { return provider_stream_fail(state, .Invalid_Data, "tool call is not an object") }
					index, index_present, index_ok := openai_value_integer(fragment_delta, "index")
					if !index_ok || !index_present { return provider_stream_fail(state, .Invalid_Data, "tool call has no index") }
					fragment, slot_ok := provider_tool_fragment_by_wire_index(state, index)
					if !slot_ok { return provider_stream_fail(state, .Invalid_Data, "tool call index is invalid", .Tool_Limit) }
					if id, present, ok := openai_value_string(fragment_delta, "id"); ok && present && id != "" {
						if fragment.ID != "" && fragment.ID != id { return provider_stream_fail(state, .Invalid_Data, "tool call id changed") }
						if fragment.ID == "" { fragment.ID = strings.clone(id, state.Allocator) }
					} else if !ok { return provider_stream_fail(state, .Invalid_Data, "tool call id is invalid") }
					raw_function, function_present := fragment_delta["function"]
					if function_present {
						if _, is_null := raw_function.(json.Null); !is_null {
							function, function_ok := raw_function.(json.Object)
							if !function_ok { return provider_stream_fail(state, .Invalid_Data, "tool function is not an object") }
							if name, present, ok := openai_value_string(function, "name"); ok && present && name != "" {
								if fragment.Name != "" && fragment.Name != name { return provider_stream_fail(state, .Invalid_Data, "tool call name changed") }
								if fragment.Name == "" { fragment.Name = strings.clone(name, state.Allocator) }
							} else if !ok { return provider_stream_fail(state, .Invalid_Data, "tool call name is invalid") }
							if args, present, ok := openai_value_string(function, "arguments"); ok && present && args != "" {
								if len(fragment.Arguments) + len(args) > PROVIDER_MAX_TOOL_ARGS_BYTES {
									return provider_stream_fail(state, .Invalid_Data, "tool arguments exceed limit", .Tool_Limit)
								}
								append(&fragment.Arguments, args)
							} else if !ok { return provider_stream_fail(state, .Invalid_Data, "tool arguments are invalid") }
						}
					}
					fragment.Present = true
				}
			}
		}
		if raw_function, present := delta["function_call"]; present {
			if _, is_null := raw_function.(json.Null); !is_null {
				return provider_stream_fail(state, .Unsupported_Tool_Output, "OpenAI function call output is unsupported", .None)
			}
		}
		content, content_present, content_ok := openai_value_string(delta, "content")
		if !content_ok { return provider_stream_fail(state, .Invalid_Data, "delta content is not text") }
		if content_present && content != "" {
			text_content = content
			text_present = true
		}
		finish_text, finish_present, finish_ok := openai_value_string(choice, "finish_reason")
		if !finish_ok { return provider_stream_fail(state, .Invalid_Data, "finish_reason is invalid") }
		if finish_present && finish_text != "" {
			reason = finish_text
			reason_present = true
		}
	}
	if state^.Phase == .Completed && (text_present || tools_present || reason_present) {
		return provider_stream_fail(state, .Invalid_Data, "data received after completion")
	}
	if text_present { provider_stream_push(state, Provider_Text_Event{Text = strings.clone(text_content, state.Allocator)}) }
	if usage_present { provider_stream_push(state, Provider_Usage_Event(usage)) }
	if reason_present {
		finish := openai_finish_reason(reason)
		if finish == .Tool_Call {
			calls, calls_ok := provider_tool_finalize(state, state.Allocator)
			if !calls_ok { return provider_stream_fail(state, .Invalid_Data, "tool calls are invalid") }
			state^.Phase = .Completed
			provider_stream_push(
				state,
				Provider_Completed_Event{Reason = .Tool_Call, Reason_Text = strings.clone(reason, state.Allocator), Tool_Calls = calls},
			)
		} else {
			if openai_chat_calls_open(state) { return provider_stream_fail(state, .Invalid_Data, "response ended with unfinished tool calls") }
			state^.Phase = .Completed
			provider_stream_push(state, Provider_Completed_Event{Reason = finish, Reason_Text = strings.clone(reason, state.Allocator)})
		}
	}
	return .None
}
