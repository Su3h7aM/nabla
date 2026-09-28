package ai

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

// Shared OpenAI helpers used by the Chat Completions and Responses adapters.

// OPENAI_TOOL_SCHEMA_DEPTH is the deepest JSON document the schema validator and
// the argument reader accept. Both walk nested values by recursing, so this is
// the recursion guard that keeps a hostile document off the stack; it is not a
// statement about which schemas an API accepts.
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

@(require_results)
openai_value_string :: proc(object: json.Object, key: string) -> (string, bool, bool) {
	value, present := object[key]
	if !present { return "", false, true }
	text, ok := value.(json.String)
	if ok { return string(text), true, true }
	if _, is_null := value.(json.Null); is_null { return "", true, true }
	return "", true, false
}

@(require_results)
openai_value_integer :: proc(object: json.Object, key: string) -> (i64, bool, bool) {
	value, present := object[key]
	if !present { return 0, false, true }
	integer, ok := value.(json.Integer)
	if !ok { return 0, true, false }
	return i64(integer), true, true
}

// openai_error_event builds the error event both OpenAI APIs report a failure with. The
// event owns its strings, and a failure to retain them yields no event and the allocator
// error, so a caller never delivers a failure whose wording was silently dropped.
@(require_results)
openai_error_event :: proc(kind: Provider_Error_Kind, message: string, code := "", allocator := context.allocator) -> (Provider_Event, mem.Allocator_Error) {
	owned_message, message_error := strings.clone(message, allocator)
	if message_error != nil { return nil, message_error }
	owned_code, code_error := strings.clone(code, allocator)
	if code_error != nil {
		if owned_message != "" { delete(owned_message, allocator) }
		return nil, code_error
	}
	return Provider_Error_Event{Kind = kind, Message = owned_message, Provider_Code = owned_code}, nil
}

// openai_error_rejection decodes the error document this API returns for a refused
// request, through the same reader an in-stream error event uses, so a refusal read
// from a response body and one read from a stream cannot drift apart. The returned
// strings are owned by allocator, and a failure to retain them is reported rather than
// read as a document this API did not send.
@(require_results)
openai_error_rejection :: proc(body: []u8, allocator := context.allocator) -> (Provider_Rejection, mem.Allocator_Error) {
	value, object, parsed := provider_error_document(body, allocator)
	if !parsed { return {}, nil }
	defer json.destroy_value(value, allocator)
	event, is_error, event_error := openai_parse_api_error(object, allocator)
	if !is_error { return {}, nil }
	if event_error != nil { return {}, event_error }
	error_event, is_error_event := event.(Provider_Error_Event)
	if !is_error_event {
		owned := event
		Provider_Event_Destroy(&owned, allocator)
		return {}, nil
	}
	// The rejection takes the strings the parsed event built; nothing is cloned again.
	return Provider_Rejection{code = error_event.Provider_Code, message = error_event.Message}, nil
}

// openai_failure_class names the meaning this API gives to one of its own error
// codes. The codes are matched exactly: they are machine-readable tokens the API
// documents, and a prefix or substring rule would classify codes it never wrote
// down. An unrecognized code is left to the status that carried it, which is the
// fallback a compatible endpoint depends on.
@(require_results)
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

// openai_parse_api_error reads the error envelope both OpenAI APIs return. is_error says the
// object carried one, and a non-nil err says the event could not be retained.
@(require_results)
openai_parse_api_error :: proc(object: json.Object, allocator := context.allocator) -> (event: Provider_Event, is_error: bool, err: mem.Allocator_Error) {
	raw, present := object["error"]
	if !present { return nil, false, nil }
	error_object, ok := raw.(json.Object)
	if !ok {
		invalid, invalid_error := openai_error_event(.API_Error, "invalid provider error object", allocator = allocator)
		return invalid, true, invalid_error
	}
	message, message_present, message_ok := openai_value_string(error_object, "message")
	if !message_ok {
		invalid, invalid_error := openai_error_event(.API_Error, "invalid provider error message", allocator = allocator)
		return invalid, true, invalid_error
	}
	if !message_present || message == "" { message = "provider returned an API error" }
	code, code_present, code_ok := openai_value_string(error_object, "code")
	if !code_ok {
		if number, number_present, number_ok := openai_value_integer(error_object, "code"); number_ok && number_present {
			code = fmt.aprintf("%d", number, allocator = allocator)
		} else if !code_present {
			code = ""
		} else {
			invalid, invalid_error := openai_error_event(.API_Error, "invalid provider error code", allocator = allocator)
			return invalid, true, invalid_error
		}
	}
	parsed, parsed_error := openai_error_event(.API_Error, message, code, allocator)
	return parsed, true, parsed_error
}

openai_finish_reason :: proc(reason: string) -> Provider_Finish_Reason {
	if reason == "stop" { return .Stop }
	if reason == "length" { return .Length }
	if reason == "content_filter" { return .Content_Filter }
	if reason == "tool_calls" || reason == "function_call" { return .Tool_Call }
	return .Unknown
}

// Validate a tool parameter schema: one JSON object with nothing trailing. The
// walk recurses and is bounded by OPENAI_TOOL_SCHEMA_DEPTH; the worker enforces
// the same shape on arguments.
@(require_results)
openai_tool_schema_valid :: proc(raw: string) -> bool {
	if len(raw) == 0 { return false }
	bytes := transmute([]u8)raw
	end := openai_json_object_check(bytes, 0, OPENAI_TOOL_SCHEMA_DEPTH)
	if end < 0 { return false }
	return openai_json_skip(bytes, end) == len(bytes)
}

