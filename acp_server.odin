#+build linux
package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"

import "nabla:acp"
import "nabla:agent"
import "nabla:agent/session"

// The ACP agent front-end: one process, one session, one prompt turn at a time,
// speaking the Agent Client Protocol on the streams it was given. A client (an editor)
// starts the process, initializes it, opens a session for a working directory, and
// sends prompts. The session and the turn loop underneath are the harness's own, so an
// editor conversation is the same conversation the interactive and headless front-ends
// run.
//
// Two threads. The reader owns the protocol conversation: it reads messages, answers
// what it can answer alone, and hands session work to the worker. The worker owns the
// session: it opens sessions, runs turns, and writes everything a turn produces. The
// split exists because a client cancels a running turn by sending another message on the
// same stream, so nothing may block the reader while a turn runs.

// ACP_WORK_CAPACITY bounds requests waiting for the worker. The reader admits one
// session request at a time, so the queue holds the request being served and, briefly,
// nothing else.
ACP_WORK_CAPACITY :: 4

// ACP_READ_BYTES is how much of the input stream one read takes. A frame is bounded by
// the decoder; this only bounds a syscall.
ACP_READ_BYTES :: 16 * 1024

Acp_Work_Kind :: enum {
	// Open_Session opens the session a client asked for: a new one in its working
	// directory, or a stored one it names.
	Open_Session,
	// Prompt runs one turn on the open session.
	Prompt,
}

// Acp_Work is one request the reader handed to the worker. Every string is owned by the
// server's allocator and released by acp_work_destroy.
Acp_Work :: struct {
	kind:        Acp_Work_Kind,
	id:          acp.Jsonrpc_Id, // the request to answer
	// text is the prompt of a Prompt; workspace is where a new session runs;
	// session_ref names a stored session for an Open_Session.
	text:        string,
	workspace:   string,
	session_ref: string,
	// start is the session an Open_Session opens. Its id aliases session_ref.
	start:       Session_Start,
}

Acp_Work_Chan :: chan.Chan(Acp_Work)

// Acp_Server is the whole front-end: the harness runtime, the writer, the worker, and
// the little of the protocol's own state that is not the harness's.
Acp_Server :: struct {
	app:         App,
	alloc:       mem.Allocator,
	writer:      acp.Writer,
	work:        Acp_Work_Chan,
	worker:      ^thread.Thread,
	// busy is the reader's and the worker's agreement about the one request in flight:
	// the reader accepts a session request or a prompt only when it is false, and the
	// worker clears it once the request has been answered.
	busy:        bool, // atomic
	// cancel_seen is set when a cancellation arrived while a turn was still being
	// recorded. Accepting a prompt clears the process's cancellation token, so the worker
	// re-issues a cancellation it must not lose. Cleared by the worker between requests.
	cancel_seen: bool, // atomic
	// initialized is set once initialize has been answered. Only the reader writes it.
	initialized: bool,
	// mu guards session_id, which the reader matches a cancellation against and the
	// worker replaces after opening a session.
	mu:          sync.Mutex,
	session_id:  string, // owned
	// message_seq numbers the messages a turn streams, so chunks of one message share an
	// id in the client. Only the worker writes it.
	message_seq: u64,
}

// --- lifetime ----------------------------------------------------------------

// acp_work_destroy releases the strings one queued request owns.
acp_work_destroy :: proc(work: ^Acp_Work, allocator: mem.Allocator) {
	switch id in work.id {
	case string:
		delete(id, allocator)
	case i64, f64:
	}
	delete(work.text, allocator)
	delete(work.workspace, allocator)
	delete(work.session_ref, allocator)
	work^ = {}
}

// acp_work_id copies the request id a response will carry. Only the string form owns
// memory; a numeric id is a value.
acp_work_id :: proc(id: acp.Jsonrpc_Id, allocator: mem.Allocator) -> acp.Jsonrpc_Id {
	switch value in id {
	case string:
		return strings.clone(value, allocator)
	case i64, f64:
		return id
	}
	return id
}

