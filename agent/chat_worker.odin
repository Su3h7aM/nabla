package agent

import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"

import "nabla:ai"

// Chat_Attempt_Terminal is a request worker's last word: the operation error, owned by the
// process heap, and the provider's stop reason.
Chat_Attempt_Terminal :: struct {
	error:         ai.Provider_Operation_Error,
	finish_reason: ai.Provider_Finish_Reason,
}

// Chat_Request_Worker is one request attempt running off the owner thread. The owner
// allocates it from the process heap, launches it, and frees it only once its worker has
// published or the session is gone, so every borrowed field (mailbox, interrupt, connection,
// encoded) outlives the thread. It borrows the frozen request rather than owning it: the
// bytes belong to the chain, and reusing or releasing them is what retiring the worker
// before the next stage makes safe.
//
// The worker writes terminal and then publishes through its Job; the owner reads terminal
// only after job_published. An abandoned attempt keeps the chain's scratch arena in arena,
// because the frozen bytes and the mailbox live there.
Chat_Request_Worker :: struct {
	// worker is the shared lifecycle, and its allocator is where the worker's payloads come
	// from. It is not embedded with using, because the record's own fields share its names.
	worker:            Job,
	mailbox:           ^Owner_Mailbox,
	interrupt:         ^ai.Interrupt,
	source:            Chat_Event_Source,
	connection:        ai.Provider_Connection,
	// websocket is the session's WebSocket when this attempt sends through it, else nil. An
	// abandoned attempt takes it over from the session, and its reclaim destroys it.
	websocket:         ^ai.Provider_WebSocket_Session,
	websocket_request: bool,
	encoded:           ai.Provider_Encoded_Request,
	options:           ai.Provider_Operation_Options,
	terminal:          Chat_Attempt_Terminal,
	arena:             virtual.Arena,
}

// chat_request_worker_run is the job body. It stores the terminal and nothing more: job_main
// publishes it.
chat_request_worker_run :: proc(job: ^Job) {
	chat_request_worker_attempt(container_of(job, Chat_Request_Worker, "worker"))
}

// chat_request_worker_free releases an attempt record whose worker has published, together
// with a terminal the owner did not take. Owner only.
chat_request_worker_free :: proc(worker: ^Chat_Request_Worker) {
	ai.Provider_Operation_Error_Destroy(&worker.terminal.error, worker.worker.allocator)
	free(worker, os.heap_allocator())
}

// chat_request_worker_reclaim releases an abandoned attempt whose worker has published: the
// record, its terminal, its mailbox, and the arena that held the frozen bytes. The mailbox
// lives in that arena, so it is destroyed first. Owner only.
chat_request_worker_reclaim :: proc(worker: ^Chat_Request_Worker) {
	if worker.mailbox != nil { mailbox_destroy(worker.mailbox) }
	if worker.websocket != nil { ai.Provider_WebSocket_Session_Destroy(worker.websocket) }
	virtual.arena_destroy(&worker.arena)
	chat_request_worker_free(worker)
}

// chat_request_worker_attempt runs the blocking send and records in worker.terminal what the
// owner needs to decide the next stage. Everything it records as progress is queued by the
// callback, so a stream that ends badly still leaves the owner with every fact that arrived.
@(private)
chat_request_worker_attempt :: proc(worker: ^Chat_Request_Worker) {
	if worker.websocket_request {
		worker.terminal.error = ai.Provider_WebSocket_Request(worker.websocket, worker.encoded, worker, chat_worker_event, worker.options)
	} else {
		worker.terminal.error = ai.Provider_Request_Operation_Encoded(
			worker.connection,
			worker.encoded,
			worker,
			chat_worker_event,
			worker.options,
			worker.worker.allocator,
		)
	}
}

// chat_worker_event is the transport callback. The transport frees the event it hands over
// as soon as this returns, so everything worth keeping is copied into an owned Chat_Event
// and pushed to the owner. The callback has no error to return, so a copy or a push that
// fails sets the mailbox's lost flag: a fact the response carried that the worker could not
// keep is what tells the owner nothing in it may be trusted.
@(private)
chat_worker_event :: proc(user_data: rawptr, event: ai.Provider_Event) {
	worker := cast(^Chat_Request_Worker)user_data
	allocator := worker.worker.allocator
	#partial switch value in event {
	case ai.Provider_Text_Event:
		text, clone_error := strings.clone(value.Text, allocator)
		if clone_error != nil {
			mailbox_mark_lost(worker.mailbox)
			return
		}
		chat_worker_deliver(worker, Chat_Text_Event{source = worker.source, text = text})
	case ai.Provider_Reasoning_Event:
	// Reasoning is opaque replay material. The stored response is what replays it, so
	// the owner never needs the live copy.
	case ai.Provider_Completed_Event:
		worker.terminal.finish_reason = value.Reason
		completion, kept := chat_worker_completion(worker, worker.source, value)
		if !kept {
			mailbox_mark_lost(worker.mailbox)
			return
		}
		chat_worker_deliver(worker, completion)
	case ai.Provider_Error_Event:
		message, clone_error := strings.clone(value.Message, allocator)
		if clone_error != nil {
			mailbox_mark_lost(worker.mailbox)
			return
		}
		chat_worker_deliver(worker, Chat_Failure_Event{source = worker.source, kind = value.Kind, message = message})
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
	allocator := worker.worker.allocator
	defer if !kept { chat_completion_destroy(&completion, allocator) }
	clone_error: mem.Allocator_Error
	if completion.reason_text, clone_error = strings.clone(value.Reason_Text, allocator); clone_error != nil { return {}, false }
	if completion.output, clone_error = strings.clone(value.Raw_Output, allocator); clone_error != nil { return {}, false }
	if len(value.Tool_Calls) > 0 {
		if completion.calls, clone_error = make([]ai.Provider_Tool_Call, len(value.Tool_Calls), allocator); clone_error != nil { return {}, false }
		for call, index in value.Tool_Calls {
			completion.calls[index].ID, clone_error = strings.clone(call.ID, allocator)
			if clone_error != nil { return {}, false }
			completion.calls[index].Item_ID, clone_error = strings.clone(call.Item_ID, allocator)
			if clone_error != nil { return {}, false }
			completion.calls[index].Name, clone_error = strings.clone(call.Name, allocator)
			if clone_error != nil { return {}, false }
			completion.calls[index].Arguments, clone_error = strings.clone(call.Arguments, allocator)
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
	chat_event_destroy(&owned, worker.worker.allocator)
	mailbox_mark_lost(worker.mailbox)
}
