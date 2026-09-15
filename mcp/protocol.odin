package mcp

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// PROTOCOL_VERSION is the only protocol revision this client implements. It has
// no handshake and no protocol session: every request states the version and the
// client's capabilities, and the server states what it supports.
PROTOCOL_VERSION :: "2026-07-28"

// CLIENT_NAME and CLIENT_VERSION identify this client in `_meta.clientInfo`. The
// protocol treats identity as self-reported and unverified, so it is advisory:
// no behavior and no access decision may depend on it.
CLIENT_NAME :: "nabla"
CLIENT_VERSION :: "0.1.0"

// Method and notification names. Only the operations the harness needs are
// named; anything else the client receives is reported as unexpected rather than
// guessed at.
METHOD_DISCOVER :: "server/discover"
METHOD_TOOLS_LIST :: "tools/list"
METHOD_TOOLS_CALL :: "tools/call"
NOTIFICATION_CANCELLED :: "notifications/cancelled"
NOTIFICATION_PROGRESS :: "notifications/progress"
NOTIFICATION_MESSAGE :: "notifications/message"
NOTIFICATION_TOOLS_CHANGED :: "notifications/tools/list_changed"

// The reserved `_meta` keys this client reads or writes.
META_PROTOCOL_VERSION :: "io.modelcontextprotocol/protocolVersion"
META_CLIENT_INFO :: "io.modelcontextprotocol/clientInfo"
META_CLIENT_CAPABILITIES :: "io.modelcontextprotocol/clientCapabilities"
META_SERVER_INFO :: "io.modelcontextprotocol/serverInfo"

// Result discriminators. Every result carries one, which is how a completed
// result is told from one asking for more input.
RESULT_TYPE_COMPLETE :: "complete"
RESULT_TYPE_INPUT_REQUIRED :: "input_required"

// Protocol-defined JSON-RPC error codes. Codes outside this set are the peer's
// own and are reported as they arrived.
ERROR_CODE_PARSE :: -32700
ERROR_CODE_INVALID_REQUEST :: -32600
ERROR_CODE_METHOD_NOT_FOUND :: -32601
ERROR_CODE_INVALID_PARAMS :: -32602
ERROR_CODE_INTERNAL :: -32603
ERROR_CODE_HEADER_MISMATCH :: -32020
ERROR_CODE_MISSING_CLIENT_CAPABILITY :: -32021
ERROR_CODE_UNSUPPORTED_PROTOCOL_VERSION :: -32022

// MAX_MESSAGE_BYTES bounds one JSON-RPC message. It is the first check applied
// to anything a server sends, so a server cannot make the harness allocate in
// proportion to its own output.
MAX_MESSAGE_BYTES :: 4 * 1024 * 1024

// MAX_MESSAGE_DEPTH bounds nesting in a received message. It is checked before
// parsing, because the parser recurses once per level.
MAX_MESSAGE_DEPTH :: 64

// MAX_ERROR_MESSAGE_BYTES and MAX_ERROR_DATA_BYTES bound what a remote error may
// contribute to a diagnostic. A server's message is text this harness repeats, so
// it is cut to size rather than trusted.
MAX_ERROR_MESSAGE_BYTES :: 4096
MAX_ERROR_DATA_BYTES :: 16 * 1024

// MAX_STDERR_TAIL_BYTES bounds the excerpt of a stdio server's standard error
// that is kept for diagnostics.
MAX_STDERR_TAIL_BYTES :: 32 * 1024

// MAX_IDENTITY_BYTES bounds a name or version reported by a server. Identity is
// text the harness repeats, so it is cut to size rather than trusted.
MAX_IDENTITY_BYTES :: 256

// request_params_make starts a params object with the per-request protocol metadata
// already in place, so a method encoder adds its own fields and cannot forget the
// envelope. The result is passed to request_encode, which consumes it.
request_params_make :: proc(capacity := 0, allocator := context.allocator) -> json.Object {
	params := make(json.Object, capacity + 1, allocator)
	params[strings.clone("_meta", allocator)] = json.Value(protocol_meta_make(allocator))
	return params
}

