package ai

import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:strings"
import "core:time"

import "nabla:http/client"
import "nabla:websocket"

// Provider_WebSocket_Session owns one foreground Responses connection. connection
// is borrowed and must outlive the session. The value itself is allocated so the
// cancellation probe retained by the upgraded connection always points at a
// stable address.
Provider_WebSocket_Session :: struct {
	connection:   Provider_Connection,
	socket:       ^websocket.Conn,
	control:      HTTP_Control,
	// idle_timeout is what the open socket was dialed with, and what an idle failure
	// reports. It is zero while no socket is open.
	idle_timeout: time.Duration,
	allocator:    mem.Allocator,
}

@(require_results)
Provider_WebSocket_Session_Open :: proc(
	connection: Provider_Connection,
	allocator := context.allocator,
) -> (
	^Provider_WebSocket_Session,
	Provider_Operation_Error,
) {
	if connection.API != .OpenAI_Responses {
		return nil, provider_invalid_request("WebSocket transport is available only for the Responses API", allocator)
	}
	if connection.Endpoint == "" {
		return nil, provider_invalid_request("the provider endpoint is empty", allocator)
	}
	session, alloc_error := new(Provider_WebSocket_Session, allocator)
	if alloc_error != nil {
		return nil, Provider_Operation_Error{kind = .Allocation}
	}
	session.connection = connection
	session.allocator = allocator
	return session, {}
}

// Provider_WebSocket_Session_Destroy aborts the transport rather than waiting for
// a close handshake. A caller that wants an orderly close performs one explicitly
// before destroying the session.
Provider_WebSocket_Session_Destroy :: proc(session: ^Provider_WebSocket_Session) {
	if session == nil { return }
	if session.socket != nil { websocket.abort(session.socket) }
	allocator := session.allocator
	free(session, allocator)
}

// Provider_Request_Freeze_WebSocket encodes one full-context Responses request for
// a WebSocket session. The returned body is owned by allocator.
@(require_results)
Provider_Request_Freeze_WebSocket :: proc(request: Provider_Request, allocator := context.allocator) -> (Provider_Encoded_Request, Provider_Operation_Error) {
	return Provider_Request_Freeze_WebSocket_Reusing(request, nil, allocator)
}

// Provider_Request_Freeze_WebSocket_Reusing freezes a WebSocket request, reusing what
// cache already holds for the texts the request carries again. A nil cache encodes every
// byte now, and its body belongs to the caller.
@(require_results)
Provider_Request_Freeze_WebSocket_Reusing :: proc(
	request: Provider_Request,
	cache: ^Provider_Encode_Cache,
	allocator := context.allocator,
) -> (
	Provider_Encoded_Request,
	Provider_Operation_Error,
) {
	if request.API != .OpenAI_Responses {
		return {}, provider_invalid_request("WebSocket transport is available only for the Responses API", allocator)
	}
	body, encode_err := openai_responses_encode_websocket_request(request, cache, allocator)
	if encode_err != .None {
		return {}, provider_invalid_request(provider_request_error_text(encode_err), allocator)
	}
	return provider_encoded_request(request, body, cache), {}
}

// Provider_WebSocket_Connect binds this operation's interruption and deadline to
// the session's socket and opens the connection when it is not open yet. Every
// request clears the binding again when it returns, so the probe never outlives the
// operation that owns it.
@(require_results)
Provider_WebSocket_Connect :: proc(
	session: ^Provider_WebSocket_Session,
	encoded: Provider_Encoded_Request,
	options: Provider_Operation_Options,
) -> Provider_Operation_Error {
	if session == nil || encoded.API != .OpenAI_Responses {
		return provider_invalid_request("invalid Responses WebSocket session", session_allocator(session))
	}
	session.control = HTTP_Control {
		interrupt = options.interrupt,
		deadline  = options.deadline,
	}
	if session.socket != nil { return {} }
	if dial_err := provider_websocket_dial(session, encoded, options); dial_err.kind != .None {
		session.control = {}
		return dial_err
	}
	return {}
}

