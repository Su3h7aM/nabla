package ai

import "core:mem"
import "core:net"
import "nabla:http/client"
import "nabla:sse"

HTTP_Request :: struct {
	url:          string,
	body:         []u8,
	bearer_token: string,
	// Empty uses the platform trust store. A value replaces it, which tests and
	// private deployments need. Credentialed HTTPS never runs unverified.
	ca_file:      string,
	// Empty uses the system resolver configuration. A value replaces it.
	nameservers:  []net.Endpoint,
	allocator:    mem.Allocator,
}

// HTTP_Control is the caller's interruption policy for one request. Both are
// optional; a zero value restores blocking I/O.
HTTP_Control :: struct {
	interrupt: ^Interrupt,
	deadline:  Deadline,
}

HTTP_Failure :: struct {
	kind:   HTTP_Failure_Kind,
	status: int,
	detail: string,
}

HTTP_Failure_Kind :: enum {
	None,
	Transport,
	Cancelled,
	Timed_Out,
	TLS,
	Invalid_URL,
	HTTPS_Required,
	Redirect_Rejected,
	HTTP_Status,
	Content_Type,
}

// http_post_sse streams a Server-Sent Events response under one operation's
// interruption policy. The wire details -- SSE headers, the expected content
// type -- live in nabla:sse. What stays here is what is provider-specific: the
// interrupt/deadline policy handed to the transport as a wait hook, and the
// mapping into this package's failure kinds.
http_post_sse :: proc(request: HTTP_Request, control: HTTP_Control, user_data: rawptr, callback: client.Chunk_Callback) -> HTTP_Failure {
	// The wait hook needs a pointer that outlives the request, so the control
	// value lives in a local for the duration of this call.
	local_control := control
	options := client.Options {
		ca_file     = request.ca_file,
		nameservers = request.nameservers,
	}
	if control.interrupt != nil || control.deadline.active {
		options.probe = {
			check     = http_probe,
			user_data = &local_control,
		}
	}

	failure := sse.post(
		{url = request.url, body = request.body, bearer_token = request.bearer_token, allocator = request.allocator},
		options,
		user_data,
		callback,
	)
	return http_failure_from(failure)
}

// http_probe adapts this package's interrupt and deadline policy to the
// transport's probe. Readiness belongs to the transport's event loop, so the
// policy only answers whether the request should keep running; both cancellation
// and a deadline stop a stalled phase rather than waiting for it to finish.
http_probe :: proc(user_data: rawptr) -> client.Wait_Status {
	control := cast(^HTTP_Control)user_data
	if control == nil { return .Ready }
	if interrupt_requested(control.interrupt) { return .Cancelled }
	if deadline_expired(control.deadline) { return .Timed_Out }
	return .Ready
}

http_failure_from :: proc(failure: client.Failure) -> HTTP_Failure {
	kind: HTTP_Failure_Kind
	switch failure.kind {
	case .None:
		return {}
	case .Cancelled:
		kind = .Cancelled
	case .Timed_Out:
		kind = .Timed_Out
	case .TLS:
		kind = .TLS
	case .Invalid_URL:
		kind = .Invalid_URL
	case .HTTP_Status:
		kind = .HTTP_Status
	case .Content_Type:
		kind = .Content_Type
	case .Transport, .Truncated, .Closed:
		kind = .Transport
	}
	return HTTP_Failure{kind = kind, status = failure.status, detail = failure.detail}
}
