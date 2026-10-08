#+build linux
package main

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "nabla:agent"
import "nabla:agent/journal"
import "nabla:ai"
import input "nabla:input"
import "nabla:term"
import "nabla:tui"
import "nabla:tui/widgets"

Run_Setup :: struct {
	harness_options:    agent.Harness_Options,
	catalog:            agent.Catalog,
	api:                ai.API_Kind,
	credential:         string, // owned,
	// store is the running session's journal, owned. Chat_Session borrows it, so it
	// is replaced only together with the chat.
	store:              ^journal.Journal,
	journal_directory:  string, // owned
	lock_directory:     string, // owned; where the journal takes session claims
	run:                journal.Run_Id,
	// run_open says the running session's journal carries this launch's run.started, so
	// run.finished is owed when the launch ends.
	run_open:           bool,
	session:            agent.Chat_Session,
	workspace:          string, // owned; the directory sessions here run in
	provider_id:        string, // owned,
	model_id:           string, // owned,
	// resumed_provider and resumed_model are what the opened session last ran
	// with. They are empty for a new session, and they are only a fallback for
	// when no selection exists anywhere else.
	resumed_provider:   string, // owned,
	resumed_model:      string, // owned,
	resumed_effort:     string, // owned,
	// configured holds the provider ids the user's own configuration declares;
	// models.dev also contributes providers, and the model menu offers only the
	// configured ones, whose credentials the user actually set up.
	configured:         [dynamic]string, // owned,
	// owns_selection says whether this run's model choice is the user's. The
	// interactive harness owns it: its choice is published to the front-end and
	// remembered for the next launch. A headless or child run does not, because it
	// selects a model for one job and must not change what the user starts with.
	owns_selection:     bool,
	// shared_sessions says this front-end shows a session another process runs as a
	// follower instead of refusing it, and watches the lock file of the session it shows
	// so that other processes' commits and a dropped claim wake the worker. A headless
	// resume sets it too and sends its line to the runner; the ACP server leaves it false
	// and refuses a running session.
	shared_sessions:    bool,
	// follow is where the follower's reading of the journal stands. It is meaningful only
	// while the running store follows.
	follow:             agent.Follow,
	// takeover_failed stops a follower from claiming again after a claim it won could not
	// be used, so every later wake does not repeat the failure.
	takeover_failed:    bool,
	takeover_retryable: bool,
	follow_pending:     []journal.Record, // owned until initial replay
	follow_input_busy:  bool,
	// watch wakes the worker for changes of the shown session's lock file. watched is the
	// session whose lock file it watches, and watch_id the kernel's name for it.
	watch:              agent.Session_Watch,
	watched:            journal.Session_Id,
	watch_id:           agent.Session_Watch_Id,
	// mcp_servers is borrowed from the launch's configuration, which outlives the
	// setup. mcp owns the running MCP clients and the bindings a tool definition may
	// borrow, so it is released after the session that holds the registry.
	mcp_servers:        []agent.MCP_Server_Config,
	mcp:                MCP_Runtime,
	// workers_abandoned stays set after a replaced session leaves a worker behind.
	workers_abandoned:  bool,
	alloc:              mem.Allocator,
}

App :: struct {
	setup:                      Run_Setup,
	// compact_on_switch is the launch's fixed policy for fitting explicit model changes.
	compact_on_switch:          bool,
	// catalog_mu protects publication of a replacement catalog. A publication
	// releases the catalog it replaces, so anything read out of a catalog is either
	// copied while the lock is held or owned by this run.
	catalog_mu:                 sync.Mutex,
	// catalog_refresh_at is when the last catalog refresh was asked for, on the monotonic
	// clock, and catalog_refreshed says one was asked for at all, since a zero tick is not
	// a time. Only the front-end asks, so this is front-end state.
	catalog_refresh_at:         time.Tick,
	catalog_refreshed:          bool,
	// models_dev_read_at is when this run last read models.dev into sources. It is only
	// meaningful while models_dev_sources is non-empty, which is what says a read happened.
	models_dev_read_at:         time.Tick,
	// endpoint is the base_url the running connection borrows. The catalog a model
	// was selected from is released when a refresh replaces it, so the endpoint is
	// owned here rather than borrowed from a catalog entry a publication frees.
	endpoint:                   string, // owned,
	// Retired connection strings are endpoints and credentials an abandoned
	// operation may still borrow, so they stay valid until the run ends.
	retired_connection_strings: [dynamic]string, // owned,
	catalog_sources:            []agent.Catalog_Provider_Source, // borrowed for tui_run
	provider_sources:           [dynamic]agent.Catalog_Provider_Source, // owned refresh snapshot
	models_dev_sources:         [dynamic]agent.Catalog_Provider_Source, // owned refresh snapshot
	catalog_refresh:            Catalog_Refresh_Chan,
	catalog_worker:             ^thread.Thread,
	catalog_worker_done:        sync.One_Shot_Event, // signaled by the catalog worker as its last action
	catalog_revision:           u64,
	catalog_seen:               u64,
	terminal:                   ^term.Session,
	tty:                        ^os.File,
	parser:                     input.Parser,
	raw:                        [dynamic]input.Event, // owned; the latest input batch,
	run:                        Runtime,
	storage:                    ^Frame_Storage,
	// box_drag is a drag that started on the result rows of an expanded box.
	box_drag:                   Box_Drag,
	// transcript is the committed history on screen, which only the main thread touches.
	transcript:                 Transcript,
	home:                       string, // owned; shortens the footer path,
	input:                      widgets.Input,
	scroll:                     int, // rows scrolled back; 0 follows the bottom,
	// conv_scroll_range is the conversation's scrollable height in rows, as
	// the last completed layout frame reported it. The offset handed to layout
	// is range - scroll, so a scroll of 0 pins the newest content to the
	// bottom and the range shrinks and grows with the transcript.
	conv_scroll_range:          int,
	generation_seen:            u64,
	// steer_active is whether the runtime was running when this thread last looked. The
	// transition back to idle is what returns input the turn never applied to the
	// prompt. The loop reads and writes it on the front-end's thread only.
	steer_active:               bool,
	// viewport_reported latches the one warning a terminal that reports no size
	// produces. The loop reads it on the front-end's thread only.
	viewport_reported:          bool,
	spin_lap:                   time.Tick, // last working-frame advance,
	spin_frame:                 int,
	// menu is the open choice list, when menu_open. One component serves every
	// command whose argument is picked from a list.
	menu:                       Menu,
	menu_open:                  bool,
	// completion_query and completion_index carry a Tab cycle: the prefix the
	// cycle began with and where it has reached. Any other key ends the cycle.
	completion_query:           string, // owned,
	completion_index:           int,
	completion_active:          bool,
	// history holds the prompts submitted this run, oldest first; history_index is the
	// entry the prompt line shows, or len(history) while a fresh line is composed. Only
	// prompts enter it, because submit routes a slash command to dispatch_command.
	history:                    [dynamic]string, // owned,
	history_index:              int,
	// history_draft is the fresh line as the arrow keys left it: stepping forward past the
	// newest entry puts it back. It never joins history. The empty string means nothing is
	// kept.
	history_draft:              string, // owned,
	columns:                    int,
	rows:                       int,
	// conversation_rect is the cells the transcript occupied in the last frame. A
	// mouse report is in screen cells, so this is what converts one into the
	// conversation's own coordinates.
	conversation_rect:          tui.Cell_Rect,
	// selecting marks a drag in progress, and the anchor and cursor are the cells
	// it spans. The selection lives only while the drag does: the release copies
	// what it covers, so there is no highlight left to drift when the transcript
	// moves under it.
	selecting:                  bool,
	selection_anchor:           Cell_Point,
	selection_cursor:           Cell_Point,
	quit:                       bool,
}

