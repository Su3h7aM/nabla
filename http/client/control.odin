// Package client is a minimal HTTP/1.1 client whose blocking phases are
// interruptible. The caller supplies a wait hook, so cancellation and deadlines
// are the caller's policy and the transport never blocks unobservably.
//
// It is a stopgap kept deliberately small: streaming bodies, verified TLS,
// deadlines, and cancellation are the whole requirement set, and nothing is
// added beyond them. Migrate to the official core HTTP package once it exists;
// upstream laid its foundation with core:nbio (odin-lang/Odin #6124, backbone
// of the coming HTTP package) but has not published it yet.
package client

import "core:net"
import "core:time"

// Wait_Kind is the readiness a caller is asked to wait for. Probe asks for
// terminal state without waiting, so work the transport cannot interrupt can be
// bracketed by it.
Wait_Kind :: enum {
	Read,
	Write,
	Probe,
}

Wait_Status :: enum {
	Ready,
	Timed_Out,
	Cancelled,
	Closed,
	Failed,
}

// Wait_Hook blocks until a descriptor is ready or reports why waiting stopped.
// fd is -1 for a Probe. A timeout of zero means "until the caller's own deadline
// or cancellation"; a positive timeout only bounds this one wait, which is how a
// single DNS attempt can expire without ending the operation.
// A nil hook means blocking I/O and no interruption.
Wait_Hook :: #type proc(user_data: rawptr, fd: i64, kind: Wait_Kind, timeout: time.Duration) -> Wait_Status

Wait_Channel :: struct {
	hook: Wait_Hook,
	data: rawptr,
}

// Options carries caller policy. An empty ca_file uses the platform trust store;
// a value replaces it. TLS verification is always on. Empty nameservers use the
// system resolver configuration.
Options :: struct {
	wait:        Wait_Channel,
	ca_file:     string,
	nameservers: []net.Endpoint,
}

wait_for :: proc(channel: Wait_Channel, fd: i64, kind: Wait_Kind, timeout: time.Duration) -> Wait_Status {
	if channel.hook == nil { return .Ready }
	return channel.hook(channel.data, fd, kind, timeout)
}

wait_probe :: proc(channel: Wait_Channel) -> Wait_Status {
	if channel.hook == nil { return .Ready }
	return channel.hook(channel.data, -1, .Probe, 0)
}

// Error classifies transport outcomes. Cancellation and deadlines stay distinct
// from connection failures so a caller never reports one as the other.
Error :: enum {
	None,
	Cancelled,
	Timed_Out,
	Closed,
	Truncated,
	Invalid_URL,
	Connect,
	Resolve,
	TLS_Config,
	TLS_Trust,
	TLS_Hostname,
	TLS_Peer_Rejected,
	TLS_Handshake,
	TLS_Read,
	TLS_Write,
	Send,
	Recv,
	Bad_Response,
}

// Transport_Stop records why a connection stopped making progress.
Transport_Stop :: enum {
	None,
	Cancelled,
	Timed_Out,
	Peer_Closed,
	Truncated,
	Failed,
}

stop_from_wait :: proc(status: Wait_Status) -> Transport_Stop {
	switch status {
	case .Ready:
		return .None
	case .Timed_Out:
		return .Timed_Out
	case .Cancelled:
		return .Cancelled
	case .Closed:
		return .Peer_Closed
	case .Failed:
		return .Failed
	}
	return .Failed
}

error_from_stop :: proc(stop: Transport_Stop) -> Error {
	switch stop {
	case .Cancelled:
		return .Cancelled
	case .Timed_Out:
		return .Timed_Out
	case .Peer_Closed:
		return .Closed
	case .Truncated:
		return .Truncated
	case .None, .Failed:
		return .Recv
	}
	return .Recv
}
