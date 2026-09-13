package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sys/posix"

import "nabla:agent/session"
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

// chat_api_name is the stable text a request record keeps for the api family a
// request was sent through.
chat_api_name :: proc(api: ai.API_Kind) -> string {
	switch api {
	case .OpenAI_Chat_Completions:
		return "openai_chat_completions"
	case .OpenAI_Responses:
		return "openai_responses"
	case .Anthropic_Messages:
		return "anthropic_messages"
	case .Invalid:
		return ""
	}
	return ""
}

Chat_Request_Usage :: struct {
	operation: u64,
	usage:     ai.Provider_Usage_Event,
}

Chat_Runtime_Context :: struct {
	chat:           ^Chat_Session,
	source:         Chat_Event_Source,
	observer:       Chat_Observer,
	usage_log:      ^[dynamic]Chat_Request_Usage,
	assistant_open: bool, // the assistant block is announced once per request,
	finish_reason:  ai.Provider_Finish_Reason, // the provider's own stop reason,
}

chat_provider_event :: proc(user_data: rawptr, event: ai.Provider_Event) {
	runtime := cast(^Chat_Runtime_Context)user_data
	#partial switch value in event {
	case ai.Provider_Text_Event:
		if chat_session_feed_text(runtime.chat, runtime.source, value.Text) {
			if !runtime.assistant_open {
				_observer_assistant_begin(runtime.observer)
				runtime.assistant_open = true
			}
			_observer_assistant_text(runtime.observer, value.Text)
		}
	case ai.Provider_Reasoning_Event:
		// Reasoning never displays; it is staged so the next request can
		// replay it. A rejected feed is a stale event, not a turn failure.
		chat_session_feed_reasoning(runtime.chat, runtime.source, value.ID, value.Encrypted)
	case ai.Provider_Completed_Event:
		// One response feeds one path: tool handoff when the provider
		// assembled calls, plain completion on stop, failure otherwise.
		// A length limit or content filter is not a usable answer, so it
		// must not finalize as success. Partial argument fragments never
		// reach the executor; only this validated event carries
		// executable calls.
		runtime.finish_reason = value.Reason
		if value.Reason == .Tool_Call && len(value.Tool_Calls) > 0 {
			if !chat_session_feed_tool_calls(runtime.chat, runtime.source, value.Tool_Calls) {
				chat_session_feed_error(runtime.chat, runtime.source, "tool response was rejected")
			}
		} else if value.Reason == .Stop {
			chat_session_feed_completion(runtime.chat, runtime.source)
		} else {
			if value.Reason_Text != "" {
				chat_session_feed_error(runtime.chat, runtime.source, fmt.tprintf("response incomplete: %s", value.Reason_Text))
			} else {
				chat_session_feed_error(runtime.chat, runtime.source, "response incomplete")
			}
		}
	case ai.Provider_Error_Event:
		// A cancelled turn reports cancellation, not the transport error that
		// cancellation itself produced. Noting it here also stops every later event
		// from reaching a turn that is already stopping.
		if chat_session_cancelled(runtime.chat) {
			chat_session_note_cancel(runtime.chat)
		} else {
			chat_session_feed_error(runtime.chat, runtime.source, value.Message)
		}
	case ai.Provider_Usage_Event:
		if value.Input_Tokens_Present {
			runtime.chat.last_input_measured = value.Input_Tokens
			runtime.chat.last_input_measured_present = true
		}
		if runtime.usage_log != nil {
			append(runtime.usage_log, Chat_Request_Usage{operation = u64(runtime.chat.requests_made), usage = value})
		}
	}
}

// --- request assembly --------------------------------------------------------

// Chat_Request_Prep is one request built from committed history, together with
// the storage the request borrows. It owns the context it was built from.
Chat_Request_Prep :: struct {
	history:  session.Context,
	request:  ai.Provider_Request,
	wire:     [dynamic]ai.Provider_Message,
	tools:    [dynamic]ai.Provider_Tool_Def,
	calls:    [dynamic][dynamic]ai.Provider_Tool_Call,
	estimate: int,
}

chat_request_prep_destroy :: proc(prep: ^Chat_Request_Prep, allocator: mem.Allocator) {
	session.context_destroy(&prep.history, allocator)
	for &slot in prep.calls { delete(slot) }
	delete(prep.calls)
	delete(prep.tools)
	delete(prep.wire)
	prep^ = {}
}

