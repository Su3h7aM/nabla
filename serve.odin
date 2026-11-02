#+build linux
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "nabla:agent"
import "nabla:agent/journal"

// Serve_Parse_Error is why the session server's arguments could not be read.
// None means they named a session.
Serve_Parse_Error :: enum {
	None,
	Unknown_Option,
	Missing_Value,
	Missing_Session,
}

// Serve_Options is the launch an interface passes when it re-executes the binary
// to start the session server. Strings are borrowed from the argument slice.
Serve_Options :: struct {
	session_id:  string,
	provider_id: string,
	model_id:    string,
	config_path: string,
}

// serve_main runs the session server and returns the process exit status.
// arguments are the process arguments after the program name. An interface
// re-executes the binary with --serve --session <id> and, when it has them,
// --provider, --model, and --config. Those arguments are not a user command.
// Exit 0 means another server already holds the session, or this one was idle.
// A failure prints one line on stderr and returns non-zero.
@(require_results)
serve_main :: proc(arguments: []string) -> int {
	process_name_set(PROCESS_NAME_MAIN)
	options, parse_error := serve_parse(arguments)
	if parse_error != .None {
		serve_parse_report(parse_error)
		return 2
	}
	if (options.provider_id == "") != (options.model_id == "") {
		fmt.eprintln("nabla: --provider and --model must be given together")
		return 2
	}

	explicit_config := options.config_path
	config_path := options.config_path
	if config_path == "" {
		directory, directory_err := agent.xdg_directory(.Config, context.temp_allocator)
		if directory_err != .None {
			fmt.eprintln("nabla: cannot resolve the configuration directory")
			return 1
		}
		path, path_error := strings.concatenate([]string{directory, "/config.lua"}, allocator = context.temp_allocator)
		if path_error != nil {
			fmt.eprintln("nabla: the configuration path could not be allocated")
			return 1
		}
		config_path = path
	}
	sources, harness_options, mcp_servers, config_err, config_detail := agent.load_lua_config(config_path)
	defer if config_detail != "" { delete(config_detail) }
	if config_err != .None && config_err != .Missing {
		fmt.eprintln(config_error_display_text(config_path, config_err, config_detail))
		return 1
	}
	if !subagent_launch_options(&harness_options, explicit_config) { return 1 }
	defer {
		delete(harness_options.nabla_executable)
		delete(harness_options.nabla_config)
	}
	defer agent.catalog_sources_destroy(&sources)
	defer agent.mcp_servers_destroy(&mcp_servers)
	return serve_run(sources[:], mcp_servers[:], harness_options, options)
}

@(require_results)
serve_parse :: proc(args: []string) -> (Serve_Options, Serve_Parse_Error) {
	options: Serve_Options
	session_seen := false
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--serve" { continue }
		if arg == "--session" {
			if i + 1 >= len(args) { return options, .Missing_Value }
			i += 1
			options.session_id = args[i]
			session_seen = true
			continue
		}
		if strings.has_prefix(arg, "--session=") {
			options.session_id = arg[len("--session="):]
			session_seen = true
			continue
		}
		if strings.has_prefix(arg, "--config=") {
			options.config_path = arg[len("--config="):]
			continue
		}
		if strings.has_prefix(arg, "--provider=") {
			options.provider_id = arg[len("--provider="):]
			continue
		}
		if strings.has_prefix(arg, "--model=") {
			options.model_id = arg[len("--model="):]
			continue
		}
		if arg == "--config" || arg == "--provider" || arg == "--model" {
			if i + 1 >= len(args) { return options, .Missing_Value }
			i += 1
			if arg == "--config" { options.config_path = args[i] }
			if arg == "--provider" { options.provider_id = args[i] }
			if arg == "--model" { options.model_id = args[i] }
			continue
		}
		return options, .Unknown_Option
	}
	if !session_seen || options.session_id == "" { return options, .Missing_Session }
	return options, .None
}

serve_parse_report :: proc(parse_error: Serve_Parse_Error) {
	switch parse_error {
	case .Unknown_Option:
		fmt.eprintln("nabla: unknown option")
	case .Missing_Value:
		fmt.eprintln("nabla: option is missing its value")
	case .Missing_Session:
		fmt.eprintln("nabla: a session id is required")
	case .None:
	}
}

