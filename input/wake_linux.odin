#+build linux
package input

import "core:sys/linux"

// wake_make creates a wake descriptor: a non-blocking, close-on-exec eventfd that
// read_events polls beside the terminal. Release it with wake_destroy.
@(require_results)
wake_make :: proc() -> (fd: int, err: Error) {
	wake, errno := linux.eventfd(0, {.NONBLOCK, .CLOEXEC})
	if errno != .NONE {
		return -1, errno
	}
	return int(wake), nil
}

// wake_signal makes the descriptor readable, so a read_events call polling it returns.
// It never blocks and is async-signal-safe. A failed write is not an error: the only
// failure of a non-blocking eventfd add is a counter that is already full, which means
// the descriptor is readable.
wake_signal :: proc "contextless" (fd: int) {
	one := u64(1)
	_, _ = linux.write(linux.Fd(fd), ([^]u8)(&one)[:size_of(one)])
}

// wake_drain clears a signalled descriptor so the next poll waits again. The caller
// drains before it reads the state the signal announces, so a signal that arrives
// after the drain is never lost. An empty descriptor is not an error.
wake_drain :: proc(fd: int) {
	count: u64
	_, _ = linux.read(linux.Fd(fd), ([^]u8)(&count)[:size_of(count)])
}

// wake_destroy closes the descriptor. A failed close of an eventfd leaves nothing to
// recover, so it reports nothing.
wake_destroy :: proc(fd: int) {
	_ = linux.close(linux.Fd(fd))
}
