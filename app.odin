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
import input "nabla:input"
import "nabla:term"
import "nabla:tui/widgets"

// The front-end: a worker thread owns the agent session, the main thread owns
// the terminal, and results cross through the runtime snapshot.
//
// The snapshot is a display projection only. The session keeps the real
// history, request context, effort, and usage; this package renders the
// snapshot and nothing else.

TUI_POLL_MS :: 50
WORK_CAPACITY :: 16

// Entry is one rendered conversation line group: a role or diagnostic plus
// its text, owned by the snapshot.
Entry_Kind :: enum u8 {
	User,
	Assistant,
	Tool,
	Notice,
	Warning,
	Error,
}
Entry :: struct {
	kind:            Entry_Kind,
	text:            [dynamic]u8, // owned,
	complete:        bool,
	tool_outcome:    session.Tool_Outcome,
	// tool_scroll is the first preview row a tool box shows, so a long result can
	// be read inside its own box. The box clamps it to the rows it has, which is
	// why the value is only a request until the next frame resolves it.
	tool_scroll:     int,
	// tool_scroll_max is the largest tool_scroll that window has, as the last
	// frame resolved it. Zero means the result fits and the box has nothing to
	// scroll, which is what tells the wheel the transcript behind it owns the
	// report.
	tool_scroll_max: int,
}

// Status carries the runtime facts the footer shows. provider_id and cwd
// are borrowed from the runtime (the provider id and the session workspace,
// both stable for the app's lifetime); model_id, effort, and effort_levels are
// owned display copies, replaced under the runtime mutex when they change.
// Cache numbers are the token-weighted totals over finished requests: input
// and cache reads plus the request counts each rests on, so a bucket the
// provider never reported reads as unknown rather than zero.
Status :: struct {
	provider_id:           string,
	model_id:              string, // owned,
	effort:                string, // owned,
	effort_levels:         [dynamic]string, // owned; the levels the model allows,
	cwd:                   string,
	context_window:        int,
	est_input:             int,
	last_input:            i64,
	last_input_present:    bool,
	cost:                  f64,
	cost_present:          bool,
	session_input:         i64,
	session_input_present: bool,
	session_cache_read:    i64,
	session_cache_present: bool,
	session_hit_rate:      f64,
	session_hit_measured:  bool,
	// session_hit_partial says the rate rests on part of the session's input,
	// because some finished requests reported no cache usage.
	session_hit_partial:   bool,
	running:               bool,
	// working_since spans the complete execution of one accepted prompt, across
	// every provider request and tool call, until the session returns to idle.
	working_since:         time.Tick,
	// The retry the turn is waiting for, while it waits for one. The attempt numbers come
	// from the retry the agent scheduled, and the due time is when the harness sends
	// again: a front-end showing this clears it when the next send is prepared, and the
	// worker clears it whenever the session stops running.
	retry_present:         bool,
	retry_next:            int,
	retry_max:             int,
	retry_due:             time.Tick,
}

// Snapshot is everything the renderer reads. The worker bumps generation
// after any change; the main thread redraws when it moves.
Snapshot :: struct {
	entries:        [dynamic]Entry, // owned,
	status:         Status,
	// sessions is what the /resume menu offers. Only the worker reads the store,
	// so only the worker rebuilds this.
	sessions:       [dynamic]Session_Row, // owned,
	// active_session is the session the worker is running. It travels with the row
	// list so the menu can open on it without reading the running session, which
	// the worker can replace at any moment.
	active_session: session.Session_Id, // owned,
	// setup_error is why the last selection attempt failed; the model menu shows
	// it because it has no transcript.
	setup_error:    string, // owned,
	generation:     u64,
}

Work_Kind :: enum u8 {
	Prompt,
	Compact,
	Status,
	Effort,
	// Catalog wakes the worker after a replacement catalog is published. The
	// worker reapplies the active selection so metadata that arrived after the
	// model was chosen reaches the running session and its snapshot.
	Catalog,
	// Model wakes the worker for a pending selection. The selection itself is not in the
	// item: the turn owns the session until its next request boundary, so the choice has
	// to wait in run state for whichever boundary comes first. See Pending_Selection.
	Model,
	New_Session,
	Resume_Session,
}
Work :: struct {
	kind: Work_Kind,
	text: string, // owned; prompt, effort text, or session reference, empty otherwise,
}

