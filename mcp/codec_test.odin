#+test
package mcp

import "core:encoding/json"
import "core:strings"
import "core:testing"

// --- helpers -----------------------------------------------------------------

@(private)
codec_object :: proc(t: ^testing.T, object: json.Object, key: string) -> json.Object {
	value, present := object[key]
	if !testing.expectf(t, present, "field %q should be present", key) { return nil }
	nested, is_object := value.(json.Object)
	if !testing.expectf(t, is_object, "field %q should be an object", key) { return nil }
	return nested
}

@(private)
codec_string :: proc(t: ^testing.T, object: json.Object, key: string) -> string {
	value, present := object[key]
	if !testing.expectf(t, present, "field %q should be present", key) { return "" }
	text, is_string := value.(json.String)
	if !testing.expectf(t, is_string, "field %q should be a string", key) { return "" }
	return string(text)
}

@(private)
codec_integer :: proc(t: ^testing.T, object: json.Object, key: string) -> i64 {
	value, present := object[key]
	if !testing.expectf(t, present, "field %q should be present", key) { return 0 }
	number, is_integer := value.(json.Integer)
	if !testing.expectf(t, is_integer, "field %q should be an integer", key) { return 0 }
	return i64(number)
}

// codec_parse reads an encoded message the way a peer would, so a test asserts
// the wire bytes rather than a struct it built itself.
@(private)
codec_parse :: proc(t: ^testing.T, line: string) -> json.Object {
	value, parse_err := json.parse_string(line, .JSON, true, context.allocator)
	if !testing.expectf(t, parse_err == nil, "the encoded message should parse: %v", parse_err) { return nil }
	object, is_object := value.(json.Object)
	if !testing.expect(t, is_object, "the encoded message should be an object") {
		json.destroy_value(value, context.allocator)
		return nil
	}
	return object
}

// --- requests ----------------------------------------------------------------