// protocol_meta_make builds the `_meta` object every request carries. The client
// declares no capabilities, because it implements no sampling, elicitation,
// roots, or subscription support: declaring one would invite a server to require
// it, and a server must not rely on a capability the client did not declare.
@(private)
protocol_meta_make :: proc(allocator: mem.Allocator) -> json.Object {
	capabilities := make(json.Object, 0, allocator)
	info := make(json.Object, 2, allocator)
	info[strings.clone("name", allocator)] = json.String(strings.clone(CLIENT_NAME, allocator))
	info[strings.clone("version", allocator)] = json.String(strings.clone(CLIENT_VERSION, allocator))

	meta := make(json.Object, 3, allocator)
	meta[strings.clone(META_PROTOCOL_VERSION, allocator)] = json.String(strings.clone(PROTOCOL_VERSION, allocator))
	meta[strings.clone(META_CLIENT_CAPABILITIES, allocator)] = json.Value(capabilities)
	meta[strings.clone(META_CLIENT_INFO, allocator)] = json.Value(info)
	return meta
}

// request_encode frames one JSON-RPC request. It takes ownership of params, including
// on failure, so a caller cannot leak a partially built envelope.
request_encode :: proc(method: string, params: json.Object, id: i64, allocator := context.allocator) -> (string, Error) {
	envelope := make(json.Object, 4, allocator)
	envelope[strings.clone("jsonrpc", allocator)] = json.String(strings.clone("2.0", allocator))
	envelope[strings.clone("id", allocator)] = json.Integer(id)
	envelope[strings.clone("method", allocator)] = json.String(strings.clone(method, allocator))
	envelope[strings.clone("params", allocator)] = json.Value(params)

	value := json.Value(envelope)
	defer json.destroy_value(value, allocator)
	return mcp_frame(value, allocator)
}

// notification_encode frames one JSON-RPC notification. It takes ownership of
// params and has no id, which is what makes it a notification rather than a
// request.
notification_encode :: proc(method: string, params: json.Object, allocator := context.allocator) -> (string, Error) {
	envelope := make(json.Object, 3, allocator)
	envelope[strings.clone("jsonrpc", allocator)] = json.String(strings.clone("2.0", allocator))
	envelope[strings.clone("method", allocator)] = json.String(strings.clone(method, allocator))
	envelope[strings.clone("params", allocator)] = json.Value(params)

	value := json.Value(envelope)
	defer json.destroy_value(value, allocator)
	return mcp_frame(value, allocator)
}

// mcp_frame serializes one message. Keys are sorted so the same request always
// encodes to the same bytes, which makes a forwarded body reproducible and keeps
// map iteration order out of the wire format.
@(private)
mcp_frame :: proc(value: json.Value, allocator: mem.Allocator) -> (string, Error) {
	encoded, unparse_err := json.unparse(value, {spec = .JSON, sort_maps_by_key = true}, allocator)
	if unparse_err != nil { return "", error_make(.Out_Of_Memory, allocator = allocator) }
	// JSON escapes a newline inside a string, so an encoded newline cannot occur
	// in valid output; it is checked anyway because the stdio framing makes it
	// fatal rather than cosmetic.
	if strings.contains_rune(encoded, '\n') {
		delete(encoded, allocator)
		return "", error_make(.Malformed_Message, "the encoded message contained a newline", allocator = allocator)
	}
	if len(encoded) > MAX_MESSAGE_BYTES {
		delete(encoded, allocator)
		return "", error_make(.Message_Too_Large, allocator = allocator)
	}
	return encoded, {}
}

// --- received messages -------------------------------------------------------

// Message_Kind is the JSON-RPC shape a received message has.
Message_Kind :: enum {
	// Result answers a request this client sent.
	Result,
	// Error answers a request this client sent with a JSON-RPC error object.
	Error,
	// Notification is a one-way message, which must carry no id.
	Notification,
	// Request is a server-initiated request. A server must not send one in this
	// revision: server-to-client interaction travels inside an input-required
	// result. It is decoded so the client can say what arrived instead of calling
	// it unparseable.
	Request,
}

// Remote_Error is a JSON-RPC error object from the server. Its strings are owned.
Remote_Error :: struct {
	code:         i64,
	message:      string,
	data_json:    string,
	data_present: bool,
}

// Message is one decoded JSON-RPC message. The fields that apply are the ones its
// kind names; result and params are owned values and everything else is an owned
// string, all released by message_destroy.
Message :: struct {
	kind:         Message_Kind,
	id:           i64,
	id_present:   bool,
	result:       json.Value,
	remote_error: Remote_Error,
	method:       string,
	params:       json.Value,
}

message_destroy :: proc(message: ^Message, allocator := context.allocator) {
	json.destroy_value(message.result, allocator)
	json.destroy_value(message.params, allocator)
	delete(message.method, allocator)
	delete(message.remote_error.message, allocator)
	delete(message.remote_error.data_json, allocator)
	message^ = {}
}

