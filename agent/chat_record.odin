package agent

import "core:encoding/json"

import "nabla:agent/session"
import "nabla:ai"

// --- request records ---------------------------------------------------------

@(private)
Chat_Request_Config :: struct {
	max_output_tokens: Maybe(i64) `json:"max_output_tokens"`,
	effort:            string `json:"effort"`,
}

@(private)
Chat_Request_Input :: struct {
	instructions:    string `json:"instructions"`,
	tools:           []string `json:"tools"`,
	summary_seq:     Maybe(session.Seq) `json:"summary_seq"`,
	covered_seq:     Maybe(session.Seq) `json:"covered_seq"`,
	context_through: Maybe(session.Seq) `json:"context_through"`,
}

@(private)
Chat_Request_Response :: struct {
	reason: string `json:"reason"`,
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

// chat_request_config_json describes the settings a request is sent with. A
// summarization request carries its own output bound and no reasoning effort, so
// the record describes that request rather than the ordinary one the session
// would run.
@(private)
chat_request_config_json :: proc(chat: ^Chat_Session, compact: bool) -> string {
	config := Chat_Request_Config{}
	if compact {
		config.max_output_tokens = CHAT_COMPACT_MAX_OUTPUT
	} else {
		config.effort = chat.effort
		if chat.max_output_tokens > 0 { config.max_output_tokens = i64(chat.max_output_tokens) }
	}
	data, marshal_err := json.marshal(config, allocator = context.temp_allocator)
	if marshal_err != nil { return "{}" }
	return string(data)
}

// chat_request_input_json describes what a request carried: the instructions and
// tool names that are not in the entries, the boundary its context started
// after, and the last entry it included. The entries themselves stay in one
// place, so the record points at them rather than copying them.
@(private)
chat_request_input_json :: proc(chat: ^Chat_Session, ctx: session.Context, entry_count: int, compact: bool) -> string {
	tools := make([dynamic]string, 0, 1, context.temp_allocator)
	defer delete(tools)
	if chat.tools_enabled && !compact { append(&tools, TOOL_SHELL_NAME) }

	input := Chat_Request_Input {
		instructions = AGENT_SYSTEM_PROMPT if !compact else CHAT_COMPACT_INSTRUCTIONS,
		tools        = tools[:],
		summary_seq  = ctx.summary_seq,
		covered_seq  = ctx.covered_seq,
	}
	count := entry_count
	if count > len(ctx.entries) { count = len(ctx.entries) }
	if count > 0 { input.context_through = ctx.entries[count - 1].seq }

	data, marshal_err := json.marshal(input, allocator = context.temp_allocator)
	if marshal_err != nil { return "{}" }
	return string(data)
}

@(private)
chat_error_json :: proc(message: string) -> string {
	data, marshal_err := json.marshal(Chat_Request_Error{message = message}, allocator = context.temp_allocator)
	if marshal_err != nil { return "" }
	return string(data)
}

// chat_request_usage totals one request's usage. The provider's last word wins,
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
