package term

import "base:runtime"
import "core:io"

// General_Error groups the semantic package states the terminal reports.
// None is the zero value. Stage names are deliberately absent: syscall,
// ioctl, termios, fcntl, poll, and nonzero-error write failures preserve
// their underlying cause via io.Error or Platform_Error (see the
// platform-suffixed files); the operation being called (open, close,
// present, viewport) supplies the stage context.
General_Error :: enum u32 {
	None = 0,
	Already_Open, // a session is already open on this tty
	Not_Open, // the operation requires an open session
	Not_A_Tty, // the descriptor is not a terminal
	No_Controlling_Tty, // open of /dev/tty found no controlling terminal
	Unsupported, // a cell width or shape the serializer cannot encode
	Invalid_Frame_Data, // frame dimensions or logical cell count are malformed
	Invalid_Cell, // a cell grapheme is malformed UTF-8 or carries terminal controls
	Invalid_Cursor, // a cursor Position is out of the frame bounds
	Presentation_Workspace_Too_Small, // the caller's output scratch is too small
	Partial_Write, // a write made zero progress with bytes pending and no cause
}

// Platform_Error resolves per platform: linux.Errno on Linux
// (errors_linux.odin). The indirection keeps the portable surface free of
// platform types, mirroring core:os.
Platform_Error :: _Platform_Error

// Error is the package-wide result type, mirroring core:os: a #shared_nil
// union of the general errors, core:io errors, allocator errors (open
// allocates), and platform errors.
Error :: union #shared_nil {
	General_Error,
	io.Error,
	runtime.Allocator_Error,
	Platform_Error,
}

#assert(size_of(Error) == size_of(u64))
