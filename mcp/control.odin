package mcp

import "core:time"

// Stop says why an operation stopped short of finishing.
Stop :: enum {
	None,
	Cancelled,
	Timed_Out,
}

// Control bounds one operation. Its callback and deadline are borrowed and polled,
// never retained, and a nil callback means the condition never holds.
//
// Cancellation wins over the deadline, so a cancelled turn is never reported as a
// timeout. The caller keeps its own cancellation vocabulary: this package only
// observes it.
Control :: struct {
	user_data:    rawptr,
	interrupted:  proc(user_data: rawptr) -> bool,
	// deadline_at is the absolute instant the operation must stop by; has_deadline
	// says whether it applies. It is a monotonic tick, so a wall-clock change
	// cannot make it fire early.
	deadline_at:  time.Tick,
	has_deadline: bool,
}

control_stop :: proc(control: Control) -> Stop {
	if control.interrupted != nil && control.interrupted(control.user_data) { return .Cancelled }
	if control.has_deadline && time.tick_since(control.deadline_at) >= 0 { return .Timed_Out }
	return .None
}

// control_error turns a stop into the error an operation reports. delivery says
// whether the operation's request had already been written, which is the fact a
// caller needs to tell a transport failure from an unknown outcome.
control_error :: proc(stop: Stop, delivery: Delivery_State, allocator := context.allocator) -> Error {
	if stop == .None { return {} }
	err := error_make(.Cancelled if stop == .Cancelled else .Timed_Out, allocator = allocator)
	err.delivery = delivery
	return err
}
