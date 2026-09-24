#+build linux
package main

import "core:fmt"
import "core:mem"
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
// the context depends on it. This is the front-end's explicit policy for the
// period before an owner wake is connected to the work mailbox; it is not a
// model-request deadline.
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
	return agent.chat_compact_idle_service(&app.setup.session, observer, app.run.connection)
}

// work_destroy releases the strings a queued command owns.
work_destroy :: proc(app: ^App, work: Work) {
	if work.text != "" {
		delete(work.text, app.run.alloc)
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
	// Catalog metadata can arrive while the worker is idle or while a turn is in
	// progress. Apply it before every command; request boundaries do the same for
	// multi-request turns.
	catalog_selection_sync(app)
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
		switch accepted {
		case .Accepted:
		case .Storage_Failed:
			snap_append(app, .Error, agent.chat_session_last_error(&app.setup.session))
			return
		case .Worker_Escaped:
			snap_append(app, .Error, agent.CHAT_WORKER_ESCAPED_NOTICE)
			stop_runtime(app)
			return
		case .Busy:
			snap_append(app, .Warning, "chat is busy; input dropped")
			return
		}
		snap_append(app, .User, work.text)
		set_running(app, true)
		// Accepting the prompt reset the cancellation token for the new turn, so a
		// stop that arrived while the prompt was being recorded has to be re-issued
		// here: otherwise shutdown would wait out a whole model request.
		if runtime_stopping(app) { agent.chat_cancel_request() }
		steer := agent.Steer_Context {
			queue      = &app.run.steer,
			apply      = app_steer_apply,
			apply_data = app,
		}
		// How the turn ended reaches the front-end through the observer, which reports the
		// terminal status, so the worker has nothing of its own to do with the return.
		agent.chat_run_turn_steered(&app.setup.session, app.run.connection, agent.chat_retry_policy_default(), observer, &steer)
		// A tool worker that ignored its stop still borrows the session's workspace, registry
		// generation, and backends. Nothing else may run in this process: the runtime stops,
		// and teardown leaves what that worker can reach to process exit.
		if agent.chat_session_worker_escaped(&app.setup.session) {
			snap_append(app, .Error, agent.CHAT_WORKER_ESCAPED_NOTICE)
			stop_runtime(app)
			return
		}
	// Steering lines left queued here arrived after the turn recorded what it was sent,
	// so they are not part of its history. Its end is still the caller's to report, and
	// the front-end returns them to the prompt when it sees the runtime stop running.
	case .Compact:
		set_running(app, true)
		if runtime_stopping(app) { agent.chat_cancel_request() }
		// Compaction reports why the model side stopped, but a durable write that
		// failed only latches the session: the reason the user needs is there.
		if !agent.chat_command_compact(&app.setup.session, observer, app.run.connection) && agent.chat_session_storage_failed(&app.setup.session) {
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
	case .Catalog:
	// catalog_selection_sync above consumed the published revision. This item
	// exists only to wake an idle worker.
	case .Model:
		apply_pending_selection(app)
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
	target, opened := session_open_target(setup, {kind = .New}, setup.workspace, stderr_writer())
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

	// The name of each call, by the seq its result names.
	call_names := make(map[session.Seq]string, len(replayed.entries), app.run.alloc)
	defer delete(call_names)

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
		case session.Tool_Call_Entry:
			// A result names its call, not the tool, so the call's name is kept
			// for the result that follows it.
			call_names[entry.seq] = payload.name
		case session.Tool_Result_Entry:
			name := ""
			if related, present := entry.related_seq.?; present { name = call_names[related] }
			snap_append_tool(app, name, payload.content, session.tool_outcome_name(payload.outcome), payload.outcome)
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
	app.run.snap.entries_bytes = 0
	app.run.snap.transcript_trimmed = false
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
		status.session_hit_partial = false
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
		status.session_hit_partial = false
		if share, coverage_measured := session.cache_coverage(totals); coverage_measured && share < 1 {
			status.session_hit_partial = true
		}
	}
	if status.cwd != running.workspace {
		delete(status.cwd, app.run.alloc)
		status.cwd = strings.clone(running.workspace, app.run.alloc)
	}
	was_running := status.running
	status.running = running.state != .Idle
	if status.running && !was_running {
		status.working_since = time.tick_now()
	}
	// A retry belongs to the turn that scheduled it. A turn that is no longer running has
	// none, so the working indicator cannot keep showing the attempt it waited for.
	if !status.running { status.retry_present = false }
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
	status := &app.run.snap.status
	if running && !status.running {
		status.working_since = time.tick_now()
	}
	status.running = running
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

// snap_entry_make builds one transcript entry: the allocator its text belongs to,
// a fresh identity, and the display text when there is any.
snap_entry_make :: proc(app: ^App, kind: Entry_Kind, text: string) -> Entry {
	entry := Entry{kind = kind}
	entry.text.allocator = app.run.alloc
	app.run.snap.next_entry_id += 1
	entry.id = app.run.snap.next_entry_id
	snap_entry_set_text(app, &entry, text)
	return entry
}

// snap_entry_set_text writes text that arrived in one piece. The buffer is sized for
// the text exactly, because a buffer grown to reach it holds up to twice the text and
// the transcript budget counts the capacity an entry holds.
snap_entry_set_text :: proc(app: ^App, entry: ^Entry, text: string) {
	if len(text) == 0 { return }
	if resize_error := resize(&entry.text, len(text)); resize_error != nil {
		snap_report_dropped(app, resize_error)
		return
	}
	copy(entry.text[:], text)
	snap_entry_account(entry)
}

// snap_entry_account charges one entry for everything it holds: its own slot in
// the transcript and the text buffer behind it. One budget then covers both costs,
// so a very long run of very short lines is bounded by the same number as a short
// run of very long ones.
snap_entry_account :: proc(entry: ^Entry) {
	entry.bytes = size_of(Entry) + cap(entry.text)
}

// snap_entry_append_text adds display text to one entry. A buffer that cannot
// hold it is reported once rather than silently truncating the line.
snap_entry_append_text :: proc(app: ^App, entry: ^Entry, text: string) {
	if len(text) > 0 {
		if _, append_error := append(&entry.text, ..transmute([]byte)text); append_error != nil {
			snap_report_dropped(app, append_error)
		}
	}
	snap_entry_account(entry)
}

// snap_report_dropped says once that the transcript could not hold a line. The
// line's record is already in the store, so only its display is lost, and the
// run continues without a screen that quietly disagrees with what it kept.
snap_report_dropped :: proc(app: ^App, alloc_error: mem.Allocator_Error) {
	if app.run.snap.transcript_failed { return }
	app.run.snap.transcript_failed = true
	detail := fmt.tprintf("%v", alloc_error)
	fields := [1]agent.Log_Field{{key = "allocation_error", value = detail}}
	agent.log_emit(agent.Log_Record{level = .Error, category = .Runtime, event = "ui.transcript_line_dropped", fields = fields[:]})
}

// snap_push_locked appends one entry and trims the transcript to its budget.
snap_push_locked :: proc(app: ^App, entry: Entry) {
	app.run.snap.entries_bytes += entry.bytes
	if _, append_error := append(&app.run.snap.entries, entry); append_error != nil {
		app.run.snap.entries_bytes -= entry.bytes
		// Nothing holds the buffer now: the array did not take the entry. A
		// dynamic array releases through its own allocator, which the entry's text
		// was given when it was made.
		delete(entry.text)
		snap_report_dropped(app, append_error)
		return
	}
	app.run.snap.generation += 1
	snap_trim_locked(app)
}

// snap_trim_locked drops the oldest entries, and their text, while the transcript
// passes its budget, and says once that it did. The newest entry is always kept:
// one entry larger than the budget is still the newest thing said.
snap_trim_locked :: proc(app: ^App) {
	was_trimmed := app.run.snap.transcript_trimmed
	for len(app.run.snap.entries) > 1 && app.run.snap.entries_bytes > TRANSCRIPT_MAX_BYTES {
		dropped := app.run.snap.entries[0]
		app.run.snap.entries_bytes -= dropped.bytes
		ordered_remove(&app.run.snap.entries, 0)
		delete(dropped.text)
		app.run.snap.transcript_trimmed = true
	}
	if app.run.snap.transcript_trimmed && !was_trimmed {
		snap_push_locked(app, snap_entry_make(app, .Notice, TRANSCRIPT_TRIMMED_NOTICE))
	}
}

// snap_append_locked appends under a held runtime mutex.
snap_append_locked :: proc(app: ^App, kind: Entry_Kind, text: string) {
	snap_push_locked(app, snap_entry_make(app, kind, text))
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
		request_prepared = obs_request_prepared,
		request_finished = obs_request_finished,
		retry_scheduled = obs_retry_scheduled,
	}
}

// obs_request_prepared and obs_request_finished both move what the status describes: the
// first knows how large the request about to be sent is, and the second has the provider's
// own report of the one that just finished. Refreshing at both is what keeps the footer
// live while a turn runs, instead of only once the whole prompt is done. Neither runs
// inside a store transaction, because a request's record is committed before this is
// called.
obs_request_prepared :: proc(user_data: rawptr) {
	app := cast(^App)user_data
	// The send the front-end was waiting for is this one, so whatever it showed about the
	// last retry is over.
	clear_retry(app)
	refresh_status(app)
}

// obs_retry_scheduled reports a scheduled retry twice: the transcript keeps the sentence,
// and the status keeps the attempt the turn is waiting for, which is what the working
// indicator reads.
obs_retry_scheduled :: proc(user_data: rawptr, event: agent.Chat_Retry_Event) {
	app := cast(^App)user_data
	snap_append(app, .Notice, retry_display_text(event))
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	status := &app.run.snap.status
	status.retry_present = true
	status.retry_next = event.next_attempt
	status.retry_max = event.max_attempts
	status.retry_due = time.tick_add(time.tick_now(), event.delay)
	app.run.snap.generation += 1
}

// clear_retry forgets a retry the front-end was showing.
clear_retry :: proc(app: ^App) {
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	if !app.run.snap.status.retry_present { return }
	app.run.snap.status.retry_present = false
	app.run.snap.generation += 1
}

obs_request_finished :: proc(user_data: rawptr) {
	refresh_status(cast(^App)user_data)
}

obs_assistant_begin :: proc(user_data: rawptr) {
	app := cast(^App)user_data
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	snap_push_locked(app, snap_entry_make(app, .Assistant, ""))
}

obs_assistant_text :: proc(user_data: rawptr, text: string) {
	app := cast(^App)user_data
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	count := len(app.run.snap.entries)
	if count > 0 {
		last := &app.run.snap.entries[count - 1]
		if last.kind == .Assistant && !last.complete {
			before := last.bytes
			snap_entry_append_text(app, last, text)
			app.run.snap.entries_bytes += last.bytes - before
			snap_trim_locked(app)
			app.run.snap.generation += 1
			return
		}
	}
	snap_push_locked(app, snap_entry_make(app, .Assistant, text))
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
	snap_append_tool(app, name, result.content, tool_display_summary(result), result.outcome)
}

// snap_append_tool records one tool box: the call's name, the preview of its
// result, and the outcome its border is colored by. The live turn and the
// replayed session both arrive here, so the box is the same either way.
snap_append_tool :: proc(app: ^App, name, content, fallback: string, outcome: session.Tool_Outcome) {
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	entry := snap_entry_make(app, .Tool, tool_entry_text(name, content, fallback))
	entry.tool_outcome = outcome
	snap_push_locked(app, entry)
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
