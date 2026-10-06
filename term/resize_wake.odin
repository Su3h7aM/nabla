package term

// set_resize_wake registers a descriptor that the SIGWINCH handler writes a u64 1 to
// when the terminal is resized, so a thread blocked in poll on another descriptor
// wakes. fd must be a non-blocking eventfd, and -1 clears the registration. The
// caller clears it before closing the descriptor. The flag and viewport stay the
// source of truth: the write only wakes the caller. A target without a terminal
// backend ignores it.
set_resize_wake :: proc(fd: int) {
	_session_set_resize_wake(fd)
}
