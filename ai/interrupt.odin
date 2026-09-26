package ai

import "core:sync"
import "core:time"

// Interrupt is a one-way cancellation token owned by whoever starts blocking work and
// observed by whoever performs it. Requesting is idempotent and safe from any thread.
// The zero value is not requested; the owner reuses a token only after every observer
// of the previous request has finished.
Interrupt :: struct {
	requested: bool,
}

interrupt_request :: proc "contextless" (interrupt: ^Interrupt) {
	if interrupt != nil { sync.atomic_store(&interrupt.requested, true) }
}

interrupt_requested :: proc "contextless" (interrupt: ^Interrupt) -> bool {
	return interrupt != nil && sync.atomic_load(&interrupt.requested)
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
