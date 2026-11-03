#+build linux
package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"

import "nabla:acp"
import "nabla:agent"
import "nabla:agent/journal"
import "nabla:ai"

// The ACP agent front-end: one connection, up to ACP_MAX_SESSIONS sessions, one prompt
// turn at a time per session, speaking the Agent Client Protocol on the streams it was
// given. The reader answers what it can alone and hands session work to the worker of the
// session the request names. The worker never runs a turn: it appends the session's
// input and commands to the journal and polls what the session server commits, translating
// every record into session/update notifications. All threads enqueue output for the
// writer thread because a client cancels a turn by sending another message on the same
// stream.

// ACP_WORK_CAPACITY bounds requests waiting for one session's worker. The reader admits
// one session request at a time, so the queue holds the request being served and, briefly,
// nothing else.
ACP_WORK_CAPACITY :: 4

// ACP_WORK_OPEN carries the validated open parameters. session_ref names the stored
// session; the id of start aliases it, so only session_ref is released by
// acp_work_destroy.
ACP_Work_Open_Session :: struct {
	workspace:     string,
	session_ref:   string,
	mcp_servers:   [dynamic]agent.MCP_Server_Config,
	system_prompt: string,
	session_title: string,
	start:         Session_Start,
	replay:        bool,
}

// ACP_Work_Prompt runs one prompt on the open session. It owns the text and the
// attachments, names and bytes, and acp_work_destroy releases them.
ACP_Work_Prompt :: struct {
	text:        string,
	attachments: []ai.Provider_Attachment,
}

// ACP_Work_Compact owns the command text for its live-only V2 user message.
ACP_Work_Compact :: struct {
	text: string,
}

// ACP_Work_Set_Model carries Buzz's v1 model-selection RPC, session/set_model. The
// worker appends it as a Select_Model command and answers when the server applies it.
ACP_Work_Set_Model :: struct {
	kind:     ACP_Model_Kind,
	model_id: string,
}

// ACP_Work_Set_Config_Option applies the stable ACP model configuration method: the
// model id or the effort level. The worker appends it as a command and answers when
// the server applies it.
ACP_Work_Set_Config_Option :: struct {
	config_id:    string,
	config_value: string,
}

// ACP_Work_Close_Session releases the followed session.
ACP_Work_Close_Session :: struct {}

// ACP_Work is one request the reader handed to the worker. Every string is owned by the
// session's allocator and released by acp_work_destroy.
ACP_Work :: struct {
	// id is the request to answer.
	id:      acp.JSONRPC_Id,
	variant: union {
		ACP_Work_Open_Session,
		ACP_Work_Prompt,
		ACP_Work_Compact,
		ACP_Work_Set_Model,
		ACP_Work_Set_Config_Option,
		ACP_Work_Close_Session,
	},
}

// ACP_Model_Kind identifies which model-selection RPC a worker answers.
ACP_Model_Kind :: enum {
	// Set_Model identifies Buzz's v1 model-selection RPC.
	Set_Model,
	// Set_Config_Option applies the stable ACP model configuration method.
	Set_Config_Option,
}

ACP_Work_Chan :: chan.Chan(ACP_Work)

ACP_Wire_Profile :: enum {
	V1,
	V2,
}

@(require_results)
acp_is_v2 :: proc(conn: ^ACP_Server) -> bool {
	return conn.profile == .V2
}

// acp_model_value returns an opaque wire identity owned by allocator, released with
// delete. An unset selection returns an empty string; failure returns an allocation error.
@(require_results)
acp_model_value :: proc(provider_id, model_id: string, allocator := context.allocator) -> (string, mem.Allocator_Error) {
	if provider_id == "" || model_id == "" { return "", nil }
	return strings.concatenate({provider_id, "/", model_id}, allocator)
}

@(require_results)
acp_session_has_work :: proc(session: ^ACP_Session) -> bool {
	sync.mutex_guard(&session.queue_mu)
	return session.pending_work > 0
}

acp_queue_add :: proc(session: ^ACP_Session) {
	sync.mutex_guard(&session.queue_mu)
	session.pending_work += 1
}

acp_queue_remove :: proc(session: ^ACP_Session) {
	sync.mutex_guard(&session.queue_mu)
	session.pending_work -= 1
	if session.pending_work <= 0 {
		session.pending_work = 0
	}
}

// acp_session_live reports whether the session is open and not closing, which is what
// decides whether a queued request may still run. Owner thread only.
@(require_results)
acp_session_live :: proc(session: ^ACP_Session) -> bool {
	sync.mutex_guard(&session.conn.table_mu)
	return session.opened && session.id != "" && !session.closing
}

// acp_work_session_valid reports whether a queued request may still run. A session that
// started closing refuses everything but its own close. Owner thread only.
@(require_results)
acp_work_session_valid :: proc(session: ^ACP_Session, work: ACP_Work) -> bool {
	closing := false
	if sync.mutex_guard(&session.conn.table_mu) {
		closing = session.closing
	}
	switch _ in work.variant {
	case ACP_Work_Open_Session:
		return !closing
	case ACP_Work_Prompt, ACP_Work_Compact, ACP_Work_Set_Model, ACP_Work_Set_Config_Option:
		return !closing && session.opened && session.store != nil
	case ACP_Work_Close_Session:
		return session.opened && session.store != nil
	}
	return false
}

// --- lifetime ----------------------------------------------------------------

// acp_work_destroy releases the strings one queued request owns.
acp_work_destroy :: proc(work: ^ACP_Work, allocator: mem.Allocator) {
	acp_work_id_destroy(work.id, allocator)
	switch item in work.variant {
	case ACP_Work_Open_Session:
		delete(item.workspace, allocator)
		delete(item.session_ref, allocator)
		servers := item.mcp_servers
		agent.MCP_Server_Configs_Destroy(&servers, allocator)
		delete(item.system_prompt, allocator)
		delete(item.session_title, allocator)
	case ACP_Work_Prompt:
		delete(item.text, allocator)
		acp_attachments_destroy(item.attachments, allocator)
	case ACP_Work_Compact:
		delete(item.text, allocator)
	case ACP_Work_Set_Model:
		// kind is a value, so only the model id is owned.
		delete(item.model_id, allocator)
	case ACP_Work_Set_Config_Option:
		delete(item.config_id, allocator)
		delete(item.config_value, allocator)
	case ACP_Work_Close_Session:
	}
	work^ = {}
}

// acp_work_id_destroy releases the owned string form of a request id.
acp_work_id_destroy :: proc(id: acp.JSONRPC_Id, allocator: mem.Allocator) {
	switch value in id {
	case string:
		delete(value, allocator)
	case i64, f64, acp.JSONRPC_Null:
	}
}

// acp_work_id copies the request id a response will carry. Only the string form owns
// memory; a numeric id is a value. A copy failure reports false so the request is
// refused rather than answered under a wrong id.
@(require_results)
acp_work_id :: proc(id: acp.JSONRPC_Id, allocator: mem.Allocator) -> (acp.JSONRPC_Id, bool) {
	switch value in id {
	case string:
		cloned, clone_error := strings.clone(value, allocator)
		if clone_error != nil { return "", false }
		return cloned, true
	case i64, f64, acp.JSONRPC_Null:
		return id, true
	}
	return id, true
}

@(require_results)
acp_available_commands :: proc() -> [1]acp.Available_Command {
	command, _ := command_find("/compact")
	return {acp.Available_Command{name = "compact", description = command.summary}}
}

// --- the worker --------------------------------------------------------------

