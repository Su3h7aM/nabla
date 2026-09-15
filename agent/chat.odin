package agent

import "core:encoding/json"
import "core:fmt"
import "core:sys/posix"
import "core:time"

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
	// Reasoning never displays, and it needs no staging: on the Responses
	// API the verbatim output array is the replay record, and Chat
	// Completions has no representation for it at all.
	case ai.Provider_Completed_Event:
		// One response feeds one path: tool handoff when the provider
		// assembled calls, plain completion on stop, failure otherwise.
		// A length limit or content filter is not a usable answer, so it
		// must not finalize as success. Partial argument fragments never
		// reach the executor; only this validated event carries
		// executable calls. The verbatim output array is staged for the
		// commit below, which stores it as the replay record.
		runtime.finish_reason = value.Reason
		if !chat_session_feed_response_output(runtime.chat, runtime.source, value.Raw_Output) {
			chat_session_feed_error(runtime.chat, runtime.source, "tool response was rejected")
		} else if value.Reason == .Tool_Call && len(value.Tool_Calls) > 0 {
			notice := chat_session_feed_tool_calls(runtime.chat, runtime.source, value.Tool_Calls)
			if notice != .None && notice != .Ignored {
				// The response proposed calls the harness cannot use. Executing
				// nothing and telling the model why keeps the turn alive.
				chat_session_note_notice(runtime.chat, runtime.source, notice)
			}
		} else if value.Reason == .Stop {
			chat_session_feed_completion(runtime.chat, runtime.source)
		} else if value.Reason == .Length {
			chat_session_note_notice(runtime.chat, runtime.source, .Truncated)
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

// --- running a request -------------------------------------------------------

// chat_perform_request builds one request from committed history, records it,
// runs it, and records what came back. The record exists before the model is
// asked anything, so a request that never finishes still says what it carried.
@(private)
chat_perform_request :: proc(chat: ^Chat_Session, connection: ai.Provider_Connection, observer: Chat_Observer, usages: ^[dynamic]Chat_Request_Usage) {
	if chat.skill_instructions == "" && !chat_ensure_instructions(chat) { return }
	prep, prep_err := chat_prepare(chat, connection)
	if prep_err != nil {
		chat_session_record_failure(chat, "the request context could not be read", prep_err)
		return
	}
	defer chat_request_prep_destroy(&prep, chat.allocator)

	// A request that does not fit compacts once and recounts; one that still does
	// not fit fails here, before any byte is sent. Compaction is deliberately not
	// eager: it rewrites the active context, which discards the prefix the
	// provider has cached and pays for a summarization request, so it happens
	// when a request would otherwise be refused and not before. A turn that
	// keeps growing can therefore compact more than once, and each time it does
	// the alternative was failing.
	message, admitted := chat_admission_check(chat, prep.estimate)
	if !admitted {
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
			input_json = chat_request_input_json(&prep, &prep.history, chat.skill_snapshot_seq, len(prep.history.entries), false),
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
	// One request may be attempted more than once. A retry happens only while
	// nothing has been exposed to the model, so the conversation the next request
	// is built from is the same one, and the model never learns that an attempt
	// failed. The operation and its deadline span every attempt, so the turn bound
	// caps the total.
	attempts := 0
	operation_error: ai.Provider_Operation_Error
	for {
		attempts += 1
		operation_error = ai.Provider_Request_Operation_Controlled(connection, prep.request, &runtime, chat_provider_event, options, chat.allocator)
		if !chat_request_may_retry(chat, operation_error, attempts) { break }
		_observer_message(observer, .Notice, chat_retry_notice(attempts, operation_error))
		if !chat_retry_wait(chat, chat_retry_delay(attempts)) { break }
		chat_session_clear_attempt(chat)
		delete(operation_error.detail, chat.allocator)
		operation_error = {}
	}
	chat.request_attempts = attempts
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
// ended. A completed response becomes entries: the verbatim Responses output
// when the API produced one, then any text, then the calls it proposed. A
// failed or cancelled one records only its outcome here; the text it produced
// becomes a partial entry when the turn settles, because an unfinished answer
// must never be replayed as a finished one.
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
		response_count := 1 if chat.pending_response_present else 0
		notice_text := chat_notice_text(chat.pending_notice)
		entries: [dynamic]session.New_Entry = make([dynamic]session.New_Entry, 0, response_count + len(chat.pending_calls) + 2, chat.allocator)
		defer delete(entries)
		if chat.pending_response_present {
			append(
				&entries,
				session.New_Entry {
					turn_no = chat.turn_no,
					request_no = request_no,
					created_at_ms = at_ms,
					payload = session.Response_Entry{output = chat.pending_response.output},
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
		// The harness's explanation of an unusable response is committed with the
		// response itself, after whatever text it produced.
		if notice_text != "" {
			append(
				&entries,
				session.New_Entry {
					turn_no = chat.turn_no,
					request_no = request_no,
					created_at_ms = at_ms,
					payload = session.User_Entry{text = notice_text, origin = .Harness},
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
		offset := response_count + (1 if text != "" else 0)
		for i in 0 ..< len(chat.pending_calls) { chat.pending_calls[i].seq = seqs[offset + i] }
		delete(seqs, chat.allocator)

		chat_response_output_destroy(&chat.pending_response, chat.allocator)
		chat.pending_response_present = false
		delete(chat.partial_assistant)
		chat.partial_assistant = make([dynamic]u8, 0, 0, chat.allocator)
	}
	// A notice is only ever committed with the response that raised it. One that
	// did not commit, because the turn failed or was cancelled, is dropped.
	chat.pending_notice = .None

	response_json := ""
	if finish_reason != .Unknown {
		response_json = string(
			json.marshal(
				Chat_Request_Response{reason = chat_finish_reason_text(finish_reason), attempts = chat.request_attempts},
				allocator = context.temp_allocator,
			) or_else nil,
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

// --- settling a turn ---------------------------------------------------------

// chat_persist_turn_end records the turn's outcome and keeps whatever text the
// turn produced but never committed. That text is marked partial, so it is
// evidence in the record and never a finished answer in a later request.
//
// It reports whether every write landed. A turn whose outcome did not reach the
// store must not be reported as the status the model reached, because that would
// claim a record the database does not have.
@(private)
chat_persist_turn_end :: proc(chat: ^Chat_Session, effect: Chat_Effect) -> (recorded: bool) {
	turn_no, has_turn := chat.turn_no.?
	if !has_turn { return true }
	at_ms := session.now_ms()
	recorded = true

	if text := string(chat.partial_assistant[:]); text != "" {
		entry := session.New_Entry {
			turn_no = turn_no,
			created_at_ms = at_ms,
			payload = session.Assistant_Entry{text = text, partial = true},
		}
		if _, append_err := session.entry_append(chat.store, chat.id, entry); append_err != nil {
			chat_session_record_failure(chat, "the partial answer could not be recorded", append_err)
			recorded = false
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
		recorded = false
	}
	chat.turn_no = nil
	chat.active_request = nil
	// A turn that ended without running its staged calls, such as one a durable
	// write stopped, releases them here.
	chat_pending_calls_clear(chat)
	chat_response_output_destroy(&chat.pending_response, chat.allocator)
	chat.pending_response_present = false
	return recorded
}

// CHAT_REQUEST_MAX_ATTEMPTS bounds how many times one request is sent. A retried
// request reuses the same prepared bytes and the same operation, so the turn
// bound and the record both span every attempt.
CHAT_REQUEST_MAX_ATTEMPTS :: 3
CHAT_RETRY_BASE_DELAY :: 500 * time.Millisecond
CHAT_RETRY_MAX_DELAY :: 8 * time.Second
CHAT_RETRY_SLICE :: 50 * time.Millisecond

// chat_request_may_retry decides whether a failed attempt is followed by
// another. Every reason is explicit: the failure has to be one that could
// succeed on identical bytes, nothing may have been exposed, the turn must not be
// stopping, and there has to be an attempt left.
@(private)
chat_request_may_retry :: proc(chat: ^Chat_Session, err: ai.Provider_Operation_Error, attempts: int) -> bool {
	if err.kind == .None { return false }
	if chat_session_cancelled(chat) { return false }
	if attempts >= CHAT_REQUEST_MAX_ATTEMPTS { return false }
	if !chat_request_retryable(err) { return false }
	return !chat_request_output_exposed(chat)
}

// chat_request_retryable says whether sending the same bytes again could
// succeed. Only a transport that never reached a usable response, or a status
// that providers use for overload and throttling, qualifies. A refusal, a bad
// request, an unauthenticated peer, and an expired deadline are deterministic:
// the same bytes would fail the same way.
@(private)
chat_request_retryable :: proc(err: ai.Provider_Operation_Error) -> bool {
	switch err.kind {
	case .None, .Invalid_Request, .Cancelled, .Timed_Out, .TLS:
		return false
	case .Transport, .Stream:
		return true
	case .HTTP:
		return err.status == 408 || err.status == 409 || err.status == 429 || err.status >= 500
	}
	return false
}

// chat_request_output_exposed reports whether the failed attempt produced
// anything the model or the user could have seen. Once it has, a retry would
// duplicate output, so the failure is reported instead.
@(private)
chat_request_output_exposed :: proc(chat: ^Chat_Session) -> bool {
	return len(chat.partial_assistant) > 0 || len(chat.pending_calls) > 0 || chat.pending_response_present
}

// chat_retry_notice is the line a retry reports to the front-end. It is a
// diagnostic for whoever is watching the turn, never conversation: the model is
// told nothing about an attempt it never saw.
@(private)
chat_retry_notice :: proc(attempt: int, err: ai.Provider_Operation_Error) -> string {
	if err.status != 0 { return fmt.tprintf("attempt %d did not complete (status %d); retrying", attempt, err.status) }
	return fmt.tprintf("attempt %d did not complete; retrying", attempt)
}

@(private)
chat_retry_delay :: proc(attempt: int) -> time.Duration {delay := CHAT_RETRY_BASE_DELAY
	for _ in 1 ..< attempt {
		delay *= 2
		if delay >= CHAT_RETRY_MAX_DELAY { return CHAT_RETRY_MAX_DELAY }
	}
	return delay
}

// chat_retry_wait sleeps out one backoff delay. It waits in slices and checks
// cancellation and the operation deadline between them, so a retry never delays
// a turn that is being stopped.
@(private)
chat_retry_wait :: proc(chat: ^Chat_Session, delay: time.Duration) -> bool {
	remaining := delay
	for remaining > 0 {
		if chat_session_cancelled(chat) { return false }
		if ai.deadline_expired(chat.operation.deadline) { return false }
		slice := CHAT_RETRY_SLICE
		if remaining < slice { slice = remaining }
		time.sleep(slice)
		remaining -= slice
	}
	return true
}

// chat_session_clear_attempt forgets the failure of an attempt that exposed
// nothing, so the next attempt starts as if it were the first. Only a retry that
// is about to happen calls it, and only while the operation is still running.
chat_session_clear_attempt :: proc(chat: ^Chat_Session) {
	if chat.operation.state != .Running { return }
	delete(chat.last_error, chat.allocator)
	chat.last_error = ""
	chat.active_failed = false
	chat.state = .Requesting
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
	// quit, when not nil, is set by a queued line that asks the session to end.
	// A caller with no such flag leaves it nil; the line is then reported and
	// ignored rather than dereferenced.
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
			// A turn whose outcome did not reach the store reports the storage failure,
			// not the status the model reached: the session has no record of it.
			if !chat_persist_turn_end(chat, effect) {
				delete(effect.error, effect.allocator)
				effect.error = chat_clone_string(chat.last_error, effect.allocator)
				effect.status = .Failed
			}
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
	switch api {
	case .OpenAI_Chat_Completions, .OpenAI_Responses, .Anthropic_Messages:
		return true
	case .Invalid:
	}
	return false
}
