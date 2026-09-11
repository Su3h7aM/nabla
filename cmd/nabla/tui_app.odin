#+build linux
package main

// tui_app.odin is the harness's full-screen front-end.
//
// One worker thread owns the session: it runs turns, tool executions, and
// compaction, and it is the only thread that mutates agent state. The main
// thread owns the terminal: it reads input, edits the prompt line, and
// renders. Communication is a single direction: the worker pushes work
// results into the runtime snapshot (under a mutex) and the main thread
// renders that snapshot. The session is never shared unlocked.
//
// The snapshot is a display projection only. The session keeps the real
// history, request context, effort, and usage; the TUI renders the snapshot
// and nothing else.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:unicode/utf8"

import "nabla:agent"
import "nabla:ai"
import input "nabla:input"
import "nabla:term"

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
	entries:    [dynamic]Entry, // owned,
	status:     Status,
	generation: u64,
}

Work_Kind :: enum u8 {
	Prompt,
	Compact,
	Context,
	Effort,
	Model,
}
Work :: struct {
	kind: Work_Kind,
	text: string, // owned,
}

Work_Chan :: chan.Chan(Work)

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
	alloc:       mem.Allocator,
}

App :: struct {
	setup:           Run_Setup,
	terminal:        ^term.Session,
	tty:             ^os.File,
	parser:          input.Parser,
	run:             Runtime,
	storage:         ^Frame_Storage,
	home:            string, // owned; shortens the footer path,
	line:            [dynamic]u8, // owned prompt line,
	cursor:          int,
	scroll:          int, // lines scrolled back; 0 follows the bottom,
	events:          [dynamic]input.Event,
	generation_seen: u64,
	columns:         int,
	rows:            int,
	quit:            bool,
}

// run_setup resolves the catalog, validates the selection, and builds the
// session. Errors print to stderr; false means the caller should exit.
run_setup :: proc(sources: []agent.Catalog_Provider_Source, provider_id, model_id: string) -> (Run_Setup, bool) {
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

	provider_index, provider_found := agent.catalog_find_provider(&result.catalog, provider_id)
	if !provider_found {
		fmt.eprintln("nabla: provider not found:", provider_id)
		return result, false
	}
	provider := &result.catalog.providers[provider_index]
	model_index, model_found := agent.catalog_find_model(&result.catalog, provider_id, model_id)
	if !model_found {
		fmt.eprintln("nabla: model not found for provider:", provider_id, model_id)
		return result, false
	}
	model := &result.catalog.models[model_index]
	if !provider.base_url_present || provider.base_url == "" {
		fmt.eprintln("nabla: selected provider requires explicit base_url endpoint")
		return result, false
	}
	if !provider.api_present || provider.api == "" {
		fmt.eprintln("nabla: selected provider requires explicit api")
		return result, false
	}
	api, api_ok := agent.chat_api_kind(provider.api)
	if !api_ok {
		fmt.eprintln("nabla: unsupported api:", provider.api)
		return result, false
	}
	if !provider.api_key_present {
		fmt.eprintln("nabla: selected provider requires api_key")
		return result, false
	}
	credential, credential_ok := agent.config_resolve_credential(provider.api_key, result.alloc)
	if !credential_ok {
		fmt.eprintln("nabla: selected provider requires api_key: name an environment variable that is set, or provide the key")
		return result, false
	}
	result.credential = credential
	result.api = api
	result.connection = ai.Provider_Connection {
		API        = api,
		Endpoint   = provider.base_url,
		Credential = credential,
	}

	session := agent.chat_session_init(result.alloc)
	result.session = session
	if session.workspace == "" {
		fmt.eprintln("nabla: cannot determine working directory")
		return result, false
	}
	session.tools_enabled = (model.tools_present && model.tools) && agent.chat_supports_tools(api)
	session.max_output_tokens = model.max_output_tokens
	window, _ := agent.chat_context_window(model^)
	session.context_window = window
	if model.thinking.levels_present {
		for level in model.thinking.levels {
			append(&session.effort_levels, strings.clone(level, result.alloc))
		}
	}
	result.session = session
	result.provider_id = strings.clone(provider_id, result.alloc)
	result.model_id = strings.clone(model_id, result.alloc)

	ok = true
	return result, true
}

run_setup_destroy :: proc(setup: ^Run_Setup) {
	agent.chat_session_destroy(&setup.session)
	agent.catalog_destroy(&setup.catalog)
	if setup.credential != "" { delete(setup.credential, setup.alloc) }
	if setup.provider_id != "" { delete(setup.provider_id, setup.alloc) }
	if setup.model_id != "" { delete(setup.model_id, setup.alloc) }
	setup^ = {}
}

