package journal

// A payload is the JSON `data` of one record or node. Each begins with its
// version `v`, which an append sets to PAYLOAD_VERSION when left zero. Enums are
// stored as the stable names of their tables; read them back with enum_from_name.
PAYLOAD_VERSION :: 1

Session_Role :: enum u8 {
	Main,
	Subagent,
}

SESSION_ROLE_NAMES := [Session_Role]string {
	.Main     = "main",
	.Subagent = "subagent",
}

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

// Tool_Outcome is what a call produced. Unknown is the zero value, so an
// outcome that was never observed never reads as a success.
Tool_Outcome :: enum u8 {
	Unknown,
	Success,
	Tool_Failed,
	Invalid_Arguments,
	Denied,
	Unavailable,
	Not_Executed,
	Transport_Failed,
	Cancelled,
	Timed_Out,
}

TOOL_OUTCOME_NAMES := [Tool_Outcome]string {
	.Unknown           = "unknown",
	.Success           = "success",
	.Tool_Failed       = "tool_failed",
	.Invalid_Arguments = "invalid_arguments",
	.Denied            = "denied",
	.Unavailable       = "unavailable",
	.Not_Executed      = "not_executed",
	.Transport_Failed  = "transport_failed",
	.Cancelled         = "cancelled",
	.Timed_Out         = "timed_out",
}

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

Request_Purpose :: enum u8 {
	Response,
	Compaction,
}

REQUEST_PURPOSE_NAMES := [Request_Purpose]string {
	.Response   = "response",
	.Compaction = "compaction",
}

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

// Completion ends a unit of work: outcome is a TURN_OUTCOME_NAMES name for a
// turn and a TOOL_OUTCOME_NAMES name for a call, Lua run, Task, or subagent.
Completion :: struct {
	v:       int,
	outcome: string,
	detail:  string,
}

Turn_Completed :: Completion
Tool_Completed :: Completion
Call_Completed :: Completion // lua.completed, task.completed, subagent.completed

// Detail carries only an explanation: request.interrupted and response.rejected.
Detail :: struct {
	v:      int,
	detail: string,
}

Request_Interrupted :: Detail
Response_Rejected :: Detail

Session_Created :: struct {
	v:              int,
	workspace:      string,
	role:           string, // SESSION_ROLE_NAMES
	parent_session: string, // hex, "" for a main session
	parent_call:    Call_Id,
}

Session_Titled :: struct {
	v:     int,
	title: string,
}

// Session_Recovered counts what recover recorded.
Session_Recovered :: struct {
	v:        int,
	turns:    int,
	requests: int,
	calls:    int,
	results:  int,
}

// Selection_Changed has no session for the process-wide default. effort is the
// provider's own level name, "" for its default.
Selection_Changed :: struct {
	v:        int,
	provider: string,
	model:    string,
	effort:   string,
}

Branch_Created :: struct {
	v:         int,
	base_node: Node_Id,
}

// Branch_Selected names the branch in the record's branch column.
Branch_Selected :: struct {
	v: int,
}

Node_Committed :: struct {
	v:    int,
	kind: string, // NODE_KIND_NAMES
}

// Turn_Started names the instruction artifact by hex digest.
Turn_Started :: struct {
	v:            int,
	instructions: string,
	model:        string,
	effort:       string,
}

Request_Sent :: struct {
	v:               int,
	purpose:         string, // REQUEST_PURPOSE_NAMES
	api:             string,
	model_requested: string,
}

// Response_Committed carries the endpoint's native output items in the body. A
// token count the provider did not report is null, never zero.
Response_Committed :: struct {
	v:                  int,
	model_resolved:     string,
	finish:             string, // RESPONSE_FINISH_NAMES
	input_tokens:       Maybe(i64),
	output_tokens:      Maybe(i64),
	cache_read_tokens:  Maybe(i64),
	cache_write_tokens: Maybe(i64),
}

// Tool_Proposed carries the arguments exactly as the model sent them in the body.
Tool_Proposed :: struct {
	v:           int,
	provider_id: string,
	item_id:     string,
	name:        string,
}

// Tool_Admitted carries the arguments the tool runs with in the body.
Tool_Admitted :: struct {
	v:       int,
	tool:    string,
	repairs: []string,
}

// User carries the text in the node body.
User :: struct {
	v:      int,
	origin: string, // USER_ORIGIN_NAMES
}

Reasoning_Item :: struct {
	id:        string,
	encrypted: string,
}

// Assistant carries the visible text in the node body. partial marks text kept
// from a cancelled or failed response.
Assistant :: struct {
	v:         int,
	request:   Request_Id,
	partial:   bool,
	reasoning: []Reasoning_Item,
}

// Notice carries the feedback text in the node body.
Notice :: struct {
	v: int,
}

// Checkpoint carries the summary in the node body; the node's covers names the
// last node it replaces.
Checkpoint :: struct {
	v:       int,
	request: Request_Id,
}

// Results lists the root calls it answers in proposal order.
Results :: struct {
	v:     int,
	calls: []Call_Id,
}
