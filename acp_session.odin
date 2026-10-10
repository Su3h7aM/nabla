#+build linux
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"

import "nabla:acp"
import "nabla:agent"
import "nabla:agent/journal"

// The ACP connection holds what every session of it shares, and a table of the sessions
// themselves. Each ACP_Session has exactly one owner, its worker thread: the worker holds
// the session's journal, chat, queue, Turn_Control and MCP runtime, and nothing else touches
// them while it runs. The reader thread alone creates, finds, and frees sessions, so a
// session it found stays valid for the request it is handling.

// ACP_MAX_SESSIONS is how many sessions one connection runs at once. Opening one more
// closes the least recently used idle session, and is refused when all are busy.
ACP_MAX_SESSIONS :: 8

// ACP_Session is one conversation of a connection.
//
// Its App is a view over the connection's: app.setup shares the following fields by
// shallow copy, borrows them from the connection's own setup, and never frees them:
// harness_options, catalog, configured, journal_directory, lock_directory, run, and alloc.
// The catalog is safe to share because an ACP connection never refreshes or replaces it.
// owns_selection and shared_sessions stay false and run_open stays true: the connection
// records run.started and run.finished once, so no session's journal does.
//
// Everything else in app.setup is the session's own: store, session, workspace, the
// resumed_* strings, provider_id, model_id, api, credential, mcp, and mcp_servers.
// acp_session_make is the one place the shared fields are copied.
ACP_Session :: struct {
	conn:              ^ACP_Server,
	app:               App,
	// id, title, workspace, closing, owner_active, and last_used are guarded by conn.table_mu: the
	// reader finds a session by its id and the owner publishes them after an open. A
	// session opened from a stored id carries that id before it is open, so a request
	// for it queues behind the open.
	id:                string, // owned by conn.alloc
	title:             string, // owned; the client-supplied title
	workspace:         string, // owned; copied for the session list
	closing:           bool, // a close or eviction began; no new request may be queued
	owner_active:      bool, // owner servicing a turn or a request, including across owner waits
	last_used:         u64, // conn.use_clock at the last open or request
	// opened and released are the owner's: the session holds its conversation, and the
	// conversation has been given back.
	opened:            bool,
	released:          bool,
	// retired is set atomically by the worker as its last decision, so the reader
	// knows to reap the session.
	retired:           bool,
	mcp_servers_owned: [dynamic]agent.MCP_Server_Config, // owned active list when a client supplied servers
	work:              ACP_Work_Chan,
	worker:            ^thread.Thread,
	worker_done:       sync.One_Shot_Event, // signaled by the worker as its last action
	// queue_mu guards pending_work.
	queue_mu:          sync.Mutex,
	pending_work:      int,
	// model_mu guards only the single pending reader-to-owner handoff.
	model_mu:          sync.Mutex,
	model_request:     ACP_Model_Request,
	model_cancel:      bool, // owner should settle all current model-selection RPCs
	model_selection:   ACP_Model_Selection, // owner only
	// message_seq numbers process-local fallback messages. The v2 live assistant id
	// is derived from the durable turn and request instead, so replay can reproduce it.
	message_seq:       u64,
	active_message_id: string, // owned by conn.alloc; the v2 answer being streamed
}

// ACP_Server is the connection: the writer, the wire profile, the setup every session
// shares, and the session table. The table's slots are written by the reader thread only.
ACP_Server :: struct {
	// app.setup carries the shared catalog, configuration, directories, and run id, and
	// the connection's own default selection in provider_id and model_id. It holds no
	// session.
	app:              App,
	alloc:            mem.Allocator,
	base_mcp_servers: []agent.MCP_Server_Config, // borrowed from the launch config
	default_effort:   string, // owned; the effort that goes with the default selection
	writer:           acp.Writer,
	// initialized is set once initialize has been answered. Only the reader writes it.
	initialized:      bool,
	// profile is the wire surface agreed with the client.
	profile:          ACP_Wire_Profile,
	// table_mu guards use_clock and the fields of every session that its comment names.
	table_mu:         sync.Mutex,
	sessions:         [ACP_MAX_SESSIONS]^ACP_Session,
	use_clock:        u64,
	// worker_stuck and memory_leaked say a session could not be released: a worker thread
	// that did not stop, or a tool worker that still borrows the session. Reader only.
	worker_stuck:     bool,
	memory_leaked:    bool,
}

