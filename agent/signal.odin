package agent

import "core:sys/posix"

import "nabla:ai"

// process_interrupt latches a SIGINT or SIGTERM: the process was asked to stop. A signal
// handler may only write static storage, so this is the one process-wide stop; the owner
// applies it to the turn it runs, and the root ends the process once no turn runs.
// Every turn's stop chains to it, so a wait blocked inside the turn sees it at once.
@(private)
process_interrupt: ai.Interrupt

process_interrupted :: proc "contextless" () -> bool {
	return ai.interrupt_requested(&process_interrupt)
}

chat_signal_interrupt :: proc "c" (signal: posix.Signal) {
	ai.interrupt_request(&process_interrupt)
	owner_wake_signal()
}

// chat_signal_arm installs the handler only while a turn is in flight, so a headless
// run keeps the default meaning of Ctrl-C while idle. The handler is installed without
// SA_RESTART, so an interrupted wait returns and observes the stop.
chat_signal_arm :: proc(previous: ^posix.sigaction_t) {
	action: posix.sigaction_t
	action.sa_handler = chat_signal_interrupt
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

// chat_interactive_arm installs the handler for the whole interactive lifetime, so
// SIGINT and SIGTERM end the process through the owner instead of killing it with the
// terminal unrestored. Per-turn arming nests inside this and restores it afterwards.
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

// chat_signal_block_watched blocks SIGINT and SIGTERM on the calling thread and returns
// its previous mask. A thread inherits its creator's mask, so a worker that must never
// run the handler is created between this and chat_signal_restore.
chat_signal_block_watched :: proc() -> (previous: posix.sigset_t) {
	blocked: posix.sigset_t
	posix.sigemptyset(&blocked)
	posix.sigaddset(&blocked, .SIGINT)
	posix.sigaddset(&blocked, .SIGTERM)
	_ = posix.pthread_sigmask(.BLOCK, &blocked, &previous)
	return
}

chat_signal_restore :: proc(previous: posix.sigset_t) {
	mask := previous
	_ = posix.pthread_sigmask(.SETMASK, &mask, nil)
}
