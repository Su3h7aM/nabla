package agent

import "core:mem"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

import "nabla:agent/session"
import "nabla:agent/skills"
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

// Chat_Response_Output stages one completed Responses output for commit: the
// terminal output array verbatim, exactly as the endpoint sent it. Display
// text and executable calls are derived from the completion event alongside
// this; the output itself is the replay record, owned here until the response
// commits. Only the Responses API sets it; Chat Completions has no
// replayable output items to preserve. A Reasoning_Entry payload recorded
// before this change still decodes, so old sessions replay through the
// legacy path in the request builder.
Chat_Response_Output :: struct {
	output: string, // owned; verbatim output array,
}

chat_response_output_destroy :: proc(output: ^Chat_Response_Output, allocator: mem.Allocator) {
	delete(output.output, allocator)
	output^ = {}
}

// Chat_State is the control state of the session. Durable state lives in the
// store: these are transitions in flight, not conversation.
Chat_State :: enum {
	Idle,
	Preparing,
	Requesting,
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
	// A tool worker ignored its stop and still owns borrowed session data, so the
	// session must not run another turn.
	Worker_Escaped,
}

// Chat_Session is the running half of a session. Committed history lives in the
// store; this holds only what the turn in flight needs.
//
// store is borrowed and must outlive the chat; id is owned by the chat, because
// the claim that produced it can be released while the chat is still alive
// (a refused switch puts the running claim back, and the chat must not depend on
// that claim's storage). The caller owns the store, holds the writer claim for
// id, and keeps both alive for the session's lifetime.
Chat_Session :: struct {
	store:                        ^session.Store,
	id:                           session.Session_Id, // owned
	allocator:                    mem.Allocator,
	state:                        Chat_State,
	terminal_status:              Chat_Terminal_Status,
	last_error:                   string, // owned

	// active_turn_id and the operation id are process-local identities. They
	// name an execution, not a durable turn; turn_no is the durable one.
	active_turn_id:               u64,
	next_turn_id:                 u64,
	turn_no:                      Maybe(session.Turn_No),
	active_request:               Maybe(session.Request_No),
	next_operation_id:            u64,
	operation:                    Chat_Operation,

	// chain is the request in flight between its attempts. It lives here because the
	// driver returns to its loop between one effect and the next: a retry wait is request
	// state, not a nested loop. It owns the prepared request and the frozen bytes until
	// chat_chain_commit releases them.
	chain:                        Chat_Request_Chain,

	// mailbox is how the request worker hands facts to the owner thread. It is fixed-size,
	// owns only its queued payloads, and allocates them with its own allocator, which must be
	// safe to use from a worker.
	mailbox:                      Owner_Mailbox,

	// storage_failed latches a durable write that did not land. A session that
	// could not record its own history accepts no further work: continuing would
	// let the conversation diverge from what was stored.
	storage_failed:               bool,

	// worker_escaped latches a tool worker that ignored its stop and still owns borrowed
	// session data. The session accepts no further turn, and the process exits without
	// releasing anything that worker can reach.
	worker_escaped:               bool,

	// tools is the set of tools a turn may dispatch, owned by the chat. It is
	// replaceable while the chat is idle and frozen for the entire user turn,
	// so a response always runs against the definitions it was advertised
	// with. Replacement swaps whole registries; the registry is never mutated
	// in place, because dynamic-array growth could invalidate borrowed
	// definition pointers and a failed build could leave half of the new
	// inventory installed.
	tools:                        Tool_Registry,

	// tool_jobs is the response's in-flight execution table. It belongs to the
	// session rather than the driver's stack, so a turn can return to its event pump
	// while a worker blocks and a Lua parent can later suspend on a child.
	tool_jobs:                    Tool_Jobs,
	tool_jobs_active:             bool,

	// partial_assistant is streamed text that has not been committed. It stays
	// provisional until the turn settles.
	partial_assistant:            [dynamic]u8,

	// pending_response and pending_calls are what the current response produced
	// and has not committed yet. pending_response holds the verbatim Responses
	// output array; pending_calls holds the validated calls awaiting execution.
	pending_response:             Chat_Response_Output,
	pending_response_present:     bool,
	pending_calls:                [dynamic]Chat_Tool_Call,
	// pending_notice is why the running response could not be used. It is set
	// while the response is still streaming and committed with it, so the
	// explanation lands after the text it explains.
	pending_notice:               Chat_Notice,
	requests_made:                int, // model requests made in this turn
	calls_made:                   int, // tool executions in this turn
	active_failed:                bool,
	workspace:                    string, // owned; validated process directory
	provider_id:                  string, // owned; the provider requests are addressed to
	model_id:                     string, // owned; the model requests ask for
	provider_transport:           Provider_Transport,
	provider_websocket:           ^ai.Provider_WebSocket_Session,
	websocket_fallback_http:      bool,
	// encode_cache is what this session's own requests already wrote, kept so each
	// request writes only what changed since the one before it. One cache is walked by
	// one encode at a time: the requests of a turn are encoded by its thread, while the
	// background compaction encodes its own request with no cache at all.
	encode_cache:                 ai.Provider_Encode_Cache,
	tools_enabled:                bool, // frozen for the session's life
	// capacity is the resolved model's context budget, copied from the catalog when
	// the model was selected. It is the only thing that answers how much a request
	// may send, because it is the only thing that was divided.
	capacity:                     Model_Capacity,
	effort_levels:                [dynamic]string, // owned; allowed levels, verbatim
	effort:                       string, // owned; "" means provider default

	// last_input_measured is the last endpoint-reported input size, and
	// last_estimate is the harness's own count of the active context, kept for
	// the status line without touching the store from another thread. Usage
	// accumulation lives in the store: a refresh sums finished requests, so the
	// session totals never depend on which stream events already arrived.
	last_input_measured:          Maybe(i64),
	last_estimate:                int,
	// turn_recovery and turn_repair_refusal are why the last turn ended without
	// completing: the reason its chain stopped, and, when the context did not fit, what
	// stood in the way of making room. They are typed rather than read back out of a
	// message, so the turn's record and a front-end can tell "no summary exists" from
	// "the summary did not free enough" without parsing prose.
	turn_recovery:                Maybe(Request_Recovery_Reason),
	turn_repair_refusal:          Chat_Repair_Refusal,
	// response_cost is what the response the running turn committed added to the
	// model's context. A tool batch's budget subtracts it, because the response is
	// already part of the context the results are joining.
	response_cost:                int,

	// compact is the background compaction this session owns. It outlives any
	// single turn: a summary computed while the agent works is installed at a later
	// request boundary.
	compact:                      Compact_Control,
	// compact_retry bounds a summary's own chain. It is the session's policy rather than
	// the turn's, because compaction outlives the turn that asked for it and may run while
	// no turn does.
	compact_retry:                Chat_Retry_Policy,

	// skill_catalog is the frozen catalog from the instruction snapshot. Nil
	// means unavailable, never an instruction to rescan.
	skill_catalog:                Maybe(skills.Catalog),
	skill_instructions:           string, // owned; exact normal-request prefix
	skill_snapshot_seq:           Maybe(session.Seq),
	disable_project_instructions: bool,
}

