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
import "nabla:agent/journal"
import "nabla:ai"
import input "nabla:input"
import "nabla:term"
import "nabla:tui/widgets"

// The front-end: a worker thread owns the agent session, the main thread owns the
// terminal, and results cross through the runtime snapshot. The snapshot is a display
// projection; the session keeps the real history, request context, effort, and usage.

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
	// id names this entry for as long as it is on screen. The frame carries it on
	// a tool box, and the mouse report is answered by id rather than by position,
	// which is what keeps a box under the pointer its own after the transcript
	// dropped older lines. Zero is not an entry.
	id:              u64,
	// revision counts changes to text, so a presentation derived from the text can tell it is stale.
	revision:        u64,
	// bytes is what this entry costs the transcript's budget: its own slot and the
	// text it keeps, so one budget covers everything the transcript holds.
	bytes:           int,
	complete:        bool,
	tool_outcome:    journal.Tool_Outcome,
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

// Status carries the runtime facts the footer shows. provider_id and cwd are borrowed
// from the runtime for the app's lifetime; model_id, effort, and effort_levels are owned
// display copies replaced under the runtime mutex. A usage bucket the provider never
// reported reads as unknown rather than zero.
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
	// cost_partial says the total prices only part of the session's responses,
	// because some committed responses named a model the catalog has no price for.
	cost_partial:          bool,
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
	// following says the session runs in another process: this front-end shows it and
	// sends lines to it, and running then reports that process's turn.
	following:             bool,
	// working_since spans the complete execution of one accepted prompt, across
	// every provider request and tool call, until the session returns to idle.
	working_since:         time.Tick,
	// Whether the turn is waiting to resend a failed request. The next send clears it, and the
	// worker clears it whenever the session stops running.
	retry_present:         bool,
}

// TRANSCRIPT_MAX_BYTES bounds the rendered transcript: the entries the screen keeps for
// scrolling and the text they hold. Past the budget the oldest entries are dropped and
// their text released, while the store keeps the whole conversation, so the bound is a
// display cost and never a limit on the run.
TRANSCRIPT_MAX_BYTES :: 1 * mem.Megabyte

// TRANSCRIPT_TRIMMED_NOTICE is said once, when the transcript first drops an old
// line. A screen that quietly loses its oldest rows looks like a screen that lost
// them for another reason.
TRANSCRIPT_TRIMMED_NOTICE :: "older transcript lines are not shown; the session store keeps them and /resume replays them"

// snapshot_transcript_own points the transcript at the run's allocator, so every
// entry is allocated with the allocator the run releases it with rather than with
// whatever default the appending thread carries. Both front-ends call it before
// anything can append.
snapshot_transcript_own :: proc(app: ^App) {
	app.run.snap.entries.allocator = app.run.alloc
}

// snapshot_status_start publishes the launch's provider, model, and workspace into
// the status block, each copied into the run's allocator. False means one of the
// copies failed, and the launch stops rather than show a status that names nothing.
@(require_results)
snapshot_status_start :: proc(app: ^App) -> bool {
	provider_id, provider_error := strings.clone(app.setup.provider_id, app.run.alloc)
	model_id, model_error := strings.clone(app.setup.model_id, app.run.alloc)
	workspace, workspace_error := strings.clone(app.setup.workspace, app.run.alloc)
	if provider_error != nil || model_error != nil || workspace_error != nil {
		delete(provider_id, app.run.alloc)
		delete(model_id, app.run.alloc)
		delete(workspace, app.run.alloc)
		return false
	}
	app.run.snap.status.provider_id = provider_id
	app.run.snap.status.model_id = model_id
	app.run.snap.status.cwd = workspace
	return true
}

// Snapshot is everything the renderer reads. The worker bumps generation
// after any change; the main thread redraws when it moves.
Snapshot :: struct {
	entries:            [dynamic]Entry, // owned,
	// entries_bytes is what the resident entries hold: each entry's own slot and
	// the text it keeps, the number the transcript's budget is spent from.
	entries_bytes:      int,
	// display_incomplete records that a line or status field could not be kept.
	display_incomplete: bool,
	// transcript_trimmed records that the transcript dropped old lines, so the
	// notice is said once rather than at every drop.
	transcript_trimmed: bool,
	// next_entry_id numbers the entries the transcript keeps. An entry's id
	// travels on its tool box node to the mouse, so a report still finds its box
	// after older entries were dropped.
	next_entry_id:      u64,
	status:             Status,
	// sessions is what the /resume menu offers. Only the worker reads the store,
	// so only the worker rebuilds this.
	sessions:           [dynamic]Session_Row, // owned,
	// active_session is the session the worker is running. It travels with the row
	// list so the menu can open on it without reading the running session, which
	// the worker can replace at any moment.
	active_session:     journal.Session_Id,
	// setup_error is why the last selection attempt failed; the model menu shows
	// it because it has no transcript. setup_error_failed means the reason could
	// not be cloned, so the presentation uses its static fallback instead.
	setup_error:        string, // owned,
	setup_error_failed: bool,
	generation:         u64,
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
	id: journal.Session_Id,
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
	id:    journal.Session_Id,
	title: string, // owned; a child's is its name and title
	child: bool, // a subagent session, listed under the main session that started it
}

