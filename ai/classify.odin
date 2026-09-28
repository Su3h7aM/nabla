package ai

// Failure normalization: what a provider's refusal means, in terms a recovery
// decision can act on.
//
// A provider says no in three shapes: an HTTP status with its own error document,
// an error event inside a stream that opened successfully, or nothing at all
// because the connection broke. This file turns all three into one vocabulary.
//
// The vocabulary is names, not prose. Nothing here reads English out of a message
// to guess a cause, apart from the one narrow check an API needs because a single
// code covers several causes, and an unrecognized refusal stays Unknown rather
// than becoming retryable by accident.

import "base:intrinsics"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:time"

import "nabla:http"
import "nabla:http/client"

// Provider_Failure_Class is the provider's own meaning for a failed attempt,
// derived from what the provider said and what the transport observed.
Provider_Failure_Class :: enum {
	// None means no provider classification applies: the attempt failed locally,
	// before the provider could refuse anything.
	None,
	// Unknown is a refusal this package recognized as one but could not name. It is
	// terminal, because guessing is what this vocabulary exists to avoid.
	Unknown,
	Authentication,
	Quota,
	Rate_Limited,
	Context_Overflow,
	Payload_Too_Large,
	Invalid_Request,
	Content_Policy,
	Provider_Unavailable,
	Incomplete_Stream,
	Invalid_Output,
}

// Provider_Retry_Directive is what the provider's own response said about sending
// again. Unspecified means it said nothing, which is not permission.
Provider_Retry_Directive :: enum {
	Unspecified,
	Forbid,
	Allow,
}

// PROVIDER_RETRY_DIRECTIVE_HEADER is the response field the OpenAI APIs document
// for telling a client whether sending the same request again could help. No other
// API family this package speaks has one, so no other family reads one.
PROVIDER_RETRY_DIRECTIVE_HEADER :: "x-should-retry"

// Provider_Transport_Cause is what the transport reported, in the terms a recovery
// decision needs: a peer that never authenticated is a different fact from a
// connection that broke after the request went out.
Provider_Transport_Cause :: enum {
	None,
	// Trust is a peer whose TLS identity could not be established: the chain, the
	// hostname, or the handshake. Sending again cannot fix it, and verification is
	// never weakened to recover.
	Trust,
	// Configuration is local TLS setup, which no attempt changes.
	Configuration,
	// Connection is a peer that was never reachable.
	Connection,
	// IO is an exchange that failed after a connection existed: a read, a write, or
	// a peer that closed early.
	IO,
}

// Provider_Rejection is the provider's own account of a refused request, decoded
// from its error document or its in-stream error event. Both strings are owned by
// whoever holds the rejection and are released with provider_rejection_destroy.
Provider_Rejection :: struct {
	code:    string,
	message: string,
}

// provider_rejection_present reports whether a rejection carries anything at all.
// A provider may name a cause without writing about it, or write about it without
// naming one; either is a rejection.
provider_rejection_present :: proc(rejection: Provider_Rejection) -> bool {
	return rejection.code != "" || rejection.message != ""
}

provider_rejection_destroy :: proc(rejection: ^Provider_Rejection, allocator: mem.Allocator) {
	if rejection == nil { return }
	if rejection.code != "" { delete(rejection.code, allocator) }
	if rejection.message != "" { delete(rejection.message, allocator) }
	rejection^ = {}
}

// provider_transport_cause names what the transport reported. Cancellation and an
// expired deadline are the caller's own decisions, not transport causes, so they
// carry none.
provider_transport_cause :: proc(err: client.Error) -> Provider_Transport_Cause {
	switch err {
	case .None, .Cancelled, .Timed_Out:
		return .None
	case .Connect, .Resolve:
		return .Connection
	case .Closed, .Truncated, .Send, .Recv, .Bad_Response, .No_Room:
		return .IO
	case .Invalid_URL, .Invalid_Request, .TLS_Config:
		return .Configuration
	case .TLS_Trust, .TLS_Hostname, .TLS_Peer_Rejected, .TLS_Handshake:
		return .Trust
	case .TLS_Read, .TLS_Write:
		// The handshake succeeded and the connection then broke, which is the case
		// a retry can succeed at.
		return .IO
	}
	return .None
}