// --- the connection ----------------------------------------------------------

// acp_connection_open resolves the configuration into the shared setup, records
// run.started in a journal of its own, and fixes the connection's default model: the
// user's last choice, otherwise the first model the configuration can serve. It opens no
// session. Errors print to stderr; false means the caller should exit.
@(require_results)
acp_connection_open :: proc(conn: ^ACP_Server, sources: []agent.Catalog_Provider_Source) -> bool {
	setup := &conn.app.setup
	setup.alloc = conn.alloc
	ok := false
	defer if !ok { run_setup_destroy(setup) }

	catalog, configured, resolved := resolve_run_catalog(sources, setup.alloc)
	if !resolved { return false }
	setup.catalog = catalog
	setup.configured = configured

	directory, directory_error := agent.xdg_directory(.State, setup.alloc)
	if directory_error != .None {
		fmt.eprintln("nabla: cannot resolve the state directory for sessions")
		return false
	}
	setup.journal_directory = directory
	locks, replaced, locks_error := agent.session_lock_directory(setup.alloc)
	if locks_error != .None {
		fmt.eprintln("nabla: cannot resolve the directory for session locks")
		return false
	}
	if replaced {
		fmt.eprintf("nabla: warning: XDG_RUNTIME_DIR is not an absolute path; session locks are kept in %s\n", locks)
	}
	setup.lock_directory = locks
	setup.run = journal.run_id_create()

	store, open_error := session_store_open(setup)
	if open_error != nil {
		fmt.eprintln("nabla: cannot open the session database:", journal.error_text(open_error, context.temp_allocator))
		return false
	}
	journal.append_record(store, {kind = .Run_Started}, journal.Run_Started{pid = int(os.get_pid())})
	_, commit_error := journal.commit(store)
	if commit_error != nil {
		fmt.eprintln("nabla: cannot record the run:", journal.error_text(commit_error, context.temp_allocator))
		_ = session_store_close(store)
		return false
	}
	// run.finished is owed from here, and no session's journal carries it.
	setup.run_open = true
	selection, found, load_error := selection_latest(store, setup.alloc)
	defer selection_destroy(&selection, setup.alloc)
	if close_error := session_store_close(store); close_error != nil {
		fmt.eprintln("nabla: the session database could not be closed cleanly:", journal.error_text(close_error, context.temp_allocator))
	}
	acp_default_selection(conn, selection, found && load_error == nil)
	ok = true
	return true
}

// acp_default_selection fixes the model new sessions start with when their own record
// names none. Nothing is persisted: a model chosen for an editor conversation is not the
// user's own last choice. An empty default is not fatal, because the prompt is what
// refuses a session with no model.
acp_default_selection :: proc(conn: ^ACP_Server, selection: journal.Selection_Changed, found: bool) {
	if found && acp_default_install(conn, selection.provider, selection.model, selection.effort) { return }
	candidates, candidates_ok := acp_servable_models(&conn.app, conn.alloc)
	if !candidates_ok { return }
	defer acp_candidates_destroy(candidates, conn.alloc)
	for candidate in candidates {
		if acp_default_install(conn, candidate.provider_id, candidate.model_id, "") { return }
	}
}

