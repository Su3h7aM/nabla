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

// The ACP agent front-end: one process, one session, one prompt turn at a time,
// speaking the Agent Client Protocol on the streams it was given. Two threads: the
// reader answers what it can alone and hands session work to the worker, which owns the
// session and writes everything a turn produces. The split exists because a client
// cancels a turn by sending another message on the same stream.

// ACP_WORK_CAPACITY bounds requests waiting for the worker. The reader admits one
// session request at a time, so the queue holds the request being served and, briefly,
// nothing else.
ACP_WORK_CAPACITY :: 4

// ACP_READ_BYTES is how much of the input stream one read takes. It sizes a syscall,
// not a frame: the decoder keeps reading until the frame ends.
ACP_READ_BYTES :: 16 * 1024

Acp_Work_Kind :: enum {
	// Open_Session opens the session a client asked for: a new one in its working
	// directory, or a stored one it names.
	Open_Session,
	// Prompt runs one turn on the open session.
	Prompt,
	// Set_Model applies Buzz's model-selection extension on the worker thread.
	Set_Model,
	// Set_Config_Option applies the stable ACP model configuration method.
	Set_Config_Option,
	// List_Sessions answers the v2 session/list method.
	List_Sessions,
	// Close_Session releases the active v2 session.
	Close_Session,
}

// Acp_Work is one request the reader handed to the worker. Every string is owned by the
// server's allocator and released by acp_work_destroy.
Acp_Work :: struct {
	kind:               Acp_Work_Kind,
	id:                 acp.Jsonrpc_Id, // the request to answer
	// text is the prompt of a Prompt; workspace is where a new session runs;
	// session_ref names a stored session for an Open_Session.
	text:               string,
	workspace:          string,
	session_ref:        string,
	model_id:           string,
	config_id:          string,
	config_value:       string,
	list_cwd:           string,
	list_cursor:        string,
	mcp_servers:        [dynamic]agent.MCP_Server_Config,
	system_prompt:      string,
	session_title:      string,
	replay:             bool,
	// start is the session an Open_Session opens. Its id aliases session_ref.
	start:              Session_Start,
	// session_generation is the open session the reader observed. A queued request
	// must not mutate a session that has since been replaced or closed.
	session_generation: u64,
}

Acp_Work_Chan :: chan.Chan(Acp_Work)

// Acp_Server is the whole front-end: the harness runtime, the writer, the worker, and
// the little of the protocol's own state that is not the harness's.
Acp_Wire_Profile :: enum {
	V1,
	V2,
}

@(require_results)
acp_is_v2 :: proc(server: ^Acp_Server) -> bool {
	return server.profile == .V2
}

@(require_results)
acp_server_has_work :: proc(server: ^Acp_Server) -> bool {
	if sync.atomic_load(&server.busy) { return true }
	sync.mutex_lock(&server.queue_mu)
	pending := server.pending_work > 0
	sync.mutex_unlock(&server.queue_mu)
	return pending
}

acp_queue_add :: proc(server: ^Acp_Server) {
	sync.mutex_lock(&server.queue_mu)
	server.pending_work += 1
	sync.atomic_store(&server.busy, true)
	sync.mutex_unlock(&server.queue_mu)
}

acp_queue_remove :: proc(server: ^Acp_Server) {
	sync.mutex_lock(&server.queue_mu)
	server.pending_work -= 1
	if server.pending_work <= 0 {
		server.pending_work = 0
		sync.atomic_store(&server.busy, false)
	}
	sync.mutex_unlock(&server.queue_mu)
}

acp_capture_session_generation :: proc(server: ^Acp_Server) -> u64 {
	sync.mutex_lock(&server.mu)
	generation := server.session_generation
	sync.mutex_unlock(&server.mu)
	return generation
}

@(require_results)
acp_work_session_valid :: proc(server: ^Acp_Server, work: Acp_Work) -> bool {
	if work.kind == .List_Sessions { return true }
	sync.mutex_lock(&server.mu)
	valid := work.session_generation == server.session_generation
	if valid && server.closing && work.kind != .Close_Session { valid = false }
	if valid {
		switch work.kind {
		case .Open_Session:
		case .Prompt, .Set_Model, .Set_Config_Option:
			valid = server.session_id != ""
		case .Close_Session:
			valid = server.session_id != "" && server.session_id == work.session_ref
		case .List_Sessions:
		}
	}
	sync.mutex_unlock(&server.mu)
	return valid
}

acp_mark_session_closing :: proc(server: ^Acp_Server) {
	sync.mutex_lock(&server.mu)
	server.closing = true
	sync.mutex_unlock(&server.mu)
}

acp_unmark_session_closing :: proc(server: ^Acp_Server, generation: u64) {
	sync.mutex_lock(&server.mu)
	if server.session_generation == generation { server.closing = false }
	sync.mutex_unlock(&server.mu)
}

acp_invalidate_published_session :: proc(server: ^Acp_Server) {
	sync.mutex_lock(&server.mu)
	server.session_generation += 1
	server.closing = false
	delete(server.session_id, server.alloc)
	server.session_id = ""
	delete(server.session_title, server.alloc)
	server.session_title = ""
	sync.mutex_unlock(&server.mu)
	delete(server.active_message_id, server.alloc)
	server.active_message_id = ""
}

