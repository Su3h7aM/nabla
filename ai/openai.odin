package ai

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

// Shared OpenAI helpers used by the Chat Completions and Responses adapters.
OPENAI_ERROR_MESSAGE_LIMIT :: 1024
OPENAI_TOOL_ARGS_BYTES :: 64 * 1024
OPENAI_TOOL_SCHEMA_DEPTH :: 16

openai_role_name :: proc(role: Provider_Role) -> string {
	switch role {
	case .System:
		return "system"
	case .User:
		return "user"
	case .Assistant:
		return "assistant"
	case .Tool:
		return "tool"
	case .Reasoning:
		return ""
	case .Invalid:
		return ""
	}
	return ""
}

openai_copy_limited :: proc(value: string, allocator := context.allocator) -> string {
	end := len(value)
	if end > OPENAI_ERROR_MESSAGE_LIMIT { end = OPENAI_ERROR_MESSAGE_LIMIT }
	return strings.clone(value[:end], allocator)
}

openai_value_string :: proc(object: json.Object, key: string) -> (string, bool, bool) {
	value, present := object[key]
	if !present { return "", false, true }
	text, ok := value.(json.String)
	if ok { return string(text), true, true }
	if _, is_null := value.(json.Null); is_null { return "", true, true }
	return "", true, false
}

openai_value_integer :: proc(object: json.Object, key: string) -> (i64, bool, bool) {
	value, present := object[key]
	if !present { return 0, false, true }
	integer, ok := value.(json.Integer)
	if !ok { return 0, true, false }
	return i64(integer), true, true
}

openai_error_event :: proc(kind: Provider_Error_Kind, message: string, code := "", allocator := context.allocator) -> Provider_Event {
	return Provider_Error_Event{Kind = kind, Message = openai_copy_limited(message, allocator), Provider_Code = openai_copy_limited(code, allocator)}
}

// openai_error_rejection decodes the error document this API returns for a refused
// request, through the same reader an in-stream error event uses, so a refusal read
// from a response body and one read from a stream cannot drift apart. The returned
// strings are owned by allocator.
openai_error_rejection :: proc(body: []u8, allocator := context.allocator) -> Provider_Rejection {
	value, object, parsed := provider_error_document(body, allocator)
	if !parsed { return {} }
	defer json.destroy_value(value, allocator)
	event, is_error := openai_parse_api_error(object, allocator)
	if !is_error { return {} }
	defer Provider_Event_Destroy(&event, allocator)
	error_event, is_error_event := event.(Provider_Error_Event)
	if !is_error_event { return {} }
	return Provider_Rejection {
		code = provider_bounded_text(error_event.Provider_Code, PROVIDER_MAX_CODE_BYTES, allocator),
		message = provider_bounded_text(error_event.Message, PROVIDER_MAX_MESSAGE_BYTES, allocator),
	}
}

// openai_failure_class names the meaning this API gives to one of its own error
// codes. The codes are matched exactly: they are machine-readable tokens the API
// documents, and a prefix or substring rule would classify codes it never wrote
// down. An unrecognized code is left to the status that carried it, which is the
// fallback a compatible endpoint depends on.
openai_failure_class :: proc(code: string) -> (Provider_Failure_Class, bool) {
	switch code {
	case "context_length_exceeded":
		return .Context_Overflow, true
	case "insufficient_quota":
		return .Quota, true
	case "content_policy_violation":
		return .Content_Policy, true
	}
	return .None, false
}

openai_parse_api_error :: proc(object: json.Object, allocator := context.allocator) -> (Provider_Event, bool) {
	raw, present := object["error"]
	if !present { return nil, false }
	error_object, ok := raw.(json.Object)
	if !ok { return openai_error_event(.API_Error, "invalid provider error object", allocator = allocator), true }
	message, message_present, message_ok := openai_value_string(error_object, "message")
	if !message_ok { return openai_error_event(.API_Error, "invalid provider error message", allocator = allocator), true }
	if !message_present || message == "" { message = "provider returned an API error" }
	code, code_present, code_ok := openai_value_string(error_object, "code")
	if !code_ok {
		if number, number_present, number_ok := openai_value_integer(error_object, "code"); number_ok && number_present {
			code = fmt.aprintf("%d", number, allocator = allocator)
		} else if !code_present {
			code = ""
		} else {
			return openai_error_event(.API_Error, "invalid provider error code", allocator = allocator), true
		}
	}
	return openai_error_event(.API_Error, message, code, allocator), true
}

