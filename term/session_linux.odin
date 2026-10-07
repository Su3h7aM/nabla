#+build linux
#+private
package term

import "core:io"
import "core:os"
import "core:sync"
import "core:sys/linux"
import "core:terminal/ansi"

// Session_Impl is the Linux session state: the controlling-terminal
// descriptor, the saved termios and file flags, and the entered terminal
// modes. It mirrors core:os's File_Impl split (portable handle plus
// per-platform state, os/file_linux.odin) and is the platform file of the
// session extension, equivalent to terminal_posix.odin for the copied base.
Session_Impl :: struct {
	file:                ^os.File,
	original_termios:    Termios,
	original_file_flags: linux.Open_Flags,
	file_flags_changed:  bool,
	mode_applied:        bool,
	// The transition flags mean "transition attempted": they are set before the
	// write, so rollback and close always emit the compensating sequence even
	// for a partially written one. cursor_hidden tracks only the open option;
	// close shows the cursor regardless, because a frame may have hidden it.
	alt_screen_entered:  bool,
	autowrap_disabled:   bool,
	bracketed_paste:     bool,
	mouse:               bool,
	cursor_hidden:       bool,
	sigwinch_installed:  bool,
	previous_sigaction:  linux.Sig_Action,
}

// Control sequences, composed from core:terminal/ansi constants rather than
// hand-written literals, so a mistyped mode is a compile error and the whole
// repository shares one definition. The byte-output test asserts they start
// with a real ESC (0x1B).
ALT_SCREEN_ENTER :: ansi.CSI + ansi.DECASB_ENTER + ansi.CSI + ansi.CUP
ALT_SCREEN_LEAVE :: ansi.CSI + ansi.DECASB_EXIT
CURSOR_HIDE :: ansi.CSI + ansi.DECTCEM_HIDE
CURSOR_SHOW :: ansi.CSI + ansi.DECTCEM_SHOW
SGR_RESET :: ansi.CSI + "0" + ansi.SGR
// The session disables autowrap (DECAWM) for its lifetime: the frame path may
// write the bottom-right cell, and with autowrap on that write can scroll the
// viewport. Disabling it is what lets present write every cell, including a
// wide character that spans the final two columns of the last row. The
// session does not query the mode: it assumes autowrap is on at entry and
// enables it on close (the documented baseline in doc.odin), so a terminal
// that entered with autowrap off is left with it on.
AUTOWRAP_OFF :: ansi.CSI + ansi.DECAWM_OFF
AUTOWRAP_ON :: ansi.CSI + ansi.DECAWM_ON
// Bracketed paste (DECSET 2004). core:terminal/ansi has no constant for it, so
// the mode is composed here. Like autowrap, the mode is baseline-assumed
// rather than queried: close sends the off sequence, so a terminal that
// entered with bracketed paste on is left with it off. It is best-effort: a
// crash that skips close leaves the mode on until the terminal resets, which
// is the same hazard every full-screen program carries.
BRACKETED_PASTE_ON :: ansi.CSI + "?2004h"
BRACKETED_PASTE_OFF :: ansi.CSI + "?2004l"
// Mouse reporting (DECSET 1002 button-event tracking with 1006 SGR extended
// coordinates). core:terminal/ansi has no constants for these either, so the
// modes are composed here like bracketed paste. Like the other modes the pair
// is baseline-assumed rather than queried: close sends the off sequences,
// leaving mouse reporting off even if the terminal had it on at entry.
MOUSE_ON :: ansi.CSI + "?1002h" + ansi.CSI + "?1006h"
MOUSE_OFF :: ansi.CSI + "?1006l" + ansi.CSI + "?1002l"

Linux_Window_Size :: struct {
	rows, columns, x_pixels, y_pixels: u16,
}

// session_active implements the one-active-session contract: a second open
// fails with .Already_Open before touching the terminal.
@(private = "file")
session_active: bool

// sigwinch_wake is the descriptor the SIGWINCH handler writes to, or -1. The handler
// can run on any thread, so without the write a resize would not end a poll that
// another thread is blocked in.
@(private = "file")
sigwinch_wake: i32 = -1

@(private = "file")
sigwinch_wake_readers: sync.Futex

_session_set_resize_wake :: proc(fd: int) {
	sync.atomic_store(&sigwinch_wake, -1)
	for readers := sync.atomic_load(&sigwinch_wake_readers); readers != 0; readers = sync.atomic_load(&sigwinch_wake_readers) {
		sync.futex_wait(&sigwinch_wake_readers, u32(readers))
	}
	sync.atomic_store(&sigwinch_wake, i32(fd))
}

