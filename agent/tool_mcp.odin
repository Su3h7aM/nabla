package agent

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import "nabla:agent/session"
import "nabla:ai"
import "nabla:mcp"

// MCP_Tool_Backend binds one adapted definition to the server and remote tool it
// came from. client and server_id borrow the runtime generation; remote_name is
// owned by the binding because discovery pages are released after each refresh.
//
// The registry copies the pointer into the definition and the definition into every
// turn that borrows it, so the generation must outlive every registry that holds a
// definition pointing here. See Tool_Definition.backend for the full rule.
MCP_Tool_Backend :: struct {
	client:      ^mcp.Client,
	server_id:   string,
	remote_name: string,
}

// TOOL_MCP_STDERR_EXCERPT bounds how much of a server's own output is repeated in a
// failure message. The transport keeps a larger tail for diagnostics; a message the
// model reads is not the place for all of it.
TOOL_MCP_STDERR_EXCERPT :: 1024

// mcp_tool_definition builds the definition one allowed remote tool becomes. name is
// the advertised alias the user chose, and the returned strings borrow tool, so the
// definition must be registered before tool is released: tool_registry_add clones
// what it keeps.
mcp_tool_definition :: proc(name: string, tool: mcp.Tool, backend: ^MCP_Tool_Backend, timeouts: Tool_Timeout_Policy) -> Tool_Definition {
	return Tool_Definition {
		name = name,
		description = tool.description,
		input_schema = tool.input_schema,
		hints = mcp_tool_hints(tool.annotations),
		timeouts = timeouts,
		execute = tool_mcp_execute,
		backend = backend,
	}
}

// mcp_tool_hints maps the server's annotations onto the harness vocabulary. The
// protocol's defaults are not applied: an annotation the server left out stays
// unknown, because reading absence as "no" would invent a fact it never stated.
@(private)
mcp_tool_hints :: proc(annotations: mcp.Tool_Annotations) -> Tool_Behavior_Hints {
	return {
		read_only = mcp_hint(annotations.read_only),
		destructive = mcp_hint(annotations.destructive),
		idempotent = mcp_hint(annotations.idempotent),
		open_world = mcp_hint(annotations.open_world),
	}
}

@(private)
mcp_hint :: proc(hint: mcp.Hint) -> Tool_Hint_Value {
	switch hint {
	case .Unknown:
		return .Unknown
	case .No:
		return .No
	case .Yes:
		return .Yes
	}
	return .Unknown
}

// tool_mcp_execute runs one adapted call. It is the only executor every MCP
// definition shares, which is what lets a definition carry a backend binding instead
// of a procedure of its own.
tool_mcp_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	// The arguments are already admitted and the object is already parsed; what
	// travels is the admitted text, so the peer and the dispatch record agree.
	_ = arguments
	backend := cast(^MCP_Tool_Backend)ctx.backend
	if backend == nil || backend.client == nil {
		return tool_result_failure(ctx, .Unavailable, "the server for this tool is not configured", "unavailable")
	}
	if ctx.arguments_json == "" {
		// Dispatch always sets the admitted text for a call that runs, so this is a
		// harness defect rather than anything the model did.
		return tool_result_failure(ctx, .Tool_Failed, "the call arguments were not available", "no arguments")
	}
	if !mcp.client_running(backend.client) {
		return tool_result_failure(ctx, .Unavailable, fmt.tprintf("the server %s is not running", backend.server_id), "server down")
	}

	call, err := mcp.client_tools_call(backend.client, backend.remote_name, ctx.arguments_json, tool_mcp_control(ctx), ctx.allocator)
	defer mcp.error_destroy(&err, ctx.allocator)
	defer mcp.call_result_destroy(&call, ctx.allocator)
	if err.kind != .None { return tool_mcp_error_result(ctx, backend, err) }
	return tool_mcp_call_result(ctx, call)
}