// Provider_WebSocket_Request performs one sequential Responses operation. A valid
// terminal event completes the request while the socket remains open for reuse.
// A reused socket the peer closed while it sat idle is replaced by a new connection
// and the request is sent again, when none of the response had arrived on it.
@(require_results)
Provider_WebSocket_Request :: proc(
	session: ^Provider_WebSocket_Session,
	encoded: Provider_Encoded_Request,
	user_data: rawptr,
	callback: Provider_Event_Callback,
	options: Provider_Operation_Options,
) -> Provider_Operation_Error {
	if session == nil || encoded.API != .OpenAI_Responses || len(encoded.Body) == 0 {
		return provider_invalid_request("invalid Responses WebSocket request", session_allocator(session))
	}
	allocator := session.allocator
	// The session may be used from a different thread on every operation, and each wait on
	// its socket runs on the calling thread's event loop. Holding that loop for the whole
	// operation keeps every wait from starting and stopping one of its own. A loop that
	// cannot start is not fatal here: each wait then reports its own failure.
	loop_held := nbio.acquire_thread_event_loop() == nil
	defer if loop_held { nbio.release_thread_event_loop() }
	reused := session.socket != nil
	if connect_err := Provider_WebSocket_Connect(session, encoded, options); connect_err.kind != .None {
		return connect_err
	}
	if options.observer.report != nil {
		options.observer.report(
			options.observer.user_data,
			Provider_Operation_Report{stage = .Encoded, api = encoded.API, model = encoded.Model, tools = encoded.Tools, body = encoded.Body},
		)
	}

	error_body, error_body_error := make([dynamic]u8, allocator)
	if error_body_error != nil { return Provider_Operation_Error{kind = .Allocation} }
	state := Provider_Request_Stream_State {
		stream     = Provider_Stream_Start(.OpenAI_Responses, allocator),
		api        = .OpenAI_Responses,
		user_data  = user_data,
		callback   = callback,
		allocator  = allocator,
		interrupt  = options.interrupt,
		deadline   = options.deadline,
		observer   = options.observer,
		error_body = error_body,
	}
	defer Provider_Event_Destroy(&state.completion, allocator)
	defer Provider_Stream_Destroy(&state.stream)
	defer provider_state_release(&state)
	// The probe binding names interruption storage that belongs to this operation, so
	// it is cleared before the session can outlive it.
	defer session.control = {}

	for {
		result, stale := provider_websocket_exchange(session, encoded, &state, options, reused)
		if !stale { return result }
		// Nothing of the response arrived, so the peer ended the idle connection before it
		// read the request, and sending it again on a new connection is the retry RFC 9112
		// section 9.3.1 allows. A new connection is never stale, so this runs once.
		reused = false
		if options.observer.report != nil {
			options.observer.report(options.observer.user_data, Provider_Operation_Report{stage = .Reconnected, api = encoded.API, model = encoded.Model})
		}
		if dial_err := provider_websocket_dial(session, encoded, options); dial_err.kind != .None { return dial_err }
	}
}

// provider_websocket_exchange sends the request and reads its response. stale is true,
// with nothing reported to the callback, when a reused socket ended before any of the
// response arrived; the socket is then dropped.
@(private, require_results)
provider_websocket_exchange :: proc(
	session: ^Provider_WebSocket_Session,
	encoded: Provider_Encoded_Request,
	state: ^Provider_Request_Stream_State,
	options: Provider_Operation_Options,
	reused: bool,
) -> (
	result: Provider_Operation_Error,
	stale: bool,
) {
	allocator := session.allocator
	if write_err := websocket.write(session.socket, .Text, encoded.Body); write_err != .None {
		provider_websocket_drop(session)
		if reused && provider_websocket_ended(state, write_err) { return {}, true }
		return provider_websocket_error(state, write_err, "the WebSocket request could not be sent", .Model_Send_Started), false
	}
	delivery := Provider_Delivery_State.Model_Send_Started

	message: [dynamic]u8
	message.allocator = allocator
	defer delete(message)
	chunk: [16 * 1024]u8
	for {
		count, opcode, complete, read_err := websocket.read(session.socket, chunk[:])
		if read_err != .None {
			provider_websocket_drop(session)
			if reused && delivery == .Model_Send_Started && provider_websocket_ended(state, read_err) { return {}, true }
			if read_err == .Idle_Timeout {
				detail := fmt.tprintf("no bytes were received from the WebSocket peer for %v", session.idle_timeout)
				return provider_websocket_error(state, read_err, detail, delivery), false
			}
			return provider_websocket_error(state, read_err, "the WebSocket response ended before a terminal event", delivery), false
		}
		if opcode != .Text {
			provider_websocket_drop(session)
			return provider_websocket_error(state, .Protocol, "the Responses WebSocket sent a binary message", .Response_Observed), false
		}
		if count > 0 {
			delivery = .Response_Observed
			if _, append_error := append(&message, ..chunk[:count]); append_error != nil {
				provider_websocket_drop(session)
				provider_emit_error(state, .Allocation, "the WebSocket response could not be stored")
				provider_drain_events(state)
				failure := provider_terminal_error(state, .Allocation)
				failure.delivery = delivery
				return failure, false
			}
			state.response_bytes += u64(count)
			if options.observer.report != nil {
				options.observer.report(
					options.observer.user_data,
					Provider_Operation_Report{stage = .Response_Body, api = .OpenAI_Responses, chunk = chunk[:count], bytes = state.response_bytes},
				)
			}
		}
		if !complete { continue }
		stream_err := Provider_Consume_Event_JSON(string(message[:]), &state.stream)
		clear(&message)
		provider_drain_events(state)
		if stream_err != .None && !state.failed {
			provider_emit_error(state, .Invalid_Data, provider_stream_error_text(stream_err))
		}
		if state.failed {
			provider_websocket_drop(session)
			err := provider_terminal_error(state, .Stream)
			err.delivery = delivery
			return err, false
		}
		if state.stream.Phase == .Completed && state.completion != nil {
			provider_deliver(state, state.completion)
			state.completion = nil
			return {}, false
		}
	}
}

