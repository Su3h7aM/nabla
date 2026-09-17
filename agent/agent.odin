package agent

import "core:fmt"
import "core:mem"

import "nabla:agent/session"
import "nabla:ai"

Chat_Effect_Kind :: enum {
	None,
	Start_Request,
	Run_Tools,
	Turn_Finished,
}

// Chat_Effect is what the current state wants done next. It carries no stored
// data: the driver reads the committed record when it runs an effect and writes
// the record when the effect settles.
Chat_Effect :: struct {
	kind:      Chat_Effect_Kind,
	turn_id:   u64,
	status:    Chat_Terminal_Status,
	error:     string, // owned
	allocator: mem.Allocator,
}

chat_effect_none :: proc() -> Chat_Effect { return Chat_Effect{kind = .None} }

chat_effect_destroy :: proc(effect: ^Chat_Effect) {
	delete(effect.error, effect.allocator)
	effect^ = {}
}

// chat_session_advance is the control decision for the current state. It touches
// nothing durable: the driver runs the effect and records what happened.
chat_session_advance :: proc(chat: ^Chat_Session) -> Chat_Effect {
	switch chat.state {
	case .Idle, .Requesting, .Streaming:
		return chat_effect_none()
	case .Executing_Tools:
		return Chat_Effect{kind = .Run_Tools, turn_id = chat.active_turn_id, allocator = chat.allocator}
	case .Preparing:
		// The turn bound is observed here, at an operation boundary, because a running
		// request cannot be preempted by a single-threaded control loop.
		if ai.deadline_expired(chat.turn_deadline) {
			return chat_session_fail_turn(chat, "turn deadline exceeded")
		}
		chat.requests_made += 1
		chat.state = .Requesting
		return Chat_Effect{kind = .Start_Request, turn_id = chat.active_turn_id, allocator = chat.allocator}
	case .Cancelling:
		// Cancellation requested interruption; it did not stop anything. A cancelled
		// turn finalizes only after its operation is retired, which is the
		// confirmation that the request is no longer running.
		if chat.operation.state == .Running { return chat_effect_none() }
		return chat_finalize_turn(chat, .Cancelled, "")
	case .Finalizing:
		if chat.active_failed { return chat_finalize_turn(chat, .Failed, chat.last_error) }
		return chat_finalize_turn(chat, .Completed, "")
	}
	return chat_effect_none()
}

// chat_session_fail_turn records a turn-level failure and moves to finalizing.
chat_session_fail_turn :: proc(chat: ^Chat_Session, message: string) -> Chat_Effect {
	delete(chat.last_error, chat.allocator)
	chat.last_error = chat_clone_string(message, chat.allocator)
	chat.active_failed = true
	chat.state = .Finalizing
	return chat_effect_none()
}

// chat_finalize_turn is the only place a turn reaches a terminal status. Every
// terminal path goes through it and it returns the session to Idle in the same
// step, so a turn finalizes exactly once and the next turn can start immediately.
//
// Uncommitted assistant text is not dropped here; the driver records it as a
// partial entry when it settles the turn.
chat_finalize_turn :: proc(chat: ^Chat_Session, status: Chat_Terminal_Status, error: string) -> Chat_Effect {
	turn_id := chat.active_turn_id
	chat.terminal_status = status
	chat.state = .Idle
	chat.active_failed = false
	return Chat_Effect{kind = .Turn_Finished, turn_id = turn_id, status = status, error = chat_clone_string(error, chat.allocator), allocator = chat.allocator}
}

chat_terminal_text :: proc(status: Chat_Terminal_Status) -> string {
	switch status {
	case .None:
		return "no status"
	case .Completed:
		return "completed"
	case .Failed:
		return "request failed"
	case .Cancelled:
		return "turn cancelled"
	}
	return "no status"
}

chat_report_terminal :: proc(observer: Chat_Observer, finish: Chat_Effect) {
	if finish.status == .Completed {
		_observer_assistant_end(observer)
		return
	}
	if finish.error != "" {
		_observer_message(observer, .Error, fmt.tprintf("%s: %s", chat_terminal_text(finish.status), finish.error))
	} else {
		_observer_message(observer, .Error, chat_terminal_text(finish.status))
	}
}

// chat_session_feed_text accepts a streamed fragment and returns whether it
// belongs to the running request.
chat_session_feed_text :: proc(chat: ^Chat_Session, source: Chat_Event_Source, text: string) -> bool {
	if !chat_session_accepts_event(chat, source) { return false }
	if chat.state == .Requesting { chat.state = .Streaming }
	append(&chat.partial_assistant, text)
	return true
}

chat_session_feed_completion :: proc(chat: ^Chat_Session, source: Chat_Event_Source) -> bool {
	if !chat_session_accepts_event(chat, source) { return false }
	chat.state = .Finalizing
	return true
}

// chat_session_feed_response_output stages the verbatim Responses output array
// for the response being assembled. The output is the replay record; display
// text and executable calls travel through their own feeds alongside it.
// Only the Responses API calls this; Chat Completions has no replayable
// output items to preserve.
chat_session_feed_response_output :: proc(chat: ^Chat_Session, source: Chat_Event_Source, output: string) -> bool {
	if !chat_session_accepts_event(chat, source) { return false }
	if output == "" { return true }
	if chat.pending_response_present { return false }
	chat.pending_response.output = chat_clone_string(output, chat.allocator)
	chat.pending_response_present = true
	return true
}

// chat_session_set_effort validates a level against the model's configured
// levels and applies it to the next request. An empty level clears the
// override back to provider default. Effort never touches in-flight work:
// the builder copies the selection when it freezes each request.
chat_session_set_effort :: proc(chat: ^Chat_Session, level: string) -> bool {
	if level == "" {
		delete(chat.effort, chat.allocator)
		chat.effort = ""
		return true
	}
	for allowed in chat.effort_levels {
		if allowed == level {
			delete(chat.effort, chat.allocator)
			chat.effort = chat_clone_string(level, chat.allocator)
			return true
		}
	}
	return false
}