// chat_prepare reads the committed context and builds the request that follows
// from it. Every request is built this way: there is no other copy of the
// conversation to fall out of step with.
@(private)
chat_prepare :: proc(chat: ^Chat_Session, connection: ai.Provider_Connection) -> (prep: Chat_Request_Prep, err: session.Error) {
	ctx, context_err := session.context_load(chat.store, chat.id, chat.allocator)
	if context_err != nil { return {}, context_err }
	prep.history = ctx
	chat_build_request_into(chat, &prep, ctx.entries, ctx.summary, connection, false)
	return prep, nil
}

// chat_build_request_into assembles a request from an explicit span of stored
// entries and the summary that precedes it. compact selects the summarization
// request, which carries instructions instead of the agent prompt and no tools,
// because a summary must be text.
@(private)
chat_build_request_into :: proc(
	chat: ^Chat_Session,
	prep: ^Chat_Request_Prep,
	entries: []session.Entry,
	summary: string,
	connection: ai.Provider_Connection,
	compact: bool,
) {
	prep.wire = make([dynamic]ai.Provider_Message, 0, len(entries) + 2, chat.allocator)
	prep.tools = make([dynamic]ai.Provider_Tool_Def, 0, chat.allocator)
	prep.calls = make([dynamic][dynamic]ai.Provider_Tool_Call, 0, chat.allocator)

	if compact {
		append(&prep.wire, ai.Provider_Message{Role = .System, Content = CHAT_COMPACT_INSTRUCTIONS})
	} else if chat.tools_enabled {
		append(&prep.wire, ai.Provider_Message{Role = .System, Content = AGENT_SYSTEM_PROMPT})
	}
	// A checkpoint stands in for the history it covers, so the request opens
	// with the summary and continues with the entries after it.
	if summary != "" {
		summary_text := strings.concatenate({"Summary of the conversation so far:\n", summary}, context.temp_allocator)
		append(&prep.wire, ai.Provider_Message{Role = .Assistant, Content = summary_text})
	}
	chat_append_entries(&prep.wire, &prep.calls, entries)

	prep.request = ai.Provider_Request {
		API              = connection.API,
		Model_Present    = true,
		Model            = chat.model_id,
		Messages_Present = true,
		Messages         = prep.wire[:],
	}
	if compact {
		prep.request.Max_Output_Tokens_Present = true
		prep.request.Max_Output_Tokens = CHAT_COMPACT_MAX_OUTPUT
	} else {
		if chat.max_output_tokens > 0 {
			prep.request.Max_Output_Tokens_Present = true
			prep.request.Max_Output_Tokens = chat.max_output_tokens
		}
		if chat.effort != "" {
			prep.request.Reasoning_Effort_Present = true
			prep.request.Reasoning_Effort = chat.effort
		}
		if chat.tools_enabled {
			append(
				&prep.tools,
				ai.Provider_Tool_Def{Name = TOOL_SHELL_NAME, Description = TOOL_SHELL_DESCRIPTION, Parameters_JSON = TOOL_SHELL_PARAMETERS_JSON},
			)
			prep.request.Tools = prep.tools[:]
		}
	}
	prep.estimate = chat_estimate_input_tokens(prep.wire[:], prep.tools[:])
}

// chat_append_entries turns stored entries into provider messages. Consecutive
// tool calls become one assistant message, which is how a provider sees a
// multi-call response, and a result names the call it answers through the
// sequence the two entries share.
@(private)
chat_append_entries :: proc(messages: ^[dynamic]ai.Provider_Message, call_lists: ^[dynamic][dynamic]ai.Provider_Tool_Call, entries: []session.Entry) {
	group: [dynamic]ai.Provider_Tool_Call
	group_open := false
	call_ids := make(map[i64]string, allocator = context.temp_allocator)
	defer delete(call_ids)

	for entry in entries {
		#partial switch payload in entry.payload {
		case session.User_Entry:
			chat_flush_calls(messages, call_lists, &group, &group_open)
			append(messages, ai.Provider_Message{Role = .User, Content = payload.text})
		case session.Assistant_Entry:
			if !payload.partial {
				chat_flush_calls(messages, call_lists, &group, &group_open)
				append(messages, ai.Provider_Message{Role = .Assistant, Content = payload.text})
			}
		case session.Reasoning_Entry:
			chat_flush_calls(messages, call_lists, &group, &group_open)
			append(messages, ai.Provider_Message{Role = .Reasoning, Reasoning_ID = payload.id, Reasoning_Encrypted = payload.encrypted})
		case session.Tool_Call_Entry:
			call_ids[i64(entry.seq)] = payload.call_id
			append(&group, ai.Provider_Tool_Call{ID = payload.call_id, Item_ID = payload.item_id, Name = payload.name, Arguments = payload.arguments})
			group_open = true
		case session.Tool_Result_Entry:
			chat_flush_calls(messages, call_lists, &group, &group_open)
			call_id := ""
			if related, present := entry.related_seq.?; present { call_id = call_ids[i64(related)] }
			append(messages, ai.Provider_Message{Role = .Tool, Content = payload.content, Tool_Call_ID = call_id})
		case session.Tool_Dispatch_Entry, session.Checkpoint_Entry:
		// Bookkeeping a model is never shown.
		}
	}
	chat_flush_calls(messages, call_lists, &group, &group_open)
	delete(group)
}

