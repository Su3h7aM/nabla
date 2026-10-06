package agent

import "core:mem"
import "core:strings"
import "core:thread"

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
}

// Chat_Worker_Runtime is the callback's user data: the worker fact sink, the identity every
// queued event carries, and the provider's stop reason as it arrives.
Chat_Worker_Runtime :: struct {
	worker:        ^Chat_Request_Worker,
	source:        Chat_Event_Source,
	finish_reason: ai.Provider_Finish_Reason,
}

// chat_request_worker_main is the thread body. Odin gives a new thread a fresh managed temp
// allocator but nothing else, so the allocator the worker uses is set here.
chat_request_worker_main :: proc(thread: ^thread.Thread) {
	worker := cast(^Chat_Request_Worker)thread.data
	if worker == nil { return }
	context.allocator = worker.allocator
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
	operation_error: ai.Provider_Operation_Error
	if worker.websocket_request {
		operation_error = ai.Provider_WebSocket_Request(worker.websocket, worker.encoded, &runtime, chat_worker_event, worker.options)
	} else {
		operation_error = ai.Provider_Request_Operation_Encoded(
			worker.connection,
			worker.encoded,
			&runtime,
			chat_worker_event,
			worker.options,
			worker.allocator,
		)
	}
	return {error = operation_error, finish_reason = runtime.finish_reason}
}

// chat_worker_event is the transport callback. The transport frees the event it hands over
// as soon as this returns, so everything worth keeping is copied into an owned Chat_Event
// and pushed to the owner. The callback has no error to return, so a copy or a push that
// fails sets the mailbox's lost flag: a fact the response carried that the worker could not
// keep is what tells the owner nothing in it may be trusted.
@(private)
chat_worker_event :: proc(user_data: rawptr, event: ai.Provider_Event) {
	runtime := cast(^Chat_Worker_Runtime)user_data
	worker := runtime.worker
	#partial switch value in event {
	case ai.Provider_Text_Event:
		text, clone_error := strings.clone(value.Text, worker.allocator)
		if clone_error != nil {
			mailbox_mark_lost(worker.mailbox)
			return
		}
		chat_worker_deliver(worker, Chat_Text_Event{source = runtime.source, text = text})
	case ai.Provider_Reasoning_Event:
	// Reasoning is opaque replay material. The stored response is what replays it, so
	// the owner never needs the live copy.
	case ai.Provider_Completed_Event:
		runtime.finish_reason = value.Reason
		completion, kept := chat_worker_completion(worker, runtime.source, value)
		if !kept {
			mailbox_mark_lost(worker.mailbox)
			return
		}
		chat_worker_deliver(worker, completion)
	case ai.Provider_Error_Event:
		message, clone_error := strings.clone(value.Message, worker.allocator)
		if clone_error != nil {
			mailbox_mark_lost(worker.mailbox)
			return
		}
		chat_worker_deliver(worker, Chat_Failure_Event{source = runtime.source, kind = value.Kind, message = message})
	case ai.Provider_Usage_Event:
		// Usage is a measurement, not text: it is copied whole and needs no ownership, and a
		// queue that cannot take it does not make the response unusable the way a lost
		// fragment of the answer does.
		_ = mailbox_push(worker.mailbox, Chat_Usage_Event{usage = value})
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

// chat_worker_deliver hands one owned event to the mailbox, or releases it and marks the
// fact it carried as lost when the queue could not take it.
@(private)
chat_worker_deliver :: proc(worker: ^Chat_Request_Worker, event: Chat_Event) {
	if mailbox_push(worker.mailbox, event) { return }
	owned := event
	chat_event_destroy(&owned, worker.allocator)
	mailbox_mark_lost(worker.mailbox)
}