// acp_worker runs the requests the reader hands over and follows the session while it
// does. It leaves when the queue is closed and drained.
acp_worker :: proc(thread_handle: ^thread.Thread) {
	session := cast(^ACP_Session)thread_handle.data
	defer sync.one_shot_event_signal(&session.worker_done)
	// A thread started without init_context gets the default context, so the session's
	// allocator, which the work it destroys was allocated with, is installed here.
	context.allocator = session.conn.alloc
	for {
		seen := agent.owner_wake_seen()
		work, ok := chan.try_recv(session.work)
		if !ok {
			// A closed queue is shutdown, which answers nothing more.
			if chan.is_closed(session.work) { break }
			agent.owner_wake_wait(seen, nil)
			continue
		}
		if sync.mutex_guard(&session.conn.table_mu) {
			session.worker_active = true
		}
		acp_run_work(session, work)
		if sync.mutex_guard(&session.conn.table_mu) {
			session.worker_active = false
		}
		retiring := false
		switch _ in work.variant {
		case ACP_Work_Close_Session:
			retiring = true
		case ACP_Work_Open_Session:
			retiring = !session.opened
		case ACP_Work_Prompt, ACP_Work_Compact, ACP_Work_Set_Model, ACP_Work_Set_Config_Option:
		}
		acp_work_destroy(&work, session.conn.alloc)
		// Temp scratch belongs to one request: the worker is long-lived, so its pool is
		// recycled here rather than left to grow with the conversation.
		free_all(context.temp_allocator)
		if retiring {
			// A closed session and a session whose first open failed have nothing left to
			// serve. Closing the queue turns any later request into a refusal, and the
			// reader, which alone frees sessions, reaps this one.
			acp_session_retire(session)
			break
		}
	}
}

acp_run_work :: proc(session: ^ACP_Session, work: ACP_Work) {
	if !acp_work_session_valid(session, work) {
		acp_sent(session, acp.write_error(&session.conn.writer, work.id, acp.ERROR_INVALID_PARAMS, "the session changed before the request could run"))
	} else {
		switch item in work.variant {
		case ACP_Work_Open_Session:
			acp_work_open_session(session, work.id, item)
		case ACP_Work_Prompt:
			acp_work_prompt(session, work.id, item)
		case ACP_Work_Compact:
			acp_work_compact(session, work.id, item)
		case ACP_Work_Set_Model:
			acp_work_set_model(session, work.id, item)
		case ACP_Work_Set_Config_Option:
			acp_work_set_config_option(session, work.id, item)
		case ACP_Work_Close_Session:
			acp_work_close_session(session, work.id, item)
		}
	}
	acp_queue_remove(session)
}

// --- appending ----------------------------------------------------------------

// acp_append_input commits the prompt text as a user.input record the server delivers,
// and returns its seq. Attachments ride along as named artifacts. A busy database keeps
// the record pending, so the commit runs once more before the line is reported lost.
@(require_results)
acp_append_input :: proc(
	session: ^ACP_Session,
	text: string,
	origin: journal.User_Origin,
	attachments: []ai.Provider_Attachment,
) -> (
	seq: journal.Journal_Seq,
	ok: bool,
) {
	error := journal.append_input(session.store, text, origin, attachments)
	seq = session.store.last_seq
	if error != nil && journal.error_is_busy(error) { seq, error = journal.commit(session.store) }
	if error != nil { return 0, false }
	return seq, true
}

// acp_append_command commits one command for the server to apply at its own boundary.
// A busy database keeps the record pending, so the commit runs once more before the
// command is reported lost.
@(require_results)
acp_append_command :: proc(session: ^ACP_Session, command: journal.Command) -> (seq: journal.Journal_Seq, ok: bool) {
	error := journal.append_command(session.store, command)
	seq = session.store.last_seq
	if error != nil && journal.error_is_busy(error) { seq, error = journal.commit(session.store) }
	if error != nil { return 0, false }
	return seq, true
}

// acp_wait_step runs one follow poll: cancellations the reader recorded are appended,
// every committed record streams through the observer, and the selection the session
// last saw is refreshed. Stop means the wait is over: the session closed, the journal
// failed, or the process is leaving.
@(require_results)
acp_wait_step :: proc(session: ^ACP_Session) -> (stop: bool) {
	// A session with no queue is not shut down. Only a queue the reader closed ends
	// the wait; a nil one is closed by the channel package and would stop it at once.
	if acp_session_is_closing(session) || (session.work != {} && chan.is_closed(session.work)) { return true }
	if acp_cancel_take(session) { _, _ = acp_append_command(session, journal.Cancel_Turn{}) }
	if poll_error := client_follow_poll(&session.follow, acp_observer(session)); poll_error != nil { return true }
	acp_selection_sync(session)
	if agent.process_interrupted() { return true }
	return false
}

// acp_server_failed reports whether the session server died before answering. A server
// that exited 0 lost the claim to another server, so the wait continues under the next
// one; any other death ends it.
@(require_results)
acp_server_failed :: proc(session: ^ACP_Session) -> bool {
	status, _ := client_server_status(&session.server)
	switch status.kind {
	case .None, .Running:
		return false
	case .Exited:
		return status.exit_code != 0
	case .Signalled, .Unknown:
		return true
	}
	return true
}

// acp_wait_turn waits for the turn that delivers input to end, streaming every record
// meanwhile. The prompt request completes when that turn ends.
@(require_results)
acp_wait_turn :: proc(session: ^ACP_Session, input: journal.Journal_Seq) -> (outcome: journal.Turn_Outcome, ok: bool) {
	session.follow.cursor.input = input
	for {
		seen := agent.owner_wake_seen()
		if acp_wait_step(session) { return {}, false }
		if session.follow.cursor.ended { return session.follow.cursor.outcome, true }
		if acp_server_failed(session) { return {}, false }
		agent.owner_wake_wait(seen, nil)
	}
}

// acp_wait_accept waits for the committed input's echo, which is the user message the
// prompt's acceptance names. True means the observer stashed its id; false means the
// wait ended first, and the caller answers from the follow cursor instead.
@(require_results)
acp_wait_accept :: proc(session: ^ACP_Session, input: journal.Journal_Seq) -> bool {
	session.follow.cursor.input = input
	for {
		seen := agent.owner_wake_seen()
		if acp_wait_step(session) { return false }
		if session.pending_accept { return true }
		if session.follow.cursor.ended { return false }
		if acp_server_failed(session) { return false }
		agent.owner_wake_wait(seen, nil)
	}
}

// acp_command_answer reads the answer the server committed for command: its outcome and
// why a refusal was not applied, in temp memory. Found is false while no command.applied
// names it yet.
@(require_results)
acp_command_answer :: proc(session: ^ACP_Session, command: journal.Journal_Seq) -> (outcome: journal.Command_Outcome, reason: string, found: bool) {
	records, _, read_error := journal.read_records(
		session.store,
		{session = session.session_id, kinds = {.Command_Applied}},
		command,
		0,
		context.temp_allocator,
	)
	if read_error != nil { return {}, "", false }
	defer journal.records_destroy(records, context.temp_allocator)
	for record in records {
		applied, is_applied := journal.payload_as(record, journal.Command_Applied)
		if !is_applied { continue }
		if applied.command != command { continue }
		named, known := journal.enum_from_name(journal.COMMAND_OUTCOME_NAMES, applied.outcome)
		if !known { continue }
		return named, applied.reason, true
	}
	return {}, "", false
}

// acp_wait_applied waits for the server to answer command, streaming every record
// meanwhile. A command the server never answers, because the session closed first,
// ends the wait as a failure.
@(require_results)
acp_wait_applied :: proc(session: ^ACP_Session, command: journal.Journal_Seq) -> (outcome: journal.Command_Outcome, reason: string, ok: bool) {
	for {
		seen := agent.owner_wake_seen()
		if acp_wait_step(session) { return {}, "", false }
		if answered, answer_reason, was_answered := acp_command_answer(session, command); was_answered {
			return answered, answer_reason, true
		}
		if acp_server_failed(session) { return {}, "", false }
		agent.owner_wake_wait(seen, nil)
	}
}

// --- opening a session -------------------------------------------------------

// acp_selection_sync refreshes the serving identity the session tracks from the latest
// selection.applied the server committed, so prompts and listings answer from what the
// session runs rather than from what this connection asked for last.
acp_selection_sync :: proc(session: ^ACP_Session) {
	provider, model, effort, found, _, _, _ := session_recorded_selection(session.store, session.session_id, context.temp_allocator)
	if !found { return }
	defer {
		delete(provider, context.temp_allocator)
		delete(model, context.temp_allocator)
		delete(effort, context.temp_allocator)
	}
	if provider == session.provider_id && model == session.model_id && effort == session.effort { return }
	owned_provider, provider_error := strings.clone(provider, session.conn.alloc)
	owned_model, model_error := strings.clone(model, session.conn.alloc)
	owned_effort, effort_error := strings.clone(effort, session.conn.alloc)
	if provider_error != nil || model_error != nil || effort_error != nil {
		delete(owned_provider, session.conn.alloc)
		delete(owned_model, session.conn.alloc)
		delete(owned_effort, session.conn.alloc)
		return
	}
	delete(session.provider_id, session.conn.alloc)
	delete(session.model_id, session.conn.alloc)
	delete(session.effort, session.conn.alloc)
	session.provider_id = owned_provider
	session.model_id = owned_model
	session.effort = owned_effort
}

