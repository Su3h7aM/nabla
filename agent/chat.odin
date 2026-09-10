package agent

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "nabla:ai"

chat_api_kind :: proc(value: string) -> (ai.API_Kind, bool) {
	switch value {
	case "openai_chat_completions":
		return .OpenAI_Chat_Completions, true
	case "openai_responses":
		return .OpenAI_Responses, true
	case "anthropic_messages":
		return .Anthropic_Messages, true
	}
	return .Invalid, false
}

Chat_Request_Usage :: struct {
	operation: u64,
	usage:     ai.Provider_Usage_Event,
}

Chat_Runtime_Context :: struct {
	session:        ^Chat_Session,
	source:         Chat_Event_Source,
	observer:       Chat_Observer,
	usage_log:      ^[dynamic]Chat_Request_Usage,
	assistant_open: bool, // the assistant block is announced once per request,
}

chat_provider_event :: proc(user_data: rawptr, event: ai.Provider_Event) {
	runtime := cast(^Chat_Runtime_Context)user_data
	#partial switch value in event {
	case ai.Provider_Text_Event:
		effect := chat_session_feed_text(runtime.session, runtime.source, value.Text)
		if effect.kind == .Publish_Text {
			if !runtime.assistant_open {
				_observer_assistant_begin(runtime.observer)
				runtime.assistant_open = true
			}
			_observer_assistant_text(runtime.observer, value.Text)
		}
		chat_effect_destroy(&effect)
	case ai.Provider_Reasoning_Event:
		// Reasoning never displays; it is stored so the next request can
		// replay it. A rejected feed is a stale event, not a turn failure.
		chat_session_feed_reasoning(runtime.session, runtime.source, value.ID, value.Encrypted)
	case ai.Provider_Completed_Event:
		// One response feeds one path: tool handoff when the provider
		// assembled calls, plain completion on stop, failure otherwise.
		// A length limit or content filter is not a usable answer, so it
		// must not finalize as success. Partial argument fragments never
		// reach the executor; only this validated event carries
		// executable calls.
		if value.Reason == .Tool_Call && len(value.Tool_Calls) > 0 {
			if !chat_session_feed_tool_calls(runtime.session, runtime.source, value.Tool_Calls) {
				chat_session_feed_error(runtime.session, runtime.source, "tool response was rejected")
			}
		} else if value.Reason == .Stop {
			chat_session_feed_completion(runtime.session, runtime.source)
		} else {
			if value.Reason_Text != "" {
				chat_session_feed_error(runtime.session, runtime.source, fmt.tprintf("response incomplete: %s", value.Reason_Text))
			} else {
				chat_session_feed_error(runtime.session, runtime.source, "response incomplete")
			}
		}
	case ai.Provider_Error_Event:
		// A cancelled turn reports cancellation, not the transport error that
		// cancellation itself produced. Noting it here also stops every later event
		// from reaching a turn that is already stopping.
		if chat_session_cancelled(runtime.session) {
			chat_session_note_cancel(runtime.session)
		} else {
			chat_session_feed_error(runtime.session, runtime.source, value.Message)
		}
	case ai.Provider_Usage_Event:
		if value.Input_Tokens_Present {
			session := runtime.session
			session.last_input_measured = value.Input_Tokens
			session.last_input_measured_present = true
		}
		if runtime.usage_log != nil { append(runtime.usage_log, Chat_Request_Usage{operation = u64(runtime.session.requests_made), usage = value}) }
	}
}

// chat_build_from_active clones the committed history and builds the request
// from it. Post-compaction rebuilds must use this: the in-flight view
// predates the appended summary, so its indices no longer match the session
// and the summary is absent from it. The view must outlive the wire.
chat_build_from_active :: proc(
	session: ^Chat_Session,
	connection: ai.Provider_Connection,
	model: string,
) -> (
	Chat_Request_View,
	ai.Provider_Request,
	[dynamic]ai.Provider_Message,
	[dynamic]ai.Provider_Tool_Def,
	[dynamic][dynamic]ai.Provider_Tool_Call,
) {
	view := chat_request_view_clone(session.messages[:], 0, session.allocator)
	request, wire, tools_owned, call_lists := chat_build_request(session, view, connection, model)
	return view, request, wire, tools_owned, call_lists
}

