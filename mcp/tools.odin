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

// tools_list_params_make builds the params for one tools/list page. An empty
// cursor asks for the first page.
tools_list_params_make :: proc(cursor: string, version: Protocol_Version, allocator := context.allocator) -> (json.Object, Error) {
	params, build_error := request_params_make(version, 1 if cursor != "" else 0, allocator)
	if build_error.kind != .None { return {}, build_error }
	if cursor != "" {
		if !mcp_object_put_string(&params, "cursor", cursor, allocator) {
			json.destroy_value(json.Value(params), allocator)
			return {}, error_make(.Out_Of_Memory, allocator = allocator)
		}
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
	page_tools, tools_error := make([dynamic]Tool, 0, len(tools), allocator)
	if tools_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
	page.tools = page_tools
	page_rejected, rejected_error := make([dynamic]Rejected_Tool, 0, allocator)
	if rejected_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
	page.rejected = page_rejected
	for value in tools {
		tool, reason := tool_decode(value, allocator)
		if reason != "" {
			rejected_name, name_error := tool_rejected_name(value, allocator)
			if name_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
			owned_reason, reason_error := strings.clone(reason, allocator)
			if reason_error != nil {
				delete(rejected_name, allocator)
				return {}, error_make(.Out_Of_Memory, allocator = allocator)
			}
			rejected := Rejected_Tool {
				name   = rejected_name,
				reason = owned_reason,
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
		next_cursor, clone_error := strings.clone(string(text), allocator)
		if clone_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
		page.next_cursor = next_cursor
	}

	failed = false
	return page, {}
}

// tool_rejected_name recovers a name for a rejected tool so the report says which
// one was refused, without trusting it as a usable name. A value that carries no
// name at all reads as no name; a name that cannot be copied is the allocator's own
// failure, which the caller reports rather than dropping the name from the report.
@(private)
tool_rejected_name :: proc(value: json.Value, allocator: mem.Allocator) -> (name: string, err: mem.Allocator_Error) {
	object, is_object := value.(json.Object)
	if !is_object { return "", nil }
	name_value, present := object["name"]
	if !present { return "", nil }
	text, is_string := name_value.(json.String)
	if !is_string { return "", nil }
	owned, clone_error := strings.clone(string(text), allocator)
	if clone_error != nil { return "", clone_error }
	return owned, nil
}

// Schema_Role says which schema of a definition is being read, so a refusal names
// the part of the definition the user has to fix.
@(private)
Schema_Role :: enum {
	Input,
	Output,
}

// tool_schema_canonical admits a schema document and returns it as canonical JSON
// bytes. Sorted keys mean the same remote schema always yields the same advertised
// bytes, which is what keeps the cacheable prefix stable across refreshes.
//
// The schema arrives whole. It was carried by a message the protocol layer already
// refused if it nested past the stack bound, so no size or depth of its own applies.
@(private)
tool_schema_canonical :: proc(value: json.Value, role: Schema_Role, allocator: mem.Allocator) -> (schema: string, reason: string) {
	object, is_object := value.(json.Object)
	if !is_object {
		return "", "the tool input schema is not a JSON object" if role == .Input else "the tool output schema is not a JSON object"
	}
	if role == .Input {
		type_value, has_type := object["type"]
		type_text, type_is_string := type_value.(json.String)
		if !has_type || !type_is_string || string(type_text) != "object" {
			return "", `the tool input schema does not declare "type": "object"`
		}
	}

	encoded, unparse_err := json.unparse(value, {spec = .JSON, sort_maps_by_key = true}, allocator)
	if unparse_err != nil { return "", "the tool schema could not be read" }
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
	owned_name, name_error := strings.clone(string(name), allocator)
	if name_error != nil { return {}, "the tool definition could not be allocated" }
	tool.name = owned_name

	// A description is required here even though the protocol makes it optional:
	// the harness advertises a description with every definition, and a tool
	// without one could not be registered. Refusing it here says so once, instead
	// of letting the registry refuse it later without naming the server.
	description_value, has_description := object["description"]
	description, description_is_string := description_value.(json.String)
	if !has_description || !description_is_string || string(description) == "" {
		return {}, "the tool definition has no description"
	}
	owned_description, description_error := strings.clone(string(description), allocator)
	if description_error != nil { return {}, "the tool definition could not be allocated" }
	tool.description = owned_description

	if title_value, present := object["title"]; present {
		title, title_is_string := title_value.(json.String)
		if !title_is_string { return {}, "the tool title is not a string" }
		owned_title, title_error := strings.clone(string(title), allocator)
		if title_error != nil { return {}, "the tool definition could not be allocated" }
		tool.title = owned_title
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
				owned_title, title_error := strings.clone(string(title), allocator)
				if title_error != nil { return {}, "the tool definition could not be allocated" }
				tool.title = owned_title
			}
		}
	}

	failed = false
	return tool, ""
}

// --- calling -----------------------------------------------------------------

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
// input_requests. Every field a result carries arrives whole.
Call_Result :: struct {
	input_required:  bool,
	is_error:        bool,
	content:         [dynamic]Content,
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
	name_value, name_value_error := strings.clone(name, allocator)
	if name_value_error != nil {
		delete(name_key, allocator)
		json.destroy_value(json.Value(built_params), allocator)
		json.destroy_value(arguments, allocator)
		return {}, error_make(.Out_Of_Memory, allocator = allocator)
	}
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
			state, clone_error := strings.clone(string(text), allocator)
			if clone_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
			decoded.request_state = state
		}
		if requests_value, present := result["inputRequests"]; present {
			encoded, unparse_err := json.unparse(requests_value, {spec = .JSON, sort_maps_by_key = true}, allocator)
			if unparse_err != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
			decoded.input_requests = encoded
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

		content_blocks, blocks_error := make([dynamic]Content, 0, len(blocks), allocator)
		if blocks_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
		decoded.content = content_blocks
		for block in blocks {
			content, content_err := content_decode(block, allocator)
			if content_err.kind != .None {
				// The blocks already kept are owned by decoded, which the deferred
				// cleanup releases.
				return {}, content_err
			}
			appended := append(&decoded.content, content)
			if appended != 1 {
				if appended == 0 { content_block_destroy(&content, allocator) }
				return {}, error_make(.Out_Of_Memory, allocator = allocator)
			}
		}

		if structured_value, present := result["structuredContent"]; present {
			encoded, unparse_err := json.unparse(structured_value, {spec = .JSON, sort_maps_by_key = true}, allocator)
			if unparse_err != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
			decoded.structured_json = encoded
		}

	case:
		return {}, error_make(.Unexpected_Message, fmt.tprintf("the tool result has unknown result type %q", kind), allocator = allocator)
	}

	failed = false
	return decoded, {}
}