// serve_run claims the named session and serves it until it is idle or it fails.
// The model flags are applied the way a headless prompt applies them, and the
// saved selection is left as it was.
@(require_results)
serve_run :: proc(
	sources: []agent.Catalog_Provider_Source,
	mcp_servers: []agent.MCP_Server_Config,
	harness_options: agent.Harness_Options,
	options: Serve_Options,
) -> int {
	app, app_error := new(App)
	if app_error != nil {
		fmt.eprintln("nabla: out of memory")
		return 1
	}
	// run_setup_destroy sets workers_abandoned when a worker still reaches this
	// allocation, and that flag is read by the free below, which runs after it.
	abandoned := false
	defer if !abandoned { free(app) }
	app.run.alloc = context.allocator
	app.setup.alloc = context.allocator
	app.setup.harness_options = harness_options
	app.compact_on_switch = harness_options.compact_on_switch
	// The server watches the session it owns. It does not follow one it could not claim.
	app.setup.shared_sessions = true
	// The model this run uses belongs to the launch, not to the user.
	app.setup.owns_selection = false
	snapshot_transcript_own(app)
	defer {
		snapshot_destroy(app)
		run_setup_destroy(&app.setup)
		abandoned = app.setup.workers_abandoned
	}

	app.setup.mcp_servers = mcp_servers
	mcp_ok: bool
	app.setup.mcp, mcp_ok = mcp_runtime_make(mcp_servers, app.setup.alloc)
	if !mcp_ok {
		fmt.eprintln("nabla: the MCP runtime could not be allocated")
		return 1
	}
	catalog, configured, resolved := resolve_run_catalog(sources, app.setup.alloc)
	if !resolved { return 1 }
	app.setup.catalog = catalog
	app.setup.configured = configured

	ok, elsewhere := serve_session_open(&app.setup, options.session_id)
	if elsewhere { return 0 }
	if !ok { return 1 }
	if app.setup.watch_id == 0 {
		fmt.eprintln("nabla: cannot watch the session, so lines other processes send it would not arrive")
		return 1
	}
	if !apply_startup_selection(app, options.provider_id, options.model_id) {
		fmt.eprintln("nabla:", setup_error_text(app))
		return 1
	}
	if app.setup.model_id == "" {
		fmt.eprintln("nabla: no model is selected; give --provider and --model, or run the interactive harness once")
		return 1
	}
	if app.setup.session.storage_failed {
		return serve_storage_exit(&app.setup.session)
	}
	return serve_loop(app, serve_idle_limit(harness_options))
}

// serve_idle_limit is how long the server waits with nothing to do. Zero in
// configuration means the default.
@(require_results)
serve_idle_limit :: proc(options: agent.Harness_Options) -> time.Duration {
	seconds := options.idle_exit_seconds
	if seconds == 0 { seconds = agent.IDLE_EXIT_SECONDS_DEFAULT }
	return time.Duration(seconds) * time.Second
}

// serve_session_open claims the named session the way the owner path opens one:
// its own journal, the claim, recovery, then the running session. elsewhere means
// another server holds the claim; nothing is printed and the caller exits 0.
// ok false with elsewhere false means a reason was printed on stderr.
@(require_results)
serve_session_open :: proc(setup: ^Run_Setup, session_text: string) -> (ok: bool, elsewhere: bool) {
	directory, directory_error := agent.xdg_directory(.State, setup.alloc)
	if directory_error != .None {
		fmt.eprintln("nabla: cannot resolve the state directory for sessions")
		return false, false
	}
	setup.journal_directory = directory
	locks, replaced, locks_error := agent.session_lock_directory(setup.alloc)
	if locks_error != .None {
		fmt.eprintln("nabla: cannot resolve the directory for session locks")
		return false, false
	}
	setup.lock_directory = locks
	setup.run = journal.run_id_create()

	opened: Opened_Session
	defer opened_session_destroy(&opened, setup.alloc)
	open_error: journal.Error
	opened.store, open_error = session_store_open(setup)
	if open_error != nil {
		fmt.eprintln("nabla: cannot open the session database:", journal.error_text(open_error, context.temp_allocator))
		return false, false
	}
	if !setup.run_open {
		journal.append_record(opened.store, {kind = .Run_Started}, journal.Run_Started{pid = int(os.get_pid())})
	}

	parsed, valid := journal.session_id_parse(session_text)
	if !valid || parsed == {} {
		fmt.eprintln("nabla:", fmt.tprintf("%s is not a session id", session_text))
		return false, false
	}
	summaries, list_error := journal.list_sessions(opened.store, {session = parsed, limit = 1}, setup.alloc)
	if list_error != nil {
		fmt.eprintln("nabla:", session_error_message("cannot list sessions", list_error, setup.alloc))
		return false, false
	}
	defer journal.session_summaries_destroy(summaries, setup.alloc)
	if len(summaries) == 0 {
		fmt.eprintln("nabla:", fmt.tprintf("session %s does not exist", session_text))
		return false, false
	}
	summary := &summaries[0]
	if !os.is_dir(summary.workspace) {
		fmt.eprintln("nabla:", fmt.tprintf("the session's directory is not usable: %s", summary.workspace))
		return false, false
	}

	opened.id = summary.id
	_, claim_error := journal.claim(opened.store, summary.id)
	if claim_error != nil {
		if journal.error_is(claim_error, .Claimed) { return false, true }
		fmt.eprintln("nabla:", session_error_message("cannot take the session", claim_error, setup.alloc))
		return false, false
	}
	if replaced {
		fmt.eprintf("nabla: warning: XDG_RUNTIME_DIR is not an absolute path; session locks are kept in %s\n", setup.lock_directory)
	}

	message, settled := session_settle(&opened, summary.workspace, setup.alloc)
	if !settled {
		fmt.eprintln("nabla:", message)
		delete(message, setup.alloc)
		return false, false
	}
	if problem := session_install(setup, &opened); problem != "" {
		fmt.eprintln("nabla:", problem)
		return false, false
	}
	return true, false
}

