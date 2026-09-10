package term

import "base:runtime"
import "core:os"

// Input_Mode selects how open treats the terminal's input configuration.
// .Unchanged is the zero-value-safe default: the termios and file flags are
// left exactly as the caller found them. .Raw is the explicit opt-in for the
// TUI input path: it clears echo/canonical/signal processing and sets the
// descriptor nonblocking so an input parser can drain until EAGAIN. .Raw is
// the only mode that changes the input termios.
Input_Mode :: enum u8 {
	Unchanged,
	Raw,
}

// Options selects the terminal modes applied by open. Only the requested
// modes are applied; anything not listed is left untouched.
Options :: struct {
	alternate_screen: bool,
	hide_cursor:      bool,
	input_mode:       Input_Mode,
}

// Session is the caller-owned handle to an open terminal session. The
// platform state lives in impl (Session_Impl, defined per platform — the
// core:os File/File_Impl split); the portable fields track session liveness
// so stale reads observe !opened after close.
//
// Ownership (the core:os File contract, os/file_linux.odin): open allocates
// the Session with the caller's allocator and stores that allocator in the
// session; close restores every entered transition and, on success, frees
// the Session with the stored allocator. The caller never calls free on the
// handle: after a successful close the pointer is dead and no further call,
// including another close, is valid. close is retryable only until it
// succeeds — a teardown failure leaves the session allocated in its current
// state for a later retry. close(nil) is a documented no-op returning nil.
// One active session per process: a second open fails with .Already_Open.
Session :: struct {
	allocator: runtime.Allocator,
	impl:      Session_Impl,
	opened:    bool,
}

// open allocates a Session with the caller's allocator, stores that
// allocator in the session, opens the controlling terminal, and applies the
// requested terminal modes. Setup is atomic: any failed transition rolls
// back every transition already entered and frees the handle, so a failed
// open never leaks a half-configured terminal or an allocation.
@(require_results)
open :: proc(options: Options = {}, allocator := context.allocator, loc := #caller_location) -> (session: ^Session, err: Error) {
	session = new(Session, allocator, loc)
	session.allocator = allocator
	if err = _session_open(session, options); err != nil {
		free(session, allocator)
		return nil, err
	}
	session.opened = true
	return session, nil
}

// close tears the session down in reverse setup order and is retryable
// until it succeeds: closing nil is a no-op returning nil, and a teardown
// failure reports the first cause and leaves the session allocated in its
// current state (un-compensated transitions and, short of the descriptor
// close itself, the descriptor intact) so close can be called again with
// the same pointer. The descriptor close is the one one-shot step: core:os
// consumes the handle on close, so a failure there is reported and the next
// close settles the fully-compensated session. A successful close frees the
// Session with its stored allocator — the pointer is dead by contract
// afterwards, and no post-success call, including another close, is valid.
@(require_results)
close :: proc(session: ^Session) -> Error {
	if session == nil || !session.opened {
		return nil
	}
	err := _session_close(session)
	if err == nil {
		free(session, session.allocator)
	}
	return err
}

// session_file exposes the session's tty descriptor — the input handoff
// seam: the application hands the file to the input package for
// acquisition. The file is owned by the session and must not be closed by
// the caller.
@(require_results)
session_file :: proc(session: ^Session) -> (file: ^os.File, err: Error) {
	if session == nil || !session.opened {
		return nil, General_Error.Not_Open
	}
	return _session_file(session)
}

// viewport reports the current terminal dimensions. It requires an open
// session; a dead or closed tty is an error, never a fabricated size.
@(require_results)
viewport :: proc(session: ^Session) -> (result: Viewport, err: Error) {
	if session == nil || !session.opened {
		return {}, .Not_Open
	}
	return _session_viewport(session)
}
