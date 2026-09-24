package ai

import "core:encoding/json"
import "core:mem"
import "core:strings"

openai_responses_encode_request :: proc(
	request: Provider_Request,
	cache: ^Provider_Encode_Cache,
	allocator := context.allocator,
) -> (
	string,
	Provider_Request_Error,
) {
	return openai_responses_encode_request_body(request, cache, false, allocator)
}

// The WebSocket request carries the same Responses fields under a response.create
// event. Streaming is inherent to the connection, so its HTTP-only stream field is
// not sent.
openai_responses_encode_websocket_request :: proc(
	request: Provider_Request,
	cache: ^Provider_Encode_Cache,
	allocator := context.allocator,
) -> (
	string,
	Provider_Request_Error,
) {
	return openai_responses_encode_request_body(request, cache, true, allocator)
}

// openai_responses_encode_request_body writes one Responses request body. The body is
// bytes: every string the request carries is written through its slot in the cache, so a
// request that repeats or extends a conversation copies the bytes already written for
// the texts it carries again instead of reading and writing them a second time. What
// that saves is largest here, because a record the endpoint sent is read from the
// conversation and written back unchanged on every request that follows it.
openai_responses_encode_request_body :: proc(
	request: Provider_Request,
	cache: ^Provider_Encode_Cache,
	websocket: bool,
	allocator := context.allocator,
) -> (
	string,
	Provider_Request_Error,
) {
	if request_err := Provider_Validate_Request(request); request_err != .None { return "", request_err }
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
	encode_write_field(&cursor, body, &first, "input")
	encode_write_raw(&cursor, body, "[")
	item_first := true
	for message in request.Messages {
		// A verbatim message carries the endpoint's own items. They are read as the input
		// the request takes back, and an item the input schema refuses fails the request:
		// this is the last point before the wire, and a record spliced unread would send
		// bytes the endpoint rejects to every request built from the same history, not only
		// to this one. They are emitted where they sit among the projected messages, so the
		// request keeps the conversation's real order. Re-deriving them would lose phase,
		// annotations, and summaries, and would send assistant content twice.
		if message.Verbatim_Items != "" {
			if !openai_responses_record_write(&cursor, body, &item_first, message.Verbatim_Items) {
				encode_finish(&cursor)
				if cursor.error != .None { return "", cursor.error }
				return "", .Invalid_Message
			}
			continue
		}
		if message.Role == .Reasoning {
			// A reasoning item is replayable only when the endpoint returned
			// encrypted content: without it the item carries nothing the
			// endpoint can continue from, and it is skipped rather than sent.
			if message.Reasoning_Encrypted == "" { continue }
			encode_write_item(&cursor, body, &item_first)
			field_first := true
			encode_write_raw(&cursor, body, "{")
			encode_write_field(&cursor, body, &field_first, "encrypted_content")
			encode_write_text(&cursor, body, message.Reasoning_Encrypted)
			encode_write_field(&cursor, body, &field_first, "id")
			encode_write_text(&cursor, body, message.Reasoning_ID)
			// The request schema requires a summary on every replayed reasoning
			// item, empty or not; summaries are display-only and were never
			// kept, so the replayed one is empty.
			encode_write_field(&cursor, body, &field_first, "summary")
			encode_write_raw(&cursor, body, "[]")
			encode_write_field(&cursor, body, &field_first, "type")
			encode_write_literal_string(&cursor, body, "reasoning")
			encode_write_raw(&cursor, body, "}")
			continue
		}
		if message.Role == .Tool {
			encode_write_item(&cursor, body, &item_first)
			field_first := true
			encode_write_raw(&cursor, body, "{")
			encode_write_field(&cursor, body, &field_first, "call_id")
			encode_write_text(&cursor, body, message.Tool_Call_ID)
			encode_write_field(&cursor, body, &field_first, "output")
			encode_write_text(&cursor, body, message.Content)
			encode_write_field(&cursor, body, &field_first, "type")
			encode_write_literal_string(&cursor, body, "function_call_output")
			encode_write_raw(&cursor, body, "}")
			continue
		}
		if len(message.Tool_Calls) > 0 {
			for call in message.Tool_Calls {
				encode_write_item(&cursor, body, &item_first)
				call_first := true
				encode_write_raw(&cursor, body, "{")
				encode_write_field(&cursor, body, &call_first, "arguments")
				encode_write_text(&cursor, body, call.Arguments)
				encode_write_field(&cursor, body, &call_first, "call_id")
				encode_write_text(&cursor, body, call.ID)
				if call.Item_ID != "" {
					encode_write_field(&cursor, body, &call_first, "id")
					encode_write_text(&cursor, body, call.Item_ID)
				}
				encode_write_field(&cursor, body, &call_first, "name")
				encode_write_text(&cursor, body, call.Name)
				encode_write_field(&cursor, body, &call_first, "type")
				encode_write_literal_string(&cursor, body, "function_call")
				encode_write_raw(&cursor, body, "}")
			}
			if message.Content != "" {
				encode_write_item(&cursor, body, &item_first)
				text_first := true
				encode_write_raw(&cursor, body, "{")
				encode_write_field(&cursor, body, &text_first, "content")
				encode_write_text(&cursor, body, message.Content)
				encode_write_field(&cursor, body, &text_first, "role")
				encode_write_literal_string(&cursor, body, openai_role_name(message.Role))
				encode_write_raw(&cursor, body, "}")
			}
			continue
		}
		encode_write_item(&cursor, body, &item_first)
		field_first := true
		encode_write_raw(&cursor, body, "{")
		if message.Cache_Breakpoint {
			encode_write_field(&cursor, body, &field_first, "content")
			encode_write_raw(&cursor, body, "[{")
			part_first := true
			encode_write_field(&cursor, body, &part_first, "prompt_cache_breakpoint")
			encode_write_raw(&cursor, body, "{")
			breakpoint_first := true
			encode_write_field(&cursor, body, &breakpoint_first, "mode")
			encode_write_literal_string(&cursor, body, "explicit")
			encode_write_raw(&cursor, body, "}")
			encode_write_field(&cursor, body, &part_first, "text")
			encode_write_text(&cursor, body, message.Content)
			encode_write_field(&cursor, body, &part_first, "type")
			encode_write_literal_string(&cursor, body, "input_text")
			encode_write_raw(&cursor, body, "}]")
		} else {
			encode_write_field(&cursor, body, &field_first, "content")
			encode_write_text(&cursor, body, message.Content)
		}
		encode_write_field(&cursor, body, &field_first, "role")
		encode_write_literal_string(&cursor, body, openai_role_name(message.Role))
		encode_write_raw(&cursor, body, "}")
	}
	encode_write_raw(&cursor, body, "]")
	if request.Instructions_Present {
		encode_write_field(&cursor, body, &first, "instructions")
		encode_write_text(&cursor, body, request.Instructions)
	}
	if request.Max_Output_Tokens_Present {
		encode_write_field(&cursor, body, &first, "max_output_tokens")
		encode_write_int(&cursor, body, request.Max_Output_Tokens)
	}
	encode_write_field(&cursor, body, &first, "model")
	encode_write_text(&cursor, body, request.Model)
	if request.Prompt_Cache_Key_Present {
		encode_write_field(&cursor, body, &first, "prompt_cache_key")
		encode_write_text(&cursor, body, request.Prompt_Cache_Key)
	}
	if request.Prompt_Cache_Options_Present {
		encode_write_field(&cursor, body, &first, "prompt_cache_options")
		encode_write_raw(&cursor, body, "{")
		options_first := true
		if request.Prompt_Cache_Options.Mode_Present {
			mode := "implicit"
			if request.Prompt_Cache_Options.Mode == .Explicit { mode = "explicit" }
			encode_write_field(&cursor, body, &options_first, "mode")
			encode_write_literal_string(&cursor, body, mode)
		}
		if request.Prompt_Cache_Options.TTL_Present {
			encode_write_field(&cursor, body, &options_first, "ttl")
			encode_write_literal_string(&cursor, body, request.Prompt_Cache_Options.TTL)
		}
		encode_write_raw(&cursor, body, "}")
	}
	if request.Prompt_Cache_Retention_Present {
		encode_write_field(&cursor, body, &first, "prompt_cache_retention")
		encode_write_text(&cursor, body, request.Prompt_Cache_Retention)
	}
	if request.Reasoning_Effort_Present {
		encode_write_field(&cursor, body, &first, "reasoning")
		encode_write_raw(&cursor, body, "{")
		effort_first := true
		encode_write_field(&cursor, body, &effort_first, "effort")
		encode_write_text(&cursor, body, request.Reasoning_Effort)
		encode_write_raw(&cursor, body, "}")
	}
	if request.Store_Response_Present {
		encode_write_field(&cursor, body, &first, "store")
		encode_write_bool(&cursor, body, request.Store_Response)
	}
	if !websocket {
		encode_write_field(&cursor, body, &first, "stream")
		encode_write_bool(&cursor, body, true)
	}
	if len(request.Tools) > 0 {
		encode_write_field(&cursor, body, &first, "tools")
		encode_write_raw(&cursor, body, "[")
		for tool, index in request.Tools {
			if index > 0 { encode_write_byte(&cursor, body, ',') }
			tool_first := true
			encode_write_raw(&cursor, body, "{")
			encode_write_field(&cursor, body, &tool_first, "description")
			encode_write_text(&cursor, body, tool.Description)
			encode_write_field(&cursor, body, &tool_first, "name")
			encode_write_text(&cursor, body, tool.Name)
			// A tool's parameters are the one part of a request that is JSON inside JSON:
			// the schema text is read once and the bytes are kept with the request's other
			// texts. Strict schema enforcement is not set: it requires every property to be
			// required, which would make an optional argument mandatory and push the model
			// into filling it with an empty value. The tool's own schema and the harness's
			// reading of it are the contract.
			if !openai_tool_parameters_write(&cursor, body, &tool_first, tool.Parameters_JSON, allocator) {
				encode_finish(&cursor)
				if cursor.error != .None { return "", cursor.error }
				return "", .Invalid_Tools
			}
			encode_write_field(&cursor, body, &tool_first, "type")
			encode_write_literal_string(&cursor, body, "function")
			encode_write_raw(&cursor, body, "}")
		}
		encode_write_raw(&cursor, body, "]")
	}
	if websocket {
		encode_write_field(&cursor, body, &first, "type")
		encode_write_literal_string(&cursor, body, "response.create")
	}
	encode_write_raw(&cursor, body, "}")
	encode_finish(&cursor)
	if cursor.error != .None { return "", cursor.error }
	result, take_error := encode_body_take(&cursor)
	if take_error != .None { return "", take_error }
	return result, .None
}