// resolve_run_catalog builds the initial resolved catalog from local data only:
// the user's configuration, any provider listings already cached, and the last
// models.dev document. Network refresh is owned by the interactive runtime.
@(require_results)
resolve_run_catalog :: proc(
	sources: []agent.Catalog_Provider_Source,
	allocator: mem.Allocator,
) -> (
	catalog: agent.Catalog,
	configured: [dynamic]string,
	ok: bool,
) {
	// Only configured providers are selectable, so the raw catalog is filtered to
	// them as it is read: enrichment for anything else has no consumer.
	names, names_error := make([]string, len(sources), context.temp_allocator)
	if names_error != nil {
		fmt.eprintln("nabla: the provider names could not be listed")
		return {}, {}, false
	}
	defer delete(names, context.temp_allocator)
	for source, index in sources { names[index] = source.id }

	discovered, discovered_ok := agent.provider_models_cached(sources, allocator = allocator)
	defer agent.catalog_sources_destroy(&discovered, allocator)
	if !discovered_ok {
		fmt.eprintln("nabla: the cached provider listings could not be held")
		return {}, {}, false
	}
	models_dev, models_dev_error := agent.models_dev_cached_sources(providers = names, allocator = allocator)
	// A cache that was never written is the normal first launch, not a report;
	// anything else about it is worth saying even though the launch proceeds.
	if models_dev_error != .None && models_dev_error != .Unavailable {
		fmt.eprintln("nabla: the cached models.dev document could not be read")
	}
	defer agent.catalog_sources_destroy(&models_dev, allocator)
	resolved, resolve_error := agent.resolve_catalog(sources, discovered[:], models_dev[:], allocator)
	if resolve_error != .None {
		if resolve_error == agent.Catalog_Error.Allocation {
			fmt.eprintln("nabla: the catalog could not be held")
		} else {
			fmt.eprintln("nabla: invalid configuration: a model cannot be excluded and customized at the same time")
		}
		return {}, {}, false
	}
	configured.allocator = allocator
	listed := true
	for &source in sources {
		cloned, clone_error := strings.clone(source.id, allocator)
		if clone_error != nil {
			listed = false
			break
		}
		if _, append_error := append(&configured, cloned); append_error != nil {
			delete(cloned, allocator)
			listed = false
			break
		}
	}
	if !listed {
		for id in configured { delete(id, allocator) }
		delete(configured)
		fmt.eprintln("nabla: the configured providers could not be listed")
		return {}, {}, false
	}
	return resolved, configured, true
}

// run_catalog resolves the configuration into the catalog and opens the session.
// Which provider and model run is applied separately, so the front-end can start
// without a selection and choose one in the TUI. Errors print to stderr; false
// means the caller should exit.
@(require_results)
run_catalog :: proc(sources: []agent.Catalog_Provider_Source, mcp_servers: []agent.MCP_Server_Config, setup: ^Run_Setup, start: Session_Start) -> bool {
	setup.alloc = context.allocator
	ok := false
	defer if !ok { run_setup_destroy(setup) }

	setup.mcp_servers = mcp_servers
	// The runtime's slots are fixed before any definition can borrow a binding.
	mcp_ok: bool
	setup.mcp, mcp_ok = mcp_runtime_make(mcp_servers, setup.alloc)
	if !mcp_ok {
		fmt.eprintln("nabla: the MCP runtime could not be allocated")
		return false
	}

	catalog, configured, resolved := resolve_run_catalog(sources, setup.alloc)
	if !resolved { return false }
	setup.catalog = catalog
	setup.configured = configured

	workspace, workspace_error := os.get_working_directory(setup.alloc)
	if workspace_error != nil || workspace == "" {
		fmt.eprintln("nabla: cannot determine working directory")
		return false
	}
	defer delete(workspace, setup.alloc)

	if !run_session_attach(setup, workspace, start, stderr_writer()) { return false }

	ok = true
	return true
}

