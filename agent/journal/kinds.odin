package journal

// Record_Kind is the closed set of journal facts. The integer is what `records.kind`
// stores. RECORD_KIND_NAMES is the same fact for a log line and for the
// record_names view. A new kind is a new code at the end and a schema bump,
// because the column's CHECK bound is the last code.
Record_Kind :: enum u8 {
	Run_Started          = 0,
	Run_Finished         = 1,
	Session_Created      = 2,
	Session_Titled       = 3,
	Session_Recovered    = 4,
	Session_Claimed      = 5,
	Session_Released     = 6,
	Session_Environment  = 7,
	Branch_Created       = 8,
	Branch_Selected      = 9,
	User_Input           = 10,
	Node_Committed       = 11,
	Turn_Started         = 12,
	Turn_Completed       = 13,
	Request_Prepared     = 14,
	Request_Admitted     = 15,
	Request_Sent         = 16,
	Response_Committed   = 17,
	Response_Rejected    = 18,
	Request_Interrupted  = 19,
	Retry_Scheduled      = 20,
	Retry_Completed      = 21,
	Tool_Proposed        = 22,
	Tool_Admitted        = 23,
	Tool_Started         = 24,
	Tool_Completed       = 25,
	Lua_Started          = 26,
	Lua_Completed        = 27,
	Task_Started         = 28,
	Task_Completed       = 29,
	Subagent_Started     = 30,
	Subagent_Completed   = 31,
	Compaction_Started   = 32,
	Compaction_Completed = 33,
	Checkpoint_Installed = 34,
	Runtime_Message      = 35,
	Job_Abandoned        = 36,
	Job_Reclaimed        = 37,
	Selection_Changed    = 38,
	Subagent_Message     = 39,
	Selection_Fit        = 40,
	Selection_Applied    = 41,
	Background_Completed = 42,
	User_Command         = 43,
	Command_Applied      = 44,
}

RECORD_KIND_NAMES := [Record_Kind]string {
	.Run_Started          = "run.started",
	.Run_Finished         = "run.finished",
	.Session_Created      = "session.created",
	.Session_Titled       = "session.titled",
	.Session_Recovered    = "session.recovered",
	.Session_Claimed      = "session.claimed",
	.Session_Released     = "session.released",
	.Session_Environment  = "session.environment",
	.Branch_Created       = "branch.created",
	.Branch_Selected      = "branch.selected",
	.User_Input           = "user.input",
	.Node_Committed       = "node.committed",
	.Turn_Started         = "turn.started",
	.Turn_Completed       = "turn.completed",
	.Request_Prepared     = "request.prepared",
	.Request_Admitted     = "request.admitted",
	.Request_Sent         = "request.sent",
	.Response_Committed   = "response.committed",
	.Response_Rejected    = "response.rejected",
	.Request_Interrupted  = "request.interrupted",
	.Retry_Scheduled      = "retry.scheduled",
	.Retry_Completed      = "retry.completed",
	.Tool_Proposed        = "tool.proposed",
	.Tool_Admitted        = "tool.admitted",
	.Tool_Started         = "tool.started",
	.Tool_Completed       = "tool.completed",
	.Lua_Started          = "lua.started",
	.Lua_Completed        = "lua.completed",
	.Task_Started         = "task.started",
	.Task_Completed       = "task.completed",
	.Subagent_Started     = "subagent.started",
	.Subagent_Completed   = "subagent.completed",
	.Compaction_Started   = "compaction.started",
	.Compaction_Completed = "compaction.completed",
	.Checkpoint_Installed = "checkpoint.installed",
	.Runtime_Message      = "runtime.message",
	.Job_Abandoned        = "job.abandoned",
	.Job_Reclaimed        = "job.reclaimed",
	.Selection_Changed    = "selection.changed",
	.Subagent_Message     = "subagent.message",
	.Selection_Fit        = "selection.fit",
	.Selection_Applied    = "selection.applied",
	.Background_Completed = "background.completed",
	.User_Command         = "user.command",
	.Command_Applied      = "command.applied",
}

// Node_Kind is the closed set of committed conversational steps. The integer is
// what `nodes.kind` stores.
Node_Kind :: enum u8 {
	User       = 0,
	Assistant  = 1,
	Results    = 2,
	Context    = 3,
	Notice     = 4,
	Checkpoint = 5,
}

NODE_KIND_NAMES := [Node_Kind]string {
	.User       = "user",
	.Assistant  = "assistant",
	.Results    = "results",
	.Context    = "context",
	.Notice     = "notice",
	.Checkpoint = "checkpoint",
}

// enum_from_name reads a stored stable name back through its name table.
@(require_results)
enum_from_name :: proc(names: [$Enum]string, name: string) -> (Enum, bool) {
	for candidate in Enum {
		if names[candidate] == name { return candidate, true }
	}
	return {}, false
}

#assert(int(min(Record_Kind)) == 0)
#assert(int(max(Record_Kind)) == 44)
#assert(int(min(Node_Kind)) == 0)
#assert(int(max(Node_Kind)) == 5)
