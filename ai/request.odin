package ai

import "core:mem"
import "core:net"
import "core:strings"

import "nabla:http/client"
import "nabla:sse"

Provider_Event_Callback :: #type proc(user_data: rawptr, event: Provider_Event)

// Provider_Operation_Stage names what one provider operation has produced.
//
// Encoded carries the exact request body the operation is about to send, which is
// the only moment it exists: the operation frees it when it returns. Response_Body
// carries a plaintext response chunk as it arrives, before it is parsed, which is
// what a capture needs and what a byte count is counted from.
Provider_Operation_Stage :: enum {
	Encoded,
	Response_Body,
	Transfer,
}

// Provider_Transfer_Phase is where one provider request stopped at the HTTP
// layer. Complete means the response body framing finished without a transport
// error.
Provider_Transfer_Phase :: enum {
	Validate,
	Resolve,
	Connect,
	TLS,
	Request_Write,
	Response_Head,
	Response_Body,
	Complete,
}

// Provider_Transfer_Summary is the HTTP layer's account of one provider request,
// in this package's vocabulary so no transport type reaches a caller.
//
// `accepted` means the plaintext bytes were taken by the socket or the TLS layer.
// It is not evidence that the peer received or acted on them.
Provider_Transfer_Summary :: struct {
	stopped_at:                  Provider_Transfer_Phase,
	request_bytes_accepted:      u64,
	request_body_bytes_accepted: u64,
	request_complete:            bool,
	response_head_received:      bool,
	status:                      int,
	declared_body_bytes:         u64,
	declared_body_bytes_present: bool,
}

// Provider_Operation_Report is one observation of a provider operation. body and
// chunk are borrowed for the duration of the call and never retained; an observer
// that wants them beyond that must copy them itself.
Provider_Operation_Report :: struct {
	stage:    Provider_Operation_Stage,
	api:      API_Kind,
	// model and tools describe the request the body was built from, and are zero
	// for a response chunk.
	model:    string,
	tools:    int,
	body:     []u8,
	chunk:    []u8,
	// bytes is the running plaintext response byte count for the operation.
	bytes:    u64,

	// transfer is set only for the final Transfer report, which is the one
	// observation the operation itself cannot make: how far its request got.
	transfer: Provider_Transfer_Summary,
}

Provider_Operation_Observer :: struct {
	user_data: rawptr,
	report:    proc(user_data: rawptr, report: Provider_Operation_Report),
}

Provider_Operation_Error_Kind :: enum {
	None,
	Invalid_Request,
	// HTTP means the endpoint answered with a status that is not a usable stream.
	HTTP,
	// Transport means the connection failed or ended before the endpoint said
	// anything usable; Stream means it answered but the stream itself was broken.
	Transport,
	Stream,
	Cancelled,
	Timed_Out,
	// TLS means the peer did not authenticate; the response was never usable.
	TLS,
}

Provider_Operation_Error :: struct {
	kind:   Provider_Operation_Error_Kind,
	// detail is owned by the caller and released with the operation's allocator,
	// so a constant message is cloned into it like any other.
	detail: string,
	// status is the HTTP response status when the endpoint gave one, and zero when
	// no response arrived. Retry policy needs the status, and it is a fact about
	// the request, not about the turn.
	status: int,
}

// Provider_Encoded_Request is a provider request whose body was encoded before
// the operation runs. It exists so a caller that has to freeze the exact bytes it
// will send can encode once and hand those bytes to another thread. Every string
// is borrowed for the life of the operation, and Body comes from
// Provider_Encode_Request, so it is already validated.
Provider_Encoded_Request :: struct {
	API:                API_Kind,
	Body:               []u8,
	// Model and Tools describe the body for the observer, which cannot read them
	// back out of the encoded bytes.
	Model:              string,
	Tools:              int,
	Session_Id_Present: bool,
	Session_Id:         string,
	User_Agent_Present: bool,
	User_Agent:         string,
}