// tool_mcp_control derives the call's bounds from the turn control and the
// definition's own timeout policy. The turn deadline has already reached
// ctx.control, so the effective bound is the earliest applicable one.
@(private)
tool_mcp_control :: proc(ctx: ^Tool_Context) -> mcp.Control {
	control := mcp.Control {
		user_data   = ctx.control.interrupt,
		interrupted = tool_mcp_interrupted,
	}
	// An adapted tool exposes no timeout argument, so there is nothing for the model
	// to request and nothing to clamp: the default is the bound, with the maximum as
	// a ceiling in case the configuration states them the wrong way round.
	timeout := ctx.timeouts.default
	if ctx.timeouts.maximum > 0 && (timeout <= 0 || ctx.timeouts.maximum < timeout) { timeout = ctx.timeouts.maximum }
	deadline := ctx.control.deadline
	if timeout > 0 { deadline = tool_mcp_deadline_earlier(deadline, ai.deadline_in(timeout)) }
	if deadline.active {
		control.deadline_at = deadline.at
		control.has_deadline = true
	}
	return control
}

@(private)
tool_mcp_interrupted :: proc(user_data: rawptr) -> bool {
	return ai.interrupt_requested(cast(^ai.Interrupt)user_data)
}

@(private)
tool_mcp_deadline_earlier :: proc(a, b: ai.Deadline) -> ai.Deadline {
	if !a.active { return b }
	if !b.active { return a }
	a_remaining, _ := ai.deadline_remaining(a)
	b_remaining, _ := ai.deadline_remaining(b)
	return a if a_remaining <= b_remaining else b
}

// --- results -----------------------------------------------------------------

// Tool_MCP_Data is what an MCP result looks like to the model. Text blocks carry
// their text; every other block carries a line saying what was returned and why it
// is not shown, because a binary payload would consume the context to no purpose.
Tool_MCP_Data :: struct {
	content:            []Tool_MCP_Block `json:"content"`,
	structured_content: string `json:"structured_content"`,
	truncated:          bool `json:"truncated"`,
}

Tool_MCP_Block :: struct {
	type:   string `json:"type"`,
	text:   string `json:"text"`,
	detail: string `json:"detail"`,
}

@(private)
tool_mcp_call_result :: proc(ctx: ^Tool_Context, call: mcp.Call_Result) -> Tool_Result {
	if call.input_required {
		// No sampling, elicitation, or roots capability is declared, so a server
		// asking for input is asking for something this harness does not do. The
		// request is reported rather than answered, and the call is not retried.
		message := "the server asked for more input, which this harness cannot supply"
		if call.input_requests != "" {
			message = fmt.tprintf("%s: %s", message, call.input_requests)
		}
		return tool_result_failure(ctx, .Tool_Failed, message, "input required")
	}

	blocks := make([dynamic]Tool_MCP_Block, 0, len(call.content), ctx.allocator)
	defer delete(blocks)
	for content in call.content {
		block := Tool_MCP_Block {
			type = content.type_name,
		}
		if content.kind == .Text {
			block.text = content.text
		} else {
			block.detail = tool_mcp_omitted_detail(content, context.temp_allocator)
		}
		append(&blocks, block)
	}

	outcome := session.Tool_Outcome.Success
	reason := "completed"
	message := ""
	if call.is_error {
		outcome = .Tool_Failed
		reason = "server reported a failure"
		message = "the tool reported a failure"
	} else if call.truncated {
		message = "the result was longer than the harness shows"
	}

	data := Tool_MCP_Data {
		content   = blocks[:],
		truncated = call.truncated,
	}
	// The structured half is spliced in as the JSON value the server sent rather
	// than as a string, so a model reading it sees an object.
	value := tool_mcp_data_json(ctx, data, call.structured_json)
	defer json.destroy_value(json.Value(value), ctx.allocator)
	return tool_result_of(ctx, outcome, message, value, reason)
}

// tool_mcp_omitted_detail says what a block the harness does not show was. The type
// and the MIME type are the parts a reader can act on.
@(private)
tool_mcp_omitted_detail :: proc(content: mcp.Content, allocator := context.allocator) -> string {
	switch content.kind {
	case .Image, .Audio:
		if content.mime_type != "" { return fmt.aprintf("%s is not shown", content.mime_type, allocator = allocator) }
		return fmt.aprintf("%s content is not shown", content.type_name, allocator = allocator)
	case .Resource_Link:
		if content.mime_type != "" {
			return fmt.aprintf("link to %s (%s), not fetched", content.uri, content.mime_type, allocator = allocator)
		}
		return fmt.aprintf("link to %s, not fetched", content.uri, allocator = allocator)
	case .Embedded_Resource:
		return fmt.aprintf("embedded resource %s is not expanded", content.uri, allocator = allocator)
	case .Text, .Unknown:
		return fmt.aprintf("%s content is not shown", content.type_name, allocator = allocator)
	}
	return ""
}