// chat_session_init builds the running state for a claimed session. workspace is
// the validated process directory; it is copied, because the caller's copy may
// be temporary. The session id is copied too: the chat owns its identity rather
// than borrowing it from whichever claim happens to be in the store.
//
// Diagnostics are not a field here. The session's work inherits the writer from
// context.logger, which is what lets a call site emit without threading one.
chat_session_init :: proc(store: ^session.Store, id: session.Session_Id, workspace: string, allocator := context.allocator) -> (Chat_Session, Tool_Registry_Error) {
	// The native definitions are compile-time constants, so a build failure
	// here is a programming error; the registry tests hold them to validity.
	// A partial registry is never installed: make destroys it before returning.
	tools, tool_error := tool_registry_make(allocator)
	if tool_error.kind != .None { return {}, tool_error }
	chat := Chat_Session {
		store             = store,
		compact_retry     = chat_compact_retry_policy_default(),
		id                = session.Session_Id(strings.clone(string(id), allocator)),
		allocator         = allocator,
		next_turn_id      = 1,
		next_operation_id = 1,
		partial_assistant = make([dynamic]u8, 0, allocator),
		pending_calls     = make([dynamic]Chat_Tool_Call, 0, allocator),
		effort_levels     = make([dynamic]string, 0, allocator),
		workspace         = strings.clone(workspace, allocator),
		tools             = tools,
	}
	// A worker publishes through the mailbox, so its payloads come from the process heap
	// rather than from the allocator the owner may be writing through at the same time.
	mailbox_init(&chat.mailbox, os.heap_allocator())
	return chat, {}
}