// run_session_attach opens the session the launch asked for and makes it the running one;
// a launch that cannot open what it asked for fails rather than quietly starting a
// different one.
@(require_results)
run_session_attach :: proc(setup: ^Run_Setup, workspace: string, start: Session_Start, stderr: io.Writer) -> bool {
	directory, directory_error := agent.xdg_directory(.State, setup.alloc)
	if directory_error != .None {
		fmt.wprintln(stderr, "nabla: cannot resolve the state directory for sessions")
		return false
	}
	setup.journal_directory = directory
	locks, replaced, locks_error := agent.session_lock_directory(setup.alloc)
	if locks_error != .None {
		fmt.wprintln(stderr, "nabla: cannot resolve the directory for session locks")
		return false
	}
	if replaced {
		fmt.wprintf(stderr, "nabla: warning: XDG_RUNTIME_DIR is not an absolute path; session locks are kept in %s\n", locks)
	}
	setup.lock_directory = locks
	setup.run = journal.run_id_create()

	opened, message, ok := session_open(setup, start, workspace)
	if !ok {
		fmt.wprintln(stderr, "nabla:", message)
		delete(message, setup.alloc)
		return false
	}
	report_recovery(opened.recovery, opened.queued)
	if problem := session_install(setup, &opened); problem != "" {
		fmt.wprintln(stderr, "nabla:", problem)
		return false
	}
	return true
}

// Opened_Session is a session resolved and taken in its own journal, not yet
// running. It owns store and its strings until session_install takes them.
Opened_Session :: struct {
	store:       ^journal.Journal,
	id:          journal.Session_Id,
	workspace:   string,
	branch:      journal.Branch_Id,
	head:        journal.Node_Id,
	// provider and model are what the session's last turn ran with, "" for a new session.
	provider:    string,
	model:       string,
	effort:      string,
	recovery:    journal.Recovery,
	// queued is how many lines the session accepted and never delivered, which go with the
	// next prompt.
	queued:      int,
	// own_queued counts the queued lines this process wrote as a follower, which a takeover
	// delivers.
	own_queued:  int,
	// following says store follows the session another process claimed. follow is where its
	// reading of the journal starts.
	following:   bool,
	follow:      agent.Follow,
	pending:     []journal.Record, // owned, captured with the follower cursor and head
	// settle_busy says the failure that stopped settling was another writer holding
	// the database, which a later attempt may get past.
	settle_busy: bool,
}

opened_session_destroy :: proc(opened: ^Opened_Session, allocator: mem.Allocator) {
	journal.records_destroy(opened.pending, allocator)
	// The opened session is being released; its close failure changes nothing here.
	_ = session_store_close(opened.store, allocator)
	delete(opened.workspace, allocator)
	delete(opened.provider, allocator)
	delete(opened.model, allocator)
	delete(opened.effort, allocator)
	opened^ = {}
}

// session_open resolves start and takes the session in a journal of its own, so a
// refusal leaves the running session untouched. An existing session is claimed and
// what an earlier run left open is settled. A new session is only an id: its first
// prompt creates it. The message is owned by setup.alloc.
@(require_results)
session_open :: proc(setup: ^Run_Setup, start: Session_Start, launch_workspace: string) -> (opened: Opened_Session, message: string, ok: bool) {
	allocator := setup.alloc
	defer if !ok { opened_session_destroy(&opened, allocator) }

	open_error: journal.Error
	opened.store, open_error = session_store_open(setup)
	if open_error != nil { return {}, session_error_message("cannot open the session database", open_error, allocator), false }

	// The launch's first journal carries its run.started, before any claim of this launch.
	// It is buffered: the session install takes the journal, and the first commit writes it.
	if !setup.run_open {
		journal.append_record(opened.store, {kind = .Run_Started}, journal.Run_Started{pid = int(os.get_pid())})
	}

	filter := journal.Session_Filter {
		limit = 1,
	}
	// A launch that asks for nothing starts fresh, so the zero value opens a new session.
	requested := start
	if requested == nil { requested = Start_Fresh{} }
	resume_latest := false
	resume_id := ""
	switch id in requested {
	case Start_Fresh:
		opened.id = journal.session_id_create()
		workspace, workspace_error := strings.clone(launch_workspace, allocator)
		if workspace_error != nil {
			return opened, fmt.aprintf("the new session's directory could not be stored", allocator = allocator), false
		}
		opened.workspace = workspace
		opened.branch = journal.INITIAL_BRANCH
		return opened, "", true
	case Start_Resume_Latest:
		filter.workspace = launch_workspace
		filter.role = .Main
		resume_latest = true
	case Start_Resume_Id:
		resume_id = string(id)
		parsed, valid := journal.session_id_parse(resume_id)
		if !valid || parsed == {} { return opened, fmt.aprintf("%s is not a session id", resume_id, allocator = allocator), false }
		filter.session = parsed
	}

	summaries, list_error := journal.list_sessions(opened.store, filter, allocator)
	if list_error != nil { return opened, session_error_message("cannot list sessions", list_error, allocator), false }
	defer journal.session_summaries_destroy(summaries, allocator)
	if len(summaries) == 0 {
		if resume_latest {
			return opened, fmt.aprintf("no session has run in %s; nothing to resume", launch_workspace, allocator = allocator), false
		}
		return opened, fmt.aprintf("session %s does not exist", resume_id, allocator = allocator), false
	}
	summary := &summaries[0]
	// A session carries the directory it ran in, and an id can name one from
	// anywhere, so the directory is checked rather than assumed.
	if !os.is_dir(summary.workspace) {
		return opened, fmt.aprintf("the session's directory is not usable: %s", summary.workspace, allocator = allocator), false
	}

	opened.id = summary.id
	// The session this process already shows cannot be opened a second time: its own claim
	// would make it a follower of itself.
	if setup.store != nil && (setup.store.claimed == summary.id || setup.store.followed == summary.id) {
		return opened, fmt.aprintf("the session is already open here", allocator = allocator), false
	}
	if _, claim_error := journal.claim(opened.store, summary.id); claim_error != nil {
		if claim_error != journal.Journal_Error.Claimed {
			return opened, session_error_message("cannot take the session", claim_error, allocator), false
		}
		if !setup.shared_sessions {
			return opened,
				fmt.aprintf("cannot take the session: another process runs it, and this mode cannot follow a running session", allocator = allocator),
				false
		}
		if follow_message, followed := session_follow(setup, &opened); !followed { return opened, follow_message, false }
	}
	if settle_message, settled := session_settle(&opened, summary.workspace, allocator); !settled { return opened, settle_message, false }
	return opened, "", true
}