chat_build_request :: proc(
	session: ^Chat_Session,
	view: Chat_Request_View,
	connection: ai.Provider_Connection,
	model: string,
	compact := false,
	// range_end bounds a compaction request to the span being summarized,
	// so the retained tail is not summarized and then kept verbatim.
	range_end := -1,
) -> (
	ai.Provider_Request,
	[dynamic]ai.Provider_Message,
	[dynamic]ai.Provider_Tool_Def,
	[dynamic][dynamic]ai.Provider_Tool_Call,
) {
	messages := make([dynamic]ai.Provider_Message, 0, len(view.messages) + 1, session.allocator)
	tools_owned := make([dynamic]ai.Provider_Tool_Def, 0, session.allocator)
	call_lists := make([dynamic][dynamic]ai.Provider_Tool_Call, 0, session.allocator)
	// A compaction request carries instructions instead of the agent prompt,
	// and no tools: the model must answer text, never call.
	if compact {
		append(&messages, ai.Provider_Message{Role = .System, Content = CHAT_COMPACT_INSTRUCTIONS})
	} else if session.tools_enabled {
		append(&messages, ai.Provider_Message{Role = .System, Content = AGENT_SYSTEM_PROMPT})
	}
	tool_group: [dynamic]ai.Provider_Tool_Call
	group_open := false
	flush_group :: proc(
		messages: ^[dynamic]ai.Provider_Message,
		call_lists: ^[dynamic][dynamic]ai.Provider_Tool_Call,
		group: ^[dynamic]ai.Provider_Tool_Call,
		open: ^bool,
	) {
		if !open^ { return }
		append(call_lists, group^)
		append(messages, ai.Provider_Message{Role = .Assistant, Tool_Calls = call_lists[len(call_lists) - 1][:]})
		group^ = {}
		open^ = false
	}
	defer if group_open { delete(tool_group) }
	start := min(session.active_start, len(view.messages))
	end := len(view.messages)
	if range_end >= 0 { end = min(range_end, len(view.messages)) }
	if end < start { end = start }
	for message in view.messages[start:end] {
		if message.is_system { continue }
		if message.is_reasoning {
			flush_group(&messages, &call_lists, &tool_group, &group_open)
			append(&messages, ai.Provider_Message{Role = .Reasoning, Reasoning_ID = message.reasoning_id, Reasoning_Encrypted = message.reasoning_encrypted})
			continue
		}
		if message.role == .Assistant && message.is_tool_call {
			append(
				&tool_group,
				ai.Provider_Tool_Call {
					ID = message.tool_call.id,
					Item_ID = message.tool_call.item_id,
					Name = message.tool_call.name,
					Arguments = message.tool_call.arguments,
				},
			)
			group_open = true
			continue
		}
		flush_group(&messages, &call_lists, &tool_group, &group_open)
		switch message.role {
		case .User:
			append(&messages, ai.Provider_Message{Role = .User, Content = message.text})
		case .Assistant:
			append(&messages, ai.Provider_Message{Role = .Assistant, Content = message.text})
		case .Tool:
			append(&messages, ai.Provider_Message{Role = .Tool, Content = message.text, Tool_Call_ID = message.tool_call_id})
		}
	}
	flush_group(&messages, &call_lists, &tool_group, &group_open)
	request := ai.Provider_Request {
		API              = connection.API,
		Model_Present    = true,
		Model            = model,
		Messages_Present = true,
		Messages         = messages[:],
	}
	if compact {
		request.Max_Output_Tokens_Present = true
		request.Max_Output_Tokens = CHAT_COMPACT_MAX_OUTPUT
	} else {
		if session.max_output_tokens > 0 {
			request.Max_Output_Tokens_Present = true
			request.Max_Output_Tokens = session.max_output_tokens
		}
		if session.effort != "" {
			request.Reasoning_Effort_Present = true
			request.Reasoning_Effort = session.effort
		}
		if session.tools_enabled {
			append(
				&tools_owned,
				ai.Provider_Tool_Def{Name = TOOL_SHELL_NAME, Description = TOOL_SHELL_DESCRIPTION, Parameters_JSON = TOOL_SHELL_PARAMETERS_JSON},
			)
			request.Tools = tools_owned[:]
		}
	}
	return request, messages, tools_owned, call_lists
}