Acp_Server :: struct {
	app:                App,
	alloc:              mem.Allocator,
	base_mcp_servers:   []agent.MCP_Server_Config, // borrowed from the launch config
	mcp_servers_owned:  [dynamic]agent.MCP_Server_Config, // owned active list when a client supplied servers
	writer:             acp.Writer,
	work:               Acp_Work_Chan,
	worker:             ^thread.Thread,
	// queue_mu guards pending_work and the busy flag. v2 can have a short bounded
	// queue, so the count and flag must change as one state transition.
	queue_mu:           sync.Mutex,
	busy:               bool, // atomic mirror, read by teardown and tests
	pending_work:       int,
	// initialized is set once initialize has been answered. Only the reader writes it.
	initialized:        bool,
	// protocol_version is the number agreed with the client. profile is the
	// corresponding wire surface.
	protocol_version:   int,
	profile:            Acp_Wire_Profile,
	// mu guards session_id, which the reader matches a cancellation against and the
	// worker replaces after opening a session.
	mu:                 sync.Mutex,
	session_id:         string, // owned
	session_title:      string, // owned; the client-supplied title for the open session
	session_generation: u64, // changes whenever the open session is replaced or closed
	closing:            bool, // a close request has been admitted and invalidates queued work
	// message_seq numbers process-local fallback messages. The v2 live assistant id
	// is derived from the durable turn and request instead, so replay can reproduce it.
	message_seq:        u64,
	active_message_id:  string, // owned by server.alloc; the v2 answer being streamed
}

// --- lifetime ----------------------------------------------------------------

// acp_work_destroy releases the strings one queued request owns.
acp_work_destroy :: proc(work: ^Acp_Work, allocator: mem.Allocator) {
	switch id in work.id {
	case string:
		delete(id, allocator)
	case i64, f64, acp.Jsonrpc_Null:
	}
	delete(work.text, allocator)
	delete(work.workspace, allocator)
	delete(work.session_ref, allocator)
	delete(work.model_id, allocator)
	delete(work.config_id, allocator)
	delete(work.config_value, allocator)
	delete(work.list_cwd, allocator)
	delete(work.list_cursor, allocator)
	agent.MCP_Server_Configs_Destroy(&work.mcp_servers, allocator)
	delete(work.system_prompt, allocator)
	delete(work.session_title, allocator)
	work^ = {}
}

// acp_work_id copies the request id a response will carry. Only the string form owns
// memory; a numeric id is a value. A copy failure reports false so the request is
// refused rather than answered under a wrong id.
@(require_results)
acp_work_id :: proc(id: acp.Jsonrpc_Id, allocator: mem.Allocator) -> (acp.Jsonrpc_Id, bool) {
	switch value in id {
	case string:
		cloned, clone_error := strings.clone(value, allocator)
		if clone_error != nil { return "", false }
		return cloned, true
	case i64, f64, acp.Jsonrpc_Null:
		return id, true
	}
	return id, true
}

// acp_server_destroy releases everything the server owns. It must run after the worker
// has retired: a worker that ignored its stop still borrows the session, the workspace,
// and the tool backends, and those are not handed back while it can reach them.
acp_server_destroy :: proc(server: ^Acp_Server) {
	// A turn still running is stopped before the worker is joined, so it settles as
	// cancelled and the record says the session was interrupted.
	if acp_server_has_work(server) { agent.turn_control_stop(&server.app.run.control) }
	if server.work != {} {
		chan.close(&server.work)
		agent.owner_wake_signal()
	}
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
	delete(server.session_title, server.alloc)
	server.session_title = ""
	sync.mutex_unlock(&server.mu)
	delete(server.active_message_id, server.alloc)
	server.active_message_id = ""
	snapshot_destroy(&server.app)
	if server.app.setup.workers_abandoned || agent.chat_session_workers_outstanding(&server.app.setup.session) {
		agent.log_emit(agent.Log_Record{level = .Warning, category = .Runtime, event = "runtime.workers_outstanding"})
		return
	}
	run_setup_destroy(&server.app.setup)
	agent.MCP_Server_Configs_Destroy(&server.mcp_servers_owned, server.alloc)
}

// --- the worker --------------------------------------------------------------

// acp_worker runs the requests the reader hands over and owns the session while it does.
// While a V2 client has nothing queued, a background subagent's report starts a turn of its
// own; a V1 client cannot receive a turn it did not ask for, so its reports wait in the
// inbox for the next prompt's turn. It leaves when the queue is closed and drained.
acp_worker :: proc(thread_handle: ^thread.Thread) {
	server := cast(^Acp_Server)thread_handle.data
	// A thread started without init_context gets the default context, so the run's
	// logger and the server's allocator, which the work it destroys was allocated
	// with, are installed here.
	context.logger = agent.log_logger(&server.app.setup.log_binding)
	context.allocator = server.alloc
	for {
		seen := agent.owner_wake_seen()
		work, ok := chan.try_recv(server.work)
		if !ok {
			// A closed queue is shutdown, which starts no report turn.
			if chan.is_closed(server.work) { break }
			if acp_is_v2(server) && server.app.setup.store != nil {
				if acp_report_turn(server) {
					free_all(context.temp_allocator)
					continue
				}
				// Reports arrive through the owner wake, which new requests signal too.
				if agent.chat_agents_pending(&server.app.setup.session) {
					agent.owner_wake_wait(seen, nil)
					continue
				}
			}
			work, ok = chan.recv(server.work)
			if !ok { break }
		}
		acp_run_work(server, work)
		acp_work_destroy(&work, server.alloc)
		// Temp scratch belongs to one request: the worker is long-lived, so its pool is
		// recycled here rather than left to grow with the conversation.
		free_all(context.temp_allocator)
	}
}