// acp_open_request_selection fixes what the freshly opened session runs: the connection's
// default for a new session, or what the stored session last ran with for a load. A
// session that names no model still opens: the prompt is what refuses it, the way it
// refuses a session whose model was never configured.
@(require_results)
acp_open_request_selection :: proc(session: ^ACP_Session, fresh: bool) -> (message: string, ok: bool) {
	if fresh {
		return acp_install_default_selection(session)
	}
	provider, model, effort, found, _, _, _ := session_recorded_selection(session.store, session.session_id, session.conn.alloc)
	if !found { return acp_install_default_selection(session) }
	session.provider_id = provider
	session.model_id = model
	session.effort = effort
	return "", true
}

// acp_install_default_selection tracks the connection's default serving identity. A
// session without one still opens: the prompt is what refuses it.
@(require_results)
acp_install_default_selection :: proc(session: ^ACP_Session) -> (message: string, ok: bool) {
	if session.conn.app.setup.provider_id == "" || session.conn.app.setup.model_id == "" { return "", true }
	provider, provider_error := strings.clone(session.conn.app.setup.provider_id, session.conn.alloc)
	model, model_error := strings.clone(session.conn.app.setup.model_id, session.conn.alloc)
	effort, effort_error := strings.clone(session.conn.default_effort, session.conn.alloc)
	if provider_error != nil || model_error != nil || effort_error != nil {
		delete(provider, session.conn.alloc)
		delete(model, session.conn.alloc)
		delete(effort, session.conn.alloc)
		return "the session selection could not be stored", false
	}
	delete(session.provider_id, session.conn.alloc)
	delete(session.model_id, session.conn.alloc)
	delete(session.effort, session.conn.alloc)
	session.provider_id = provider
	session.model_id = model
	session.effort = effort
	return "", true
}

// acp_open_environment records the editor's standing instructions and MCP server list as
// the session's environment, which the server applies before the first prompt. A server
// the launch already configures is refused rather than replaced.
@(require_results)
acp_open_environment :: proc(session: ^ACP_Session, instructions: string, servers: [dynamic]agent.MCP_Server_Config) -> (message: string, ok: bool) {
	environment, environment_error := agent.session_environment_from_configs(instructions, servers[:], context.temp_allocator)
	if environment_error != .None {
		return "the session environment could not be allocated", false
	}
	defer agent.session_environment_destroy(&environment, context.temp_allocator)
	if serve_environment_mcp_conflict(session.conn.app.setup.environment_base, servers) {
		return "the session MCP configuration names an MCP server the launch already configures", false
	}
	if append_error := journal.append_environment(session.store, environment); append_error != nil {
		if journal.error_is_busy(append_error) {
			_, append_error = journal.commit(session.store)
		}
		if append_error != nil {
			return "the session environment could not be recorded", false
		}
	}
	return "", true
}

// acp_ensure_server starts the session's server unless the session already has a claim
// holder, in which case this connection follows it.
@(require_results)
acp_ensure_server :: proc(session: ^ACP_Session) -> (message: string, ok: bool) {
	if session.server.state != nil {
		status, _ := client_server_status(&session.server)
		switch status.kind {
		case .None, .Running:
			return "", true
		case .Exited:
			// A server that exited 0 lost the claim to another server, so this
			// connection follows that one instead of starting a second one.
			if status.exit_code == 0 { return "", true }
		case .Signalled, .Unknown:
		}
		client_server_close(&session.server)
	}
	options := &session.conn.app.setup.harness_options
	server, server_error := client_ensure_server(options.nabla_executable, session.session_id, options.nabla_config, nil)
	if server_error.kind != .None {
		switch server_error.kind {
		case .None:
		case .Locks:
			return "cannot resolve the directory for session locks", false
		case .Path:
			return "the session lock path could not be stored", false
		case .Claim:
			return "cannot tell whether the session is running", false
		case .Start:
			return "the session server could not be started", false
		case .Sink:
			return "the session server could not be started: /dev/null could not be opened", false
		case .Waiter:
			return "the session server could not be watched", false
		case .Follow, .Watch:
			return "cannot follow the session", false
		}
		return "the session server could not be started", false
	}
	session.server = server
	return "", true
}

// acp_session_row creates the session row a fresh session runs in and releases its claim,
// so the server the connection starts can take it. Resume opens no row: the stored one
// is validated by the reader before the work is queued.
@(require_results)
acp_session_row :: proc(session: ^ACP_Session, workspace: string) -> (message: string, ok: bool) {
	setup := &session.conn.app.setup
	store, open_error := session_store_open(setup)
	if open_error != nil {
		return "cannot open the session database", false
	}
	session.store = store
	id, create_error := journal.create_session(store, {workspace = workspace, role = .Main})
	if create_error != nil {
		return "the session could not be created", false
	}
	if _, commit_error := journal.commit(store); commit_error != nil {
		return "the session could not be committed", false
	}
	if release_error := journal.release(store); release_error != nil {
		return "the session could not be released", false
	}
	session.session_id = id
	return "", true
}

// acp_session_follow follows the session's journal and arms its watch, so the worker
// polls what the server commits.
@(require_results)
acp_session_follow :: proc(session: ^ACP_Session) -> (message: string, ok: bool) {
	follow, follow_error := client_follow_open(session.store, session.session_id)
	if follow_error.kind != .None {
		#partial switch follow_error.kind {
		case .Watch:
			return "cannot watch the session", false
		case .Follow:
			return "cannot read the session", false
		case:
			return "cannot follow the session", false
		}
	}
	session.follow = follow
	return "", true
}

acp_work_open_session :: proc(session: ^ACP_Session, id: acp.JSONRPC_Id, work: ACP_Work_Open_Session) {
	// A session that already holds its conversation is opened a second time by a load or
	// resume of its own id: the conversation is the same, so its environment is recorded
	// again and announced again.
	if session.opened {
		if message, ok := acp_open_environment(session, work.system_prompt, work.mcp_servers); !ok {
			acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INVALID_PARAMS, message))
			return
		}
	} else {
		fresh: bool
		switch _ in work.start {
		case Start_Resume_Id:
			fresh = false
			parsed, valid := journal.session_id_parse(work.session_ref)
			if !valid || parsed == {} {
				acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INVALID_PARAMS, "the session id is not a session id"))
				return
			}
			session.session_id = parsed
		case Start_Fresh, Start_Resume_Latest, nil:
			fresh = true
		}
		if fresh {
			if message, ok := acp_session_row(session, work.workspace); !ok {
				acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, message))
				return
			}
		} else {
			setup := &session.conn.app.setup
			store, open_error := session_store_open(setup)
			if open_error != nil {
				acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "cannot open the session database"))
				return
			}
			session.store = store
		}
		if message, ok := acp_open_request_selection(session, fresh); !ok {
			acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, message))
			return
		}
		// The server starts now when a model names one; a session without one still
		// opens, and the first prompt or model change starts its server.
		if session.provider_id != "" && session.model_id != "" {
			if message, ok := acp_ensure_server(session); !ok {
				acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, message))
				return
			}
		}
		if message, ok := acp_session_follow(session); !ok {
			acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, message))
			return
		}
		if message, ok := acp_open_environment(session, work.system_prompt, work.mcp_servers); !ok {
			acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INVALID_PARAMS, message))
			return
		}
		acp_selection_sync(session)
		hex: [journal.SESSION_ID_HEX_LENGTH]u8
		session_text := journal.session_id_to_hex(session.session_id, hex[:])
		owned_session_id, session_id_error := strings.clone(session_text, session.conn.alloc)
		owned_title, title_error := strings.clone(work.session_title, session.conn.alloc)
		owned_workspace, workspace_error := strings.clone(work.workspace, session.conn.alloc)
		if session_id_error != nil || title_error != nil || workspace_error != nil {
			delete(owned_session_id, session.conn.alloc)
			delete(owned_title, session.conn.alloc)
			delete(owned_workspace, session.conn.alloc)
			acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the session reference could not be stored"))
			return
		}
		if sync.mutex_guard(&session.conn.table_mu) {
			delete(session.id, session.conn.alloc)
			session.id = owned_session_id
			delete(session.title, session.conn.alloc)
			session.title = owned_title
			delete(session.workspace, session.conn.alloc)
			session.workspace = owned_workspace
		}
		session.opened = true
	}
	if work.session_title != "" { acp_sent(session, acp_send_session_info(session, work.session_title)) }
	if work.replay { acp_replay_session(session) }
	acp_open_respond(session, id, work)
	commands := acp_available_commands()
	acp_sent(session, acp_notify(session, acp.Available_Commands_Update{session_update = acp.UPDATE_AVAILABLE_COMMANDS, available_commands = commands[:]}))
}

