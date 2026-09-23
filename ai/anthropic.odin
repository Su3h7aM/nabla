package ai

import "core:encoding/json"
import "core:mem"
import "core:strings"

// The Anthropic Messages API. It shares the request contract but not the wire
// shape: a system prompt that is its own top-level field, tool calls and results
// as content blocks with an explicit block type, and usage whose input count
// excludes everything the prompt cache served. Every one of those differences is
// present here rather than flattened into a common form, because flattening
// loses exactly the fields that make a later request replay faithfully.
//
// Extended thinking is not requested by this adapter, so no thinking block is
// expected on the way back. A response that carries one is not a failure: the
// block is ignored instead of breaking an answer the model already produced.
ANTHROPIC_VERSION :: "2023-06-01"

// The block type names this adapter understands. Anything else is either
// provider-hosted work this harness did not ask for or a protocol addition, and
// neither can be executed here.
ANTHROPIC_BLOCK_TEXT :: "text"
ANTHROPIC_BLOCK_TOOL_USE :: "tool_use"
ANTHROPIC_BLOCK_TOOL_RESULT :: "tool_result"

// --- encoding ----------------------------------------------------------------

// anthropic_encode_request writes one Messages request body as bytes. The body is mostly
// text the cache already holds: the instruction lane, every tool's schema, every tool
// result, and the arguments of every call. A text that did not change is copied rather
// than read and written again.
anthropic_encode_request :: proc(
	request: Provider_Request,
	cache: ^Provider_Encode_Cache,
	allocator := context.allocator,
) -> (
	string,
	Provider_Request_Error,
) {
	if err := Provider_Validate_Request(request); err != .None { return "", err }
	// max_tokens has no default in this API: it is required, and inventing one
	// would either truncate an answer or silently pick a bound the model does not
	// share.
	if !request.Max_Output_Tokens_Present { return "", .Missing_Max_Output_Tokens }
	for tool in request.Tools {
		if !openai_tool_schema_valid(tool.Parameters_JSON) { return "", .Invalid_Tools }
	}

	cursor := encode_cursor(cache, allocator)
	body := encode_body_make(&cursor, allocator)
	defer strings.builder_destroy(&body)

	// Fields are written in the order the standard library's writer sorts them in, so a
	// body is the bytes a parsed request would be written as, and the same conversation
	// writes the same bytes in any process.
	first := true
	encode_write_raw(&body, "{")
	if request.Cache_Request_Present && request.Cache_Request {
		// Top-level cache control marks the last cacheable block and advances as
		// the conversation grows, so an append-only history reuses its whole
		// prefix without the harness naming a breakpoint.
		encode_write_field(&body, &first, "cache_control")
		encode_write_raw(&body, "{\"type\":")
		encode_write_literal_string(&body, "ephemeral")
		encode_write_raw(&body, "}")
	}
	encode_write_field(&body, &first, "max_tokens")
	encode_write_int(&body, request.Max_Output_Tokens)
	encode_write_field(&body, &first, "messages")
	encode_write_raw(&body, "[")
	if messages_err := anthropic_write_messages(&cursor, &body, request.Messages, allocator); messages_err != .None {
		return "", messages_err
	}
	encode_write_raw(&body, "]")
	encode_write_field(&body, &first, "model")
	encode_write_text(&cursor, &body, request.Model)
	if request.Reasoning_Effort_Present {
		// The effort name is opaque and travels verbatim. Anthropic states it as a
		// level under output_config, which is the same shape the harness stores.
		encode_write_field(&body, &first, "output_config")
		encode_write_raw(&body, "{\"effort\":")
		encode_write_text(&cursor, &body, request.Reasoning_Effort)
		encode_write_raw(&body, "}")
	}
	encode_write_field(&body, &first, "stream")
	encode_write_bool(&body, true)
	if request.Instructions_Present {
		encode_write_field(&body, &first, "system")
		encode_write_text(&cursor, &body, request.Instructions)
	}
	if len(request.Tools) > 0 {
		encode_write_field(&body, &first, "tools")
		encode_write_raw(&body, "[")
		tool_first := true
		for tool in request.Tools {
			encode_write_item(&body, &tool_first)
			if !anthropic_write_tool_def(&cursor, &body, tool, allocator) { return "", .Invalid_Tools }
		}
		encode_write_raw(&body, "]")
	}
	encode_write_raw(&body, "}")
	encode_finish(&cursor)
	encode_body_store(&cursor, &body)
	return strings.clone(strings.to_string(body), allocator), .None
}