acp_run_work :: proc(server: ^Acp_Server, work: Acp_Work) {
	if !acp_work_session_valid(server, work) {
		// A write error latches the writer, which the run reports as its failure, so
		// every reply's own result is not acted on here or below.
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INVALID_PARAMS, "the session changed before the request could run")
	} else {
		switch work.kind {
		case .Open_Session:
			acp_work_open_session(server, work)
		case .Prompt:
			acp_work_prompt(server, work)
		case .Set_Model:
			acp_work_set_model(server, work)
		case .Set_Config_Option:
			acp_work_set_config_option(server, work)
		case .List_Sessions:
			acp_work_list_sessions(server, work)
		case .Close_Session:
			acp_work_close_session(server, work)
		}
	}
	// The request is answered, so the next one may be admitted. The cancellation belongs
	// to the turn that just ended; a client that cancels a finished turn is ignored.
	agent.turn_control_clear(&server.app.run.control)
	acp_queue_remove(server)
	// The worker owns the journal, so the diagnostics commit waits for no reply.
	run_log_flush(&server.app.setup)
}

// --- opening a session -------------------------------------------------------

acp_work_open_session :: proc(server: ^Acp_Server, work: Acp_Work) {
	// Invalidate the published reference before replacing the harness session. If opening
	// the replacement fails, requests that were queued against the old session are then
	// rejected instead of running against a session the client no longer owns.
	acp_invalidate_published_session(server)

	message, opened := acp_session_open(server, work.workspace, work.start)
	if !opened {
		if message == "" {
			_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the session could not be opened")
		} else {
			defer delete(message, server.app.setup.alloc)
			_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INVALID_PARAMS, message)
		}
		return
	}
	defer delete(message, server.app.setup.alloc)
	acp_session_select_model(server)
	if !agent.chat_session_set_client_instructions(&server.app.setup.session, work.system_prompt) {
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the client system prompt could not be stored")
		return
	}
	if !acp_server_apply_mcp(server, work.mcp_servers) {
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the session MCP configuration could not be installed")
		return
	}

	// Allocate every value that can fail before publishing the new session id. A
	// response must not advertise a session that failed partway through setup.
	v1_options: []acp.V1_Config_Option
	v1_options_ok: bool
	v2_options: []acp.V2_Config_Option
	v2_options_ok: bool
	if work.start.kind == .Resume_Id {
		if acp_is_v2(server) {
			v2_options, v2_options_ok = acp_model_config_options_v2(server)
			if !v2_options_ok {
				_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the model configuration could not be allocated")
				return
			}
		}
	} else if acp_is_v2(server) {
		v2_options, v2_options_ok = acp_model_config_options_v2(server)
		if !v2_options_ok {
			_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the model configuration could not be allocated")
			return
		}
	} else {
		v1_options, v1_options_ok = acp_model_config_options_v1(server)
		if !v1_options_ok {
			_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the model configuration could not be allocated")
			return
		}
	}
	models: acp.Models_State
	if work.start.kind != .Resume_Id && !acp_is_v2(server) {
		models_ok: bool
		models, models_ok = acp_models_state(server)
		if !models_ok {
			_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the model catalog could not be allocated")
			return
		}
	}

	session_id := agent.chat_session_text(&server.app.setup.session)
	owned_session_id, session_id_error := strings.clone(session_id, server.alloc)
	if session_id_error != nil {
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the session reference could not be allocated")
		return
	}
	owned_title, title_error := strings.clone(work.session_title, server.alloc)
	if title_error != nil {
		delete(owned_session_id, server.alloc)
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the session title could not be allocated")
		return
	}
	sync.mutex_lock(&server.mu)
	delete(server.session_id, server.alloc)
	server.session_id = owned_session_id
	delete(server.session_title, server.alloc)
	server.session_title = owned_title
	sync.mutex_unlock(&server.mu)

	if warning := app_tools_refresh(&server.app); warning != "" {
		_ = acp_send_message(server, acp.UPDATE_AGENT_MESSAGE_CHUNK, warning, acp_next_message_id(server))
	}
	if work.session_title != "" { _ = acp_send_session_info(server, work.session_title) }
	if work.replay {
		acp_replay_session(server)
	}
	if work.start.kind == .Resume_Id {
		if acp_is_v2(server) {
			_ = acp.writer_write_response(&server.writer, work.id, acp.Session_Resume_Result{config_options = v2_options})
		} else {
			_ = acp.writer_write_response(&server.writer, work.id, acp.Empty_Result{})
		}
	} else if acp_is_v2(server) {
		_ = acp.writer_write_response(&server.writer, work.id, acp.V2_Session_New_Result{session_id = session_id, config_options = v2_options})
	} else {
		_ = acp.writer_write_response(&server.writer, work.id, acp.Session_New_Result{session_id = session_id, config_options = v1_options, models = models})
	}
}

acp_restore_base_runtime :: proc(server: ^Acp_Server) {
	// A failed restore leaves the zero runtime: no MCP servers. The caller reports the
	// failure that led here either way, so the restore failure is recorded in the log
	// rather than answered twice.
	restored, restore_ok := mcp_runtime_make(server.base_mcp_servers, server.app.setup.alloc)
	server.app.setup.mcp = restored
	if !restore_ok {
		agent.log_emit(agent.Log_Record{level = .Error, category = .Runtime, event = "acp.mcp_restore_failed"})
	}
}

