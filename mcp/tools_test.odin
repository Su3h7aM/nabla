#+test
package mcp

import "core:encoding/json"
import "core:strings"
import "core:testing"

// One stream serves one request at a time. A call made while another owns it is refused
// before anything is written, so the caller knows the server never saw it.
@(test)
test_a_call_while_another_is_in_flight_is_refused_unsent :: proc(t: ^testing.T) {
	client := Client {
		version   = .V2026_07_28,
		allocator = context.allocator,
		busy      = true,
	}
	result, err := client_tools_call(&client, "search", `{}`, {}, context.allocator)
	defer call_result_destroy(&result, context.allocator)
	defer error_destroy(&err, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.Busy)
	testing.expect(t, !error_delivered(err))
	testing.expect_value(t, client.next_id, 0)
}

@(test)
test_tools_list_reads_a_page :: proc(t: ^testing.T) {
	text := `{"resultType":"complete","nextCursor":"page-2","tools":[{
		"name": "issues.create",
		"title": "Create an issue",
		"description": "Create one issue.",
		"inputSchema": {"type":"object","properties":{"b":{"type":"string"},"a":{"type":"integer"}},"required":["a"]}
	}]}`
	owner, object := result_fixture(t, text)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	page, err := tools_list_decode(object, .V2026_07_28, context.allocator)
	defer tool_page_destroy(&page, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	if !testing.expect_value(t, len(page.tools), 1) { return }
	testing.expect_value(t, len(page.rejected), 0)
	cursor, has_cursor := page.next_cursor.(string)
	if testing.expect(t, has_cursor, "the next cursor is present") {
		testing.expect_value(t, cursor, "page-2")
	}
	testing.expect_value(t, page.tools[0].name, "issues.create")
	testing.expect_value(t, page.tools[0].title, "Create an issue")
	testing.expect_value(t, page.tools[0].description, "Create one issue.")
	// The harness advertises bytes, so a schema is canonicalized once: sorted keys
	// make the same remote schema yield the same advertised bytes every refresh.
	testing.expect_value(t, page.tools[0].input_schema, `{"properties":{"a":{"type":"integer"},"b":{"type":"string"}},"required":["a"],"type":"object"}`)
}

@(test)
test_tools_list_preserves_an_empty_cursor :: proc(t: ^testing.T) {
	owner, object := result_fixture(t, `{"resultType":"complete","nextCursor":"","tools":[]}`)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	page, err := tools_list_decode(object, .V2026_07_28, context.allocator)
	defer tool_page_destroy(&page, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	cursor, has_cursor := page.next_cursor.(string)
	if !testing.expect(t, has_cursor, "an empty cursor is still present") { return }
	testing.expect_value(t, cursor, "")

	params, params_err := tools_list_params_make(page.next_cursor, .V2026_07_28, context.allocator)
	defer json.destroy_value(json.Value(params), context.allocator)
	defer error_destroy(&params_err, context.allocator)
	if !testing.expect_value(t, params_err.kind, Error_Kind.None) { return }
	value, present := params["cursor"]
	text, is_string := value.(json.String)
	testing.expect(t, present && is_string, "the empty cursor is sent")
	if present && is_string { testing.expect_value(t, string(text), "") }
}

// One unusable definition should not cost the user the tools that were well
// formed, and the refusal should name which tool it was.
@(test)
test_tools_list_rejects_a_bad_tool_and_keeps_the_good_one :: proc(t: ^testing.T) {
	text := `{"resultType":"complete","tools":[
		{"name":"good","description":"fine","inputSchema":{"type":"object"}},
		{"name":"no_description","inputSchema":{"type":"object"}},
		{"name":"bad_annotation","description":"d","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":"yes"}}
	]}`
	owner, object := result_fixture(t, text)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	page, err := tools_list_decode(object, .V2026_07_28, context.allocator)
	defer tool_page_destroy(&page, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	testing.expect_value(t, len(page.tools), 1)
	testing.expect_value(t, page.tools[0].name, "good")
	if !testing.expect_value(t, len(page.rejected), 2) { return }
	testing.expect_value(t, page.rejected[0].name, "no_description")
	testing.expect_value(t, page.rejected[1].name, "bad_annotation")
	testing.expect(t, page.rejected[0].reason != "", "a rejection says why")
}

// An absent annotation is not a claim: reading it as "no" would invent a fact the
// server never stated.
@(test)
test_tool_annotations_map_absence_to_unknown :: proc(t: ^testing.T) {
	text := `{"resultType":"complete","tools":[
		{"name":"bare","description":"d","inputSchema":{"type":"object"}},
		{"name":"stated","description":"d","inputSchema":{"type":"object"},
		 "annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}}
	]}`
	owner, object := result_fixture(t, text)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	page, err := tools_list_decode(object, .V2026_07_28, context.allocator)
	defer tool_page_destroy(&page, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	bare := page.tools[0].annotations
	testing.expect_value(t, bare.read_only, Hint.Unknown)
	testing.expect_value(t, bare.open_world, Hint.Unknown)
	stated := page.tools[1].annotations
	testing.expect_value(t, stated.read_only, Hint.Yes)
	testing.expect_value(t, stated.destructive, Hint.No)
	testing.expect_value(t, stated.idempotent, Hint.Yes)
	testing.expect_value(t, stated.open_world, Hint.No)
}

@(test)
test_tools_list_refuses_malformed_results :: proc(t: ^testing.T) {
	cases := []string {
		`{}`,
		`{"resultType":"complete"}`,
		`{"resultType":"complete","tools":{}}`,
		// A failure after tools were kept still releases them: the page is an
		// accumulator, and a refused page must not leak what it had read.
		`{"resultType":"complete","tools":[{"name":"a","description":"d","inputSchema":{"type":"object"}}],"nextCursor":5}`,
	}
	for text in cases {
		owner, object := result_fixture(t, text)
		if owner == nil { continue }
		page, err := tools_list_decode(object, .V2026_07_28, context.allocator)
		testing.expectf(t, err.kind != .None, "%s should be refused", text)
		tool_page_destroy(&page, context.allocator)
		error_destroy(&err, context.allocator)
		json.destroy_value(owner, context.allocator)
	}
}

@(test)
test_tools_call_params_carry_the_admitted_arguments :: proc(t: ^testing.T) {
	params, err := tools_call_params_make("issues.create", `{"title":"a bug"}`, .V2026_07_28, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	line, encode_err := request_encode(METHOD_TOOLS_CALL, params, 5, context.allocator)
	defer error_destroy(&encode_err, context.allocator)
	defer delete(line, context.allocator)
	if !testing.expect_value(t, encode_err.kind, Error_Kind.None) { return }

	root := wire_object(t, line)
	if root == nil { return }
	defer json.destroy_value(json.Value(root), context.allocator)
	params_object := wire_object_field(t, root, "params")
	if params_object == nil { return }
	testing.expect_value(t, wire_string(t, params_object, "name"), "issues.create")
	testing.expect_value(t, wire_string(t, wire_object_field(t, params_object, "arguments"), "title"), "a bug")

	// Arguments that do not parse are refused rather than sent: an endpoint cannot
	// read them, and a caller would have no record of what it said.
	_, bad_err := tools_call_params_make("t", `{`, .V2026_07_28, context.allocator)
	defer error_destroy(&bad_err, context.allocator)
	testing.expect_value(t, bad_err.kind, Error_Kind.Malformed_Message)
}

// --- calling -----------------------------------------------------------------

@(test)
test_call_result_reads_completion_and_failure :: proc(t: ^testing.T) {
	owner, object := result_fixture(t, `{"resultType":"complete","content":[{"type":"text","text":"created issue 12"}],"structuredContent":{"number":12}}`)
	if owner == nil { return }
	result, err := call_result_decode(object, .V2026_07_28, context.allocator)
	if testing.expect_value(t, err.kind, Error_Kind.None) {
		testing.expect(t, !result.is_error && !result.input_required)
		if testing.expect_value(t, len(result.content), 1) {
			text, is_text := result.content[0].(Text_Content)
			testing.expect(t, is_text, "the block is text")
			testing.expect_value(t, text.text, "created issue 12")
		}
		testing.expect_value(t, result.structured_json, `{"number":12}`)
	}
	call_result_destroy(&result, context.allocator)
	error_destroy(&err, context.allocator)
	json.destroy_value(owner, context.allocator)

	owner, object = result_fixture(t, `{"resultType":"complete","isError":true,"content":[{"type":"text","text":"no such repo"}]}`)
	if owner == nil { return }
	result, err = call_result_decode(object, .V2026_07_28, context.allocator)
	if testing.expect_value(t, err.kind, Error_Kind.None) {
		testing.expect(t, result.is_error, "the failure flag is read")
	}
	call_result_destroy(&result, context.allocator)
	error_destroy(&err, context.allocator)
	json.destroy_value(owner, context.allocator)
}

// An input-required reply is a different shape, not a failure: it is read
// faithfully so the adapter can report what the server asked for.
@(test)
test_call_result_reads_an_input_required_reply :: proc(t: ^testing.T) {
	owner, object := result_fixture(t, `{"resultType":"input_required","requestState":"opaque","inputRequests":{"q1":{"method":"elicitation/create"}}}`)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	result, err := call_result_decode(object, .V2026_07_28, context.allocator)
	defer call_result_destroy(&result, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }
	testing.expect(t, result.input_required)
	testing.expect_value(t, len(result.content), 0)
	testing.expect_value(t, result.request_state, "opaque")
	testing.expect(t, strings.contains(result.input_requests, "elicitation/create"), "what was asked for is kept")
}

// Binary payloads are never retained: the block is reported by type and MIME type,
// because a base64 image would consume the model's context to no purpose.
@(test)
test_call_result_reports_content_it_does_not_show :: proc(t: ^testing.T) {
	owner, object := result_fixture(
		t,
		`{"resultType":"complete","content":[
			{"type":"image","data":"aGVsbG8=","mimeType":"image/png"},
			{"type":"resource_link","name":"log","uri":"file:///tmp/log"},
			{"type":"resource","resource":{"uri":"file:///tmp/x","mimeType":"text/plain","text":"body"}},
			{"type":"future_block","whatever":1}
		]}`,
	)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	result, err := call_result_decode(object, .V2026_07_28, context.allocator)
	defer call_result_destroy(&result, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	if !testing.expect_value(t, len(result.content), 4) { return }
	image, is_image := result.content[0].(Image_Content)
	testing.expect(t, is_image, "the block is an image")
	testing.expect_value(t, image.mime_type, "image/png")
	link, is_link := result.content[1].(Resource_Link_Content)
	testing.expect(t, is_link, "the block is a resource link")
	testing.expect_value(t, link.uri, "file:///tmp/log")
	embedded, is_embedded := result.content[2].(Embedded_Resource_Content)
	testing.expect(t, is_embedded, "the block is an embedded resource")
	testing.expect_value(t, embedded.uri, "file:///tmp/x")
	// A type this revision does not define is reported, not refused, and it is
	// named by what the server called it.
	unknown, is_unknown := result.content[3].(Unknown_Content)
	testing.expect(t, is_unknown, "the block is unknown")
	testing.expect_value(t, unknown.type_name, "future_block")
}

// A server's text is kept as it was sent. No block is dropped or cut, and nothing is
// charged against a budget here: what the model is shown is the adapter's decision.
@(test)
test_call_result_keeps_every_text_block_whole :: proc(t: ^testing.T) {
	chunk := strings.repeat("x", 64 * 1024, context.allocator)
	defer delete(chunk, context.allocator)
	block := strings.concatenate({`{"type":"text","text":"`, chunk, `"}`}, context.allocator)
	defer delete(block, context.allocator)

	builder := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `{"resultType":"complete","content":[`)
	for index in 0 ..< 6 {
		if index > 0 { strings.write_string(&builder, ",") }
		strings.write_string(&builder, block)
	}
	strings.write_string(&builder, `]}`)

	owner, object := result_fixture(t, strings.to_string(builder))
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	result, err := call_result_decode(object, .V2026_07_28, context.allocator)
	defer call_result_destroy(&result, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	if !testing.expect_value(t, len(result.content), 6) { return }
	for content in result.content {
		text, is_text := content.(Text_Content)
		testing.expect(t, is_text, "the block is text")
		testing.expect_value(t, len(text.text), len(chunk))
	}
}

// A long title and a long cursor are kept whole: the server chose their length, and
// this client does not shorten what it read.
@(test)
test_tools_list_keeps_long_fields_whole :: proc(t: ^testing.T) {
	cursor := strings.repeat("c", 8 * 1024, context.allocator)
	defer delete(cursor, context.allocator)
	title := strings.repeat("t", 4 * 1024, context.allocator)
	defer delete(title, context.allocator)
	text := strings.concatenate(
		{
			`{"resultType":"complete","nextCursor":"`,
			cursor,
			`","tools":[{"name":"a","description":"d","title":"`,
			title,
			`","inputSchema":{"type":"object"}}]}`,
		},
		context.allocator,
	)
	defer delete(text, context.allocator)

	owner, object := result_fixture(t, text)
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	page, err := tools_list_decode(object, .V2026_07_28, context.allocator)
	defer tool_page_destroy(&page, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }
	next_cursor, has_next_cursor := page.next_cursor.(string)
	if !testing.expect(t, has_next_cursor, "the next cursor is present") { return }
	testing.expect_value(t, next_cursor, cursor)
	if !testing.expect_value(t, len(page.tools), 1) { return }
	testing.expect_value(t, page.tools[0].title, title)
}

@(test)
test_call_result_refuses_malformed_results :: proc(t: ^testing.T) {
	cases := []string {
		`{}`,
		`{"resultType":"complete"}`,
		`{"resultType":"complete","content":[{"type":"text"}]}`,
		`{"resultType":"complete","content":[{"type":"image","mimeType":"image/png"}]}`,
		`{"resultType":"something_else","content":[]}`,
	}
	for text in cases {
		owner, object := result_fixture(t, text)
		if owner == nil { continue }
		result, err := call_result_decode(object, .V2026_07_28, context.allocator)
		testing.expectf(t, err.kind != .None, "%s should be refused", text)
		call_result_destroy(&result, context.allocator)
		error_destroy(&err, context.allocator)
		json.destroy_value(owner, context.allocator)
	}
}

// --- the handshake era --------------------------------------------------------

// A handshake-era listing and call carry no resultType, because that discriminator
// belongs to the stateless revision. Reading them with the stateless rule would
// refuse every reply a 2025 server sends.
@(test)
test_handshake_era_results_carry_no_result_type :: proc(t: ^testing.T) {
	owner, object := result_fixture(t, `{"tools":[{"name":"find_files","description":"Find a file.","inputSchema":{"type":"object"}}]}`)
	if owner == nil { return }
	page, page_err := tools_list_decode(object, .V2025_11_25, context.allocator)
	if testing.expect_value(t, page_err.kind, Error_Kind.None) {
		testing.expect_value(t, len(page.tools), 1)
		testing.expect_value(t, page.tools[0].name, "find_files")
	}
	tool_page_destroy(&page, context.allocator)
	error_destroy(&page_err, context.allocator)
	json.destroy_value(owner, context.allocator)

	owner, object = result_fixture(t, `{"content":[{"type":"text","text":"legacy ok"}],"structuredContent":{"n":1}}`)
	if owner == nil { return }
	result, call_err := call_result_decode(object, .V2025_11_25, context.allocator)
	if testing.expect_value(t, call_err.kind, Error_Kind.None) {
		// That era has no input-required reply: a result is always a completion.
		testing.expect(t, !result.input_required, "a handshake-era result is a completion")
		if testing.expect_value(t, len(result.content), 1) {
			text, is_text := result.content[0].(Text_Content)
			testing.expect(t, is_text, "the block is text")
			testing.expect_value(t, text.text, "legacy ok")
		}
		testing.expect_value(t, result.structured_json, `{"n":1}`)
	}
	call_result_destroy(&result, context.allocator)
	error_destroy(&call_err, context.allocator)
	json.destroy_value(owner, context.allocator)
}

// The stateless envelope belongs to one revision. Sending it under a handshake
// revision would be a field the server has no reason to expect, and the negotiated
// version is what decides.
@(test)
test_request_envelope_follows_the_revision :: proc(t: ^testing.T) {
	stateless, stateless_error := tools_list_params_make(nil, .V2026_07_28, context.allocator)
	if !testing.expect_value(t, stateless_error.kind, Error_Kind.None) { return }
	defer error_destroy(&stateless_error, context.allocator)
	defer json.destroy_value(json.Value(stateless), context.allocator)
	_, stateless_has_meta := stateless["_meta"]
	testing.expect(t, stateless_has_meta, "a stateless revision declares its version on every request")

	handshake, handshake_error := tools_list_params_make(nil, .V2025_11_25, context.allocator)
	if !testing.expect_value(t, handshake_error.kind, Error_Kind.None) { return }
	defer error_destroy(&handshake_error, context.allocator)
	defer json.destroy_value(json.Value(handshake), context.allocator)
	_, handshake_has_meta := handshake["_meta"]
	testing.expect(t, !handshake_has_meta, "a handshake revision negotiated once and carries nothing per request")
	testing.expect_value(t, len(handshake), 0)

	// The handshake itself is where the version is offered, and it carries no `_meta`
	// either: the revision is not known until the server answers.
	initialize, initialize_error := initialize_params_make(context.allocator)
	if !testing.expect_value(t, initialize_error.kind, Error_Kind.None) { return }
	defer error_destroy(&initialize_error, context.allocator)
	defer json.destroy_value(json.Value(initialize), context.allocator)
	testing.expect_value(t, wire_string(t, initialize, "protocolVersion"), PROTOCOL_VERSION_HANDSHAKE)
	_, initialize_has_meta := initialize["_meta"]
	testing.expect(t, !initialize_has_meta)
}