// content_decode reads one content block. Every field the block carries is kept as
// the server sent it.
@(private)
content_decode :: proc(value: json.Value, allocator: mem.Allocator) -> (Content, Error) {
	content: Content
	object, is_object := value.(json.Object)
	if !is_object { return {}, error_make(.Malformed_Message, "a content block is not an object", allocator = allocator) }

	type_value, has_type := object["type"]
	type_text, type_is_string := type_value.(json.String)
	if !has_type || !type_is_string || string(type_text) == "" {
		return {}, error_make(.Malformed_Message, "a content block has no usable type", allocator = allocator)
	}
	owned_type_name, type_error := strings.clone(string(type_text), allocator)
	if type_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
	content.type_name = owned_type_name
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
		owned_text, text_error := strings.clone(string(text), allocator)
		if text_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
		content.text = owned_text

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
		mime_error: mem.Allocator_Error
		content.mime_type, mime_error = strings.clone(string(mime), allocator)
		if mime_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }

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
		name_error, uri_error: mem.Allocator_Error
		content.name, name_error = strings.clone(string(name), allocator)
		if name_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
		content.uri, uri_error = strings.clone(string(uri), allocator)
		if uri_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
		if mime_value, present := object["mimeType"]; present {
			mime, mime_is_string := mime_value.(json.String)
			if !mime_is_string { return {}, error_make(.Malformed_Message, "a resource link's MIME type is not a string", allocator = allocator) }
			mime_error: mem.Allocator_Error
			content.mime_type, mime_error = strings.clone(string(mime), allocator)
			if mime_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
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
		uri_error: mem.Allocator_Error
		content.uri, uri_error = strings.clone(string(uri), allocator)
		if uri_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
		if mime_value, present := resource["mimeType"]; present {
			mime, mime_is_string := mime_value.(json.String)
			if !mime_is_string { return {}, error_make(.Malformed_Message, "an embedded resource's MIME type is not a string", allocator = allocator) }
			mime_error: mem.Allocator_Error
			content.mime_type, mime_error = strings.clone(string(mime), allocator)
			if mime_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
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