// chat_execute_pending runs the committed calls in order. Once cancellation is
// requested the active call is terminated and the remaining committed calls get
// not-executed results, so the turn's history stays well formed.
chat_execute_pending :: proc(session: ^Chat_Session, observer: Chat_Observer) -> int {
	control := Tool_Control {
		interrupt = &chat_cancel,
		deadline  = session.turn_deadline,
	}
	count := 0
	for staged in session.pending_calls {
		result: Tool_Result
		args: Tool_Shell_Args
		args_valid := false
		if chat_session_cancelled(session) {
			result = tool_error_result(staged.id, .Not_Executed, "turn cancelled before this call ran", session.allocator)
		} else if staged.name != TOOL_SHELL_NAME {
			result = tool_error_result(staged.id, .Invalid_Arguments, "unknown tool", session.allocator)
		} else {
			args, args_valid = tool_shell_parse_args(staged.arguments, session.allocator)
			if !args_valid {
				result = tool_error_result(staged.id, .Invalid_Arguments, "invalid shell arguments", session.allocator)
			} else {
				result = tool_shell_execute(staged.id, args, session.workspace, control, session.allocator)
			}
		}
		text := tool_result_json(&result, session.allocator)
		_observer_tool_result(observer, staged.name, &result)
		tool_result_destroy(&result)
		if args_valid { tool_shell_args_destroy(&args, session.allocator) }
		append(&session.messages, Chat_Message{role = .Tool, text = text, tool_call_id = chat_clone_string(staged.id, session.allocator)})
		count += 1
	}
	return count
}

chat_report_usage :: proc(observer: Chat_Observer, entries: [dynamic]Chat_Request_Usage) {
	for entry in entries {
		_observer_usage(observer, entry.operation, entry.usage)
	}
}

// chat_settle_turn drives a terminal turn to its single Turn_Finished effect and
// reports it. It returns true only when the turn is over, so a turn that handed
// off to tools keeps running.
chat_settle_turn :: proc(session: ^Chat_Session, observer: Chat_Observer, usages: ^[dynamic]Chat_Request_Usage) -> bool {
	if session.state != .Finalizing && session.state != .Cancelling { return false }
	finish := chat_session_advance(session)
	if finish.kind != .Turn_Finished {
		chat_effect_destroy(&finish)
		return false
	}
	chat_report_terminal(observer, finish)
	chat_effect_destroy(&finish)
	chat_report_usage(observer, usages^)
	return true
}

// Admission is approximate and says so: character counts divided by four plus
// a per-message overhead cannot replace endpoint token counting, so the check
// keeps a safety margin and refuses over-budget requests instead of sending
// them. Measured usage from the endpoint is evidence, never the estimate.
CHAT_CHARS_PER_TOKEN :: 4
CHAT_MESSAGE_OVERHEAD_TOKENS :: 8
CHAT_ADMISSION_MARGIN_TOKENS :: 8192
CHAT_DEFAULT_OUTPUT_RESERVE_TOKENS :: 4096

chat_estimate_input_tokens :: proc(messages: []ai.Provider_Message, tools: []ai.Provider_Tool_Def) -> int {
	chars := 0
	for message in messages {
		chars += len(message.Content) + len(message.Tool_Call_ID) + len(message.Reasoning_ID) + len(message.Reasoning_Encrypted)
		for call in message.Tool_Calls {
			chars += len(call.ID) + len(call.Item_ID) + len(call.Name) + len(call.Arguments)
		}
	}
	for tool in tools {
		chars += len(tool.Name) + len(tool.Description) + len(tool.Parameters_JSON)
	}
	return chars / CHAT_CHARS_PER_TOKEN + len(messages) * CHAT_MESSAGE_OVERHEAD_TOKENS
}

