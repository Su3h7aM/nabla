#+build linux
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"

import "nabla:agent"
import "nabla:agent/session"
import "nabla:ai"

// --- worker ---------------------------------------------------------------

run_worker :: proc(thread_handle: ^thread.Thread) {
	app := cast(^App)thread_handle.data
	// A thread started without init_context gets the default context, not the one
	// the creating scope modified, so the run's logger is installed here. Only the
	// logger is taken: leaving init_context unset is what keeps the thread library
	// managing this thread's temporary allocator.
	context.logger = agent.log_logger(&app.setup.log_binding)
	observer := run_observer(app)
	// The session list the /resume menu offers is built here, because only the
	// worker touches the store.
	session_refresh_rows(app)
	for {
		work, ok := chan.try_recv(app.run.work)
		if !ok {
			// A stop that arrived with nothing queued leaves through the drain loop
			// below, so shutdown never waits on a compaction to finish.
			if runtime_stopping(app) { break }
			// Nothing is queued. A compaction that is still running has to be looked
			// at even with no work to do, or a finished summary would wait for the
			// next prompt to be installed.
			if app_compaction_pending(app) {
				if app_compaction_tick(app, observer) { refresh_status(app) }
				free_all(context.temp_allocator)
				time.sleep(WORK_IDLE_POLL)
				continue
			}
			work, ok = chan.recv(app.run.work)
			if !ok {
				return
			}
		}
		if runtime_stopping(app) {
			work_destroy(app, work)
			break
		}
		run_work(app, work, observer)
		work_destroy(app, work)
		// Temp scratch belongs to one work item. The worker is long-lived, so the
		// pool is recycled here rather than left to grow with the process.
		free_all(context.temp_allocator)
	}
	// The front-end stopped the runtime, so anything still queued is abandoned
	// rather than run. Closing the channel ends the loop once the buffer drains.
	for {
		queued, more := chan.recv(app.run.work)
		if !more { break }
		work_destroy(app, queued)
	}
}

// WORK_IDLE_POLL is how often the worker looks at a compaction that is still
// running. It bounds how long a finished summary waits when no command arrives,
// and it is a scheduling delay, not a token budget: nothing about the model or
// the context depends on it.
WORK_IDLE_POLL :: 50 * time.Millisecond

// app_compaction_pending reports whether the open session has compaction work to
// look at. A session that is not open has no control to poll, and its zero state
// is idle.
app_compaction_pending :: proc(app: ^App) -> bool {
	if app.setup.session.store == nil { return false }
	return app.setup.session.compact.state != agent.Compact_State.Idle
}

// app_compaction_tick advances the session's compaction by one look: it adopts a
// finished job, and installs a summary whose boundary has arrived. True means the
// active context changed and the status line it describes is stale.
app_compaction_tick :: proc(app: ^App, observer: agent.Chat_Observer) -> bool {
	if app.setup.session.store == nil { return false }
	return agent.chat_compact_service(&app.setup.session, observer)
}

// work_destroy releases the strings a queued command owns.
work_destroy :: proc(app: ^App, work: Work) {
	if work.text != "" {
		delete(work.text, app.run.alloc)
	}
	if work.provider != "" {
		delete(work.provider, app.run.alloc)
	}
}

// session_refresh_rows rebuilds the list the /resume menu shows. Only the worker
// calls it, so the store is never read from two threads.
session_refresh_rows :: proc(app: ^App) {
	if app.setup.session.store == nil { return }
	sessions, list_err := session.session_list(&app.setup.store, {workspace = app.setup.workspace, limit = 20}, app.run.alloc)
	if list_err != nil { return }
	defer session.sessions_destroy(sessions, app.run.alloc)

	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	for &row in app.run.snap.sessions {
		delete(string(row.id), app.run.alloc)
		delete(row.title, app.run.alloc)
	}
	clear(&app.run.snap.sessions)
	for &entry in sessions {
		append(
			&app.run.snap.sessions,
			Session_Row{id = session.Session_Id(strings.clone(string(entry.id), app.run.alloc)), title = strings.clone(entry.title, app.run.alloc)},
		)
	}
	// The running session is published with the list, so the menu can open on it
	// without reading the running session from another thread.
	delete(string(app.run.snap.active_session), app.run.alloc)
	app.run.snap.active_session = session.Session_Id(strings.clone(string(app.setup.session.id), app.run.alloc))
	app.run.snap.generation += 1
}