// acp_server_destroy releases everything the server owns. It must run after the worker
// has retired: a worker that ignored its stop still borrows the session, the workspace,
// and the tool backends, and those are not handed back while it can reach them.
acp_server_destroy :: proc(server: ^Acp_Server) {
	// A turn still running is stopped before the worker is joined, so it settles as
	// cancelled and the record says the session was interrupted.
	if sync.atomic_load(&server.busy) { agent.chat_cancel_request() }
	if server.work != {} { chan.close(&server.work) }
	if server.worker != nil {
		if join_retiring(server.worker, "nabla-acp-worker") {
			server.worker = nil
		} else {
			// The worker still owns the session and the log binding. Nothing below may
			// run; the process exits with what that thread can reach.
			agent.log_emit(agent.Log_Record{level = .Error, category = .Runtime, event = "runtime.teardown_abandoned"})
			return
		}
	}
	for {
		queued, ok := chan.recv(server.work)
		if !ok { break }
		acp_work_destroy(&queued, server.alloc)
	}
	if server.work != {} { chan.destroy(&server.work) }
	acp.writer_destroy(&server.writer)
	sync.mutex_lock(&server.mu)
	delete(server.session_id, server.alloc)
	server.session_id = ""
	sync.mutex_unlock(&server.mu)
	snapshot_destroy(&server.app)
	if agent.chat_session_worker_escaped(&server.app.setup.session) {
		agent.log_emit(agent.Log_Record{level = .Error, category = .Runtime, event = "runtime.worker_escaped"})
		return
	}
	run_setup_destroy(&server.app.setup)
}

// --- the worker --------------------------------------------------------------

// acp_worker runs the requests the reader hands over and owns the session while it does.
// It leaves when the queue is closed and drained.
acp_worker :: proc(thread_handle: ^thread.Thread) {
	server := cast(^Acp_Server)thread_handle.data
	// A thread started without init_context gets the default context, so the run's
	// logger is installed here.
	context.logger = agent.log_logger(&server.app.setup.log_binding)
	for {
		work, ok := chan.recv(server.work)
		if !ok { break }
		acp_run_work(server, work)
		acp_work_destroy(&work, server.alloc)
		if agent.chat_session_worker_escaped(&server.app.setup.session) { break }
		// Temp scratch belongs to one request: the worker is long-lived, so its pool is
		// recycled here rather than left to grow with the conversation.
		free_all(context.temp_allocator)
	}
}

acp_run_work :: proc(server: ^Acp_Server, work: Acp_Work) {
	switch work.kind {
	case .Open_Session:
		acp_work_open_session(server, work)
	case .Prompt:
		acp_work_prompt(server, work)
	}
	if agent.chat_session_worker_escaped(&server.app.setup.session) { return }
	// The request is answered, so the next one may be admitted. The cancellation belongs
	// to the turn that just ended; a client that cancels a finished turn is ignored.
	sync.atomic_store(&server.cancel_seen, false)
	sync.atomic_store(&server.busy, false)
}

// --- opening a session -------------------------------------------------------

acp_work_open_session :: proc(server: ^Acp_Server, work: Acp_Work) {
	message, opened := acp_session_open(server, work.workspace, work.start)
	if !opened {
		defer delete(message, server.alloc)
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INVALID_PARAMS, message)
		return
	}
	acp_session_select_model(server)
	session_id := string(server.app.setup.session.id)
	sync.mutex_lock(&server.mu)
	delete(server.session_id, server.alloc)
	server.session_id = strings.clone(session_id, server.alloc)
	sync.mutex_unlock(&server.mu)
	// A loaded conversation is streamed before its answer: the client shows the
	// conversation it asked for, and only then learns that the session is ready. A new
	// session answers with its id; a loaded one has nothing to add.
	if work.start.kind == .Resume_Id {
		acp_replay_session(server)
		_ = acp.writer_write_response(&server.writer, work.id, acp.Empty_Result{})
	} else {
		_ = acp.writer_write_response(&server.writer, work.id, acp.Session_New_Result{session_id = session_id})
	}
}