// acp_open_respond answers the open with the serving identity the session runs and the
// wire surface the profile names.
acp_open_respond :: proc(session: ^ACP_Session, id: acp.JSONRPC_Id, work: ACP_Work_Open_Session) {
	// Allocate every value that can fail before answering. A response must not advertise
	// a session that failed partway through setup.
	options, options_ok := acp_model_config_options(session)
	if !options_ok {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the model configuration could not be allocated"))
		return
	}
	session_id := acp_session_id(session)
	switch _ in work.start {
	case Start_Resume_Id:
		if acp_is_v2(session.conn) {
			commands := acp_available_commands()
			acp_sent(
				session,
				acp.write_response(&session.conn.writer, id, acp.Session_Resume_Result{config_options = options, available_commands = commands[:]}),
			)
		} else {
			acp_sent(session, acp.write_response(&session.conn.writer, id, acp.Empty_Result{}))
		}
	case Start_Fresh, Start_Resume_Latest, nil:
		if acp_is_v2(session.conn) {
			commands := acp_available_commands()
			acp_sent(
				session,
				acp.write_response(
					&session.conn.writer,
					id,
					acp.V2_Session_New_Result{session_id = session_id, config_options = options, available_commands = commands[:]},
				),
			)
		} else {
			models, models_ok := acp_models_state(session)
			if !models_ok {
				acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the model catalog could not be allocated"))
				return
			}
			acp_sent(
				session,
				acp.write_response(&session.conn.writer, id, ACP_Session_New_Result{session_id = session_id, config_options = options, models = models}),
			)
		}
	}
}

// --- running a prompt ---------------------------------------------------------

acp_work_close_session :: proc(session: ^ACP_Session, id: acp.JSONRPC_Id, work: ACP_Work_Close_Session) {
	acp_session_release(session)
	acp_sent(session, acp.write_response(&session.conn.writer, id, acp.Empty_Result{}))
}

acp_work_prompt :: proc(session: ^ACP_Session, id: acp.JSONRPC_Id, work: ACP_Work_Prompt) {
	acp_selection_sync(session)
	if session.provider_id == "" || session.model_id == "" {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "no model is selected; configure a provider in nabla's config.lua"))
		return
	}
	if message, ok := acp_ensure_server(session); !ok {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, message))
		return
	}
	if message, ok := acp_selection_record_default(session); !ok {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, message))
		return
	}
	seq, appended := acp_append_input(session, work.text, .Prompt, work.attachments)
	if !appended {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the prompt could not be recorded"))
		return
	}
	// The echo of the committed input is the user message, so the acceptance names a
	// message the client already saw rather than one invented beside it. The worker
	// owns the wait, so the pending match and the stashed id need no lock.
	session.pending_text = work.text
	session.pending_accept = false
	delete(session.accept_message, session.conn.alloc)
	session.accept_message = ""
	if acp_is_v2(session.conn) && !acp_wait_accept(session, seq) {
		if session.follow.cursor.ended {
			// The echo never arrived, but the turn already ended: name the prompt
			// with a fresh message rather than leaving the request unanswered.
			message_id := acp_next_message_id(session)
			owned, clone_error := strings.clone(message_id, session.conn.alloc)
			if clone_error == nil {
				delete(session.accept_message, session.conn.alloc)
				session.accept_message = owned
			}
			acp_sent(session, acp_send_user_message(session, message_id, work.text))
		} else {
			acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the turn did not complete"))
			return
		}
	}
	if acp_is_v2(session.conn) {
		if session.accept_message == "" {
			acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the prompt could not be accepted"))
			return
		}
		acp_sent(session, acp.write_response(&session.conn.writer, id, acp.Prompt_Accepted_Result{message_id = session.accept_message}))
		acp_sent(session, acp_send_state(session, "running", ""))
		delete(session.accept_message, session.conn.alloc)
		session.accept_message = ""
	}
	outcome, waited := acp_wait_turn(session, seq)
	session.pending_text = ""
	if !waited {
		if acp_is_v2(session.conn) && session.pending_accept {
			acp_sent(
				session,
				acp_send_state(session, "idle", acp.stop_reason_name(.Error), acp.RPC_Error{code = acp.ERROR_INTERNAL, message = "the turn did not complete"}),
			)
		} else {
			acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the turn did not complete"))
		}
		return
	}
	if acp_is_v2(session.conn) {
		switch outcome {
		case .Completed:
			acp_sent(session, acp_send_state(session, "idle", acp.stop_reason_name(.End_Turn)))
		case .Cancelled:
			acp_sent(session, acp_send_state(session, "idle", acp.stop_reason_name(.Cancelled)))
		case .Failed, .Interrupted:
			message := acp_last_error(session)
			if message == "" { message = "the turn did not complete" }
			acp_sent(session, acp_send_state(session, "idle", acp.stop_reason_name(.Error), acp.RPC_Error{code = acp.ERROR_INTERNAL, message = message}))
		}
		return
	}
	switch outcome {
	case .Completed:
		acp_sent(session, acp.write_response(&session.conn.writer, id, acp.Prompt_Result{stop_reason = acp.stop_reason_name(.End_Turn)}))
	case .Cancelled:
		acp_sent(session, acp.write_response(&session.conn.writer, id, acp.Prompt_Result{stop_reason = acp.stop_reason_name(.Cancelled)}))
	case .Failed, .Interrupted:
		message := acp_last_error(session)
		if message == "" { message = "the turn did not complete" }
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, message))
	}
}

// acp_work_compact appends a compaction command and answers when the server applies it.
// The V2 user message is live-only: the command text is never written to the journal.
acp_work_compact :: proc(session: ^ACP_Session, id: acp.JSONRPC_Id, command: ACP_Work_Compact) {
	acp_selection_sync(session)
	if session.provider_id == "" || session.model_id == "" {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "no model is selected; configure a provider in nabla's config.lua"))
		return
	}
	if message, ok := acp_ensure_server(session); !ok {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, message))
		return
	}
	if acp_is_v2(session.conn) {
		message_id := acp_next_message_id(session)
		acp_sent(session, acp_send_user_message(session, message_id, command.text))
		acp_sent(session, acp.write_response(&session.conn.writer, id, acp.Prompt_Accepted_Result{message_id = message_id}))
		acp_sent(session, acp_send_state(session, "running", ""))
	}
	seq, appended := acp_append_command(session, journal.Compact{})
	if !appended {
		if acp_is_v2(session.conn) {
			acp_sent(
				session,
				acp_send_state(
					session,
					"idle",
					acp.stop_reason_name(.Error),
					acp.RPC_Error{code = acp.ERROR_INTERNAL, message = "the compaction could not be recorded"},
				),
			)
		} else {
			acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the compaction could not be recorded"))
		}
		return
	}
	outcome, reason, waited := acp_wait_applied(session, seq)
	if !waited {
		if acp_is_v2(session.conn) {
			acp_sent(
				session,
				acp_send_state(
					session,
					"idle",
					acp.stop_reason_name(.Error),
					acp.RPC_Error{code = acp.ERROR_INTERNAL, message = "the compaction was not answered before the session closed"},
				),
			)
		} else {
			acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the compaction was not answered before the session closed"))
		}
		return
	}
	if outcome == .Applied {
		if acp_is_v2(session.conn) {
			acp_sent(session, acp_send_state(session, "idle", acp.stop_reason_name(.End_Turn)))
		} else {
			acp_sent(session, acp.write_response(&session.conn.writer, id, acp.Prompt_Result{stop_reason = acp.stop_reason_name(.End_Turn)}))
		}
		return
	}
	if reason == "" { reason = "compaction is not available" }
	if acp_is_v2(session.conn) {
		acp_sent(session, acp_send_state(session, "idle", acp.stop_reason_name(.Error), acp.RPC_Error{code = acp.ERROR_INTERNAL, message = reason}))
	} else {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, reason))
	}
}

