package agent

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:time"

import "nabla:agent/session"
import "nabla:ai"

// --- request records ---------------------------------------------------------

@(private)
Chat_Request_Config :: struct {
	max_output_tokens: Maybe(i64) `json:"max_output_tokens"`,
	effort:            string `json:"effort"`,
}

// Chat_Request_Tool is one advertised tool as the model saw it: the exact
// name, description, and schema bytes the request carried.
@(private)
Chat_Request_Tool :: struct {
	name:         string `json:"name"`,
	description:  string `json:"description"`,
	input_schema: string `json:"input_schema"`,
}

// CHAT_REQUEST_INPUT_VERSION versions the request input record. input_json is
// opaque text, so old rows stay valid; the version tells a future reader which
// shape a row was written in. Version 2 adds where the send sat in its chain.
CHAT_REQUEST_INPUT_VERSION :: 2

// Chat_Recovery_Kind names how one send came to be. A chain is read back through
// these: a first send, the same frozen bytes sent again, and a send of rebuilt
// context are three different facts, and a reader that had to infer them from
// timing or from an outcome would get them wrong.
Chat_Recovery_Kind :: enum {
	Initial,
	Transient_Retry,
	Checkpoint_Repair,
}

chat_recovery_kind_name :: proc(kind: Chat_Recovery_Kind) -> string {
	switch kind {
	case .Initial:
		return "initial"
	case .Transient_Retry:
		return "transient_retry"
	case .Checkpoint_Repair:
		return "checkpoint_repair"
	}
	return "initial"
}

// Chat_Attempt is where one send sits in the chain that produced it. The first send
// of a chain names no predecessor, and every later one names the send before it, so
// the chain is stored rather than reconstructed.
Chat_Attempt :: struct {
	number:   int,
	recovery: Chat_Recovery_Kind,
	previous: Maybe(session.Request_No),
}

@(private)
Chat_Request_Input :: struct {
	format_version:           u32 `json:"format_version"`,
	instructions:             string `json:"instructions"`,
	tools:                    []Chat_Request_Tool `json:"tools"`,
	summary_seq:              Maybe(session.Seq) `json:"summary_seq"`,
	covered_seq:              Maybe(session.Seq) `json:"covered_seq"`,
	context_through:          Maybe(session.Seq) `json:"context_through"`,
	instruction_snapshot_seq: Maybe(session.Seq) `json:"instruction_snapshot_seq"`,
	attempt_number:           i64 `json:"attempt_number"`,
	recovery_kind:            string `json:"recovery_kind"`,
	previous_request_no:      Maybe(i64) `json:"previous_request_no"`,
	// body_sha256 is the digest of the bytes this send carries. A chain that repeats the
	// same bytes says so in the store rather than in a comment, and a repaired request
	// shows the payload that changed.
	body_sha256:              string `json:"body_sha256"`,
}

@(private)
Chat_Request_Response :: struct {
	reason:   string `json:"reason"`,
	attempts: int `json:"attempts"`,
}

// CHAT_COMPACTION_RESPONSE_VERSION versions the record of a summarization's
// result. The summary is stored here and nowhere else until a checkpoint installs
// it, so a request that completed and produced a checkpoint that was never
// installed is legible after the fact.
CHAT_COMPACTION_RESPONSE_VERSION :: 1

@(private)
Chat_Compaction_Response :: struct {
	format_version: u32 `json:"format_version"`,
	summary:        string `json:"summary"`,
	base_seq:       Maybe(i64) `json:"base_seq"`,
	covered_seq:    i64 `json:"covered_seq"`,
}

// chat_compaction_response_json records what a summarization produced. The result is
// temp-allocated, because the caller stores it immediately.
chat_compaction_response_json :: proc(summary: string, base_seq: Maybe(session.Seq), covered_seq: session.Seq) -> string {
	record := Chat_Compaction_Response {
		format_version = CHAT_COMPACTION_RESPONSE_VERSION,
		summary        = summary,
		covered_seq    = i64(covered_seq),
	}
	if value, present := base_seq.?; present { record.base_seq = i64(value) }
	data, marshal_err := json.marshal(record, allocator = context.temp_allocator)
	if marshal_err != nil { return "{}" }
	return string(data)
}

