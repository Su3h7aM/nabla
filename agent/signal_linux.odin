#+build linux
package agent

import "core:sys/linux"

// Signal_Action is the saved disposition of one signal. The zero value holds the default.
Signal_Action :: linux.Sig_Action

// Signal_Mask is the set of signals a thread blocks. The zero value blocks none.
Signal_Mask :: linux.Sig_Set

@(private = "file")
signal_number :: proc "contextless" (signal: Signal) -> linux.Signal {
	switch signal {
	case .Interrupt:
		return .SIGINT
	case .Terminate:
		return .SIGTERM
	case .Hangup:
		return .SIGHUP
	}
	return .SIGINT
}

@(private = "file")
signal_handler :: proc "c" (signal: linux.Signal) {
	signal_interrupt_latch()
}

// signal_wake_write adds 1 to an eventfd. A full counter means the descriptor is already
// readable, so a failed write loses nothing.
@(private)
signal_wake_write :: proc "contextless" (fd: int) {
	one := u64(1)
	for {
		_, error := linux.write(linux.Fd(fd), ([^]u8)(&one)[:size_of(one)])
		if error != .EINTR { return }
	}
}

// signal_action_install routes signal to signal_interrupt_latch and saves the disposition it
// replaces in previous. The handler is installed without SA_RESTART. A disposition that cannot
// be installed leaves the default in place.
@(private)
signal_action_install :: proc(signal: Signal, previous: ^Signal_Action) {
	action: linux.Sig_Action
	action.handler = signal_handler
	_ = linux.rt_sigaction(signal_number(signal), &action, previous)
}

// signal_action_restore puts a saved disposition back.
@(private)
signal_action_restore :: proc(signal: Signal, previous: ^Signal_Action) {
	_ = linux.rt_sigaction(signal_number(signal), previous, nil)
}

// signal_mask_block blocks signals on the calling thread and returns its previous mask. A mask
// that cannot be set leaves the thread exposed.
@(private)
signal_mask_block :: proc(signals: bit_set[Signal]) -> (previous: Signal_Mask) {
	blocked: linux.Sig_Set
	for signal in signals {
		// Signal numbers start at 1, so signal n is bit n-1 of the set.
		bit := uint(signal_number(signal)) - 1
		blocked[bit / (8 * size_of(uint))] |= 1 << (bit % (8 * size_of(uint)))
	}
	_ = linux.rt_sigprocmask(.SIG_BLOCK, &blocked, &previous)
	return
}

// signal_mask_set replaces the calling thread's mask.
@(private)
signal_mask_set :: proc(mask: Signal_Mask) {
	mask := mask
	_ = linux.rt_sigprocmask(.SIG_SETMASK, &mask, nil)
}
