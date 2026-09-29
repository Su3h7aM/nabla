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
// Adaptive thinking may be enabled by default, so signed and redacted thinking
// blocks must be preserved when the assistant turn is replayed after tool use.
ANTHROPIC_VERSION :: "2023-06-01"

// The block type names this adapter understands. Anything else is either
// provider-hosted work this harness did not ask for or a protocol addition, and
// neither can be executed here.
ANTHROPIC_BLOCK_TEXT :: "text"
ANTHROPIC_BLOCK_TOOL_USE :: "tool_use"
ANTHROPIC_BLOCK_TOOL_RESULT :: "tool_result"
ANTHROPIC_BLOCK_THINKING :: "thinking"
ANTHROPIC_BLOCK_REDACTED_THINKING :: "redacted_thinking"
ANTHROPIC_BLOCK_FALLBACK :: "fallback"

// --- encoding ----------------------------------------------------------------

// anthropic_encode_request writes one Messages request body, with a cache reusing the bytes
// it already holds for the texts this request carries again.
@(require_results)
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
	body, body_error := encode_body_begin(&cursor, allocator)
	if body_error != .None { return "", body_error }
	defer encode_body_end(&cursor)

	// Fields are written in the order the standard library's writer sorts them in, so a
	// body is the bytes a parsed request would be written as, and the same conversation
	// writes the same bytes in any process.
	first := true
	encode_write_raw(&cursor, body, "{")
	encode_write_field(&cursor, body, &first, "max_tokens")
	encode_write_int(&cursor, body, request.Max_Output_Tokens)
	encode_write_field(&cursor, body, &first, "messages")
	encode_write_raw(&cursor, body, "[")
	cached := request.Cache_Request_Present && request.Cache_Request
	if messages_err := anthropic_write_messages(&cursor, body, request.Messages, cached, allocator); messages_err != .None {
		encode_finish(&cursor)
		if cursor.error != .None { return "", cursor.error }
		return "", messages_err
	}
	encode_write_raw(&cursor, body, "]")
	encode_write_field(&cursor, body, &first, "model")
	encode_write_text(&cursor, body, request.Model)
	if request.Reasoning_Effort_Present {
		// The effort name is opaque and travels verbatim. Anthropic states it as a
		// level under output_config, which is the same shape the harness stores.
		encode_write_field(&cursor, body, &first, "output_config")
		encode_write_raw(&cursor, body, "{\"effort\":")
		encode_write_text(&cursor, body, request.Reasoning_Effort)
		encode_write_raw(&cursor, body, "}")
	}
	encode_write_field(&cursor, body, &first, "stream")
	encode_write_bool(&cursor, body, true)
	if request.Instructions_Present {
		encode_write_field(&cursor, body, &first, "system")
		encode_write_text(&cursor, body, request.Instructions)
	}
	if len(request.Tools) > 0 {
		encode_write_field(&cursor, body, &first, "tools")
		encode_write_raw(&cursor, body, "[")
		tool_first := true
		for tool in request.Tools {
			encode_write_item(&cursor, body, &tool_first)
			if !anthropic_write_tool_def(&cursor, body, tool, allocator) {
				encode_finish(&cursor)
				if cursor.error != .None { return "", cursor.error }
				return "", .Invalid_Tools
			}
		}
		encode_write_raw(&cursor, body, "]")
	}
	encode_write_raw(&cursor, body, "}")
	encode_finish(&cursor)
	if cursor.error != .None { return "", cursor.error }
	result, take_error := encode_body_take(&cursor)
	if take_error != .None { return "", take_error }
	return result, .None
}