// chat_finish_reason_text is the stable name a request record keeps for why the
// model stopped, so the stored value does not depend on a borrowed event string.
chat_finish_reason_text :: proc(reason: ai.Provider_Finish_Reason) -> string {
	switch reason {
	case .Stop:
		return "stop"
	case .Length:
		return "length"
	case .Content_Filter:
		return "content_filter"
	case .Tool_Call:
		return "tool_call"
	case .Unknown:
		return "unknown"
	}
	return "unknown"
}

@(private)
Chat_Request_Error :: struct {
	message: string `json:"message"`,
}

// CHAT_REQUEST_ERROR_VERSION versions the record of a send that did not complete.
// Version 1 kept the harness's message and nothing else; version 2 keeps what the
// layers observed, so a reader can act on the failure instead of reading prose.
CHAT_REQUEST_ERROR_VERSION :: 2

// CHAT_ERROR_DETAIL_MAX_BYTES bounds the detail a durable failure record keeps. The
// provider's own message is bounded where it is read; this bounds what the record
// stores, whatever produced it, and it cuts on a character boundary.
CHAT_ERROR_DETAIL_MAX_BYTES :: 2048

// Chat_Request_Error_Evidence is the harness's account of one send that did not
// complete: the operation's own outcome, what the provider's refusal meant once it was
// normalized, the evidence the transport kept, and what the attempt had already made
// visible. Names are stored rather than ordinals, and a measurement the provider never
// reported is -1 rather than zero.
@(private)
Chat_Request_Error_Evidence :: struct {
	format_version:      u32 `json:"format_version"`,
	kind:                string `json:"kind"`,
	failure_class:       string `json:"failure_class"`,
	status:              i64 `json:"status"`,
	provider_code:       string `json:"provider_code"`,
	provider_request_id: string `json:"provider_request_id"`,
	retry_after_ms:      i64 `json:"retry_after_ms"`,
	retry_directive:     string `json:"retry_directive"`,
	transport_cause:     string `json:"transport_cause"`,
	text_exposed:        bool `json:"text_exposed"`,
	completion_accepted: bool `json:"completion_accepted"`,
	recovery:            string `json:"recovery"`,
	delay_ms:            i64 `json:"delay_ms"`,
	message:             string `json:"message"`,
}

// chat_request_config_json describes the settings a request is sent with. output is the
// bound the request itself carries, not the capacity's ordinary one, because a
// summarization request asks for more and the record has to say what was asked.
@(private)
chat_request_config_json :: proc(chat: ^Chat_Session, output: int) -> string {
	config := Chat_Request_Config{}
	config.effort = chat.effort
	if output > 0 { config.max_output_tokens = i64(output) }
	data, marshal_err := json.marshal(config, allocator = context.temp_allocator)
	if marshal_err != nil { return "{}" }
	return string(data)
}

// chat_request_input_json describes what one send carried, serialized from
// the prepared request rather than reconstructed from the session. The
// inventory in prep.request is the snapshot the request was built with, so the
// record stays true even if the registry changes before the write lands. The
// entries themselves stay in one place, so the record points at them through
// the history boundaries rather than copying them.
//
// Schema bytes are stored as written: the schema travels as a JSON string
// value, so no canonical re-encoding touches the definition the model saw.
@(private)
chat_request_input_json :: proc(
	prep: ^Chat_Request_Prep,
	history: ^session.Context,
	snapshot_seq: Maybe(session.Seq),
	entry_count: int,
	attempt: Chat_Attempt,
	body: []u8,
) -> string {
	input := chat_request_input_make(prep, history, snapshot_seq, entry_count, body)
	chat_request_input_situate(&input, attempt)
	return chat_request_input_encode(input)
}

