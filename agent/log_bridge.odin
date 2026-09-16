package agent

import "core:time"

import "nabla:agent/session"
import "nabla:ai"

// The bridge is where harness state becomes diagnostics: the scope a record is
// emitted against, and the names the log's own fields use for enums that other
// packages define.
//
// Everything here is derived from state the harness already keeps, so a record
// carries no identity the session database does not also have, and no procedure
// here retains what it borrows.
//
// Enum names are written out rather than derived from ordinals, because an ordinal
// changes the day a member is inserted and a record is read long after the code
// that wrote it.

// log_scope is the scope for work on chat. Whatever correlation the session has
// reached is carried; a field the session has not set is left absent.
log_scope :: proc(chat: ^Chat_Session) -> Log_Context {
	if chat == nil { return {} }
	scope := Log_Context {
		log        = chat.log,
		session_id = chat.id,
	}
	if turn_no, has_turn := chat.turn_no.?; has_turn { scope.turn_no = turn_no }
	if request_no, has_request := chat.active_request.?; has_request { scope.request_no = request_no }
	scope.operation_id = chat.active_operation_id
	return scope
}

// log_duration_ms is a duration in whole milliseconds, which is the unit every
// numeric duration in a record uses.
log_duration_ms :: proc(duration: time.Duration) -> i64 {
	return time.duration_nanoseconds(duration) / 1_000_000
}

@(private)
log_error_kind_name :: proc(kind: session.Error_Kind) -> string {
	switch kind {
	case .None:
		return "none"
	case .Invalid_Argument:
		return "invalid_argument"
	case .Not_Found:
		return "not_found"
	case .Claimed:
		return "claimed"
	case .Contended:
		return "contended"
	case .Stale_Snapshot:
		return "stale_snapshot"
	case .Constraint:
		return "constraint"
	case .Storage:
		return "storage"
	case .Schema_Too_New:
		return "schema_too_new"
	case .Schema_Unknown:
		return "schema_unknown"
	case .Corrupt:
		return "corrupt"
	case .Encode:
		return "encode"
	case .Invalid_State:
		return "invalid_state"
	}
	return "invalid_state"
}

// tool_arguments_status_name is what tool.arguments_prepared records for the
// admission outcome.
@(private)
tool_arguments_status_name :: proc(status: Tool_Arguments_Status) -> string {
	switch status {
	case .Valid:
		return "valid"
	case .Repaired:
		return "repaired"
	case .Rejected:
		return "rejected"
	}
	return "rejected"
}

@(private)
log_operation_error_name :: proc(kind: ai.Provider_Operation_Error_Kind) -> string {
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
	return "tls"
}