run_work :: proc(app: ^App, work: Work, observer: agent.Chat_Observer) {
	// A stop that arrived while this item was queued abandons it: shutdown does
	// not start new work.
	if runtime_stopping(app) { return }
	// A sink that failed during the previous item is reported once, here, where
	// the snapshot can carry it.
	run_log_failure(&app.setup, &app.run.log_failure_reported)
	// Work that can change which sessions exist, or what they are called, marks the
	// list the /resume menu reads as needing a rebuild.
	rows_dirty := false
	switch work.kind {
	case .Prompt:
		rows_dirty = true
		if app.setup.session.store == nil {
			snap_append(app, .Error, "no session is open; use /new or /resume")
			return
		}
		// Tools are refreshed between turns, while the session is idle. Both prompt
		// paths refresh, so an interactive turn and a headless one see the same tools.
		if warning := app_tools_refresh(app); warning != "" { snap_append(app, .Warning, warning) }
		accepted := agent.chat_session_accept_user(&app.setup.session, work.text, session.now_ms())
		if accepted != .Accepted {
			if accepted == .Storage_Failed {
				snap_append(app, .Error, agent.chat_session_last_error(&app.setup.session))
			} else {
				snap_append(app, .Warning, "chat is busy; input dropped")
			}
			return
		}
		snap_append(app, .User, work.text)
		set_running(app, true)
		// Accepting the prompt reset the cancellation token for the new turn, so a
		// stop that arrived while the prompt was being recorded has to be re-issued
		// here: otherwise shutdown would wait out a whole model request.
		if runtime_stopping(app) { agent.chat_cancel_request() }
		steer := agent.Steer_Context {
			queue       = &app.run.steer,
			provider_id = app.setup.provider_id,
			model_id    = app.setup.model_id,
			connection  = app.run.connection,
		}
		agent.chat_run_turn_steered(&app.setup.session, app.run.connection, observer, &steer)
		// A steering line applies only at a request boundary inside the turn it was
		// typed during. One the turn ended before reaching would otherwise be
		// applied to whatever turn comes next, where it no longer means what the
		// user intended, so it is reported and dropped.
		if dropped := agent.steer_clear(&app.run.steer); dropped > 0 {
			snap_append(app, .Warning, fmt.tprintf("%d steering line(s) arrived too late to apply; dropped", dropped))
		}
	case .Compact:
		set_running(app, true)
		if runtime_stopping(app) { agent.chat_cancel_request() }
		// Compaction reports why the model side stopped, but a durable write that
		// failed only latches the session: the reason the user needs is there.
		if !agent.chat_command_compact(&app.setup.session, observer, app.run.connection, nil) && agent.chat_session_storage_failed(&app.setup.session) {
			snap_append(app, .Error, agent.chat_session_last_error(&app.setup.session))
		}
	case .Status:
		agent.chat_notice_status(&app.setup.session, observer, session.now_ms())
	case .Effort:
		applied := true
		if work.text == "" || work.text == "default" {
			agent.chat_session_set_effort(&app.setup.session, "")
			snap_append(app, .Notice, agent.chat_effort_change_note(""))
		} else if agent.chat_session_set_effort(&app.setup.session, work.text) {
			snap_append(app, .Notice, agent.chat_effort_change_note(work.text))
		} else {
			applied = false
			snap_append(app, .Notice, fmt.tprintf("effort %s is not allowed for this model", work.text))
		}
		// The effort is part of the persisted selection, so a change rewrites it.
		if applied {
			selection := session.Selection {
				provider = app.setup.provider_id,
				model    = app.setup.model_id,
				effort   = app.setup.session.effort,
			}
			if save_err := session.selection_save(&app.setup.store, selection); save_err != nil {
				local := save_err
				snap_append(app, .Error, fmt.tprintf("the selection could not be recorded: %s", session.error_detail(&local)))
			}
		}
	case .Model:
		apply_selection(app, work.provider, work.text, "")
	case .New_Session:
		rows_dirty = true
		// The new session runs the same selection; only the conversation is new.
		provider := strings.clone(app.setup.provider_id, app.run.alloc)
		model := strings.clone(app.setup.model_id, app.run.alloc)
		defer delete(provider, app.run.alloc)
		defer delete(model, app.run.alloc)
		if session_start_new(app) {
			snapshot_clear(app)
			snap_append(app, .Notice, "started a new session")
			if provider != "" && model != "" { apply_selection(app, provider, model, "") }
		}
	case .Resume_Session:
		rows_dirty = true
		session_resume(app, work.text)
	}
	if rows_dirty { session_refresh_rows(app) }
	refresh_status(app)
}

