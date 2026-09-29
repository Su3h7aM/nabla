package acp

import "core:encoding/json"
import "core:strings"

Jsonrpc_Null :: struct {}
Jsonrpc_Id :: union {
	i64,
	f64,
	string,
	Jsonrpc_Null,
}
Rpc_Error :: struct {
	code:         i64,
	message:      string,
	data:         json.Value,
	data_present: bool,
}
Envelope_Kind :: enum {
	Invalid,
	Request,
	Notification,
	Response,
}
Envelope :: struct {
	kind:           Envelope_Kind,
	id:             Jsonrpc_Id,
	id_present:     bool,
	method:         string,
	params:         json.Value,
	params_present: bool,
	result:         json.Value,
	result_present: bool,
	rpc_error:      Rpc_Error,
	error_present:  bool,
}
Envelope_Error :: enum {
	None,
	Invalid_JSON,
	Invalid_Envelope,
	Invalid_Version,
	Invalid_ID,
	Invalid_Method,
	Invalid_Result,
	Invalid_Error,
	Allocation,
}

Params_Error :: enum {
	None,
	Invalid,
	Allocation,
}

@(require_results)
parse_envelope :: proc(payload: string, allocator := context.allocator) -> (Envelope, Envelope_Error) {
	value, parse_err := json.parse_string(payload, .JSON, true, allocator)
	if parse_err != nil {
		if parse_err == .Out_Of_Memory || parse_err == .Invalid_Allocator { return {}, .Allocation }
		return {}, .Invalid_JSON
	}
	defer json.destroy_value(value, allocator)
	object, is_object := value.(json.Object)
	if !is_object { return {}, .Invalid_Envelope }
	version, version_ok := object_string(object, "jsonrpc")
	if !version_ok || version != "2.0" { return {}, .Invalid_Version }
	parsed_id, parsed_id_present, id_error := object_id(object, "id", allocator)
	if id_error != .None { return {}, id_error }
	// The id can own a cloned string, so every rejection below releases it.
	result := Envelope {
		id         = parsed_id,
		id_present = parsed_id_present,
	}
	parsed_method, method_present, method_ok := object_string_present(object, "method")
	if !method_ok || (method_present && parsed_method == "") {
		destroy_envelope(&result, allocator)
		return {}, .Invalid_Method
	}
	result_value, result_present := object["result"]
	error_value, error_present := object["error"]
	if method_present {
		if result_present || error_present {
			destroy_envelope(&result, allocator)
			return {}, .Invalid_Envelope
		}
	} else if !parsed_id_present || (result_present == error_present) {
		destroy_envelope(&result, allocator)
		return {}, .Invalid_Result
	}
	result.kind = .Notification
	if method_present {
		method, method_error := strings.clone(parsed_method, allocator)
		if method_error != nil {
			destroy_envelope(&result, allocator)
			return {}, .Allocation
		}
		result.method = method
		if parsed_id_present { result.kind = .Request }
		if params_value, present := object["params"]; present {
			// The subtree moves into the envelope instead of being copied, so it is
			// removed from the document the deferred destroy releases.
			owned_key, _ := delete_key(&value.(json.Object), "params")
			delete(owned_key, allocator)
			result.params = params_value
			result.params_present = true
		}
		return result, .None
	}
	result.kind = .Response
	if error_present {
		parsed_error, error_error := parse_rpc_error(error_value, allocator)
		if error_error != .None {
			destroy_envelope(&result, allocator)
			return {}, error_error
		}
		result.rpc_error = parsed_error
		result.error_present = true
	}
	if result_present {
		result.result = json.clone_value(result_value, allocator)
		result.result_present = true
	}
	return result, .None
}

// envelope_error_text says what a message failed to be, in the words the client reads.
envelope_error_text :: proc(err: Envelope_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Invalid_JSON:
		return "the message is not valid JSON"
	case .Invalid_Envelope:
		return "the message is not a JSON-RPC envelope"
	case .Invalid_Version:
		return "the message does not declare JSON-RPC 2.0"
	case .Invalid_ID:
		return "the message's id is neither a number nor a string"
	case .Invalid_Method:
		return "the message names no method"
	case .Invalid_Result:
		return "the message is neither a request nor a response"
	case .Invalid_Error:
		return "the message's error object is malformed"
	case .Allocation:
		return "the message could not be stored"
	}
	return "the message could not be read"
}

