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
	// serve is the internal entry a prompt client passes when it starts the session
	// server. It is not a user command.
	serve:       bool,
}

@(require_results)
chat_cli_parse :: proc(args: []string) -> (chat_cli_options, CLI_Parse_Error) {
	result: chat_cli_options
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if result.serve || arg == "--serve" {
			result.serve = true
			continue
		}
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

session_start_from_options :: proc(resume: bool, resume_id: string) -> Session_Start {
	if !resume { return Start_Fresh{} }
	if resume_id != "" { return Start_Resume_Id(resume_id) }
	return Start_Resume_Latest{}
}

// --- entry point ------------------------------------------------------------

config_error_display_text :: proc(path: string, err: agent.Config_Error, detail: string, allocator := context.temp_allocator) -> string {
	parts := [?]string{"nabla: ", path, ": ", agent.config_error_text(err), ": ", detail}
	text, text_error := strings.concatenate(parts[:] if detail != "" else parts[:4], allocator)
	if text_error != nil { return "nabla: the configuration error message could not be built: out of memory" }
	return text
}

// subagent_launch_options fills the paths inherited by native ACP children.
// config is only the explicitly supplied path. The caller frees both results with context.allocator.
subagent_launch_options :: proc(options: ^agent.Harness_Options, config: string) -> bool {
	executable, executable_error := os.get_executable_path(context.allocator)
	if executable_error != nil {
		fmt.eprintf("nabla: cannot locate the executable: %v\n", executable_error)
		return false
	}
	options.nabla_executable = executable
	complete := false
	defer if !complete {
		delete(options.nabla_executable)
		options.nabla_executable = ""
	}
	if config != "" {
		absolute, path_error := os.get_absolute_path(config, context.allocator)
		if path_error != nil {
			fmt.eprintf("nabla: cannot resolve the explicit configuration path: %v\n", path_error)
			return false
		}
		options.nabla_config = absolute
	}
	complete = true
	return true
}

// chat_main returns the invocation exit code after deferred cleanup.
chat_main :: proc() -> int {
	args := os.args[1:]
	// The ACP agent is a front-end of its own: it takes over the process's standard
	// streams, so it is a subcommand rather than a launch option.
	// The subagent child is this same subcommand, so it is named for its role.
	if len(args) > 0 && args[0] == "acp" {
		process_name_set(PROCESS_NAME_ACP)
		return acp_main(args[1:])
	}

	options, parse_error := chat_cli_parse(args)
	// --serve is the internal entry a prompt client passes when it starts the session
	// server. serve_main names the process; this path does not.
	if options.serve {
		return serve_main(args)
	}
	process_name_set(PROCESS_NAME_MAIN)
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
	explicit_config := options.config_path
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
	if !subagent_launch_options(&harness_options, explicit_config) { return 1 }
	defer { delete(harness_options.nabla_executable); delete(harness_options.nabla_config) }
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
	if options.prompt != "" {
		return run_prompt(harness_options.nabla_executable, options, harness_options.nabla_config, stdout_writer())
	}

	start := session_start_from_options(options.resume, options.resume_id)
	process_name_set(PROCESS_NAME_TUI)
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