// session_follow makes opened follow the session another process runs: it opens the
// session's lock file without the claim and arms the watch before session_settle captures
// the attachment snapshot, so a commit after the first read raises a wake. A failure leaves the watch on
// the target; the caller that keeps the running session restores it with app_watch_sync.
@(require_results)
session_follow :: proc(setup: ^Run_Setup, opened: ^Opened_Session) -> (message: string, ok: bool) {
	allocator := setup.alloc
	if follow_error := journal.follow(opened.store, opened.id); follow_error != nil {
		return session_error_message("cannot follow the session", follow_error, allocator), false
	}
	if watch_error := app_watch_session(setup, opened.id); watch_error != nil {
		return fmt.aprintf("cannot watch the session: %v", watch_error, allocator = allocator), false
	}
	opened.following = true
	return "", true
}

// session_settle completes an opened session whose store holds the claim or follows it.
// A claimed session first settles what an earlier run left open and counts the lines it
// accepted and never delivered; either way it reads the session's head and the selection
// it last ran with. workspace is copied into opened. The message is owned by allocator.
@(require_results)
session_settle :: proc(opened: ^Opened_Session, workspace: string, allocator: mem.Allocator) -> (message: string, ok: bool) {
	store := opened.store
	id := opened.id
	snapshot_open := false
	defer if snapshot_open {
		if snapshot_error := journal.end_read_snapshot(store); snapshot_error != nil {
			delete(message, allocator)
			opened.settle_busy = journal.error_is_busy(snapshot_error)
			message = session_error_message("cannot finish reading the session", snapshot_error, allocator)
			ok = false
		}
	}
	claimed := store.claimed != {}
	if claimed {
		recover_error: journal.Error
		opened.recovery, recover_error = journal.recover(store, agent.session_tool_output_directory(id, context.temp_allocator))
		if recover_error != nil {
			opened.settle_busy = journal.error_is_busy(recover_error)
			return session_error_message("cannot settle the session", recover_error, allocator), false
		}
	}
	if opened.following {
		if snapshot_error := journal.begin_read_snapshot(store); snapshot_error != nil {
			opened.settle_busy = journal.error_is_busy(snapshot_error)
			return session_error_message("cannot read the session", snapshot_error, allocator), false
		}
		snapshot_open = true
		follow_error: journal.Error
		opened.follow, follow_error = agent.follow_start(store, id)
		if follow_error != nil {
			opened.settle_busy = journal.error_is_busy(follow_error)
			return session_error_message("cannot read the session", follow_error, allocator), false
		}
	}
	head_error: journal.Error
	opened.branch, opened.head, head_error = journal.session_head(store, id)
	if head_error != nil {
		opened.settle_busy = journal.error_is_busy(head_error)
		return session_error_message("cannot read the session", head_error, allocator), false
	}

	if claimed || opened.following {
		delivered, delivered_error := journal.last_delivered_message(store, id)
		if delivered_error != nil {
			opened.settle_busy = journal.error_is_busy(delivered_error)
			return session_error_message("cannot read the session", delivered_error, allocator), false
		}
		waiting, waiting_error := journal.read_inbox(store, id, delivered, allocator)
		if waiting_error != nil {
			opened.settle_busy = journal.error_is_busy(waiting_error)
			return session_error_message("cannot read the session", waiting_error, allocator), false
		}
		for record in waiting {
			if record.kind != .User_Input { continue }
			opened.queued += 1
			if record.run == store.run { opened.own_queued += 1 }
		}
		if opened.following { opened.pending = waiting } else { journal.records_destroy(waiting, allocator) }
	}

	selection_record, selection_found, read_error := journal.read_latest(store, {session = id, kinds = {.Selection_Applied}}, allocator)
	if read_error != nil {
		opened.settle_busy = journal.error_is_busy(read_error)
		return session_error_message("cannot read the session selection", read_error, allocator), false
	}
	if selection_found {
		defer journal.record_destroy(&selection_record, allocator)
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		selection: journal.Selection_Applied
		if decode_error := journal.payload_decode(
			selection_record.data,
			&selection,
			context.temp_allocator,
			corruption_journal = opened.store,
			session = selection_record.session,
			seq = selection_record.seq,
		); decode_error != nil {
			opened.settle_busy = journal.error_is_busy(decode_error)
			return session_error_message("cannot read the session selection", decode_error, allocator), false
		}
		provider, provider_error := strings.clone(selection.provider, allocator)
		model, model_error := strings.clone(selection.model, allocator)
		effort, effort_error := strings.clone(selection.effort, allocator)
		if provider_error != nil || model_error != nil || effort_error != nil {
			delete(provider, allocator)
			delete(model, allocator)
			delete(effort, allocator)
			return fmt.aprintf("the session's model could not be stored", allocator = allocator), false
		}
		opened.provider = provider
		opened.model = model
		opened.effort = effort
	} else {
		latest, found, turn_read_error := journal.read_latest(opened.store, {session = id, kinds = {.Turn_Started}}, allocator)
		if turn_read_error != nil {
			opened.settle_busy = journal.error_is_busy(turn_read_error)
			return session_error_message("cannot read the session", turn_read_error, allocator), false
		}
		defer journal.record_destroy(&latest, allocator)
		if found {
			provider, provider_error := strings.clone(latest.provider, allocator)
			model, model_error := strings.clone(latest.model, allocator)
			if provider_error != nil || model_error != nil {
				delete(provider, allocator)
				delete(model, allocator)
				return fmt.aprintf("the session's model could not be stored", allocator = allocator), false
			}
			opened.provider = provider
			opened.model = model
		}
	}
	owned_workspace, workspace_error := strings.clone(workspace, allocator)
	if workspace_error != nil {
		return fmt.aprintf("the session's directory could not be stored", allocator = allocator), false
	}
	opened.workspace = owned_workspace
	return "", true
}

