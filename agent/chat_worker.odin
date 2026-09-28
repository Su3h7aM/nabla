package agent

import "core:mem"
import "core:strings"
import "core:thread"
import "core:time"

import "nabla:ai"

// Chat_Request_Worker is one request attempt running off the owner thread. The owner
// allocates it, launches it, and frees it only after the join, so every borrowed field
// (mailbox, interrupt, connection, encoded) outlives the thread. It borrows the frozen
// request rather than owning it: the bytes belong to the chain, and reusing or releasing
// them is what the join before the next stage makes safe.
Chat_Request_Worker :: struct {
	allocator:         mem.Allocator, // safe from a worker thread; payloads come from here
	mailbox:           ^Owner_Mailbox,
	interrupt:         ^ai.Interrupt,
	source:            Chat_Event_Source,
	connection:        ai.Provider_Connection,
	websocket:         ^ai.Provider_WebSocket_Session,
	websocket_request: bool,
	encoded:           ai.Provider_Encoded_Request,
	options:           ai.Provider_Operation_Options,
	logging:           Log_Binding,
}

// Chat_Worker_Runtime is the callback's user data: the worker fact sink, the identity every
// queued event carries, and the provider's stop reason as it arrives.
Chat_Worker_Runtime :: struct {
	worker:        ^Chat_Request_Worker,
	source:        Chat_Event_Source,
	finish_reason: ai.Provider_Finish_Reason,
}

// chat_request_worker_main is the thread body. Odin gives a new thread a fresh managed temp
// allocator but nothing else, so the allocator and logger the worker uses are set here.
chat_request_worker_main :: proc(thread: ^thread.Thread) {
	worker := cast(^Chat_Request_Worker)thread.data
	if worker == nil { return }
	context.allocator = worker.allocator
	context.logger = log_logger(&worker.logging)
	mailbox_publish_terminal(worker.mailbox, chat_request_worker_attempt(worker))
}

// chat_request_worker_attempt runs the blocking send and returns what the owner needs to
// decide the next stage. Everything it records as progress is queued by the callback, so a
// stream that ends badly still leaves the owner with every fact that arrived.
@(private, require_results)
chat_request_worker_attempt :: proc(worker: ^Chat_Request_Worker) -> Chat_Attempt_Terminal {
	runtime := Chat_Worker_Runtime {
		worker = worker,
		source = worker.source,
	}
	log_emit({level = .Info, category = .Provider, event = "attempt.started"})

	// The observation belongs to this attempt: a retry that receives no chunk must not
	// inherit the previous attempt's byte count. It is only attached when something will
	// come of it, so a run with diagnostics off pays nothing per chunk.
	provider_log: Provider_Log
	attempt_options := worker.options
	if log_enabled(.Info) { attempt_options.observer = provider_log_observer(&provider_log) } else { attempt_options.observer = {} }

	at := time.tick_now()
	operation_error: ai.Provider_Operation_Error
	if worker.websocket_request {
		operation_error = ai.Provider_WebSocket_Request(worker.websocket, worker.encoded, &runtime, chat_worker_event, attempt_options)
	} else {
		operation_error = ai.Provider_Request_Operation_Encoded(
			worker.connection,
			worker.encoded,
			&runtime,
			chat_worker_event,
			attempt_options,
			worker.allocator,
		)
	}
	// The transport's own account of the attempt goes beside the provider's, because "the
	// peer refused the request" and "nothing ever left this machine" are different findings
	// the high-level transport error cannot separate.
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
	delivery_name := ai.provider_delivery_state_name(operation_error.delivery)
	if worker.websocket_request && operation_error.kind == .None { delivery_name = ai.provider_delivery_state_name(.Terminal_Observed) }
	finished := [14]Log_Field {
		{key = "error_kind", value = ai.provider_operation_error_name(operation_error.kind)},
		{key = "delivery", value = delivery_name},
		{key = "finish_reason", value = chat_finish_reason_text(runtime.finish_reason)},
		{key = "status", value = i64(operation_error.status)},
		// The provider's own message, which for a refused request is the only thing that
		// says why. The transport bounds what it reads, so this is bounded text.
		{key = "detail", value = operation_error.detail},
		{key = "response_bytes", value = i64(provider_log.response_bytes)},
		{key = "transfer_phase", value = transfer_phase},
		{key = "request_bytes_accepted", value = request_bytes_accepted},
		{key = "request_body_bytes_accepted", value = request_body_bytes_accepted},
		{key = "request_complete", value = request_complete},
		{key = "response_head_received", value = response_head_received},
		// Presence stays separate from the value: a declared empty body and an undeclared
		// one are different facts.
		{key = "declared_body_bytes_present", value = declared_body_bytes_present},
		{key = "declared_body_bytes", value = declared_body_bytes},
		{key = "elapsed_ms", value = Log_Duration_Milliseconds(time.tick_since(at))},
	}
	log_emit({level = .Info, category = .Provider, event = "attempt.finished", fields = finished[:]})
	return {error = operation_error, finish_reason = runtime.finish_reason}
}

