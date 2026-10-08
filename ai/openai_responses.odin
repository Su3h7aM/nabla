package ai

import "core:encoding/json"
import "core:mem"
import "core:strings"

@(require_results)
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
@(require_results)
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

// openai_responses_encode_request_body writes one Responses request body, with a cache
// reusing the bytes it already holds for the texts this request carries again. What that
// saves is largest here, because every record the endpoint sent is written back unchanged
// on every request that follows it.
@(require_results)
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
			if len(message.Attachments) > 0 {
				encode_write_raw(&cursor, body, "[")
				part_first := true
				if message.Content != "" { encode_write_text_part(&cursor, body, &part_first, "input_text", message.Content, false) }
				openai_responses_write_attachments(&cursor, body, &part_first, message.Attachments, false)
				encode_write_raw(&cursor, body, "]")
			} else {
				encode_write_text(&cursor, body, message.Content)
			}
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
		if message.Cache_Breakpoint || len(message.Attachments) > 0 {
			encode_write_field(&cursor, body, &field_first, "content")
			encode_write_raw(&cursor, body, "[")
			part_first := true
			if message.Content != "" || len(message.Attachments) == 0 {
				encode_write_text_part(&cursor, body, &part_first, "input_text", message.Content, message.Cache_Breakpoint && len(message.Attachments) == 0)
			}
			openai_responses_write_attachments(&cursor, body, &part_first, message.Attachments, message.Cache_Breakpoint)
			encode_write_raw(&cursor, body, "]")
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
	encode_write_cache_fields(&cursor, body, &first, request)
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
	return encode_finish_take(&cursor)
}

// openai_responses_write_attachments writes each attachment as the input_image or
// input_file part the Responses API takes. Every part type accepts a cache breakpoint, so
// a marked list carries it on its last part.
@(private)
openai_responses_write_attachments :: proc(
	cursor: ^Encode_Cursor,
	body: ^strings.Builder,
	part_first: ^bool,
	attachments: []Provider_Attachment,
	marked: bool,
) {
	for attachment, index in attachments {
		breakpoint := marked && index == len(attachments) - 1
		encode_write_item(cursor, body, part_first)
		field_first := true
		encode_write_raw(cursor, body, "{")
		switch attachment.Media {
		case .PNG, .JPEG, .GIF, .WebP:
			encode_write_field(cursor, body, &field_first, "image_url")
			encode_write_data_url(cursor, body, attachment)
			if breakpoint { encode_write_breakpoint(cursor, body, &field_first) }
			encode_write_field(cursor, body, &field_first, "type")
			encode_write_literal_string(cursor, body, "input_image")
		case .PDF:
			encode_write_field(cursor, body, &field_first, "file_data")
			encode_write_data_url(cursor, body, attachment)
			encode_write_field(cursor, body, &field_first, "filename")
			encode_write_text(cursor, body, attachment.Name)
			if breakpoint { encode_write_breakpoint(cursor, body, &field_first) }
			encode_write_field(cursor, body, &field_first, "type")
			encode_write_literal_string(cursor, body, "input_file")
		}
		encode_write_raw(cursor, body, "}")
	}
}

// openai_responses_record_write writes the items one response record replays as, where
// they sit among the projected items, and reports whether the record can be sent back at
// all. Nothing is spliced unread: an item the input schema refuses fails the whole
// record, because a request cannot carry half a response, and an endpoint that receives
// one refuses every request built from the same history after it.
//
// A record does not change once it is stored, so reading it is work that happens once per
// record rather than once per request.
@(private = "package", require_results)
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
@(private = "package", require_results)
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
		if !first && strings.write_byte(out, ',') != 1 {
			delete(text, allocator)
			return false, .Allocation
		}
		first = false
		if strings.write_string(out, text) != len(text) {
			delete(text, allocator)
			return false, .Allocation
		}
		delete(text, allocator)
	}
	return true, .None
}