// anthropic_write_messages projects the conversation onto the Messages API. The
// projection is not mechanical: this API requires roles to alternate, so
// consecutive user content is one user turn. Text and tool results accumulate
// into the open user turn until something that is not user content ends it. A
// turn that ends up holding exactly one text block is emitted in the plain
// string form, so an ordinary conversation encodes to the bytes it always has.
@(private)
anthropic_write_messages :: proc(
	cursor: ^Encode_Cursor,
	body: ^strings.Builder,
	messages: []Provider_Message,
	allocator: mem.Allocator,
) -> Provider_Request_Error {
	item_first := true
	// The open user turn: the text and tool results the messages in it carry, and
	// whether exactly one text block is among them. The turn is written when a message
	// that is not user content ends it, so what it holds is counted as it is handed over.
	open := -1
	open_blocks := 0
	open_texts := 0
	turns := 0

	for message, index in messages {
		switch message.Role {
		case .System, .Reasoning:
			// The system prompt is the instruction lane, and a replayed reasoning
			// item has no representation here. Neither may be sent as a turn.
			continue
		case .User:
			if message.Content == "" { continue }
			if open < 0 { open = index }
			open_blocks += 1
			open_texts += 1
		case .Tool:
			if message.Tool_Call_ID == "" { return .Invalid_Message }
			if open < 0 { open = index }
			open_blocks += 1
		case .Assistant:
			if open_blocks > 0 {
				if err := anthropic_write_user_turn(cursor, body, messages[open:index], open_blocks, open_texts, &item_first); err != .None {
					return err
				}
				turns += 1
				open = -1
				open_blocks = 0
				open_texts = 0
			}
			// This API opens a conversation with a user turn. The only assistant
			// turn that can come first is the checkpoint summary the harness
			// carries, which is harness-authored context rather than something the
			// model said, so it opens the conversation instead of being a message
			// the API would refuse.
			role := "assistant"
			if turns == 0 && len(message.Tool_Calls) == 0 { role = "user" }
			encode_write_item(body, &item_first)
			field_first := true
			encode_write_raw(body, "{")
			encode_write_field(body, &field_first, "content")
			if len(message.Tool_Calls) == 0 {
				encode_write_text(cursor, body, message.Content)
			} else {
				encode_write_raw(body, "[")
				block_first := true
				if message.Content != "" {
					encode_write_item(body, &block_first)
					anthropic_write_text_block(cursor, body, message.Content)
				}
				for call in message.Tool_Calls {
					encode_write_item(body, &block_first)
					if err := anthropic_write_tool_use(cursor, body, call, allocator); err != .None { return err }
				}
				encode_write_raw(body, "]")
			}
			encode_write_field(body, &field_first, "role")
			encode_write_literal_string(body, role)
			encode_write_raw(body, "}")
			turns += 1
		case .Invalid:
			return .Invalid_Message
		}
	}
	if open_blocks > 0 {
		if err := anthropic_write_user_turn(cursor, body, messages[open:], open_blocks, open_texts, &item_first); err != .None { return err }
	}
	return .None
}

