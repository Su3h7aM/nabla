package main

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

import "nabla:agent"
import "nabla:agent/journal"

CLI_Parse_Error :: enum {
	None,
	Unknown_Option,
	Missing_Value,
	Empty_Prompt,
}

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

@(require_results)
chat_cli_parse :: proc(args: []string) -> (chat_cli_options, CLI_Parse_Error) {
	result: chat_cli_options
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--help" || arg == "-h" {
			result.help = true
			continue
		}
		if arg == "--list" {
			result.list = true
			continue
		}
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
			if i + 1 >= len(args) { return result, .Missing_Value }
			if args[i + 1] == "" { return result, .Empty_Prompt }
			i += 1
			result.prompt = args[i]
			continue
		}
		if strings.has_prefix(arg, "--prompt=") {
			result.prompt = arg[len("--prompt="):]
			if result.prompt == "" { return result, .Empty_Prompt }
			continue
		}
		if strings.has_prefix(arg, "--config=") {
			result.config_path = arg[len("--config="):]
			continue
		}
		if strings.has_prefix(arg, "--provider=") {
			result.provider_id = arg[len("--provider="):]
			continue
		}
		if strings.has_prefix(arg, "--model=") {
			result.model_id = arg[len("--model="):]
			continue
		}
		if arg == "--config" || arg == "--provider" || arg == "--model" {
			if i + 1 >= len(args) { return result, .Missing_Value }
			i += 1
			if arg == "--config" { result.config_path = args[i] }
			if arg == "--provider" { result.provider_id = args[i] }
			if arg == "--model" { result.model_id = args[i] }
			continue
		}
		return result, .Unknown_Option
	}
	return result, .None
}

chat_cli_usage :: proc() {
	fmt.println("nabla [--config PATH] [--resume [SESSION]] [--provider ID --model ID] [--prompt TEXT]")
	fmt.println("nabla acp                         run an Agent Client Protocol agent on stdin and stdout")
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
	answer:       io.Writer,
	answered:     bool,
	write_failed: bool,
	// follow is set while the run follows a session another process runs. Only the
	// assistant messages of the turn it waits for are the answer; the zero value treats
	// every message as one.
	follow:       ^agent.Follow,
	// aside says the assistant message being shown is not the answer and goes to stderr.
	aside:        bool,
}

headless_observer :: proc(out: ^Headless_Output) -> agent.Chat_Observer {
	return {
		user_data = out,
		assistant_begin = headless_assistant_begin,
		assistant_text = headless_assistant_text,
		assistant_end = headless_assistant_end,
		tool_result = headless_tool_result,
		message = headless_message,
		retry_scheduled = headless_retry_scheduled,
	}
}

// headless_retry_scheduled prints one line per scheduled retry, to stderr like the rest of
// the harness's own reporting: a caller watching a headless run learns that an attempt
// failed while it is still waiting, rather than only when the turn ends.
headless_retry_scheduled :: proc(user_data: rawptr, event: agent.Chat_Retry_Event) {
	fmt.eprintln("nabla:", retry_display_text(event))
}

// The answer goes to stdout as it arrives, and everything else goes to stderr, so
// a caller can capture the answer alone.
headless_assistant_begin :: proc(user_data: rawptr) {
	out := cast(^Headless_Output)user_data
	out.answered = false
	out.aside = out.follow != nil && (out.follow.turn == 0 || out.follow.ended)
}

// headless_answer_write writes text where the message being shown belongs: stdout for the
// answer, stderr for a message of a turn this run does not wait for.
headless_answer_write :: proc(out: ^Headless_Output, text: string) {
	if out.aside {
		fmt.eprint(text)
		return
	}
	written, write_err := io.write_string(out.answer, text)
	if write_err != nil || written != len(text) { out.write_failed = true }
}

headless_assistant_text :: proc(user_data: rawptr, text: string) {
	out := cast(^Headless_Output)user_data
	out.answered = true
	headless_answer_write(out, text)
}

headless_assistant_end :: proc(user_data: rawptr) {
	out := cast(^Headless_Output)user_data
	if out.answered { headless_answer_write(out, "\n") }
}

