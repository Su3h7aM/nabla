package ai

import "core:encoding/json"
import "core:mem"
import "core:strings"

openai_responses_encode_request :: proc(request: Provider_Request, allocator := context.allocator) -> (string, Provider_Request_Error) {
	if err := Provider_Validate_Request(request); err != .None { return "", err }
	for tool in request.Tools {
		if !openai_tool_schema_valid(tool.Parameters_JSON) { return "", .Invalid_Tools }
	}
	object := make(json.Object, 8, allocator)
	object[strings.clone("model", allocator)] = json.String(strings.clone(request.Model, allocator))
	if request.Instructions_Present {
		object[strings.clone("instructions", allocator)] = json.String(strings.clone(request.Instructions, allocator))
	}
	input := make(json.Array, 0, len(request.Messages), allocator)
	for message in request.Messages {
		// A verbatim message carries the endpoint's own items. They are emitted
		// here, where they sit among the projected messages, so the request keeps
		// the conversation's real order. Re-deriving them would lose phase,
		// status, annotations, and summaries, and would send assistant content
		// twice.
		if message.Verbatim_Items != "" {
			items, parse_err := json.parse_string(message.Verbatim_Items, .JSON, true, allocator)
			if parse_err != nil { return "", .Invalid_Message }
			array, is_array := items.(json.Array)
			if !is_array {
				json.destroy_value(items, allocator)
				return "", .Invalid_Message
			}
			for item in array { append(&input, json.Value(json.clone_value(item, allocator))) }
			json.destroy_value(items, allocator)
			continue
		}
		if message.Role == .Reasoning {
			// A reasoning item is replayable only when the endpoint returned
			// encrypted content: without it the item carries nothing the
			// endpoint can continue from, and it is skipped rather than sent.
			if message.Reasoning_Encrypted == "" {
				continue
			}
			// The request schema requires a summary on every replayed reasoning
			// item, empty or not; summaries are display-only and were never
			// kept, so the replayed one is empty.
			summaries := make(json.Array, 0, 0, allocator)
			reasoning := make(json.Object, 4, allocator)
			reasoning[strings.clone("type", allocator)] = json.String(strings.clone("reasoning", allocator))
			reasoning[strings.clone("id", allocator)] = json.String(strings.clone(message.Reasoning_ID, allocator))
			reasoning[strings.clone("summary", allocator)] = json.Value(summaries)
			if message.Reasoning_Encrypted != "" {
				reasoning[strings.clone("encrypted_content", allocator)] = json.String(strings.clone(message.Reasoning_Encrypted, allocator))
			}
			append(&input, json.Value(reasoning))
			continue
		}
		if message.Role == .Tool {
			output := make(json.Object, 3, allocator)
			output[strings.clone("type", allocator)] = json.String(strings.clone("function_call_output", allocator))
			output[strings.clone("call_id", allocator)] = json.String(strings.clone(message.Tool_Call_ID, allocator))
			output[strings.clone("output", allocator)] = json.String(strings.clone(message.Content, allocator))
			append(&input, json.Value(output))
			continue
		}
		if len(message.Tool_Calls) > 0 {
			for call in message.Tool_Calls {
				entry := make(json.Object, 5, allocator)
				entry[strings.clone("type", allocator)] = json.String(strings.clone("function_call", allocator))
				if call.Item_ID != "" { entry[strings.clone("id", allocator)] = json.String(strings.clone(call.Item_ID, allocator)) }
				entry[strings.clone("call_id", allocator)] = json.String(strings.clone(call.ID, allocator))
				entry[strings.clone("name", allocator)] = json.String(strings.clone(call.Name, allocator))
				entry[strings.clone("arguments", allocator)] = json.String(strings.clone(call.Arguments, allocator))
				append(&input, json.Value(entry))
			}
			if message.Content != "" {
				text_item := make(json.Object, 2, allocator)
				text_item[strings.clone("role", allocator)] = json.String(strings.clone(openai_role_name(message.Role), allocator))
				text_item[strings.clone("content", allocator)] = json.String(strings.clone(message.Content, allocator))
				append(&input, json.Value(text_item))
			}
			continue
		}
		item := make(json.Object, 2, allocator)
		item[strings.clone("role", allocator)] = json.String(strings.clone(openai_role_name(message.Role), allocator))
		if message.Cache_Breakpoint {
			part := make(json.Object, 3, allocator)
			part[strings.clone("type", allocator)] = json.String(strings.clone("input_text", allocator))
			part[strings.clone("text", allocator)] = json.String(strings.clone(message.Content, allocator))
			breakpoint := make(json.Object, 1, allocator)
			breakpoint[strings.clone("mode", allocator)] = json.String(strings.clone("explicit", allocator))
			part[strings.clone("prompt_cache_breakpoint", allocator)] = json.Value(breakpoint)
			parts := make(json.Array, 0, 1, allocator)
			append(&parts, json.Value(part))
			item[strings.clone("content", allocator)] = json.Value(parts)
		} else {
			item[strings.clone("content", allocator)] = json.String(strings.clone(message.Content, allocator))
		}
		append(&input, json.Value(item))
	}
	object[strings.clone("input", allocator)] = json.Value(input)
	if len(request.Tools) > 0 {
		tools := make(json.Array, 0, len(request.Tools), allocator)
		for tool in request.Tools {
			append(&tools, openai_responses_tool_def(tool, allocator))
		}
		object[strings.clone("tools", allocator)] = json.Value(tools)
	}
	if request.Max_Output_Tokens_Present { object[strings.clone("max_output_tokens", allocator)] = json.Integer(request.Max_Output_Tokens) }
	if request.Reasoning_Effort_Present {
		reasoning := make(json.Object, 1, allocator)
		reasoning[strings.clone("effort", allocator)] = json.String(strings.clone(request.Reasoning_Effort, allocator))
		object[strings.clone("reasoning", allocator)] = json.Value(reasoning)
	}
	if request.Prompt_Cache_Key_Present { object[strings.clone("prompt_cache_key", allocator)] = json.String(strings.clone(request.Prompt_Cache_Key, allocator)) }
	if request.Prompt_Cache_Options_Present {
		options := make(json.Object, 2, allocator)
		if request.Prompt_Cache_Options.Mode_Present {
			mode_text := "implicit"
			if request.Prompt_Cache_Options.Mode == .Explicit { mode_text = "explicit" }
			options[strings.clone("mode", allocator)] = json.String(strings.clone(mode_text, allocator))
		}
		if request.Prompt_Cache_Options.TTL_Present { options[strings.clone("ttl", allocator)] = json.String(strings.clone(request.Prompt_Cache_Options.TTL, allocator)) }
		object[strings.clone("prompt_cache_options", allocator)] = json.Value(options)
	}
	if request.Prompt_Cache_Retention_Present { object[strings.clone("prompt_cache_retention", allocator)] = json.String(strings.clone(request.Prompt_Cache_Retention, allocator)) }
	if request.Store_Response_Present { object[strings.clone("store", allocator)] = json.Boolean(request.Store_Response) }
	object[strings.clone("stream", allocator)] = json.Boolean(true)
	value := json.Value(object)
	// Keys are sorted so the same conversation encodes to the same bytes every
	// time, including in a later process. Map iteration order is otherwise
	// allocation-dependent, which would move bytes inside the cached prefix.
	result, err := json.unparse(value, {sort_maps_by_key = true}, allocator)
	json.destroy_value(value, allocator)
	if err != nil { return "", .Invalid_Message }
	return result, .None
}

