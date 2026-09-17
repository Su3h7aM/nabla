package agent

import "core:time"

import "nabla:agent/session"
import "nabla:mcp"

@(private)
log_mcp_exchange_started :: proc(backend: ^MCP_Tool_Backend) {
	server_id, remote_name := "", ""
	if backend != nil { server_id, remote_name = backend.server_id, backend.remote_name }
	fields := [3]Log_Field{{key = "method", value = mcp.METHOD_TOOLS_CALL}, {key = "server_id", value = server_id}, {key = "remote_name", value = remote_name}}
	log_emit({level = .Info, category = .MCP, event = "mcp.exchange_started", fields = fields[:]})
}

@(private)
log_mcp_exchange_finished :: proc(
	backend: ^MCP_Tool_Backend,
	delivery: mcp.Delivery_State,
	exchange_error: mcp.Error,
	outcome: session.Tool_Outcome,
	elapsed: time.Duration,
) {
	server_id, remote_name := "", ""
	if backend != nil { server_id, remote_name = backend.server_id, backend.remote_name }
	delivery_name := "not_delivered"
	if delivery == .Delivered { delivery_name = "delivered" }
	fields := [8]Log_Field {
		{key = "method", value = mcp.METHOD_TOOLS_CALL},
		{key = "server_id", value = server_id},
		{key = "remote_name", value = remote_name},
		{key = "delivery", value = delivery_name},
		{key = "error_kind", value = log_mcp_error_name(exchange_error.kind)},
		{key = "outcome", value = session.tool_outcome_name(outcome)},
		{key = "elapsed_ms", value = log_duration_ms(elapsed)},
		{key = "remote_code", value = exchange_error.code},
	}
	log_emit({level = .Info, category = .MCP, event = "mcp.exchange_finished", fields = fields[:]})
	if exchange_error.stderr_tail != "" {
		stderr_fields := [3]Log_Field {
			{key = "server_id", value = server_id},
			{key = "tail_bytes", value = i64(len(exchange_error.stderr_tail))},
			{key = "error_kind", value = log_mcp_error_name(exchange_error.kind)},
		}
		log_emit({level = .Warning, category = .MCP, event = "mcp.stderr", fields = stderr_fields[:]})
	}
}

log_mcp_error_name :: proc(kind: mcp.Error_Kind) -> string {
	switch kind {
	case .None:
		return "none"
	case .Cancelled:
		return "cancelled"
	case .Timed_Out:
		return "timed_out"
	case .Spawn_Failed:
		return "spawn_failed"
	case .Write_Failed:
		return "write_failed"
	case .Read_Failed:
		return "read_failed"
	case .End_Of_Stream:
		return "end_of_stream"
	case .Server_Exited:
		return "server_exited"
	case .Message_Too_Large:
		return "message_too_large"
	case .Malformed_Message:
		return "malformed_message"
	case .Unexpected_Message:
		return "unexpected_message"
	case .Version_Unsupported:
		return "version_unsupported"
	case .Capability_Missing:
		return "capability_missing"
	case .Protocol_Violation:
		return "protocol_violation"
	case .Out_Of_Memory:
		return "out_of_memory"
	}
	unreachable()
}

// --- the wire bridge ---------------------------------------------------------

// MCP_Log is what one MCP client operation reports its messages into. It lives in
// the caller's frame and is borrowed by the operation, so it never outlives the
// call it observes.
//
// It carries no correlation of its own: a message belongs to whatever scope
// installed the binding, which is the tool call for a call and the refresh for
// discovery and listing.
MCP_Log :: struct {
	server_id: string,
}

mcp_log_observer :: proc(log: ^MCP_Log) -> mcp.Wire_Observer {
	return {user_data = log, report = log_mcp_wire}
}

// log_mcp_wire stores one JSON-RPC message when payload capture is on. Each
// message is one artifact, opened and finished here because the whole line arrives
// at once; the artifact holds the exact framed bytes, including the newline the
// transport adds.
//
// A refused admission is counted by the sink rather than recorded here, so a run
// that exhausts its quota reports that once instead of once per message.
@(private)
log_mcp_wire :: proc(user_data: rawptr, report: mcp.Wire_Report) {
	log := cast(^MCP_Log)user_data
	if log == nil { return }
	sink := log_active_sink()
	if sink == nil || sink.capture_mode != .Payloads { return }

	kind := Capture_Kind.MCP_Outgoing
	if report.direction == .Incoming { kind = .MCP_Incoming }
	descriptor := Capture_Descriptor {
		server_id = log.server_id,
		operation = report.operation,
	}
	if report.request_id != 0 {
		descriptor.external_id = report.request_id
		descriptor.external_id_present = true
	}
	capture, opened := log_capture_open(sink, log_active_correlation(), kind, descriptor)
	if !opened { return }
	log_capture_write(&capture, report.message)
	log_capture_write(&capture, []u8{'\n'})
	log_capture_finish(&capture, true)
}
