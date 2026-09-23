package mcp

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

// Hint is a three-valued statement a server made about a tool. Unknown is the
// zero value: an absent annotation is not a claim, and reading it as "no" would
// invent a fact the server never stated.
Hint :: enum {
	Unknown,
	No,
	Yes,
}

// Tool_Annotations is what a server said about a tool's behavior. Every string is
// owned by the reading allocator.
Tool_Annotations :: struct {
	read_only:   Hint,
	destructive: Hint,
	idempotent:  Hint,
	open_world:  Hint,
}

// Tool is one tool a server listed. Every string is owned, and input_schema holds
// canonical JSON bytes rather than a parsed value, because the definition this
// becomes advertises bytes.
Tool :: struct {
	name:          string,
	title:         string,
	description:   string,
	input_schema:  string,
	output_schema: string,
	annotations:   Tool_Annotations,
}

tool_destroy :: proc(tool: ^Tool, allocator := context.allocator) {
	delete(tool.name, allocator)
	delete(tool.title, allocator)
	delete(tool.description, allocator)
	delete(tool.input_schema, allocator)
	delete(tool.output_schema, allocator)
	tool^ = {}
}

// Rejected_Tool is a remote tool this client refused, with the reason. It is
// reported rather than dropped silently: a tool the user asked for by name and
// did not get is something they need to know about. Both strings are owned.
Rejected_Tool :: struct {
	name:   string,
	reason: string,
}

// Tool_Page is one page of a tools/list result. next_cursor is empty when the
// server reported no more pages.
Tool_Page :: struct {
	tools:       [dynamic]Tool,
	rejected:    [dynamic]Rejected_Tool,
	next_cursor: string,
	allocator:   mem.Allocator,
}

tool_page_destroy :: proc(page: ^Tool_Page, allocator := context.allocator) {
	owner := page.allocator
	if owner.procedure == nil { owner = allocator }
	for &tool in page.tools { tool_destroy(&tool, owner) }
	// A dynamic array carries its own allocator, so its backing store is released
	// without being told which one.
	delete(page.tools)
	for &rejected in page.rejected {
		delete(rejected.name, owner)
		delete(rejected.reason, owner)
	}
	delete(page.rejected)
	delete(page.next_cursor, owner)
	page^ = {}
}

// MAX_TOOLS_PER_PAGE bounds one tools/list page. A page is not a listing, so a
// page larger than this is a malformed reply rather than a large one.
MAX_TOOLS_PER_PAGE :: 1024

// MAX_TOOL_NAME_BYTES and MAX_TOOL_DESCRIPTION_BYTES bound what one tool may
// contribute. The advertised definition carries both on every request, so a tool
// that does not fit is refused rather than advertised at the user's expense.
MAX_TOOL_NAME_BYTES :: 128
MAX_TOOL_DESCRIPTION_BYTES :: 4096
MAX_TOOL_TITLE_BYTES :: 256

// MAX_TOOL_SCHEMA_BYTES and MAX_TOOL_SCHEMA_DEPTH bound a schema document. The
// depth matches what the harness's own definition admission accepts, so a schema
// this client keeps is one the registry can install.
MAX_TOOL_SCHEMA_BYTES :: 64 * 1024
MAX_TOOL_SCHEMA_DEPTH :: 32

// MAX_CURSOR_BYTES bounds an opaque pagination cursor. It is a token the server
// chose, so it is bounded like any other server text.
MAX_CURSOR_BYTES :: 4096

// tools_list_params_make builds the params for one tools/list page. An empty
// cursor asks for the first page.
tools_list_params_make :: proc(cursor: string, version: Protocol_Version, allocator := context.allocator) -> (json.Object, Error) {
	params, build_error := request_params_make(version, 1 if cursor != "" else 0, allocator)
	if build_error.kind != .None { return {}, build_error }
	if cursor != "" {
		key, clone_error := strings.clone("cursor", allocator)
		if clone_error != nil { json.destroy_value(json.Value(params), allocator); return {}, error_make(.Out_Of_Memory, allocator = allocator) }
		params[key] = json.String(mcp_clone_bounded(cursor, MAX_CURSOR_BYTES, allocator))
	}
	return params, {}
}

