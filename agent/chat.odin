package agent

import "core:encoding/json"
import "core:fmt"
import "core:log"
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

// Chat_Request_Usage is one usage report the endpoint sent, keyed by the send that
// produced it. A send is one operation, so a report is attributed to the attempt
// that received it rather than to the request as a whole.
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
			calls := make([dynamic]ai.Provider_Tool_Call, 0, len(value.Tool_Calls), context.temp_allocator)
			defer delete(calls)
			for call in value.Tool_Calls {
				wire_call := call
				wire_call.Name = chat_tool_canonical_name(&runtime.chat.tools, wire_call.Name)
				// The name the model sent and the name the harness resolved it to are
				// two different facts, and a mismatch is what a rejected tool name
				// looks like from here.
				resolved: Log_Binding
				context.logger = log_rebind(&resolved, log_correlation_for_call(runtime.chat, call.ID))
				fields := [2]Log_Field{{key = "wire_name", value = call.Name}, {key = "tool", value = wire_call.Name}}
				log_emit({level = .Info, category = .Tool, event = "tool.name_resolved", fields = fields[:]})
				append(&calls, wire_call)
			}
			notice := chat_session_feed_tool_calls(runtime.chat, runtime.source, calls[:])
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
			append(runtime.usage_log, Chat_Request_Usage{operation = u64(runtime.chat.operation.id), usage = value})
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
	// This request has no durable number yet, and the one the previous request
	// left behind is not its own. Clearing it here is what keeps the preparation
	// records from naming the wrong request; the number is set again from what
	// request_begin returns. The tool loop has already recorded the previous
	// request's calls by now, so nothing else needs the old value.
	chat.active_request = nil
	// This request's correlation is narrowed once and refreshed as each identity
	// becomes durable: the request number after request_begin, the attempt inside
	// the retry loop. Nothing here invents an identity before it exists.
	binding: Log_Binding
	context.logger = log_rebind(&binding, log_correlation(chat))

	// A finished summary is installed at a request boundary, so the context the
	// request is built from is the one this session will actually send.
	_ = chat_compact_service(chat, observer)

	prep, prep_err := chat_prepare(chat, connection)
	if prep_err != nil {
		chat_session_record_failure(chat, "the request context could not be read", prep_err)
		return
	}
	defer chat_request_prep_destroy(&prep, chat.allocator)

	// The exact request about to be sent is what a compaction freezes, so it is
	// considered here, after the boundary above and before admission decides
	// anything. Compaction never runs in the foreground: this only starts a
	// background job for a context that is filling up.
	chat_compact_consider(chat, observer, connection, &prep)

	// A request that does not fit is refused unless a summary that already finished
	// can be installed right now. Nothing waits for compaction: a request that still
	// does not fit fails explicitly, and the turn is told why.
	message, admitted := chat_admission_check(chat, prep.estimate)
	if !admitted {
		if chat_compact_relieve(chat, observer) && !chat_session_cancelled(chat) {
			if !chat_rebuild_prep(chat, connection, &prep) { return }
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

	// The bytes this request sends are frozen once, before the first attempt, so every
	// attempt of the chain sends exactly what the first would have sent instead of a
	// fresh encoding that has to be assumed equal. A request that cannot be encoded
	// never reaches the provider, so it fails the turn here, before a request row
	// exists, rather than being recorded as a send that did not happen.
	encoded, encode_err := ai.Provider_Request_Freeze(prep.request, chat.allocator)
	if encode_err.kind != .None {
		chat_session_fail_turn(chat, encode_err.detail)
		ai.Provider_Operation_Error_Destroy(&encode_err, chat.allocator)
		return
	}
	defer delete(encoded.Body, chat.allocator)

	chat.last_estimate = prep.estimate
	// The input size is settled here and the request has not been sent yet, so this is
	// where a front-end learns what the context now holds.
	_observer_request_prepared(observer)

	// What the harness intends to send is recorded before it is stored, so a
	// request that never reaches the store still says what it was going to carry.
	prepared := [8]Log_Field {
		{key = "purpose", value = session.request_purpose_name(.Response)},
		{key = "provider", value = chat.provider_id},
		{key = "model", value = chat.model_id},
		{key = "api", value = chat_api_name(connection.API)},
		{key = "estimate", value = i64(prep.estimate)},
		{key = "context_window", value = i64(chat.capacity.window)},
		{key = "messages", value = i64(len(prep.history.entries))},
		{key = "tools", value = i64(len(prep.tools))},
	}
	log_emit({level = .Info, category = .Provider, event = "request.prepared", fields = prepared[:]})

	// The request carries interruption only. No deadline is set: the request
	// stays open as long as the provider keeps it open, and ends when the
	// provider, the transport, or cancellation ends it.
	options := ai.Provider_Operation_Options {
		interrupt = &chat_cancel,
	}
	// One request may be attempted more than once, and every attempt sends the
	// frozen bytes: nothing about the request changes between attempts. A retry
	// happens only while nothing has been exposed to the model, so the conversation
	// the next request is built from is the same one, and the model never learns that
	// an attempt failed.
	attempts := 0
	operation_error: ai.Provider_Operation_Error
	// The finish reason of the attempt that ends the chain is what the response is
	// committed with. Every attempt starts without one.
	finish_reason := ai.Provider_Finish_Reason.Unknown
	// The event source of the attempt that ends the chain, which is what its staged
	// output is committed under.
	source: Chat_Event_Source
	// The send that ends the chain, which is the row the response is committed under.
	request_no: session.Request_No
	// The send before this one, which is how each row names its chain.
	previous: Maybe(session.Request_No)
	// settled records that the send which ended the chain was already finished for its
	// own failure, before a retry was waited on. Such a row is not finished twice.
	settled := false
	for {
		attempts += 1
		// Each send is its own operation. An attempt is over when its call has
		// returned, so the one before it retires as this one begins: the cancellation
		// gate, the event source, and the usage reports all name exactly one send, and
		// nothing an abandoned attempt produced is attributed to the attempt after it.
		chat_session_retire_operation(chat)
		chat_session_begin_operation(chat)
		source = chat_session_event_source(chat)
		settled = false

		// One row per send. The row identifies the actual provider send, and the chain
		// it belongs to is written into the row, so a retry is legible from the store
		// rather than reconstructed from it. The row is recorded before the send: a
		// request that never finishes still says what it was about to carry.
		attempt := Chat_Attempt {
			number   = attempts,
			recovery = previous == nil ? .Initial : .Transient_Retry,
			previous = previous,
		}
		begin_no, begin_err := session.request_begin(
			chat.store,
			chat.id,
			{
				turn_no = chat.turn_no,
				purpose = .Response,
				provider = chat.provider_id,
				model_requested = chat.model_id,
				api = chat_api_name(connection.API),
				config_json = chat_request_config_json(chat, prep.request.Max_Output_Tokens),
				input_json = chat_request_input_json(&prep, &prep.history, chat.skill_snapshot_seq, len(prep.history.entries), attempt),
			},
			session.now_ms(),
		)
		if begin_err != nil {
			chat_session_record_failure(chat, "the request could not be recorded", begin_err)
			return
		}
		request_no = begin_no
		previous = begin_no
		chat.active_request = request_no
		binding.correlation = log_correlation_for(chat, attempts)

		recorded := [1]Log_Field{{key = "purpose", value = session.request_purpose_name(.Response)}}
		log_emit({level = .Info, category = .Storage, event = "request.recorded", fields = recorded[:]})
		// The runtime belongs to one attempt: a retry that produces nothing must not
		// inherit the finish reason of the attempt before it, nor the record that the
		// assistant block was already announced.
		runtime := Chat_Runtime_Context {
			chat      = chat,
			source    = source,
			observer  = observer,
			usage_log = usages,
		}
		log_emit({level = .Info, category = .Provider, event = "attempt.started"})

		// The observation belongs to this attempt: a retry that receives no chunk
		// must not inherit the previous attempt's byte count. It is only attached
		// when something will come of it, so a run with diagnostics off and capture
		// off pays nothing per chunk.
		provider_log: Provider_Log
		if log_observation_wanted() { options.observer = provider_log_observer(&provider_log) } else { options.observer = {} }

		at := time.tick_now()
		operation_error = ai.Provider_Request_Operation_Encoded(connection, encoded, &runtime, chat_provider_event, options, chat.allocator)
		finish_reason = runtime.finish_reason
		// The response artifact covers the whole attempt, so it is settled as soon as
		// the bytes stop arriving. A cut-short stream is kept and marked incomplete.
		if provider_log.response_capture.kind != .Invalid {
			log_capture_finish(&provider_log.response_capture, operation_error.kind == .None)
		}
		// The transport's own account of the attempt goes beside the provider's,
		// because "the peer refused the request" and "nothing ever left this machine"
		// are different findings that the high-level transport error cannot separate.
		transfer_phase := "not_reached"
		request_bytes_accepted := i64(0)
		request_body_bytes_accepted := i64(0)
		request_complete := false
		response_head_received := false
		declared_body_bytes := i64(0)
		declared_body_bytes_present := false
		if provider_log.transfer_seen {
			transfer_phase = log_provider_transfer_name(provider_log.transfer.stopped_at)
			request_bytes_accepted = i64(provider_log.transfer.request_bytes_accepted)
			request_body_bytes_accepted = i64(provider_log.transfer.request_body_bytes_accepted)
			request_complete = provider_log.transfer.request_complete
			response_head_received = provider_log.transfer.response_head_received
			declared_body_bytes = i64(provider_log.transfer.declared_body_bytes)
			declared_body_bytes_present = provider_log.transfer.declared_body_bytes_present
		}
		finished := [13]Log_Field {
			{key = "error_kind", value = log_operation_error_name(operation_error.kind)},
			{key = "finish_reason", value = chat_finish_reason_text(runtime.finish_reason)},
			{key = "status", value = i64(operation_error.status)},
			// The provider's own message, which for a refused request is the only
			// thing that says why. The transport bounds what it reads, so this is
			// bounded text, not an unbounded body.
			{key = "detail", value = operation_error.detail},
			{key = "response_bytes", value = i64(provider_log.response_bytes)},
			{key = "transfer_phase", value = transfer_phase},
			{key = "request_bytes_accepted", value = request_bytes_accepted},
			{key = "request_body_bytes_accepted", value = request_body_bytes_accepted},
			{key = "request_complete", value = request_complete},
			{key = "response_head_received", value = response_head_received},
			// Presence stays separate from the value: a declared empty body and an
			// undeclared one are different facts.
			{key = "declared_body_bytes_present", value = declared_body_bytes_present},
			{key = "declared_body_bytes", value = declared_body_bytes},
			{key = "elapsed_ms", value = log_duration_ms(time.tick_since(at))},
		}
		log_emit({level = .Info, category = .Provider, event = "attempt.finished", fields = finished[:]})
		if !chat_request_may_retry(chat, operation_error, attempts) { break }
		_observer_message(observer, .Notice, chat_retry_notice(attempts, operation_error))
		// The send is over, so its row is finished before anything is waited on or sent
		// again: the failure is in the store before the policy acts on it, with the
		// numbers and the usage of the send that produced it.
		chat_finish_request(chat, request_no, .Failed, .Unknown, operation_error.detail, usages)
		settled = true
		delay := chat_retry_delay(attempts)
		retry := [3]Log_Field {
			{key = "error_kind", value = log_operation_error_name(operation_error.kind)},
			{key = "next_attempt", value = i64(attempts + 1)},
			{key = "delay_ms", value = log_duration_ms(delay)},
		}
		log_emit({level = .Warning, category = .Provider, event = "request.retry", fields = retry[:]})
		if !chat_retry_wait(chat, delay) { break }
		chat_session_clear_attempt(chat)
		ai.Provider_Operation_Error_Destroy(&operation_error, chat.allocator)
	}
	chat.request_attempts = attempts
	// The error owns its evidence, and every path out of the request releases it.
	defer ai.Provider_Operation_Error_Destroy(&operation_error, chat.allocator)
	_observer_assistant_flush(observer)

	// Cancellation is the reason the turn ended, so it wins over any error the
	// transport also reported.
	if chat_session_cancelled(chat) {
		chat_session_note_cancel(chat)
	} else if operation_error.kind != .None && chat.state != .Finalizing {
		chat_session_feed_error(chat, source, operation_error.detail)
	}
	chat_session_retire_operation(chat)

	chat_commit_response(chat, request_no, finish_reason, usages, finish_row = !settled)
	// The request's outcome is recorded, so the provider's own accounting of it is part of
	// the session the front-end describes.
	_observer_request_finished(observer)
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
	// finish_row is false when the send this response came from was already finished
	// for its own failure, before a retry was waited on. A row says how its send ended
	// once, so a turn that ended while waiting does not write over that record.
	finish_row := true,
) {
	at_ms := session.now_ms()
	outcome: session.Outcome = .Completed
	if chat_session_cancelled(chat) {
		outcome = .Cancelled
	} else if chat.active_failed {
		outcome = .Failed
	}

	// A response that did not commit adds nothing to the context.
	chat.response_cost = 0
	if outcome == .Completed {
		text := string(chat.partial_assistant[:])
		response_count := 1 if chat.pending_response_present else 0
		notice_text := chat_notice_text(chat.pending_notice)
		chat.response_cost = chat_response_cost(chat, text, notice_text)
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

	if finish_row {
		chat_finish_request(chat, request_no, outcome, finish_reason, chat.last_error, usages)
	}
	finished := [3]Log_Field {
		{key = "outcome", value = session.outcome_name(outcome)},
		{key = "attempts", value = i64(chat.request_attempts)},
		{key = "finish_reason", value = chat_finish_reason_text(finish_reason)},
	}
	// A cancelled request is an ordinary end of the turn; one that failed is an
	// error. The record keeps the completed request number, and the correlation is
	// taken before the operation is retired.
	finished_binding: Log_Binding
	context.logger = log_rebind(&finished_binding, log_correlation(chat))
	level := log.Level.Info
	if outcome == .Failed { level = .Error }
	log_emit({level = level, category = .Provider, event = "request.finished", fields = finished[:]})
}

// chat_finish_request records how one send ended: its outcome, what the model stopped
// for, the harness's account of a failure, and the usage the endpoint reported for it.
// Every send reaches exactly one of these, including a send an attempt chain
// abandoned, so no row is left running and each row's numbers are its own.
@(private)
chat_finish_request :: proc(
	chat: ^Chat_Session,
	request_no: session.Request_No,
	outcome: session.Outcome,
	finish_reason: ai.Provider_Finish_Reason,
	error_text: string,
	usages: ^[dynamic]Chat_Request_Usage,
) {
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
	if outcome == .Failed && error_text != "" {
		error_json = chat_error_json(error_text)
	} else if outcome == .Cancelled {
		error_json = chat_error_json("cancelled")
	}

	finish_err := session.request_finish(
		chat.store,
		chat.id,
		request_no,
		{outcome = outcome, response_json = response_json, error_json = error_json, usage = chat_send_usage(chat, usages), at_ms = session.now_ms()},
	)
	if finish_err != nil {
		chat_session_record_failure(chat, "the request outcome could not be recorded", finish_err)
	}
}

// chat_response_cost estimates what one committed response adds to the model's
// context: the text it produced, the calls it proposed, the harness's notice, and the
// verbatim output the Responses API produced. It counts the same text the projection
// sends and estimates it the same way, so a tool batch's budget is charged for what
// the next request will actually carry.
@(private)
chat_response_cost :: proc(chat: ^Chat_Session, text, notice: string) -> int {
	chars := len(text) + len(notice)
	messages := 0
	if text != "" { messages += 1 }
	if notice != "" { messages += 1 }
	if chat.pending_response_present {
		chars += len(chat.pending_response.output)
		messages += 1
	}
	if len(chat.pending_calls) > 0 {
		for call in chat.pending_calls { chars += len(call.name) + len(call.arguments) }
		messages += 1
	}
	return chars / CHAT_CHARS_PER_TOKEN + messages * CHAT_MESSAGE_OVERHEAD_TOKENS
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
	// The turn is still identifiable here, which is what the end record carries.
	binding: Log_Binding
	context.logger = log_rebind(&binding, log_correlation(chat))

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
	finished := [5]Log_Field {
		{key = "outcome", value = session.outcome_name(outcome)},
		{key = "recorded", value = recorded},
		{key = "requests", value = i64(chat.requests_made)},
		{key = "calls", value = i64(chat.calls_made)},
		{key = "status", value = chat_terminal_text(chat.terminal_status)},
	}
	log_emit({level = .Info, category = .Agent, event = "turn.finished", fields = finished[:]})
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
// cancellation between them, so a retry never delays a turn that is being
// stopped.
@(private)
chat_retry_wait :: proc(chat: ^Chat_Session, delay: time.Duration) -> bool {
	remaining := delay
	for remaining > 0 {
		if chat_session_cancelled(chat) { return false }
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
