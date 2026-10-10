package term

// set_resize_wake registers a descriptor that the SIGWINCH handler writes a u64 1 to
// when the terminal is resized, so a thread blocked in poll on another descriptor
// wakes. fd must be a non-blocking eventfd, and -1 clears the registration. The
// caller clears it before closing the descriptor. Clearing waits for handlers that
// borrowed the old fd to finish writing. Calls must be serialized and must not run
// from a signal handler. viewport remains authoritative: the write only wakes the
// caller. A frame write blocked on the terminal also polls fd and returns
// General_Error.Superseded once it is readable, without reading it, so present must
// not run on another thread than the calls that register fd. A target without a
// terminal backend ignores it.
set_resize_wake :: proc(fd: int) {
	_session_set_resize_wake(fd)
}
