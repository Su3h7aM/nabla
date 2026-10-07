#+build linux
package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
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
// session the request names, which owns that session. All threads enqueue output for the
// writer thread because a client cancels a turn by sending another message on the same
// stream.

// ACP_WORK_CAPACITY bounds requests waiting for one session's worker. The reader admits
// one session request at a time, so the queue holds the request being served and, briefly,
// nothing else.
ACP_WORK_CAPACITY :: 4

// ACP_READ_BYTES is how much of the input stream one read takes. It sizes a syscall,
// not a frame: the decoder keeps reading until the frame ends.
ACP_READ_BYTES :: 16 * 1024

// ACP_Work_Open_Session opens the session a client asked for: a new one in its working
// directory, or a stored one it names. session_ref names the stored session; the id of
// start aliases it, so only session_ref is released by acp_work_destroy.
ACP_Work_Open_Session :: struct {
	id:            acp.JSONRPC_Id, // the request to answer
	workspace:     string,
	session_ref:   string,
	mcp_servers:   [dynamic]agent.MCP_Server_Config,
	system_prompt: string,
	session_title: string,
	start:         Session_Start,
	replay:        bool,
}

// ACP_Work_Prompt runs one turn on the open session.
ACP_Work_Prompt :: struct {
	id:   acp.JSONRPC_Id, // the request to answer
	text: string,
}

// ACP_Work_Set_Model is Buzz's v1 model-selection RPC. Model selection runs on the
// session owner through ACP_Model_Request, so the worker only refuses it.
ACP_Work_Set_Model :: struct {
	id: acp.JSONRPC_Id, // the request to answer
}

// ACP_Work_Set_Config_Option applies the stable ACP model configuration method.
ACP_Work_Set_Config_Option :: struct {
	id:           acp.JSONRPC_Id, // the request to answer
	config_id:    string,
	config_value: string,
}

// ACP_Work_Close_Session releases the active v2 session.
ACP_Work_Close_Session :: struct {
	id: acp.JSONRPC_Id, // the request to answer
}

// ACP_Work is one request the reader handed to the worker. Every string is owned by the
// session's allocator and released by acp_work_destroy.
ACP_Work :: union {
	ACP_Work_Open_Session,
	ACP_Work_Prompt,
	ACP_Work_Set_Model,
	ACP_Work_Set_Config_Option,
	ACP_Work_Close_Session,
}

// ACP_Model_Kind identifies which model-selection RPC a reader handoff answers.
ACP_Model_Kind :: enum {
	// Set_Model identifies Buzz's v1 model-selection RPC.
	Set_Model,
	// Set_Config_Option applies the stable ACP model configuration method.
	Set_Config_Option,
}

ACP_Work_Chan :: chan.Chan(ACP_Work)

// ACP_Model_Request is an ACP model-change intent handed from the reader to the
// session owner. Its strings are connection-allocator owned until settled.
ACP_Model_Request :: struct {
	active:   bool,
	kind:     ACP_Model_Kind,
	id:       acp.JSONRPC_Id,
	model_id: string,
}

ACP_Model_Selection :: struct {
	active:     bool,
	kind:       ACP_Model_Kind,
	id:         acp.JSONRPC_Id,
	target:     agent.Model_Selection,
	transition: agent.Selection_Transition,
}

ACP_Wire_Profile :: enum {
	V1,
	V2,
}

@(require_results)
acp_is_v2 :: proc(conn: ^ACP_Server) -> bool {
	return conn.profile == .V2
}

@(require_results)
acp_session_has_work :: proc(session: ^ACP_Session) -> bool {
	sync.mutex_lock(&session.queue_mu)
	pending := session.pending_work > 0
	sync.mutex_unlock(&session.queue_mu)
	return pending
}

acp_queue_add :: proc(session: ^ACP_Session) {
	sync.mutex_lock(&session.queue_mu)
	session.pending_work += 1
	sync.mutex_unlock(&session.queue_mu)
}

acp_queue_remove :: proc(session: ^ACP_Session) {
	sync.mutex_lock(&session.queue_mu)
	session.pending_work -= 1
	if session.pending_work <= 0 {
		session.pending_work = 0
	}
	sync.mutex_unlock(&session.queue_mu)
}

acp_model_request_destroy :: proc(request: ^ACP_Model_Request, allocator: mem.Allocator) {
	switch id in request.id {
	case string:
		delete(id, allocator)
	case i64, f64, acp.JSONRPC_Null:
	}
	delete(request.model_id, allocator)
	request^ = {}
}

// acp_model_request_submit replaces only a not-yet-claimed intent. The caller transfers
// ownership whether it is superseded or accepted.
acp_model_request_submit :: proc(session: ^ACP_Session, request: ACP_Model_Request) {
	sync.mutex_lock(&session.model_mu)
	previous := session.model_request
	session.model_request = request
	session.model_cancel = false
	sync.mutex_unlock(&session.model_mu)
	if previous.active {
		_ = acp.writer_write_error(&session.conn.writer, previous.id, acp.ERROR_INVALID_REQUEST, "a newer model selection replaced this request")
		acp_model_request_destroy(&previous, session.conn.alloc)
	}
	agent.owner_wake_signal()
}

@(require_results)
acp_model_request_take :: proc(session: ^ACP_Session) -> ACP_Model_Request {
	sync.mutex_lock(&session.model_mu)
	request := session.model_request
	session.model_request = {}
	sync.mutex_unlock(&session.model_mu)
	return request
}

@(require_results)
acp_model_request_pending :: proc(session: ^ACP_Session) -> bool {
	sync.mutex_lock(&session.model_mu)
	pending := session.model_request.active
	sync.mutex_unlock(&session.model_mu)
	return pending
}

@(require_results)
acp_model_owner_work_pending :: proc(session: ^ACP_Session) -> bool {
	sync.mutex_lock(&session.model_mu)
	pending := session.model_request.active || session.model_cancel
	sync.mutex_unlock(&session.model_mu)
	return pending
}

acp_model_cancel_signal :: proc(session: ^ACP_Session) {
	sync.mutex_lock(&session.model_mu)
	session.model_cancel = true
	sync.mutex_unlock(&session.model_mu)
	agent.owner_wake_signal()
}

@(require_results)
acp_model_cancel_take :: proc(session: ^ACP_Session) -> (bool, ACP_Model_Request) {
	sync.mutex_lock(&session.model_mu)
	cancel := session.model_cancel
	session.model_cancel = false
	request: ACP_Model_Request
	if cancel {
		request = session.model_request
		session.model_request = {}
	}
	sync.mutex_unlock(&session.model_mu)
	return cancel, request
}

