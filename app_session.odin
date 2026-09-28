#+build linux
package main

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
	harness_options:   agent.Harness_Options,
	catalog:           agent.Catalog,
	api:               ai.API_Kind,
	credential:        string, // owned,
	// store is the running session's journal, owned. Chat_Session borrows it, so it
	// is replaced only together with the chat.
	store:             ^journal.Journal,
	journal_directory: string, // owned
	run:               journal.Run_Id,
	// log is this launch's diagnostic stream. It is opened before the store and
	// closed after it, so a launch that cannot reach the store still says so.
	log:               agent.Log,
	// log_binding is what context.logger points at while the run is logging. It
	// lives here, next to the writer, so it outlives every logger value that
	// borrows it.
	log_binding:       agent.Log_Binding,
	// log_cleanup is what the retention pass did, held until the run's logger is
	// installed so the pass is reported after run.started rather than before it.
	log_cleanup:       agent.Log_Cleanup_Summary,
	session:           agent.Chat_Session,
	workspace:         string, // owned; the directory sessions here run in
	provider_id:       string, // owned,
	model_id:          string, // owned,
	// resumed_provider and resumed_model are what the opened session last ran
	// with. They are empty for a new session, and they are only a fallback for
	// when no selection exists anywhere else.
	resumed_provider:  string, // owned,
	resumed_model:     string, // owned,
	// configured holds the provider ids the user's own configuration declares;
	// models.dev also contributes providers, and the model menu offers only the
	// configured ones, whose credentials the user actually set up.
	configured:        [dynamic]string, // owned,
	// owns_selection says whether this run's model choice is the user's. The
	// interactive harness owns it: its choice is published to the front-end and
	// remembered for the next launch. A headless or child run does not, because it
	// selects a model for one job and must not change what the user starts with.
	owns_selection:    bool,
	// mcp_servers is borrowed from the launch's configuration, which outlives the
	// setup. mcp owns the running MCP clients and the bindings a tool definition may
	// borrow, so it is released after the session that holds the registry.
	mcp_servers:       []agent.MCP_Server_Config,
	mcp:               MCP_Runtime,
	alloc:             mem.Allocator,
}