// chat_session_steer records a queued line as a user entry at a request
// boundary. Unlike accept_user it starts no turn and resets no budget: the turn
// keeps its identity and its counters, so steering changes what the next request
// sends, never work already committed. Only Preparing is safe; anywhere else the
// line is dropped by the caller.
chat_session_steer :: proc(chat: ^Chat_Session, text: string, at_ms: i64) -> bool {
	if chat.state != .Preparing { return false }
	entry := session.New_Entry {
		turn_no = chat.turn_no,
		created_at_ms = at_ms,
		payload = session.User_Entry{text = text, origin = .Steering},
	}
	if _, err := session.entry_append(chat.store, chat.id, entry); err != nil {
		chat_session_record_failure(chat, "the steering line could not be recorded", err)
		return false
	}
	return true
}

chat_tool_call_clone :: proc(call: ai.Provider_Tool_Call, allocator: mem.Allocator) -> (Chat_Tool_Call, bool) {
	if call.ID == "" || call.Name == "" { return {}, false }
	return Chat_Tool_Call {
			id = chat_clone_string(call.ID, allocator),
			item_id = chat_clone_string(call.Item_ID, allocator),
			name = chat_clone_string(call.Name, allocator),
			arguments = chat_clone_string(call.Arguments, allocator),
		},
		true
}

// Chat_Notice is why a completed response could not be used as it stood. None
// means it was usable, and Ignored means the event did not belong to the running
// operation and nothing should happen at all. Every other member is a defect the
// model is told about: the response executes nothing, and the turn goes on to
// another request so the model can correct itself.
Chat_Notice :: enum {
	None,
	Ignored,
	Truncated,
	Missing_Call_Identity,
	Duplicate_Call_ID,
}

// chat_notice_text is the harness's own explanation of an unusable response. The
// text is a literal: the same notice always puts the same bytes into the
// conversation, so a recovery turn adds no avoidable churn to the cacheable
// prefix.
chat_notice_text :: proc(notice: Chat_Notice) -> string {
	switch notice {
	case .Truncated:
		return "the previous response was cut off by the output limit before it finished, so none of it was executed; reissue the work in smaller steps"
	case .Missing_Call_Identity:
		return "a proposed tool call carried no id or no tool name, so none of the calls ran; every call needs the provider's id and the tool's name"
	case .Duplicate_Call_ID:
		return "two proposed tool calls shared one id, so none of them ran; every call needs its own id"
	case .None, .Ignored:
		return ""
	}
	return ""
}

// chat_session_note_notice records that the running response was unusable and
// moves the turn on to another request. The notice itself is committed with the
// response that caused it, so the explanation follows the text it explains.
chat_session_note_notice :: proc(chat: ^Chat_Session, source: Chat_Event_Source, notice: Chat_Notice) -> bool {
	if !chat_session_accepts_event(chat, source) { return false }
	chat.pending_notice = notice
	chat.state = .Preparing
	return true
}

// chat_session_feed_tool_calls validates the calls a response assembled and
// stages them for execution. It reports None when they were staged, Ignored when
// the event did not belong to the running operation, and otherwise why the whole
// response was refused: calls are staged all at once or not at all, so a
// response is never half executed.
chat_session_feed_tool_calls :: proc(chat: ^Chat_Session, source: Chat_Event_Source, calls: []ai.Provider_Tool_Call) -> Chat_Notice {
	if !chat_session_accepts_event(chat, source) { return .Ignored }
	if len(calls) == 0 { return .Ignored }

	staged := make([dynamic]Chat_Tool_Call, 0, len(calls), chat.allocator)
	defer delete(staged)
	for call in calls {
		cloned, valid := chat_tool_call_clone(call, chat.allocator)
		if !valid {
			for &leftover in staged { chat_tool_call_destroy(&leftover, chat.allocator) }
			return .Missing_Call_Identity
		}
		for prior in staged {
			if prior.id == cloned.id {
				chat_tool_call_destroy(&cloned, chat.allocator)
				for &leftover in staged { chat_tool_call_destroy(&leftover, chat.allocator) }
				return .Duplicate_Call_ID
			}
		}
		append(&staged, cloned)
	}
	for staged_call in staged { append(&chat.pending_calls, staged_call) }
	clear(&staged)
	chat.state = .Executing_Tools
	return .None
}

chat_session_tools_done :: proc(chat: ^Chat_Session, turn_id: u64, results: int) -> bool {
	// A cancelled turn still resolves its committed calls, so its history stays
	// well formed even though no further request will be made.
	if chat.state != .Executing_Tools && chat.state != .Cancelling { return false }
	if chat.active_turn_id != turn_id { return false }
	if results != len(chat.pending_calls) { return false }
	chat.calls_made += len(chat.pending_calls)
	for &call in chat.pending_calls { chat_tool_call_destroy(&call, chat.allocator) }
	clear(&chat.pending_calls)
	// A cancelled turn resolves its committed calls but must not continue to another
	// request, so it stays in Cancelling for the finalization owner.
	if chat.state == .Executing_Tools { chat.state = .Preparing }
	return true
}

chat_session_feed_error :: proc(chat: ^Chat_Session, source: Chat_Event_Source, message: string) -> bool {
	if !chat_session_accepts_event(chat, source) { return false }
	delete(chat.last_error, chat.allocator)
	chat.last_error = chat_clone_string(message, chat.allocator)
	chat.active_failed = true
	chat.state = .Finalizing
	return true
}