acp_model_selection_cancel :: proc(session: ^ACP_Session, request: ACP_Model_Request) {
	owned_request := request
	if owned_request.active {
		_ = acp.writer_write_error(
			&session.conn.writer,
			owned_request.id,
			acp.ERROR_INVALID_REQUEST,
			"the model selection was canceled before it could be applied",
		)
		acp_model_request_destroy(&owned_request, session.conn.alloc)
	}
	if session.model_selection.active {
		acp_model_selection_error(session, &session.model_selection, acp.ERROR_INVALID_REQUEST, "the model selection was canceled before it could be applied")
	}
}

acp_model_selection_destroy :: proc(session: ^ACP_Session, selection: ^ACP_Model_Selection) {
	if selection.active {
		switch id in selection.id {
		case string:
			delete(id, session.conn.alloc)
		case i64, f64, acp.JSONRPC_Null:
		}
		agent.model_selection_destroy(&selection.target, session.app.setup.alloc)
	}
	selection^ = {}
}

acp_model_selection_error :: proc(session: ^ACP_Session, selection: ^ACP_Model_Selection, code: i64, message: string) {
	if !selection.active { return }
	_ = acp.writer_write_error(&session.conn.writer, selection.id, code, message)
	acp_model_selection_destroy(session, selection)
}

// acp_model_request_resolve takes the newest reader handoff and resolves it once on the
// session owner. The target owns its catalog-derived strings through installation.
acp_model_request_resolve :: proc(session: ^ACP_Session) {
	request := acp_model_request_take(session)
	if !request.active { return }
	if session.model_selection.active {
		acp_model_selection_error(session, &session.model_selection, acp.ERROR_INVALID_REQUEST, "a newer model selection replaced this request")
	}
	if !acp_session_live(session) {
		_ = acp.writer_write_error(&session.conn.writer, request.id, acp.ERROR_INVALID_PARAMS, "the session changed before the model selection could run")
		acp_model_request_destroy(&request, session.conn.alloc)
		return
	}
	app := &session.app
	provider_id := ""
	provider_error := false
	sync.mutex_lock(&app.catalog_mu)
	for provider in app.setup.catalog.providers {
		if _, found := agent.catalog_find_model(&app.setup.catalog, provider.id, request.model_id); !found { continue }
		provider_copy, clone_error := strings.clone(provider.id, app.setup.alloc)
		provider_id = provider_copy
		provider_error = clone_error != nil
		break
	}
	sync.mutex_unlock(&app.catalog_mu)
	if provider_error {
		_ = acp.writer_write_error(&session.conn.writer, request.id, acp.ERROR_INTERNAL, "the provider id could not be allocated")
		acp_model_request_destroy(&request, session.conn.alloc)
		return
	}
	if provider_id == "" {
		_ = acp.writer_write_error(&session.conn.writer, request.id, acp.ERROR_INVALID_PARAMS, fmt.tprintf("the model %q is not available", request.model_id))
		acp_model_request_destroy(&request, session.conn.alloc)
		return
	}
	defer delete(provider_id, app.setup.alloc)
	target, problem := selection_target_resolve(app, provider_id, request.model_id, app.setup.alloc)
	defer if problem != "" { delete(problem, context.temp_allocator) }
	if target.provider_id == "" {
		_ = acp.writer_write_error(&session.conn.writer, request.id, acp.ERROR_INVALID_PARAMS, problem)
		acp_model_request_destroy(&request, session.conn.alloc)
		return
	}
	request_id := request.id
	request.id = ""
	delete(request.model_id, session.conn.alloc)
	request.model_id = ""
	session.model_selection = ACP_Model_Selection {
		active = true,
		kind   = request.kind,
		id     = request_id,
		target = target,
	}
	request = {}
}

// acp_model_selection_service checks a pending target at an owner boundary or while
// idle. The transition is caller-owned state and remains with the target while pending.
acp_model_selection_service :: proc(session: ^ACP_Session) -> ai.Provider_Connection {
	cancel, request := acp_model_cancel_take(session)
	if cancel {
		acp_model_selection_cancel(session, request)
		return session.app.run.connection
	}
	if acp_model_request_pending(session) { acp_model_request_resolve(session) }
	selection := &session.model_selection
	if !selection.active { return session.app.run.connection }
	if !acp_session_live(session) {
		acp_model_selection_error(session, selection, acp.ERROR_INVALID_PARAMS, "the session changed before the model selection could be applied")
		return session.app.run.connection
	}
	status, problem, selection_error := agent.chat_selection_check(
		&session.app.setup.session,
		selection.target,
		&selection.transition,
		session.app.compact_on_switch,
		session.app.run.connection,
	)
	defer if problem != "" { delete(problem, context.temp_allocator) }
	if selection_error != nil {
		detail := journal.error_text(selection_error, context.temp_allocator)
		session.app.setup.session.storage_failed = true
		acp_model_selection_error(session, selection, acp.ERROR_INTERNAL, fmt.tprintf("the model switch could not be recorded: %s", detail))
		return session.app.run.connection
	}
	switch status {
	case .Pending:
		return session.app.run.connection
	case .Refused:
		message := problem
		if message == "" { message = "the model selection was refused" }
		acp_model_selection_error(session, selection, acp.ERROR_INVALID_PARAMS, message)
	case .Ready:
		cancel_before_install, request_before_install := acp_model_cancel_take(session)
		if cancel_before_install {
			acp_model_selection_cancel(session, request_before_install)
			return session.app.run.connection
		}
		if acp_model_request_pending(session) { return session.app.run.connection }
		model_id := selection.target.model_id
		installed := selection_install(&session.app, selection.target, "", false)
		if !installed {
			acp_model_selection_error(session, selection, acp.ERROR_INTERNAL, "the selected model could not be installed durably")
			return session.app.run.connection
		}
		if selection.kind == .Set_Model {
			_ = acp.writer_write_response(
				&session.conn.writer,
				selection.id,
				acp.Session_Set_Model_Result{session_id = acp_session_id(session), model_id = model_id},
			)
		} else if acp_is_v2(session.conn) {
			v2_options, options_ok := acp_model_config_options_v2(session)
			if !options_ok {
				acp_model_selection_error(
					session,
					selection,
					acp.ERROR_INTERNAL,
					"the model was installed but its configuration response could not be allocated",
				)
				return session.app.run.connection
			}
			_ = acp.writer_write_response(&session.conn.writer, selection.id, acp.V2_Session_Set_Config_Option_Result{config_options = v2_options})
		} else {
			v1_options, options_ok := acp_model_config_options_v1(session)
			if !options_ok {
				acp_model_selection_error(
					session,
					selection,
					acp.ERROR_INTERNAL,
					"the model was installed but its configuration response could not be allocated",
				)
				return session.app.run.connection
			}
			_ = acp.writer_write_response(&session.conn.writer, selection.id, acp.V1_Session_Set_Config_Option_Result{config_options = v1_options})
		}
		acp_model_selection_destroy(session, selection)
	}
	return session.app.run.connection
}