// chat_request_input_make gathers what a request row records about its input. What it
// returns borrows the preparation and the history it was read from, so it does not
// outlive them.
@(private)
chat_request_input_make :: proc(
	prep: ^Chat_Request_Prep,
	history: ^session.Context,
	snapshot_seq: Maybe(session.Seq),
	entry_count: int,
	body: []u8,
) -> Chat_Request_Input {
	tools := make([dynamic]Chat_Request_Tool, 0, len(prep.request.Tools), context.temp_allocator)
	for &definition in prep.request.Tools {
		append(&tools, Chat_Request_Tool{name = definition.Name, description = definition.Description, input_schema = definition.Parameters_JSON})
	}
	input := Chat_Request_Input {
		format_version = CHAT_REQUEST_INPUT_VERSION,
		tools          = tools[:],
		summary_seq    = history.summary_seq,
		covered_seq    = history.covered_seq,
		body_sha256    = chat_body_digest(body),
	}
	if prep.request.Instructions_Present { input.instructions = prep.request.Instructions }
	input.instruction_snapshot_seq = snapshot_seq
	count := entry_count
	if count > len(history.entries) { count = len(history.entries) }
	if count > 0 { input.context_through = history.entries[count - 1].seq }
	return input
}

// chat_body_digest is the digest of the bytes one send carries, written the way the
// logging capture writes the artifacts it stores. A reader can tell whether two attempts
// sent the same bytes without either one being kept.
@(private)
chat_body_digest :: proc(body: []u8) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, body)
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&ctx, digest[:])
	encoded, encode_err := hex.encode(digest[:], context.temp_allocator)
	if encode_err != nil { return "" }
	return string(encoded)
}

// chat_request_input_situate puts one send in its chain. A chain's rows carry the same
// ingredients and their own place in it, which is what a reader follows instead of
// inferring an order from timing.
@(private)
chat_request_input_situate :: proc(input: ^Chat_Request_Input, attempt: Chat_Attempt) {
	input.attempt_number = i64(attempt.number)
	input.recovery_kind = chat_recovery_kind_name(attempt.recovery)
	input.previous_request_no = nil
	if previous, present := attempt.previous.?; present { input.previous_request_no = i64(previous) }
}

// chat_request_input_encode writes one input record.
@(private)
chat_request_input_encode :: proc(input: Chat_Request_Input) -> string {
	data, marshal_err := json.marshal(input, allocator = context.temp_allocator)
	if marshal_err != nil { return "{}" }
	return string(data)
}

// chat_request_input_clone copies an input record into an allocator that outlives the
// preparation it was read from. It is how a background chain keeps the ingredients of
// every row it will write after the request that produced them is long gone.
@(private)
chat_request_input_clone :: proc(input: ^Chat_Request_Input, allocator: mem.Allocator) {
	input.instructions = strings.clone(input.instructions, allocator)
	input.body_sha256 = strings.clone(input.body_sha256, allocator)
	tools := make([]Chat_Request_Tool, len(input.tools), allocator)
	for &tool, index in tools {
		source := input.tools[index]
		tool = {
			name         = strings.clone(source.name, allocator),
			description  = strings.clone(source.description, allocator),
			input_schema = strings.clone(source.input_schema, allocator),
		}
	}
	input.tools = tools
}

// chat_request_input_destroy releases what chat_request_input_clone allocated.
@(private)
chat_request_input_destroy :: proc(input: ^Chat_Request_Input, allocator: mem.Allocator) {
	delete(input.instructions, allocator)
	delete(input.body_sha256, allocator)
	for &tool in input.tools {
		delete(tool.name, allocator)
		delete(tool.description, allocator)
		delete(tool.input_schema, allocator)
	}
	delete(input.tools, allocator)
	input^ = {}
}

// chat_send_usage totals the usage one send reported. The send is the operation that
// performed it, which is the identity its reports were recorded under.
@(private)
chat_send_usage :: proc(chat: ^Chat_Session, usages: ^[dynamic]Chat_Request_Usage) -> session.Usage {
	return chat_request_usage(usages, u64(chat.operation.id))
}

