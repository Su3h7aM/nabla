package main

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

import "nabla:agent"
import "nabla:agent/session"

chat_cli_options :: struct {
	config_path: string,
	provider_id: string,
	model_id:    string,
	// resume opens an existing session instead of starting one, and resume_id
	// names which. An empty resume_id means the newest session for the directory.
	resume:      bool,
	resume_id:   string,
	// prompt runs one turn without a terminal: the answer goes to stdout and the
	// process exits with the turn's outcome. An empty prompt means the interactive
	// harness is what the launch asked for.
	prompt:      string,
	help:        bool,
	list:        bool,
}

chat_cli_parse :: proc(args: []string) -> (chat_cli_options, bool) {
	result: chat_cli_options
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--help" || arg == "-h" { result.help = true; continue }
		if arg == "--list" { result.list = true; continue }
		if arg == "--resume" {
			result.resume = true
			// A following argument that is not another flag names the session.
			// Without one, the newest session for this directory is resumed.
			if i + 1 < len(args) && !strings.has_prefix(args[i + 1], "-") {
				i += 1
				result.resume_id = args[i]
			}
			continue
		}
		if strings.has_prefix(arg, "--resume=") {
			result.resume = true
			result.resume_id = arg[len("--resume="):]
			continue
		}
		if arg == "--prompt" {
			// A prompt is the whole instruction, so an empty one is a launch
			// mistake rather than a request for the interactive harness.
			if i + 1 >= len(args) || args[i + 1] == "" { return result, false }
			i += 1
			result.prompt = args[i]
			continue
		}
		if strings.has_prefix(arg, "--prompt=") {
			result.prompt = arg[len("--prompt="):]
			if result.prompt == "" { return result, false }
			continue
		}
		if strings.has_prefix(arg, "--config=") { result.config_path = arg[len("--config="):]; continue }
		if strings.has_prefix(arg, "--provider=") { result.provider_id = arg[len("--provider="):]; continue }
		if strings.has_prefix(arg, "--model=") { result.model_id = arg[len("--model="):]; continue }
		if arg == "--config" || arg == "--provider" || arg == "--model" {
			if i + 1 >= len(args) { return result, false }
			i += 1
			if arg == "--config" { result.config_path = args[i] }
			if arg == "--provider" { result.provider_id = args[i] }
			if arg == "--model" { result.model_id = args[i] }
			continue
		}
		return result, false
	}
	return result, true
}

chat_cli_usage :: proc() {
	fmt.println("nabla [--config PATH] [--resume [SESSION]] [--provider ID --model ID] [--prompt TEXT]")
	fmt.println("nabla diagnostics <session-id>    print what one session left in the diagnostic logs")
	fmt.println("default config: $XDG_CONFIG_HOME/nabla/config.lua (~/.config/nabla/config.lua)")
	fmt.println("without --resume, a new session starts in the current directory")
	fmt.println("--resume opens the newest session for the current directory; --resume SESSION opens that one")
	fmt.println("without provider/model, the last selection is restored, or the model menu opens")
	fmt.println("--prompt runs one turn without a terminal, prints the answer to stdout, and exits")
	fmt.println("--list prints the resolved catalog")
}

// --- headless ---------------------------------------------------------------

// Headless_Output is the headless front-end's only state: where the answer goes,
// and whether the turn has produced any of it, so a turn that produced none does
// not print a blank line.
Headless_Output :: struct {
	answer:   io.Writer,
	answered: bool,
}

headless_observer :: proc(out: ^Headless_Output) -> agent.Chat_Observer {
	return {
		user_data = out,
		assistant_begin = headless_assistant_begin,
		assistant_text = headless_assistant_text,
		assistant_end = headless_assistant_end,
		tool_result = headless_tool_result,
		message = headless_message,
	}
}

// The answer goes to stdout as it arrives, and everything else goes to stderr, so
// a caller can capture the answer alone.
headless_assistant_begin :: proc(user_data: rawptr) {
	out := cast(^Headless_Output)user_data
	out.answered = false
}

headless_assistant_text :: proc(user_data: rawptr, text: string) {
	out := cast(^Headless_Output)user_data
	out.answered = true
	_, _ = io.write_string(out.answer, text)
}

headless_assistant_end :: proc(user_data: rawptr) {
	out := cast(^Headless_Output)user_data
	if out.answered { _, _ = io.write_string(out.answer, "\n") }
}

headless_tool_result :: proc(user_data: rawptr, name: string, result: ^agent.Tool_Result) {
	fmt.eprintf("nabla: tool %s: %s\n", name, tool_display_summary(result))
}

headless_message :: proc(user_data: rawptr, kind: agent.Chat_Message_Kind, text: string) {
	switch kind {
	case .Notice:
		fmt.eprintln("nabla:", text)
	case .Warning:
		fmt.eprintln("nabla: warning:", text)
	case .Error:
		fmt.eprintln("nabla: error:", text)
	}
}