// openai_responses_record_write writes the items one response record replays as, where
// they sit among the projected items, and reports whether the record can be sent back at
// all. Nothing is spliced unread: an item the input schema refuses fails the whole
// record, because a request cannot carry half a response, and an endpoint that receives
// one refuses every request built from the same history after it.
//
// A record does not change once it is stored, so reading it is work that happens once per
// record rather than once per request.
@(private = "package")
openai_responses_record_write :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder, first: ^bool, record: string, allocator := context.allocator) -> bool {
	slot, hit := encode_slot_for(cursor, record, .Record)
	if cursor.error != .None { return false }
	if slot == nil {
		scratch, build_error := strings.builder_make(allocator)
		if build_error != nil {
			encode_fail(cursor, .Allocation)
			return false
		}
		defer strings.builder_destroy(&scratch)
		ok, record_error := openai_responses_record_bytes(record, &scratch, allocator)
		if record_error != .None {
			if record_error != .Invalid_Message { encode_fail(cursor, record_error) }
			return false
		}
		if !ok { return false }
		openai_responses_items_write(cursor, body, first, strings.to_string(scratch))
		return cursor.error == .None
	}
	if !hit {
		ok, record_error := openai_responses_record_bytes(record, &slot.bytes, allocator)
		if record_error != .None {
			if record_error != .Invalid_Message { encode_fail(cursor, record_error) }
			return false
		}
		if !encode_slot_store(cursor, slot, record) { return false }
		slot.ok = ok
	}
	if !slot.ok { return false }
	openai_responses_items_write(cursor, body, first, strings.to_string(slot.bytes))
	return cursor.error == .None
}

