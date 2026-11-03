package journal

// A payload is the typed body of one record or node, stored in the family tables
// of its kind. Enums are stored as integer codes; the name tables below map them
// to the stable names the structs carry, and enum_from_name reads them back.

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
	Job,
}

USER_ORIGIN_NAMES := [User_Origin]string {
	.Prompt   = "prompt",
	.Steering = "steering",
	.Harness  = "harness",
	.Agent    = "agent",
	.Job      = "job",
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
	Context_Window,
	Content_Filter,
	Tool_Call,
}

RESPONSE_FINISH_NAMES := [Response_Finish]string {
	.Unknown        = "unknown",
	.Stop           = "stop",
	.Length         = "length",
	.Context_Window = "context_window",
	.Content_Filter = "content_filter",
	.Tool_Call      = "tool_call",
}

// Completion ends a unit of work: outcome is a TOOL_OUTCOME_NAMES name for a call, Lua run, Task, or subagent. attachments are the files a tool result carries
// beside its rendered text, in the order the model reads them.
Completion :: struct {
	outcome:     string,
	detail:      string,
	attachments: []Attachment,
}

// Background_Completed carries the rendered tool result in the body; call names the background call.
Background_Completed :: struct {
	outcome:     string, // TOOL_OUTCOME_NAMES
	detail:      string,
	tool:        string,
	attachments: []Attachment,
}

Tool_Completed :: Completion
Call_Completed :: Completion // lua.completed, task.completed

// Attachment names one file a User node or a tool result carries; its bytes are the artifact stored under digest, as lowercase hexadecimal, media_type is the
// wire name of the format, and name is the file name the model is told.
Attachment :: struct {
	media_type: string,
	name:       string,
	digest:     string,
}

ATTACHMENT_ARTIFACT :: "attachment"

// User_Input is one line a user sent a session, committed before anything acknowledges
// it. The line is in the body and may be empty when attachments is not. origin is a
// USER_ORIGIN_NAMES name, the origin of the User node that delivers it. attachments
// are the files the line carries, stored as attachment artifacts the same way a
// background completion stores them. The record is not a node, so a session accepts
// it in any phase; a User node whose message names its seq delivers it.
User_Input :: struct {
	origin:      string,
	attachments: []Attachment,
}

// Command_Kind is the closed set of commands a client appends to steer a running
// session. The record's `kind` stores the stable name.
Command_Kind :: enum u8 {
	Cancel_Turn,
	Select_Model,
	Set_Effort,
	Compact,
	Stop_Server,
}

COMMAND_KIND_NAMES := [Command_Kind]string {
	.Cancel_Turn  = "cancel_turn",
	.Select_Model = "select_model",
	.Set_Effort   = "set_effort",
	.Compact      = "compact",
	.Stop_Server  = "stop_server",
}

// Command is one action a client asks a running session to take. A command
// reaches the server only through the journal, so it is a value a client builds
// and appends; the server reads it back as the same union.
Command :: union #no_nil {
	Cancel_Turn,
	Select_Model,
	Set_Effort,
	Compact,
	Stop_Server,
}

Cancel_Turn :: struct {}

Select_Model :: struct {
	provider: string,
	model:    string,
}

Set_Effort :: struct {
	level: string, // "" for the provider default
}

Compact :: struct {}

// Stop_Server asks the session server to stop its turn and exit.
Stop_Server :: struct {}

// User_Command is one command a client appended, stored flat with the fields its
// kind uses: the payload is the boundary between the union above and JSON.
User_Command :: struct {
	kind:     string, // COMMAND_KIND_NAMES
	provider: string,
	model:    string,
	level:    string,
}

// command_payload encodes one command as the payload user.command stores.
command_payload :: proc(command: Command) -> (payload: User_Command) {
	switch value in command {
	case Cancel_Turn:
		payload.kind = COMMAND_KIND_NAMES[.Cancel_Turn]
	case Select_Model:
		payload.kind = COMMAND_KIND_NAMES[.Select_Model]
		payload.provider = value.provider
		payload.model = value.model
	case Set_Effort:
		payload.kind = COMMAND_KIND_NAMES[.Set_Effort]
		payload.level = value.level
	case Compact:
		payload.kind = COMMAND_KIND_NAMES[.Compact]
	case Stop_Server:
		payload.kind = COMMAND_KIND_NAMES[.Stop_Server]
	}
	return
}

// command_decode reads the action a stored user.command names, false when its
// kind is not a command. The result borrows payload.
@(require_results)
command_decode :: proc(payload: User_Command) -> (command: Command, known: bool) {
	kind, found := enum_from_name(COMMAND_KIND_NAMES, payload.kind)
	if !found { return {}, false }
	switch kind {
	case .Cancel_Turn:
		return Cancel_Turn{}, true
	case .Select_Model:
		return Select_Model{provider = payload.provider, model = payload.model}, true
	case .Set_Effort:
		return Set_Effort{level = payload.level}, true
	case .Compact:
		return Compact{}, true
	case .Stop_Server:
		return Stop_Server{}, true
	}
	return {}, false
}