chat_tool_call_destroy :: proc(call: ^Chat_Tool_Call, allocator: mem.Allocator) {
	delete(call.id, allocator)
	delete(call.item_id, allocator)
	delete(call.name, allocator)
	delete(call.arguments, allocator)
	call^ = {}
}

chat_skill_catalog :: proc(chat: ^Chat_Session) -> ^skills.Catalog {
	if catalog, present := &chat.skill_catalog.?; present { return catalog }
	return nil
}

// Tool_Registry_Replace_Error names why a registry replacement was refused.
// None is the zero value, so a fresh error reads as no error.
Tool_Registry_Replace_Error :: enum {
	None,
	// A turn is in flight, and it borrows the current registry. Replacing
	// now would pull the definitions out from under running requests.
	Busy,
}

// chat_session_replace_tools swaps the session's tool registry for a
// replacement the caller built. The swap is atomic: on success the old
// registry is destroyed and the session owns the replacement, whose struct the
// caller must no longer use; on Busy nothing changes and the caller keeps
// owning the replacement.
//
// Replacement is refused unless the chat is idle. Idle implies no turn is in
// flight, so no request preparation or tool execution can still borrow the
// old registry when it is destroyed. Each registry frees with its own
// allocator, so the replacement may come from any allocator.
//
// Whether a failed external refresh keeps the previous registry, removes
// unavailable tools, or blocks the next turn is the root package's policy
// once discovery exists; it does not belong here.
chat_session_replace_tools :: proc(chat: ^Chat_Session, replacement: ^Tool_Registry) -> Tool_Registry_Replace_Error {
	if chat.state != .Idle { return .Busy }
	tool_registry_destroy(&chat.tools)
	chat.tools = replacement^
	replacement^ = {}
	return .None
}

chat_session_destroy :: proc(chat: ^Chat_Session) {
	// A worker still running a call keeps the job it owns and the workspace, registry generation
	// and backends it borrows. The session says so rather than pretending the batch retired: what
	// to do with what such a worker can still reach is the caller's decision.
	if chat.tool_jobs_active {
		if tool_jobs_destroy(&chat.tool_jobs) { chat.worker_escaped = true }
		chat.tool_jobs_active = false
	}
	// Compaction's worker borrows this session's id for its logging correlation, so
	// it is stopped before anything the session owns is released.
	chat_compact_destroy(chat)
	chat_chain_release(chat)
	ai.Provider_Encode_Cache_Destroy(&chat.encode_cache)
	if chat.provider_websocket != nil {
		ai.Provider_WebSocket_Session_Destroy(chat.provider_websocket)
		chat.provider_websocket = nil
	}
	if catalog, present := &chat.skill_catalog.?; present { skills.catalog_destroy(catalog, chat.allocator) }
	chat.skill_catalog = nil
	delete(chat.skill_instructions, chat.allocator)
	chat.skill_instructions = ""
	delete(string(chat.id), chat.allocator)
	delete(chat.partial_assistant)
	if chat.pending_response_present { chat_response_output_destroy(&chat.pending_response, chat.allocator) }
	for &call in chat.pending_calls { chat_tool_call_destroy(&call, chat.allocator) }
	delete(chat.pending_calls)
	delete(chat.last_error, chat.allocator)
	for level in chat.effort_levels { delete(level, chat.allocator) }
	delete(chat.effort_levels)
	delete(chat.effort, chat.allocator)
	delete(chat.workspace, chat.allocator)
	delete(chat.provider_id, chat.allocator)
	delete(chat.model_id, chat.allocator)
	tool_registry_destroy(&chat.tools)
	chat^ = {}
}

chat_clone_string :: proc(value: string, allocator: mem.Allocator) -> string {
	return strings.clone(value, allocator)
}

// chat_pending_calls_clear releases calls a turn staged but never ran, such as
// when a durable write failed before they could be committed.
chat_pending_calls_clear :: proc(chat: ^Chat_Session) {
	for &call in chat.pending_calls { chat_tool_call_destroy(&call, chat.allocator) }
	clear(&chat.pending_calls)
}

// CHAT_TITLE_MAX_BYTES bounds the derived title. It is a listing line, not a
// summary: enough to recognise a session and no more.
CHAT_TITLE_MAX_BYTES :: 80