openai_responses_parse_usage :: proc(object: json.Object) -> (Provider_Usage_Event, bool) {
	usage := Provider_Usage_Event{}
	ok := true
	usage.Input_Tokens, usage.Input_Tokens_Present, ok = openai_value_integer(object, "input_tokens")
	if !ok { return {}, false }
	usage.Output_Tokens, usage.Output_Tokens_Present, ok = openai_value_integer(object, "output_tokens")
	if !ok { return {}, false }
	usage.Total_Tokens, usage.Total_Tokens_Present, ok = openai_value_integer(object, "total_tokens")
	if !ok { return {}, false }
	if raw_details, present := object["input_tokens_details"]; present {
		if _, is_null := raw_details.(json.Null); !is_null {
			details, details_ok := raw_details.(json.Object)
			if !details_ok { return {}, false }
			usage.Cached_Input_Tokens, usage.Cached_Input_Tokens_Present, ok = openai_value_integer(details, "cached_tokens")
			if !ok || (usage.Cached_Input_Tokens_Present && usage.Cached_Input_Tokens < 0) { return {}, false }
			usage.Cache_Write_Tokens, usage.Cache_Write_Tokens_Present, ok = openai_value_integer(details, "cache_write_tokens")
			if !ok || (usage.Cache_Write_Tokens_Present && usage.Cache_Write_Tokens < 0) { return {}, false }
		}
	}
	return usage, true
}

