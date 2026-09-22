package agent

import "core:mem"
import "core:sync"
import "core:time"

import "nabla:ai"

// OWNER_MAILBOX_CAPACITY bounds the progress one producer may have in flight. Progress may
// be coalesced; the terminal slot is separate, so a full queue never drops an outcome.
OWNER_MAILBOX_CAPACITY :: 64

// OWNER_MAILBOX_WAIT is how long the owner sleeps when nothing has arrived. A publication
// wakes it at once; the slice only bounds how late a stop that published nothing is seen,
// in the same way the transport's wait slice bounds cancellation during a send.
OWNER_MAILBOX_WAIT :: 50 * time.Millisecond

// Chat_Attempt_Terminal is what one request worker sends when its operation returns: the
// error it owns and the provider's own stop reason. Exposure is not here: the owner records
// that as it applies the events the worker queued before this.
Chat_Attempt_Terminal :: struct {
	error:         ai.Provider_Operation_Error, // owned by the mailbox allocator
	finish_reason: ai.Provider_Finish_Reason,
}

// Owner_Mailbox is the one way a producer hands facts to the owner: a bounded queue of
// progress events and a terminal slot of its own. Only the owner reads it, and a worker
// writes it only to publish. The mailbox is fixed-size, so it never allocates; event
// payloads use allocator, which must be safe to use from a worker thread.
Owner_Mailbox :: struct {
	allocator:        mem.Allocator,
	mutex:            sync.Mutex,
	cond:             sync.Cond,
	events:           [OWNER_MAILBOX_CAPACITY]Chat_Event,
	head:             int,
	count:            int,
	terminal:         Chat_Attempt_Terminal,
	terminal_present: bool,
}

// mailbox_init gives the mailbox the allocator its payloads come from. The process heap is
// the caller's choice, because a worker must not allocate from the session's allocator,
// which may be a wrapper the owner is writing through at the same time.
mailbox_init :: proc(box: ^Owner_Mailbox, allocator: mem.Allocator) {
	box.allocator = allocator
}

// mailbox_push transfers ownership of one event to the mailbox. It waits while the queue is
// full, so a producer applies backpressure instead of dropping progress; false means the
// caller stopped and still owns the event.
mailbox_push :: proc(box: ^Owner_Mailbox, event: Chat_Event, interrupt: ^ai.Interrupt) -> bool {
	sync.mutex_lock(&box.mutex)
	defer sync.mutex_unlock(&box.mutex)
	for box.count >= len(box.events) {
		if ai.interrupt_requested(interrupt) { return false }
		_ = sync.cond_wait_with_timeout(&box.cond, &box.mutex, OWNER_MAILBOX_WAIT)
	}
	box.events[(box.head + box.count) % len(box.events)] = event
	box.count += 1
	sync.cond_signal(&box.cond)
	return true
}

// mailbox_take removes the oldest event and transfers its ownership to the caller.
mailbox_take :: proc(box: ^Owner_Mailbox) -> (event: Chat_Event, ok: bool) {
	sync.mutex_lock(&box.mutex)
	defer sync.mutex_unlock(&box.mutex)
	if box.count == 0 { return nil, false }
	event = box.events[box.head]
	box.events[box.head] = nil
	box.head = (box.head + 1) % len(box.events)
	box.count -= 1
	// Wake a producer that is waiting for room.
	sync.cond_signal(&box.cond)
	return event, true
}

// mailbox_publish_terminal records the producer's last word. The slot is its own, so a full
// progress queue cannot drop it. One admitted producer publishes one terminal.
mailbox_publish_terminal :: proc(box: ^Owner_Mailbox, terminal: Chat_Attempt_Terminal) {
	sync.mutex_lock(&box.mutex)
	defer sync.mutex_unlock(&box.mutex)
	box.terminal = terminal
	box.terminal_present = true
	sync.cond_signal(&box.cond)
}

// mailbox_take_terminal transfers the terminal outcome to the owner.
mailbox_take_terminal :: proc(box: ^Owner_Mailbox) -> (terminal: Chat_Attempt_Terminal, ok: bool) {
	sync.mutex_lock(&box.mutex)
	defer sync.mutex_unlock(&box.mutex)
	if !box.terminal_present { return {}, false }
	terminal = box.terminal
	box.terminal = {}
	box.terminal_present = false
	return terminal, true
}

// mailbox_wait blocks until something arrives or the slice ends. A wakeup is a hint, not the
// record of a completion: the caller rechecks its predicates, and the predicate check and
// this wait share the mutex, so a publication that landed first cannot be missed.
mailbox_wait :: proc(box: ^Owner_Mailbox, timeout := OWNER_MAILBOX_WAIT) {
	sync.mutex_lock(&box.mutex)
	defer sync.mutex_unlock(&box.mutex)
	if box.count > 0 || box.terminal_present { return }
	_ = sync.cond_wait_with_timeout(&box.cond, &box.mutex, timeout)
}

// mailbox_reset releases what the mailbox still holds. Only the owner may call it, and only
// once no producer can still publish, so it takes no lock.
mailbox_reset :: proc(box: ^Owner_Mailbox) {
	for box.count > 0 {
		event := box.events[box.head]
		box.events[box.head] = nil
		box.head = (box.head + 1) % len(box.events)
		box.count -= 1
		chat_event_destroy(&event, box.allocator)
	}
	box.head = 0
	if box.terminal_present {
		ai.Provider_Operation_Error_Destroy(&box.terminal.error, box.allocator)
		box.terminal = {}
		box.terminal_present = false
	}
}
