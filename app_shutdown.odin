package main

import "core:thread"
import "core:time"

import "nabla:agent"

// SHUTDOWN_JOIN_PATIENCE is how long the front-end waits for one thread to retire before
// it reports the thread and stops releasing what that thread can still reach. A tool stuck
// in a blocking syscall can outlive any request to stop, and the front-end must not be the
// reason a process cannot exit. A strict bound for arbitrary native code needs process
// isolation, not a longer wait.
SHUTDOWN_JOIN_PATIENCE :: 5 * time.Second

// SHUTDOWN_JOIN_POLL is how often a retiring thread is checked. The wait polls instead of
// joining because giving up is the point of the bound.
SHUTDOWN_JOIN_POLL :: 5 * time.Millisecond

// join_retiring waits for one thread to retire, up to patience, and reports whether it did.
// A thread that did not retire is reported and left alone: thread.destroy joins, so calling
// it here would block exactly where this procedure refuses to, and the caller must not
// free anything that thread can still reach.
join_retiring :: proc(worker: ^thread.Thread, name: string, patience := SHUTDOWN_JOIN_PATIENCE) -> bool {
	if worker == nil { return true }
	deadline := time.tick_add(time.tick_now(), patience)
	for !thread.is_done(worker) {
		if time.tick_since(deadline) >= 0 { break }
		time.sleep(SHUTDOWN_JOIN_POLL)
	}
	if !thread.is_done(worker) {
		fields := [2]agent.Log_Field{{key = "thread", value = name}, {key = "waited_ms", value = agent.Log_Duration_Milliseconds(patience)}}
		agent.log_emit(agent.Log_Record{level = .Error, category = .Runtime, event = "runtime.thread_unretired", fields = fields[:]})
		return false
	}
	thread.destroy(worker)
	return true
}