// chat_title_from_prompt derives a session title from the prompt that opened it:
// the first line, trimmed and cut to a whole rune. The result is owned by
// allocator.
chat_title_from_prompt :: proc(prompt: string, allocator := context.allocator) -> string {
	line := prompt
	if newline := strings.index_byte(line, '\n'); newline >= 0 { line = line[:newline] }
	line = strings.trim_space(line)
	if len(line) > CHAT_TITLE_MAX_BYTES {
		line = line[:CHAT_TITLE_MAX_BYTES]
		for len(line) > 0 {
			_, width := utf8.decode_last_rune_in_string(line)
			if width > 0 { break }
			line = line[:len(line) - 1]
		}
	}
	return strings.clone(line, allocator)
}

// chat_session_record_failure stops the turn because a durable write failed. The
// turn is not allowed to continue from memory: the record did not land, and
// carrying on would let the conversation diverge from what was stored.
//
// The latch is deliberately not conditioned on the error kind. A write that
// failed for any reason leaves the record's state in question, and separating
// the kinds here would buy a more permissive policy at the cost of having to
// reason about which failures are safe to continue past.
chat_session_record_failure :: proc(chat: ^Chat_Session, what: string, err: session.Error) {
	local := err
	chat_session_record_failure_detail(chat, what, session.error_detail(&local), session.error_kind(local))
}

// chat_session_record_failure_detail is the same storage stop for failures that
// happen before the store sees a row, such as encoding a request record. Keeping
// the detail separate lets those failures join the same latched state without
// inventing a fake session-store error.
chat_session_record_failure_detail :: proc(chat: ^Chat_Session, what: string, detail: string, kind: session.Error_Kind) {
	delete(chat.last_error, chat.allocator)
	if what == "" {
		chat.last_error = chat_clone_string(detail, chat.allocator)
	} else {
		chat.last_error = strings.concatenate({what, ": ", detail}, chat.allocator)
	}
	// The record names the local step that failed, the store's classification, and
	// how much detail the store gave. The text itself stays out: a storage failure
	// is a local exception, and one can name a path or a row. The full message is
	// what the front-end shows, which is outside the persisted stream.
	// The failure can be reached from any depth, so the binding is narrowed here to
	// the session the failure belongs to.
	binding: Log_Binding
	context.logger = log_rebind(&binding, log_correlation(chat))
	fields := [3]Log_Field {
		{key = "operation", value = what},
		{key = "error_kind", value = log_error_kind_name(kind)},
		{key = "detail_bytes", value = i64(len(detail))},
	}
	log_emit({level = .Error, category = .Storage, event = "storage.failed", fields = fields[:]})
	chat.active_failed = true
	chat.storage_failed = true
	chat.state = .Finalizing
}

