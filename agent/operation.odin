package agent

// Chat_Event_Source identifies which turn and which operation an event belongs
// to. Every event carries one, so an event from a superseded operation can be
// rejected instead of mutating current state.
Chat_Event_Source :: struct {
	turn_id:      u64,
	operation_id: u64,
}

// Chat_Operation_State tracks whether an operation is still running. It is retired
// only when the work's holder confirms it stopped.
Chat_Operation_State :: enum {
	None,
	Running,
	Retired,
}

// Chat_Operation is one model request within a turn.
Chat_Operation :: struct {
	id:    u64,
	state: Chat_Operation_State,
}

chat_operation_start :: proc(operation: ^Chat_Operation, id: u64) {
	operation^ = Chat_Operation {
		id    = id,
		state = .Running,
	}
}

// chat_operation_retire is the confirmation that the work stopped. Nothing may be
// released on the strength of a cancellation request alone.
chat_operation_retire :: proc(operation: ^Chat_Operation) {
	if operation.state == .Retired { return }
	operation.state = .Retired
}