// acp_model_identify reads the provider and model a "provider/model" wire value names.
// The strings borrow the catalog.
@(require_results)
acp_model_identify :: proc(session: ^ACP_Session, value: string) -> (provider, model: string, found: bool) {
	if sync.mutex_guard(&session.conn.app.catalog_mu) {
		for candidate in session.conn.app.setup.catalog.models {
			candidate_value, value_error := acp_model_value(candidate.provider_id, candidate.id)
			if value_error != nil { return "", "", false }
			matched := candidate_value == value
			delete(candidate_value)
			if matched { return candidate.provider_id, candidate.id, true }
		}
	}
	return "", "", false
}

acp_work_set_model :: proc(session: ^ACP_Session, id: acp.JSONRPC_Id, work: ACP_Work_Set_Model) {
	acp_work_select_model(session, id, work.kind, work.model_id)
}

// acp_work_select_model appends a model change and answers when the server applies it.
// A value no catalog model answers is refused before anything is recorded.
acp_work_select_model :: proc(session: ^ACP_Session, id: acp.JSONRPC_Id, kind: ACP_Model_Kind, value: string) {
	provider, model, found := acp_model_identify(session, value)
	if !found {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INVALID_PARAMS, fmt.tprintf("the model value %q is not available", value)))
		return
	}
	if message, ok := acp_ensure_server(session); !ok {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, message))
		return
	}
	seq, appended := acp_append_command(session, journal.Select_Model{provider = provider, model = model})
	if !appended {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the model change could not be recorded"))
		return
	}
	outcome, reason, waited := acp_wait_applied(session, seq)
	if !waited {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the model selection was not answered before the session closed"))
		return
	}
	if outcome == .Refused {
		if reason == "" { reason = "the model selection was refused" }
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INVALID_PARAMS, reason))
		return
	}
	acp_selection_sync(session)
	if kind == .Set_Model {
		acp_sent(session, acp.write_response(&session.conn.writer, id, ACP_Set_Model_Result{session_id = acp_session_id(session), model_id = value}))
		return
	}
	options, options_ok := acp_model_config_options(session)
	if !options_ok {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the model configuration could not be allocated"))
		return
	}
	acp_sent(session, acp.write_response(&session.conn.writer, id, acp.Session_Set_Config_Option_Result{config_options = options}))
}

// acp_selection_record_default gives the server the serving identity this connection tracks
// for a session that never recorded a selection, which is the connection's default: the
// server runs only what the journal names.
@(require_results)
acp_selection_record_default :: proc(session: ^ACP_Session) -> (message: string, ok: bool) {
	_, _, _, found, _, _, _ := session_recorded_selection(session.store, session.session_id, context.temp_allocator)
	if found { return "", true }
	commands := [2]journal.Command{journal.Select_Model{provider = session.provider_id, model = session.model_id}, journal.Set_Effort{level = session.effort}}
	for command in commands[:1 if session.effort == "" else 2] {
		seq, appended := acp_append_command(session, command)
		if !appended { return "the default model could not be recorded", false }
		outcome, reason, waited := acp_wait_applied(session, seq)
		if !waited { return "the default model was not answered before the session closed", false }
		if outcome == .Refused { return fmt.tprintf("the default model was refused: %s", reason), false }
	}
	return "", true
}

// acp_effort_allowed reports whether level is a thinking level the named model states.
// An empty level clears the override back to the provider default and is always allowed.
@(require_results)
acp_effort_allowed :: proc(session: ^ACP_Session, provider_id, model_id, level: string) -> bool {
	if level == "" { return true }
	levels, levels_ok := acp_model_effort_levels(session, provider_id, model_id)
	if !levels_ok { return false }
	defer delete(levels)
	for allowed in levels {
		if allowed == level { return true }
	}
	return false
}

// acp_model_effort_levels names the thinking levels the named model states, owned by
// allocator. Failure reads as no levels, so the effort option is omitted rather than
// refused.
@(require_results)
acp_model_effort_levels :: proc(session: ^ACP_Session, provider_id, model_id: string, allocator := context.allocator) -> (levels: []string, ok: bool) {
	if sync.mutex_guard(&session.conn.app.catalog_mu) {
		for candidate in session.conn.app.setup.catalog.models {
			if candidate.provider_id != provider_id || candidate.id != model_id { continue }
			if candidate.thinking.levels == nil { return nil, true }
			cloned, clone_error := slice.clone(candidate.thinking.levels.?, allocator)
			if clone_error != nil { return nil, false }
			return cloned, true
		}
	}
	return nil, false
}

acp_work_set_config_option :: proc(session: ^ACP_Session, id: acp.JSONRPC_Id, work: ACP_Work_Set_Config_Option) {
	if work.config_id == "model" {
		acp_work_select_model(session, id, .Set_Config_Option, work.config_value)
		return
	}
	if work.config_id != "effort" {
		acp_sent(
			session,
			acp.write_error(
				&session.conn.writer,
				id,
				acp.ERROR_INVALID_PARAMS,
				fmt.tprintf("the config option %q cannot be set to %q", work.config_id, work.config_value),
			),
		)
		return
	}
	level := work.config_value if work.config_value != "default" else ""
	acp_selection_sync(session)
	if session.provider_id == "" || session.model_id == "" {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "no model is selected; configure a provider in nabla's config.lua"))
		return
	}
	if message, ok := acp_ensure_server(session); !ok {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, message))
		return
	}
	if !acp_effort_allowed(session, session.provider_id, session.model_id, level) {
		acp_sent(
			session,
			acp.write_error(
				&session.conn.writer,
				id,
				acp.ERROR_INVALID_PARAMS,
				fmt.tprintf("the config option %q cannot be set to %q", work.config_id, work.config_value),
			),
		)
		return
	}
	seq, appended := acp_append_command(session, journal.Set_Effort{level = level})
	if !appended {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the effort change could not be recorded"))
		return
	}
	outcome, reason, waited := acp_wait_applied(session, seq)
	if !waited {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the effort change was not answered before the session closed"))
		return
	}
	if outcome == .Refused {
		if reason == "" { reason = "the effort change was refused" }
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INVALID_PARAMS, reason))
		return
	}
	acp_selection_sync(session)
	options, options_ok := acp_model_config_options(session)
	if !options_ok {
		acp_sent(session, acp.write_error(&session.conn.writer, id, acp.ERROR_INTERNAL, "the model configuration could not be allocated"))
		return
	}
	acp_sent(session, acp.write_response(&session.conn.writer, id, acp.Session_Set_Config_Option_Result{config_options = options}))
}

// --- serving identity ----------------------------------------------------------

// acp_candidates_destroy releases servable-model names the selector did not use.
acp_candidates_destroy :: proc(candidates: [dynamic]Model_Choice, allocator: mem.Allocator) {
	for candidate in candidates {
		delete(candidate.provider_id, allocator)
		delete(candidate.model_id, allocator)
	}
	delete(candidates)
}

// acp_servable_models names every serving identity this process may choose, in catalog
// order: each configured provider that states a usable endpoint, and each of its models.
// The names are copied under the catalog lock and owned by allocator. A copy failure
// releases what was already named and reports false.
@(require_results)
acp_servable_models :: proc(app: ^App, allocator: mem.Allocator) -> ([dynamic]Model_Choice, bool) {
	candidates: [dynamic]Model_Choice
	candidates.allocator = allocator
	sync.mutex_guard(&app.catalog_mu)
	for &provider in app.setup.catalog.providers {
		if !provider_usable(&provider) { continue }
		if !provider_configured(app, provider.id) { continue }
		for &model in app.setup.catalog.models {
			if model.provider_id != provider.id { continue }
			provider_id, provider_error := strings.clone(provider.id, allocator)
			if provider_error != nil {
				acp_candidates_destroy(candidates, allocator)
				return {}, false
			}
			model_id, model_error := strings.clone(model.id, allocator)
			if model_error != nil {
				delete(provider_id, allocator)
				acp_candidates_destroy(candidates, allocator)
				return {}, false
			}
			if append(&candidates, Model_Choice{provider_id = provider_id, model_id = model_id}) != 1 {
				delete(provider_id, allocator)
				delete(model_id, allocator)
				acp_candidates_destroy(candidates, allocator)
				return {}, false
			}
		}
	}
	return candidates, true
}

