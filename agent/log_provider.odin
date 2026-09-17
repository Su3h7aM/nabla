package agent

import "core:crypto/sha2"

import "nabla:ai"

// Provider observations are the one piece of evidence the harness cannot see for
// itself: the exact bytes an operation encoded are freed when it returns, and the
// response bytes pass through the operation's own chunk callback. The observer
// borrows state that lives in the caller's frame for one attempt, so nothing here
// is retained past the call it describes.
//
// Records are emitted against the binding the caller installed, so an observation
// needs no copy of the writer or of the correlation. A payload capture does need
// the writer, because it holds quota and a file, and it copies the correlation
// because its metadata may be written after the operation has moved on.

// Provider_Log is what one provider attempt reports into: the running count of
// what came back, how far the transport got, and the response capture when
// payload capture is on. It is created fresh for each attempt, because a retry is
// a new attempt with its own bytes and its own transfer rather than a
// continuation of the previous one.
Provider_Log :: struct {
	response_bytes:             u64,
	// transfer is the transport's own account of the attempt, and transfer_seen
	// says whether it arrived. An attempt that never reached the transport has no
	// transfer at all, which is a different fact from one that stopped at its first
	// phase.
	transfer:                   ai.Provider_Transfer_Summary,
	transfer_seen:              bool,
	response_capture:           Capture,
	response_capture_attempted: bool,
}

provider_log_observer :: proc(observation: ^Provider_Log) -> ai.Provider_Operation_Observer {
	return {user_data = observation, report = log_provider_report}
}

@(private)
log_provider_report :: proc(user_data: rawptr, report: ai.Provider_Operation_Report) {
	observation := cast(^Provider_Log)user_data
	#partial switch report.stage {
	case .Encoded:
		// The digest is only worth computing when the record would be written:
		// a filtered record must not pay for hashing bytes nobody will read.
		if log_enabled(.Info) {
			// The digest is taken over the exact buffer the operation is about to
			// send, so the record can be compared against a later capture without
			// the capture having to exist yet.
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
			log_emit({level = .Info, category = .Provider, event = "provider.encoded", fields = fields[:]})
		}
		// The whole request body is handed over at once, so its artifact is opened
		// and finished in this call: nothing else can arrive for it.
		if sink := log_active_sink(); sink != nil && sink.capture_mode == .Payloads {
			capture, opened := log_capture_open(sink, log_active_correlation(), .Provider_Request)
			if opened {
				log_capture_write(&capture, report.body)
				log_capture_finish(&capture, true)
			}
		}
	case .Response_Body:
		// The count is what an attempt reports when it ends; the bytes themselves
		// are only kept when capture is on.
		observation.response_bytes = report.bytes
		sink := log_active_sink()
		if sink == nil || sink.capture_mode != .Payloads { return }
		// One artifact covers the whole stream, opened on the first chunk. A refused
		// admission is remembered so the quota is asked once rather than per chunk.
		if !observation.response_capture_attempted {
			observation.response_capture_attempted = true
			capture, opened := log_capture_open(sink, log_active_correlation(), .Provider_Response)
			if opened { observation.response_capture = capture }
		}
		if observation.response_capture.kind != .Invalid {
			log_capture_write(&observation.response_capture, report.chunk)
		}
	case .Transfer:
		// The transport's account of the attempt, recorded whether or not anything
		// was written, because a request that never left says so.
		observation.transfer = report.transfer
		observation.transfer_seen = true
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
