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

// Wire_Direction is which way one message travelled.
Wire_Direction :: enum {
	Outgoing,
	Incoming,
}

// Wire_Report is one complete JSON-RPC message, observed while it is borrowed.
//
// It is a whole message or nothing: a partial pipe write exists only inside the
// transport, and a decoded message tree is mutable state the caller must not keep.
// The message excludes the framing newline, and is valid only until report
// returns.
//
// operation names the method the exchange belongs to. request_id is the id the
// message carried, and is zero for an exchange-scoped notification that has none.
Wire_Report :: struct {
	direction:  Wire_Direction,
	operation:  string,
	request_id: i64,
	message:    []u8,
}

// Wire_Observer is told every message one client operation exchanges. It is a
// protocol fact rather than policy: this package knows nothing about capture,
// destinations, or what a caller does with the bytes.
Wire_Observer :: struct {
	user_data: rawptr,
	report:    proc(user_data: rawptr, report: Wire_Report),
}

// Operation_Options is the caller's policy for one client operation: what bounds
// it, and whether its messages are observed.
//
// Both fields are borrowed for one synchronous operation. A zero value performs
// the operation without a bound and without observation, which is what a caller
// that only wants a result passes.
Operation_Options :: struct {
	control:  Control,
	observer: Wire_Observer,
}

// operation_report calls the observer, if there is one.
@(private)
operation_report :: proc(options: Operation_Options, report: Wire_Report) {
	if options.observer.report == nil { return }
	options.observer.report(options.observer.user_data, report)
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