// Provider_Evidence is everything known about a failed attempt when a decision is
// needed. Every field is a fact from the layer that observed it.
Provider_Evidence :: struct {
	api:       API_Kind,
	// kind is this operation's own outcome. It decides the family of the failure,
	// and provider text never overrides it: a cancelled request is cancelled even
	// if a proxy answered on the way out.
	kind:      Provider_Operation_Error_Kind,
	// head_seen says a final response head arrived, so status is a fact from the
	// peer rather than zero initialization.
	head_seen: bool,
	status:    int,
	cause:     Provider_Transport_Cause,
	// event is the terminal event the stream layer produced, when it produced one.
	// It separates a stream that ended without its marker from output this client
	// cannot read.
	event:     Maybe(Provider_Error_Kind),
	rejection: Provider_Rejection,
}

// provider_classify_failure names what a failed attempt means.
//
// A local outcome keeps its own meaning, so provider text cannot turn a cancellation, an
// expired deadline, or a request this client refused into a rejection. A recognized code
// then beats the status that carried it, and what is left is read from the transport and
// the status. It never guesses: a status outside the classes HTTP defines, a code the
// adapter does not know, and a stream defect nobody named all stay Unknown.
provider_classify_failure :: proc(evidence: Provider_Evidence) -> Provider_Failure_Class {
	switch evidence.kind {
	case .Cancelled, .Timed_Out, .Invalid_Request, .Allocation:
		return .None
	case .HTTP, .Transport, .Stream, .TLS, .None:
	}

	if class, known := provider_rejection_class(evidence.api, evidence.rejection); known { return class }

	switch evidence.kind {
	case .HTTP:
		if !evidence.head_seen { return .Unknown }
		return provider_status_class(evidence.status)
	case .Transport:
		switch evidence.cause {
		case .Connection, .IO:
			return .Provider_Unavailable
		case .None, .Trust, .Configuration:
			return .Unknown
		}
	case .Stream:
		return provider_stream_class(evidence.event)
	case .TLS:
		// A peer that did not authenticate carries no provider meaning, and it is
		// never retried.
		return .Unknown
	case .None:
		return .Unknown
	case .Cancelled, .Timed_Out, .Invalid_Request, .Allocation:
		return .None
	}
	return .Unknown
}

// provider_status_class reads a status the way HTTP defines it, with the meaning
// these provider APIs attach to a few of them. Anything outside the classes HTTP
// defines is Unknown, and never retryable because its number is large.
provider_status_class :: proc(status: int) -> Provider_Failure_Class {
	switch {
	case status == 401 || status == 403:
		return .Authentication
	case status == 402:
		return .Quota
	case status == 408 || status == 409:
		return .Provider_Unavailable
	case status == 413:
		return .Payload_Too_Large
	case status == 429:
		// Rate limiting, unless the body named something stronger, which step 2 has
		// already read.
		return .Rate_Limited
	case status >= 500 && status <= 599:
		return .Provider_Unavailable
	case status >= 400 && status <= 499:
		return .Invalid_Request
	}
	return .Unknown
}

// provider_stream_class names why a stream was unusable. A stream that ended
// without its required marker is incomplete; output that cannot be read as the
// API's own is invalid. Both are terminal until a sender decides otherwise, and
// neither is a network disconnect.
provider_stream_class :: proc(event: Maybe(Provider_Error_Kind)) -> Provider_Failure_Class {
	kind, present := event.?
	if !present { return .Unknown }
	switch kind {
	case .Invalid_Data, .Unsupported_Tool_Output:
		return .Invalid_Output
	case .Stream_Truncated:
		return .Incomplete_Stream
	case .API_Error:
		// The provider refused inside a stream it had already opened, and what it
		// wrote named nothing this package knows.
		return .Unknown
	case .Allocation:
		// A local allocation failure says nothing about the provider, and it is
		// never a reason to classify the refusal.
		return .None
	case .Cancelled, .Timed_Out, .TLS:
		return .None
	}
	return .Unknown
}

// provider_rejection_class maps a provider's own code onto the meaning this
// package gives it. A code no adapter knows is not classified here, and the status
// decides whatever it can.
provider_rejection_class :: proc(api: API_Kind, rejection: Provider_Rejection) -> (Provider_Failure_Class, bool) {
	if rejection.code == "" { return .None, false }
	switch api {
	case .OpenAI_Chat_Completions, .OpenAI_Responses:
		return openai_failure_class(rejection.code)
	case .Anthropic_Messages:
		return anthropic_failure_class(rejection.code, rejection.message)
	case .Invalid:
	}
	return .None, false
}