// session_install makes opened the running session in place of the one running,
// whose chat and journal it releases after the target chat initializes. It takes
// everything opened owns and leaves it zero. A problem, static text, leaves the running session
// intact. An opened session that carries the running store, as a takeover does, keeps it open.
// The new session takes the instructions and tools of its role, so a subagent session opened
// here is the agent its orchestrator ran.
@(require_results)
session_install :: proc(setup: ^Run_Setup, opened: ^Opened_Session) -> (problem: string) {
	new_session, tool_error := agent.chat_session_init(opened.store, opened.id, opened.branch, opened.head, opened.workspace, setup.alloc)
	if tool_error.kind != .None {
		if opened.store == setup.store { opened.store = nil }
		opened_session_destroy(opened, setup.alloc)
		return "the tool registry could not be allocated"
	}
	if role_problem := agent.chat_session_role_setup(&new_session, &new_session.tools); role_problem != "" {
		agent.chat_session_destroy(&new_session)
		if opened.store == setup.store { opened.store = nil }
		opened_session_destroy(opened, setup.alloc)
		return role_problem
	}

	if setup.store != nil {
		agent.chat_session_destroy(&setup.session)
		setup.workers_abandoned = setup.workers_abandoned || setup.session.workers_retained
	}
	// The session being replaced is released; its close failure changes nothing here.
	if setup.store != opened.store { _ = session_store_close(setup.store, setup.alloc) }
	delete(setup.workspace, setup.alloc)
	delete(setup.resumed_provider, setup.alloc)
	delete(setup.resumed_model, setup.alloc)
	delete(setup.resumed_effort, setup.alloc)
	setup.store = opened.store
	setup.run_open = true
	setup.workspace = opened.workspace
	setup.resumed_provider = opened.provider
	setup.resumed_model = opened.model
	setup.resumed_effort = opened.effort
	journal.records_destroy(setup.follow_pending, setup.alloc)
	setup.follow_pending = opened.pending
	setup.follow = opened.follow
	setup.takeover_failed = false
	setup.takeover_retryable = false
	setup.follow_input_busy = false
	opened^ = {}
	setup.session = new_session
	agent.chat_session_apply_harness(&setup.session, setup.harness_options)
	if watch_error := app_watch_sync(setup); watch_error != nil {
		agent.chat_runtime_message(&setup.session, .Warning, "the session cannot be watched, so lines other processes send it wait for the next prompt")
	}
	return ""
}

// app_following reports whether the running session is one another process runs. Owner
// thread only: the front-end reads Status.following instead.
@(require_results)
app_following :: proc(app: ^App) -> bool {
	store := app.setup.store
	return store != nil && store.followed != {}
}

// app_watch_session makes the watch cover the lock file of session, or nothing for the
// zero session, and removes the watch on the one it covered. The watch is armed when this
// returns, so a caller that reads the session after it misses no commit. A failure leaves
// session recorded as watched, so a worker that syncs again does not repeat the failure; a
// caller that needs the watch reports it.
@(require_results)
app_watch_session :: proc(setup: ^Run_Setup, session: journal.Session_Id) -> os.Error {
	if setup.watched == session { return nil }
	if setup.watched != {} { agent.session_watch_remove(&setup.watch, setup.watch_id) }
	setup.watched = session
	setup.watch_id = 0
	if session == {} { return nil }
	path := agent.session_lock_path(setup.lock_directory, session, context.temp_allocator) or_return
	setup.watch_id = agent.session_watch_add(&setup.watch, path) or_return
	return nil
}

// app_watch_sync points the watch at the running session's lock file, which exists once
// the session is claimed or followed, so a session nobody has prompted yet has none. It
// does nothing for a front-end that does not share sessions.
@(require_results)
app_watch_sync :: proc(setup: ^Run_Setup) -> os.Error {
	if !setup.shared_sessions { return nil }
	wanted: journal.Session_Id
	if setup.store != nil {
		wanted = setup.store.claimed
		if wanted == {} { wanted = setup.store.followed }
	}
	return app_watch_session(setup, wanted)
}

// session_store_open opens a journal of this run on the launch's state directory,
// owned by setup.alloc.
@(require_results)
session_store_open :: proc(setup: ^Run_Setup) -> (store: ^journal.Journal, error: journal.Error) {
	store = new(journal.Journal, setup.alloc) or_return
	if open_error := journal.open(store, setup.journal_directory, setup.lock_directory, setup.run, .Read_Write, setup.alloc); open_error != nil {
		free(store, setup.alloc)
		return nil, open_error
	}
	return store, nil
}

// session_store_close records the launch's end when finish_run says the store carries the
// last of it, commits it, and closes the store, which records the release of the store's
// session. A commit that fails changes nothing here: the store is closing either way.
// Owner thread only.
@(require_results)
session_store_close :: proc(store: ^journal.Journal, allocator: mem.Allocator, finish_run := false) -> journal.Error {
	if store == nil { return nil }
	if finish_run {
		journal.append_record(store, {kind = .Run_Finished}, journal.Run_Finished{})
		_, _ = journal.commit(store)
	}
	close_error := journal.close(store)
	free(store, allocator)
	return close_error
}

