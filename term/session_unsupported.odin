#+build !linux
package term

import "core:os"

// Session_Impl is the platform state for targets without a terminal
// backend. There is none: every session operation returns a typed
// .Unsupported error, so the portable public surface (Session, Viewport,
// Frame_Buffer, open/close/session_file/viewport/present) exists on every
// target and fails explicitly instead of vanishing at compile time.
Session_Impl :: struct {}

@(require_results)
_session_open :: proc(session: ^Session, options: Options) -> Error {
	return General_Error.Unsupported
}

@(require_results)
_session_close :: proc(session: ^Session) -> Error {
	return General_Error.Unsupported
}

@(require_results)
_session_file :: proc(session: ^Session) -> (file: ^os.File, err: Error) {
	return nil, General_Error.Unsupported
}

@(require_results)
_session_viewport :: proc(session: ^Session) -> (result: Viewport, err: Error) {
	return {}, General_Error.Unsupported
}

@(require_results)
_session_present :: proc(session: ^Session, bytes: []byte, supersedable := false) -> (committed: int, err: Error) {
	return 0, General_Error.Unsupported
}

_session_set_resize_wake :: proc(fd: int) {  }
