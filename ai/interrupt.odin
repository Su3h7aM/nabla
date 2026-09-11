package ai

import "core:sync"
import "core:time"

// Interrupt is a one-way cancellation token owned by the turn and observed by
// whoever performs blocking work on its behalf. Requesting is idempotent and safe
// from any thread and from a signal handler.
//
// The token is one atomic word holding a generation and a request bit. A signal
// handler loads the word and then compare-exchanges it, so its request only takes
// effect if the generation is unchanged: a handler that was descheduled before its
// write, while the turn advanced and the token was reset for the next turn, finds a
// different generation and its stale request is dropped. Resetting is a single
// store of the next generation with the request bit clear.
//
// The word is a plain 8-byte value with no descriptor and no allocated state, so
// there is nothing for a signal handler to race with and nothing to release. A
// self-pipe would wake a blocked poll sooner, but it is an OS resource that would
// have to be freed while a handler that already observed the token may still be
// running; sigaction does not wait for in-flight handlers. Cancellation latency is
// bounded by the transport's wait slice instead, which is cheaper than that race.
Interrupt :: struct {
	// [generation:63][requested:1]. Must stay naturally aligned: the compare-exchange
	// has to remain lock-free to be usable from a signal handler.
	word: u64,
}

// interrupt_capture reads the token as a signal handler sees it. A handler must
// pair this with interrupt_request_captured and pass the captured value through, so
// the write is conditional on the generation it observed.
interrupt_capture :: proc "contextless" (interrupt: ^Interrupt) -> u64 {
	if interrupt == nil { return 0 }
	return sync.atomic_load(&interrupt.word)
}

// interrupt_request_captured records a request only if the token still holds the
// generation that was captured. Two things are deliberately not errors: losing to
// another requester means the turn is already cancelled, and losing to a reset
// means this signal belongs to a superseded turn and must not cancel the next one.
interrupt_request_captured :: proc "contextless" (interrupt: ^Interrupt, captured: u64) {
	if interrupt == nil { return }
	if captured & 1 != 0 { return }
	if sync.atomic_compare_exchange_strong(&interrupt.word, captured, captured | 1) != captured { return }
}

interrupt_request :: proc "contextless" (interrupt: ^Interrupt) {
	interrupt_request_captured(interrupt, interrupt_capture(interrupt))
}

interrupt_requested :: proc "contextless" (interrupt: ^Interrupt) -> bool {
	if interrupt == nil { return false }
	return sync.atomic_load(&interrupt.word) & 1 != 0
}

// interrupt_reset starts a new generation with no request pending. The caller must
// know that no handler may still attribute a signal to the previous turn, which the
// generation check enforces even for a handler that is already inside.
interrupt_reset :: proc(interrupt: ^Interrupt) {
	if interrupt == nil { return }
	current := sync.atomic_load(&interrupt.word)
	sync.atomic_store(&interrupt.word, ((current >> 1) + 1) << 1)
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
