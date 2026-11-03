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
		if app_client_service(app, observer) { refresh_status(app) }
		work, ok := chan.try_recv(app.run.work)
		if !ok {
			// A stop that arrived with nothing queued leaves through the drain loop
			// below, so shutdown never waits on a compaction to finish.
			if runtime_stopping(app) { break }
			// The queue is closed and empty: the front-end is gone.
			if chan.is_closed(app.run.work) { return }
			free_all(context.temp_allocator)
			deadline: Maybe(time.Tick)
			if app.setup.follow_input_busy { deadline = journal.flush_deadline(app.setup.store) }
			agent.owner_wake_wait(seen, deadline)
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
// and the names live in temporary memory and borrow sessions. The error is an allocation failure.
@(require_results)
session_listing :: proc(store: ^journal.Journal, sessions: []journal.Session_Summary) -> (result: []Listed_Session, err: mem.Allocator_Error) {
	listed := make([dynamic]Listed_Session, context.temp_allocator) or_return
	for &entry in sessions {
		if entry.role != .Main { continue }
		_ = append(&listed, Listed_Session{summary = &entry}) or_return
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
			_ = append(&listed, Listed_Session{summary = &child, name = name, child = true}) or_return
		}
	}
	return listed[:], nil
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
	listed, listing_error := session_listing(app.setup.store, sessions)
	if listing_error != nil {
		snap_append(app, .Warning, "the session list could not be refreshed: out of memory")
		return
	}

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
	// Work that can change which sessions exist, or what they are called, marks the
	// list the /resume menu reads as needing a rebuild.
	rows_dirty := false
	switch work.kind {
	case .Prompt:
		rows_dirty = true
		if app.setup.follow_client.store == nil {
			snap_append(app, .Error, "no session is open; use /new or /resume")
			return
		}
		app_client_prompt(app, work.text, observer)
	case .Compact:
		_ = app_command_send(app, journal.Compact{})
	case .Status:
		agent.chat_notice_status(&app.setup.session, observer, time.to_unix_nanoseconds(time.now()) / i64(time.Millisecond))
	case .Effort:
		cleared := work.text == "" || work.text == "default"
		level := "" if cleared else work.text
		_ = app_command_send(app, journal.Set_Effort{level = level})
	case .Catalog:
		catalog_selection_sync(app)
	case .Model:
		pending: Maybe(Pending_Selection)
		if sync.mutex_guard(&app.run.mu) {
			pending = app.run.pending
			app.run.pending = nil
		}
		if selection, chosen := pending.?; chosen {
			_ = app_command_send(app, journal.Select_Model{provider = selection.provider, model = selection.model})
			pending_selection_clear(&pending, app.run.alloc)
		}
	case .New_Session:
		rows_dirty = true
		if session_switch(app, Start_Fresh{}) {
			snapshot_clear(app)
			snap_append(app, .Notice, "started a new session")
			session_client_ensure(app)
		}
	case .Resume_Session:
		rows_dirty = true
		if session_resume(app, work.text) { session_client_ensure(app) }
	}
	if rows_dirty { session_refresh_rows(app) }
	refresh_status(app)
}

// app_command_compact runs compaction for a session this process owns. The ACP worker
// calls it. The TUI sends Compact instead and does not run the summary.
app_command_compact :: proc(app: ^App, observer: agent.Chat_Observer) {
	if !agent.chat_command_compact(&app.setup.session, observer, app.run.connection) && agent.chat_session_storage_failed(&app.setup.session) {
		snap_append(app, .Error, agent.chat_session_last_error(&app.setup.session))
	}
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

// app_catalog_ref is the catalog subagents resolve models from, with the lock it is
// replaced under.
app_catalog_ref :: proc(app: ^App) -> agent.Catalog_Ref {
	return {catalog = &app.setup.catalog, mutex = &app.catalog_mu}
}

// session_resume switches to the session, a main session or a subagent's, a full id or an
// unambiguous prefix names, then shows the tail of its conversation. The menu always names a whole
// id; the prefix form exists for typing, and an ambiguous one is refused rather
// than guessed.
session_resume :: proc(app: ^App, reference: string) -> bool {
	if reference == "" {
		snap_append(app, .Notice, "usage: /resume <session id or prefix>")
		return false
	}
	sessions, list_error := journal.list_sessions(app.setup.store, {workspace = app.setup.workspace}, app.run.alloc)
	if list_error != nil {
		detail := journal.error_text(list_error, context.temp_allocator)
		snap_append(app, .Error, fmt.tprintf("cannot list sessions: %s", detail))
		return false
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
		return false
	}
	if matches > 1 {
		snap_append(app, .Notice, fmt.tprintf("%s matches more than one session", reference))
		return false
	}
	matched_text := string(matched[:])
	if !session_switch(app, Start_Resume_Id(matched_text)) { return false }
	snapshot_clear(app)
	snap_append(app, .Notice, fmt.tprintf("resumed session %s", matched_text))
	session_opened_show(app)
	return true
}

// session_switch replaces the running session with one this process follows. It does
// not claim the session and does not settle what an earlier run left open.
@(require_results)
session_switch :: proc(app: ^App, start: Session_Start) -> bool {
	return session_client_switch(app, start)
}

// session_opened_show shows the lines the runner has not delivered, consuming follow_pending.
session_opened_show :: proc(app: ^App) {
	defer {
		journal.records_destroy(app.setup.follow_pending, app.setup.alloc)
		app.setup.follow_pending = nil
	}
	if app.setup.session.store.followed == {} { return }
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
	// The session's own state stays Idle while another process runs it, so the follow is
	// where that process's turn shows.
	status.running = running.state != .Idle || app.setup.follow.working
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
	// Whatever follows a streaming response ends it: its text is final, and the
	// transcript may cover it as soon as the journal shows the response.
	if count := len(app.run.snap.entries); count > 0 && app.run.snap.entries[count - 1].kind == .Assistant {
		app.run.snap.entries[count - 1].complete = true
	}
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
	app := cast(^App)user_data
	if app.setup.follow_client.store != nil { app.run.steer_boundary = true }
	refresh_status(app)
}

observer_assistant_begin :: proc(user_data: rawptr) {
	app := cast(^App)user_data
	sync.mutex_guard(&app.run.mu)
	snap_after_update_locked(app)
	snap_push_locked(app, snap_entry_make(app, .Assistant, ""))
}

observer_assistant_text :: proc(user_data: rawptr, text: string) {
	app := cast(^App)user_data
	sync.mutex_guard(&app.run.mu)
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
	#reverse for &entry in app.run.snap.entries {
		if entry.kind != .Assistant { continue }
		entry.complete = true
		break
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
	case .Agent, .Job:
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
