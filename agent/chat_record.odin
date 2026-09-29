package agent

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

// Chat_Recovery_Kind names how one send came to be: a first send, the same frozen
// bytes sent again, a send of rebuilt context, or the same request without its cache hints.
Chat_Recovery_Kind :: enum {
	Initial,
	Transient_Retry,
	Checkpoint_Repair,
	Cache_Hints_Omitted,
}

CHAT_RECOVERY_KIND_NAMES := [Chat_Recovery_Kind]string {
	.Initial             = "initial",
	.Transient_Retry     = "transient_retry",
	.Checkpoint_Repair   = "checkpoint_repair",
	.Cache_Hints_Omitted = "cache_hints_omitted",
}

// Chat_Attempt is where one send sits in its request: its number, from 1, and
// how it came to be.
Chat_Attempt :: struct {
	number:   int,
	recovery: Chat_Recovery_Kind,
}

// chat_finish_reason_text is the RESPONSE_FINISH_NAMES name for why the model
// stopped.
chat_finish_reason_text :: proc(reason: ai.Provider_Finish_Reason) -> string {
	switch reason {
	case .Stop:
		return journal.RESPONSE_FINISH_NAMES[.Stop]
	case .Length:
		return journal.RESPONSE_FINISH_NAMES[.Length]
	case .Content_Filter:
		return journal.RESPONSE_FINISH_NAMES[.Content_Filter]
	case .Tool_Call:
		return journal.RESPONSE_FINISH_NAMES[.Tool_Call]
	case .Unknown:
	}
	return journal.RESPONSE_FINISH_NAMES[.Unknown]
}

// chat_text_digest is the hexadecimal SHA-256 of text, in temp memory.
@(require_results)
chat_text_digest :: proc(text: string) -> (string, bool) {
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, transmute([]u8)text)
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&hash_context, digest[:])
	encoded, encode_error := hex.encode(digest[:], context.temp_allocator)
	if encode_error != nil { return "", false }
	return string(encoded), true
}

Chat_Send_Outcome :: enum {
	Completed,
	Failed,
	Cancelled,
}

CHAT_SEND_OUTCOME_NAMES := [Chat_Send_Outcome]string {
	.Completed = "completed",
	.Failed    = "failed",
	.Cancelled = "cancelled",
}

// Chat_Send_Result is how one send ended, as the caller knows it: the outcome, what
// the model stopped for, the operation's own error when the send had one, and what the
// attempt had already made visible. A failure the callback layer detected instead of
// the operation leaves error absent and carries only the harness's message.
Chat_Send_Result :: struct {
	outcome:             Chat_Send_Outcome,
	finish_reason:       ai.Provider_Finish_Reason,
	error:               ai.Provider_Operation_Error,
	error_present:       bool,
	message:             string,
	text_exposed:        bool,
	completion_accepted: bool,
	// recovery says why the harness stopped or waited after this send, and delay is what
	// it waited. They describe the decision taken on this send rather than the send
	// itself, and they are what tells a bounded chain from a broken one.
	recovery:            Request_Recovery_Reason,
	delay:               time.Duration,
}

// chat_send_rejection is the evidence of a send that failed, from what the
// operation returned and the decision the harness took on it. Its strings borrow
// result and temp memory, so it is recorded before either is released.
chat_send_rejection :: proc(result: Chat_Send_Result) -> journal.Response_Rejected {
	rejection := journal.Response_Rejected {
		text_exposed        = result.text_exposed,
		completion_accepted = result.completion_accepted,
		recovery            = request_recovery_reason_name(result.recovery),
		delay_ms            = Log_Duration_Milliseconds(result.delay),
		detail              = result.message,
	}
	if !result.error_present { return rejection }
	error := result.error
	rejection.kind = ai.provider_operation_error_name(error.kind)
	rejection.failure_class = ai.provider_failure_class_name(error.failure_class)
	rejection.status = error.status
	rejection.provider_code = error.provider_code
	rejection.provider_request_id = error.provider_request_id
	rejection.retry_directive = ai.provider_retry_directive_name(error.retry_directive)
	rejection.transport_cause = ai.provider_transport_cause_name(error.transport_cause)
	rejection.detail = error.detail
	if delay, present := error.retry_after.?; present { rejection.retry_after_ms = Log_Duration_Milliseconds(delay) }
	return rejection
}

// chat_send_usage is the usage the running send reported, as the response.committed
// payload carries it, priced with the session's model when the catalog can price
// it. The send is the operation that performed it.
@(private)
chat_send_usage :: proc(chat: ^Chat_Session, usages: ^[dynamic]Chat_Request_Usage) -> journal.Response_Committed {
	committed := chat_request_usage(usages, u64(chat.operation.id))
	if dollars, ok := catalog_cost_of(chat.cost, committed.input_tokens, committed.output_tokens, committed.cache_read_tokens, committed.cache_write_tokens);
	   ok {
		committed.cost = dollars
	}
	return committed
}

// chat_request_usage totals one operation's usage. The provider's last word wins,
// because a provider may report the same measurement more than once as it
// settles, and an absent measurement stays absent rather than becoming zero.
@(private)
chat_request_usage :: proc(usages: ^[dynamic]Chat_Request_Usage, operation: u64) -> (committed: journal.Response_Committed) {
	for entry in usages {
		if entry.operation != operation { continue }
		if entry.usage.Input_Tokens_Present { committed.input_tokens = entry.usage.Input_Tokens }
		if entry.usage.Output_Tokens_Present { committed.output_tokens = entry.usage.Output_Tokens }
		if entry.usage.Cached_Input_Tokens_Present { committed.cache_read_tokens = entry.usage.Cached_Input_Tokens }
		if entry.usage.Cache_Write_Tokens_Present { committed.cache_write_tokens = entry.usage.Cache_Write_Tokens }
	}
	return
}