// Chat_Send_Result is how one send ended, as the caller knows it: the outcome, what
// the model stopped for, the operation's own error when the send had one, and what the
// attempt had already made visible. A failure the callback layer detected instead of
// the operation leaves error absent and carries only the harness's message.
Chat_Send_Result :: struct {
	outcome:             session.Outcome,
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

// chat_request_error_json records a send that failed, from the evidence the operation
// returned and the decision the harness took on it, rather than from the text a
// front-end would show.
@(private)
chat_request_error_json :: proc(result: Chat_Send_Result) -> string {
	error := result.error
	record := Chat_Request_Error_Evidence {
		format_version      = CHAT_REQUEST_ERROR_VERSION,
		kind                = ai.provider_operation_error_name(error.kind),
		failure_class       = ai.provider_failure_class_name(error.failure_class),
		status              = i64(error.status),
		provider_code       = error.provider_code,
		provider_request_id = error.provider_request_id,
		retry_after_ms      = -1,
		retry_directive     = ai.provider_retry_directive_name(error.retry_directive),
		transport_cause     = ai.provider_transport_cause_name(error.transport_cause),
		text_exposed        = result.text_exposed,
		completion_accepted = result.completion_accepted,
		recovery            = request_recovery_reason_name(result.recovery),
		delay_ms            = log_duration_ms(result.delay),
		message             = ai.provider_bounded_text(error.detail, CHAT_ERROR_DETAIL_MAX_BYTES, context.temp_allocator),
	}
	if delay, present := error.retry_after.?; present { record.retry_after_ms = log_duration_ms(delay) }
	data, marshal_err := json.marshal(record, allocator = context.temp_allocator)
	if marshal_err != nil { return "" }
	return string(data)
}

// CHAT_TURN_ERROR_VERSION versions the record of a turn that did not complete. Version 1
// kept the harness's message; version 2 keeps typed facts beside it, so a front-end can
// tell a retry budget that ran out from a context that did not fit without reading prose.
CHAT_TURN_ERROR_VERSION :: 2

// Chat_Turn_Error is why a turn ended without completing. The reason is the one the
// chain's own decision carried, and the cause is what stood in the way when the context
// did not fit. Either may be absent, and an absent fact stays absent rather than becoming
// a name that claims something was known.
@(private)
Chat_Turn_Error :: struct {
	format_version: u32 `json:"format_version"`,
	reason:         string `json:"reason"`,
	cause:          string `json:"cause"`,
	message:        string `json:"message"`,
}

@(private)
chat_turn_error_json :: proc(message: string, reason: Request_Recovery_Reason, reason_present: bool, refusal: Chat_Repair_Refusal) -> string {
	record := Chat_Turn_Error {
		format_version = CHAT_TURN_ERROR_VERSION,
		cause          = chat_repair_refusal_name(refusal),
		message        = message,
	}
	if reason_present { record.reason = request_recovery_reason_name(reason) }
	data, marshal_err := json.marshal(record, allocator = context.temp_allocator)
	if marshal_err != nil { return "" }
	return string(data)
}

@(private)
chat_error_json :: proc(message: string) -> string {
	data, marshal_err := json.marshal(Chat_Request_Error{message = message}, allocator = context.temp_allocator)
	if marshal_err != nil { return "" }
	return string(data)
}

// chat_request_usage totals one send's usage. The provider's last word wins,
// because a provider may report the same measurement more than once as it
// settles, and an absent measurement stays absent rather than becoming zero.
@(private)
chat_request_usage :: proc(usages: ^[dynamic]Chat_Request_Usage, operation: u64) -> session.Usage {
	usage: session.Usage
	for entry in usages {
		if entry.operation != operation { continue }
		if entry.usage.Input_Tokens_Present { usage.input = entry.usage.Input_Tokens }
		if entry.usage.Output_Tokens_Present { usage.output = entry.usage.Output_Tokens }
		if entry.usage.Cached_Input_Tokens_Present { usage.cache_read = entry.usage.Cached_Input_Tokens }
		if entry.usage.Cache_Write_Tokens_Present { usage.cache_write = entry.usage.Cache_Write_Tokens }
	}
	return usage
}
