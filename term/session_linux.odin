#+build linux
#+private
package term

import "core:c"
import "core:io"
import "core:os"
import "core:sys/linux"
import "core:sys/posix"

// Session_Impl is the Linux session state: the controlling-terminal
// descriptor, the saved termios and file flags, and the entered terminal
// modes. It mirrors core:os's File_Impl split (portable handle plus
// per-platform state, os/file_linux.odin) and is the platform file of the
// session extension, equivalent to terminal_posix.odin for the copied base.
Session_Impl :: struct {
	file:                ^os.File,
	original_termios:    posix.termios,
	original_file_flags: c.int,
	file_flags_changed:  bool,
	termios_saved:       bool,
	mode_applied:        bool,
	// alt_screen_entered and cursor_hidden mean "transition attempted": they
	// are set before the write, so rollback and close always emit the
	// compensating sequence even for a partially written one.
	alt_screen_entered:  bool,
	cursor_hidden:       bool,
	sigwinch_installed:  bool,
	previous_sigaction:  posix.sigaction_t,
}

// Control-sequence literals. Every sequence starts with a real ESC (0x1B);
// the byte-output test asserts this so a mangled literal cannot slip
// through again. The ansi subpackage is not imported here: its package name
// collides with core:terminal/ansi once core:testing is linked (see
// doc.odin).
ALT_SCREEN_ENTER :: "\e[?1049h\e[H"
ALT_SCREEN_LEAVE :: "\e[?1049l"
CURSOR_HIDE :: "\e[?25l"
CURSOR_SHOW :: "\e[?25h"

Linux_Window_Size :: struct {
	rows, columns, x_pixels, y_pixels: u16,
}

// _errno surfaces the current thread's errno as the package's Platform_Error
// (linux.Errno). posix calls report failure through their return status; the
// cause always lives in errno, and the error model preserves it instead of
// collapsing into a stage name.
_errno :: #force_inline proc "contextless" () -> Platform_Error {
	return Platform_Error(linux.Errno(i32(c.int(posix.get_errno()))))
}

// session_active implements the one-active-session contract: a second open
// fails with .Already_Open before touching the terminal.
@(private = "file")
session_active: bool

// sigwinch_pending is set by the SIGWINCH handler; the handler does no I/O.
// The demo re-reads the viewport every frame, so nothing consumes the flag
// yet — it is the resize-notification seam.
@(private = "file")
sigwinch_pending: bool

// atexit state: the exact saved termios plus the tty fd, restored on
// abnormal exits as a best-effort safety net (raw_console pattern,
// examples/console/raw_console/raw_posix.odin). POSIX atexit cannot
// unregister, so the callback is registered once per process; atexit_active
// is true only while the session still owns its descriptor — it is disarmed
// the moment the one-shot descriptor close consumes the handle, success or
// failure, so a consumed (and possibly reused) fd never receives the saved
// termios at exit.
@(private = "file")
atexit_termios: posix.termios

@(private = "file")
atexit_fd: posix.FD

@(private = "file")
atexit_active: bool

@(private = "file")
atexit_registered: bool

