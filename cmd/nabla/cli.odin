package main

import "core:fmt"
import "core:os"
import "core:strings"

import "nabla:agent"
import "nabla:ai"

// The interim interactive front-end: resolve one model from the loaded
// configuration, open the connection, and pump the turn loop until the user
// quits.
//
// This is the only layer that knows about an output stream, a terminal, or the
// steering reader thread. The agent knows about none of them: it reports what
// happened through a Chat_Observer and this decides how to show it.
cli_run :: proc(sources: []agent.Catalog_Provider_Source, provider_id, model_id: string) {
	source: ^agent.Catalog_Provider_Source
	for &candidate in sources { if candidate.id == provider_id { source = &candidate; break } }
	if source == nil { display_error(fmt.tprintf("provider not found: %s", provider_id)); return }

	model_tools := false
	model_found := false
	model_max_output := 0
	model_context_window := 0
	effort_levels: [dynamic]string
	defer delete(effort_levels)
	for &candidate in source.models {
		if candidate.id == model_id && !(candidate.disabled_present && candidate.disabled) {
			model_found = true
			model_tools = candidate.tools_present && candidate.tools
			if candidate.max_output_tokens_present && candidate.max_output_tokens > 0 { model_max_output = candidate.max_output_tokens }
			if candidate.context_window_present && candidate.context_window > 0 { model_context_window = candidate.context_window }
			if candidate.thinking.levels_present {
				for level in candidate.thinking.levels { append(&effort_levels, level) }
			}
			break
		}
	}
	if !model_found { display_error(fmt.tprintf("model not found for provider: %s %s", provider_id, model_id)); return }
	if !source.base_url_present || source.base_url == "" { display_error("selected provider requires explicit base_url endpoint"); return }
	if !source.api_present || source.api == "" { display_error("selected provider requires explicit api"); return }
	api, api_ok := agent.chat_api_kind(source.api)
	if !api_ok { display_error(fmt.tprintf("unsupported api: %s", source.api)); return }

	if !source.api_key_present {
		display_error("selected provider requires api_key")
		return
	}
	credential, credential_ok := agent.config_resolve_credential(source.api_key, context.allocator)
	if !credential_ok {
		display_error("selected provider requires api_key, or names an unset environment variable as ${NAME}")
		return
	}
	defer delete(credential, context.allocator)

	allocator := context.allocator
	session := agent.chat_session_init(allocator)
	defer agent.chat_session_destroy(&session)
	if session.workspace == "" { display_error("cannot determine working directory"); return }
	session.tools_enabled = model_tools && agent.chat_supports_tools(api)
	session.max_output_tokens = model_max_output
	session.context_window = model_context_window
	for level in effort_levels { append(&session.effort_levels, strings.clone(level, allocator)) }

	sink := Display_Sink {
		output = os.to_writer(os.stdout),
	}
	observer := display_observer(&sink)

	connection := ai.Provider_Connection {
		API        = api,
		Endpoint   = source.base_url,
		Credential = credential,
	}
	display_warning("shell execution is local and unsandboxed: valid model tool calls run directly")
	display_notice(
		fmt.tprintf("chat %s / %s (type /quit to exit, Ctrl-C cancels a request; input during a turn is queued, /compact summarizes)", provider_id, model_id),
	)

	queue := agent.steer_queue_init(allocator)
	defer agent.steer_queue_destroy(&queue)
	signals: agent.Chat_Interactive_Signals
	agent.chat_interactive_arm(&signals)
	defer agent.chat_interactive_disarm(&signals)
	reader := agent.Steer_Reader {
		queue    = &queue,
		observer = observer,
	}
	if !agent.steer_reader_start(&reader) { display_error("cannot start input reader"); return }

	quit := false
	steer_ctx := agent.Steer_Context {
		queue       = &queue,
		quit        = &quit,
		provider_id = provider_id,
		model_id    = model_id,
		connection  = connection,
		model       = model_id,
	}
	for !quit {
		if !agent.steer_available(&queue) {
			switch agent.steer_idle_wait(&queue) {
			case .Input:
			case .Closed, .Cancelled:
				quit = true
				continue
			}
		}
		line, ok := agent.steer_pop(&queue)
		if !ok { continue }
		if line == "/compact" {
			agent.chat_command_compact(&session, observer, connection, model_id, nil)
			agent.steer_line_free(&queue, line)
			continue
		}
		if agent.chat_handle_command(&session, observer, &queue, line, provider_id, model_id, &quit) {
			agent.steer_line_free(&queue, line)
			continue
		}
		if !agent.chat_session_accept_user(&session, line) {
			display_warning("chat is busy; input dropped")
			agent.steer_line_free(&queue, line)
			continue
		}
		display_user(line)
		agent.steer_line_free(&queue, line)
		// Failure is finalized; the next input remains usable.
		agent.chat_run_turn_steered(&session, connection, model_id, observer, &steer_ctx)
	}
	agent.steer_reader_stop(&reader)
}
