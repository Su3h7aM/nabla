package ai

import "core:sync"
import "core:time"

// Interrupt is a one-way cancellation token owned by whoever starts blocking work and
// observed by whoever performs it. Requesting is idempotent and safe from any thread.
// The zero value is not requested; the owner reuses a token only after every observer
// of the previous request has finished.
//
// parent, when set, is a wider token whose request also stops this work, such as the
// turn a call belongs to. It is read on every check and must outlive this token.
Interrupt :: struct {
	requested: bool,
	parent:    ^Interrupt,
}

interrupt_request :: proc "contextless" (interrupt: ^Interrupt) {
	if interrupt != nil { sync.atomic_store(&interrupt.requested, true) }
}

// interrupt_requested reports whether interrupt or any of its parents was requested.
interrupt_requested :: proc "contextless" (interrupt: ^Interrupt) -> bool {
	for token := interrupt; token != nil; token = token.parent {
		if sync.atomic_load(&token.requested) { return true }
	}
	return false
}

// Deadline is a monotonic bound. The zero value means "no deadline"; a deadline
// never fires because the wall clock moved.
Deadline :: struct {
	at:     time.Tick,
	active: bool,
}

deadline_none :: proc() -> Deadline { return {} }

deadline_in :: proc(after: time.Duration) -> Deadline {
	return Deadline{at = time.tick_add(time.tick_now(), after), active = true}
}

deadline_expired :: proc(deadline: Deadline) -> bool {
	return deadline.active && time.tick_since(deadline.at) >= 0
}

deadline_remaining :: proc(deadline: Deadline) -> (time.Duration, bool) {
	if !deadline.active { return 0, false }
	elapsed := time.tick_since(deadline.at)
	if elapsed >= 0 { return 0, true }
	return -elapsed, true
}