// Command_Outcome is what the session did with a command.
Command_Outcome :: enum u8 {
	Applied,
	Refused,
}

COMMAND_OUTCOME_NAMES := [Command_Outcome]string {
	.Applied = "applied",
	.Refused = "refused",
}

// Command_Applied ends one command: command is the seq of its user.command, and
// reason says why a refused command was not applied.
Command_Applied :: struct {
	command: Journal_Seq,
	outcome: string, // COMMAND_OUTCOME_NAMES
	reason:  string,
}

// Turn_Completed ends a turn. reason is why its request chain stopped and cause
// what kept the context from fitting, both "" when absent.
Turn_Completed :: struct {
	outcome: string, // TURN_OUTCOME_NAMES
	detail:  string,
	reason:  string,
	cause:   string,
}

// Attempt_Usage is what one provider attempt reported and what it cost, carried by
// the attempt's terminal record: response.committed, response.rejected, or
// request.interrupted. The payloads embed it with `using _`, which the JSON
// encoding flattens into the payload's own keys. A token count the provider did
// not report is null, never zero. cost is the attempt's price in US dollars,
// absent when a count or the model's catalog price is missing. A record written
// before the field existed reads as null, so it needs no payload version.
Attempt_Usage :: struct {
	input_tokens:       Maybe(i64),
	output_tokens:      Maybe(i64),
	reasoning_tokens:   Maybe(i64),
	cache_read_tokens:  Maybe(i64),
	cache_write_tokens: Maybe(i64),
	cost:               Maybe(f64),
}

Request_Interrupted :: struct {
	detail:  string,
	using _: Attempt_Usage,
}

// Response_Rejected is why one send produced no usable response: the failure as
// the provider layer classified it, the evidence it kept, and what the harness
// decided. A retry delay the provider did not give is null.
Response_Rejected :: struct {
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
	using _:             Attempt_Usage,
}

Session_Created :: struct {
	workspace:      string,
	role:           string, // SESSION_ROLE_NAMES
	parent_session: string, // hex, "" for a main session
	parent_call:    Call_Id,
}

Session_Titled :: struct {
	title: string,
}

// Session_Recovered counts what recover recorded.
Session_Recovered :: struct {
	turns:    int,
	requests: int,
	calls:    int,
	results:  int,
}

// Session_Environment carries what an interface installed when it opened, loaded,
// or resumed the session: the standing system instructions and the MCP server
// list. It mirrors MCP_Server_Config in native structs, with the timeouts in
// milliseconds, and the server converts it once at the journal boundary.
Session_Environment :: struct {
	instructions: string,
	servers:      []Session_Environment_Server,
}

// Session_Environment_Server is one configured MCP server of a
// session.environment record.
Session_Environment_Server :: struct {
	id:                   string,
	executable:           string,
	arguments:            []string,
	working_directory:    string,
	environment:          []Session_Environment_Variable,
	tools:                []Session_Environment_Tool,
	discovery_timeout_ms: i64,
	call_timeout_ms:      i64,
}

// Session_Environment_Variable is one variable a server is launched with.
Session_Environment_Variable :: struct {
	name:  string,
	value: string,
}

// Session_Environment_Tool overrides one discovered remote tool: an entry may
// disable it or replace its model-visible name, never both.
Session_Environment_Tool :: struct {
	remote_name: string,
	name:        string,
	enabled:     bool,
}

// Selection_Changed has no session for the process-wide default. The record's
// provider and model are the default; effort is the provider's own level name,
// "" for its default.
Selection_Changed :: struct {
	effort: string,
}

Selection_Fit_Decision :: enum u8 {
	Fits,
	Compact,
	Refused,
}

SELECTION_FIT_DECISION_NAMES := [Selection_Fit_Decision]string {
	.Fits    = "fits",
	.Compact = "compact",
	.Refused = "refused",
}

// Selection_Fit records a target selection's admission check. The record's provider
// and model name the target; recheck distinguishes checks after the initial request.
Selection_Fit :: struct {
	api:            string,
	recheck:        bool,
	decision:       string, // SELECTION_FIT_DECISION_NAMES
	estimate:       int,
	context_window: int,
	reason:         string,
}

// Selection_Applied records the session's installed serving identity, which the
// record's provider and model name. It is separate from Selection_Changed, which
// stores the process-wide default for the next launch.
Selection_Applied :: struct {
	api:    string,
	effort: string,
}

Branch_Created :: struct {
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
	level: string,
	text:  string,
}

// Branch_Selected names the branch in the record's branch column.
Branch_Selected :: struct {}

Node_Committed :: struct {
	kind: string, // NODE_KIND_NAMES
}

// Turn_Started names the instruction and manifest artifacts the turn runs with
// by hex digest. The record's model is the one the turn runs with.
Turn_Started :: struct {
	instructions: string,
	manifest:     string,
	effort:       string,
}

