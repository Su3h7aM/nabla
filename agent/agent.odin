package agent

import "core:fmt"
import "core:mem"

import "nabla:ai"

Chat_Effect_Kind :: enum {
	None,
	Start_Request,
	Publish_Text,
	Run_Tools,
	Turn_Finished,
}

Chat_Request_View :: struct {
	messages:  [dynamic]Chat_Message,
	operation: u64, // model request index within the turn,
	allocator: mem.Allocator,
}

Chat_Effect :: struct {
	kind:      Chat_Effect_Kind,
	turn_id:   u64,
	request:   Chat_Request_View,
	text:      string,
	status:    Chat_Terminal_Status,
	error:     string,
	allocator: mem.Allocator,
}

chat_effect_none :: proc() -> Chat_Effect { return Chat_Effect{kind = .None} }

chat_request_view_clone :: proc(messages: []Chat_Message, operation: u64, allocator: mem.Allocator) -> Chat_Request_View {
	result := Chat_Request_View {
		messages  = make([dynamic]Chat_Message, 0, len(messages), allocator),
		operation = operation,
		allocator = allocator,
	}
	for message in messages { append(&result.messages, chat_message_clone(message, allocator)) }
	return result
}

chat_request_view_destroy :: proc(request: ^Chat_Request_View) {
	for &message in request.messages { chat_message_destroy(&message, request.allocator) }
	delete(request.messages)
	request^ = {}
}

chat_effect_destroy :: proc(effect: ^Chat_Effect) {
	chat_request_view_destroy(&effect.request)
	delete(effect.text, effect.allocator)
	delete(effect.error, effect.allocator)
	effect^ = {}
}

chat_session_advance :: proc(session: ^Chat_Session) -> Chat_Effect {
	switch session.state {
	case .Idle, .Requesting, .Streaming:
		return chat_effect_none()
	case .Executing_Tools:
		return Chat_Effect{kind = .Run_Tools, turn_id = session.active_turn_id, allocator = session.allocator}
	case .Preparing:
		if session.requests_made >= TOOL_MAX_REQUESTS_PER_TURN {
			return chat_session_fail_turn(session, "tool loop budget exhausted")
		}
		// The turn bound is observed here, at an operation boundary, because a running
		// request cannot be preempted by a single-threaded control loop.
		if ai.deadline_expired(session.turn_deadline) {
			return chat_session_fail_turn(session, "turn deadline exceeded")
		}
		session.requests_made += 1
		session.state = .Requesting
		return Chat_Effect {
			kind = .Start_Request,
			turn_id = session.active_turn_id,
			request = chat_request_view_clone(session.messages[:], u64(session.requests_made), session.allocator),
			allocator = session.allocator,
		}
	case .Cancelling:
		// Cancellation requested interruption; it did not stop anything. A cancelled
		// turn finalizes only after its operation is retired, which is the
		// confirmation that the request is no longer running.
		if session.operation.state == .Running { return chat_effect_none() }
		return chat_finalize_turn(session, .Cancelled, "")
	case .Finalizing:
		if session.active_failed { return chat_finalize_turn(session, .Failed, session.last_error) }
		return chat_finalize_turn(session, .Completed, "")
	}
	return chat_effect_none()
}

// chat_session_fail_turn records a turn-level failure and moves to finalizing.
chat_session_fail_turn :: proc(session: ^Chat_Session, message: string) -> Chat_Effect {
	delete(session.last_error, session.allocator)
	session.last_error = chat_clone_string(message, session.allocator)
	session.active_failed = true
	session.state = .Finalizing
	return chat_effect_none()
}

