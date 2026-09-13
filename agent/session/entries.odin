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

// User_Origin says whether user text opened a turn or arrived while one ran.
User_Origin :: enum {
	Prompt,
	Steering,
}

@(private)
user_origin_names := [User_Origin]string {
	.Prompt   = "prompt",
	.Steering = "steering",
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

// Tool_Outcome is what the harness observed when it handled a tool call. It is
// not a judgement about the model: a nonzero exit is a result, not a mistake.
Tool_Outcome :: enum {
	Exited,
	Invalid_Arguments,
	Spawn_Failed,
	Timed_Out,
	Cancelled,
	Not_Executed,
	IO_Failed,
	Unknown,
}

@(private)
tool_outcome_names := [Tool_Outcome]string {
	.Exited            = "exited",
	.Invalid_Arguments = "invalid_arguments",
	.Spawn_Failed      = "spawn_failed",
	.Timed_Out         = "timed_out",
	.Cancelled         = "cancelled",
	.Not_Executed      = "not_executed",
	.IO_Failed         = "io_failed",
	.Unknown           = "unknown",
}

tool_outcome_name :: proc(outcome: Tool_Outcome) -> string {
	return tool_outcome_names[outcome]
}

tool_outcome_from_name :: proc(name: string) -> (Tool_Outcome, bool) {
	for outcome in Tool_Outcome {
		if tool_outcome_names[outcome] == name { return outcome, true }
	}
	return .Unknown, false
}

// Tool_Result_Origin says where a result came from: an execution the harness
// observed, or the recovery that closed an interrupted session. A recovered
// result describes what the harness knows, not what happened.
Tool_Result_Origin :: enum {
	Executed,
	Recovered,
}

@(private)
tool_result_origin_names := [Tool_Result_Origin]string {
	.Executed  = "executed",
	.Recovered = "recovered",
}

tool_result_origin_name :: proc(origin: Tool_Result_Origin) -> string {
	return tool_result_origin_names[origin]
}

tool_result_origin_from_name :: proc(name: string) -> (Tool_Result_Origin, bool) {
	for origin in Tool_Result_Origin {
		if tool_result_origin_names[origin] == name { return origin, true }
	}
	return .Executed, false
}

// --- entries ----------------------------------------------------------------

// Entry_Kind is the shape of one entry's payload. It is an enum because both
// the codec and the schema check switch on it exhaustively.
Entry_Kind :: enum {
	User,
	Assistant,
	Reasoning,
	Tool_Call,
	Tool_Dispatch,
	Tool_Result,
	Checkpoint,
}

entry_kind_name :: proc(kind: Entry_Kind) -> string {
	switch kind {
	case .User:
		return "user"
	case .Assistant:
		return "assistant"
	case .Reasoning:
		return "reasoning"
	case .Tool_Call:
		return "tool_call"
	case .Tool_Dispatch:
		return "tool_dispatch"
	case .Tool_Result:
		return "tool_result"
	case .Checkpoint:
		return "checkpoint"
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
Reasoning_Entry :: struct {
	id:        string,
	encrypted: string,
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
// outcome is unknown rather than "did not run".
Tool_Dispatch_Entry :: struct {
	tool:      string,
	arguments: string, // effective arguments, after defaults were resolved
}

// Tool_Result_Entry is what the harness observed, together with the exact text
// the model was given. outcome and error are the analysis-facing summary;
// content is what goes back into the conversation.
Tool_Result_Entry :: struct {
	outcome:   Tool_Outcome,
	exit_code: Maybe(i32),
	error:     string,
	content:   string,
	origin:    Tool_Result_Origin,
}

// Checkpoint_Entry is a summary that stands in for the history up to
// covered_seq. It never replaces that history; it tells a later request where
// to start reading.
Checkpoint_Entry :: struct {
	summary:      string,
	covered_seq:  Maybe(Seq), // the last ordinary entry the summary covers
	previous_seq: Maybe(Seq), // the checkpoint it summarized, when it summarized one
}

// Entry_Payload is the decoded content of one entry. The active variant fixes
// what the entry means; Entry.kind and the payload are always in agreement
// because the codec derives one from the other.
Entry_Payload :: union {
	User_Entry,
	Assistant_Entry,
	Reasoning_Entry,
	Tool_Call_Entry,
	Tool_Dispatch_Entry,
	Tool_Result_Entry,
	Checkpoint_Entry,
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
	case Tool_Call_Entry:
		return .Tool_Call
	case Tool_Dispatch_Entry:
		return .Tool_Dispatch
	case Tool_Result_Entry:
		return .Tool_Result
	case Checkpoint_Entry:
		return .Checkpoint
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
	}
	payload^ = nil
}