App :: struct {
	setup:              Run_Setup,
	// catalog_mu protects publication of a replacement catalog. A publication
	// releases the catalog it replaces, so anything read out of a catalog is either
	// copied while the lock is held or owned by this run.
	catalog_mu:         sync.Mutex,
	// catalog_refresh_at is when the last catalog refresh was asked for, on the
	// monotonic clock, and catalog_refreshed says one was asked for at all: a zero
	// tick is not a time. It is the cooldown's own record: a refresh runs because a
	// person asked to see the catalog, and asking twice in a row is the same
	// question. Only the front-end asks, so it is front-end state.
	catalog_refresh_at: time.Tick,
	catalog_refreshed:  bool,
	// models_dev_read_at is when this run last read models.dev into sources. The
	// document behind it changes on the order of days, so a run re-reads it far less
	// often than the provider listings, which change when a provider adds a model. It
	// is only meaningful while models_dev_sources is non-empty, which is what says a
	// read happened.
	models_dev_read_at: time.Tick,
	// endpoint is the base_url the running connection borrows. The catalog a model
	// was selected from is released when a refresh replaces it, so the endpoint is
	// owned here rather than borrowed from a catalog entry a publication frees.
	endpoint:           string, // owned,
	// retired_endpoints are endpoints a turn in flight may still be talking to. A
	// selection can change at a request boundary inside a turn, so the endpoint the
	// request before it was given stays valid until the run ends.
	retired_endpoints:  [dynamic]string, // owned,
	catalog_sources:    []agent.Catalog_Provider_Source, // borrowed for tui_run
	provider_sources:   [dynamic]agent.Catalog_Provider_Source, // owned refresh snapshot
	models_dev_sources: [dynamic]agent.Catalog_Provider_Source, // owned refresh snapshot
	catalog_refresh:    Catalog_Refresh_Chan,
	catalog_worker:     ^thread.Thread,
	catalog_revision:   u64,
	catalog_seen:       u64,
	terminal:           ^term.Session,
	tty:                ^os.File,
	parser:             input.Parser,
	raw:                [dynamic]input.Event, // owned; the latest input batch,
	run:                Runtime,
	storage:            ^Frame_Storage,
	home:               string, // owned; shortens the footer path,
	input:              widgets.Input,
	scroll:             int, // rows scrolled back; 0 follows the bottom,
	// conv_scroll_range is the conversation's scrollable height in rows, as
	// the last completed layout frame reported it. The offset handed to layout
	// is range - scroll, so a scroll of 0 pins the newest content to the
	// bottom and the range shrinks and grows with the transcript.
	conv_scroll_range:  int,
	generation_seen:    u64,
	// steer_active is whether the runtime was running when this thread last looked. The
	// transition back to idle is what returns input the turn never applied to the
	// prompt. The loop reads and writes it on the front-end's thread only.
	steer_active:       bool,
	// viewport_reported latches the one warning a terminal that reports no size
	// produces. The loop reads it on the front-end's thread only.
	viewport_reported:  bool,
	spin_lap:           time.Tick, // last working-frame advance,
	spin_frame:         int,
	// menu is the open choice list, when menu_open. One component serves every
	// command whose argument is picked from a list.
	menu:               Menu,
	menu_open:          bool,
	// completion_query and completion_index carry a Tab cycle: the prefix the
	// cycle began with and where it has reached. Any other key ends the cycle.
	completion_query:   string, // owned,
	completion_index:   int,
	completion_active:  bool,
	// history holds the prompts submitted this run, oldest first;
	// history_index is the entry the prompt line shows, or len(history) while a
	// fresh line is composed. Only prompts enter it: a slash command is routed
	// by dispatch_command and is not one. The zero value works: the list grows
	// on the first submitted prompt.
	history:            [dynamic]string, // owned,
	history_index:      int,
	// history_draft is the fresh line as the arrow keys left it when they first
	// walked into history: stepping forward past the newest entry puts it back.
	// It is what the user is typing rather than a submitted prompt, so it never
	// joins history, and a whole-line clear drops it. The empty string means
	// nothing is kept.
	history_draft:      string, // owned,
	columns:            int,
	rows:               int,
	// conversation_rect is the cells the transcript occupied in the last frame. A
	// mouse report is in screen cells, so this is what converts one into the
	// conversation's own coordinates.
	conversation_rect:  tui.Cell_Rect,
	// selecting marks a drag in progress, and the anchor and cursor are the cells
	// it spans. The selection lives only while the drag does: the release copies
	// what it covers, so there is no highlight left to drift when the transcript
	// moves under it.
	selecting:          bool,
	selection_anchor:   Cell_Point,
	selection_cursor:   Cell_Point,
	quit:               bool,
}

// resolve_run_catalog builds the initial resolved catalog from local data only:
// the user's configuration, any provider listings already cached, and the last
// models.dev document. Network refresh is owned by the interactive runtime.
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
	names := make([]string, len(sources), context.temp_allocator)
	defer delete(names, context.temp_allocator)
	for source, index in sources { names[index] = source.id }

	discovered := agent.provider_models_cached(sources, allocator = allocator)
	defer agent.catalog_sources_destroy(&discovered, allocator)
	models_dev, _ := agent.models_dev_cached_sources(providers = names, allocator = allocator)
	defer agent.catalog_sources_destroy(&models_dev, allocator)
	resolved, resolve_error := agent.resolve_catalog(sources, discovered[:], models_dev[:], allocator)
	if resolve_error != .None {
		fmt.eprintln("nabla: invalid configuration: a model cannot be excluded and customized at the same time")
		return {}, {}, false
	}
	configured.allocator = allocator
	for &source in sources {
		append(&configured, strings.clone(source.id, allocator))
	}
	return resolved, configured, true
}

// run_catalog resolves the configuration into the catalog and opens the session.
// Which provider and model run is applied separately, so the front-end can start
// without a selection and choose one in the TUI. Errors print to stderr; false
// means the caller should exit.
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

// run_session_attach opens the session the launch asked for and makes it the
// running one. A launch that cannot open the session it asked for fails rather
// than quietly starting a different one.
//
// The caller installs the launch's logger before this runs, so the adoption is
// recorded.
run_session_attach :: proc(setup: ^Run_Setup, workspace: string, start: Session_Start, stderr: io.Writer) -> bool {
	directory, directory_error := agent.xdg_directory(.State, setup.alloc)
	if directory_error != .None {
		fmt.wprintln(stderr, "nabla: cannot resolve the state directory for sessions")
		return false
	}
	setup.journal_directory = directory
	setup.run = journal.run_id_create()

	opened, message, ok := session_open(setup, start, workspace)
	if !ok {
		fmt.wprintln(stderr, "nabla:", message)
		delete(message, setup.alloc)
		return false
	}
	report_recovery(opened.recovery)
	if !session_install(setup, &opened) {
		fmt.wprintln(stderr, "nabla: the tool registry could not be allocated")
		return false
	}
	return true
}

