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

mailbox_init :: proc(box: ^Owner_Mailbox, allocator: mem.Allocator) {
	box.allocator = allocator
	box.events = make([dynamic]Chat_Event, allocator)
}

// mailbox_push takes ownership of event, or returns false and leaves it with the caller.
mailbox_push :: proc(box: ^Owner_Mailbox, event: Chat_Event) -> bool {
	sync.mutex_lock(&box.mutex)
	_, err := append(&box.events, event)
	sync.mutex_unlock(&box.mutex)
	if err != nil { return false }
	owner_wake_signal()
	return true
}

// mailbox_take_all transfers the queued events, oldest first. The caller destroys each event
// and the array with the mailbox allocator.
mailbox_take_all :: proc(box: ^Owner_Mailbox) -> [dynamic]Chat_Event {
	sync.mutex_guard(&box.mutex)
	events := box.events
	box.events = make([dynamic]Chat_Event, box.allocator)
	return events
}

mailbox_publish_terminal :: proc(box: ^Owner_Mailbox, terminal: Chat_Attempt_Terminal) {
	sync.mutex_lock(&box.mutex)
	box.terminal = terminal
	box.terminal_present = true
	sync.mutex_unlock(&box.mutex)
	owner_wake_signal()
}

mailbox_take_terminal :: proc(box: ^Owner_Mailbox) -> (terminal: Chat_Attempt_Terminal, ok: bool) {
	sync.mutex_guard(&box.mutex)
	if !box.terminal_present { return }
	terminal, ok = box.terminal, true
	box.terminal = {}
	box.terminal_present = false
	return
}

// mailbox_reset releases what the mailbox holds. Owner only, after the producer was joined.
mailbox_reset :: proc(box: ^Owner_Mailbox) {
	for &event in box.events {
		chat_event_destroy(&event, box.allocator)
	}
	clear(&box.events)
	if box.terminal_present {
		ai.Provider_Operation_Error_Destroy(&box.terminal.error, box.allocator)
		box.terminal = {}
		box.terminal_present = false
	}
}

mailbox_destroy :: proc(box: ^Owner_Mailbox) {
	mailbox_reset(box)
	delete(box.events)
	box.events = nil
}