// openai_responses_items_write appends written items to the array being built. A record
// that carries no items adds nothing and takes no separator.
@(private = "package")
openai_responses_items_write :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder, first: ^bool, items: string) {
	if items == "" { return }
	if !first^ { encode_write_byte(cursor, body, ',') }
	first^ = false
	encode_write_raw(cursor, body, items)
}

// openai_responses_record_bytes writes the items one response record is sent back as: the
// endpoint's own output array, with the fields the input schema has no place for removed,
// written with sorted keys like the rest of the body. It reports false when the record is
// not an array of items the input schema takes back, which is what makes the request that
// carries it unsendable.
@(private = "package")
openai_responses_record_bytes :: proc(record: string, out: ^strings.Builder, allocator: mem.Allocator) -> (bool, Provider_Request_Error) {
	items, parse_err := json.parse_string(record, .JSON, true, allocator)
	if parse_err != nil { return false, .Invalid_Message }
	defer json.destroy_value(items, allocator)
	array, is_array := items.(json.Array)
	if !is_array { return false, .Invalid_Message }
	first := true
	for item in array {
		replayed, is_object := item.(json.Object)
		if !is_object || !openai_responses_replay_item_ok(replayed, allocator) { return false, .Invalid_Message }
		// An output item carries a terminal status; the input-item schema has no such
		// field, and an endpoint refuses a field it does not know. Everything else
		// survives, so the record stays replayable.
		clone, clone_error := make(json.Object, len(replayed), allocator)
		if clone_error != nil { return false, .Allocation }
		for key, value in replayed {
			if key == "status" { continue }
			owned_key, key_error := strings.clone(key, allocator)
			if key_error != nil {
				json.destroy_value(json.Value(clone), allocator)
				return false, .Allocation
			}
			clone[owned_key] = json.Value(json.clone_value(value, allocator))
		}
		text, unparse_err := json.unparse(json.Value(clone), {sort_maps_by_key = true}, allocator)
		json.destroy_value(json.Value(clone), allocator)
		if unparse_err != nil { return false, .Allocation }
		if !first && strings.write_byte(out, ',') != 1 { delete(text, allocator); return false, .Allocation }
		first = false
		if strings.write_string(out, text) != len(text) {
			delete(text, allocator)
			return false, .Allocation
		}
		delete(text, allocator)
	}
	return true, .None
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

// Provider_Replay_Read reads one endpoint output array the way a request would carry it
// back, and reports the calls the record declares. ok is false when the array cannot be
// sent back at all, which is a fact about the bytes rather than an error: the caller
// replays its own projection of that response instead, and the conversation loses nothing
// but the fields only the endpoint models.
//
// Nothing is spliced unread. The record is the endpoint's own output, so its items are not
// the harness's to trust: an item the input schema refuses fails the whole record, because
// a request cannot carry half a response, and an endpoint that receives one refuses every
// request built from the same history after it. The returned calls are owned by allocator
// and released with Provider_Tool_Calls_Destroy.
Provider_Replay_Read :: proc(output: string, allocator := context.allocator) -> (calls: []Provider_Tool_Call, ok: bool) {
	value, parse_err := json.parse_string(output, .JSON, true, allocator)
	if parse_err != nil { return nil, false }
	defer json.destroy_value(value, allocator)
	array, is_array := value.(json.Array)
	if !is_array { return nil, false }
	for item in array {
		object, is_object := item.(json.Object)
		if !is_object || !openai_responses_replay_item_ok(object, allocator) { return nil, false }
	}
	declared := make([dynamic]Provider_Tool_Call, 0, len(array), allocator)
	for item in array {
		object := item.(json.Object)
		item_type, _, _ := openai_value_string(object, "type")
		if item_type != "function_call" { continue }
		id, _, _ := openai_value_string(object, "id")
		call_id, _, _ := openai_value_string(object, "call_id")
		name, _, _ := openai_value_string(object, "name")
		arguments, _, _ := openai_value_string(object, "arguments")
		append(
			&declared,
			Provider_Tool_Call {
				ID = strings.clone(call_id, allocator),
				Item_ID = strings.clone(id, allocator),
				Name = strings.clone(name, allocator),
				Arguments = strings.clone(arguments, allocator),
			},
		)
	}
	return declared[:], true
}

// openai_responses_replay_item_ok reports whether one item of an endpoint output array can
// be sent back as request input. An output item carries fields an input item has no place
// for, and the input schema constrains some values the output schema does not: a call whose
// arguments are not the object the schema requires is refused here rather than by the
// endpoint, which would refuse every request that carried it.
//
// An item type this adapter does not model replays as it stands. Keeping fields and item
// types the harness never learned is what the record is for.
openai_responses_replay_item_ok :: proc(object: json.Object, allocator: mem.Allocator) -> bool {
	item_type, type_present, type_ok := openai_value_string(object, "type")
	if !type_ok || !type_present || item_type == "" { return false }
	switch item_type {
	case "function_call":
		// The endpoint validates all three: a call id its results name the call by, a name
		// its tool registry knows, and arguments that parse as the object the schema wants.
		call_id, call_present, call_ok := openai_value_string(object, "call_id")
		if !call_ok || !call_present || call_id == "" { return false }
		name, name_present, name_ok := openai_value_string(object, "name")
		if !name_ok || !name_present || name == "" { return false }
		arguments, arguments_present, arguments_ok := openai_value_string(object, "arguments")
		if !arguments_ok || !arguments_present { return false }
		return Provider_Arguments_Object(arguments, allocator)
	case "reasoning":
		// A replayed reasoning item is continued from, so the endpoint requires the id and
		// the encrypted content; a summary alone is display-only and carries nothing the
		// endpoint can resume.
		id, id_present, id_ok := openai_value_string(object, "id")
		if !id_ok || !id_present || id == "" { return false }
		encrypted, encrypted_present, encrypted_ok := openai_value_string(object, "encrypted_content")
		return encrypted_ok && encrypted_present && encrypted != ""
	case "message":
		role, role_present, role_ok := openai_value_string(object, "role")
		if !role_ok || !role_present || role == "" { return false }
		_, content_present := object["content"]
		return content_present
	case:
		return true
	}
	return true
}

provider_tool_fragment_by_item :: proc(object: json.Object, state: ^Provider_Stream_State, allocator := context.allocator) -> (^Provider_Tool_Fragment, bool) {
	id, present, ok := openai_value_string(object, "item_id")
	if !ok || !present || id == "" { state^.Phase = .Failed; return nil, false }
	for &fragment in state.Tool_Fragments {
		if fragment.Present && fragment.Item_ID == id { return &fragment, true }
	}
	fragment := provider_tool_fragment_append(state)
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
		fragment := provider_tool_fragment_append(state)
		fragment.Wire_Index = index
		fragment.Wire_Index_Present = true
		return fragment, true
	}
	fragment := provider_tool_fragment_append(state)
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
	if payload != "[DONE]" { return openai_responses_consume_event(payload, state) }
	switch state.Phase {
	case .Open:
		return provider_stream_fail(state, .Stream_Truncated, "stream ended before completion", .Stream_Truncated)
	case .Completed:
		state.Phase = .Done
		return .None
	case .Done, .Failed:
		return .None
	}
	return .Invalid_State
}

openai_responses_consume_event :: proc(payload: string, state: ^Provider_Stream_State) -> Provider_Stream_Error {
	if state == nil || state^.API != .OpenAI_Responses { return .Invalid_State }
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
