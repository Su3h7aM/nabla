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
@(private)
chat_request_worker_attempt :: proc(worker: ^Chat_Request_Worker) -> Chat_Attempt_Terminal {
	runtime := Chat_Worker_Runtime {
		worker = worker,
		source = worker.source,
	}
	log_emit({level = .Info, category = .Provider, event = "attempt.started"})

	// The observation belongs to this attempt: a retry that receives no chunk must not
	// inherit the previous attempt's byte count. It is only attached when something will
	// come of it, so a run with diagnostics off and capture off pays nothing per chunk.
	provider_log: Provider_Log
	attempt_options := worker.options
	if log_observation_wanted() { attempt_options.observer = provider_log_observer(&provider_log) } else { attempt_options.observer = {} }

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
	// The response artifact covers the whole attempt, so it is settled as soon as the bytes
	// stop arriving. A cut-short stream is kept and marked incomplete.
	if provider_log.response_capture.kind != .Invalid {
		log_capture_finish(&provider_log.response_capture, operation_error.kind == .None)
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
// and pushed to the owner.
@(private)
chat_worker_event :: proc(user_data: rawptr, event: ai.Provider_Event) {
	runtime := cast(^Chat_Worker_Runtime)user_data
	worker := runtime.worker
	#partial switch value in event {
	case ai.Provider_Text_Event:
		chat_worker_push(worker, Chat_Text_Event{source = runtime.source, text = strings.clone(value.Text, worker.allocator)})
	case ai.Provider_Reasoning_Event:
	// Reasoning is opaque replay material. The stored response is what replays it, so
	// the owner never needs the live copy.
	case ai.Provider_Completed_Event:
		runtime.finish_reason = value.Reason
		completion := Chat_Provider_Completion {
			source      = runtime.source,
			reason      = value.Reason,
			reason_text = strings.clone(value.Reason_Text, worker.allocator),
			output      = strings.clone(value.Raw_Output, worker.allocator),
		}
		if len(value.Tool_Calls) > 0 {
			completion.calls = make([]ai.Provider_Tool_Call, len(value.Tool_Calls), worker.allocator)
			for call, index in value.Tool_Calls {
				completion.calls[index] = ai.Provider_Tool_Call {
					ID        = strings.clone(call.ID, worker.allocator),
					Item_ID   = strings.clone(call.Item_ID, worker.allocator),
					Name      = strings.clone(call.Name, worker.allocator),
					Arguments = strings.clone(call.Arguments, worker.allocator),
				}
			}
		}
		chat_worker_push(worker, completion)
	case ai.Provider_Error_Event:
		chat_worker_push(worker, Chat_Failure_Event{source = runtime.source, message = strings.clone(value.Message, worker.allocator)})
	case ai.Provider_Usage_Event:
		// Usage is a measurement, not text: it is copied whole and needs no ownership.
		chat_worker_push(worker, Chat_Usage_Event{usage = value})
	}
}

// chat_worker_push hands one owned event to the mailbox, or releases it when the turn
// stopped while the queue was full. The release uses the worker allocator, which is the one
// the payload was cloned with.
@(private)
chat_worker_push :: proc(worker: ^Chat_Request_Worker, event: Chat_Event) {
	if mailbox_push(worker.mailbox, event, worker.interrupt) { return }
	owned := event
	chat_event_destroy(&owned, worker.allocator)
}