// tui_run is the interactive entry point: resolve, open the terminal, start
// the worker, and drive the frame loop until quit.
tui_run :: proc(sources: []agent.Catalog_Provider_Source, provider_id, model_id: string) {
	setup, setup_ok := run_setup(sources, provider_id, model_id)
	if !setup_ok {
		return
	}

	terminal, open_err := term.open({alternate_screen = true, input_mode = .Raw})
	if open_err != nil {
		fmt.eprintln("nabla: cannot open the terminal:", open_err)
		run_setup_destroy(&setup)
		return
	}
	defer { _ = term.close(terminal) }
	tty, file_err := term.session_file(terminal)
	if file_err != nil {
		fmt.eprintln("nabla: cannot access the terminal input:", file_err)
		run_setup_destroy(&setup)
		return
	}

	app := new(App)
	defer free(app)
	app.setup = setup
	app.terminal = terminal
	app.tty = tty
	app.run.alloc = context.allocator
	app.run.connection = setup.connection
	app.run.snap.entries = make([dynamic]Entry, 0, 16, app.run.alloc)
	app.run.snap.status.provider_id = setup.provider_id
	app.run.snap.status.model_id = strings.clone(setup.model_id, app.run.alloc)
	app.run.snap.status.cwd = setup.session.workspace
	app.run.snap.status.context_window = setup.session.context_window
	app.home = os.get_env("HOME", app.run.alloc)
	app.line = make([dynamic]u8, 0, 128, app.run.alloc)
	app.events = make([dynamic]input.Event, 0, 16, app.run.alloc)
	app.storage = frame_storage_new(app.run.alloc)
	app.run.work, _ = chan.create_buffered(Work_Chan, WORK_CAPACITY, app.run.alloc)

	input.parser_init(&app.parser)
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

	if viewport, vp_err := term.viewport(terminal); vp_err == nil {
		app.columns, app.rows = viewport.columns, viewport.rows
		present_frame(app, app.storage)
	}

	for !app.quit {
		count, read_err := input.read_events(&app.parser, app.tty, &app.events, TUI_POLL_MS)
		if read_err != nil {
			fmt.eprintln("nabla: input:", read_err)
			break
		}
		for event in app.events {
			handle_event(app, event)
		}
		clear(&app.events)

		// A terminal that has not reported a size yet (ENODATA) is treated
		// as "keep waiting": nothing can be drawn until one exists.
		viewport, vp_err := term.viewport(terminal)
		if vp_err != nil {
			continue
		}
		resized := viewport.columns != app.columns || viewport.rows != app.rows
		app.columns, app.rows = viewport.columns, viewport.rows

		// SIGINT/SIGTERM through the agent handler: cancel a running turn,
		// or quit when idle (raw mode sends Ctrl-C as a byte, handled below).
		if agent.chat_cancel_requested() && !runtime_busy(app) {
			app.quit = true
			break
		}

		if count > 0 || resized || generation_changed(app) {
			present_frame(app, app.storage)
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
	delete(app.run.snap.status.model_id, app.run.alloc)
	delete(app.run.snap.status.effort, app.run.alloc)
	delete(app.home, app.run.alloc)
	delete(app.line)
	delete(app.events)
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
		if work.text == "" || work.text == "default" {
			agent.chat_session_set_effort(&app.setup.session, "")
			snap_append(app, .Notice, "effort cleared to provider default")
		} else if agent.chat_session_set_effort(&app.setup.session, work.text) {
			snap_append(app, .Notice, fmt.tprintf("effort set to %s for the next request", work.text))
		} else {
			snap_append(app, .Notice, fmt.tprintf("effort %s is not allowed for this model", work.text))
		}
	case .Model:
		run_model(app, work.text)
	}
	refresh_status(app)
}

// run_model switches the session to another model of the same provider.
// Only the worker mutates the session; the footer picks the new id up from
// the next refresh_status.
run_model :: proc(app: ^App, model_id: string) {
	if app.setup.session.state != .Idle {
		snap_append(app, .Warning, "the model can change only when idle")
		return
	}
	index, found := agent.catalog_find_model(&app.setup.catalog, app.setup.provider_id, model_id)
	if !found {
		snap_append(app, .Warning, fmt.tprintf("no model %s under provider %s", model_id, app.setup.provider_id))
		return
	}
	model := &app.setup.catalog.models[index]
	session := &app.setup.session
	window, _ := agent.chat_context_window(model^)
	session.context_window = window
	session.max_output_tokens = model.max_output_tokens
	session.tools_enabled = (model.tools_present && model.tools) && agent.chat_supports_tools(app.setup.api)
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
	sync.mutex_lock(&app.run.mu)
	defer sync.mutex_unlock(&app.run.mu)
	delete(app.setup.model_id, app.setup.alloc)
	app.setup.model_id = strings.clone(model.id, app.setup.alloc)
	app.run.snap.generation += 1
	snap_append_locked(app, .Notice, fmt.tprintf("model set to %s", model.id))
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
		handle_key(app, data)
	case input.Resize_Event:
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
		edit_backspace(app)
	case .Delete:
		edit_delete(app)
	case .Left:
		edit_left(app)
	case .Right:
		edit_right(app)
	case .Home:
		app.cursor = 0
	case .End:
		app.cursor = len(app.line)
	case .Escape:
		clear(&app.line)
		app.cursor = 0
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
			if key.character == '\x03' {
				if runtime_busy(app) {
					agent.chat_cancel_request()
				} else {
					app.quit = true
				}
			}
		} else if key.character >= 0x20 && key.character != 0x7f {
			edit_insert(app, key.character)
		}
	case .Insert, .F1, .F2, .F3, .F4, .F5:
	}
}

