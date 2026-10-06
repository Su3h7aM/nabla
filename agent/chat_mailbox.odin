package agent

import "core:mem"
import "core:sync"

// Owner_Mailbox carries a request worker's events to the owner in order. A push never
// blocks. Payloads and the queue use allocator, which must be safe to use from a worker
// thread. lost is atomic: the producer sets it for a fact it could not hand over, which
// needs no allocation, and the owner takes it. The worker's terminal is not here: it is in
// the attempt record, read after the worker publishes.
Owner_Mailbox :: struct {
	allocator: mem.Allocator,
	mutex:     sync.Mutex,
	events:    [dynamic]Chat_Event,
	lost:      bool,
}

mailbox_init :: proc(mailbox: ^Owner_Mailbox, allocator: mem.Allocator) {
	mailbox.allocator = allocator
	// An empty queue allocates nothing; it carries the allocator the first push grows from.
	mailbox.events.allocator = allocator
}

// mailbox_push takes ownership of event, or returns false and leaves it with the caller.
@(require_results)
mailbox_push :: proc(mailbox: ^Owner_Mailbox, event: Chat_Event) -> bool {
	sync.mutex_lock(&mailbox.mutex)
	_, err := append(&mailbox.events, event)
	sync.mutex_unlock(&mailbox.mutex)
	if err != nil { return false }
	owner_wake_signal()
	return true
}

// mailbox_mark_lost records that a fact of the response could not be handed over. It
// allocates nothing, so it cannot fail the way the handoff did.
mailbox_mark_lost :: proc(mailbox: ^Owner_Mailbox) {
	sync.atomic_store(&mailbox.lost, true)
	owner_wake_signal()
}

// mailbox_take_lost reports whether a fact was lost since the last call, and clears the
// report. Take it after the worker's publication: the worker marks a loss before it publishes.
@(require_results)
mailbox_take_lost :: proc(mailbox: ^Owner_Mailbox) -> bool {
	return sync.atomic_exchange(&mailbox.lost, false)
}

// mailbox_take_all transfers the queued events, oldest first. The caller destroys each event
// and the array with the mailbox allocator.
@(require_results)
mailbox_take_all :: proc(mailbox: ^Owner_Mailbox) -> [dynamic]Chat_Event {
	sync.mutex_guard(&mailbox.mutex)
	events := mailbox.events
	// The queue the producer pushes into next holds nothing yet and allocates nothing, so
	// taking the events cannot fail; only the allocator it grows from is carried over.
	mailbox.events = nil
	mailbox.events.allocator = mailbox.allocator
	return events
}

// mailbox_reset releases what the mailbox holds. Owner only, after the producer was joined.
mailbox_reset :: proc(mailbox: ^Owner_Mailbox) {
	for &event in mailbox.events {
		chat_event_destroy(&event, mailbox.allocator)
	}
	clear(&mailbox.events)
}

mailbox_destroy :: proc(mailbox: ^Owner_Mailbox) {
	mailbox_reset(mailbox)
	delete(mailbox.events)
	mailbox.events = nil
}
