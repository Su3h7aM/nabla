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
// It never blocks and is async-signal-safe. fd must remain open until it returns.
// A full counter is already readable; an interrupted write is retried.
wake_signal :: proc "contextless" (fd: int) {
	one := u64(1)
	for {
		_, error := linux.write(linux.Fd(fd), ([^]u8)(&one)[:size_of(one)])
		if error != .EINTR { return }
	}
}

// wake_drain clears a signalled descriptor so the next poll waits again. The caller
// drains before it reads the state the signal announces, so a signal that arrives
// after the drain is never lost. An empty descriptor is not an error.
wake_drain :: proc(fd: int) {
	count: u64
	for {
		_, error := linux.read(linux.Fd(fd), ([^]u8)(&count)[:size_of(count)])
		if error != .EINTR { return }
	}
}

// wake_destroy closes the descriptor. A failed close of an eventfd leaves nothing to
// recover, so it reports nothing.
wake_destroy :: proc(fd: int) {
	_ = linux.close(linux.Fd(fd))
}
