package ai

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

// Shared OpenAI helpers used by the Chat Completions and Responses adapters.

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

// openai_failure_class names the meaning this API gives to one of its own error
// codes or types. The tokens are matched exactly, and an unrecognized one is left
// to the status that carried it.
@(require_results)
openai_failure_class :: proc(code: string) -> (Provider_Failure_Class, bool) {
	switch code {
	case "context_length_exceeded":
		return .Context_Overflow, true
	case "insufficient_quota",
	     "credit_balance_exhausted",
	     "usage_limit_exceeded",
	     "organization_usage_limit_exceeded",
	     "organization_spend_limit_exceeded",
	     "project_spend_limit_exceeded":
		return .Quota, true
	// invalid_api_key and model_not_found are not in the published error-codes guide; they
	// are classified by their meaning, and the status decides when they are absent.
	case "invalid_api_key", "authentication_error":
		return .Authentication, true
	case "model_not_found", "not_found_error":
		return .Not_Found, true
	case "content_policy_violation", "bio_policy", "cyber_policy", "misalignment_policy_violation", "image_content_policy_violation":
		return .Content_Policy, true
	case "server_error", "server_is_overloaded", "vector_store_timeout", "service_unavailable_error":
		return .Provider_Unavailable, true
	case "rate_limit_exceeded", "slow_down", "rate_limit_error":
		return .Rate_Limited, true
	case "invalid_prompt",
	     "data_residency_mismatch",
	     "invalid_image",
	     "invalid_image_format",
	     "invalid_base64_image",
	     "invalid_image_url",
	     "image_too_large",
	     "image_too_small",
	     "image_parse_error",
	     "invalid_image_mode",
	     "image_file_too_large",
	     "unsupported_image_media_type",
	     "empty_image_file",
	     "failed_to_download_image",
	     "image_file_not_found":
		return .Invalid_Request, true
	}
	return .None, false
}

// openai_error_class_code picks the token a rejection is classified by: the error's code
// when it is one this package knows, otherwise its type, which names a broader class. The
// generic invalid_request_error type is not classified here, so the status decides it.
openai_error_class_code :: proc(code, error_type: string) -> string {
	if code != "" {
		if _, known := openai_failure_class(code); known { return code }
	}
	if error_type != "" { return error_type }
	return code
}

// openai_parse_api_error reads the error envelope both OpenAI APIs return. is_error says the
// object carried one, and a non-nil err says the event could not be retained.
@(require_results)
openai_parse_api_error :: proc(object: json.Object, allocator := context.allocator) -> (event: Provider_Event, is_error: bool, err: mem.Allocator_Error) {
	raw, present := object["error"]
	if !present { return nil, false, nil }
	error_object, ok := raw.(json.Object)
	if !ok {
		invalid, invalid_error := provider_error_event_make(.API_Error, "invalid provider error object", allocator = allocator)
		return invalid, true, invalid_error
	}
	message, message_present, message_ok := provider_json_string(error_object, "message")
	if !message_ok {
		invalid, invalid_error := provider_error_event_make(.API_Error, "invalid provider error message", allocator = allocator)
		return invalid, true, invalid_error
	}
	if !message_present || message == "" { message = "provider returned an API error" }
	code, code_present, code_ok := provider_json_string(error_object, "code")
	number_text: [32]u8
	if !code_ok {
		if number, number_present, number_ok := provider_json_integer(error_object, "code"); number_ok && number_present {
			code = fmt.bprintf(number_text[:], "%d", number)
		} else if !code_present {
			code = ""
		} else {
			invalid, invalid_error := provider_error_event_make(.API_Error, "invalid provider error code", allocator = allocator)
			return invalid, true, invalid_error
		}
	}
	error_type := ""
	if value, type_present, valid := provider_json_string(error_object, "type"); valid && type_present { error_type = value }
	code = openai_error_class_code(code, error_type)
	parsed, parsed_error := provider_error_event_make(.API_Error, message, code, allocator = allocator)
	return parsed, true, parsed_error
}

openai_finish_reason :: proc(reason: string) -> Provider_Finish_Reason {
	if reason == "stop" { return .Stop }
	if reason == "length" { return .Length }
	if reason == "content_filter" { return .Content_Filter }
	if reason == "tool_calls" || reason == "function_call" { return .Tool_Call }
	return .Unknown
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
