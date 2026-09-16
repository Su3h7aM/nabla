package agent

import "core:encoding/json"
import "core:fmt"

import "nabla:agent/session"

// --- running tools -----------------------------------------------------------

// chat_run_tools executes the calls the current response committed. Each call's
// intent is recorded before it runs, and its result after, so an interruption
// between the two is legible as an unknown outcome rather than a guess.
//
// It returns how many calls it recorded, which is what the caller compares
// against the number of committed calls before the turn moves on.
@(private)
chat_run_tools :: proc(chat: ^Chat_Session, observer: Chat_Observer) -> int {
	control := Tool_Control {
		interrupt = &chat_cancel,
		deadline  = chat.turn_deadline,
	}
	count := 0
	for &staged in chat.pending_calls {
		// Every record for this call carries its own id, so a call can be followed
		// from what the model proposed to what was committed for it.
		call := log_scope(chat)
		call.call_id = staged.id
		received := [2]Log_Field{{key = "tool", value = staged.name}, {key = "arguments_bytes", value = i64(len(staged.arguments))}}
		log_emit(call, Log_Record{level = .Info, category = .Tool, event = "tool.call_received", fields = received[:]})

		ctx := Tool_Context {
			call_id   = staged.id,
			workspace = chat.workspace,
			control   = control,
			allocator = chat.allocator,
			skills    = chat_skill_catalog(chat),
		}
		result: Tool_Result

		if chat_session_cancelled(chat) {
			result = tool_result_failure(&ctx, .Not_Executed, "the turn was cancelled before this call ran", "not executed")
		} else if definition, present := tool_registry_find(&chat.tools, staged.name); !present {
			result = tool_result_failure(&ctx, .Unavailable, fmt.tprintf("no tool named %q is available", staged.name), "unavailable")
		} else {
			ctx.backend = definition.backend
			ctx.timeouts = definition.timeouts
			prepared, prepared_ok := chat_prepare_call(chat, observer, &staged, definition)
			if !prepared_ok { return count }
			result = prepared
		}
		// Finalization is the one boundary between execution and storage:
		// every observed result crosses it here, regardless of its source,
		// so the store only ever receives a valid bounded envelope.
		finalized := tool_result_finalize(&ctx, result)

		result_seq, recorded := chat_record_tool_result(chat, &staged, &finalized)
		if !recorded {
			tool_result_destroy(&finalized)
			return count
		}
		committed := [3]Log_Field {
			{key = "tool", value = staged.name},
			{key = "outcome", value = session.tool_outcome_name(finalized.outcome)},
			{key = "result_seq", value = i64(result_seq)},
		}
		log_emit(call, Log_Record{level = .Info, category = .Tool, event = "tool.result_committed", fields = committed[:]})
		_observer_tool_result(observer, staged.name, &finalized)
		tool_result_destroy(&finalized)
		count += 1
	}
	return count
}

// chat_prepare_call admits one call's arguments, records the dispatch, and runs
// the tool. It reports false when a durable write failed, which leaves the
// result empty and the turn stopping.
@(private)
chat_prepare_call :: proc(
	chat: ^Chat_Session,
	observer: Chat_Observer,
	staged: ^Chat_Tool_Call,
	definition: ^Tool_Definition,
) -> (
	result: Tool_Result,
	ok: bool,
) {
	call := log_scope(chat)
	call.call_id = staged.id
	ctx := Tool_Context {
		call_id = staged.id,
		workspace = chat.workspace,
		control = {interrupt = &chat_cancel, deadline = chat.turn_deadline},
		timeouts = definition.timeouts,
		allocator = chat.allocator,
		skills = chat_skill_catalog(chat),
		backend = definition.backend,
	}
	arguments := tool_arguments_prepare(staged.arguments, chat.allocator)
	defer tool_arguments_destroy(&arguments, chat.allocator)
	prepared := [4]Log_Field {
		{key = "tool", value = staged.name},
		{key = "status", value = tool_arguments_status_name(arguments.status)},
		{key = "repair", value = session.tool_repair_name(arguments.repair)},
		{key = "effective_bytes", value = i64(len(arguments.effective))},
	}
	log_emit(call, Log_Record{level = .Debug, category = .Tool, event = "tool.arguments_prepared", fields = prepared[:]})
	if arguments.status == .Rejected {
		return tool_result_refused(&ctx, &arguments.error), true
	}
	// What the call runs with is the text the dispatch record holds, so an executor
	// that forwards the call cannot send something other than what was recorded.
	ctx.arguments_json = arguments.effective
	if arguments.repair != .None {
		_observer_message(observer, .Notice, "a tool call was repaired before it ran: a raw control character was escaped")
	}

	object, is_object := arguments.value.(json.Object)
	if !is_object {
		return tool_result_failure(&ctx, .Invalid_Arguments, "the arguments are not a JSON object", "invalid arguments"), true
	}
	dispatch := session.New_Entry {
		turn_no = chat.turn_no,
		request_no = chat.active_request,
		created_at_ms = session.now_ms(),
		related_seq = staged.seq,
		payload = session.Tool_Dispatch_Entry{tool = staged.name, arguments = arguments.effective, repair = arguments.repair},
	}
	if dispatch_seq, dispatch_error := session.entry_append(chat.store, chat.id, dispatch); dispatch_error != nil {
		chat_session_record_failure(chat, "the tool dispatch could not be recorded", dispatch_error)
		return {}, false
	} else {
		dispatched := [2]Log_Field{{key = "tool", value = staged.name}, {key = "dispatch_seq", value = i64(dispatch_seq)}}
		log_emit(call, Log_Record{level = .Info, category = .Tool, event = "tool.dispatch_committed", fields = dispatched[:]})
	}
	// Cancellation can land after the intent was recorded but before execution
	// begins. The intent is durable, but the call never started.
	if tool_control_cancelled(ctx.control) {
		return tool_result_failure(&ctx, .Not_Executed, "the turn was cancelled before this call ran", "not executed"), true
	}
	started := [1]Log_Field{{key = "tool", value = staged.name}}
	log_emit(call, Log_Record{level = .Info, category = .Tool, event = "tool.execution_started", fields = started[:]})
	result = definition.execute(&ctx, object)
	finished := [2]Log_Field{{key = "tool", value = staged.name}, {key = "outcome", value = session.tool_outcome_name(result.outcome)}}
	log_emit(call, Log_Record{level = .Info, category = .Tool, event = "tool.execution_finished", fields = finished[:]})
	return result, true
}

// chat_record_tool_result appends the result entry a model later reads. It reports
// the entry it stored, and reports no entry when the write failed, which stops the
// turn: a call that ran and left no result is exactly the unanswered call the
// record must never have.
@(private)
chat_record_tool_result :: proc(chat: ^Chat_Session, staged: ^Chat_Tool_Call, result: ^Tool_Result) -> (seq: session.Seq, recorded: bool) {
	error_text := ""
	if result.error.kind != .None { error_text = tool_argument_error_text(result.error, context.temp_allocator) }
	entry := session.New_Entry {
		turn_no = chat.turn_no,
		request_no = chat.active_request,
		created_at_ms = session.now_ms(),
		related_seq = staged.seq,
		payload = session.Tool_Result_Entry{outcome = result.outcome, error = error_text, content = result.content, origin = .Observed},
	}
	stored, append_error := session.entry_append(chat.store, chat.id, entry)
	if append_error != nil {
		chat_session_record_failure(chat, "the tool result could not be recorded", append_error)
		return {}, false
	}
	return stored, true
}