@(require_results)
acp_server_apply_mcp :: proc(server: ^Acp_Server, requested: [dynamic]agent.MCP_Server_Config) -> bool {
	setup := &server.app.setup
	// The old runtime owns processes and bindings that the newly opened session no
	// longer borrows. Stop it before changing the configuration list.
	mcp_runtime_destroy(&setup.mcp)
	agent.MCP_Server_Configs_Destroy(&server.mcp_servers_owned, server.alloc)
	setup.mcp_servers = server.base_mcp_servers
	if len(requested) == 0 {
		setup.mcp_servers = server.base_mcp_servers
		built, ok := mcp_runtime_make(setup.mcp_servers, setup.alloc)
		setup.mcp = built
		return ok
	}
	combined, clone_error := agent.MCP_Server_Configs_Clone(server.base_mcp_servers, server.alloc)
	if clone_error != .None {
		acp_restore_base_runtime(server)
		return false
	}
	failed := true
	defer if failed { agent.MCP_Server_Configs_Destroy(&combined, server.alloc) }
	for existing in combined {
		for wanted in requested {
			if existing.id == wanted.id {
				acp_restore_base_runtime(server)
				return false
			}
		}
	}
	for server_config, index in requested {
		appended := append(&combined, server_config)
		if appended != 1 {
			if appended == 0 {
				agent.MCP_Server_Config_Destroy(&requested[index], server.alloc)
				requested[index] = {}
			}
			acp_restore_base_runtime(server)
			return false
		}
		requested[index] = {}
	}
	built, runtime_ok := mcp_runtime_make(combined[:], setup.alloc)
	if !runtime_ok {
		acp_restore_base_runtime(server)
		return false
	}
	server.mcp_servers_owned = combined
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

// acp_session_open makes one session the running one: the client's working directory for
// a new conversation, the stored session for a loaded one.
//
// The message of a refusal is owned by the setup's allocator.
@(require_results)
acp_session_open :: proc(server: ^Acp_Server, workspace: string, start: Session_Start) -> (message: string, ok: bool) {
	app := &server.app
	// Loading the session this process already runs is not a switch: it is the same
	// conversation, and the harness would refuse to claim it twice.
	if start.kind == .Resume_Id && app.setup.store != nil && agent.chat_session_text(&app.setup.session) == start.id { return "", true }
	opened, open_message, opened_ok := session_open(&app.setup, start, workspace)
	if !opened_ok { return open_message, false }
	report_recovery(opened.recovery)
	if !session_install(&app.setup, &opened) {
		return acp_open_message("the tool registry could not be allocated", app.setup.alloc), false
	}
	return "", true
}

// acp_session_select_model gives a freshly opened session a model: the one its own record
// names, otherwise the one this process chose at startup. A stale record falls back to the
// process's selection, and a session with no selection at all still opens, because the
// prompt is what refuses it.
acp_session_select_model :: proc(server: ^Acp_Server) {
	app := &server.app
	if app.setup.resumed_provider != "" && app.setup.resumed_model != "" {
		if apply_selection(app, app.setup.resumed_provider, app.setup.resumed_model, "") { return }
	}
	if app.setup.provider_id != "" && app.setup.model_id != "" {
		if apply_selection(app, app.setup.provider_id, app.setup.model_id, "") { return }
	}
	if app.setup.model_id == "" && !acp_select_first_model(server) {
		agent.log_emit(agent.Log_Record{level = .Warning, category = .Runtime, event = "acp.session_without_model"})
	}
}

// acp_select_startup_model chooses the model this process runs with: the user's own last
// choice, otherwise the first model the configuration can actually serve. The fallback
// exists because an editor session is often the first thing a person runs, and it must
// not depend on having opened the interactive harness once.
@(require_results)
acp_select_startup_model :: proc(server: ^Acp_Server) -> bool {
	app := &server.app
	selection, found, load_err := selection_latest(app.setup.store, app.run.alloc)
	defer selection_destroy(&selection, app.run.alloc)
	if load_err == nil && found {
		if apply_selection(app, selection.provider, selection.model, selection.effort) { return true }
	}
	return acp_select_first_model(server)
}

// acp_select_first_model picks the first configured provider that can serve a request and
// its first model, in catalog order, so the choice is the same on every launch. Nothing is
// persisted: a model chosen for an editor conversation is not the user's own last choice.
// Every candidate is named before any of them is tried, because applying a selection takes
// the catalog lock and a publication releases the catalog the names were read from.
@(require_results)
acp_select_first_model :: proc(server: ^Acp_Server) -> bool {
	app := &server.app
	candidates, candidates_ok := acp_servable_models(app, app.run.alloc)
	if !candidates_ok { return false }
	defer acp_candidates_destroy(candidates, app.run.alloc)
	for candidate in candidates {
		if apply_selection(app, candidate.provider_id, candidate.model_id, "") { return true }
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

@(require_results)
acp_apply_model_id :: proc(server: ^Acp_Server, model_id: string) -> bool {
	app := &server.app
	for provider in app.setup.catalog.providers {
		if _, found := agent.catalog_find_model(&app.setup.catalog, provider.id, model_id); !found { continue }
		if apply_selection(app, provider.id, model_id, "") { return true }
	}
	return false
}

acp_work_set_model :: proc(server: ^Acp_Server, work: Acp_Work) {
	if acp_apply_model_id(server, work.model_id) {
		_ = acp.writer_write_response(&server.writer, work.id, acp.Session_Set_Model_Result{session_id = acp_session_id(server), model_id = work.model_id})
		return
	}
	_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INVALID_PARAMS, fmt.tprintf("the model %q is not available", work.model_id))
}

acp_work_set_config_option :: proc(server: ^Acp_Server, work: Acp_Work) {
	applied := false
	if work.config_id == "model" {
		applied = acp_apply_model_id(server, work.config_value)
	} else if work.config_id == "effort" {
		applied = agent.chat_session_set_effort(&server.app.setup.session, work.config_value)
	}
	if !applied {
		_ = acp.writer_write_error(
			&server.writer,
			work.id,
			acp.ERROR_INVALID_PARAMS,
			fmt.tprintf("the config option %q cannot be set to %q", work.config_id, work.config_value),
		)
		return
	}
	options, options_ok := acp_model_config_options_v1(server)
	if !options_ok {
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the model configuration could not be allocated")
		return
	}
	if acp_is_v2(server) {
		v2_options, v2_options_ok := acp_model_config_options_v2(server)
		if !v2_options_ok {
			_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the model configuration could not be allocated")
			return
		}
		_ = acp.writer_write_response(&server.writer, work.id, acp.V2_Session_Set_Config_Option_Result{config_options = v2_options})
		return
	}
	_ = acp.writer_write_response(&server.writer, work.id, acp.V1_Session_Set_Config_Option_Result{config_options = options})
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

acp_work_list_sessions :: proc(server: ^Acp_Server, work: Acp_Work) {
	store := server.app.setup.store
	// With no session open, the list is read through a journal of its own.
	opened_store: ^journal.Journal
	// The lookup's store is being abandoned; its close failure changes nothing.
	defer _ = session_store_close(opened_store, server.app.setup.alloc)
	if store == nil {
		open_error: journal.Error
		opened_store, open_error = session_store_open(&server.app.setup)
		if open_error != nil {
			_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the session list could not be opened")
			return
		}
		store = opened_store
	}
	options := journal.Session_Filter {
		workspace = work.list_cwd,
		role      = .Main,
		limit     = ACP_SESSION_LIST_PAGE_SIZE,
	}
	if work.list_cursor != "" {
		cursor, valid := acp_session_cursor_decode(work.list_cursor)
		if !valid {
			_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INVALID_PARAMS, "the session list cursor is invalid")
			return
		}
		options.before = cursor
	}
	sessions, list_error := journal.list_sessions(store, options, server.alloc)
	if list_error != nil {
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the session list could not be read")
		return
	}
	active_id := ""
	sync.mutex_lock(&server.mu)
	if server.app.setup.store != nil && server.session_id == agent.chat_session_text(&server.app.setup.session) {
		active_id = agent.chat_session_text(&server.app.setup.session)
	}
	sync.mutex_unlock(&server.mu)
	active_matches := active_id != "" && (work.list_cwd == "" || server.app.setup.workspace == work.list_cwd)
	active_listed := false
	for listed in sessions {
		buffer: [journal.SESSION_ID_HEX_LENGTH]u8
		if journal.session_id_to_hex(listed.id, buffer[:]) == active_id {
			active_listed = true
			break
		}
	}
	extra := 1 if active_matches && !active_listed else 0
	infos, infos_error := make([]acp.Session_Info, len(sessions) + extra, server.alloc)
	if infos_error != nil {
		journal.session_summaries_destroy(sessions, server.alloc)
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the session list could not be allocated")
		return
	}
	id_buffers, buffers_error := make([][journal.SESSION_ID_HEX_LENGTH]u8, len(sessions), context.temp_allocator)
	if buffers_error != nil {
		delete(infos, server.alloc)
		journal.session_summaries_destroy(sessions, server.alloc)
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, "the session list could not be allocated")
		return
	}
	for listed, index in sessions {
		infos[index] = acp.Session_Info {
			session_id = journal.session_id_to_hex(listed.id, id_buffers[index][:]),
			cwd        = listed.workspace,
			title      = listed.title,
			updated_at = acp_session_timestamp(listed.updated_ms),
		}
	}
	if extra == 1 {
		sync.mutex_lock(&server.mu)
		title := server.session_title
		sync.mutex_unlock(&server.mu)
		infos[len(sessions)] = acp.Session_Info {
			session_id = active_id,
			cwd        = server.app.setup.workspace,
			title      = title,
			updated_at = acp_session_timestamp(time.to_unix_nanoseconds(time.now()) / i64(time.Millisecond)),
		}
	}
	next_cursor := ""
	if len(sessions) == ACP_SESSION_LIST_PAGE_SIZE {
		last := sessions[len(sessions) - 1]
		next_cursor = acp_session_cursor_encode(last.last_seq)
	}
	_ = acp.writer_write_response(&server.writer, work.id, acp.Session_List_Result{sessions = infos, next_cursor = next_cursor})
	delete(infos, server.alloc)
	journal.session_summaries_destroy(sessions, server.alloc)
}

acp_work_close_session :: proc(server: ^Acp_Server, work: Acp_Work) {
	if !acp_closing_session_matches(server, work.session_ref) || server.app.setup.store == nil {
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INVALID_PARAMS, "no session is open for that id")
		return
	}
	acp_invalidate_published_session(server)
	agent.chat_session_destroy(&server.app.setup.session)
	// A release failure is recorded rather than answered: the session is already
	// destroyed, so the close stands either way.
	if release_error := session_store_close(server.app.setup.store, server.app.setup.alloc); release_error != nil {
		agent.log_emit(agent.Log_Record{level = .Error, category = .Runtime, event = "acp.session_release_failed"})
	}
	server.app.setup.store = nil
	mcp_runtime_destroy(&server.app.setup.mcp)
	agent.MCP_Server_Configs_Destroy(&server.mcp_servers_owned, server.alloc)
	server.app.setup.mcp_servers = server.base_mcp_servers
	acp_restore_base_runtime(server)
	sync.mutex_lock(&server.mu)
	delete(server.session_id, server.alloc)
	server.session_id = ""
	delete(server.session_title, server.alloc)
	server.session_title = ""
	sync.mutex_unlock(&server.mu)
	delete(server.active_message_id, server.alloc)
	server.active_message_id = ""
	_ = acp.writer_write_response(&server.writer, work.id, acp.Empty_Result{})
}