// anthropic_write_user_turn writes the open user turn. One text block goes out as the
// plain string this API has always accepted for a text turn; anything else is written as
// the blocks it carries, in the order the conversation hands them over.
@(private)
anthropic_write_user_turn :: proc(
	cursor: ^Encode_Cursor,
	body: ^strings.Builder,
	turn: []Provider_Message,
	blocks: int,
	texts: int,
	item_first: ^bool,
) -> Provider_Request_Error {
	encode_write_item(body, item_first)
	field_first := true
	encode_write_raw(body, "{")
	encode_write_field(body, &field_first, "content")
	if blocks == 1 && texts == 1 {
		for message in turn {
			if message.Role != .User || message.Content == "" { continue }
			encode_write_text(cursor, body, message.Content)
			break
		}
	} else {
		encode_write_raw(body, "[")
		block_first := true
		for message in turn {
			switch message.Role {
			case .User:
				if message.Content == "" { continue }
				encode_write_item(body, &block_first)
				anthropic_write_text_block(cursor, body, message.Content)
			case .Tool:
				encode_write_item(body, &block_first)
				if err := anthropic_write_tool_result(cursor, body, message); err != .None { return err }
			case .System, .Reasoning, .Assistant, .Invalid:
				continue
			}
		}
		encode_write_raw(body, "]")
	}
	encode_write_field(body, &field_first, "role")
	encode_write_literal_string(body, "user")
	encode_write_raw(body, "}")
	return .None
}

@(private)
anthropic_write_text_block :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder, text: string) {
	field_first := true
	encode_write_raw(body, "{")
	encode_write_field(body, &field_first, "text")
	encode_write_text(cursor, body, text)
	encode_write_field(body, &field_first, "type")
	encode_write_literal_string(body, ANTHROPIC_BLOCK_TEXT)
	encode_write_raw(body, "}")
}

// anthropic_write_tool_use writes a call as its content block. The arguments are a JSON
// object on the wire, so a call whose arguments are not one is replayed with an empty
// object: the id and name are preserved so the paired result still answers this call, and
// the rejection travels in that result rather than in invented arguments.
@(private)
anthropic_write_tool_use :: proc(
	cursor: ^Encode_Cursor,
	body: ^strings.Builder,
	call: Provider_Tool_Call,
	allocator: mem.Allocator,
) -> Provider_Request_Error {
	if call.ID == "" || call.Name == "" { return .Invalid_Tool_Call }
	field_first := true
	encode_write_raw(body, "{")
	encode_write_field(body, &field_first, "id")
	encode_write_text(cursor, body, call.ID)
	encode_write_field(body, &field_first, "input")
	if !encode_write_object(cursor, body, call.Arguments, allocator) { encode_write_raw(body, "{}") }
	encode_write_field(body, &field_first, "name")
	encode_write_text(cursor, body, call.Name)
	encode_write_field(body, &field_first, "type")
	encode_write_literal_string(body, ANTHROPIC_BLOCK_TOOL_USE)
	encode_write_raw(body, "}")
	return .None
}

@(private)
anthropic_write_tool_result :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder, message: Provider_Message) -> Provider_Request_Error {
	if message.Tool_Call_ID == "" { return .Invalid_Message }
	field_first := true
	encode_write_raw(body, "{")
	encode_write_field(body, &field_first, "content")
	encode_write_text(cursor, body, message.Content)
	if message.Tool_Is_Error {
		encode_write_field(body, &field_first, "is_error")
		encode_write_bool(body, true)
	}
	encode_write_field(body, &field_first, "tool_use_id")
	encode_write_text(cursor, body, message.Tool_Call_ID)
	encode_write_field(body, &field_first, "type")
	encode_write_literal_string(body, ANTHROPIC_BLOCK_TOOL_RESULT)
	encode_write_raw(body, "}")
	return .None
}

// anthropic_write_tool_def writes one tool definition. Its schema is the object the tool
// declared, written once and kept: a schema does not change between the requests of one
// conversation. Strict schema enforcement is not set: an optional argument has to stay
// optional, and the harness reads and validates the arguments itself.
@(private)
anthropic_write_tool_def :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder, tool: Provider_Tool_Def, allocator: mem.Allocator) -> bool {
	field_first := true
	encode_write_raw(body, "{")
	encode_write_field(body, &field_first, "description")
	encode_write_text(cursor, body, tool.Description)
	encode_write_field(body, &field_first, "input_schema")
	if !encode_write_object(cursor, body, tool.Parameters_JSON, allocator) { return false }
	encode_write_field(body, &field_first, "name")
	encode_write_text(cursor, body, tool.Name)
	encode_write_raw(body, "}")
	return true
}

