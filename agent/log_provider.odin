package agent

import "core:crypto/sha2"

import "nabla:ai"

// Provider observations are the one piece of evidence the harness cannot see for
// itself: the exact bytes an operation encoded are freed when it returns, and the
// response bytes pass through the operation's own chunk callback. The observer
// borrows state that lives in the caller's frame for the whole operation, so
// nothing here is retained past the call it describes.

// Provider_Log is what one provider operation reports into: the scope its records
// carry and the running count of what came back.
Provider_Log :: struct {
	scope:          Log_Context,
	response_bytes: u64,
}

provider_log_observer :: proc(observation: ^Provider_Log) -> ai.Provider_Operation_Observer {
	return {user_data = observation, report = log_provider_report}
}

@(private)
log_provider_report :: proc(user_data: rawptr, report: ai.Provider_Operation_Report) {
	observation := cast(^Provider_Log)user_data
	#partial switch report.stage {
	case .Encoded:
		// The digest is taken over the exact buffer the operation is about to
		// send, so the record can be compared against a later capture without the
		// capture having to exist yet.
		state: sha2.Context_256
		sha2.init_256(&state)
		sha2.update(&state, report.body)
		digest: [sha2.DIGEST_SIZE_256]u8
		sha2.final(&state, digest[:])
		digest_text: [sha2.DIGEST_SIZE_256 * 2]u8
		for byte, index in digest {
			digest_text[index * 2] = log_hex_digit(byte >> 4)
			digest_text[index * 2 + 1] = log_hex_digit(byte & 0x0F)
		}

		fields := [5]Log_Field {
			{key = "api", value = chat_api_name(report.api)},
			{key = "model", value = report.model},
			{key = "tools", value = i64(report.tools)},
			{key = "body_bytes", value = i64(len(report.body))},
			{key = "body_sha256", value = string(digest_text[:])},
		}
		log_emit(observation.scope, Log_Record{level = .Info, category = .Provider, event = "provider.encoded", fields = fields[:]})
	case .Response_Body:
		// The count is what an attempt reports when it ends; the bytes themselves
		// are only kept when capture is on.
		observation.response_bytes = report.bytes
	}
}
