package agent

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sys/posix"

import "nabla:agent/session"
import "nabla:ai"

// Compaction is a memory operation: the full history stays in the store, one
// bounded summarization request produces a summary, and that summary becomes a
// checkpoint that stands in for everything it covers. History is never
// rewritten, so an evaluation of an old turn still sees exactly what happened.
CHAT_COMPACT_KEEP_MESSAGES :: 10
CHAT_COMPACT_MAX_OUTPUT :: 2000
CHAT_COMPACT_INSTRUCTIONS :: "Summarize the conversation so far in a few paragraphs for continued work. Preserve decisions, unresolved tasks, file paths, tool outcomes, and anything the next step depends on. Omit small talk. Plain text only. Name every loaded skill, the decisions made with it, and the paths it used. A summary never retains a complete skill verbatim: reload a skill before relying on its details."

// chat_compact_seam finds where the kept tail starts so the last keep entries
// stay verbatim. Coherence beats the count: the seam must not fall inside a
// call/result run, because a result kept without its call is malformed history
// and a call summarized without its result would be sent as an unanswered tool
// call. A seam on a call is coherent -- its result follows inside the tail -- so
// only a result, or a position whose predecessor is a call, moves the seam left.
chat_compact_seam :: proc(entries: []session.Entry, keep: int) -> int {
	if keep <= 0 { return len(entries) }
	seam := len(entries) - keep
	if seam < 0 { seam = 0 }
	for seam > 0 {
		if entries[seam].kind != .Tool_Result && entries[seam - 1].kind != .Tool_Call { break }
		seam -= 1
	}
	return seam
}

// Compact_Outcome collects what one summarization request produced. Usage is
// kept here rather than in the turn's log: a compaction is not a turn request,
// and its cost should not be folded into the request that follows it.
Compact_Outcome :: struct {
	text:       [dynamic]u8, // owned
	reason:     ai.Provider_Finish_Reason,
	calls:      int,
	failed:     bool,
	error_text: string, // owned
	usage:      session.Usage,
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
		delete(outcome.error_text, outcome.allocator)
		outcome.error_text = strings.clone(value.Message, outcome.allocator)
	case ai.Provider_Usage_Event:
		if value.Input_Tokens_Present { outcome.usage.input = value.Input_Tokens }
		if value.Output_Tokens_Present { outcome.usage.output = value.Output_Tokens }
		if value.Cached_Input_Tokens_Present { outcome.usage.cache_read = value.Cached_Input_Tokens }
		if value.Cache_Write_Tokens_Present { outcome.usage.cache_write = value.Cache_Write_Tokens }
	}
}

// chat_compact summarizes the part of the active context that the kept tail does
// not cover, records the summary as a checkpoint, and rebuilds prep from it.
// False leaves the context exactly as it was.
@(private)
chat_compact :: proc(
	chat: ^Chat_Session,
	observer: Chat_Observer,
	connection: ai.Provider_Connection,
	prep: ^Chat_Request_Prep,
	usages: ^[dynamic]Chat_Request_Usage,
) -> bool {
	_ = usages
	if chat.context_window <= 0 {
		_observer_message(observer, .Error, "compaction needs context_window: add context_window to the model in config.lua")
		return false
	}
	entries := prep.history.entries
	seam := chat_compact_seam(entries, CHAT_COMPACT_KEEP_MESSAGES)
	if seam <= 0 {
		_observer_message(observer, .Notice, "nothing to compact")
		return false
	}
	// The summary covers everything before the seam and the tail stays verbatim.
	covered := entries[seam - 1].seq

	compact_prep: Chat_Request_Prep
	chat_build_request_into(chat, &compact_prep, entries[:seam], prep.history.dispatches, prep.history.summary, connection, true)
	defer chat_request_prep_destroy(&compact_prep, chat.allocator)
	if compact_prep.estimate + CHAT_COMPACT_MAX_OUTPUT + CHAT_ADMISSION_MARGIN_TOKENS > chat.context_window {
		_observer_message(observer, .Error, "active context is too large to compact in one request; start a fresh session for a new topic")
		return false
	}

	at_ms := session.now_ms()
	request_no, begin_err := session.request_begin(
		chat.store,
		chat.id,
		{
			turn_no = chat.turn_no,
			purpose = .Compaction,
			provider = chat.provider_id,
			model_requested = chat.model_id,
			api = chat_api_name(connection.API),
			config_json = chat_request_config_json(chat, true),
			input_json = chat_request_input_json(chat, prep.history, seam, true),
		},
		at_ms,
	)
	if begin_err != nil {
		chat_session_record_failure(chat, "the compaction request could not be recorded", begin_err)
		return false
	}

	_observer_message(observer, .Notice, fmt.tprintf("compacting %d entries, keeping %d", seam, len(entries) - seam))
	outcome := Compact_Outcome {
		text      = make([dynamic]u8, 0, chat.allocator),
		allocator = chat.allocator,
	}
	defer delete(outcome.text)
	defer delete(outcome.error_text, chat.allocator)

	previous: posix.sigaction_t
	chat_signal_arm(&previous)
	defer chat_signal_disarm(&previous)
	options := ai.Provider_Operation_Options {
		interrupt = &chat_cancel,
		deadline  = ai.deadline_in(CHAT_OPERATION_DEADLINE),
	}
	operation_error := ai.Provider_Request_Operation_Controlled(connection, compact_prep.request, &outcome, chat_compact_event, options, chat.allocator)
	// The error owns its detail, and every path out of the attempt releases it.
	defer delete(operation_error.detail, chat.allocator)

	if chat_session_cancelled(chat) {
		chat_finish_compaction(chat, request_no, .Cancelled, outcome.usage, "cancelled")
		return false
	}
	if operation_error.kind != .None {
		_observer_message(observer, .Error, fmt.tprintf("compaction failed: %s", operation_error.detail))
		chat_finish_compaction(chat, request_no, .Failed, outcome.usage, operation_error.detail)
		return false
	}
	if outcome.failed {
		_observer_message(observer, .Error, fmt.tprintf("compaction failed: %s", outcome.error_text))
		chat_finish_compaction(chat, request_no, .Failed, outcome.usage, outcome.error_text)
		return false
	}
	if outcome.reason != .Stop || outcome.calls > 0 {
		_observer_message(observer, .Error, "compaction produced no usable summary")
		chat_finish_compaction(chat, request_no, .Failed, outcome.usage, "no usable summary")
		return false
	}
	summary_text := strings.trim_space(string(outcome.text[:]))
	if summary_text == "" {
		_observer_message(observer, .Error, "compaction produced no usable summary")
		chat_finish_compaction(chat, request_no, .Failed, outcome.usage, "no usable summary")
		return false
	}

	// The checkpoint and then the request's outcome. The checkpoint landing
	// first is what makes an interruption between them harmless: the summary is
	// valid, and recovery closes the request.
	_, checkpoint_err := session.checkpoint_append(
		chat.store,
		chat.id,
		{turn_no = chat.turn_no, request_no = request_no, at_ms = at_ms, summary = summary_text, covered_seq = covered},
	)
	if checkpoint_err != nil {
		chat_session_record_failure(chat, "the summary could not be recorded", checkpoint_err)
		return false
	}
	if finish_err := session.request_finish(chat.store, chat.id, request_no, {outcome = .Completed, usage = outcome.usage, at_ms = session.now_ms()});
	   finish_err != nil {
		chat_session_record_failure(chat, "the compaction outcome could not be recorded", finish_err)
		return false
	}

	// Rebuild from the new checkpoint so the caller re-admits against it.
	return chat_rebuild_prep(chat, connection, prep)
}