// tools_list_decode reads one tools/list page. A tool that cannot be used is
// reported as rejected rather than failing the page, so one malformed definition
// does not cost the user the tools that were well formed.
tools_list_decode :: proc(result: json.Object, version: Protocol_Version, allocator := context.allocator) -> (Tool_Page, Error) {
	// The accumulator is a local rather than the named return value: a deferred
	// cleanup runs after the return value is assigned, so a named one would be
	// freed after it had already been overwritten with the zero value.
	page: Tool_Page
	page.allocator = allocator
	failed := true
	defer if failed { tool_page_destroy(&page, allocator) }

	// Only the stateless revision discriminates its results. A handshake-era listing
	// has no resultType at all.
	if protocol_version_era(version) == .Stateless {
		kind, has_kind := result_type(result)
		if !has_kind {
			return {}, error_make(.Malformed_Message, "the tool listing carries no resultType", allocator = allocator)
		}
		if kind != RESULT_TYPE_COMPLETE {
			return {}, error_make(.Unexpected_Message, fmt.tprintf("the tool listing answered with result type %q", kind), allocator = allocator)
		}
	}

	tools_value, has_tools := result["tools"]
	if !has_tools {
		return {}, error_make(.Malformed_Message, "the tool listing carries no tools", allocator = allocator)
	}
	tools, tools_are_array := tools_value.(json.Array)
	if !tools_are_array {
		return {}, error_make(.Malformed_Message, "the tool listing's tools are not an array", allocator = allocator)
	}
	if len(tools) > MAX_TOOLS_PER_PAGE {
		return {}, error_make(.Malformed_Message, "the tool listing page is larger than 1024 tools", allocator = allocator)
	}

	page_tools, tools_error := make([dynamic]Tool, 0, len(tools), allocator)
	if tools_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
	page.tools = page_tools
	page_rejected, rejected_error := make([dynamic]Rejected_Tool, 0, allocator)
	if rejected_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
	page.rejected = page_rejected
	for value in tools {
		tool, reason := tool_decode(value, allocator)
		if reason != "" {
			rejected := Rejected_Tool {
				name   = tool_rejected_name(value, allocator),
				reason = mcp_clone_bounded(reason, MAX_TOOL_DESCRIPTION_BYTES, allocator),
			}
			appended := append(&page.rejected, rejected)
			if appended != 1 {
				if appended == 0 {
					delete(rejected.name, allocator)
					delete(rejected.reason, allocator)
				}
				return {}, error_make(.Out_Of_Memory, allocator = allocator)
			}
			continue
		}
		appended := append(&page.tools, tool)
		if appended != 1 {
			if appended == 0 { tool_destroy(&tool, allocator) }
			return {}, error_make(.Out_Of_Memory, allocator = allocator)
		}
	}

	if cursor_value, present := result["nextCursor"]; present {
		text, is_string := cursor_value.(json.String)
		if !is_string {
			return {}, error_make(.Malformed_Message, "the tool listing's next cursor is not a string", allocator = allocator)
		}
		page.next_cursor = mcp_clone_bounded(string(text), MAX_CURSOR_BYTES, allocator)
	}

	failed = false
	return page, {}
}

// tool_rejected_name recovers a name for a rejected tool so the report says which
// one was refused, without trusting it as a usable name.
@(private)
tool_rejected_name :: proc(value: json.Value, allocator: mem.Allocator) -> string {
	object, is_object := value.(json.Object)
	if !is_object { return "" }
	name_value, present := object["name"]
	if !present { return "" }
	text, is_string := name_value.(json.String)
	if !is_string { return "" }
	return mcp_clone_bounded(string(text), MAX_TOOL_NAME_BYTES, allocator)
}

// Schema_Role says which schema of a definition is being read, so a refusal names
// the part of the definition the user has to fix.
@(private)
Schema_Role :: enum {
	Input,
	Output,
}

