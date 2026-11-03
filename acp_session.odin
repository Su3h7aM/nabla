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
// themselves. Each ACP_Session is followed by its worker thread: the worker appends the
// session's input and commands to the journal and polls what the session server commits.
// The reader submits work through the guarded queue and never touches the journal. The
// reader thread alone creates, finds, and frees sessions, so a session it found stays
// valid for the request it is handling.

// ACP_MAX_SESSIONS is how many sessions one connection runs at once. Opening one more
// closes the least recently used idle session, and is refused when all are busy.
ACP_MAX_SESSIONS :: 8

// ACP_Session is one conversation of a connection.
//
// id, title, workspace, closing, worker_active, and last_used are guarded by
// conn.table_mu: the reader finds a session by its id and the worker publishes them
// after an open. A session opened from a stored id carries that id before it is open,
// so a request for it queues behind the open.
//
// Everything else is the worker's: the journal it follows, the server handle it
// started, the follow cursor it polls, and the selection it last saw applied. The
// worker alone appends records and reads the cursor, so no lock guards them.
ACP_Session :: struct {
	conn:              ^ACP_Server,
	id:                string, // owned by conn.alloc; hex session id
	title:             string, // owned; the client-supplied title
	workspace:         string, // owned; copied for the session list
	closing:           bool, // a close or eviction began; no new request may be queued
	worker_active:     bool, // worker servicing a request, including across waits
	last_used:         u64, // conn.use_clock at the last open or request
	// opened and released are the worker's: the session holds its conversation, and the
	// conversation has been given back.
	opened:            bool,
	released:          bool,
	// retired is set atomically by the worker as its last decision, so the reader
	// knows to reap the session.
	retired:           bool,
	work:              ACP_Work_Chan,
	worker:            ^thread.Thread,
	worker_done:       sync.One_Shot_Event, // signaled by the worker as its last action
	// queue_mu guards pending_work.
	queue_mu:          sync.Mutex,
	pending_work:      int,
	// cancel_mu guards cancel_requested. The reader sets it; the worker appends the
	// command, because only the worker touches the journal.
	cancel_mu:         sync.Mutex,
	cancel_requested:  bool,
	// store follows the session another process runs. It is open from the first
	// open to the release.
	store:             ^journal.Journal,
	follow:            Client_Follow,
	server:            Client_Server,
	session_id:        journal.Session_Id,
	// provider_id, model_id, and effort are the serving identity the session last
	// saw applied, owned by conn.alloc. They answer prompts and option listings
	// without reading the journal.
	provider_id:       string,
	model_id:          string,
	effort:            string,
	// message_seq numbers process-local live message ids. Replay uses its own ids
	// from the durable turn and request, so it can reproduce them.
	message_seq:       u64,
	// turn_waiting is set while the worker waits for a turn to end. A prompt that arrives
	// then is steering input, and the worker serves the queue between polls. Worker only.
	turn_waiting:      bool,
	active_message_id: string, // owned by conn.alloc; the v2 answer being streamed
	// pending_text borrows the prompt the worker waits to see echoed. The echo is the
	// user message the prompt's acceptance names, and accept_message carries its id,
	// owned by conn.alloc. The two can never disagree.
	pending_text:      string,
	pending_accept:    bool,
	accept_message:    string,
	// tool_calls maps a journal call to the provider's id the announcement carried,
	// owned by conn.alloc, so the result settles the call the client was shown. The
	// follow observer reports every committed call exactly once as pending and exactly
	// once as settled, so every result finds its announcement.
	tool_calls:        map[journal.Call_Id]string,
}

// ACP_Server is the connection: the writer, the wire surface the profile names, and the
// session table. The table's slots are written by the reader thread only.
ACP_Server :: struct {
	// app.setup carries the shared catalog, configuration, directories, and run id. It
	// holds no session and no selection of this connection.
	app:              App,
	alloc:            mem.Allocator,
	base_mcp_servers: []agent.MCP_Server_Config, // borrowed from the launch config
	// default_provider, default_model, and default_effort are the selection new sessions
	// start with; they are owned by alloc.
	default_provider: string,
	default_model:    string,
	default_effort:   string,
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
	// that did not stop. Reader only.
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
acp_default_selection :: proc(conn: ^ACP_Server, selection: Applied_Selection, found: bool) {
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
	target, problem := selection_target_resolve(&conn.app, provider_id, model_id, conn.alloc)
	defer if problem != "" { delete(problem, conn.alloc) }
	if target.model_id == "" { return false }
	defer agent.model_selection_destroy(&target, conn.alloc)
	provider, provider_error := strings.clone(target.provider_id, conn.alloc)
	model, model_error := strings.clone(target.model_id, conn.alloc)
	kept_effort, effort_error := strings.clone(effort, conn.alloc)
	if provider_error != nil || model_error != nil || effort_error != nil {
		delete(provider, conn.alloc)
		delete(model, conn.alloc)
		delete(kept_effort, conn.alloc)
		return false
	}
	delete(conn.default_provider, conn.alloc)
	delete(conn.default_model, conn.alloc)
	delete(conn.default_effort, conn.alloc)
	conn.default_provider = provider
	conn.default_model = model
	conn.default_effort = kept_effort
	return true
}

// acp_server_destroy stops and joins every session before draining the writer. False
// means a worker still borrows the connection: the caller must retain conn, its
// writer, and all shared setup allocations until process exit. A closed connection
// only detaches: the session servers keep running without it.
acp_server_destroy :: proc(conn: ^ACP_Server, patience := SHUTDOWN_JOIN_PATIENCE) -> bool {
	for session in conn.sessions {
		if session == nil { continue }
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
		acp_session_free(session)
	}
	if conn.worker_stuck {
		// Late worker callbacks can still enqueue frames, so the writer stays alive.
		return false
	}
	if !acp.writer_destroy(&conn.writer, patience) { return false }
	run_setup_destroy(&conn.app.setup)
	delete(conn.default_provider, conn.alloc)
	delete(conn.default_model, conn.alloc)
	delete(conn.default_effort, conn.alloc)
	conn.default_provider = ""
	conn.default_model = ""
	conn.default_effort = ""
	return true
}

// --- the table ---------------------------------------------------------------

// acp_session_make allocates a session with its queue and starts nothing.
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
	delete(session.provider_id, alloc)
	delete(session.model_id, alloc)
	delete(session.effort, alloc)
	delete(session.accept_message, alloc)
	delete(session.active_message_id, alloc)
	for _, provider_id in session.tool_calls { delete(provider_id, alloc) }
	delete(session.tool_calls)
	free(session, alloc)
}

