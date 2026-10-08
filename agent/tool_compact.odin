package agent


// compact asks for a checkpoint while the agent keeps working. It records the
// same intent as the automatic path and /compact, and returns immediately: the summary
// is produced in the background and installed at the next boundary.

TOOL_COMPACT_NAME :: "compact"

TOOL_COMPACT_DESCRIPTION :: "Ask for the conversation so far to be replaced by a summary checkpoint, so later requests carry less context. The harness also does this on its own when the context nears its limit, so call it only at a natural break: one piece of work is finished and the next does not need its details. The call returns at once with state scheduled, already_running, or ready. The summary is written in the background while you keep working with the current context, and it is installed at the next request boundary; steps you take meanwhile stay after the checkpoint. After it is installed, reload any skill whose details you still need."

TOOL_COMPACT_SCHEMA :: `{"type":"object","properties":{},"additionalProperties":false}`

TOOL_COMPACT_DEFINITION :: Tool_Definition {
	name = TOOL_COMPACT_NAME,
	description = TOOL_COMPACT_DESCRIPTION,
	input_schema = TOOL_COMPACT_SCHEMA,
	// Recording an intent changes nothing the model or the user can observe, and
	// asking twice is the same as asking once.
	hints = {read_only = .No, destructive = .No, idempotent = .Yes, open_world = .No},
	// The intent is session control state, which only the owner thread touches.
	placement = .Owner,
	kind = .Compact,
	execute = tool_compact_execute,
}

tool_compact_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	if ctx.compact == nil {
		return tool_result_failure(ctx, .Unavailable, "compaction is not available in this session", "unavailable")
	}
	switch compact_request_intent(ctx.compact, .Agent_Tool, ctx.call) {
	case .Scheduled:
		return tool_result_success(ctx, Compact_Output{state = "scheduled"}, "scheduled")
	case .Already_Scheduled:
		// A summary that is ready is not a summary being made, and a caller told the wrong one
		// waits for something else: an explicit request has already made this candidate install
		// at the next boundary.
		if ctx.compact.state == .Ready {
			return tool_result_success(ctx, Compact_Output{state = "ready"}, "ready")
		}
		return tool_result_success(ctx, Compact_Output{state = "already_running"}, "already running")
	case .Unavailable:
	}
	return tool_result_failure(ctx, .Unavailable, "compaction is not available right now", "unavailable")
}
