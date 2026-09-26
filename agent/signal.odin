package agent

import "core:sync"
import linux "core:sys/linux"
import "core:sys/posix"

// process_interrupt latches a SIGINT or SIGTERM: the process was asked to stop. A signal
// handler may only write static storage, so this is the one process-wide stop; the owner
// applies it to the turn it runs, and the root ends the process once no turn runs.
@(private)
process_interrupt: bool

process_interrupted :: proc "contextless" () -> bool {
	return sync.atomic_load(&process_interrupt)
}

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

chat_signal_interrupt :: proc "c" (signal: posix.Signal) {
	sync.atomic_store(&process_interrupt, true)
	owner_wake_signal()
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

// chat_signal_disarm restores the previous disposition. The handler references only
// static storage, so a signal that arrives while this runs either latches the
// interrupt or terminates the process under the restored default.
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
