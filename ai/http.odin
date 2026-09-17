package ai

import "core:mem"
import "core:net"

import "nabla:http"
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

// HTTP_Response_Facts is where one provider request reports what the transport saw
// of it. It is separate from Provider_Operation_Observer because a recovery
// decision needs these facts whether or not diagnostics are enabled, and neither
// callback may keep what it is shown: a response head and a transfer summary are
// borrowed for the call that reports them.
HTTP_Response_Facts :: struct {
	user_data: rawptr,
	// head is told the final status and its fields, once, after the head was read
	// and before its body: the one moment the fields exist while the body is still
	// ahead, which is when a caller decides what to do with that body.
	head:      proc(user_data: rawptr, head: client.Response_Head, headers: http.Headers),
	// transfer is told how the attempt ended, on every path that reached the
	// transport.
	transfer:  proc(user_data: rawptr, summary: Provider_Transfer_Summary),
}

// http_post_sse streams a Server-Sent Events response under one operation's
// interruption policy. The wire details -- SSE headers, the expected content
// type -- live in nabla:sse. What stays here is what is provider-specific: the
// headers the request carries, the interrupt/deadline policy handed to the
// transport as a wait hook, and the facts the caller needs reported.
//
// api and observer name the provider operation this transfer belongs to, so the
// transport's own account of how far the request got can be reported through the
// same observer that carries the encoded body and the response chunks. The
// facts are reported whatever the observer does, so a recovery decision never
// depends on diagnostics being enabled.
http_post_sse :: proc(
	request: HTTP_Request,
	control: HTTP_Control,
	api: API_Kind,
	facts: HTTP_Response_Facts,
	observer: Provider_Operation_Observer,
	user_data: rawptr,
	callback: client.Chunk_Callback,
) -> client.Failure {
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
	relay := HTTP_Relay {
		facts    = facts,
		observer = observer,
		api      = api,
	}
	options.response_head = {
		user_data = &relay,
		observed  = http_relay_head,
	}
	options.observer = {
		user_data = &relay,
		complete  = http_relay_transfer,
	}

	return sse.post({url = request.url, body = request.body, headers = request.headers, allocator = request.allocator}, options, user_data, callback)
}

// HTTP_Relay is what one HTTP exchange reports into: the operation's own facts
// and the diagnostic observer. It is borrowed by the transport for one synchronous
// call and never retained.
@(private)
HTTP_Relay :: struct {
	facts:    HTTP_Response_Facts,
	observer: Provider_Operation_Observer,
	api:      API_Kind,
}

@(private)
http_relay_head :: proc(user_data: rawptr, head: client.Response_Head, headers: http.Headers) {
	relay := cast(^HTTP_Relay)user_data
	if relay == nil || relay.facts.head == nil { return }
	relay.facts.head(relay.facts.user_data, head, headers)
}

// http_relay_transfer turns the transport's own account of a request into this
// package's vocabulary, hands it to the operation first, and reports it to the
// diagnostic observer second: the facts a decision needs are collected whether or
// not logging is on, and a reader sees the transfer summary as the end of one
// attempt.
@(private)
http_relay_transfer :: proc(user_data: rawptr, summary: client.Transfer_Summary) {
	relay := cast(^HTTP_Relay)user_data
	if relay == nil { return }
	mapped := Provider_Transfer_Summary {
		stopped_at                  = http_transfer_phase(summary.stopped_at),
		request_bytes_accepted      = summary.request_bytes_accepted,
		request_body_bytes_accepted = summary.request_body_bytes_accepted,
		request_complete            = summary.request_complete,
		response_head_received      = summary.response_head_received,
		status                      = summary.status,
		declared_body_bytes         = summary.declared_body_bytes,
		declared_body_bytes_present = summary.declared_body_bytes_present,
	}
	if relay.facts.transfer != nil { relay.facts.transfer(relay.facts.user_data, mapped) }
	if relay.observer.report != nil {
		relay.observer.report(relay.observer.user_data, Provider_Operation_Report{stage = .Transfer, api = relay.api, transfer = mapped})
	}
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