// run_store_close ends the launch's use of the journal: the launch's run.finished when it
// recorded a run.started, then the close, which records the session's release. A launch whose
// last session was closed has no running store, so one is opened to carry run.finished; when
// that fails the run reads as ended abruptly and the error is returned. Call it on the
// thread that owns the journal.
@(require_results)
run_store_close :: proc(setup: ^Run_Setup) -> journal.Error {
	finish := setup.run_open
	setup.run_open = false
	store := setup.store
	if store == nil && finish {
		open_error: journal.Error
		store, open_error = session_store_open(setup)
		if open_error != nil { return open_error }
	}
	return session_store_close(store, setup.alloc, finish)
}

// session_error_message is what for a person, followed by the journal's reason,
// owned by allocator. A message that cannot itself be allocated falls back to the
// plain reason, so the caller always gets something it can report.
@(require_results)
session_error_message :: proc(what: string, error: journal.Error, allocator: mem.Allocator) -> string {
	detail := journal.error_text(error, allocator)
	defer delete(detail, allocator)
	message, join_error := strings.concatenate({what, ": ", detail}, allocator)
	if join_error != nil { return fmt.aprintf("%s: out of memory", what, allocator = allocator) }
	return message
}

// report_recovery says what an earlier run left behind, so a resumed session
// starts knowing which calls have an outcome the harness never saw and which lines it
// accepted and never delivered.
report_recovery :: proc(recovery: journal.Recovery, queued: int) {
	if recovery.calls > 0 {
		fmt.eprintf("nabla: %d tool call(s) never reported a result; their results say whether they ran\n", recovery.calls)
	}
	if queued > 0 {
		fmt.eprintf("nabla: %d queued line(s) will go with your next prompt\n", queued)
	}
}

// selection_record remembers the model the user chose, so the next launch starts with it.
@(require_results)
selection_record :: proc(store: ^journal.Journal, provider, model, effort: string) -> journal.Error {
	journal.append_record(store, {kind = .Selection_Changed}, journal.Selection_Changed{provider = provider, model = model, effort = effort})
	_, commit_error := journal.commit(store)
	return commit_error
}

// selection_latest reads the model the user last chose, owned by allocator.
@(require_results)
selection_latest :: proc(store: ^journal.Journal, allocator: mem.Allocator) -> (selection: journal.Selection_Changed, found: bool, error: journal.Error) {
	record: journal.Record
	record, found = journal.read_latest(store, {kinds = {.Selection_Changed}}, allocator) or_return
	defer journal.record_destroy(&record, allocator)
	if !found { return }
	journal.payload_decode(record.data, &selection, allocator, corruption_journal = store, session = record.session, seq = record.seq) or_return
	return selection, true, nil
}

selection_destroy :: proc(selection: ^journal.Selection_Changed, allocator: mem.Allocator) {
	delete(selection.provider, allocator)
	delete(selection.model, allocator)
	delete(selection.effort, allocator)
	selection^ = {}
}

provider_usable :: agent.provider_usable

// provider_configured reports whether the user's own configuration named the
// provider; models.dev contributes providers the user never set up, and their
// credentials are not the user's to resolve.
@(require_results)
provider_configured :: proc(app: ^App, provider_id: string) -> bool {
	for id in app.setup.configured {
		if id == provider_id {
			return true
		}
	}
	return false
}

// pending_selection_clear releases whatever the intent holds and zeroes it, so it is
// safe on an empty intent and on one whose strings a boundary already took.
pending_selection_clear :: proc(pending: ^Maybe(Pending_Selection), allocator: mem.Allocator) {
	if selected, ok := pending^.?; ok {
		delete(selected.provider, allocator)
		delete(selected.model, allocator)
	}
	pending^ = nil
}

pending_target_clear :: proc(pending: ^Maybe(Pending_Target), allocator: mem.Allocator) {
	if fit, ok := pending^.?; ok {
		live := fit
		agent.model_selection_destroy(&live.target, allocator)
	}
	pending^ = nil
}

selection_intent_clear :: proc(app: ^App) {
	pending: Maybe(Pending_Selection)
	if sync.mutex_guard(&app.run.mu) {
		pending = app.run.pending
		app.run.pending = nil
	}
	pending_selection_clear(&pending, app.run.alloc)
	pending_target_clear(&app.run.pending_target, app.run.alloc)
}

// selection_request records the selection the user asked for and wakes the worker. The
// choice cannot travel in the work item, because a turn owns the session until its next
// request boundary and applying a selection edits the session, so it waits in run state
// for whichever boundary comes first.
selection_request :: proc(app: ^App, provider_id, model_id: string) {
	if runtime_stopping(app) { return }
	if runtime_following(app) {
		follower_refuse(app, "changing the model")
		return
	}
	provider, provider_error := strings.clone(provider_id, app.run.alloc)
	model, model_error := strings.clone(model_id, app.run.alloc)
	if provider_error != nil || model_error != nil {
		delete(provider, app.run.alloc)
		delete(model, app.run.alloc)
		snap_append(app, .Error, "the model selection could not be stored")
		return
	}
	previous: Maybe(Pending_Selection)
	if sync.mutex_guard(&app.run.mu) {
		previous = app.run.pending
		app.run.pending = Pending_Selection {
			provider = provider,
			model    = model,
		}
	}
	pending_selection_clear(&previous, app.run.alloc)
	enqueue(app, .Model)
}