// chat_finalize_turn is the only place a turn reaches a terminal status. Every
// terminal path goes through it and it returns the session to Idle in the same
// step, so a turn finalizes exactly once and the next turn can start immediately.
chat_finalize_turn :: proc(session: ^Chat_Session, status: Chat_Terminal_Status, error: string) -> Chat_Effect {
	turn_id := session.active_turn_id
	// Only a completed response is a complete assistant message. A cancelled or
	// failed turn may have produced partial text, and committing that would invent
	// a response the model never finished.
	if status == .Completed {
		append(&session.messages, Chat_Message{role = .Assistant, text = chat_clone_string(string(session.partial_assistant[:]), session.allocator)})
	}
	session.terminal_status = status
	session.state = .Idle
	session.active_failed = false
	delete(session.partial_assistant)
	session.partial_assistant = make([dynamic]u8, 0, 0, session.allocator)
	return Chat_Effect {
		kind = .Turn_Finished,
		turn_id = turn_id,
		status = status,
		error = chat_clone_string(error, session.allocator),
		allocator = session.allocator,
	}
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

chat_session_feed_text :: proc(session: ^Chat_Session, source: Chat_Event_Source, text: string) -> Chat_Effect {
	if !chat_session_accepts_event(session, source) { return chat_effect_none() }
	if session.state == .Requesting { session.state = .Streaming }
	append(&session.partial_assistant, text)
	return Chat_Effect{kind = .Publish_Text, turn_id = source.turn_id, text = chat_clone_string(text, session.allocator), allocator = session.allocator}
}

chat_session_feed_completion :: proc(session: ^Chat_Session, source: Chat_Event_Source) -> bool {
	if !chat_session_accepts_event(session, source) { return false }
	session.state = .Finalizing
	return true
}

// chat_session_feed_reasoning stores one opaque reasoning item in wire order.
// The id is the replay key; a repeated id is the same item seen twice, not a
// second item.
chat_session_feed_reasoning :: proc(session: ^Chat_Session, source: Chat_Event_Source, id, encrypted: string) -> bool {
	if !chat_session_accepts_event(session, source) { return false }
	if id == "" { return false }
	for message in session.messages {
		if message.is_reasoning && message.reasoning_id == id { return true }
	}
	append(
		&session.messages,
		Chat_Message {
			role = .Assistant,
			is_reasoning = true,
			reasoning_id = chat_clone_string(id, session.allocator),
			reasoning_encrypted = chat_clone_string(encrypted, session.allocator),
		},
	)
	return true
}

// chat_session_set_effort validates a level against the model's configured
// levels and applies it to the next request. An empty level clears the
// override back to provider default. Effort never touches in-flight work:
// the builder copies the selection when it freezes each request.
chat_session_set_effort :: proc(session: ^Chat_Session, level: string) -> bool {
	if level == "" {
		delete(session.effort, session.allocator)
		session.effort = ""
		return true
	}
	for allowed in session.effort_levels {
		if allowed == level {
			delete(session.effort, session.allocator)
			session.effort = chat_clone_string(level, session.allocator)
			return true
		}
	}
	return false
}

// chat_session_steer appends a queued line as a user message at a request
// boundary. Unlike accept_user it starts no turn and resets no budget: the
// turn keeps its id and its counters, so steering changes what the next
// request sends, never work already committed. Only Preparing is safe;
// anywhere else the line is dropped by the caller.
chat_session_steer :: proc(session: ^Chat_Session, text: string) -> bool {
	if session.state != .Preparing { return false }
	append(&session.messages, Chat_Message{role = .User, text = chat_clone_string(text, session.allocator)})
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

chat_session_feed_tool_calls :: proc(session: ^Chat_Session, source: Chat_Event_Source, calls: []ai.Provider_Tool_Call) -> bool {
	if !chat_session_accepts_event(session, source) { return false }
	if len(calls) == 0 || len(calls) > TOOL_MAX_CALLS_PER_RESPONSE { return false }
	if session.calls_made + len(calls) > TOOL_MAX_CALLS_PER_TURN { return false }
	staged := make([dynamic]Chat_Tool_Call, 0, len(calls), session.allocator)
	defer delete(staged)
	for call in calls {
		cloned, valid := chat_tool_call_clone(call, session.allocator)
		if !valid {
			for &leftover in staged { chat_tool_call_destroy(&leftover, session.allocator) }
			return false
		}
		duplicate := false
		for message in session.messages {
			if message.is_tool_call && message.tool_call.id == cloned.id { duplicate = true }
		}
		for prior in staged {
			if prior.id == cloned.id { duplicate = true }
		}
		if duplicate {
			chat_tool_call_destroy(&cloned, session.allocator)
			for &leftover in staged { chat_tool_call_destroy(&leftover, session.allocator) }
			return false
		}
		append(&staged, cloned)
	}
	if len(string(session.partial_assistant[:])) > 0 {
		append(&session.messages, Chat_Message{role = .Assistant, text = chat_clone_string(string(session.partial_assistant[:]), session.allocator)})
		delete(session.partial_assistant)
		session.partial_assistant = make([dynamic]u8, 0, 0, session.allocator)
	}
	for staged_call in staged {
		pending, _ := chat_tool_call_clone(
			ai.Provider_Tool_Call{ID = staged_call.id, Item_ID = staged_call.item_id, Name = staged_call.name, Arguments = staged_call.arguments},
			session.allocator,
		)
		append(&session.pending_calls, pending)
		append(&session.messages, Chat_Message{role = .Assistant, is_tool_call = true, tool_call = staged_call})
	}
	clear(&staged)
	session.state = .Executing_Tools
	return true
}

chat_session_tools_done :: proc(session: ^Chat_Session, turn_id: u64, results: int) -> bool {
	// A cancelled turn still resolves its committed calls, so its history stays
	// well formed even though no further request will be made.
	if session.state != .Executing_Tools && session.state != .Cancelling { return false }
	if session.active_turn_id != turn_id { return false }
	if results != len(session.pending_calls) { return false }
	session.calls_made += len(session.pending_calls)
	for &call in session.pending_calls { chat_tool_call_destroy(&call, session.allocator) }
	clear(&session.pending_calls)
	// A cancelled turn resolves its committed calls but must not continue to another
	// request, so it stays in Cancelling for the finalization owner.
	if session.state == .Executing_Tools { session.state = .Preparing }
	return true
}

chat_session_feed_error :: proc(session: ^Chat_Session, source: Chat_Event_Source, message: string) -> bool {
	if !chat_session_accepts_event(session, source) { return false }
	delete(session.last_error, session.allocator)
	session.last_error = chat_clone_string(message, session.allocator)
	session.active_failed = true
	session.state = .Finalizing
	return true
}