// Opened_Session is a session resolved and taken in its own journal, not yet
// running. It owns store and its strings until session_install takes them.
Opened_Session :: struct {
	store:     ^journal.Journal,
	id:        journal.Session_Id,
	workspace: string,
	branch:    journal.Branch_Id,
	head:      journal.Node_Id,
	// provider and model are what the session's last turn ran with, "" for a new session.
	provider:  string,
	model:     string,
	recovery:  journal.Recovery,
}

opened_session_destroy :: proc(opened: ^Opened_Session, allocator: mem.Allocator) {
	session_store_close(opened.store, allocator)
	delete(opened.workspace, allocator)
	delete(opened.provider, allocator)
	delete(opened.model, allocator)
	opened^ = {}
}

// session_open resolves start and takes the session in a journal of its own, so a
// refusal leaves the running session untouched. An existing session is claimed and
// what an earlier run left open is settled. A new session is only an id: its first
// prompt creates it. The message is owned by setup.alloc.
session_open :: proc(setup: ^Run_Setup, start: Session_Start, launch_workspace: string) -> (opened: Opened_Session, message: string, ok: bool) {
	allocator := setup.alloc
	defer if !ok { opened_session_destroy(&opened, allocator) }

	open_error: journal.Error
	opened.store, open_error = session_store_open(setup)
	if open_error != nil { return {}, session_error_message("cannot open the session database", open_error, allocator), false }

	filter := journal.Session_Filter {
		limit = 1,
	}
	switch start.kind {
	case .New:
		opened.id = journal.session_id_create()
		opened.workspace = strings.clone(launch_workspace, allocator)
		opened.branch = journal.INITIAL_BRANCH
		log_session_claimed(opened.id, false, {})
		return opened, "", true
	case .Resume_Latest:
		filter.workspace = launch_workspace
		filter.role = .Main
	case .Resume_Id:
		id, valid := journal.session_id_parse(start.id)
		if !valid || id == {} { return opened, fmt.aprintf("%s is not a session id", start.id, allocator = allocator), false }
		filter.session = id
	}

	summaries, list_error := journal.list_sessions(opened.store, filter, allocator)
	if list_error != nil { return opened, session_error_message("cannot list sessions", list_error, allocator), false }
	defer journal.session_summaries_destroy(summaries, allocator)
	if len(summaries) == 0 {
		if start.kind == .Resume_Latest {
			return opened, fmt.aprintf("no session has run in %s; nothing to resume", launch_workspace, allocator = allocator), false
		}
		return opened, fmt.aprintf("session %s does not exist", start.id, allocator = allocator), false
	}
	summary := &summaries[0]
	// A session carries the directory it ran in, and an id can name one from
	// anywhere, so the directory is checked rather than assumed.
	if !os.is_dir(summary.workspace) {
		return opened, fmt.aprintf("the session's directory is not usable: %s", summary.workspace, allocator = allocator), false
	}

	opened.id = summary.id
	if _, claim_error := journal.claim(opened.store, summary.id); claim_error != nil {
		return opened, session_error_message("cannot take the session", claim_error, allocator), false
	}
	recover_error: journal.Error
	opened.recovery, recover_error = journal.recover(opened.store)
	if recover_error != nil { return opened, session_error_message("cannot settle the session", recover_error, allocator), false }
	head_error: journal.Error
	opened.branch, opened.head, head_error = journal.session_head(opened.store, summary.id)
	if head_error != nil { return opened, session_error_message("cannot read the session", head_error, allocator), false }

	latest, found, read_error := journal.read_latest(opened.store, {session = summary.id, kinds = {.Turn_Started}}, allocator)
	if read_error != nil { return opened, session_error_message("cannot read the session", read_error, allocator), false }
	defer journal.record_destroy(&latest, allocator)
	if found {
		opened.provider = strings.clone(latest.provider, allocator)
		opened.model = strings.clone(latest.model, allocator)
	}
	opened.workspace = strings.clone(summary.workspace, allocator)
	log_session_claimed(opened.id, true, opened.recovery)
	return opened, "", true
}