// fini state: the exact saved termios plus the tty fd, restored by the
// @(fini) hook below. atexit_active is true only while the session still owns
// its descriptor: it is disarmed the moment the one-shot descriptor close
// consumes the handle, success or failure, so a consumed (and possibly
// reused) fd never receives the saved termios at exit.
@(private = "file")
atexit_termios: Termios

@(private = "file")
atexit_fd: linux.Fd

@(private = "file")
atexit_active: bool

@(require_results)
_session_open :: proc(session: ^Session, options: Options) -> (err: Error) {
	if session_active {
		return General_Error.Already_Open
	}
	impl := &session.impl
	file, open_err := os.open("/dev/tty", {.Read, .Write})
	if open_err != nil {
		// A missing /dev/tty is the semantic "no controlling terminal"
		// state; any other open cause is preserved.
		if platform, ok := open_err.(os.Platform_Error); ok {
			if platform == .ENOENT || platform == .ENXIO {
				return General_Error.No_Controlling_Tty
			}
			return platform
		}
		if open_err == os.General_Error.Not_Exist {
			return General_Error.No_Controlling_Tty
		}
		return io.Error.Unknown
	}
	impl.file = file
	defer if !session_active {
		if rollback_err := _session_rollback(impl); err == nil {
			err = rollback_err
		}
	}

	if !os.is_tty(file) {
		return General_Error.Not_A_Tty
	}
	fd := linux.Fd(os.fd(file))

	// .Raw saves and replaces the termios and sets the descriptor nonblocking.
	if options.input_mode == .Raw {
		if errno := _tcgetattr(fd, &impl.original_termios); errno != .NONE {
			return Platform_Error(errno)
		}

		// Nonblocking mode: the input stage drains reads until EAGAIN. The
		// original flags are saved and restored on teardown.
		flags, flags_errno := linux.fcntl_getfl(fd, .GETFL)
		if flags_errno != .NONE {
			return Platform_Error(flags_errno)
		}
		impl.original_file_flags = flags
		if errno := linux.fcntl_setfl(fd, .SETFL, flags + {.NONBLOCK}); errno != .NONE {
			return Platform_Error(errno)
		}
		impl.file_flags_changed = true

		// Narrow TUI profile: clear echo/canonical/signals/extended, input and
		// output postprocessing; retain all unrelated bits; VMIN=1 VTIME=0.
		raw := impl.original_termios
		raw.c_lflag &~= ECHO | ECHONL | ICANON | IEXTEN | ISIG
		raw.c_iflag &~= ICRNL | INLCR | IGNCR | IXON
		raw.c_oflag &~= OPOST
		raw.c_cc[VMIN] = 1
		raw.c_cc[VTIME] = 0
		if errno := _tcsetattr(fd, TCSAFLUSH, &raw); errno != .NONE {
			return Platform_Error(errno)
		}
		impl.mode_applied = true

		atexit_termios = impl.original_termios
		atexit_fd = fd
		atexit_active = true
	}

	if options.alternate_screen {
		// Mark the transition before writing: a partial write may still have
		// entered the alternate screen, and the rollback must compensate.
		impl.alt_screen_entered = true
		if write_err := _session_write(file, ALT_SCREEN_ENTER); write_err != nil {
			return write_err
		}
	}
	// Autowrap is always disabled: the session exists to present frames, and a
	// frame writes the bottom-right cell. See AUTOWRAP_OFF.
	impl.autowrap_disabled = true
	if write_err := _session_write(file, AUTOWRAP_OFF); write_err != nil {
		return write_err
	}
	if options.bracketed_paste {
		impl.bracketed_paste = true
		if write_err := _session_write(file, BRACKETED_PASTE_ON); write_err != nil {
			return write_err
		}
	}
	if options.mouse {
		impl.mouse = true
		if write_err := _session_write(file, MOUSE_ON); write_err != nil {
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
@(require_results)
_session_close_file :: proc(file: ^os.File) -> Error {
	close_error := os.close(file)
	when #config(NABLA_TERM_TEST_HOOKS, false) {
		if _test_fail_close_once {
			_test_fail_close_once = false
			return Platform_Error(.EIO)
		}
	}
	if close_error == nil {
		return nil
	}
	#partial switch os_error in close_error {
	case os.Platform_Error:
		return Platform_Error(os_error)
	case os.General_Error:
		#partial switch os_error {
		case .Invalid_File:
			return io.Error(.Closed)
		case:
			return io.Error(.Unknown)
		}
	case io.Error:
		return os_error
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
@(require_results)
_session_rollback :: proc(impl: ^Session_Impl) -> Error {
	first_error: Error
	_keep_first_error(&first_error, _session_undo(&impl.cursor_hidden, impl.file, CURSOR_SHOW, _session_write))
	_keep_first_error(&first_error, _session_restore(impl, _session_write))
	if impl.file != nil {
		_keep_first_error(&first_error, _session_close_file(impl.file))
		impl.file = nil
	}
	atexit_active = false
	return first_error
}

// _keep_first_error records err unless an earlier failure is already held.
_keep_first_error :: proc(first_error: ^Error, err: Error) {
	if first_error^ == nil {
		first_error^ = err
	}
}

// _session_undo writes the compensating sequence for one entered transition
// and clears its flag only when the write succeeded.
@(require_results)
_session_undo :: proc(entered: ^bool, file: ^os.File, text: string, write: proc(file: ^os.File, text: string) -> Error) -> Error {
	if !entered^ {
		return nil
	}
	err := write(file, text)
	if err == nil {
		entered^ = false
	}
	return err
}

// _session_restore reverses the terminal modes in reverse setup order,
// attempting every one, and returns the first failure. Each flag clears only
// when its compensation succeeded. The descriptor stays open.
@(require_results)
_session_restore :: proc(impl: ^Session_Impl, write: proc(file: ^os.File, text: string) -> Error) -> (first_error: Error) {
	_keep_first_error(&first_error, _session_undo(&impl.bracketed_paste, impl.file, BRACKETED_PASTE_OFF, write))
	_keep_first_error(&first_error, _session_undo(&impl.mouse, impl.file, MOUSE_OFF, write))
	_keep_first_error(&first_error, _session_undo(&impl.autowrap_disabled, impl.file, AUTOWRAP_ON, write))
	_keep_first_error(&first_error, _session_undo(&impl.alt_screen_entered, impl.file, ALT_SCREEN_LEAVE, write))
	if impl.mode_applied {
		if errno := _tcsetattr(linux.Fd(os.fd(impl.file)), TCSAFLUSH, &impl.original_termios); errno != .NONE {
			_keep_first_error(&first_error, Platform_Error(errno))
		} else {
			impl.mode_applied = false
		}
	}
	if impl.file_flags_changed {
		if errno := linux.fcntl_setfl(linux.Fd(os.fd(impl.file)), .SETFL, impl.original_file_flags); errno != .NONE {
			_keep_first_error(&first_error, Platform_Error(errno))
		} else {
			impl.file_flags_changed = false
		}
	}
	if impl.sigwinch_installed {
		if errno := linux.rt_sigaction(.SIGWINCH, &impl.previous_sigaction, nil); errno != .NONE {
			_keep_first_error(&first_error, Platform_Error(errno))
		} else {
			impl.sigwinch_installed = false
		}
	}
	return first_error
}

// _session_close tears down in reverse setup order, attempting every
// applicable transition even after a failure. A transition flag is cleared
// when its compensation succeeds or a terminal write reports EIO, which
// means its modes are no longer reachable. Other failures leave the
// descriptor and uncompensated transitions in place so close can be retried;
// the first underlying cause is reported. The descriptor close itself is
// one-shot (core:os consumes the handle); a failure there is reported and
// the fully-compensated session settles on the next close.
@(require_results)
_session_close :: proc(session: ^Session) -> Error {
	when #config(NABLA_TERM_TEST_HOOKS, false) {
		if _test_fail_teardown_once {
			_test_fail_teardown_once = false
			return Platform_Error(.EIO)
		}
	}
	impl := &session.impl
	first_error: Error
	// The cursor is part of the documented baseline: a presented frame may have
	// hidden it and a partial write leaves that unspecified, so close shows it
	// whenever the descriptor is still open, rather than tracking every frame's
	// intent. The descriptor guard keeps a retry after the one-shot descriptor
	// close from writing to a file the session no longer owns.
	if impl.file != nil {
		if err := _session_close_write(impl.file, CURSOR_SHOW + SGR_RESET); err != nil {
			_keep_first_error(&first_error, err)
		} else {
			impl.cursor_hidden = false
		}
	}
	_keep_first_error(&first_error, _session_restore(impl, _session_close_write))
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

// _session_present writes bytes (a frame or a clipboard sequence) through the
// shared write loop and reports the committed byte count.
@(require_results)
_session_present :: proc(session: ^Session, bytes: []byte) -> (committed: int, err: Error) {
	if session.impl.file == nil {
		return 0, General_Error.Not_Open
	}
	return _session_write_bytes(linux.Fd(os.fd(session.impl.file)), bytes)
}

// _session_write_bytes writes all of bytes to fd, retrying EINTR, waiting
// for POLLOUT on EAGAIN (the tty is O_NONBLOCK), and completing short
// writes. Frames and control sequences share this path, so a transient
// short write cannot leave a setup or teardown sequence half-applied.
// Nonzero write failures preserve their Platform_Error cause; a write that
// returns zero while bytes remain is the one narrow Partial_Write case
// (no errno exists to preserve).
@(require_results)
_session_write_bytes :: proc(fd: linux.Fd, bytes: []byte) -> (committed: int, err: Error) {
	offset := 0
	for offset < len(bytes) {
		when #config(NABLA_TERM_TEST_HOOKS, false) {
			if _test_write_eio_once {
				_test_write_eio_once = false
				return offset, Platform_Error(.EIO)
			}
			if _test_zero_write_once {
				_test_zero_write_once = false
				return offset, General_Error.Partial_Write
			}
		}
		written, errno := linux.write(fd, bytes[offset:])
		if errno != .NONE {
			#partial switch errno {
			case .EINTR:
				continue
			case .EAGAIN:
				wait_ok, poll_err := _session_poll_out(fd)
				if !wait_ok {
					return offset, poll_err
				}
				continue
			case:
				return offset, Platform_Error(errno)
			}
		}
		if written == 0 {
			return offset, General_Error.Partial_Write
		}
		offset += int(written)
		committed = offset
	}
	return offset, nil
}