openai_responses_incomplete_reason :: proc(reason: string) -> Provider_Finish_Reason {
	if reason == "max_output_tokens" || reason == "max_messages" { return .Length }
	if reason == "content_filter" { return .Content_Filter }
	return .Unknown
}

// openai_responses_clone_output clones the terminal response's output array
// verbatim for the replay record. A missing, null, or empty array replays as
// empty: there are no items to replay, and the harness falls back to its own
// projection for that response rather than sending an empty native record. ok
// is false only when a present value cannot be stringified. The caller owns the
// result on success.
openai_responses_clone_output :: proc(response: json.Object, allocator := context.allocator) -> (cloned: string, ok: bool) {
	raw_output_value, output_present := response["output"]
	if !output_present { return "", true }
	if _, is_null := raw_output_value.(json.Null); is_null { return "", true }
	if array, is_array := raw_output_value.(json.Array); is_array && len(array) == 0 { return "", true }
	text, clone_err := json.unparse(raw_output_value, allocator = allocator)
	if clone_err != nil { return "", false }
	return text, true
}

provider_tool_fragment_by_item :: proc(object: json.Object, state: ^Provider_Stream_State, allocator := context.allocator) -> (^Provider_Tool_Fragment, bool) {
	id, present, ok := openai_value_string(object, "item_id")
	if !ok || !present || id == "" { state^.Phase = .Failed; return nil, false }
	for &fragment in state.Tool_Fragments {
		if fragment.Present && fragment.Item_ID == id { return &fragment, true }
	}
	fragment, slot_ok := provider_tool_fragment(state, provider_tool_call_count(state))
	if !slot_ok { state^.Phase = .Failed; return nil, false }
	fragment.Item_ID = strings.clone(id, state.Allocator)
	return fragment, true
}

openai_responses_call_slot :: proc(object, item: json.Object, state: ^Provider_Stream_State, allocator: mem.Allocator) -> (^Provider_Tool_Fragment, bool) {
	if id, present, ok := openai_value_string(item, "id"); ok && present && id != "" {
		for &fragment in state.Tool_Fragments {
			if fragment.Present && fragment.Item_ID == id { return &fragment, true }
		}
	}
	if index, present, ok := openai_value_integer(object, "output_index"); ok && present {
		for &fragment in state.Tool_Fragments {
			if fragment.Present && fragment.Wire_Index == index { return &fragment, true }
		}
		fragment, slot_ok := provider_tool_fragment(state, provider_tool_call_count(state))
		if !slot_ok { state^.Phase = .Failed; return nil, false }
		fragment.Wire_Index = index
		fragment.Wire_Index_Present = true
		return fragment, true
	}
	fragment, slot_ok := provider_tool_fragment(state, provider_tool_call_count(state))
	if !slot_ok { state^.Phase = .Failed; return nil, false }
	return fragment, true
}

openai_responses_tool_def :: proc(tool: Provider_Tool_Def, allocator := context.allocator) -> json.Value {
	definition := make(json.Object, 5, allocator)
	definition[strings.clone("type", allocator)] = json.String(strings.clone("function", allocator))
	definition[strings.clone("name", allocator)] = json.String(strings.clone(tool.Name, allocator))
	definition[strings.clone("description", allocator)] = json.String(strings.clone(tool.Description, allocator))
	schema, parse_err := json.parse_string(tool.Parameters_JSON, .JSON, true, allocator)
	if parse_err == nil {
		defer json.destroy_value(schema, allocator)
		definition[strings.clone("parameters", allocator)] = json.Value(json.clone_value(schema, allocator))
	}
	// Strict schema enforcement is not set: it requires every property to be
	// required, which would make an optional argument mandatory and push the model
	// into filling it with an empty value. The tool's own schema and the harness's
	// reading of it are the contract.
	return json.Value(definition)
}