// openai_tool_parameters_write writes the parameters field of one tool definition and
// reports whether the wire can carry it. The object itself comes from the shared writer,
// which reads a schema once and keeps the bytes: a schema does not change between the
// requests of one conversation.
@(private = "package", require_results)
openai_tool_parameters_write :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder, first: ^bool, schema: string, allocator := context.allocator) -> bool {
	encode_write_field(cursor, body, first, "parameters")
	return encode_write_object(cursor, body, schema, allocator)
}

openai_json_skip :: proc(raw: []u8, position: int) -> int {
	i := position
	for i < len(raw) && (raw[i] == ' ' || raw[i] == '\t' || raw[i] == '\n' || raw[i] == '\r') { i += 1 }
	return i
}

// openai_json_string_span spans a JSON string starting at the opening quote. It returns
// the content start and the position after the closing quote, or -1 twice on bad syntax.
openai_json_string_span :: proc(raw: []u8, position: int) -> (int, int) {
	if position >= len(raw) || raw[position] != '"' { return -1, -1 }
	i := position + 1
	for i < len(raw) {
		character := raw[i]
		if character == '"' { return position + 1, i + 1 }
		if character == '\\' {
			i += 1
			if i >= len(raw) { return -1, -1 }
			escape := raw[i]
			if escape == 'u' {
				for offset in 1 ..= 4 {
					if i + offset >= len(raw) { return -1, -1 }
					hex_digit := raw[i + offset]
					if !(hex_digit >= '0' && hex_digit <= '9' ||
						   hex_digit >= 'a' && hex_digit <= 'f' ||
						   hex_digit >= 'A' && hex_digit <= 'F') { return -1, -1 }
				}
				i += 4
			} else if escape != '"' && escape != '\\' && escape != '/' && escape != 'b' && escape != 'f' && escape != 'n' && escape != 'r' && escape != 't' {
				return -1, -1
			}
		} else if character < 0x20 {
			return -1, -1
		}
		i += 1
	}
	return -1, -1
}

openai_json_literal :: proc(raw: []u8, position: int, word: string) -> int {
	if position + len(word) > len(raw) { return -1 }
	for offset in 0 ..< len(word) {
		if raw[position + offset] != word[offset] { return -1 }
	}
	return position + len(word)
}

openai_json_number_end :: proc(raw: []u8, position: int) -> int {
	i := position
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

// openai_json_value_skip skips one JSON value and returns the position after it. Objects
// recurse with the same duplicate-key rule, arrays recurse for shape only.
@(require_results)
openai_json_value_skip :: proc(raw: []u8, position, depth: int) -> (int, bool) {
	if depth < 0 { return position, false }
	i := openai_json_skip(raw, position)
	if i >= len(raw) { return i, false }
	character := raw[i]
	if character == '"' {
		_, end := openai_json_string_span(raw, i)
		if end < 0 { return i, false }
		return end, true
	}
	if character == '{' {
		end := openai_json_object_check(raw, i, depth)
		if end < 0 { return i, false }
		return end, true
	}
	if character == '[' {
		i += 1
		i = openai_json_skip(raw, i)
		if i < len(raw) && raw[i] == ']' { return i + 1, true }
		for {
			next, ok := openai_json_value_skip(raw, i, depth - 1)
			if !ok { return i, false }
			i = openai_json_skip(raw, next)
			if i < len(raw) && raw[i] == ',' {
				i = openai_json_skip(raw, i + 1)
				continue
			}
			if i < len(raw) && raw[i] == ']' { return i + 1, true }
			return i, false
		}
	}
	if character == 't' {
		end := openai_json_literal(raw, i, "true")
		return end, end >= 0
	}
	if character == 'f' {
		end := openai_json_literal(raw, i, "false")
		return end, end >= 0
	}
	if character == 'n' {
		end := openai_json_literal(raw, i, "null")
		return end, end >= 0
	}
	end := openai_json_number_end(raw, i)
	return end, end >= 0
}

// openai_json_key_seen reports whether the key bytes appeared earlier in this object. The
// caller passes the keys seen so far, and a linear scan is what its small list costs.
openai_json_key_seen :: proc(raw: []u8, seen: [dynamic][2]int, key_start, key_end: int) -> bool {
	for entry in seen {
		if entry[1] - entry[0] != key_end - key_start { continue }
		match := true
		for offset in 0 ..< (key_end - key_start) {
			if raw[entry[0] + offset] != raw[key_start + offset] {
				match = false
				break
			}
		}
		if match { return true }
	}
	return false
}

openai_json_object_check :: proc(raw: []u8, position, depth: int) -> int {
	if depth < 0 { return -1 }
	i := openai_json_skip(raw, position)
	if i >= len(raw) || raw[i] != '{' { return -1 }
	i += 1
	i = openai_json_skip(raw, i)
	if i < len(raw) && raw[i] == '}' { return i + 1 }
	seen, seen_error := make([dynamic][2]int, 0, context.temp_allocator)
	if seen_error != nil { return -1 }
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
		if _, append_error := append(&seen, [2]int{key_start, key_end}); append_error != nil { return -1 }
		i = openai_json_skip(raw, i)
		if i >= len(raw) || raw[i] != ':' { return -1 }
		i = openai_json_skip(raw, i + 1)
		tail, value_ok := openai_json_value_skip(raw, i, depth - 1)
		if !value_ok { return -1 }
		i = tail
		i = openai_json_skip(raw, i)
		if i < len(raw) && raw[i] == ',' {
			i += 1
			continue
		}
		if i < len(raw) && raw[i] == '}' { return i + 1 }
		return -1
	}
}