// --- decoding ----------------------------------------------------------------

anthropic_stop_reason :: proc(reason: string) -> Provider_Finish_Reason {
	switch reason {
	case "end_turn", "stop_sequence":
		return .Stop
	case "max_tokens", "model_context_window_exceeded":
		return .Length
	case "tool_use":
		return .Tool_Call
	case "refusal":
		return .Content_Filter
	}
	// pause_turn and anything unrecognized: the response did not reach a usable
	// end, so it is reported as unknown and the reason text says why.
	return .Unknown
}

// anthropic_parse_usage reads one usage object. Anthropic reports input_tokens as
// only what the prompt cache did not serve, so the total the harness measures a
// hit rate against is the sum of the three input counts. Absent stays absent.
@(private)
anthropic_parse_usage :: proc(usage: json.Object) -> (Provider_Usage_Event, bool) {
	result := Provider_Usage_Event{}
	uncached, uncached_present, uncached_ok := anthropic_optional_integer(usage, "input_tokens")
	if !uncached_ok { return {}, false }
	if uncached_present {
		if uncached < 0 { return {}, false }
		read, read_present, read_ok := anthropic_optional_integer(usage, "cache_read_input_tokens")
		if !read_ok || (read_present && read < 0) { return {}, false }
		if read_present {
			result.Cached_Input_Tokens = read
			result.Cached_Input_Tokens_Present = true
		}
		written, written_present, written_ok := anthropic_optional_integer(usage, "cache_creation_input_tokens")
		if !written_ok || (written_present && written < 0) { return {}, false }
		if written_present {
			result.Cache_Write_Tokens = written
			result.Cache_Write_Tokens_Present = true
		}
		// Anthropic counts only what the cache did not serve, so the total the
		// harness measures a hit rate against is the sum of the three.
		total := uncached
		if result.Cached_Input_Tokens_Present { total += result.Cached_Input_Tokens }
		if result.Cache_Write_Tokens_Present { total += result.Cache_Write_Tokens }
		result.Input_Tokens = total
		result.Input_Tokens_Present = true
	}
	output, output_present, output_ok := anthropic_optional_integer(usage, "output_tokens")
	if !output_ok || (output_present && output < 0) { return {}, false }
	if output_present {
		result.Output_Tokens = output
		result.Output_Tokens_Present = true
	}
	return result, true
}

// anthropic_optional_integer reads an integer that may be absent or null. The
// two mean the same thing here: the provider did not state it.
@(private)
anthropic_optional_integer :: proc(object: json.Object, key: string) -> (value: i64, present: bool, ok: bool) {
	raw, exists := object[key]
	if !exists { return 0, false, true }
	if _, is_null := raw.(json.Null); is_null { return 0, false, true }
	return openai_value_integer(object, key)
}

// anthropic_block_fragment finds the tool-call slot a content block index maps
// to, or takes the next one. The block index counts every block, not just the
// tool calls, so it cannot be used as the slot number itself.
@(private)
anthropic_block_fragment :: proc(state: ^Provider_Stream_State, index: i64) -> (^Provider_Tool_Fragment, bool) {
	for &fragment in state.Tool_Fragments {
		if fragment.Wire_Index_Present && fragment.Wire_Index == index { return &fragment, true }
	}
	fragment := provider_tool_fragment_append(state)
	fragment.Wire_Index = index
	fragment.Wire_Index_Present = true
	return fragment, true
}

