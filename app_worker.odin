#+build linux
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"

import "nabla:agent"
import "nabla:agent/journal"
import "nabla:ai"
import input "nabla:input"

// --- worker ---------------------------------------------------------------

run_worker :: proc(thread_handle: ^thread.Thread) {
	app := cast(^App)thread_handle.data
	defer sync.one_shot_event_signal(&app.run.worker_done)
	// A thread started without init_context gets the default context, not the one
	// the creating scope modified, so the run's allocator is installed here. Leaving
	// init_context unset is what keeps the thread library managing this thread's
	// temporary allocator.
	context.allocator = app.setup.alloc
	observer := run_observer(app)
	// The session list the /resume menu offers is built here, because only the
	// worker touches the store.
	session_refresh_rows(app)
	for {
		seen := agent.owner_wake_seen()
		if !runtime_stopping(app) { app_compact_observe(app, observer) }
		work, ok := chan.try_recv(app.run.work)
		if !ok {
			// A stop that arrived with nothing queued leaves through the drain loop
			// below, so shutdown never waits on a compaction to finish.
			if runtime_stopping(app) { break }
			// The queue is closed and empty: the front-end is gone.
			if chan.is_closed(app.run.work) { return }
			// A session this process runs and nobody had prompted has a lock file only
			// once its first prompt created it, so the watch follows the session here.
			if watch_error := app_watch_sync(&app.setup); watch_error != nil {
				snap_append(app, .Warning, fmt.tprintf("the session cannot be watched, so other processes' changes are not shown: %v", watch_error))
			}
			catalog_selection_sync(app)
			if app_selection_service(app) { refresh_status(app) }
			// A follower shows what the runner commits and claims the session when the
			// runner's claim drops. It runs no turn, so the rest of the idle work is not its.
			if app_following(app) {
				changed := app_follow_service(app, observer)
				if changed { refresh_status(app) }
				free_all(context.temp_allocator)
				if !changed {
					deadline: Maybe(time.Tick)
					if app.setup.follow_input_busy { deadline = journal.flush_deadline(app.setup.store) }
					agent.owner_wake_wait(seen, deadline)
				}
				continue
			}
			// A background subagent's report, or a line another process sent, that arrived
			// while idle starts a turn of its own.
			if app_agent_report_turn(app, observer) {
				refresh_status(app)
				free_all(context.temp_allocator)
				continue
			}
			// An outstanding compaction is serviced while idle, so a finished summary does
			// not wait for the next prompt. Work senders signal the same wake.
			// While subagents run, the worker waits on the wake instead of the queue, because
			// their reports arrive through the wake.
			agents_pending := app.setup.session.store != nil && agent.chat_agents_pending(&app.setup.session)
			if app_compaction_pending(app) || app.run.pending_target != nil || agents_pending {
				if app_compaction_tick(app, observer) { refresh_status(app) }
				if app_selection_service(app) { refresh_status(app) }
				free_all(context.temp_allocator)
				agent.owner_wake_wait(seen, agent.chat_compact_deadline(&app.setup.session))
				continue
			}
			// Work senders, the session watch, and teardown all signal the owner wake.
			free_all(context.temp_allocator)
			agent.owner_wake_wait(seen, nil)
			continue
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

// app_compaction_pending reports whether the open session has compaction work to
// look at. A session that is not open has no control to poll, and its zero state
// is idle.
@(require_results)
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

// work_send queues one command for the worker without blocking and wakes it. False means
// the queue is full or closed, and the caller still owns the item.
@(require_results)
work_send :: proc(app: ^App, item: Work) -> bool {
	if !chan.try_send(app.run.work, item) { return false }
	agent.owner_wake_signal()
	return true
}

// work_destroy releases the strings a queued command owns.
work_destroy :: proc(app: ^App, work: Work) {
	if work.text != "" {
		delete(work.text, app.run.alloc)
	}
}

// Listed_Session is one row of the /resume menu before it is copied into the snapshot: a
// main session, or a subagent session under the one that started it. The summary and the name
// are borrowed.
Listed_Session :: struct {
	summary: ^journal.Session_Summary,
	name:    string, // the child's name from its parent's subagent.started; "" for a main session
	child:   bool,
}

// session_listing orders sessions for the /resume menu: each main session, newest activity
// first, followed by the subagent sessions it started, each with the name its parent's
// subagent.started gave it. A name that cannot be read leaves the child unnamed. The result
// and the names live in temporary memory and borrow sessions.
session_listing :: proc(store: ^journal.Journal, sessions: []journal.Session_Summary) -> []Listed_Session {
	listed := make([dynamic]Listed_Session, context.temp_allocator)
	for &entry in sessions {
		if entry.role != .Main { continue }
		append(&listed, Listed_Session{summary = &entry})
		starts: []journal.Record
		loaded := false
		for &child in sessions {
			if child.role != .Subagent || child.parent_session != entry.id { continue }
			if !loaded {
				loaded = true
				read_error: journal.Error
				starts, _, read_error = journal.read_records(store, {session = entry.id, kinds = {.Subagent_Started}}, 0, 0, context.temp_allocator)
				if read_error != nil { starts = nil }
			}
			name := ""
			for start in starts {
				if start.subagent != child.id { continue }
				started: journal.Subagent_Started
				if journal.payload_decode(start.data, &started, context.temp_allocator) == nil { name = started.name }
			}
			append(&listed, Listed_Session{summary = &child, name = name, child = true})
		}
	}
	return listed[:]
}

// session_row_title is the text a menu row shows for entry: a main session's title, or a
// child's name with its title. The title is owned by allocator.
session_row_title :: proc(entry: Listed_Session, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	title := entry.summary.title
	if !entry.child { return strings.clone(title, allocator) }
	name := entry.name if entry.name != "" else "subagent"
	if title == "" { return strings.clone(name, allocator) }
	return strings.concatenate({name, ": ", title}, allocator)
}

// session_refresh_rows rebuilds the list the /resume menu shows. Only the worker
// calls it, so the store is never read from two threads.
session_refresh_rows :: proc(app: ^App) {
	if app.setup.session.store == nil { return }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sessions, list_error := journal.list_sessions(app.setup.store, {workspace = app.setup.workspace}, app.run.alloc)
	if list_error != nil { return }
	defer journal.session_summaries_destroy(sessions, app.run.alloc)
	listed := session_listing(app.setup.store, sessions)

	sync.mutex_guard(&app.run.mu)
	for &row in app.run.snap.sessions {
		delete(row.title, app.run.alloc)
	}
	clear(&app.run.snap.sessions)
	for entry in listed {
		title, title_error := session_row_title(entry, app.run.alloc)
		if title_error != nil {
			// A row without its title would read as a session that has none, so
			// the row is left out rather than mislabeled.
			snap_report_dropped_locked(app)
			continue
		}
		if _, append_error := append(&app.run.snap.sessions, Session_Row{id = entry.summary.id, title = title, child = entry.child}); append_error != nil {
			delete(title, app.run.alloc)
			snap_report_dropped_locked(app)
			break
		}
	}
	// The running session is published with the list, so the menu can open on it
	// without reading the running session from another thread.
	app.run.snap.active_session = app.setup.session.session
	snap_publish_locked(app)
}

run_work :: proc(app: ^App, work: Work, observer: agent.Chat_Observer) {
	// A stop that arrived while this item was queued abandons it: shutdown does
	// not start new work.
	if runtime_stopping(app) { return }
	// Catalog metadata can arrive while the worker is idle or while a turn is in
	// progress. Apply it before every command; request boundaries do the same for
	// multi-request turns.
	catalog_selection_sync(app)
	_ = app_selection_service(app)
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
		if app_following(app) {
			app_follow_submit(app, work.text, observer)
			break
		}
		// Tools are refreshed between turns, while the session is idle. Both prompt
		// paths refresh, so an interactive turn and a headless one see the same tools.
		if warning := app_tools_refresh(app); warning != "" { snap_append(app, .Warning, warning) }
		accepted := agent.chat_session_accept_user(&app.setup.session, work.text, observer)
		switch accepted {
		case .Accepted:
		case .Storage_Failed:
			snap_append(app, .Error, agent.chat_session_last_error(&app.setup.session))
			return
		case .Busy:
			snap_append(app, .Warning, "chat is busy; input dropped")
			return
		}
		refresh_status(app)
		run_accepted_turn(app, observer)
	// Steering lines left queued here arrived after the turn recorded what it was sent,
	// so they are not part of its history. Its end is still the caller's to report, and
	// the front-end returns them to the prompt when it sees the runtime stop running.
	case .Compact:
		app_command_compact(app, observer)
	case .Status:
		agent.chat_notice_status(&app.setup.session, observer, time.to_unix_nanoseconds(time.now()) / i64(time.Millisecond))
	case .Effort:
		if app_following(app) {
			follower_refuse(app, "changing the effort")
			break
		}
		cleared := work.text == "" || work.text == "default"
		level := "" if cleared else work.text
		applied := agent.chat_session_set_effort(&app.setup.session, level)
		if applied {
			snap_append(app, .Notice, agent.chat_effort_change_note(level))
		} else {
			snap_append(app, .Notice, fmt.tprintf("effort %s is not allowed for this model", work.text))
		}
		// The effort is part of the persisted selection, so a change rewrites it.
		if applied {
			record_error := selection_record(app.setup.store, app.setup.provider_id, app.setup.model_id, app.setup.session.effort)
			if record_error != nil {
				detail := journal.error_text(record_error, context.temp_allocator)
				snap_append(app, .Error, fmt.tprintf("the selection could not be recorded: %s", detail))
			} else if session_record_error := agent.chat_selection_record(
				&app.setup.session,
				app.setup.api,
				app.setup.provider_id,
				app.setup.model_id,
				app.setup.session.effort,
			); session_record_error != nil {
				app.setup.session.storage_failed = true
				detail := journal.error_text(session_record_error, context.temp_allocator)
				snap_append(app, .Error, fmt.tprintf("the session selection could not be recorded: %s", detail))
			}
		}
	case .Catalog:
	// catalog_selection_sync above consumed the published revision. This item
	// exists only to wake an idle worker.
	case .Model:
		_ = app_selection_service(app)
	case .New_Session:
		rows_dirty = true
		// The new session runs the same selection; only the conversation is new. The
		// selection is copied first because the switch replaces it, and a session
		// opened without one could not run a turn.
		provider, provider_error := strings.clone(app.setup.provider_id, app.run.alloc)
		model, model_error := strings.clone(app.setup.model_id, app.run.alloc)
		if provider_error != nil || model_error != nil {
			delete(provider, app.run.alloc)
			delete(model, app.run.alloc)
			snap_append(app, .Error, "a new session could not be started: its model could not be allocated")
			break
		}
		defer delete(provider, app.run.alloc)
		defer delete(model, app.run.alloc)
		if session_switch(app, Start_Fresh{}) {
			snapshot_clear(app)
			snap_append(app, .Notice, "started a new session")
			// The new session keeps the same selection; a failure is already in the
			// snapshot, and the session stays open without a model.
			if provider != "" && model != "" { _ = selection_apply_direct(app, provider, model, "", true) }
		}
	case .Resume_Session:
		rows_dirty = true
		session_resume(app, work.text)
	}
	if rows_dirty { session_refresh_rows(app) }
	refresh_status(app)
}

run_accepted_turn :: proc(app: ^App, observer: agent.Chat_Observer) {
	app.setup.session.catalog = app_catalog_ref(app)
	// A stop the front-end asked for is for a running turn, and none runs until the flag
	// below is set, so an older request is cleared first. Shutdown that already began
	// stops this turn too, rather than waiting out a whole model request.
	agent.turn_control_clear(&app.run.control)
	set_running(app, true)
	if runtime_stopping(app) { agent.turn_control_stop(&app.run.control) }
	steer := agent.Steer_Context {
		queue      = &app.run.steer,
		apply      = app_steer_apply,
		observe    = app_steer_observe,
		apply_data = app,
	}
	// How the turn ended reaches the front-end through the observer, which reports the
	// terminal status, so the worker has nothing of its own to do with the return.
	_ = agent.chat_run_turn_steered(&app.setup.session, app.run.connection, agent.chat_retry_policy_default(), observer, &steer, &app.run.control)
}

app_command_compact :: proc(app: ^App, observer: agent.Chat_Observer) {
	if app_following(app) {
		follower_refuse(app, "compaction")
		return
	}
	if !agent.chat_command_compact(&app.setup.session, observer, app.run.connection) && agent.chat_session_storage_failed(&app.setup.session) {
		snap_append(app, .Error, agent.chat_session_last_error(&app.setup.session))
	}
}

app_compact_observe :: proc(app: ^App, observer: agent.Chat_Observer) {
	if runtime_stopping(app) { return }
	if !sync.atomic_exchange(&app.run.compact_pending, false) { return }
	app_command_compact(app, observer)
	refresh_status(app)
}

app_steer_observe :: proc(steer: ^agent.Steer_Context, observer: agent.Chat_Observer) {
	app_compact_observe(cast(^App)steer.apply_data, observer)
}

// app_agent_report_turn runs a turn for the oldest message a subagent sent while no turn ran,
// and reports whether there was one.
@(require_results)
app_agent_report_turn :: proc(app: ^App, observer: agent.Chat_Observer) -> bool {
	if app.setup.session.store == nil { return false }
	accepted, had_message := agent.chat_session_accept_agent_message(&app.setup.session, observer)
	if !had_message { return false }
	if accepted != .Accepted {
		snap_append(app, .Error, agent.chat_session_last_error(&app.setup.session))
		return false
	}
	run_accepted_turn(app, observer)
	return true
}

// follower_refuse says that action is refused because only the process that runs the
// session can take it. The front-end and the worker both call it.
follower_refuse :: proc(app: ^App, action: string) {
	snap_append(app, .Notice, fmt.tprintf("%s is refused: the session runs in another process", action))
}

// app_follow_submit sends a line to the process that runs the session. The line is
// accepted when its commit returns, and the poll that follows shows it. A commit that
// failed busy keeps the record pending, so it is committed again and never appended twice.
app_follow_submit :: proc(app: ^App, text: string, observer: agent.Chat_Observer) {
	setup := &app.setup
	if setup.takeover_failed && setup.takeover_retryable {
		setup.takeover_failed = false
		setup.takeover_retryable = false
	}
	_ = app_follow_flush(app)
	store := setup.store
	error := journal.append_input(store, text, .Prompt)
	if error != nil && journal.error_is_busy(error) {
		_, error = journal.commit(store)
	}
	setup.follow_input_busy = journal.error_is_busy(error)
	if error != nil {
		if setup.follow_input_busy {
			snap_append(app, .Warning, "the session database is busy; the line is pending and has not been sent")
		} else {
			snap_append(app, .Error, fmt.tprintf("the line was not sent: %s", journal.error_text(error, context.temp_allocator)))
		}
		return
	}
	_ = app_follow_poll(app, observer)
}

// app_follow_flush retries the existing batch without appending input again.
app_follow_flush :: proc(app: ^App) -> bool {
	setup := &app.setup
	if !setup.follow_input_busy { return false }
	_, error := journal.commit(setup.store)
	setup.follow_input_busy = journal.error_is_busy(error)
	if error != nil && !setup.follow_input_busy {
		snap_append(app, .Error, fmt.tprintf("pending input was not sent: %s", journal.error_text(error, context.temp_allocator)))
	}
	return error == nil
}

// app_follow_poll shows what the runner committed since the last poll and takes the size
// of its newest request for the footer. It reports whether anything moved.
app_follow_poll :: proc(app: ^App, observer: agent.Chat_Observer) -> bool {
	setup := &app.setup
	before := setup.follow
	if error := agent.follow_poll(setup.store, setup.session.session, &setup.follow, observer); error != nil {
		snap_append(app, .Error, fmt.tprintf("cannot read the session: %s", journal.error_text(error, context.temp_allocator)))
	}
	// The follower runs no request, so the estimate and window it shows are the runner's.
	setup.session.last_estimate = setup.follow.estimate
	if setup.follow.window > 0 { setup.session.capacity.window = setup.follow.window }
	return setup.follow != before
}

// app_follow_service is the follower's idle step: it tries the claim, which succeeds only
// once the runner's has dropped, and otherwise shows what the runner committed. A lock close
// raises a wake, and a claim that fails costs one syscall, so every wake tries. It reports
// whether the display or the role changed.
app_follow_service :: proc(app: ^App, observer: agent.Chat_Observer) -> bool {
	_ = app_follow_flush(app)
	setup := &app.setup
	if !setup.takeover_failed {
		_, claim_error := journal.try_claim(setup.store)
		if claim_error == nil {
			app_takeover(app, observer)
			return true
		}
		if claim_error != journal.Journal_Error.Claimed {
			setup.takeover_failed = true
			setup.takeover_retryable = journal.error_is_busy(claim_error)
			snap_append(app, .Error, fmt.tprintf("cannot take over the session: %s", journal.error_text(claim_error, context.temp_allocator)))
		}
	}
	return app_follow_poll(app, observer)
}

// app_takeover makes this process the runner of the session its store just claimed: it
// shows what the old runner committed last, runs recovery, installs the session as the
// runner through the install every open uses (the transcript on screen stays), applies the
// selection this process runs with, and delivers the lines it wrote as a follower that no
// turn has read. The post-settlement poll shows every committed line before delivery, which reports none.
app_takeover :: proc(app: ^App, observer: agent.Chat_Observer) {
	setup := &app.setup
	_ = app_follow_poll(app, observer)
	opened := Opened_Session {
		store = setup.store,
		id    = setup.session.session,
	}
	if message, settled := session_settle(&opened, setup.workspace, setup.alloc); !settled {
		// The store stays with its owner; only what settling read is released here.
		retryable := opened.settle_busy
		opened.store = nil
		opened_session_destroy(&opened, setup.alloc)
		app_takeover_abort(app, message, retryable)
		delete(message, setup.alloc)
		return
	}
	_ = app_follow_poll(app, observer)
	recovery := opened.recovery
	own_queued := opened.own_queued
	if problem := session_install(setup, &opened); problem != "" {
		app_takeover_abort(app, problem)
		return
	}
	snap_append(app, .Notice, "the session's process ended; this one runs it now")
	if recovery.calls > 0 {
		snap_append(app, .Notice, fmt.tprintf("%d tool call(s) in this session never reported a result; their results say whether they ran", recovery.calls))
	}
	// The selection this process runs with is the one it applies, and it is not recorded
	// as the user's default: the user did not choose it now.
	if setup.provider_id != "" && setup.model_id != "" {
		_ = selection_apply_direct(app, setup.provider_id, setup.model_id, "", false)
	}
	if own_queued == 0 || setup.model_id == "" { return }
	if warning := app_tools_refresh(app); warning != "" { snap_append(app, .Warning, warning) }
	switch agent.chat_session_accept_user(&setup.session, "", {}) {
	case .Accepted:
		run_accepted_turn(app, observer)
	case .Storage_Failed:
		snap_append(app, .Error, agent.chat_session_last_error(&setup.session))
	case .Busy:
	}
}

// app_takeover_abort gives the claim back when this process won it and could not use it,
// so a session is never held by a process that cannot run it, and follows again. It stops
// the claims from being retried, because the release raises a wake that would retry them.
app_takeover_abort :: proc(app: ^App, reason: string, retryable := false) {
	setup := &app.setup
	setup.takeover_failed = true
	setup.takeover_retryable = retryable
	snap_append(app, .Error, fmt.tprintf("cannot take over the session: %s; this process keeps following it", reason))
	session := setup.store.claimed
	_ = journal.release(setup.store)
	if follow_error := journal.follow(setup.store, session); follow_error != nil {
		snap_append(app, .Error, fmt.tprintf("cannot follow the session again: %s", journal.error_text(follow_error, context.temp_allocator)))
	}
}

// app_catalog_ref is the catalog subagents resolve models from, with the lock it is
// replaced under.
app_catalog_ref :: proc(app: ^App) -> agent.Catalog_Ref {
	return {catalog = &app.setup.catalog, mutex = &app.catalog_mu}
}

// session_resume switches to the session, a main session or a subagent's, a full id or an
// unambiguous prefix names, then shows the tail of its conversation. The menu always names a whole
// id; the prefix form exists for typing, and an ambiguous one is refused rather
// than guessed.
session_resume :: proc(app: ^App, reference: string) {
	if reference == "" {
		snap_append(app, .Notice, "usage: /resume <session id or prefix>")
		return
	}
	sessions, list_error := journal.list_sessions(app.setup.store, {workspace = app.setup.workspace}, app.run.alloc)
	if list_error != nil {
		detail := journal.error_text(list_error, context.temp_allocator)
		snap_append(app, .Error, fmt.tprintf("cannot list sessions: %s", detail))
		return
	}
	defer journal.session_summaries_destroy(sessions, app.run.alloc)

	matched: [journal.SESSION_ID_HEX_LENGTH]u8
	matches := 0
	for &entry in sessions {
		hex_text: [journal.SESSION_ID_HEX_LENGTH]u8
		if !strings.has_prefix(journal.session_id_to_hex(entry.id, hex_text[:]), reference) { continue }
		matched = hex_text
		matches += 1
	}
	if matches == 0 {
		snap_append(app, .Notice, fmt.tprintf("no session matches %s", reference))
		return
	}
	if matches > 1 {
		snap_append(app, .Notice, fmt.tprintf("%s matches more than one session", reference))
		return
	}
	matched_text := string(matched[:])
	if !session_switch(app, Start_Resume_Id(matched_text)) { return }
	snapshot_clear(app)
	snap_append(app, .Notice, fmt.tprintf("resumed session %s", matched_text))
	session_opened_show(app)
}

// session_switch replaces the running session with the one start names, settling
// anything an earlier run left open. The session is opened in its own journal while
// the running one stays claimed, so a refusal leaves the front-end working in the
// session it already had.
@(require_results)
session_switch :: proc(app: ^App, start: Session_Start) -> bool {
	setup := &app.setup
	opened, message, ok := session_open(setup, start, setup.workspace)
	if !ok {
		snap_append(app, .Error, message)
		delete(message, setup.alloc)
		// A refused follow may have moved the watch to the target, and the running
		// session still needs its own.
		_ = app_watch_sync(setup)
		return false
	}
	recovery := opened.recovery
	if problem := session_install(setup, &opened); problem != "" {
		snap_append(app, .Error, problem)
		_ = app_watch_sync(setup)
		return false
	}
	selection_intent_clear(app)
	if recovery.calls > 0 {
		snap_append(app, .Notice, fmt.tprintf("%d tool call(s) in this session never reported a result; their results say whether they ran", recovery.calls))
	}
	switch _ in start {
	case Start_Fresh, nil:
		return true
	case Start_Resume_Latest, Start_Resume_Id:
	}

	// A conversation has to be configured before it can run: the new chat starts with no
	// model, so the session's recorded one is applied, with the selection already in
	// effect as the fallback. A session whose model is gone from the catalog stays open on
	// the current selection. A follower runs nothing, so it keeps its own selection, which
	// is the one it would run with after a takeover.
	if !app_following(app) &&
	   setup.resumed_provider != "" &&
	   setup.resumed_model != "" &&
	   selection_apply_direct(app, setup.resumed_provider, setup.resumed_model, setup.resumed_effort, true) {
		return true
	}
	if setup.provider_id != "" && setup.model_id != "" {
		// The selection already in effect is reapplied; the snapshot carries any
		// failure.
		_ = selection_apply_direct(app, setup.provider_id, setup.model_id, "", true)
	}
	return true
}

// session_opened_show says that the session is followed and shows the lines the runner has not delivered, consuming follow_pending.
session_opened_show :: proc(app: ^App) {
	defer {
		journal.records_destroy(app.setup.follow_pending, app.setup.alloc)
		app.setup.follow_pending = nil
	}
	if app.setup.session.store.followed == {} { return }
	snap_append(app, .Notice, "the session runs in another process; this one follows it")
	for record in app.setup.follow_pending {
		if record.kind == .User_Input {
			snap_append(app, user_entry_kind(agent.user_input_origin(record)), string(record.body))
		}
	}
	session_running_calls_show(app)
}

// session_running_calls_show shows as running boxes the calls a follower found proposed and not completed in the turn it attached to,
// and the calls of their scripts. Calls with a committed completion are the window's.
session_running_calls_show :: proc(app: ^App) {
	setup := &app.setup
	if !setup.follow.working { return }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	session := setup.session.session
	started, found, started_error := journal.read_latest(setup.store, {session = session, kinds = {.Turn_Started}}, context.temp_allocator)
	if started_error != nil || !found { return }
	records, _, read_error := journal.read_records(
		setup.store,
		{session = session, kinds = {.Tool_Proposed, .Tool_Completed}},
		started.seq,
		0,
		context.temp_allocator,
	)
	if read_error != nil { return }
	completed := make(map[journal.Call_Id]journal.Record, context.temp_allocator)
	for record in records {
		if record.kind == .Tool_Completed { completed[record.call] = record }
	}
	for record in records {
		if record.kind != .Tool_Proposed || record.seq > setup.follow.last { continue }
		done, is_done := completed[record.call]
		if is_done && record.parent_call == 0 { continue }
		if record.parent_call in completed { continue }
		proposed: journal.Tool_Proposed
		if journal.payload_decode(record.data, &proposed, context.temp_allocator) != nil { continue }
		arguments := string(record.body)
		observer_tool_call(
			app,
			agent.Chat_Tool_Event {
				call = record.call,
				parent_call = record.parent_call,
				call_id = proposed.provider_id,
				name = proposed.name,
				arguments = arguments,
			},
		)
		if !is_done { continue }
		completion: journal.Tool_Completed
		if journal.payload_decode(done.data, &completion, context.temp_allocator) != nil { continue }
		outcome, _ := journal.enum_from_name(journal.TOOL_OUTCOME_NAMES, completion.outcome)
		result := agent.Tool_Result {
			outcome   = outcome,
			reason    = journal.TOOL_OUTCOME_NAMES[outcome],
			content   = string(done.body),
			allocator = context.temp_allocator,
		}
		observer_tool_result(app, record.call, record.parent_call, proposed.name, arguments, &result)
	}
}

// head_publish publishes the session shown and its committed head for the transcript window.
head_publish :: proc(app: ^App) {
	running := &app.setup.session
	session: journal.Session_Id
	head: journal.Node_Id
	if running.store != nil {
		session = running.session
		_, committed, head_error := journal.session_head(running.store, session)
		if head_error != nil { return }
		head = committed
	}
	sync.mutex_guard(&app.run.mu)
	snap := &app.run.snap
	snap.after = max(head, running.head)
	if snap.head_session == session && snap.head == head { return }
	snap.head_session, snap.head = session, head
	snap_publish_locked(app)
}

// snapshot_clear drops the rendered transcript. The history lives in the store;
// this is only what the screen shows.
snapshot_clear :: proc(app: ^App) {
	head_publish(app)
	sync.mutex_guard(&app.run.mu)
	for &entry in app.run.snap.entries {
		entry_destroy(&entry)
	}
	clear(&app.run.snap.entries)
	app.run.snap.image_bytes = 0
	codemode_pending_clear_locked(app)
	snap_publish_locked(app)
}

// menu_begin publishes a freshly built list. Every open procedure builds its
// choices completely and then hands them over, so a half-built menu is never
// visible.

refresh_status :: proc(app: ^App) {
	head_publish(app)
	running := &app.setup.session
	totals: journal.Usage_Totals
	totals_error: journal.Error = journal.Journal_Error.Not_Found
	if running.store != nil { totals, totals_error = journal.usage_totals(running.store, running.session) }
	sync.mutex_guard(&app.run.mu)
	status := &app.run.snap.status
	// The estimate is the one the agent measured when it built the last request.
	status.est_input = running.last_estimate
	status.context_window = running.capacity.window
	// The footer shows the session's token-weighted hit rate beside the estimate.
	// Keep the SQLite query outside the lock so readers can still read status.
	if totals_error != nil {
		status.session_input = nil
		status.session_cache_read = nil
		status.session_hit_measured = false
		status.session_hit_partial = false
		status.cost = nil
		status.cost_partial = false
	} else {
		if totals.requests > 0 {
			status.session_input = totals.input
		} else {
			status.session_input = nil
		}
		if totals.paired_requests > 0 {
			status.session_cache_read = totals.cache_read
		} else {
			status.session_cache_read = nil
		}
		if totals.priced_requests > 0 {
			status.cost = totals.cost
		} else {
			status.cost = nil
		}
		status.cost_partial = totals.priced_requests < totals.requests
		rate, measured := journal.cache_hit_rate(totals)
		status.session_hit_rate = rate
		status.session_hit_measured = measured
		status.session_hit_partial = false
		if share, coverage_measured := journal.cache_coverage(totals); coverage_measured && share < 1 {
			status.session_hit_partial = true
		}
	}
	snap_status_replace(app, &status.cwd, running.workspace)
	was_running := status.running
	following := app_following(app)
	status.following = following
	// A follower runs no turn of its own; it is working while the runner's turn is.
	status.running = running.state != .Idle || (following && app.setup.follow.working)
	if status.running && !was_running {
		status.working_since = time.tick_now()
	}
	// A retry belongs to the turn that scheduled it. A turn that is no longer running has
	// none, so the working indicator cannot keep showing the attempt it waited for.
	if !status.running { status.retrying = false }
	snap_status_replace(app, &status.provider_id, app.setup.provider_id)
	snap_status_replace(app, &status.model_id, app.setup.model_id)
	snap_status_replace(app, &status.effort, running.effort)
	snap_publish_locked(app)
}

// snap_status_replace replaces one owned status string with a copy of text, keeping
// the value already published when the copy fails, so the footer never loses a fact
// because memory ran out. The caller may hold the runtime mutex; nothing here takes
// it. The failure appears in the footer's display-incomplete status.
snap_status_replace :: proc(app: ^App, field: ^string, text: string) {
	if field^ == text { return }
	cloned, clone_error := strings.clone(text, app.run.alloc)
	if clone_error != nil {
		snap_report_dropped_locked(app)
		return
	}
	delete(field^, app.run.alloc)
	field^ = cloned
}

// --- hooks into the snapshot ----------------------------------------------

set_running :: proc(app: ^App, running: bool) {
	sync.mutex_guard(&app.run.mu)
	status := &app.run.snap.status
	if running && !status.running {
		status.working_since = time.tick_now()
	}
	status.running = running
	snap_publish_locked(app)
}

@(require_results)
runtime_busy :: proc(app: ^App) -> bool {
	sync.mutex_guard(&app.run.mu)
	return app.run.snap.status.running
}

// runtime_following reports whether the session runs in another process, under the lock
// the worker publishes the status with.
@(require_results)
runtime_following :: proc(app: ^App) -> bool {
	sync.mutex_guard(&app.run.mu)
	return app.run.snap.status.following
}

// runtime_model_selected reports whether a model is in effect, under the lock the
// worker publishes the status with.
@(require_results)
runtime_model_selected :: proc(app: ^App) -> bool {
	sync.mutex_guard(&app.run.mu)
	return app.run.snap.status.model_id != ""
}

// runtime_selection_provider copies the provider the runtime currently runs,
// under the lock the worker publishes it with. The copy is temp-allocated, which
// is the lifetime of one keypress on the front-end.
runtime_selection_provider :: proc(app: ^App) -> string {
	sync.mutex_guard(&app.run.mu)
	provider, provider_error := strings.clone(app.run.snap.status.provider_id, context.temp_allocator)
	if provider_error != nil {
		snap_report_dropped_locked(app)
	}
	return provider
}

// snap_publish_locked records that the snapshot changed and wakes the frame loop. The
// caller holds the runtime mutex. The wake may be written under it because adding to
// a non-blocking eventfd never waits.
snap_publish_locked :: proc(app: ^App) {
	app.run.snap.generation += 1
	run_wake(app)
}

// run_wake makes the frame loop's next poll return. It does nothing without a frame
// loop, as in a headless run.
run_wake :: proc(app: ^App) {
	if wake, armed := app.run.wake.?; armed {
		input.wake_signal(wake)
	}
}

generation_changed :: proc(app: ^App) -> bool {
	sync.mutex_guard(&app.run.mu)
	if app.run.snap.generation != app.generation_seen {
		app.generation_seen = app.run.snap.generation
		return true
	}
	return false
}

snap_append :: proc(app: ^App, kind: Entry_Kind, text: string) {
	sync.mutex_guard(&app.run.mu)
	snap_append_locked(app, kind, text)
}

// snap_entry_make builds a live entry with a fresh id that follows the current head.
snap_entry_make :: proc(app: ^App, kind: Entry_Kind, text: string) -> Entry {
	entry := Entry {
		kind = kind,
		after = app.run.snap.after,
		tool_scroll = {top = 0},
	}
	entry.text.allocator = app.run.alloc
	entry.stream.allocator = app.run.alloc
	app.run.snap.next_entry_id += 1
	entry.id = app.run.snap.next_entry_id
	snap_entry_set_text(app, &entry, text)
	return entry
}

// snap_entry_set_text writes text that arrived in one piece.
snap_entry_set_text :: proc(app: ^App, entry: ^Entry, text: string) {
	if len(text) == 0 { return }
	if resize_error := resize(&entry.text, len(text)); resize_error != nil {
		snap_report_dropped_locked(app)
		return
	}
	copy(entry.text[:], text)
	entry.revision += 1
}

// snap_entry_append_text adds display text to one entry. A buffer that cannot
// hold it is reported once rather than silently truncating the line.
snap_entry_append_text :: proc(app: ^App, entry: ^Entry, text: string) {
	if len(text) > 0 {
		entry.revision += 1
		if _, append_error := append(&entry.text, ..transmute([]byte)text); append_error != nil {
			snap_report_dropped_locked(app)
		}
	}
}

// snap_report_dropped_locked marks the display incomplete once, without allocating or
// writing to the terminal's stderr stream. The footer reads the flag under the same lock.
snap_report_dropped_locked :: proc(app: ^App) {
	if app.run.snap.display_incomplete { return }
	app.run.snap.display_incomplete = true
	snap_publish_locked(app)
}

snap_push_locked :: proc(app: ^App, entry: Entry) {
	entry := entry // a parameter is not addressable, and the refused entry is destroyed
	if _, append_error := append(&app.run.snap.entries, entry); append_error != nil {
		app.run.snap.image_bytes -= entry.image.bytes
		// Nothing holds the buffer now: the array did not take the entry. A
		// dynamic array releases through its own allocator, which the entry's text
		// was given when it was made.
		entry_destroy(&entry)
		snap_report_dropped_locked(app)
		return
	}
	snap_publish_locked(app)
}

// snap_append_locked appends under a held runtime mutex.
snap_append_locked :: proc(app: ^App, kind: Entry_Kind, text: string) {
	snap_push_locked(app, snap_entry_make(app, kind, text))
}

// --- observer -------------------------------------------------------------

run_observer :: proc(app: ^App) -> agent.Chat_Observer {
	return {
		user_data = app,
		assistant_begin = observer_assistant_begin,
		assistant_text = observer_assistant_text,
		assistant_end = observer_assistant_end,
		user_text = observer_user_text,
		tool_call = observer_tool_call,
		tool_result = observer_tool_result,
		tool_output = observer_tool_output,
		turn_finished = observer_turn_finished,
		message = observer_message,
		usage = observer_usage,
		request_prepared = observer_request_prepared,
		request_finished = observer_request_finished,
		retry_scheduled = observer_retry_scheduled,
	}
}

// observer_request_prepared and observer_request_finished both move what the status
// describes: the size of the request about to be sent, and the provider's report of the
// one that just finished. Neither runs inside a store transaction, because a request's
// record is committed before this is called.
observer_request_prepared :: proc(user_data: rawptr) {
	app := cast(^App)user_data
	// The send the front-end was waiting for is this one, so whatever it showed about the
	// last retry is over.
	clear_retry(app)
	refresh_status(app)
}

// observer_retry_scheduled reports a scheduled retry twice: the transcript keeps the sentence,
// and the status keeps the attempt the turn is waiting for, which is what the working
// indicator reads.
observer_retry_scheduled :: proc(user_data: rawptr, event: agent.Chat_Retry_Event) {
	app := cast(^App)user_data
	snap_append(app, .Notice, retry_display_text(event))
	sync.mutex_guard(&app.run.mu)
	status := &app.run.snap.status
	status.retrying = true
	snap_publish_locked(app)
}

clear_retry :: proc(app: ^App) {
	sync.mutex_guard(&app.run.mu)
	if !app.run.snap.status.retrying { return }
	app.run.snap.status.retrying = false
	snap_publish_locked(app)
}

observer_request_finished :: proc(user_data: rawptr) {
	refresh_status(cast(^App)user_data)
}

observer_assistant_begin :: proc(user_data: rawptr) {
	app := cast(^App)user_data
	sync.mutex_guard(&app.run.mu)
	if app.run.snap.status.following { return }
	snap_after_update_locked(app)
	snap_push_locked(app, snap_entry_make(app, .Assistant, ""))
}

observer_assistant_text :: proc(user_data: rawptr, text: string) {
	app := cast(^App)user_data
	sync.mutex_guard(&app.run.mu)
	if app.run.snap.status.following { return }
	count := len(app.run.snap.entries)
	if count > 0 {
		last := &app.run.snap.entries[count - 1]
		if last.kind == .Assistant && !last.complete {
			snap_entry_append_text(app, last, text)
			snap_publish_locked(app)
			return
		}
	}
	snap_push_locked(app, snap_entry_make(app, .Assistant, text))
}

observer_assistant_end :: proc(user_data: rawptr) {
	app := cast(^App)user_data
	sync.mutex_guard(&app.run.mu)
	if app.run.snap.status.following { return }
	count := len(app.run.snap.entries)
	if count > 0 {
		app.run.snap.entries[count - 1].complete = true
	}
	snap_publish_locked(app)
}

// snap_after_update_locked makes new live entries follow the in-memory head. Worker thread only.
snap_after_update_locked :: proc(app: ^App) {
	app.run.snap.after = max(app.run.snap.head, app.setup.session.head)
}

// user_entry_kind maps a user-role text's origin to its transcript kind, live and
// replayed: what another agent sent shows as its own kind of entry, text the harness
// wrote as a notice, and a prompt or steering line as the user's own.
user_entry_kind :: proc(origin: journal.User_Origin) -> (kind: Entry_Kind) {
	switch origin {
	case .Prompt, .Steering:
		kind = .User
	case .Harness:
		kind = .Notice
	case .Agent:
		kind = .Subagent
	}
	return
}

observer_user_text :: proc(user_data: rawptr, text: string, origin: journal.User_Origin) {
	snap_append(cast(^App)user_data, user_entry_kind(origin), text)
}

observer_tool_call :: proc(user_data: rawptr, event: agent.Chat_Tool_Event) {
	app := cast(^App)user_data
	display := tool_display_call(event.name, event.arguments)
	sync.mutex_guard(&app.run.mu)
	if snap_tool_entry_locked(app, event.call) != nil { return }
	snap_after_update_locked(app)
	switch {
	case event.parent_call != 0:
		inner := Codemode_Inner {
			call      = event.call,
			name      = event.name,
			arguments = event.arguments,
			running   = true,
		}
		codemode_inner_update_locked(app, event.parent_call, inner)
		text := tool_entry_text_titled(display, codemode_inner_title(event.name), "", "", .Success)
		snap_push_tool_locked(app, .Codemode, event.call, text, .Unknown, true)
	case event.name == agent.TOOL_CODEMODE_NAME:
		if event.call != 0 { codemode_pending_start_locked(app, event.call, display.code) }
		snap_push_tool_locked(app, .Codemode, event.call, codemode_entry_text(display, "", "", .Success, nil), .Unknown, true)
	case:
		snap_push_tool_locked(app, .Tool, event.call, tool_entry_text(display, "", "", .Success), .Unknown, true)
	}
}

// observer_tool_result settles the running box of the call and, for a call whose pending
// event was never observed, shows the finished box. A call with a finished box already
// is ignored: the window showed it, or its turn finished and settled the box as unknown, so
// a completion that arrives after turn_finished does not change what the box says. Call 0
// is no identity and always gets a box of its own.
observer_tool_result :: proc(user_data: rawptr, call, parent_call: journal.Call_Id, name, arguments: string, result: ^agent.Tool_Result) {
	app := cast(^App)user_data
	display := tool_display_call(name, arguments)
	summary := tool_display_summary(result)
	preview := tool_preview(result.content, summary)
	// Only the boxes of a single call draw a picture; the Code Mode outer box has none.
	image: Entry_Image
	if parent_call != 0 || name != agent.TOOL_CODEMODE_NAME { image = image_prepare(app, result.attachments) }
	defer delete(image.pixels)
	sync.mutex_guard(&app.run.mu)
	if shown := snap_tool_entry_locked(app, call); shown != nil && !shown.running { return }
	snap_after_update_locked(app)
	switch {
	case parent_call != 0:
		inner := Codemode_Inner {
			call      = call,
			name      = name,
			arguments = arguments,
			outcome   = result.outcome,
		}
		codemode_inner_update_locked(app, parent_call, inner)
		text := tool_entry_text_titled(display, codemode_inner_title(name), result.content, summary, result.outcome)
		snap_settle_tool_locked(app, .Codemode, call, text, preview, result.outcome, &image)
	case name == agent.TOOL_CODEMODE_NAME:
		pending: Codemode_Pending
		if call != 0 {
			pending = app.run.codemode_pending[call]
			delete_key(&app.run.codemode_pending, call)
		}
		text := codemode_entry_text(display, result.content, summary, result.outcome, pending.inner[:])
		snap_settle_tool_locked(app, .Codemode, call, text, preview, result.outcome)
		codemode_pending_destroy_locked(app, &pending)
	case:
		snap_settle_tool_locked(app, .Tool, call, tool_entry_text(display, result.content, summary, result.outcome), preview, result.outcome, &image)
	}
}

// STREAM_TAIL_BYTES and STREAM_TAIL_LINES bound what a running box shows of the output
// its call streams: the bytes kept of it and the last lines drawn from them. They are
// display bounds only; the call's result is whole.
STREAM_TAIL_BYTES :: 8 * 1024
STREAM_TAIL_LINES :: 20

// observer_tool_output shows the tail of the output a running call has streamed so far
// in its own box, below the text the box has while running. It runs on a tool worker
// thread, possibly after the turn finished, and takes only the runtime mutex. A chunk for a box that is not
// running, or that does not exist, arrived after the result or the end of the turn and
// is dropped. A Code Mode inner call has its own box, so its output never changes its
// script's box. The output is not journaled.
observer_tool_output :: proc(user_data: rawptr, call, parent_call: journal.Call_Id, chunk: string) {
	app := cast(^App)user_data
	if len(chunk) == 0 { return }
	// The tool worker streams for the whole run and never resets its temporary memory.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sync.mutex_guard(&app.run.mu)
	entry := snap_tool_entry_locked(app, call)
	if entry == nil || !entry.running { return }
	if len(entry.stream) == 0 { entry.stream_prefix = len(entry.text) }
	kept := chunk
	if len(kept) > STREAM_TAIL_BYTES { kept = kept[len(kept) - STREAM_TAIL_BYTES:] }
	if _, append_error := append(&entry.stream, ..transmute([]byte)kept); append_error != nil {
		snap_report_dropped_locked(app)
		return
	}
	cut := max(len(entry.stream) - STREAM_TAIL_BYTES, 0)
	for cut < len(entry.stream) && entry.stream[cut] & 0xC0 == 0x80 { cut += 1 }
	if cut > 0 {
		remaining := copy(entry.stream[:], entry.stream[cut:])
		_ = resize(&entry.stream, remaining)
	}
	base := string(entry.text[:entry.stream_prefix])
	separator := "" if len(base) == 0 || strings.has_suffix(base, "\n") else "\n"
	tail := text_last_lines(string(entry.stream[:]), STREAM_TAIL_LINES)
	text, concatenate_error := strings.concatenate({base, separator, tail}, context.temp_allocator)
	if concatenate_error != nil {
		snap_report_dropped_locked(app)
		return
	}
	if !snap_entry_rewrite_locked(app, entry, text) { return }
	entry.tool_scroll.top = nil
	snap_publish_locked(app)
}

// snap_stream_release_locked frees the streamed tail of a box that ends and charges the
// transcript's budget for the smaller entry.
snap_stream_release_locked :: proc(app: ^App, entry: ^Entry) {
	if cap(entry.stream) == 0 { return }
	delete(entry.stream)
	entry.stream = nil
	entry.stream.allocator = app.run.alloc
	entry.stream_prefix = 0
}

// snap_push_tool_locked appends a tool box under a held runtime mutex. kind is the box
// the entry draws as: a Code Mode inner call draws as .Codemode even though its text
// reads like a normal tool box. Live and follower boxes are built through it.
snap_push_tool_locked :: proc(
	app: ^App,
	kind: Entry_Kind,
	call: journal.Call_Id,
	text: string,
	outcome: journal.Tool_Outcome,
	running: bool,
	image: ^Entry_Image = nil,
	preview := "",
) {
	shown, preview_at, hidden := text, 0, 0
	if !running && preview != "" { shown, preview_at, hidden = tool_text_collapse(text, preview) }
	entry := snap_entry_make(app, kind, shown)
	entry.preview_at = preview_at
	entry.hidden_lines = hidden
	entry.call = call
	entry.tool_outcome = outcome
	entry.running = running
	snap_entry_image_set_locked(app, &entry, image)
	snap_push_locked(app, entry)
}

// snap_tool_entry_locked finds the newest box of call, running or finished, or nil. Call 0
// is no identity and finds nothing. The pointer is valid until the entries change.
snap_tool_entry_locked :: proc(app: ^App, call: journal.Call_Id) -> ^Entry {
	if call == 0 { return nil }
	#reverse for &entry in app.run.snap.entries {
		if entry.call == call { return &entry }
	}
	return nil
}

// snap_settle_tool_locked replaces the text and outcome of the running box of call and
// ends its running state, keeping only the first lines of the result preview that ends text.
// A call without a box gets a finished one. When the new text cannot be set the box stays as it was, running.
snap_settle_tool_locked :: proc(
	app: ^App,
	kind: Entry_Kind,
	call: journal.Call_Id,
	text, preview: string,
	outcome: journal.Tool_Outcome,
	image: ^Entry_Image = nil,
) {
	entry := snap_tool_entry_locked(app, call)
	if entry == nil {
		snap_push_tool_locked(app, kind, call, text, outcome, false, image, preview)
		return
	}
	kept, preview_at, hidden := tool_text_collapse(text, preview)
	if !snap_entry_rewrite_locked(app, entry, kept) { return }
	entry.preview_at = preview_at
	entry.hidden_lines = hidden
	entry.tool_outcome = outcome
	entry.running = false
	snap_stream_release_locked(app, entry)
	snap_entry_image_set_locked(app, entry, image)
	snap_publish_locked(app)
}

// snap_entry_rewrite_locked replaces the text of a live entry. When the new text cannot be
// allocated the entry keeps its old text and the result is false.
snap_entry_rewrite_locked :: proc(app: ^App, entry: ^Entry, text: string) -> bool {
	replacement, allocation_error := make([dynamic]u8, len(text), len(text), app.run.alloc)
	if allocation_error != nil {
		snap_report_dropped_locked(app)
		return false
	}
	copy(replacement[:], text)
	delete(entry.text)
	entry.text = replacement
	entry.revision += 1
	return true
}

// codemode_pending_entry_locked returns the pending record of a Code Mode call, creating
// an empty one when the call has none. It is nil after reporting a failed allocation.
codemode_pending_entry_locked :: proc(app: ^App, call: journal.Call_Id) -> ^Codemode_Pending {
	if app.run.codemode_pending == nil {
		app.run.codemode_pending = make(map[journal.Call_Id]Codemode_Pending, app.run.alloc)
	}
	_, pending, inserted, map_error := map_entry(&app.run.codemode_pending, call)
	if map_error != nil {
		snap_report_dropped_locked(app)
		return nil
	}
	if inserted { pending.inner.allocator = app.run.alloc }
	return pending
}

// codemode_pending_start_locked records the script of a Code Mode call that started.
codemode_pending_start_locked :: proc(app: ^App, call: journal.Call_Id, code: Maybe(string)) {
	script, present := code.?
	if !present { return }
	pending := codemode_pending_entry_locked(app, call)
	if pending == nil { return }
	owned, clone_error := strings.clone(script, app.run.alloc)
	if clone_error != nil {
		snap_report_dropped_locked(app)
		return
	}
	if previous, had_previous := pending.code.?; had_previous { delete(previous, app.run.alloc) }
	pending.code = owned
}

// codemode_pending_upsert_locked updates the item of an inner call in its script's list, or
// adds it, cloning its strings into the worker-owned list.
codemode_pending_upsert_locked :: proc(app: ^App, parent_call: journal.Call_Id, inner: Codemode_Inner) {
	pending := codemode_pending_entry_locked(app, parent_call)
	if pending == nil { return }
	for &existing in pending.inner {
		if existing.call != inner.call { continue }
		existing.outcome = inner.outcome
		existing.running = inner.running
		return
	}
	owned := inner
	name_error, arguments_error: mem.Allocator_Error
	owned.name, name_error = strings.clone(inner.name, app.run.alloc)
	owned.arguments, arguments_error = strings.clone(inner.arguments, app.run.alloc)
	if name_error != nil || arguments_error != nil {
		delete(owned.name, app.run.alloc)
		delete(owned.arguments, app.run.alloc)
		snap_report_dropped_locked(app)
		return
	}
	if _, append_error := append(&pending.inner, owned); append_error != nil {
		delete(owned.name, app.run.alloc)
		delete(owned.arguments, app.run.alloc)
		snap_report_dropped_locked(app)
	}
}

// codemode_inner_update_locked records the state of an inner call in its script's pending
// record and rebuilds the script's running box. A script whose box is not running (it
// settled, or was never observed) keeps its box and gets no record.
codemode_inner_update_locked :: proc(app: ^App, parent_call: journal.Call_Id, inner: Codemode_Inner) {
	outer := snap_tool_entry_locked(app, parent_call)
	if outer == nil || !outer.running { return }
	codemode_pending_upsert_locked(app, parent_call, inner)
	pending := app.run.codemode_pending[parent_call]
	display := Tool_Display_Call {
		name = agent.TOOL_CODEMODE_NAME,
		code = pending.code,
	}
	if !snap_entry_rewrite_locked(app, outer, codemode_entry_text(display, "", "", .Success, pending.inner[:])) { return }
	snap_publish_locked(app)
}

// observer_turn_finished settles every box still running: no call of the turn can report
// anymore, so each ends with an unknown outcome. A script's box also settles its running
// inner lines as unknown.
observer_turn_finished :: proc(user_data: rawptr) {
	app := cast(^App)user_data
	sync.mutex_guard(&app.run.mu)
	for &entry in app.run.snap.entries {
		if !entry.running { continue }
		entry.running = false
		entry.tool_outcome = .Unknown
		if len(entry.stream) > 0 {
			// The box settles with the text it had before the tail was added.
			_ = snap_entry_rewrite_locked(app, &entry, string(entry.text[:entry.stream_prefix]))
			snap_stream_release_locked(app, &entry)
		}
		pending, found := app.run.codemode_pending[entry.call]
		if entry.kind != .Codemode || !found { continue }
		for &inner in pending.inner {
			if inner.running {
				inner.running = false
				inner.outcome = .Unknown
			}
		}
		display := Tool_Display_Call {
			name = agent.TOOL_CODEMODE_NAME,
			code = pending.code,
		}
		fallback := journal.TOOL_OUTCOME_NAMES[.Unknown]
		// A text that cannot be set leaves the old one; the box still ends, since no
		// later event can settle it.
		_ = snap_entry_rewrite_locked(app, &entry, codemode_entry_text(display, "", fallback, .Unknown, pending.inner[:]))
	}
	snap_publish_locked(app)
	codemode_pending_clear_locked(app)
}

// codemode_pending_destroy_locked releases the strings and the list of one pending record.
codemode_pending_destroy_locked :: proc(app: ^App, pending: ^Codemode_Pending) {
	if code, present := pending.code.?; present { delete(code, app.run.alloc) }
	for inner in pending.inner {
		delete(inner.name, app.run.alloc)
		delete(inner.arguments, app.run.alloc)
	}
	delete(pending.inner)
}

// codemode_pending_clear_locked releases the records whose scripts can no longer
// report, when their turn ends or their transcript is discarded. The caller holds
// the runtime mutex.
codemode_pending_clear_locked :: proc(app: ^App) {
	for _, &pending in app.run.codemode_pending {
		codemode_pending_destroy_locked(app, &pending)
	}
	delete(app.run.codemode_pending)
	app.run.codemode_pending = nil
}

observer_message :: proc(user_data: rawptr, kind: agent.Chat_Message_Kind, text: string) {
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

observer_usage :: proc(user_data: rawptr, operation: u64, usage: ai.Provider_Usage_Event) {
	app := cast(^App)user_data
	sync.mutex_guard(&app.run.mu)
	status := &app.run.snap.status
	if usage.Input_Tokens_Present {
		status.last_input = usage.Input_Tokens
	}
	// Session totals, the priced cost among them, are recomputed at work
	// boundaries, not per stream event, so this only records the latest request's
	// size for the footer beside them.
	_ = operation
	snap_publish_locked(app)
}