@(private)
tool_schema_reason :: proc(role: Schema_Role, problem: string) -> string {
	switch role {
	case .Input:
		switch problem {
		case "object":
			return "the tool input schema is not a JSON object"
		case "type":
			return `the tool input schema does not declare "type": "object"`
		case "size":
			return "the tool input schema is larger than 64 KiB"
		case "shape":
			return "the tool input schema is not one bounded JSON document"
		}
	case .Output:
		switch problem {
		case "object":
			return " the tool output schema is not a JSON object"
		}
	}
	return "the tool schema could not be read"
}

// tool_schema_canonical admits a schema document and returns it as canonical JSON
// bytes. Sorted keys mean the same remote schema always yields the same advertised
// bytes, which is what keeps the cacheable prefix stable across refreshes.
//
// The nesting bound is repeated here rather than left to the one already applied to
// the whole message: a schema this client keeps must be one the harness's own
// definition admission will accept.
@(private)
tool_schema_canonical :: proc(value: json.Value, role: Schema_Role, allocator: mem.Allocator) -> (schema: string, reason: string) {
	object, is_object := value.(json.Object)
	if !is_object { return "", tool_schema_reason(role, "object") }
	if role == .Input {
		type_value, has_type := object["type"]
		type_text, type_is_string := type_value.(json.String)
		if !has_type || !type_is_string || string(type_text) != "object" {
			return "", tool_schema_reason(role, "type")
		}
	}

	encoded, unparse_err := json.unparse(value, {spec = .JSON, sort_maps_by_key = true}, allocator)
	if unparse_err != nil { return "", tool_schema_reason(role, "shape") }
	if len(encoded) > MAX_TOOL_SCHEMA_BYTES {
		delete(encoded, allocator)
		return "", tool_schema_reason(role, "size")
	}
	if problem := document_admit(encoded, MAX_TOOL_SCHEMA_BYTES, MAX_TOOL_SCHEMA_DEPTH, true, context.temp_allocator); problem != .None {
		delete(encoded, allocator)
		return "", tool_schema_reason(role, "shape")
	}
	return encoded, ""
}

@(private)
tool_annotation :: proc(annotations: json.Object, field: string) -> (Hint, bool) {
	value, present := annotations[field]
	if !present { return .Unknown, true }
	flag, is_boolean := value.(json.Boolean)
	if !is_boolean { return .Unknown, false }
	return .Yes if bool(flag) else .No, true
}