acp_model_selection_steer :: proc(steer: ^agent.Steer_Context) -> ai.Provider_Connection {
	session := cast(^ACP_Session)steer.apply_data
	_ = acp_model_selection_service(session)
	sync.mutex_lock(&session.app.run.mu)
	defer sync.mutex_unlock(&session.app.run.mu)
	return session.app.run.connection
}

// acp_session_live reports whether the session is open and not closing, which is what
// decides whether a model selection still has a session to apply to.
@(require_results)
acp_session_live :: proc(session: ^ACP_Session) -> bool {
	sync.mutex_lock(&session.conn.table_mu)
	defer sync.mutex_unlock(&session.conn.table_mu)
	return session.id != "" && !session.closing
}

// acp_work_session_valid reports whether a queued request may still run. A session that
// started closing refuses everything but its own close, and a request that needs an open
// conversation waits for the open that makes one. Owner thread only.
@(require_results)
acp_work_session_valid :: proc(session: ^ACP_Session, work: ACP_Work) -> bool {
	sync.mutex_lock(&session.conn.table_mu)
	closing := session.closing
	sync.mutex_unlock(&session.conn.table_mu)
	switch _ in work {
	case ACP_Work_Open_Session:
		return !closing
	case ACP_Work_Prompt, ACP_Work_Set_Model, ACP_Work_Set_Config_Option:
		return !closing && session.app.setup.store != nil
	case ACP_Work_Close_Session:
		return session.app.setup.store != nil
	}
	return false
}

// --- lifetime ----------------------------------------------------------------

