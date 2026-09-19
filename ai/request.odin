package ai

import "core:mem"
import "core:net"
import "core:strings"
import "core:time"

import "nabla:http"
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
	request_write_started:       bool,
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

Provider_Delivery_State :: enum {
	None,
	Model_Send_Started,
	Response_Observed,
	Terminal_Observed,
}

provider_delivery_state_name :: proc(state: Provider_Delivery_State) -> string {
	switch state {
	case .None:
		return "none"
	case .Model_Send_Started:
		return "model_send_started"
	case .Response_Observed:
		return "response_observed"
	case .Terminal_Observed:
		return "terminal_observed"
	}
	return "none"
}

Provider_Operation_Error :: struct {
	kind:                Provider_Operation_Error_Kind,
	// delivery is how far a model request observably progressed. Once sending
	// starts, replay is ambiguous even when no model output reached the caller.
	delivery:            Provider_Delivery_State,
	// delivery_present separates "the model send was not entered" from "no attempt
	// to establish it was made". Only a present state may authorize recovery.
	delivery_present:    bool,
	// failure_class is the provider's normalized meaning for this failure, and None
	// when no provider classification applies: a local refusal, or an attempt that
	// never reached the provider. Neither is a success signal.
	failure_class:       Provider_Failure_Class,
	// status is the HTTP response status when the endpoint gave one, and zero when
	// no response arrived. Retry policy needs the status, and it is a fact about
	// the request, not about the turn.
	status:              int,
	// provider_code is the provider's own code or type for the refusal, owned by the
	// caller, and empty when the provider wrote none.
	provider_code:       string,
	// provider_request_id is the identifier the provider's own response header
	// carried, owned by the caller, and empty when it sent none. It is what a
	// support request or a log search correlates on.
	provider_request_id: string,
	// retry_after is the delay the provider asked for, and is absent when it asked
	// for none. A present zero is not an absent value: it means "as soon as this
	// client is ready", and policy still decides whether it may send again.
	retry_after:         Maybe(time.Duration),
	// retry_directive is what the provider's own response said about sending again,
	// for the API families that document such a field.
	retry_directive:     Provider_Retry_Directive,
	// detail is owned by the caller and released with Provider_Operation_Error_Destroy,
	// so a constant message is cloned into it like any other.
	detail:              string,
	// transfer is the transport's own account of the attempt, in this package's
	// vocabulary, and is present whenever the request reached the transport.
	transfer:            Provider_Transfer_Summary,
	transfer_present:    bool,
	// transport_cause distinguishes a peer that never authenticated from a
	// connection that broke after the request went out.
	transport_cause:     Provider_Transport_Cause,
}