// serve_loop reads the inbox and runs turns until the server has been idle for
// the whole limit, or until the session can no longer be stored. A publication
// on the owner wake, including one from the session watch, ends a wait early.
@(require_results)
serve_loop :: proc(app: ^App, idle: time.Duration) -> int {
	signals: agent.Chat_Interactive_Signals
	agent.chat_interactive_arm(&signals)
	defer agent.chat_interactive_disarm(&signals)

	idle_due: Maybe(time.Tick)
	for {
		defer free_all(context.temp_allocator)
		// Load the wake before any read, so a commit that lands after the read
		// cannot be missed by the wait below.
		seen := agent.owner_wake_seen()
		if agent.process_interrupted() {
			fmt.eprintln("nabla: interrupted")
			return 1
		}
		chat := &app.setup.session
		if chat.storage_failed {
			return serve_storage_exit(chat)
		}
		_ = agent.chat_background_report_failure(chat, {})
		if chat.storage_failed {
			return serve_storage_exit(chat)
		}
		_ = agent.chat_background_pending(chat)
		if chat.storage_failed {
			return serve_storage_exit(chat)
		}
		if app_compaction_pending(app) {
			_ = app_compaction_tick(app, {})
		}

		step, step_ok := serve_step(app)
		if !step_ok { return 1 }
		switch step {
		case .Turn:
			idle_due = nil
			if !serve_run_turn(app) { return 1 }
		case .Wait:
			idle_due = nil
			deadline := agent.chat_background_deadline(chat, agent.chat_compact_deadline(chat))
			free_all(context.temp_allocator)
			agent.owner_wake_wait(seen, deadline)
		case .None:
			if due, armed := idle_due.?; !armed {
				idle_due = time.tick_add(time.tick_now(), idle)
			} else if time.tick_diff(time.tick_now(), due) <= 0 {
				return 0
			}
			free_all(context.temp_allocator)
			agent.owner_wake_wait(seen, idle_due)
		}
	}
}

// Serve_Step is the one answer to whether the server has a next step. Turn delivers
// the pending inbox. Wait stays up for work already in progress. None is idle.
Serve_Step :: enum {
	None,
	Turn,
	Wait,
}

// serve_step is the idle decision. It is called on every wake. Turn means the inbox
// after the last delivered message holds any inbound record (user.input,
// background.completed, subagent.completed, or subagent.message) and the session is
// idle, so one turn should deliver that batch. Wait means a turn, tool job, subagent,
// or compaction is already in progress. None means nothing of that is left, so the
// idle limit may run. An interrupted turn from an earlier process is not resumed:
// recovery closed it when the session was claimed, and only an undelivered inbox
// record starts a new one. The records stay in temp memory until the caller resets it.
@(require_results)
serve_step :: proc(app: ^App) -> (step: Serve_Step, ok: bool) {
	chat := &app.setup.session
	records, read_error := journal.read_inbox(chat.store, chat.session, chat.delivered, context.temp_allocator)
	if read_error != nil {
		fmt.eprintln("nabla: cannot read the session:", journal.error_text(read_error, context.temp_allocator))
		return .None, false
	}
	if chat.state == .Idle && len(records) > 0 { return .Turn, true }
	if len(records) > 0 || chat.state != .Idle || agent.chat_session_workers_outstanding(chat) || app_compaction_pending(app) {
		return .Wait, true
	}
	return .None, true
}

// serve_run_turn delivers the pending inbox and runs one turn. The text is empty
// because each record is already committed: delivering it does not record it again.
// False means the session can no longer be stored and the reason was printed.
@(require_results)
serve_run_turn :: proc(app: ^App) -> bool {
	chat := &app.setup.session
	if warning := app_tools_refresh(app); warning != "" {
		agent.chat_runtime_message(chat, .Warning, warning)
	}
	chat.catalog = app_catalog_ref(app)
	// The origin is unused: an empty text adds no node of its own, and each
	// staged record keeps the origin it was committed with.
	switch agent.chat_session_accept_message(chat, "", .Agent, {}) {
	case .Accepted:
	case .Storage_Failed:
		// A busy store leaves the lines pending and the session usable. Only a
		// latched storage failure ends the process.
		if !chat.storage_failed { return true }
		serve_storage_exit(chat)
		return false
	case .Busy:
		return true
	}
	_ = agent.chat_run_turn_steered(chat, app.run.connection, agent.chat_retry_policy_default(), {}, nil)
	if chat.storage_failed {
		serve_storage_exit(chat)
		return false
	}
	return true
}

serve_storage_exit :: proc(chat: ^agent.Chat_Session) -> int {
	text := agent.chat_session_last_error(chat)
	if text == "" { text = "the session could not be stored" }
	fmt.eprintln("nabla:", text)
	return 1
}
