package main

import "core:fmt"
import "core:os"
import "core:strings"

import "nabla:agent"

chat_cli_options :: struct {
	config_path: string,
	provider_id: string,
	model_id:    string,
	// resume opens an existing session instead of starting one, and resume_id
	// names which. An empty resume_id means the newest session for the directory.
	resume:      bool,
	resume_id:   string,
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

main :: proc() {
	options, ok := chat_cli_parse(os.args[1:])
	if !ok { fmt.println("usage: nabla [--config PATH] [--resume [SESSION]] [--provider ID --model ID]"); return }
	if options.help {
		fmt.println("nabla [--config PATH] [--resume [SESSION]] [--provider ID --model ID]")
		fmt.println("default config: $XDG_CONFIG_HOME/nabla/config.lua (~/.config/nabla/config.lua)")
		fmt.println("without --resume, a new session starts in the current directory")
		fmt.println("--resume opens the newest session for the current directory; --resume SESSION opens that one")
		fmt.println("without provider/model, the last selection is restored, or the model menu opens")
		fmt.println("--list prints the resolved catalog")
		return
	}
	if options.config_path == "" {
		directory, directory_err := agent.xdg_directory(.Config, context.temp_allocator)
		if directory_err != .None { fmt.eprintln("cannot resolve the configuration directory"); return }
		options.config_path = strings.concatenate([]string{directory, "/config.lua"}, allocator = context.temp_allocator)
	}
	sources, err := agent.load_lua_config(
		options.config_path,
	); if err != .None { fmt.println(agent.config_error_text(err)); return }; defer agent.catalog_sources_destroy(&sources)
	if options.list {
		catalog, configured, catalog_ok := resolve_run_catalog(sources[:], context.allocator)
		defer {
			for id in configured { delete(id, context.allocator) }
			delete(configured)
			agent.catalog_destroy(&catalog)
		}
		if !catalog_ok { return }
		for model in catalog.models {
			fmt.println(model.provider_id, "/", model.id)
		}
		return
	}
	if (options.provider_id == "") != (options.model_id == "") {
		fmt.eprintln("nabla: --provider and --model must be given together")
		return
	}
	start := Session_Start {
		kind = .New,
	}
	if options.resume {
		start.kind = .Resume_Id if options.resume_id != "" else .Resume_Latest
		start.id = options.resume_id
	}
	tui_run(sources[:], options.provider_id, options.model_id, start)
}