// session_install makes opened the running session in place of the one running,
// whose chat and journal it releases. It takes everything opened owns and leaves
// it zero. False means the tool registry could not be allocated, and no session runs.
session_install :: proc(setup: ^Run_Setup, opened: ^Opened_Session) -> bool {
	if setup.store != nil { agent.chat_session_destroy(&setup.session) }
	session_store_close(setup.store, setup.alloc)
	delete(setup.workspace, setup.alloc)
	delete(setup.resumed_provider, setup.alloc)
	delete(setup.resumed_model, setup.alloc)
	setup.store = opened.store
	setup.workspace = opened.workspace
	setup.resumed_provider = opened.provider
	setup.resumed_model = opened.model
	id, branch, head := opened.id, opened.branch, opened.head
	opened^ = {}

	tool_error: agent.Tool_Registry_Error
	setup.session, tool_error = agent.chat_session_init(setup.store, id, branch, head, setup.workspace, setup.alloc)
	if tool_error.kind != .None {
		session_store_close(setup.store, setup.alloc)
		setup.store = nil
		return false
	}
	if agent.chat_session_apply_harness(&setup.session, setup.harness_options).kind != .None {
		agent.log_emit({level = .Error, category = .Tool, event = "tools.agents_undescribed"})
	}
	return true
}

// session_store_open opens a journal of this run on the launch's state directory,
// owned by setup.alloc.
session_store_open :: proc(setup: ^Run_Setup) -> (store: ^journal.Journal, error: journal.Error) {
	store = new(journal.Journal, setup.alloc) or_return
	if open_error := journal.open(store, setup.journal_directory, setup.run, .Read_Write, setup.alloc); open_error != nil {
		free(store, setup.alloc)
		return nil, open_error
	}
	return store, nil
}

// session_store_close gives up the store's session, if it holds one, and closes it.
// Pending records are dropped: every write that matters commits where it is made.
session_store_close :: proc(store: ^journal.Journal, allocator: mem.Allocator) -> journal.Error {
	if store == nil { return nil }
	released := store.claimed
	close_error := journal.close(store)
	free(store, allocator)
	if released != {} { log_session_released(released) }
	return close_error
}

// session_error_message is what for a person, followed by the journal's reason,
// owned by allocator.
session_error_message :: proc(what: string, error: journal.Error, allocator: mem.Allocator) -> string {
	detail := journal.error_text(error, allocator)
	defer delete(detail, allocator)
	return strings.concatenate({what, ": ", detail}, allocator)
}

// report_recovery says what an earlier run left behind, so a resumed session
// starts knowing which calls have an outcome the harness never saw.
report_recovery :: proc(recovery: journal.Recovery) {
	if recovery.calls > 0 {
		fmt.eprintf("nabla: %d tool call(s) never reported a result; their results say whether they ran\n", recovery.calls)
	}
}

// selection_record remembers the model the user chose, so the next launch starts with it.
selection_record :: proc(store: ^journal.Journal, provider, model, effort: string) -> journal.Error {
	journal.append_record(store, {kind = .Selection_Changed}, journal.Selection_Changed{provider = provider, model = model, effort = effort})
	_, commit_error := journal.commit(store)
	return commit_error
}