// acp_session_open makes one session the running one: the client's working directory for
// a new conversation, the stored session for a loaded one. A session the process already
// held is given up, because the harness claims one session at a time and a client asking
// for a session is asking for that conversation and no other.
//
// The message of a refusal is owned by the setup's allocator.
acp_session_open :: proc(server: ^Acp_Server, workspace: string, start: Session_Start) -> (message: string, ok: bool) {
	app := &server.app
	if agent.chat_session_worker_escaped(&app.setup.session) {
		return strings.clone(agent.CHAT_WORKER_ESCAPED_NOTICE, app.setup.alloc), false
	}
	// Loading the session this process already runs is not a switch: it is the same
	// conversation, and the harness would refuse to claim it twice.
	if start.kind == .Resume_Id && string(app.setup.session.id) == start.id { return "", true }

	target, resolved := session_open_target(&app.setup, start, workspace, stderr_writer())
	if !resolved {
		if start.id == "" { return strings.clone("a session could not be started", app.setup.alloc), false }
		return strings.concatenate({"the session could not be opened: ", start.id}, app.setup.alloc), false
	}
	defer session_target_destroy(&target, app.setup.alloc)
	// The directory a session records is where it ran, and a stored session can be opened
	// from anywhere, so it is checked rather than assumed.
	if !os.is_dir(target.workspace) {
		return fmt.aprintf("the session's directory is not usable: %s", target.workspace, allocator = app.setup.alloc), false
	}
	adoption, adopt_message, adopted := session_adopt_target(&app.setup, start.kind, target)
	if !adopted { return adopt_message, false }
	defer adoption_destroy(&adoption, app.setup.alloc)
	report_recovery(adoption.recovery)

	claimed, held := session.session_claimed(&app.setup.store)
	if !held { return strings.clone("the session claim went missing", app.setup.alloc), false }

	agent.chat_session_destroy(&app.setup.session)
	delete(app.setup.workspace, app.setup.alloc)
	app.setup.workspace = strings.clone(adoption.header.workspace, app.setup.alloc)
	delete(app.setup.resumed_provider, app.setup.alloc)
	app.setup.resumed_provider = strings.clone(adoption.header.provider, app.setup.alloc)
	delete(app.setup.resumed_model, app.setup.alloc)
	app.setup.resumed_model = strings.clone(adoption.header.model, app.setup.alloc)
	app.setup.session = agent.chat_session_init(&app.setup.store, claimed, app.setup.workspace, app.setup.alloc)
	app.setup.session.disable_project_instructions = app.setup.harness_options.disable_project_instructions
	return "", true
}

// acp_session_select_model gives a freshly opened session a model: the one its own record
// names, otherwise the one this process chose at startup. A session whose record cannot
// be served keeps the process's selection, so a stale record does not make the session
// unusable.
acp_session_select_model :: proc(server: ^Acp_Server) {
	app := &server.app
	if app.setup.resumed_provider != "" && app.setup.resumed_model != "" {
		if apply_selection(app, app.setup.resumed_provider, app.setup.resumed_model, "") { return }
	}
	if app.setup.provider_id != "" && app.setup.model_id != "" {
		if apply_selection(app, app.setup.provider_id, app.setup.model_id, "") { return }
	}
	_ = acp_select_first_model(server)
}

// acp_select_startup_model chooses the model this process runs with: the user's own last
// choice, otherwise the first model the configuration can actually serve. The fallback
// exists because an editor session is often the first thing a person runs, and it must
// not depend on having opened the interactive harness once.
acp_select_startup_model :: proc(server: ^Acp_Server) -> bool {
	app := &server.app
	selection, found, load_err := session.selection_load(&app.setup.store, app.run.alloc)
	defer session.selection_destroy(&selection, app.run.alloc)
	if load_err == nil && found {
		if apply_selection(app, selection.provider, selection.model, selection.effort) { return true }
	}
	return acp_select_first_model(server)
}

// acp_select_first_model picks the first configured provider that can serve a request
// and its first model, in catalog order, so the choice is the same on every launch.
// Nothing is persisted: a model chosen for an editor conversation is not the user's own
// last choice for the harness.
//
// Every candidate is named before any of them is tried: applying a selection takes the
// catalog lock, and a publication releases the catalog the names were read from, so a
// borrow would not survive the attempts below.
acp_select_first_model :: proc(server: ^Acp_Server) -> bool {
	app := &server.app
	candidates := acp_servable_models(app, app.run.alloc)
	defer {
		for &candidate in candidates {
			delete(candidate.provider_id, app.run.alloc)
			delete(candidate.model_id, app.run.alloc)
		}
		delete(candidates)
	}
	for candidate in candidates {
		if apply_selection(app, candidate.provider_id, candidate.model_id, "") { return true }
	}
	return false
}

// acp_servable_models names every serving identity this process may choose, in catalog
// order: each configured provider that states a usable endpoint, and each of its models.
// The names are copied under the catalog lock and owned by allocator.
acp_servable_models :: proc(app: ^App, allocator: mem.Allocator) -> [dynamic]Model_Choice {
	candidates: [dynamic]Model_Choice
	candidates.allocator = allocator
	sync.mutex_lock(&app.catalog_mu)
	defer sync.mutex_unlock(&app.catalog_mu)
	for &provider in app.setup.catalog.providers {
		if !provider_usable(&provider) { continue }
		if !provider_configured(app, provider.id) { continue }
		for &model in app.setup.catalog.models {
			if model.provider_id != provider.id { continue }
			append(&candidates, Model_Choice{provider_id = strings.clone(provider.id, allocator), model_id = strings.clone(model.id, allocator)})
		}
	}
	return candidates
}