Work_Chan :: chan.Chan(Work)

// Choice is one line a menu offers and what choosing it means. Every string is
// owned by the menu's allocator and released by menu_destroy.
Choice :: struct {
	label:  string, // owned; the line itself
	detail: string, // owned; a second column, "" when the choice needs none
	action: Choice_Action,
}

Choice_Action :: union {
	Model_Choice,
	Effort_Choice,
	Session_Choice,
}

Model_Choice :: struct {
	provider_id: string, // owned
	model_id:    string, // owned
}

// Effort_Choice carries a level name, or "" for the provider default.
Effort_Choice :: struct {
	level: string, // owned
}

Session_Choice :: struct {
	id: session.Session_Id, // owned
}

choice_destroy :: proc(choice: ^Choice, allocator: mem.Allocator) {
	delete(choice.label, allocator)
	delete(choice.detail, allocator)
	switch &action in choice.action {
	case Model_Choice:
		delete(action.provider_id, allocator)
		delete(action.model_id, allocator)
	case Effort_Choice:
		delete(action.level, allocator)
	case Session_Choice:
		delete(string(action.id), allocator)
	}
	choice^ = {}
}

// Menu is an open choice list. The prompt is cleared while one is open: the menu
// owns the keyboard until a choice is made or it is cancelled.
Menu_Kind :: enum {
	None,
	Model,
	Effort,
	Session,
}

Menu :: struct {
	kind:     Menu_Kind,
	title:    string, // owned
	choices:  [dynamic]Choice, // owned
	cursor:   int,
	top:      int, // first choice line on screen, so the cursor stays visible
	// required marks the startup chooser: no model is selected yet, so escape
	// quits rather than returning to the prompt.
	required: bool,
}

menu_destroy :: proc(menu: ^Menu, allocator: mem.Allocator) {
	delete(menu.title, allocator)
	for &choice in menu.choices { choice_destroy(&choice, allocator) }
	delete(menu.choices)
	menu^ = {}
}

// Session_Row is one session the /resume menu can offer. The worker owns the
// list; the front-end only renders it.
Session_Row :: struct {
	id:    session.Session_Id, // owned
	title: string, // owned
}

// Pending_Selection is the selection the user asked for and the worker has not
// installed yet. The front-end only records it; apply_selection is still the only
// writer of a resolved selection, and it consumes this at the next request boundary
// so a change made while a response streams reaches the next request of that same
// turn rather than waiting for the turn to end.
Pending_Selection :: struct {
	present:  bool,
	provider: string, // owned by the runtime allocator,
	model:    string, // owned by the runtime allocator,
}

Runtime :: struct {
	mu:                       sync.Mutex, // guards snapshot and pending,
	snap:                     Snapshot,
	work:                     Work_Chan,
	worker:                   ^thread.Thread,
	connection:               ai.Provider_Connection,
	// pending is the selection change waiting for a request boundary. It is written
	// by the front-end and consumed by the worker, so it is guarded by mu like the
	// snapshot the same boundary is published into.
	pending:                  Pending_Selection,
	// steer carries lines typed while a turn is running. The front-end pushes
	// them as they arrive and the worker drains them at request boundaries, which
	// is why it is written from one thread and read from another.
	steer:                    agent.Steer_Queue,
	alloc:                    mem.Allocator,
	signals:                  agent.Chat_Interactive_Signals,
	// stopping is set once by the front-end before the worker is stopped. It is
	// separate from a turn cancellation: a cancel ends the running turn and the
	// session keeps going, while stopping ends the process. The worker checks it
	// at its own boundaries, so shutdown does not have to reach the worker
	// through the command queue.
	stopping:                 bool,
	// log_failure_reported latches the one warning that diagnostics stopped. Only
	// the worker reads and writes it, so it needs no lock of its own.
	log_failure_reported:     bool,
	// catalog_applied_revision is the newest published catalog whose metadata the
	// worker applied to the active selection. Only the worker reads and writes it.
	catalog_applied_revision: u64,
}