@(require_results)
openai_responses_parse_usage :: proc(object: json.Object) -> (Provider_Usage_Event, bool) {
	usage := Provider_Usage_Event{}
	ok := true
	usage.Input_Tokens, usage.Input_Tokens_Present, ok = provider_json_integer(object, "input_tokens")
	if !ok { return {}, false }
	usage.Output_Tokens, usage.Output_Tokens_Present, ok = provider_json_integer(object, "output_tokens")
	if !ok { return {}, false }
	usage.Total_Tokens, usage.Total_Tokens_Present, ok = provider_json_integer(object, "total_tokens")
	if !ok { return {}, false }
	if raw_details, present := object["input_tokens_details"]; present {
		if _, is_null := raw_details.(json.Null); !is_null {
			details, details_ok := raw_details.(json.Object)
			if !details_ok { return {}, false }
			usage.Cached_Input_Tokens, usage.Cached_Input_Tokens_Present, ok = provider_json_integer(details, "cached_tokens")
			if !ok || (usage.Cached_Input_Tokens_Present && usage.Cached_Input_Tokens < 0) { return {}, false }
			usage.Cache_Write_Tokens, usage.Cache_Write_Tokens_Present, ok = provider_json_integer(details, "cache_write_tokens")
			if !ok || (usage.Cache_Write_Tokens_Present && usage.Cache_Write_Tokens < 0) { return {}, false }
		}
	}
	if raw_details, present := object["output_tokens_details"]; present {
		if _, is_null := raw_details.(json.Null); !is_null {
			details, details_ok := raw_details.(json.Object)
			if !details_ok { return {}, false }
			usage.Reasoning_Tokens, usage.Reasoning_Tokens_Present, ok = provider_json_integer(details, "reasoning_tokens")
			if !ok || (usage.Reasoning_Tokens_Present && usage.Reasoning_Tokens < 0) { return {}, false }
		}
	}
	return usage, true
}

openai_responses_incomplete_reason :: proc(reason: string) -> Provider_Finish_Reason {
	switch reason {
	case "max_output_tokens", "max_messages":
		return .Length
	case "content_filter":
		return .Content_Filter
	case:
		return .Unknown
	}
}

// openai_responses_clone_output clones the terminal response's output array
// verbatim for the replay record. A missing, null, or empty array replays as
// empty: there are no items to replay, and the harness falls back to its own
// projection for that response rather than sending an empty native record. ok is
// false when a present value could not be written, which is a local failure: the
// caller reports the allocation it is. The caller owns the result on success.
@(require_results)
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
// sent back at all, whether because of the bytes or because the calls it declares could not
// be retained: the caller replays its own projection of that response instead, and the
// conversation loses nothing but the fields only the endpoint models.
//
// Nothing is spliced unread. The record is the endpoint's own output, so its items are not
// the harness's to trust: an item the input schema refuses fails the whole record, because
// a request cannot carry half a response, and an endpoint that receives one refuses every
// request built from the same history after it. The returned calls are owned by allocator
// and released with Provider_Tool_Calls_Destroy.
@(require_results)
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
	declared, make_error := make([dynamic]Provider_Tool_Call, 0, len(array), allocator)
	if make_error != nil { return nil, false }
	for item in array {
		object := item.(json.Object)
		item_type, _, _ := provider_json_string(object, "type")
		if item_type != "function_call" { continue }
		id, _, _ := provider_json_string(object, "id")
		call_id, _, _ := provider_json_string(object, "call_id")
		name, _, _ := provider_json_string(object, "name")
		arguments, _, _ := provider_json_string(object, "arguments")
		call := Provider_Tool_Call{}
		if !provider_call_clone_strings(&call, call_id, id, name, arguments, allocator) {
			Provider_Tool_Calls_Destroy(declared[:], allocator)
			return nil, false
		}
		if _, append_error := append(&declared, call); append_error != nil {
			provider_tool_call_destroy(&call, allocator)
			Provider_Tool_Calls_Destroy(declared[:], allocator)
			return nil, false
		}
	}
	return declared[:], true
}

