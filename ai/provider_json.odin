package ai

import "core:encoding/json"
import "core:mem"
import "core:strings"

// JSON field readers and the error event shared by the OpenAI and Anthropic adapters.

@(require_results)
provider_json_string :: proc(object: json.Object, key: string) -> (string, bool, bool) {
	value, present := object[key]
	if !present { return "", false, true }
	text, ok := value.(json.String)
	if ok { return string(text), true, true }
	if _, is_null := value.(json.Null); is_null { return "", true, true }
	return "", true, false
}

@(require_results)
provider_json_integer :: proc(object: json.Object, key: string) -> (i64, bool, bool) {
	value, present := object[key]
	if !present { return 0, false, true }
	integer, ok := value.(json.Integer)
	if !ok { return 0, true, false }
	return i64(integer), true, true
}

// provider_error_event_make builds the error event every provider API reports a failure with. The
// event owns its strings, and a failure to retain them yields no event and the allocator
// error, so a caller never delivers a failure whose wording was silently dropped.
@(require_results)
provider_error_event_make :: proc(
	kind: Provider_Error_Kind,
	message: string,
	code := "",
	detail_code := "",
	allocator := context.allocator,
) -> (
	Provider_Event,
	mem.Allocator_Error,
) {
	owned_message, message_error := strings.clone(message, allocator)
	if message_error != nil { return nil, message_error }
	owned_code, code_error := strings.clone(code, allocator)
	if code_error != nil {
		if owned_message != "" { delete(owned_message, allocator) }
		return nil, code_error
	}
	owned_detail_code, detail_code_error := strings.clone(detail_code, allocator)
	if detail_code_error != nil {
		if owned_message != "" { delete(owned_message, allocator) }
		if owned_code != "" { delete(owned_code, allocator) }
		return nil, detail_code_error
	}
	return Provider_Error_Event{Kind = kind, Message = owned_message, Provider_Code = owned_code, Provider_Detail_Code = owned_detail_code}, nil
}
