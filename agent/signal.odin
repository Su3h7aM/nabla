package agent

import "core:sync"
import "nabla:ai"

// process_interrupt latches SIGINT, SIGTERM, or SIGHUP: the process was asked to stop. A
// signal handler may only write static storage, so this is the one process-wide stop; the
// owner applies it to the turn it runs, and the root ends the process once no turn runs.
// Every turn's stop chains to it, so a wait blocked inside the turn sees it at once.
@(private)
process_interrupt: ai.Interrupt

@(require_results)
process_interrupted :: proc "contextless" () -> bool {
	return ai.interrupt_requested(&process_interrupt)
}

// Signal is a process signal the harness watches: the ones that ask it to stop.
Signal :: enum {
	Interrupt,
	Terminate,
	Hangup,
}

// signal_wake is the descriptor the latch writes to, or -1. A handler can run on any
// thread, so the latch alone would not end a poll another thread is blocked in.
@(private)
signal_wake: i32 = -1

@(private)
signal_wake_readers: sync.Futex

// signal_set_wake registers a non-blocking eventfd that the latch writes a u64 1 to, so a
// frontend polling it wakes at once. -1 clears the registration, which the caller does
// before it closes the descriptor. Clearing waits for handlers that borrowed the old fd
// to finish writing, so it may then be closed safely. Calls must be serialized and must
// not run from a signal handler. The latch stays the source of truth.
signal_set_wake :: proc(fd: int) {
	sync.atomic_store(&signal_wake, -1)
	for readers := sync.atomic_load(&signal_wake_readers); readers != 0; readers = sync.atomic_load(&signal_wake_readers) {
		sync.futex_wait(&signal_wake_readers, u32(readers))
	}
	sync.atomic_store(&signal_wake, i32(fd))
}

// signal_interrupt_latch is what an installed handler runs. It writes only static storage.
@(private)
signal_interrupt_latch :: proc "contextless" () {
	ai.interrupt_request(&process_interrupt)
	owner_wake_signal()
	sync.atomic_add(&signal_wake_readers, 1)
	if fd := sync.atomic_load(&signal_wake); fd >= 0 {
		signal_wake_write(int(fd))
	}
	if sync.atomic_sub(&signal_wake_readers, 1) == 1 { sync.futex_broadcast(&signal_wake_readers) }
}

// chat_signal_arm installs the handler only while a turn is in flight, so a headless
// run keeps the default meaning of Ctrl-C while idle. The handler is installed without
// SA_RESTART, so an interrupted wait returns and observes the stop. A disposition that
// cannot be installed leaves the default in place, under which the signal ends the process
// and journal recovery takes over.
chat_signal_arm :: proc(previous: ^Signal_Action) {
	signal_action_install(.Interrupt, previous)
}

// chat_signal_disarm restores the previous disposition, which is teardown: a disposition
// that cannot be restored changes nothing about a process that is finishing. The handler
// references only static storage, so a signal that arrives while this runs either latches
// the interrupt or terminates the process under the restored default.
chat_signal_disarm :: proc(previous: ^Signal_Action) {
	if previous == nil { return }
	signal_action_restore(.Interrupt, previous)
}

Chat_Interactive_Signals :: struct {
	previous_int:  Signal_Action,
	previous_term: Signal_Action,
	previous_hup:  Signal_Action,
}

// chat_interactive_arm installs the handler for the whole interactive lifetime, so
// SIGINT, SIGTERM, and SIGHUP end the process through the owner instead of killing it
// with the terminal unrestored. Per-turn arming nests inside this and restores it afterwards.
chat_interactive_arm :: proc(state: ^Chat_Interactive_Signals) {
	signal_action_install(.Interrupt, &state.previous_int)
	signal_action_install(.Terminate, &state.previous_term)
	signal_action_install(.Hangup, &state.previous_hup)
}

// chat_interactive_disarm restores both dispositions, which is teardown: the process is
// going away and a disposition that cannot be restored changes nothing about that.
chat_interactive_disarm :: proc(state: ^Chat_Interactive_Signals) {
	if state == nil { return }
	signal_action_restore(.Interrupt, &state.previous_int)
	signal_action_restore(.Terminate, &state.previous_term)
	signal_action_restore(.Hangup, &state.previous_hup)
}

// chat_signal_block_watched blocks SIGINT, SIGTERM, and SIGHUP on the calling thread and
// returns its previous mask. A thread inherits its creator's mask, so a worker that must
// never run the handler is created between this and chat_signal_restore. A mask that
// cannot be set leaves the thread exposed, and the handler only stores atomics.
chat_signal_block_watched :: proc() -> Signal_Mask {
	return signal_mask_block({.Interrupt, .Terminate, .Hangup})
}

// chat_signal_restore puts a thread's mask back, which is teardown for a thread that is
// starting its work: a mask that cannot be restored changes nothing about the process.
chat_signal_restore :: proc(previous: Signal_Mask) {
	signal_mask_set(previous)
}
