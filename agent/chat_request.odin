package agent

import "core:fmt"
import "core:mem"
import "core:strings"

import "nabla:agent/session"
import "nabla:ai"

// --- request assembly --------------------------------------------------------

// Chat_Request_Prep is one request built from committed history, together with
// the storage the request borrows. It owns the context it was built from. The
// wire is one ordered list: a verbatim Responses output is a message in it, at
// the position the response occupies in the conversation, so replay order and
// projection order are the same order.
Chat_Request_Prep :: struct {
	history:   session.Context,
	request:   ai.Provider_Request,
	wire:      [dynamic]ai.Provider_Message,
	tools:     [dynamic]ai.Provider_Tool_Def,
	calls:     [dynamic][dynamic]ai.Provider_Tool_Call,
	cache_key: string, // owned; request.Prompt_Cache_Key borrows it when present,
	estimate:  int,
}

chat_request_prep_destroy :: proc(prep: ^Chat_Request_Prep, allocator: mem.Allocator) {
	session.context_destroy(&prep.history, allocator)
	for &slot in prep.calls { delete(slot) }
	delete(prep.calls)
	delete(prep.tools)
	delete(prep.wire)
	delete(prep.cache_key, allocator)
	prep^ = {}
}

// chat_prepare reads the committed context and builds the request that follows
// from it. Every request is built this way: there is no other copy of the
// conversation to fall out of step with.
@(private)
chat_prepare :: proc(chat: ^Chat_Session, connection: ai.Provider_Connection) -> (prep: Chat_Request_Prep, err: session.Error) {
	ctx, context_err := session.context_load(chat.store, chat.id, chat.allocator)
	if context_err != nil { return {}, context_err }
	prep.history = ctx
	chat_build_request_into(chat, &prep, ctx.entries, ctx.summary, connection, false)
	return prep, nil
}

// chat_build_request_into assembles a request from an explicit span of stored
// entries and the summary that precedes it. compact selects the summarization
// request, which carries instructions instead of the agent prompt and no tools,
// because a summary must be text.
@(private)
chat_build_request_into :: proc(
	chat: ^Chat_Session,
	prep: ^Chat_Request_Prep,
	entries: []session.Entry,
	summary: string,
	connection: ai.Provider_Connection,
	compact: bool,
) {
	prep.wire = make([dynamic]ai.Provider_Message, 0, len(entries) + 2, chat.allocator)
	prep.tools = make([dynamic]ai.Provider_Tool_Def, 0, chat.allocator)
	prep.calls = make([dynamic][dynamic]ai.Provider_Tool_Call, 0, chat.allocator)

	// The instruction lane is the most stable content a request carries, so it
	// travels beside the conversation rather than as a turn inside it. A
	// summarization request states what a summary is, not what the agent is.
	instructions := ""
	if compact {
		instructions = CHAT_COMPACT_INSTRUCTIONS
	} else if chat.tools_enabled {
		instructions = AGENT_SYSTEM_PROMPT
	}
	// A checkpoint stands in for the history it covers, so the request opens
	// with the summary and continues with the entries after it.
	if summary != "" {
		summary_text := strings.concatenate({"Summary of the conversation so far:\n", summary}, context.temp_allocator)
		append(&prep.wire, ai.Provider_Message{Role = .Assistant, Content = summary_text})
	}
	chat_append_entries(&prep.wire, &prep.calls, connection.API, entries)

	prep.request = ai.Provider_Request {
		API                  = connection.API,
		Model_Present        = true,
		Model                = chat.model_id,
		Instructions_Present = instructions != "",
		Instructions         = instructions,
		Messages_Present     = true,
		Messages             = prep.wire[:],
	}
	// The harness replays history itself, so the endpoint is asked not to keep a
	// second copy. On Responses this also makes reasoning items carry their
	// encrypted content, which is what the verbatim record needs to be
	// self-contained rather than dependent on server-side state.
	prep.request.Store_Response_Present = true
	prep.request.Store_Response = false
	// The conversation is worth caching because later requests reuse its prefix.
	// A summarization is not: its content is one-off, so a cache write would pay a
	// premium for something nothing reads back.
	prep.request.Cache_Request_Present = true
	prep.request.Cache_Request = !compact
	// The session id is the cache identity: stable for the session's life, so
	// related requests route together and account together. On Responses the
	// implicit breakpoint advances through the newest eligible boundary on its
	// own; on both APIs the key is the routing hint for models that need one. A
	// summarization request carries a different identity, so it neither reuses
	// nor displaces the conversation's cache accounting.
	prep.request.Prompt_Cache_Key_Present = true
	if compact {
		prep.cache_key = strings.concatenate({string(chat.id), ":summary"}, chat.allocator)
		prep.request.Prompt_Cache_Key = prep.cache_key
	} else {
		prep.request.Prompt_Cache_Key = string(chat.id)
	}
	if compact {
		prep.request.Max_Output_Tokens_Present = true
		prep.request.Max_Output_Tokens = CHAT_COMPACT_MAX_OUTPUT
	} else {
		if chat.max_output_tokens > 0 {
			prep.request.Max_Output_Tokens_Present = true
			prep.request.Max_Output_Tokens = chat.max_output_tokens
		}
		if chat.effort != "" {
			prep.request.Reasoning_Effort_Present = true
			prep.request.Reasoning_Effort = chat.effort
		}
		if chat.tools_enabled {
			append(
				&prep.tools,
				ai.Provider_Tool_Def{Name = TOOL_SHELL_NAME, Description = TOOL_SHELL_DESCRIPTION, Parameters_JSON = TOOL_SHELL_PARAMETERS_JSON},
			)
			prep.request.Tools = prep.tools[:]
		}
	}
	prep.estimate = chat_estimate_input_tokens(instructions, prep.wire[:], prep.tools[:])
}