// chat_session_accept_user admits a prompt: it opens a turn and records the
// prompt as that turn's first entry before any request is made.
chat_session_accept_user :: proc(chat: ^Chat_Session, text: string, at_ms: i64) -> Chat_Accept {
	if chat.worker_escaped { return .Worker_Escaped }
	if chat.storage_failed { return .Storage_Failed }
	if chat.state != .Idle { return .Busy }

	// The turn does not exist yet, so the binding is installed with what is known
	// and its correlation is refreshed once the durable turn number is.
	binding: Log_Binding
	context.logger = log_rebind(&binding, log_correlation(chat))

	// The first prompt is what records the session. Everything below needs the row
	// to exist, and the write leaves a session that already has one alone, so a
	// resumed session keeps the time and title it was created with.
	header := session.Session {
		id            = chat.id,
		created_at_ms = at_ms,
		updated_at_ms = at_ms,
		workspace     = chat.workspace,
		provider      = chat.provider_id,
		model         = chat.model_id,
	}
	if record_err := session.session_record(chat.store, header); record_err != nil {
		chat_session_record_failure(chat, "the session could not be recorded", record_err)
		return .Storage_Failed
	}

	// The header records which model the session last ran with, so a later
	// continuation starts from it rather than from nothing.
	if chat.provider_id != "" && chat.model_id != "" {
		if model_err := session.session_set_model(chat.store, chat.id, chat.provider_id, chat.model_id); model_err != nil {
			chat_session_record_failure(chat, "the session model could not be recorded", model_err)
			return .Storage_Failed
		}
	}
	// The first prompt names the session, so a listing says what each session was
	// about without asking the user to name it.
	if chat.next_turn_id == 1 {
		title := chat_title_from_prompt(text, chat.allocator)
		defer delete(title, chat.allocator)
		if title_err := session.session_set_title_if_untitled(chat.store, chat.id, title); title_err != nil {
			chat_session_record_failure(chat, "the session title could not be recorded", title_err)
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
	chat.turn_recovery = nil
	chat.turn_repair_refusal = .None
	chat.active_failed = false
	chat.requests_made = 0
	chat.calls_made = 0
	// A turn begins uncancelled, so a signal that arrived after the previous turn
	// finished can never be inherited by this one.
	chat_cancel_reset()
	chat_operation_retire(&chat.operation)
	chat_chain_release(chat)
	if chat.tool_jobs_active {
		// The batch is released, and a worker still running a call keeps what it borrows from
		// this session: the session refuses further work rather than reusing a busy backend.
		if tool_jobs_destroy(&chat.tool_jobs) { chat.worker_escaped = true }
		chat.tool_jobs_active = false
	}
	chat_pending_calls_clear(chat)
	chat.pending_notice = .None
	if chat.pending_response_present {
		chat_response_output_destroy(&chat.pending_response, chat.allocator)
		chat.pending_response_present = false
	}
	delete(chat.last_error, chat.allocator)
	chat.last_error = ""
	delete(chat.partial_assistant)
	chat.partial_assistant = make([dynamic]u8, 0, 0, chat.allocator)

	fields := [1]Log_Field{{key = "prompt_bytes", value = i64(len(text))}}
	binding.correlation = log_correlation(chat)
	log_emit({level = .Info, category = .Agent, event = "turn.started", fields = fields[:]})
	return .Accepted
}

chat_session_state :: proc(chat: ^Chat_Session) -> Chat_State { return chat.state }
chat_session_turn_id :: proc(chat: ^Chat_Session) -> u64 { return chat.active_turn_id }
chat_session_last_error :: proc(chat: ^Chat_Session) -> string { return chat.last_error }

// chat_session_storage_failed reports whether a durable write failed and latched
// the session. The front-end reads this to report a command that failed only
// because the store did.
chat_session_storage_failed :: proc(chat: ^Chat_Session) -> bool { return chat.storage_failed }

// --- operation ownership -----------------------------------------------------

// chat_session_event_source is the identity the running operation's events must
// carry. It stays stable for the life of the operation, including while stopping.
chat_session_event_source :: proc(chat: ^Chat_Session) -> Chat_Event_Source {
	return Chat_Event_Source{turn_id = chat.active_turn_id, operation_id = chat.operation.id}
}

// chat_session_accepts_event is the single gate for turn state changes. An event
// is accepted only while its own operation is the running one, so an event from a
// cancelled, retired, or superseded operation cannot mutate a newer turn. A
// refusal is recorded with its reason: dropping the event is correct, and the
// reason is what makes the drop legible later.
chat_session_accepts_event :: proc(chat: ^Chat_Session, source: Chat_Event_Source) -> bool {
	reason := ""
	switch {
	case chat.state != .Requesting:
		reason = "not_receiving"
	case chat.active_turn_id != source.turn_id:
		reason = "superseded_turn"
	case chat.operation.id != source.operation_id:
		reason = "superseded_operation"
	case chat.operation.state != .Running:
		reason = "operation_retired"
	}
	if reason == "" { return true }

	// The refused event is recorded against the session and the operation the
	// harness is actually running, not the one the event claimed.
	binding: Log_Binding
	context.logger = log_rebind(&binding, log_correlation(chat))
	fields := [4]Log_Field {
		{key = "reason", value = reason},
		{key = "supplied_turn", value = i64(source.turn_id)},
		{key = "supplied_operation", value = source.operation_id},
		{key = "current_operation", value = chat.operation.id},
	}
	log_emit({level = .Debug, category = .Agent, event = "agent.event_ignored", fields = fields[:]})
	return false
}

// chat_session_begin_operation takes ownership of the next operation for the
// active turn. The operation carries identity only: the request it names runs
// until the provider, the transport, or cancellation ends it.
chat_session_begin_operation :: proc(chat: ^Chat_Session) {
	id := chat.next_operation_id
	chat.next_operation_id += 1
	chat_operation_start(&chat.operation, id)
}

// chat_session_cancellable reports whether the turn still has work a cancellation
// request could stop.
chat_session_cancellable :: proc(chat: ^Chat_Session) -> bool {
	switch chat.state {
	case .Preparing, .Requesting, .Executing_Tools:
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