// submit sends the prompt line as a turn prompt or a slash command.
submit :: proc(app: ^App) {
	text := strings.trim_space(string(app.line[:]))
	if text == "" {
		clear(&app.line)
		app.cursor = 0
		return
	}
	if strings.has_prefix(text, "/") {
		dispatch_command(app, text)
	} else {
		enqueue(app, .Prompt, text)
	}
	clear(&app.line)
	app.cursor = 0
}

// dispatch_command picks only the known commands; everything else is
// reported as unknown rather than sent to the model. Command semantics live
// in the agent; this only routes the input.
dispatch_command :: proc(app: ^App, text: string) {
	switch {
	case text == "/quit":
		if runtime_busy(app) {
			agent.chat_cancel_request()
		}
		app.quit = true
	case text == "/compact":
		enqueue(app, .Compact, "")
	case text == "/context":
		enqueue(app, .Context, "")
	case text == "/effort" || strings.has_prefix(text, "/effort "):
		enqueue(app, .Effort, strings.trim_space(text[len("/effort"):]))
	case text == "/model" || strings.has_prefix(text, "/model "):
		rest := strings.trim_space(text[len("/model"):])
		if rest == "" {
			snap_append(app, .Notice, "usage: /model <model-id>")
			return
		}
		enqueue(app, .Model, rest)
	case:
		snap_append(app, .Notice, fmt.tprintf("unknown command: %s", text))
	}
}

enqueue :: proc(app: ^App, kind: Work_Kind, text: string) {
	item := Work {
		kind = kind,
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
	snap_append(app, .Warning, "input queue full; line dropped")
}

// --- prompt line editing --------------------------------------------------

edit_insert :: proc(app: ^App, r: rune) {
	encoded, width := utf8.encode_rune(r)
	old_len := len(app.line)
	allowed := old_len + width
	for len(app.line) < allowed {
		append(&app.line, 0)
	}
	for i := old_len - 1; i >= app.cursor; i -= 1 {
		app.line[i + width] = app.line[i]
	}
	for k in 0 ..< width {
		app.line[app.cursor + k] = encoded[k]
	}
	app.cursor += width
}

edit_backspace :: proc(app: ^App) {
	if app.cursor == 0 {
		return
	}
	start := app.cursor - 1
	for start > 0 && (app.line[start] & 0xC0) == 0x80 {
		start -= 1
	}
	// remove_range takes the half-open range [lo, hi), not index and count.
	remove_range(&app.line, start, app.cursor)
	app.cursor = start
}

edit_delete :: proc(app: ^App) {
	if app.cursor >= len(app.line) {
		return
	}
	width := 1
	if app.line[app.cursor] >= 0x80 {
		_, decoded := utf8.decode_rune(app.line[app.cursor:])
		width = decoded
	}
	// remove_range takes the half-open range [lo, hi), not index and count.
	remove_range(&app.line, app.cursor, app.cursor + width)
}

edit_left :: proc(app: ^App) {
	if app.cursor == 0 {
		return
	}
	start := app.cursor - 1
	for start > 0 && (app.line[start] & 0xC0) == 0x80 {
		start -= 1
	}
	app.cursor = start
}

edit_right :: proc(app: ^App) {
	if app.cursor >= len(app.line) {
		return
	}
	_, width := utf8.decode_rune(app.line[app.cursor:])
	app.cursor += width
}
