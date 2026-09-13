#+build linux
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

import "nabla:agent"
import "nabla:agent/session"
import "nabla:ai"
import input "nabla:input"
import "nabla:term"
import "nabla:tui/widgets"

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
	// owns_selection says whether this run's model choice is the user's. The
	// interactive harness owns it: its choice is published to the front-end and
	// remembered for the next launch. A headless or child run does not, because it
	// selects a model for one job and must not change what the user starts with.
	owns_selection:   bool,
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

	adoption, message, adopted := session_adopt(setup, target.id)
	if !adopted {
		defer delete(message, setup.alloc)
		fmt.eprintln("nabla:", message)
		return false
	}
	defer adoption_destroy(&adoption, setup.alloc)
	report_recovery(adoption.recovery)

	claimed, held := session.session_claimed(&setup.store)
	if !held {
		fmt.eprintln("nabla: the session claim went missing")
		return false
	}
	setup.workspace = strings.clone(adoption.header.workspace, setup.alloc)
	setup.resumed_provider = strings.clone(adoption.header.provider, setup.alloc)
	setup.resumed_model = strings.clone(adoption.header.model, setup.alloc)
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
		// An empty session does not count. A launch opened and closed without a prompt
		// must not become the session a later --resume picks up.
		sessions, list_err := session.session_list(&setup.store, {workspace = launch_workspace, limit = 1, used_only = true}, setup.alloc)
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

// Adoption is a session this process has taken over: the header as read under the
// claim, and what an interrupted run left to settle. header is owned by the
// allocator session_adopt was given.
Adoption :: struct {
	header:   session.Session,
	recovery: session.Recovery,
}

adoption_destroy :: proc(adoption: ^Adoption, allocator: mem.Allocator) {
	session.session_destroy(&adoption.header, allocator)
	adoption^ = {}
}

// session_adopt makes id the claimed session on this store: it takes the candidate
// claim while the claim the store already holds stays held, reads the header under
// the new claim, and settles whatever an interrupted run left running. The
// displaced claim is released only after all of that has succeeded.
//
// A refusal leaves the store holding exactly the claim it held before, so a switch
// that fails leaves the running session claimed and usable. The message is owned by
// setup.alloc.
//
// It runs on whichever thread owns the store: the startup thread before the worker
// exists, and the worker afterwards.
session_adopt :: proc(setup: ^Run_Setup, id: session.Session_Id) -> (adopted: Adoption, message: string, ok: bool) {
	displaced, claim_err := session.session_claim_candidate(&setup.store, id)
	if claim_err != nil {
		local := claim_err
		return {}, strings.concatenate({"cannot take the session: ", session.error_detail(&local)}, setup.alloc), false
	}

	// The claim is what makes the row safe to read: another process may have deleted
	// the session between the caller's own read and this claim.
	header, load_err := session.session_load(&setup.store, id, setup.alloc)
	if load_err != nil {
		// Abandoning the candidate cannot fail in a way the caller could act on: the
		// descriptor is closed either way, so the lock is gone.
		_ = session.session_claim_restore(&setup.store, displaced)
		local := load_err
		return {}, strings.concatenate({"cannot open the session: ", session.error_detail(&local)}, setup.alloc), false
	}
	recovery, recover_err := session.session_recover(
		&setup.store,
		id,
		{at_ms = session.now_ms(), recovered_content = agent.TOOL_RECOVERED_RESULT, unexecuted_content = agent.TOOL_UNEXECUTED_RESULT},
	)
	if recover_err != nil {
		session.session_destroy(&header)
		_ = session.session_claim_restore(&setup.store, displaced)
		local := recover_err
		return {}, strings.concatenate({"cannot settle the session: ", session.error_detail(&local)}, setup.alloc), false
	}

	// The candidate is settled, so the session that was running can be given up. A
	// release that reports an error has still closed the descriptor, which is what
	// actually frees the lock, so there is nothing left for the caller to do.
	_ = session.claim_release(&displaced)
	return Adoption{header = header, recovery = recovery}, "", true
}

// session_activate makes an adopted session the running one. Its claim is already
// the store's, so the previous chat is destroyed here and the workspace and chat
// both become the adopted session's.
@(private)
session_activate :: proc(app: ^App, adoption: ^Adoption) {
	setup := &app.setup
	claimed, held := session.session_claimed(&setup.store)
	if !held {
		// session_adopt commits the candidate claim, so this cannot happen; a missing
		// claim would mean the store lost it underneath us.
		snap_append(app, .Error, "the session claim went missing")
		return
	}
	agent.chat_session_destroy(&setup.session)
	delete(setup.workspace, setup.alloc)
	setup.workspace = strings.clone(adoption.header.workspace, setup.alloc)
	setup.session = agent.chat_session_init(&setup.store, claimed, setup.workspace, setup.alloc)
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
	if app.setup.owns_selection { selection_publish_locked(app, provider_id, model_id) }
	sync.mutex_unlock(&app.run.mu)

	// A run that owns the selection remembers it, so the next launch restores the
	// user's own last choice. A headless or child run leaves it alone.
	if app.setup.owns_selection {
		saved := session.Selection {
			provider = provider_id,
			model    = model_id,
			effort   = running.effort,
		}
		if save_err := session.selection_save(&app.setup.store, saved); save_err != nil {
			local := save_err
			fmt.eprintln("nabla: the selection could not be recorded:", session.error_detail(&local))
		}
	}
	return true
}

// selection_publish_locked shows an applied selection to the front-end. The
// caller holds the runtime mutex, because the status block is what the frame
// reads; a headless run has no frame and never calls this.
@(private)
selection_publish_locked :: proc(app: ^App, provider_id, model_id: string) {
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
	status.context_window = running.context_window
	delete(app.run.snap.setup_error, app.run.alloc)
	app.run.snap.setup_error = ""
	snap_append_locked(app, .Notice, fmt.tprintf("model set to %s / %s", provider_id, model_id))
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

	selection, found, load_err := session.selection_load(&app.setup.store, app.run.alloc)
	defer session.selection_destroy(&selection, app.run.alloc)
	if load_err != nil {
		// A database the store just opened failing to answer this is worth saying
		// out loud, but the launch can still proceed to the model menu.
		local := load_err
		fmt.eprintln("nabla: the selection could not be read:", session.error_detail(&local))
	}
	applied := found && apply_selection(app, selection.provider, selection.model, selection.effort)
	if !applied && app.setup.resumed_provider != "" && app.setup.resumed_model != "" {
		apply_selection(app, app.setup.resumed_provider, app.setup.resumed_model, "")
	}
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
