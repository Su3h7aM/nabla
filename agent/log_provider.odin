package agent

import "core:crypto/sha2"

import "nabla:agent/journal"
import "nabla:ai"

// Provider_Log is what one provider attempt reports into: the count of what came
// back and how far the transport got. It lives in the caller's frame for one attempt.
Provider_Log :: struct {
	response_bytes: u64,
	// transfer is the transport's own account of the attempt, and transfer_seen
	// says whether it arrived.
	transfer:       ai.Provider_Transfer_Summary,
	transfer_seen:  bool,
}

provider_log_observer :: proc(observation: ^Provider_Log) -> ai.Provider_Operation_Observer {
	return {user_data = observation, report = log_provider_report}
}

@(private)
log_provider_report :: proc(user_data: rawptr, report: ai.Provider_Operation_Report) {
	observation := cast(^Provider_Log)user_data
	#partial switch report.stage {
	case .Encoded:
		// The digest is only worth computing when the entry would be kept.
		if log_enabled(.Info) {
			state: sha2.Context_256
			sha2.init_256(&state)
			sha2.update(&state, report.body)
			digest: journal.Digest
			sha2.final(&state, digest[:])
			digest_text: [journal.DIGEST_HEX_LENGTH]u8

			fields := [5]Log_Field {
				{key = "api", value = chat_api_name(report.api)},
				{key = "model", value = report.model},
				{key = "tools", value = i64(report.tools)},
				{key = "body_bytes", value = i64(len(report.body))},
				{key = "body_sha256", value = journal.digest_to_hex(digest, digest_text[:])},
			}
			log_emit({level = .Info, category = .Provider, event = "provider.encoded", fields = fields[:]})
		}
	case .Response_Body:
		observation.response_bytes = report.bytes
	case .Transfer:
		// The transport's account of the attempt, recorded whether or not anything
		// was written, because a request that never left says so.
		observation.transfer = report.transfer
		observation.transfer_seen = true
	case .Reconnected:
		log_emit({level = .Info, category = .Provider, event = "provider.websocket_reconnected"})
	}
}

// log_provider_transfer_name names where a transfer stopped. The names are stable
// wire vocabulary, so a record keeps its meaning when the enum gains a member.
log_provider_transfer_name :: proc(phase: ai.Provider_Transfer_Phase) -> string {
	switch phase {
	case .Validate:
		return "validate"
	case .Resolve:
		return "resolve"
	case .Connect:
		return "connect"
	case .TLS:
		return "tls"
	case .Request_Write:
		return "request_write"
	case .Response_Head:
		return "response_head"
	case .Response_Body:
		return "response_body"
	case .Complete:
		return "complete"
	}
	unreachable()
}