// openai_responses_replay_item_ok reports whether one item of an endpoint output array can
// be sent back as request input. An output item carries fields an input item has no place
// for, and the input schema constrains some values the output schema does not, so an item
// the schema could not take back is refused here rather than by the endpoint, which would
// refuse every request that carried it. An item type this adapter does not model replays
// as it stands.
@(require_results)
openai_responses_replay_item_ok :: proc(object: json.Object, allocator: mem.Allocator) -> bool {
	item_type, type_present, type_ok := provider_json_string(object, "type")
	if !type_ok || !type_present || item_type == "" { return false }
	switch item_type {
	case "function_call":
		// The endpoint validates all three: a call id its results name the call by, a name
		// its tool registry knows, and arguments that parse as the object the schema wants.
		call_id, call_present, call_ok := provider_json_string(object, "call_id")
		if !call_ok || !call_present || call_id == "" { return false }
		name, name_present, name_ok := provider_json_string(object, "name")
		if !name_ok || !name_present || name == "" { return false }
		arguments, arguments_present, arguments_ok := provider_json_string(object, "arguments")
		if !arguments_ok || !arguments_present { return false }
		return Provider_Arguments_Object(arguments, allocator)
	case "reasoning":
		// A replayed reasoning item is continued from, so the endpoint requires the id and
		// the encrypted content; a summary alone is display-only and carries nothing the
		// endpoint can resume.
		id, id_present, id_ok := provider_json_string(object, "id")
		if !id_ok || !id_present || id == "" { return false }
		encrypted, encrypted_present, encrypted_ok := provider_json_string(object, "encrypted_content")
		return encrypted_ok && encrypted_present && encrypted != ""
	case "message":
		role, role_present, role_ok := provider_json_string(object, "role")
		if !role_ok || !role_present || role == "" { return false }
		_, content_present := object["content"]
		return content_present
	case:
		return true
	}
	return true
}

@(require_results)
provider_tool_fragment_by_item :: proc(object: json.Object, state: ^Provider_Stream_State) -> (^Provider_Tool_Fragment, Provider_Stream_Error) {
	id, present, ok := provider_json_string(object, "item_id")
	if !ok || !present || id == "" {
		return nil, provider_stream_fail(state, .Invalid_Data, "arguments event has no item id")
	}
	for &fragment in state.Tool_Fragments {
		if fragment.Present && fragment.Item_ID == id { return &fragment, .None }
	}
	fragment, fragment_error := provider_tool_fragment_append(state)
	if fragment_error != .None { return nil, fragment_error }
	owned_id, clone_error := strings.clone(id, state.Allocator)
	if clone_error != nil {
		return nil, provider_stream_fail_allocation(state, "the output item id could not be retained")
	}
	fragment.Item_ID = owned_id
	return fragment, .None
}

@(require_results)
openai_responses_call_slot :: proc(object, item: json.Object, state: ^Provider_Stream_State) -> (^Provider_Tool_Fragment, Provider_Stream_Error) {
	if id, present, ok := provider_json_string(item, "id"); ok && present && id != "" {
		for &fragment in state.Tool_Fragments {
			if fragment.Present && fragment.Item_ID == id { return &fragment, .None }
		}
	}
	if index, present, ok := provider_json_integer(object, "output_index"); ok && present {
		for &fragment in state.Tool_Fragments {
			if fragment.Present && fragment.Wire_Index == index { return &fragment, .None }
		}
		fragment, fragment_error := provider_tool_fragment_append(state)
		if fragment_error != .None { return nil, fragment_error }
		fragment.Wire_Index = index
		fragment.Wire_Index_Present = true
		return fragment, .None
	}
	return provider_tool_fragment_append(state)
}