// Pending_Selection is the selection the user asked for and the worker has not installed
// yet. Only the front-end records it; the worker consumes it at the next request
// boundary, so a change made while a response streams reaches the next request of that
// same turn rather than waiting for the turn to end.
Pending_Selection :: struct {
	present:  bool,
	provider: string, // owned by the runtime allocator,
	model:    string, // owned by the runtime allocator,
}

Pending_Target :: struct {
	present:    bool,
	target:     agent.Model_Selection, // owned by the runtime allocator,
	transition: agent.Selection_Transition,
	announced:  bool,
}

Runtime :: struct {
	mu:                       sync.Mutex, // guards snapshot and pending,
	snap:                     Snapshot,
	// wake is the eventfd the frame loop polls beside the terminal. Whatever changes
	// what the frame shows signals it, so an idle loop sleeps until there is something
	// to draw. It is set before the worker starts and cleared after the worker and the
	// catalog refresh have stopped, so no thread reads it while it changes. Nil means
	// there is no frame loop to wake.
	wake:                     Maybe(int),
	work:                     Work_Chan,
	worker:                   ^thread.Thread,
	// worker_done is signaled by the worker as its last action, which is what
	// join_retiring waits on.
	worker_done:              sync.One_Shot_Event,
	connection:               ai.Provider_Connection,
	// pending is the selection change waiting for a request boundary. It is written
	// by the front-end and consumed by the worker, so it is guarded by mu like the
	// snapshot the same boundary is published into.
	pending:                  Pending_Selection,
	// compact_pending crosses queue and turn boundaries until the owner consumes it.
	compact_pending:          bool,
	// pending_target is owner-thread state retained while the target model is being fit.
	pending_target:           Pending_Target,
	// steer carries lines typed while a turn is running. The front-end pushes
	// them as they arrive and the worker drains them at request boundaries, which
	// is why it is written from one thread and read from another.
	steer:                    agent.Steer_Queue,
	// control stops the turn the worker runs. The front-end requests; the worker clears it
	// before each turn it starts.
	control:                  agent.Turn_Control,
	alloc:                    mem.Allocator,
	signals:                  agent.Chat_Interactive_Signals,
	// stopping is set once by the front-end before the worker is stopped. A cancel ends
	// the running turn and the session keeps going; stopping ends the process. The worker
	// checks it at its own boundaries.
	stopping:                 bool,
	// catalog_applied_revision is the newest published catalog whose metadata the
	// worker applied to the active selection. Only the worker reads and writes it.
	catalog_applied_revision: u64,
}

// stop_runtime refuses further work. The front-end is the only enqueuer, so once
// this returns no command can enter the queue, and the worker abandons what is
// already in it.
stop_runtime :: proc(app: ^App) {
	sync.atomic_store(&app.run.stopping, true)
	agent.owner_wake_signal()
}

@(require_results)
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

run_setup_destroy :: proc(setup: ^Run_Setup) {
	journal.records_destroy(setup.follow_pending, setup.alloc)
	agent.chat_session_destroy(&setup.session)
	// The watch only wakes owners, so it stops once the session it woke is gone.
	agent.session_watch_stop(&setup.watch)
	// The tool registry borrowed the runtime's bindings, so the session goes first
	// and the MCP clients second. A runtime that was never built owns nothing.
	mcp_runtime_destroy(&setup.mcp)
	if close_error := run_store_close(setup); close_error != nil {
		detail := journal.error_text(close_error, context.temp_allocator)
		fmt.eprintln("nabla: the session database could not be closed cleanly:", detail)
	}
	delete(setup.journal_directory, setup.alloc)
	delete(setup.lock_directory, setup.alloc)
	agent.catalog_destroy(&setup.catalog)
	for id in setup.configured {
		delete(id, setup.alloc)
	}
	delete(setup.configured)
	delete(setup.workspace, setup.alloc)
	delete(setup.resumed_provider, setup.alloc)
	delete(setup.resumed_model, setup.alloc)
	delete(setup.resumed_effort, setup.alloc)
	if setup.credential != "" { delete(setup.credential, setup.alloc) }
	if setup.provider_id != "" { delete(setup.provider_id, setup.alloc) }
	if setup.model_id != "" { delete(setup.model_id, setup.alloc) }
	setup^ = {}
}

