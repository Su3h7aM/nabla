package agent

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:sys/posix"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

@(require_results)
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
@(private, require_results)
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
		encoded, encode_err = ai.Provider_Request_Freeze_WebSocket_Reusing(prep.request, &chat.encode_cache, chat.allocator)
	} else {
		encoded, encode_err = ai.Provider_Request_Freeze_Reusing(prep.request, &chat.encode_cache, chat.allocator)
	}
	if encode_err.kind != .None {
		chat_session_fail_turn(chat, encode_err.detail)
		ai.Provider_Operation_Error_Destroy(&encode_err, chat.allocator)
		return {}, false, false
	}
	if websocket_request && chat.provider_websocket == nil {
		chat.provider_websocket, encode_err = ai.Provider_WebSocket_Session_Open(connection, chat.allocator)
		if encode_err.kind != .None {
			if !encoded.Body_Borrowed { delete(encoded.Body, chat.allocator) }
			chat_session_fail_turn(chat, encode_err.detail)
			ai.Provider_Operation_Error_Destroy(&encode_err, chat.allocator)
			return {}, false, false
		}
	}
	if websocket_request && chat.provider_transport == .Auto {
		connect_err := ai.Provider_WebSocket_Connect(chat.provider_websocket, encoded, options)
		if connect_err.kind != .None {
			if !chat_websocket_fallback_safe(connect_err) {
				if !encoded.Body_Borrowed { delete(encoded.Body, chat.allocator) }
				chat_session_fail_turn(chat, connect_err.detail)
				ai.Provider_Operation_Error_Destroy(&connect_err, chat.allocator)
				return {}, false, false
			}
			ai.Provider_Operation_Error_Destroy(&connect_err, chat.allocator)
			ai.Provider_WebSocket_Session_Destroy(chat.provider_websocket)
			chat.provider_websocket = nil
			chat.websocket_fallback_http = true
			websocket_request = false
			if !encoded.Body_Borrowed { delete(encoded.Body, chat.allocator) }
			encoded, encode_err = ai.Provider_Request_Freeze_Reusing(prep.request, &chat.encode_cache, chat.allocator)
			if encode_err.kind != .None {
				chat_session_fail_turn(chat, encode_err.detail)
				ai.Provider_Operation_Error_Destroy(&encode_err, chat.allocator)
				return {}, false, false
			}
		}
	}
	return encoded, websocket_request, true
}

// chat_commit_response records what the response produced and how the send
// ended. A completed response becomes an Assistant node with its native output,
// the calls it proposed, and the harness's notice. A failed or cancelled one
// records only how it ended; the text it produced becomes a partial Assistant
// node when the turn settles, because an unfinished answer must never be
// replayed as a finished one.
@(private)
chat_commit_response :: proc(
	chat: ^Chat_Session,
	request: journal.Request_Id,
	// attempt is the number of the send this response came from within its request.
	attempt: int,
	result: Chat_Send_Result,
	usages: ^[dynamic]Chat_Request_Usage,
	// finish_send is false when the send this response came from was already
	// recorded as ended for its own failure, before a retry was waited on.
	finish_send := true,
) {
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
	if outcome == .Completed {
		if !chat_commit_response_nodes(chat, request, attempt, result.finish_reason, usages) { return }
	} else if finish_send {
		chat_finish_send(chat, request, attempt, send)
	}
	// A notice is only ever committed with the response that raised it. One that
	// did not commit, because the turn failed or was cancelled, is dropped.
	chat_notice_clear(chat)

	finished := [3]Log_Field {
		{key = "outcome", value = CHAT_SEND_OUTCOME_NAMES[outcome]},
		{key = "attempts", value = i64(attempt)},
		{key = "finish_reason", value = chat_finish_reason_text(result.finish_reason)},
	}
	// A cancelled request is an ordinary end of the turn; one that failed is an
	// error.
	finished_binding: Log_Binding
	previous_logger := context.logger
	defer context.logger = previous_logger
	context.logger = log_rebind(&finished_binding, log_correlation(chat))
	level := log.Level.Info
	if outcome == .Failed { level = .Error }
	log_emit({level = level, category = .Provider, event = "request.finished", fields = finished[:]})
}