// anthropic_complete delivers the terminal event once the stream has stated why
// it ended. Anthropic states the reason in message_delta and closes in a separate
// message_stop, so the reason arrives before the end.
@(private)
anthropic_complete :: proc(state: ^Provider_Stream_State, reason_text: string) -> Provider_Stream_Error {
	reason := anthropic_stop_reason(reason_text)
	calls: []Provider_Tool_Call
	if reason == .Tool_Call {
		finalized, finalized_ok := provider_tool_finalize(state, state.Allocator)
		if !finalized_ok { return provider_stream_fail(state, .Invalid_Data, "tool calls are invalid") }
		calls = finalized
	} else if provider_tool_fragments_present(state) {
		// A tool block that never became a usable call is a defect, not a stop.
		return provider_stream_fail(state, .Invalid_Data, "response ended with unfinished tool calls")
	}
	state^.Phase = .Completed
	provider_stream_push(state, Provider_Completed_Event{Reason = reason, Reason_Text = strings.clone(reason_text, state.Allocator), Tool_Calls = calls})
	return .None
}

// anthropic_error_event reads the error envelope this API uses, which names the
// failure kind in `type` rather than `code`.
@(private)
anthropic_error_event :: proc(object: json.Object, allocator := context.allocator) -> (Provider_Event, bool) {
	raw, present := object["error"]
	if !present { return nil, false }
	error_object, ok := raw.(json.Object)
	if !ok { return openai_error_event(.API_Error, "invalid provider error object", allocator = allocator), true }
	message, _, message_ok := openai_value_string(error_object, "message")
	if !message_ok { return openai_error_event(.API_Error, "invalid provider error message", allocator = allocator), true }
	if message == "" { message = "provider returned an API error" }
	code, _, code_ok := openai_value_string(error_object, "type")
	if !code_ok { code = "" }
	return openai_error_event(.API_Error, message, code, allocator), true
}

// anthropic_error_rejection decodes the error document this API returns for a
// refused request, through the same reader an in-stream error event uses, so a
// refusal read from a response body and one read from a stream cannot drift apart.
// The returned strings are owned by allocator.
anthropic_error_rejection :: proc(body: []u8, allocator := context.allocator) -> Provider_Rejection {
	value, object, parsed := provider_error_document(body, allocator)
	if !parsed { return {} }
	defer json.destroy_value(value, allocator)
	event, is_error := anthropic_error_event(object, allocator)
	if !is_error { return {} }
	defer Provider_Event_Destroy(&event, allocator)
	error_event, is_error_event := event.(Provider_Error_Event)
	if !is_error_event { return {} }
	return Provider_Rejection {
		code = provider_bounded_text(error_event.Provider_Code, PROVIDER_MAX_CODE_BYTES, allocator),
		message = provider_bounded_text(error_event.Message, PROVIDER_MAX_MESSAGE_BYTES, allocator),
	}
}

// ANTHROPIC_CONTEXT_OVERFLOW_MESSAGE is this API's own wording for a rejected
// payload whose prompt was too long. It is the only prose this package reads, and
// only ever beside the single code that covers every malformed request.
ANTHROPIC_CONTEXT_OVERFLOW_MESSAGE :: "prompt is too long"

// anthropic_failure_class names the meaning this API gives to one of its own error
// types. `invalid_request_error` covers every malformed request, so overflow is
// read from the provider's own wording for it and nothing else: a mention of
// tokens or limits is not evidence, the way every other refusal stays unknown.
anthropic_failure_class :: proc(code, message: string) -> (Provider_Failure_Class, bool) {
	switch code {
	case "rate_limit_error":
		return .Rate_Limited, true
	case "overloaded_error":
		return .Provider_Unavailable, true
	case "authentication_error", "permission_error":
		return .Authentication, true
	case "invalid_request_error":
		if strings.contains(message, ANTHROPIC_CONTEXT_OVERFLOW_MESSAGE) { return .Context_Overflow, true }
		return .Invalid_Request, true
	}
	return .None, false
}

