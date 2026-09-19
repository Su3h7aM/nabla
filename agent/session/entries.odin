package session

import "core:mem"

// --- vocabularies -----------------------------------------------------------
//
// A persisted vocabulary is an enum, so an unknown value cannot be constructed
// by accident and every switch over one is exhaustive. The name tables are what
// the schema, the CHECK constraints, and the stored JSON share.

// Outcome is how a turn or a request ended. Running is the state a record has
// between its start and its end.
Outcome :: enum {
	Running,
	Completed,
	Failed,
	Cancelled,
	Interrupted,
}

@(private)
outcome_names := [Outcome]string {
	.Running     = "running",
	.Completed   = "completed",
	.Failed      = "failed",
	.Cancelled   = "cancelled",
	.Interrupted = "interrupted",
}

outcome_name :: proc(outcome: Outcome) -> string {
	return outcome_names[outcome]
}

outcome_from_name :: proc(name: string) -> (Outcome, bool) {
	for outcome in Outcome {
		if outcome_names[outcome] == name { return outcome, true }
	}
	return .Running, false
}

// Request_Purpose distinguishes the request that answers a turn from the one
// that summarizes history.
Request_Purpose :: enum {
	Response,
	Compaction,
}

@(private)
request_purpose_names := [Request_Purpose]string {
	.Response   = "response",
	.Compaction = "compaction",
}

request_purpose_name :: proc(purpose: Request_Purpose) -> string {
	return request_purpose_names[purpose]
}

request_purpose_from_name :: proc(name: string) -> (Request_Purpose, bool) {
	for purpose in Request_Purpose {
		if request_purpose_names[purpose] == name { return purpose, true }
	}
	return .Response, false
}

// User_Origin says where user-role conversation text came from: the prompt that
// opened a turn, a line that arrived while one ran, or the harness explaining a
// response it could not use. Harness text is conversation the model reads next,
// never input the user wrote.
User_Origin :: enum {
	Prompt,
	Steering,
	Harness,
}

@(private)
user_origin_names := [User_Origin]string {
	.Prompt   = "prompt",
	.Steering = "steering",
	.Harness  = "harness",
}

user_origin_name :: proc(origin: User_Origin) -> string {
	return user_origin_names[origin]
}

user_origin_from_name :: proc(name: string) -> (User_Origin, bool) {
	for origin in User_Origin {
		if user_origin_names[origin] == name { return origin, true }
	}
	return .Prompt, false
}

// Tool_Repair is what the harness had to change to make a proposed call usable.
// It is recorded beside the arguments the call actually ran with, so a reader can
// tell a repaired call from an untouched one without diffing the proposal. None
// means nothing was changed.
Tool_Repair :: enum {
	None,
	Escaped_Control_Characters,
}

@(private)
tool_repair_names := [Tool_Repair]string {
	.None                       = "none",
	.Escaped_Control_Characters = "escaped_control_characters",
}

tool_repair_name :: proc(repair: Tool_Repair) -> string {
	return tool_repair_names[repair]
}

tool_repair_from_name :: proc(name: string) -> (Tool_Repair, bool) {
	for repair in Tool_Repair {
		if tool_repair_names[repair] == name { return repair, true }
	}
	return .None, false
}

// Tool_Outcome is what the harness observed when it handled a tool call. It is
// not a judgement about the model: a nonzero exit is an observation about the
// command, and a refusal before anything ran is one about the arguments.
//
// Unknown is the zero value, so a call whose outcome was never recorded reads as
// unobserved rather than as a success. Invalid_Arguments, Unavailable,
// Not_Executed, and Transport_Failed all mean nothing ran; Unknown means the
// harness cannot say.
Tool_Outcome :: enum {
	Unknown,
	Success,
	Tool_Failed,
	Invalid_Arguments,
	Unavailable,
	Timed_Out,
	Cancelled,
	Not_Executed,
	Transport_Failed,
}

@(private)
tool_outcome_names := [Tool_Outcome]string {
	.Unknown           = "unknown",
	.Success           = "success",
	.Tool_Failed       = "tool_failed",
	.Invalid_Arguments = "invalid_arguments",
	.Unavailable       = "unavailable",
	.Timed_Out         = "timed_out",
	.Cancelled         = "cancelled",
	.Not_Executed      = "not_executed",
	.Transport_Failed  = "transport_failed",
}

tool_outcome_name :: proc(outcome: Tool_Outcome) -> string {
	return tool_outcome_names[outcome]
}