// message_decode reads one JSON-RPC message from a line the server sent.
//
// A response must carry an integer id, because that is the only id this client ever
// sends and an unmatchable reply cannot be acted on. An error whose id is null is
// accepted, because the specification allows it when the server could not read the
// request's id at all.
message_decode :: proc(line: string, allocator := context.allocator) -> (message: Message, err: Error) {
	switch problem := document_admit(line, MAX_MESSAGE_BYTES, MAX_MESSAGE_DEPTH, true, allocator); problem {
	case .None:
	case .Too_Large:
		return {}, error_make(.Message_Too_Large, allocator = allocator)
	case .Too_Deep:
		return {}, error_make(.Malformed_Message, "it nests more than 64 levels deep", allocator = allocator)
	case .Duplicate_Key:
		return {}, error_make(.Malformed_Message, "it repeats a field name", allocator = allocator)
	case .Not_Object, .Syntax:
		return {}, error_make(.Malformed_Message, allocator = allocator)
	}

	root, parse_err := json.parse_string(line, .JSON, true, allocator)
	if parse_err != nil { return {}, error_make(.Malformed_Message, allocator = allocator) }
	object, is_object := root.(json.Object)
	if !is_object {
		json.destroy_value(root, allocator)
		return {}, error_make(.Malformed_Message, allocator = allocator)
	}
	// From here root is owned, and every exit path releases whatever it did not
	// move out. A moved value is cleared in the container so the release at the
	// end cannot free it twice.
	result_value, has_result := object["result"]
	error_value, has_error := object["error"]
	id_value, has_id := object["id"]
	method_value, has_method := object["method"]

	version_value, version_present := object["jsonrpc"]
	version, version_is_string := version_value.(json.String)
	if !version_present || !version_is_string || string(version) != "2.0" {
		json.destroy_value(root, allocator)
		return {}, error_make(.Malformed_Message, `it does not declare "jsonrpc": "2.0"`, allocator = allocator)
	}

	id, id_state := message_read_id(id_value, has_id)

	switch {
	case has_result && has_error:
		json.destroy_value(root, allocator)
		return {}, error_make(.Malformed_Message, "it carries both a result and an error", allocator = allocator)

	case has_result:
		if id_state != .Present {
			json.destroy_value(root, allocator)
			return {}, error_make(.Malformed_Message, "its result has no usable request id", allocator = allocator)
		}
		if _, result_is_object := result_value.(json.Object); !result_is_object {
			json.destroy_value(root, allocator)
			return {}, error_make(.Malformed_Message, "its result is not an object", allocator = allocator)
		}
		message.kind = .Result
		message.id = id
		message.id_present = true
		message.result = result_value
		object["result"] = nil

	case has_error:
		if id_state == .Invalid {
			json.destroy_value(root, allocator)
			return {}, error_make(.Malformed_Message, "its error carries an id this client never sends", allocator = allocator)
		}
		remote, remote_err := message_read_remote_error(error_value, allocator)
		if remote_err.kind != .None {
			json.destroy_value(root, allocator)
			return {}, remote_err
		}
		message.kind = .Error
		message.id = id
		message.id_present = id_state == .Present
		message.remote_error = remote

	case has_method:
		method_name, method_is_string := method_value.(json.String)
		if !method_is_string {
			json.destroy_value(root, allocator)
			return {}, error_make(.Malformed_Message, "its method is not a string", allocator = allocator)
		}
		if id_state == .Invalid {
			json.destroy_value(root, allocator)
			return {}, error_make(.Malformed_Message, "its request carries an id this client never sends", allocator = allocator)
		}
		// A notification must carry no id at all: an id would make it a request,
		// which this client would then owe a reply it is forbidden to send.
		if id_state != .Present {
			message.kind = .Notification
		} else {
			message.kind = .Request
			message.id = id
			message.id_present = true
		}
		message.method = strings.clone(string(method_name), allocator)
		if params, present := object["params"]; present {
			if _, params_is_null := params.(json.Null); !params_is_null {
				if _, params_is_object := params.(json.Object); !params_is_object {
					message_destroy(&message, allocator)
					json.destroy_value(root, allocator)
					return {}, error_make(.Malformed_Message, "its params are not an object", allocator = allocator)
				}
				message.params = params
				object["params"] = nil
			}
		}

	case:
		json.destroy_value(root, allocator)
		return {}, error_make(.Malformed_Message, "it is neither a request, a reply, nor a notification", allocator = allocator)
	}

	json.destroy_value(root, allocator)
	return message, {}
}