_session_open :: proc(s: ^Session, options: Options) -> (err: Error) {
	if session_active {
		return General_Error.Already_Open
	}
	impl := &s.impl
	file, open_err := os.open("/dev/tty", {.Read, .Write})
	if open_err != nil {
		// A missing /dev/tty is the semantic "no controlling terminal"
		// state; any other open cause is preserved.
		errno := linux.Errno(i32(c.int(posix.get_errno())))
		if errno == .ENOENT || errno == .ENXIO {
			return General_Error.No_Controlling_Tty
		}
		return Platform_Error(errno)
	}
	impl.file = file
	defer if !session_active {
		// The rollback descriptor-close cause surfaces only when no setup
		// cause precedes it: the defer runs exclusively on failure paths, so
		// the setup cause is the primary one today, and the guard keeps a
		// future failure after the last setup step from swallowing the close
		// cause.
		if rollback_err := _session_rollback(impl); err == nil {
			err = rollback_err
		}
	}

	if !os.is_tty(file) {
		return General_Error.Not_A_Tty
	}
	fd := posix.FD(os.fd(file))

	// Raw input mode is an explicit opt-in (.Raw): it saves and replaces the
	// termios, sets the descriptor nonblocking for the drain-until-EAGAIN
	// input path, and arms the atexit termios safety net. .Unchanged leaves
	// the input configuration entirely alone.
	if options.input_mode == .Raw {
		if posix.tcgetattr(fd, &impl.original_termios) != .OK {
			return _errno()
		}
		impl.termios_saved = true

		// Nonblocking mode: the input stage drains reads until EAGAIN. The
		// original flags are saved and restored on teardown.
		flags := posix.fcntl(fd, .GETFL)
		if flags < 0 {
			return _errno()
		}
		impl.original_file_flags = flags
		if posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK)) < 0 {
			return _errno()
		}
		impl.file_flags_changed = true

		// Narrow TUI profile: clear echo/canonical/signals/extended, input and
		// output postprocessing; retain all unrelated bits; VMIN=1 VTIME=0.
		raw := impl.original_termios
		raw.c_lflag -= {.ECHO, .ECHONL, .ICANON, .IEXTEN, .ISIG}
		raw.c_iflag -= {.ICRNL, .INLCR, .IGNCR, .IXON}
		raw.c_oflag -= {.OPOST}
		raw.c_cc[.VMIN] = 1
		raw.c_cc[.VTIME] = 0
		if posix.tcsetattr(fd, .TCSAFLUSH, &raw) != .OK {
			return _errno()
		}
		impl.mode_applied = true

		atexit_termios = impl.original_termios
		atexit_fd = fd
		atexit_active = true
		if !atexit_registered {
			posix.atexit(_session_atexit_restore)
			atexit_registered = true
		}
	}

	if options.alternate_screen {
		// Mark the transition before writing: a partial write may still have
		// entered the alternate screen, and the rollback must compensate.
		impl.alt_screen_entered = true
		if write_err := _session_write(file, ALT_SCREEN_ENTER); write_err != nil {
			return write_err
		}
	}
	if options.hide_cursor {
		impl.cursor_hidden = true
		if write_err := _session_write(file, CURSOR_HIDE); write_err != nil {
			return write_err
		}
	}

	_session_install_sigwinch(impl)

	session_active = true
	return nil
}

// _session_close_file releases the session descriptor through core:os and
// converts its error into the package Error. core:os's close consumes the
// handle — the stream layer destroys the File_Impl on every result except
// EBADF — so the descriptor close is one-shot, never retried through the
// same pointer. The raw errno (os.Platform_Error) passes through as the
// faithful low-level cause; the few semantic folds core:os applies (close
// can hit .Invalid_File for an already-closed descriptor) map onto io.Error.
_session_close_file :: proc(file: ^os.File) -> Error {
	os_err := os.close(file)
	when #config(NABLA_TERM_TEST_HOOKS, false) {
		if _test_fail_close_once {
			_test_fail_close_once = false
			return Platform_Error(.EIO)
		}
	}
	if os_err == nil {
		return nil
	}
	#partial switch e in os_err {
	case os.Platform_Error:
		return Platform_Error(e)
	case os.General_Error:
		#partial switch e {
		case .Invalid_File:
			return io.Error(.Closed)
		case:
			return io.Error(.Unknown)
		}
	case io.Error:
		return e
	}
	return io.Error(.Unknown)
}