openai_responses_call_event :: proc(object: json.Object, state: ^Provider_Stream_State, done: bool) -> Provider_Stream_Error {
	raw, item_present := object["item"]
	item: json.Object
	if done {
		if !item_present { return provider_stream_fail(state, .Invalid_Data, "done item has no item") }
		var, item_ok := raw.(json.Object)
		if !item_ok { return provider_stream_fail(state, .Invalid_Data, "done item is not an object") }
		item = var
	} else if item_present {
		var, item_ok := raw.(json.Object)
		if !item_ok { return provider_stream_fail(state, .Invalid_Data, "added item is not an object") }
		item = var
	}
	if item != nil {
		item_type, type_present, type_ok := openai_value_string(item, "type")
		if !type_ok || !type_present { return provider_stream_fail(state, .Invalid_Data, "output item has no type") }
		if item_type == "message" { return .None }
		if item_type == "reasoning" {
			// The added event may not carry the id yet; the done item
			// repeats the whole reasoning item, so capture there. The
			// endpoint needs id plus encrypted_content back to continue
			// reasoning; summaries are display-only and are not replayed.
			if !done { return .None }
			id, id_present, id_ok := openai_value_string(item, "id")
			if !id_ok || !id_present || id == "" { return provider_stream_fail(state, .Invalid_Data, "reasoning item has no id") }
			encrypted, _, encrypted_ok := openai_value_string(item, "encrypted_content")
			if !encrypted_ok { return provider_stream_fail(state, .Invalid_Data, "reasoning content is invalid") }
			provider_stream_push(
				state,
				Provider_Reasoning_Event{ID = strings.clone(id, state.Allocator), Encrypted = strings.clone(encrypted, state.Allocator)},
			)
			return .None
		}
		fragment, slot_ok := openai_responses_call_slot(object, item, state, state.Allocator)
		if !slot_ok { return provider_stream_fail(state, .Invalid_Data, "tool call has no slot") }
		if item_type != "function_call" {
			return provider_stream_fail(state, .Unsupported_Tool_Output, "Responses tool output is unsupported", .None)
		}
		if id, present, ok := openai_value_string(item, "id"); ok && present && id != "" {
			if fragment.Item_ID != "" && fragment.Item_ID != id { return provider_stream_fail(state, .Invalid_Data, "output item id changed") }
			if fragment.Item_ID == "" { fragment.Item_ID = strings.clone(id, state.Allocator) }
		} else if !ok { return provider_stream_fail(state, .Invalid_Data, "output item id is invalid") }
		if id, present, ok := openai_value_string(item, "call_id"); ok && present && id != "" {
			if fragment.ID != "" && fragment.ID != id { return provider_stream_fail(state, .Invalid_Data, "call id changed") }
			if fragment.ID == "" { fragment.ID = strings.clone(id, state.Allocator) }
		} else if !ok { return provider_stream_fail(state, .Invalid_Data, "call id is invalid") }
		if name, present, ok := openai_value_string(item, "name"); ok && present && name != "" {
			if fragment.Name != "" && fragment.Name != name { return provider_stream_fail(state, .Invalid_Data, "call name changed") }
			if fragment.Name == "" { fragment.Name = strings.clone(name, state.Allocator) }
		} else if !ok { return provider_stream_fail(state, .Invalid_Data, "call name is invalid") }
		if args, present, ok := openai_value_string(item, "arguments"); ok && present && args != "" {
			// The done item repeats the full arguments already streamed
			// as deltas; replace so a replayed payload is not doubled.
			if len(args) > PROVIDER_MAX_TOOL_ARGS_BYTES { return provider_stream_fail(state, .Invalid_Data, "tool arguments exceed limit", .Tool_Limit) }
			clear(&fragment.Arguments)
			append(&fragment.Arguments, args)
		} else if !ok { return provider_stream_fail(state, .Invalid_Data, "call arguments are invalid") }
		fragment.Present = true
		if done { fragment.Complete = true }
	}
	return .None
}

