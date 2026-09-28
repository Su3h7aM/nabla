package agent

import "base:intrinsics"
import "core:time"

import "nabla:agent/journal"

// log_correlation is the correlation work on chat currently carries; what the
// chat has not reached is absent.
log_correlation :: proc(chat: ^Chat_Session) -> Log_Correlation {
	if chat == nil { return {} }
	return Log_Correlation{session = chat.session, turn = chat.turn, request = chat.request}
}

// log_correlation_for_request is log_correlation for work that belongs to a
// request the chat is not currently running, such as a background compaction.
log_correlation_for_request :: proc(chat: ^Chat_Session, request: journal.Request_Id) -> Log_Correlation {
	correlation := log_correlation(chat)
	correlation.request = request
	return correlation
}

// log_optional_i64 writes an unreported measurement as -1, because a log field
// carries one integer and a reader has to tell "not reported" from zero.
log_optional_i64 :: proc(value: Maybe($T)) -> i64 where intrinsics.type_is_integer(T) {
	number, present := value.?
	return present ? i64(number) : -1
}

// log_correlation_for is log_correlation for one request attempt: the same
// identities with the attempt the caller keeps.
log_correlation_for :: proc(chat: ^Chat_Session, attempt: int) -> Log_Correlation {
	correlation := log_correlation(chat)
	correlation.attempt = attempt
	return correlation
}

// log_correlation_for_call is log_correlation for one tool call. The call id is
// scoped to one session and request, which is what the ambient binding already
// carries.
log_correlation_for_call :: proc(chat: ^Chat_Session, call_id: string) -> Log_Correlation {
	correlation := log_correlation(chat)
	correlation.call_id = call_id
	return correlation
}

// Log_Duration_Milliseconds is a duration in whole milliseconds, which is the unit every
// numeric duration in a record uses.
Log_Duration_Milliseconds :: proc(duration: time.Duration) -> i64 {
	return time.duration_nanoseconds(duration) / 1_000_000
}

// tool_arguments_status_name is what tool.arguments_prepared records for the
// admission outcome.
@(private)
tool_arguments_status_name :: proc(status: Tool_Arguments_Status) -> string {
	switch status {
	case .None:
		return "none"
	case .Valid:
		return "valid"
	case .Rejected:
		return "rejected"
	}
	return "rejected"
}
