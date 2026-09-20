#+test
#+private file
package client

import "core:nbio"
import "core:net"
import "core:testing"
import "core:time"

// stop_at_once ends any wait on its first probe, so a wait under it is prompt
// unless the wait blocks on something else first.
stop_at_once :: proc(_: rawptr) -> Wait_Status {
	return .Cancelled
}

unrelated_poll :: struct {
	done: bool,
}

on_unrelated_poll :: proc(op: ^nbio.Operation, state: ^unrelated_poll) {
	state.done = true
}

// A cancelled wait reaps only its own operation: unrelated work outstanding on
// the same thread's loop is still there when the wait returns, instead of the
// wait blocking until that work finishes.
@(test)
test_a_cancelled_wait_leaves_unrelated_work_alone :: proc(t: ^testing.T) {
	if loop_err := nbio.acquire_thread_event_loop(); loop_err != nil {
		testing.fail_now(t, "the test event loop could not be started")
	}
	defer nbio.release_thread_event_loop()

	created, create_err := net.create_socket(.IP4, .UDP)
	if !testing.expectf(t, create_err == nil, "the test socket could not be created: %v", create_err) { return }
	socket := created.(net.UDP_Socket)
	defer net.close(socket)

	// Unrelated work that never completes on its own: a wait that drained the
	// loop would block on it rather than return.
	other: unrelated_poll
	other_op := nbio.poll_poly(socket, nbio.Poll_Event.Receive, &other, on_unrelated_poll)
	defer nbio.remove(other_op)

	start := time.tick_now()
	result, stop := wait_ready(socket, .Read, {check = stop_at_once})
	elapsed := time.tick_since(start)
	testing.expect_value(t, result, Wait_Result.Stopped)
	testing.expect_value(t, stop, Transport_Stop.Cancelled)
	testing.expect(t, elapsed < 2 * time.Second, "a cancelled wait blocked on unrelated work")
	testing.expect(t, !other.done, "the unrelated operation was reaped by the wait")
}