@(require_results)
acp_default_install :: proc(conn: ^ACP_Server, provider_id, model_id, effort: string) -> bool {
	setup := &conn.app.setup
	target, problem := selection_target_resolve(&conn.app, provider_id, model_id, setup.alloc)
	defer if problem != "" { delete(problem, context.temp_allocator) }
	if target.model_id == "" { return false }
	defer agent.model_selection_destroy(&target, setup.alloc)
	provider, provider_error := strings.clone(target.provider_id, setup.alloc)
	model, model_error := strings.clone(target.model_id, setup.alloc)
	kept_effort, effort_error := strings.clone(effort, setup.alloc)
	if provider_error != nil || model_error != nil || effort_error != nil {
		delete(provider, setup.alloc)
		delete(model, setup.alloc)
		delete(kept_effort, setup.alloc)
		return false
	}
	setup.provider_id = provider
	setup.model_id = model
	conn.default_effort = kept_effort
	return true
}

// acp_server_destroy stops and joins every session before draining the writer. False
// means a worker or abandoned child still borrows the connection: the caller must retain
// conn, its writer, and all shared setup allocations until process exit.
acp_server_destroy :: proc(conn: ^ACP_Server, patience := SHUTDOWN_JOIN_PATIENCE) -> bool {
	for session in conn.sessions {
		if session == nil { continue }
		acp_cancel_session(session)
		chan.close(&session.work)
	}
	agent.owner_wake_signal()
	for session in conn.sessions {
		if session == nil || session.worker == nil { continue }
		if join_retiring(session.worker, &session.worker_done, patience) {
			session.worker = nil
		} else {
			conn.worker_stuck = true
		}
	}
	for session, index in conn.sessions {
		if session == nil || session.worker != nil { continue }
		acp_session_shutdown(session)
		acp_session_release(session)
		conn.sessions[index] = nil
		if session.app.setup.workers_abandoned {
			conn.memory_leaked = true
			continue
		}
		acp_session_free(session)
	}
	if conn.worker_stuck || conn.memory_leaked {
		// Late worker callbacks can still enqueue frames, so the writer stays alive.
		return false
	}
	if !acp.writer_destroy(&conn.writer, patience) { return false }
	run_setup_destroy(&conn.app.setup)
	delete(conn.default_effort, conn.alloc)
	conn.default_effort = ""
	return true
}

// --- the table ---------------------------------------------------------------

// acp_session_make allocates a session with its queue and the shared view of the
// connection's setup, and starts nothing. preset_id is the id a stored session is opened
// by, or empty for a new one. It is the only place a session copies the connection's
// shared fields, and so the only place that changes if the setup is ever split.
@(require_results)
acp_session_make :: proc(conn: ^ACP_Server, preset_id: string) -> (session: ^ACP_Session, ok: bool) {
	made, new_error := new(ACP_Session, conn.alloc)
	if new_error != nil { return nil, false }
	id, id_error := strings.clone(preset_id, conn.alloc)
	if id_error != nil {
		free(made, conn.alloc)
		return nil, false
	}
	channel, channel_error := chan.create_buffered(ACP_Work_Chan, ACP_WORK_CAPACITY, conn.alloc)
	if channel_error != nil {
		delete(id, conn.alloc)
		free(made, conn.alloc)
		return nil, false
	}
	made.conn = conn
	made.id = id
	made.work = channel
	shared := &conn.app.setup
	setup := &made.app.setup
	setup.harness_options = shared.harness_options
	setup.catalog = shared.catalog
	setup.configured = shared.configured
	setup.journal_directory = shared.journal_directory
	setup.lock_directory = shared.lock_directory
	setup.run = shared.run
	setup.alloc = shared.alloc
	setup.run_open = true
	setup.owns_selection = false
	setup.shared_sessions = false
	setup.mcp_servers = conn.base_mcp_servers
	made.app.run.alloc = conn.alloc
	made.app.compact_on_switch = conn.app.compact_on_switch
	return made, true
}

// acp_session_free releases a session that is released and has no worker. Its queue must
// be empty.
acp_session_free :: proc(session: ^ACP_Session) {
	alloc := session.conn.alloc
	if session.work != {} { chan.destroy(&session.work) }
	delete(session.id, alloc)
	delete(session.title, alloc)
	delete(session.workspace, alloc)
	delete(session.active_message_id, alloc)
	free(session, alloc)
}