openai_responses_terminal :: proc(event_type: string, object: json.Object, state: ^Provider_Stream_State) -> Provider_Stream_Error {
	raw, response_present := object["response"]
	if !response_present { return provider_stream_fail(state, .Invalid_Data, "response event has no response") }
	response, ok := raw.(json.Object)
	if !ok { return provider_stream_fail(state, .Invalid_Data, "response is not an object") }
	usage := Provider_Usage_Event{}
	usage_present := false
	if raw_usage, present := response["usage"]; present {
		if _, is_null := raw_usage.(json.Null); !is_null {
			usage_object, usage_ok := raw_usage.(json.Object)
			if !usage_ok { return provider_stream_fail(state, .Invalid_Data, "response usage is invalid") }
			parsed: bool
			usage, parsed = openai_responses_parse_usage(usage_object)
			if !parsed { return provider_stream_fail(state, .Invalid_Data, "response usage is invalid") }
			usage_present = true
		}
	}
	switch event_type {
	case "response.completed":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "duplicate response completion") }
		// The terminal output array is the replay record, so clone it before
		// finalizing calls: a finalize failure returns here and must release it.
		// An absent or empty array is not an error; a completed response may
		// carry usage alone.
		raw_output, output_ok := openai_responses_clone_output(response, state.Allocator)
		if !output_ok { return provider_stream_fail(state, .Invalid_Data, "response output is invalid") }
		calls: []Provider_Tool_Call
		if provider_tool_fragments_present(state) {
			finalized, finalized_ok := provider_tool_finalize(state, state.Allocator)
			if !finalized_ok {
				delete(raw_output, state.Allocator)
				return provider_stream_fail(state, .Invalid_Data, "tool calls are invalid")
			}
			calls = finalized
		}
		if usage_present { provider_stream_push(state, Provider_Usage_Event(usage)) }
		state^.Phase = .Completed
		// The push takes ownership of raw_output on every path.
		if calls != nil {
			provider_stream_push(
				state,
				Provider_Completed_Event {
					Reason = .Tool_Call,
					Reason_Text = strings.clone("tool_calls", state.Allocator),
					Tool_Calls = calls,
					Raw_Output = raw_output,
				},
			)
		} else {
			provider_stream_push(
				state,
				Provider_Completed_Event{Reason = .Stop, Reason_Text = strings.clone("completed", state.Allocator), Raw_Output = raw_output},
			)
		}
		return .None
	case "response.incomplete":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "duplicate response completion") }
		reason := "incomplete"
		if raw_details, present := response["incomplete_details"]; present {
			if _, is_null := raw_details.(json.Null); !is_null {
				details, details_ok := raw_details.(json.Object)
				if !details_ok { return provider_stream_fail(state, .Invalid_Data, "incomplete details are invalid") }
				detail_reason, _, reason_ok := openai_value_string(details, "reason")
				if !reason_ok { return provider_stream_fail(state, .Invalid_Data, "incomplete details are invalid") }
				if detail_reason != "" { reason = detail_reason }
			}
		}
		if usage_present { provider_stream_push(state, Provider_Usage_Event(usage)) }
		state^.Phase = .Completed
		provider_stream_push(
			state,
			Provider_Completed_Event{Reason = openai_responses_incomplete_reason(reason), Reason_Text = strings.clone(reason, state.Allocator)},
		)
		return .None
	case "response.failed":
		message := "response failed"
		code := ""
		if raw_error, present := response["error"]; present {
			if _, is_null := raw_error.(json.Null); !is_null {
				error_object, error_ok := raw_error.(json.Object)
				if !error_ok { return provider_stream_fail(state, .Invalid_Data, "response error is invalid") }
				error_message, _, message_ok := openai_value_string(error_object, "message")
				error_code, _, code_ok := openai_value_string(error_object, "code")
				if !message_ok || !code_ok { return provider_stream_fail(state, .Invalid_Data, "response error is invalid") }
				if error_message != "" { message = error_message }
				code = error_code
			}
		}
		// A failed response may still carry usage. Deliver usage first, then
		// the error; a malformed terminal payload yields the error alone.
		if usage_present { provider_stream_push(state, Provider_Usage_Event(usage)) }
		state^.Phase = .Failed
		provider_stream_push(state, openai_error_event(.API_Error, message, code, state.Allocator))
		return .None
	}
	return provider_stream_fail(state, .Invalid_Data, "unknown terminal response event")
}