// tool_decode reads one tool definition. A reason other than "" means the tool was
// refused, and the reason is static text naming what is wrong.
@(private)
tool_decode :: proc(value: json.Value, allocator: mem.Allocator) -> (Tool, string) {
	// The accumulator is a local rather than the named return value: a deferred
	// cleanup runs after the return value is assigned, so a named one would be
	// freed after it had already been overwritten with the zero value.
	tool: Tool
	failed := true
	defer if failed { tool_destroy(&tool, allocator) }

	object, is_object := value.(json.Object)
	if !is_object { return {}, "the tool definition is not a JSON object" }

	name_value, has_name := object["name"]
	name, name_is_string := name_value.(json.String)
	if !has_name || !name_is_string || string(name) == "" { return {}, "the tool definition has no usable name" }
	if len(name) > MAX_TOOL_NAME_BYTES { return {}, "the tool name is longer than 128 bytes" }
	tool.name = mcp_clone_bounded(string(name), MAX_TOOL_NAME_BYTES, allocator)

	// A description is required here even though the protocol makes it optional:
	// the harness advertises a description with every definition, and a tool
	// without one could not be registered. Refusing it here says so once, instead
	// of letting the registry refuse it later without naming the server.
	description_value, has_description := object["description"]
	description, description_is_string := description_value.(json.String)
	if !has_description || !description_is_string || string(description) == "" {
		return {}, "the tool definition has no description"
	}
	if len(description) > MAX_TOOL_DESCRIPTION_BYTES { return {}, "the tool description is longer than 4096 bytes" }
	tool.description = mcp_clone_bounded(string(description), MAX_TOOL_DESCRIPTION_BYTES, allocator)

	if title_value, present := object["title"]; present {
		title, title_is_string := title_value.(json.String)
		if !title_is_string { return {}, "the tool title is not a string" }
		tool.title = mcp_clone_bounded(string(title), MAX_TOOL_TITLE_BYTES, allocator)
	}

	schema_value, has_schema := object["inputSchema"]
	if !has_schema { return {}, "the tool definition has no input schema" }
	input_schema, schema_reason := tool_schema_canonical(schema_value, .Input, allocator)
	if schema_reason != "" { return {}, schema_reason }
	tool.input_schema = input_schema

	if output_value, present := object["outputSchema"]; present {
		output_schema, output_reason := tool_schema_canonical(output_value, .Output, allocator)
		if output_reason != "" { return {}, output_reason }
		tool.output_schema = output_schema
	}

	if annotations_value, present := object["annotations"]; present {
		annotations, annotations_are_object := annotations_value.(json.Object)
		if !annotations_are_object { return {}, "the tool annotations are not an object" }
		hints := [?]struct {
			field: string,
			value: ^Hint,
		} {
			{"readOnlyHint", &tool.annotations.read_only},
			{"destructiveHint", &tool.annotations.destructive},
			{"idempotentHint", &tool.annotations.idempotent},
			{"openWorldHint", &tool.annotations.open_world},
		}
		for hint in hints {
			value, ok := tool_annotation(annotations, hint.field)
			if !ok { return {}, "a tool annotation is not a boolean" }
			hint.value^ = value
		}
		// A title in the annotations is the same display title as the tool's own.
		// It is read only when the tool did not carry one.
		if tool.title == "" {
			if annotation_title, annotation_has_title := annotations["title"]; annotation_has_title {
				title, title_is_string := annotation_title.(json.String)
				if !title_is_string { return {}, "the tool annotation title is not a string" }
				tool.title = mcp_clone_bounded(string(title), MAX_TOOL_TITLE_BYTES, allocator)
			}
		}
	}

	failed = false
	return tool, ""
}

// --- calling -----------------------------------------------------------------

// MAX_CONTENT_ITEMS bounds how many content blocks one result may carry.
MAX_CONTENT_ITEMS :: 256

// MAX_CONTENT_TYPE_BYTES, MAX_MIME_BYTES, MAX_CONTENT_URI_BYTES, and
// MAX_CONTENT_NAME_BYTES bound the descriptive fields of one content block.
MAX_CONTENT_TYPE_BYTES :: 128
MAX_MIME_BYTES :: 256
MAX_CONTENT_URI_BYTES :: 2048
MAX_CONTENT_NAME_BYTES :: 256

// MAX_CONTENT_TEXT_BYTES bounds one text block, and MAX_CALL_RESULT_BYTES bounds
// all of them together. The harness result budget is smaller than either, so the
// adapter trims what it forwards; these bounds exist so a server cannot make this
// package hold an amount of text it never described a limit for.
MAX_CONTENT_TEXT_BYTES :: 64 * 1024
MAX_CALL_RESULT_BYTES :: 256 * 1024

// MAX_STRUCTURED_BYTES bounds the structured half of a result.
MAX_STRUCTURED_BYTES :: 256 * 1024

// MAX_REQUEST_STATE_BYTES and MAX_INPUT_REQUESTS_BYTES bound what an
// input-required result may contribute to the diagnostic that reports it.
MAX_REQUEST_STATE_BYTES :: 4096
MAX_INPUT_REQUESTS_BYTES :: 16 * 1024

// Content_Kind classifies one content block.
Content_Kind :: enum {
	Text,
	Image,
	Audio,
	Resource_Link,
	Embedded_Resource,
	// A content type this revision does not define, named by type_name.
	Unknown,
}

// Content is one content block. type_name is what the server called it, so a
// block that is not shown can still be reported. Binary payloads are never
// retained: an image, an audio block, and an embedded resource carry their
// descriptive fields only, because their data would consume the model's context
// to no purpose.
Content :: struct {
	kind:      Content_Kind,
	type_name: string,
	text:      string,
	mime_type: string,
	uri:       string,
	name:      string,
}

