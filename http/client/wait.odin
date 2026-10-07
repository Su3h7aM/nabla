package client

import "core:nbio"
import "core:net"
import "core:time"

import "nabla:dns"

// This file waits: for a connect to complete, and for a connected socket to
// become ready. It never moves data.
//
// The event loop is used to wait for a socket to become ready, and the transfer
// itself stays a direct call on the socket. core:nbio also offers send and recv
// operations that carry the bytes, which suit most callers but not this one:
//
//   - TLS owns the socket's bytes. OpenSSL's BIO reads and writes the socket
//     itself, so bytes taken out of it by nbio.recv would never reach the record
//     layer, and bytes handed to nbio.send would bypass it. For a TLS
//     connection only readiness can be expressed, and using the operations for
//     plaintext and readiness for TLS would mean two partial-write loops, two
//     cancellation paths and two error mappings where one of each does.
//   - send's "all" option does carry the partial-write loop, but the case that
//     cannot use the operation is the one that needs it.
//
// Neither choice is cheaper than the other: nbio.send and nbio.recv copy a
// multi-buffer operation's slice into the loop's allocator, but a single buffer,
// which is all this transport submits, is held inline and does not allocate.
//
// core:nbio keeps one event loop per thread, and a connection can outlive the
// thread that opened it: an upgraded connection is read by whichever thread holds
// it next. Each wait therefore acquires the calling thread's own loop for as long
// as it runs. The acquisition is reference counted, so a request that already
// holds the loop pays only for a count; a thread that holds none gets a loop for
// this wait and releases it afterwards.

// WAIT_SLICE bounds one tick of the event loop, and so bounds how long a request
// can go without the caller's probe being asked whether to stop.
WAIT_SLICE :: dns.DNS_IO_SLICE

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
	// The wait's own timeout passed before the socket was ready.
	Expired,
}

// probe_stop names why a probe ended a wait. A probe that no longer answers
// with a stop reads as a cancellation, which is how dns reported it.
probe_stop :: proc(probe: Probe) -> Transport_Stop {
	if stop := stop_from_wait(probe_now(probe)); stop != .None { return stop }
	return .Cancelled
}

/*
wait_connected opens a connection on the calling thread's event loop, so the
caller's probe can end an attempt that is not progressing, which a connect that
blocks cannot express.

A zero socket means the attempt failed on its own; a stop means the probe ended
it, and the operation was cancelled rather than left to run on. The socket is
non-blocking.
*/
@(require_results)
wait_connected :: proc(endpoint: net.Endpoint, probe: Probe) -> (socket: net.TCP_Socket, stop: Transport_Stop) {
	// Without a loop the attempt cannot be made, which the caller reads as a
	// connect that failed on its own.
	if nbio.acquire_thread_event_loop() != nil { return 0, .None }
	defer nbio.release_thread_event_loop()

	asked := probe
	dialed, wait := dns.dial_tcp(endpoint, {}, {check = dns_interrupt_check, user_data = &asked})
	#partial switch wait {
	case .Ready:
		return dialed, .None
	case .Cancelled:
		return 0, probe_stop(probe)
	}
	return 0, .None
}

/*
wait_ready blocks until `socket` is ready in the requested direction, the caller's
probe ends the request, `timeout` passes, or the wait fails. A timeout of zero is no
timeout, and an expired one reports .Expired with no stop: it is the wait's own bound,
never the caller's deadline.

Readiness comes from the event loop rather than from the caller, so the caller's
probe only has to answer "keep going?", which is what makes it cheap enough to
ask on every slice: the upper bound on cancellation latency is WAIT_SLICE.

A connection with neither a probe nor a timeout does blocking I/O and never waits here.
*/
wait_ready :: proc(socket: net.Any_Socket, kind: Ready_For, probe: Probe, timeout: time.Duration) -> (result: Wait_Result, stop: Transport_Stop) {
	if probe.check == nil && timeout <= 0 { return .Ready, .None }
	if nbio.acquire_thread_event_loop() != nil { return .Failed, .Failed }
	defer nbio.release_thread_event_loop()

	event := nbio.Poll_Event.Receive
	if kind == .Write { event = nbio.Poll_Event.Send }
	deadline: time.Tick
	if timeout > 0 { deadline = time.tick_add(time.tick_now(), timeout) }

	asked := probe
	switch dns.wait_ready(socket, event, deadline, {check = dns_interrupt_check, user_data = &asked}) {
	case .Ready:
		return .Ready, .None
	case .Expired:
		return .Expired, .None
	case .Cancelled:
		return .Stopped, probe_stop(probe)
	case .Failed:
	}
	return .Failed, .Failed
}
