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
			prepared, prepared_ok := chat_prepare_call(chat, observer, &staged, definition)
			if !prepared_ok { return count }
			result = prepared
		}

		if !chat_record_tool_result(chat, &staged, &result) {
			tool_result_destroy(&result)
			return count
		}
		_observer_tool_result(observer, staged.name, &result)
		tool_result_destroy(&result)
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
	ctx := Tool_Context {
		call_id = staged.id,
		workspace = chat.workspace,
		control = {interrupt = &chat_cancel, deadline = chat.turn_deadline},
		allocator = chat.allocator,
		skills = chat_skill_catalog(chat),
		backend = definition.backend,
	}
	arguments := tool_arguments_prepare(staged.arguments, chat.allocator)
	defer tool_arguments_destroy(&arguments, chat.allocator)
	if arguments.status == .Rejected {
		return tool_result_refused(&ctx, &arguments.error), true
	}
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
	if _, dispatch_error := session.entry_append(chat.store, chat.id, dispatch); dispatch_error != nil {
		chat_session_record_failure(chat, "the tool dispatch could not be recorded", dispatch_error)
		return {}, false
	}
	return definition.execute(&ctx, object), true
}

// chat_record_tool_result appends the result entry a model later reads. It
// reports false when the write failed, which stops the turn: a call that ran and
// left no result is exactly the unanswered call the record must never have.
@(private)
chat_record_tool_result :: proc(chat: ^Chat_Session, staged: ^Chat_Tool_Call, result: ^Tool_Result) -> bool {
	error_text := ""
	if result.error.kind != .None { error_text = tool_argument_error_text(result.error, context.temp_allocator) }
	entry := session.New_Entry {
		turn_no = chat.turn_no,
		request_no = chat.active_request,
		created_at_ms = session.now_ms(),
		related_seq = staged.seq,
		payload = session.Tool_Result_Entry{outcome = result.outcome, error = error_text, content = result.content, origin = .Observed},
	}
	if _, append_error := session.entry_append(chat.store, chat.id, entry); append_error != nil {
		chat_session_record_failure(chat, "the tool result could not be recorded", append_error)
		return false
	}
	return true
}
