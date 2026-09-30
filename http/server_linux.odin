#+build linux
package http

import "core:os"
import "core:sys/linux"

@(private)
interrupt_notify_fd: linux.Fd = -1

@(private)
interrupt_notify_signal :: proc "c" (_: linux.Signal) {
	// write is async-signal-safe; the byte only makes the pipe readable.
	signaled := [1]u8{1}
	_, _ = linux.write(interrupt_notify_fd, signaled[:])
}

// interrupt_notify_install makes SIGINT write one byte to notify, which must stay
// open for as long as the handler can run. The handler is process-wide, so one
// notification pipe serves the whole program.
@(private, require_results)
interrupt_notify_install :: proc(notify: ^os.File) -> os.Error {
	interrupt_notify_fd = linux.Fd(os.fd(notify))

	// rt_sigaction supplies the restorer and its flag on x86_64.
	action := linux.Sig_Action {
		handler = interrupt_notify_signal,
	}
	if errno := linux.rt_sigaction(.SIGINT, &action, nil); errno != .NONE {
		return os.Platform_Error(errno)
	}
	return nil
}