@(require_results)
acp_model_config_values :: proc(session: ^ACP_Session) -> ([]acp.Config_Value, bool) {
	models: []agent.Catalog_Model
	if sync.mutex_guard(&session.conn.app.catalog_mu) {
		models = session.conn.app.setup.catalog.models[:]
	}
	values, values_error := make([]acp.Config_Value, len(models), context.temp_allocator)
	if values_error != nil { return nil, false }
	names: [dynamic]string
	names.allocator = context.temp_allocator
	defer delete(names)
	for model in models {
		name := model.id
		if name_value, is_text := model.display_name.?; is_text && name_value != "" { name = name_value }
		value, value_error := acp_model_value(model.provider_id, model.id, context.temp_allocator)
		if value_error != nil { return nil, false }
		append(&names, name)
		values[len(names) - 1] = acp.Config_Value {
			value = value,
			name  = names[len(names) - 1],
		}
	}
	return values, true
}

// acp_effort_config_values names the thinking levels the session's model states,
// verbatim. An empty result means the model states none, and no effort option is
// advertised for it.
@(require_results)
acp_effort_config_values :: proc(session: ^ACP_Session) -> ([]acp.Config_Value, bool) {
	levels, levels_ok := acp_model_effort_levels(session, session.provider_id, session.model_id, context.temp_allocator)
	if !levels_ok { return nil, false }
	defer delete(levels, context.temp_allocator)
	values, values_error := make([]acp.Config_Value, len(levels), context.temp_allocator)
	if values_error != nil { return nil, false }
	for level, index in levels {
		values[index] = acp.Config_Value {
			value = level,
			name  = level,
		}
	}
	return values, true
}

@(require_results)
acp_config_option_counts :: proc(session: ^ACP_Session) -> (model_count, effort_count: int) {
	models: []agent.Catalog_Model
	if sync.mutex_guard(&session.conn.app.catalog_mu) {
		models = session.conn.app.setup.catalog.models[:]
	}
	if len(models) > 0 { model_count = 1 }
	levels, levels_ok := acp_model_effort_levels(session, session.provider_id, session.model_id, context.temp_allocator)
	defer delete(levels, context.temp_allocator)
	if levels_ok && len(levels) > 0 { effort_count = 1 }
	return model_count, effort_count
}

// acp_model_config_options is the model and effort options of the open session in the wire
// form of the connection's protocol version, temp-allocated. The current values are what
// the session last saw applied.
@(require_results)
acp_model_config_options :: proc(session: ^ACP_Session) -> ([]json.Value, bool) {
	model_count, effort_count := acp_config_option_counts(session)
	options, options_error := make([]acp.Config_Option, model_count + effort_count, context.temp_allocator)
	if options_error != nil { return nil, false }
	index := 0
	if model_count == 1 {
		values, values_ok := acp_model_config_values(session)
		if !values_ok { return nil, false }
		current, current_error := acp_model_value(session.provider_id, session.model_id, context.temp_allocator)
		if current_error != nil { return nil, false }
		options[index] = acp.Config_Option {
			id = "model",
			name = "Model",
			category = "model",
			variant = acp.Config_Select{current_value = current, options = values},
		}
		index += 1
	}
	if effort_count == 1 {
		levels, levels_ok := acp_effort_config_values(session)
		if !levels_ok { return nil, false }
		options[index] = acp.Config_Option {
			id = "effort",
			name = "Effort",
			category = "thought_level",
			variant = acp.Config_Select{current_value = session.effort, options = levels},
		}
	}
	version := acp.PROTOCOL_VERSION_V2 if acp_is_v2(session.conn) else acp.PROTOCOL_VERSION
	encoded, encode_error := acp.config_options_encode(options, version, context.temp_allocator)
	return encoded, encode_error == nil
}

@(require_results)
acp_models_state :: proc(session: ^ACP_Session) -> (ACP_Models_State, bool) {
	models: []agent.Catalog_Model
	if sync.mutex_guard(&session.conn.app.catalog_mu) {
		models = session.conn.app.setup.catalog.models[:]
	}
	if len(models) == 0 { return {}, true }
	result: ACP_Models_State
	current, current_error := acp_model_value(session.provider_id, session.model_id, context.temp_allocator)
	if current_error != nil { return {}, false }
	result.current_model_id = current
	available, available_error := make([]ACP_Model_Info, len(models), context.temp_allocator)
	if available_error != nil { return {}, false }
	names: [dynamic]string
	names.allocator = context.temp_allocator
	defer delete(names)
	for model, index in models {
		name := model.id
		if name_value, is_text := model.display_name.?; is_text && name_value != "" { name = name_value }
		value, value_error := acp_model_value(model.provider_id, model.id, context.temp_allocator)
		if value_error != nil { return {}, false }
		append(&names, name)
		available[index] = ACP_Model_Info {
			model_id = value,
			name     = names[len(names) - 1],
		}
	}
	result.available_models = available
	return result, true
}

acp_session_timestamp :: proc(at_ms: i64) -> string {
	if at_ms <= 0 { return "" }
	instant := time.unix(at_ms / 1000, (at_ms % 1000) * 1_000_000)
	datetime, valid := time.time_to_datetime(instant)
	if !valid { return "" }
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", datetime.year, datetime.month, datetime.day, datetime.hour, datetime.minute, datetime.second)
}

@(require_results)
acp_session_cursor_decode :: proc(cursor: string) -> (journal.Journal_Seq, bool) {
	sequence, parsed := strconv.parse_i64(cursor)
	return journal.Journal_Seq(sequence), parsed && sequence > 0
}

acp_session_cursor_encode :: proc(value: journal.Journal_Seq) -> string {
	return fmt.tprintf("%d", i64(value))
}

ACP_SESSION_LIST_PAGE_SIZE :: 50

// --- streaming what happens ---------------------------------------------------

// acp_sent ends the wait of session when a frame was not queued. The writer has
// latched the failure and the run reports it, so the client no longer hears this session.
acp_sent :: proc(session: ^ACP_Session, result: acp.Write_Error) {
	if result != .None { acp_cancel_session(session) }
}

// acp_notify sends one session/update notification carrying update. Every streamed
// frame is built here, so the session id and the notification name are stated once.
@(require_results)
acp_notify :: proc(session: ^ACP_Session, update: $T) -> acp.Write_Error {
	params := acp.Session_Notification(T) {
		session_id = acp_session_id(session),
		update     = update,
	}
	return acp.write_notification(&session.conn.writer, acp.METHOD_SESSION_UPDATE, params)
}

@(require_results)
acp_send_session_info :: proc(session: ^ACP_Session, title: string) -> acp.Write_Error {
	return acp_notify(session, acp.Session_Info_Update{session_update = acp.UPDATE_SESSION_INFO, title = title})
}

// acp_send_user_message writes one user message. Only v2 names one; v1 carries user
// lines as message chunks.
@(require_results)
acp_send_user_message :: proc(session: ^ACP_Session, message_id, text: string) -> acp.Write_Error {
	if !acp_is_v2(session.conn) { return .Closed }
	content, content_error := make([]acp.Text_Content, 1, context.temp_allocator)
	if content_error != nil { return .Allocation }
	content[0] = {
		type = acp.CONTENT_TEXT,
		text = text,
	}
	return acp_notify(session, acp.Message_Update{session_update = acp.UPDATE_USER_MESSAGE, message_id = message_id, content = content})
}

@(require_results)
acp_send_state :: proc(session: ^ACP_Session, state, stop_reason: string, error: Maybe(acp.RPC_Error) = nil) -> acp.Write_Error {
	if !acp_is_v2(session.conn) { return .Closed }
	return acp_notify(session, acp.State_Update{session_update = acp.UPDATE_STATE, state = state, stop_reason = stop_reason, error = error})
}