// session_resume switches to the session a full id or an unambiguous prefix
// names, then shows the tail of its conversation. The menu always names a whole
// id; the prefix form exists for typing, and an ambiguous one is refused rather
// than guessed.
session_resume :: proc(app: ^App, reference: string) {
	if reference == "" {
		snap_append(app, .Notice, "usage: /resume <session id or prefix>")
		return
	}
	sessions, list_err := session.session_list(&app.setup.store, {workspace = app.setup.workspace, limit = session.SESSION_LIST_MAX_LIMIT}, app.run.alloc)
	if list_err != nil {
		local := list_err
		snap_append(app, .Error, fmt.tprintf("cannot list sessions: %s", session.error_detail(&local)))
		return
	}
	defer session.sessions_destroy(sessions, app.run.alloc)

	matched: session.Session_Id
	matches := 0
	defer if matched != "" { delete(string(matched), app.setup.alloc) }
	for &entry in sessions {
		if !strings.has_prefix(string(entry.id), reference) { continue }
		if matches > 0 { delete(string(matched), app.setup.alloc) }
		matched = session.Session_Id(strings.clone(string(entry.id), app.setup.alloc))
		matches += 1
	}
	if matches == 0 {
		snap_append(app, .Notice, fmt.tprintf("no session matches %s", reference))
		return
	}
	if matches > 1 {
		delete(string(matched), app.setup.alloc)
		matched = ""
		snap_append(app, .Notice, fmt.tprintf("%s matches more than one session", reference))
		return
	}
	if !session_switch(app, matched) { return }
	snapshot_clear(app)
	snap_append(app, .Notice, fmt.tprintf("resumed session %s", string(matched)))
	session_replay(app, &app.setup.session)
}

// session_start_new closes the running session and opens a fresh one, so the
// next prompt starts a new conversation. Nothing is recorded for the new session
// until that prompt, so starting one and never prompting leaves the store as it
// was. The candidate is claimed while the running session stays claimed, so a
// failure leaves the running session usable rather than dropping the front-end's
// only session.
session_start_new :: proc(app: ^App) -> bool {
	setup := &app.setup
	target, opened := session_open_target(setup, {kind = .New}, setup.workspace)
	if !opened { return false }
	defer session_target_destroy(&target, setup.alloc)

	adoption, message, adopted := session_adopt_new(setup, target)
	if !adopted {
		defer delete(message, setup.alloc)
		snap_append(app, .Error, message)
		return false
	}
	defer adoption_destroy(&adoption, setup.alloc)
	session_activate(app, &adoption)
	return true
}

// session_switch opens the named session, settling anything an earlier run left
// running. The workspace recorded in the session becomes the running session's
// workspace.
//
// The target is read and checked before anything is given up, and session_adopt
// holds the running session's claim until the candidate is settled, so a refusal
// leaves the front-end working in the session it already had. Nothing is released
// in between, so another process cannot take the running session during the
// attempt.
session_switch :: proc(app: ^App, target: session.Session_Id) -> bool {
	setup := &app.setup

	header, load_err := session.session_load(&setup.store, target, setup.alloc)
	if load_err != nil {
		local := load_err
		snap_append(app, .Error, fmt.tprintf("cannot read the session: %s", session.error_detail(&local)))
		return false
	}
	defer session.session_destroy(&header)
	if !os.is_dir(header.workspace) {
		snap_append(app, .Error, fmt.tprintf("the session's directory is gone: %s", header.workspace))
		return false
	}

	adoption, message, adopted := session_adopt(setup, target)
	if !adopted {
		defer delete(message, setup.alloc)
		snap_append(app, .Error, message)
		return false
	}
	defer adoption_destroy(&adoption, setup.alloc)

	session_activate(app, &adoption)
	if adoption.recovery.recovered_calls > 0 {
		snap_append(app, .Notice, fmt.tprintf("%d tool result(s) in this session record an outcome the harness never saw", adoption.recovery.recovered_calls))
	}
	if adoption.recovery.unexecuted_calls > 0 {
		snap_append(app, .Notice, fmt.tprintf("%d tool call(s) in this session never ran", adoption.recovery.unexecuted_calls))
	}

	// A conversation has to be configured before it can run: the new chat starts
	// with no model, so the session's recorded one is applied, with the selection
	// already in effect as the fallback. A session whose model is gone from the
	// catalog stays open on the current selection, and can still be changed from
	// the model menu.
	if adoption.header.provider != "" && adoption.header.model != "" && apply_selection(app, adoption.header.provider, adoption.header.model, "") {
		return true
	}
	if setup.provider_id != "" && setup.model_id != "" {
		apply_selection(app, setup.provider_id, setup.model_id, "")
	}
	return true
}