content_block_destroy :: proc(block: ^Content, allocator := context.allocator) {
	delete(block.type_name, allocator)
	delete(block.text, allocator)
	delete(block.mime_type, allocator)
	delete(block.uri, allocator)
	delete(block.name, allocator)
	block^ = {}
}

content_destroy :: proc(content: []Content, allocator := context.allocator) {
	for &block in content { content_block_destroy(&block, allocator) }
	delete(content, allocator)
}

// Call_Result is one tools/call answer. input_required marks a reply that asks
// for more input instead of reporting a finished call, in which case content is
// empty and the server's request description is in request_state and
// input_requests.
Call_Result :: struct {
	input_required:  bool,
	is_error:        bool,
	content:         [dynamic]Content,
	truncated:       bool,
	structured_json: string,
	request_state:   string,
	input_requests:  string,
	allocator:       mem.Allocator,
}

call_result_destroy :: proc(result: ^Call_Result, allocator := context.allocator) {
	owner := result.allocator
	if owner.procedure == nil { owner = allocator }
	content_destroy(result.content[:], owner)
	delete(result.structured_json, owner)
	delete(result.request_state, owner)
	delete(result.input_requests, owner)
	result^ = {}
}

// tools_call_params_make builds the params for one tools/call. The arguments are
// taken as the admitted argument text the caller already holds, so the bytes on
// the wire are the bytes the session recorded as what the call ran with. Text
// that does not parse is refused rather than sent, because an endpoint cannot
// read it and the caller would have no record of what it said.
tools_call_params_make :: proc(name, arguments_json: string, version: Protocol_Version, allocator := context.allocator) -> (params: json.Object, err: Error) {
	arguments, parse_err := json.parse_string(arguments_json, .JSON, true, allocator)
	if parse_err != nil {
		return {}, error_make(.Malformed_Message, "the call arguments are not valid JSON", allocator = allocator)
	}
	object, is_object := arguments.(json.Object)
	if !is_object {
		json.destroy_value(arguments, allocator)
		return {}, error_make(.Malformed_Message, "the call arguments are not a JSON object", allocator = allocator)
	}

	built_params, build_error := request_params_make(version, 2, allocator)
	if build_error.kind != .None {
		json.destroy_value(arguments, allocator)
		return {}, build_error
	}
	name_key, name_key_error := strings.clone("name", allocator)
	if name_key_error != nil {
		json.destroy_value(json.Value(built_params), allocator)
		json.destroy_value(arguments, allocator)
		return {}, error_make(.Out_Of_Memory, allocator = allocator)
	}
	name_value := mcp_clone_bounded(name, MAX_TOOL_NAME_BYTES, allocator)
	built_params[name_key] = json.String(name_value)
	arguments_key, arguments_key_error := strings.clone("arguments", allocator)
	if arguments_key_error != nil {
		json.destroy_value(json.Value(built_params), allocator)
		json.destroy_value(arguments, allocator)
		return {}, error_make(.Out_Of_Memory, allocator = allocator)
	}
	built_params[arguments_key] = json.Value(object)
	return built_params, {}
}