// acp_session_create gives the connection a new session and starts its worker. A full table
// closes the least recently used idle session to make room; with none idle the reason says
// so. A session created from a stored id carries that id at once. Reader thread only.
@(require_results)
acp_session_create :: proc(conn: ^ACP_Server, preset_id: string) -> (session: ^ACP_Session, reason: string) {
	acp_sessions_reap(conn)
	made, made_ok := acp_session_make(conn, preset_id)
	if !made_ok { return nil, "the session could not be allocated" }

	slot := -1
	victim: ^ACP_Session
	if sync.mutex_guard(&conn.table_mu) {
		for entry, index in conn.sessions {
			if entry == nil {
				slot = index
				break
			}
		}
		if slot < 0 {
			for entry, index in conn.sessions {
				if entry.closing || !acp_session_idle(entry) { continue }
				if victim == nil || entry.last_used < victim.last_used {
					victim = entry
					slot = index
				}
			}
		}
		if slot >= 0 {
			if victim != nil { victim.closing = true }
			conn.sessions[slot] = made
			conn.use_clock += 1
			made.last_used = conn.use_clock
		}
	}
	if slot < 0 {
		acp_session_free(made)
		return nil, "this connection is running its maximum number of sessions and all of them are busy; wait for one to finish or close one"
	}
	// The evicted session gives its claim back before the new one can ask for it.
	if victim != nil { acp_session_drop(conn, victim) }

	worker := thread.create(acp_worker, name = "nabla-acp-worker")
	if worker == nil {
		conn.sessions[slot] = nil
		acp_session_free(made)
		return nil, "the session worker could not be started"
	}
	worker.data = made
	made.worker = worker
	thread.start(worker)
	return made, ""
}

// acp_session_find returns the open session a request names, or nil for an id the
// connection does not run, or runs no longer. Reader thread only.
@(require_results)
acp_session_find :: proc(conn: ^ACP_Server, id: string) -> ^ACP_Session {
	if id == "" { return nil }
	sync.mutex_guard(&conn.table_mu)
	for session in conn.sessions {
		if session != nil && !session.closing && session.id == id { return session }
	}
	return nil
}

// acp_session_touch records a use, which is what eviction orders by.
acp_session_touch :: proc(session: ^ACP_Session) {
	sync.mutex_guard(&session.conn.table_mu)
	session.conn.use_clock += 1
	session.last_used = session.conn.use_clock
}

// acp_session_idle reports whether a session has no turn running and no request queued.
// Called with table_mu held.
@(require_results)
acp_session_idle :: proc(session: ^ACP_Session) -> bool {
	return !session.owner_active && !acp_session_has_work(session) && !acp_model_owner_work_pending(session)
}

// acp_owner_service_begin reserves background servicing against reader eviction.
@(require_results)
acp_owner_service_begin :: proc(session: ^ACP_Session) -> bool {
	sync.mutex_guard(&session.conn.table_mu)
	if session.closing { return false }
	session.owner_active = true
	return true
}

// acp_owner_service_end keeps unfinished owner-only service protected across waits.
acp_owner_service_end :: proc(session: ^ACP_Session) {
	active := acp_owner_service_pending(session)
	sync.mutex_guard(&session.conn.table_mu)
	session.owner_active = active
}

// acp_session_retire is the worker's last decision: the session has nothing left to serve.
// Closing the queue turns a request that raced the retirement into a refusal.
acp_session_retire :: proc(session: ^ACP_Session) {
	if sync.mutex_guard(&session.conn.table_mu) {
		session.closing = true
	}
	chan.close(&session.work)
	sync.atomic_store(&session.retired, true)
}

// acp_sessions_reap frees every session whose worker retired, which frees its slot.
// Reader thread only.
acp_sessions_reap :: proc(conn: ^ACP_Server) {
	for session, index in conn.sessions {
		if session == nil || !sync.atomic_load(&session.retired) { continue }
		conn.sessions[index] = nil
		acp_session_drop(conn, session)
	}
}