// parse_batch recognizes a JSON-RPC batch without changing the single-envelope
// parser. Individual entries are returned as text so the normal dispatcher owns
// their validation and response rules.
@(require_results)
parse_batch :: proc(payload: string, allocator := context.allocator) -> (frames: [dynamic]string, is_batch: bool, err: Envelope_Error) {
	trimmed := strings.trim_space(payload)
	if len(trimmed) == 0 || trimmed[0] != '[' { return {}, false, .None }
	value, parse_err := json.parse_string(payload, .JSON, true, allocator)
	if parse_err != nil {
		if parse_err == .Out_Of_Memory || parse_err == .Invalid_Allocator { return {}, true, .Allocation }
		return {}, true, .Invalid_JSON
	}
	defer json.destroy_value(value, allocator)
	items, is_array := value.(json.Array)
	// JSON-RPC 2.0 section 6 requires a batch to be an array with at least one value.
	if !is_array || len(items) == 0 { return {}, true, .Invalid_Envelope }
	batch, allocation_error := make([dynamic]string, 0, len(items), allocator)
	if allocation_error != nil { return {}, true, .Allocation }
	frames = batch
	for item in items {
		body, marshal_err := json.marshal(item, allocator = allocator)
		if marshal_err != nil {
			for frame in frames { delete(frame, allocator) }
			delete(frames)
			return {}, true, .Allocation
		}
		frame, clone_err := strings.clone(string(body), allocator)
		delete(body, allocator)
		if clone_err != nil {
			for owned in frames { delete(owned, allocator) }
			delete(frames)
			return {}, true, .Allocation
		}
		appended := append(&frames, frame)
		if appended != 1 {
			if appended == 0 { delete(frame, allocator) }
			for owned in frames { delete(owned, allocator) }
			delete(frames)
			return {}, true, .Allocation
		}
	}
	return frames, true, .None
}

// params_decode reads one message's params into a typed payload. The parsed value is
// encoded again because the JSON package decodes from bytes. The target's strings are
// owned by allocator. It returns Invalid when the value does not match the target and
// Allocation when encoding or decoding runs out of storage.
@(require_results)
params_decode :: proc(value: json.Value, target: ^$T, allocator := context.allocator) -> Params_Error {
	if value == nil { return .Invalid }
	encoded, marshal_err := json.marshal(value, allocator = allocator)
	if marshal_err != nil { return .Allocation }
	defer delete(encoded, allocator)
	if unmarshal_err := json.unmarshal(encoded, target, allocator = allocator); unmarshal_err != nil {
		#partial switch error in unmarshal_err {
		case json.Error:
			if error == .Out_Of_Memory || error == .Invalid_Allocator { return .Allocation }
		}
		return .Invalid
	}
	return .None
}

@(require_results)
object_string_present :: proc(object: json.Object, key: string) -> (string, bool, bool) {
	value, present := object[key]
	if !present { return "", false, true }
	text, is_string := value.(json.String)
	if !is_string { return "", true, false }
	return string(text), true, true
}
@(require_results)
object_string :: proc(object: json.Object, key: string) -> (string, bool) {
	value, present := object[key]
	if !present { return "", false }
	text, is_string := value.(json.String)
	if !is_string { return "", false }
	return string(text), true
}
@(require_results)
object_id :: proc(object: json.Object, key: string, allocator := context.allocator) -> (id: Jsonrpc_Id, present: bool, err: Envelope_Error) {
	value, has_value := object[key]
	if !has_value { return nil, false, .None }
	#partial switch id_value in value {
	case json.Integer:
		return i64(id_value), true, .None
	case json.Float:
		return f64(id_value), true, .None
	case json.String:
		text, clone_error := strings.clone(string(id_value), allocator)
		if clone_error != nil { return nil, true, .Allocation }
		return text, true, .None
	case json.Null:
		return Jsonrpc_Null{}, true, .None
	}
	return nil, true, .Invalid_ID
}
@(require_results)
parse_rpc_error :: proc(value: json.Value, allocator := context.allocator) -> (Rpc_Error, Envelope_Error) {
	object, is_object := value.(json.Object)
	if !is_object { return {}, .Invalid_Error }
	code_value, code_present := object["code"]
	message_value, message_present := object["message"]
	code, code_is_integer := code_value.(json.Integer)
	message_text, message_is_string := message_value.(json.String)
	if !code_present || !message_present || !code_is_integer || !message_is_string { return {}, .Invalid_Error }
	message, message_error := strings.clone(string(message_text), allocator)
	if message_error != nil { return {}, .Allocation }
	result := Rpc_Error {
		code    = i64(code),
		message = message,
	}
	if data, present := object["data"]; present {
		result.data = json.clone_value(data, allocator)
		result.data_present = true
	}
	return result, .None
}
destroy_envelope :: proc(envelope: ^Envelope, allocator := context.allocator) {
	if envelope.id_present {
		#partial switch id in envelope.id {
		case string:
			delete(id, allocator)
		}
	}
	if envelope.method != "" { delete(envelope.method, allocator) }
	if envelope.params_present { json.destroy_value(envelope.params, allocator) }
	if envelope.result_present { json.destroy_value(envelope.result, allocator) }
	if envelope.error_present {
		delete(envelope.rpc_error.message, allocator)
		if envelope.rpc_error.data_present { json.destroy_value(envelope.rpc_error.data, allocator) }
	}
	envelope^ = {}
}
