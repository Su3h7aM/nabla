#+test
package mcp

import "core:encoding/json"
import "core:strings"
import "core:testing"

// wire_object reads an encoded message the way a peer would, so a test asserts
// bytes rather than a struct it built itself.
@(private)
wire_object :: proc(t: ^testing.T, line: string) -> json.Object {
	value, parse_err := json.parse_string(line, .JSON, true, context.allocator)
	if !testing.expectf(t, parse_err == nil, "the encoded message should parse: %v", parse_err) { return nil }
	object, is_object := value.(json.Object)
	if !testing.expect(t, is_object, "the encoded message should be an object") {
		json.destroy_value(value, context.allocator)
		return nil
	}
	return object
}

@(private)
wire_string :: proc(t: ^testing.T, object: json.Object, key: string) -> string {
	value, present := object[key]
	if !testing.expectf(t, present, "field %q should be present", key) { return "" }
	text, is_string := value.(json.String)
	if !testing.expectf(t, is_string, "field %q should be a string", key) { return "" }
	return string(text)
}

@(private)
wire_object_field :: proc(t: ^testing.T, object: json.Object, key: string) -> json.Object {
	value, present := object[key]
	if !testing.expectf(t, present, "field %q should be present", key) { return nil }
	nested, is_object := value.(json.Object)
	if !testing.expectf(t, is_object, "field %q should be an object", key) { return nil }
	return nested
}

// --- framing -----------------------------------------------------------------

