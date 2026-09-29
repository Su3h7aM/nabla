package journal

// payload_decode is generic, so this package never instantiates its use.
@(require) import "core:encoding/json"
import "core:mem"

// A payload is the JSON `data` of one record or node. Each begins with its
// `version`, which an append sets to PAYLOAD_VERSION when left zero. Enums are
// stored as the stable names of their tables; read them back with enum_from_name.
PAYLOAD_VERSION :: 1

// payload_decode reads one supported record or node payload, with strings and slices in
// allocator. Malformed JSON or a missing or unsupported version returns .Corrupt. A failed
// decode may leave partial allocations behind, so allocator is a temp or arena allocator.
// When corruption_journal is given, a corrupt payload also records its session and seq there.
@(require_results)
payload_decode :: proc(
	data: string,
	payload: ^$Payload,
	allocator: mem.Allocator,
	corruption_journal: ^Journal = nil,
	session: Session_Id = {},
	seq: Journal_Seq = 0,
) -> Error {
	payload.version = 0
	if json.unmarshal_string(data, payload, allocator = allocator) != nil || payload.version != PAYLOAD_VERSION {
		if corruption_journal != nil {
			return corrupt(corruption_journal, Journal_Error.Corrupt, session, seq)
		}
		return Journal_Error.Corrupt
	}
	return nil
}

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

// Completion ends a unit of work: outcome is a TOOL_OUTCOME_NAMES name for a
// call, Lua run, Task, or subagent.
Completion :: struct {
	version: int,
	outcome: string,
	detail:  string,
}

Tool_Completed :: Completion
Call_Completed :: Completion // lua.completed, task.completed

// Turn_Completed ends a turn. reason is why its request chain stopped and cause
// what kept the context from fitting, both "" when absent.
Turn_Completed :: struct {
	version: int,
	outcome: string, // TURN_OUTCOME_NAMES
	detail:  string,
	reason:  string,
	cause:   string,
}

Request_Interrupted :: struct {
	version: int,
	detail:  string,
}

// Response_Rejected is why one send produced no usable response: the failure as
// the provider layer classified it, the evidence it kept, and what the harness
// decided. A retry delay the provider did not give is null.
Response_Rejected :: struct {
	version:             int,
	kind:                string,
	failure_class:       string,
	status:              int,
	provider_code:       string,
	provider_request_id: string,
	retry_after_ms:      Maybe(i64),
	retry_directive:     string,
	transport_cause:     string,
	text_exposed:        bool,
	completion_accepted: bool,
	recovery:            string,
	delay_ms:            i64,
	detail:              string,
}

Session_Created :: struct {
	version:        int,
	workspace:      string,
	role:           string, // SESSION_ROLE_NAMES
	parent_session: string, // hex, "" for a main session
	parent_call:    Call_Id,
}

Session_Titled :: struct {
	version: int,
	title:   string,
}

// Session_Recovered counts what recover recorded.
Session_Recovered :: struct {
	version:  int,
	turns:    int,
	requests: int,
	calls:    int,
	results:  int,
}

// Selection_Changed has no session for the process-wide default. effort is the
// provider's own level name, "" for its default.
Selection_Changed :: struct {
	version:  int,
	provider: string,
	model:    string,
	effort:   string,
}

Branch_Created :: struct {
	version:   int,
	base_node: Node_Id,
}

Runtime_Level :: enum u8 {
	Warning,
	Error,
}

RUNTIME_LEVEL_NAMES := [Runtime_Level]string {
	.Warning = "warning",
	.Error   = "error",
}

// Runtime_Message is one process diagnostic. level is a RUNTIME_LEVEL_NAMES entry.
Runtime_Message :: struct {
	version: int,
	level:   string,
	text:    string,
}

// Branch_Selected names the branch in the record's branch column.
Branch_Selected :: struct {
	version: int,
}

Node_Committed :: struct {
	version: int,
	kind:    string, // NODE_KIND_NAMES
}

// Turn_Started names the instruction and manifest artifacts the turn runs with
// by hex digest.
Turn_Started :: struct {
	version:      int,
	instructions: string,
	manifest:     string,
	model:        string,
	effort:       string,
}

Request_Prepared :: struct {
	version:        int,
	purpose:        string, // REQUEST_PURPOSE_NAMES
	api:            string,
	transport:      string, // "http" or "websocket"
	estimate:       int,
	context_window: int,
	messages:       int,
	tools:          int,
	replay_refused: int,
}

Admission_Decision :: enum u8 {
	Fits,
	Refused,
	Unconfigured,
}

ADMISSION_DECISION_NAMES := [Admission_Decision]string {
	.Fits         = "fits",
	.Refused      = "refused",
	.Unconfigured = "unconfigured",
}

// Request_Admitted is whether a request fits its model's window. output is the
// answer bound the request would be sent with; margin is what
// the window keeps back for estimator error.
Request_Admitted :: struct {
	version:             int,
	decision:            string, // ADMISSION_DECISION_NAMES
	estimate:            int,
	context_window:      int,
	margin:              int,
	output:              int,
	instructions_tokens: int,
	tools_tokens:        int,
	conversation_tokens: int,
}

Request_Sent :: struct {
	version:         int,
	purpose:         string, // REQUEST_PURPOSE_NAMES
	api:             string,
	model_requested: string,
	// recovery is how the send came to be: initial, transient_retry, checkpoint_repair,
	// adaptive_thinking_omitted, or cache_hints_omitted.
	recovery:        string,
	body_digest:     string, // hex SHA-256 of the frozen body, "" when the body was not encoded
	body_bytes:      int,
}