// session_replay shows the tail of a resumed conversation. The store keeps every
// entry; this is the part a person needs to recognise where they left off.
session_replay :: proc(app: ^App, chat: ^agent.Chat_Session) {
	replayed, replay_err := session.context_load(chat.store, chat.id, app.run.alloc)
	if replay_err != nil {
		// Resuming a session and showing nothing would look like an empty
		// conversation rather than a failure to read one.
		local := replay_err
		snap_append(app, .Error, fmt.tprintf("cannot read the session history: %s", session.error_detail(&local)))
		return
	}
	defer session.context_destroy(&replayed, app.run.alloc)

	if replayed.summary != "" {
		snap_append(app, .Notice, "(earlier turns are summarized)")
	}
	for &entry in replayed.entries {
		#partial switch payload in entry.payload {
		case session.User_Entry:
			if payload.origin == .Harness {
				snap_append(app, .Notice, payload.text)
			} else {
				snap_append(app, .User, payload.text)
			}
		case session.Assistant_Entry:
			snap_append(app, .Assistant, payload.text)
		case session.Tool_Result_Entry:
			snap_append(app, .Tool, payload.content)
		}
	}
}

// snapshot_clear drops the rendered transcript. The history lives in the store;
// this is only what the screen shows.
snapshot_clear :: proc(app: ^App) {
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	for &entry in app.run.snap.entries {
		if entry.text != nil { delete(entry.text) }
	}
	clear(&app.run.snap.entries)
	app.run.snap.generation += 1
}

// menu_begin publishes a freshly built list. Every open procedure builds its
// choices completely and then hands them over, so a half-built menu is never
// visible.

refresh_status :: proc(app: ^App) {
	running := &app.setup.session
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	status := &app.run.snap.status
	// The estimate is the one the agent measured when it built the last request;
	// the main thread never reads the store, so it cannot compute one itself.
	status.est_input = running.last_estimate
	status.context_window = running.capacity.window
	// The footer shows the session's token-weighted hit rate beside the
	// estimate: the estimate bounds the request being built, the hit rate says
	// how much of the finished session the provider read from its cache. Both
	// come from the worker's own records, never from a second thread's query.
	totals, totals_err := session.cache_totals(running.store, running.id)
	if totals_err != nil {
		status.session_input_present = false
		status.session_cache_present = false
		status.session_hit_measured = false
	} else {
		if totals.input_requests > 0 {
			status.session_input = totals.input
			status.session_input_present = true
		} else {
			status.session_input_present = false
		}
		if totals.cache_read_requests > 0 {
			status.session_cache_read = totals.cache_read
			status.session_cache_present = true
		} else {
			status.session_cache_present = false
		}
		rate, measured := session.cache_hit_rate(totals)
		status.session_hit_rate = rate
		status.session_hit_measured = measured
	}
	if status.cwd != running.workspace {
		delete(status.cwd, app.run.alloc)
		status.cwd = strings.clone(running.workspace, app.run.alloc)
	}
	status.running = running.state != .Idle
	if status.provider_id != app.setup.provider_id {
		delete(status.provider_id, app.run.alloc)
		status.provider_id = strings.clone(app.setup.provider_id, app.run.alloc)
	}
	if status.model_id != app.setup.model_id {
		delete(status.model_id, app.run.alloc)
		status.model_id = strings.clone(app.setup.model_id, app.run.alloc)
	}
	if status.effort != running.effort {
		delete(status.effort, app.run.alloc)
		status.effort = strings.clone(running.effort, app.run.alloc)
	}
	app.run.snap.generation += 1
}

// --- hooks into the snapshot ----------------------------------------------

set_running :: proc(app: ^App, running: bool) {
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	app.run.snap.status.running = running
	app.run.snap.generation += 1
}

