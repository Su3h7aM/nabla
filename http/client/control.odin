// Package client is a minimal HTTP/1.1 client whose blocking phases are
// interruptible. Readiness and deadlines are the transport's business and are
// answered by a core:nbio event loop; the caller supplies only an interruption
// policy, so it never has to poll a descriptor itself.
//
// It is a stopgap kept deliberately small: streaming bodies, verified TLS,
// deadlines, and cancellation are the whole requirement set, and nothing is
// added beyond them.
package client

import "core:net"

// Wait_Status is why a probe ended. Ready means the request should continue; the
// other values end it, and Cancelled and Timed_Out stay distinct so a caller
// never reports one as the other.
Wait_Status :: enum {
	Ready,
	Timed_Out,
	Cancelled,
	Closed,
	Failed,
}

// Probe is the caller's interruption policy for one request. It is asked before
// each wait slice and answers only whether the request should keep going; an
// empty check waits indefinitely.
Probe :: struct {
	check:     proc(user_data: rawptr) -> Wait_Status,
	user_data: rawptr,
}

probe_now :: proc(probe: Probe) -> Wait_Status {
	if probe.check == nil { return .Ready }
	return probe.check(probe.user_data)
}

// Options carries caller policy. An empty ca_file uses the platform trust store;
// a value replaces it. TLS verification is always on. Empty nameservers use the
// system resolver configuration.
Options :: struct {
	probe:       Probe,
	ca_file:     string,
	nameservers: []net.Endpoint,
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