Retry_Scheduled :: struct {
	version:      int,
	purpose:      string, // REQUEST_PURPOSE_NAMES
	reason:       string, // request_recovery_reason_name
	next_attempt: int,
	delay_ms:     i64,
}

Retry_Outcome :: enum u8 {
	Resent,
	Cancelled,
}

RETRY_OUTCOME_NAMES := [Retry_Outcome]string {
	.Resent    = "resent",
	.Cancelled = "cancelled",
}

// Retry_Completed ends a retry's wait: resent carries the attempt being sent,
// cancelled the attempt that failed.
Retry_Completed :: struct {
	version: int,
	purpose: string, // REQUEST_PURPOSE_NAMES
	outcome: string, // RETRY_OUTCOME_NAMES
}

// Subagent_Started opens a delegation in the parent's session, committed with the
// call's dispatch before the child starts. The record's call is the parent's call,
// and its subagent column the child's session id, chosen here so the child creates
// that session. The fields are what the call asked for, "" where it inherits;
// program names the ACP agent, "" for a native child.
Subagent_Started :: struct {
	version:    int,
	program:    string,
	provider:   string,
	model:      string,
	effort:     string,
	background: bool,
}

// Subagent_Completed ends a delegation in the parent's session; the child's
// final answer, or why there is none, is in the body.
Subagent_Completed :: Completion

// Subagent_Message carries one message of a delegation in the body. The record's
// session is the sender's and its subagent column the child's session, so each
// side reads the other's messages with Filter{session = peer, subagent = child}.
Subagent_Message :: struct {
	version: int,
}

// Response_Committed carries the API family that produced the response and the
// endpoint's native output items in the body. api uses the stable API names from
// Request_Sent. A token count the provider did not report is null, never zero.
Response_Committed :: struct {
	version:            int,
	api:                string,
	model_resolved:     string,
	finish:             string, // RESPONSE_FINISH_NAMES
	input_tokens:       Maybe(i64),
	output_tokens:      Maybe(i64),
	reasoning_tokens:   Maybe(i64),
	cache_read_tokens:  Maybe(i64),
	cache_write_tokens: Maybe(i64),
	// cost is the response's price in US dollars, absent when the answering model
	// has no price in the catalog.
	cost:               Maybe(f64),
}

// Tool_Proposed carries the arguments exactly as the model sent them in the body.
Tool_Proposed :: struct {
	version:     int,
	provider_id: string,
	item_id:     string,
	name:        string,
}

// Tool_Admitted carries the arguments the tool runs with in the body.
Tool_Admitted :: struct {
	version: int,
	tool:    string,
	repairs: []string,
}

// Tool_Started is the owner's dispatch of an admitted call, immediately before its
// effect begins. A call with no such record never started.
Tool_Started :: struct {
	version: int,
	tool:    string,
}

// Run_Started opens one launch of the harness. The record has no session.
Run_Started :: struct {
	version: int,
	pid:     int,
}

// Run_Finished closes a launch that reached its teardown; a run without one ended
// abruptly. The record has no session.
Run_Finished :: struct {
	version: int,
}

// Session_Claimed is the process taking the session's writer claim. resumed is false
// for a session this launch created, and true for one an earlier run left.
Session_Claimed :: struct {
	version: int,
	resumed: bool,
}

// Session_Released is written just before the journal that holds the claim closes.
Session_Released :: struct {
	version: int,
}

// Compaction_Started is a summary request about to be sent. The record's request is
// the compaction's own. trigger is a compaction trigger's name, covers the last node
// the summary replaces, and head_estimate the token estimate of the context it covers.
Compaction_Started :: struct {
	version:       int,
	trigger:       string,
	covers:        Node_Id,
	head_estimate: int,
}

// Job_Kind is the kind of worker the owner stopped waiting for.
Job_Kind :: enum u8 {
	Tool,
	Provider_Attempt,
	Compaction,
	Subagent,
}

JOB_KIND_NAMES := [Job_Kind]string {
	.Tool             = "tool",
	.Provider_Attempt = "provider_attempt",
	.Compaction       = "compaction",
	.Subagent         = "subagent",
}

// Job_Abandoned is the owner giving up on a worker that ignored its stop: the worker
// and everything it can reach are retained, and its outcome is already recorded as
// cancelled or unknown. waited_ms is how long the stop went unanswered and patience_ms
// the patience it was given.
Job_Abandoned :: struct {
	version:     int,
	job:         string, // JOB_KIND_NAMES
	waited_ms:   i64,
	patience_ms: i64,
}

// Job_Reclaimed is a retained worker finishing late, so the owner released it. What it
// published is dropped.
Job_Reclaimed :: struct {
	version: int,
	job:     string, // JOB_KIND_NAMES
}

// User carries the text in the node body.
User :: struct {
	version: int,
	origin:  string, // USER_ORIGIN_NAMES
	// message is the seq of the subagent.message this node delivers, 0 for none.
	// The highest one is where the session's reading of its peer's messages resumes.
	message: Journal_Seq,
}

// Assistant carries the visible text in the node body. partial marks text kept
// from a cancelled or failed response.
Assistant :: struct {
	version: int,
	request: Request_Id,
	partial: bool,
}

// Notice carries the feedback text in the node body.
Notice :: struct {
	version: int,
}

// Checkpoint carries the summary in the node body; the node's covers names the
// last node it replaces.
Checkpoint :: struct {
	version: int,
	request: Request_Id,
}

// Results lists the root calls it answers in proposal order.
Results :: struct {
	version: int,
	calls:   []Call_Id,
}