// anthropic_write_messages projects the conversation onto the Messages API. The
// projection is not mechanical: this API requires roles to alternate, so
// consecutive user content is one user turn. Text and tool results accumulate
// into the open user turn until something that is not user content ends it. A
// turn that ends up holding exactly one text block is emitted in the plain
// string form, so an ordinary conversation encodes to the bytes it always has.
// Consecutive assistant entries are one turn too: native replay items, text, and
// tool calls remain in their response order without emitting adjacent roles.
//
// When cached is set, the last block of the last turn carries the cache breakpoint, so an
// append-only history reuses its whole prefix as the conversation grows. The breakpoint is
// written on the block rather than as the top-level field because the API refuses a
// top-level field whose lifetime differs from a marker already on that block, and not every
// endpoint of this API accepts the top-level field. A marker on the block is accepted by every
// endpoint and states no lifetime, so the endpoint's default applies.
@(private, require_results)
anthropic_write_messages :: proc(
	cursor: ^Encode_Cursor,
	body: ^strings.Builder,
	messages: []Provider_Message,
	cached: bool,
	allocator: mem.Allocator,
) -> Provider_Request_Error {
	// The last message that is written as a turn of its own; an open user turn written
	// after the loop is always the last one.
	last_written := -1
	#reverse for message, index in messages {
		if message.Role == .Assistant || message.Role == .Tool || (message.Role == .User && message.Content != "") {
			last_written = index
			break
		}
	}
	item_first := true
	// The open user turn: the text and tool results the messages in it carry, and
	// whether exactly one text block is among them. The turn is written when a message
	// that is not user content ends it, so what it holds is counted as it is handed over.
	open := -1
	open_blocks := 0
	open_texts := 0
	turns := 0
	assistant_skip_through := -1

	for message, index in messages {
		if index <= assistant_skip_through { continue }
		if message.Role == .Assistant || (message.Role == .Invalid && message.Verbatim_Items != "") {
			if open_blocks > 0 {
				if err := anthropic_write_user_turn(cursor, body, messages[open:index], open_blocks, open_texts, false, &item_first); err != .None {
					return err
				}
				turns += 1
				open = -1
				open_blocks = 0
				open_texts = 0
			}
			assistant_end := index
			for next_index := index + 1; next_index < len(messages); next_index += 1 {
				next := messages[next_index]
				if next.Role != .Assistant && !(next.Role == .Invalid && next.Verbatim_Items != "") { break }
				assistant_end = next_index
			}
			marked :=
				cached &&
				last_written >= index &&
				last_written <= assistant_end &&
				(messages[last_written].Content != "" || len(messages[last_written].Tool_Calls) > 0)
			if err := anthropic_write_assistant_turn(cursor, body, messages, index, assistant_end, turns == 0, marked, &item_first, allocator); err != .None {
				return err
			}
			turns += 1
			assistant_skip_through = assistant_end
			continue
		}
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
			return .Invalid_Message
		case .Invalid:
			return .Invalid_Message
		}
	}
	if open_blocks > 0 {
		if err := anthropic_write_user_turn(cursor, body, messages[open:], open_blocks, open_texts, cached, &item_first); err != .None { return err }
	}
	return .None
}

@(private, require_results)
anthropic_write_assistant_turn :: proc(
	cursor: ^Encode_Cursor,
	body: ^strings.Builder,
	messages: []Provider_Message,
	start, end: int,
	first_turn: bool,
	marked: bool,
	item_first: ^bool,
	allocator: mem.Allocator,
) -> Provider_Request_Error {
	text_count := 0
	call_count := 0
	last_text_index := -1
	has_native_items := false
	single_text := ""
	for index := start; index <= end; index += 1 {
		message := messages[index]
		if message.Verbatim_Items != "" { has_native_items = true }
		if message.Role != .Assistant { continue }
		if message.Content != "" {
			text_count += 1
			last_text_index = index
			single_text = message.Content
		}
		call_count += len(message.Tool_Calls)
	}
	if !has_native_items && text_count == 0 && call_count == 0 { return .Invalid_Message }
	role := "assistant"
	if first_turn && call_count == 0 { role = "user" }
	encode_write_item(cursor, body, item_first)
	field_first := true
	encode_write_raw(cursor, body, "{")
	encode_write_field(cursor, body, &field_first, "content")
	if !has_native_items && call_count == 0 && !marked && text_count == 1 {
		encode_write_text(cursor, body, single_text)
	} else {
		encode_write_raw(cursor, body, "[")
		block_first := true
		for index := start; index <= end; index += 1 {
			message := messages[index]
			if message.Verbatim_Items == "" { continue }
			if message.Role != .Invalid && message.Role != .Assistant { return .Invalid_Message }
			if err := anthropic_write_native_items(cursor, body, &block_first, message.Verbatim_Items); err != .None {
				return err
			}
		}
		for index := start; index <= end; index += 1 {
			message := messages[index]
			if message.Role != .Assistant || message.Content == "" { continue }
			encode_write_item(cursor, body, &block_first)
			text_marked := marked && call_count == 0 && index == last_text_index
			anthropic_write_text_block(cursor, body, message.Content, text_marked)
		}
		call_index := 0
		for index := start; index <= end; index += 1 {
			message := messages[index]
			if message.Role != .Assistant { continue }
			for call in message.Tool_Calls {
				encode_write_item(cursor, body, &block_first)
				call_marked := marked && call_index == call_count - 1
				if err := anthropic_write_tool_use(cursor, body, call, call_marked, allocator); err != .None { return err }
				call_index += 1
			}
		}
		if block_first { return .Invalid_Message }
		encode_write_raw(cursor, body, "]")
	}
	encode_write_field(cursor, body, &field_first, "role")
	encode_write_literal_string(cursor, body, role)
	encode_write_raw(cursor, body, "}")
	return .None
}