acp_work_prompt :: proc(server: ^Acp_Server, work: Acp_Work) {
	chat := &server.app.setup.session
	accepted := agent.chat_session_accept_user(chat, work.text)
	switch accepted {
	case .Accepted:
	case .Storage_Failed:
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INTERNAL, agent.chat_session_last_error(chat))
		return
	case .Busy:
		_ = acp.writer_write_error(&server.writer, work.id, acp.ERROR_INVALID_REQUEST, "the session is already running a turn")
		return
	}
	if acp_is_v2(server) {
		acp_clear_active_message_id(server)
		message_id := acp_user_message_id(server)
		_ = acp_send_user_message(server, message_id, work.text)
		_ = acp.writer_write_response(&server.writer, work.id, acp.Prompt_Accepted_Result{message_id = message_id})
		_ = acp_send_state(server, "running", "")
	}

	// The completion flag is read because the terminal status alone cannot report a
	// turn the store could not record: the status still names what the model reached,
	// so an unrecorded completion is corrected to a failure below.
	chat.catalog = app_catalog_ref(&server.app)
	observer := acp_observer(server)
	turn_completed := agent.chat_run_turn_steered(chat, server.app.run.connection, agent.chat_retry_policy_default(), observer, nil, &server.app.run.control)
	if acp_is_v2(server) {
		acp_v2_turn_end(server, turn_completed)
		return
	}

	status := chat.terminal_status
	if !turn_completed && status == .Completed { status = .Failed }
	// A cancelled turn is an ordinary answer, not an error. A turn the harness could not
	// finish is reported as the failure it is; the observer has already said why in the
	// transcript.
	switch status {
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

// acp_v2_turn_end tells a V2 client how a turn ended and that the agent is idle again.
@(private = "file")
acp_v2_turn_end :: proc(server: ^Acp_Server, turn_completed: bool) {
	chat := &server.app.setup.session
	status := chat.terminal_status
	if !turn_completed && status == .Completed { status = .Failed }
	switch status {
	case .Completed:
		_ = acp_send_state(server, "idle", acp.stop_reason_name(.End_Turn))
	case .Cancelled:
		_ = acp_send_state(server, "idle", acp.stop_reason_name(.Cancelled))
	case .Failed, .None:
		message := agent.chat_session_last_error(chat)
		if message == "" { message = "the turn did not complete" }
		message_id := acp_notice_message_id(server)
		_ = acp_send_message(server, acp.UPDATE_AGENT_MESSAGE_CHUNK, message, message_id)
		// A failed turn is not a refusal: the transcript carries the reason, and the
		// state only says the agent is idle again.
		_ = acp_send_state(server, "idle", "")
	}
}

// acp_report_turn runs a turn for the oldest message a background subagent sent while no
// request ran, and reports whether it ran one. The turn counts as work, so a cancel or a
// shutdown stops it the way it stops a prompt's turn.
@(private = "file", require_results)
acp_report_turn :: proc(server: ^Acp_Server) -> bool {
	chat := &server.app.setup.session
	observer := acp_observer(server)
	accepted, had_message := agent.chat_session_accept_agent_message(chat, observer)
	if !had_message { return false }
	if accepted != .Accepted {
		_ = acp_send_message(server, acp.UPDATE_AGENT_MESSAGE_CHUNK, agent.chat_session_last_error(chat), acp_notice_message_id(server))
		return false
	}
	acp_queue_add(server)
	defer acp_queue_remove(server)
	defer agent.turn_control_clear(&server.app.run.control)
	acp_clear_active_message_id(server)
	_ = acp_send_state(server, "running", "")
	chat.catalog = app_catalog_ref(&server.app)
	turn_completed := agent.chat_run_turn_steered(chat, server.app.run.connection, agent.chat_retry_policy_default(), observer, nil, &server.app.run.control)
	acp_v2_turn_end(server, turn_completed)
	return true
}

@(require_results)
acp_models_state :: proc(server: ^Acp_Server) -> (acp.Models_State, bool) {
	if len(server.app.setup.catalog.models) == 0 { return {}, true }
	result: acp.Models_State
	result.current_model_id = server.app.setup.model_id
	available, available_error := make([]acp.Model_Info, len(server.app.setup.catalog.models), context.temp_allocator)
	if available_error != nil { return {}, false }
	for model, index in server.app.setup.catalog.models {
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
acp_model_config_values :: proc(server: ^Acp_Server) -> ([]acp.Config_Value, bool) {
	values, values_error := make([]acp.Config_Value, len(server.app.setup.catalog.models), context.temp_allocator)
	if values_error != nil { return nil, false }
	for model, index in server.app.setup.catalog.models {
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
acp_effort_config_values :: proc(server: ^Acp_Server) -> ([]acp.Config_Value, bool) {
	levels := server.app.setup.session.effort_levels[:]
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
acp_model_config_options_v1 :: proc(server: ^Acp_Server) -> ([]acp.V1_Config_Option, bool) {
	model_count := 0
	if len(server.app.setup.catalog.models) > 0 { model_count = 1 }
	effort_count := 0
	if len(server.app.setup.session.effort_levels) > 0 { effort_count = 1 }
	options, options_error := make([]acp.V1_Config_Option, model_count + effort_count, context.temp_allocator)
	if options_error != nil { return nil, false }
	index := 0
	if model_count == 1 {
		values, values_ok := acp_model_config_values(server)
		if !values_ok { return nil, false }
		options[index] = acp.V1_Config_Option {
			id            = "model",
			name          = "Model",
			category      = "model",
			type          = "select",
			current_value = server.app.setup.model_id,
			options       = values,
		}
		index += 1
	}
	if effort_count == 1 {
		levels, levels_ok := acp_effort_config_values(server)
		if !levels_ok { return nil, false }
		options[index] = acp.V1_Config_Option {
			id            = "effort",
			name          = "Effort",
			category      = "thought_level",
			type          = "select",
			current_value = server.app.setup.session.effort,
			options       = levels,
		}
	}
	return options, true
}

@(require_results)
acp_model_config_options_v2 :: proc(server: ^Acp_Server) -> ([]acp.V2_Config_Option, bool) {
	model_count := 0
	if len(server.app.setup.catalog.models) > 0 { model_count = 1 }
	effort_count := 0
	if len(server.app.setup.session.effort_levels) > 0 { effort_count = 1 }
	options, options_error := make([]acp.V2_Config_Option, model_count + effort_count, context.temp_allocator)
	if options_error != nil { return nil, false }
	index := 0
	if model_count == 1 {
		values, values_ok := acp_model_config_values(server)
		if !values_ok { return nil, false }
		options[index] = acp.V2_Config_Option {
			config_id     = "model",
			name          = "Model",
			category      = "model",
			type          = "select",
			current_value = server.app.setup.model_id,
			options       = values,
		}
		index += 1
	}
	if effort_count == 1 {
		levels, levels_ok := acp_effort_config_values(server)
		if !levels_ok { return nil, false }
		options[index] = acp.V2_Config_Option {
			config_id     = "effort",
			name          = "Effort",
			category      = "thought_level",
			type          = "select",
			current_value = server.app.setup.session.effort,
			options       = levels,
		}
	}
	return options, true
}

// acp_notify sends one session/update notification carrying update. Every streamed
// frame is built here, so the session id and the notification name are stated once.
@(require_results)
acp_notify :: proc(server: ^Acp_Server, update: $T) -> bool {
	params := acp.Session_Notification(T) {
		session_id = acp_session_id(server),
		update     = update,
	}
	return acp.writer_write_notification(&server.writer, acp.NOTIFICATION_SESSION_UPDATE, params)
}

@(require_results)
acp_send_session_info :: proc(server: ^Acp_Server, title: string) -> bool {
	return acp_notify(server, acp.Session_Info_Update{session_update = acp.UPDATE_SESSION_INFO, title = title})
}

// --- streaming what happens --------------------------------------------------

// acp_send_message writes one streamed message fragment. Chunks that share an id are one
// message in the client, which is what keeps a notice from reading as part of the answer.
@(require_results)
acp_send_user_message :: proc(server: ^Acp_Server, message_id, text: string) -> bool {
	if !acp_is_v2(server) { return false }
	content, content_error := make([]acp.Text_Content, 1, context.temp_allocator)
	if content_error != nil { return false }
	content[0] = {
		type = acp.CONTENT_TEXT,
		text = text,
	}
	return acp_notify(server, acp.Message_Update{session_update = acp.UPDATE_USER_MESSAGE, message_id = message_id, content = content})
}

@(require_results)
acp_send_state :: proc(server: ^Acp_Server, state, stop_reason: string) -> bool {
	if !acp_is_v2(server) { return false }
	return acp_notify(server, acp.State_Update{session_update = acp.UPDATE_STATE, state = state, stop_reason = stop_reason})
}

@(require_results)
acp_send_message_full :: proc(server: ^Acp_Server, kind, message_id, text: string) -> bool {
	if !acp_is_v2(server) { return acp_send_message(server, kind, text, message_id) }
	content, content_error := make([]acp.Text_Content, 1, context.temp_allocator)
	if content_error != nil { return false }
	content[0] = {
		type = acp.CONTENT_TEXT,
		text = text,
	}
	return acp_notify(server, acp.Message_Update{session_update = kind, message_id = message_id, content = content})
}

@(require_results)
acp_send_message :: proc(server: ^Acp_Server, kind: string, text, message_id: string) -> bool {
	resolved_message_id := message_id
	if acp_is_v2(server) && resolved_message_id == "" {
		resolved_message_id = acp_next_message_id(server)
	}
	return acp_notify(server, acp.Message_Chunk{session_update = kind, content = {type = acp.CONTENT_TEXT, text = text}, message_id = resolved_message_id})
}

// acp_send_tool_call announces one call with the state it is in when it is announced: a
// call about to run is pending, and a call replayed from the record already has its
// output.
@(require_results)
acp_send_tool_call :: proc(server: ^Acp_Server, call_id, name, arguments: string, status: acp.Tool_Status, output: string) -> bool {
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
	if acp_is_v2(server) {
		return acp_notify(
			server,
			acp.Tool_Call_Update_V2 {
				session_update = acp.UPDATE_TOOL_CALL_UPDATE,
				tool_call_id = call_id,
				name = name,
				title = acp_tool_title(name, arguments),
				kind = acp.tool_kind_name(acp_tool_kind(&server.app.setup.session, name)),
				status = acp.tool_status_name(status),
				content = content,
				raw_input = raw if parse_err == nil else nil,
			},
		)
	}
	return acp_notify(
		server,
		acp.Tool_Call {
			session_update = acp.UPDATE_TOOL_CALL,
			tool_call_id = call_id,
			title = acp_tool_title(name, arguments),
			kind = acp.tool_kind_name(acp_tool_kind(&server.app.setup.session, name)),
			status = acp.tool_status_name(status),
			content = content,
			raw_input = raw if parse_err == nil else nil,
		},
	)
}

// acp_send_tool_result settles a call that was already announced, by its id.
@(require_results)
acp_send_tool_result :: proc(server: ^Acp_Server, call_id: string, status: acp.Tool_Status, output: string) -> bool {
	content, content_error := make([]acp.Tool_Call_Content, 1, context.temp_allocator)
	if content_error != nil { return false }
	content[0] = acp_tool_content(output)
	if acp_is_v2(server) {
		return acp_notify(
			server,
			acp.Tool_Call_Update_V2 {
				session_update = acp.UPDATE_TOOL_CALL_UPDATE,
				tool_call_id = call_id,
				status = acp.tool_status_name(status),
				content = content,
			},
		)
	}
	return acp_notify(
		server,
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
acp_send_usage :: proc(server: ^Acp_Server, used, size: i64) -> bool {
	return acp_notify(server, acp.Usage_Update{session_update = acp.UPDATE_USAGE, used = used, size = size})
}

// acp_session_id is the id a session update names. The worker owns the session, so the
// string is borrowed for the write and no longer.
acp_session_id :: proc(server: ^Acp_Server) -> string {
	return agent.chat_session_text(&server.app.setup.session)
}

acp_user_message_id :: proc(server: ^Acp_Server) -> string {
	if turn := server.app.setup.session.turn; turn != 0 { return fmt.tprintf("msg-user-%d-1", i64(turn)) }
	return acp_next_message_id(server)
}

acp_assistant_message_id :: proc(server: ^Acp_Server) -> string {
	turn := server.app.setup.session.turn
	request := server.app.setup.session.request
	if turn != 0 && request != 0 {
		return fmt.tprintf("msg-assistant-%d-%d", i64(turn), i64(request))
	}
	if turn != 0 { return fmt.tprintf("msg-assistant-%d", i64(turn)) }
	return acp_next_message_id(server)
}

acp_notice_message_id :: proc(server: ^Acp_Server) -> string {
	turn := server.app.setup.session.turn
	request := server.app.setup.session.request
	if turn != 0 && request != 0 {
		return fmt.tprintf("msg-notice-%d-%d", i64(turn), i64(request))
	}
	return acp_next_message_id(server)
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
// the server so it outlives the scratch memory the streamed chunks borrow. A copy
// that fails is recorded and leaves the previous id in place, so the stream
// continues under the id it already had rather than under none.
acp_set_active_message_id :: proc(server: ^Acp_Server, message_id: string) {
	owned, clone_error := strings.clone(message_id, server.alloc)
	if clone_error != nil {
		agent.log_emit(agent.Log_Record{level = .Error, category = .Runtime, event = "acp.message_id_failed"})
		return
	}
	delete(server.active_message_id, server.alloc)
	server.active_message_id = owned
}

acp_clear_active_message_id :: proc(server: ^Acp_Server) {
	delete(server.active_message_id, server.alloc)
	server.active_message_id = ""
}

// acp_tool_status maps a harness outcome to the wire status. v2 names cancellation;
// v1 has no cancelled state, so a cancelled call reads as failed there.
acp_tool_status :: proc(server: ^Acp_Server, outcome: journal.Tool_Outcome) -> acp.Tool_Status {
	if outcome == .Success { return .Completed }
	if outcome == .Cancelled && acp_is_v2(server) { return .Cancelled }
	return .Failed
}

acp_next_message_id :: proc(server: ^Acp_Server) -> string {
	server.message_seq += 1
	return fmt.tprintf("msg-%d", server.message_seq)
}

@(private)
acp_current_message_id :: proc(server: ^Acp_Server) -> string {
	if acp_is_v2(server) && server.active_message_id != "" {
		return server.active_message_id
	}
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
	if acp_is_v2(server) {
		acp_set_active_message_id(server, acp_assistant_message_id(server))
	} else {
		_ = acp_next_message_id(server)
	}
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
	message_id := acp_next_message_id(server)
	if acp_is_v2(server) { message_id = acp_notice_message_id(server) }
	_ = acp_send_message(server, acp.UPDATE_AGENT_MESSAGE_CHUNK, text, message_id)
}

acp_obs_tool_call :: proc(user_data: rawptr, event: agent.Chat_Tool_Event) {
	server := cast(^Acp_Server)user_data
	_ = acp_send_tool_call(server, event.call_id, event.name, event.arguments, .Pending, "")
}

acp_obs_tool_result :: proc(user_data: rawptr, name: string, result: ^agent.Tool_Result) {
	server := cast(^Acp_Server)user_data
	text := tool_display_preview(result.content)
	if text == "" { text = tool_display_summary(result) }
	_ = acp_send_tool_result(server, result.call_id, acp_tool_status(server, result.outcome), text)
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
	message_id := acp_next_message_id(server)
	if acp_is_v2(server) { message_id = acp_notice_message_id(server) }
	_ = acp_send_message(server, acp.UPDATE_AGENT_MESSAGE_CHUNK, retry_display_text(event), message_id)
}

// --- replaying a loaded conversation -----------------------------------------

// acp_replay_session streams the conversation a client just loaded. Every entry the
// harness keeps becomes the update that carries it: the user's own lines, the model's
// answers, and each stored call with the result it produced. A client that asked to load
// a session shows the conversation it asked for rather than an empty one.
acp_replay_session :: proc(server: ^Acp_Server) {
	chat := &server.app.setup.session
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		_ = acp_send_message(server, acp.UPDATE_AGENT_MESSAGE_CHUNK, "the session's history could not be allocated", acp_next_message_id(server))
		return
	}
	defer virtual.arena_destroy(&arena)
	replayed, load_err := agent.projection_load(chat.store, chat.session, chat.head, virtual.arena_allocator(&arena))
	if load_err != nil {
		_ = acp_send_message(server, acp.UPDATE_AGENT_MESSAGE_CHUNK, "the session's history could not be read", acp_next_message_id(server))
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
			if acp_is_v2(server) {
				_ = acp_send_message_full(server, message_kind, message_id, payload.text)
			} else {
				_ = acp_send_message(server, kind, payload.text, message_id)
			}
		case agent.Projected_Assistant:
			message_id := acp_replay_assistant_message_id(item)
			if acp_is_v2(server) {
				_ = acp_send_message_full(server, acp.UPDATE_AGENT_MESSAGE, message_id, payload.text)
			} else {
				_ = acp_send_message(server, acp.UPDATE_AGENT_MESSAGE_CHUNK, payload.text, message_id)
			}
		case agent.Projected_Call:
			calls[payload.call] = payload
		case agent.Projected_Result:
			call, known := calls[payload.call]
			if !known { continue }
			text := tool_display_preview(payload.content)
			if text == "" { text = journal.TOOL_OUTCOME_NAMES[payload.outcome] }
			_ = acp_send_tool_call(server, call.provider_id, call.name, call.proposed, acp_tool_status(server, payload.outcome), text)
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