// chat_commit_response_nodes commits one completed response: its Assistant node,
// the response.committed record with the endpoint's native output and usage, a
// tool.proposed record per call, and the harness's notice. It also settles what
// the response costs the next request and releases the staged response. It
// reports whether the commit landed; a failure stops the turn.
@(private, require_results)
chat_commit_response_nodes :: proc(
	chat: ^Chat_Session,
	request: journal.Request_Id,
	attempt: int,
	finish: ai.Provider_Finish_Reason,
	usages: ^[dynamic]Chat_Request_Usage,
) -> bool {
	// The notice's text is composed in temp memory and copied by the journal.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	text := string(chat.partial_assistant[:])
	notice_text := chat_notice_committed_text(chat, context.temp_allocator)
	chat.response_cost = chat_response_cost(chat, text, notice_text)

	assistant := chat_node(chat, .Assistant, journal.Assistant{request = request}, transmute([]u8)text)
	chat.response_node = assistant
	committed := chat_send_usage(chat, usages)
	committed.finish = chat_finish_reason_text(finish)
	output: []u8
	if chat.pending_response_present { output = transmute([]u8)chat.pending_response.output }
	header := journal.Record {
		kind     = .Response_Committed,
		node     = assistant,
		request  = request,
		attempt  = journal.Attempt_No(attempt),
		provider = chat.provider_id,
		model    = chat.model_id,
	}
	chat_record(chat, header, committed, output)
	for &call in chat.pending_calls {
		call.call = journal.next_call(chat.store)
		proposal := journal.Tool_Proposed {
			provider_id = call.id,
			item_id     = call.item_id,
			name        = call.name,
		}
		chat_record(chat, {kind = .Tool_Proposed, node = assistant, request = request, call = call.call}, proposal, transmute([]u8)call.arguments)
	}
	// The harness's explanation of an unusable response follows the response it explains.
	if notice_text != "" { chat_node(chat, .Notice, journal.Notice{}, transmute([]u8)notice_text) }
	if !chat_commit(chat, "the response could not be recorded") { return false }

	chat_pending_response_clear(chat)
	chat_partial_assistant_clear(chat)
	return true
}

// chat_finish_send records how one send that produced no usable response ended:
// response.rejected with the evidence of a failure, or request.interrupted for a
// send the turn cancelled. Every send that did not commit reaches exactly one of
// these, including a send an attempt chain abandoned, so none is left open.
@(private)
chat_finish_send :: proc(chat: ^Chat_Session, request: journal.Request_Id, attempt: int, result: Chat_Send_Result) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	header := journal.Record {
		request  = request,
		attempt  = journal.Attempt_No(attempt),
		provider = chat.provider_id,
		model    = chat.model_id,
	}
	if result.outcome == .Cancelled {
		header.kind = .Request_Interrupted
		chat_record(chat, header, journal.Request_Interrupted{detail = "the turn was cancelled"})
	} else {
		header.kind = .Response_Rejected
		chat_record(chat, header, chat_send_rejection(result))
	}
	// The commit latches the storage failure itself, which is what the turn reads next.
	_ = chat_commit(chat, "the request outcome could not be recorded")
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
// turn produced but never committed. That text is a partial Assistant node, so it
// is evidence in the record and never a finished answer in a later request.
//
// It reports whether the commit landed. A turn whose outcome did not reach the
// journal must not be reported as the status the model reached, because that
// would claim a record the journal does not have.
@(private, require_results)
chat_persist_turn_end :: proc(chat: ^Chat_Session, effect: Chat_Effect) -> (recorded: bool) {
	if chat.turn == 0 { return true }
	// The turn is still identifiable here, which is what the end record carries.
	binding: Log_Binding
	previous_logger := context.logger
	defer context.logger = previous_logger
	context.logger = log_rebind(&binding, log_correlation(chat))

	if text := string(chat.partial_assistant[:]); text != "" {
		chat_node(chat, .Assistant, journal.Assistant{request = chat.request, partial = true}, transmute([]u8)text)
		chat_partial_assistant_clear(chat)
	}

	outcome: journal.Turn_Outcome
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
	completed := journal.Turn_Completed {
		outcome = journal.TURN_OUTCOME_NAMES[outcome],
		detail  = chat.last_error,
	}
	if reason, present := chat.turn_recovery.?; present { completed.reason = request_recovery_reason_name(reason) }
	if chat.turn_repair_refusal != .None { completed.cause = chat_repair_refusal_name(chat.turn_repair_refusal) }
	chat_record(chat, {kind = .Turn_Completed}, completed)
	recorded = chat_commit(chat, "the turn outcome could not be recorded")

	finished := [5]Log_Field {
		{key = "outcome", value = journal.TURN_OUTCOME_NAMES[outcome]},
		{key = "recorded", value = recorded},
		{key = "requests", value = i64(chat.requests_made)},
		{key = "calls", value = i64(chat.calls_made)},
		{key = "status", value = chat_terminal_text(chat.terminal_status)},
	}
	log_emit({level = .Info, category = .Agent, event = "turn.finished", fields = finished[:]})
	chat.turn = 0
	chat.request = 0
	// A turn that ended without running its staged calls, such as one a durable
	// write stopped, releases them here.
	chat_pending_calls_clear(chat)
	chat_pending_response_clear(chat)
	return recorded
}

// chat_retry_deadline is the tick a wait of delay ends at, or nil when the delay is longer
// than the clock can hold from now. A wait with no deadline ends on a cancel alone, which
// is the only end an unrepresentable delay has: it has not elapsed.
@(private)
chat_retry_deadline :: proc(delay: time.Duration) -> Maybe(time.Tick) {
	now := time.tick_now()
	// The clock's zero tick is its start, so this is the clock's own reading, and what
	// remains of its range is the most a deadline can add to now.
	elapsed := time.tick_diff(time.Tick{}, now)
	if delay > max(time.Duration) - elapsed { return nil }
	return time.tick_add(now, delay)
}

