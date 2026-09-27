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

// Selection_Changed is the payload of `selection.changed`: the model selection
// now in effect. provider and model are catalog ids, and effort is the
// provider's own level name, empty for the provider's default.
Selection_Changed :: struct {
	v:        int,
	provider: string,
	model:    string,
	effort:   string,
}

// Branch_Created is the payload of `branch.created`: the node the branch forks
// from, 0 for the initial branch of a session.
Branch_Created :: struct {
	v:         int,
	base_node: Node_Id,
}

// Branch_Selected is the payload of `branch.selected`. The branch column of the
// record names the branch it makes active.
Branch_Selected :: struct {
	v: int,
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

// Turn_Started is the payload of `turn.started`. instructions is the hex
// SHA-256 digest of the instruction artifact the turn runs with, and effort is
// the provider's own level name, empty for the provider's default.
Turn_Started :: struct {
	v:            int,
	instructions: string,
	model:        string,
	effort:       string,
}

// Request_Purpose is what a sent request was for.
Request_Purpose :: enum u8 {
	Response,
	Compaction,
}

REQUEST_PURPOSE_NAMES := [Request_Purpose]string {
	.Response   = "response",
	.Compaction = "compaction",
}

// request_purpose_from_name reads a stored purpose name back.
request_purpose_from_name :: proc(name: string) -> (Request_Purpose, bool) {
	for candidate in Request_Purpose {
		if REQUEST_PURPOSE_NAMES[candidate] == name { return candidate, true }
	}
	return {}, false
}

// Request_Sent is the payload of `request.sent`, the barrier written before a
// provider send.
Request_Sent :: struct {
	v:               int,
	purpose:         string, // REQUEST_PURPOSE_NAMES
	api:             string,
	model_requested: string,
}

// Response_Finish is why the endpoint stopped generating.
Response_Finish :: enum u8 {
	Unknown,
	Stop,
	Length,
	Content_Filter,
	Tool_Call,
}

RESPONSE_FINISH_NAMES := [Response_Finish]string {
	.Unknown        = "unknown",
	.Stop           = "stop",
	.Length         = "length",
	.Content_Filter = "content_filter",
	.Tool_Call      = "tool_call",
}

// response_finish_from_name reads a stored finish name back.
response_finish_from_name :: proc(name: string) -> (Response_Finish, bool) {
	for candidate in Response_Finish {
		if RESPONSE_FINISH_NAMES[candidate] == name { return candidate, true }
	}
	return {}, false
}

// Response_Committed is the payload of `response.committed`. A token field is
// absent when the provider did not report it, which is not the same as zero.
Response_Committed :: struct {
	v:                  int,
	model_resolved:     string,
	finish:             string, // RESPONSE_FINISH_NAMES
	input_tokens:       Maybe(i64),
	output_tokens:      Maybe(i64),
	cache_read_tokens:  Maybe(i64),
	cache_write_tokens: Maybe(i64),
}

// Response_Rejected is the payload of `response.rejected`: a response the
// harness refused, and why.
Response_Rejected :: struct {
	v:      int,
	detail: string,
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

// Tool_Proposed is the payload of `tool.proposed`: one call the model asked
// for. The body is the argument document exactly as the model sent it.
Tool_Proposed :: struct {
	v:           int,
	provider_id: string,
	item_id:     string,
	name:        string,
}

// Tool_Admitted is the payload of `tool.admitted`, the barrier written before
// the call runs: the tool that will run it and the repairs admission applied.
// The body is the argument document the tool runs with.
Tool_Admitted :: struct {
	v:       int,
	tool:    string,
	repairs: []string,
}

// Tool_Completed is the payload of `tool.completed`: the outcome of one call,
// with the evidence that settled it.
Tool_Completed :: struct {
	v:       int,
	outcome: string, // TOOL_OUTCOME_NAMES
	detail:  string,
	origin:  string, // where the result came from; a free text name
}

// Call_Completed is the payload of `lua.completed`, `task.completed`, and
// `subagent.completed`. One delegated execution of any of those kinds ends the
// same way, with an outcome and the detail behind it, so they share one struct.
Call_Completed :: struct {
	v:       int,
	outcome: string, // TOOL_OUTCOME_NAMES
	detail:  string,
}

// User_Origin is where a User node's text came from: the person, steering that
// arrived during a turn, the harness itself, or a delegated agent.
User_Origin :: enum u8 {
	Prompt,
	Steering,
	Harness,
	Agent,
}

USER_ORIGIN_NAMES := [User_Origin]string {
	.Prompt   = "prompt",
	.Steering = "steering",
	.Harness  = "harness",
	.Agent    = "agent",
}

// user_origin_from_name reads a stored origin name back.
user_origin_from_name :: proc(name: string) -> (User_Origin, bool) {
	for candidate in User_Origin {
		if USER_ORIGIN_NAMES[candidate] == name { return candidate, true }
	}
	return {}, false
}

// User is the payload of a User node. The body is the text the model is shown.
User :: struct {
	v:      int,
	origin: string, // USER_ORIGIN_NAMES
}

// Reasoning_Item is one reasoning artifact a provider returned, kept so the
// response can be replayed. id names it and encrypted holds its opaque bytes.
Reasoning_Item :: struct {
	id:        string,
	encrypted: string,
}

// Assistant is the payload of an Assistant node. The body is the visible text.
// partial marks text kept from a cancelled or failed response.
Assistant :: struct {
	v:         int,
	request:   Request_Id,
	partial:   bool,
	reasoning: []Reasoning_Item,
}

// Notice is the payload of a Notice node: harness feedback for a response or a
// call it refused. The body is the text the model reads.
Notice :: struct {
	v: int,
}

// Checkpoint is the payload of a Checkpoint node: the request whose response
// produced the summary in the body. The node's covers names the last node the
// summary replaces.
Checkpoint :: struct {
	v:       int,
	request: Request_Id,
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
