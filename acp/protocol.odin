package acp

import "core:encoding/json"
import "core:strings"

Jsonrpc_Id :: union {
	i64,
	f64,
	string,
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
}

parse_envelope :: proc(payload: string, allocator := context.allocator) -> (Envelope, Envelope_Error) {
	value, parse_err := json.parse_string(payload, .JSON, true, allocator)
	if parse_err != nil { return {}, .Invalid_JSON }
	defer json.destroy_value(value, allocator)
	obj, ok := value.(json.Object)
	if !ok { return {}, .Invalid_Envelope }
	version, version_ok := object_string(obj, "jsonrpc")
	if !version_ok || version != "2.0" { return {}, .Invalid_Version }
	parsed_id, parsed_id_present, id_ok := object_id(obj, "id", allocator)
	if !id_ok { return {}, .Invalid_ID }
	// The id can own a cloned string, so every rejection below releases it.
	result := Envelope {
		id         = parsed_id,
		id_present = parsed_id_present,
	}
	parsed_method, method_present, method_ok := object_string_present(obj, "method")
	if !method_ok || (method_present && parsed_method == "") {
		destroy_envelope(&result, allocator)
		return {}, .Invalid_Method
	}
	result_value, result_present := obj["result"]
	error_value, error_present := obj["error"]
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
		result.method = strings.clone(parsed_method, allocator)
		if parsed_id_present { result.kind = .Request }
		if params_value, present := obj["params"]; present { result.params = json.clone_value(params_value, allocator); result.params_present = true }
		return result, .None
	}
	result.kind = .Response
	if error_present {
		parsed_error, error_ok := parse_rpc_error(error_value, allocator)
		if !error_ok {
			destroy_envelope(&result, allocator)
			return {}, .Invalid_Error
		}
		result.rpc_error = parsed_error
		result.error_present = true
	}
	if result_present { result.result = json.clone_value(result_value, allocator); result.result_present = true }
	return result, .None
}

object_string_present :: proc(obj: json.Object, key: string) -> (string, bool, bool) {
	value, present := obj[key]
	if !present { return "", false, true }
	str, ok := value.(json.String)
	if !ok { return "", true, false }
	return string(str), true, true
}
object_string :: proc(obj: json.Object, key: string) -> (string, bool) {
	value, present := obj[key]
	if !present { return "", false }
	str, ok := value.(json.String)
	if !ok { return "", false }
	return string(str), true
}
object_id :: proc(obj: json.Object, key: string, allocator := context.allocator) -> (Jsonrpc_Id, bool, bool) {
	value, present := obj[key]
	if !present { return nil, false, true }
	#partial switch v in value {
	case json.Integer:
		return i64(v), true, true
	case json.Float:
		return f64(v), true, true
	case json.String:
		return strings.clone(string(v), allocator), true, true
	}
	return nil, true, false
}
parse_rpc_error :: proc(value: json.Value, allocator := context.allocator) -> (Rpc_Error, bool) {
	obj, ok := value.(json.Object)
	if !ok { return {}, false }
	code_value, code_present := obj["code"]
	message_value, message_present := obj["message"]
	code, code_ok := code_value.(json.Integer)
	message, message_ok := message_value.(json.String)
	if !code_present || !message_present || !code_ok || !message_ok { return {}, false }
	result := Rpc_Error {
		code    = i64(code),
		message = strings.clone(string(message), allocator),
	}
	if data, present := obj["data"]; present { result.data = json.clone_value(data, allocator); result.data_present = true }
	return result, true
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