@(require_results)
openai_responses_call_event :: proc(object: json.Object, state: ^Provider_Stream_State, done: bool) -> Provider_Stream_Error {
	raw, item_present := object["item"]
	item: json.Object
	if done {
		if !item_present { return provider_stream_fail(state, .Invalid_Data, "done item has no item") }
		done_item, item_ok := raw.(json.Object)
		if !item_ok { return provider_stream_fail(state, .Invalid_Data, "done item is not an object") }
		item = done_item
	} else if item_present {
		added_item, item_ok := raw.(json.Object)
		if !item_ok { return provider_stream_fail(state, .Invalid_Data, "added item is not an object") }
		item = added_item
	}
	if item != nil {
		item_type, type_present, type_ok := provider_json_string(item, "type")
		if !type_ok || !type_present { return provider_stream_fail(state, .Invalid_Data, "output item has no type") }
		if item_type == "message" { return .None }
		if item_type == "reasoning" {
			// The added event may not carry the id yet; the done item
			// repeats the whole reasoning item, so capture there. The
			// endpoint needs id plus encrypted_content back to continue
			// reasoning; summaries are display-only and are not replayed.
			if !done { return .None }
			id, id_present, id_ok := provider_json_string(item, "id")
			if !id_ok || !id_present || id == "" { return provider_stream_fail(state, .Invalid_Data, "reasoning item has no id") }
			encrypted, _, encrypted_ok := provider_json_string(item, "encrypted_content")
			if !encrypted_ok { return provider_stream_fail(state, .Invalid_Data, "reasoning content is invalid") }
			owned_id, id_error := strings.clone(id, state.Allocator)
			if id_error != nil {
				return provider_stream_fail_allocation(state, "the reasoning item id could not be retained")
			}
			owned_encrypted, encrypted_error := strings.clone(encrypted, state.Allocator)
			if encrypted_error != nil {
				delete(owned_id, state.Allocator)
				return provider_stream_fail_allocation(state, "the reasoning content could not be retained")
			}
			provider_stream_push(state, Provider_Reasoning_Event{ID = owned_id, Encrypted = owned_encrypted})
			return .None
		}
		fragment, slot_error := openai_responses_call_slot(object, item, state)
		if slot_error != .None { return slot_error }
		if item_type != "function_call" {
			return provider_stream_fail(state, .Unsupported_Tool_Output, "Responses tool output is unsupported", .None)
		}
		if id, present, ok := provider_json_string(item, "id"); ok && present && id != "" {
			if fragment.Item_ID != "" && fragment.Item_ID != id { return provider_stream_fail(state, .Invalid_Data, "output item id changed") }
			if fragment.Item_ID == "" {
				owned, clone_error := strings.clone(id, state.Allocator)
				if clone_error != nil {
					return provider_stream_fail_allocation(state, "the output item id could not be retained")
				}
				fragment.Item_ID = owned
			}
		} else if !ok { return provider_stream_fail(state, .Invalid_Data, "output item id is invalid") }
		if id, present, ok := provider_json_string(item, "call_id"); ok && present && id != "" {
			if fragment.ID != "" && fragment.ID != id { return provider_stream_fail(state, .Invalid_Data, "call id changed") }
			if fragment.ID == "" {
				owned, clone_error := strings.clone(id, state.Allocator)
				if clone_error != nil {
					return provider_stream_fail_allocation(state, "the tool call id could not be retained")
				}
				fragment.ID = owned
			}
		} else if !ok { return provider_stream_fail(state, .Invalid_Data, "call id is invalid") }
		if name, present, ok := provider_json_string(item, "name"); ok && present && name != "" {
			if fragment.Name != "" && fragment.Name != name { return provider_stream_fail(state, .Invalid_Data, "call name changed") }
			if fragment.Name == "" {
				owned, clone_error := strings.clone(name, state.Allocator)
				if clone_error != nil {
					return provider_stream_fail_allocation(state, "the tool call name could not be retained")
				}
				fragment.Name = owned
			}
		} else if !ok { return provider_stream_fail(state, .Invalid_Data, "call name is invalid") }
		if arguments, present, ok := provider_json_string(item, "arguments"); ok && present && arguments != "" {
			// The done item repeats the full arguments already streamed
			// as deltas; replace so a replayed payload is not doubled.
			clear(&fragment.Arguments)
			if _, append_error := append(&fragment.Arguments, arguments); append_error != nil {
				return provider_stream_fail_allocation(state, "the tool call arguments could not be retained")
			}
		} else if !ok { return provider_stream_fail(state, .Invalid_Data, "call arguments are invalid") }
		fragment.Present = true
		if done { fragment.Complete = true }
	}
	return .None
}