// app_selection_service resolves and fits the newest explicit intent at a safe owner
// boundary. A pending fit stays owned here while background compaction advances.
@(require_results)
app_selection_service :: proc(app: ^App) -> bool {
	if runtime_stopping(app) { return false }
	newer: Maybe(Pending_Selection)
	if sync.mutex_guard(&app.run.mu) {
		newer = app.run.pending
		app.run.pending = nil
	}
	if selected, newer_ok := newer.?; newer_ok {
		pending_target_clear(&app.run.pending_target, app.run.alloc)
		defer pending_selection_clear(&newer, app.run.alloc)
		if app.setup.session.state == .Idle {
			if warning := app_tools_refresh(app); warning != "" { snap_append(app, .Warning, warning) }
		}
		target, problem := selection_target_resolve(app, selected.provider, selected.model, app.run.alloc)
		defer if problem != "" { delete(problem, context.temp_allocator) }
		superseded := false
		if sync.mutex_guard(&app.run.mu) {
			superseded = app.run.pending != nil
		}
		if superseded {
			agent.model_selection_destroy(&target, app.run.alloc)
			return false
		}
		if problem != "" {
			selection_fail(app, problem)
			return false
		}
		app.run.pending_target = Pending_Target {
			target = target,
		}
	}
	if app.run.pending_target == nil { return false }
	pending := &app.run.pending_target.?

	status, problem, gate_error := agent.chat_selection_check(
		&app.setup.session,
		pending.target,
		&pending.transition,
		app.compact_on_switch,
		app.run.connection,
	)
	defer if problem != "" { delete(problem, context.temp_allocator) }
	if gate_error != nil {
		detail := journal.error_text(gate_error, context.temp_allocator)
		app.setup.session.storage_failed = true
		selection_fail(app, fmt.tprintf("the model switch could not be recorded: %s", detail))
		pending_target_clear(&app.run.pending_target, app.run.alloc)
		return false
	}
	// A newer UI request may arrive while the gate commits or advances compaction.
	superseded := false
	if sync.mutex_guard(&app.run.mu) {
		superseded = app.run.pending != nil
	}
	if superseded {
		pending_target_clear(&app.run.pending_target, app.run.alloc)
		return false
	}
	switch status {
	case .Ready:
		installed := selection_install(app, pending.target, "", true)
		pending_target_clear(&app.run.pending_target, app.run.alloc)
		return installed
	case .Pending:
		if !pending.announced {
			snap_append(app, .Notice, "model switch is waiting for background compaction")
			pending.announced = true
		}
	case .Refused:
		if problem == "" { problem = "the requested model does not fit the active conversation" }
		selection_fail(app, problem)
		pending_target_clear(&app.run.pending_target, app.run.alloc)
	}
	return false
}

// app_steer_apply is the turn's request-boundary hook. It installs the selection the
// user asked for since the last request and returns the connection the next request is
// built for.
app_steer_apply :: proc(steer: ^agent.Steer_Context) -> ai.Provider_Connection {
	app := cast(^App)steer.apply_data
	catalog_selection_sync(app)
	if app_selection_service(app) { refresh_status(app) }
	sync.mutex_guard(&app.run.mu)
	return app.run.connection
}

// selection_target_resolve copies one selection out of the published catalog. The target
// is owned by allocator; problem is temporary and must be consumed before that allocator resets.
@(require_results)
selection_target_resolve :: proc(app: ^App, provider_id, model_id: string, allocator: mem.Allocator) -> (agent.Model_Selection, string) {
	// The catalog entry is copied out while it is the published one: a refresh releases the
	// catalog it lives in, and the connection built from it outlives that moment.
	sync.mutex_guard(&app.catalog_mu)
	resolved, problem := agent.model_selection_resolve(&app.setup.catalog, provider_id, model_id, allocator)
	return resolved, problem
}

// selection_install installs a resolved target on the session owner. target is borrowed;
// its owner keeps it alive through this call.
@(require_results)
selection_install :: proc(app: ^App, target: agent.Model_Selection, effort: string, announce: bool) -> bool {
	api := target.connection.API

	running := &app.setup.session
	// The level to carry over: an explicit one, or the one already in effect, which
	// a model switch keeps whenever the new model allows it. It may alias the session's
	// stored effort, which selecting replaces, so it is copied first.
	desired := effort
	if desired == "" { desired = running.effort }
	desired = agent.model_selection_effort(target, desired)
	carried, carried_error := strings.clone(desired, app.setup.alloc)
	if carried_error != nil {
		selection_fail(app, "the reasoning effort could not be copied")
		return false
	}
	defer delete(carried, app.setup.alloc)

	// The runtime keeps its own copy of the selection, and provider_id and model_id
	// may alias the strings being replaced, so the replacements are built before
	// the old values are released.
	setup_provider, provider_error := strings.clone(target.provider_id, app.setup.alloc)
	setup_model, model_error := strings.clone(target.model_id, app.setup.alloc)
	setup_endpoint, endpoint_error := strings.clone(target.connection.Endpoint, app.run.alloc)
	credential, credential_error := strings.clone(target.connection.Credential, app.setup.alloc)
	if provider_error != nil || model_error != nil || endpoint_error != nil || credential_error != nil {
		delete(setup_provider, app.setup.alloc)
		delete(setup_model, app.setup.alloc)
		delete(setup_endpoint, app.run.alloc)
		delete(credential, app.setup.alloc)
		selection_fail(app, "the model selection could not be stored")
		return false
	}
	installed, applied, record_error := agent.chat_selection_install(running, target, carried, app.run.connection)
	if !installed {
		delete(setup_provider, app.setup.alloc)
		delete(setup_model, app.setup.alloc)
		delete(setup_endpoint, app.run.alloc)
		delete(credential, app.setup.alloc)
		selection_fail(app, "the model selection could not be stored")
		return false
	}
	if !applied { snap_append(app, .Warning, "the reasoning effort could not be applied") }
	if record_error != nil {
		running.storage_failed = true
		selection_fail(app, "the selected model was installed but its session record could not be committed")
		return false
	}

	if sync.mutex_guard(&app.run.mu) {
		if app.setup.credential != "" {
			if _, append_error := append(&app.retired_connection_strings, app.setup.credential); append_error != nil {
				// Keep the old credential rather than freeing it under an operation that
				// may still be using it.
				snap_report_dropped_locked(app)
			}
		}
		app.setup.credential = credential
		app.setup.api = api
		// The endpoint the connection being replaced borrowed stays valid for any turn
		// that already holds it.
		if app.endpoint != "" {
			if _, append_error := append(&app.retired_connection_strings, app.endpoint); append_error != nil {
				// The endpoint is left unfreed rather than freed under a turn that may
				// still be talking to it, which is a leak and not a dangling pointer.
				snap_report_dropped_locked(app)
			}
		}
		app.endpoint = setup_endpoint
		app.run.connection = ai.Provider_Connection {
			API        = api,
			Endpoint   = app.endpoint,
			Credential = credential,
		}
		delete(app.setup.provider_id, app.setup.alloc)
		app.setup.provider_id = setup_provider
		delete(app.setup.model_id, app.setup.alloc)
		app.setup.model_id = setup_model
	}
	// A follower never records a selection: it would rewrite the user's default model
	// for a session whose model it does not choose.
	if app.setup.owns_selection && announce && !app_following(app) {
		if default_error := selection_record(app.setup.store, target.provider_id, target.model_id, running.effort); default_error != nil {
			running.storage_failed = true
			selection_fail(app, "the selected model was installed but its default could not be committed")
			return false
		}
	}
	if app.setup.owns_selection {
		sync.mutex_guard(&app.run.mu)
		selection_publish_locked(app, target.provider_id, target.model_id, announce)
	}

	return true
}

