package agent

import "core:sync"
import "core:time"

// chat_wake is process-wide because a signal handler holds no session.
chat_wake: Owner_Wake

// Owner_Wake is a monotonic sequence. A producer publishes its fact, then signals. A waiter
// loads the sequence before checking its predicates and waits on that value, so a
// publication after the load ends the wait. A wake is a hint; the waiter rechecks.
Owner_Wake :: struct {
	seq: sync.Futex,
}

// owner_wake_signal is async-signal-safe.
owner_wake_signal :: proc "contextless" () {
	sync.atomic_add(&chat_wake.seq, 1)
	sync.futex_broadcast(&chat_wake.seq)
}

owner_wake_seen :: proc "contextless" () -> u32 {
	return u32(sync.atomic_load(&chat_wake.seq))
}

// owner_wake_wait returns when the sequence differs from seen, at the deadline, or on a
// signal. A nil deadline waits for a publication only.
owner_wake_wait :: proc(seen: u32, deadline: Maybe(time.Tick)) {
	due, has_deadline := deadline.?
	if !has_deadline {
		sync.futex_wait(&chat_wake.seq, seen)
		return
	}
	if remaining := time.tick_diff(time.tick_now(), due); remaining > 0 {
		// Whether the wait woke or reached its deadline is a hint; the caller rechecks.
		_ = sync.futex_wait_with_timeout(&chat_wake.seq, seen, remaining)
	}
}