// stop_runtime refuses further work. The front-end is the only enqueuer, so once
// this returns no command can enter the queue, and the worker abandons what is
// already in it.
stop_runtime :: proc(app: ^App) {
	sync.atomic_store(&app.run.stopping, true)
}

runtime_stopping :: proc(app: ^App) -> bool {
	return sync.atomic_load(&app.run.stopping)
}

// Run_Setup is the resolved runtime the app starts from: the catalog, the
// selected provider/model, the connection, the session store, and the running
// session the worker drives.
// Session_Start_Kind is which session a launch opens.
Session_Start_Kind :: enum {
	// New starts a session in the launch directory. It is the zero value, so a
	// launch that asks for nothing starts fresh. The session is recorded by its
	// first prompt, so a launch that never gets one leaves no session behind.
	New,
	// Resume_Latest opens the newest session that ran and recorded work in the
	// launch directory. A session that was created and then abandoned holds no
	// work, so it is not a candidate.
	Resume_Latest,
	// Resume_Id opens one named session, wherever it ran.
	Resume_Id,
}

// Session_Start is the session a launch asks for. id is borrowed and is read
// only for .Resume_Id.
Session_Start :: struct {
	kind: Session_Start_Kind,
	id:   string,
}

// Session_Target is the session a launch resolved to, with what the launch knows
// about it before the running session exists. Every string is owned by the
// allocator session_open_target was given.
Session_Target :: struct {
	id:        session.Session_Id,
	workspace: string,
	provider:  string,
	model:     string,
}

run_setup_destroy :: proc(setup: ^Run_Setup) {
	agent.chat_session_destroy(&setup.session)
	// The tool registry borrowed the runtime's bindings, so the session goes first
	// and the MCP clients second. A runtime that was never built owns nothing.
	mcp_runtime_destroy(&setup.mcp)
	_ = run_session_release(setup)
	session.store_close(&setup.store)
	// The log outlives the session and the store deliberately: the record of the
	// launch ending is the last thing it can write. A close failure is reported
	// outside the log, because that log is what failed.
	if close_err := run_log_close(setup); close_err != nil {
		local := close_err
		fmt.eprintln("nabla: the diagnostic log could not be closed cleanly:", agent.log_error_detail(&local))
	}
	agent.catalog_destroy(&setup.catalog)
	for id in setup.configured {
		delete(id, setup.alloc)
	}
	delete(setup.configured)
	delete(setup.workspace, setup.alloc)
	delete(setup.resumed_provider, setup.alloc)
	delete(setup.resumed_model, setup.alloc)
	if setup.credential != "" { delete(setup.credential, setup.alloc) }
	if setup.provider_id != "" { delete(setup.provider_id, setup.alloc) }
	if setup.model_id != "" { delete(setup.model_id, setup.alloc) }
	setup^ = {}
}

