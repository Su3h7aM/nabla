package agent

import "core:mem"
import "core:sync"

import "nabla:ai"

// Chat_Attempt_Terminal is a request worker's last word: the operation error, owned by the
// mailbox allocator, and the provider's stop reason.
Chat_Attempt_Terminal :: struct {
	error:         ai.Provider_Operation_Error,
	finish_reason: ai.Provider_Finish_Reason,
}

// Owner_Mailbox carries a request worker's events to the owner in order, plus one terminal
// published after every event. A push never blocks. Payloads and the queue use allocator,
// which must be safe to use from a worker thread.
Owner_Mailbox :: struct {
	allocator:        mem.Allocator,
	mutex:            sync.Mutex,
	events:           [dynamic]Chat_Event,
	terminal:         Chat_Attempt_Terminal,
	terminal_present: bool,
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

mailbox_publish_terminal :: proc(mailbox: ^Owner_Mailbox, terminal: Chat_Attempt_Terminal) {
	sync.mutex_lock(&mailbox.mutex)
	mailbox.terminal = terminal
	mailbox.terminal_present = true
	sync.mutex_unlock(&mailbox.mutex)
	owner_wake_signal()
}

@(require_results)
mailbox_take_terminal :: proc(mailbox: ^Owner_Mailbox) -> (terminal: Chat_Attempt_Terminal, ok: bool) {
	sync.mutex_guard(&mailbox.mutex)
	if !mailbox.terminal_present { return }
	terminal, ok = mailbox.terminal, true
	mailbox.terminal = {}
	mailbox.terminal_present = false
	return
}

// mailbox_reset releases what the mailbox holds. Owner only, after the producer was joined.
mailbox_reset :: proc(mailbox: ^Owner_Mailbox) {
	for &event in mailbox.events {
		chat_event_destroy(&event, mailbox.allocator)
	}
	clear(&mailbox.events)
	if mailbox.terminal_present {
		ai.Provider_Operation_Error_Destroy(&mailbox.terminal.error, mailbox.allocator)
		mailbox.terminal = {}
		mailbox.terminal_present = false
	}
}

mailbox_destroy :: proc(mailbox: ^Owner_Mailbox) {
	mailbox_reset(mailbox)
	delete(mailbox.events)
	mailbox.events = nil
}
