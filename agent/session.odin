package agent

import "core:mem"
import "core:os"
import "core:strings"

import "nabla:ai"

Chat_Role :: enum {
	User,
	Assistant,
	Tool,
}

Chat_Tool_Call :: struct {
	id:        string, // owned; Chat id / Responses call_id,
	item_id:   string, // owned; Responses output-item id, "" for Chat,
	name:      string, // owned,
	arguments: string, // owned; raw JSON object,
}

Chat_Message :: struct {
	role:                Chat_Role,
	text:                string, // owned; assistant text or tool result JSON,
	tool_call:           Chat_Tool_Call, // owned; set when role == .Assistant and this message is a call,
	is_tool_call:        bool,
	tool_call_id:        string, // owned; set when role == .Tool, matches the call,
	is_system:           bool, // owned text is a prompt, never user content,
	is_reasoning:        bool, // opaque Responses reasoning item, kept for replay in wire order,
	reasoning_id:        string, // owned; output-item id, present when is_reasoning,
	reasoning_encrypted: string, // owned; encrypted content, "" when the endpoint sent none,
}

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

Chat_Session :: struct {
	messages:                    [dynamic]Chat_Message,
	allocator:                   mem.Allocator,
	state:                       Chat_State,
	terminal_status:             Chat_Terminal_Status,
	last_error:                  string,
	active_turn_id:              u64,
	next_turn_id:                u64,
	active_operation_id:         u64,
	next_operation_id:           u64,
	operation:                   Chat_Operation,
	turn_deadline:               ai.Deadline,
	partial_assistant:           [dynamic]u8,
	pending_calls:               [dynamic]Chat_Tool_Call, // owned; validated handoff awaiting execution,
	requests_made:               int, // model requests this turn; bounds the tool loop,
	calls_made:                  int, // tool executions this turn,
	active_failed:               bool,
	workspace:                   string, // owned; validated process directory at session creation,
	tools_enabled:               bool, // frozen: model supports tools and the adapter carries calls,
	max_output_tokens:           int, // frozen: 0 means unset,
	// Selected-model limits, frozen from configuration. A zero context window
	// means unconfigured; effort_levels empty means effort is unconfigured.
	context_window:              int,
	effort_levels:               [dynamic]string, // owned; allowed effort levels, verbatim,
	effort:                      string, // owned; "" means provider default,
	// Last measured input tokens from endpoint usage, for /context display.
	last_input_measured:         i64,
	last_input_measured_present: bool,
	// active_start is where the request context begins. Full history stays in
	// messages; compaction moves this forward, never deletes.
	active_start:                int,
	// auto_compacted_turn records the turn automatic compaction already ran
	// in, so a turn that still cannot fit fails instead of compacting forever.
	auto_compacted_turn:         u64,
}

chat_session_init :: proc(allocator := context.allocator) -> Chat_Session {
	workspace, workspace_err := os.get_working_directory(allocator)
	owned_workspace := ""
	if workspace_err == nil && workspace != "" {
		owned_workspace = strings.clone(workspace, allocator)
		delete(workspace, allocator)
	}
	return Chat_Session {
		messages = make([dynamic]Chat_Message, 0, allocator),
		allocator = allocator,
		next_turn_id = 1,
		next_operation_id = 1,
		partial_assistant = make([dynamic]u8, 0, 0, allocator),
		effort_levels = make([dynamic]string, 0, allocator),
		workspace = owned_workspace,
	}
}

chat_message_destroy :: proc(message: ^Chat_Message, allocator: mem.Allocator) {
	if message.text != "" || message.is_system { delete(message.text, allocator) }
	if message.tool_call.id != "" { delete(message.tool_call.id, allocator) }
	if message.tool_call.item_id != "" { delete(message.tool_call.item_id, allocator) }
	if message.tool_call.name != "" { delete(message.tool_call.name, allocator) }
	if message.tool_call.arguments != "" { delete(message.tool_call.arguments, allocator) }
	if message.tool_call_id != "" { delete(message.tool_call_id, allocator) }
	if message.reasoning_id != "" { delete(message.reasoning_id, allocator) }
	if message.reasoning_encrypted != "" { delete(message.reasoning_encrypted, allocator) }
	message^ = {}
}

chat_message_clone :: proc(message: Chat_Message, allocator: mem.Allocator) -> Chat_Message {
	return Chat_Message {
		role = message.role,
		text = chat_clone_string(message.text, allocator),
		is_system = message.is_system,
		tool_call = Chat_Tool_Call {
			id = chat_clone_string(message.tool_call.id, allocator),
			item_id = chat_clone_string(message.tool_call.item_id, allocator),
			name = chat_clone_string(message.tool_call.name, allocator),
			arguments = chat_clone_string(message.tool_call.arguments, allocator),
		},
		is_tool_call = message.is_tool_call,
		tool_call_id = chat_clone_string(message.tool_call_id, allocator),
		is_reasoning = message.is_reasoning,
		reasoning_id = chat_clone_string(message.reasoning_id, allocator),
		reasoning_encrypted = chat_clone_string(message.reasoning_encrypted, allocator),
	}
}