// Provider_Operation_Options is the caller's interruption and trust policy for
// one request. A zero value performs the request without cancellation, which is
// what the synchronous prototype path wants.
Provider_Operation_Options :: struct {
	interrupt:   ^Interrupt,
	deadline:    Deadline,
	// Empty uses the platform trust store. Credentialed HTTPS is never sent over
	// an unverified connection, even when this is empty.
	ca_file:     string,
	// Empty uses the system resolver configuration. A value replaces it.
	nameservers: []net.Endpoint,
	// observer, when set, is told what this operation encoded and what came back.
	// A zero observer observes nothing.
	observer:    Provider_Operation_Observer,
}

// provider_request_headers builds the fields one request carries: the ones its
// API family authenticates with, the version header that family requires, and
// the client and session identities the caller named. Authentication and
// identity are caller policy, so the transport never learns either: sse.post
// carries whatever headers it is handed.
//
// An empty credential yields no auth header rather than a refused request, which
// is what an endpoint that needs no credential expects, and an unnamed client or
// session sends no header for it. Every value in the result is owned by
// allocator; the names are literals. provider_headers_destroy releases the whole
// result.
@(private)
provider_encoded_headers :: proc(connection: Provider_Connection, encoded: Provider_Encoded_Request, allocator := context.allocator) -> []client.Header {
	// Sized for the most any API family needs, so every entry is allocated up
	// front from the caller's allocator rather than grown through an ambient one.
	result := make([]client.Header, 4, allocator)
	count := 0
	switch connection.API {
	case .OpenAI_Chat_Completions, .OpenAI_Responses:
		if connection.Credential != "" {
			result[count] = {"authorization", strings.concatenate({"Bearer ", connection.Credential}, allocator)}
			count += 1
		}
	case .Anthropic_Messages:
		// Anthropic authenticates with a key header rather than a bearer token,
		// and requires the API version on every request.
		if connection.Credential != "" {
			result[count] = {"x-api-key", strings.clone(connection.Credential, allocator)}
			count += 1
		}
		result[count] = {"anthropic-version", strings.clone(ANTHROPIC_VERSION, allocator)}
		count += 1
	case .Invalid:
	}
	if encoded.User_Agent_Present && encoded.User_Agent != "" {
		result[count] = {"user-agent", strings.clone(encoded.User_Agent, allocator)}
		count += 1
	}
	if encoded.Session_Id_Present && encoded.Session_Id != "" {
		result[count] = {"session-id", strings.clone(encoded.Session_Id, allocator)}
		count += 1
	}
	return result[:count]
}

@(private)
provider_headers_destroy :: proc(headers: []client.Header, allocator := context.allocator) {
	for header in headers { delete(header.value, allocator) }
	delete(headers, allocator)
}

// Provider_Request_Operation_Controlled performs one request with explicit
// cancellation and deadline control. It delivers at most one terminal callback,
// never exposes executable tool calls from an interrupted or truncated stream,
// and destroys every payload it retains on failure.
Provider_Request_Operation_Controlled :: proc(
	connection: Provider_Connection,
	request: Provider_Request,
	user_data: rawptr,
	callback: Provider_Event_Callback,
	options: Provider_Operation_Options,
	allocator := context.allocator,
) -> Provider_Operation_Error {
	if err := Provider_Validate_Request(request); err != .None {
		return Provider_Operation_Error{kind = .Invalid_Request, detail = strings.clone(provider_request_error_text(err), allocator)}
	}
	if connection.API != request.API {
		return Provider_Operation_Error{kind = .Invalid_Request, detail = strings.clone("connection/request API mismatch", allocator)}
	}
	body, encode_err := Provider_Encode_Request(request, allocator)
	if encode_err != .None {
		return Provider_Operation_Error{kind = .Invalid_Request, detail = strings.clone(provider_request_error_text(encode_err), allocator)}
	}
	defer delete(body, allocator)
	encoded := Provider_Encoded_Request {
		API                = request.API,
		Body               = transmute([]u8)body,
		Model              = request.Model,
		Tools              = len(request.Tools),
		Session_Id_Present = request.Session_Id_Present,
		Session_Id         = request.Session_Id,
		User_Agent_Present = request.User_Agent_Present,
		User_Agent         = request.User_Agent,
	}
	return Provider_Request_Operation_Encoded(connection, encoded, user_data, callback, options, allocator)
}