// chat_append_entries turns stored entries into provider messages. Consecutive
// tool calls become one assistant message, which is how a provider sees a
// multi-call response, and a result names the call it answers through the
// sequence the two entries share.
//
// On the Responses API a Response_Entry carries the endpoint's own items, so it
// becomes one verbatim message at that point in the conversation and the plain
// text and calls it already contains are not projected a second time. The calls
// are still indexed either way, because a result names its call through the
// sequence the two entries share. Chat Completions has no native items to
// replay, so it keeps the portable projection; entries written before the
// Response_Entry existed replay through that same path.
@(private)
chat_append_entries :: proc(
	messages: ^[dynamic]ai.Provider_Message,
	call_lists: ^[dynamic][dynamic]ai.Provider_Tool_Call,
	api: ai.API_Kind,
	entries: []session.Entry,
) {
	group: [dynamic]ai.Provider_Tool_Call
	group_open := false
	call_ids := make(map[i64]string, allocator = context.temp_allocator)
	defer delete(call_ids)

	// covered is the request whose assistant side a verbatim output already
	// carries. Its projected text and calls would be the same content twice.
	covered: Maybe(session.Request_No)

	for entry in entries {
		#partial switch payload in entry.payload {
		case session.User_Entry:
			chat_flush_calls(messages, call_lists, &group, &group_open)
			append(messages, ai.Provider_Message{Role = .User, Content = payload.text})
		case session.Assistant_Entry:
			if !payload.partial && !chat_verbatim_covers(api, covered, entry.request_no) {
				chat_flush_calls(messages, call_lists, &group, &group_open)
				append(messages, ai.Provider_Message{Role = .Assistant, Content = payload.text})
			}
		case session.Reasoning_Entry:
			chat_flush_calls(messages, call_lists, &group, &group_open)
			append(messages, ai.Provider_Message{Role = .Reasoning, Reasoning_ID = payload.id, Reasoning_Encrypted = payload.encrypted})
		case session.Response_Entry:
			chat_flush_calls(messages, call_lists, &group, &group_open)
			if api == .OpenAI_Responses {
				append(messages, ai.Provider_Message{Verbatim_Items = payload.output})
				covered = entry.request_no
			}
		case session.Tool_Call_Entry:
			// The index is built before the coverage check: a result names its
			// call through the sequence whether or not the call is projected.
			call_ids[i64(entry.seq)] = payload.call_id
			if !chat_verbatim_covers(api, covered, entry.request_no) {
				append(&group, ai.Provider_Tool_Call{ID = payload.call_id, Item_ID = payload.item_id, Name = payload.name, Arguments = payload.arguments})
				group_open = true
			}
		case session.Tool_Result_Entry:
			chat_flush_calls(messages, call_lists, &group, &group_open)
			call_id := ""
			if related, present := entry.related_seq.?; present { call_id = call_ids[i64(related)] }
			append(messages, ai.Provider_Message{Role = .Tool, Content = payload.content, Tool_Call_ID = call_id})
		case session.Tool_Dispatch_Entry, session.Checkpoint_Entry:
		// Bookkeeping a model is never shown.
		}
	}
	chat_flush_calls(messages, call_lists, &group, &group_open)
	delete(group)
}