// chat_admission_check enforces input estimate plus reserved generation plus
// margin against the configured window. The message is temp-allocated; the
// caller clones it when the turn must record the failure.
chat_admission_check :: proc(session: ^Chat_Session, estimate: int) -> (message: string, admitted: bool) {
	if session.context_window <= 0 {
		return "context admission needs context_window: add context_window to the model in config.lua", false
	}
	reserved := session.max_output_tokens
	if reserved <= 0 { reserved = CHAT_DEFAULT_OUTPUT_RESERVE_TOKENS }
	if estimate + reserved + CHAT_ADMISSION_MARGIN_TOKENS <= session.context_window {
		return "", true
	}
	return fmt.tprintf(
			"request estimated at ~%d input tokens exceeds the %d-token window (reserved %d output, %d margin): shorten the prompt, compact, or raise the limits",
			estimate,
			session.context_window,
			reserved,
			CHAT_ADMISSION_MARGIN_TOKENS,
		),
		false
}

// chat_perform_request runs one model request as an owned, interruptible
// operation. The operation is retired as soon as the call returns, which is the
// confirmation that it stopped; only then may the turn finalize. Request storage
// stays alive until the call returns because the provider borrows it.
chat_perform_request :: proc(
	session: ^Chat_Session,
	effect: ^Chat_Effect,
	connection: ai.Provider_Connection,
	model: string,
	observer: Chat_Observer,
	usages: ^[dynamic]Chat_Request_Usage,
) -> bool {
	request, wire, tools_owned, call_lists := chat_build_request(session, effect.request, connection, model)
	cleanup_wire :: proc(
		wire: ^[dynamic]ai.Provider_Message,
		tools_owned: ^[dynamic]ai.Provider_Tool_Def,
		call_lists: ^[dynamic][dynamic]ai.Provider_Tool_Call,
	) {
		for &slot in call_lists { delete(slot) }
		delete(call_lists^)
		delete(tools_owned^)
		delete(wire^)
	}

	// Admission runs on every request, including tool continuations. An
	// over-budget turn compacts once and recounts; a turn that still cannot
	// fit fails here, before any byte is sent. A fitting but hot window
	// compacts once so the next continuation starts small.
	estimate := chat_estimate_input_tokens(wire[:], tools_owned[:])
	message, admitted := chat_admission_check(session, estimate)
	hot := session.context_window > 0 && estimate * 5 >= session.context_window * 4
	fresh := Chat_Request_View{}
	has_fresh := false
	if !admitted || hot {
		if chat_maybe_auto_compact(session, observer, connection, model, usages) && !chat_session_cancelled(session) {
			cleanup_wire(&wire, &tools_owned, &call_lists)
			fresh, request, wire, tools_owned, call_lists = chat_build_from_active(session, connection, model)
			has_fresh = true
			estimate = chat_estimate_input_tokens(wire[:], tools_owned[:])
			message, admitted = chat_admission_check(session, estimate)
		}
		if !admitted {
			if chat_session_cancelled(session) {
				chat_session_note_cancel(session)
			} else {
				chat_session_fail_turn(session, message)
			}
			if has_fresh { chat_request_view_destroy(&fresh) }
			cleanup_wire(&wire, &tools_owned, &call_lists)
			return chat_settle_turn(session, observer, usages)
		}
	}
	if chat_session_cancelled(session) {
		chat_session_note_cancel(session)
		if has_fresh { chat_request_view_destroy(&fresh) }
		cleanup_wire(&wire, &tools_owned, &call_lists)
		return chat_settle_turn(session, observer, usages)
	}
	defer if has_fresh { chat_request_view_destroy(&fresh) }
	defer cleanup_wire(&wire, &tools_owned, &call_lists)

	chat_session_begin_operation(session)
	operation := chat_session_operation(session)
	runtime := Chat_Runtime_Context {
		session   = session,
		source    = chat_session_event_source(session),
		observer  = observer,
		usage_log = usages,
	}
	options := ai.Provider_Operation_Options {
		interrupt = &chat_cancel,
		deadline  = operation.deadline,
	}

	operation_error := ai.Provider_Request_Operation_Controlled(connection, request, &runtime, chat_provider_event, options, session.allocator)
	_observer_assistant_flush(observer)

	// Cancellation is the reason the turn ended, so it wins over any error the
	// transport also reported.
	if chat_session_cancelled(session) {
		chat_session_note_cancel(session)
	} else if operation_error.kind != .None && session.state != .Finalizing {
		chat_session_feed_error(session, runtime.source, operation_error.detail)
	}
	chat_session_retire_operation(session)
	return chat_settle_turn(session, observer, usages)
}

