package agent

import "core:mem"
import "core:sync"
import "core:time"

import "nabla:ai"

// OWNER_MAILBOX_CAPACITY bounds the progress one producer may have in flight. Progress may
// be coalesced; the terminal slot is separate, so a full queue never drops an outcome.
OWNER_MAILBOX_CAPACITY :: 64

// Chat_Attempt_Terminal is what one request worker sends when its operation returns: the
// error it owns and the provider's own stop reason. Exposure is not here: the owner records
// that as it applies the events the worker queued before this.
Chat_Attempt_Terminal :: struct {
	error:         ai.Provider_Operation_Error, // owned by the mailbox allocator
	finish_reason: ai.Provider_Finish_Reason,
}

// Owner_Mailbox is the one way a producer hands facts to the owner: a bounded queue of
// progress events and a terminal slot of its own. Only the owner reads it, and a worker
// writes it only to publish. The mailbox is fixed-size, so it never allocates; event payloads
// use allocator, which must be safe to use from a worker thread. Waiting never polls: a
// producer that finds the queue full waits on chat_wake, the owner waits there for facts, and
// the owner wakes producers as it drains.
Owner_Mailbox :: struct {
	allocator:        mem.Allocator,
	mutex:            sync.Mutex,
	events:           [OWNER_MAILBOX_CAPACITY]Chat_Event,
	head:             int,
	count:            int,
	terminal:         Chat_Attempt_Terminal,
	terminal_present: bool,
	// closed releases a producer that is waiting for room, so backpressure cannot outlive
	// the drain. The owner closes the mailbox before it joins a producer and clears the flag
	// once nothing can still publish.
	closed:           bool,
}

// mailbox_init gives the mailbox the allocator its payloads come from. The process heap is
// the caller's choice, because a worker must not allocate from the session's allocator,
// which may be a wrapper the owner is writing through at the same time.
mailbox_init :: proc(box: ^Owner_Mailbox, allocator: mem.Allocator) {
	box.allocator = allocator
}

// mailbox_push transfers ownership of one event to the mailbox. It waits while the queue is
// full, so a producer applies backpressure instead of dropping progress; false means the
// caller stopped, or the mailbox is closing, and still owns the event. The wait is on the
// shared owner wake, so a signal that interrupts it or a requested stop ends it too.
mailbox_push :: proc(box: ^Owner_Mailbox, event: Chat_Event, interrupt: ^ai.Interrupt) -> bool {
	sync.mutex_lock(&chat_wake.mutex)
	defer sync.mutex_unlock(&chat_wake.mutex)
	for {
		sync.mutex_lock(&box.mutex)
		if box.closed {
			sync.mutex_unlock(&box.mutex)
			return false
		}
		if box.count < len(box.events) {
			box.events[(box.head + box.count) % len(box.events)] = event
			box.count += 1
			sync.mutex_unlock(&box.mutex)
			owner_wake_notify()
			return true
		}
		sync.mutex_unlock(&box.mutex)
		if ai.interrupt_requested(interrupt) { return false }
		// No deadline: room arrives when the owner drains, and the drain signals.
		owner_wake_wait(nil)
	}
}

// mailbox_take removes the oldest event and transfers its ownership to the caller.
mailbox_take :: proc(box: ^Owner_Mailbox) -> (event: Chat_Event, ok: bool) {
	sync.mutex_lock(&box.mutex)
	if box.count == 0 {
		sync.mutex_unlock(&box.mutex)
		return nil, false
	}
	was_full := box.count >= len(box.events)
	event = box.events[box.head]
	box.events[box.head] = nil
	box.head = (box.head + 1) % len(box.events)
	box.count -= 1
	sync.mutex_unlock(&box.mutex)
	// Room only matters to a producer that found the queue full.
	if was_full { owner_wake_signal() }
	return event, true
}

// mailbox_publish_terminal records the producer's last word. The slot is its own, so a full
// progress queue cannot drop it. One admitted producer publishes one terminal.
mailbox_publish_terminal :: proc(box: ^Owner_Mailbox, terminal: Chat_Attempt_Terminal) {
	sync.mutex_lock(&box.mutex)
	box.terminal = terminal
	box.terminal_present = true
	sync.mutex_unlock(&box.mutex)
	owner_wake_signal()
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

// mailbox_await blocks until the mailbox holds something the owner can take, the deadline
// arrives, or a signal interrupts the wait. The check is narrow on purpose: the caller drains
// and joins outside it, because holding the wake across those would let a producer block on
// the publication it is finishing, which is the thread the caller joins next. No deadline
// means nothing the caller waits for expires on its own.
mailbox_await :: proc(box: ^Owner_Mailbox, deadline: Maybe(time.Tick)) {
	sync.mutex_lock(&chat_wake.mutex)
	defer sync.mutex_unlock(&chat_wake.mutex)
	sync.mutex_lock(&box.mutex)
	ready := box.count > 0 || box.terminal_present
	sync.mutex_unlock(&box.mutex)
	if ready { return }
	owner_wake_wait(deadline)
}

// mailbox_close releases a producer that is waiting for room. The owner calls it before it
// joins, so a full queue can never outlive the drain that would empty it.
mailbox_close :: proc(box: ^Owner_Mailbox) {
	sync.mutex_lock(&box.mutex)
	box.closed = true
	sync.mutex_unlock(&box.mutex)
	owner_wake_signal()
}

// mailbox_reset releases what the mailbox still holds and leaves it empty and open. Only the
// owner may call it, and only once no producer can still publish, so it takes no lock.
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
	box.closed = false
}