// anthropic_write_native_items writes the decoder's preserved thinking blocks before the
// assistant message's projected text and tool calls, without changing their signatures.
@(private, require_results)
anthropic_write_native_items :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder, block_first: ^bool, record: string) -> Provider_Request_Error {
	if len(record) < 2 || record[0] != '[' || record[len(record) - 1] != ']' { return .Invalid_Message }
	items := record[1:len(record) - 1]
	if items == "" { return .None }
	encode_write_item(cursor, body, block_first)
	encode_write_raw(cursor, body, items)
	return .None
}

// anthropic_write_user_turn writes the open user turn. One text block goes out as the
// plain string this API has always accepted for a text turn; anything else is written as
// the blocks it carries, in the order the conversation hands them over. A marked turn
// carries the cache breakpoint on its last block, which needs the block form.
@(private, require_results)
anthropic_write_user_turn :: proc(
	cursor: ^Encode_Cursor,
	body: ^strings.Builder,
	turn: []Provider_Message,
	blocks: int,
	texts: int,
	marked: bool,
	item_first: ^bool,
) -> Provider_Request_Error {
	encode_write_item(cursor, body, item_first)
	field_first := true
	encode_write_raw(cursor, body, "{")
	encode_write_field(cursor, body, &field_first, "content")
	if blocks == 1 && texts == 1 && !marked {
		for message in turn {
			if message.Role != .User || message.Content == "" { continue }
			encode_write_text(cursor, body, message.Content)
			break
		}
	} else {
		encode_write_raw(cursor, body, "[")
		block_first := true
		written := 0
		for message in turn {
			switch message.Role {
			case .User:
				if message.Content == "" { continue }
				written += 1
				encode_write_item(cursor, body, &block_first)
				anthropic_write_text_block(cursor, body, message.Content, marked && written == blocks)
			case .Tool:
				written += 1
				encode_write_item(cursor, body, &block_first)
				if err := anthropic_write_tool_result(cursor, body, message, marked && written == blocks); err != .None { return err }
			case .System, .Reasoning, .Assistant, .Invalid:
				continue
			}
		}
		encode_write_raw(cursor, body, "]")
	}
	encode_write_field(cursor, body, &field_first, "role")
	encode_write_literal_string(cursor, body, "user")
	encode_write_raw(cursor, body, "}")
	return .None
}

// anthropic_write_cache_control writes the breakpoint field of a block. It states no
// lifetime, so the API's default applies unless a gateway on the way sets its own.
@(private)
anthropic_write_cache_control :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder, field_first: ^bool) {
	encode_write_field(cursor, body, field_first, "cache_control")
	encode_write_raw(cursor, body, "{\"type\":")
	encode_write_literal_string(cursor, body, "ephemeral")
	encode_write_raw(cursor, body, "}")
}