chat_run_turn :: proc(session: ^Chat_Session, connection: ai.Provider_Connection, model: string, observer: Chat_Observer) -> bool {
	return chat_run_turn_steered(session, connection, model, observer, nil)
}

// Steer_Context carries the steering queue into the turn loop. Nil means no
// steering: queued lines are drained before every model request, which is
// after tool calls settled and before the request view is frozen. Connection
// and model serve in-turn /compact; usages is the turn's log while a turn
// runs and nil at the prompt.
Steer_Context :: struct {
	queue:       ^Steer_Queue,
	quit:        ^bool,
	provider_id: string,
	model_id:    string,
	connection:  ai.Provider_Connection,
	model:       string,
	usages:      ^[dynamic]Chat_Request_Usage,
}

chat_run_turn_steered :: proc(
	session: ^Chat_Session,
	connection: ai.Provider_Connection,
	model: string,
	observer: Chat_Observer,
	steer: ^Steer_Context,
) -> bool {
	usages := make([dynamic]Chat_Request_Usage, 0, session.allocator)
	defer delete(usages)
	if steer != nil { steer.usages = &usages }
	defer if steer != nil { steer.usages = nil }
	previous: posix.sigaction_t
	chat_signal_arm(&previous)
	defer chat_signal_disarm(&previous)
	for {
		if steer != nil && session.state == .Preparing {
			chat_drain_steering(session, observer, steer)
		}
		effect := chat_session_advance(session)
		#partial switch effect.kind {
		case .Start_Request:
			finished := chat_perform_request(session, &effect, connection, model, observer, &usages)
			chat_effect_destroy(&effect)
			if finished { return session.terminal_status == .Completed }
		case .Run_Tools:
			chat_effect_destroy(&effect)
			count := chat_execute_pending(session, observer)
			chat_session_tools_done(session, session.active_turn_id, count)
			if chat_session_cancelled(session) { chat_session_note_cancel(session) }
		case .Turn_Finished:
			chat_report_terminal(observer, effect)
			status := effect.status
			chat_effect_destroy(&effect)
			chat_report_usage(observer, usages)
			return status == .Completed
		case:
			chat_effect_destroy(&effect)
			if chat_session_state(session) == .Finalizing || chat_session_state(session) == .Cancelling { continue }
			return false
		}
	}
}

chat_supports_tools :: proc(api: ai.API_Kind) -> bool {
	return api == .OpenAI_Chat_Completions || api == .OpenAI_Responses
}

chat_notice_effort :: proc(session: ^Chat_Session, observer: Chat_Observer, provider_id, model_id: string) {
	if session.effort != "" {
		_observer_message(observer, .Notice, fmt.tprintf("effort for %s / %s is %s", provider_id, model_id, session.effort))
	} else {
		_observer_message(observer, .Notice, fmt.tprintf("effort for %s / %s is provider default", provider_id, model_id))
	}
	if len(session.effort_levels) > 0 {
		levels, join_err := strings.join(session.effort_levels[:], " ", context.temp_allocator)
		if join_err == nil {
			_observer_message(observer, .Notice, fmt.tprintf("allowed: %s", levels))
		}
	} else {
		_observer_message(observer, .Notice, "no effort levels configured for this model")
	}
}

