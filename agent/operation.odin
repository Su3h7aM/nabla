package agent

import "core:time"

import "nabla:ai"

// Turn-wide and per-operation bounds are deliberately separate facts.
//
// The per-operation bound is handed to the transport and enforced for as long as a
// request is in flight, including name resolution. Because an operation's deadline
// is clamped to whatever remains of the turn bound, the turn bound does preempt a
// running model request: it reaches the transport as a shorter deadline. What the
// turn bound cannot do is preempt a running tool, because tools are executed
// synchronously by the control loop; a tool is bounded by its own timeout and by
// cancellation instead.
CHAT_OPERATION_DEADLINE :: 120 * time.Second
CHAT_TURN_DEADLINE :: 300 * time.Second

// Chat_Event_Source identifies which turn and which operation an event belongs
// to. Every event carries one, so an event from a superseded operation can be
// rejected instead of mutating current state.
Chat_Event_Source :: struct {
	turn_id:      u64,
	operation_id: u64,
}

// Chat_Operation_State tracks only whether an operation is still running. It cannot
// be retired until its holder confirms the work stopped, which is what keeps
// operation storage valid for as long as anything may still be using it.
Chat_Operation_State :: enum {
	None,
	Running,
	Retired,
}

// Chat_Operation is one model request within a turn. It carries the operation's
// identity, its own deadline, and the event source its events must match.
Chat_Operation :: struct {
	id:       u64,
	turn_id:  u64,
	state:    Chat_Operation_State,
	deadline: ai.Deadline,
}

chat_operation_start :: proc(operation: ^Chat_Operation, id, turn_id: u64, deadline: ai.Deadline) {
	operation^ = Chat_Operation {
		id       = id,
		turn_id  = turn_id,
		state    = .Running,
		deadline = deadline,
	}
}

// chat_operation_retire is the confirmation that the work stopped. Nothing may be
// released on the strength of a cancellation request alone.
chat_operation_retire :: proc(operation: ^Chat_Operation) {
	if operation.state == .Retired { return }
	operation.state = .Retired
}