// tui_run is the interactive entry point: resolve the catalog, open the session
// the launch asked for, open the terminal, apply the selection (explicit flags,
// then the persisted one, then the in-TUI model menu), start the worker, and
// drive the frame loop until quit.
@(require_results)
tui_run :: proc(
	sources: []agent.Catalog_Provider_Source,
	mcp_servers: []agent.MCP_Server_Config,
	harness_options: agent.Harness_Options,
	flag_provider, flag_model: string,
	start: Session_Start,
) -> (
	ok: bool,
) {
	app, app_error := new(App)
	if app_error != nil { return false }
	app_abandoned := false
	// An abandoned worker may still access this allocation.
	defer if !app_abandoned { free(app) }
	app.run.alloc = context.allocator
	// This run is the user's own, so its model choice is published to the frame and
	// remembered for the next launch.
	app.setup.owns_selection = true
	// The TUI shows a session another process runs as a follower, and watches the
	// sessions it shows.
	app.setup.shared_sessions = true
	// The setup is filled in place: a store owns a live connection, and copying
	// one would leave two owners of it.
	app.setup.harness_options = harness_options
	app.compact_on_switch = harness_options.compact_on_switch
	app.setup.alloc = context.allocator
	if !run_catalog(sources, mcp_servers, &app.setup, start) {
		return false
	}
	// The transcript's text belongs to the run's allocator, not to whatever
	// default the appending thread happens to carry, so the array's allocator is
	// set before its first line. The slots grow with the transcript and are
	// bounded by its budget.
	snapshot_transcript_own(app)
	// The resumed conversation is shown before the first prompt, so the screen
	// matches the history the next request will be built from.
	session_replay(app, &app.setup.session)
	app.home = os.get_env("HOME", app.run.alloc)
	app.input = widgets.Input{}
	widgets.input_init(&app.input, app.run.alloc)
	app.storage = frame_storage_new(app.run.alloc)
	if app.storage == nil {
		fmt.eprintln("nabla: cannot allocate the frame budget")
		app_abandoned = app_teardown(app)
		return false
	}
	// The status is published only once the frame budget exists, so a failure here
	// can still take the launch down through the same release path as every later
	// one. cwd is owned by the snapshot because a session switch replaces the
	// workspace and the footer reads the status under the lock, so a borrowed
	// workspace would dangle as soon as the running session changed.
	if !snapshot_status_start(app) {
		fmt.eprintln("nabla: the status line could not be allocated")
		app_abandoned = app_teardown(app)
		return false
	}
	app.run.snap.status.context_window = app.setup.session.capacity.window
	work, work_error := chan.create_buffered(Work_Chan, WORK_CAPACITY, app.run.alloc)
	if work_error != nil {
		fmt.eprintln("nabla: cannot create the command queue:", work_error)
		app_abandoned = app_teardown(app)
		return false
	}
	app.run.work = work
	app.run.steer = agent.steer_queue_init(app.run.alloc)

	terminal, open_err := term.open({alternate_screen = true, hide_cursor = true, bracketed_paste = true, mouse = true, input_mode = .Raw}, app.run.alloc)
	if open_err != nil {
		fmt.eprintln("nabla: cannot open the terminal:", open_err)
		app_abandoned = app_teardown(app)
		return false
	}
	// The terminal is being released on the way out, after the frame loop stops drawing.
	defer {
		close_error := term.close(terminal)
		if close_error != nil {
			close_error = term.close(terminal)
			if close_error != nil {
				fmt.eprintfln("nabla: could not restore the terminal state (%v); run `reset` to restore it", close_error)
			}
		}
		// The screen is restored, so the message stays on the user's terminal.
		if app_abandoned { fmt.eprintln("nabla: a thread did not stop in time; the process exits without releasing what it still uses") }
	}
	app.terminal = terminal

	tty, file_err := term.session_file(terminal)
	if file_err != nil {
		fmt.eprintln("nabla: cannot access the terminal input:", file_err)
		app_abandoned = app_teardown(app)
		return false
	}
	app.tty = tty
	input.parser_init(&app.parser)
	raw, raw_error := make([dynamic]input.Event, 0, 16, app.run.alloc)
	if raw_error != nil {
		fmt.eprintln("nabla: the input buffer could not be allocated")
		app_abandoned = app_teardown(app)
		return false
	}
	app.raw = raw

	wake, wake_error := input.wake_make()
	if wake_error != nil {
		fmt.eprintln("nabla: cannot create the wake descriptor:", wake_error)
		app_abandoned = app_teardown(app)
		return false
	}
	app.run.wake = wake
	term.set_resize_wake(wake)
	agent.signal_set_wake(wake)

	if !apply_startup_selection(app, flag_provider, flag_model) {
		fmt.eprintln("nabla:", setup_error_text(app))
		app_abandoned = app_teardown(app)
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

	worker := thread.create(run_worker, name = "nabla-tui-worker")
	if worker == nil {
		fmt.eprintln("nabla: cannot start the worker thread")
		app_abandoned = app_teardown(app)
		return false
	}
	worker.data = app
	app.run.worker = worker
	thread.start(worker)
	if !catalog_refresh_start(app, sources) {
		snap_append(app, .Warning, "the catalog refresh could not be started; the catalog stays as it is")
	}

	if viewport, viewport_err := term.viewport(app.terminal); viewport_err == nil {
		app.columns, app.rows = viewport.columns, viewport.rows
		present_frame(app, app.storage)
	}

	read_failed := false
	for !app.quit {
		_, read_err := input.read_events(&app.parser, app.tty, &app.raw, tui_wait_ms(app), wake)
		// The drain comes after the poll and before the loop reads any state a wake
		// announces. A change published while this pass runs then leaves the descriptor
		// readable, so the next poll returns at once instead of sleeping past it.
		input.wake_drain(wake)
		if read_err != nil {
			fmt.eprintln("nabla: input:", read_err)
			read_failed = true
			break
		}
		for event in app.raw {
			handle_event(app, event)
		}
		count := len(app.raw)
		input.events_clear(&app.raw, app.run.alloc)

		// A terminal that has reported no size cannot be drawn into: the frame it would
		// have drawn is dropped and the rest of the iteration still runs. The stop check
		// below runs on this pass too, so a front-end waiting on a size still answers a
		// quit and a signal.
		viewport, viewport_err := term.viewport(app.terminal)
		sizable := viewport_err == nil
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
			report_viewport_unavailable(app, viewport_err)
		}

		// The working indicator animates only while a request is active, so a
		// silent request (no stream events, tools running) still advances it.
		now := time.tick_now()
		busy := runtime_busy(app)
		// A steering line applies at a request boundary inside the turn that was running
		// when it was typed. Whatever is still queued when the turn stops was never
		// applied, so it goes back to the prompt as the user's own text.
		if app.steer_active && !busy { restore_steering(app) }
		app.steer_active = busy
		advance_spinner := busy && time.tick_diff(app.spin_lap, now) >= SPINNER_INTERVAL
		// The lap restarts even when no frame can be drawn, because tui_wait_ms would
		// otherwise return zero and spin until a size arrives.
		if advance_spinner {
			app.spin_frame = (app.spin_frame + 1) % SPINNER_FRAMES
			app.spin_lap = now
		}
		// A startup chooser closes once its selection applies on the worker; a menu
		// opened from the prompt closes on submit instead, so browsing it does not
		// dismiss it.
		if app.menu.required && runtime_model_selected(app) {
			menu_close(app)
			prompt_clear(app)
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
			present_frame(app, app.storage)
		}

		// Signals stop this process's turn before exit. A follower owns no remote turn,
		// so it leaves without waiting for the runner.
		if agent.process_interrupted() && (!runtime_busy(app) || runtime_following(app)) {
			app.quit = true
			break
		}
	}

	// Teardown: refuse further work, cancel a running turn so the worker settles,
	// then stop it and join. Join is safe only after the turn retired;
	// cancellation guarantees that.
	stop_runtime(app)
	if runtime_busy(app) { agent.turn_control_stop(&app.run.control) }
	app_abandoned = app_teardown(app)
	return !read_failed
}