// run_prompt_turn accepts one prompt on an opened session and runs it to
// completion, reporting through out. False means the turn did not complete; the
// observer has already said why, so the caller only needs the exit code.
//
// This is the whole of what a headless run does with a prompt, which is what
// makes it testable without a terminal: the launch around it is shared with the
// interactive harness.
run_prompt_turn :: proc(app: ^App, prompt: string, out: ^Headless_Output) -> bool {
	// Tools are refreshed between turns, while the session is idle, so the registry a
	// turn dispatches against is the one it was advertised with.
	if warning := app_tools_refresh(app); warning != "" { fmt.eprintln("nabla:", warning) }
	switch agent.chat_session_accept_user(&app.setup.session, prompt, session.now_ms()) {
	case .Accepted:
	case .Storage_Failed:
		fmt.eprintln("nabla:", agent.chat_session_last_error(&app.setup.session))
		return false
	case .Busy:
		fmt.eprintln("nabla: the session is already running")
		return false
	}
	return agent.chat_run_turn_steered(&app.setup.session, app.run.connection, agent.chat_retry_policy_default(), headless_observer(out), nil)
}

// run_prompt executes one prompt without a terminal and returns the process exit
// code. It shares the launch path with the interactive harness: the same
// configuration, the same catalog, the same session. Only the front-end differs,
// so a headless run is the same conversation rather than a second implementation
// of one.
run_prompt :: proc(
	sources: []agent.Catalog_Provider_Source,
	mcp_servers: []agent.MCP_Server_Config,
	harness_options: agent.Harness_Options,
	options: chat_cli_options,
	answer: io.Writer,
) -> int {
	app := new(App)
	defer free(app)
	app.run.alloc = context.allocator

	start := Session_Start {
		kind = .New,
	}
	if options.resume {
		start.kind = .Resume_Id if options.resume_id != "" else .Resume_Latest
		start.id = options.resume_id
	}
	app.setup.harness_options = harness_options
	// The writer is opened and the logger installed in the scope that owns the run,
	// so the headless path records the same launch the interactive one does.
	app.setup.alloc = context.allocator
	context.logger = run_log_open(&app.setup)
	run_log_header(&app.setup)
	if !run_catalog(sources, mcp_servers, &app.setup, start) { return 1 }
	// The model this run picks belongs to the job, not to the user: a headless run
	// must not change what the interactive harness starts with.
	app.setup.owns_selection = false
	defer {
		snapshot_destroy(app)
		run_setup_destroy(&app.setup)
	}

	if !apply_startup_selection(app, options.provider_id, options.model_id) {
		fmt.eprintln("nabla:", app.run.snap.setup_error)
		return 1
	}
	if app.setup.model_id == "" {
		fmt.eprintln("nabla: no model is selected; give --provider and --model, or run the interactive harness once")
		return 1
	}

	out := Headless_Output {
		answer = answer,
	}
	return run_prompt_turn(app, options.prompt, &out) ? 0 : 1
}

// --- entry point ------------------------------------------------------------

// chat_main runs one invocation and returns its exit code, so main has a single
// exit and the deferred cleanup still runs.
chat_main :: proc() -> int {
	args := os.args[1:]
	// A subcommand is recognized before the launch options, because its argument is
	// a session id rather than a flag.
	if len(args) > 0 && args[0] == "diagnostics" { return diagnostics_main(args[1:]) }

	options, parsed := chat_cli_parse(args)
	if !parsed {
		chat_cli_usage()
		return 2
	}
	if options.help {
		chat_cli_usage()
		return 0
	}
	if options.config_path == "" {
		directory, directory_err := agent.xdg_directory(.Config, context.temp_allocator)
		if directory_err != .None {
			fmt.eprintln("nabla: cannot resolve the configuration directory")
			return 1
		}
		options.config_path = strings.concatenate([]string{directory, "/config.lua"}, allocator = context.temp_allocator)
	}
	// A missing config file is a valid setup, not an error: the run proceeds
	// with no providers and default options. Only a config that exists but
	// cannot be used stops the launch.
	sources, harness_options, mcp_servers, config_err := agent.load_lua_config_full(options.config_path)
	if config_err != .None && config_err != .Missing {
		fmt.eprintln("nabla:", agent.config_error_text(config_err))
		return 1
	}
	defer agent.catalog_sources_destroy(&sources)
	defer agent.mcp_servers_destroy(&mcp_servers)

	if options.list {
		catalog, configured, catalog_ok := resolve_run_catalog(sources[:], context.allocator)
		defer {
			for id in configured { delete(id, context.allocator) }
			delete(configured)
			agent.catalog_destroy(&catalog)
		}
		if !catalog_ok { return 1 }
		for model in catalog.models {
			fmt.println(model.provider_id, "/", model.id)
		}
		return 0
	}
	if (options.provider_id == "") != (options.model_id == "") {
		fmt.eprintln("nabla: --provider and --model must be given together")
		return 2
	}
	if options.prompt != "" { return run_prompt(sources[:], mcp_servers[:], harness_options, options, stdout_writer()) }

	start := Session_Start {
		kind = .New,
	}
	if options.resume {
		start.kind = .Resume_Id if options.resume_id != "" else .Resume_Latest
		start.id = options.resume_id
	}
	return tui_run(sources[:], mcp_servers[:], harness_options, options.provider_id, options.model_id, start) ? 0 : 1
}

main :: proc() {
	os.exit(chat_main())
}

// stdout_writer is where a real headless run's answer goes.
stdout_writer :: proc() -> io.Writer {
	return io.to_writer(os.to_stream(os.stdout))
}
