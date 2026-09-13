package agent

import "core:mem"
import "core:strings"

import "nabla:agent/session"
import "nabla:ai"

// Chat_Tool_Call is a validated tool call awaiting execution. seq is the stored
// tool-call entry it belongs to, so the dispatch and the result can name it.
Chat_Tool_Call :: struct {
	id:        string, // owned
	item_id:   string, // owned
	name:      string, // owned
	arguments: string, // owned; raw JSON, exactly as the model sent it
	seq:       session.Seq,
}

// Chat_Reasoning is one provider replay item the current response produced. It
// is committed with that response; nothing here survives the request otherwise.
Chat_Reasoning :: struct {
	id:        string, // owned
	encrypted: string, // owned
}

// Chat_State is the control state of the session. Durable state lives in the
// store: these are transitions in flight, not conversation.
Chat_State :: enum {
	Idle,
	Preparing,
	Requesting,
	Streaming,
	Executing_Tools,
	// Cancellation requested; the turn settles only once its operation retires.
	Cancelling,
	Finalizing,
}

Chat_Terminal_Status :: enum {
	None,
	Completed,
	Failed,
	Cancelled,
}

// Chat_Accept says whether input was admitted.
Chat_Accept :: enum {
	Accepted,
	// A turn is already running.
	Busy,
	// The input could not be recorded, so the turn was not started.
	Storage_Failed,
}

// Chat_Session is the running half of a session. Committed history lives in the
// store; this holds only what the turn in flight needs.
//
// store and id are borrowed. The caller owns the store, holds the writer claim
// for id, and keeps both alive for the session's lifetime.
Chat_Session :: struct {
	store:                       ^session.Store,
	id:                          session.Session_Id,
	allocator:                   mem.Allocator,
	state:                       Chat_State,
	terminal_status:             Chat_Terminal_Status,
	last_error:                  string, // owned

	// active_turn_id and the operation ids are process-local identities. They
	// name an execution, not a durable turn; turn_no is the durable one.
	active_turn_id:              u64,
	next_turn_id:                u64,
	turn_no:                     Maybe(session.Turn_No),
	active_request:              Maybe(session.Request_No),
	active_operation_id:         u64,
	next_operation_id:           u64,
	operation:                   Chat_Operation,
	turn_deadline:               ai.Deadline,

	// storage_failed latches a durable write that did not land. A session that
	// could not record its own history accepts no further work: continuing would
	// let the conversation diverge from what was stored.
	storage_failed:              bool,

	// partial_assistant is streamed text that has not been committed. It stays
	// provisional until the turn settles.
	partial_assistant:           [dynamic]u8,

	// pending_reasoning and pending_calls are what the current response produced
	// and has not committed yet.
	pending_reasoning:           [dynamic]Chat_Reasoning,
	pending_calls:               [dynamic]Chat_Tool_Call,
	requests_made:               int, // model requests this turn; bounds the tool loop
	calls_made:                  int, // tool executions this turn
	active_failed:               bool,
	workspace:                   string, // owned; validated process directory
	provider_id:                 string, // owned; the provider requests are addressed to
	model_id:                    string, // owned; the model requests ask for
	tools_enabled:               bool, // frozen for the session's life
	max_output_tokens:           int, // 0 means unset
	context_window:              int, // 0 means unconfigured
	effort_levels:               [dynamic]string, // owned; allowed levels, verbatim
	effort:                      string, // owned; "" means provider default

	// last_input_measured is the last endpoint-reported input size, and
	// last_estimate is the harness's own count of the active context, kept for
	// the status line without touching the store from another thread.
	last_input_measured:         i64,
	last_input_measured_present: bool,
	last_estimate:               int,

	// auto_compacted_turn records the turn automatic compaction already ran in,
	// so a turn that still cannot fit fails instead of compacting forever.
	auto_compacted_turn:         u64,
}

// CHAT_DEFAULT_CONTEXT_WINDOW is the window a session assumes for a model that no
// enrichment source described. It is a runtime default rather than a metadata
// source: it applies only after user configuration, provider discovery, and
// models.dev have all left the window unstated, and it never replaces a stated one.
CHAT_DEFAULT_CONTEXT_WINDOW :: 128 * 1024

