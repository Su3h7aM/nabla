package input

import "base:runtime"
import "core:io"

// General_Error groups the resource failures the package reports. Malformed
// or partial input normalizes to events (Unknown_Input), never to errors;
// only resource failures are errors.
General_Error :: enum u32 {
	None = 0,
	Not_Open, // acquisition on a closed descriptor
	Read_Failed, // the read path failed
	Poll_Failed, // poll failed
	Allocation_Failed,
}

Platform_Error :: _Platform_Error

Error :: union #shared_nil {
	General_Error,
	io.Error,
	runtime.Allocator_Error,
	Platform_Error,
}

#assert(size_of(Error) == size_of(u64))
