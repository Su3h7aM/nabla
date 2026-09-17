package ai

// Stable names for the vocabulary a durable record keeps.
//
// A record names an enum rather than numbering it: a name outlives the build that
// wrote it, and a reader that does not know one reads it as unknown instead of as
// whatever value happens to share its ordinal now.

provider_operation_error_name :: proc(kind: Provider_Operation_Error_Kind) -> string {
	switch kind {
	case .None:
		return "none"
	case .Invalid_Request:
		return "invalid_request"
	case .HTTP:
		return "http"
	case .Transport:
		return "transport"
	case .Stream:
		return "stream"
	case .Cancelled:
		return "cancelled"
	case .Timed_Out:
		return "timed_out"
	case .TLS:
		return "tls"
	}
	return "unknown"
}

provider_failure_class_name :: proc(class: Provider_Failure_Class) -> string {
	switch class {
	case .None:
		return "none"
	case .Unknown:
		return "unknown"
	case .Authentication:
		return "authentication"
	case .Quota:
		return "quota"
	case .Rate_Limited:
		return "rate_limited"
	case .Context_Overflow:
		return "context_overflow"
	case .Payload_Too_Large:
		return "payload_too_large"
	case .Invalid_Request:
		return "invalid_request"
	case .Content_Policy:
		return "content_policy"
	case .Provider_Unavailable:
		return "provider_unavailable"
	case .Incomplete_Stream:
		return "incomplete_stream"
	case .Invalid_Output:
		return "invalid_output"
	}
	return "unknown"
}

provider_retry_directive_name :: proc(directive: Provider_Retry_Directive) -> string {
	switch directive {
	case .Unspecified:
		return "unspecified"
	case .Forbid:
		return "forbid"
	case .Allow:
		return "allow"
	}
	return "unspecified"
}

provider_transport_cause_name :: proc(cause: Provider_Transport_Cause) -> string {
	switch cause {
	case .None:
		return "none"
	case .Trust:
		return "trust"
	case .Configuration:
		return "configuration"
	case .Connection:
		return "connection"
	case .IO:
		return "io"
	}
	return "none"
}