@(private)
chat_flush_calls :: proc(
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

@(private)
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

// Admission is approximate and says so: character counts divided by four plus
// a per-message overhead cannot replace endpoint token counting, so the check
// keeps a safety margin and refuses over-budget requests instead of sending
// them. Measured usage from the endpoint is evidence, never the estimate.
CHAT_CHARS_PER_TOKEN :: 4
CHAT_MESSAGE_OVERHEAD_TOKENS :: 8
CHAT_ADMISSION_MARGIN_TOKENS :: 8192
CHAT_DEFAULT_OUTPUT_RESERVE_TOKENS :: 4096

// chat_admission_check enforces input estimate plus reserved generation plus
// margin against the configured window. The message is temp-allocated; the
// caller clones it when the turn must record the failure.
chat_admission_check :: proc(chat: ^Chat_Session, estimate: int) -> (message: string, admitted: bool) {
	if chat.context_window <= 0 {
		return "context admission needs context_window: add context_window to the model in config.lua", false
	}
	reserved := chat.max_output_tokens
	if reserved <= 0 { reserved = CHAT_DEFAULT_OUTPUT_RESERVE_TOKENS }
	if estimate + reserved + CHAT_ADMISSION_MARGIN_TOKENS <= chat.context_window {
		return "", true
	}
	return fmt.tprintf(
			"request estimated at ~%d input tokens exceeds the %d-token window (reserved %d output, %d margin): shorten the prompt, compact, or raise the limits",
			estimate,
			chat.context_window,
			reserved,
			CHAT_ADMISSION_MARGIN_TOKENS,
		),
		false
}

// --- request records ---------------------------------------------------------

@(private)
Chat_Request_Config :: struct {
	max_output_tokens: Maybe(i64) `json:"max_output_tokens"`,
	effort:            string `json:"effort"`,
}

@(private)
Chat_Request_Input :: struct {
	instructions:    string `json:"instructions"`,
	tools:           []string `json:"tools"`,
	summary_seq:     Maybe(session.Seq) `json:"summary_seq"`,
	covered_seq:     Maybe(session.Seq) `json:"covered_seq"`,
	context_through: Maybe(session.Seq) `json:"context_through"`,
}

@(private)
Chat_Request_Response :: struct {
	reason: string `json:"reason"`,
}

// chat_finish_reason_text is the stable name a request record keeps for why the
// model stopped, so the stored value does not depend on a borrowed event string.
chat_finish_reason_text :: proc(reason: ai.Provider_Finish_Reason) -> string {
	switch reason {
	case .Stop:
		return "stop"
	case .Length:
		return "length"
	case .Content_Filter:
		return "content_filter"
	case .Tool_Call:
		return "tool_call"
	case .Unknown:
		return "unknown"
	}
	return "unknown"
}

@(private)
Chat_Request_Error :: struct {
	message: string `json:"message"`,
}

// chat_request_config_json describes the settings a request is sent with. A
// summarization request carries its own output bound and no reasoning effort, so
// the record describes that request rather than the ordinary one the session
// would run.
@(private)
chat_request_config_json :: proc(chat: ^Chat_Session, compact: bool) -> string {
	config := Chat_Request_Config{}
	if compact {
		config.max_output_tokens = CHAT_COMPACT_MAX_OUTPUT
	} else {
		config.effort = chat.effort
		if chat.max_output_tokens > 0 { config.max_output_tokens = i64(chat.max_output_tokens) }
	}
	data, marshal_err := json.marshal(config, allocator = context.temp_allocator)
	if marshal_err != nil { return "{}" }
	return string(data)
}

// chat_request_input_json describes what a request carried: the instructions and
// tool names that are not in the entries, the boundary its context started
// after, and the last entry it included. The entries themselves stay in one
// place, so the record points at them rather than copying them.
@(private)
chat_request_input_json :: proc(chat: ^Chat_Session, ctx: session.Context, entry_count: int, compact: bool) -> string {
	tools := make([dynamic]string, 0, 1, context.temp_allocator)
	defer delete(tools)
	if chat.tools_enabled && !compact { append(&tools, TOOL_SHELL_NAME) }

	input := Chat_Request_Input {
		instructions = AGENT_SYSTEM_PROMPT if !compact else CHAT_COMPACT_INSTRUCTIONS,
		tools        = tools[:],
		summary_seq  = ctx.summary_seq,
		covered_seq  = ctx.covered_seq,
	}
	count := entry_count
	if count > len(ctx.entries) { count = len(ctx.entries) }
	if count > 0 { input.context_through = ctx.entries[count - 1].seq }

	data, marshal_err := json.marshal(input, allocator = context.temp_allocator)
	if marshal_err != nil { return "{}" }
	return string(data)
}

@(private)
chat_error_json :: proc(message: string) -> string {
	data, marshal_err := json.marshal(Chat_Request_Error{message = message}, allocator = context.temp_allocator)
	if marshal_err != nil { return "" }
	return string(data)
}

// chat_request_usage totals one request's usage. The provider's last word wins,
// because a provider may report the same measurement more than once as it
// settles, and an absent measurement stays absent rather than becoming zero.
@(private)
chat_request_usage :: proc(usages: ^[dynamic]Chat_Request_Usage, operation: u64) -> session.Usage {
	usage: session.Usage
	for entry in usages {
		if entry.operation != operation { continue }
		if entry.usage.Input_Tokens_Present { usage.input = entry.usage.Input_Tokens }
		if entry.usage.Output_Tokens_Present { usage.output = entry.usage.Output_Tokens }
		if entry.usage.Cached_Input_Tokens_Present { usage.cache_read = entry.usage.Cached_Input_Tokens }
		if entry.usage.Cache_Write_Tokens_Present { usage.cache_write = entry.usage.Cache_Write_Tokens }
	}
	return usage
}

// --- running a request -------------------------------------------------------

// chat_perform_request builds one request from committed history, records it,
// runs it, and records what came back. The record exists before the model is
// asked anything, so a request that never finishes still says what it carried.
@(private)
chat_perform_request :: proc(chat: ^Chat_Session, connection: ai.Provider_Connection, observer: Chat_Observer, usages: ^[dynamic]Chat_Request_Usage) {
	prep, prep_err := chat_prepare(chat, connection)
	if prep_err != nil {
		chat_session_record_failure(chat, "the request context could not be read", prep_err)
		return
	}
	defer chat_request_prep_destroy(&prep, chat.allocator)

	// Admission runs on every request, including tool continuations. An
	// over-budget turn compacts once and recounts; a turn that still cannot
	// fit fails here, before any byte is sent. A fitting but hot window
	// compacts once so the next continuation starts small.
	message, admitted := chat_admission_check(chat, prep.estimate)
	hot := chat.context_window > 0 && prep.estimate * 5 >= chat.context_window * 4
	if !admitted || hot {
		if chat_compact(chat, observer, connection, &prep, usages) && !chat_session_cancelled(chat) {
			message, admitted = chat_admission_check(chat, prep.estimate)
		}
		if !admitted {
			if chat_session_cancelled(chat) {
				chat_session_note_cancel(chat)
			} else {
				chat_session_fail_turn(chat, message)
			}
			return
		}
	}
	if chat_session_cancelled(chat) {
		chat_session_note_cancel(chat)
		return
	}

	chat.last_estimate = prep.estimate
	at_ms := session.now_ms()
	request_no, begin_err := session.request_begin(
		chat.store,
		chat.id,
		{
			turn_no = chat.turn_no,
			purpose = .Response,
			provider = chat.provider_id,
			model_requested = chat.model_id,
			api = chat_api_name(connection.API),
			config_json = chat_request_config_json(chat, false),
			input_json = chat_request_input_json(chat, prep.history, len(prep.history.entries), false),
		},
		at_ms,
	)
	if begin_err != nil {
		chat_session_record_failure(chat, "the request could not be recorded", begin_err)
		return
	}
	chat.active_request = request_no

	chat_session_begin_operation(chat)
	operation := chat_session_operation(chat)
	runtime := Chat_Runtime_Context {
		chat      = chat,
		source    = chat_session_event_source(chat),
		observer  = observer,
		usage_log = usages,
	}
	options := ai.Provider_Operation_Options {
		interrupt = &chat_cancel,
		deadline  = operation.deadline,
	}
	operation_error := ai.Provider_Request_Operation_Controlled(connection, prep.request, &runtime, chat_provider_event, options, chat.allocator)
	// The error owns its detail, and every path out of the request releases it.
	defer delete(operation_error.detail, chat.allocator)
	_observer_assistant_flush(observer)

	// Cancellation is the reason the turn ended, so it wins over any error the
	// transport also reported.
	if chat_session_cancelled(chat) {
		chat_session_note_cancel(chat)
	} else if operation_error.kind != .None && chat.state != .Finalizing {
		chat_session_feed_error(chat, runtime.source, operation_error.detail)
	}
	chat_session_retire_operation(chat)

	chat_commit_response(chat, request_no, runtime.finish_reason, usages)
}

// chat_commit_response records what the response produced and how the request
// ended. A completed response becomes entries: its reasoning, then any text,
// then the calls it proposed. A failed or cancelled one records only its
// outcome here; the text it produced becomes a partial entry when the turn
// settles, because an unfinished answer must never be replayed as a finished one.
@(private)
chat_commit_response :: proc(
	chat: ^Chat_Session,
	request_no: session.Request_No,
	finish_reason: ai.Provider_Finish_Reason,
	usages: ^[dynamic]Chat_Request_Usage,
) {
	at_ms := session.now_ms()
	outcome: session.Outcome = .Completed
	if chat_session_cancelled(chat) {
		outcome = .Cancelled
	} else if chat.active_failed {
		outcome = .Failed
	}

	if outcome == .Completed {
		text := string(chat.partial_assistant[:])
		entries := make([dynamic]session.New_Entry, 0, len(chat.pending_reasoning) + len(chat.pending_calls) + 1, chat.allocator)
		defer delete(entries)
		for reasoning in chat.pending_reasoning {
			append(
				&entries,
				session.New_Entry {
					turn_no = chat.turn_no,
					request_no = request_no,
					created_at_ms = at_ms,
					payload = session.Reasoning_Entry{id = reasoning.id, encrypted = reasoning.encrypted},
				},
			)
		}
		if text != "" {
			append(
				&entries,
				session.New_Entry{turn_no = chat.turn_no, request_no = request_no, created_at_ms = at_ms, payload = session.Assistant_Entry{text = text}},
			)
		}
		for call in chat.pending_calls {
			append(
				&entries,
				session.New_Entry {
					turn_no = chat.turn_no,
					request_no = request_no,
					created_at_ms = at_ms,
					payload = session.Tool_Call_Entry{call_id = call.id, item_id = call.item_id, name = call.name, arguments = call.arguments},
				},
			)
		}

		seqs, append_err := session.entries_append(chat.store, chat.id, entries[:], chat.allocator)
		if append_err != nil {
			delete(seqs, chat.allocator)
			chat_session_record_failure(chat, "the response could not be recorded", append_err)
			return
		}
		// Each staged call now knows the entry it was stored as, which is what a
		// later dispatch and result name.
		offset := len(chat.pending_reasoning) + (1 if text != "" else 0)
		for i in 0 ..< len(chat.pending_calls) { chat.pending_calls[i].seq = seqs[offset + i] }
		delete(seqs, chat.allocator)

		chat_pending_reasoning_clear(chat)
		delete(chat.partial_assistant)
		chat.partial_assistant = make([dynamic]u8, 0, 0, chat.allocator)
	}

	response_json := ""
	if finish_reason != .Unknown {
		response_json = string(
			json.marshal(Chat_Request_Response{reason = chat_finish_reason_text(finish_reason)}, allocator = context.temp_allocator) or_else nil,
		)
	}
	error_json := ""
	if outcome == .Failed && chat.last_error != "" {
		error_json = chat_error_json(chat.last_error)
	} else if outcome == .Cancelled {
		error_json = chat_error_json("cancelled")
	}

	finish_err := session.request_finish(
		chat.store,
		chat.id,
		request_no,
		{
			outcome = outcome,
			response_json = response_json,
			error_json = error_json,
			usage = chat_request_usage(usages, u64(chat.requests_made)),
			at_ms = at_ms,
		},
	)
	if finish_err != nil {
		chat_session_record_failure(chat, "the request outcome could not be recorded", finish_err)
	}
}

// --- running tools -----------------------------------------------------------

// chat_run_tools executes the calls the current response committed. Each call's
// intent is recorded before it runs, and its result after, so an interruption
// between the two is legible as an unknown outcome rather than a guess.
@(private)
chat_run_tools :: proc(chat: ^Chat_Session, observer: Chat_Observer) -> int {
	control := Tool_Control {
		interrupt = &chat_cancel,
		deadline  = chat.turn_deadline,
	}
	count := 0
	for &staged in chat.pending_calls {
		result: Tool_Result
		args: Tool_Shell_Args
		args_valid := false

		if chat_session_cancelled(chat) {
			result = tool_error_result(staged.id, .Not_Executed, "turn cancelled before this call ran", chat.allocator)
		} else if staged.name != TOOL_SHELL_NAME {
			result = tool_error_result(staged.id, .Invalid_Arguments, "unknown tool", chat.allocator)
		} else {
			args, args_valid = tool_shell_parse_args(staged.arguments, chat.allocator)
			if !args_valid {
				result = tool_error_result(staged.id, .Invalid_Arguments, "invalid shell arguments", chat.allocator)
			} else {
				dispatch := session.New_Entry {
					turn_no = chat.turn_no,
					request_no = chat.active_request,
					created_at_ms = session.now_ms(),
					related_seq = staged.seq,
					payload = session.Tool_Dispatch_Entry{tool = staged.name, arguments = staged.arguments},
				}
				if _, dispatch_err := session.entry_append(chat.store, chat.id, dispatch); dispatch_err != nil {
					chat_session_record_failure(chat, "the tool dispatch could not be recorded", dispatch_err)
					tool_shell_args_destroy(&args, chat.allocator)
					return count
				}
				result = tool_shell_execute(staged.id, args, chat.workspace, control, chat.allocator)
			}
		}

		text := tool_result_json(&result, chat.allocator)
		_observer_tool_result(observer, staged.name, &result)

		entry := session.New_Entry {
			turn_no = chat.turn_no,
			request_no = chat.active_request,
			created_at_ms = session.now_ms(),
			related_seq = staged.seq,
			payload = session.Tool_Result_Entry {
				outcome = chat_tool_outcome(result.status),
				exit_code = i32(result.exit_code) if result.exit_present else nil,
				error = result.error_text,
				content = text,
				origin = .Observed,
			},
		}
		_, result_err := session.entry_append(chat.store, chat.id, entry)
		delete(text, chat.allocator)
		tool_result_destroy(&result)
		if args_valid { tool_shell_args_destroy(&args, chat.allocator) }
		if result_err != nil {
			chat_session_record_failure(chat, "the tool result could not be recorded", result_err)
			return count
		}
		count += 1
	}
	return count
}

chat_tool_outcome :: proc(status: Tool_Result_Status) -> session.Tool_Outcome {
	switch status {
	case .Exited:
		return .Exited
	case .Invalid_Arguments:
		return .Invalid_Arguments
	case .Spawn_Failed:
		return .Spawn_Failed
	case .Timed_Out:
		return .Timed_Out
	case .Cancelled:
		return .Cancelled
	case .Not_Executed:
		return .Not_Executed
	case .IO_Failed:
		return .IO_Failed
	case .None:
		return .Unknown
	}
	return .Unknown
}

// --- settling a turn ---------------------------------------------------------

// chat_persist_turn_end records the turn's outcome and keeps whatever text the
// turn produced but never committed. That text is marked partial, so it is
// evidence in the record and never a finished answer in a later request.
@(private)
chat_persist_turn_end :: proc(chat: ^Chat_Session, effect: Chat_Effect) {
	turn_no, has_turn := chat.turn_no.?
	if !has_turn { return }
	at_ms := session.now_ms()

	if text := string(chat.partial_assistant[:]); text != "" {
		entry := session.New_Entry {
			turn_no = turn_no,
			created_at_ms = at_ms,
			payload = session.Assistant_Entry{text = text, partial = true},
		}
		if _, append_err := session.entry_append(chat.store, chat.id, entry); append_err != nil {
			chat_session_record_failure(chat, "the partial answer could not be recorded", append_err)
		}
		delete(chat.partial_assistant)
		chat.partial_assistant = make([dynamic]u8, 0, 0, chat.allocator)
	}

	outcome: session.Outcome = .Completed
	switch effect.status {
	case .Completed:
		outcome = .Completed
	case .Failed:
		outcome = .Failed
	case .Cancelled:
		outcome = .Cancelled
	case .None:
		outcome = .Interrupted
	}
	error_json := ""
	if effect.error != "" { error_json = chat_error_json(effect.error) }

	if turn_err := session.turn_finish(chat.store, chat.id, turn_no, outcome, error_json, at_ms); turn_err != nil {
		chat_session_record_failure(chat, "the turn outcome could not be recorded", turn_err)
	}
	chat.turn_no = nil
	chat.active_request = nil
	// A turn that ended without running its staged calls, such as one a durable
	// write stopped, releases them here.
	chat_pending_calls_clear(chat)
	chat_pending_reasoning_clear(chat)
}

@(private)
chat_pending_reasoning_clear :: proc(chat: ^Chat_Session) {
	for &reasoning in chat.pending_reasoning { chat_reasoning_destroy(&reasoning, chat.allocator) }
	clear(&chat.pending_reasoning)
}

// --- the turn loop -----------------------------------------------------------

chat_run_turn :: proc(chat: ^Chat_Session, connection: ai.Provider_Connection, observer: Chat_Observer) -> bool {
	return chat_run_turn_steered(chat, connection, observer, nil)
}

// Steer_Context carries the steering queue into the turn loop. Nil means no
// steering: queued lines are drained before every model request, which is
// after tool calls settled and before the request is read from the store.
Steer_Context :: struct {
	queue:       ^Steer_Queue,
	quit:        ^bool,
	provider_id: string,
	model_id:    string,
	connection:  ai.Provider_Connection,
	usages:      ^[dynamic]Chat_Request_Usage,
}

chat_run_turn_steered :: proc(chat: ^Chat_Session, connection: ai.Provider_Connection, observer: Chat_Observer, steer: ^Steer_Context) -> bool {
	usages := make([dynamic]Chat_Request_Usage, 0, chat.allocator)
	defer delete(usages)
	if steer != nil { steer.usages = &usages }
	defer if steer != nil { steer.usages = nil }

	previous: posix.sigaction_t
	chat_signal_arm(&previous)
	defer chat_signal_disarm(&previous)

	for {
		if steer != nil && chat.state == .Preparing {
			chat_drain_steering(chat, observer, steer)
		}
		effect := chat_session_advance(chat)
		switch effect.kind {
		case .Start_Request:
			chat_effect_destroy(&effect)
			chat_perform_request(chat, connection, observer, &usages)
		case .Run_Tools:
			chat_effect_destroy(&effect)
			count := chat_run_tools(chat, observer)
			chat_session_tools_done(chat, chat.active_turn_id, count)
			if chat_session_cancelled(chat) { chat_session_note_cancel(chat) }
		case .Turn_Finished:
			chat_persist_turn_end(chat, effect)
			chat_report_terminal(observer, effect)
			status := effect.status
			chat_effect_destroy(&effect)
			chat_report_usage(observer, usages)
			return status == .Completed
		case .None:
			chat_effect_destroy(&effect)
			if chat.state == .Finalizing || chat.state == .Cancelling { continue }
			return false
		}
	}
}

chat_report_usage :: proc(observer: Chat_Observer, entries: [dynamic]Chat_Request_Usage) {
	for entry in entries {
		_observer_usage(observer, entry.operation, entry.usage)
	}
}

chat_supports_tools :: proc(api: ai.API_Kind) -> bool {
	return api == .OpenAI_Chat_Completions || api == .OpenAI_Responses
}

chat_notice_effort :: proc(chat: ^Chat_Session, observer: Chat_Observer, provider_id, model_id: string) {
	if chat.effort != "" {
		_observer_message(observer, .Notice, fmt.tprintf("effort for %s / %s is %s", provider_id, model_id, chat.effort))
	} else {
		_observer_message(observer, .Notice, fmt.tprintf("effort for %s / %s is provider default", provider_id, model_id))
	}
	if len(chat.effort_levels) > 0 {
		levels, join_err := strings.join(chat.effort_levels[:], " ", context.temp_allocator)
		if join_err == nil {
			_observer_message(observer, .Notice, fmt.tprintf("allowed: %s", levels))
		}
	} else {
		_observer_message(observer, .Notice, "no effort levels configured for this model")
	}
}

// chat_notice_status reports what the session is and what it is doing: who it is,
// where it runs, how long it has run, which model and effort it uses, and the
// context and usage numbers the harness already measured. Nothing here is
// collected for the report; every value is one the session already holds.
chat_notice_status :: proc(chat: ^Chat_Session, observer: Chat_Observer, now_ms: i64) {
	header, header_err := session.session_load(chat.store, chat.id, context.temp_allocator)
	have_header := header_err == nil
	defer session.session_destroy(&header, context.temp_allocator)

	chat_status_line(observer, "session", string(chat.id))
	if have_header {
		title := header.title if header.title != "" else "(untitled)"
		chat_status_line(observer, "title", title)
	}
	chat_status_line(observer, "cwd", chat.workspace)
	if have_header {
		age := chat_age_text(now_ms - header.created_at_ms)
		chat_status_line(observer, "running", fmt.tprintf("%s%s", age, " (turn active)" if chat.state != .Idle else ""))
	}
	chat_status_line(observer, "model", fmt.tprintf("%s / %s", chat.provider_id, chat.model_id))
	chat_status_line(observer, "effort", chat.effort if chat.effort != "" else "provider default")
	chat_status_line(observer, "tools", "shell" if chat.tools_enabled else "none")

	if chat.context_window > 0 {
		reserved := chat.max_output_tokens
		if reserved <= 0 { reserved = CHAT_DEFAULT_OUTPUT_RESERVE_TOKENS }
		usable := chat.context_window - reserved - CHAT_ADMISSION_MARGIN_TOKENS
		chat_status_line(
			observer,
			"context",
			fmt.tprintf("%d window, %d reserved, %d margin (%d usable)", chat.context_window, reserved, CHAT_ADMISSION_MARGIN_TOKENS, usable),
		)
	} else {
		chat_status_line(observer, "context", "not configured for this model")
	}

	estimate := "none"
	if chat.last_estimate > 0 { estimate = fmt.tprintf("%d", chat.last_estimate) }
	measured := "none"
	if chat.last_input_measured_present { measured = fmt.tprintf("%d", chat.last_input_measured) }
	chat_status_line(observer, "usage", fmt.tprintf("estimate %s, measured %s", estimate, measured))
}

@(private)
chat_status_line :: proc(observer: Chat_Observer, label, value: string) {
	_observer_message(observer, .Notice, fmt.tprintf("%-10s %s", label, value))
}

// chat_age_text says how long ago something happened, in the largest two units
// that keep it readable.
@(private)
chat_age_text :: proc(elapsed_ms: i64) -> string {
	seconds := elapsed_ms / 1_000
	if seconds < 0 { return "unknown" }
	if seconds < 60 { return fmt.tprintf("%ds", seconds) }
	minutes := seconds / 60
	if minutes < 60 { return fmt.tprintf("%dm %ds", minutes, seconds % 60) }
	hours := minutes / 60
	if hours < 24 { return fmt.tprintf("%dh %dm", hours, minutes % 60) }
	return fmt.tprintf("%dd %dh", hours / 24, hours % 24)
}

// chat_handle_command runs one input line as a command. True means handled;
// the caller sends anything else as a turn or a steering line. /quit during
// a turn quits after it: no turn is running at shutdown, so the reader join
// cannot strand tool children.
chat_handle_command :: proc(chat: ^Chat_Session, observer: Chat_Observer, queue: ^Steer_Queue, text, provider_id, model_id: string, quit: ^bool) -> bool {
	if text == "/quit" {
		if chat.state != .Idle { _observer_message(observer, .Notice, "quitting after this turn finishes") }
		quit^ = true
		return true
	}
	if text == "/effort" {
		chat_notice_effort(chat, observer, provider_id, model_id)
		return true
	}
	if text == "/status" {
		chat_notice_status(chat, observer, session.now_ms())
		return true
	}
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
			chat_session_set_effort(chat, "")
			_observer_message(observer, .Notice, "effort cleared to provider default")
		} else if chat_session_set_effort(chat, level) {
			_observer_message(observer, .Notice, fmt.tprintf("effort set to %s for the next request", level))
		} else {
			_observer_message(observer, .Notice, fmt.tprintf("effort %s is not allowed for this model", level))
			chat_notice_effort(chat, observer, provider_id, model_id)
		}
		return true
	}
	return false
}

// chat_drain_steering injects queued lines at a request boundary. Commands
// run immediately, so /effort still lands before the request is read from the
// store; anything else becomes a user entry for the next request. A quit
// discards what was never sent.
chat_drain_steering :: proc(chat: ^Chat_Session, observer: Chat_Observer, steer: ^Steer_Context) {
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
		if !chat_handle_command(chat, observer, steer.queue, line, steer.provider_id, steer.model_id, steer.quit) {
			if line == "/compact" {
				chat_command_compact(chat, observer, steer.connection, steer.usages)
			} else if strings.has_prefix(line, "/") {
				// A slash is a command, never a message. A command this path does not
				// answer to is refused rather than sent to the model as steering text.
				_observer_message(observer, .Notice, fmt.tprintf("%s is not available while a turn is running", line))
			} else if !chat_session_steer(chat, line, session.now_ms()) {
				if chat.last_error != "" {
					_observer_message(observer, .Error, chat.last_error)
				} else {
					_observer_message(observer, .Warning, "steering arrived outside a request boundary; dropped")
				}
			} else {
				_observer_user_text(observer, line)
			}
		}
		steer_line_free(steer.queue, line)
		if steer.quit^ { return }
	}
}