headless_tool_result :: proc(user_data: rawptr, call, parent_call: journal.Call_Id, name, arguments: string, result: ^agent.Tool_Result) {
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

// run_prompt_turn accepts one prompt on an opened session and runs it to completion,
// reporting through out. False means the turn did not complete, and the observer has
// already said why, so the caller only needs the exit code. It is the whole of what a
// headless run does with a prompt, and the launch around it is shared.
@(require_results)
run_prompt_turn :: proc(app: ^App, prompt: string, out: ^Headless_Output) -> bool {
	// Tools are refreshed between turns, while the session is idle, so the registry a
	// turn dispatches against is the one it was advertised with.
	if warning := app_tools_refresh(app); warning != "" { fmt.eprintln("nabla:", warning) }
	observer := headless_observer(out)
	switch agent.chat_session_accept_user(&app.setup.session, prompt, observer) {
	case .Accepted:
	case .Storage_Failed:
		fmt.eprintln("nabla:", agent.chat_session_last_error(&app.setup.session))
		return false
	case .Busy:
		fmt.eprintln("nabla: the session is already running")
		return false
	}
	chat := &app.setup.session
	chat.catalog = app_catalog_ref(app)
	completed := agent.chat_run_turn_steered(chat, app.run.connection, agent.chat_retry_policy_default(), observer, nil)
	// A headless run ends when its work does, so it waits for the subagents it started in the
	// background and answers each report with a turn of its own.
	for completed && agent.chat_agents_wait(chat, nil) {
		accepted, had_message := agent.chat_session_accept_agent_message(chat, observer)
		if !had_message {
			// The report the wait promised was taken elsewhere; there is nothing
			// left to run a turn for.
			break
		}
		if accepted != .Accepted {
			fmt.eprintln("nabla:", agent.chat_session_last_error(chat))
			return false
		}
		completed = agent.chat_run_turn_steered(chat, app.run.connection, agent.chat_retry_policy_default(), observer, nil)
	}
	if out.write_failed {
		fmt.eprintln("nabla: the answer could not be written")
		return false
	}
	return completed
}

// run_prompt_follow sends prompt to the process that runs the session app follows and
// waits for the turn that answers it, reporting through out like run_prompt_turn. The
// line is committed as a `user.input` record, and the turn is the one whose User node
// delivers that record. Its assistant messages are the answer; everything else the runner
// commits meanwhile goes to stderr. It runs no turn and never claims the session, so a
// runner whose claim drops leaves it waiting for the next one. Only an interrupt ends the
// wait early, and no timeout does. False means the line was not sent, the session could
// not be read, the run was interrupted, or the turn did not complete; the observer has
// said why for a turn that failed.
@(require_results)
run_prompt_follow :: proc(app: ^App, prompt: string, out: ^Headless_Output) -> bool {
	setup := &app.setup
	store := setup.store
	error := journal.append_input(store, prompt, .Prompt)
	// The line is the last record of its commit, so the seq the commit reached is its own.
	seq := store.last_seq
	if error != nil && journal.error_is_busy(error) { seq, error = journal.commit(store) }
	if error != nil {
		fmt.eprintf("nabla: the line was not sent: %s\n", journal.error_text(error, context.temp_allocator))
		return false
	}

	setup.follow.input = seq
	out.follow = &setup.follow
	observer := headless_observer(out)
	// The handler is armed for the whole wait, as it is for a turn, so Ctrl-C wakes the
	// owner wake instead of ending the process with a line still unanswered.
	previous: agent.Signal_Action
	agent.chat_signal_arm(&previous)
	defer agent.chat_signal_disarm(&previous)
	for {
		// The wake is read before the poll, so a commit that lands after the poll ends the wait.
		seen := agent.owner_wake_seen()
		if poll_error := agent.follow_poll(store, setup.session.session, &setup.follow, observer); poll_error != nil {
			fmt.eprintf("nabla: cannot read the session: %s\n", journal.error_text(poll_error, context.temp_allocator))
			return false
		}
		if setup.follow.ended { break }
		if agent.process_interrupted() {
			fmt.eprintln("nabla: interrupted while waiting for the session's turn")
			return false
		}
		agent.owner_wake_wait(seen, nil)
	}
	if out.write_failed {
		fmt.eprintln("nabla: the answer could not be written")
		return false
	}
	return setup.follow.outcome == .Completed
}

// run_prompt executes one prompt without a terminal and returns the process exit code. It
// shares the launch path with the interactive harness, so only the front-end differs and a
// headless run is the same conversation rather than a second implementation of one.
session_start_from_options :: proc(resume: bool, resume_id: string) -> Session_Start {
	if !resume { return Start_Fresh{} }
	if resume_id != "" { return Start_Resume_Id(resume_id) }
	return Start_Resume_Latest{}
}

run_prompt :: proc(
	sources: []agent.Catalog_Provider_Source,
	mcp_servers: []agent.MCP_Server_Config,
	harness_options: agent.Harness_Options,
	options: chat_cli_options,
	answer: io.Writer,
) -> int {
	app, app_error := new(App)
	if app_error != nil { return 1 }
	defer free(app)
	app.run.alloc = context.allocator
	// The headless run shows nothing, but a refusal or a selection notice still
	// reaches the transcript, so it owns its allocator here too.
	snapshot_transcript_own(app)

	start := session_start_from_options(options.resume, options.resume_id)
	// A resumed session another process runs is followed rather than refused.
	app.setup.shared_sessions = options.resume
	app.setup.harness_options = harness_options
	app.setup.alloc = context.allocator
	if !run_catalog(sources, mcp_servers, &app.setup, start) { return 1 }
	// The model this run picks belongs to the job, not to the user: a headless run
	// must not change what the interactive harness starts with.
	app.setup.owns_selection = false
	defer {
		snapshot_destroy(app)
		// A tool worker that ignored its stop may still use the tool backends, so the
		// process exits with them rather than freeing them under it.
		if !agent.chat_session_workers_outstanding(&app.setup.session) {
			run_setup_destroy(&app.setup)
		}
	}

	out := Headless_Output {
		answer = answer,
	}
	// A follower runs no turn, so it needs no model and records no selection.
	if app_following(app) { return run_prompt_follow(app, options.prompt, &out) ? 0 : 1 }
	if !apply_startup_selection(app, options.provider_id, options.model_id) {
		fmt.eprintln("nabla:", setup_error_text(app))
		return 1
	}
	if app.setup.model_id == "" {
		fmt.eprintln("nabla: no model is selected; give --provider and --model, or run the interactive harness once")
		return 1
	}

	return run_prompt_turn(app, options.prompt, &out) ? 0 : 1
}

// --- entry point ------------------------------------------------------------

config_error_display_text :: proc(path: string, err: agent.Config_Error, detail: string, allocator := context.temp_allocator) -> string {
	if detail != "" {
		return fmt.aprintf("nabla: %s: %s: %s", path, agent.config_error_text(err), detail, allocator = allocator)
	}
	return fmt.aprintf("nabla: %s: %s", path, agent.config_error_text(err), allocator = allocator)
}

// chat_main runs one invocation and returns its exit code, so main has a single
// exit and the deferred cleanup still runs.
chat_main :: proc() -> int {
	args := os.args[1:]
	// The ACP agent is a front-end of its own: it takes over the process's standard
	// streams, so it is a subcommand rather than a launch option.
	if len(args) > 0 && args[0] == "acp" { return acp_main(args[1:]) }

	options, parse_error := chat_cli_parse(args)
	if parse_error != .None {
		switch parse_error {
		case .Unknown_Option:
			fmt.eprintln("nabla: unknown option")
		case .Missing_Value:
			fmt.eprintln("nabla: option is missing its value")
		case .Empty_Prompt:
			fmt.eprintln("nabla: --prompt cannot be empty")
		case .None:
		}
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
		config_path, path_error := strings.concatenate([]string{directory, "/config.lua"}, allocator = context.temp_allocator)
		if path_error != nil {
			fmt.eprintln("nabla: the configuration path could not be allocated")
			return 1
		}
		options.config_path = config_path
	}
	// A missing config file is a valid setup, not an error: the run proceeds
	// with no providers and default options. Only a config that exists but
	// cannot be used stops the launch.
	sources, harness_options, mcp_servers, config_err, config_detail := agent.load_lua_config(options.config_path)
	defer if config_detail != "" { delete(config_detail) }
	if config_err != .None && config_err != .Missing {
		fmt.eprintln(config_error_display_text(options.config_path, config_err, config_detail))
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

	start := session_start_from_options(options.resume, options.resume_id)
	return tui_run(sources[:], mcp_servers[:], harness_options, options.provider_id, options.model_id, start) ? 0 : 1
}

main :: proc() {
	os.exit(chat_main())
}

stdout_writer :: proc() -> io.Writer {
	return io.to_writer(os.to_stream(os.stdout))
}

// stderr_writer is where a real run's human-facing notices go.
stderr_writer :: proc() -> io.Writer {
	return io.to_writer(os.to_stream(os.stderr))
}
