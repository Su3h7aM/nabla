#+test
package mcp

import "core:encoding/json"
import "core:strings"
import "core:testing"

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

	page, err := tools_list_decode(object, context.allocator)
	defer tool_page_destroy(&page, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	if !testing.expect_value(t, len(page.tools), 1) { return }
	testing.expect_value(t, len(page.rejected), 0)
	testing.expect_value(t, page.next_cursor, "page-2")
	testing.expect_value(t, page.tools[0].name, "issues.create")
	testing.expect_value(t, page.tools[0].title, "Create an issue")
	testing.expect_value(t, page.tools[0].description, "Create one issue.")
	// The harness advertises bytes, so a schema is canonicalized once: sorted keys
	// make the same remote schema yield the same advertised bytes every refresh.
	testing.expect_value(t, page.tools[0].input_schema, `{"properties":{"a":{"type":"integer"},"b":{"type":"string"}},"required":["a"],"type":"object"}`)
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

	page, err := tools_list_decode(object, context.allocator)
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

	page, err := tools_list_decode(object, context.allocator)
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
		page, err := tools_list_decode(object, context.allocator)
		testing.expectf(t, err.kind != .None, "%s should be refused", text)
		tool_page_destroy(&page, context.allocator)
		error_destroy(&err, context.allocator)
		json.destroy_value(owner, context.allocator)
	}
}

// A schema is refused when the harness's own definition admission would refuse it,
// so a schema this client keeps is one the registry can install.
@(test)
test_tool_schema_depth_is_bounded_like_the_definition_admission :: proc(t: ^testing.T) {
	builder := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `{"resultType":"complete","tools":[{"name":"deep","description":"d","inputSchema":{"type":"object","p":`)
	for _ in 0 ..< MAX_TOOL_SCHEMA_DEPTH + 2 { strings.write_string(&builder, `{"p":`) }
	strings.write_string(&builder, `1`)
	for _ in 0 ..< MAX_TOOL_SCHEMA_DEPTH + 2 { strings.write_string(&builder, `}`) }
	strings.write_string(&builder, `}}]}`)

	owner, object := result_fixture(t, strings.to_string(builder))
	if owner == nil { return }
	defer json.destroy_value(owner, context.allocator)

	page, err := tools_list_decode(object, context.allocator)
	defer tool_page_destroy(&page, context.allocator)
	defer error_destroy(&err, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect_value(t, len(page.tools), 0)
	if testing.expect_value(t, len(page.rejected), 1) {
		testing.expect(t, page.rejected[0].reason != "", "the refusal says why")
	}
}

@(test)
test_tools_call_params_carry_the_admitted_arguments :: proc(t: ^testing.T) {
	params, err := tools_call_params_make("issues.create", `{"title":"a bug"}`, context.allocator)
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
	_, bad_err := tools_call_params_make("t", `{`, context.allocator)
	defer error_destroy(&bad_err, context.allocator)
	testing.expect_value(t, bad_err.kind, Error_Kind.Malformed_Message)
}

// --- calling -----------------------------------------------------------------

@(test)
test_call_result_reads_completion_and_failure :: proc(t: ^testing.T) {
	owner, object := result_fixture(t, `{"resultType":"complete","content":[{"type":"text","text":"created issue 12"}],"structuredContent":{"number":12}}`)
	if owner == nil { return }
	result, err := call_result_decode(object, context.allocator)
	if testing.expect_value(t, err.kind, Error_Kind.None) {
		testing.expect(t, !result.is_error && !result.input_required)
		if testing.expect_value(t, len(result.content), 1) {
			testing.expect_value(t, result.content[0].kind, Content_Kind.Text)
			testing.expect_value(t, result.content[0].text, "created issue 12")
		}
		testing.expect_value(t, result.structured_json, `{"number":12}`)
	}
	call_result_destroy(&result, context.allocator)
	error_destroy(&err, context.allocator)
	json.destroy_value(owner, context.allocator)

	owner, object = result_fixture(t, `{"resultType":"complete","isError":true,"content":[{"type":"text","text":"no such repo"}]}`)
	if owner == nil { return }
	result, err = call_result_decode(object, context.allocator)
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

	result, err := call_result_decode(object, context.allocator)
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

	result, err := call_result_decode(object, context.allocator)
	defer call_result_destroy(&result, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	if !testing.expect_value(t, len(result.content), 4) { return }
	testing.expect_value(t, result.content[0].kind, Content_Kind.Image)
	testing.expect_value(t, result.content[0].mime_type, "image/png")
	testing.expect_value(t, result.content[1].kind, Content_Kind.Resource_Link)
	testing.expect_value(t, result.content[1].uri, "file:///tmp/log")
	testing.expect_value(t, result.content[2].kind, Content_Kind.Embedded_Resource)
	testing.expect_value(t, result.content[2].uri, "file:///tmp/x")
	// A type this revision does not define is reported, not refused, and it is
	// named by what the server called it.
	testing.expect_value(t, result.content[3].kind, Content_Kind.Unknown)
	testing.expect_value(t, result.content[3].type_name, "future_block")
}

@(test)
test_call_result_marks_and_bounds_the_text_it_keeps :: proc(t: ^testing.T) {
	chunk := strings.repeat("x", MAX_CONTENT_TEXT_BYTES, context.allocator)
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

	result, err := call_result_decode(object, context.allocator)
	defer call_result_destroy(&result, context.allocator)
	defer error_destroy(&err, context.allocator)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }

	testing.expect(t, result.truncated, "the result says the text was not all kept")
	kept := 0
	for content in result.content { kept += len(content.text) }
	testing.expect(t, kept <= MAX_CALL_RESULT_BYTES, "the kept text stays inside the budget")
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
		result, err := call_result_decode(object, context.allocator)
		testing.expectf(t, err.kind != .None, "%s should be refused", text)
		call_result_destroy(&result, context.allocator)
		error_destroy(&err, context.allocator)
		json.destroy_value(owner, context.allocator)
	}
}