// call_result_decode reads one tools/call result, of either shape the revision
// defines. A result type this revision does not define is refused rather than
// guessed at, because the fields it carries would be unknown.
call_result_decode :: proc(result: json.Object, version: Protocol_Version, allocator := context.allocator) -> (Call_Result, Error) {
	decoded: Call_Result
	decoded.allocator = allocator
	failed := true
	defer if failed { call_result_destroy(&decoded, allocator) }

	// A handshake-era result is a completion: that era has no input-required reply,
	// because server-to-client interaction travels as a request on the stream.
	kind := RESULT_TYPE_COMPLETE
	if protocol_version_era(version) == .Stateless {
		read_kind, has_kind := result_type(result)
		if !has_kind {
			return {}, error_make(.Malformed_Message, "the tool result carries no resultType", allocator = allocator)
		}
		kind = read_kind
	}
	switch kind {
	case RESULT_TYPE_INPUT_REQUIRED:
		decoded.input_required = true
		if state_value, present := result["requestState"]; present {
			text, is_string := state_value.(json.String)
			if !is_string {
				return {}, error_make(.Malformed_Message, "the input request state is not a string", allocator = allocator)
			}
			decoded.request_state = mcp_clone_bounded(string(text), MAX_REQUEST_STATE_BYTES, allocator)
		}
		if requests_value, present := result["inputRequests"]; present {
			encoded, unparse_err := json.unparse(requests_value, {spec = .JSON, sort_maps_by_key = true}, allocator)
			if unparse_err != nil {
				return {}, error_make(.Out_Of_Memory, allocator = allocator)
			}
			// The description is diagnostic. One that does not fit is dropped
			// rather than cut, because a half-rendered request description is not
			// what the server asked for.
			if len(encoded) > MAX_INPUT_REQUESTS_BYTES {
				delete(encoded, allocator)
			} else {
				decoded.input_requests = encoded
			}
		}

	case RESULT_TYPE_COMPLETE:
		if error_value, present := result["isError"]; present {
			flag, flag_is_boolean := error_value.(json.Boolean)
			if !flag_is_boolean {
				return {}, error_make(.Malformed_Message, "the tool result's isError flag is not a boolean", allocator = allocator)
			}
			decoded.is_error = bool(flag)
		}

		content_value, has_content := result["content"]
		if !has_content {
			return {}, error_make(.Malformed_Message, "the tool result carries no content", allocator = allocator)
		}
		blocks, blocks_are_array := content_value.(json.Array)
		if !blocks_are_array {
			return {}, error_make(.Malformed_Message, "the tool result's content is not an array", allocator = allocator)
		}
		if len(blocks) > MAX_CONTENT_ITEMS {
			return {}, error_make(.Malformed_Message, "the tool result carries more than 256 content blocks", allocator = allocator)
		}

		decoded.content = make([dynamic]Content, 0, len(blocks), allocator)
		kept_text := 0
		for block in blocks {
			content, content_err := content_decode(block, &kept_text, allocator)
			if content_err.kind != .None {
				// The blocks already kept are owned by decoded, which the deferred
				// cleanup releases.
				return {}, content_err
			}
			append(&decoded.content, content)
		}
		decoded.truncated = kept_text > MAX_CALL_RESULT_BYTES

		if structured_value, present := result["structuredContent"]; present {
			encoded, unparse_err := json.unparse(structured_value, {spec = .JSON, sort_maps_by_key = true}, allocator)
			if unparse_err != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
			if len(encoded) > MAX_STRUCTURED_BYTES {
				delete(encoded, allocator)
				return {}, error_make(.Malformed_Message, "the tool result's structured content is larger than 256 KiB", allocator = allocator)
			}
			decoded.structured_json = encoded
		}

	case:
		return {}, error_make(.Unexpected_Message, fmt.tprintf("the tool result has unknown result type %q", kind), allocator = allocator)
	}

	failed = false
	return decoded, {}
}