// --- running a prompt --------------------------------------------------------

acp_work_prompt :: proc(server: ^Acp_Server, work: Acp_Work) {
	chat := &server.app.setup.session
	accepted := agent.chat_session_accept_user(chat, work.text, session.now_ms())
	switch accepted {
	case .Accepted:
	case .Storage_Failed:
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, agent.chat_session_last_error(chat))
		return
	case .Worker_Escaped:
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, agent.CHAT_WORKER_ESCAPED_NOTICE)
		return
	case .Busy:
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INVALID_REQUEST, "the session is already running a turn")
		return
	}
	// Accepting a prompt clears the process's cancellation token for the new turn, so a
	// cancellation that arrived while the prompt was being recorded is re-issued here.
	if sync.atomic_load(&server.cancel_seen) { agent.chat_cancel_request() }

	agent.chat_run_turn_steered(chat, server.app.run.connection, agent.chat_retry_policy_default(), acp_observer(server), nil)

	if agent.chat_session_worker_escaped(chat) {
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, agent.CHAT_WORKER_ESCAPED_NOTICE)
		return
	}
	// A cancelled turn is an ordinary answer, not an error. A turn the harness could not
	// finish is reported as the failure it is; the observer has already said why in the
	// transcript.
	switch chat.terminal_status {
	case .Completed:
		_ = acp.writer_write_response(&server.writer, work.id, acp.Prompt_Result{stop_reason = acp.stop_reason_name(.End_Turn)})
	case .Cancelled:
		_ = acp.writer_write_response(&server.writer, work.id, acp.Prompt_Result{stop_reason = acp.stop_reason_name(.Cancelled)})
	case .Failed, .None:
		message := agent.chat_session_last_error(chat)
		if message == "" { message = "the turn did not complete" }
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, message)
	}
}

// --- streaming what happens --------------------------------------------------

// acp_send_message writes one streamed message fragment. Chunks that share an id are one
// message in the client, which is what keeps a notice from reading as part of the answer.
acp_send_message :: proc(server: ^Acp_Server, kind: string, text, message_id: string) -> bool {
	update := acp.Message_Chunk {
		session_update = kind,
		content = {type = acp.CONTENT_TEXT, text = text},
		message_id = message_id,
	}
	params := acp.Session_Notification(acp.Message_Chunk) {
		session_id = acp_session_id(server),
		update     = update,
	}
	return acp.writer_write_notification(&server.writer, acp.NOTIFICATION_SESSION_UPDATE, params)
}

// acp_send_tool_call announces one call with the state it is in when it is announced: a
// call about to run is pending, and a call replayed from the record already has its
// output.
acp_send_tool_call :: proc(server: ^Acp_Server, call_id, name, arguments: string, status: acp.Tool_Status, output: string) -> bool {
	update := acp.Tool_Call {
		session_update = acp.UPDATE_TOOL_CALL,
		tool_call_id   = call_id,
		title          = acp_tool_title(name, arguments),
		kind           = acp.tool_kind_name(acp_tool_kind(&server.app.setup.session, name)),
		status         = acp.tool_status_name(status),
	}
	// The arguments are parsed for the client's benefit and released after the frame is
	// written, not when this block ends: the value the update carries must outlive it.
	raw, parse_err := json.parse_string(arguments, .JSON, true, context.temp_allocator)
	defer if parse_err == nil { json.destroy_value(raw, context.temp_allocator) }
	if parse_err == nil { update.raw_input = raw }
	if output != "" {
		content := make([]acp.Tool_Call_Content, 1, context.temp_allocator)
		content[0] = acp_tool_content(output)
		update.content = content
	}
	params := acp.Session_Notification(acp.Tool_Call) {
		session_id = acp_session_id(server),
		update     = update,
	}
	return acp.writer_write_notification(&server.writer, acp.NOTIFICATION_SESSION_UPDATE, params)
}