// Provider_Request_Operation_Encoded performs one request from a body that was
// encoded earlier. Encoding is the only thing it skips: an operation that begins
// with bytes must behave exactly like one that begins with a request, so this is
// the one place the send path lives.
Provider_Request_Operation_Encoded :: proc(
	connection: Provider_Connection,
	encoded: Provider_Encoded_Request,
	user_data: rawptr,
	callback: Provider_Event_Callback,
	options: Provider_Operation_Options,
	allocator := context.allocator,
) -> Provider_Operation_Error {
	if connection.API != encoded.API {
		return Provider_Operation_Error{kind = .Invalid_Request, detail = strings.clone("connection/request API mismatch", allocator)}
	}
	if len(encoded.Body) == 0 {
		return Provider_Operation_Error{kind = .Invalid_Request, detail = strings.clone("the encoded request body is empty", allocator)}
	}
	endpoint := strings.trim_right(connection.Endpoint, "/")
	owned_endpoint := ""
	// Each API family names its own resource path. A configured endpoint may
	// already include it, so the suffix is added only when it is missing.
	want_suffix: string
	switch encoded.API {
	case .OpenAI_Chat_Completions:
		want_suffix = "/chat/completions"
	case .OpenAI_Responses:
		want_suffix = "/responses"
	case .Anthropic_Messages:
		// The configured endpoint is the API root, version segment included, so the
		// resource path is relative to it exactly as the OpenAI paths are.
		want_suffix = "/messages"
	case .Invalid:
	}
	if want_suffix != "" && !strings.has_suffix(endpoint, want_suffix) {
		owned_endpoint = strings.concatenate([]string{endpoint, want_suffix}, allocator = allocator)
		endpoint = owned_endpoint
	}
	defer delete(owned_endpoint, allocator)
	if options.observer.report != nil {
		options.observer.report(
			options.observer.user_data,
			Provider_Operation_Report{stage = .Encoded, api = encoded.API, model = encoded.Model, tools = encoded.Tools, body = encoded.Body},
		)
	}

	headers := provider_encoded_headers(connection, encoded, allocator)
	defer provider_headers_destroy(headers, allocator)

	state := Provider_Request_Stream_State {
		stream    = Provider_Stream_Start(connection.API, allocator),
		api       = connection.API,
		user_data = user_data,
		callback  = callback,
		allocator = allocator,
		interrupt = options.interrupt,
		deadline  = options.deadline,
		observer  = options.observer,
	}
	sse.parser_init(&state.parser, provider_sse_event, &state, allocator = allocator)
	defer sse.parser_destroy(&state.parser)
	defer Provider_Event_Destroy(&state.completion, allocator)
	defer Provider_Stream_Destroy(&state.stream)

	failure := http_post_sse(
		HTTP_Request {
			url = endpoint,
			body = encoded.Body,
			headers = headers,
			ca_file = options.ca_file,
			nameservers = options.nameservers,
			allocator = allocator,
		},
		HTTP_Control{interrupt = options.interrupt, deadline = options.deadline},
		encoded.API,
		options.observer,
		&state,
		provider_http_chunk,
	)
	if failure.kind != .None {
		if !state.failed { provider_emit_error(&state, provider_failure_kind(failure.kind), failure.detail) }
		provider_drain_events(&state)
		if failure.kind == .HTTP_Status && failure.detail != "" { delete(failure.detail, allocator) }
		state.failure_status = failure.status
		return provider_terminal_error(&state, provider_operation_error_kind(failure.kind))
	}
	if state.failed { return provider_terminal_error(&state, .Stream) }
	sse.parser_finish(&state.parser)
	stream_err := Provider_Stream_Finish(&state.stream)
	provider_drain_events(&state)
	if stream_err != .None && !state.failed {
		provider_emit_error(&state, .Stream_Truncated, provider_stream_error_text(stream_err))
	}
	if state.failed { return provider_terminal_error(&state, .Stream) }
	// The transport finished cleanly and the terminal event is authoritative.
	if state.stream.Phase == .Done && state.completion != nil {
		provider_deliver(&state, state.completion)
		state.completion = nil
	}
	return {}
}