runtime_busy :: proc(app: ^App) -> bool {
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	return app.run.snap.status.running
}

// runtime_model_selected reports whether a model is in effect, under the lock the
// worker publishes the status with.
runtime_model_selected :: proc(app: ^App) -> bool {
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	return app.run.snap.status.model_id != ""
}

// runtime_selection_provider copies the provider the runtime currently runs,
// under the lock the worker publishes it with. The copy is temp-allocated, which
// is the lifetime of one keypress on the front-end.
runtime_selection_provider :: proc(app: ^App) -> string {
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	return strings.clone(app.run.snap.status.provider_id, context.temp_allocator)
}

generation_changed :: proc(app: ^App) -> bool {
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	if app.run.snap.generation != app.generation_seen {
		app.generation_seen = app.run.snap.generation
		return true
	}
	return false
}

snap_append :: proc(app: ^App, kind: Entry_Kind, text: string) {
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	snap_append_locked(app, kind, text)
}

// snap_append_locked appends under a held runtime mutex.
snap_append_locked :: proc(app: ^App, kind: Entry_Kind, text: string) {
	entry := Entry {
		kind = kind,
		text = make([dynamic]u8, 0, 0, app.run.alloc),
	}
	if len(text) > 0 {
		append(&entry.text, ..transmute([]byte)text)
	}
	append(&app.run.snap.entries, entry)
	app.run.snap.generation += 1
}

// --- observer -------------------------------------------------------------

run_observer :: proc(app: ^App) -> agent.Chat_Observer {
	return {
		user_data = app,
		assistant_begin = obs_assistant_begin,
		assistant_text = obs_assistant_text,
		assistant_end = obs_assistant_end,
		user_text = obs_user_text,
		tool_result = obs_tool_result,
		message = obs_message,
		usage = obs_usage,
	}
}

obs_assistant_begin :: proc(user_data: rawptr) {
	app := cast(^App)user_data
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	append(&app.run.snap.entries, Entry{kind = .Assistant, text = make([dynamic]u8, 0, 0, app.run.alloc)})
	app.run.snap.generation += 1
}

obs_assistant_text :: proc(user_data: rawptr, text: string) {
	app := cast(^App)user_data
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	count := len(app.run.snap.entries)
	if count > 0 {
		last := &app.run.snap.entries[count - 1]
		if last.kind == .Assistant && !last.complete {
			append(&last.text, ..transmute([]byte)text)
			app.run.snap.generation += 1
			return
		}
	}
	entry := Entry {
		kind = .Assistant,
		text = make([dynamic]u8, 0, 0, app.run.alloc),
	}
	append(&entry.text, ..transmute([]byte)text)
	append(&app.run.snap.entries, entry)
	app.run.snap.generation += 1
}

obs_assistant_end :: proc(user_data: rawptr) {
	app := cast(^App)user_data
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	count := len(app.run.snap.entries)
	if count > 0 {
		app.run.snap.entries[count - 1].complete = true
	}
	app.run.snap.generation += 1
}

obs_user_text :: proc(user_data: rawptr, text: string) {
	snap_append(cast(^App)user_data, .User, text)
}

obs_tool_result :: proc(user_data: rawptr, name: string, result: ^agent.Tool_Result) {
	app := cast(^App)user_data
	snap_append(app, .Tool, fmt.tprintf("tool %s: %s", name, tool_display_summary(result)))
}

obs_message :: proc(user_data: rawptr, kind: agent.Chat_Message_Kind, text: string) {
	app := cast(^App)user_data
	entry_kind := Entry_Kind.Notice
	switch kind {
	case .Notice:
		entry_kind = .Notice
	case .Warning:
		entry_kind = .Warning
	case .Error:
		entry_kind = .Error
	}
	snap_append(app, entry_kind, text)
}

obs_usage :: proc(user_data: rawptr, operation: u64, usage: ai.Provider_Usage_Event) {
	app := cast(^App)user_data
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	status := &app.run.snap.status
	if usage.Input_Tokens_Present {
		status.last_input = usage.Input_Tokens
		status.last_input_present = true
	}
	// Cost accumulation lands here once the catalog carries pricing. Session
	// totals are recomputed at work boundaries, not per stream event, so this
	// only records the latest request's size for the footer beside them.
	_ = operation
	app.run.snap.generation += 1
}
