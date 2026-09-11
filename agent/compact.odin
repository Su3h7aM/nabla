package agent

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sys/posix"

import "nabla:ai"

// Compaction is a memory operation: the full history stays in the session,
// one bounded summarization request replaces the active context, and the
// replacement commits only after that request succeeds. Persistence across
// restarts is a separate job for later.
CHAT_COMPACT_KEEP_MESSAGES :: 10
CHAT_COMPACT_MAX_OUTPUT :: 2000
CHAT_COMPACT_INSTRUCTIONS :: "Summarize the conversation so far in a few paragraphs for continued work. Preserve decisions, unresolved tasks, file paths, tool outcomes, and anything the next step depends on. Omit small talk. Plain text only."

// chat_compact_seam finds where the kept tail starts so the last keep
// messages stay verbatim. Coherence beats the count: the seam must not fall
// inside a call/result run, because a result kept without its call is
// malformed history and a call summarized without its result would be sent as
// an unanswered tool call. A seam on a call is coherent -- its result follows
// inside the tail -- so only a result, or a position whose predecessor is a
// call, moves the seam left. A seam at active_start means nothing older than
// the kept tail is left to summarize.
chat_compact_seam :: proc(messages: []Chat_Message, active_start, keep: int) -> int {
	seam := len(messages) - keep
	if seam < active_start { seam = active_start }
	for seam > active_start {
		if messages[seam].role != .Tool && !messages[seam - 1].is_tool_call { break }
		seam -= 1
	}
	return seam
}

Compact_Outcome :: struct {
	text:       [dynamic]u8, // owned summary bytes,
	reason:     ai.Provider_Finish_Reason,
	calls:      int,
	failed:     bool,
	error_text: string, // owned,
	usages:     ^[dynamic]Chat_Request_Usage, // borrowed; nil skips logging,
	operation:  u64,
	allocator:  mem.Allocator,
}

chat_compact_event :: proc(user_data: rawptr, event: ai.Provider_Event) {
	outcome := cast(^Compact_Outcome)user_data
	#partial switch value in event {
	case ai.Provider_Text_Event:
		append(&outcome.text, value.Text)
	case ai.Provider_Reasoning_Event:
	case ai.Provider_Completed_Event:
		outcome.reason = value.Reason
		outcome.calls = len(value.Tool_Calls)
	case ai.Provider_Error_Event:
		outcome.failed = true
		if outcome.error_text != "" { delete(outcome.error_text, outcome.allocator) }
		outcome.error_text = strings.clone(value.Message, outcome.allocator)
	case ai.Provider_Usage_Event:
		if outcome.usages != nil {
			append(outcome.usages, Chat_Request_Usage{operation = outcome.operation, usage = value})
		}
	}
}