// acp_session_drop stops a session that is no longer in the table, joins its worker, and
// frees it. A worker that does not stop, or a tool worker that still borrows the session,
// leaves the session unfreed and is reported at teardown. Reader thread only.
acp_session_drop :: proc(conn: ^ACP_Server, session: ^ACP_Session) {
	acp_cancel_session(session)
	chan.close(&session.work)
	agent.owner_wake_signal()
	if !join_retiring(session.worker, &session.worker_done) {
		conn.worker_stuck = true
		return
	}
	session.worker = nil
	acp_session_shutdown(session)
	acp_session_release(session)
	if session.app.setup.workers_abandoned {
		conn.memory_leaked = true
		return
	}
	acp_session_free(session)
}

// acp_session_shutdown answers what a session never ran: requests still queued, and a
// model selection still pending. The worker has retired.
acp_session_shutdown :: proc(session: ^ACP_Session) {
	alloc := session.conn.alloc
	for {
		queued, ok := chan.try_recv(session.work)
		if !ok { break }
		_ = acp.writer_write_error(&session.conn.writer, queued.id, acp.ERROR_INVALID_REQUEST, "the session closed before the request could run")
		acp_work_destroy(&queued, alloc)
	}
	request := acp_model_request_take(session)
	if request.active {
		_ = acp.writer_write_error(
			&session.conn.writer,
			request.id,
			acp.ERROR_INVALID_REQUEST,
			"the ACP session is closing before the model selection could be applied",
		)
		acp_model_request_destroy(&request, alloc)
	}
	if session.model_selection.active {
		acp_model_selection_error(
			session,
			&session.model_selection,
			acp.ERROR_INVALID_REQUEST,
			"the ACP session is closing before the model selection could be applied",
		)
	}
}

// acp_session_release gives back what the session's conversation holds: the chat, its
// journal and claim, the MCP runtime, and the model's strings. It may run twice, once by a
// close on the worker and once by whoever frees the session. The tool registry borrowed the
// runtime's bindings, so the chat goes first and the MCP clients second.
acp_session_release :: proc(session: ^ACP_Session) {
	if session.released { return }
	session.released = true
	setup := &session.app.setup
	agent.chat_session_destroy(&setup.session)
	setup.workers_abandoned = setup.workers_abandoned || setup.session.workers_retained
	if setup.workers_abandoned { return }
	// A release failure is recorded rather than answered: the session is already
	// destroyed, so the close stands either way.
	if close_error := session_store_close(setup.store); close_error != nil {
		fmt.eprintln("nabla: the session database could not be closed cleanly:", journal.error_text(close_error, context.temp_allocator))
	}
	setup.store = nil
	mcp_runtime_destroy(&setup.mcp)
	agent.MCP_Server_Configs_Destroy(&session.mcp_servers_owned, session.conn.alloc)
	setup.mcp_servers = session.conn.base_mcp_servers
	snapshot_destroy(&session.app)
	catalog_run_destroy(&session.app)
	delete(setup.workspace, setup.alloc)
	delete(setup.resumed_provider, setup.alloc)
	delete(setup.resumed_model, setup.alloc)
	delete(setup.resumed_effort, setup.alloc)
	delete(setup.credential, setup.alloc)
	delete(setup.provider_id, setup.alloc)
	delete(setup.model_id, setup.alloc)
	setup.workspace = ""
	setup.resumed_provider = ""
	setup.resumed_model = ""
	setup.resumed_effort = ""
	setup.credential = ""
	setup.provider_id = ""
	setup.model_id = ""
	delete(session.active_message_id, session.conn.alloc)
	session.active_message_id = ""
	sync.mutex_guard(&session.conn.table_mu)
	delete(session.id, session.conn.alloc)
	session.id = ""
	delete(session.title, session.conn.alloc)
	session.title = ""
	delete(session.workspace, session.conn.alloc)
	session.workspace = ""
}