// tui_run is the interactive entry point: resolve the catalog, open the session
// the launch asked for, open the terminal, apply the selection (explicit flags,
// then the persisted one, then the in-TUI model menu), start the worker, and
// drive the frame loop until quit.
tui_run :: proc(
	sources: []agent.Catalog_Provider_Source,
	mcp_servers: []agent.MCP_Server_Config,
	harness_options: agent.Harness_Options,
	flag_provider, flag_model: string,
	start: Session_Start,
) -> (
	ok: bool,
) {
	app := new(App)
	defer free(app)
	app.run.alloc = context.allocator
	// This run is the user's own, so its model choice is published to the frame and
	// remembered for the next launch.
	app.setup.owns_selection = true
	// The setup is filled in place: a store owns a live connection, and copying
	// one would leave two owners of it.
	app.setup.harness_options = harness_options
	// The writer is opened and the logger installed here, in the scope that owns the
	// run, so adoption, the store, and every turn below are recorded. A helper
	// cannot install it: assigning context.logger only configures the calling scope.
	app.setup.alloc = context.allocator
	context.logger = run_log_open(&app.setup)
	run_log_header(&app.setup)
	if !run_catalog(sources, mcp_servers, &app.setup, start) {
		return false
	}
	app.run.connection = app.setup.connection
	app.run.snap.entries = make([dynamic]Entry, 0, 16, app.run.alloc)
	app.run.snap.status.provider_id = strings.clone(app.setup.provider_id, app.run.alloc)
	app.run.snap.status.model_id = strings.clone(app.setup.model_id, app.run.alloc)
	// cwd is owned by the snapshot: a session switch replaces the workspace, and
	// the footer reads the status under the lock, so a borrowed workspace would
	// dangle as soon as the running session changed.
	app.run.snap.status.cwd = strings.clone(app.setup.workspace, app.run.alloc)
	app.run.snap.status.context_window = app.setup.session.capacity.window
	// The resumed conversation is shown before the first prompt, so the screen
	// matches the history the next request will be built from.
	session_replay(app, &app.setup.session)
	app.home = os.get_env("HOME", app.run.alloc)
	app.input = widgets.Input{}
	widgets.input_init(&app.input, app.run.alloc)
	app.storage = frame_storage_new(app.run.alloc)
	if app.storage == nil {
		fmt.eprintln("nabla: cannot allocate the frame budget")
		app_teardown(app)
		return false
	}
	app.run.work, _ = chan.create_buffered(Work_Chan, WORK_CAPACITY, app.run.alloc)
	app.run.steer = agent.steer_queue_init(app.run.alloc)

	terminal, open_err := term.open({alternate_screen = true, hide_cursor = true, bracketed_paste = true, mouse = true, input_mode = .Raw}, app.run.alloc)
	if open_err != nil {
		fmt.eprintln("nabla: cannot open the terminal:", open_err)
		app_teardown(app)
		return false
	}
	defer { _ = term.close(terminal) }
	app.terminal = terminal

	tty, file_err := term.session_file(terminal)
	if file_err != nil {
		fmt.eprintln("nabla: cannot access the terminal input:", file_err)
		app_teardown(app)
		return false
	}
	app.tty = tty
	input.parser_init(&app.parser)
	app.raw = make([dynamic]input.Event, 0, 16, app.run.alloc)

	if !apply_startup_selection(app, flag_provider, flag_model) {
		fmt.eprintln("nabla:", app.run.snap.setup_error)
		app_teardown(app)
		return false
	}

	// With no model selected, the chooser is the only input: escape quits rather
	// than returning to a prompt that cannot send anything.
	if app.setup.model_id == "" {
		menu_open_model(app)
		app.menu.required = true
	}

	agent.chat_interactive_arm(&app.run.signals)
	defer agent.chat_interactive_disarm(&app.run.signals)

	// The watcher reports a loop that stops returning. It is started with the
	// worker, so a front-end that never reaches its first frame is covered too.
	_ = watchdog_start(app)

	worker := thread.create(run_worker, name = "nabla-tui-worker")
	if worker == nil {
		fmt.eprintln("nabla: cannot start the worker thread")
		app_teardown(app)
		return false
	}
	worker.data = app
	app.run.worker = worker
	thread.start(worker)
	_ = catalog_refresh_start(app, sources)

	if viewport, vp_err := term.viewport(app.terminal); vp_err == nil {
		app.columns, app.rows = viewport.columns, viewport.rows
		present_frame(app, app.storage)
	}

	read_failed := false
	for !app.quit {
		watchdog_stage(app, .Waiting)
		_, read_err := input.read_events(&app.parser, app.tty, &app.raw, TUI_POLL_MS)
		if read_err != nil {
			fmt.eprintln("nabla: input:", read_err)
			read_failed = true
			break
		}
		watchdog_stage(app, .Events)
		for event in app.raw {
			handle_event(app, event)
		}
		count := len(app.raw)
		input.events_clear(&app.raw, app.run.alloc)

		// A terminal that has reported no size cannot be drawn into: nothing may be
		// presented until one exists, and the frame it would have drawn is dropped
		// rather than carried over. It must not stop the rest of the iteration
		// either. The stop check below runs on this pass too, because a front-end
		// that silently stopped drawing and stopped listening for a quit is a
		// process nothing but a signal can end.
		watchdog_stage(app, .Viewport)
		viewport, vp_err := term.viewport(app.terminal)
		sizable := vp_err == nil
		resized := false
		recovered := false
		if sizable {
			// A size that arrived after a reported failure owes one frame even when
			// nothing else moved, so the screen cannot stay on the last frame it
			// held before the terminal went quiet.
			recovered = app.viewport_reported
			app.viewport_reported = false
			resized = viewport.columns != app.columns || viewport.rows != app.rows
			app.columns, app.rows = viewport.columns, viewport.rows
		} else {
			report_viewport_unavailable(app, vp_err)
		}

		// The working indicator animates only while a request is active, so a
		// silent request (no stream events, tools running) still advances it. The
		// runtime reads that follow wait on the mutex the worker publishes through,
		// so they are the phase a front-end waits in rather than runs in.
		watchdog_stage(app, .Runtime)
		now := time.tick_now()
		busy := runtime_busy(app)
		watchdog_observe(app, busy, sizable)
		advance_spinner := busy && time.tick_diff(app.spin_lap, now) >= SPINNER_INTERVAL
		// A startup chooser closes once its selection applies on the worker; a menu
		// opened from the prompt closes on submit instead, so browsing it does not
		// dismiss it.
		if app.menu.required && runtime_model_selected(app) {
			menu_close(app)
			widgets.input_clear(&app.input)
		}
		catalog_updated := catalog_changed(app)
		if catalog_updated {
			catalog_selection_refresh_request(app)
		}
		if catalog_updated && app.menu_open && app.menu.kind == .Model {
			required := app.menu.required
			menu_rebuild_model(app)
			app.menu.required = required
		}
		if sizable && (count > 0 || resized || recovered || generation_changed(app) || advance_spinner || catalog_updated) {
			watchdog_stage(app, .Drawing)
			if advance_spinner {
				app.spin_frame = (app.spin_frame + 1) % SPINNER_FRAMES
				app.spin_lap = now
			}
			present_frame(app, app.storage)
		}

		// SIGINT/SIGTERM through the agent handler: cancel a running turn, or
		// quit when idle. A cancel this front-end requested through a key is
		// cleared once its turn retired, so it ends the turn only; an outside
		// signal ends the session once the turn retired.
		watchdog_stage(app, .Stop)
		if agent.chat_cancel_requested() && !runtime_busy(app) {
			if app.cancel_seen {
				app.cancel_seen = false
				agent.chat_cancel_reset()
			} else {
				app.quit = true
				break
			}
		}
	}

	// Teardown: refuse further work, cancel a running turn so the worker settles,
	// then stop it and join. Join is safe only after the turn retired;
	// cancellation guarantees that.
	stop_runtime(app)
	if runtime_busy(app) {
		agent.chat_cancel_request()
	}
	app_teardown(app)
	return !read_failed
}