// acp_work_destroy releases the strings one queued request owns.
acp_work_destroy :: proc(work: ^ACP_Work, allocator: mem.Allocator) {
	switch item in work^ {
	case ACP_Work_Open_Session:
		acp_work_id_destroy(item.id, allocator)
		delete(item.workspace, allocator)
		delete(item.session_ref, allocator)
		servers := item.mcp_servers
		agent.MCP_Server_Configs_Destroy(&servers, allocator)
		delete(item.system_prompt, allocator)
		delete(item.session_title, allocator)
	case ACP_Work_Prompt:
		acp_work_id_destroy(item.id, allocator)
		delete(item.text, allocator)
	case ACP_Work_Set_Model:
		acp_work_id_destroy(item.id, allocator)
	case ACP_Work_Set_Config_Option:
		acp_work_id_destroy(item.id, allocator)
		delete(item.config_id, allocator)
		delete(item.config_value, allocator)
	case ACP_Work_Close_Session:
		acp_work_id_destroy(item.id, allocator)
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

// acp_work_request_id reads the request id a response will carry.
@(require_results)
acp_work_request_id :: proc(work: ACP_Work) -> acp.JSONRPC_Id {
	switch item in work {
	case ACP_Work_Open_Session:
		return item.id
	case ACP_Work_Prompt:
		return item.id
	case ACP_Work_Set_Model:
		return item.id
	case ACP_Work_Set_Config_Option:
		return item.id
	case ACP_Work_Close_Session:
		return item.id
	}
	return {}
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

// --- the worker --------------------------------------------------------------

// acp_worker runs the requests the reader hands over and owns the session while it does.
// While a V2 client has nothing queued, a background subagent's report starts a turn of its
// own; a V1 client cannot receive a turn it did not ask for, so its reports wait in the
// inbox for the next prompt's turn. It leaves when the queue is closed and drained.
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
			// A closed queue is shutdown, which starts no report turn.
			if chan.is_closed(session.work) { break }
			if !acp_owner_service_begin(session) {
				agent.owner_wake_wait(seen, nil)
				continue
			}
			if acp_is_v2(session.conn) && session.app.setup.store != nil {
				if acp_report_turn(session) {
					acp_owner_service_end(session)
					free_all(context.temp_allocator)
					continue
				}
				// Reports arrive through the owner wake, which new requests signal too.
				if agent.chat_agents_pending(&session.app.setup.session) {
					acp_owner_service_end(session)
					agent.owner_wake_wait(seen, nil)
					continue
				}
			}
			model_pending := acp_model_owner_work_pending(session) || session.model_selection.active
			if model_pending {
				_ = acp_model_selection_service(session)
			}
			compact_pending := session.app.setup.session.store != nil && session.app.setup.session.compact.state != agent.Compact_State.Idle
			if model_pending || compact_pending {
				if compact_pending {
					observer := acp_observer(session)
					_ = agent.chat_compact_idle_service(&session.app.setup.session, observer, session.app.run.connection)
					if session.model_selection.active {
						_ = acp_model_selection_service(session)
						if session.app.setup.session.compact.state != agent.Compact_State.Idle {
							_ = agent.chat_compact_idle_service(&session.app.setup.session, observer, session.app.run.connection)
						}
					}
				}
				acp_owner_service_end(session)
				free_all(context.temp_allocator)
				agent.owner_wake_wait(seen, agent.chat_compact_deadline(&session.app.setup.session))
				continue
			}
			acp_owner_service_end(session)
			free_all(context.temp_allocator)
			agent.owner_wake_wait(seen, nil)
			continue
		}
		sync.mutex_lock(&session.conn.table_mu)
		session.owner_active = true
		sync.mutex_unlock(&session.conn.table_mu)
		acp_run_work(session, work)
		acp_owner_service_end(session)
		retiring := false
		switch _ in work {
		case ACP_Work_Close_Session:
			retiring = true
		case ACP_Work_Open_Session:
			retiring = !session.opened
		case ACP_Work_Prompt, ACP_Work_Set_Model, ACP_Work_Set_Config_Option:
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
		// A write error latches the writer, which the run reports as its failure, so
		// every reply's own result is not acted on here or below.
		_ = acp.writer_write_error(
			&session.conn.writer,
			acp_work_request_id(work),
			acp.ERROR_INVALID_PARAMS,
			"the session changed before the request could run",
		)
	} else {
		switch item in work {
		case ACP_Work_Open_Session:
			acp_work_open_session(session, item)
		case ACP_Work_Prompt:
			acp_work_prompt(session, item)
		case ACP_Work_Set_Model:
			_ = acp.writer_write_error(&session.conn.writer, item.id, acp.ERROR_INVALID_REQUEST, "model selection must be handled by the session owner")
		case ACP_Work_Set_Config_Option:
			acp_work_set_config_option(session, item)
		case ACP_Work_Close_Session:
			acp_work_close_session(session, item)
		}
	}
	// The request is answered, so the next one may be admitted. The cancellation belongs
	// to the turn that just ended; a client that cancels a finished turn is ignored.
	agent.turn_control_clear(&session.app.run.control)
	acp_queue_remove(session)
}

// --- opening a session -------------------------------------------------------

acp_work_open_session :: proc(session: ^ACP_Session, work: ACP_Work_Open_Session) {
	// A session that already holds its conversation is opened a second time by a load or
	// resume of its own id: the conversation is the same, so it is announced again and
	// nothing is claimed or selected. A refusal then leaves the session as it was.
	reopen := session.opened
	if !reopen {
		message, opened := acp_session_open(session, work.workspace, work.start)
		if !opened {
			if message == "" {
				_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INTERNAL, "the session could not be opened")
			} else {
				defer delete(message, session.app.setup.alloc)
				_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INVALID_PARAMS, message)
			}
			return
		}
		delete(message, session.app.setup.alloc)
		acp_session_select_model(session)
	}
	if !agent.chat_session_set_client_instructions(&session.app.setup.session, work.system_prompt) {
		_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INTERNAL, "the client system prompt could not be stored")
		return
	}
	if !acp_server_apply_mcp(session, work.mcp_servers) {
		_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INTERNAL, "the session MCP configuration could not be installed")
		return
	}

	// Allocate every value that can fail before publishing the new session id. A
	// response must not advertise a session that failed partway through setup.
	v1_options: []acp.V1_Config_Option
	v1_options_ok: bool
	v2_options: []acp.V2_Config_Option
	v2_options_ok: bool
	if acp_is_v2(session.conn) {
		v2_options, v2_options_ok = acp_model_config_options_v2(session)
		if !v2_options_ok {
			_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INTERNAL, "the model configuration could not be allocated")
			return
		}
	} else {
		// A stored session brings its own model state; only a fresh session lists the
		// catalog's, so the picker the client shows is never built from nothing.
		switch _ in work.start {
		case Start_Resume_Id:
		case Start_Fresh, Start_Resume_Latest, nil:
			v1_options, v1_options_ok = acp_model_config_options_v1(session)
			if !v1_options_ok {
				_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INTERNAL, "the model configuration could not be allocated")
				return
			}
		}
	}
	models: acp.Models_State
	resume_open := false
	switch _ in work.start {
	case Start_Resume_Id:
		resume_open = true
	case Start_Fresh, Start_Resume_Latest, nil:
	}
	if !resume_open && !acp_is_v2(session.conn) {
		models_ok: bool
		models, models_ok = acp_models_state(session)
		if !models_ok {
			_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INTERNAL, "the model catalog could not be allocated")
			return
		}
	}

	session_id := agent.chat_session_text(&session.app.setup.session)
	owned_session_id, session_id_error := strings.clone(session_id, session.conn.alloc)
	if session_id_error != nil {
		_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INTERNAL, "the session reference could not be allocated")
		return
	}
	owned_title, title_error := strings.clone(work.session_title, session.conn.alloc)
	if title_error != nil {
		delete(owned_session_id, session.conn.alloc)
		_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INTERNAL, "the session title could not be allocated")
		return
	}
	owned_workspace, workspace_error := strings.clone(session.app.setup.workspace, session.conn.alloc)
	if workspace_error != nil {
		delete(owned_session_id, session.conn.alloc)
		delete(owned_title, session.conn.alloc)
		_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INTERNAL, "the session directory could not be allocated")
		return
	}
	sync.mutex_lock(&session.conn.table_mu)
	delete(session.id, session.conn.alloc)
	session.id = owned_session_id
	delete(session.title, session.conn.alloc)
	session.title = owned_title
	delete(session.workspace, session.conn.alloc)
	session.workspace = owned_workspace
	sync.mutex_unlock(&session.conn.table_mu)
	session.opened = true

	if warning := app_tools_refresh(&session.app); warning != "" {
		_ = acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, warning, acp_next_message_id(session))
	}
	if work.session_title != "" { _ = acp_send_session_info(session, work.session_title) }
	if work.replay {
		acp_replay_session(session)
	}
	switch _ in work.start {
	case Start_Resume_Id:
		if acp_is_v2(session.conn) {
			_ = acp.writer_write_response(&session.conn.writer, work.id, acp.Session_Resume_Result{config_options = v2_options})
		} else {
			_ = acp.writer_write_response(&session.conn.writer, work.id, acp.Empty_Result{})
		}
	case Start_Fresh, Start_Resume_Latest, nil:
		if acp_is_v2(session.conn) {
			_ = acp.writer_write_response(&session.conn.writer, work.id, acp.V2_Session_New_Result{session_id = session_id, config_options = v2_options})
		} else {
			_ = acp.writer_write_response(
				&session.conn.writer,
				work.id,
				acp.Session_New_Result{session_id = session_id, config_options = v1_options, models = models},
			)
		}
	}
}

acp_restore_base_runtime :: proc(session: ^ACP_Session) {
	// A failed restore leaves the zero runtime: no MCP servers. The caller reports the
	// failure that led here either way, so the restore failure is not answered twice.
	restored, _ := mcp_runtime_make(session.conn.base_mcp_servers, session.app.setup.alloc)
	session.app.setup.mcp = restored
}