// selection_latest reads the model the user last chose, owned by allocator.
selection_latest :: proc(store: ^journal.Journal, allocator: mem.Allocator) -> (selection: journal.Selection_Changed, found: bool, error: journal.Error) {
	record: journal.Record
	record, found = journal.read_latest(store, {kinds = {.Selection_Changed}}, allocator) or_return
	defer journal.record_destroy(&record, allocator)
	if !found { return }
	journal.payload_decode(record.data, &selection, allocator) or_return
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
pending_selection_clear :: proc(pending: ^Pending_Selection, allocator: mem.Allocator) {
	delete(pending.provider, allocator)
	delete(pending.model, allocator)
	pending^ = {}
}

// selection_request records the selection the user asked for and wakes the worker.
//
// The choice cannot travel in the work item: a turn owns the session until its next
// request boundary, and applying a selection edits the session, so the choice waits in
// run state for whichever boundary comes first. The wake exists because an idle worker
// is blocked on the queue and would otherwise never look.
selection_request :: proc(app: ^App, provider_id, model_id: string) {
	if runtime_stopping(app) { return }
	provider := strings.clone(provider_id, app.run.alloc)
	model := strings.clone(model_id, app.run.alloc)
	sync.mutex_lock(&app.run.mu)
	pending_selection_clear(&app.run.pending, app.run.alloc)
	app.run.pending = Pending_Selection {
		present  = true,
		provider = provider,
		model    = model,
	}
	sync.mutex_unlock(&app.run.mu)
	enqueue(app, .Model)
}

// apply_pending_selection installs the pending selection, if there is one, and says
// whether it did. Taking the intent under the lock is what makes it apply once: the idle
// path and the turn boundary both call this, and whoever takes it takes it for good.
apply_pending_selection :: proc(app: ^App) -> bool {
	sync.mutex_lock(&app.run.mu)
	pending := app.run.pending
	app.run.pending = {}
	sync.mutex_unlock(&app.run.mu)
	if !pending.present { return false }
	// The intent owns its strings through the install, which clones what it keeps.
	defer pending_selection_clear(&pending, app.run.alloc)
	return apply_selection(app, pending.provider, pending.model, "")
}

// app_steer_apply is the turn's request-boundary hook. It installs the selection the
// user asked for since the last request and returns the connection the next request is
// built for.
app_steer_apply :: proc(steer: ^agent.Steer_Context) -> ai.Provider_Connection {
	app := cast(^App)steer.apply_data
	catalog_selection_sync(app)
	apply_pending_selection(app)
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	return app.run.connection
}

// apply_selection switches the runtime to one provider's model and applies an
// effort level. `effort` is an explicit level for the new model; empty means the
// caller states none, and the level already in effect is then carried over
// whenever the new model allows it, so switching models does not silently drop
// the user's choice. A carried level the model does not allow falls back to the
// lowest level it does state. It resolves the credential and builds the
// connection, so it must run where the runtime is owned: on the worker once it
// exists, or at startup before it starts. The selection persists on success, so
// the next launch restores it. A failure is reported through the snapshot; the
// previously selected model, if any, stays in place.
apply_selection :: proc(app: ^App, provider_id, model_id, effort: string, announce := true) -> bool {
	// The catalog entry is copied out while it is the published one: a refresh releases the
	// catalog it lives in, and the connection built from it outlives that moment.
	sync.mutex_lock(&app.catalog_mu)
	resolved, problem := agent.model_selection_resolve(&app.setup.catalog, provider_id, model_id, app.run.alloc)
	sync.mutex_unlock(&app.catalog_mu)
	if problem != "" {
		selection_fail(app, problem)
		return false
	}
	defer agent.model_selection_destroy(&resolved, app.run.alloc)
	api := resolved.connection.API

	running := &app.setup.session
	selection_changed := app.setup.provider_id != provider_id || app.setup.model_id != model_id
	connection_changed :=
		app.run.connection.API != api || app.run.connection.Endpoint != resolved.connection.Endpoint || running.provider_transport != resolved.transport
	// A different model invalidates a pending summary. A metadata-only refresh of
	// the same model does not: it updates the facts used by the next request while
	// preserving compaction already in flight.
	if selection_changed { agent.chat_compact_cancel(running) }
	if running.provider_websocket != nil && (selection_changed || connection_changed) {
		ai.Provider_WebSocket_Session_Destroy(running.provider_websocket)
		running.provider_websocket = nil
	}
	running.last_estimate = 0
	running.last_input_measured = nil
	// The level to carry over: an explicit one, or the one already in effect, which
	// a model switch keeps whenever the new model allows it. It may alias the session's
	// stored effort, which selecting replaces, so it is copied first.
	desired := effort
	if desired == "" { desired = running.effort }
	carried := strings.clone(desired, app.setup.alloc)
	defer delete(carried, app.setup.alloc)
	// A carried level the new model does not allow falls back to the lowest level
	// the model does state, so a switch never leaves an effort it cannot serve.
	// With nothing to carry, the provider default stands.
	if !agent.chat_session_select(running, resolved, carried) && len(running.effort_levels) > 0 {
		agent.chat_session_set_effort(running, running.effort_levels[0])
	}

	// The runtime keeps its own copy of the selection, and provider_id and model_id
	// may alias the strings being replaced, so the replacements are built before
	// the old values are released.
	setup_provider := strings.clone(provider_id, app.setup.alloc)
	setup_model := strings.clone(model_id, app.setup.alloc)
	setup_endpoint := strings.clone(resolved.connection.Endpoint, app.run.alloc)
	credential := strings.clone(resolved.connection.Credential, app.setup.alloc)

	sync.mutex_lock(&app.run.mu)
	delete(app.setup.credential, app.setup.alloc)
	app.setup.credential = credential
	app.setup.api = api
	// The endpoint the connection being replaced borrowed stays valid for any turn
	// that already holds it.
	if app.endpoint != "" { append(&app.retired_endpoints, app.endpoint) }
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
	if app.setup.owns_selection { selection_publish_locked(app, provider_id, model_id, announce) }
	sync.mutex_unlock(&app.run.mu)

	// A run that owns the selection remembers it, so the next launch restores the
	// user's own last choice. A headless or child run leaves it alone.
	if app.setup.owns_selection && announce {
		if record_error := selection_record(app.setup.store, provider_id, model_id, running.effort); record_error != nil {
			detail := journal.error_text(record_error, context.temp_allocator)
			fmt.eprintln("nabla: the selection could not be recorded:", detail)
		}
	}
	return true
}

// selection_publish_locked shows an applied selection to the front-end. The
// caller holds the runtime mutex, because the status block is what the frame
// reads; a headless run has no frame and never calls this.
@(private)
selection_publish_locked :: proc(app: ^App, provider_id, model_id: string, announce := true) {
	running := &app.setup.session
	status := &app.run.snap.status
	if status.provider_id != provider_id {
		delete(status.provider_id, app.run.alloc)
		status.provider_id = strings.clone(provider_id, app.run.alloc)
	}
	if status.model_id != model_id {
		delete(status.model_id, app.run.alloc)
		status.model_id = strings.clone(model_id, app.run.alloc)
	}
	// The effort and the window apply here too, not only through refresh_status: a
	// restored selection must show both before the first work item runs.
	if status.effort != running.effort {
		delete(status.effort, app.run.alloc)
		status.effort = strings.clone(running.effort, app.run.alloc)
	}
	// The levels travel with the model, because only the worker owns the session
	// and the /effort menu is built on the front-end.
	for level in status.effort_levels { delete(level, app.run.alloc) }
	clear(&status.effort_levels)
	for level in running.effort_levels {
		append(&status.effort_levels, strings.clone(level, app.run.alloc))
	}
	status.context_window = running.capacity.window
	delete(app.run.snap.setup_error, app.run.alloc)
	app.run.snap.setup_error = ""
	app.run.snap.setup_error_failed = false
	if announce { snap_append_locked(app, .Notice, fmt.tprintf("model set to %s / %s", provider_id, model_id)) }
	app.run.snap.generation += 1
}

// apply_startup_selection chooses the model a launch runs with. Two flags win,
// because they are the launch's own instruction, and a pair that cannot be
// resolved is a launch mistake rather than something to paper over. Otherwise
// the stored selection is used, because it is the user's own last choice, and
// the model a resumed session recorded is the fallback when there is no usable
// selection. Neither is fatal: a stale selection leaves the launch to the model
// menu, which is where a model would be chosen anyway.
//
// False means the launch cannot continue. The reason is in the snapshot.
apply_startup_selection :: proc(app: ^App, flag_provider, flag_model: string) -> bool {
	if flag_provider != "" || flag_model != "" {
		if flag_provider == "" || flag_model == "" {
			selection_fail(app, "--provider and --model must be given together")
			return false
		}
		return apply_selection(app, flag_provider, flag_model, "")
	}

	selection, found, load_error := selection_latest(app.setup.store, app.run.alloc)
	defer selection_destroy(&selection, app.run.alloc)
	if load_error != nil {
		// A database the store just opened failing to answer this is worth saying
		// out loud, but the launch can still proceed to the model menu.
		detail := journal.error_text(load_error, context.temp_allocator)
		fmt.eprintln("nabla: the selection could not be read:", detail)
	}
	applied := found && apply_selection(app, selection.provider, selection.model, selection.effort)
	if !applied && app.setup.resumed_provider != "" && app.setup.resumed_model != "" {
		apply_selection(app, app.setup.resumed_provider, app.setup.resumed_model, "")
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
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
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
	app.run.snap.generation += 1
}