// tui_wait_ms is how long the frame loop may sleep: forever while idle, because every
// change that needs a frame signals the wake, and until the next spinner frame while a
// turn runs, because the spinner animates without any change to signal.
tui_wait_ms :: proc(app: ^App) -> i64 {
	if !runtime_busy(app) { return -1 }
	remaining := SPINNER_INTERVAL - time.tick_diff(app.spin_lap, time.tick_now())
	return max(i64(0), i64((remaining + time.Millisecond - 1) / time.Millisecond))
}

// report_viewport_unavailable says once per episode that the terminal reported no size to
// draw into, and records it in the transcript. The latch clears when a size
// arrives, so a terminal that goes quiet and comes back is reported each time.
report_viewport_unavailable :: proc(app: ^App, err: term.Error) {
	if app.viewport_reported { return }
	app.viewport_reported = true
	reason := fmt.tprintf("%v", err)
	snap_append(app, .Warning, fmt.tprintf("the terminal reports no size to draw into (%s); waiting for one", reason))
}

// app_teardown releases everything after the worker stopped, and must be called at most
// once. A thread that does not retire stops the release, because what it can still reach
// must not be handed back while it is using it. patience is per thread, so a test can
// hold the give-up path without the bound a real shutdown uses.
@(require_results)
app_teardown :: proc(app: ^App, patience := SHUTDOWN_JOIN_PATIENCE) -> bool {
	retired := catalog_refresh_stop(app, patience)
	if app.run.work != {} {
		chan.close(&app.run.work)
		agent.owner_wake_signal()
	}
	if app.run.worker != nil {
		if join_retiring(app.run.worker, &app.run.worker_done, patience) {
			app.run.worker = nil
		} else {
			retired = false
		}
	}
	if !retired {
		// Nothing below this line may run: the release path would free the channel and the
		// snapshot that the thread still reads. The process exits with that memory owned by
		// the thread that is using it.
		return true
	}
	// The worker and the catalog refresh are gone, so nothing signals the wake. The
	// registrations clear first because a signal handler can still run on any thread.
	if wake, armed := app.run.wake.?; armed {
		term.set_resize_wake(-1)
		agent.signal_set_wake(-1)
		input.wake_destroy(wake)
		app.run.wake = nil
	}
	// The worker frees what it had buffered on the way out; this covers commands
	// that were queued after it stopped receiving, and a worker that never started.
	for {
		queued, ok := chan.recv(app.run.work)
		if !ok { break }
		work_destroy(app, queued)
	}
	chan.destroy(&app.run.work)
	// Input the user sent that no request carried. A turn records what it was sent when it
	// ends, so what is left here reached no turn at all: the process is the last holder, and
	// saying so is the only report an exiting front-end can give. This is the difference
	// between input that was pending and input that was dropped.
	if undelivered, taken := agent.steer_take_all(&app.run.steer); taken && len(undelivered) > 0 {
		fmt.eprintf("nabla: %d line(s) typed during a turn were never recorded; they were not delivered\n", len(undelivered))
		agent.steer_taken_destroy(&app.run.steer, undelivered)
	}
	agent.steer_queue_destroy(&app.run.steer)
	pending_selection_clear(&app.run.pending, app.run.alloc)
	pending_target_clear(&app.run.pending_target, app.run.alloc)
	snapshot_destroy(app)
	menu_destroy(&app.menu, app.run.alloc)
	delete(app.completion_query, app.run.alloc)
	history_destroy(app)
	delete(app.home, app.run.alloc)
	widgets.input_destroy(&app.input)
	input.parser_destroy(&app.parser)
	input.events_destroy(&app.raw, app.run.alloc)
	frame_storage_destroy(app.storage)
	// A tool worker that ignored its stop may still use the tool backends, so the process
	// exits with them rather than freeing them under it.
	if app.setup.workers_abandoned || agent.chat_session_workers_outstanding(&app.setup.session) {
		return true
	}
	run_setup_destroy(&app.setup)
	catalog_run_destroy(app)
	return false
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
		delete(row.title, app.run.alloc)
	}
	delete(app.run.snap.sessions)
	delete(app.run.snap.status.provider_id, app.run.alloc)
	delete(app.run.snap.status.model_id, app.run.alloc)
	delete(app.run.snap.status.effort, app.run.alloc)
	delete(app.run.snap.status.cwd, app.run.alloc)
	for level in app.run.snap.status.effort_levels { delete(level, app.run.alloc) }
	delete(app.run.snap.status.effort_levels)
	delete(app.run.snap.setup_error, app.run.alloc)
	app.run.snap = {}
}