@(require_results)
acp_server_apply_mcp :: proc(session: ^ACP_Session, requested: [dynamic]agent.MCP_Server_Config) -> bool {
	setup := &session.app.setup
	// The old runtime owns processes and bindings that the newly opened session no
	// longer borrows. Stop it before changing the configuration list.
	mcp_runtime_destroy(&setup.mcp)
	agent.MCP_Server_Configs_Destroy(&session.mcp_servers_owned, session.conn.alloc)
	setup.mcp_servers = session.conn.base_mcp_servers
	if len(requested) == 0 {
		setup.mcp_servers = session.conn.base_mcp_servers
		built, ok := mcp_runtime_make(setup.mcp_servers, setup.alloc)
		setup.mcp = built
		return ok
	}
	combined, clone_error := agent.MCP_Server_Configs_Clone(session.conn.base_mcp_servers, session.conn.alloc)
	if clone_error != .None {
		acp_restore_base_runtime(session)
		return false
	}
	failed := true
	defer if failed { agent.MCP_Server_Configs_Destroy(&combined, session.conn.alloc) }
	for existing in combined {
		for wanted in requested {
			if existing.id == wanted.id {
				acp_restore_base_runtime(session)
				return false
			}
		}
	}
	for server_config, index in requested {
		appended := append(&combined, server_config)
		if appended != 1 {
			if appended == 0 {
				agent.MCP_Server_Config_Destroy(&requested[index], session.conn.alloc)
				requested[index] = {}
			}
			acp_restore_base_runtime(session)
			return false
		}
		requested[index] = {}
	}
	built, runtime_ok := mcp_runtime_make(combined[:], setup.alloc)
	if !runtime_ok {
		acp_restore_base_runtime(session)
		return false
	}
	session.mcp_servers_owned = combined
	setup.mcp_servers = combined[:]
	setup.mcp = built
	failed = false
	return true
}

// acp_open_message copies a refusal reason into setup memory. An empty result means
// the copy itself failed, which the caller answers as an internal error: without
// memory there is no better account of what went wrong.
@(require_results)
acp_open_message :: proc(text: string, allocator: mem.Allocator) -> string {
	message, clone_error := strings.clone(text, allocator)
	if clone_error != nil { return "" }
	return message
}

// acp_session_open takes the conversation a client asked for into the session: the
// client's working directory for a new one, the stored session for a loaded one. It is the
// one place a session another process runs would be followed instead of refused; today
// session_open refuses it because the session's setup does not share sessions.
//
// The message of a refusal is owned by the setup's allocator.
@(require_results)
acp_session_open :: proc(session: ^ACP_Session, workspace: string, start: Session_Start) -> (message: string, ok: bool) {
	app := &session.app
	opened, open_message, opened_ok := session_open(&app.setup, start, workspace)
	if !opened_ok { return open_message, false }
	report_recovery(opened.recovery, opened.queued)
	if problem := session_install(&app.setup, &opened); problem != "" {
		return acp_open_message(problem, app.setup.alloc), false
	}
	return "", true
}

// acp_session_select_model gives a freshly opened session a model: the one its own record
// names, otherwise the one this connection chose at startup. A stale record falls back to
// the connection's selection, and a session with no selection at all still opens, because
// the prompt is what refuses it.
acp_session_select_model :: proc(session: ^ACP_Session) {
	app := &session.app
	chosen := &session.conn.app.setup
	if app.setup.resumed_provider != "" && app.setup.resumed_model != "" {
		if acp_selection_install(session, app.setup.resumed_provider, app.setup.resumed_model, "") { return }
	}
	if chosen.provider_id != "" && chosen.model_id != "" {
		if acp_selection_install(session, chosen.provider_id, chosen.model_id, session.conn.default_effort) { return }
	}
	if app.setup.model_id == "" { _ = acp_select_first_model(session) }
}

acp_selection_install :: proc(session: ^ACP_Session, provider_id, model_id, effort: string) -> bool {
	target, problem := selection_target_resolve(&session.app, provider_id, model_id, session.app.setup.alloc)
	defer if problem != "" { delete(problem, context.temp_allocator) }
	if target.model_id == "" { return false }
	defer agent.model_selection_destroy(&target, session.app.setup.alloc)
	return selection_install(&session.app, target, effort, false)
}

// acp_select_first_model picks the first configured provider that can serve a request and
// its first model, in catalog order, so the choice is the same on every launch. Nothing is
// persisted: a model chosen for an editor conversation is not the user's own last choice.
// Every candidate is named before any of them is tried, because applying a selection takes
// the catalog lock and a publication releases the catalog the names were read from.
@(require_results)
acp_select_first_model :: proc(session: ^ACP_Session) -> bool {
	app := &session.app
	candidates, candidates_ok := acp_servable_models(app, app.run.alloc)
	if !candidates_ok { return false }
	defer acp_candidates_destroy(candidates, app.run.alloc)
	for candidate in candidates {
		if acp_selection_install(session, candidate.provider_id, candidate.model_id, "") { return true }
	}
	return false
}

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
	sync.mutex_lock(&app.catalog_mu)
	defer sync.mutex_unlock(&app.catalog_mu)
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

// --- running a prompt --------------------------------------------------------

acp_work_set_config_option :: proc(session: ^ACP_Session, work: ACP_Work_Set_Config_Option) {
	applied := false
	if work.config_id == "effort" {
		applied = agent.chat_session_set_effort(&session.app.setup.session, work.config_value)
	}
	if !applied {
		_ = acp.writer_write_error(
			&session.conn.writer,
			work.id,
			acp.ERROR_INVALID_PARAMS,
			fmt.tprintf("the config option %q cannot be set to %q", work.config_id, work.config_value),
		)
		return
	}
	options, options_ok := acp_model_config_options_v1(session)
	if !options_ok {
		_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INTERNAL, "the model configuration could not be allocated")
		return
	}
	if acp_is_v2(session.conn) {
		v2_options, v2_options_ok := acp_model_config_options_v2(session)
		if !v2_options_ok {
			_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INTERNAL, "the model configuration could not be allocated")
			return
		}
		_ = acp.writer_write_response(&session.conn.writer, work.id, acp.V2_Session_Set_Config_Option_Result{config_options = v2_options})
		return
	}
	_ = acp.writer_write_response(&session.conn.writer, work.id, acp.V1_Session_Set_Config_Option_Result{config_options = options})
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

// acp_work_close_session releases the session before it answers, so a client that loads the
// session again as soon as it hears the close finds its claim dropped.
acp_work_close_session :: proc(session: ^ACP_Session, work: ACP_Work_Close_Session) {
	acp_session_release(session)
	_ = acp.writer_write_response(&session.conn.writer, work.id, acp.Empty_Result{})
}

