#+build linux
package main

// The front-end: a worker thread owns the agent session, the main thread owns
// the terminal, and results cross through the runtime snapshot.
//
// The snapshot is a display projection only. The session keeps the real
// history, request context, effort, and usage; this package renders the
// snapshot and nothing else.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
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
	kind:     Entry_Kind,
	text:     [dynamic]u8, // owned,
	complete: bool,
}

// Status carries the runtime facts the footer shows. provider_id and cwd
// are borrowed from the runtime (the provider id and the session workspace,
// both stable for the app's lifetime); model_id, effort, and effort_levels are
// owned display copies, replaced under the runtime mutex when they change.
Status :: struct {
	provider_id:        string,
	model_id:           string, // owned,
	effort:             string, // owned,
	effort_levels:      [dynamic]string, // owned; the levels the model allows,
	cwd:                string,
	context_window:     int,
	est_input:          int,
	last_input:         i64,
	last_input_present: bool,
	cost:               f64,
	cost_present:       bool,
	running:            bool,
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
	Model,
	New_Session,
	Resume_Session,
}
Work :: struct {
	kind:     Work_Kind,
	provider: string, // owned; target provider for .Model, empty otherwise,
	text:     string, // owned; model id for .Model, prompt or effort text otherwise,
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
Menu :: struct {
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

Runtime :: struct {
	mu:         sync.Mutex, // guards snapshot,
	snap:       Snapshot,
	work:       Work_Chan,
	worker:     ^thread.Thread,
	connection: ai.Provider_Connection,
	alloc:      mem.Allocator,
	signals:    agent.Chat_Interactive_Signals,
}

// Run_Setup is the resolved runtime the app starts from: the catalog, the
// selected provider/model, the connection, the session store, and the running
// session the worker drives.
// Session_Start_Kind is which session a launch opens.
Session_Start_Kind :: enum {
	// New starts a session in the launch directory. It is the zero value, so a
	// launch that asks for nothing starts fresh.
	New,
	// Resume_Latest opens the newest session that ran in the launch directory.
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

session_target_destroy :: proc(target: ^Session_Target, allocator: mem.Allocator) {
	delete(string(target.id), allocator)
	delete(target.workspace, allocator)
	delete(target.provider, allocator)
	delete(target.model, allocator)
	target^ = {}
}

Run_Setup :: struct {
	catalog:          agent.Catalog,
	api:              ai.API_Kind,
	credential:       string, // owned,
	connection:       ai.Provider_Connection,
	store:            session.Store,
	session:          agent.Chat_Session,
	workspace:        string, // owned; the directory sessions here run in
	provider_id:      string, // owned,
	model_id:         string, // owned,
	// resumed_provider and resumed_model are what the opened session last ran
	// with. They are empty for a new session, and they are only a fallback for
	// when no selection exists anywhere else.
	resumed_provider: string, // owned,
	resumed_model:    string, // owned,
	// configured holds the provider ids the user's own configuration declares;
	// models.dev also contributes providers, and the model menu offers only the
	// configured ones, whose credentials the user actually set up.
	configured:       [dynamic]string, // owned,
	alloc:            mem.Allocator,
}

App :: struct {
	setup:             Run_Setup,
	terminal:          ^term.Session,
	tty:               ^os.File,
	parser:            input.Parser,
	raw:               [dynamic]input.Event, // owned; the latest input batch,
	run:               Runtime,
	storage:           ^Frame_Storage,
	home:              string, // owned; shortens the footer path,
	input:             widgets.Input,
	scroll:            int, // lines scrolled back; 0 follows the bottom,
	generation_seen:   u64,
	cancel_seen:       bool, // the running cancel came from our own keys, not a signal,
	spin_lap:          time.Tick, // last working-frame advance,
	spin_frame:        int,
	// menu is the open choice list, when menu_open. One component serves every
	// command whose argument is picked from a list.
	menu:              Menu,
	menu_open:         bool,
	// completion_query and completion_index carry a Tab cycle: the prefix the
	// cycle began with and where it has reached. Any other key ends the cycle.
	completion_query:  string, // owned,
	completion_index:  int,
	completion_active: bool,
	columns:           int,
	rows:              int,
	quit:              bool,
}

// resolve_run_catalog builds the resolved catalog from the user's configuration:
// the configuration's own statements, then each configured provider's listing,
// then the models.dev catalog, merged first-value-wins. `configured` holds the
// provider ids the user set up, which is the set the model menu offers. Both results
// are owned by the caller.
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

	// The provider's own listing comes before the shared catalog, so a model it
	// introduces is enriched by models.dev in the same pass.
	discovered := agent.discover_provider_models(sources, allocator = allocator)
	defer agent.catalog_sources_destroy(&discovered, allocator)
	models_dev, models_dev_err := agent.models_dev_sources(providers = names, allocator = allocator)
	defer agent.catalog_sources_destroy(&models_dev, allocator)
	if models_dev_err != .None {
		fmt.eprintln("nabla: warning: models.dev is unavailable; using configured values only")
	}
	resolved, resolve_err := agent.resolve_catalog(sources, discovered[:], models_dev[:], allocator)
	if resolve_err != .None {
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
run_catalog :: proc(sources: []agent.Catalog_Provider_Source, setup: ^Run_Setup, start: Session_Start) -> bool {
	setup.alloc = context.allocator
	ok := false
	defer if !ok { run_setup_destroy(setup) }

	catalog, configured, resolved := resolve_run_catalog(sources, setup.alloc)
	if !resolved { return false }
	setup.catalog = catalog
	setup.configured = configured

	workspace, workspace_err := os.get_working_directory(setup.alloc)
	if workspace_err != nil || workspace == "" {
		fmt.eprintln("nabla: cannot determine working directory")
		return false
	}
	defer delete(workspace, setup.alloc)

	if !run_session_attach(setup, workspace, start) { return false }

	ok = true
	return true
}

// run_session_attach opens the session store, opens the session the launch asked
// for, claims it for writing, and settles anything an earlier run left running.
// The running session is built on top of that claim. A launch that cannot open
// the session it asked for fails rather than quietly starting a different one.
run_session_attach :: proc(setup: ^Run_Setup, workspace: string, start: Session_Start) -> bool {
	directory, directory_err := agent.xdg_directory(.State, setup.alloc)
	if directory_err != .None {
		fmt.eprintln("nabla: cannot resolve the state directory for sessions")
		return false
	}
	defer delete(directory, setup.alloc)

	if store_err := session.store_open(&setup.store, directory); store_err != nil {
		local := store_err
		fmt.eprintln("nabla: cannot open the session database:", session.error_detail(&local))
		return false
	}

	target, opened := session_open_target(setup, start, workspace)
	if !opened { return false }
	defer session_target_destroy(&target, setup.alloc)

	// A session carries the directory it ran in, and an explicit id can name one
	// from anywhere, so the directory is checked rather than assumed.
	if !os.is_dir(target.workspace) {
		fmt.eprintf("nabla: the session's directory is not usable: %s\n", target.workspace)
		return false
	}

	recovery, message, attached := session_attach(setup, target.id)
	if !attached {
		defer delete(message, setup.alloc)
		fmt.eprintln("nabla:", message)
		return false
	}
	report_recovery(recovery)

	claimed, held := session.session_claimed(&setup.store)
	if !held {
		fmt.eprintln("nabla: the session claim went missing")
		return false
	}
	setup.workspace = strings.clone(target.workspace, setup.alloc)
	setup.resumed_provider = strings.clone(target.provider, setup.alloc)
	setup.resumed_model = strings.clone(target.model, setup.alloc)
	setup.session = agent.chat_session_init(&setup.store, claimed, setup.workspace, setup.alloc)
	return true
}

// session_open_target resolves which session the launch opens. It reads the
// store and, for .New, creates the session, but it never claims anything, so a
// refusal costs nothing. Everything it returns is owned by setup.alloc.
//
// Every failure here is the launch's own: the caller reports it and exits rather
// than falling back to a different session.
session_open_target :: proc(setup: ^Run_Setup, start: Session_Start, launch_workspace: string) -> (target: Session_Target, ok: bool) {
	switch start.kind {
	case .New:
		created, create_err := session.session_create(&setup.store, {workspace = launch_workspace}, session.now_ms())
		if create_err != nil {
			local := create_err
			fmt.eprintln("nabla: cannot start a session:", session.error_detail(&local))
			return {}, false
		}
		defer session.session_destroy(&created)
		target.id = session.Session_Id(strings.clone(string(created.id), setup.alloc))
		target.workspace = strings.clone(launch_workspace, setup.alloc)
		return target, true

	case .Resume_Latest:
		sessions, list_err := session.session_list(&setup.store, {workspace = launch_workspace, limit = 1}, setup.alloc)
		if list_err != nil {
			local := list_err
			fmt.eprintln("nabla: cannot list sessions:", session.error_detail(&local))
			return {}, false
		}
		defer session.sessions_destroy(sessions, setup.alloc)
		if len(sessions) == 0 {
			fmt.eprintf("nabla: no session has run in %s; nothing to resume\n", launch_workspace)
			return {}, false
		}
		return session_target_from(&sessions[0], setup.alloc), true

	case .Resume_Id:
		if !session.session_id_valid(session.Session_Id(start.id)) {
			fmt.eprintf("nabla: %s is not a session id\n", start.id)
			return {}, false
		}
		header, load_err := session.session_load(&setup.store, session.Session_Id(start.id), setup.alloc)
		if load_err != nil {
			local := load_err
			fmt.eprintf("nabla: cannot open session %s: %s\n", start.id, session.error_detail(&local))
			return {}, false
		}
		defer session.session_destroy(&header)
		return session_target_from(&header, setup.alloc), true
	}
	return {}, false
}

// session_target_from copies what a launch needs out of a stored header.
@(private)
session_target_from :: proc(header: ^session.Session, allocator: mem.Allocator) -> Session_Target {
	return Session_Target {
		id = session.Session_Id(strings.clone(string(header.id), allocator)),
		workspace = strings.clone(header.workspace, allocator),
		provider = strings.clone(header.provider, allocator),
		model = strings.clone(header.model, allocator),
	}
}

// session_attach takes the writer claim for target and settles whatever an
// earlier run left running in it. On failure the store holds no claim and the
// message says why; the message is owned by setup.alloc.
session_attach :: proc(setup: ^Run_Setup, target: session.Session_Id) -> (recovery: session.Recovery, message: string, ok: bool) {
	if claim_err := session.session_claim(&setup.store, target); claim_err != nil {
		local := claim_err
		return {}, strings.concatenate({"cannot take the session: ", session.error_detail(&local)}, setup.alloc), false
	}
	settled, recover_err := session.session_recover(
		&setup.store,
		target,
		{at_ms = session.now_ms(), recovered_content = agent.TOOL_RECOVERED_RESULT, unexecuted_content = agent.TOOL_UNEXECUTED_RESULT},
	)
	if recover_err != nil {
		session.session_release(&setup.store)
		local := recover_err
		return {}, strings.concatenate({"cannot settle the session: ", session.error_detail(&local)}, setup.alloc), false
	}
	return settled, "", true
}

// report_recovery says what an earlier run left behind, so a resumed session
// starts with the two cases told apart: an outcome the harness never saw, and a
// call it never began.
report_recovery :: proc(recovery: session.Recovery) {
	if recovery.recovered_calls > 0 {
		fmt.eprintf("nabla: %d tool call(s) were dispatched and never came back; their results say the outcome is unknown\n", recovery.recovered_calls)
	}
	if recovery.unexecuted_calls > 0 {
		fmt.eprintf("nabla: %d tool call(s) were recorded and never ran; their results say so\n", recovery.unexecuted_calls)
	}
}
// provider_usable reports whether a provider can serve a request at all: an
// endpoint, an api family, and a credential source. The model menu offers only
// usable providers' models.
provider_usable :: proc(provider: ^agent.Catalog_Provider) -> bool {
	return provider.base_url_present && provider.base_url != "" && provider.api_present && provider.api != "" && provider.api_key_present
}

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
apply_selection :: proc(app: ^App, provider_id, model_id, effort: string) -> bool {
	provider_index, provider_found := agent.catalog_find_provider(&app.setup.catalog, provider_id)
	if !provider_found {
		selection_fail(app, fmt.tprintf("provider not found: %s", provider_id))
		return false
	}
	provider := &app.setup.catalog.providers[provider_index]
	if !provider_usable(provider) {
		selection_fail(app, fmt.tprintf("provider %s needs base_url, api, and api_key", provider_id))
		return false
	}
	api, api_ok := agent.chat_api_kind(provider.api)
	if !api_ok {
		selection_fail(app, fmt.tprintf("unsupported api: %s", provider.api))
		return false
	}
	credential, credential_ok := agent.config_resolve_credential(provider.api_key, app.setup.alloc)
	if !credential_ok {
		selection_fail(app, fmt.tprintf("provider %s needs api_key: name an environment variable that is set, or provide the key", provider_id))
		return false
	}
	model_index, model_found := agent.catalog_find_model(&app.setup.catalog, provider_id, model_id)
	if !model_found {
		delete(credential, app.setup.alloc)
		selection_fail(app, fmt.tprintf("model not found for provider: %s %s", provider_id, model_id))
		return false
	}
	model := &app.setup.catalog.models[model_index]

	running := &app.setup.session
	window, _ := agent.chat_context_window(model^)
	running.context_window = window
	running.max_output_tokens = model.max_output_tokens
	running.tools_enabled = (model.tools_present && model.tools) && agent.chat_supports_tools(api)
	// The request record names the provider and model each request was sent to,
	// so the running session carries them.
	delete(running.provider_id, running.allocator)
	running.provider_id = strings.clone(provider_id, running.allocator)
	delete(running.model_id, running.allocator)
	running.model_id = strings.clone(model_id, running.allocator)
	// The level to carry over: an explicit one, or the one already in effect, which
	// a model switch keeps whenever the new model allows it. It may alias the
	// session's stored effort, which rebuilding the level list replaces, so it is
	// copied before the session is touched.
	desired := effort
	if desired == "" { desired = running.effort }
	carried := strings.clone(desired, app.setup.alloc)
	defer delete(carried, app.setup.alloc)
	agent.chat_session_set_effort(running, "")
	for level in running.effort_levels {
		delete(level, running.allocator)
	}
	clear(&running.effort_levels)
	if model.thinking.levels_present {
		for level in model.thinking.levels {
			append(&running.effort_levels, strings.clone(level, running.allocator))
		}
	}
	// A carried level the new model does not allow falls back to the lowest level
	// the model does state, so a switch never leaves an effort it cannot serve.
	// With nothing to carry, the provider default stands.
	if carried != "" && !agent.chat_session_set_effort(running, carried) && len(running.effort_levels) > 0 {
		agent.chat_session_set_effort(running, running.effort_levels[0])
	}

	// The runtime keeps its own copy of the selection, and provider_id and model_id
	// may alias the strings being replaced, so the replacements are built before
	// the old values are released.
	setup_provider := strings.clone(provider_id, app.setup.alloc)
	setup_model := strings.clone(model_id, app.setup.alloc)

	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	delete(app.setup.credential, app.setup.alloc)
	app.setup.credential = credential
	app.setup.api = api
	app.run.connection = ai.Provider_Connection {
		API        = api,
		Endpoint   = provider.base_url,
		Credential = credential,
	}
	delete(app.setup.provider_id, app.setup.alloc)
	app.setup.provider_id = setup_provider
	delete(app.setup.model_id, app.setup.alloc)
	app.setup.model_id = setup_model
	status := &app.run.snap.status
	if status.provider_id != provider_id {
		delete(status.provider_id, app.run.alloc)
		status.provider_id = strings.clone(provider_id, app.run.alloc)
	}
	if status.model_id != model_id {
		delete(status.model_id, app.run.alloc)
		status.model_id = strings.clone(model_id, app.run.alloc)
	}
	// The effort and the window apply here too, not only through
	// refresh_status: a restored selection must show both before the first
	// work item runs.
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
	status.context_window = window
	delete(app.run.snap.setup_error, app.run.alloc)
	app.run.snap.setup_error = ""
	snap_append_locked(app, .Notice, fmt.tprintf("model set to %s / %s", provider_id, model_id))
	app.run.snap.generation += 1

	saved := agent.Selection {
		provider = provider_id,
		model    = model_id,
		effort   = running.effort,
	}
	sync.mutex_unlock(&app.run.mu)
	agent.selection_save(saved)
	sync.mutex_lock(&app.run.mu)
	return true
}

// selection_fail records why a selection could not apply. The model menu shows it
// directly; chat mode sees it as a transcript warning.
selection_fail :: proc(app: ^App, message: string) {
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	delete(app.run.snap.setup_error, app.run.alloc)
	app.run.snap.setup_error = strings.clone(message, app.run.alloc)
	snap_append_locked(app, .Warning, message)
	app.run.snap.generation += 1
}

run_setup_destroy :: proc(setup: ^Run_Setup) {
	agent.chat_session_destroy(&setup.session)
	session.session_release(&setup.store)
	session.store_close(&setup.store)
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
tui_run :: proc(sources: []agent.Catalog_Provider_Source, flag_provider, flag_model: string, start: Session_Start) {
	app := new(App)
	defer free(app)
	app.run.alloc = context.allocator
	// The setup is filled in place: a store owns a live connection, and copying
	// one would leave two owners of it.
	if !run_catalog(sources, &app.setup, start) {
		return
	}
	app.run.connection = app.setup.connection
	app.run.snap.entries = make([dynamic]Entry, 0, 16, app.run.alloc)
	app.run.snap.status.provider_id = strings.clone(app.setup.provider_id, app.run.alloc)
	app.run.snap.status.model_id = strings.clone(app.setup.model_id, app.run.alloc)
	app.run.snap.status.cwd = app.setup.workspace
	app.run.snap.status.context_window = app.setup.session.context_window
	// The resumed conversation is shown before the first prompt, so the screen
	// matches the history the next request will be built from.
	session_replay(app, &app.setup.session)
	app.home = os.get_env("HOME", app.run.alloc)
	app.input = widgets.Input{}
	widgets.input_init(&app.input, app.run.alloc)
	app.storage = frame_storage_new(app.run.alloc)
	app.run.work, _ = chan.create_buffered(Work_Chan, WORK_CAPACITY, app.run.alloc)

	terminal, open_err := term.open({alternate_screen = true, hide_cursor = true, bracketed_paste = true, input_mode = .Raw}, app.run.alloc)
	if open_err != nil {
		fmt.eprintln("nabla: cannot open the terminal:", open_err)
		app_teardown(app)
		return
	}
	defer { _ = term.close(terminal) }
	app.terminal = terminal

	tty, file_err := term.session_file(terminal)
	if file_err != nil {
		fmt.eprintln("nabla: cannot access the terminal input:", file_err)
		app_teardown(app)
		return
	}
	app.tty = tty
	input.parser_init(&app.parser)
	app.raw = make([dynamic]input.Event, 0, 16, app.run.alloc)

	if flag_provider != "" && flag_model != "" {
		if !apply_selection(app, flag_provider, flag_model, "") {
			fmt.eprintln("nabla:", app.run.snap.setup_error)
			app_teardown(app)
			return
		}
	} else if flag_provider == "" && flag_model == "" {
		// The persisted selection is the user's own choice, so it outranks the model
		// a resumed session happens to have recorded. That model is used only when
		// there is no selection at all, which beats opening the model menu.
		if selection, selection_ok := agent.selection_load(app.run.alloc); selection_ok {
			apply_selection(app, selection.provider, selection.model, selection.effort)
			agent.selection_destroy(&selection, app.run.alloc)
		} else if app.setup.resumed_provider != "" && app.setup.resumed_model != "" {
			// The session's own model is a weaker hint than a selection, so it is
			// used only when no selection exists, which beats opening the model menu.
			apply_selection(app, app.setup.resumed_provider, app.setup.resumed_model, "")
		}
	} else {
		fmt.eprintln("nabla: --provider and --model must be given together")
		app_teardown(app)
		return
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
		app_teardown(app)
		return
	}
	worker.data = app
	app.run.worker = worker
	thread.start(worker)

	if viewport, vp_err := term.viewport(app.terminal); vp_err == nil {
		app.columns, app.rows = viewport.columns, viewport.rows
		present_frame(app, app.storage)
	}

	for !app.quit {
		_, read_err := input.read_events(&app.parser, app.tty, &app.raw, TUI_POLL_MS)
		if read_err != nil {
			fmt.eprintln("nabla: input:", read_err)
			break
		}
		for event in app.raw {
			handle_event(app, event)
		}
		count := len(app.raw)
		input.events_clear(&app.raw, app.run.alloc)

		// A terminal that has not reported a size yet (ENODATA) is treated
		// as "keep waiting": nothing can be drawn until one exists.
		viewport, vp_err := term.viewport(app.terminal)
		if vp_err != nil {
			continue
		}
		resized := viewport.columns != app.columns || viewport.rows != app.rows
		app.columns, app.rows = viewport.columns, viewport.rows

		// The working indicator animates only while a request is active, so a
		// silent request (no stream events, tools running) still advances it.
		now := time.tick_now()
		advance_spinner := app.run.snap.status.running && time.tick_diff(app.spin_lap, now) >= SPINNER_INTERVAL
		// A startup chooser closes once its selection applies on the worker; a menu
		// opened from the prompt closes on submit instead, so browsing it does not
		// dismiss it.
		if app.menu.required && app.run.snap.status.model_id != "" {
			menu_close(app)
			widgets.input_clear(&app.input)
		}
		if count > 0 || resized || generation_changed(app) || advance_spinner {
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

	// Teardown: cancel a running turn so the worker settles, then stop it
	// and join. Join is safe only after the turn retired; cancellation
	// guarantees that.
	if runtime_busy(app) {
		agent.chat_cancel_request()
	}
	app_teardown(app)
}

// app_teardown releases everything after the worker stopped. It must be
// called at most once.
app_teardown :: proc(app: ^App) {
	if app.run.work != {} {
		chan.close(&app.run.work)
	}
	if app.run.worker != nil {
		thread.join(app.run.worker)
		thread.destroy(app.run.worker)
		app.run.worker = nil
	}
	chan.destroy(&app.run.work)
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
	for level in app.run.snap.status.effort_levels { delete(level, app.run.alloc) }
	delete(app.run.snap.status.effort_levels)
	delete(app.run.snap.setup_error, app.run.alloc)
	menu_destroy(&app.menu, app.run.alloc)
	delete(app.completion_query, app.run.alloc)
	delete(app.home, app.run.alloc)
	widgets.input_destroy(&app.input)
	input.parser_destroy(&app.parser)
	input.events_destroy(&app.raw, app.run.alloc)
	frame_storage_destroy(app.storage)
	run_setup_destroy(&app.setup)
}

// --- worker ---------------------------------------------------------------

run_worker :: proc(thread_handle: ^thread.Thread) {
	app := cast(^App)thread_handle.data
	observer := run_observer(app)
	// The session list the /resume menu offers is built here, because only the
	// worker touches the store.
	session_refresh_rows(app)
	for {
		work, ok := chan.recv(app.run.work)
		if !ok {
			return
		}
		run_work(app, work, observer)
		if work.text != "" {
			delete(work.text, app.run.alloc)
		}
		if work.provider != "" {
			delete(work.provider, app.run.alloc)
		}
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
		agent.chat_run_turn_steered(&app.setup.session, app.run.connection, observer, nil)
	case .Compact:
		set_running(app, true)
		agent.chat_command_compact(&app.setup.session, observer, app.run.connection, nil)
	case .Status:
		agent.chat_notice_status(&app.setup.session, observer, session.now_ms())
	case .Effort:
		applied := true
		if work.text == "" || work.text == "default" {
			agent.chat_session_set_effort(&app.setup.session, "")
			snap_append(app, .Notice, "effort cleared to provider default")
		} else if agent.chat_session_set_effort(&app.setup.session, work.text) {
			snap_append(app, .Notice, fmt.tprintf("effort set to %s for the next request", work.text))
		} else {
			applied = false
			snap_append(app, .Notice, fmt.tprintf("effort %s is not allowed for this model", work.text))
		}
		// The effort is part of the persisted selection, so a change rewrites it.
		if applied {
			agent.selection_save(agent.Selection{provider = app.setup.provider_id, model = app.setup.model_id, effort = app.setup.session.effort})
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
// next prompt starts a new conversation. The claim is released for the attempt
// and taken again, because a store holds one claim; a failure puts the running
// session back rather than leaving the front-end with no session at all.
session_start_new :: proc(app: ^App) -> bool {
	setup := &app.setup
	target, opened := session_open_target(setup, {kind = .New}, setup.workspace)
	if !opened { return false }
	defer session_target_destroy(&target, setup.alloc)

	previous := session.Session_Id(strings.clone(string(setup.session.id), setup.alloc))
	defer delete(string(previous), setup.alloc)
	session.session_release(&setup.store)

	_, message, attached := session_attach(setup, target.id)
	if !attached {
		defer delete(message, setup.alloc)
		snap_append(app, .Error, message)
		session_restore_claim(app, previous)
		return false
	}
	claimed, held := session.session_claimed(&setup.store)
	if !held {
		snap_append(app, .Error, "the session claim went missing")
		return false
	}
	agent.chat_session_destroy(&setup.session)
	setup.session = agent.chat_session_init(&setup.store, claimed, setup.workspace, setup.alloc)
	return true
}

// session_switch opens the named session, settling anything an earlier run left
// running. The workspace recorded in the session becomes the running session's
// workspace.
//
// The target is read and checked before anything is given up, and the running
// session's claim is taken back when the switch fails, so a refusal leaves the
// front-end working in the session it already had.
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

	previous := session.Session_Id(strings.clone(string(setup.session.id), setup.alloc))
	defer delete(string(previous), setup.alloc)
	session.session_release(&setup.store)

	recovery, message, attached := session_attach(setup, target)
	if !attached {
		defer delete(message, setup.alloc)
		snap_append(app, .Error, message)
		session_restore_claim(app, previous)
		return false
	}
	if recovery.recovered_calls > 0 {
		snap_append(app, .Notice, fmt.tprintf("%d tool result(s) in this session record an outcome the harness never saw", recovery.recovered_calls))
	}
	if recovery.unexecuted_calls > 0 {
		snap_append(app, .Notice, fmt.tprintf("%d tool call(s) in this session never ran", recovery.unexecuted_calls))
	}
	claimed, held := session.session_claimed(&setup.store)
	if !held {
		snap_append(app, .Error, "the session claim went missing")
		return false
	}
	// The other session's workspace is where its next request runs.
	agent.chat_session_destroy(&setup.session)
	delete(setup.workspace, setup.alloc)
	setup.workspace = strings.clone(header.workspace, setup.alloc)
	setup.session = agent.chat_session_init(&setup.store, claimed, setup.workspace, setup.alloc)

	// A conversation has to be configured before it can run: the new chat starts
	// with no model, so the session's recorded one is applied, with the selection
	// already in effect as the fallback. A session whose model is gone from the
	// catalog stays open on the current selection, and can still be changed from
	// the model menu.
	if header.provider != "" && header.model != "" && apply_selection(app, header.provider, header.model, "") {
		return true
	}
	if setup.provider_id != "" && setup.model_id != "" {
		apply_selection(app, setup.provider_id, setup.model_id, "")
	}
	return true
}

// session_restore_claim takes the claim the switch gave up, so a failed switch
// leaves the front-end where it started. A failure here is reported because the
// running session can no longer write.
@(private)
session_restore_claim :: proc(app: ^App, previous: session.Session_Id) {
	setup := &app.setup
	if claim_err := session.session_claim(&setup.store, previous); claim_err != nil {
		local := claim_err
		snap_append(app, .Error, fmt.tprintf("the running session could not be reclaimed: %s", session.error_detail(&local)))
	}
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
			snap_append(app, .User, payload.text)
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
menu_begin :: proc(app: ^App, title: string, choices: [dynamic]Choice, required: bool) {
	menu_destroy(&app.menu, app.run.alloc)
	app.menu = Menu {
		title    = strings.clone(title, app.run.alloc),
		choices  = choices,
		required = required,
	}
	app.menu_open = true
	app.completion_active = false
	widgets.input_clear(&app.input)
}

// menu_close drops the open menu and returns the prompt.
menu_close :: proc(app: ^App) {
	app.menu_open = false
	menu_destroy(&app.menu, app.run.alloc)
}

// menu_pick places the cursor on the first choice whose label names the current
// value, so a menu opens where the user already is.
menu_pick :: proc(app: ^App, label: string) {
	for choice, index in app.menu.choices {
		if choice.label == label { app.menu.cursor = index; return }
	}
}

// menu_open_model lists every usable configured model, with the provider as the
// second column. The catalog's own order follows the loader's table iteration,
// which varies between runs, so the list is sorted.
menu_open_model :: proc(app: ^App) {
	// The catalog is read-only after startup. The current selection is snapshot
	// state, so it is read under the lock the worker writes it with.
	sync.mutex_lock(&app.run.mu)
	current_provider := strings.clone(app.run.snap.status.provider_id, context.temp_allocator)
	current_model := strings.clone(app.run.snap.status.model_id, context.temp_allocator)
	sync.mutex_unlock(&app.run.mu)

	models := make([dynamic]Model_Choice, 0, 16, context.temp_allocator)
	defer delete(models)
	for &provider in app.setup.catalog.providers {
		if !provider_usable(&provider) || !provider_configured(app, provider.id) { continue }
		for &model in app.setup.catalog.models {
			if model.provider_id != provider.id { continue }
			append(&models, Model_Choice{provider_id = provider.id, model_id = model.id})
		}
	}
	slice.sort_by(models[:], model_choice_less)

	choices := make([dynamic]Choice, 0, len(models), app.run.alloc)
	for model in models {
		append(
			&choices,
			Choice {
				label = strings.clone(model.model_id, app.run.alloc),
				detail = strings.clone(model.provider_id, app.run.alloc),
				action = Model_Choice{provider_id = strings.clone(model.provider_id, app.run.alloc), model_id = strings.clone(model.model_id, app.run.alloc)},
			},
		)
	}
	menu_title := "select a model"
	if current_model != "" {
		menu_title = fmt.tprintf("models (current: %s / %s)", current_provider, current_model)
	}
	menu_begin(app, menu_title, choices, false)
	for choice, index in app.menu.choices {
		action := choice.action.(Model_Choice)
		if action.provider_id == current_provider && action.model_id == current_model {
			app.menu.cursor = index
			break
		}
	}
}

model_choice_less :: proc(a, b: Model_Choice) -> bool {
	order := strings.compare(a.provider_id, b.provider_id)
	if order == 0 { order = strings.compare(a.model_id, b.model_id) }
	return order < 0
}

// menu_open_effort lists the levels the model allows, plus the provider default.
// The levels are snapshot state, because only the worker owns the session, and
// their strings belong to the worker, so they are copied while the lock that
// protects them is held.
menu_open_effort :: proc(app: ^App) {
	sync.mutex_lock(&app.run.mu)
	current := strings.clone(app.run.snap.status.effort, context.temp_allocator)
	levels := make([dynamic]string, 0, len(app.run.snap.status.effort_levels) + 1, context.temp_allocator)
	append(&levels, "provider default")
	for level in app.run.snap.status.effort_levels { append(&levels, strings.clone(level, context.temp_allocator)) }
	sync.mutex_unlock(&app.run.mu)
	defer delete(levels)

	choices := make([dynamic]Choice, 0, len(levels), app.run.alloc)
	for level in levels {
		value := "" if level == "provider default" else level
		append(&choices, Choice{label = strings.clone(level, app.run.alloc), action = Effort_Choice{level = strings.clone(value, app.run.alloc)}})
	}
	menu_begin(app, "reasoning effort", choices, false)
	menu_pick(app, "provider default" if current == "" else current)
}

// menu_open_session lists the workspace's recent sessions from the snapshot, with
// a short id as the second column. Only the worker reads the store, so the list
// it built is what the menu shows.
menu_open_session :: proc(app: ^App) {
	choices := make([dynamic]Choice, 0, 8, app.run.alloc)
	active: session.Session_Id

	// The snapshot's rows and their strings belong to the worker, which can replace
	// them the moment the lock is released, so the labels are copied while the lock
	// that protects them is still held.
	sync.mutex_lock(&app.run.mu)
	active = session.Session_Id(strings.clone(string(app.run.snap.active_session), app.run.alloc))
	for &row in app.run.snap.sessions {
		label := row.title if row.title != "" else "(untitled)"
		append(
			&choices,
			Choice {
				label = strings.clone(label, app.run.alloc),
				detail = strings.clone(string(row.id)[:8], app.run.alloc),
				action = Session_Choice{id = session.Session_Id(strings.clone(string(row.id), app.run.alloc))},
			},
		)
	}
	sync.mutex_unlock(&app.run.mu)
	defer delete(string(active), app.run.alloc)

	menu_begin(app, "sessions in this workspace", choices, false)
	menu_pick_session(app, active)
}

// menu_pick_session opens the list on the running session, so the menu shows
// where the user already is.
@(private)
menu_pick_session :: proc(app: ^App, active: session.Session_Id) {
	if active == "" { return }
	for choice, index in app.menu.choices {
		action := choice.action.(Session_Choice)
		if action.id == active {
			app.menu.cursor = index
			return
		}
	}
}

// menu_page is how far one Page_Up/Page_Down moves in a menu.
menu_page :: proc(app: ^App) -> int {
	return max(app.rows - TUI_FOOTER_ROWS - 1, 1)
}

// menu_submit sends the choice under the cursor as work. The startup chooser
// stays open until its selection applies, because no model is selected yet; a
// menu opened from the prompt closes at once, and a selection that fails is
// reported as a transcript warning.
menu_submit :: proc(app: ^App) {
	if len(app.menu.choices) == 0 { return }
	cursor := min(app.menu.cursor, len(app.menu.choices) - 1)
	switch action in app.menu.choices[cursor].action {
	case Model_Choice:
		enqueue(app, .Model, action.provider_id, action.model_id)
	case Effort_Choice:
		enqueue(app, .Effort, "", action.level)
	case Session_Choice:
		enqueue(app, .Resume_Session, "", string(action.id))
	}
	if !app.menu.required { menu_close(app) }
}

// handle_menu_key drives every menu: arrows move, enter chooses, escape cancels,
// and the startup chooser quits instead because it cannot be dismissed.
handle_menu_key :: proc(app: ^App, key: input.Key_Event) {
	last := len(app.menu.choices) - 1
	#partial switch key.code {
	case .Up:
		app.menu.cursor = max(app.menu.cursor - 1, 0)
	case .Down:
		app.menu.cursor = min(app.menu.cursor + 1, max(last, 0))
	case .Home:
		app.menu.cursor = 0
	case .End:
		app.menu.cursor = max(last, 0)
	case .Page_Up:
		app.menu.cursor = max(app.menu.cursor - menu_page(app), 0)
	case .Page_Down:
		app.menu.cursor = min(app.menu.cursor + menu_page(app), max(last, 0))
	case .Enter:
		menu_submit(app)
	case .Escape:
		if app.menu.required {
			app.quit = true
		} else {
			menu_close(app)
		}
	case:
	}
}

// resolve_model_reference maps a /model argument onto a serving identity. The
// current provider is preferred, then any single provider serving that model
// id, then an explicit "provider/model" pair.
resolve_model_reference :: proc(app: ^App, text: string) -> (provider_id, model_id: string, ok: bool) {
	if _, found := agent.catalog_find_model(&app.setup.catalog, app.setup.provider_id, text); found {
		return app.setup.provider_id, text, true
	}
	matches := 0
	found_provider := ""
	for &provider in app.setup.catalog.providers {
		if _, found := agent.catalog_find_model(&app.setup.catalog, provider.id, text); found {
			matches += 1
			found_provider = provider.id
		}
	}
	if matches == 1 {
		return found_provider, text, true
	}
	if slash := strings.index_byte(text, '/'); slash > 0 {
		qualified_provider := text[:slash]
		qualified_model := text[slash + 1:]
		if _, found := agent.catalog_find_model(&app.setup.catalog, qualified_provider, qualified_model); found {
			return qualified_provider, qualified_model, true
		}
	}
	if matches > 1 {
		snap_append(app, .Notice, fmt.tprintf("several providers serve %s; use provider/model", text))
	} else {
		snap_append(app, .Notice, fmt.tprintf("no model %s", text))
	}
	return "", "", false
}

// refresh_status recomputes the status block from the session after a work
// item settles. Estimated input mirrors the agent's estimator over the
// active request span.
refresh_status :: proc(app: ^App) {
	running := &app.setup.session
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	status := &app.run.snap.status
	// The estimate is the one the agent measured when it built the last request;
	// the main thread never reads the store, so it cannot compute one itself.
	status.est_input = running.last_estimate
	status.context_window = running.context_window
	status.cwd = running.workspace
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
	// Cost accumulation lands here once the catalog carries pricing.
	_ = operation
	app.run.snap.generation += 1
}

// --- input handling -------------------------------------------------------

// Command_Id names what a slash command does. The id is what dispatch switches
// on; everything else about a command lives in its table row.
Command_Id :: enum {
	Quit,
	Help,
	New_Session,
	Resume,
	Compact,
	Status,
	Effort,
	Model,
}

// Command is one slash command. name is what the user types, summary is what
// /help says about it, and open_menu shows the list its argument is chosen from
// (nil when it takes no argument). The table is the only place a command is
// declared, so completion, help, and dispatch cannot disagree about what exists
// or about which commands offer a list.
Command :: struct {
	id:        Command_Id,
	name:      string,
	summary:   string,
	open_menu: proc(app: ^App),
}

@(rodata)
COMMANDS := [?]Command {
	Command{id = .Quit, name = "/quit", summary = "exit; during a turn, cancel it first"},
	Command{id = .Help, name = "/help", summary = "list the commands"},
	Command{id = .New_Session, name = "/new", summary = "start a new session"},
	Command{id = .Resume, name = "/resume", summary = "choose a session to resume", open_menu = menu_open_session},
	Command{id = .Compact, name = "/compact", summary = "summarize the active context now"},
	Command{id = .Status, name = "/status", summary = "show the session, model, and context"},
	Command{id = .Effort, name = "/effort", summary = "choose a reasoning effort level", open_menu = menu_open_effort},
	Command{id = .Model, name = "/model", summary = "choose a provider and model", open_menu = menu_open_model},
}

// command_find looks a command up by its exact name, ignoring case.
command_find :: proc(name: string) -> (Command, bool) {
	for command in COMMANDS {
		if strings.equal_fold(command.name, name) { return command, true }
	}
	return {}, false
}

// command_split separates a command's name from its argument.
command_split :: proc(text: string) -> (name, argument: string) {
	trimmed := strings.trim_space(text)
	space := strings.index_byte(trimmed, ' ')
	if space < 0 { return trimmed, "" }
	return trimmed[:space], strings.trim_space(trimmed[space + 1:])
}

// command_prefixed reports whether the typed text is a prefix of a command,
// ignoring case so a capital is a typo rather than a miss.
command_prefixed :: proc(command, typed: string) -> bool {
	if len(typed) > len(command) { return false }
	return strings.equal_fold(command[:len(typed)], typed)
}

// complete_command advances the slash command at the prompt. Tab cycles: the
// first press reaches the first match of what is typed, and the next press moves
// to the one after it, wrapping around, so pressing Tab on "/" walks the whole
// set. A completed name whose command takes a list opens that list. Matching
// ignores case; what is written back is the command's own lowercase name.
complete_command :: proc(app: ^App) {
	typed := widgets.input_text(&app.input)
	if !strings.has_prefix(typed, "/") || strings.contains_rune(typed, ' ') {
		completion_reset(app)
		return
	}

	// A second Tab still refers to the prefix the cycle began with, because the
	// input now holds the name the previous press wrote.
	query := typed
	after := -1
	if app.completion_active {
		query = app.completion_query
		after = app.completion_index
	}

	index, found := command_next_match(query, after)
	if !found {
		completion_reset(app)
		return
	}
	command := COMMANDS[index]
	if !app.completion_active && query == command.name {
		completion_reset(app)
		if command.open_menu != nil { command.open_menu(app) }
		return
	}

	// The query is stored only when a cycle begins, because the stored copy is
	// what a later press reads and the input buffer is what it was taken from.
	if !app.completion_active { completion_query_set(app, typed) }
	app.completion_index = index
	app.completion_active = true
	widgets.input_clear(&app.input)
	widgets.input_insert(&app.input, command.name)
}

// command_next_match finds the next command after `after` whose name starts with
// query, wrapping around. -1 starts at the beginning.
command_next_match :: proc(query: string, after: int) -> (int, bool) {
	for offset in 1 ..= len(COMMANDS) {
		index := (after + offset) % len(COMMANDS)
		if command_prefixed(COMMANDS[index].name, query) { return index, true }
	}
	return 0, false
}

// completion_reset ends a Tab cycle. Any key other than Tab calls it, so an edit
// starts the next cycle from what is on screen.
completion_reset :: proc(app: ^App) {
	app.completion_active = false
	app.completion_index = 0
	delete(app.completion_query, app.run.alloc)
	app.completion_query = ""
}

@(private)
completion_query_set :: proc(app: ^App, query: string) {
	delete(app.completion_query, app.run.alloc)
	app.completion_query = strings.clone(query, app.run.alloc)
}

// command_help prints the command table and the keys the prompt answers to. It is
// generated from the same table completion and dispatch read, so it cannot go
// stale.
command_help :: proc(app: ^App) {
	snap_append(app, .Notice, "commands")
	for command in COMMANDS {
		snap_append(app, .Notice, fmt.tprintf("  %-11s %s", command.name, command.summary))
	}
	snap_append(app, .Notice, "  tab completes a command and cycles through the matches")
	snap_append(app, .Notice, "  a command that names a list opens it when given no argument")
	snap_append(app, .Notice, "keys: escape interrupt | ctrl+c clear, cancel, then quit")
}

handle_event :: proc(app: ^App, event: input.Event) {
	#partial switch data in event {
	case input.Key_Event:
		if app.menu_open {
			handle_menu_key(app, data)
		} else {
			handle_key(app, data)
		}
	case input.Resize_Event:
	case input.Paste:
		paste_insert(app, data.text)
	case input.End_Of_Input:
		app.quit = true
	case input.Unknown_Input:
	}
}

// cancel_or_quit cancels the running request, or exits when nothing is running. A
// cancel this front-end requested is remembered, so the retirement that follows
// ends the turn rather than the session.
cancel_or_quit :: proc(app: ^App) {
	if runtime_busy(app) {
		app.cancel_seen = true
		agent.chat_cancel_request()
		return
	}
	app.quit = true
}

// interrupt resolves one Ctrl+C press in the order the prompt's state demands:
// text being composed is discarded first, then a running request is cancelled,
// and only an empty, idle prompt exits. The first state that applies wins, so a
// half-written prompt can neither cancel work nor end the session.
interrupt :: proc(app: ^App) {
	if len(widgets.input_text(&app.input)) > 0 {
		widgets.input_clear(&app.input)
		return
	}
	cancel_or_quit(app)
}

handle_key :: proc(app: ^App, key: input.Key_Event) {
	switch key.code {
	case .Enter:
		submit(app)
	case .Backspace:
		completion_reset(app)
		widgets.input_backspace(&app.input)
	case .Delete:
		completion_reset(app)
		widgets.input_delete(&app.input)
	case .Left:
		widgets.input_move_left(&app.input)
	case .Right:
		widgets.input_move_right(&app.input)
	case .Home:
		widgets.input_move_home(&app.input)
	case .End:
		widgets.input_move_end(&app.input)
	case .Escape:
		if runtime_busy(app) {
			app.cancel_seen = true
			agent.chat_cancel_request()
		} else {
			widgets.input_clear(&app.input)
		}
	case .Page_Up:
		page := app.rows - 3
		if page < 1 {
			page = 1
		}
		app.scroll += page
	case .Page_Down:
		page := app.rows - 3
		if page < 1 {
			page = 1
		}
		app.scroll -= page
		if app.scroll < 0 {
			app.scroll = 0
		}
	case .Tab:
		complete_command(app)
	case .Up, .Down:
	case .Character:
		if .Control in key.modifiers {
			switch key.character {
			case '\x03':
				interrupt(app)
			case '\x04':
				cancel_or_quit(app)
			}
		} else if key.character >= 0x20 && key.character != 0x7f {
			completion_reset(app)
			widgets.input_insert_rune(&app.input, key.character)
		}
	case .Insert, .F1, .F2, .F3, .F4, .F5:
	}
}

// submit sends the prompt line as a turn prompt or a slash command.
submit :: proc(app: ^App) {
	text := strings.trim_space(widgets.input_text(&app.input))
	if text == "" {
		widgets.input_clear(&app.input)
		completion_reset(app)
		return
	}
	if strings.has_prefix(text, "/") {
		dispatch_command(app, text)
	} else {
		enqueue(app, .Prompt, "", text)
	}
	widgets.input_clear(&app.input)
	completion_reset(app)
}

// dispatch_command routes one slash command. The name comes from the command
// table, so a command that completion and help know about is always one dispatch
// can run; the switch decides what that command does. Everything else is reported
// as unknown rather than sent to the model.
dispatch_command :: proc(app: ^App, text: string) {
	name, argument := command_split(text)
	command, found := command_find(name)
	if !found {
		snap_append(app, .Notice, fmt.tprintf("unknown command: %s (try /help)", name))
		return
	}
	// A command whose argument is chosen from a list opens that list when given no
	// argument. One rule covers every such command, and it is the same rule
	// completion applies to a completed name.
	if argument == "" && command.open_menu != nil {
		command.open_menu(app)
		return
	}
	switch command.id {
	case .Quit:
		if runtime_busy(app) {
			app.cancel_seen = true
			agent.chat_cancel_request()
		}
		app.quit = true
	case .Help:
		command_help(app)
	case .New_Session:
		enqueue(app, .New_Session, "", "")
	case .Resume:
		enqueue(app, .Resume_Session, "", argument)
	case .Compact:
		enqueue(app, .Compact, "", "")
	case .Status:
		enqueue(app, .Status, "", "")
	case .Effort:
		enqueue(app, .Effort, "", argument)
	case .Model:
		provider_id, model_id, ok := resolve_model_reference(app, argument)
		if ok {
			enqueue(app, .Model, provider_id, model_id)
		}
	}
}

enqueue :: proc(app: ^App, kind: Work_Kind, provider, text: string) {
	item := Work {
		kind = kind,
	}
	if provider != "" {
		item.provider = strings.clone(provider, app.run.alloc)
	}
	if text != "" {
		item.text = strings.clone(text, app.run.alloc)
	}
	if chan.try_send(app.run.work, item) {
		return
	}
	if item.text != "" {
		delete(item.text, app.run.alloc)
	}
	if item.provider != "" {
		delete(item.provider, app.run.alloc)
	}
	snap_append(app, .Warning, "input queue full; line dropped")
}

// --- prompt line editing --------------------------------------------------

// paste_insert inserts a bracketed paste at the cursor. A single-line prompt
// has no place for a line break, so CR/LF become spaces and other controls are
// dropped.
paste_insert :: proc(app: ^App, text_value: string) {
	if text_value == "" {
		return
	}
	run := strings.builder_make(0, 0, context.temp_allocator)
	for r in text_value {
		switch {
		case r == '\r' || r == '\n':
			strings.write_byte(&run, ' ')
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f):
		// A control code point has no place in the prompt line.
		case:
			strings.write_rune(&run, r)
		}
	}
	widgets.input_insert(&app.input, strings.to_string(run))
}
