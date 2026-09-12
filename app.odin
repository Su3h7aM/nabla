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
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"

import "nabla:agent"
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
// both stable for the app's lifetime); model_id and effort are owned display
// copies, replaced under the runtime mutex when they change.
Status :: struct {
	provider_id:        string,
	model_id:           string, // owned,
	effort:             string, // owned,
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
	entries:     [dynamic]Entry, // owned,
	status:      Status,
	// setup_error is why the last selection attempt failed; the picker shows
	// it because it has no transcript.
	setup_error: string, // owned,
	generation:  u64,
}

Work_Kind :: enum u8 {
	Prompt,
	Compact,
	Context,
	Effort,
	Model,
}
Work :: struct {
	kind:     Work_Kind,
	provider: string, // owned; target provider for .Model, empty otherwise,
	text:     string, // owned; model id for .Model, prompt or effort text otherwise,
}

Work_Chan :: chan.Chan(Work)

// Picker_Entry is one selectable model in the picker: a serving identity.
Picker_Entry :: struct {
	provider_id: string,
	model_id:    string,
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
// selected provider/model, the connection, and the session.
Run_Setup :: struct {
	catalog:     agent.Catalog,
	api:         ai.API_Kind,
	credential:  string, // owned,
	connection:  ai.Provider_Connection,
	session:     agent.Chat_Session,
	provider_id: string, // owned,
	model_id:    string, // owned,
	// configured holds the provider ids the user's own configuration declares;
	// models.dev also contributes providers, and the picker offers only the
	// configured ones, whose credentials the user actually set up.
	configured:  [dynamic]string, // owned,
	alloc:       mem.Allocator,
}

App :: struct {
	setup:           Run_Setup,
	terminal:        ^term.Session,
	tty:             ^os.File,
	parser:          input.Parser,
	raw:             [dynamic]input.Event, // owned; the latest input batch,
	run:             Runtime,
	storage:         ^Frame_Storage,
	home:            string, // owned; shortens the footer path,
	input:           widgets.Input,
	scroll:          int, // lines scrolled back; 0 follows the bottom,
	generation_seen: u64,
	cancel_seen:     bool, // the running cancel came from our own keys, not a signal,
	spin_lap:        time.Tick, // last working-frame advance,
	spin_frame:      int,
	picking:         bool, // the model picker owns the input until a model applies,
	picker_cursor:   int,
	picker_top:      int, // first picker line on screen, so the cursor stays visible,
	columns:         int,
	rows:            int,
	quit:            bool,
}

// run_catalog resolves the configuration into the catalog and creates the
// session. Which provider and model run is applied separately, so the
// front-end can start without a selection and choose one in the TUI. Errors
// print to stderr; false means the caller should exit.
run_catalog :: proc(sources: []agent.Catalog_Provider_Source) -> (Run_Setup, bool) {
	result := Run_Setup {
		alloc = context.allocator,
	}
	ok := false
	defer if !ok {
		run_setup_destroy(&result)
	}

	models_dev, models_dev_err := agent.models_dev_sources(allocator = result.alloc)
	defer agent.catalog_sources_destroy(&models_dev, result.alloc)
	if models_dev_err != .None {
		fmt.eprintln("nabla: warning: models.dev is unavailable; using configured values only")
	}
	catalog, resolve_err := agent.resolve_catalog(sources, {}, models_dev[:], result.alloc)
	if resolve_err != .None {
		fmt.eprintln("nabla: invalid configuration: a model cannot be excluded and customized at the same time")
		return result, false
	}
	result.catalog = catalog
	for &source in sources {
		append(&result.configured, strings.clone(source.id, result.alloc))
	}

	session := agent.chat_session_init(result.alloc)
	result.session = session
	if session.workspace == "" {
		fmt.eprintln("nabla: cannot determine working directory")
		return result, false
	}

	ok = true
	return result, true
}

// provider_usable reports whether a provider can serve a request at all: an
// endpoint, an api family, and a credential source. The picker offers only
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
// effort level. It resolves the credential and builds the connection, so it
// must run where the runtime is owned: on the worker once it exists, or at
// startup before it starts. The selection persists on success, so the next
// launch restores it. A failure is reported through the snapshot; the
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

	session := &app.setup.session
	window, _ := agent.chat_context_window(model^)
	session.context_window = window
	session.max_output_tokens = model.max_output_tokens
	session.tools_enabled = (model.tools_present && model.tools) && agent.chat_supports_tools(api)
	agent.chat_session_set_effort(session, "")
	for level in session.effort_levels {
		delete(level, session.allocator)
	}
	clear(&session.effort_levels)
	if model.thinking.levels_present {
		for level in model.thinking.levels {
			append(&session.effort_levels, strings.clone(level, session.allocator))
		}
	}
	// A persisted effort the restored model does not allow falls back to the
	// provider default rather than failing the selection.
	desired := effort
	if desired != "" && !agent.chat_session_set_effort(session, desired) {
		desired = ""
	}

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
	app.setup.provider_id = strings.clone(provider_id, app.setup.alloc)
	delete(app.setup.model_id, app.setup.alloc)
	app.setup.model_id = strings.clone(model_id, app.setup.alloc)
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
	if status.effort != session.effort {
		delete(status.effort, app.run.alloc)
		status.effort = strings.clone(session.effort, app.run.alloc)
	}
	status.context_window = window
	delete(app.run.snap.setup_error, app.run.alloc)
	app.run.snap.setup_error = ""
	snap_append_locked(app, .Notice, fmt.tprintf("model set to %s / %s", provider_id, model_id))
	app.run.snap.generation += 1

	saved := agent.Selection {
		provider = provider_id,
		model    = model_id,
		effort   = session.effort,
	}
	sync.mutex_unlock(&app.run.mu)
	agent.selection_save(saved)
	sync.mutex_lock(&app.run.mu)
	return true
}