@(test)
test_request_carries_the_per_request_metadata :: proc(t: ^testing.T) {
	params := request_params_make(.V2026_07_28, 1, context.allocator)
	params[strings.clone("cursor", context.allocator)] = json.String(strings.clone("page-2", context.allocator))
	line, err := request_encode(METHOD_TOOLS_LIST, params, 7, context.allocator)
	defer error_destroy(&err, context.allocator)
	defer delete(line, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	root := wire_object(t, line)
	if root == nil { return }
	defer json.destroy_value(json.Value(root), context.allocator)
	testing.expect_value(t, wire_string(t, root, "jsonrpc"), "2.0")
	testing.expect_value(t, wire_string(t, root, "method"), METHOD_TOOLS_LIST)

	params_object := wire_object_field(t, root, "params")
	if params_object == nil { return }
	testing.expect_value(t, wire_string(t, params_object, "cursor"), "page-2")
	meta := wire_object_field(t, params_object, "_meta")
	if meta == nil { return }
	testing.expect_value(t, wire_string(t, meta, META_PROTOCOL_VERSION), VERSION_2026_07_28)
	// An empty capabilities object is the declaration: the client implements no
	// sampling, elicitation, roots, or subscriptions.
	capabilities := wire_object_field(t, meta, META_CLIENT_CAPABILITIES)
	testing.expect_value(t, len(capabilities), 0)
	info := wire_object_field(t, meta, META_CLIENT_INFO)
	if info == nil { return }
	testing.expect_value(t, wire_string(t, info, "name"), CLIENT_NAME)
}

// The same request encodes to the same bytes, so a forwarded body is reproducible
// and map iteration order never reaches the wire.
@(test)
test_encoding_is_deterministic_and_a_notification_has_no_id :: proc(t: ^testing.T) {
	encode := proc() -> string {
		params := request_params_make(.V2026_07_28, 1, context.allocator)
		params[strings.clone("name", context.allocator)] = json.String(strings.clone("do_thing", context.allocator))
		line, _ := request_encode(METHOD_TOOLS_CALL, params, 11, context.allocator)
		return line
	}
	first := encode()
	defer delete(first, context.allocator)
	second := encode()
	defer delete(second, context.allocator)
	testing.expect_value(t, first, second)

	cancel := make(json.Object, 1, context.allocator)
	cancel[strings.clone("requestId", context.allocator)] = json.Integer(4)
	notification, notification_err := notification_encode(NOTIFICATION_CANCELLED, cancel, context.allocator)
	defer error_destroy(&notification_err, context.allocator)
	defer delete(notification, context.allocator)
	root := wire_object(t, notification)
	if root == nil { return }
	defer json.destroy_value(json.Value(root), context.allocator)
	_, has_id := root["id"]
	testing.expect(t, !has_id, "a notification must carry no id")
}

// --- received messages -------------------------------------------------------

@(test)
test_message_decode_reads_every_shape :: proc(t: ^testing.T) {
	result_line := `{"jsonrpc":"2.0","id":3,"result":{"resultType":"complete"}}`
	message, err := message_decode(result_line, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect_value(t, message.kind, Message_Kind.Result)
	testing.expect_value(t, message.id, i64(3))
	if object, is_object := message.result.(json.Object); testing.expect(t, is_object) {
		kind, present := result_type(object)
		testing.expect(t, present, "every result carries a resultType")
		testing.expect_value(t, kind, RESULT_TYPE_COMPLETE)
	}
	message_destroy(&message, context.allocator)
	error_destroy(&err, context.allocator)

	// A server that could not read the request's id may report a null one.
	error_line := `{"jsonrpc":"2.0","id":null,"error":{"code":-32602,"message":"bad params","data":{"field":"x"}}}`
	message, err = message_decode(error_line, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect_value(t, message.kind, Message_Kind.Error)
	testing.expect(t, !message.id_present)
	testing.expect_value(t, message.remote_error.code, i64(ERROR_CODE_INVALID_PARAMS))
	testing.expect_value(t, message.remote_error.message, "bad params")
	testing.expect(t, message.remote_error.data_present)
	message_destroy(&message, context.allocator)
	error_destroy(&err, context.allocator)

	notification_line := `{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":0.5}}`
	message, err = message_decode(notification_line, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect_value(t, message.kind, Message_Kind.Notification)
	testing.expect(t, !message.id_present)
	message_destroy(&message, context.allocator)
	error_destroy(&err, context.allocator)

	// A server must not send a request in this revision. It is decoded as one so
	// the client can report what arrived rather than calling it unparseable.
	request_line := `{"jsonrpc":"2.0","id":9,"method":"elicitation/create","params":{}}`
	message, err = message_decode(request_line, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect_value(t, message.kind, Message_Kind.Request)
	testing.expect_value(t, message.method, "elicitation/create")
	message_destroy(&message, context.allocator)
	error_destroy(&err, context.allocator)
}

@(test)
test_message_decode_refuses_malformed_input :: proc(t: ^testing.T) {
	cases := []string {
		``,
		`[]`,
		`{"jsonrpc":"2.0"}`,
		`{"jsonrpc":"1.0","id":1,"result":{}}`,
		`{"jsonrpc":"2.0","id":"abc","result":{}}`,
		`{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":1,"message":"x"}}`,
		`{"jsonrpc":"2.0","id":1,"method":"tools/list","params":[]}`,
		`{"jsonrpc":"2.0","id":1,"id":2,"result":{}}`,
		`{"jsonrpc":"2.0","id":1,"result":{}} trailing`,
	}
	for line in cases {
		message, err := message_decode(line, context.allocator)
		testing.expectf(t, err.kind == .Malformed_Message, "%q should be refused, got %v", line, err.kind)
		testing.expectf(t, err.delivery == .Not_Delivered, "%q should not claim delivery", line)
		message_destroy(&message, context.allocator)
		error_destroy(&err, context.allocator)
	}
}

// Size and nesting are refused before the parser runs, because the parser
// recurses once per level and would reach the stack first.
@(test)
test_message_decode_bounds_size_and_nesting :: proc(t: ^testing.T) {
	padding := strings.repeat("x", MAX_MESSAGE_BYTES, context.allocator)
	defer delete(padding, context.allocator)
	oversized := strings.concatenate({`{"jsonrpc":"2.0","id":1,"result":{"a":"`, padding, `"}}`}, context.allocator)
	defer delete(oversized, context.allocator)
	message, err := message_decode(oversized, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.Message_Too_Large)
	message_destroy(&message, context.allocator)
	error_destroy(&err, context.allocator)

	builder := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `{"jsonrpc":"2.0","id":1,"result":`)
	for _ in 0 ..< MAX_MESSAGE_DEPTH + 4 { strings.write_string(&builder, `{"a":`) }
	strings.write_string(&builder, `1`)
	for _ in 0 ..< MAX_MESSAGE_DEPTH + 4 { strings.write_string(&builder, `}`) }
	strings.write_string(&builder, `}`)

	message, err = message_decode(strings.to_string(builder), context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.Malformed_Message)
	testing.expect(t, strings.contains(err.message, "nest"), "the diagnostic should name the nesting bound")
	message_destroy(&message, context.allocator)
	error_destroy(&err, context.allocator)
}

// A remote message is text this harness repeats, so it is bounded and cut back to
// a rune boundary. Oversized error data is dropped, not truncated into a value the
// server never sent.
@(test)
test_remote_error_text_is_bounded :: proc(t: ^testing.T) {
	padding := strings.repeat("é", MAX_ERROR_MESSAGE_BYTES, context.allocator)
	defer delete(padding, context.allocator)
	data := strings.repeat("y", MAX_ERROR_DATA_BYTES + 1, context.allocator)
	defer delete(data, context.allocator)
	line := strings.concatenate({`{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"`, padding, `","data":"`, data, `"}}`}, context.allocator)
	defer delete(line, context.allocator)

	message, err := message_decode(line, context.allocator)
	defer message_destroy(&message, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }
	testing.expect(t, len(message.remote_error.message) <= MAX_ERROR_MESSAGE_BYTES, "the message should be bounded")
	testing.expect(t, len(message.remote_error.message) > 0, "the message should still say something")
	testing.expect(t, !message.remote_error.data_present, "oversized data should be dropped")
}

@(test)
test_zero_values_destroy_cleanly :: proc(t: ^testing.T) {
	err: Error
	error_destroy(&err, context.allocator)
	message: Message
	message_destroy(&message, context.allocator)
	testing.expect(t, message.result == nil && message.params == nil)

	// Every kind renders as a sentence, so a caller never shows an empty reason.
	for kind in Error_Kind {
		if kind == .None { continue }
		local := error_make(kind, allocator = context.allocator)
		text := error_text(local, context.allocator)
		testing.expectf(t, text != "", "%v should say what happened", kind)
		delete(text, context.allocator)
		error_destroy(&local, context.allocator)
	}
}
