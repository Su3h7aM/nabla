package agent

import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"

import "nabla:agent/journal"
import "nabla:agent/skills"
import "nabla:ai"

// Chat_Tool_Call is a validated tool call awaiting execution. call is the id its
// tool.proposed record carries, which its admission and completion name.
Chat_Tool_Call :: struct {
	id:        string, // owned
	item_id:   string, // owned
	name:      string, // owned
	arguments: string, // owned; raw JSON, exactly as the model sent it
	call:      journal.Call_Id,
}

// Chat_Response_Output stages one completed Responses output for commit: the
// terminal output array verbatim, exactly as the endpoint sent it. It is the
// replay record, owned here until the response commits, and only the Responses
// API sets it.
Chat_Response_Output :: struct {
	output: string, // owned; the verbatim output array
}

chat_response_output_destroy :: proc(output: ^Chat_Response_Output, allocator: mem.Allocator) {
	delete(output.output, allocator)
	output^ = {}
}

// chat_pending_response_clear drops the response output staged for the response being
// assembled, and with it the fact that one is staged. Every move of a staged response
// into the store ends this way.
chat_pending_response_clear :: proc(chat: ^Chat_Session) {
	chat_response_output_destroy(&chat.pending_response, chat.allocator)
	chat.pending_response_present = false
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
}

// Chat_Session is the running half of a session. Committed history lives in the
// journal; this holds only what the turn in flight needs.
//
// store is borrowed: the caller opens it, claims session, and keeps both for
// the chat's life. The chat writes through it from the owner thread only.
Chat_Session :: struct {
	store:                        ^journal.Journal,
	session:                      journal.Session_Id,
	session_hex:                  [journal.SESSION_ID_HEX_LENGTH]u8, // read through chat_session_text
	// branch and head are where the next node is appended: the active branch and
	// its newest node.
	branch:                       journal.Branch_Id,
	head:                         journal.Node_Id,
	allocator:                    mem.Allocator,
	state:                        Chat_State,
	terminal_status:              Chat_Terminal_Status,
	last_error:                   string, // owned

	// active_turn_id and the operation id are process-local identities. They
	// name an execution, not a durable turn; turn is the durable one, 0 between turns.
	active_turn_id:               u64,
	next_turn_id:                 u64,
	turn:                         journal.Turn_Id,
	// request is the response request in flight or last sent in the turn, 0 before one.
	request:                      journal.Request_Id,
	// response_node is the Assistant node of the response whose calls are running,
	// which their tool records name.
	response_node:                journal.Node_Id,
	next_operation_id:            u64,
	operation:                    Chat_Operation,

	// stop is the running turn's cancellation token. The owner requests it; the request
	// worker and tool executions read it. It is reset when a turn starts, while no worker
	// of an earlier turn remains.
	stop:                         ai.Interrupt,
	// control is the front-end's stop request for the turn in flight, borrowed for the
	// duration of chat_run_turn_steered and nil otherwise.
	control:                      ^Turn_Control,

	// chain is the request in flight between its attempts. It lives here because the
	// driver returns to its loop between one effect and the next: a retry wait is request
	// state, not a nested loop. It owns the prepared request and the frozen bytes until
	// chat_chain_commit releases them.
	chain:                        Chat_Request_Chain,

	// storage_failed latches a durable write that did not land. A session that
	// could not record its own history accepts no further work: continuing would
	// let the conversation diverge from what was stored.
	storage_failed:               bool,

	// abandoned_jobs are tool jobs whose workers ignored their stop. The session keeps
	// working; each job is released once its worker publishes, and until then nothing the
	// worker can reach (the workspace, the skill catalog, the tool backends) is freed.
	abandoned_jobs:               [dynamic]^Tool_Job,
	// abandoned_attempts are provider attempts whose workers ignored their stop, and
	// abandoned_compactions are summaries whose workers did. Each is released once its worker
	// publishes; until then nothing that worker can reach is freed.
	abandoned_attempts:           [dynamic]^Chat_Abandoned_Attempt,
	abandoned_compactions:        [dynamic]^Compact_Job,

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
	// provisional until the turn settles, and its storage is kept once the answer
	// is committed, so the next answer reuses it rather than growing a new buffer.
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
	// notice_detail is the provider's own account of the failure the notice explains:
	// owned, whole, and empty when the harness refused the response itself. It is
	// committed with the notice, because a refusal the model cannot read is one it
	// cannot correct.
	notice_detail:                string,
	// refused is the failure class of the provider refusal the turn's last notice
	// answered. The same refusal again means nothing the model adds will fix it.
	refused:                      ai.Provider_Failure_Class,
	requests_made:                int, // model requests made in this turn
	calls_made:                   int, // tool executions in this turn
	active_failed:                bool,
	workspace:                    string, // owned; validated process directory
	// tool_output_directory is where outputs larger than what the model is shown are kept
	// whole; owned, and "" when none resolves.
	tool_output_directory:        string,
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
	// cost is the resolved model's price per million tokens, copied from the catalog
	// when the model was selected. It prices the usage each committed response
	// reports; a zero cost prices nothing.
	cost:                         Catalog_Cost,
	// cache_hints_refused records that the endpoint refused a request carrying the cache
	// hints and accepted it without them, so later requests leave them out. It holds for the
	// model it was learned on and clears when another model is selected.
	cache_hints_refused:          bool,
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
	// compact_retry is the backoff a summary's own chain waits with. It is the session's
	// policy rather than the turn's, because compaction outlives the turn that asked for it
	// and may run while no turn does.
	compact_retry:                Chat_Retry_Policy,

	// skill_catalog is the frozen catalog from the instruction snapshot. Nil
	// means unavailable, never an instruction to rescan.
	skill_catalog:                Maybe(skills.Catalog),
	skill_instructions:           string, // owned; exact normal-request prefix
	client_instructions:          string, // owned; client-supplied standing system instructions
	// instructions_digest and manifest_digest name the snapshot artifacts that
	// skill_instructions and skill_catalog came from; zero until one is settled.
	instructions_digest:          journal.Digest,
	manifest_digest:              journal.Digest,
	disable_project_instructions: bool,

	// role_instructions are appended after everything else the instructions hold, so a
	// subagent's requests share its orchestrator's instruction prefix. Owned.
	role_instructions:            string,
	// team is the subagents this session started, heap-allocated so they may outlive a
	// session that could not stop them. member is set only in a subagent's own session: the
	// record its orchestrator keeps of it, which outlives this session.
	team:                         ^Agent_Team,
	member:                       ^Subagent,
	workers_retained:             bool,
	// acp_agents are the ACP agent programs subagents may run, borrowed from the loaded config.
	acp_agents:                   []ACP_Agent_Config,
	// inbox is where other agents' messages to this session wait for a settled point:
	// team.inbox in an orchestrator, member.inbox in a subagent. Borrowed.
	inbox:                        ^Steer_Queue,
	// catalog is where subagent models are resolved from, borrowed from the front-end. A
	// zero value lets subagents run only the orchestrator's own model.
	catalog:                      Catalog_Ref,
	// stop_parent is the wider stop this session's turns chain to when no front-end control
	// drives them; nil means the process interrupt.
	stop_parent:                  ^ai.Interrupt,
}