// acp_session_create gives the connection a new session and starts its worker. A full
// table closes the least recently used idle session to make room; with none idle the
// reason says so. A session created from a stored id carries that id at once. Reader
// thread only.
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
	// The evicted session detaches before the new one can ask for its slot.
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

// acp_session_idle reports whether a session has no request running and none queued.
// Called with table_mu held.
@(require_results)
acp_session_idle :: proc(session: ^ACP_Session) -> bool {
	return !session.worker_active && !acp_session_has_work(session)
}

// acp_session_is_closing reports whether the reader began closing the session.
@(require_results)
acp_session_is_closing :: proc(session: ^ACP_Session) -> bool {
	sync.mutex_guard(&session.conn.table_mu)
	return session.closing
}

// acp_cancel_session asks the running turn of session to stop. It only records the
// intent; the worker appends the command, because only the worker touches the journal.
// A cancellation for a session that is idle is ignored by the server, which is what the
// protocol expects: a turn that already ended has nothing to cancel.
acp_cancel_session :: proc(session: ^ACP_Session) {
	if sync.mutex_guard(&session.cancel_mu) {
		session.cancel_requested = true
	}
	agent.owner_wake_signal()
}

// acp_cancel_take claims a pending cancellation for the worker that appends it.
@(require_results)
acp_cancel_take :: proc(session: ^ACP_Session) -> bool {
	sync.mutex_guard(&session.cancel_mu)
	requested := session.cancel_requested
	session.cancel_requested = false
	return requested
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
// frees it. A worker that does not stop leaves the session unfreed and is reported at
// teardown. Only detaching: the session server keeps running without this connection.
// Reader thread only.
acp_session_drop :: proc(conn: ^ACP_Server, session: ^ACP_Session) {
	chan.close(&session.work)
	agent.owner_wake_signal()
	if !join_retiring(session.worker, &session.worker_done) {
		conn.worker_stuck = true
		return
	}
	session.worker = nil
	acp_session_shutdown(session)
	acp_session_release(session)
	acp_session_free(session)
}

// acp_session_shutdown answers what a session never ran: requests still queued. The
// worker has retired.
acp_session_shutdown :: proc(session: ^ACP_Session) {
	alloc := session.conn.alloc
	for {
		queued, ok := chan.try_recv(session.work)
		if !ok { break }
		_ = acp.write_error(&session.conn.writer, queued.id, acp.ERROR_INVALID_REQUEST, "the session closed before the request could run")
		acp_work_destroy(&queued, alloc)
	}
}

// acp_session_release gives back what the session holds: the follow, the server handle,
// the journal, and the model's strings. It may run twice, once by a close on the worker
// and once by whoever frees the session. A closed connection only detaches: the session
// server keeps running without it.
acp_session_release :: proc(session: ^ACP_Session) {
	if session.released { return }
	session.released = true
	client_follow_close(&session.follow)
	client_server_close(&session.server)
	if session.store != nil {
		if close_error := session_store_close(session.store); close_error != nil {
			fmt.eprintln("nabla: the session database could not be closed cleanly:", journal.error_text(close_error, context.temp_allocator))
		}
		session.store = nil
	}
	delete(session.provider_id, session.conn.alloc)
	delete(session.model_id, session.conn.alloc)
	delete(session.effort, session.conn.alloc)
	session.provider_id = ""
	session.model_id = ""
	session.effort = ""
	delete(session.accept_message, session.conn.alloc)
	session.accept_message = ""
	delete(session.active_message_id, session.conn.alloc)
	session.active_message_id = ""
	for _, provider_id in session.tool_calls { delete(provider_id, session.conn.alloc) }
	delete(session.tool_calls)
	session.tool_calls = nil
	sync.mutex_guard(&session.conn.table_mu)
	delete(session.id, session.conn.alloc)
	session.id = ""
	delete(session.title, session.conn.alloc)
	session.title = ""
	delete(session.workspace, session.conn.alloc)
	session.workspace = ""
}
