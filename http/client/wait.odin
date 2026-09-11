package client

import "core:nbio"
import "core:net"
import "core:time"

// WAIT_SLICE bounds one tick of the event loop, and so bounds how long a request
// can go without the caller's probe being asked whether to stop.
WAIT_SLICE :: 50 * time.Millisecond

// Ready_For is the readiness a wait is asking the event loop for.
Ready_For :: enum {
	Read,
	Write,
}

Wait_Result :: enum {
	// The socket is ready for the requested direction.
	Ready,
	// The caller's probe ended the request.
	Stopped,
	// The wait itself failed.
	Failed,
}

@(private)
Wait_State :: struct {
	done:   bool,
	result: nbio.Poll_Result,
}

@(private)
on_poll_ready :: proc(op: ^nbio.Operation, state: ^Wait_State) {
	state.done = true
	state.result = op.poll.result
}

/*
wait_ready blocks until `socket` is ready in the requested direction, the caller's
probe ends the request, or the wait fails.

Readiness comes from the event loop rather than from the caller, so the caller's
probe only has to answer "keep going?", which is what makes it cheap enough to
ask on every slice: the upper bound on cancellation latency is WAIT_SLICE.

A connection whose probe is empty does blocking I/O and never waits here.
*/
wait_ready :: proc(socket: net.Any_Socket, kind: Ready_For, probe: Probe, timeout: time.Duration = 0) -> (result: Wait_Result, stop: Transport_Stop) {
	if probe.check == nil { return .Ready, .None }

	event := nbio.Poll_Event.Receive
	if kind == .Write { event = nbio.Poll_Event.Send }

	// A timeout bounds this one wait, and is separate from the caller's own
	// deadline, which reaches us through the probe.
	attempt_deadline: time.Tick
	bounded := timeout > 0
	if bounded { attempt_deadline = time.tick_add(time.tick_now(), timeout) }

	state: Wait_State
	op := nbio.poll_poly(socket, event, &state, on_poll_ready)

	for !state.done {
		if probe_stop := stop_from_wait(probe_now(probe)); probe_stop != .None {
			// remove only *requests* cancellation: the operation stays
			// outstanding, so its callback would still run and would write
			// through a pointer to this frame. Drain the loop until it is reaped.
			nbio.remove(op)
			drain_event_loop()
			return .Stopped, probe_stop
		}

		slice := WAIT_SLICE
		if bounded {
			remaining := -time.tick_since(attempt_deadline)
			if remaining <= 0 {
				nbio.remove(op)
				drain_event_loop()
				return .Stopped, .Timed_Out
			}
			if remaining < slice { slice = remaining }
		}
		nbio.tick(slice)
	}

	switch state.result {
	case .Ready:
		return .Ready, .None
	case .Timeout:
		return .Stopped, .Timed_Out
	case .Invalid_Argument, .Error:
		return .Failed, .Failed
	}
	return .Failed, .Failed
}

// drain_event_loop runs the loop until every operation issued on it has been
// reaped, which is what makes it safe to let a wait return.
@(private)
drain_event_loop :: proc() {
	for nbio.num_waiting() > 0 {
		nbio.tick(nbio.NO_TIMEOUT)
	}
}
