#+build !linux
package agent

// Targets without signal dispositions have nothing to install, save, or mask.

Signal_Action :: struct {}

Signal_Mask :: struct {}

@(private)
signal_action_install :: proc(signal: Signal, previous: ^Signal_Action) {  }

@(private)
signal_wake_write :: proc "contextless" (fd: int) {  }

@(private)
signal_action_restore :: proc(signal: Signal, previous: ^Signal_Action) {  }

@(private)
signal_mask_block :: proc(signals: bit_set[Signal]) -> (previous: Signal_Mask) {
	return {}
}

@(private)
signal_mask_set :: proc(mask: Signal_Mask) {  }