// chat_retry_wait waits out a backoff and reports whether it elapsed without a cancel.
@(private, require_results)
chat_retry_wait :: proc(chat: ^Chat_Session, delay: time.Duration) -> bool {
	deadline := chat_retry_deadline(delay)
	for {
		seen := owner_wake_seen()
		chat_session_observe_stop(chat)
		if chat_session_cancelled(chat) { return false }
		if due, timed := deadline.?; timed && time.tick_diff(time.tick_now(), due) <= 0 { return true }
		owner_wake_wait(seen, deadline)
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

@(require_results)
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
// consumes what the user queued while the turn ran. control is nil for a caller that
// never stops a turn itself; a process interrupt stops the turn either way.
@(require_results)
chat_run_turn_steered :: proc(
	chat: ^Chat_Session,
	connection: ai.Provider_Connection,
	policy: Chat_Retry_Policy,
	observer: Chat_Observer,
	steer: ^Steer_Context,
	control: ^Turn_Control = nil,
) -> bool {
	previous: posix.sigaction_t
	chat_signal_arm(&previous)
	defer chat_signal_disarm(&previous)
	return chat_turn_drive(chat, connection, policy, observer, steer, control)
}

// chat_turn_drive is the turn loop without the process signal handler, for a turn that does
// not own the terminal, such as a subagent's on its own thread.
@(require_results)
chat_turn_drive :: proc(
	chat: ^Chat_Session,
	connection: ai.Provider_Connection,
	policy: Chat_Retry_Policy,
	observer: Chat_Observer,
	steer: ^Steer_Context,
	control: ^Turn_Control,
) -> bool {
	// The turn's usage log holds nothing yet and allocates nothing; it carries the allocator
	// the reports it collects grow from.
	usages: [dynamic]Chat_Request_Usage
	usages.allocator = chat.allocator
	defer delete(usages)

	if control != nil { control.stop.parent = &process_interrupt }
	chat.control = control
	chat.stop.parent = chat_stop_parent(chat)
	defer {
		chat.control = nil
		chat.stop.parent = chat_stop_parent(chat)
	}

	// current is the connection the next request is built for. The boundary may
	// replace it, which is how a selection the user changed mid-turn reaches the
	// request that follows rather than the turn after this one.
	current := connection
	for {
		// The session keeps only heap- or chain-owned data between effects. Scratch from
		// one effect is released before the next request or tool step begins.
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		// External facts are applied before the state is read, so the selection below is
		// a pure read of state. The owner observes the clock once and both steps use it.
		now := time.tick_now()
		chat_session_observe_at(chat, now)
		// A summarizer that finished is adopted here, where its completion is read, so the job's
		// storage and its thread are released without waiting for a request boundary. The summary
		// itself still installs at a boundary, because a frozen prefix is chosen there.
		chat_compact_poll(chat, observer)
		// Input queued while the turn ran is applied before the state is read, so the
		// selector sees a turn that still has a message to answer.
		chat_steering_observe(chat, observer, steer)
		effect := chat_session_advance_at(chat, now)
		switch effect.kind {
		case .Start_Request:
			// The boundary is a stage of the request the selector just proposed, and it runs
			// before the claim that counts it: the selection the user may have changed since
			// the last request is installed, and a boundary that stops the turn claims
			// nothing. The input this request carries is already recorded above, so the claim
			// prepares it from the record.
			if steer != nil && steer.apply != nil { current = steer.apply(steer) }
			// A subagent started by this request's calls inherits the selection it runs with.
			agent_team_note_parent(chat)
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
			if chat.active_turn_id != turn_id {
				// A batch belongs to the turn that committed its calls. Failing the turn keeps the
				// session usable and its terminal reachable; abandoning it here would leave the
				// batch open with nothing that could close it.
				chat_session_fail_turn(chat, "the turn changed under a tool batch")
				continue
			}
		case .Step_Tools:
			tool_effect := effect.tool
			chat_tool_jobs_step(chat, observer, tool_effect)
		case .Wait_Tools:
			chat_tool_jobs_wait(chat)
		case .Finish_Tools:
			turn_id := effect.turn_id
			if !chat_tool_jobs_finish(chat, turn_id) {
				// The batch is released but the turn cannot continue from it: either it did not answer
				// every committed call, or the runtime is done because a worker would not stop. The
				// transition that refused it already moved the turn to a state that ends, so the loop
				// finishes it here rather than returning with the session still claiming a stage it
				// cannot leave.
				continue
			}
			if chat_session_cancelled(chat) { chat_session_note_cancel(chat) }
		case .Turn_Finished:
			// The claim applies the transition the selector proposed, which only read state.
			// It runs before the line drain so the line still belongs to the turn that was
			// sent it, while the turn number still names that turn.
			// A claim refuses only for a turn that already left the state it names.
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
			// Every state a turn can be in proposes an effect that moves it, so a proposal of
			// nothing means the turn reached a state with no work left in it: it fails here
			// rather than returning with the session claiming a stage nothing will move it out
			// of, and rather than spinning on a proposal that will not change.
			if chat.state != .Idle {
				_ = chat_session_fail_turn(chat, "the turn reached a state with no effect to take")
				continue
			}
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
