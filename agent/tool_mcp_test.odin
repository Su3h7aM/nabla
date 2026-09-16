#+test
package agent

import "core:strings"
import "core:testing"
import "core:time"

import "nabla:agent/session"
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
test_mcp_definition_carries_the_alias_schema_and_hints :: proc(t: ^testing.T) {
	tool := mcp.Tool {
		name = "issues.create",
		description = "Create one issue.",
		input_schema = `{"type":"object"}`,
		annotations = {read_only = .Yes, destructive = .No, idempotent = .Unknown, open_world = .Yes},
	}
	backend: MCP_Tool_Backend
	definition := mcp_tool_definition("github.create_issue", tool, &backend, Tool_Timeout_Policy{default = 5 * time.Second, maximum = time.Minute})

	// The alias is what the model is advertised, and the remote name travels in the
	// binding: the two are deliberately not the same string.
	testing.expect_value(t, definition.name, "github.create_issue")
	testing.expect_value(t, definition.description, "Create one issue.")
	testing.expect_value(t, definition.input_schema, `{"type":"object"}`)
	testing.expect(t, definition.execute == tool_mcp_execute, "every adapted tool shares one executor")
	testing.expect_value(t, definition.timeouts.default, 5 * time.Second)
	testing.expect(t, definition.backend == rawptr(&backend), "the binding is borrowed, not copied")
	testing.expect_value(t, definition.hints.read_only, Tool_Hint_Value.Yes)
	testing.expect_value(t, definition.hints.destructive, Tool_Hint_Value.No)
	// An annotation the server left out stays unknown rather than becoming "no".
	testing.expect_value(t, definition.hints.idempotent, Tool_Hint_Value.Unknown)
	testing.expect_value(t, definition.hints.open_world, Tool_Hint_Value.Yes)
}

// The only question that decides an outcome is whether the call can have happened.
@(private)
Mcp_Failure_Case :: struct {
	err:     mcp.Error,
	outcome: session.Tool_Outcome,
}

@(test)
test_mcp_failures_map_by_delivery :: proc(t: ^testing.T) {
	cases := []Mcp_Failure_Case {
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
		outcome, reason := tool_mcp_outcome(item.err)
		testing.expectf(t, outcome == item.outcome, "%v should map to %v, got %v", item.err.kind, item.outcome, outcome)
		testing.expectf(t, reason != "", "%v should say why in one line", item.err.kind)
	}
}

@(test)
test_mcp_result_shows_text_and_reports_what_it_omits :: proc(t: ^testing.T) {
	ctx := mcp_test_context()
	call := mcp.Call_Result {
		allocator       = context.allocator,
		content         = make([dynamic]mcp.Content, 0, 2, context.allocator),
		structured_json = strings.clone(`{"number":12}`, context.allocator),
	}
	defer mcp.call_result_destroy(&call, context.allocator)
	append(&call.content, mcp_test_content(.Text, "text", "created issue 12", ""))
	append(&call.content, mcp_test_content(.Image, "image", "", "image/png"))

	result := tool_mcp_call_result(&ctx, call)
	defer tool_result_destroy(&result)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(result.content, "created issue 12"), "the text reaches the model")
	testing.expect(t, strings.contains(result.content, "image/png"), "an omitted block says what it was")
	testing.expect(t, !strings.contains(result.content, "aGVsbG8"), "the payload is not carried")
	testing.expect(
		t,
		strings.contains(result.content, `"structured_content":{"number":12}`),
		"structured content is spliced in as a value rather than escaped as a string",
	)
}

@(test)
test_mcp_failure_flag_and_truncation_reach_the_model :: proc(t: ^testing.T) {
	ctx := mcp_test_context()
	failed := mcp.Call_Result {
		allocator = context.allocator,
		is_error  = true,
		content   = make([dynamic]mcp.Content, 0, 1, context.allocator),
	}
	defer mcp.call_result_destroy(&failed, context.allocator)
	append(&failed.content, mcp_test_content(.Text, "text", "no such repo", ""))

	result := tool_mcp_call_result(&ctx, failed)
	defer tool_result_destroy(&result)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Tool_Failed)

	truncated := mcp.Call_Result {
		allocator = context.allocator,
		truncated = true,
		content   = make([dynamic]mcp.Content, 0, context.allocator),
	}
	defer mcp.call_result_destroy(&truncated, context.allocator)
	message_result := tool_mcp_call_result(&ctx, truncated)
	defer tool_result_destroy(&message_result)
	testing.expect(t, strings.contains(message_result.content, "longer than the harness shows"), "truncation is reported")
}

// No sampling, elicitation, or roots capability is declared, so a server asking for
// input is asking for something this harness does not do.
@(test)
test_mcp_input_required_is_a_failure_that_says_so :: proc(t: ^testing.T) {
	ctx := mcp_test_context()
	call := mcp.Call_Result {
		allocator      = context.allocator,
		input_required = true,
		request_state  = strings.clone("opaque", context.allocator),
		input_requests = strings.clone(`{"q1":{"method":"elicitation/create"}}`, context.allocator),
	}
	defer mcp.call_result_destroy(&call, context.allocator)

	result := tool_mcp_call_result(&ctx, call)
	defer tool_result_destroy(&result)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Tool_Failed)
	testing.expect(t, strings.contains(result.content, "cannot supply"), "the message says what happened")
	testing.expect(t, strings.contains(result.content, "elicitation/create"), "the request is described for the reader")
}