// provider_rejection_parse decodes a provider's own error document from the body
// of a response that was not a stream. A body that is empty, truncated, malformed,
// or simply not that document yields no rejection: the status and the transport
// facts stay the evidence, and nothing is read out of prose to fill the gap. A
// non-nil error means the provider's account could not be retained.
provider_rejection_parse :: proc(api: API_Kind, body: []u8, allocator: mem.Allocator) -> (Provider_Rejection, mem.Allocator_Error) {
	if len(body) == 0 { return {}, nil }
	switch api {
	case .OpenAI_Chat_Completions, .OpenAI_Responses:
		return openai_error_rejection(body, allocator)
	case .Anthropic_Messages:
		return anthropic_error_rejection(body, allocator)
	case .Invalid:
	}
	return {}, nil
}

// provider_error_document parses the root of an error document. The caller owns the
// returned value, releases it once it is done with the object, and gets no object
// at all when the body is empty, truncated, or not a JSON object: a provider's
// error document is evidence, and a body that is not one is not read as one.
provider_error_document :: proc(body: []u8, allocator: mem.Allocator) -> (value: json.Value, object: json.Object, ok: bool) {
	parsed, parse_err := json.parse(body, .JSON, false, allocator)
	if parse_err != nil { return {}, {}, false }
	parsed_object, is_object := parsed.(json.Object)
	if !is_object {
		json.destroy_value(parsed, allocator)
		return {}, {}, false
	}
	return parsed, parsed_object, true
}

// provider_request_id_header names the response field each API family documents
// for a request identifier. A family that documents none reports none, rather than
// reading a field it happens to share a name with.
provider_request_id_header :: proc(api: API_Kind) -> string {
	switch api {
	case .OpenAI_Chat_Completions, .OpenAI_Responses:
		return "x-request-id"
	case .Anthropic_Messages:
		return "request-id"
	case .Invalid:
		return ""
	}
	return ""
}

// provider_retry_directive reads the directive an API documents for whether to
// send again. Every other family leaves it unspecified.
provider_retry_directive :: proc(api: API_Kind, headers: http.Headers) -> Provider_Retry_Directive {
	switch api {
	case .OpenAI_Chat_Completions, .OpenAI_Responses:
		value, present := http.headers_get_unsafe(headers, PROVIDER_RETRY_DIRECTIVE_HEADER)
		if !present { return .Unspecified }
		if strings.equal_fold(value, "false") { return .Forbid }
		if strings.equal_fold(value, "true") { return .Allow }
		// Anything else is not a directive this client reads as one.
		return .Unspecified
	case .Anthropic_Messages, .Invalid:
	}
	return .Unspecified
}

// provider_retry_after reads the delay a provider asked for, and reports none when the
// field is absent or is not the delay-seconds or HTTP-date form RFC 9110 10.2.3 defines.
// Digits are scanned in full without allocating a big integer, and a date is converted
// here at receipt against the wall clock. A stated delay is returned in full unless it is
// past what a Duration can hold, which becomes that type's longest delay rather than none,
// because a caller that read it as silence would send again.
provider_retry_after :: proc(value: string) -> Maybe(time.Duration) {
	if len(value) == 0 { return nil }
	text := http.trim_ows(value)
	if text == "" { return nil }

	digits := true
	for character in text {
		if character < '0' || character > '9' {
			digits = false
			break
		}
	}
	if digits {
		seconds: i64
		for character in text {
			scaled, mul_overflow := intrinsics.overflow_mul(seconds, 10)
			next, add_overflow := intrinsics.overflow_add(scaled, i64(character - '0'))
			if mul_overflow || add_overflow { return max(time.Duration) }
			seconds = next
		}
		nanoseconds, mul_overflow := intrinsics.overflow_mul(seconds, i64(time.Second))
		if mul_overflow { return max(time.Duration) }
		return time.Duration(nanoseconds)
	}

	// An HTTP-date, and only in the three formats RFC 9110 5.6.1 defines. An
	// ISO 8601 timestamp is not one of them, and is not read as one.
	if at, parsed := http.date_parse(text); parsed {
		delay := time.diff(time.now(), at)
		if delay <= 0 { return time.Duration(0) }
		return delay
	}
	return nil
}