acp_work_prompt :: proc(session: ^ACP_Session, work: ACP_Work_Prompt) {
	chat := &session.app.setup.session
	accepted := agent.chat_session_accept_user(chat, work.text, acp_observer(session))
	switch accepted {
	case .Accepted:
	case .Storage_Failed:
		_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INTERNAL, agent.chat_session_last_error(chat))
		return
	case .Busy:
		_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INVALID_REQUEST, "the session is already running a turn")
		return
	}
	if acp_is_v2(session.conn) {
		acp_clear_active_message_id(session)
		message_id := acp_user_message_id(session)
		_ = acp_send_user_message(session, message_id, work.text)
		_ = acp.writer_write_response(&session.conn.writer, work.id, acp.Prompt_Accepted_Result{message_id = message_id})
		_ = acp_send_state(session, "running", "")
	}

	// The completion flag is read because the terminal status alone cannot report a
	// turn the store could not record: the status still names what the model reached,
	// so an unrecorded completion is corrected to a failure below.
	chat.catalog = app_catalog_ref(&session.app)
	observer := acp_observer(session)
	steer := agent.Steer_Context {
		apply      = acp_model_selection_steer,
		apply_data = session,
	}
	turn_completed := agent.chat_run_turn_steered(
		chat,
		session.app.run.connection,
		agent.chat_retry_policy_default(),
		observer,
		&steer,
		&session.app.run.control,
	)
	if acp_is_v2(session.conn) {
		acp_v2_turn_end(session, turn_completed)
		return
	}

	status := chat.terminal_status
	if !turn_completed && status == .Completed { status = .Failed }
	// A cancelled turn is an ordinary answer, not an error. A turn the harness could not
	// finish is reported as the failure it is; the observer has already said why in the
	// transcript.
	switch status {
	case .Completed:
		_ = acp.writer_write_response(&session.conn.writer, work.id, acp.Prompt_Result{stop_reason = acp.stop_reason_name(.End_Turn)})
	case .Cancelled:
		_ = acp.writer_write_response(&session.conn.writer, work.id, acp.Prompt_Result{stop_reason = acp.stop_reason_name(.Cancelled)})
	case .Failed, .None:
		message := agent.chat_session_last_error(chat)
		if message == "" { message = "the turn did not complete" }
		_ = acp.writer_write_error(&session.conn.writer, work.id, acp.ERROR_INTERNAL, message)
	}
}

// acp_v2_turn_end tells a V2 client how a turn ended and that the agent is idle again.
@(private = "file")
acp_v2_turn_end :: proc(session: ^ACP_Session, turn_completed: bool) {
	chat := &session.app.setup.session
	status := chat.terminal_status
	if !turn_completed && status == .Completed { status = .Failed }
	switch status {
	case .Completed:
		_ = acp_send_state(session, "idle", acp.stop_reason_name(.End_Turn))
	case .Cancelled:
		_ = acp_send_state(session, "idle", acp.stop_reason_name(.Cancelled))
	case .Failed, .None:
		message := agent.chat_session_last_error(chat)
		if message == "" { message = "the turn did not complete" }
		message_id := acp_notice_message_id(session)
		_ = acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, message, message_id)
		// A failed turn is not a refusal: the transcript carries the reason, and the
		// state only says the agent is idle again.
		_ = acp_send_state(session, "idle", "")
	}
}

// acp_report_turn runs a turn for the oldest message a background subagent sent while no
// request ran, and reports whether it ran one. The turn counts as work, so a cancel or a
// shutdown stops it the way it stops a prompt's turn.
@(private = "file", require_results)
acp_report_turn :: proc(session: ^ACP_Session) -> bool {
	chat := &session.app.setup.session
	observer := acp_observer(session)
	accepted, had_message := agent.chat_session_accept_agent_message(chat, observer)
	if !had_message { return false }
	if accepted != .Accepted {
		_ = acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, agent.chat_session_last_error(chat), acp_notice_message_id(session))
		return false
	}
	acp_queue_add(session)
	defer acp_queue_remove(session)
	defer agent.turn_control_clear(&session.app.run.control)
	acp_clear_active_message_id(session)
	_ = acp_send_state(session, "running", "")
	chat.catalog = app_catalog_ref(&session.app)
	steer := agent.Steer_Context {
		apply      = acp_model_selection_steer,
		apply_data = session,
	}
	turn_completed := agent.chat_run_turn_steered(
		chat,
		session.app.run.connection,
		agent.chat_retry_policy_default(),
		observer,
		&steer,
		&session.app.run.control,
	)
	acp_v2_turn_end(session, turn_completed)
	return true
}

@(require_results)
acp_models_state :: proc(session: ^ACP_Session) -> (acp.Models_State, bool) {
	if len(session.app.setup.catalog.models) == 0 { return {}, true }
	result: acp.Models_State
	result.current_model_id = session.app.setup.model_id
	available, available_error := make([]acp.Model_Info, len(session.app.setup.catalog.models), context.temp_allocator)
	if available_error != nil { return {}, false }
	for model, index in session.app.setup.catalog.models {
		name := model.id
		if model.display_name_present && model.display_name != "" { name = model.display_name }
		available[index] = acp.Model_Info {
			model_id = model.id,
			name     = name,
		}
	}
	result.available_models = available
	return result, true
}

@(require_results)
acp_model_config_values :: proc(session: ^ACP_Session) -> ([]acp.Config_Value, bool) {
	values, values_error := make([]acp.Config_Value, len(session.app.setup.catalog.models), context.temp_allocator)
	if values_error != nil { return nil, false }
	for model, index in session.app.setup.catalog.models {
		name := model.id
		if model.display_name_present && model.display_name != "" { name = model.display_name }
		values[index] = acp.Config_Value {
			value = model.id,
			name  = name,
		}
	}
	return values, true
}