// chat_compact_active summarizes everything before the kept tail and moves
// the active window to the summary. False leaves history untouched.
chat_compact_active :: proc(
	session: ^Chat_Session,
	observer: Chat_Observer,
	connection: ai.Provider_Connection,
	model: string,
	usages: ^[dynamic]Chat_Request_Usage,
) -> bool {
	if session.context_window <= 0 {
		_observer_message(observer, .Error, "compaction needs context_window: add context_window to the model in config.lua")
		return false
	}
	seam := chat_compact_seam(session.messages[:], session.active_start, CHAT_COMPACT_KEEP_MESSAGES)
	if seam >= len(session.messages) {
		_observer_message(observer, .Notice, "nothing to compact")
		return false
	}
	// The seam bounds the summary: everything before it is replaced by the
	// summary, everything from it on stays in the active window verbatim. A seam
	// at the window start means there is nothing older than the kept tail -- the
	// whole active window is one call run or shorter than the tail -- so all of it
	// is summarized and the summary then stands alone.
	end := seam
	if end <= session.active_start { end = len(session.messages) }
	view := chat_request_view_clone(session.messages[:], 0, session.allocator)
	defer chat_request_view_destroy(&view)
	request, wire, tools_owned, call_lists := chat_build_request(session, view, connection, model, true, end)
	defer {
		for &slot in call_lists { delete(slot) }
		delete(call_lists)
		delete(tools_owned)
		delete(wire)
	}
	estimate := chat_estimate_input_tokens(wire[:], tools_owned[:])
	if estimate + CHAT_COMPACT_MAX_OUTPUT + CHAT_ADMISSION_MARGIN_TOKENS > session.context_window {
		_observer_message(observer, .Error, "active context is too large to compact in one request; start a fresh session for a new topic")
		return false
	}
	_observer_message(observer, .Notice, fmt.tprintf("compacting %d message(s), keeping %d", end - session.active_start, len(session.messages) - end))
	outcome := Compact_Outcome {
		text      = make([dynamic]u8, 0, session.allocator),
		operation = u64(session.requests_made),
		usages    = usages,
		allocator = session.allocator,
	}
	defer delete(outcome.text)
	defer delete(outcome.error_text, session.allocator)
	previous: posix.sigaction_t
	chat_signal_arm(&previous)
	defer chat_signal_disarm(&previous)
	deadline := ai.deadline_in(CHAT_OPERATION_DEADLINE)
	options := ai.Provider_Operation_Options {
		interrupt = &chat_cancel,
		deadline  = deadline,
	}
	operation_error := ai.Provider_Request_Operation_Controlled(connection, request, &outcome, chat_compact_event, options, session.allocator)
	if chat_session_cancelled(session) { return false }
	if operation_error.kind != .None {
		_observer_message(observer, .Error, fmt.tprintf("compaction failed: %s", operation_error.detail))
		return false
	}
	if outcome.failed {
		_observer_message(observer, .Error, fmt.tprintf("compaction failed: %s", outcome.error_text))
		return false
	}
	if outcome.reason != .Stop || outcome.calls > 0 {
		_observer_message(observer, .Error, "compaction produced no usable summary")
		return false
	}
	summary_text := strings.trim_space(string(outcome.text[:]))
	if summary_text == "" {
		_observer_message(observer, .Error, "compaction produced no usable summary")
		return false
	}
	chat_compact_commit(session, end, summary_text)
	return true
}

// chat_compact_commit installs a summary ahead of the kept tail and moves the
// active window onto it, so the active context becomes [summary] + [kept tail]
// and the newest exchange still reaches the model. History is never deleted:
// the summarized messages stay in the record behind the new window, which is
// also what lets a later compaction fold the previous summary into the new one.
chat_compact_commit :: proc(session: ^Chat_Session, end: int, summary_text: string) {
	summary := strings.concatenate([]string{"Summary of the conversation so far:\n", summary_text}, allocator = session.allocator)
	inject_at(&session.messages, end, Chat_Message{role = .Assistant, text = summary})
	session.active_start = end
}

// chat_command_compact runs one manual compaction at a settled turn or a
// request boundary, where the history is coherent. Anything else refuses;
// a partial turn must settle first.
chat_command_compact :: proc(
	session: ^Chat_Session,
	observer: Chat_Observer,
	connection: ai.Provider_Connection,
	model: string,
	usages: ^[dynamic]Chat_Request_Usage,
) -> bool {
	if session.state != .Idle && session.state != .Preparing {
		_observer_message(observer, .Error, "compaction needs a settled turn or a request boundary")
		return false
	}
	before := len(session.messages) - session.active_start
	if !chat_compact_active(session, observer, connection, model, usages) { return false }
	if chat_session_cancelled(session) { chat_cancel_reset() }
	_observer_message(observer, .Notice, fmt.tprintf("compacted %d message(s); %d active", before, len(session.messages) - session.active_start))
	return true
}

// chat_maybe_auto_compact runs the same operation once per turn when the
// request no longer fits or the window runs hot. True means the caller must
// rebuild and recount; the turn still fails if it cannot fit afterwards.
chat_maybe_auto_compact :: proc(
	session: ^Chat_Session,
	observer: Chat_Observer,
	connection: ai.Provider_Connection,
	model: string,
	usages: ^[dynamic]Chat_Request_Usage,
) -> bool {
	if session.context_window <= 0 { return false }
	if session.auto_compacted_turn == session.active_turn_id { return false }
	if len(session.messages) <= session.active_start { return false }
	session.auto_compacted_turn = session.active_turn_id
	if !chat_compact_active(session, observer, connection, model, usages) { return false }
	session.requests_made += 1
	return true
}
