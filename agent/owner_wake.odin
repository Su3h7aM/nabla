package agent

import "core:sync"
import "core:time"

// chat_wake is the one wake primitive the session owner waits on, beside the one cancel
// token. It is process-wide for the same reason that token is: the thread that requests
// cancellation holds no session, and a registered wake address is one such a thread could
// still signal after the session it belonged to was freed. The wake carries no state, so a
// signal is only a hint to recheck predicates under the synchronization that produced them.
chat_wake: Owner_Wake

// Owner_Wake is the rendezvous between the owner and every producer: one mutex and one
// condition variable. A producer publishes its own fact under its own lock and then signals
// here, so taking this mutex is what makes a predicate check see everything published before
// the check. One such object is what the execution contract asks for: a bounded owner mailbox
// plus wake primitive, rather than a condition variable per producer.
//
// Lock order: this mutex is taken before whatever lock guards the fact being checked, and a
// producer releases its own lock before signalling. Holding both in the other order would
// invert with a producer that must take the wake to publish.
Owner_Wake :: struct {
	mutex: sync.Mutex,
	cond:  sync.Cond,
}

// owner_wake_signal wakes every waiter. A publication is not addressed to one session, so a
// waiter that finds nothing new rechecks and waits again; the alternative, signalling one
// waiter, can hand a wake to a session the publication was not for. Callable from any thread.
owner_wake_signal :: proc() {
	sync.mutex_lock(&chat_wake.mutex)
	owner_wake_notify()
	sync.mutex_unlock(&chat_wake.mutex)
}

// owner_wake_interrupt wakes every waiter from a signal handler. It takes no mutex, because a
// handler cannot take one and does not need to: on Linux signalling a condition variable is one
// atomic add and one futex wake, with no lock, no allocation, and no libc state, and the mutex a
// waiter holds protects its predicates rather than the condition variable. A wake is only a
// hint, so a signal that arrives while the owner is between its check and its wait still ends
// that wait: the waiter's futex word has already moved.
owner_wake_interrupt :: proc "contextless" () {
	sync.cond_broadcast(&chat_wake.cond)
}

// owner_wake_notify wakes every waiter of a caller that already holds the wake mutex, which
// is how a producer signals after publishing with that mutex held.
owner_wake_notify :: proc() {
	sync.cond_broadcast(&chat_wake.cond)
}

// owner_wake_wait releases the wake mutex and blocks until a producer signals, the deadline
// arrives, or a signal interrupts the wait. The caller holds the wake mutex and has already
// checked the predicate it is waiting on, so a publication that lands while it checks either
// changed what it saw or signals after this wait began. No deadline means the caller waits for
// a publication, because nothing it is waiting for expires on its own.
owner_wake_wait :: proc(deadline: Maybe(time.Tick)) {
	if due, has_deadline := deadline.?; has_deadline {
		remaining := time.tick_diff(time.tick_now(), due)
		if remaining > 0 { _ = sync.cond_wait_with_timeout(&chat_wake.cond, &chat_wake.mutex, remaining) }
		return
	}
	sync.cond_wait(&chat_wake.cond, &chat_wake.mutex)
}