// chat_worker_event is the transport callback. The transport frees the event it hands over
// as soon as this returns, so everything worth keeping is copied into an owned Chat_Event
// and pushed to the owner. The callback has no error to return, so a copy or a push that
// fails is reported to the owner as a response it cannot use: a fact the response carried
// that the worker could not keep is what tells the owner nothing in it may be trusted.
@(private)
chat_worker_event :: proc(user_data: rawptr, event: ai.Provider_Event) {
	runtime := cast(^Chat_Worker_Runtime)user_data
	worker := runtime.worker
	#partial switch value in event {
	case ai.Provider_Text_Event:
		text, clone_error := strings.clone(value.Text, worker.allocator)
		if clone_error != nil {
			chat_worker_lost(worker, runtime.source, "the response text")
			return
		}
		chat_worker_deliver(worker, runtime.source, Chat_Text_Event{source = runtime.source, text = text}, "the response text")
	case ai.Provider_Reasoning_Event:
	// Reasoning is opaque replay material. The stored response is what replays it, so
	// the owner never needs the live copy.
	case ai.Provider_Completed_Event:
		runtime.finish_reason = value.Reason
		completion, kept := chat_worker_completion(worker, runtime.source, value)
		if !kept {
			chat_worker_lost(worker, runtime.source, "the completed response")
			return
		}
		chat_worker_deliver(worker, runtime.source, completion, "the completed response")
	case ai.Provider_Error_Event:
		message, clone_error := strings.clone(value.Message, worker.allocator)
		if clone_error != nil {
			chat_worker_lost(worker, runtime.source, "the provider's failure message")
			return
		}
		chat_worker_deliver(
			worker,
			runtime.source,
			Chat_Failure_Event{source = runtime.source, kind = value.Kind, message = message},
			"the provider's failure message",
		)
	case ai.Provider_Usage_Event:
		// Usage is a measurement, not text: it is copied whole and needs no ownership, and a
		// queue that cannot take it does not make the response unusable the way a lost
		// fragment of the answer does.
		if mailbox_push(worker.mailbox, Chat_Usage_Event{usage = value}) { return }
		log_emit({level = .Error, category = .Provider, event = "provider.usage_lost"})
	}
}

// chat_worker_completion copies a completed response into what the owner keeps, or reports
// that it did not fit. A copy that fails releases everything it copied before it gave up, so
// the owner never receives a response that is missing a piece of what the model sent.
@(private, require_results)
chat_worker_completion :: proc(
	worker: ^Chat_Request_Worker,
	source: Chat_Event_Source,
	value: ai.Provider_Completed_Event,
) -> (
	Chat_Provider_Completion,
	bool,
) {
	completion: Chat_Provider_Completion
	completion.source = source
	completion.reason = value.Reason
	kept := false
	defer if !kept { chat_completion_destroy(&completion, worker.allocator) }
	clone_error: mem.Allocator_Error
	if completion.reason_text, clone_error = strings.clone(value.Reason_Text, worker.allocator); clone_error != nil { return {}, false }
	if completion.output, clone_error = strings.clone(value.Raw_Output, worker.allocator); clone_error != nil { return {}, false }
	if len(value.Tool_Calls) > 0 {
		if completion.calls, clone_error = make([]ai.Provider_Tool_Call, len(value.Tool_Calls), worker.allocator); clone_error != nil { return {}, false }
		for call, index in value.Tool_Calls {
			completion.calls[index].ID, clone_error = strings.clone(call.ID, worker.allocator)
			if clone_error != nil { return {}, false }
			completion.calls[index].Item_ID, clone_error = strings.clone(call.Item_ID, worker.allocator)
			if clone_error != nil { return {}, false }
			completion.calls[index].Name, clone_error = strings.clone(call.Name, worker.allocator)
			if clone_error != nil { return {}, false }
			completion.calls[index].Arguments, clone_error = strings.clone(call.Arguments, worker.allocator)
			if clone_error != nil { return {}, false }
		}
	}
	kept = true
	return completion, true
}

// chat_worker_deliver hands one owned event to the mailbox, or releases it and reports the
// fact it carried as lost when the queue could not take it. what names the fact, which is
// also what the report says was lost.
@(private)
chat_worker_deliver :: proc(worker: ^Chat_Request_Worker, source: Chat_Event_Source, event: Chat_Event, what: string) {
	if mailbox_push(worker.mailbox, event) { return }
	owned := event
	chat_event_destroy(&owned, worker.allocator)
	chat_worker_lost(worker, source, what)
}

// chat_worker_lost tells the owner that a fact the response carried could not be kept, so
// that response is not usable as it stands. The owner answers it with the notice that says
// the harness could not keep the response, which tells the model nothing in it ran and asks
// it to send the work again: the only correction available to the owner, and the only one
// the model can act on. The report owns no string, so it cannot fail the way the fact it
// reports did.
@(private)
chat_worker_lost :: proc(worker: ^Chat_Request_Worker, source: Chat_Event_Source, what: string) {
	fields := [1]Log_Field{{key = "lost", value = what}}
	log_emit({level = .Error, category = .Provider, event = "provider.fact_lost", fields = fields[:]})
	if mailbox_push(worker.mailbox, Chat_Lost_Event{source = source}) { return }
	// The queue could not take the report either, so the log line above is the whole record.
	log_emit({level = .Error, category = .Provider, event = "provider.fact_lost_unreported"})
}
