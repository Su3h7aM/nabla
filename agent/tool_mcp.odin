package agent

import "base:runtime"
import "core:fmt"
import "core:time"

import "nabla:agent/journal"
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

// mcp_tool_definition builds the definition one allowed remote tool becomes. name is
// the advertised alias the user chose, and the returned strings borrow tool, so the
// definition must be registered before tool is released: tool_registry_add clones
// what it keeps.
mcp_tool_definition :: proc(name: string, tool: mcp.Tool, backend: ^MCP_Tool_Backend, timeout: time.Duration) -> Tool_Definition {
	return Tool_Definition {
		name = name,
		description = tool.description,
		input_schema = tool.input_schema,
		hints = mcp_tool_hints(tool.annotations),
		timeout = timeout,
		kind = .MCP,
		execute = tool_mcp_execute,
		backend = backend,
		lane = backend.client if backend != nil else nil,
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

// tool_mcp_execute runs one adapted call. It is the only executor every MCP definition
// shares, which is what lets a definition carry a backend binding instead of a procedure of
// its own. An MCP server validates its own tool's arguments, so they are not read here: what
// travels to the peer is the admitted text, so the peer and the dispatch record agree.
tool_mcp_execute :: proc(ctx: ^Tool_Context, _: Tool_Args) -> (result: Tool_Result) {
	backend := cast(^MCP_Tool_Backend)ctx.backend
	started := time.tick_now()
	exchange_error: mcp.Error
	delivery := mcp.Delivery_State.Not_Delivered
	defer mcp.error_destroy(&exchange_error, ctx.allocator)
	defer log_mcp_exchange_finished(backend, delivery, exchange_error, result.outcome, time.tick_since(started))
	log_mcp_exchange_started(backend)
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

	call: mcp.Call_Result
	call, exchange_error = mcp.client_tools_call(backend.client, backend.remote_name, ctx.arguments_json, tool_mcp_options(ctx), ctx.allocator)
	defer mcp.call_result_destroy(&call, ctx.allocator)
	if exchange_error.kind != .None {
		delivery = exchange_error.delivery
		return tool_mcp_error_result(ctx, backend, exchange_error)
	}
	delivery = .Delivered
	return tool_mcp_call_result(ctx, call)
}

// tool_mcp_options bounds the call by the definition's timeout, measured from now.
@(private)
tool_mcp_options :: proc(ctx: ^Tool_Context) -> mcp.Operation_Options {
	options := mcp.Operation_Options {
		control = {user_data = ctx.control.interrupt, interrupted = tool_mcp_interrupted, wake = ctx.control.wake},
	}
	if ctx.timeout > 0 {
		options.control.deadline_at = time.tick_add(time.tick_now(), ctx.timeout)
		options.control.has_deadline = true
	}
	return options
}

@(private)
tool_mcp_interrupted :: proc(user_data: rawptr) -> bool {
	return ai.interrupt_requested(cast(^ai.Interrupt)user_data)
}

// --- results -----------------------------------------------------------------

@(private)
tool_mcp_call_result :: proc(ctx: ^Tool_Context, call: mcp.Call_Result) -> Tool_Result {
	// The blocks and their details are built in temp memory and copied into the result
	// before this returns.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
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

	blocks := make([dynamic]MCP_Block, 0, len(call.content), context.temp_allocator)
	for content in call.content {
		block := MCP_Block {
			type = content.type_name,
		}
		if content.kind == .Text {
			block.text = content.text
		} else {
			block.detail = tool_mcp_omitted_detail(content, context.temp_allocator)
		}
		append(&blocks, block)
	}

	outcome := journal.Tool_Outcome.Success
	reason := "completed"
	message := ""
	if call.is_error {
		outcome = .Tool_Failed
		reason = "server reported a failure"
		message = "the tool reported a failure"
	}

	output := MCP_Output {
		content            = blocks[:],
		structured_content = call.structured_json,
	}
	return tool_result_of(ctx, outcome, message, output, reason)
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

// tool_mcp_error_result reports a call that delivered no usable result.
@(private)
tool_mcp_error_result :: proc(ctx: ^Tool_Context, backend: ^MCP_Tool_Backend, err: mcp.Error) -> Tool_Result {
	// The message is assembled in temp memory and cloned into the result.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	outcome, reason := tool_mcp_outcome(err)
	message := mcp.error_text(err, context.temp_allocator)
	if err.stderr_tail != "" {
		message = fmt.tprintf("%s; the server's last output was: %s", message, err.stderr_tail)
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
tool_mcp_outcome :: proc(err: mcp.Error) -> (journal.Tool_Outcome, string) {
	switch err.kind {
	case .Cancelled:
		return .Cancelled, "cancelled"
	case .Timed_Out:
		return .Timed_Out, "timed out"
	case .Spawn_Failed:
		return .Unavailable, "server did not start"
	case .Busy:
		return .Unavailable, "server busy"
	case .Version_Unsupported, .Capability_Missing:
		return .Unavailable, "server unusable"
	case .Protocol_Violation:
		// A remote JSON-RPC error: the server received the call and refused it.
		return .Tool_Failed, "server reported an error"
	case .Malformed_Message, .Unexpected_Message, .Out_Of_Memory:
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