// chat_session_init builds the running state for a session the caller claimed in
// store, positioned at branch and head. A store without a claim makes session a new
// one, created by its first prompt. workspace is the validated process directory;
// it is copied, because the caller's copy may be temporary.
//
// The error is the zero value when the session is ready, and otherwise why it was not
// built: a tool registry error, or kind Allocation for an allocation the session's own
// state needed. Nothing is left owned when it is not the zero value.
//
// Diagnostics are not a field here. The session's work inherits the writer from
// context.logger, which is what lets a call site emit without threading one.
@(require_results)
chat_session_init :: proc(
	store: ^journal.Journal,
	session: journal.Session_Id,
	branch: journal.Branch_Id,
	head: journal.Node_Id,
	workspace: string,
	allocator := context.allocator,
) -> (
	Chat_Session,
	Tool_Registry_Error,
) {
	// The native definitions are compile-time constants, so a build failure
	// here is a programming error; the registry tests hold them to validity.
	// A partial registry is never installed: make destroys it before returning.
	tools, tool_error := tool_registry_make(allocator)
	if tool_error.kind != .None { return {}, tool_error }
	owned_workspace, clone_error := strings.clone(workspace, allocator)
	if clone_error != nil {
		tool_registry_destroy(&tools)
		return {}, Tool_Registry_Error{kind = .Allocation}
	}
	chat := Chat_Session {
		store             = store,
		session           = session,
		branch            = branch,
		head              = head,
		compact_retry     = chat_retry_policy_default(),
		allocator         = allocator,
		next_turn_id      = 1,
		next_operation_id = 1,
		workspace         = owned_workspace,
		tools             = tools,
	}
	// Every table of a new session holds nothing and so allocates nothing; each carries only
	// the allocator its first entry grows from.
	chat.partial_assistant.allocator = allocator
	chat.pending_calls.allocator = allocator
	chat.effort_levels.allocator = allocator
	chat.abandoned_jobs.allocator = allocator
	chat.abandoned_attempts.allocator = allocator
	chat.abandoned_compactions.allocator = allocator
	chat.tool_output_directory = tool_output_directory(chat_session_text(&chat), allocator)
	chat.team = agent_team_make(os.heap_allocator())
	if chat.team != nil { chat.inbox = &chat.team.inbox }
	return chat, {}
}

