package ai

import "core:encoding/json"
import "core:strings"

openai_chat_tool_def :: proc(tool: Provider_Tool_Def, allocator := context.allocator) -> (json.Value, bool) {
	schema, parse_err := json.parse_string(tool.Parameters_JSON, .JSON, true, allocator)
	if parse_err != nil { return nil, false }
	defer json.destroy_value(schema, allocator)
	if _, is_object := schema.(json.Object); !is_object { return nil, false }
	function := make(json.Object, 3, allocator)
	function[strings.clone("name", allocator)] = json.String(strings.clone(tool.Name, allocator))
	function[strings.clone("description", allocator)] = json.String(strings.clone(tool.Description, allocator))
	function[strings.clone("parameters", allocator)] = json.Value(json.clone_value(schema, allocator))
	definition := make(json.Object, 2, allocator)
	definition[strings.clone("type", allocator)] = json.String(strings.clone("function", allocator))
	definition[strings.clone("function", allocator)] = json.Value(function)
	return json.Value(definition), true
}

openai_chat_encode_request :: proc(request: Provider_Request, allocator := context.allocator) -> (string, Provider_Request_Error) {
	if err := Provider_Validate_Request(request); err != .None { return "", err }
	object := make(json.Object, 8, allocator)
	object[strings.clone("model", allocator)] = json.String(strings.clone(request.Model, allocator))
	// Chat Completions has no instruction field, so the lane becomes the leading
	// message it does understand. It is emitted here rather than carried in
	// request.Messages, because an instruction is not a conversation turn.
	capacity := len(request.Messages) + (1 if request.Instructions_Present else 0)
	messages := make(json.Array, 0, capacity, allocator)
	if request.Instructions_Present {
		instructions := make(json.Object, 2, allocator)
		instructions[strings.clone("role", allocator)] = json.String(strings.clone("system", allocator))
		instructions[strings.clone("content", allocator)] = json.String(strings.clone(request.Instructions, allocator))
		append(&messages, json.Value(instructions))
	}
	for message in request.Messages {
		// Chat Completions has no reasoning input; reasoning continuity is
		// a Responses replay contract, so these items are dropped here.
		if message.Role == .Reasoning { continue }
		item := make(json.Object, 4, allocator)
		item[strings.clone("role", allocator)] = json.String(strings.clone(openai_role_name(message.Role), allocator))
		if message.Role == .Assistant && len(message.Tool_Calls) > 0 {
			calls := make(json.Array, 0, len(message.Tool_Calls), allocator)
			for call in message.Tool_Calls {
				entry := make(json.Object, 3, allocator)
				entry[strings.clone("id", allocator)] = json.String(strings.clone(call.ID, allocator))
				entry[strings.clone("type", allocator)] = json.String(strings.clone("function", allocator))
				function := make(json.Object, 2, allocator)
				function[strings.clone("name", allocator)] = json.String(strings.clone(call.Name, allocator))
				function[strings.clone("arguments", allocator)] = json.String(strings.clone(call.Arguments, allocator))
				entry[strings.clone("function", allocator)] = json.Value(function)
				append(&calls, json.Value(entry))
			}
			item[strings.clone("tool_calls", allocator)] = json.Value(calls)
		}
		if message.Role == .Tool {
			item[strings.clone("tool_call_id", allocator)] = json.String(strings.clone(message.Tool_Call_ID, allocator))
		}
		if message.Cache_Breakpoint {
			part := make(json.Object, 3, allocator)
			part[strings.clone("type", allocator)] = json.String(strings.clone("text", allocator))
			part[strings.clone("text", allocator)] = json.String(strings.clone(message.Content, allocator))
			bp := make(json.Object, 1, allocator)
			bp[strings.clone("mode", allocator)] = json.String(strings.clone("explicit", allocator))
			part[strings.clone("prompt_cache_breakpoint", allocator)] = json.Value(bp)
			parts := make(json.Array, 0, 1, allocator)
			append(&parts, json.Value(part))
			item[strings.clone("content", allocator)] = json.Value(parts)
		} else {
			item[strings.clone("content", allocator)] = json.String(strings.clone(message.Content, allocator))
		}
		append(&messages, json.Value(item))
	}
	object[strings.clone("messages", allocator)] = json.Value(messages)
	if len(request.Tools) > 0 {
		tools := make(json.Array, 0, len(request.Tools), allocator)
		for tool in request.Tools {
			definition, ok := openai_chat_tool_def(tool, allocator)
			if !ok { return "", .Invalid_Tools }
			append(&tools, definition)
		}
		object[strings.clone("tools", allocator)] = json.Value(tools)
	}
	// The output bound is sent in the field every current model accepts. The older
	// `max_tokens` spelling is deprecated and is rejected outright by the reasoning
	// models, so there is no model for which it is the right choice.
	if request.Max_Output_Tokens_Present { object[strings.clone("max_completion_tokens", allocator)] = json.Integer(request.Max_Output_Tokens) }
	if request.Reasoning_Effort_Present {
		object[strings.clone("reasoning_effort", allocator)] = json.String(strings.clone(request.Reasoning_Effort, allocator))
	}
	if request.Prompt_Cache_Key_Present { object[strings.clone("prompt_cache_key", allocator)] = json.String(strings.clone(request.Prompt_Cache_Key, allocator)) }
	if request.Prompt_Cache_Options_Present {
		opts := make(json.Object, 2, allocator)
		if request.Prompt_Cache_Options.Mode_Present {
			mode_text := "implicit"
			if request.Prompt_Cache_Options.Mode == .Explicit { mode_text = "explicit" }
			opts[strings.clone("mode", allocator)] = json.String(strings.clone(mode_text, allocator))
		}
		if request.Prompt_Cache_Options.TTL_Present { opts[strings.clone("ttl", allocator)] = json.String(strings.clone(request.Prompt_Cache_Options.TTL, allocator)) }
		object[strings.clone("prompt_cache_options", allocator)] = json.Value(opts)
	}
	if request.Prompt_Cache_Retention_Present { object[strings.clone("prompt_cache_retention", allocator)] = json.String(strings.clone(request.Prompt_Cache_Retention, allocator)) }
	if request.Store_Response_Present { object[strings.clone("store", allocator)] = json.Boolean(request.Store_Response) }
	object[strings.clone("stream", allocator)] = json.Boolean(true)
	options := make(json.Object, 1, allocator)
	options[strings.clone("include_usage", allocator)] = json.Boolean(true)
	object[strings.clone("stream_options", allocator)] = json.Value(options)
	value := json.Value(object)
	// Keys are sorted so the same conversation encodes to the same bytes every
	// time, including in a later process. Map iteration order is otherwise
	// allocation-dependent, which would move bytes inside the cached prefix.
	result, err := json.unparse(value, {sort_maps_by_key = true}, allocator)
	json.destroy_value(value, allocator)
	if err != nil { return "", .Invalid_Message }
	return result, .None
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