// tool_outcome_from_name reads the outcome vocabulary, including the names
// earlier versions wrote. A stored row keeps its own meaning: a command that
// exited is a success here whatever its exit code was, because the exit code is
// not in this field.
tool_outcome_from_name :: proc(name: string) -> (Tool_Outcome, bool) {
	switch name {
	case "unknown":
		return .Unknown, true
	case "success", "exited":
		return .Success, true
	case "tool_failed", "spawn_failed", "io_failed":
		return .Tool_Failed, true
	case "invalid_arguments":
		return .Invalid_Arguments, true
	case "unavailable":
		return .Unavailable, true
	case "timed_out":
		return .Timed_Out, true
	case "cancelled":
		return .Cancelled, true
	case "not_executed":
		return .Not_Executed, true
	case "transport_failed":
		return .Transport_Failed, true
	}
	return .Unknown, false
}

// Tool_Result_Origin says where a result came from: an execution the harness
// observed, or the recovery that closed an interrupted session. A recovered
// result describes what the harness knows, not what happened.
Tool_Result_Origin :: enum {
	Observed,
	Recovered,
}

@(private)
tool_result_origin_names := [Tool_Result_Origin]string {
	.Observed  = "observed",
	.Recovered = "recovered",
}

tool_result_origin_name :: proc(origin: Tool_Result_Origin) -> string {
	return tool_result_origin_names[origin]
}

tool_result_origin_from_name :: proc(name: string) -> (Tool_Result_Origin, bool) {
	for origin in Tool_Result_Origin {
		if tool_result_origin_names[origin] == name { return origin, true }
	}
	return .Observed, false
}

// --- entries ----------------------------------------------------------------

// Entry_Kind is the shape of one entry's payload. It is an enum because both
// the codec and the schema check switch on it exhaustively.
Entry_Kind :: enum {
	User,
	Assistant,
	Reasoning,
	Response,
	Tool_Call,
	Tool_Dispatch,
	Tool_Result,
	Checkpoint,
	Instruction_Snapshot,
}

entry_kind_name :: proc(kind: Entry_Kind) -> string {
	switch kind {
	case .User:
		return "user"
	case .Assistant:
		return "assistant"
	case .Reasoning:
		return "reasoning"
	case .Response:
		return "response"
	case .Tool_Call:
		return "tool_call"
	case .Tool_Dispatch:
		return "tool_dispatch"
	case .Tool_Result:
		return "tool_result"
	case .Checkpoint:
		return "checkpoint"
	case .Instruction_Snapshot:
		return "instruction_snapshot"
	}
	return ""
}

entry_kind_from_name :: proc(name: string) -> (Entry_Kind, bool) {
	for kind in Entry_Kind {
		if entry_kind_name(kind) == name { return kind, true }
	}
	return .User, false
}

// User_Entry is text the user supplied. origin separates the prompt that opened
// a turn from a steering line that joined one already running.
User_Entry :: struct {
	text:   string,
	origin: User_Origin,
}

// Assistant_Entry is text the model produced. partial marks text that was
// available when a turn was cancelled or failed: it is kept, but it never
// enters a later request as a finished answer.
Assistant_Entry :: struct {
	text:    string,
	partial: bool,
}

// Reasoning_Entry is one opaque provider replay item. It has no meaning to this
// package; it is stored so the adapter that produced it can see it again.
// New Responses sessions record the whole output as a Response_Entry instead;
// this variant stays so sessions written before that change still decode.
Reasoning_Entry :: struct {
	id:        string,
	encrypted: string,
}

// Response_Entry is one completed Responses output, stored verbatim: the
// terminal output array exactly as the endpoint sent it. Display text and
// executable calls are projections recorded as their own entries; this entry
// is the replay record, so the fields the stream decoder does not model --
// assistant phase, reasoning summaries, annotations -- and any item type it
// does not know survive. Only the Responses API writes this entry; Chat
// Completions has no replayable output items to preserve.
Response_Entry :: struct {
	output: string,
}

// Tool_Call_Entry is a call the model proposed. arguments holds the raw JSON
// text exactly as received, including arguments that did not parse.
Tool_Call_Entry :: struct {
	call_id:   string,
	item_id:   string,
	name:      string,
	arguments: string,
}

// Tool_Dispatch_Entry is the harness committing to run a call. It is written
// before the external work begins, so a dispatch with no result means the
// outcome is unknown rather than "did not run". arguments is the argument JSON
// the call actually ran with, and repair names what had to change for it to be
// usable, if anything.
Tool_Dispatch_Entry :: struct {
	tool:      string,
	arguments: string,
	repair:    Tool_Repair,
}