// _session_rollback reverses every entered transition and closes the
// descriptor. Used only from failed setup paths (the open defer), it
// mirrors _session_close's discipline: attempt every compensation, clear a
// flag only when its compensation succeeded, report the first cause. open's
// single error channel already carries the setup cause (which the error
// contract requires to survive), so the returned cause surfaces only when
// no setup cause precedes it; the SIGWINCH flag in particular clears only
// on a successful restore, because an armed handler outliving the discarded
// session is a process-wide hazard, not bookkeeping.
_session_rollback :: proc(impl: ^Session_Impl) -> Error {
	first_error: Error = nil
	if impl.cursor_hidden {
		if err := _session_write(impl.file, CURSOR_SHOW); err != nil {
			if first_error == nil {
				first_error = err
			}
		} else {
			impl.cursor_hidden = false
		}
	}
	if impl.alt_screen_entered {
		if err := _session_write(impl.file, ALT_SCREEN_LEAVE); err != nil {
			if first_error == nil {
				first_error = err
			}
		} else {
			impl.alt_screen_entered = false
		}
	}
	if impl.mode_applied {
		if posix.tcsetattr(posix.FD(os.fd(impl.file)), .TCSAFLUSH, &impl.original_termios) != .OK {
			if first_error == nil {
				first_error = _errno()
			}
		} else {
			impl.mode_applied = false
		}
	}
	impl.termios_saved = false
	if impl.file_flags_changed {
		if posix.fcntl(posix.FD(os.fd(impl.file)), .SETFL, impl.original_file_flags) < 0 {
			if first_error == nil {
				first_error = _errno()
			}
		} else {
			impl.file_flags_changed = false
		}
	}
	if impl.sigwinch_installed {
		if posix.sigaction(posix.Signal(posix.SIGWINCH), &impl.previous_sigaction, nil) != .OK {
			if first_error == nil {
				first_error = _errno()
			}
		} else {
			impl.sigwinch_installed = false
		}
	}
	if impl.file != nil {
		if close_err := _session_close_file(impl.file); close_err != nil {
			if first_error == nil {
				first_error = close_err
			}
		}
		impl.file = nil
	}
	atexit_active = false
	return first_error
}

// _session_close tears down in reverse setup order, attempting every
// applicable transition even after a failure. A transition flag is cleared
// only when its compensation succeeded; on any failure the descriptor and
// the un-compensated transitions are left in place so close can be retried,
// and the first underlying cause is reported (the write path's own error,
// or the Platform_Error/io.Error from the failed syscall). The descriptor
// close itself is one-shot (core:os consumes the handle); a failure there
// is reported and the fully-compensated session settles on the next close.
_session_close :: proc(s: ^Session) -> Error {
	when #config(NABLA_TERM_TEST_HOOKS, false) {
		if _test_fail_teardown_once {
			_test_fail_teardown_once = false
			return Platform_Error(.EIO)
		}
	}
	impl := &s.impl
	first_error: Error = nil
	fd := posix.FD(os.fd(impl.file))
	if impl.cursor_hidden {
		if err := _session_write(impl.file, CURSOR_SHOW); err != nil {
			if first_error == nil {
				first_error = err
			}
		} else {
			impl.cursor_hidden = false
		}
	}
	if impl.alt_screen_entered {
		if err := _session_write(impl.file, ALT_SCREEN_LEAVE); err != nil {
			if first_error == nil {
				first_error = err
			}
		} else {
			impl.alt_screen_entered = false
		}
	}
	if impl.mode_applied {
		if posix.tcsetattr(fd, .TCSAFLUSH, &impl.original_termios) != .OK {
			if first_error == nil {
				first_error = _errno()
			}
		} else {
			impl.mode_applied = false
		}
	}
	if impl.file_flags_changed {
		if posix.fcntl(fd, .SETFL, impl.original_file_flags) < 0 {
			if first_error == nil {
				first_error = _errno()
			}
		} else {
			impl.file_flags_changed = false
		}
	}
	if impl.sigwinch_installed {
		if posix.sigaction(posix.Signal(posix.SIGWINCH), &impl.previous_sigaction, nil) != .OK {
			if first_error == nil {
				first_error = _errno()
			}
		} else {
			impl.sigwinch_installed = false
		}
	}
	if first_error != nil {
		return first_error
	}
	if impl.file != nil {
		// The descriptor close is one-shot: core:os destroys the File_Impl
		// on every result except EBADF, so a failure cannot be retried
		// through the same pointer. Report the cause (the session stays
		// allocated); the fully-compensated session settles on the next
		// close, which is retryable until it succeeds.
		first_error = _session_close_file(impl.file)
		impl.file = nil
	}
	// The termios was already restored above, so the atexit net is disarmed
	// the moment the descriptor is consumed — regardless of the close result,
	// the fd may already be gone (or reused), and a saved termios must never
	// be applied to an unrelated file at process exit.
	atexit_active = false
	if first_error != nil {
		return first_error
	}
	session_active = false
	return nil
}

