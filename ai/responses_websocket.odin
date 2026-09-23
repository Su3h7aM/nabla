package ai

import "core:mem"
import "core:strings"

import "nabla:http/client"
import "nabla:websocket"

// Provider_WebSocket_Session owns one foreground Responses connection. connection
// is borrowed and must outlive the session. The value itself is allocated so the
// cancellation probe retained by the upgraded connection always points at a
// stable address.
Provider_WebSocket_Session :: struct {
	connection: Provider_Connection,
	socket:     ^websocket.Conn,
	control:    HTTP_Control,
	allocator:  mem.Allocator,
}

Provider_WebSocket_Session_Open :: proc(
	connection: Provider_Connection,
	allocator := context.allocator,
) -> (
	^Provider_WebSocket_Session,
	Provider_Operation_Error,
) {
	if connection.API != .OpenAI_Responses {
		return nil, Provider_Operation_Error {
			kind = .Invalid_Request,
			detail = strings.clone("WebSocket transport is available only for the Responses API", allocator),
		}
	}
	if connection.Endpoint == "" {
		return nil, Provider_Operation_Error{kind = .Invalid_Request, detail = strings.clone("the provider endpoint is empty", allocator)}
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
Provider_Request_Freeze_WebSocket :: proc(request: Provider_Request, allocator := context.allocator) -> (Provider_Encoded_Request, Provider_Operation_Error) {
	return Provider_Request_Freeze_WebSocket_Reusing(request, nil, allocator)
}

// Provider_Request_Freeze_WebSocket_Reusing freezes a WebSocket request, reusing what
// cache already holds for the texts the request carries again. A nil cache encodes every
// byte now.
Provider_Request_Freeze_WebSocket_Reusing :: proc(
	request: Provider_Request,
	cache: ^Provider_Encode_Cache,
	allocator := context.allocator,
) -> (
	Provider_Encoded_Request,
	Provider_Operation_Error,
) {
	if request.API != .OpenAI_Responses {
		return {}, Provider_Operation_Error{kind = .Invalid_Request, detail = strings.clone("WebSocket transport is available only for the Responses API", allocator)}
	}
	body, encode_err := openai_responses_encode_websocket_request(request, cache, allocator)
	if encode_err != .None {
		return {}, Provider_Operation_Error{kind = .Invalid_Request, detail = strings.clone(provider_request_error_text(encode_err), allocator)}
	}
	return Provider_Encoded_Request {
		API = request.API,
		Body = transmute([]u8)body,
		Model = request.Model,
		Tools = len(request.Tools),
		Session_Id_Present = request.Session_Id_Present,
		Session_Id = request.Session_Id,
		User_Agent_Present = request.User_Agent_Present,
		User_Agent = request.User_Agent,
	}, {}
}

// Provider_WebSocket_Connect binds this operation's interruption and deadline to
// the session's socket and opens the connection when it is not open yet. Every
// request clears the binding again when it returns, so the probe never outlives the
// operation that owns it.
Provider_WebSocket_Connect :: proc(
	session: ^Provider_WebSocket_Session,
	encoded: Provider_Encoded_Request,
	options: Provider_Operation_Options,
) -> Provider_Operation_Error {
	if session == nil || encoded.API != .OpenAI_Responses {
		return Provider_Operation_Error{kind = .Invalid_Request, detail = strings.clone("invalid Responses WebSocket session", session_allocator(session))}
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
Provider_WebSocket_Request :: proc(
	session: ^Provider_WebSocket_Session,
	encoded: Provider_Encoded_Request,
	user_data: rawptr,
	callback: Provider_Event_Callback,
	options: Provider_Operation_Options,
) -> Provider_Operation_Error {
	if session == nil || encoded.API != .OpenAI_Responses || len(encoded.Body) == 0 {
		return Provider_Operation_Error{kind = .Invalid_Request, detail = strings.clone("invalid Responses WebSocket request", session_allocator(session))}
	}
	allocator := session.allocator
	if connect_err := Provider_WebSocket_Connect(session, encoded, options); connect_err.kind != .None {
		return connect_err
	}
	if options.observer.report != nil {
		options.observer.report(
			options.observer.user_data,
			Provider_Operation_Report{stage = .Encoded, api = encoded.API, model = encoded.Model, tools = encoded.Tools, body = encoded.Body},
		)
	}

	state := Provider_Request_Stream_State {
		stream     = Provider_Stream_Start(.OpenAI_Responses, allocator),
		api        = .OpenAI_Responses,
		user_data  = user_data,
		callback   = callback,
		allocator  = allocator,
		interrupt  = options.interrupt,
		deadline   = options.deadline,
		observer   = options.observer,
		error_body = make([dynamic]u8, allocator),
	}
	defer Provider_Event_Destroy(&state.completion, allocator)
	defer Provider_Stream_Destroy(&state.stream)
	defer provider_state_release(&state)
	// The probe binding names interruption storage that belongs to this operation, so
	// it is cleared before the session can outlive it.
	defer session.control = {}

	if write_err := websocket.write(session.socket, .Text, encoded.Body); write_err != .None {
		provider_websocket_drop(session)
		return provider_websocket_error(&state, write_err, "the WebSocket request could not be sent", .Model_Send_Started)
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
			return provider_websocket_error(&state, read_err, "the WebSocket response ended before a terminal event", delivery)
		}
		if opcode != .Text {
			provider_websocket_drop(session)
			return provider_websocket_error(&state, .Protocol, "the Responses WebSocket sent a binary message", .Response_Observed)
		}
		if count > 0 {
			delivery = .Response_Observed
			append(&message, ..chunk[:count])
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
		provider_drain_events(&state)
		if stream_err != .None && !state.failed {
			provider_emit_error(&state, .Invalid_Data, provider_stream_error_text(stream_err))
		}
		if state.failed {
			provider_websocket_drop(session)
			err := provider_terminal_error(&state, .Stream)
			err.delivery = delivery
			err.delivery_present = true
			return err
		}
		if state.stream.Phase == .Completed && state.completion != nil {
			provider_deliver(&state, state.completion)
			state.completion = nil
			return {}
		}
	}
}

provider_websocket_dial :: proc(
	session: ^Provider_WebSocket_Session,
	encoded: Provider_Encoded_Request,
	options: Provider_Operation_Options,
) -> Provider_Operation_Error {
	allocator := session.allocator
	endpoint, endpoint_ok := provider_websocket_endpoint(session.connection.Endpoint, allocator)
	if !endpoint_ok {
		return Provider_Operation_Error {
			kind = .Invalid_Request,
			detail = strings.clone("the Responses WebSocket endpoint is not HTTP, HTTPS, WS, or WSS", allocator),
		}
	}
	defer delete(endpoint, allocator)
	headers := provider_encoded_headers(session.connection, encoded, allocator)
	defer provider_headers_destroy(headers, allocator)
	http_options := client.Options {
		ca_file = options.ca_file,
		nameservers = options.nameservers,
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
			detail          = strings.clone(failure.detail, allocator),
		}
		if kind == .Transport && result.transport_cause != .Trust && result.transport_cause != .Configuration {
			result.failure_class = .Provider_Unavailable
		}
		return result
	}
	session.socket = socket
	return {}
}

provider_websocket_endpoint :: proc(base: string, allocator: mem.Allocator) -> (string, bool) {
	resource, resource_ok := provider_endpoint(base, .OpenAI_Responses, allocator)
	if !resource_ok { return "", false }
	defer delete(resource, allocator)
	switch {
	case strings.has_prefix(resource, "https://"):
		return strings.concatenate([]string{"wss://", resource[len("https://"):]}, allocator = allocator), true
	case strings.has_prefix(resource, "http://"):
		return strings.concatenate([]string{"ws://", resource[len("http://"):]}, allocator = allocator), true
	case strings.has_prefix(resource, "wss://"), strings.has_prefix(resource, "ws://"):
		return strings.clone(resource, allocator), true
	}
	return "", false
}

provider_websocket_drop :: proc(session: ^Provider_WebSocket_Session) {
	if session.socket == nil { return }
	websocket.abort(session.socket)
	session.socket = nil
}

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
	} else if cause == .Protocol {
		kind = .Stream
		failure_kind = .Invalid_Data
	}
	provider_emit_error(state, failure_kind, detail)
	provider_drain_events(state)
	err := provider_terminal_error(state, kind)
	err.delivery = delivery
	err.delivery_present = true
	return err
}

session_allocator :: proc(session: ^Provider_WebSocket_Session) -> mem.Allocator {
	if session != nil { return session.allocator }
	return context.allocator
}