Provider_Request_Stream_State :: struct {
	stream:         Provider_Stream_State,
	parser:         sse.Parser,
	api:            API_Kind,
	user_data:      rawptr,
	callback:       Provider_Event_Callback,
	allocator:      mem.Allocator,
	interrupt:      ^Interrupt,
	deadline:       Deadline,
	observer:       Provider_Operation_Observer,
	response_bytes: u64,
	failed:         bool,
	failure_detail: string,
	failure_status: int,
	completion:     Provider_Event,
}

// provider_operation_error_kind maps a transport failure onto the operation's
// own outcome, so a caller that only inspects the returned error still learns
// that the request was interrupted rather than malformed. A content-type
// rejection is a stream failure: the peer answered 2xx with something other
// than the expected media type, which an unstable peer can produce on one
// attempt and not the next, so it retries like any other broken stream.
provider_operation_error_kind :: proc(kind: HTTP_Failure_Kind) -> Provider_Operation_Error_Kind {
	switch kind {
	case .Cancelled:
		return .Cancelled
	case .Timed_Out:
		return .Timed_Out
	case .TLS:
		return .TLS
	case .HTTP_Status:
		return .HTTP
	case .Invalid_URL:
		return .Invalid_Request
	case .Content_Type:
		return .Stream
	case .Transport:
		return .Transport
	case .None:
	}
	return .Stream
}

// provider_terminal_error reports why an operation ended. An accepted
// cancellation or an expired deadline always wins over whichever path happened
// to notice first, so a late failure is never reported as an ordinary stream
// defect and a late success can never be reported at all.
provider_terminal_error :: proc(state: ^Provider_Request_Stream_State, kind: Provider_Operation_Error_Kind) -> Provider_Operation_Error {
	resolved := kind
	if interrupt_requested(state.interrupt) {
		resolved = .Cancelled
	} else if deadline_expired(state.deadline) {
		resolved = .Timed_Out
	}
	return Provider_Operation_Error{kind = resolved, detail = provider_take_failure_detail(state), status = state.failure_status}
}

// provider_failure_kind maps a transport failure onto the event kind the caller
// sees. Interruption is never reported as a stream defect, so a cancelled
// operation can be distinguished from a broken one.
provider_failure_kind :: proc(kind: HTTP_Failure_Kind) -> Provider_Error_Kind {
	switch kind {
	case .Cancelled:
		return .Cancelled
	case .Timed_Out:
		return .Timed_Out
	case .TLS:
		return .TLS
	case .None, .Transport, .Invalid_URL, .HTTP_Status, .Content_Type:
		return .Stream_Truncated
	}
	return .Stream_Truncated
}

provider_request_error_text :: proc(err: Provider_Request_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Unsupported_API:
		return "unsupported API family (only openai_chat_completions and openai_responses are implemented)"
	case .Missing_Model:
		return "model is required"
	case .Missing_Messages:
		return "at least one message is required"
	case .Invalid_Instructions:
		return "instructions must be a non-empty string when present"
	case .Invalid_Message:
		return "message role/content is invalid"
	case .Invalid_Tools:
		return "tool definitions are invalid"
	case .Invalid_Tool_Call:
		return "tool call id/name is invalid"
	case .Invalid_Max_Output_Tokens:
		return "max output tokens must be positive"
	case .Missing_Max_Output_Tokens:
		return "this API requires an output bound; set max_output_tokens for the model"
	case .Invalid_Reasoning_Effort:
		return "reasoning effort must be a non-empty level"
	case .Invalid_Prompt_Cache_Key:
		return "prompt cache key must be a non-empty string"
	case .Invalid_Prompt_Cache_Options:
		return "prompt cache options need implicit/explicit mode and 30m ttl"
	case .Invalid_Prompt_Cache_Retention:
		return "prompt cache retention must be in_memory or 24h (deprecated)"
	}
	return "invalid provider request"
}