// chat_context_window is the window a session runs with for a resolved model, and
// whether that window is an assumption rather than a stated fact. Presence decides:
// a window the catalog carries is used as stated, including an explicit zero, which
// admission then refuses rather than quietly running with the default.
chat_context_window :: proc(model: Catalog_Model) -> (window: int, assumed: bool) {
	if model.context_window_present { return model.context_window, false }
	return CHAT_DEFAULT_CONTEXT_WINDOW, true
}

// chat_session_init builds the running state for a claimed session. workspace is
// the validated process directory; it is copied, because the caller's copy may
// be temporary.
chat_session_init :: proc(store: ^session.Store, id: session.Session_Id, workspace: string, allocator := context.allocator) -> Chat_Session {
	return Chat_Session {
		store = store,
		id = id,
		allocator = allocator,
		next_turn_id = 1,
		next_operation_id = 1,
		partial_assistant = make([dynamic]u8, 0, allocator),
		pending_reasoning = make([dynamic]Chat_Reasoning, 0, allocator),
		pending_calls = make([dynamic]Chat_Tool_Call, 0, allocator),
		effort_levels = make([dynamic]string, 0, allocator),
		workspace = strings.clone(workspace, allocator),
	}
}

chat_tool_call_destroy :: proc(call: ^Chat_Tool_Call, allocator: mem.Allocator) {
	delete(call.id, allocator)
	delete(call.item_id, allocator)
	delete(call.name, allocator)
	delete(call.arguments, allocator)
	call^ = {}
}

chat_reasoning_destroy :: proc(reasoning: ^Chat_Reasoning, allocator: mem.Allocator) {
	delete(reasoning.id, allocator)
	delete(reasoning.encrypted, allocator)
	reasoning^ = {}
}

chat_session_destroy :: proc(chat: ^Chat_Session) {
	delete(chat.partial_assistant)
	for &reasoning in chat.pending_reasoning { chat_reasoning_destroy(&reasoning, chat.allocator) }
	delete(chat.pending_reasoning)
	for &call in chat.pending_calls { chat_tool_call_destroy(&call, chat.allocator) }
	delete(chat.pending_calls)
	delete(chat.last_error, chat.allocator)
	for level in chat.effort_levels { delete(level, chat.allocator) }
	delete(chat.effort_levels)
	delete(chat.effort, chat.allocator)
	delete(chat.workspace, chat.allocator)
	delete(chat.provider_id, chat.allocator)
	delete(chat.model_id, chat.allocator)
	chat^ = {}
}

chat_clone_string :: proc(value: string, allocator: mem.Allocator) -> string {
	return strings.clone(value, allocator)
}

// chat_session_record_failure stops the turn because a durable write failed.
// The turn is not allowed to continue from memory: the record did not land, and
// carrying on would let the conversation diverge from what was stored.
chat_session_record_failure :: proc(chat: ^Chat_Session, what: string, err: session.Error) {
	local := err
	detail := session.error_detail(&local)
	delete(chat.last_error, chat.allocator)
	if what == "" {
		chat.last_error = chat_clone_string(detail, chat.allocator)
	} else {
		chat.last_error = strings.concatenate({what, ": ", detail}, chat.allocator)
	}
	chat.active_failed = true
	chat.storage_failed = true
	chat.state = .Finalizing
}

// chat_session_accept_user admits a prompt: it opens a turn and records the
// prompt as that turn's first entry before any request is made.
chat_session_accept_user :: proc(chat: ^Chat_Session, text: string, at_ms: i64) -> Chat_Accept {
	if chat.state != .Idle || chat.storage_failed { return .Busy }

	// The header records which model the session last ran with, so a later
	// continuation starts from it rather than from nothing.
	if chat.provider_id != "" && chat.model_id != "" {
		if model_err := session.session_set_model(chat.store, chat.id, chat.provider_id, chat.model_id); model_err != nil {
			chat_session_record_failure(chat, "the session model could not be recorded", model_err)
			return .Storage_Failed
		}
	}

	turn_no, turn_err := session.turn_begin(chat.store, chat.id, text, .Prompt, at_ms)
	if turn_err != nil {
		chat_session_record_failure(chat, "the prompt could not be recorded", turn_err)
		return .Storage_Failed
	}

	chat.turn_no = turn_no
	chat.active_turn_id = chat.next_turn_id
	chat.next_turn_id += 1
	chat.state = .Preparing
	chat.terminal_status = .None
	chat.active_failed = false
	chat.requests_made = 0
	chat.calls_made = 0
	chat.turn_deadline = ai.deadline_in(CHAT_TURN_DEADLINE)
	// A turn begins uncancelled, so a signal that arrived after the previous turn
	// finished can never be inherited by this one.
	chat_cancel_reset()
	chat_operation_retire(&chat.operation)
	clear(&chat.pending_calls)
	clear(&chat.pending_reasoning)
	delete(chat.last_error, chat.allocator)
	chat.last_error = ""
	delete(chat.partial_assistant)
	chat.partial_assistant = make([dynamic]u8, 0, 0, chat.allocator)
	return .Accepted
}