@(require_results)
selection_apply_direct :: proc(app: ^App, provider_id, model_id, effort: string, announce: bool) -> bool {
	target, problem := selection_target_resolve(app, provider_id, model_id, app.run.alloc)
	defer if problem != "" { delete(problem, context.temp_allocator) }
	if problem != "" {
		selection_fail(app, problem)
		return false
	}
	defer agent.model_selection_destroy(&target, app.run.alloc)
	return selection_install(app, target, effort, announce)
}

// selection_publish_locked shows an applied selection to the front-end. The
// caller holds the runtime mutex, because the status block is what the frame
// reads; a headless run has no frame and never calls this.
@(private)
selection_publish_locked :: proc(app: ^App, provider_id, model_id: string, announce := true) {
	running := &app.setup.session
	status := &app.run.snap.status
	snap_status_replace(app, &status.provider_id, provider_id)
	snap_status_replace(app, &status.model_id, model_id)
	// The effort and the window apply here too, not only through refresh_status: a
	// restored selection must show both before the first work item runs.
	snap_status_replace(app, &status.effort, running.effort)
	// The levels travel with the model, because only the worker owns the session
	// and the /effort menu is built on the front-end.
	for level in status.effort_levels { delete(level, app.run.alloc) }
	clear(&status.effort_levels)
	for level in running.effort_levels {
		cloned, clone_error := strings.clone(level, app.run.alloc)
		if clone_error != nil {
			snap_report_dropped_locked(app)
			continue
		}
		if _, append_error := append(&status.effort_levels, cloned); append_error != nil {
			delete(cloned, app.run.alloc)
			snap_report_dropped_locked(app)
			break
		}
	}
	status.context_window = running.capacity.window
	delete(app.run.snap.setup_error, app.run.alloc)
	app.run.snap.setup_error = ""
	app.run.snap.setup_error_failed = false
	if announce { snap_append_locked(app, .Notice, fmt.tprintf("model set to %s / %s", provider_id, model_id)) }
	snap_publish_locked(app)
}

// apply_startup_selection chooses the model a launch runs with: the two flags if they are
// given, otherwise the stored selection, otherwise the model a resumed session recorded.
// A stale selection is not fatal; it leaves the launch to the model menu. False means the
// launch cannot continue, and the reason is in the snapshot.
@(require_results)
apply_startup_selection :: proc(app: ^App, flag_provider, flag_model: string) -> bool {
	if flag_provider != "" || flag_model != "" {
		if flag_provider == "" || flag_model == "" {
			selection_fail(app, "--provider and --model must be given together")
			return false
		}
		return selection_apply_direct(app, flag_provider, flag_model, "", true)
	}
	selection, found, load_error := selection_latest(app.setup.store, app.run.alloc)
	defer selection_destroy(&selection, app.run.alloc)
	if load_error != nil {
		// A database the store just opened failing to answer this is worth saying
		// out loud, but the launch can still proceed to the model menu.
		detail := journal.error_text(load_error, context.temp_allocator)
		fmt.eprintln("nabla: the selection could not be read:", detail)
	}
	applied := found && selection_apply_direct(app, selection.provider, selection.model, selection.effort, true)
	if !applied && app.setup.resumed_provider != "" && app.setup.resumed_model != "" {
		// A fallback that also fails leaves the launch to the model menu, and the
		// snapshot already carries why.
		_ = selection_apply_direct(app, app.setup.resumed_provider, app.setup.resumed_model, app.setup.resumed_effort, true)
	}
	return true
}

// SETUP_ERROR_ALLOCATION is shown when the selection reason itself could not be
// copied into the snapshot.
SETUP_ERROR_ALLOCATION :: "the setup error could not be allocated"

setup_error_text :: proc(app: ^App) -> string {
	if app.run.snap.setup_error_failed { return SETUP_ERROR_ALLOCATION }
	return app.run.snap.setup_error
}

// selection_fail records why a selection could not apply. The model menu shows it
// directly; chat mode sees it as a transcript warning.
selection_fail :: proc(app: ^App, message: string) {
	sync.mutex_guard(&app.run.mu)
	delete(app.run.snap.setup_error, app.run.alloc)
	app.run.snap.setup_error = ""
	app.run.snap.setup_error_failed = false
	cloned, clone_error := strings.clone(message, app.run.alloc)
	if clone_error != nil {
		app.run.snap.setup_error_failed = true
	} else {
		app.run.snap.setup_error = cloned
	}
	snap_append_locked(app, .Warning, message)
	snap_publish_locked(app)
}