chat_tool_call_destroy :: proc(call: ^Chat_Tool_Call, allocator: mem.Allocator) {
	if call.id != "" { delete(call.id, allocator) }
	if call.item_id != "" { delete(call.item_id, allocator) }
	if call.name != "" { delete(call.name, allocator) }
	if call.arguments != "" { delete(call.arguments, allocator) }
	call^ = {}
}

chat_session_destroy :: proc(session: ^Chat_Session) {
	for &message in session.messages { chat_message_destroy(&message, session.allocator) }
	delete(session.messages)
	for &call in session.pending_calls { chat_tool_call_destroy(&call, session.allocator) }
	delete(session.pending_calls)
	delete(session.last_error, session.allocator)
	delete(session.partial_assistant)
	for level in session.effort_levels { delete(level, session.allocator) }
	delete(session.effort_levels)
	delete(session.effort, session.allocator)
	if session.workspace != "" { delete(session.workspace, session.allocator) }
	session^ = {}
}

chat_clone_string :: proc(value: string, allocator: mem.Allocator) -> string {
	return strings.clone(value, allocator)
}

chat_session_accept_user :: proc(session: ^Chat_Session, text: string) -> bool {
	if session.state != .Idle { return false }
	append(&session.messages, Chat_Message{role = .User, text = chat_clone_string(text, session.allocator)})
	session.active_turn_id = session.next_turn_id
	session.next_turn_id += 1
	session.state = .Preparing
	session.terminal_status = .None
	session.active_failed = false
	session.requests_made = 0
	session.calls_made = 0
	session.turn_deadline = ai.deadline_in(CHAT_TURN_DEADLINE)
	// A turn begins uncancelled, so a signal that arrived after the previous turn
	// finished can never be inherited by this one.
	chat_cancel_reset()
	chat_operation_retire(&session.operation)
	for &call in session.pending_calls { chat_tool_call_destroy(&call, session.allocator) }
	clear(&session.pending_calls)
	delete(session.last_error, session.allocator)
	session.last_error = ""
	delete(session.partial_assistant)
	session.partial_assistant = make([dynamic]u8, 0, 0, session.allocator)
	return true
}

chat_session_messages :: proc(session: ^Chat_Session) -> []Chat_Message { return session.messages[:] }
chat_session_state :: proc(session: ^Chat_Session) -> Chat_State { return session.state }
chat_session_turn_id :: proc(session: ^Chat_Session) -> u64 { return session.active_turn_id }
chat_session_last_error :: proc(session: ^Chat_Session) -> string { return session.last_error }

// --- operation ownership -----------------------------------------------------

chat_session_operation :: proc(session: ^Chat_Session) -> ^Chat_Operation { return &session.operation }

// chat_session_event_source is the identity the running operation's events must
// carry. It stays stable for the life of the operation, including while stopping.
chat_session_event_source :: proc(session: ^Chat_Session) -> Chat_Event_Source {
	return Chat_Event_Source{turn_id = session.active_turn_id, operation_id = session.operation.id}
}

// chat_session_accepts_event is the single gate for turn state changes. An event
// is accepted only while its own operation is the running one, so an event from a
// cancelled, retired, or superseded operation cannot mutate a newer turn.
chat_session_accepts_event :: proc(session: ^Chat_Session, source: Chat_Event_Source) -> bool {
	if session.state != .Requesting && session.state != .Streaming { return false }
	if session.active_turn_id != source.turn_id { return false }
	if session.operation.id != source.operation_id { return false }
	return session.operation.state == .Running
}

// chat_session_begin_operation takes ownership of the next operation for the
// active turn. Its deadline is the per-operation bound, clamped so an operation
// can never outlive what remains of the turn bound; that clamp is how the turn
// bound reaches the transport and preempts a running request.
chat_session_begin_operation :: proc(session: ^Chat_Session) {
	deadline := ai.deadline_in(CHAT_OPERATION_DEADLINE)
	if remaining, active := ai.deadline_remaining(session.turn_deadline); active && remaining < CHAT_OPERATION_DEADLINE {
		deadline = session.turn_deadline
	}
	session.active_operation_id = session.next_operation_id
	session.next_operation_id += 1
	chat_operation_start(&session.operation, session.active_operation_id, session.active_turn_id, deadline)
}

// chat_session_cancellable reports whether the turn still has work a cancellation
// request could stop.
chat_session_cancellable :: proc(session: ^Chat_Session) -> bool {
	switch session.state {
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
chat_session_note_cancel :: proc(session: ^Chat_Session) {
	if chat_session_cancellable(session) { session.state = .Cancelling }
}

// chat_session_request_cancel requests interruption. It never finalizes: the turn
// settles only once retirement confirms the operation stopped.
chat_session_request_cancel :: proc(session: ^Chat_Session) -> bool {
	if !chat_session_cancellable(session) { return false }
	chat_cancel_request()
	chat_session_note_cancel(session)
	return true
}

chat_session_cancelled :: proc(session: ^Chat_Session) -> bool {
	return chat_cancel_requested()
}

// chat_session_retire_operation is the confirmation that the turn's work stopped.
chat_session_retire_operation :: proc(session: ^Chat_Session) {
	chat_operation_retire(&session.operation)
}