Request_Prepared :: struct {
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

// Request_Admitted is whether a request fits its model's window.
Request_Admitted :: struct {
	decision:            string, // ADMISSION_DECISION_NAMES
	estimate:            int,
	context_window:      int,
	instructions_tokens: int,
	tools_tokens:        int,
	conversation_tokens: int,
}

// Request_Sent names the model requested in the record's model.
Request_Sent :: struct {
	purpose:     string, // REQUEST_PURPOSE_NAMES
	api:         string,
	// recovery is how the send came to be: initial, transient_retry, checkpoint_repair,
	// adaptive_thinking_omitted, or cache_hints_omitted.
	recovery:    string,
	body_digest: string, // hex SHA-256 of the frozen body, "" when the body was not encoded
	body_bytes:  int,
}

Retry_Scheduled :: struct {
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
	purpose: string, // REQUEST_PURPOSE_NAMES
	outcome: string, // RETRY_OUTCOME_NAMES
}

// Subagent_Started opens a delegation in the parent's session, committed with the
// call's dispatch before the child starts. The record's call is the parent's call,
// and its subagent column the child's session id, chosen here so the child creates
// that session. The fields are what the call asked for, "" where it inherits;
// program names the ACP agent, "" for a native child. name is the id the parent's model
// knows the child by, and the body is the child's instruction, so the record alone
// defines the child. A record written before these existed reads name as "" and an
// empty body.
Subagent_Started :: struct {
	name:       string,
	program:    string,
	provider:   string,
	model:      string,
	effort:     string,
	background: bool,
}

// Subagent_Completed ends a delegation in the parent's session; the child's
// final answer, or why there is none, is in the body. name is the id the parent's
// model knows the child by, "" when recovery wrote the record.
// ACP fields preserve its external session, selection, and last consumed inbox sequence.
Subagent_Completed :: struct {
	outcome:     string, // TOOL_OUTCOME_NAMES
	detail:      string,
	name:        string,
	acp_session: string,
	acp_after:   Journal_Seq,
	acp_model:   string,
	acp_effort:  string,
}

// Subagent_Message carries one message of a delegation in the body. The record's
// session is the sender's and its subagent column the child's session, so each
// parent's inbox reads replies while its ACP client sends parent messages as prompts. name is the id the parent's model
// knows the child by.
Subagent_Message :: struct {
	name: string,
}

// Response_Committed carries the API family that produced the response and the
// endpoint's native output items in the body. api uses the stable API names from
// Request_Sent.
Response_Committed :: struct {
	api:            string,
	model_resolved: string,
	finish:         string, // RESPONSE_FINISH_NAMES
	using _:        Attempt_Usage,
}

// Tool_Proposed carries the arguments exactly as the model sent them in the body.
Tool_Proposed :: struct {
	provider_id: string,
	item_id:     string,
	name:        string,
}

// Tool_Admitted carries the arguments the tool runs with in the body.
Tool_Admitted :: struct {
	tool:       string,
	repairs:    []string,
	background: bool,
}

// Tool_Started is the owner's dispatch of an admitted call, immediately before its
// effect begins. A call with no such record never started.
Tool_Started :: struct {
	tool: string,
}

// Run_Started opens one launch of the harness. The record has no session.
Run_Started :: struct {
	pid: int,
}

// Run_Finished closes a launch that reached its teardown; a run without one ended
// abruptly. The record has no session.
Run_Finished :: struct {}

// Session_Claimed is the process taking the session's writer claim. resumed is false
// for a session this launch created, and true for one an earlier run left.
Session_Claimed :: struct {
	resumed: bool,
}

// Session_Released is written just before the journal that holds the claim closes.
Session_Released :: struct {}

// Compaction_Started is a summary request about to be sent. The record's request is
// the compaction's own. trigger is a compaction trigger's name, covers the last node
// the summary replaces, and head_estimate the token estimate of the context it covers.
Compaction_Started :: struct {
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
	job:         string, // JOB_KIND_NAMES
	waited_ms:   i64,
	patience_ms: i64,
}

// Job_Reclaimed is a retained worker finishing late, so the owner released it. What it
// published is dropped.
Job_Reclaimed :: struct {
	job: string, // JOB_KIND_NAMES
}

// User carries the text in the node body and the files the user attached to it.
User :: struct {
	origin:      string, // USER_ORIGIN_NAMES
	// message is the seq of the user.input, background.completed, subagent.completed, or subagent.message
	// record this node delivers, 0 for none. The highest one is where the session's
	// reading of its inbox resumes.
	message:     Journal_Seq,
	attachments: []Attachment,
}

// Assistant carries the visible text in the node body. partial marks text kept
// from a cancelled or failed response.
Assistant :: struct {
	request: Request_Id,
	partial: bool,
}

// Notice carries the feedback text in the node body.
Notice :: struct {}

// Checkpoint carries the summary in the node body; the node's covers names the
// last node it replaces.
Checkpoint :: struct {
	request: Request_Id,
}

// Results lists the root calls it answers in proposal order.
Results :: struct {
	calls: []Call_Id,
}
