package ai

import "core:mem"
import "core:net"
import "nabla:http/client"
import "nabla:sse"

HTTP_Request :: struct {
	url:         string,
	body:        []u8,
	// headers are the provider's own request fields, authentication included.
	// The transport adds only what every event-stream request shares.
	headers:     []client.Header,
	// Empty uses the platform trust store. A value replaces it, which tests and
	// private deployments need. Credentialed HTTPS never runs unverified.
	ca_file:     string,
	// Empty uses the system resolver configuration. A value replaces it.
	nameservers: []net.Endpoint,
	allocator:   mem.Allocator,
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
	HTTP_Status,
	Content_Type,
}

// http_post_sse streams a Server-Sent Events response under one operation's
// interruption policy. The wire details -- SSE headers, the expected content
// type -- live in nabla:sse. What stays here is what is provider-specific: the
// headers the request carries, the interrupt/deadline policy handed to the
// transport as a wait hook, and the mapping into this package's failure kinds.
//
// api and observer name the provider operation this transfer belongs to, so the
// transport's own account of how far the request got can be reported through the
// same observer that carries the encoded body and the response chunks.
http_post_sse :: proc(
	request: HTTP_Request,
	control: HTTP_Control,
	api: API_Kind,
	observer: Provider_Operation_Observer,
	user_data: rawptr,
	callback: client.Chunk_Callback,
) -> HTTP_Failure {
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
	// The relay is in this frame for the whole call, because the transport reports
	// synchronously before it returns.
	relay := Transfer_Relay {
		observer = observer,
		api      = api,
	}
	if observer.report != nil {
		options.observer = {
			user_data = &relay,
			complete  = http_transfer_complete,
		}
	}

	failure := sse.post({url = request.url, body = request.body, headers = request.headers, allocator = request.allocator}, options, user_data, callback)
	return http_failure_from(failure)
}

// Transfer_Relay is what one HTTP transfer reports into: the provider observer
// and the api the request belonged to. It is borrowed by the transport for one
// synchronous call and never retained.
@(private)
Transfer_Relay :: struct {
	observer: Provider_Operation_Observer,
	api:      API_Kind,
}

// http_transfer_complete turns the transport's own account of a request into the
// provider operation's Transfer report. The observer is asked last, after
// encoding and after every response chunk, so a reader sees the transfer summary
// as the end of one attempt.
http_transfer_complete :: proc(user_data: rawptr, summary: client.Transfer_Summary) {
	relay := cast(^Transfer_Relay)user_data
	if relay == nil || relay.observer.report == nil { return }
	relay.observer.report(
		relay.observer.user_data,
		Provider_Operation_Report {
			stage = .Transfer,
			api = relay.api,
			transfer = {
				stopped_at = http_transfer_phase(summary.stopped_at),
				request_bytes_accepted = summary.request_bytes_accepted,
				request_body_bytes_accepted = summary.request_body_bytes_accepted,
				request_complete = summary.request_complete,
				response_head_received = summary.response_head_received,
				status = summary.status,
				declared_body_bytes = summary.declared_body_bytes,
				declared_body_bytes_present = summary.declared_body_bytes_present,
			},
		},
	)
}

// http_transfer_phase maps a transport stopping point onto this package's
// vocabulary. The switch is exhaustive, so a new HTTP phase is a compile error
// here until this package has decided what it means for a provider operation.
@(private)
http_transfer_phase :: proc(phase: client.Transfer_Phase) -> Provider_Transfer_Phase {
	switch phase {
	case .Validate:
		return .Validate
	case .Resolve:
		return .Resolve
	case .Connect:
		return .Connect
	case .TLS:
		return .TLS
	case .Request_Write:
		return .Request_Write
	case .Response_Head:
		return .Response_Head
	case .Response_Body:
		return .Response_Body
	case .Complete:
		return .Complete
	}
	unreachable()
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