// content_decode reads one content block. kept_text is the running total of text
// already kept, so a result cannot accumulate text a server never bounded; past
// the budget a text block is recorded as empty and the result is marked
// truncated, which is a fact the adapter passes on to the model.
@(private)
content_decode :: proc(value: json.Value, kept_text: ^int, allocator: mem.Allocator) -> (Content, Error) {
	content: Content
	object, is_object := value.(json.Object)
	if !is_object { return {}, error_make(.Malformed_Message, "a content block is not an object", allocator = allocator) }

	type_value, has_type := object["type"]
	type_text, type_is_string := type_value.(json.String)
	if !has_type || !type_is_string || string(type_text) == "" {
		return {}, error_make(.Malformed_Message, "a content block has no usable type", allocator = allocator)
	}
	content.type_name = mcp_clone_bounded(string(type_text), MAX_CONTENT_TYPE_BYTES, allocator)
	failed := true
	defer if failed { content_block_destroy(&content, allocator) }

	switch string(type_text) {
	case "text":
		text_value, has_text := object["text"]
		text, text_is_string := text_value.(json.String)
		if !has_text || !text_is_string {
			return {}, error_make(.Malformed_Message, "a text content block carries no text", allocator = allocator)
		}
		content.kind = .Text
		// Every offered block is charged against the budget, whether it was kept
		// or dropped, so a result that dropped text reports itself as truncated.
		offered := mcp_clone_bounded(string(text), MAX_CONTENT_TEXT_BYTES, allocator)
		defer delete(offered, allocator)
		if kept_text^ < MAX_CALL_RESULT_BYTES {
			content.text = mcp_clone_bounded(offered, MAX_CONTENT_TEXT_BYTES, allocator)
		}
		kept_text^ += len(offered)

	case "image", "audio":
		// The payload is checked for presence and shape without being copied: the
		// harness reports that the block exists and what it is, and never puts the
		// bytes anywhere.
		data_value, has_data := object["data"]
		_, data_is_string := data_value.(json.String)
		if !has_data || !data_is_string {
			return {}, error_make(.Malformed_Message, "a binary content block carries no data", allocator = allocator)
		}
		mime_value, has_mime := object["mimeType"]
		mime, mime_is_string := mime_value.(json.String)
		if !has_mime || !mime_is_string {
			return {}, error_make(.Malformed_Message, "a binary content block carries no MIME type", allocator = allocator)
		}
		content.kind = .Image if string(type_text) == "image" else .Audio
		content.mime_type = mcp_clone_bounded(string(mime), MAX_MIME_BYTES, allocator)

	case "resource_link":
		name_value, has_name := object["name"]
		name, name_is_string := name_value.(json.String)
		if !has_name || !name_is_string {
			return {}, error_make(.Malformed_Message, "a resource link carries no name", allocator = allocator)
		}
		uri_value, has_uri := object["uri"]
		uri, uri_is_string := uri_value.(json.String)
		if !has_uri || !uri_is_string {
			return {}, error_make(.Malformed_Message, "a resource link carries no URI", allocator = allocator)
		}
		content.kind = .Resource_Link
		content.name = mcp_clone_bounded(string(name), MAX_CONTENT_NAME_BYTES, allocator)
		content.uri = mcp_clone_bounded(string(uri), MAX_CONTENT_URI_BYTES, allocator)
		if mime_value, present := object["mimeType"]; present {
			mime, mime_is_string := mime_value.(json.String)
			if !mime_is_string { return {}, error_make(.Malformed_Message, "a resource link's MIME type is not a string", allocator = allocator) }
			content.mime_type = mcp_clone_bounded(string(mime), MAX_MIME_BYTES, allocator)
		}

	case "resource":
		resource_value, has_resource := object["resource"]
		resource, resource_is_object := resource_value.(json.Object)
		if !has_resource || !resource_is_object {
			return {}, error_make(.Malformed_Message, "an embedded resource carries no resource", allocator = allocator)
		}
		uri_value, has_uri := resource["uri"]
		uri, uri_is_string := uri_value.(json.String)
		if !has_uri || !uri_is_string {
			return {}, error_make(.Malformed_Message, "an embedded resource carries no URI", allocator = allocator)
		}
		content.kind = .Embedded_Resource
		content.uri = mcp_clone_bounded(string(uri), MAX_CONTENT_URI_BYTES, allocator)
		if mime_value, present := resource["mimeType"]; present {
			mime, mime_is_string := mime_value.(json.String)
			if !mime_is_string { return {}, error_make(.Malformed_Message, "an embedded resource's MIME type is not a string", allocator = allocator) }
			content.mime_type = mcp_clone_bounded(string(mime), MAX_MIME_BYTES, allocator)
		}

	case:
		// A content type this revision does not define is reported, not refused:
		// the result itself is usable, and the model is owed the fact that
		// something came back which the harness does not show.
		content.kind = .Unknown
	}

	failed = false
	return content, {}
}