@(private)
anthropic_usage_from :: proc(object: json.Object, key: string, state: ^Provider_Stream_State) -> Provider_Stream_Error {
	raw, present := object[key]
	if !present { return .None }
	if _, is_null := raw.(json.Null); is_null { return .None }
	usage_object, ok := raw.(json.Object)
	if !ok { return provider_stream_fail(state, .Invalid_Data, "usage is not an object") }
	usage, parsed := anthropic_parse_usage(usage_object)
	if !parsed { return provider_stream_fail(state, .Invalid_Data, "usage is invalid") }
	provider_stream_push(state, Provider_Usage_Event(usage))
	return .None
}

anthropic_consume_sse_data :: proc(payload: string, state: ^Provider_Stream_State) -> Provider_Stream_Error {
	if state == nil || state^.API != .Anthropic_Messages { return .Invalid_State }
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
	if parse_err != nil {
		return provider_stream_fail(state, .Invalid_Data, "malformed provider stream JSON", .Invalid_JSON)
	}
	defer json.destroy_value(value, state.Allocator)
	object, object_ok := value.(json.Object)
	if !object_ok { return provider_stream_fail(state, .Invalid_Data, "stream event is not an object") }
	if api_error, is_error := anthropic_error_event(object, state.Allocator); is_error {
		provider_stream_batch_clear(state)
		provider_stream_push(state, api_error)
		state.Phase = .Failed
		return .None
	}
	event_type, type_present, type_ok := openai_value_string(object, "type")
	if !type_ok || !type_present || event_type == "" {
		return provider_stream_fail(state, .Invalid_Data, "stream event has no type")
	}

	switch event_type {
	case "message_start":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "data received after completion") }
		raw_message, present := object["message"]
		if !present { return provider_stream_fail(state, .Invalid_Data, "message_start has no message") }
		message, message_ok := raw_message.(json.Object)
		if !message_ok { return provider_stream_fail(state, .Invalid_Data, "message_start message is not an object") }
		return anthropic_usage_from(message, "usage", state)
	case "content_block_start":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "data received after completion") }
		index, index_present, index_ok := openai_value_integer(object, "index")
		if !index_ok || !index_present || index < 0 {
			return provider_stream_fail(state, .Invalid_Data, "content block has no index")
		}
		raw_block, present := object["content_block"]
		if !present { return provider_stream_fail(state, .Invalid_Data, "content_block_start has no block") }
		block, block_ok := raw_block.(json.Object)
		if !block_ok { return provider_stream_fail(state, .Invalid_Data, "content block is not an object") }
		block_type, _, block_type_ok := openai_value_string(block, "type")
		if !block_type_ok || block_type == "" { return provider_stream_fail(state, .Invalid_Data, "content block has no type") }
		switch block_type {
		case ANTHROPIC_BLOCK_TEXT:
			text, text_present, text_ok := openai_value_string(block, "text")
			if !text_ok { return provider_stream_fail(state, .Invalid_Data, "text block is invalid") }
			if text_present && text != "" {
				provider_stream_push(state, Provider_Text_Event{Text = strings.clone(text, state.Allocator)})
			}
		case ANTHROPIC_BLOCK_TOOL_USE:
			fragment, slot_ok := anthropic_block_fragment(state, index)
			if !slot_ok { return provider_stream_fail(state, .Invalid_Data, "tool block index is invalid", .Tool_Limit) }
			id, id_present, id_ok := openai_value_string(block, "id")
			if !id_ok || !id_present || id == "" { return provider_stream_fail(state, .Invalid_Data, "tool_use block has no id") }
			name, name_present, name_ok := openai_value_string(block, "name")
			if !name_ok || !name_present || name == "" { return provider_stream_fail(state, .Invalid_Data, "tool_use block has no name") }
			fragment.ID = strings.clone(id, state.Allocator)
			fragment.Name = strings.clone(name, state.Allocator)
			// The block states the input object up front and the stream fills it
			// afterwards. Keeping the stated value covers a call with no arguments,
			// which streams no delta at all.
			if raw_input, input_present := block["input"]; input_present {
				if _, is_null := raw_input.(json.Null); !is_null {
					if _, is_object := raw_input.(json.Object); !is_object {
						return provider_stream_fail(state, .Invalid_Data, "tool_use input is not an object")
					}
					text, text_err := json.unparse(raw_input, allocator = state.Allocator)
					if text_err != nil { return provider_stream_fail(state, .Invalid_Data, "tool_use input is invalid") }
					append(&fragment.Arguments, text)
					delete(text, state.Allocator)
				}
			}
			fragment.Present = true
		case "thinking", "redacted_thinking":
		// Not requested by this adapter; ignoring the block keeps an answer the
		// model already produced from being discarded.
		case:
			return provider_stream_fail(state, .Unsupported_Tool_Output, "unsupported content block", .None)
		}
		return .None
	case "content_block_delta":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "data received after completion") }
		raw_delta, present := object["delta"]
		if !present { return provider_stream_fail(state, .Invalid_Data, "content_block_delta has no delta") }
		delta, delta_ok := raw_delta.(json.Object)
		if !delta_ok { return provider_stream_fail(state, .Invalid_Data, "delta is not an object") }
		delta_type, _, delta_type_ok := openai_value_string(delta, "type")
		if !delta_type_ok || delta_type == "" { return provider_stream_fail(state, .Invalid_Data, "delta has no type") }
		switch delta_type {
		case "text_delta":
			text, text_present, text_ok := openai_value_string(delta, "text")
			if !text_ok { return provider_stream_fail(state, .Invalid_Data, "text delta is invalid") }
			if text_present && text != "" {
				provider_stream_push(state, Provider_Text_Event{Text = strings.clone(text, state.Allocator)})
			}
		case "input_json_delta":
			index, index_present, index_ok := openai_value_integer(object, "index")
			if !index_ok || !index_present || index < 0 {
				return provider_stream_fail(state, .Invalid_Data, "argument delta has no index")
			}
			fragment, slot_ok := anthropic_block_fragment(state, index)
			if !slot_ok { return provider_stream_fail(state, .Invalid_Data, "argument delta index is invalid", .Tool_Limit) }
			if !fragment.Present { return provider_stream_fail(state, .Invalid_Data, "argument delta has no block") }
			partial, partial_present, partial_ok := openai_value_string(delta, "partial_json")
			if !partial_ok { return provider_stream_fail(state, .Invalid_Data, "argument delta is invalid") }
			if partial_present && partial != "" {
				if !fragment.Arguments_Started {
					clear(&fragment.Arguments)
					fragment.Arguments_Started = true
				}
				if len(fragment.Arguments) + len(partial) > PROVIDER_MAX_TOOL_ARGS_BYTES {
					return provider_stream_fail(state, .Invalid_Data, "tool arguments exceed limit", .Tool_Limit)
				}
				append(&fragment.Arguments, partial)
			}
		case "thinking_delta", "signature_delta", "citations_delta":
		// Not modelled: this adapter requests no thinking and sends no
		// documents, so these updates carry nothing the harness can use.
		case:
		// An unknown delta type is a protocol addition, not a defect.
		}
		return .None
	case "content_block_stop":
		return .None
	case "message_delta":
		if err := anthropic_usage_from(object, "usage", state); err != .None { return err }
		if state^.Phase == .Completed { return .None }
		raw_delta, present := object["delta"]
		if !present { return .None }
		delta, delta_ok := raw_delta.(json.Object)
		if !delta_ok { return provider_stream_fail(state, .Invalid_Data, "message delta is not an object") }
		reason, reason_present, reason_ok := openai_value_string(delta, "stop_reason")
		if !reason_ok { return provider_stream_fail(state, .Invalid_Data, "stop_reason is invalid") }
		if !reason_present || reason == "" { return .None }
		return anthropic_complete(state, reason)
	case "message_stop":
		if state^.Phase == .Completed { return .None }
		// The stream ended without stating a reason. Reporting that is more honest
		// than reporting a truncated stream, because the response did end.
		return anthropic_complete(state, "")
	case "ping":
		return .None
	case:
		// The API adds event types over time and asks clients to ignore what they
		// do not know.
		return .None
	}
}