// _session_present writes the whole frame through the shared write loop.
// The write reports its committed byte count; the caller surfaces it
// through present's committed result.
_session_present :: proc(s: ^Session, bytes: []byte) -> (committed: int, err: Error) {
	if s.impl.file == nil {
		return 0, General_Error.Not_Open
	}
	return _session_write_bytes(posix.FD(os.fd(s.impl.file)), bytes)
}

// _session_write_bytes writes all of bytes to fd, retrying EINTR, waiting
// for POLLOUT on EAGAIN (the tty is O_NONBLOCK), and completing short
// writes. Frames and control sequences share this path, so a transient
// short write cannot leave a setup or teardown sequence half-applied.
// Nonzero write failures preserve their Platform_Error cause; a write that
// returns zero while bytes remain is the one narrow Partial_Write case
// (no errno exists to preserve).
_session_write_bytes :: proc(fd: posix.FD, bytes: []byte) -> (committed: int, err: Error) {
	offset := 0
	for offset < len(bytes) {
		when #config(NABLA_TERM_TEST_HOOKS, false) {
			if _test_zero_write_once {
				_test_zero_write_once = false
				return offset, General_Error.Partial_Write
			}
		}
		remaining := len(bytes) - offset
		n := posix.write(fd, raw_data(bytes[offset:]), c.size_t(remaining))
		if n < 0 {
			#partial switch posix.get_errno() {
			case .EINTR:
				continue
			case .EAGAIN:
				wait_ok, poll_err := _session_poll_out(fd)
				if !wait_ok {
					return offset, poll_err
				}
				continue
			case:
				return offset, _errno()
			}
		}
		if n == 0 {
			return offset, General_Error.Partial_Write
		}
		offset += int(n)
		committed = offset
	}
	return offset, nil
}

// _session_poll_out waits (blocking) until the descriptor is writable. A
// poll failure preserves its Platform_Error cause; EINTR is retried. There
// is no separate public poll-error channel: the write path surfaces this
// cause directly.
_session_poll_out :: proc(fd: posix.FD) -> (ok: bool, err: Error) {
	for {
		pfd := posix.pollfd {
			fd     = fd,
			events = {.OUT},
		}
		n := posix.poll(&pfd, 1, -1)
		if n >= 0 {
			return true, nil
		}
		if posix.get_errno() == .EINTR {
			continue
		}
		return false, _errno()
	}
}

_session_viewport :: proc(s: ^Session) -> (result: Viewport, err: Error) {
	if s.impl.file == nil {
		return {}, General_Error.Not_Open
	}
	size: Linux_Window_Size
	if linux.ioctl(linux.Fd(os.fd(s.impl.file)), u32(linux.TIOCGWINSZ), uintptr(rawptr(&size))) != 0 {
		return {}, _errno()
	}
	if size.columns == 0 || size.rows == 0 {
		// The tty reported no size: a semantic "no data" cause rather than
		// a fabricated viewport.
		return {}, Platform_Error(.ENODATA)
	}
	result.columns = int(size.columns)
	result.rows = int(size.rows)
	return
}

_session_file :: proc(s: ^Session) -> (file: ^os.File, err: Error) {
	return s.impl.file, nil
}

_session_write :: proc(file: ^os.File, text: string) -> Error {
	_, err := _session_write_bytes(posix.FD(os.fd(file)), transmute([]byte)text)
	return err
}

_session_atexit_restore :: proc "c" () {
	// No-op after a normal close: the termios is already restored and the
	// saved fd may have been reused by an unrelated file.
	if atexit_active {
		_ = posix.tcsetattr(atexit_fd, .TCSAFLUSH, &atexit_termios)
	}
}

_session_sigwinch_handler :: proc "c" (sig: posix.Signal) {
	sigwinch_pending = true
}

_session_install_sigwinch :: proc(impl: ^Session_Impl) {
	action := posix.sigaction_t {
		sa_handler = _session_sigwinch_handler,
	}
	if posix.sigaction(posix.Signal(posix.SIGWINCH), &action, &impl.previous_sigaction) == .OK {
		impl.sigwinch_installed = true
	}
}