@(require_results)
acp_send_message_full :: proc(session: ^ACP_Session, kind, message_id, text: string) -> acp.Write_Error {
	if !acp_is_v2(session.conn) { return acp_send_message(session, kind, text, message_id) }
	content, content_error := make([]acp.Text_Content, 1, context.temp_allocator)
	if content_error != nil { return .Allocation }
	content[0] = {
		type = acp.CONTENT_TEXT,
		text = text,
	}
	return acp_notify(session, acp.Message_Update{session_update = kind, message_id = message_id, content = content})
}

@(require_results)
acp_send_message :: proc(session: ^ACP_Session, kind: string, text, message_id: string) -> acp.Write_Error {
	resolved_message_id := message_id
	if acp_is_v2(session.conn) && resolved_message_id == "" {
		resolved_message_id = acp_next_message_id(session)
	}
	return acp_notify(session, acp.Message_Chunk{session_update = kind, content = {type = acp.CONTENT_TEXT, text = text}, message_id = resolved_message_id})
}

// acp_send_tool_call announces one call with the state it is in when it is announced: a
// call about to run is pending, and a call replayed from the record already has its
// output.
@(require_results)
acp_send_tool_call :: proc(session: ^ACP_Session, call_id, name, arguments: string, status: acp.Tool_Status, output: string) -> acp.Write_Error {
	// The arguments are parsed for the client's benefit and released after the frame is
	// written, not when this block ends: the value the update carries must outlive it.
	raw, parse_err := json.parse_string(arguments, .JSON, true, context.temp_allocator)
	defer if parse_err == nil { json.destroy_value(raw, context.temp_allocator) }
	content: []acp.Tool_Call_Content
	if output != "" {
		made, content_error := make([]acp.Tool_Call_Content, 1, context.temp_allocator)
		if content_error != nil { return .Allocation }
		made[0] = acp_tool_content(output)
		content = made
	}
	if acp_is_v2(session.conn) {
		return acp_notify(
			session,
			acp.Tool_Call_Update_V2 {
				session_update = acp.UPDATE_TOOL_CALL_UPDATE,
				tool_call_id = call_id,
				name = name,
				title = acp_tool_title(name, arguments),
				kind = acp.tool_kind_name(acp_tool_kind(name)),
				status = acp.tool_status_name(status),
				content = content,
				raw_input = raw if parse_err == nil else nil,
			},
		)
	}
	return acp_notify(
		session,
		acp.Tool_Call {
			session_update = acp.UPDATE_TOOL_CALL,
			tool_call_id = call_id,
			title = acp_tool_title(name, arguments),
			kind = acp.tool_kind_name(acp_tool_kind(name)),
			status = acp.tool_status_name(status),
			content = content,
			raw_input = raw if parse_err == nil else nil,
		},
	)
}

// acp_send_tool_result settles a call that was already announced, by its id.
@(require_results)
acp_send_tool_result :: proc(session: ^ACP_Session, call_id: string, status: acp.Tool_Status, output: string) -> acp.Write_Error {
	content, content_error := make([]acp.Tool_Call_Content, 1, context.temp_allocator)
	if content_error != nil { return .Allocation }
	content[0] = acp_tool_content(output)
	if acp_is_v2(session.conn) {
		return acp_notify(
			session,
			acp.Tool_Call_Update_V2 {
				session_update = acp.UPDATE_TOOL_CALL_UPDATE,
				tool_call_id = call_id,
				status = acp.tool_status_name(status),
				content = content,
			},
		)
	}
	return acp_notify(
		session,
		acp.Tool_Call_Update{session_update = acp.UPDATE_TOOL_CALL_UPDATE, tool_call_id = call_id, status = acp.tool_status_name(status), content = content},
	)
}

@(private)
acp_tool_content :: proc(text: string) -> acp.Tool_Call_Content {
	return {type = acp.TOOL_CALL_CONTENT_INLINE, content = {type = acp.CONTENT_TEXT, text = text}}
}

// acp_send_usage reports how full the context is: the size the provider measured, or the
// harness's own count when the provider reported none, against the model's window.
@(require_results)
acp_send_usage :: proc(session: ^ACP_Session, used, size: i64) -> acp.Write_Error {
	return acp_notify(session, acp.Usage_Update{session_update = acp.UPDATE_USAGE, used = used, size = size})
}

// acp_session_id is the id a session update names. The worker publishes it under the
// table lock, so it is borrowed for the write and no longer.
acp_session_id :: proc(session: ^ACP_Session) -> string {
	return session.id
}

// acp_last_error is what the turn's terminal record said went wrong, in temp memory.
acp_last_error :: proc(session: ^ACP_Session) -> string {
	record, found, read_error := journal.read_latest(
		session.store,
		{session = session.session_id, turn = session.follow.cursor.turn, kinds = {.Turn_Completed}},
		context.temp_allocator,
	)
	if read_error != nil || !found { return "" }
	defer journal.record_destroy(&record, context.temp_allocator)
	completed, is_completed := journal.payload_as(record, journal.Turn_Completed)
	if !is_completed { return "" }
	return completed.detail
}

acp_next_message_id :: proc(session: ^ACP_Session) -> string {
	session.message_seq += 1
	return fmt.tprintf("msg-%d", session.message_seq)
}

@(private)
acp_current_message_id :: proc(session: ^ACP_Session) -> string {
	if acp_is_v2(session.conn) && session.active_message_id != "" {
		return session.active_message_id
	}
	return fmt.tprintf("msg-%d", session.message_seq)
}

acp_replay_notice_id :: proc(item: agent.Projection_Item) -> string {
	return fmt.tprintf("msg-entry-%d", i64(item.node))
}

// acp_replay_user_message_id matches the id the live turn gave its occurrence-th user message.
acp_replay_user_message_id :: proc(item: agent.Projection_Item, occurrence: int) -> string {
	if item.turn != 0 { return fmt.tprintf("msg-user-%d-%d", i64(item.turn), occurrence) }
	return fmt.tprintf("msg-entry-%d", i64(item.node))
}

acp_replay_assistant_message_id :: proc(item: agent.Projection_Item) -> string {
	if item.turn != 0 && item.request != 0 { return fmt.tprintf("msg-assistant-%d-%d", i64(item.turn), i64(item.request)) }
	return fmt.tprintf("msg-entry-%d", i64(item.node))
}

// acp_set_active_message_id names the v2 answer being streamed. The id is owned by
// the session so it outlives the scratch memory the streamed chunks borrow. A copy
// that fails leaves the previous id in place, so the stream continues under the id it
// already had rather than under none.
acp_set_active_message_id :: proc(session: ^ACP_Session, message_id: string) {
	owned, clone_error := strings.clone(message_id, session.conn.alloc)
	if clone_error != nil { return }
	delete(session.active_message_id, session.conn.alloc)
	session.active_message_id = owned
}

acp_clear_active_message_id :: proc(session: ^ACP_Session) {
	delete(session.active_message_id, session.conn.alloc)
	session.active_message_id = ""
}

// acp_tool_status maps a harness outcome to the wire status. v2 names cancellation;
// v1 has no cancelled state, so a cancelled call reads as failed there.
acp_tool_status :: proc(session: ^ACP_Session, outcome: journal.Tool_Outcome) -> acp.Tool_Status {
	if outcome == .Success { return .Completed }
	if outcome == .Cancelled && acp_is_v2(session.conn) { return .Cancelled }
	return .Failed
}

// --- the observer ------------------------------------------------------------

// acp_observer translates what the follow poll reads into session/update notifications.
// It runs on the session's worker while it polls, so it reaches the session directly.
acp_observer :: proc(session: ^ACP_Session) -> agent.Chat_Observer {
	return {
		user_data = session,
		user_text = acp_obs_user_text,
		assistant_begin = acp_obs_assistant_begin,
		assistant_text = acp_obs_assistant_text,
		tool_call = acp_obs_tool_call,
		tool_result = acp_obs_tool_result,
		message = acp_obs_message,
		turn_finished = acp_obs_turn_finished,
		request_finished = acp_obs_request_finished,
		retry_scheduled = acp_obs_retry_scheduled,
	}
}