openai_finish_reason :: proc(reason: string) -> Provider_Finish_Reason {
	if reason == "stop" { return .Stop }
	if reason == "length" { return .Length }
	if reason == "content_filter" { return .Content_Filter }
	if reason == "tool_calls" || reason == "function_call" { return .Tool_Call }
	return .Unknown
}

// Validate a tool parameter schema: bounded JSON object with nothing
// trailing. Depth-bounded; the worker enforces the same shape on arguments.
openai_tool_schema_valid :: proc(raw: string) -> bool {
	if len(raw) == 0 || len(raw) > OPENAI_TOOL_ARGS_BYTES { return false }
	bytes := transmute([]u8)raw
	end := openai_json_object_check(bytes, 0, OPENAI_TOOL_SCHEMA_DEPTH)
	if end < 0 { return false }
	return openai_json_skip(bytes, end) == len(bytes)
}

// openai_tool_parameters_bytes writes the object a tool's parameters are sent as into
// out: the tool's own schema text, read once into the value the wire carries, with the
// keys sorted like the rest of the body. It reports false when the text is not that
// object, which is what makes a request carrying it unsendable.
@(private = "package")
openai_tool_parameters_bytes :: proc(schema: string, out: ^strings.Builder, allocator: mem.Allocator) -> bool {
	value, parse_err := json.parse_string(schema, .JSON, true, allocator)
	if parse_err != nil { return false }
	defer json.destroy_value(value, allocator)
	if _, is_object := value.(json.Object); !is_object { return false }
	text, unparse_err := json.unparse(value, {sort_maps_by_key = true}, allocator)
	if unparse_err != nil { return false }
	defer delete(text, allocator)
	strings.write_string(out, text)
	return true
}

// openai_tool_parameters_write writes the parameters field of one tool definition and
// reports whether the wire can carry it. The field is written only once the object it
// carries is known, so a schema the wire cannot carry leaves nothing behind.
//
// A schema does not change between the requests of one conversation, so it is read once
// and the bytes are kept: every later request copies what was already written.
@(private = "package")
openai_tool_parameters_write :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder, first: ^bool, schema: string, allocator := context.allocator) -> bool {
	slot, hit := encode_slot_for(cursor, schema, .Parameters)
	if slot == nil {
		scratch := strings.builder_make(allocator)
		defer strings.builder_destroy(&scratch)
		if !openai_tool_parameters_bytes(schema, &scratch, allocator) { return false }
		encode_write_field(body, first, "parameters")
		strings.write_string(body, strings.to_string(scratch))
		return true
	}
	if !hit {
		slot.ok = openai_tool_parameters_bytes(schema, &slot.bytes, allocator)
		encode_slot_store(cursor, slot, schema)
	}
	if !slot.ok { return false }
	encode_write_field(body, first, "parameters")
	strings.write_string(body, strings.to_string(slot.bytes))
	return true
}

openai_json_skip :: proc(raw: []u8, pos: int) -> int {
	i := pos
	for i < len(raw) && (raw[i] == ' ' || raw[i] == '\t' || raw[i] == '\n' || raw[i] == '\r') { i += 1 }
	return i
}

// Span of a JSON string starting at the opening quote. Returns the content
// start and the position after the closing quote, or -1 on bad syntax.
openai_json_string_span :: proc(raw: []u8, pos: int) -> (int, int) {
	if pos >= len(raw) || raw[pos] != '"' { return -1, -1 }
	i := pos + 1
	for i < len(raw) {
		c := raw[i]
		if c == '"' { return pos + 1, i + 1 }
		if c == '\\' {
			i += 1
			if i >= len(raw) { return -1, -1 }
			esc := raw[i]
			if esc == 'u' {
				for k in 1 ..= 4 {
					if i + k >= len(raw) { return -1, -1 }
					h := raw[i + k]
					if !(h >= '0' && h <= '9' || h >= 'a' && h <= 'f' || h >= 'A' && h <= 'F') { return -1, -1 }
				}
				i += 4
			} else if esc != '"' && esc != '\\' && esc != '/' && esc != 'b' && esc != 'f' && esc != 'n' && esc != 'r' && esc != 't' {
				return -1, -1
			}
		} else if c < 0x20 {
			return -1, -1
		}
		i += 1
	}
	return -1, -1
}

openai_json_literal :: proc(raw: []u8, pos: int, word: string) -> int {
	if pos + len(word) > len(raw) { return -1 }
	for k in 0 ..< len(word) {
		if raw[pos + k] != word[k] { return -1 }
	}
	return pos + len(word)
}

