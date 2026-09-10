#+build !linux
package term

import "core:os"

// Session_Impl is the platform state for targets without a terminal
// backend. There is none: every session operation returns a typed
// .Unsupported error, so the portable public surface (Session, Viewport,
// Frame_Buffer, open/close/session_file/viewport/present) exists on every
// target and fails explicitly instead of vanishing at compile time.
Session_Impl :: struct {}

_session_open :: proc(s: ^Session, options: Options) -> Error {
	return General_Error.Unsupported
}

_session_close :: proc(s: ^Session) -> Error {
	return General_Error.Unsupported
}

_session_file :: proc(s: ^Session) -> (file: ^os.File, err: Error) {
	return nil, General_Error.Unsupported
}

_session_viewport :: proc(s: ^Session) -> (result: Viewport, err: Error) {
	return {}, General_Error.Unsupported
}

_session_present :: proc(s: ^Session, bytes: []byte) -> (committed: int, err: Error) {
	return 0, General_Error.Unsupported
}