// report_viewport_unavailable says once per episode that the terminal reported no size to
// draw into. The loop cannot present a frame without one, and not saying so left a run
// whose screen kept its last frame, whose transcript kept the news, and whose log kept
// nothing: a front-end waiting on a terminal that never answered looked exactly like a
// front-end that had died. The latch clears when a size arrives, so a terminal that goes
// quiet and comes back is reported each time it does.
report_viewport_unavailable :: proc(app: ^App, err: term.Error) {
	if app.viewport_reported { return }
	app.viewport_reported = true
	reason := fmt.tprintf("%v", err)
	fields := [1]agent.Log_Field{{key = "viewport_error", value = reason}}
	agent.log_emit(agent.Log_Record{level = .Warning, category = .Runtime, event = "ui.viewport_unavailable", fields = fields[:]})
	snap_append(app, .Warning, fmt.tprintf("the terminal reports no size to draw into (%s); waiting for one", reason))
}

// app_teardown releases everything after the worker stopped. It must be
// called at most once. A thread that does not retire stops the release: what such a
// thread can still reach must not be handed back while it is using it. patience is how
// long each thread is given, so a test can hold the give-up path without waiting for the
// bound a real shutdown uses.
app_teardown :: proc(app: ^App, patience := SHUTDOWN_JOIN_PATIENCE) {
	// Stopping is the phase where a front-end waits for other threads, so the
	// watcher covers it: a run that will not exit otherwise leaves nothing after
	// its last frame.
	watchdog_stage(app, .Teardown)
	retired := catalog_refresh_stop(app, patience)
	if app.run.work != {} {
		chan.close(&app.run.work)
	}
	if app.run.worker != nil {
		if join_retiring(app.run.worker, "nabla-tui-worker", patience) {
			app.run.worker = nil
		} else {
			retired = false
		}
	}
	if !retired {
		// Nothing below this line may run: the release path would free the channel, the
		// snapshot, and the log binding that the thread still reads. The process exits
		// with that memory owned by the thread that is using it, and the record names
		// which thread it was.
		agent.log_emit(agent.Log_Record{level = .Error, category = .Runtime, event = "runtime.teardown_abandoned"})
		return
	}
	// The worker frees what it had buffered on the way out; this covers commands
	// that were queued after it stopped receiving, and a worker that never started.
	for {
		queued, ok := chan.recv(app.run.work)
		if !ok { break }
		work_destroy(app, queued)
	}
	chan.destroy(&app.run.work)
	agent.steer_queue_destroy(&app.run.steer)
	pending_selection_clear(&app.run.pending, app.run.alloc)
	snapshot_destroy(app)
	menu_destroy(&app.menu, app.run.alloc)
	delete(app.completion_query, app.run.alloc)
	delete(app.home, app.run.alloc)
	widgets.input_destroy(&app.input)
	input.parser_destroy(&app.parser)
	input.events_destroy(&app.raw, app.run.alloc)
	frame_storage_destroy(app.storage)
	// The watcher stops here: after every thread it could report has been joined,
	// and before the log it writes to is closed.
	retired = watchdog_stop(app, patience)
	if !retired {
		agent.log_emit(agent.Log_Record{level = .Error, category = .Runtime, event = "runtime.teardown_abandoned"})
		return
	}
	// A tool worker that ignored its stop still borrows the session's workspace, registry
	// generation, and backends, so none of that may be released. The process exits with
	// what that worker can still reach, and the record names why.
	if agent.chat_session_worker_escaped(&app.setup.session) {
		agent.log_emit(agent.Log_Record{level = .Error, category = .Runtime, event = "runtime.worker_escaped"})
		return
	}
	run_setup_destroy(&app.setup)
	catalog_retired_destroy(app)
}

// snapshot_destroy releases everything the front-end snapshot owns and zeroes it,
// so it is safe to call on a partially filled snapshot and more than once. A
// headless run has no front-end, but the launch path publishes into the snapshot
// anyway, so both callers release it the same way.
snapshot_destroy :: proc(app: ^App) {
	for &entry in app.run.snap.entries {
		if entry.text != nil {
			delete(entry.text)
		}
	}
	delete(app.run.snap.entries)
	for &row in app.run.snap.sessions {
		delete(string(row.id), app.run.alloc)
		delete(row.title, app.run.alloc)
	}
	delete(app.run.snap.sessions)
	delete(string(app.run.snap.active_session), app.run.alloc)
	delete(app.run.snap.status.provider_id, app.run.alloc)
	delete(app.run.snap.status.model_id, app.run.alloc)
	delete(app.run.snap.status.effort, app.run.alloc)
	delete(app.run.snap.status.cwd, app.run.alloc)
	for level in app.run.snap.status.effort_levels { delete(level, app.run.alloc) }
	delete(app.run.snap.status.effort_levels)
	delete(app.run.snap.setup_error, app.run.alloc)
	app.run.snap = {}
}