@(private)
anthropic_write_text_block :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder, text: string, marked: bool) {
	field_first := true
	encode_write_raw(cursor, body, "{")
	if marked { anthropic_write_cache_control(cursor, body, &field_first) }
	encode_write_field(cursor, body, &field_first, "text")
	encode_write_text(cursor, body, text)
	encode_write_field(cursor, body, &field_first, "type")
	encode_write_literal_string(cursor, body, ANTHROPIC_BLOCK_TEXT)
	encode_write_raw(cursor, body, "}")
}

// anthropic_write_tool_use writes a call as its content block. The arguments are a JSON
// object on the wire, so a call whose arguments are not one is replayed with an empty
// object: the id and name are preserved so the paired result still answers this call, and
// the rejection travels in that result rather than in invented arguments.
@(private, require_results)
anthropic_write_tool_use :: proc(
	cursor: ^Encode_Cursor,
	body: ^strings.Builder,
	call: Provider_Tool_Call,
	marked: bool,
	allocator: mem.Allocator,
) -> Provider_Request_Error {
	if call.ID == "" || call.Name == "" { return .Invalid_Tool_Call }
	field_first := true
	encode_write_raw(cursor, body, "{")
	if marked { anthropic_write_cache_control(cursor, body, &field_first) }
	encode_write_field(cursor, body, &field_first, "id")
	encode_write_text(cursor, body, call.ID)
	encode_write_field(cursor, body, &field_first, "input")
	if !encode_write_object(cursor, body, call.Arguments, allocator) {
		if cursor.error != .None { return cursor.error }
		encode_write_raw(cursor, body, "{}")
	}
	encode_write_field(cursor, body, &field_first, "name")
	encode_write_text(cursor, body, call.Name)
	encode_write_field(cursor, body, &field_first, "type")
	encode_write_literal_string(cursor, body, ANTHROPIC_BLOCK_TOOL_USE)
	encode_write_raw(cursor, body, "}")
	return .None
}

@(private, require_results)
anthropic_write_tool_result :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder, message: Provider_Message, marked: bool) -> Provider_Request_Error {
	if message.Tool_Call_ID == "" { return .Invalid_Message }
	field_first := true
	encode_write_raw(cursor, body, "{")
	if marked { anthropic_write_cache_control(cursor, body, &field_first) }
	encode_write_field(cursor, body, &field_first, "content")
	encode_write_text(cursor, body, message.Content)
	if message.Tool_Is_Error {
		encode_write_field(cursor, body, &field_first, "is_error")
		encode_write_bool(cursor, body, true)
	}
	encode_write_field(cursor, body, &field_first, "tool_use_id")
	encode_write_text(cursor, body, message.Tool_Call_ID)
	encode_write_field(cursor, body, &field_first, "type")
	encode_write_literal_string(cursor, body, ANTHROPIC_BLOCK_TOOL_RESULT)
	encode_write_raw(cursor, body, "}")
	return .None
}

