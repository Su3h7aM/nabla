package agent

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:sync"
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

// --- running a request -------------------------------------------------------

// chat_request_transport chooses the wire transport for one request chain and freezes the
// exact bytes it will send. The configured mode says what the operator wants and the API
// adapter says which transports it implements; neither is keyed on a provider or model
// identity. An eligible WebSocket setup failure selects HTTP for this affinity, which is
// the only fallback: it never authorizes a second send of the same model request.
//
// On failure the turn is failed here and no body is returned. On success the caller owns
// encoded.Body and must release it once the chain is over.
@(private)
chat_request_transport :: proc(
	chat: ^Chat_Session,
	connection: ai.Provider_Connection,
	prep: ^Chat_Request_Prep,
	options: ai.Provider_Operation_Options,
) -> (
	encoded: ai.Provider_Encoded_Request,
	websocket_request: bool,
	ok: bool,
) {
	transports := ai.Provider_API_Transports(connection.API)
	if chat.provider_transport == .WebSocket && .WebSocket not_in transports {
		chat_session_fail_turn(chat, fmt.tprintf("the %s API has no WebSocket transport", chat_api_name(connection.API)))
		return {}, false, false
	}
	websocket_request = chat.provider_transport != .HTTP && .WebSocket in transports && !chat.websocket_fallback_http

	// A request that cannot be encoded never reaches the provider, so it fails the turn
	// before a request row exists rather than being recorded as a send that did not happen.
	encode_err: ai.Provider_Operation_Error
	if websocket_request {
		encoded, encode_err = ai.Provider_Request_Freeze_WebSocket(prep.request, chat.allocator)
	} else {
		encoded, encode_err = ai.Provider_Request_Freeze(prep.request, chat.allocator)
	}
	if encode_err.kind != .None {
		chat_session_fail_turn(chat, encode_err.detail)
		ai.Provider_Operation_Error_Destroy(&encode_err, chat.allocator)
		return {}, false, false
	}
	if websocket_request && chat.provider_websocket == nil {
		chat.provider_websocket, encode_err = ai.Provider_WebSocket_Session_Open(connection, chat.allocator)
		if encode_err.kind != .None {
			delete(encoded.Body, chat.allocator)
			chat_session_fail_turn(chat, encode_err.detail)
			ai.Provider_Operation_Error_Destroy(&encode_err, chat.allocator)
			return {}, false, false
		}
	}
	if websocket_request && chat.provider_transport == .Auto {
		connect_err := ai.Provider_WebSocket_Connect(chat.provider_websocket, encoded, options)
		if connect_err.kind != .None {
			if !chat_websocket_fallback_safe(connect_err) {
				delete(encoded.Body, chat.allocator)
				chat_session_fail_turn(chat, connect_err.detail)
				ai.Provider_Operation_Error_Destroy(&connect_err, chat.allocator)
				return {}, false, false
			}
			ai.Provider_Operation_Error_Destroy(&connect_err, chat.allocator)
			ai.Provider_WebSocket_Session_Destroy(chat.provider_websocket)
			chat.provider_websocket = nil
			chat.websocket_fallback_http = true
			websocket_request = false
			delete(encoded.Body, chat.allocator)
			encoded, encode_err = ai.Provider_Request_Freeze(prep.request, chat.allocator)
			if encode_err.kind != .None {
				chat_session_fail_turn(chat, encode_err.detail)
				ai.Provider_Operation_Error_Destroy(&encode_err, chat.allocator)
				return {}, false, false
			}
		}
	}
	return encoded, websocket_request, true
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
	result: Chat_Send_Result,
	usages: ^[dynamic]Chat_Request_Usage,
	// finish_row is false when the send this response came from was already finished
	// for its own failure, before a retry was waited on. A row says how its send ended
	// once, so a turn that ended while waiting does not write over that record.
	finish_row := true,
) {
	at_ms := session.now_ms()
	send := result
	send.outcome = .Completed
	if chat_session_cancelled(chat) {
		send.outcome = .Cancelled
	} else if chat.active_failed {
		send.outcome = .Failed
	}
	outcome := send.outcome

	// A response that did not commit adds nothing to the context.
	chat.response_cost = 0
	if outcome == .Completed && !chat_commit_response_entries(chat, request_no, at_ms) { return }
	// A notice is only ever committed with the response that raised it. One that
	// did not commit, because the turn failed or was cancelled, is dropped.
	chat.pending_notice = .None

	if finish_row { chat_finish_request(chat, request_no, send, usages) }
	finished := [3]Log_Field {
		{key = "outcome", value = session.outcome_name(outcome)},
		{key = "attempts", value = i64(chat.request_attempts)},
		{key = "finish_reason", value = chat_finish_reason_text(result.finish_reason)},
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

// chat_commit_response_entries records the entries one completed response produced: the
// verbatim Responses output, the assistant text, the calls it proposed, and the harness's
// notice. It also settles what the response costs the next request and releases the staged
// response. It reports whether every entry landed; a failed append stops the turn, so the
// caller must not continue.
@(private)
chat_commit_response_entries :: proc(chat: ^Chat_Session, request_no: session.Request_No, at_ms: i64) -> bool {
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
	// The harness's explanation of an unusable response is committed with the response
	// itself, after whatever text it produced.
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
		return false
	}
	// Each staged call now knows the entry it was stored as, which is what a later
	// dispatch and result name.
	offset := response_count + (1 if text != "" else 0)
	for i in 0 ..< len(chat.pending_calls) { chat.pending_calls[i].seq = seqs[offset + i] }
	delete(seqs, chat.allocator)

	chat_response_output_destroy(&chat.pending_response, chat.allocator)
	chat.pending_response_present = false
	delete(chat.partial_assistant)
	chat.partial_assistant = make([dynamic]u8, 0, 0, chat.allocator)
	return true
}

// chat_finish_request records how one send ended: its outcome, what the model stopped
// for, the harness's account of a failure, and the usage the endpoint reported for it.
// Every send reaches exactly one of these, including a send an attempt chain
// abandoned, so no row is left running and each row's numbers are its own.
@(private)
chat_finish_request :: proc(chat: ^Chat_Session, request_no: session.Request_No, result: Chat_Send_Result, usages: ^[dynamic]Chat_Request_Usage) {
	response_json := ""
	if result.finish_reason != .Unknown {
		response_json = string(
			json.marshal(
				Chat_Request_Response{reason = chat_finish_reason_text(result.finish_reason), attempts = chat.request_attempts},
				allocator = context.temp_allocator,
			) or_else nil,
		)
	}
	error_json := ""
	if result.outcome != .Completed {
		if result.error_present {
			error_json = chat_request_error_json(result)
		} else if result.message != "" {
			// A failure the harness detected itself has no operation behind it, so the
			// record keeps the message and nothing else.
			error_json = chat_error_json(result.message)
		}
	}

	finish_err := session.request_finish(
		chat.store,
		chat.id,
		request_no,
		{outcome = result.outcome, response_json = response_json, error_json = error_json, usage = chat_send_usage(chat, usages), at_ms = session.now_ms()},
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
	if chat.last_error != "" {
		error_json = chat_turn_error_json(chat.last_error, chat.turn_recovery, chat.turn_repair_refusal)
	}

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

// chat_retry_wait waits out the backoff before the next attempt and reports whether the
// delay elapsed instead of the turn being stopped. The deadline is the delay itself, so
// nothing polls: a wakeup from any other publication ends the wait early, and the loop
// recomputes what is left instead of shortening the backoff.
@(private)
chat_retry_wait :: proc(chat: ^Chat_Session, delay: time.Duration) -> bool {
	deadline := time.tick_add(time.tick_now(), delay)
	sync.mutex_lock(&chat_wake.mutex)
	defer sync.mutex_unlock(&chat_wake.mutex)
	for {
		if chat_session_cancelled(chat) { return false }
		if time.tick_diff(time.tick_now(), deadline) <= 0 { return true }
		// A wakeup from any other publication ends the wait early, and the loop recomputes
		// what is left rather than shortening the backoff.
		owner_wake_wait(deadline)
	}
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

chat_run_turn :: proc(chat: ^Chat_Session, connection: ai.Provider_Connection, policy: Chat_Retry_Policy, observer: Chat_Observer) -> bool {
	return chat_run_turn_steered(chat, connection, policy, observer, nil)
}

chat_websocket_fallback_safe :: proc(err: ai.Provider_Operation_Error) -> bool {
	if err.delivery != .None { return false }
	if err.transport_cause == .Trust || err.transport_cause == .Configuration { return false }
	if err.kind == .Transport { return true }
	if err.kind != .HTTP { return false }
	switch err.status {
	case 404, 405, 426, 501:
		return true
	}
	return false
}

// chat_run_turn_steered runs one turn to its terminal effect. steer is nil for a caller
// with no input of its own, such as a headless run; otherwise the request boundary
// consumes what the user queued while the turn ran.
chat_run_turn_steered :: proc(
	chat: ^Chat_Session,
	connection: ai.Provider_Connection,
	policy: Chat_Retry_Policy,
	observer: Chat_Observer,
	steer: ^Steer_Context,
) -> bool {
	usages := make([dynamic]Chat_Request_Usage, 0, chat.allocator)
	defer delete(usages)

	previous: posix.sigaction_t
	chat_signal_arm(&previous)
	defer chat_signal_disarm(&previous)

	// current is the connection the next request is built for. The boundary may
	// replace it, which is how a selection the user changed mid-turn reaches the
	// request that follows rather than the turn after this one.
	current := connection
	for {
		// External facts are applied before the state is read, so the selection below is
		// a pure read of state. The owner observes the clock once and both steps use it.
		now := time.tick_now()
		chat_session_observe_at(chat, now)
		// Input the front-end queued while the turn ran is applied before the state is read,
		// so the selector sees a turn that still has a message to answer.
		if steer != nil { chat_steering_observe(chat, observer, steer) }
		effect := chat_session_advance_at(chat, now)
		switch effect.kind {
		case .Start_Request:
			// The boundary is a stage of the request the selector just proposed, and it runs
			// before the claim that counts it: the selection the user may have changed since
			// the last request is installed, and a boundary that stops the turn claims
			// nothing. The input this request carries is already recorded above, so the claim
			// prepares it from the record.
			if steer != nil && steer.apply != nil { current = steer.apply(steer) }
			chat_request_begin(chat, current, policy, observer)
		case .Send_Attempt:
			// The claim records the attempt and its row before any network work, and the
			// launch hands the frozen bytes to a worker and returns. The send is not observed
			// here: Await_Provider collects what the worker published and waits for its
			// terminal outcome.
			chat_chain_claim_send(chat)
			chat_chain_launch_send(chat)
		case .Await_Provider:
			chat_chain_await(chat, &usages)
		case .Wait_Retry:
			chat_chain_wait(chat)
		case .Repair_Context:
			chat_chain_repair(chat)
		case .Commit_Response:
			chat_chain_commit(chat, &usages)
		case .Run_Tools:
			turn_id := effect.turn_id
			chat_tool_jobs_begin(chat, observer)
			if chat.active_turn_id != turn_id { return false }
		case .Step_Tools:
			tool_effect := effect.tool
			chat_tool_jobs_step(chat, observer, tool_effect)
		case .Wait_Tools:
			chat_tool_jobs_wait(chat)
		case .Finish_Tools:
			turn_id := effect.turn_id
			if !chat_tool_jobs_finish(chat, turn_id) { return false }
			if chat_session_cancelled(chat) { chat_session_note_cancel(chat) }
		case .Turn_Finished:
			// The claim applies the transition the selector proposed, which only read state.
			// It runs before the line drain so the line still belongs to the turn that was
			// sent it, while the turn number still names that turn.
			_ = chat_session_claim_finish(chat, effect)
			// Input the turn never recorded is recorded here, so a turn that ends takes no
			// message with it: this is input that arrived while a request was in flight, while
			// a tool batch was settling, or after a failure or cancellation. It is durable, and
			// the next request built from this history carries it, whether that request belongs
			// to a later turn or to a resumed session.
			//
			// This runs before the turn's own end writes so the line still belongs to the turn
			// that was sent it. A partial answer is written after it, and that entry is evidence
			// no model is shown, so the order the next request reads is unaffected.
			if steer != nil { chat_drain_steering(chat, observer, steer) }
			// A turn whose outcome did not reach the store reports the storage failure,
			// not the status the model reached: the session has no record of it. The
			// session's own error is what the record and the front-end read.
			status := effect.status
			if !chat_persist_turn_end(chat, effect) { status = .Failed }
			chat_report_terminal(chat, observer, status)
			chat_report_usage(observer, usages)
			return status == .Completed
		case .None:
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
