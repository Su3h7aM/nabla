package mcp

import "core:fmt"
import "core:mem"
import "core:strings"

// Delivery_State says whether a complete request was written for the operation
// that failed. It is the one fact that separates a call which provably did not
// happen from one that may have happened: a reply lost after the request was
// written cannot be observed, so the harness reports it as unknown rather than
// guessing. Not_Delivered is the zero value because a failure raised before the
// write is the honest default.
Delivery_State :: enum {
	// Not_Delivered means no complete request was written for this operation.
	Not_Delivered,
	// Delivered means the complete request was written. Whether the server
	// performed it is not known.
	Delivered,
}

// Error_Kind names why an operation delivered no result. These are local
// conditions: a remote JSON-RPC error arrives as an Error_Response message and
// is reported through Remote_Error instead, so a local failure is never mistaken
// for something a peer said.
Error_Kind :: enum {
	None,
	Cancelled,
	Timed_Out,
	Spawn_Failed,
	Write_Failed,
	Read_Failed,
	End_Of_Stream,
	Server_Exited,
	Message_Too_Large,
	Malformed_Message,
	Unexpected_Message,
	Version_Unsupported,
	Capability_Missing,
	Protocol_Violation,
	Out_Of_Memory,
}

// Error is why an operation delivered no result. message, data_json, and
// stderr_tail are owned by allocator; data_json carries the remote error's data
// member when it had one, bounded so a server cannot make the harness allocate in
// proportion to its own reply. stderr_tail is a bounded excerpt of what a stdio
// server wrote to standard error, which is diagnostic only and never decides
// whether an operation succeeded.
Error :: struct {
	kind:        Error_Kind,
	delivery:    Delivery_State,
	code:        i64,
	message:     string,
	data_json:   string,
	stderr_tail: string,
	allocator:   mem.Allocator,
}

error_make :: proc(kind: Error_Kind, message := "", allocator := context.allocator) -> Error {
	err := Error {
		kind      = kind,
		allocator = allocator,
	}
	if message != "" { err.message = strings.clone(message, allocator) }
	return err
}

// error_with_code is an Error that names a specific protocol code, used when a
// local condition has one, such as a server refusing the requested version.
error_with_code :: proc(kind: Error_Kind, code: i64, message := "", allocator := context.allocator) -> Error {
	err := error_make(kind, message, allocator)
	err.code = code
	return err
}

// error_from_remote turns a JSON-RPC error object into an Error. The remote code
// is kept as it arrived, so a caller can act on a protocol-defined code without
// parsing the message text.
error_from_remote :: proc(remote: Remote_Error, delivery: Delivery_State, allocator := context.allocator) -> Error {
	err := Error {
		kind      = .Protocol_Violation,
		delivery  = delivery,
		code      = remote.code,
		allocator = allocator,
	}
	if remote.message != "" { err.message = strings.clone(remote.message, allocator) }
	if remote.data_present { err.data_json = strings.clone(remote.data_json, allocator) }
	return err
}

error_destroy :: proc(err: ^Error, allocator := context.allocator) {
	owner := err.allocator
	// A zero Error has no allocator, and destroying one must still be safe: a
	// caller that never received an error should not have to know that.
	if owner.procedure == nil { owner = allocator }
	delete(err.message, owner)
	delete(err.data_json, owner)
	delete(err.stderr_tail, owner)
	err^ = {}
}

// error_delivered reports whether the operation's request was fully written,
// which is what a caller needs to decide between a transport failure and an
// unknown outcome.
error_delivered :: proc(err: Error) -> bool {
	return err.delivery == .Delivered
}

// error_text renders an Error as one sentence. The message is bounded and
// actionable: it says what failed and, when the failure is the peer's, what the
// peer said.
error_text :: proc(err: Error, allocator := context.allocator) -> string {
	switch err.kind {
	case .None:
		return ""
	case .Cancelled:
		return strings.clone("the request was cancelled", allocator)
	case .Timed_Out:
		return strings.clone("the request exceeded its deadline", allocator)
	case .Spawn_Failed:
		return strings.clone("the server process could not be started", allocator)
	case .Write_Failed:
		return strings.clone("the request could not be written to the server", allocator)
	case .Read_Failed:
		return strings.clone("the server's reply could not be read", allocator)
	case .End_Of_Stream:
		return strings.clone("the server closed its output before replying", allocator)
	case .Server_Exited:
		return strings.clone("the server exited before replying", allocator)
	case .Message_Too_Large:
		return fmt.aprintf("the server sent a message larger than %d bytes", MAX_MESSAGE_BYTES, allocator = allocator)
	case .Malformed_Message:
		if err.message != "" { return fmt.aprintf("the server sent a message that is not valid JSON-RPC: %s", err.message, allocator = allocator) }
		return strings.clone("the server sent a message that is not valid JSON-RPC", allocator)
	case .Unexpected_Message:
		if err.message != "" { return fmt.aprintf("the server sent an unexpected message: %s", err.message, allocator = allocator) }
		return strings.clone("the server sent an unexpected message", allocator)
	case .Version_Unsupported:
		// The reader needs to know which revision the server chose, so the message
		// built where the version was read wins over a generic one.
		if err.message != "" { return strings.clone(err.message, allocator) }
		return strings.clone("the server does not speak any protocol revision this client implements", allocator)
	case .Capability_Missing:
		return strings.clone("the server does not support tools", allocator)
	case .Protocol_Violation:
		switch {
		case err.code != 0 && err.message != "":
			return fmt.aprintf("the server reported error %d: %s", err.code, err.message, allocator = allocator)
		case err.code != 0:
			return fmt.aprintf("the server reported error %d", err.code, allocator = allocator)
		case err.message != "":
			return strings.clone(err.message, allocator)
		}
		return strings.clone("the server reported an error", allocator)
	case .Out_Of_Memory:
		return strings.clone("the message could not be allocated", allocator)
	}
	return ""
}