// acp_send_tool_result settles a call that was already announced, by its id.
acp_send_tool_result :: proc(server: ^Acp_Server, call_id: string, status: acp.Tool_Status, output: string) -> bool {
	content := make([]acp.Tool_Call_Content, 1, context.temp_allocator)
	content[0] = acp_tool_content(output)
	update := acp.Tool_Call_Update {
		session_update = acp.UPDATE_TOOL_CALL_UPDATE,
		tool_call_id   = call_id,
		status         = acp.tool_status_name(status),
		content        = content,
	}
	params := acp.Session_Notification(acp.Tool_Call_Update) {
		session_id = acp_session_id(server),
		update     = update,
	}
	return acp.writer_write_notification(&server.writer, acp.NOTIFICATION_SESSION_UPDATE, params)
}

@(private)
acp_tool_content :: proc(text: string) -> acp.Tool_Call_Content {
	return {type = acp.TOOL_CALL_CONTENT_INLINE, content = {type = acp.CONTENT_TEXT, text = text}}
}

// acp_send_usage reports how full the context is: the size the provider measured, or the
// harness's own count when the provider reported none, against the model's window.
acp_send_usage :: proc(server: ^Acp_Server, used, size: i64) -> bool {
	update := acp.Usage_Update {
		session_update = acp.UPDATE_USAGE,
		used           = used,
		size           = size,
	}
	params := acp.Session_Notification(acp.Usage_Update) {
		session_id = acp_session_id(server),
		update     = update,
	}
	return acp.writer_write_notification(&server.writer, acp.NOTIFICATION_SESSION_UPDATE, params)
}

// acp_session_id is the id a session update names. The worker owns the session, so the
// string is borrowed for the write and no longer.
acp_session_id :: proc(server: ^Acp_Server) -> string {
	return string(server.app.setup.session.id)
}

// acp_next_message_id opens a new message.
acp_next_message_id :: proc(server: ^Acp_Server) -> string {
	server.message_seq += 1
	return fmt.tprintf("msg-%d", server.message_seq)
}

@(private)
acp_current_message_id :: proc(server: ^Acp_Server) -> string {
	return fmt.tprintf("msg-%d", server.message_seq)
}

// --- the observer ------------------------------------------------------------

acp_observer :: proc(server: ^Acp_Server) -> agent.Chat_Observer {
	return {
		user_data = server,
		assistant_begin = acp_obs_assistant_begin,
		assistant_text = acp_obs_assistant_text,
		tool_call = acp_obs_tool_call,
		tool_result = acp_obs_tool_result,
		message = acp_obs_message,
		request_finished = acp_obs_request_finished,
		retry_scheduled = acp_obs_retry_scheduled,
	}
}

acp_obs_assistant_begin :: proc(user_data: rawptr) {
	server := cast(^Acp_Server)user_data
	_ = acp_next_message_id(server)
}

acp_obs_assistant_text :: proc(user_data: rawptr, text: string) {
	server := cast(^Acp_Server)user_data
	_ = acp_send_message(server, acp.UPDATE_AGENT_MESSAGE_CHUNK, text, acp_current_message_id(server))
}

// acp_obs_message reports the harness's own lines. They are the only place a client
// learns that a turn is retrying, that a tool call was repaired, or that a turn failed:
// the transcript is the protocol's only channel, so they are sent as a message of their
// own rather than folded into the model's answer.
acp_obs_message :: proc(user_data: rawptr, kind: agent.Chat_Message_Kind, text: string) {
	server := cast(^Acp_Server)user_data
	_ = acp_send_message(server, acp.UPDATE_AGENT_MESSAGE_CHUNK, text, acp_next_message_id(server))
}

acp_obs_tool_call :: proc(user_data: rawptr, event: agent.Chat_Tool_Event) {
	server := cast(^Acp_Server)user_data
	_ = acp_send_tool_call(server, event.call_id, event.name, event.arguments, .Pending, "")
}

acp_obs_tool_result :: proc(user_data: rawptr, name: string, result: ^agent.Tool_Result) {
	server := cast(^Acp_Server)user_data
	status := acp.Tool_Status.Completed
	if result.outcome != .Success { status = .Failed }
	text := tool_display_preview(result.content)
	if text == "" { text = tool_display_summary(result) }
	_ = acp_send_tool_result(server, result.call_id, status, text)
}

acp_obs_request_finished :: proc(user_data: rawptr) {
	server := cast(^Acp_Server)user_data
	chat := &server.app.setup.session
	size := i64(chat.capacity.window)
	if size <= 0 { return }
	used := i64(chat.last_estimate)
	if measured, reported := chat.last_input_measured.?; reported { used = measured }
	_ = acp_send_usage(server, used, size)
}