chat_notice_context :: proc(session: ^Chat_Session, observer: Chat_Observer) {
	if session.context_window > 0 {
		reserved := session.max_output_tokens
		if reserved <= 0 { reserved = CHAT_DEFAULT_OUTPUT_RESERVE_TOKENS }
		_observer_message(observer, .Notice, fmt.tprintf("context window: %d", session.context_window))
		_observer_message(observer, .Notice, fmt.tprintf("reserved output: %d", reserved))
		_observer_message(observer, .Notice, fmt.tprintf("safety margin: %d", CHAT_ADMISSION_MARGIN_TOKENS))
		_observer_message(observer, .Notice, fmt.tprintf("max estimated input: %d", session.context_window - reserved - CHAT_ADMISSION_MARGIN_TOKENS))
	} else {
		_observer_message(observer, .Notice, "no context_window configured for this model")
	}
	if session.last_input_measured_present {
		_observer_message(observer, .Notice, fmt.tprintf("last measured input tokens: %d", session.last_input_measured))
	} else {
		_observer_message(observer, .Notice, "no measured usage yet")
	}
}

// chat_handle_command runs one input line as a command. True means handled;
// the caller sends anything else as a turn or a steering line. /quit during
// a turn quits after it: no turn is running at shutdown, so the reader join
// cannot strand tool children.
chat_handle_command :: proc(session: ^Chat_Session, observer: Chat_Observer, queue: ^Steer_Queue, text, provider_id, model_id: string, quit: ^bool) -> bool {
	if text == "/quit" {
		if session.state != .Idle { _observer_message(observer, .Notice, "quitting after this turn finishes") }
		quit^ = true
		return true
	}
	if text == "/effort" { chat_notice_effort(session, observer, provider_id, model_id); return true }
	if text == "/context" { chat_notice_context(session, observer); return true }
	if text == "/drop" {
		dropped := steer_clear(queue)
		if dropped > 0 {
			_observer_message(observer, .Notice, fmt.tprintf("dropped %d queued line(s)", dropped))
		} else {
			_observer_message(observer, .Notice, "steering queue is empty")
		}
		return true
	}
	if strings.has_prefix(text, "/effort ") {
		level := strings.trim_space(text[len("/effort "):])
		if level == "default" {
			chat_session_set_effort(session, "")
			_observer_message(observer, .Notice, "effort cleared to provider default")
		} else if chat_session_set_effort(session, level) {
			_observer_message(observer, .Notice, fmt.tprintf("effort set to %s for the next request", level))
		} else {
			_observer_message(observer, .Notice, fmt.tprintf("effort %s is not allowed for this model", level))
			chat_notice_effort(session, observer, provider_id, model_id)
		}
		return true
	}
	return false
}

// chat_drain_steering injects queued lines at a request boundary. Commands
// run immediately, so /effort still lands before the request view freezes;
// anything else becomes a user message for the next request. A quit discards
// what was never sent.
chat_drain_steering :: proc(session: ^Chat_Session, observer: Chat_Observer, steer: ^Steer_Context) {
	for {
		line, ok := steer_pop(steer.queue)
		if !ok { break }
		if line == "/quit" {
			steer_line_free(steer.queue, line)
			steer.quit^ = true
			dropped := steer_clear(steer.queue)
			if dropped > 0 {
				_observer_message(observer, .Notice, fmt.tprintf("quitting after this turn finishes; dropped %d queued line(s)", dropped))
			} else {
				_observer_message(observer, .Notice, "quitting after this turn finishes")
			}
			return
		}
		if !chat_handle_command(session, observer, steer.queue, line, steer.provider_id, steer.model_id, steer.quit) {
			if line == "/compact" {
				chat_command_compact(session, observer, steer.connection, steer.model, steer.usages)
			} else if !chat_session_steer(session, line) {
				_observer_message(observer, .Warning, "steering arrived outside a request boundary; dropped")
			} else {
				_observer_user_text(observer, line)
			}
		}
		steer_line_free(steer.queue, line)
		if steer.quit^ { return }
	}
}