// anthropic_write_tool_def writes one tool definition. Its schema is the object the tool
// declared, written once and kept: a schema does not change between the requests of one
// conversation. Strict schema enforcement is not set: an optional argument has to stay
// optional, and the harness reads and validates the arguments itself.
@(private, require_results)
anthropic_write_tool_def :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder, tool: Provider_Tool_Def, allocator: mem.Allocator) -> bool {
	field_first := true
	encode_write_raw(cursor, body, "{")
	encode_write_field(cursor, body, &field_first, "description")
	encode_write_text(cursor, body, tool.Description)
	encode_write_field(cursor, body, &field_first, "input_schema")
	if !encode_write_object(cursor, body, tool.Parameters_JSON, allocator) { return false }
	encode_write_field(cursor, body, &field_first, "name")
	encode_write_text(cursor, body, tool.Name)
	encode_write_raw(cursor, body, "}")
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
@(private, require_results)
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
@(private, require_results)
anthropic_optional_integer :: proc(object: json.Object, key: string) -> (value: i64, present: bool, ok: bool) {
	raw, exists := object[key]
	if !exists { return 0, false, true }
	if _, is_null := raw.(json.Null); is_null { return 0, false, true }
	return openai_value_integer(object, key)
}

// anthropic_block_fragment finds the tool-call slot a content block index maps
// to, or takes the next one. The block index counts every block, not just the
// tool calls, so it cannot be used as the slot number itself.
@(private, require_results)
anthropic_block_fragment :: proc(state: ^Provider_Stream_State, index: i64) -> (^Provider_Tool_Fragment, Provider_Stream_Error) {
	for &fragment in state.Tool_Fragments {
		if fragment.Wire_Index_Present && fragment.Wire_Index == index { return &fragment, .None }
	}
	fragment, fragment_error := provider_tool_fragment_append(state)
	if fragment_error != .None { return nil, fragment_error }
	fragment.Wire_Index = index
	fragment.Wire_Index_Present = true
	return fragment, .None
}

@(private, require_results)
anthropic_native_append :: proc(state: ^Provider_Stream_State, text: string) -> Provider_Stream_Error {
	if _, append_error := append(&state^.Native_Items, text); append_error != nil {
		return provider_stream_fail_allocation(state, "thinking replay could not be retained")
	}
	return .None
}

@(private, require_results)
anthropic_native_append_escaped :: proc(state: ^Provider_Stream_State, text: string) -> Provider_Stream_Error {
	builder := strings.Builder {
		buf = state^.Native_Items,
	}
	start := len(builder.buf)
	cursor := Encode_Cursor{}
	encode_write_quoted(&cursor, &builder, text)
	state^.Native_Items = builder.buf
	if cursor.error != .None { return provider_stream_fail_allocation(state, "thinking replay could not be retained") }
	end := len(state^.Native_Items)
	copy(state^.Native_Items[start:], state^.Native_Items[start + 1:end - 1])
	_ = resize(&state^.Native_Items, end - 2)
	return .None
}

@(private, require_results)
anthropic_native_begin_item :: proc(state: ^Provider_Stream_State) -> Provider_Stream_Error {
	if len(state^.Native_Items) == 0 {
		return anthropic_native_append(state, "[")
	}
	return anthropic_native_append(state, ",")
}

@(private, require_results)
anthropic_native_start_thinking :: proc(state: ^Provider_Stream_State, text: string) -> Provider_Stream_Error {
	if state^.Native_Block != .None {
		return provider_stream_fail(state, .Invalid_Data, "thinking block started before the preceding block stopped")
	}
	if err := anthropic_native_begin_item(state); err != .None { return err }
	if err := anthropic_native_append(state, `{"type":"thinking","thinking":"`); err != .None { return err }
	if err := anthropic_native_append_escaped(state, text); err != .None { return err }
	state^.Native_Block = .Thinking
	return .None
}

@(private, require_results)
anthropic_native_start_redacted_thinking :: proc(state: ^Provider_Stream_State, data: string) -> Provider_Stream_Error {
	if state^.Native_Block != .None {
		return provider_stream_fail(state, .Invalid_Data, "redacted thinking block started before the preceding block stopped")
	}
	if err := anthropic_native_begin_item(state); err != .None { return err }
	if err := anthropic_native_append(state, `{"type":"redacted_thinking","data":"`); err != .None { return err }
	if err := anthropic_native_append_escaped(state, data); err != .None { return err }
	return anthropic_native_append(state, `"}`)
}

@(private, require_results)
anthropic_native_thinking_delta :: proc(state: ^Provider_Stream_State, text: string) -> Provider_Stream_Error {
	if state^.Native_Block != .Thinking {
		return provider_stream_fail(state, .Invalid_Data, "thinking delta has no open thinking block")
	}
	return anthropic_native_append_escaped(state, text)
}

@(private, require_results)
anthropic_native_signature_delta :: proc(state: ^Provider_Stream_State, signature: string) -> Provider_Stream_Error {
	if state^.Native_Block == .Thinking {
		if err := anthropic_native_append(state, `","signature":"`); err != .None { return err }
		state^.Native_Block = .Signature
	} else if state^.Native_Block != .Signature {
		return provider_stream_fail(state, .Invalid_Data, "signature delta has no open thinking block")
	}
	return anthropic_native_append_escaped(state, signature)
}

@(private, require_results)
anthropic_native_stop_block :: proc(state: ^Provider_Stream_State) -> Provider_Stream_Error {
	switch state^.Native_Block {
	case .Thinking:
		return provider_stream_fail(state, .Invalid_Data, "thinking block ended without a signature")
	case .Signature:
		if err := anthropic_native_append(state, `"}`); err != .None { return err }
		state^.Native_Block = .None
	case .Skipped:
		state^.Native_Block = .None
	case .None:
	}
	return .None
}

// anthropic_complete delivers the terminal event once the stream has stated why
// it ended. Anthropic states the reason in message_delta and closes in a separate
// message_stop, so the reason arrives before the end.
@(private, require_results)
anthropic_complete :: proc(state: ^Provider_Stream_State, reason_text: string) -> Provider_Stream_Error {
	if state^.Native_Block != .None {
		return provider_stream_fail(state, .Invalid_Data, "response ended with an unfinished content block")
	}
	reason := anthropic_stop_reason(reason_text)
	calls: []Provider_Tool_Call
	if reason == .Tool_Call {
		finalized, finalized_error := provider_tool_finalize(state, state.Allocator)
		if finalized_error != .None { return finalized_error }
		calls = finalized
	} else if provider_tool_fragments_present(state) {
		// A tool block that never became a usable call is a defect, not a stop.
		return provider_stream_fail(state, .Invalid_Data, "response ended with unfinished tool calls")
	}
	raw_output := ""
	if len(state^.Native_Items) > 0 {
		if err := anthropic_native_append(state, "]"); err != .None {
			Provider_Tool_Calls_Destroy(calls, state.Allocator)
			return err
		}
		owned_output, output_error := strings.clone(string(state^.Native_Items[:]), state.Allocator)
		if output_error != nil {
			Provider_Tool_Calls_Destroy(calls, state.Allocator)
			return provider_stream_fail_allocation(state, "thinking replay could not be retained")
		}
		raw_output = owned_output
	}
	owned_reason, reason_error := strings.clone(reason_text, state.Allocator)
	if reason_error != nil {
		Provider_Tool_Calls_Destroy(calls, state.Allocator)
		if raw_output != "" { delete(raw_output, state.Allocator) }
		return provider_stream_fail_allocation(state, "the completion reason could not be retained")
	}
	state^.Phase = .Completed
	provider_stream_push(state, Provider_Completed_Event{Reason = reason, Reason_Text = owned_reason, Tool_Calls = calls, Raw_Output = raw_output})
	return .None
}

// anthropic_error_event reads the error envelope this API uses, which names the
// failure kind in `type` rather than `code`.
@(private, require_results)
anthropic_error_event :: proc(object: json.Object, allocator := context.allocator) -> (event: Provider_Event, is_error: bool, err: mem.Allocator_Error) {
	raw, present := object["error"]
	if !present { return nil, false, nil }
	error_object, ok := raw.(json.Object)
	if !ok {
		invalid, invalid_error := openai_error_event(.API_Error, "invalid provider error object", allocator = allocator)
		return invalid, true, invalid_error
	}
	message, _, message_ok := openai_value_string(error_object, "message")
	if !message_ok {
		invalid, invalid_error := openai_error_event(.API_Error, "invalid provider error message", allocator = allocator)
		return invalid, true, invalid_error
	}
	if message == "" { message = "provider returned an API error" }
	code, _, code_ok := openai_value_string(error_object, "type")
	if !code_ok { code = "" }
	detail_code := ""
	if raw_details, details_present := error_object["details"]; details_present {
		if details, is_object := raw_details.(json.Object); is_object {
			if value, code_present, valid := openai_value_string(details, "error_code"); valid && code_present { detail_code = value }
		}
	}
	parsed, parsed_error := openai_error_event(.API_Error, message, code, detail_code, allocator)
	return parsed, true, parsed_error
}

// anthropic_error_rejection decodes the error document this API returns for a
// refused request, through the same reader an in-stream error event uses, so a
// refusal read from a response body and one read from a stream cannot drift apart.
// The returned strings are owned by allocator.
@(require_results)
anthropic_error_rejection :: proc(body: []u8, allocator := context.allocator) -> (Provider_Rejection, mem.Allocator_Error) {
	value, object, parsed := provider_error_document(body, allocator)
	if !parsed { return {}, nil }
	defer json.destroy_value(value, allocator)
	event, is_error, event_error := anthropic_error_event(object, allocator)
	if !is_error { return {}, nil }
	if event_error != nil { return {}, event_error }
	error_event, is_error_event := event.(Provider_Error_Event)
	if !is_error_event {
		owned := event
		Provider_Event_Destroy(&owned, allocator)
		return {}, nil
	}
	// The rejection takes the strings the parsed event built; nothing is cloned again.
	return Provider_Rejection{code = error_event.Provider_Code, detail_code = error_event.Provider_Detail_Code, message = error_event.Message}, nil
}

// These are the only prose this package reads, and only beside invalid_request_error,
// the one code that covers every malformed request. ANTHROPIC_CONTEXT_OVERFLOW_MESSAGE is
// this API's wording for a prompt too long for the model; the spend-limit prefixes are the
// wording its documentation gives for a spend limit the user set.
ANTHROPIC_CONTEXT_OVERFLOW_MESSAGE :: "prompt is too long"
ANTHROPIC_API_SPEND_LIMIT_PREFIX :: "You have reached your specified API usage limits"
ANTHROPIC_WORKSPACE_SPEND_LIMIT_PREFIX :: "You have reached your specified workspace API usage limits"

// anthropic_failure_class names the meaning this API gives to one of its own error
// types. `invalid_request_error` covers malformed requests and spend limits, so it
// reads only the documented spend-limit prefixes and its existing overflow wording.
@(require_results)
anthropic_failure_class :: proc(code, detail_code, message: string) -> (Provider_Failure_Class, bool) {
	switch code {
	case "rate_limit_error":
		if detail_code == "enforced_spend_limit_reached" { return .Quota, true }
		return .Rate_Limited, true
	case "conflict_error", "api_error", "timeout_error", "overloaded_error":
		return .Provider_Unavailable, true
	case "authentication_error", "permission_error":
		return .Authentication, true
	case "billing_error":
		return .Quota, true
	case "not_found_error":
		return .Not_Found, true
	case "request_too_large":
		return .Payload_Too_Large, true
	case "invalid_request_error":
		if strings.contains(message, ANTHROPIC_CONTEXT_OVERFLOW_MESSAGE) { return .Context_Overflow, true }
		if strings.has_prefix(message, ANTHROPIC_API_SPEND_LIMIT_PREFIX) || strings.has_prefix(message, ANTHROPIC_WORKSPACE_SPEND_LIMIT_PREFIX) {
			return .Quota, true
		}
		return .Invalid_Request, true
	}
	return .None, false
}

@(private, require_results)
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

@(require_results)
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
	if api_error, is_error, api_error_error := anthropic_error_event(object, state.Allocator); is_error {
		if api_error_error != nil {
			return provider_stream_fail_allocation(state, "the provider error could not be retained")
		}
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
		if state^.Native_Block != .None {
			return provider_stream_fail(state, .Invalid_Data, "content block started before the preceding block stopped")
		}
		switch block_type {
		case ANTHROPIC_BLOCK_TEXT:
			text, text_present, text_ok := openai_value_string(block, "text")
			if !text_ok { return provider_stream_fail(state, .Invalid_Data, "text block is invalid") }
			if text_present && text != "" {
				owned, clone_error := strings.clone(text, state.Allocator)
				if clone_error != nil { return provider_stream_fail_allocation(state, "the response text could not be retained") }
				provider_stream_push(state, Provider_Text_Event{Text = owned})
			}
		case ANTHROPIC_BLOCK_TOOL_USE:
			fragment, slot_error := anthropic_block_fragment(state, index)
			if slot_error != .None { return slot_error }
			id, id_present, id_ok := openai_value_string(block, "id")
			if !id_ok || !id_present || id == "" { return provider_stream_fail(state, .Invalid_Data, "tool_use block has no id") }
			name, name_present, name_ok := openai_value_string(block, "name")
			if !name_ok || !name_present || name == "" { return provider_stream_fail(state, .Invalid_Data, "tool_use block has no name") }
			owned_id, id_error := strings.clone(id, state.Allocator)
			if id_error != nil { return provider_stream_fail_allocation(state, "the tool call id could not be retained") }
			fragment.ID = owned_id
			owned_name, name_error := strings.clone(name, state.Allocator)
			if name_error != nil { return provider_stream_fail_allocation(state, "the tool call name could not be retained") }
			fragment.Name = owned_name
			// The block states the input object up front and the stream fills it
			// afterwards. Keeping the stated value covers a call with no arguments,
			// which streams no delta at all.
			if raw_input, input_present := block["input"]; input_present {
				if _, is_null := raw_input.(json.Null); !is_null {
					if _, is_object := raw_input.(json.Object); !is_object {
						return provider_stream_fail(state, .Invalid_Data, "tool_use input is not an object")
					}
					text, text_err := json.unparse(raw_input, allocator = state.Allocator)
					if text_err != nil {
						return provider_stream_fail_allocation(state, "the tool call arguments could not be retained")
					}
					defer delete(text, state.Allocator)
					if _, append_error := append(&fragment.Arguments, text); append_error != nil {
						return provider_stream_fail_allocation(state, "the tool call arguments could not be retained")
					}
				}
			}
			fragment.Present = true
		case ANTHROPIC_BLOCK_THINKING:
			text, text_present, text_ok := openai_value_string(block, "thinking")
			if !text_ok || !text_present { return provider_stream_fail(state, .Invalid_Data, "thinking block is invalid") }
			return anthropic_native_start_thinking(state, text)
		case ANTHROPIC_BLOCK_REDACTED_THINKING:
			data, data_present, data_ok := openai_value_string(block, "data")
			if !data_ok || !data_present { return provider_stream_fail(state, .Invalid_Data, "redacted thinking block is invalid") }
			return anthropic_native_start_redacted_thinking(state, data)
		case ANTHROPIC_BLOCK_FALLBACK:
			// A model-boundary marker has no content to replay.
			state^.Native_Block = .Skipped
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
		if state^.Native_Block == .Skipped { return .None }
		switch delta_type {
		case "text_delta":
			text, text_present, text_ok := openai_value_string(delta, "text")
			if !text_ok { return provider_stream_fail(state, .Invalid_Data, "text delta is invalid") }
			if text_present && text != "" {
				owned, clone_error := strings.clone(text, state.Allocator)
				if clone_error != nil { return provider_stream_fail_allocation(state, "the response text could not be retained") }
				provider_stream_push(state, Provider_Text_Event{Text = owned})
			}
		case "input_json_delta":
			index, index_present, index_ok := openai_value_integer(object, "index")
			if !index_ok || !index_present || index < 0 {
				return provider_stream_fail(state, .Invalid_Data, "argument delta has no index")
			}
			fragment, slot_error := anthropic_block_fragment(state, index)
			if slot_error != .None { return slot_error }
			if !fragment.Present { return provider_stream_fail(state, .Invalid_Data, "argument delta has no block") }
			partial, partial_present, partial_ok := openai_value_string(delta, "partial_json")
			if !partial_ok { return provider_stream_fail(state, .Invalid_Data, "argument delta is invalid") }
			if partial_present && partial != "" {
				if !fragment.Arguments_Started {
					clear(&fragment.Arguments)
					fragment.Arguments_Started = true
				}
				if _, append_error := append(&fragment.Arguments, partial); append_error != nil {
					return provider_stream_fail_allocation(state, "the tool call arguments could not be retained")
				}
			}
		case "thinking_delta":
			text, text_present, text_ok := openai_value_string(delta, "thinking")
			if !text_ok || !text_present { return provider_stream_fail(state, .Invalid_Data, "thinking delta is invalid") }
			return anthropic_native_thinking_delta(state, text)
		case "signature_delta":
			signature, signature_present, signature_ok := openai_value_string(delta, "signature")
			if !signature_ok || !signature_present { return provider_stream_fail(state, .Invalid_Data, "signature delta is invalid") }
			return anthropic_native_signature_delta(state, signature)
		case "citations_delta":
		// Citation annotations have no representation in the Messages projection.
		case:
		// An unknown delta type is a protocol addition, not a defect.
		}
		return .None
	case "content_block_stop":
		return anthropic_native_stop_block(state)
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