// chat_verbatim_covers reports whether a verbatim output already carries the
// assistant side of this entry's request. Both values must name the same
// request: an entry with no request, such as a steering line, is never covered.
@(private)
chat_verbatim_covers :: proc(api: ai.API_Kind, covered, request_no: Maybe(session.Request_No)) -> bool {
	if api != .OpenAI_Responses { return false }
	covered_value, covered_ok := covered.?
	request_value, request_ok := request_no.?
	return covered_ok && request_ok && covered_value == request_value
}

@(private)
chat_flush_calls :: proc(
	messages: ^[dynamic]ai.Provider_Message,
	call_lists: ^[dynamic][dynamic]ai.Provider_Tool_Call,
	group: ^[dynamic]ai.Provider_Tool_Call,
	open: ^bool,
) {
	if !open^ { return }
	append(call_lists, group^)
	append(messages, ai.Provider_Message{Role = .Assistant, Tool_Calls = call_lists[len(call_lists) - 1][:]})
	group^ = {}
	open^ = false
}

@(private)
chat_estimate_input_tokens :: proc(instructions: string, messages: []ai.Provider_Message, tools: []ai.Provider_Tool_Def) -> int {
	chars := len(instructions)
	for message in messages {
		chars += len(message.Content) + len(message.Tool_Call_ID) + len(message.Reasoning_ID) + len(message.Reasoning_Encrypted) + len(message.Verbatim_Items)
		for call in message.Tool_Calls {
			chars += len(call.ID) + len(call.Item_ID) + len(call.Name) + len(call.Arguments)
		}
	}
	for tool in tools {
		chars += len(tool.Name) + len(tool.Description) + len(tool.Parameters_JSON)
	}
	return chars / CHAT_CHARS_PER_TOKEN + len(messages) * CHAT_MESSAGE_OVERHEAD_TOKENS
}

// Admission is approximate and says so: character counts divided by four plus
// a per-message overhead cannot replace endpoint token counting, so the check
// keeps a safety margin and refuses over-budget requests instead of sending
// them. Measured usage from the endpoint is evidence, never the estimate.
CHAT_CHARS_PER_TOKEN :: 4
CHAT_MESSAGE_OVERHEAD_TOKENS :: 8
CHAT_ADMISSION_MARGIN_TOKENS :: 8192
CHAT_DEFAULT_OUTPUT_RESERVE_TOKENS :: 4096

// chat_admission_check enforces input estimate plus reserved generation plus
// margin against the configured window. The message is temp-allocated; the
// caller clones it when the turn must record the failure.
chat_admission_check :: proc(chat: ^Chat_Session, estimate: int) -> (message: string, admitted: bool) {
	if chat.context_window <= 0 {
		return "context admission needs context_window: add context_window to the model in config.lua", false
	}
	reserved := chat.max_output_tokens
	if reserved <= 0 { reserved = CHAT_DEFAULT_OUTPUT_RESERVE_TOKENS }
	if estimate + reserved + CHAT_ADMISSION_MARGIN_TOKENS <= chat.context_window {
		return "", true
	}
	return fmt.tprintf(
			"request estimated at ~%d input tokens exceeds the %d-token window (reserved %d output, %d margin): shorten the prompt, compact, or raise the limits",
			estimate,
			chat.context_window,
			reserved,
			CHAT_ADMISSION_MARGIN_TOKENS,
		),
		false
}