// Tool_Result_Entry is what the harness observed, together with the exact text
// the model was given. outcome and error are the analysis-facing summary; content
// is the whole observed result and the only place tool-specific output lives; and
// spilled says the model was shown a handle for it instead of the text, because
// the turn's results as a whole did not fit the room the context had left. A handle
// is derived from this entry and never stored beside it, so the record and the
// projection cannot disagree about what the model was told.
Tool_Result_Entry :: struct {
	outcome: Tool_Outcome,
	error:   string,
	content: string,
	origin:  Tool_Result_Origin,
	spilled: bool,
}

// Checkpoint_Entry is a summary that stands in for the history up to
// covered_seq. It never replaces that history; it tells a later request where
// to start reading.
Checkpoint_Entry :: struct {
	summary:      string,
	covered_seq:  Maybe(Seq), // the last ordinary entry the summary covers
	previous_seq: Maybe(Seq), // the checkpoint it summarized, when it summarized one
}

// Instruction_Snapshot_Entry is the frozen initial instructions and skill
// catalog a session started with. It is bookkeeping, never conversation: no
// turn or request names it, and context queries leave it out.
Instruction_Snapshot_Entry :: struct {
	format_version: u32,
	instructions:   string,
	manifest_json:  string,
}

// Entry_Payload is the decoded content of one entry. The active variant fixes
// what the entry means; Entry.kind and the payload are always in agreement
// because the codec derives one from the other.
Entry_Payload :: union {
	User_Entry,
	Assistant_Entry,
	Reasoning_Entry,
	Response_Entry,
	Tool_Call_Entry,
	Tool_Dispatch_Entry,
	Tool_Result_Entry,
	Checkpoint_Entry,
	Instruction_Snapshot_Entry,
}

// Entry is one stored history record. Every string it holds is owned by the
// allocator it was read with and released by entry_destroy.
Entry :: struct {
	seq:           Seq,
	turn_no:       Maybe(Turn_No),
	request_no:    Maybe(Request_No),
	created_at_ms: i64,
	kind:          Entry_Kind,
	related_seq:   Maybe(Seq),
	payload:       Entry_Payload,
}

// New_Entry is an entry about to be stored. Its strings are borrowed for the
// call that writes it.
New_Entry :: struct {
	turn_no:       Maybe(Turn_No),
	request_no:    Maybe(Request_No),
	created_at_ms: i64,
	related_seq:   Maybe(Seq),
	payload:       Entry_Payload,
}

// Entry_Load_Options selects a contiguous run of a session's history. The
// bounds are exclusive below and inclusive above, which is what a paging
// front-end wants: it has already shown everything up to `after`.
Entry_Load_Options :: struct {
	after:   Maybe(Seq),
	through: Maybe(Seq),
	limit:   int,
}

ENTRIES_DEFAULT_LIMIT :: 200
ENTRIES_MAX_LIMIT :: 2000

entry_kind_of :: proc(payload: Entry_Payload) -> Entry_Kind {
	switch value in payload {
	case User_Entry:
		return .User
	case Assistant_Entry:
		return .Assistant
	case Reasoning_Entry:
		return .Reasoning
	case Response_Entry:
		return .Response
	case Tool_Call_Entry:
		return .Tool_Call
	case Tool_Dispatch_Entry:
		return .Tool_Dispatch
	case Tool_Result_Entry:
		return .Tool_Result
	case Checkpoint_Entry:
		return .Checkpoint
	case Instruction_Snapshot_Entry:
		return .Instruction_Snapshot
	}
	return .User
}

entry_destroy :: proc(entry: ^Entry, allocator := context.allocator) {
	if entry == nil { return }
	entry_payload_destroy(&entry.payload, allocator)
	entry^ = {}
}

entries_destroy :: proc(entries: []Entry, allocator := context.allocator) {
	for &entry in entries { entry_destroy(&entry, allocator) }
	delete(entries, allocator)
}

@(private)
entry_payload_destroy :: proc(payload: ^Entry_Payload, allocator: mem.Allocator) {
	switch &value in payload^ {
	case User_Entry:
		delete(value.text, allocator)
	case Assistant_Entry:
		delete(value.text, allocator)
	case Reasoning_Entry:
		delete(value.id, allocator)
		delete(value.encrypted, allocator)
	case Response_Entry:
		delete(value.output, allocator)
	case Tool_Call_Entry:
		delete(value.call_id, allocator)
		delete(value.item_id, allocator)
		delete(value.name, allocator)
		delete(value.arguments, allocator)
	case Tool_Dispatch_Entry:
		delete(value.tool, allocator)
		delete(value.arguments, allocator)
	case Tool_Result_Entry:
		delete(value.error, allocator)
		delete(value.content, allocator)
	case Checkpoint_Entry:
		delete(value.summary, allocator)
	case Instruction_Snapshot_Entry:
		delete(value.instructions, allocator)
		delete(value.manifest_json, allocator)
	}
	payload^ = nil
}