// provider_websocket_ended reports whether cause is the connection going away rather
// than a protocol fault, a cancellation, or a deadline.
@(private)
provider_websocket_ended :: proc(state: ^Provider_Request_Stream_State, cause: websocket.Error) -> bool {
	if cause != .Closed && cause != .Abnormal_Closure && cause != .Transport { return false }
	return !interrupt_requested(state.interrupt) && !deadline_expired(state.deadline)
}

@(require_results)
provider_websocket_dial :: proc(
	session: ^Provider_WebSocket_Session,
	encoded: Provider_Encoded_Request,
	options: Provider_Operation_Options,
) -> Provider_Operation_Error {
	allocator := session.allocator
	endpoint, endpoint_error := provider_websocket_endpoint(session.connection.Endpoint, allocator)
	if endpoint_error.kind != .None { return endpoint_error }
	defer delete(endpoint, allocator)
	headers := provider_encoded_headers(session.connection, encoded, allocator)
	if headers == nil { return Provider_Operation_Error{kind = .Allocation} }
	defer provider_headers_destroy(headers, allocator)
	http_options := client.Options {
		ca_file = options.ca_file,
		nameservers = options.nameservers,
		idle_timeout = options.idle_timeout,
		probe = {check = http_probe, user_data = &session.control},
	}
	socket, failure := websocket.dial(endpoint, {http = http_options, headers = headers}, allocator)
	if failure.kind != .None {
		defer websocket.dial_failure_destroy(&failure, allocator)
		kind := Provider_Operation_Error_Kind.Transport
		if failure.kind == .Response { kind = .HTTP }
		result := Provider_Operation_Error {
			kind            = kind,
			status          = failure.status,
			transport_cause = provider_transport_cause(failure.cause),
		}
		detail, detail_error := strings.clone(failure.detail, allocator)
		if detail_error != nil {
			// The wording could not be retained. The failure is reported as the local
			// allocation failure it is, with what the transport observed of the dial.
			result.kind = .Allocation
		} else {
			result.detail = detail
		}
		result.failure_class = provider_classify_failure(
			Provider_Evidence{api = .OpenAI_Responses, kind = result.kind, head_seen = kind == .HTTP, status = result.status, cause = result.transport_cause},
		)
		return result
	}
	session.socket = socket
	session.idle_timeout = options.idle_timeout
	return {}
}

@(require_results)
provider_websocket_endpoint :: proc(base: string, allocator: mem.Allocator) -> (string, Provider_Operation_Error) {
	resource, resource_error := provider_endpoint(base, .OpenAI_Responses, allocator)
	if resource_error.kind != .None { return "", resource_error }
	defer delete(resource, allocator)
	switch {
	case strings.has_prefix(resource, "https://"):
		scheme_swapped, swap_error := strings.concatenate([]string{"wss://", resource[len("https://"):]}, allocator = allocator)
		if swap_error != nil { return "", Provider_Operation_Error{kind = .Allocation} }
		return scheme_swapped, {}
	case strings.has_prefix(resource, "http://"):
		scheme_swapped, swap_error := strings.concatenate([]string{"ws://", resource[len("http://"):]}, allocator = allocator)
		if swap_error != nil { return "", Provider_Operation_Error{kind = .Allocation} }
		return scheme_swapped, {}
	case strings.has_prefix(resource, "wss://"), strings.has_prefix(resource, "ws://"):
		owned, clone_error := strings.clone(resource, allocator)
		if clone_error != nil { return "", Provider_Operation_Error{kind = .Allocation} }
		return owned, {}
	}
	return "", provider_invalid_request("the Responses WebSocket endpoint is not HTTP, HTTPS, WS, or WSS", allocator)
}

provider_websocket_drop :: proc(session: ^Provider_WebSocket_Session) {
	if session.socket == nil { return }
	websocket.abort(session.socket)
	session.socket = nil
}

@(require_results)
provider_websocket_error :: proc(
	state: ^Provider_Request_Stream_State,
	cause: websocket.Error,
	detail: string,
	delivery: Provider_Delivery_State,
) -> Provider_Operation_Error {
	kind := Provider_Operation_Error_Kind.Transport
	failure_kind := Provider_Error_Kind.Stream_Truncated
	if interrupt_requested(state.interrupt) {
		kind = .Cancelled
		failure_kind = .Cancelled
	} else if deadline_expired(state.deadline) {
		kind = .Timed_Out
		failure_kind = .Timed_Out
	} else if cause == .Idle_Timeout {
		kind = .Stream
	} else if cause == .Protocol {
		kind = .Stream
		failure_kind = .Invalid_Data
	}
	provider_emit_error(state, failure_kind, detail)
	provider_drain_events(state)
	err := provider_terminal_error(state, kind)
	err.delivery = delivery
	return err
}

session_allocator :: proc(session: ^Provider_WebSocket_Session) -> mem.Allocator {
	if session != nil { return session.allocator }
	return context.allocator
}