// selection_fail records why a selection could not apply. The picker shows it
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
	agent.catalog_destroy(&setup.catalog)
	for id in setup.configured {
		delete(id, setup.alloc)
	}
	delete(setup.configured)
	if setup.credential != "" { delete(setup.credential, setup.alloc) }
	if setup.provider_id != "" { delete(setup.provider_id, setup.alloc) }
	if setup.model_id != "" { delete(setup.model_id, setup.alloc) }
	setup^ = {}
}

// tui_run is the interactive entry point: resolve the catalog, open the
// terminal, apply the selection (explicit flags, then the persisted one, then
// the in-TUI picker), start the worker, and drive the frame loop until quit.
tui_run :: proc(sources: []agent.Catalog_Provider_Source, flag_provider, flag_model: string) {
	setup, setup_ok := run_catalog(sources)
	if !setup_ok {
		return
	}

	app := new(App)
	defer free(app)
	app.setup = setup
	app.run.alloc = context.allocator
	app.run.connection = setup.connection
	app.run.snap.entries = make([dynamic]Entry, 0, 16, app.run.alloc)
	app.run.snap.status.provider_id = strings.clone(setup.provider_id, app.run.alloc)
	app.run.snap.status.model_id = strings.clone(setup.model_id, app.run.alloc)
	app.run.snap.status.cwd = setup.session.workspace
	app.run.snap.status.context_window = setup.session.context_window
	// The picker owns the input until a selection applies: explicit flags, the
	// persisted selection, or the user's choice.
	app.picking = true
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
		app.picking = false
	} else if flag_provider == "" && flag_model == "" {
		if selection, selection_ok := agent.selection_load(app.run.alloc); selection_ok {
			if apply_selection(app, selection.provider, selection.model, selection.effort) {
				app.picking = false
			}
			delete(selection.provider, app.run.alloc)
			delete(selection.model, app.run.alloc)
			delete(selection.effort, app.run.alloc)
		}
	} else {
		fmt.eprintln("nabla: --provider and --model must be given together")
		app_teardown(app)
		return
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
		// A picker selection applies on the worker; the first status that
		// carries a model closes the picker.
		if app.picking && app.run.snap.status.model_id != "" {
			app.picking = false
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
	delete(app.run.snap.status.provider_id, app.run.alloc)
	delete(app.run.snap.status.model_id, app.run.alloc)
	delete(app.run.snap.status.effort, app.run.alloc)
	delete(app.run.snap.setup_error, app.run.alloc)
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

run_work :: proc(app: ^App, work: Work, observer: agent.Chat_Observer) {
	switch work.kind {
	case .Prompt:
		if !agent.chat_session_accept_user(&app.setup.session, work.text) {
			snap_append(app, .Warning, "chat is busy; input dropped")
			return
		}
		snap_append(app, .User, work.text)
		set_running(app, true)
		agent.chat_run_turn_steered(&app.setup.session, app.run.connection, app.setup.model_id, observer, nil)
	case .Compact:
		set_running(app, true)
		agent.chat_command_compact(&app.setup.session, observer, app.run.connection, app.setup.model_id, nil)
	case .Context:
		agent.chat_notice_context(&app.setup.session, observer)
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
	}
	refresh_status(app)
}

// picker_entries lists every model the picker offers: one entry per usable
// provider's model, ordered by provider id and then model id. The catalog's
// own order follows the configuration loader's table iteration, which varies
// between runs, so the picker sorts rather than trusting it.
picker_entries :: proc(app: ^App, out: ^[dynamic]Picker_Entry) {
	for &provider in app.setup.catalog.providers {
		if !provider_usable(&provider) || !provider_configured(app, provider.id) {
			continue
		}
		for &model in app.setup.catalog.models {
			if model.provider_id != provider.id {
				continue
			}
			picker_entry_insert(out, provider.id, model.id)
		}
	}
}

// picker_entry_insert places an entry so the list stays ordered by provider id
// and then model id.
picker_entry_insert :: proc(out: ^[dynamic]Picker_Entry, provider_id, model_id: string) {
	position := len(out^)
	for index in 0 ..< len(out^) {
		entry := &out^[index]
		order := strings.compare(entry.provider_id, provider_id)
		if order == 0 {
			order = strings.compare(entry.model_id, model_id)
		}
		if order >= 0 {
			position = index
			break
		}
	}
	append(out, Picker_Entry{})
	for index := len(out^) - 1; index > position; index -= 1 {
		out^[index] = out^[index - 1]
	}
	out^[position] = Picker_Entry {
		provider_id = provider_id,
		model_id    = model_id,
	}
}

// picker_count reports how many models the picker offers.
picker_count :: proc(app: ^App) -> int {
	entries := make([dynamic]Picker_Entry, 0, 16, context.temp_allocator)
	picker_entries(app, &entries)
	return len(entries)
}

// picker_page is how far one Page_Up/Page_Down moves in the picker.
picker_page :: proc(app: ^App) -> int {
	return max(app.rows - TUI_FOOTER_ROWS - 1, 1)
}

// picker_submit sends the entry under the cursor as the next selection.
picker_submit :: proc(app: ^App) {
	entries := make([dynamic]Picker_Entry, 0, 16, context.temp_allocator)
	picker_entries(app, &entries)
	if len(entries) == 0 {
		return
	}
	cursor := app.picker_cursor
	if cursor >= len(entries) {
		cursor = len(entries) - 1
	}
	enqueue(app, .Model, entries[cursor].provider_id, entries[cursor].model_id)
}

// handle_picker_key drives the model picker: arrows move, enter applies,
// escape quits.
handle_picker_key :: proc(app: ^App, key: input.Key_Event) {
	#partial switch key.code {
	case .Up:
		if app.picker_cursor > 0 {
			app.picker_cursor -= 1
		}
	case .Down:
		entries := make([dynamic]Picker_Entry, 0, 16, context.temp_allocator)
		picker_entries(app, &entries)
		if app.picker_cursor < len(entries) - 1 {
			app.picker_cursor += 1
		}
	case .Enter:
		picker_submit(app)
	case .Escape:
		app.quit = true
	case .Home:
		app.picker_cursor = 0
	case .End:
		entries := make([dynamic]Picker_Entry, 0, 16, context.temp_allocator)
		picker_entries(app, &entries)
		app.picker_cursor = max(len(entries) - 1, 0)
	case .Page_Up:
		app.picker_cursor = max(app.picker_cursor - picker_page(app), 0)
	case .Page_Down:
		app.picker_cursor = min(app.picker_cursor + picker_page(app), picker_count(app) - 1)
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
	session := &app.setup.session
	chars := 0
	count := 0
	for &message in session.messages[session.active_start:] {
		count += 1
		chars += len(message.text) + len(message.tool_call_id) + len(message.reasoning_id) + len(message.reasoning_encrypted)
		chars += len(message.tool_call.id) + len(message.tool_call.item_id) + len(message.tool_call.name) + len(message.tool_call.arguments)
	}
	estimate := chars / agent.CHAT_CHARS_PER_TOKEN + count * agent.CHAT_MESSAGE_OVERHEAD_TOKENS
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	status := &app.run.snap.status
	status.est_input = estimate
	status.context_window = session.context_window
	status.cwd = session.workspace
	status.running = session.state != .Idle
	if status.provider_id != app.setup.provider_id {
		delete(status.provider_id, app.run.alloc)
		status.provider_id = strings.clone(app.setup.provider_id, app.run.alloc)
	}
	if status.model_id != app.setup.model_id {
		delete(status.model_id, app.run.alloc)
		status.model_id = strings.clone(app.setup.model_id, app.run.alloc)
	}
	if status.effort != session.effort {
		delete(status.effort, app.run.alloc)
		status.effort = strings.clone(session.effort, app.run.alloc)
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

handle_event :: proc(app: ^App, event: input.Event) {
	#partial switch data in event {
	case input.Key_Event:
		if app.picking {
			handle_picker_key(app, data)
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

handle_key :: proc(app: ^App, key: input.Key_Event) {
	switch key.code {
	case .Enter:
		submit(app)
	case .Backspace:
		widgets.input_backspace(&app.input)
	case .Delete:
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
	case .Up, .Down:
	case .Character:
		if .Control in key.modifiers {
			if key.character == '\x03' || key.character == '\x04' {
				if runtime_busy(app) {
					app.cancel_seen = true
					agent.chat_cancel_request()
				} else {
					app.quit = true
				}
			}
		} else if key.character >= 0x20 && key.character != 0x7f {
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
		return
	}
	if strings.has_prefix(text, "/") {
		dispatch_command(app, text)
	} else {
		enqueue(app, .Prompt, "", text)
	}
	widgets.input_clear(&app.input)
}

// dispatch_command picks only the known commands; everything else is
// reported as unknown rather than sent to the model. Command semantics live
// in the agent; this only routes the input.
dispatch_command :: proc(app: ^App, text: string) {
	switch {
	case text == "/quit":
		if runtime_busy(app) {
			app.cancel_seen = true
			agent.chat_cancel_request()
		}
		app.quit = true
	case text == "/compact":
		enqueue(app, .Compact, "", "")
	case text == "/context":
		enqueue(app, .Context, "", "")
	case text == "/effort" || strings.has_prefix(text, "/effort "):
		enqueue(app, .Effort, "", strings.trim_space(text[len("/effort"):]))
	case text == "/model" || strings.has_prefix(text, "/model "):
		rest := strings.trim_space(text[len("/model"):])
		if rest == "" {
			snap_append(app, .Notice, "usage: /model <model-id>")
			return
		}
		provider_id, model_id, ok := resolve_model_reference(app, rest)
		if ok {
			enqueue(app, .Model, provider_id, model_id)
		}
	case:
		snap_append(app, .Notice, fmt.tprintf("unknown command: %s", text))
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