acp_obs_retry_scheduled :: proc(user_data: rawptr, event: agent.Chat_Retry_Event) {
	server := cast(^Acp_Server)user_data
	_ = acp_send_message(server, acp.UPDATE_AGENT_MESSAGE_CHUNK, retry_display_text(event), acp_next_message_id(server))
}

// --- replaying a loaded conversation -----------------------------------------

// acp_replay_session streams the conversation a client just loaded. Every entry the
// harness keeps becomes the update that carries it: the user's own lines, the model's
// answers, and each stored call with the result it produced. A client that asked to load
// a session shows the conversation it asked for rather than an empty one.
acp_replay_session :: proc(server: ^Acp_Server) {
	chat := &server.app.setup.session
	replayed, load_err := session.context_load(chat.store, chat.id, context.temp_allocator)
	if load_err != nil {
		_ = acp_send_message(server, acp.UPDATE_AGENT_MESSAGE_CHUNK, "the session's history could not be read", acp_next_message_id(server))
		return
	}
	defer session.context_destroy(&replayed, context.temp_allocator)

	// A result names the call it answers, so the call's own fields are kept for it. The
	// entries own their strings and the context outlives every use below.
	calls := make(map[session.Seq]session.Tool_Call_Entry, len(replayed.entries), context.temp_allocator)
	defer delete(calls)
	for &entry in replayed.entries {
		#partial switch payload in entry.payload {
		case session.User_Entry:
			kind := acp.UPDATE_AGENT_MESSAGE_CHUNK
			if payload.origin != .Harness { kind = acp.UPDATE_USER_MESSAGE_CHUNK }
			_ = acp_send_message(server, kind, payload.text, acp_next_message_id(server))
		case session.Assistant_Entry:
			_ = acp_send_message(server, acp.UPDATE_AGENT_MESSAGE_CHUNK, payload.text, acp_next_message_id(server))
		case session.Tool_Call_Entry:
			calls[entry.seq] = payload
		case session.Tool_Result_Entry:
			related, present := entry.related_seq.?
			if !present { continue }
			call, known := calls[related]
			if !known { continue }
			status := acp.Tool_Status.Completed
			if payload.outcome != .Success { status = .Failed }
			text := tool_display_preview(payload.content)
			if text == "" { text = session.tool_outcome_name(payload.outcome) }
			_ = acp_send_tool_call(server, call.call_id, call.name, call.arguments, status, text)
		}
	}
}

// --- presenting a call -------------------------------------------------------

// acp_tool_kind tells a client what a call does, so it can render the card the call
// deserves. The harness's own hints answer for a definition that states them; what is
// left is the tools this harness ships, named here, and Other is the honest answer for
// anything else, including a tool an MCP server contributed without saying.
acp_tool_kind :: proc(chat: ^agent.Chat_Session, name: string) -> acp.Tool_Kind {
	if definition, present := agent.tool_registry_find(&chat.tools, name); present {
		if definition.hints.read_only == .Yes { return .Read }
		if definition.hints.destructive == .Yes { return .Edit }
	}
	switch name {
	case agent.TOOL_SHELL_NAME, agent.TOOL_CODE_NAME:
		return .Execute
	case agent.TOOL_READ_NAME, agent.TOOL_RESULT_READ_NAME, agent.TOOL_LIST_SKILLS_NAME, agent.TOOL_LOAD_SKILL_NAME:
		return .Read
	case agent.TOOL_WRITE_NAME, agent.TOOL_EDIT_NAME:
		return .Edit
	}
	return .Other
}

// acp_tool_title is the one line a client shows for a call: the tool, and the file or
// command the arguments name when they name one.
acp_tool_title :: proc(name, arguments: string) -> string {
	value, parse_err := json.parse_string(arguments, .JSON, true, context.temp_allocator)
	if parse_err != nil { return name }
	defer json.destroy_value(value, context.temp_allocator)
	object, is_object := value.(json.Object)
	if !is_object { return name }
	detail := ""
	for key in ([?]string{"path", "command"}) {
		if text, found := object[key].(json.String); found {
			detail = string(text)
			break
		}
	}
	if detail == "" { return name }
	excerpt := agent.chat_title_from_prompt(detail, context.temp_allocator)
	if excerpt == "" { return name }
	return fmt.tprintf("%s %s", name, excerpt)
}