openai_json_number_end :: proc(raw: []u8, pos: int) -> int {
	i := pos
	if i < len(raw) && (raw[i] == '-') { i += 1 }
	if i >= len(raw) { return -1 }
	if raw[i] == '0' { i += 1 } else if raw[i] >= '1' && raw[i] <= '9' {
		for i < len(raw) && raw[i] >= '0' && raw[i] <= '9' { i += 1 }
	} else { return -1 }
	if i < len(raw) && raw[i] == '.' {
		i += 1
		if i >= len(raw) || raw[i] < '0' || raw[i] > '9' { return -1 }
		for i < len(raw) && raw[i] >= '0' && raw[i] <= '9' { i += 1 }
	}
	if i < len(raw) && (raw[i] == 'e' || raw[i] == 'E') {
		i += 1
		if i < len(raw) && (raw[i] == '+' || raw[i] == '-') { i += 1 }
		if i >= len(raw) || raw[i] < '0' || raw[i] > '9' { return -1 }
		for i < len(raw) && raw[i] >= '0' && raw[i] <= '9' { i += 1 }
	}
	return i
}

// Skip one JSON value; returns the position after it. Objects recurse with
// the same duplicate-key rule, arrays recurse for shape only.
openai_json_value_skip :: proc(raw: []u8, pos, depth: int) -> (int, bool) {
	if depth < 0 { return pos, false }
	i := openai_json_skip(raw, pos)
	if i >= len(raw) { return i, false }
	c := raw[i]
	if c == '"' {
		_, end := openai_json_string_span(raw, i)
		if end < 0 { return i, false }
		return end, true
	}
	if c == '{' {
		end := openai_json_object_check(raw, i, depth)
		if end < 0 { return i, false }
		return end, true
	}
	if c == '[' {
		i += 1
		i = openai_json_skip(raw, i)
		if i < len(raw) && raw[i] == ']' { return i + 1, true }
		for {
			next, ok := openai_json_value_skip(raw, i, depth - 1)
			if !ok { return i, false }
			i = openai_json_skip(raw, next)
			if i < len(raw) && raw[i] == ',' { i = openai_json_skip(raw, i + 1); continue }
			if i < len(raw) && raw[i] == ']' { return i + 1, true }
			return i, false
		}
	}
	if c == 't' { end := openai_json_literal(raw, i, "true"); return end, end >= 0 }
	if c == 'f' { end := openai_json_literal(raw, i, "false"); return end, end >= 0 }
	if c == 'n' { end := openai_json_literal(raw, i, "null"); return end, end >= 0 }
	end := openai_json_number_end(raw, i)
	return end, end >= 0
}

// True when the key bytes appeared earlier in this object. The caller
// passes the keys seen so far; linear scan is fine because tool arguments
// stay under 64 KiB by contract.
openai_json_key_seen :: proc(raw: []u8, seen: [dynamic][2]int, key_start, key_end: int) -> bool {
	for entry in seen {
		if entry[1] - entry[0] != key_end - key_start { continue }
		match := true
		for k in 0 ..< (key_end - key_start) {
			if raw[entry[0] + k] != raw[key_start + k] { match = false; break }
		}
		if match { return true }
	}
	return false
}

openai_json_object_check :: proc(raw: []u8, pos, depth: int) -> int {
	if depth < 0 { return -1 }
	i := openai_json_skip(raw, pos)
	if i >= len(raw) || raw[i] != '{' { return -1 }
	i += 1
	i = openai_json_skip(raw, i)
	if i < len(raw) && raw[i] == '}' { return i + 1 }
	seen := make([dynamic][2]int, 0, context.temp_allocator)
	for {
		i = openai_json_skip(raw, i)
		key_start, key_end := -1, -1
		if i < len(raw) && raw[i] == '"' {
			key_start, key_end = openai_json_string_span(raw, i)
			if key_start < 0 { return -1 }
			i = key_end
		} else { return -1 }
		// Duplicate keys are invalid: the model must not send two
		// arguments under one name, and core's parser would hide them.
		// Only keys of this object count; values were already skipped.
		if openai_json_key_seen(raw, seen, key_start, key_end) { return -1 }
		append(&seen, [2]int{key_start, key_end})
		i = openai_json_skip(raw, i)
		if i >= len(raw) || raw[i] != ':' { return -1 }
		i = openai_json_skip(raw, i + 1)
		tail, value_ok := openai_json_value_skip(raw, i, depth - 1)
		if !value_ok { return -1 }
		i = tail
		i = openai_json_skip(raw, i)
		if i < len(raw) && raw[i] == ',' { i += 1; continue }
		if i < len(raw) && raw[i] == '}' { return i + 1 }
		return -1
	}
}
