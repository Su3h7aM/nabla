package agent

import linux "core:sys/linux"
import "core:sys/posix"
import "nabla:ai"

// chat_cancel is the process-wide cancellation token, observed by the signal
// handler, the model request, and tool execution. It is a global so the handler can
// only ever write to static storage: it can never touch a session that may already
// be freed, and there is no pointer that can dangle underneath it. One interactive
// turn runs at a time, so one token is sufficient; it is cleared when a turn starts,
// so a late signal is never inherited by the next turn.
chat_cancel: ai.Interrupt

// chat_cancel_reset begins a new cancellation generation. SIGINT is blocked across
// the change because a handler running between the generation load and the store
// would set the request bit on the outgoing generation, which the store then erases:
// the signal would be silently lost. Blocking keeps it pending until the new
// generation is published, so a signal arriving at that instant lands on the turn
// that is starting rather than on neither.
// chat_signal_int_set builds a one-signal mask. `Sig_Set` is a word array, so the
// canonical construction is a bit_set transmute rather than a libc sigaddset.
chat_signal_int_set :: proc() -> linux.Sig_Set {
	mask: bit_set[0 ..< 64;u64]
	mask += {int(linux.Signal.SIGINT) - 1}
	return transmute(linux.Sig_Set)mask
}

// chat_watched_signals masks every signal the interactive lifetime handles.
// SIGTERM joins SIGINT: with a handler installed the process quits orderly
// through the cancel flag instead of dying with state un-restored. Every
// non-execution thread inherits this mask at spawn and stays ineligible.
chat_watched_signals :: proc() -> linux.Sig_Set {
	mask: bit_set[0 ..< 64;u64]
	mask += {int(linux.Signal.SIGINT) - 1, int(linux.Signal.SIGTERM) - 1}
	return transmute(linux.Sig_Set)mask
}

chat_cancel_reset :: proc() {
	blocked := chat_watched_signals()
	previous: linux.Sig_Set
	_ = linux.rt_sigprocmask(.SIG_BLOCK, &blocked, &previous)
	ai.interrupt_reset(&chat_cancel)
	_ = linux.rt_sigprocmask(.SIG_SETMASK, &previous, nil)
}

chat_cancel_request :: proc() { ai.interrupt_request(&chat_cancel) }
chat_cancel_requested :: proc() -> bool { return ai.interrupt_requested(&chat_cancel) }

chat_signal_interrupt :: proc "c" (signal: posix.Signal) {
	// Written directly rather than through the helper so the whole handler path is
	// contextless: a signal handler cannot depend on a context.
	ai.interrupt_request(&chat_cancel)
}

// chat_signal_arm installs the handler only while a turn is in flight, so
// cancellation targets the active turn and Ctrl-C keeps its default meaning at the
// prompt instead of being swallowed.
//
// Installation goes through libc rather than linux.rt_sigaction. A restorer must not
// adjust rsp before `rt_sigreturn`, because the kernel reads the saved signal frame
// from rsp, and Odin's `linux.rt_sigreturn` is only prologue-free while nothing
// instruments it: at -sanitize:address it acquires `push %rax` and corrupts the frame,
// and at -sanitize:thread `@(no_sanitize_thread)` is available but does not suppress
// the injected `__tsan_func_entry`, so no Odin-level attribute makes it usable. An
// instrumented restorer is not a restorer. glibc's is authored assembly that no
// sanitizer instruments, and it is verified to work under default, -debug, address,
// memory, and thread builds. odin-lang/Odin#7533 tracks the core:sys/linux defect. The
// mask operations below use no restorer at all and stay native.
chat_signal_arm :: proc(previous: ^posix.sigaction_t) {
	action: posix.sigaction_t
	action.sa_handler = chat_signal_interrupt
	// Deliberately no SA_RESTART: an interrupted wait should observe the signal and
	// let the transport's wait hook report cancellation rather than resume.
	_ = posix.sigaction(.SIGINT, &action, previous)
}

// chat_signal_disarm restores the previous disposition. Nothing is freed and no
// pointer is cleared, because the handler references only chat_cancel: a signal
// that arrives while this runs either sets the token or terminates the process
// under the restored default, and neither can reach stale memory.
chat_signal_disarm :: proc(previous: ^posix.sigaction_t) {
	if previous == nil { return }
	_ = posix.sigaction(.SIGINT, previous, nil)
}

Chat_Interactive_Signals :: struct {
	previous_int:  posix.sigaction_t,
	previous_term: posix.sigaction_t,
}

// chat_interactive_arm installs the cancel handler for the whole interactive
// lifetime, so idle Ctrl-C quits cleanly instead of dying mid-prompt, and a
// SIGTERM settles through the same flag. Per-turn arming nests inside this
// and restores it afterwards.
chat_interactive_arm :: proc(state: ^Chat_Interactive_Signals) {
	action: posix.sigaction_t
	action.sa_handler = chat_signal_interrupt
	_ = posix.sigaction(.SIGINT, &action, &state.previous_int)
	_ = posix.sigaction(.SIGTERM, &action, &state.previous_term)
}

chat_interactive_disarm :: proc(state: ^Chat_Interactive_Signals) {
	if state == nil { return }
	_ = posix.sigaction(.SIGINT, &state.previous_int, nil)
	_ = posix.sigaction(.SIGTERM, &state.previous_term, nil)
}

// chat_signal_block_current masks SIGINT on the calling thread, which is how a
// thread that must not run the handler is kept ineligible for its whole lifetime.
chat_signal_block_current :: proc() {
	blocked := chat_signal_int_set()
	_ = linux.rt_sigprocmask(.SIG_BLOCK, &blocked, nil)
}

// chat_signal_block_watched blocks every signal the interactive lifetime handles
// and stores the caller's previous mask. A thread inherits the mask its creator
// had at the moment it was created, so a worker that must never run the process
// handler is created while these are blocked, and the creator restores its own
// mask afterwards.
chat_signal_block_watched :: proc(previous: ^linux.Sig_Set) {
	blocked := chat_watched_signals()
	_ = linux.rt_sigprocmask(.SIG_BLOCK, &blocked, previous)
}

chat_signal_restore :: proc(previous: linux.Sig_Set) {
	mask := previous
	_ = linux.rt_sigprocmask(.SIG_SETMASK, &mask, nil)
}
