package agent

import "nabla:agent/session"

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