// acp_obs_user_text shows one user-role line. The echo of the prompt the worker waits
// for is the user message the prompt's acceptance names, so its id is stashed for the
// worker instead of streamed twice. v1 never echoes the prompt live: it carries user
// lines as agent chunks, and only for lines another agent wrote.
acp_obs_user_text :: proc(user_data: rawptr, text: string, origin: journal.User_Origin) {
	session := cast(^ACP_Session)user_data
	if origin != .Prompt && origin != .Agent && origin != .Job { return }
	if acp_is_v2(session.conn) && origin == .Prompt && session.pending_text != "" && text == session.pending_text {
		session.pending_text = ""
		session.pending_accept = true
		message_id := acp_next_message_id(session)
		owned, clone_error := strings.clone(message_id, session.conn.alloc)
		if clone_error == nil {
			delete(session.accept_message, session.conn.alloc)
			session.accept_message = owned
		}
		acp_sent(session, acp_send_user_message(session, message_id, text))
		return
	}
	if origin == .Prompt && !acp_is_v2(session.conn) { return }
	if !acp_is_v2(session.conn) {
		acp_sent(session, acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, text, acp_next_message_id(session)))
		return
	}
	acp_sent(session, acp_send_user_message(session, acp_next_message_id(session), text))
}

acp_obs_assistant_begin :: proc(user_data: rawptr) {
	session := cast(^ACP_Session)user_data
	if acp_is_v2(session.conn) {
		acp_clear_active_message_id(session)
		acp_set_active_message_id(session, acp_next_message_id(session))
	} else {
		_ = acp_next_message_id(session)
	}
}

acp_obs_assistant_text :: proc(user_data: rawptr, text: string) {
	session := cast(^ACP_Session)user_data
	acp_sent(session, acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, text, acp_current_message_id(session)))
}

// acp_obs_message reports the harness's own lines separately from the model's answer.
// A V2 terminal failure belongs to the idle state update, not an agent message: the
// turn's own completion record already carries it, so the message is skipped once the
// follow saw that turn end.
acp_obs_message :: proc(user_data: rawptr, kind: agent.Chat_Message_Kind, text: string) {
	session := cast(^ACP_Session)user_data
	if acp_is_v2(session.conn) && kind == .Error && session.follow.cursor.ended && session.follow.cursor.outcome != .Completed {
		return
	}
	acp_sent(session, acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, text, acp_next_message_id(session)))
}

acp_obs_tool_call :: proc(user_data: rawptr, event: agent.Chat_Tool_Event) {
	session := cast(^ACP_Session)user_data
	if session.tool_calls == nil {
		session.tool_calls = make(map[journal.Call_Id]string, 8, session.conn.alloc)
	}
	if session.tool_calls != nil && event.call != 0 {
		owned, clone_error := strings.clone(event.call_id, session.conn.alloc)
		if clone_error == nil {
			delete(session.tool_calls[event.call], session.conn.alloc)
			session.tool_calls[event.call] = owned
		}
	}
	acp_sent(session, acp_send_tool_call(session, event.call_id, event.name, event.arguments, .Pending, ""))
}

acp_obs_tool_result :: proc(user_data: rawptr, call, parent_call: journal.Call_Id, name, arguments: string, result: ^agent.Tool_Result) {
	session := cast(^ACP_Session)user_data
	text := tool_display_preview(result.content)
	if text == "" { text = tool_display_summary(result) }
	acp_sent(session, acp_send_tool_result(session, session.tool_calls[call], acp_tool_status(session, result.outcome), text))
}

acp_obs_request_finished :: proc(user_data: rawptr) {
	session := cast(^ACP_Session)user_data
	if session.follow.cursor.window <= 0 { return }
	acp_sent(session, acp_send_usage(session, i64(session.follow.cursor.estimate), i64(session.follow.cursor.window)))
}

// acp_obs_turn_finished reports the turn's token use once the follow showed its end,
// which is the only point a follower knows the final estimate and window.
acp_obs_turn_finished :: proc(user_data: rawptr) {
	session := cast(^ACP_Session)user_data
	if session.follow.cursor.window <= 0 { return }
	acp_sent(session, acp_send_usage(session, i64(session.follow.cursor.estimate), i64(session.follow.cursor.window)))
}

acp_obs_retry_scheduled :: proc(user_data: rawptr, event: agent.Chat_Retry_Event) {
	session := cast(^ACP_Session)user_data
	acp_sent(session, acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, retry_display_text(event), acp_next_message_id(session)))
}

// --- replaying a loaded conversation -----------------------------------------

// acp_replay_session streams the conversation a client just loaded. Every entry the
// harness keeps becomes the update that carries it: the user's own lines, the model's
// answers, and each stored call with the result it produced. A client that asked to load
// a session shows the conversation it asked for rather than an empty one.
acp_replay_session :: proc(session: ^ACP_Session) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		acp_sent(
			session,
			acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, "the session's history could not be allocated", acp_next_message_id(session)),
		)
		return
	}
	defer virtual.arena_destroy(&arena)
	_, head, head_error := journal.session_head(session.store, session.session_id)
	if head_error != nil {
		acp_sent(session, acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, "the session's history could not be read", acp_next_message_id(session)))
		return
	}
	replayed, load_err := agent.projection_load(session.store, session.session_id, head, virtual.arena_allocator(&arena))
	if load_err != nil {
		acp_sent(session, acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, "the session's history could not be read", acp_next_message_id(session)))
		return
	}
	calls := make(map[journal.Call_Id]agent.Projected_Call, len(replayed.items), context.temp_allocator)
	defer delete(calls)
	user_occurrences := make(map[journal.Turn_Id]int, len(replayed.items), context.temp_allocator)
	defer delete(user_occurrences)
	for &item in replayed.items {
		#partial switch payload in item.payload {
		case agent.Projected_User:
			kind := acp.UPDATE_AGENT_MESSAGE_CHUNK
			message_kind := acp.UPDATE_AGENT_MESSAGE
			if payload.origin != .Harness {
				kind = acp.UPDATE_USER_MESSAGE_CHUNK
				message_kind = acp.UPDATE_USER_MESSAGE
			}
			message_id := acp_replay_notice_id(item)
			if payload.origin != .Harness {
				user_occurrences[item.turn] += 1
				message_id = acp_replay_user_message_id(item, user_occurrences[item.turn])
			}
			if acp_is_v2(session.conn) {
				acp_sent(session, acp_send_message_full(session, message_kind, message_id, payload.text))
			} else {
				acp_sent(session, acp_send_message(session, kind, payload.text, message_id))
			}
		case agent.Projected_Assistant:
			message_id := acp_replay_assistant_message_id(item)
			if acp_is_v2(session.conn) {
				acp_sent(session, acp_send_message_full(session, acp.UPDATE_AGENT_MESSAGE, message_id, payload.text))
			} else {
				acp_sent(session, acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, payload.text, message_id))
			}
		case agent.Projected_Call:
			calls[payload.call] = payload
		case agent.Projected_Result:
			call, known := calls[payload.call]
			if !known { continue }
			text := tool_display_preview(payload.content)
			if text == "" { text = journal.TOOL_OUTCOME_NAMES[payload.outcome] }
			acp_sent(session, acp_send_tool_call(session, call.provider_id, call.name, call.proposed, acp_tool_status(session, payload.outcome), text))
		}
	}
}

// --- presenting a call -------------------------------------------------------

// acp_tool_kind tells a client what a call does, so it can render the card the call
// deserves. What is left is the tools this harness ships, named here, and Other is the
// honest answer for anything else, including a tool an MCP session contributed without
// saying.
acp_tool_kind :: proc(name: string) -> acp.Tool_Kind {
	switch name {
	case agent.TOOL_SHELL_NAME, agent.TOOL_CODEMODE_NAME:
		return .Execute
	case agent.TOOL_READ_NAME, agent.TOOL_SKILLS_NAME, agent.TOOL_SKILL_NAME:
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
	excerpt, excerpt_error := agent.chat_title_from_prompt(detail, context.temp_allocator)
	if excerpt_error != nil || excerpt == "" { return name }
	return fmt.tprintf("%s %s", name, excerpt)
}