// chat_session_set_client_instructions replaces the standing instructions supplied by
// a client. The replacement invalidates the generated instruction snapshot so the next
// request renders the client's text together with the harness instructions.
@(require_results)
chat_session_set_client_instructions :: proc(chat: ^Chat_Session, instructions: string) -> bool {
	if chat.state != .Idle { return false }
	owned, clone_error := strings.clone(instructions, chat.allocator)
	if clone_error != nil { return false }
	delete(chat.client_instructions, chat.allocator)
	chat.client_instructions = owned
	delete(chat.skill_instructions, chat.allocator)
	chat.skill_instructions = ""
	chat_skill_catalog_release(chat)
	chat.instructions_digest = {}
	chat.manifest_digest = {}
	return true
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

// chat_skill_catalog_release drops the session's skill catalog. An abandoned worker may still
// read it, so while one is outstanding the catalog is left allocated.
chat_skill_catalog_release :: proc(chat: ^Chat_Session) {
	if catalog, present := &chat.skill_catalog.?; present && !chat_session_workers_outstanding(chat) {
		skills.catalog_destroy(catalog, chat.allocator)
	}
	chat.skill_catalog = nil
}

// chat_session_workers_outstanding reports whether an abandoned worker may still be running.
// While one is, what it can reach (the workspace, the skill catalog, the session's own stop
// token, the WebSocket, and the tool backends the caller owns) must stay allocated.
chat_session_workers_outstanding :: proc(chat: ^Chat_Session) -> bool {
	tool_jobs_reclaim(&chat.abandoned_jobs)
	chat_chain_attempts_reclaim(&chat.abandoned_attempts)
	return(
		chat.workers_retained ||
		len(chat.abandoned_jobs) > 0 ||
		len(chat.abandoned_attempts) > 0 ||
		agent_team_running(chat.team) ||
		(chat.team != nil && sync.atomic_load(&chat.team.abandoned)) \
	)
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
@(require_results)
chat_session_replace_tools :: proc(chat: ^Chat_Session, replacement: ^Tool_Registry) -> Tool_Registry_Replace_Error {
	if chat.state != .Idle { return .Busy }
	tool_registry_destroy(&chat.tools)
	chat.tools = replacement^
	replacement^ = {}
	return .None
}

// chat_session_apply_harness applies the launch's harness options to a session and its tool
// registry. The options must outlive the session.
@(require_results)
chat_session_apply_harness :: proc(chat: ^Chat_Session, options: Harness_Options) -> Tool_Registry_Error {
	chat.disable_project_instructions = options.disable_project_instructions
	chat.acp_agents = options.acp_agents
	return tool_registry_describe_agents(&chat.tools, options.acp_agents)
}

chat_session_destroy :: proc(chat: ^Chat_Session) {
	if chat.tool_jobs_active {
		tool_jobs_destroy(&chat.tool_jobs)
		chat.tool_jobs_active = false
	}
	retained := !agent_team_destroy(chat.team, len(chat.abandoned_jobs) > 0)
	chat.team = nil
	chat.inbox = nil
	chat.workers_retained = retained
	// Compaction's worker borrows this session's id for its logging correlation, so
	// it is stopped before anything the session owns is released.
	chat_compact_destroy(chat)
	// A worker that is still running keeps its job, the workspace, and the skill catalog, so
	// those are left to process exit rather than freed under it.
	outstanding := chat_session_workers_outstanding(chat)
	chat_skill_catalog_release(chat)
	if !outstanding { delete(chat.workspace, chat.allocator) }
	delete(chat.abandoned_jobs)
	chat_chain_release(chat)
	ai.Provider_Encode_Cache_Destroy(&chat.encode_cache)
	// A worker that ignored its stop may still be running a WebSocket request through this
	// session, so the session it borrowed is left allocated rather than destroyed under it.
	if chat.provider_websocket != nil && !chat_chain_websocket_retained(chat) {
		ai.Provider_WebSocket_Session_Destroy(chat.provider_websocket)
		chat.provider_websocket = nil
	}
	delete(chat.skill_instructions, chat.allocator)
	chat.skill_instructions = ""
	delete(chat.client_instructions, chat.allocator)
	chat.client_instructions = ""
	delete(chat.role_instructions, chat.allocator)
	delete(chat.partial_assistant)
	chat_pending_response_clear(chat)
	for &call in chat.pending_calls { chat_tool_call_destroy(&call, chat.allocator) }
	delete(chat.pending_calls)
	delete(chat.last_error, chat.allocator)
	for level in chat.effort_levels { delete(level, chat.allocator) }
	delete(chat.effort_levels)
	delete(chat.effort, chat.allocator)
	delete(chat.tool_output_directory, chat.allocator)
	delete(chat.provider_id, chat.allocator)
	delete(chat.model_id, chat.allocator)
	// An abandoned attempt and an abandoned summary are released only when their workers
	// publish, which nothing here waits for: the records stay allocated for the process.
	delete(chat.abandoned_attempts)
	delete(chat.abandoned_compactions)
	tool_registry_destroy(&chat.tools)
	chat^ = {
		workers_retained = outstanding,
	}
}

// chat_clone_string copies value with allocator. The caller owns the copy, and a copy that
// did not fit is reported rather than returned as an empty string, because a field set from
// an empty string would hold a value the caller never asked for.
@(require_results)
chat_clone_string :: proc(value: string, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	return strings.clone(value, allocator)
}

// chat_last_error_set replaces the session's own failure text, which is what the terminal
// status, the turn's record, and a front-end read. A text that cannot be kept leaves no
// reason rather than a stale one, and what the session could not keep is logged here
// instead, so the failure is still recorded somewhere.
chat_last_error_set :: proc(chat: ^Chat_Session, message: string) {
	delete(chat.last_error, chat.allocator)
	chat.last_error = ""
	cloned, clone_error := chat_clone_string(message, chat.allocator)
	if clone_error == nil {
		chat.last_error = cloned
		return
	}
	binding: Log_Binding
	previous_logger := context.logger
	defer context.logger = previous_logger
	context.logger = log_rebind(&binding, log_correlation(chat))
	fields := [2]Log_Field{{key = "detail", value = message}, {key = "detail_bytes", value = i64(len(message))}}
	log_emit({level = .Error, category = .Agent, event = "agent.failure_text_lost", fields = fields[:]})
}

// chat_pending_calls_clear releases calls a turn staged but never ran, such as
// when a durable write failed before they could be committed.
chat_pending_calls_clear :: proc(chat: ^Chat_Session) {
	for &call in chat.pending_calls { chat_tool_call_destroy(&call, chat.allocator) }
	clear(&chat.pending_calls)
}

// chat_partial_assistant_clear empties the streamed answer and keeps its storage.
// The longest answer of the session sizes the buffer, and every answer after it
// is written into what is already there instead of into a new, growing buffer.
chat_partial_assistant_clear :: proc(chat: ^Chat_Session) {
	clear(&chat.partial_assistant)
}

// CHAT_TITLE_MAX_BYTES bounds the derived title. It is a listing line, not a
// summary: enough to recognise a session and no more.
CHAT_TITLE_MAX_BYTES :: 80

// chat_title_from_prompt derives a session title from the prompt that opened it:
// the first line, trimmed and cut to a whole rune. The result is owned by
// allocator, and a title that did not fit is reported: a listing line the caller
// cannot have must not be mistaken for an empty one.
@(require_results)
chat_title_from_prompt :: proc(prompt: string, allocator := context.allocator) -> (string, mem.Allocator_Error) {
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
// The one kind that does not latch is a database another writer held past the busy
// timeout: nothing was written and the journal keeps the records for its next
// commit, so only this turn ends and the next one may go on. Every other failure
// leaves the record's state in question and stops the session's writes.
chat_session_record_failure :: proc(chat: ^Chat_Session, what: string, error: journal.Error) {
	detail := journal.error_text(error, chat.allocator)
	defer delete(detail, chat.allocator)
	chat_session_fail(chat, what, detail, latch = !journal.error_is_busy(error))
}

// chat_session_fail is the same stop for a failure the journal did not report,
// such as a snapshot the harness could not build. latch stops the session's writes
// for good; without it only the turn ends.
chat_session_fail :: proc(chat: ^Chat_Session, what: string, detail := "", latch := true) {
	if detail == "" {
		chat_last_error_set(chat, what)
	} else {
		joined, join_error := strings.concatenate({what, ": ", detail}, chat.allocator)
		if join_error != nil {
			// The failure is recorded and logged either way; the detail is what a join that
			// did not fit costs.
			chat_last_error_set(chat, what)
		} else {
			delete(chat.last_error, chat.allocator)
			chat.last_error = joined
		}
	}
	// The failure can be reached from any depth, so the binding is narrowed here to
	// the session the failure belongs to.
	binding: Log_Binding
	previous_logger := context.logger
	defer context.logger = previous_logger
	context.logger = log_rebind(&binding, log_correlation(chat))
	fields := [2]Log_Field{{key = "operation", value = what}, {key = "detail_bytes", value = i64(len(detail))}}
	log_emit({level = .Error, category = .Storage, event = "storage.failed", fields = fields[:]})
	chat.active_failed = true
	if latch { chat.storage_failed = true }
	chat.state = .Finalizing
}

// chat_session_accept_user admits a prompt: it opens a turn and commits the
// prompt as that turn's User node before any request is made.
chat_session_accept_user :: proc(chat: ^Chat_Session, text: string) -> Chat_Accept {
	return chat_session_accept_message(chat, text, .Prompt)
}

// chat_session_accept_message is chat_session_accept_user for text that did not come from
// the user, such as a subagent's report that arrived while no turn ran.
chat_session_accept_message :: proc(chat: ^Chat_Session, text: string, origin: journal.User_Origin) -> Chat_Accept {
	if chat.storage_failed { return .Storage_Failed }
	if chat.state != .Idle { return .Busy }

	// The turn does not exist yet, so the binding is installed with what is known
	// and its correlation is refreshed once the durable turn number is.
	binding: Log_Binding
	previous_logger := context.logger
	defer context.logger = previous_logger
	context.logger = log_rebind(&binding, log_correlation(chat))

	// A new session is created by its first prompt, so a session nobody prompted is
	// never recorded.
	if chat.store.claimed == {} {
		_, create_error := journal.create_session(chat.store, {id = chat.session, workspace = chat.workspace, role = .Main})
		if create_error != nil {
			chat_session_record_failure(chat, "the session could not be created", create_error)
			chat.state = .Idle
			return .Storage_Failed
		}
		chat.branch = journal.INITIAL_BRANCH
	}

	// The turn names the instruction snapshot it runs with, so it is settled first.
	// A failure latches the session with no turn open, so the chat stays idle.
	if !chat_ensure_instructions(chat) {
		chat.state = .Idle
		return .Storage_Failed
	}

	// The first turn names the session, so a listing says what each session was about
	// without asking the user to name it.
	first := chat.store.counters.turn == 0
	chat.turn = journal.next_turn(chat.store)
	chat.request = 0
	if first {
		title, title_error := chat_title_from_prompt(text, chat.allocator)
		if title_error != nil {
			// A session that cannot be named is still a session: the title is a listing
			// line, and the turn this prompt opens is what matters.
			log_emit({level = .Warning, category = .Agent, event = "agent.title_lost"})
		} else {
			defer delete(title, chat.allocator)
			chat_record(chat, {kind = .Session_Titled}, journal.Session_Titled{title = title})
		}
	}
	started := journal.Turn_Started {
		model  = chat.model_id,
		effort = chat.effort,
	}
	instructions_hex: [journal.DIGEST_HEX_LENGTH]u8
	manifest_hex: [journal.DIGEST_HEX_LENGTH]u8
	if chat.instructions_digest != {} {
		started.instructions = journal.digest_to_hex(chat.instructions_digest, instructions_hex[:])
		started.manifest = journal.digest_to_hex(chat.manifest_digest, manifest_hex[:])
	}
	chat_record(chat, {kind = .Turn_Started, provider = chat.provider_id, model = chat.model_id}, started)
	chat_node(chat, .User, journal.User{origin = journal.USER_ORIGIN_NAMES[origin]}, transmute([]u8)text)
	if !chat_commit(chat, "the prompt could not be recorded") {
		chat.turn = 0
		return .Storage_Failed
	}

	chat.active_turn_id = chat.next_turn_id
	chat.next_turn_id += 1
	chat.state = .Preparing
	chat.terminal_status = .None
	chat.turn_recovery = nil
	chat.refused = .None
	chat.turn_repair_refusal = .None
	chat.active_failed = false
	chat.requests_made = 0
	chat.calls_made = 0
	chat.stop = {
		parent = chat_stop_parent(chat),
	}
	chat_operation_retire(&chat.operation)
	chat_chain_release(chat)
	if chat.tool_jobs_active {
		tool_jobs_destroy(&chat.tool_jobs)
		chat.tool_jobs_active = false
	}
	chat_pending_calls_clear(chat)
	chat_notice_clear(chat)
	chat_pending_response_clear(chat)
	delete(chat.last_error, chat.allocator)
	chat.last_error = ""
	chat_partial_assistant_clear(chat)

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
@(require_results)
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
	previous_logger := context.logger
	defer context.logger = previous_logger
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

// chat_session_note_cancel moves a turn whose stop was requested into Cancelling, so
// the loop settles it.
chat_session_note_cancel :: proc(chat: ^Chat_Session) {
	if chat_session_cancellable(chat) { chat.state = .Cancelling }
}

// chat_session_request_cancel requests interruption. It never finalizes: the turn
// settles only once retirement confirms the operation stopped.
chat_session_request_cancel :: proc(chat: ^Chat_Session) -> bool {
	if !chat_session_cancellable(chat) { return false }
	ai.interrupt_request(&chat.stop)
	chat_session_note_cancel(chat)
	return true
}

chat_session_cancelled :: proc(chat: ^Chat_Session) -> bool {
	return ai.interrupt_requested(&chat.stop)
}

// chat_session_observe_stop moves a turn the front-end or the process stopped into
// Cancelling. The stop itself already reached everything that reads the turn's token,
// including a request blocked on the owner's thread; this is the state machine's side. It is
// also where the patience of an attempt in flight starts: the worker is given that long to
// confirm the stop before it is abandoned.
chat_session_observe_stop :: proc(chat: ^Chat_Session) {
	if !chat_session_cancelled(chat) { return }
	chat_session_note_cancel(chat)
	chat_chain_note_stop(chat, time.tick_now())
}

// chat_stop_parent is the token a turn's stop chains to: the front-end's control while
// one drives the turn, else the process interrupt.
@(private)
chat_stop_parent :: proc(chat: ^Chat_Session) -> ^ai.Interrupt {
	if chat.control != nil { return &chat.control.stop }
	if chat.stop_parent != nil { return chat.stop_parent }
	return &process_interrupt
}

// Turn_Control is how a front-end stops the turns it runs. The front-end owns it at an
// address that outlives every turn given it. Any thread may request a stop, which every
// wait of the running turn observes; the owner also wakes to apply it. The front-end
// clears it before starting a turn it has not asked to stop.
Turn_Control :: struct {
	stop: ai.Interrupt,
}

turn_control_stop :: proc "contextless" (control: ^Turn_Control) {
	ai.interrupt_request(&control.stop)
	owner_wake_signal()
}

turn_control_clear :: proc "contextless" (control: ^Turn_Control) {
	sync.atomic_store(&control.stop.requested, false)
}

// turn_control_stop_requested reports whether the front-end asked to stop, apart from
// the process interrupt.
turn_control_stop_requested :: proc "contextless" (control: ^Turn_Control) -> bool {
	return sync.atomic_load(&control.stop.requested)
}

// chat_session_retire_operation is the confirmation that the turn's work stopped.
chat_session_retire_operation :: proc(chat: ^Chat_Session) {
	chat_operation_retire(&chat.operation)
}
