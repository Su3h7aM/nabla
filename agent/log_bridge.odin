package agent

import "base:intrinsics"
import "core:log"
import "core:time"

import "nabla:agent/session"
import "nabla:ai"

// The bridge is where Odin's logger meets the harness: the adapter that installs
// this writer into context.logger, the correlation a record is emitted against,
// and the names the log's own fields use for enums other packages define.
//
// Everything here is derived from state the harness already keeps, so a record
// carries no identity the session database does not also have, and no procedure
// here retains what it borrows.
//
// Enum names are written out rather than derived from ordinals, because an ordinal
// changes the day a member is inserted and a record is read long after the code
// that wrote it.

// log_logger is the standard logger for one binding. The returned value borrows
// binding, so the binding must outlive every use of the logger. A nil or unopened
// sink yields Odin's no-op logger, which is exactly what a run with diagnostics
// off keeps.
log_logger :: proc(binding: ^Log_Binding) -> log.Logger {
	if binding == nil || binding.sink == nil || !binding.sink.open {
		return log.nil_logger()
	}
	return log.Logger{procedure = log_procedure, data = rawptr(binding), lowest_level = binding.sink.lowest, options = nil}
}

// log_rebind fills binding from the logger already installed and returns a logger
// pointed at it. It is how a scope narrows correlation: the caller declares the
// binding, which is what gives it a lifetime, and this call returns the logger
// that borrows it.
//
// When no Nabla logger is installed, the active logger is returned unchanged and
// binding is left empty, so a host's own logger is never clobbered and a run with
// diagnostics off stays off.
log_rebind :: proc(binding: ^Log_Binding, correlation: Log_Correlation) -> log.Logger {
	active := context.logger
	if active.procedure != log_procedure { return active }
	source := cast(^Log_Binding)active.data
	if source == nil || source.sink == nil { return active }
	binding^ = Log_Binding {
		sink        = source.sink,
		correlation = correlation,
	}
	return log_bound_logger(binding, active)
}

@(private)
log_bound_logger :: proc(binding: ^Log_Binding, template: log.Logger) -> log.Logger {
	return log.Logger{procedure = log_procedure, data = rawptr(binding), lowest_level = template.lowest_level, options = template.options}
}

// log_procedure is the adapter Odin's logging calls arrive at: an ordinary
// log.info, log.warnf, or log.error anywhere below the harness. The text is stored
// once as text, never parsed back into fields, and the caller's location is kept as
// scalar fields rather than as a formatted header.
@(private)
log_procedure :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	binding := cast(^Log_Binding)data
	if binding == nil || binding.sink == nil { return }
	fields := [4]Log_Field {
		{key = "message", value = log_bounded_text(text)},
		{key = "file", value = log_bounded_text(location.file_path)},
		{key = "line", value = i64(location.line)},
		{key = "procedure", value = log_bounded_text(location.procedure)},
	}
	record := Log_Record {
		level    = level,
		category = .Runtime,
		event    = "runtime.message",
		fields   = fields[:],
	}
	log_write(binding.sink, binding.correlation, record)
}

// log_enabled reports whether a record at level would be written by the active
// logger. It is for a producer that would have to do measurable work, such as
// hashing a request body, before it could emit a record the threshold discards
// anyway. It is a question about the sink, not a second filtering rule: the sink
// still decides.
log_enabled :: proc(level: log.Level) -> bool {
	logger := context.logger
	return logger.procedure == log_procedure && level >= logger.lowest_level
}

// log_active_sink returns the sink the installed logger writes to, or nil when no
// Nabla logger is installed. It is for a producer that needs the writer itself,
// such as payload capture, which holds quota and file state rather than emitting a
// record.
log_active_sink :: proc() -> ^Log {
	logger := context.logger
	if logger.procedure != log_procedure { return nil }
	binding := cast(^Log_Binding)logger.data
	if binding == nil { return nil }
	return binding.sink
}

// log_active_correlation returns the correlation the installed logger carries, or
// a zero value when there is none.
log_active_correlation :: proc() -> Log_Correlation {
	logger := context.logger
	if logger.procedure != log_procedure { return {} }
	binding := cast(^Log_Binding)logger.data
	if binding == nil { return {} }
	return binding.correlation
}

// log_observation_wanted reports whether a provider observation is worth
// attaching: either a record could be written from it, or payload capture is on
// and would store the bytes. A run with neither pays nothing per chunk.
log_observation_wanted :: proc() -> bool {
	if log_enabled(.Info) { return true }
	sink := log_active_sink()
	return sink != nil && sink.capture_mode == .Payloads
}

// log_capture_wanted reports whether payload capture is on for the active sink.
// It is the one place a producer asks, so whether an observer is attached and
// whether an artifact is admitted cannot disagree about the policy.
log_capture_wanted :: proc() -> bool {
	sink := log_active_sink()
	return sink != nil && sink.open && sink.capture_mode == .Payloads
}

// log_correlation is the correlation work on chat currently carries. Whatever the
// session has reached is carried; a field the session has not set is left absent
// rather than guessed, and a retired operation contributes no identity because no
// operation is running.
log_correlation :: proc(chat: ^Chat_Session) -> Log_Correlation {
	if chat == nil { return {} }
	correlation := Log_Correlation {
		session_id = chat.id,
	}
	if turn_no, has_turn := chat.turn_no.?; has_turn { correlation.turn_no = turn_no }
	if request_no, has_request := chat.active_request.?; has_request { correlation.request_no = request_no }
	if chat.operation.state == .Running { correlation.operation_id = chat.operation.id }
	return correlation
}

// log_active_binding returns the sink and correlation the installed logger
// carries, or a zero binding when there is none. It is how a worker that must log
// without borrowing a caller's stack binding copies one it can own.
log_active_binding :: proc() -> Log_Binding {
	logger := context.logger
	if logger.procedure != log_procedure { return {} }
	binding := cast(^Log_Binding)logger.data
	if binding == nil { return {} }
	return binding^
}

// log_correlation_for_request is log_correlation for work that belongs to a
// request the session is not currently running, such as a background compaction.
log_correlation_for_request :: proc(chat: ^Chat_Session, request_no: session.Request_No) -> Log_Correlation {
	correlation := log_correlation(chat)
	correlation.request_no = request_no
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