@(require_results)
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
		if !output_ok {
			return provider_stream_fail_allocation(state, "the response output could not be retained")
		}
		calls: []Provider_Tool_Call
		if provider_tool_fragments_present(state) {
			finalized, finalized_error := provider_tool_finalize(state, state.Allocator)
			if finalized_error != .None {
				if raw_output != "" { delete(raw_output, state.Allocator) }
				return finalized_error
			}
			calls = finalized
		}
		reason_text, reason_error := strings.clone(calls != nil ? "tool_calls" : "completed", state.Allocator)
		if reason_error != nil {
			if raw_output != "" { delete(raw_output, state.Allocator) }
			Provider_Tool_Calls_Destroy(calls, state.Allocator)
			return provider_stream_fail_allocation(state, "the completion reason could not be retained")
		}
		if usage_present { provider_stream_push(state, Provider_Usage_Event(usage)) }
		state^.Phase = .Completed
		// The push takes ownership of raw_output on every path.
		if calls != nil {
			provider_stream_push(state, Provider_Completed_Event{Reason = .Tool_Call, Reason_Text = reason_text, Tool_Calls = calls, Raw_Output = raw_output})
		} else {
			provider_stream_push(state, Provider_Completed_Event{Reason = .Stop, Reason_Text = reason_text, Raw_Output = raw_output})
		}
		return .None
	case "response.incomplete":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "duplicate response completion") }
		reason := "incomplete"
		if raw_details, present := response["incomplete_details"]; present {
			if _, is_null := raw_details.(json.Null); !is_null {
				details, details_ok := raw_details.(json.Object)
				if !details_ok { return provider_stream_fail(state, .Invalid_Data, "incomplete details are invalid") }
				detail_reason, _, reason_ok := provider_json_string(details, "reason")
				if !reason_ok { return provider_stream_fail(state, .Invalid_Data, "incomplete details are invalid") }
				if detail_reason != "" { reason = detail_reason }
			}
		}
		reason_text, reason_error := strings.clone(reason, state.Allocator)
		if reason_error != nil {
			return provider_stream_fail_allocation(state, "the completion reason could not be retained")
		}
		if usage_present { provider_stream_push(state, Provider_Usage_Event(usage)) }
		state^.Phase = .Completed
		provider_stream_push(state, Provider_Completed_Event{Reason = openai_responses_incomplete_reason(reason), Reason_Text = reason_text})
		return .None
	case "response.failed":
		message := "response failed"
		code := ""
		if raw_error, present := response["error"]; present {
			if _, is_null := raw_error.(json.Null); !is_null {
				error_object, error_ok := raw_error.(json.Object)
				if !error_ok { return provider_stream_fail(state, .Invalid_Data, "response error is invalid") }
				error_message, _, message_ok := provider_json_string(error_object, "message")
				error_code, _, code_ok := provider_json_string(error_object, "code")
				if !message_ok || !code_ok { return provider_stream_fail(state, .Invalid_Data, "response error is invalid") }
				if error_message != "" { message = error_message }
				error_type := ""
				if value, type_present, valid := provider_json_string(error_object, "type"); valid && type_present { error_type = value }
				code = openai_error_class_code(error_code, error_type)
			}
		}
		// A failed response may still carry usage. Deliver usage first, then
		// the error; a malformed terminal payload yields the error alone.
		failed_event, failed_event_error := provider_error_event_make(.API_Error, message, code, allocator = state.Allocator)
		if failed_event_error != nil {
			return provider_stream_fail_allocation(state, "the provider error could not be retained")
		}
		if usage_present { provider_stream_push(state, Provider_Usage_Event(usage)) }
		state^.Phase = .Failed
		provider_stream_push(state, failed_event)
		return .None
	}
	return provider_stream_fail(state, .Invalid_Data, "unknown terminal response event")
}

@(require_results)
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

