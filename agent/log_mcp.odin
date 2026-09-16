package agent

import "core:time"

import "nabla:agent/session"
import "nabla:mcp"

@(private)
log_mcp_exchange_started :: proc(scope: Log_Context, backend: ^MCP_Tool_Backend) {
	server_id, remote_name := "", ""
	if backend != nil { server_id, remote_name = backend.server_id, backend.remote_name }
	fields := [3]Log_Field{{key = "method", value = mcp.METHOD_TOOLS_CALL}, {key = "server_id", value = server_id}, {key = "remote_name", value = remote_name}}
	log_emit(scope, {level = .Info, category = .MCP, event = "mcp.exchange_started", fields = fields[:]})
}

@(private)
log_mcp_exchange_finished :: proc(
	scope: Log_Context,
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
	log_emit(scope, {level = .Info, category = .MCP, event = "mcp.exchange_finished", fields = fields[:]})
	if exchange_error.stderr_tail != "" {
		stderr_fields := [3]Log_Field {
			{key = "server_id", value = server_id},
			{key = "tail_bytes", value = i64(len(exchange_error.stderr_tail))},
			{key = "error_kind", value = log_mcp_error_name(exchange_error.kind)},
		}
		log_emit(scope, {level = .Warn, category = .MCP, event = "mcp.stderr", fields = stderr_fields[:]})
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
