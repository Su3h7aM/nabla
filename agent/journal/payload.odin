package journal

// A payload is the JSON `data` of one record or one node. Every payload struct
// begins with `v`, its version, and append_record and append_node set that field
// to PAYLOAD_VERSION when the caller left it zero, so a payload starts as the
// zero value plus the fields the caller filled in.
//
// An enum crosses this boundary as its stable name text, because the stored
// JSON has to stay readable and stable; the enumerated name table next to each
// enum is what produces and reads that text.
PAYLOAD_VERSION :: 1

// Session_Role is whether a session runs for a person or for a caller that
// delegated to it. It is the `role` column of `sessions`.
Session_Role :: enum u8 {
	Main,
	Subagent,
}

SESSION_ROLE_NAMES := [Session_Role]string {
	.Main     = "main",
	.Subagent = "subagent",
}

// session_role_from_name reads a stored role name back.
session_role_from_name :: proc(name: string) -> (Session_Role, bool) {
	for candidate in Session_Role {
		if SESSION_ROLE_NAMES[candidate] == name { return candidate, true }
	}
	return {}, false
}

// Session_Created is the payload of `session.created`: the facts the session's
// row holds, so a reader of `records` alone can see what was created.
Session_Created :: struct {
	v:              int,
	workspace:      string,
	role:           string, // SESSION_ROLE_NAMES
	parent_session: string, // hex, "" for a main session
	parent_call:    Call_Id,
}

// Session_Titled is the payload of `session.titled`. The latest one names the
// session in a listing.
Session_Titled :: struct {
	v:     int,
	title: string,
}

// Branch_Created is the payload of `branch.created`: the node the branch forks
// from, 0 for the initial branch of a session.
Branch_Created :: struct {
	v:         int,
	base_node: Node_Id,
}

// Node_Committed is the payload of the `node.committed` record that stamps a
// node row with its seq.
Node_Committed :: struct {
	v:    int,
	kind: string, // NODE_KIND_NAMES
}

// Turn_Outcome is how a turn ended.
Turn_Outcome :: enum u8 {
	Completed,
	Failed,
	Cancelled,
	Interrupted,
}

TURN_OUTCOME_NAMES := [Turn_Outcome]string {
	.Completed   = "completed",
	.Failed      = "failed",
	.Cancelled   = "cancelled",
	.Interrupted = "interrupted",
}

// Turn_Completed is the payload of `turn.completed`.
Turn_Completed :: struct {
	v:       int,
	outcome: string, // TURN_OUTCOME_NAMES
	detail:  string,
}

// Request_Interrupted is the payload of `request.interrupted`: a request that
// was sent and whose outcome is unknown. It is never resent.
Request_Interrupted :: struct {
	v:      int,
	detail: string,
}

// Tool_Outcome is what a tool call produced.
Tool_Outcome :: enum u8 {
	Success,
	Tool_Failed,
	Invalid_Arguments,
	Denied,
	Unavailable,
	Not_Executed,
	Transport_Failed,
	Cancelled,
	Timed_Out,
	Unknown,
}

TOOL_OUTCOME_NAMES := [Tool_Outcome]string {
	.Success           = "success",
	.Tool_Failed       = "tool_failed",
	.Invalid_Arguments = "invalid_arguments",
	.Denied            = "denied",
	.Unavailable       = "unavailable",
	.Not_Executed      = "not_executed",
	.Transport_Failed  = "transport_failed",
	.Cancelled         = "cancelled",
	.Timed_Out         = "timed_out",
	.Unknown           = "unknown",
}

// Tool_Completed is the payload of `tool.completed`: the outcome of one call,
// with the evidence that settled it.
Tool_Completed :: struct {
	v:       int,
	outcome: string, // TOOL_OUTCOME_NAMES
	detail:  string,
}

// Call_Completed is the payload of `lua.completed`, `task.completed`, and
// `subagent.completed`. One delegated execution of any of those kinds ends the
// same way, with an outcome and the detail behind it, so they share one struct.
Call_Completed :: struct {
	v:       int,
	outcome: string, // TOOL_OUTCOME_NAMES
	detail:  string,
}

// Session_Recovered is the payload of `session.recovered`: how much of section
// 9's table recovery had to record, and also what recover returns.
Session_Recovered :: struct {
	v:        int,
	turns:    int,
	requests: int,
	tools:    int,
	effects:  int,
	results:  int,
}

// Results is the payload of a `Results` node: the call ids it answers, in the
// order the preceding Assistant node proposed them.
Results :: struct {
	v:     int,
	calls: []Call_Id,
}
