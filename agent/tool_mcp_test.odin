#+test
package agent

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "core:time"

import "nabla:agent/journal"
import "nabla:mcp"

@(private)
mcp_test_context :: proc() -> Tool_Context {
	return Tool_Context{call_id = "call_mcp", allocator = context.allocator}
}

@(private)
mcp_test_content :: proc(kind: mcp.Content_Kind, type_name, text, mime_type: string) -> mcp.Content {
	return mcp.Content {
		kind = kind,
		type_name = strings.clone(type_name, context.allocator),
		text = strings.clone(text, context.allocator),
		mime_type = strings.clone(mime_type, context.allocator),
	}
}

@(test)
test_mcp_definition_carries_the_alias_schema_and_hints :: proc(test: ^testing.T) {
	tool := mcp.Tool {
		name = "issues_create",
		description = "Create one issue.",
		input_schema = `{"type":"object"}`,
		annotations = {read_only = .Yes, destructive = .No, idempotent = .Unknown, open_world = .Yes},
	}
	backend: MCP_Tool_Backend
	definition := mcp_tool_definition("github_create_issue", tool, &backend, 5 * time.Second)

	// The alias is what the model is advertised, and the remote name travels in the
	// binding: the two are deliberately not the same string.
	testing.expect_value(test, definition.name, "github_create_issue")
	testing.expect_value(test, definition.description, "Create one issue.")
	testing.expect_value(test, definition.input_schema, `{"type":"object"}`)
	testing.expect(test, definition.execute == tool_mcp_execute, "every adapted tool shares one executor")
	testing.expect_value(test, definition.timeout, 5 * time.Second)
	testing.expect(test, definition.backend == rawptr(&backend), "the binding is borrowed, not copied")
	testing.expect_value(test, definition.hints.read_only, Tool_Hint_Value.Yes)
	testing.expect_value(test, definition.hints.destructive, Tool_Hint_Value.No)
	// An annotation the server left out stays unknown rather than becoming "no".
	testing.expect_value(test, definition.hints.idempotent, Tool_Hint_Value.Unknown)
	testing.expect_value(test, definition.hints.open_world, Tool_Hint_Value.Yes)
}

// A tool whose arguments the server validates has its integer fields repaired from its own
// schema, and every other field travels exactly as it was sent.
@(test)
test_mcp_integer_fields_are_repaired_from_the_schema :: proc(test: ^testing.T) {
	registry, registry_error := tool_registry_make()
	if !testing.expect_value(test, registry_error.kind, Tool_Registry_Error_Kind.None) { return }
	defer tool_registry_destroy(&registry)
	schema := `{"type":"object","properties":{"count":{"type":"integer"},"page":{"type":["integer","null"]},"label":{"type":"string"},"either":{"type":["integer","string"]}}}`
	tool := mcp.Tool {
		name         = "search",
		description  = "Search.",
		input_schema = schema,
	}
	backend: MCP_Tool_Backend
	added := tool_registry_add(&registry, mcp_tool_definition("remote_search", tool, &backend, 0))
	if !testing.expect_value(test, added.kind, Tool_Registry_Error_Kind.None) { return }
	definition, found := tool_registry_find(&registry, "remote_search")
	if !testing.expect(test, found, "the tool is registered") { return }
	testing.expect_value(test, len(definition.integer_fields), 2)

	arguments := tool_arguments_prepare(`{"count":"7","page":3.0,"label":"12","either":"5"}`)
	defer tool_arguments_destroy(&arguments)
	tool_context := Tool_Context {
		allocator = context.allocator,
	}
	_, decode_error := tool_args_decode(&tool_context, definition^, arguments.value.(json.Object))
	testing.expect_value(test, decode_error, nil)
	testing.expect_value(test, tool_context.repairs, Tool_Repairs{.Integer_From_String, .Integer_From_Float})
	object := arguments.value.(json.Object)
	testing.expect_value(test, object["count"].(json.Integer), 7)
	testing.expect_value(test, object["page"].(json.Integer), 3)
	testing.expect_value(test, string(object["label"].(json.String)), "12")
	testing.expect_value(test, string(object["either"].(json.String)), "5")
}

