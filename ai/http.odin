package ai

import "core:mem"
import "core:net"
import "core:strings"
import linux "core:sys/linux"
import "core:time"

import "nabla:httpclient"

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

HTTP_Stream_Callback :: #type proc(user_data: rawptr, data: []u8)

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

// http_post_sse streams a Server-Sent Events response. Every failure maps onto
// the transport's classification, so interruption is never reported as a broken
// peer and a rejected certificate never yields a connection.
http_post_sse :: proc(request: HTTP_Request, control: HTTP_Control, user_data: rawptr, callback: HTTP_Stream_Callback) -> HTTP_Failure {
	headers: [3]httpclient.Header
	count := 0
	headers[count] = {"content-type", "application/json"}; count += 1
	headers[count] = {"accept", "text/event-stream"}; count += 1
	token := ""
	defer delete(token, request.allocator)
	if request.bearer_token != "" {
		token = strings.concatenate([]string{"Bearer ", request.bearer_token}, allocator = request.allocator)
		headers[count] = {"authorization", token}; count += 1
	}

	// The wait hook needs a pointer that outlives the request, so the control
	// value lives in a local for the duration of this call.
	local_control := control
	options := httpclient.Options {
		ca_file     = request.ca_file,
		nameservers = request.nameservers,
	}
	if control.interrupt != nil || control.deadline.active {
		options.wait = {
			hook = http_wait,
			data = &local_control,
		}
	}

	failure := httpclient.stream_request(
		{
			url = request.url,
			method = .Post,
			headers = headers[:count],
			body = request.body,
			expected_content_type = "text/event-stream",
			allocator = request.allocator,
		},
		options,
		user_data,
		callback,
	)
	return http_failure_from(failure)
}

// http_wait adapts Svan's interrupt/deadline policy to the transport's wait hook.
// Cancellation is reported through the same path as a deadline, so both stop a
// stalled phase instead of waiting for the next poll slice. A transport-supplied
// timeout bounds only the wait that asked for it.
http_wait :: proc(user_data: rawptr, fd: i64, kind: httpclient.Wait_Kind, timeout: time.Duration) -> httpclient.Wait_Status {
	control := cast(^HTTP_Control)user_data
	if control == nil { return .Ready }
	if kind == .Probe {
		if interrupt_requested(control.interrupt) { return .Cancelled }
		if deadline_expired(control.deadline) { return .Timed_Out }
		return .Ready
	}
	events: linux.Fd_Poll_Events = {.IN}
	if kind == .Write { events = {.OUT} }
	switch wait_fd(linux.Fd(fd), events, control.deadline, control.interrupt, timeout) {
	case .Ready:
		return .Ready
	case .Timed_Out:
		return .Timed_Out
	case .Cancelled:
		return .Cancelled
	case .Failed:
		return .Failed
	}
	return .Failed
}

http_failure_from :: proc(failure: httpclient.Failure) -> HTTP_Failure {
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