// acp_effort_config_values names the thinking levels the open session's model states,
// verbatim. An empty result means the model states none, and no effort option is
// advertised for it.
@(require_results)
acp_effort_config_values :: proc(session: ^ACP_Session) -> ([]acp.Config_Value, bool) {
	levels := session.app.setup.session.effort_levels[:]
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
acp_model_config_options_v1 :: proc(session: ^ACP_Session) -> ([]acp.V1_Config_Option, bool) {
	model_count := 0
	if len(session.app.setup.catalog.models) > 0 { model_count = 1 }
	effort_count := 0
	if len(session.app.setup.session.effort_levels) > 0 { effort_count = 1 }
	options, options_error := make([]acp.V1_Config_Option, model_count + effort_count, context.temp_allocator)
	if options_error != nil { return nil, false }
	index := 0
	if model_count == 1 {
		values, values_ok := acp_model_config_values(session)
		if !values_ok { return nil, false }
		options[index] = acp.V1_Config_Option {
			id            = "model",
			name          = "Model",
			category      = "model",
			type          = "select",
			current_value = session.app.setup.model_id,
			options       = values,
		}
		index += 1
	}
	if effort_count == 1 {
		levels, levels_ok := acp_effort_config_values(session)
		if !levels_ok { return nil, false }
		options[index] = acp.V1_Config_Option {
			id            = "effort",
			name          = "Effort",
			category      = "thought_level",
			type          = "select",
			current_value = session.app.setup.session.effort,
			options       = levels,
		}
	}
	return options, true
}

@(require_results)
acp_model_config_options_v2 :: proc(session: ^ACP_Session) -> ([]acp.V2_Config_Option, bool) {
	model_count := 0
	if len(session.app.setup.catalog.models) > 0 { model_count = 1 }
	effort_count := 0
	if len(session.app.setup.session.effort_levels) > 0 { effort_count = 1 }
	options, options_error := make([]acp.V2_Config_Option, model_count + effort_count, context.temp_allocator)
	if options_error != nil { return nil, false }
	index := 0
	if model_count == 1 {
		values, values_ok := acp_model_config_values(session)
		if !values_ok { return nil, false }
		options[index] = acp.V2_Config_Option {
			config_id     = "model",
			name          = "Model",
			category      = "model",
			type          = "select",
			current_value = session.app.setup.model_id,
			options       = values,
		}
		index += 1
	}
	if effort_count == 1 {
		levels, levels_ok := acp_effort_config_values(session)
		if !levels_ok { return nil, false }
		options[index] = acp.V2_Config_Option {
			config_id     = "effort",
			name          = "Effort",
			category      = "thought_level",
			type          = "select",
			current_value = session.app.setup.session.effort,
			options       = levels,
		}
	}
	return options, true
}

// acp_notify sends one session/update notification carrying update. Every streamed
// frame is built here, so the session id and the notification name are stated once.
@(require_results)
acp_notify :: proc(session: ^ACP_Session, update: $T) -> bool {
	params := acp.Session_Notification(T) {
		session_id = acp_session_id(session),
		update     = update,
	}
	return acp.writer_write_notification(&session.conn.writer, acp.NOTIFICATION_SESSION_UPDATE, params)
}

@(require_results)
acp_send_session_info :: proc(session: ^ACP_Session, title: string) -> bool {
	return acp_notify(session, acp.Session_Info_Update{session_update = acp.UPDATE_SESSION_INFO, title = title})
}

// --- streaming what happens --------------------------------------------------

// acp_send_message writes one streamed message fragment. Chunks that share an id are one
// message in the client, which is what keeps a notice from reading as part of the answer.
@(require_results)
acp_send_user_message :: proc(session: ^ACP_Session, message_id, text: string) -> bool {
	if !acp_is_v2(session.conn) { return false }
	content, content_error := make([]acp.Text_Content, 1, context.temp_allocator)
	if content_error != nil { return false }
	content[0] = {
		type = acp.CONTENT_TEXT,
		text = text,
	}
	return acp_notify(session, acp.Message_Update{session_update = acp.UPDATE_USER_MESSAGE, message_id = message_id, content = content})
}

@(require_results)
acp_send_state :: proc(session: ^ACP_Session, state, stop_reason: string) -> bool {
	if !acp_is_v2(session.conn) { return false }
	return acp_notify(session, acp.State_Update{session_update = acp.UPDATE_STATE, state = state, stop_reason = stop_reason})
}

@(require_results)
acp_send_message_full :: proc(session: ^ACP_Session, kind, message_id, text: string) -> bool {
	if !acp_is_v2(session.conn) { return acp_send_message(session, kind, text, message_id) }
	content, content_error := make([]acp.Text_Content, 1, context.temp_allocator)
	if content_error != nil { return false }
	content[0] = {
		type = acp.CONTENT_TEXT,
		text = text,
	}
	return acp_notify(session, acp.Message_Update{session_update = kind, message_id = message_id, content = content})
}

@(require_results)
acp_send_message :: proc(session: ^ACP_Session, kind: string, text, message_id: string) -> bool {
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
acp_send_tool_call :: proc(session: ^ACP_Session, call_id, name, arguments: string, status: acp.Tool_Status, output: string) -> bool {
	// The arguments are parsed for the client's benefit and released after the frame is
	// written, not when this block ends: the value the update carries must outlive it.
	raw, parse_err := json.parse_string(arguments, .JSON, true, context.temp_allocator)
	defer if parse_err == nil { json.destroy_value(raw, context.temp_allocator) }
	content: []acp.Tool_Call_Content
	if output != "" {
		made, content_error := make([]acp.Tool_Call_Content, 1, context.temp_allocator)
		if content_error != nil { return false }
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
				kind = acp.tool_kind_name(acp_tool_kind(&session.app.setup.session, name)),
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
			kind = acp.tool_kind_name(acp_tool_kind(&session.app.setup.session, name)),
			status = acp.tool_status_name(status),
			content = content,
			raw_input = raw if parse_err == nil else nil,
		},
	)
}

// acp_send_tool_result settles a call that was already announced, by its id.
@(require_results)
acp_send_tool_result :: proc(session: ^ACP_Session, call_id: string, status: acp.Tool_Status, output: string) -> bool {
	content, content_error := make([]acp.Tool_Call_Content, 1, context.temp_allocator)
	if content_error != nil { return false }
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
acp_send_usage :: proc(session: ^ACP_Session, used, size: i64) -> bool {
	return acp_notify(session, acp.Usage_Update{session_update = acp.UPDATE_USAGE, used = used, size = size})
}

// acp_session_id is the id a session update names. The worker owns the session, so the
// string is borrowed for the write and no longer.
acp_session_id :: proc(session: ^ACP_Session) -> string {
	return agent.chat_session_text(&session.app.setup.session)
}

acp_user_message_id :: proc(session: ^ACP_Session) -> string {
	if turn := session.app.setup.session.turn; turn != 0 { return fmt.tprintf("msg-user-%d-1", i64(turn)) }
	return acp_next_message_id(session)
}

acp_assistant_message_id :: proc(session: ^ACP_Session) -> string {
	turn := session.app.setup.session.turn
	request := session.app.setup.session.request
	if turn != 0 && request != 0 {
		return fmt.tprintf("msg-assistant-%d-%d", i64(turn), i64(request))
	}
	if turn != 0 { return fmt.tprintf("msg-assistant-%d", i64(turn)) }
	return acp_next_message_id(session)
}

acp_notice_message_id :: proc(session: ^ACP_Session) -> string {
	turn := session.app.setup.session.turn
	request := session.app.setup.session.request
	if turn != 0 && request != 0 {
		return fmt.tprintf("msg-notice-%d-%d", i64(turn), i64(request))
	}
	return acp_next_message_id(session)
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
// that fails is recorded as a runtime message and leaves the previous id in place, so the stream
// continues under the id it already had rather than under none.
acp_set_active_message_id :: proc(session: ^ACP_Session, message_id: string) {
	owned, clone_error := strings.clone(message_id, session.conn.alloc)
	if clone_error != nil {
		agent.chat_runtime_message(&session.app.setup.session, .Warning, "the answer's message id could not be copied; the stream keeps its previous id")
		return
	}
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

// --- the observer ------------------------------------------------------------

acp_observer :: proc(session: ^ACP_Session) -> agent.Chat_Observer {
	return {
		user_data = session,
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
	session := cast(^ACP_Session)user_data
	if acp_is_v2(session.conn) {
		acp_set_active_message_id(session, acp_assistant_message_id(session))
	} else {
		_ = acp_next_message_id(session)
	}
}

acp_obs_assistant_text :: proc(user_data: rawptr, text: string) {
	session := cast(^ACP_Session)user_data
	_ = acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, text, acp_current_message_id(session))
}

// acp_obs_message reports the harness's own lines. They are the only place a client
// learns that a turn is retrying, that a tool call was repaired, or that a turn failed:
// the transcript is the protocol's only channel, so they are sent as a message of their
// own rather than folded into the model's answer.
acp_obs_message :: proc(user_data: rawptr, kind: agent.Chat_Message_Kind, text: string) {
	session := cast(^ACP_Session)user_data
	message_id := acp_next_message_id(session)
	if acp_is_v2(session.conn) { message_id = acp_notice_message_id(session) }
	_ = acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, text, message_id)
}

acp_obs_tool_call :: proc(user_data: rawptr, event: agent.Chat_Tool_Event) {
	session := cast(^ACP_Session)user_data
	_ = acp_send_tool_call(session, event.call_id, event.name, event.arguments, .Pending, "")
}

acp_obs_tool_result :: proc(user_data: rawptr, name: string, result: ^agent.Tool_Result) {
	session := cast(^ACP_Session)user_data
	text := tool_display_preview(result.content)
	if text == "" { text = tool_display_summary(result) }
	_ = acp_send_tool_result(session, result.call_id, acp_tool_status(session, result.outcome), text)
}

acp_obs_request_finished :: proc(user_data: rawptr) {
	session := cast(^ACP_Session)user_data
	chat := &session.app.setup.session
	size := i64(chat.capacity.window)
	if size <= 0 { return }
	used := i64(chat.last_estimate)
	if measured, reported := chat.last_input_measured.?; reported { used = measured }
	_ = acp_send_usage(session, used, size)
}

acp_obs_retry_scheduled :: proc(user_data: rawptr, event: agent.Chat_Retry_Event) {
	session := cast(^ACP_Session)user_data
	message_id := acp_next_message_id(session)
	if acp_is_v2(session.conn) { message_id = acp_notice_message_id(session) }
	_ = acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, retry_display_text(event), message_id)
}

// --- replaying a loaded conversation -----------------------------------------

// acp_replay_session streams the conversation a client just loaded. Every entry the
// harness keeps becomes the update that carries it: the user's own lines, the model's
// answers, and each stored call with the result it produced. A client that asked to load
// a session shows the conversation it asked for rather than an empty one.
acp_replay_session :: proc(session: ^ACP_Session) {
	chat := &session.app.setup.session
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		_ = acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, "the session's history could not be allocated", acp_next_message_id(session))
		return
	}
	defer virtual.arena_destroy(&arena)
	replayed, load_err := agent.projection_load(chat.store, chat.session, chat.head, virtual.arena_allocator(&arena))
	if load_err != nil {
		_ = acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, "the session's history could not be read", acp_next_message_id(session))
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
				_ = acp_send_message_full(session, message_kind, message_id, payload.text)
			} else {
				_ = acp_send_message(session, kind, payload.text, message_id)
			}
		case agent.Projected_Assistant:
			message_id := acp_replay_assistant_message_id(item)
			if acp_is_v2(session.conn) {
				_ = acp_send_message_full(session, acp.UPDATE_AGENT_MESSAGE, message_id, payload.text)
			} else {
				_ = acp_send_message(session, acp.UPDATE_AGENT_MESSAGE_CHUNK, payload.text, message_id)
			}
		case agent.Projected_Call:
			calls[payload.call] = payload
		case agent.Projected_Result:
			call, known := calls[payload.call]
			if !known { continue }
			text := tool_display_preview(payload.content)
			if text == "" { text = journal.TOOL_OUTCOME_NAMES[payload.outcome] }
			_ = acp_send_tool_call(session, call.provider_id, call.name, call.proposed, acp_tool_status(session, payload.outcome), text)
		}
	}
}

// --- presenting a call -------------------------------------------------------

// acp_tool_kind tells a client what a call does, so it can render the card the call
// deserves. The harness's own hints answer for a definition that states them; what is
// left is the tools this harness ships, named here, and Other is the honest answer for
// anything else, including a tool an MCP session contributed without saying.
acp_tool_kind :: proc(chat: ^agent.Chat_Session, name: string) -> acp.Tool_Kind {
	if definition, present := agent.tool_registry_find(&chat.tools, name); present {
		if definition.hints.read_only == .Yes { return .Read }
		if definition.hints.destructive == .Yes { return .Edit }
	}
	switch name {
	case agent.TOOL_SHELL_NAME, agent.TOOL_CODEMODE_NAME:
		return .Execute
	case agent.TOOL_READ_NAME, agent.TOOL_LIST_SKILLS_NAME, agent.TOOL_LOAD_SKILL_NAME:
		return .Read
	case agent.TOOL_WRITE_NAME, agent.TOOL_PATCH_NAME:
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