provider_take_failure_detail :: proc(state: ^Provider_Request_Stream_State) -> string {
	detail := state.failure_detail
	state.failure_detail = ""
	return detail
}

provider_stream_error_text :: proc(err: Provider_Stream_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Invalid_State:
		return "invalid stream state"
	case .Unsupported_API:
		return "unsupported API family"
	case .Invalid_JSON:
		return "malformed provider stream JSON"
	case .Malformed_Event:
		return "malformed provider stream event"
	case .Stream_Truncated:
		return "stream ended before completion"
	case .Tool_Limit:
		return "provider tool call limit exceeded"
	case .Batch_Not_Drained:
		return "provider event batch was not drained"
	}
	return "provider stream error"
}

provider_emit_error :: proc(state: ^Provider_Request_Stream_State, kind: Provider_Error_Kind, detail: string) {
	if state.failed { return }
	state.failed = true
	state.failure_detail = strings.clone(detail, state.allocator)
	event: Provider_Event = Provider_Error_Event {
		Kind    = kind,
		Message = strings.clone(detail, state.allocator),
	}
	provider_deliver(state, event)
}

provider_deliver :: proc(state: ^Provider_Request_Stream_State, event: Provider_Event) {
	if event == nil { return }
	// Once cancellation is accepted, provisional output must not be committed:
	// only the terminal error is delivered, so the caller learns why.
	if interrupt_requested(state.interrupt) {
		#partial switch _ in event {
		case Provider_Error_Event:
		case:
			owned := event
			Provider_Event_Destroy(&owned, state.allocator)
			return
		}
	}
	if state.callback != nil { state.callback(state.user_data, event) }
	owned_event := event
	Provider_Event_Destroy(&owned_event, state.allocator)
}

// One terminal event per operation: the first error or completion wins, later
// repeats are destroyed without another callback.
provider_accept_event :: proc(state: ^Provider_Request_Stream_State, event: Provider_Event) {
	if event == nil { return }
	#partial switch value in event {
	case Provider_Error_Event:
		if state.failed {
			owned := event
			Provider_Event_Destroy(&owned, state.allocator)
			return
		}
		state.failed = true
		if state.failure_detail == "" { state.failure_detail = strings.clone(value.Message, state.allocator) }
		provider_deliver(state, event)
	case Provider_Completed_Event:
		if state.failed {
			owned := event
			Provider_Event_Destroy(&owned, state.allocator)
			return
		}
		// Retain until the transport finishes cleanly; calls must not become
		// executable while a later failure could still arrive.
		if state.completion != nil { Provider_Event_Destroy(&state.completion, state.allocator) }
		state.completion = event
	case:
		if state.failed {
			owned := event
			Provider_Event_Destroy(&owned, state.allocator)
			return
		}
		provider_deliver(state, event)
	}
}

provider_drain_events :: proc(state: ^Provider_Request_Stream_State) {
	for {
		event, ok := Provider_Stream_Drain(&state.stream)
		if !ok { break }
		provider_accept_event(state, event)
	}
}

provider_sse_event :: proc(user_data: rawptr, event: sse.Event) {
	state := cast(^Provider_Request_Stream_State)user_data
	if state.failed { return }
	stream_err := Provider_Consume_SSE_Data(event.data, &state.stream)
	provider_drain_events(state)
	if stream_err != .None && !state.failed {
		provider_emit_error(state, .Invalid_Data, provider_stream_error_text(stream_err))
	}
}

provider_http_chunk :: proc(user_data: rawptr, chunk: []u8) {
	state := cast(^Provider_Request_Stream_State)user_data
	if state.failed { return }
	state.response_bytes += u64(len(chunk))
	if state.observer.report != nil {
		state.observer.report(state.observer.user_data, Provider_Operation_Report{stage = .Response_Body, chunk = chunk, bytes = state.response_bytes})
	}
	sse.parser_feed(&state.parser, chunk)
}
