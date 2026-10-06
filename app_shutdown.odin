package main

import "core:sync"
import "core:thread"
import "core:time"

// SHUTDOWN_JOIN_PATIENCE is how long the front-end waits for one thread to retire before
// it gives up on the thread and stops releasing what that thread can still reach. A tool stuck
// in a blocking syscall can outlive any request to stop, and the front-end must not be the
// reason a process cannot exit.
SHUTDOWN_JOIN_PATIENCE :: 5 * time.Second

// join_retiring waits for one thread to retire, up to patience, and reports whether it did.
// done is the event the thread's procedure signals as its last action, and the wait is one
// futex sleep per wake until it is signaled or the deadline passes. core:thread has no timed
// join, so the signal is what lets the wait give up. Once it is signaled the thread has only
// its own exit left to run, so thread.destroy joins without blocking on user work. A thread
// that did not retire is left alone: thread.destroy joins, so calling it here would block
// exactly where this procedure refuses to, and the caller must not free anything that thread
// can still reach. The caller tells the user.
@(require_results)
join_retiring :: proc(worker: ^thread.Thread, done: ^sync.One_Shot_Event, patience := SHUTDOWN_JOIN_PATIENCE) -> bool {
	if worker == nil { return true }
	deadline := time.tick_add(time.tick_now(), patience)
	for sync.atomic_load_explicit(&done.state, .Acquire) == 0 {
		remaining := -time.tick_since(deadline)
		if remaining <= 0 { return false }
		_ = sync.futex_wait_with_timeout(&done.state, 0, remaining)
	}
	thread.destroy(worker)
	return true
}