@(test)
test_request_carries_protocol_metadata :: proc(t: ^testing.T) {
	params := request_params_make(1, context.allocator)
	params[strings.clone("cursor", context.allocator)] = json.String(strings.clone("page-2", context.allocator))
	line, err := request_encode(METHOD_TOOLS_LIST, params, 7, context.allocator)
	defer error_destroy(&err, context.allocator)
	defer delete(line, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	root := codec_parse(t, line)
	if root == nil { return }
	defer json.destroy_value(json.Value(root), context.allocator)

	testing.expect_value(t, codec_string(t, root, "jsonrpc"), "2.0")
	testing.expect_value(t, codec_string(t, root, "method"), METHOD_TOOLS_LIST)
	testing.expect_value(t, codec_integer(t, root, "id"), i64(7))

	params_object := codec_object(t, root, "params")
	if params_object == nil { return }
	testing.expect_value(t, codec_string(t, params_object, "cursor"), "page-2")

	meta := codec_object(t, params_object, "_meta")
	if meta == nil { return }
	testing.expect_value(t, codec_string(t, meta, META_PROTOCOL_VERSION), PROTOCOL_VERSION)

	// The client declares no capabilities. An empty object is the declaration:
	// absent would be a different statement, and declaring one it does not
	// implement would invite a server to require it.
	capabilities, capabilities_present := meta[META_CLIENT_CAPABILITIES]
	if !testing.expect(t, capabilities_present, "clientCapabilities is required on every request") { return }
	capability_object, is_object := capabilities.(json.Object)
	if !testing.expect(t, is_object, "clientCapabilities should be an object") { return }
	testing.expect_value(t, len(capability_object), 0)

	info := codec_object(t, meta, META_CLIENT_INFO)
	if info == nil { return }
	testing.expect_value(t, codec_string(t, info, "name"), CLIENT_NAME)
	testing.expect_value(t, codec_string(t, info, "version"), CLIENT_VERSION)
}

// A request with no method-specific fields still carries the metadata, which is
// the shape server/discover uses.
@(test)
test_request_metadata_is_the_whole_params_for_discovery :: proc(t: ^testing.T) {
	line, err := request_encode(METHOD_DISCOVER, request_params_make(0, context.allocator), 1, context.allocator)
	defer error_destroy(&err, context.allocator)
	defer delete(line, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	root := codec_parse(t, line)
	if root == nil { return }
	defer json.destroy_value(json.Value(root), context.allocator)

	params_object := codec_object(t, root, "params")
	if params_object == nil { return }
	testing.expect_value(t, len(params_object), 1)
	meta := codec_object(t, params_object, "_meta")
	if meta == nil { return }
	testing.expect_value(t, codec_string(t, meta, META_PROTOCOL_VERSION), PROTOCOL_VERSION)
}

@(test)
test_notification_carries_no_id :: proc(t: ^testing.T) {
	params := make(json.Object, 1, context.allocator)
	params[strings.clone("requestId", context.allocator)] = json.Integer(4)
	line, err := notification_encode(NOTIFICATION_CANCELLED, params, context.allocator)
	defer error_destroy(&err, context.allocator)
	defer delete(line, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	root := codec_parse(t, line)
	if root == nil { return }
	defer json.destroy_value(json.Value(root), context.allocator)

	testing.expect_value(t, codec_string(t, root, "jsonrpc"), "2.0")
	testing.expect_value(t, codec_string(t, root, "method"), NOTIFICATION_CANCELLED)
	_, has_id := root["id"]
	testing.expect(t, !has_id, "a notification must carry no id")
}

// The same request encodes to the same bytes every time, so a forwarded body is
// reproducible and map iteration order never reaches the wire.
@(test)
test_request_encoding_is_deterministic :: proc(t: ^testing.T) {
	encode := proc() -> string {
		params := request_params_make(2, context.allocator)
		params[strings.clone("name", context.allocator)] = json.String(strings.clone("do_thing", context.allocator))
		params[strings.clone("arguments", context.allocator)] = json.Value(json.Object{})
		line, _ := request_encode(METHOD_TOOLS_CALL, params, 11, context.allocator)
		return line
	}
	first := encode()
	defer delete(first, context.allocator)
	second := encode()
	defer delete(second, context.allocator)
	testing.expect_value(t, first, second)
}

// --- replies -----------------------------------------------------------------

@(test)
test_message_decode_reads_a_result :: proc(t: ^testing.T) {
	line := `{"jsonrpc":"2.0","id":3,"result":{"resultType":"complete","isError":false}}`
	message, err := message_decode(line, context.allocator)
	defer message_destroy(&message, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	testing.expect_value(t, message.kind, Message_Kind.Result)
	testing.expect_value(t, message.id, i64(3))
	testing.expect(t, message.id_present)

	object, is_object := message.result.(json.Object)
	if !testing.expect(t, is_object, "the result should be an object") { return }
	kind, present := result_type(object)
	testing.expect(t, present, "every result carries a resultType")
	testing.expect_value(t, kind, RESULT_TYPE_COMPLETE)
}

@(test)
test_message_decode_reads_an_error_with_its_code_and_data :: proc(t: ^testing.T) {
	line := `{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"bad params","data":{"field":"x"}}}`
	message, err := message_decode(line, context.allocator)
	defer message_destroy(&message, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	testing.expect_value(t, message.kind, Message_Kind.Error)
	testing.expect_value(t, message.id, i64(4))
	testing.expect_value(t, message.remote_error.code, i64(ERROR_CODE_INVALID_PARAMS))
	testing.expect_value(t, message.remote_error.message, "bad params")
	testing.expect(t, message.remote_error.data_present)
	testing.expect(t, strings.contains(message.remote_error.data_json, `"field"`), "the data is kept for diagnostics")
}

// A server that could not read the request's id may report a null id. That is an
// error reply the harness can still act on, so it is not a framing failure.
@(test)
test_message_decode_accepts_an_error_with_a_null_id :: proc(t: ^testing.T) {
	line := `{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}`
	message, err := message_decode(line, context.allocator)
	defer message_destroy(&message, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }
	testing.expect_value(t, message.kind, Message_Kind.Error)
	testing.expect(t, !message.id_present)
	testing.expect_value(t, message.remote_error.code, i64(ERROR_CODE_PARSE))
}

@(test)
test_message_decode_reads_a_notification :: proc(t: ^testing.T) {
	line := `{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":1,"progress":0.5}}`
	message, err := message_decode(line, context.allocator)
	defer message_destroy(&message, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	testing.expect_value(t, message.kind, Message_Kind.Notification)
	testing.expect(t, !message.id_present)
	testing.expect_value(t, message.method, NOTIFICATION_PROGRESS)
	_, is_object := message.params.(json.Object)
	testing.expect(t, is_object, "the notification params should be an object")
}

// A server must not send a request in this revision. It is decoded as one
// anyway, so the client can report what arrived instead of calling it
// unparseable.
@(test)
test_message_decode_names_a_server_request :: proc(t: ^testing.T) {
	line := `{"jsonrpc":"2.0","id":9,"method":"elicitation/create","params":{"message":"hi"}}`
	message, err := message_decode(line, context.allocator)
	defer message_destroy(&message, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }
	testing.expect_value(t, message.kind, Message_Kind.Request)
	testing.expect_value(t, message.id, i64(9))
	testing.expect_value(t, message.method, "elicitation/create")
}

@(test)
test_message_decode_refuses_malformed_input :: proc(t: ^testing.T) {
	cases := []string {
		``,
		`[]`,
		`not json`,
		`{"jsonrpc":"2.0"}`,
		`{"jsonrpc":"2.0","id":1}`,
		`{"id":1,"result":{}}`,
		`{"jsonrpc":"1.0","id":1,"result":{}}`,
		`{"jsonrpc":"2.0","id":1,"result":[]}`,
		`{"jsonrpc":"2.0","id":1,"error":{"message":"x"}}`,
		`{"jsonrpc":"2.0","id":1,"error":{"code":1}}`,
		`{"jsonrpc":"2.0","id":"abc","result":{}}`,
		`{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":1,"message":"x"}}`,
		`{"jsonrpc":"2.0","id":1,"method":"tools/list","params":[]}`,
		`{"jsonrpc":"2.0","id":1,"id":2,"result":{}}`,
		`{"jsonrpc":"2.0","id":1,"result":{}} trailing`,
		`{"jsonrpc":"2.0","id":1,"result":{"resultType":}}`,
	}
	for line in cases {
		message, err := message_decode(line, context.allocator)
		testing.expectf(t, err.kind == .Malformed_Message, "%q should be refused, got %v", line, err.kind)
		testing.expectf(t, err.delivery == .Not_Delivered, "%q should not claim delivery", line)
		message_destroy(&message, context.allocator)
		error_destroy(&err, context.allocator)
	}
}

@(test)
test_message_decode_refuses_a_message_over_the_size_bound :: proc(t: ^testing.T) {
	padding := strings.repeat("x", MAX_MESSAGE_BYTES, context.allocator)
	defer delete(padding, context.allocator)
	line := strings.concatenate({`{"jsonrpc":"2.0","id":1,"result":{"a":"`, padding, `"}}`}, context.allocator)
	defer delete(line, context.allocator)

	message, err := message_decode(line, context.allocator)
	defer message_destroy(&message, context.allocator)
	defer error_destroy(&err, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.Message_Too_Large)
}

@(test)
test_message_decode_refuses_excessive_nesting :: proc(t: ^testing.T) {
	builder := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `{"jsonrpc":"2.0","id":1,"result":`)
	for _ in 0 ..< MAX_MESSAGE_DEPTH + 4 { strings.write_string(&builder, `{"a":`) }
	strings.write_string(&builder, `1`)
	for _ in 0 ..< MAX_MESSAGE_DEPTH + 4 { strings.write_string(&builder, `}`) }
	strings.write_string(&builder, `}`)

	message, err := message_decode(strings.to_string(builder), context.allocator)
	defer message_destroy(&message, context.allocator)
	defer error_destroy(&err, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.Malformed_Message)
	testing.expect(t, strings.contains(err.message, "nest"), "the diagnostic should name the nesting bound")
}

// A remote message is text this harness repeats, so it is cut to size rather than
// trusted. A bounded copy is still valid UTF-8.
@(test)
test_remote_error_text_is_bounded :: proc(t: ^testing.T) {
	// A multi-byte rune straddling the bound, so a naive byte cut would leave
	// invalid UTF-8 behind.
	padding := strings.repeat("é", MAX_ERROR_MESSAGE_BYTES, context.allocator)
	defer delete(padding, context.allocator)
	line := strings.concatenate({`{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"`, padding, `"}}`}, context.allocator)
	defer delete(line, context.allocator)

	message, err := message_decode(line, context.allocator)
	defer message_destroy(&message, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }
	testing.expect(t, len(message.remote_error.message) <= MAX_ERROR_MESSAGE_BYTES, "the message should be bounded")
	testing.expect(t, len(message.remote_error.message) > 0, "the message should still say something")
}

// Oversized error data is dropped rather than truncated into a value the server
// never sent. A half-rendered diagnostic is worse than none.
@(test)
test_oversized_remote_error_data_is_dropped :: proc(t: ^testing.T) {
	padding := strings.repeat("y", MAX_ERROR_DATA_BYTES + 1, context.allocator)
	defer delete(padding, context.allocator)
	line := strings.concatenate({`{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"x","data":"`, padding, `"}}`}, context.allocator)
	defer delete(line, context.allocator)

	message, err := message_decode(line, context.allocator)
	defer message_destroy(&message, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }
	testing.expect(t, !message.remote_error.data_present, "oversized data should be dropped")
	testing.expect_value(t, message.remote_error.data_json, "")
}

@(test)
test_document_admit_reads_the_root_shape :: proc(t: ^testing.T) {
	testing.expect_value(t, document_admit(`{}`, 64, 4, true, context.temp_allocator), Document_Problem.None)
	testing.expect_value(t, document_admit(`[]`, 64, 4, true, context.temp_allocator), Document_Problem.Not_Object)
	testing.expect_value(t, document_admit(`[]`, 64, 4, false, context.temp_allocator), Document_Problem.None)
	testing.expect_value(t, document_admit(`{"a":1,"a":2}`, 64, 4, true, context.temp_allocator), Document_Problem.Duplicate_Key)
	testing.expect_value(t, document_admit(`{"a":1,}`, 64, 4, true, context.temp_allocator), Document_Problem.Syntax)
	testing.expect_value(t, document_admit(`[1,]`, 64, 4, false, context.temp_allocator), Document_Problem.Syntax)
	testing.expect_value(t, document_admit(`{"a":{"b":{"c":{"d":1}}}}`, 64, 2, true, context.temp_allocator), Document_Problem.Too_Deep)
	testing.expect_value(t, document_admit(`{"a":1}`, 4, 4, true, context.temp_allocator), Document_Problem.Too_Large)
	testing.expect_value(t, document_admit(``, 64, 4, true, context.temp_allocator), Document_Problem.Syntax)
}

@(test)
test_server_identity_is_read_from_result_meta :: proc(t: ^testing.T) {
	line := `{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"files","version":"2.1"}}}}`
	message, err := message_decode(line, context.allocator)
	defer message_destroy(&message, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	object, is_object := message.result.(json.Object)
	if !testing.expect(t, is_object) { return }
	name, version := meta_server_info(object, context.allocator)
	defer delete(name, context.allocator)
	defer delete(version, context.allocator)
	testing.expect_value(t, name, "files")
	testing.expect_value(t, version, "2.1")
}

@(test)
test_error_text_is_actionable :: proc(t: ^testing.T) {
	cases := []Error_Kind {
		.Cancelled,
		.Timed_Out,
		.Spawn_Failed,
		.Write_Failed,
		.Read_Failed,
		.End_Of_Stream,
		.Server_Exited,
		.Message_Too_Large,
		.Malformed_Message,
		.Unexpected_Message,
		.Version_Unsupported,
		.Capability_Missing,
		.Protocol_Violation,
		.Out_Of_Memory,
	}
	for kind in cases {
		err := error_make(kind, allocator = context.allocator)
		text := error_text(err, context.allocator)
		testing.expectf(t, text != "", "%v should say what happened", kind)
		delete(text, context.allocator)
		error_destroy(&err, context.allocator)
	}

	remote := Remote_Error {
		code         = -32022,
		message      = "unsupported",
		data_present = true,
		data_json    = `{"supported":["2026-07-28"]}`,
	}
	err := error_from_remote(remote, .Delivered, context.allocator)
	defer error_destroy(&err, context.allocator)
	testing.expect_value(t, err.code, i64(ERROR_CODE_UNSUPPORTED_PROTOCOL_VERSION))
	testing.expect(t, error_delivered(err), "the delivery state travels with the error")
	testing.expect(t, strings.contains(err.data_json, "2026-07-28"), "the peer's own version list is kept")
}

// Destroying a zero error is safe, so a caller that never received one does not
// have to know that.
@(test)
test_zero_error_destroys_cleanly :: proc(t: ^testing.T) {
	err: Error
	error_destroy(&err, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.None)

	message: Message
	message_destroy(&message, context.allocator)
	testing.expect_value(t, message.kind, Message_Kind.Result)
	testing.expect(t, message.result == nil)
	testing.expect(t, message.params == nil)
}