// _session_poll_out waits (blocking) until the descriptor is writable. A
// poll failure preserves its Platform_Error cause; EINTR is retried. There
// is no separate public poll-error channel: the write path surfaces this
// cause directly.
@(require_results)
_session_poll_out :: proc(fd: linux.Fd) -> (ok: bool, err: Error) {
	for {
		poll_descriptors := [1]linux.Poll_Fd{{fd = fd, events = {.OUT}}}
		_, errno := linux.poll(poll_descriptors[:], -1)
		if errno == .NONE {
			return true, nil
		}
		if errno == .EINTR {
			continue
		}
		return false, Platform_Error(errno)
	}
}

@(require_results)
_session_viewport :: proc(session: ^Session) -> (result: Viewport, err: Error) {
	if session.impl.file == nil {
		return {}, General_Error.Not_Open
	}
	size: Linux_Window_Size
	if errno := _ioctl(linux.Fd(os.fd(session.impl.file)), linux.TIOCGWINSZ, &size); errno != .NONE {
		return {}, Platform_Error(errno)
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

@(require_results)
_session_file :: proc(session: ^Session) -> (file: ^os.File, err: Error) {
	return session.impl.file, nil
}

@(require_results)
_session_write :: proc(file: ^os.File, text: string) -> Error {
	_, err := _session_write_bytes(linux.Fd(os.fd(file)), transmute([]byte)text)
	return err
}

// _session_close_write treats a hung-up terminal as a completed best-effort restore.
@(require_results)
_session_close_write :: proc(file: ^os.File, text: string) -> Error {
	err := _session_write(file, text)
	if platform, ok := err.(Platform_Error); ok && platform == .EIO {
		return nil
	}
	return err
}

// _session_restore_at_fini is the safety net for a process that returns from
// main (or ends through runtime._cleanup_runtime) without closing its session:
// it restores the saved termios. It does not run on os.exit (core:os documents
// that @(fini) blocks are skipped), on a fatal signal, or on a panic, so those
// exits still leave the terminal raw. After a normal close it is a no-op. The
// restore is best effort: the process is ending, so a failure changes nothing.
@(fini, private = "file")
_session_restore_at_fini :: proc "contextless" () {
	if atexit_active {
		_ = _tcsetattr(atexit_fd, TCSAFLUSH, &atexit_termios)
	}
}

_session_sigwinch_handler :: proc "c" (sig: linux.Signal) {
	sync.atomic_add(&sigwinch_wake_readers, 1)
	if fd := sync.atomic_load(&sigwinch_wake); fd >= 0 {
		// A full counter means the descriptor is already readable, so a failed write
		// loses nothing.
		one := u64(1)
		for {
			_, error := linux.write(linux.Fd(fd), ([^]u8)(&one)[:size_of(one)])
			if error != .EINTR { break }
		}
	}
	if sync.atomic_sub(&sigwinch_wake_readers, 1) == 1 { sync.futex_broadcast(&sigwinch_wake_readers) }
}

_session_install_sigwinch :: proc(impl: ^Session_Impl) {
	// rt_sigaction supplies the x86_64 restorer (SA_RESTORER + rt_sigreturn).
	action := linux.Sig_Action {
		handler = _session_sigwinch_handler,
	}
	if linux.rt_sigaction(.SIGWINCH, &action, &impl.previous_sigaction) == .NONE {
		impl.sigwinch_installed = true
	}
}