// Id_State says what a message's id field turned out to be. Invalid is separate
// from Absent because a reply carrying an id this client never sends cannot be
// matched to anything, which is a different problem from a reply that carries no
// id at all.
@(private)
Id_State :: enum {
	Absent,
	Present,
	Invalid,
}

@(private)
message_read_id :: proc(value: json.Value, present: bool) -> (id: i64, state: Id_State) {
	if !present { return 0, .Absent }
	#partial switch v in value {
	case json.Integer:
		return i64(v), .Present
	case json.Null:
		return 0, .Absent
	}
	return 0, .Invalid
}

@(private)
message_read_remote_error :: proc(value: json.Value, allocator: mem.Allocator) -> (Remote_Error, Error) {
	object, is_object := value.(json.Object)
	if !is_object { return {}, error_make(.Malformed_Message, "its error is not an object", allocator = allocator) }

	code_value, has_code := object["code"]
	code, code_is_integer := code_value.(json.Integer)
	if !has_code || !code_is_integer { return {}, error_make(.Malformed_Message, "its error carries no integer code", allocator = allocator) }

	text_value, has_text := object["message"]
	text, text_is_string := text_value.(json.String)
	if !has_text || !text_is_string { return {}, error_make(.Malformed_Message, "its error carries no message", allocator = allocator) }

	remote := Remote_Error {
		code    = i64(code),
		message = mcp_clone_bounded(string(text), MAX_ERROR_MESSAGE_BYTES, allocator),
	}
	if data, present := object["data"]; present {
		encoded, unparse_err := json.unparse(data, {spec = .JSON, sort_maps_by_key = true}, allocator)
		if unparse_err != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
		// Data is diagnostic only. One that does not fit the bound is dropped
		// rather than truncated into something that is not the value the server
		// sent, because a half-rendered diagnostic is worse than none.
		if len(encoded) > MAX_ERROR_DATA_BYTES {
			delete(encoded, allocator)
		} else {
			remote.data_json = encoded
			remote.data_present = true
		}
	}
	return remote, {}
}

// result_type reads the discriminator every result carries. It is read before any
// other field, because which fields exist depends on it.
result_type :: proc(object: json.Object) -> (string, bool) {
	value, present := object["resultType"]
	if !present { return "", false }
	text, is_string := value.(json.String)
	if !is_string { return "", false }
	return string(text), true
}

// meta_server_info reads the server identity a result may carry under
// `_meta["io.modelcontextprotocol/serverInfo"]`. Identity is advisory: it is
// reported, never acted on.
meta_server_info :: proc(result: json.Object, allocator := context.allocator) -> (name: string, version: string) {
	meta_value, meta_present := result["_meta"]
	if !meta_present { return "", "" }
	meta, meta_is_object := meta_value.(json.Object)
	if !meta_is_object { return "", "" }

	info_value, info_present := meta[META_SERVER_INFO]
	if !info_present { return "", "" }
	info, info_is_object := info_value.(json.Object)
	if !info_is_object { return "", "" }

	return meta_identity_field(info, "name", allocator), meta_identity_field(info, "version", allocator)
}

// meta_identity_field reads one optional string from a server identity object. A
// field that is present but not a string is ignored rather than refused: identity
// is advisory, and a server that reports it badly is still a usable server.
@(private)
meta_identity_field :: proc(info: json.Object, field: string, allocator: mem.Allocator) -> string {
	value, present := info[field]
	if !present { return "" }
	text, is_string := value.(json.String)
	if !is_string { return "" }
	return mcp_clone_bounded(string(text), MAX_IDENTITY_BYTES, allocator)
}

// mcp_clone_bounded clones at most limit bytes of text, cut back to a rune
// boundary so a bounded copy is still valid UTF-8. Nothing this package reports
// may be text a server chose the size of.
mcp_clone_bounded :: proc(text: string, limit: int, allocator: mem.Allocator) -> string {
	if len(text) <= limit { return strings.clone(text, allocator) }
	cut := text[:limit]
	for len(cut) > 0 {
		_, width := utf8.decode_last_rune_in_string(cut)
		if width > 0 { break }
		cut = cut[:len(cut) - 1]
	}
	return strings.clone(cut, allocator)
}