@(private)
chat_finish_compaction :: proc(chat: ^Chat_Session, request_no: session.Request_No, outcome: session.Outcome, usage: session.Usage, error_message: string) {
	error_json := ""
	if error_message != "" { error_json = chat_error_json(error_message) }
	if err := session.request_finish(chat.store, chat.id, request_no, {outcome = outcome, error_json = error_json, usage = usage, at_ms = session.now_ms()});
	   err != nil {
		chat_session_record_failure(chat, "the compaction outcome could not be recorded", err)
	}
}

// chat_build_compact is gone; the builder takes the span directly.

// chat_rebuild_prep discards prep's context and request and reads both again.
@(private)
chat_rebuild_prep :: proc(chat: ^Chat_Session, connection: ai.Provider_Connection, prep: ^Chat_Request_Prep) -> bool {
	session.context_destroy(&prep.history, chat.allocator)
	prep.history = {}
	chat_request_storage_destroy(prep, chat.allocator)

	ctx, context_err := session.context_load(chat.store, chat.id, chat.allocator)
	if context_err != nil {
		chat_session_record_failure(chat, "the compacted context could not be read", context_err)
		return false
	}
	prep.history = ctx
	chat_build_request_into(chat, prep, prep.history.entries, prep.history.dispatches, prep.history.summary, connection, false)
	return true
}

@(private)
chat_request_storage_destroy :: proc(prep: ^Chat_Request_Prep, allocator: mem.Allocator) {
	for &slot in prep.calls { delete(slot) }
	delete(prep.calls)
	delete(prep.tools)
	delete(prep.wire)
	for text in prep.feedback { delete(text, allocator) }
	delete(prep.feedback)
	delete(prep.cache_key, allocator)
	prep.calls = nil
	prep.tools = nil
	prep.wire = nil
	prep.feedback = nil
	prep.cache_key = ""
}

// chat_command_compact runs one manual compaction at a settled turn or a
// request boundary, where the context is coherent. Anything else refuses; a
// partial turn must settle first.
chat_command_compact :: proc(chat: ^Chat_Session, observer: Chat_Observer, connection: ai.Provider_Connection, usages: ^[dynamic]Chat_Request_Usage) -> bool {
	if chat.state != .Idle && chat.state != .Preparing {
		_observer_message(observer, .Error, "compaction needs a settled turn or a request boundary")
		return false
	}
	prep, prep_err := chat_prepare(chat, connection)
	if prep_err != nil {
		chat_session_record_failure(chat, "the context could not be read", prep_err)
		return false
	}
	defer chat_request_prep_destroy(&prep, chat.allocator)
	if !chat_compact(chat, observer, connection, &prep, usages) { return false }
	if chat_session_cancelled(chat) { chat_cancel_reset() }
	_observer_message(observer, .Notice, fmt.tprintf("compacted; %d entries remain in the active context", len(prep.history.entries)))
	return true
}