// tool_mcp_data_json builds the result data as a JSON object, so the structured half
// can be spliced in as the value the server sent instead of as an escaped string.
@(private)
tool_mcp_data_json :: proc(ctx: ^Tool_Context, data: Tool_MCP_Data, structured_json: string) -> json.Object {
	object := make(json.Object, 3, ctx.allocator)
	blocks := make(json.Array, 0, len(data.content), ctx.allocator)
	for block in data.content {
		entry := make(json.Object, 3, ctx.allocator)
		entry[strings.clone("type", ctx.allocator)] = json.String(strings.clone(block.type, ctx.allocator))
		if block.text != "" {
			entry[strings.clone("text", ctx.allocator)] = json.String(strings.clone(block.text, ctx.allocator))
		}
		if block.detail != "" {
			entry[strings.clone("detail", ctx.allocator)] = json.String(strings.clone(block.detail, ctx.allocator))
		}
		append(&blocks, json.Value(entry))
	}
	object[strings.clone("content", ctx.allocator)] = json.Value(blocks)
	object[strings.clone("truncated", ctx.allocator)] = json.Boolean(data.truncated)
	if structured_json != "" {
		if value, parse_err := json.parse_string(structured_json, .JSON, true, ctx.allocator); parse_err == nil {
			object[strings.clone("structured_content", ctx.allocator)] = value
		}
	}
	return object
}

// tool_mcp_error_result reports a call that delivered no usable result.
@(private)
tool_mcp_error_result :: proc(ctx: ^Tool_Context, backend: ^MCP_Tool_Backend, err: mcp.Error) -> Tool_Result {
	outcome, reason := tool_mcp_outcome(err)
	message := mcp.error_text(err, context.temp_allocator)
	if err.stderr_tail != "" {
		excerpt := err.stderr_tail
		if len(excerpt) > TOOL_MCP_STDERR_EXCERPT {
			excerpt = excerpt[len(excerpt) - TOOL_MCP_STDERR_EXCERPT:]
		}
		message = fmt.tprintf("%s; the server's last output was: %s", message, excerpt)
	}
	if outcome == .Unavailable || outcome == .Transport_Failed {
		message = fmt.tprintf("%s (server %s)", message, backend.server_id)
	}
	return tool_result_failure(ctx, outcome, message, reason)
}

// tool_mcp_outcome maps a transport or protocol failure onto the persisted outcome
// vocabulary. The only question that matters is whether the call can have happened:
// a request that was never written did not, and one whose reply was lost may have.
@(private)
tool_mcp_outcome :: proc(err: mcp.Error) -> (session.Tool_Outcome, string) {
	switch err.kind {
	case .Cancelled:
		return .Cancelled, "cancelled"
	case .Timed_Out:
		return .Timed_Out, "timed out"
	case .Spawn_Failed:
		return .Unavailable, "server did not start"
	case .Version_Unsupported, .Capability_Missing:
		return .Unavailable, "server unusable"
	case .Protocol_Violation:
		// A remote JSON-RPC error: the server received the call and refused it.
		return .Tool_Failed, "server reported an error"
	case .Message_Too_Large, .Malformed_Message, .Unexpected_Message, .Out_Of_Memory:
		if mcp.error_delivered(err) { return .Unknown, "outcome unknown" }
		return .Tool_Failed, "the reply could not be used"
	case .Server_Exited, .End_Of_Stream, .Read_Failed, .Write_Failed:
		if mcp.error_delivered(err) { return .Unknown, "outcome unknown" }
		return .Transport_Failed, "not delivered"
	case .None:
		return .Tool_Failed, "failed"
	}
	return .Tool_Failed, "failed"
}