// Provider_Operation_Error_Destroy releases what an operation error owns. A zero
// error owns nothing, so destroying one is harmless.
Provider_Operation_Error_Destroy :: proc(err: ^Provider_Operation_Error, allocator := context.allocator) {
	if err == nil { return }
	if err.detail != "" { delete(err.detail, allocator) }
	if err.provider_code != "" { delete(err.provider_code, allocator) }
	if err.provider_request_id != "" { delete(err.provider_request_id, allocator) }
	err^ = {}
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

// provider_resource_path is the resource path an API family names. The configured
// endpoint is the API root, version segment included, so the path is relative to
// it.
provider_resource_path :: proc(api: API_Kind) -> string {
	switch api {
	case .OpenAI_Chat_Completions:
		return "/chat/completions"
	case .OpenAI_Responses:
		return "/responses"
	case .Anthropic_Messages:
		return "/messages"
	case .Invalid:
	}
	return ""
}

// provider_endpoint places the API's resource path on the configured endpoint. The
// endpoint may already state the path, and it may state a query, which belongs after
// the path rather than inside it.
provider_endpoint :: proc(endpoint: string, api: API_Kind, allocator: mem.Allocator) -> (result: string, ok: bool) {
	url := http.url_parse(endpoint)
	if url.scheme == "" || url.host == "" { return "", false }
	resource := provider_resource_path(api)
	path := strings.trim_right(url.path, "/")
	owned := ""
	defer if owned != "" { delete(owned, allocator) }
	if !strings.has_suffix(path, resource) {
		owned = strings.concatenate([]string{path, resource}, allocator = allocator)
		path = owned
	}
	if url.query == "" { return strings.concatenate([]string{url.scheme, "://", url.host, path}, allocator = allocator), true }
	return strings.concatenate([]string{url.scheme, "://", url.host, path, "?", url.query}, allocator = allocator), true
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
	encoded, freeze_err := Provider_Request_Freeze(request, allocator)
	if freeze_err.kind != .None { return freeze_err }
	// The body belongs to this call, and is released once the operation that borrows
	// it has returned.
	defer delete(encoded.Body, allocator)
	return Provider_Request_Operation_Encoded(connection, encoded, user_data, callback, options, allocator)
}

// Provider_Request_Freeze validates a request and encodes it once, so a caller that
// has to send the same bytes more than once encodes them here and holds them: a
// retry then sends exactly what the first attempt would have sent, rather than a
// fresh encoding that has to be assumed equal.
//
// The returned Body is owned by allocator and released with delete(encoded.Body,
// allocator). A request that cannot be encoded yields an Invalid_Request operation
// error, the same failure the one-shot path reports for it.
Provider_Request_Freeze :: proc(request: Provider_Request, allocator := context.allocator) -> (Provider_Encoded_Request, Provider_Operation_Error) {
	if err := Provider_Validate_Request(request); err != .None {
		return {}, Provider_Operation_Error{kind = .Invalid_Request, detail = strings.clone(provider_request_error_text(err), allocator)}
	}
	body, encode_err := Provider_Encode_Request(request, allocator)
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
	endpoint, endpoint_ok := provider_endpoint(connection.Endpoint, connection.API, allocator)
	if !endpoint_ok {
		return Provider_Operation_Error{kind = .Invalid_Request, detail = strings.clone("the provider endpoint is not an absolute URL", allocator)}
	}
	defer delete(endpoint, allocator)
	if options.observer.report != nil {
		options.observer.report(
			options.observer.user_data,
			Provider_Operation_Report{stage = .Encoded, api = encoded.API, model = encoded.Model, tools = encoded.Tools, body = encoded.Body},
		)
	}

	headers := provider_encoded_headers(connection, encoded, allocator)
	defer provider_headers_destroy(headers, allocator)

	state := Provider_Request_Stream_State {
		stream     = Provider_Stream_Start(connection.API, allocator),
		api        = connection.API,
		user_data  = user_data,
		callback   = callback,
		allocator  = allocator,
		interrupt  = options.interrupt,
		deadline   = options.deadline,
		observer   = options.observer,
		error_body = make([dynamic]u8, allocator),
	}
	sse.parser_init(&state.parser, provider_sse_event, &state, allocator = allocator)
	defer sse.parser_destroy(&state.parser)
	defer Provider_Event_Destroy(&state.completion, allocator)
	defer Provider_Stream_Destroy(&state.stream)
	// Every path releases what the attempt still owns: only a failure hands its
	// evidence to the caller, and the state clears each field the error takes.
	defer provider_state_release(&state)

	// The facts a recovery decision needs are collected here rather than through the
	// diagnostic observer, so turning logging off cannot change what the operation
	// reports about its own failure.
	facts := HTTP_Response_Facts {
		user_data = &state,
		head      = provider_response_head,
		transfer  = provider_transfer_summary,
	}
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
		facts,
		options.observer,
		&state,
		provider_http_chunk,
	)
	// The transport owns its copy of the failure, and this operation releases it on
	// every path once it has read what it keeps.
	defer client.failure_destroy(&failure, allocator)

	if failure.kind != .None {
		state.transport_cause = provider_transport_cause(failure.cause)
		provider_record_delivery(&state, failure)
		// A refused response carried the provider's own account of the refusal in its
		// body. It is decoded before that body is released, and one that is absent,
		// truncated, or malformed simply leaves the status and the transport facts as
		// the evidence.
		state.rejection = provider_rejection_parse(encoded.API, state.error_body[:], allocator)
		if !state.failed { provider_emit_error(&state, provider_failure_kind(failure), failure.detail) }
		provider_drain_events(&state)
		return provider_terminal_error(&state, provider_operation_error_kind(failure))
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
	stream:           Provider_Stream_State,
	parser:           sse.Parser,
	api:              API_Kind,
	user_data:        rawptr,
	callback:         Provider_Event_Callback,
	allocator:        mem.Allocator,
	interrupt:        ^Interrupt,
	deadline:         Deadline,
	observer:         Provider_Operation_Observer,
	response_bytes:   u64,
	failed:           bool,
	failure_detail:   string,
	// failure_event is the terminal event the stream layer produced, when it
	// produced one. It is what separates a stream that ended without its marker from
	// output this client cannot read.
	failure_event:    Maybe(Provider_Error_Kind),
	// response_head is what the final response head said, recorded while the
	// transport's own fields were still borrowed.
	response_head:    Provider_Response_Head,
	// rejection is the provider's own account of a refused request, owned here until
	// the terminal error hands it to the caller.
	rejection:        Provider_Rejection,
	// completion is the terminal response, retained until the transport finishes
	// cleanly: no call becomes executable while a later failure could still arrive.
	completion:       Provider_Event,
	// error_body keeps a refused response's body. The transport hands over a
	// body of any size, and all of it is kept: a large valid error document
	// can carry its rejection evidence past any prefix, and only the complete
	// body is parsed before classification. Owned here until release.
	error_body:       [dynamic]u8,
	transfer:         Provider_Transfer_Summary,
	transfer_present: bool,
	// delivery and delivery_present are the model-send evidence this attempt
	// established. Evidence first established on a failure reaches the caller
	// through provider_terminal_error.
	delivery:         Provider_Delivery_State,
	delivery_present: bool,
	transport_cause:  Provider_Transport_Cause,
}

// Provider_Response_Head is what a final response head said, in this package's
// vocabulary. It is recorded while the transport's headers are borrowed, so the
// identifier that has to outlive that call is cloned into it.
Provider_Response_Head :: struct {
	seen:                bool,
	status:              int,
	// stream says the transport will deliver a stream this operation can parse. A
	// response that is not one carries the provider's error document instead.
	stream:              bool,
	// provider_request_id is owned by the operation, and is empty when the provider
	// sent no such field or when this API documents none.
	provider_request_id: string,
	// retry_after is the delay the provider asked for, converted at receipt against
	// the wall clock. The wait itself is monotonic.
	retry_after:         Maybe(time.Duration),
	retry_directive:     Provider_Retry_Directive,
}

// provider_response_head records what a response head said about this attempt. It
// runs during the transport call, so everything kept beyond it is cloned here.
provider_response_head :: proc(user_data: rawptr, head: client.Response_Head, headers: http.Headers) {
	state := cast(^Provider_Request_Stream_State)user_data
	if state == nil { return }
	state.response_head.seen = true
	state.response_head.status = head.status
	state.response_head.stream = head.usable
	if name := provider_request_id_header(state.api); name != "" {
		if value, present := http.headers_get_unsafe(headers, name); present {
			state.response_head.provider_request_id = provider_bounded_text(value, PROVIDER_MAX_CODE_BYTES, state.allocator)
		}
	}
	if value, present := http.headers_get_unsafe(headers, "retry-after"); present {
		state.response_head.retry_after = provider_retry_after(value)
	}
	state.response_head.retry_directive = provider_retry_directive(state.api, headers)
}

// provider_record_delivery states whether this attempt may have put model input in
// front of the provider and got nothing back. That is the case a second send cannot
// repair: the request may have run, and no answer says it did not. A failure after a
// final response head is the provider's own answer, so classification decides what
// happens there rather than delivery.
provider_record_delivery :: proc(state: ^Provider_Request_Stream_State, failure: client.Failure) {
	if !state.transfer_present || !state.transfer.request_write_started { return }
	if state.delivery_present || state.response_head.seen { return }
	switch failure.kind {
	case .Transport, .Truncated, .Closed:
		state.delivery = .Model_Send_Started
		state.delivery_present = true
	case .None, .Cancelled, .Timed_Out, .TLS, .Invalid_URL, .HTTP_Status, .Content_Type:
	}
}

// provider_transfer_summary records how the attempt ended. A recovery decision
// reads it, so it is collected whether or not diagnostics are enabled.
provider_transfer_summary :: proc(user_data: rawptr, summary: Provider_Transfer_Summary) {
	state := cast(^Provider_Request_Stream_State)user_data
	if state == nil { return }
	state.transfer = summary
	state.transfer_present = true
}

// provider_state_release frees what the state still owns once an operation is over.
// The terminal error takes each field as it claims it, so this releases exactly
// what is left, including the evidence a successful attempt read from the head.
provider_state_release :: proc(state: ^Provider_Request_Stream_State) {
	if state == nil { return }
	if state.failure_detail != "" { delete(state.failure_detail, state.allocator) }
	delete(state.error_body)
	provider_rejection_destroy(&state.rejection, state.allocator)
	if state.response_head.provider_request_id != "" {
		delete(state.response_head.provider_request_id, state.allocator)
	}
	state.failure_detail = ""
	state.response_head.provider_request_id = ""
}

// provider_operation_error_kind maps a transport failure onto the operation's own
// outcome, so a caller that only inspects the returned error still learns that the
// request was interrupted rather than malformed.
//
// A TLS failure is the peer failing to authenticate, with one exception: a read or
// a write that fails after the connection was established is a connection that
// broke. That one is a transport failure, and sending again can succeed. The cause
// is what tells them apart, because both arrive as the transport's TLS failure.
provider_operation_error_kind :: proc(failure: client.Failure) -> Provider_Operation_Error_Kind {
	if failure.cause == .TLS_Read || failure.cause == .TLS_Write { return .Transport }
	switch failure.kind {
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
		// A content-type rejection means the peer answered 2xx with something other
		// than the expected media type, which an unstable peer can produce on one
		// attempt and not the next.
		return .Stream
	case .Transport, .Truncated, .Closed:
		return .Transport
	case .None:
	}
	return .Stream
}

// provider_terminal_error reports why an operation ended. An accepted cancellation
// or an expired deadline always wins over whichever path happened to notice first,
// so a late failure is never reported as an ordinary stream defect and a late
// success can never be reported at all.
provider_terminal_error :: proc(state: ^Provider_Request_Stream_State, kind: Provider_Operation_Error_Kind) -> Provider_Operation_Error {
	resolved := kind
	if interrupt_requested(state.interrupt) {
		resolved = .Cancelled
	} else if deadline_expired(state.deadline) {
		resolved = .Timed_Out
	}
	class := provider_classify_failure(
		Provider_Evidence {
			api = state.api,
			kind = resolved,
			head_seen = state.response_head.seen,
			status = state.response_head.status,
			cause = state.transport_cause,
			event = state.failure_event,
			rejection = state.rejection,
		},
	)
	result := Provider_Operation_Error {
		kind                = resolved,
		failure_class       = class,
		status              = state.response_head.status,
		provider_code       = state.rejection.code,
		provider_request_id = state.response_head.provider_request_id,
		retry_after         = state.response_head.retry_after,
		retry_directive     = state.response_head.retry_directive,
		detail              = provider_take_failure_detail(state),
		delivery            = state.delivery,
		delivery_present    = state.delivery_present,
		transfer            = state.transfer,
		transfer_present    = state.transfer_present,
		transport_cause     = state.transport_cause,
	}
	// What the caller now owns is no longer the state's, so the release path cannot
	// free it twice.
	state.rejection.code = ""
	state.response_head.provider_request_id = ""
	// The provider's own words are the reason a refusal happened, so they are what
	// the failure carries when the provider wrote any.
	if state.rejection.message != "" {
		if result.detail != "" { delete(result.detail, state.allocator) }
		result.detail = state.rejection.message
		state.rejection.message = ""
	}
	return result
}

// provider_failure_kind maps a transport failure onto the event kind the caller
// sees. Interruption is never reported as a stream defect, so a cancelled
// operation can be distinguished from a broken one. A TLS read or write that failed
// after the connection was established is a broken stream rather than an
// unauthenticated peer, which is what lets it be sent again.
provider_failure_kind :: proc(failure: client.Failure) -> Provider_Error_Kind {
	if failure.cause == .TLS_Read || failure.cause == .TLS_Write { return .Stream_Truncated }
	switch failure.kind {
	case .Cancelled:
		return .Cancelled
	case .Timed_Out:
		return .Timed_Out
	case .TLS:
		return .TLS
	case .None, .Transport, .Truncated, .Closed, .Invalid_URL, .HTTP_Status, .Content_Type:
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

// provider_take_failure_detail claims the detail the state still owns.
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
	if state.failure_event == nil { state.failure_event = kind }
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
		if state.failure_event == nil { state.failure_event = value.Kind }
		// The provider's own code and message outlive the event, because the event is
		// released once the caller's callback returns.
		if !provider_rejection_present(state.rejection) {
			state.rejection = Provider_Rejection {
				code    = provider_bounded_text(value.Provider_Code, PROVIDER_MAX_CODE_BYTES, state.allocator),
				message = provider_bounded_text(value.Message, PROVIDER_MAX_MESSAGE_BYTES, state.allocator),
			}
		}
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
	// A response this operation cannot use is not a stream. Its body is the
	// provider's own account of the refusal, so it is kept as evidence rather than
	// fed to a framing parser whose stream would be that error document.
	if state.response_head.seen && !state.response_head.stream {
		provider_error_body_append(state, chunk)
		return
	}
	sse.parser_feed(&state.parser, chunk)
}

// provider_error_body_append keeps a refused response's body for the
// classification that follows. All of it is kept: only the complete body is
// parsed, so a rejection whose evidence arrives late in a large document is
// still read. The buffer grows with the operation's allocator, and release
// frees it.
provider_error_body_append :: proc(state: ^Provider_Request_Stream_State, chunk: []u8) {
	append(&state.error_body, ..chunk)
}