// The only question that decides an outcome is whether the call can have happened.
@(private)
MCP_Failure_Case :: struct {
	failure: mcp.Error,
	outcome: journal.Tool_Outcome,
}

@(test)
test_mcp_failures_map_by_delivery :: proc(test: ^testing.T) {
	cases := []MCP_Failure_Case {
		{{kind = .Cancelled}, .Cancelled},
		{{kind = .Timed_Out}, .Timed_Out},
		{{kind = .Spawn_Failed}, .Unavailable},
		{{kind = .Version_Unsupported}, .Unavailable},
		{{kind = .Capability_Missing}, .Unavailable},
		{{kind = .Protocol_Violation}, .Tool_Failed},
		// Never written, so it cannot have happened.
		{{kind = .Write_Failed, delivery = .Not_Delivered}, .Transport_Failed},
		// Written, so it may have.
		{{kind = .Server_Exited, delivery = .Delivered}, .Unknown},
		{{kind = .End_Of_Stream, delivery = .Delivered}, .Unknown},
		{{kind = .Read_Failed, delivery = .Delivered}, .Unknown},
		{{kind = .Malformed_Message, delivery = .Delivered}, .Unknown},
	}
	for item in cases {
		outcome, reason := tool_mcp_outcome(item.failure)
		testing.expectf(test, outcome == item.outcome, "%v should map to %v, got %v", item.failure.kind, item.outcome, outcome)
		testing.expectf(test, reason != "", "%v should say why in one line", item.failure.kind)
	}
}

@(test)
test_mcp_result_shows_text_and_reports_what_it_omits :: proc(test: ^testing.T) {
	tool_context := mcp_test_context()
	call := mcp.Call_Result {
		allocator       = context.allocator,
		content         = make([dynamic]mcp.Content, 0, 2, context.allocator),
		structured_json = strings.clone(`{"number":12}`, context.allocator),
	}
	defer mcp.call_result_destroy(&call, context.allocator)
	append(&call.content, mcp_test_content(.Text, "text", "created issue 12", ""))
	append(&call.content, mcp_test_content(.Image, "image", "", "image/png"))

	result := tool_mcp_call_result(&tool_context, call)
	defer tool_result_destroy(&result)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(result.content, "created issue 12"), "the text reaches the model")
	testing.expect(test, strings.contains(result.content, "image/png"), "an omitted block says what it was")
	testing.expect(test, !strings.contains(result.content, "aGVsbG8"), "the payload is not carried")
	testing.expect(
		test,
		strings.contains(result.content, "structured_content:\n{\"number\":12}"),
		"structured content is spliced in as a value rather than escaped as a string",
	)
}

@(test)
test_mcp_failure_flag_and_truncation_reach_the_model :: proc(test: ^testing.T) {
	tool_context := mcp_test_context()
	failed := mcp.Call_Result {
		allocator = context.allocator,
		is_error  = true,
		content   = make([dynamic]mcp.Content, 0, 1, context.allocator),
	}
	defer mcp.call_result_destroy(&failed, context.allocator)
	append(&failed.content, mcp_test_content(.Text, "text", "no such repo", ""))

	result := tool_mcp_call_result(&tool_context, failed)
	defer tool_result_destroy(&result)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Tool_Failed)
}

// No sampling, elicitation, or roots capability is declared, so a server asking for
// input is asking for something this harness does not do.
@(test)
test_mcp_input_required_is_a_failure_that_says_so :: proc(test: ^testing.T) {
	tool_context := mcp_test_context()
	call := mcp.Call_Result {
		allocator      = context.allocator,
		input_required = true,
		request_state  = strings.clone("opaque", context.allocator),
		input_requests = strings.clone(`{"q1":{"method":"elicitation/create"}}`, context.allocator),
	}
	defer mcp.call_result_destroy(&call, context.allocator)

	result := tool_mcp_call_result(&tool_context, call)
	defer tool_result_destroy(&result)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Tool_Failed)
	testing.expect(test, strings.contains(result.content, "cannot supply"), "the message says what happened")
	testing.expect(test, strings.contains(result.content, "elicitation/create"), "the request is described for the reader")
}