chat_session_state :: proc(chat: ^Chat_Session) -> Chat_State { return chat.state }
chat_session_turn_id :: proc(chat: ^Chat_Session) -> u64 { return chat.active_turn_id }
chat_session_last_error :: proc(chat: ^Chat_Session) -> string { return chat.last_error }

// --- operation ownership -----------------------------------------------------

chat_session_operation :: proc(chat: ^Chat_Session) -> ^Chat_Operation { return &chat.operation }

// chat_session_event_source is the identity the running operation's events must
// carry. It stays stable for the life of the operation, including while stopping.
chat_session_event_source :: proc(chat: ^Chat_Session) -> Chat_Event_Source {
	return Chat_Event_Source{turn_id = chat.active_turn_id, operation_id = chat.operation.id}
}

// chat_session_accepts_event is the single gate for turn state changes. An event
// is accepted only while its own operation is the running one, so an event from a
// cancelled, retired, or superseded operation cannot mutate a newer turn.
chat_session_accepts_event :: proc(chat: ^Chat_Session, source: Chat_Event_Source) -> bool {
	if chat.state != .Requesting && chat.state != .Streaming { return false }
	if chat.active_turn_id != source.turn_id { return false }
	if chat.operation.id != source.operation_id { return false }
	return chat.operation.state == .Running
}

// chat_session_begin_operation takes ownership of the next operation for the
// active turn. Its deadline is the per-operation bound, clamped so an operation
// can never outlive what remains of the turn bound; that clamp is how the turn
// bound reaches the transport and preempts a running request.
chat_session_begin_operation :: proc(chat: ^Chat_Session) {
	deadline := ai.deadline_in(CHAT_OPERATION_DEADLINE)
	if remaining, active := ai.deadline_remaining(chat.turn_deadline); active && remaining < CHAT_OPERATION_DEADLINE {
		deadline = chat.turn_deadline
	}
	chat.active_operation_id = chat.next_operation_id
	chat.next_operation_id += 1
	chat_operation_start(&chat.operation, chat.active_operation_id, chat.active_turn_id, deadline)
}

// chat_session_cancellable reports whether the turn still has work a cancellation
// request could stop.
chat_session_cancellable :: proc(chat: ^Chat_Session) -> bool {
	switch chat.state {
	case .Preparing, .Requesting, .Streaming, .Executing_Tools:
		return true
	case .Idle, .Cancelling, .Finalizing:
		return false
	}
	return false
}

// chat_session_note_cancel reconciles a turn whose interruption was requested
// outside the control loop, such as from a signal handler. The handler records the
// request; the loop decides what it means.
chat_session_note_cancel :: proc(chat: ^Chat_Session) {
	if chat_session_cancellable(chat) { chat.state = .Cancelling }
}

// chat_session_request_cancel requests interruption. It never finalizes: the turn
// settles only once retirement confirms the operation stopped.
chat_session_request_cancel :: proc(chat: ^Chat_Session) -> bool {
	if !chat_session_cancellable(chat) { return false }
	chat_cancel_request()
	chat_session_note_cancel(chat)
	return true
}

chat_session_cancelled :: proc(chat: ^Chat_Session) -> bool {
	return chat_cancel_requested()
}

// chat_session_retire_operation is the confirmation that the turn's work stopped.
chat_session_retire_operation :: proc(chat: ^Chat_Session) {
	chat_operation_retire(&chat.operation)
}