@(require_results)
openai_responses_event_fragment :: proc(object: json.Object, state: ^Provider_Stream_State) -> (^Provider_Tool_Fragment, Provider_Stream_Error) {
	fragment, slot_error := provider_tool_fragment_by_item(object, state)
	if slot_error != .None { return nil, slot_error }
	if id, present, ok := provider_json_string(object, "item_id"); ok && present && id != "" {
		if fragment.Item_ID != "" && fragment.Item_ID != id { return nil, provider_stream_fail(state, .Invalid_Data, "output item id changed") }
		if fragment.Item_ID == "" {
			owned, clone_error := strings.clone(id, state.Allocator)
			if clone_error != nil {
				return nil, provider_stream_fail_allocation(state, "the output item id could not be retained")
			}
			fragment.Item_ID = owned
		}
	} else if !ok { return nil, provider_stream_fail(state, .Invalid_Data, "item id is invalid") }
	return fragment, .None
}

@(require_results)
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
	if api_error, is_error, api_error_error := openai_parse_api_error(object, state.Allocator); is_error {
		if api_error_error != nil {
			return provider_stream_fail_allocation(state, "the provider error could not be retained")
		}
		provider_stream_batch_clear(state)
		provider_stream_push(state, api_error)
		state.Phase = .Failed
		return .None
	}
	event_type, type_present, type_ok := provider_json_string(object, "type")
	if !type_ok || !type_present || event_type == "" { return provider_stream_fail(state, .Invalid_Data, "stream event has no type") }
	switch event_type {
	case "response.output_text.delta", "response.refusal.delta":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "data received after completion") }
		delta, delta_present, delta_ok := provider_json_string(object, "delta")
		if !delta_ok { return provider_stream_fail(state, .Invalid_Data, "delta is not text") }
		if delta_present && delta != "" {
			owned, clone_error := strings.clone(delta, state.Allocator)
			if clone_error != nil { return provider_stream_fail_allocation(state, "the response text could not be retained") }
			provider_stream_push(state, Provider_Text_Event{Text = owned})
		}
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
		message, _, message_ok := provider_json_string(object, "message")
		if !message_ok { return provider_stream_fail(state, .Invalid_Data, "error message is invalid") }
		if message == "" { message = "provider returned an API error" }
		code, _, code_ok := provider_json_string(object, "code")
		if !code_ok { return provider_stream_fail(state, .Invalid_Data, "error code is invalid") }
		error_event, error_event_error := provider_error_event_make(.API_Error, message, code, allocator = state.Allocator)
		if error_event_error != nil {
			return provider_stream_fail_allocation(state, "the provider error could not be retained")
		}
		provider_stream_batch_clear(state)
		provider_stream_push(state, error_event)
		state^.Phase = .Failed
		return .None
	case "response.function_call_arguments.delta":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "data received after completion") }
		fragment, slot_error := openai_responses_event_fragment(object, state)
		if slot_error != .None { return slot_error }
		delta, delta_present, delta_ok := provider_json_string(object, "delta")
		if !delta_ok { return provider_stream_fail(state, .Invalid_Data, "arguments delta is not text") }
		if delta_present && delta != "" {
			if _, append_error := append(&fragment.Arguments, delta); append_error != nil {
				return provider_stream_fail_allocation(state, "the tool call arguments could not be retained")
			}
		}
		fragment.Present = true
		return .None
	case "response.function_call_arguments.done":
		if state^.Phase == .Completed { return provider_stream_fail(state, .Invalid_Data, "data received after completion") }
		fragment, slot_error := openai_responses_event_fragment(object, state)
		if slot_error != .None { return slot_error }
		if arguments, present, ok := provider_json_string(object, "arguments"); ok && present && arguments != "" {
			// The done event repeats full arguments; replace the
			// accumulated bytes so a replayed prefix is not doubled.
			clear(&fragment.Arguments)
			if _, append_error := append(&fragment.Arguments, arguments); append_error != nil {
				return provider_stream_fail_allocation(state, "the tool call arguments could not be retained")
			}
		} else if !ok { return provider_stream_fail(state, .Invalid_Data, "call arguments are invalid") }
		fragment.Present = true
		fragment.Complete = true
		return .None
	case:
		return .None
	}
}
