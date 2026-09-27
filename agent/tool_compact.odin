package agent


// context_compact lets the agent ask for a checkpoint at a boundary it chooses.
// It records the same intent the automatic path and /compact record, and returns
// immediately: the summary is produced in the background and installed at the next
// boundary, so the caller is never interrupted. A caller that wants the shorter
// context now does not get it here.

TOOL_COMPACT_NAME :: "context_compact"

TOOL_COMPACT_DESCRIPTION :: "Record the conversation up to this point as a checkpoint and continue from a shorter context. The summary is produced in the background, so this returns immediately and the current context keeps working until the checkpoint is installed at the next boundary. Call this when one piece of work is finished and the next is about to start."

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