openai_responses_consume_sse_data :: proc(payload: string, state: ^Provider_Stream_State) -> Provider_Stream_Error {
	if state == nil || state^.API != .OpenAI_Responses { return .Invalid_State }
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
	event_type, type_present, type_ok := openai_value_string(object, "type")
	if !type_ok || !type_present || event_type == "" { return provider_stream_fail(state, .Invalid_Data, "stream event has no type") }
	switch event_type {
	case "response.output_text.delta", "response.refusal.delta":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "data received after completion") }
		delta, delta_present, delta_ok := openai_value_string(object, "delta")
		if !delta_ok { return provider_stream_fail(state, .Invalid_Data, "delta is not text") }
		if delta_present && delta != "" { provider_stream_push(state, Provider_Text_Event{Text = strings.clone(delta, state.Allocator)}) }
		return .None
	case "response.completed", "response.incomplete", "response.failed":
		return openai_responses_terminal(event_type, object, state)
	case "response.output_item.added":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "data received after completion") }
		return openai_responses_call_event(object, state, false)
	case "response.output_item.done":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "data received after completion") }
		return openai_responses_call_event(object, state, true)
	case "error":
		message, _, message_ok := openai_value_string(object, "message")
		if !message_ok { return provider_stream_fail(state, .Invalid_Data, "error message is invalid") }
		if message == "" { message = "provider returned an API error" }
		code, _, code_ok := openai_value_string(object, "code")
		if !code_ok { return provider_stream_fail(state, .Invalid_Data, "error code is invalid") }
		provider_stream_batch_clear(state)
		provider_stream_push(state, openai_error_event(.API_Error, message, code, state.Allocator))
		state^.Phase = .Failed
		return .None
	case "response.function_call_arguments.delta":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "data received after completion") }
		fragment, slot_ok := provider_tool_fragment_by_item(object, state)
		if !slot_ok { return provider_stream_fail(state, .Invalid_Data, "arguments delta has no call") }
		if id, present, ok := openai_value_string(object, "item_id"); ok && present && id != "" {
			if fragment.Item_ID != "" && fragment.Item_ID != id { return provider_stream_fail(state, .Invalid_Data, "output item id changed") }
			if fragment.Item_ID == "" { fragment.Item_ID = strings.clone(id, state.Allocator) }
		} else if !ok { return provider_stream_fail(state, .Invalid_Data, "item id is invalid") }
		delta, delta_present, delta_ok := openai_value_string(object, "delta")
		if !delta_ok { return provider_stream_fail(state, .Invalid_Data, "arguments delta is not text") }
		if delta_present && delta != "" {
			if len(fragment.Arguments) + len(delta) > PROVIDER_MAX_TOOL_ARGS_BYTES {
				return provider_stream_fail(state, .Invalid_Data, "tool arguments exceed limit", .Tool_Limit)
			}
			append(&fragment.Arguments, delta)
		}
		fragment.Present = true
		return .None
	case "response.function_call_arguments.done":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "data received after completion") }
		fragment, slot_ok := provider_tool_fragment_by_item(object, state)
		if !slot_ok { return provider_stream_fail(state, .Invalid_Data, "arguments done has no call") }
		if id, present, ok := openai_value_string(object, "item_id"); ok && present && id != "" {
			if fragment.Item_ID != "" && fragment.Item_ID != id { return provider_stream_fail(state, .Invalid_Data, "output item id changed") }
			if fragment.Item_ID == "" { fragment.Item_ID = strings.clone(id, state.Allocator) }
		} else if !ok { return provider_stream_fail(state, .Invalid_Data, "item id is invalid") }
		if args, present, ok := openai_value_string(object, "arguments"); ok && present && args != "" {
			// The done event repeats full arguments; replace the
			// accumulated bytes so a replayed prefix is not doubled.
			if len(args) > PROVIDER_MAX_TOOL_ARGS_BYTES { return provider_stream_fail(state, .Invalid_Data, "tool arguments exceed limit", .Tool_Limit) }
			clear(&fragment.Arguments)
			append(&fragment.Arguments, args)
		} else if !ok { return provider_stream_fail(state, .Invalid_Data, "call arguments are invalid") }
		fragment.Present = true
		fragment.Complete = true
		return .None
	case:
		return .None
	}
}
