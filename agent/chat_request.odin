package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

import "nabla:agent/session"
import "nabla:ai"

// --- request assembly --------------------------------------------------------

// NABLA_USER_AGENT names this client to a provider endpoint. Every HTTP client
// sends one, and an endpoint that logs, routes, or throttles by client has only
// this to read.
NABLA_USER_AGENT :: "nabla/0.1.0"

// Chat_Request_Prep is one request built from committed history, together with
// the storage the request borrows. It owns the context it was built from. The
// wire is one ordered list: a verbatim Responses output is a message in it, at
// the position the response occupies in the conversation, so replay order and
// projection order are the same order.
Chat_Request_Prep :: struct {
	history:  session.Context,
	request:  ai.Provider_Request,
	wire:     [dynamic]ai.Provider_Message,
	tools:    [dynamic]ai.Provider_Tool_Def,
	calls:    [dynamic][dynamic]ai.Provider_Tool_Call,
	// feedback holds text this preparation owns and the request borrows: what a refused
	// call is said to be, and what a kept result is replaced by.
	feedback: [dynamic]string,
	estimate: int,
	// sizes is what each part of this request costs on its own. A part measured alone is
	// not a share of the whole, and that is the point: one that alone exceeds what the
	// window can hold will not fit in the whole either, and it is the one thing a person
	// has to change.
	sizes:    Chat_Request_Sizes,
}

chat_request_prep_destroy :: proc(prep: ^Chat_Request_Prep, allocator: mem.Allocator) {
	session.context_destroy(&prep.history, allocator)
	for &slot in prep.calls { delete(slot) }
	delete(prep.calls)
	delete(prep.tools)
	delete(prep.wire)
	for text in prep.feedback { delete(text, allocator) }
	delete(prep.feedback)
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
	chat_build_request_into(chat, &prep, ctx.entries, ctx.dispatches, ctx.summary, connection, "")
	return prep, nil
}

// chat_rebuild_prep replaces prep with a request built from the context as it is
// now. It is how a request is rebuilt after the active context changed under it,
// such as when a finished compaction was installed. False leaves prep destroyed
// and the caller with nothing to send.
@(private)
chat_rebuild_prep :: proc(chat: ^Chat_Session, connection: ai.Provider_Connection, prep: ^Chat_Request_Prep) -> bool {
	chat_request_prep_destroy(prep, chat.allocator)
	ctx, context_err := session.context_load(chat.store, chat.id, chat.allocator)
	if context_err != nil {
		chat_session_record_failure(chat, "the context could not be read again", context_err)
		return false
	}
	prep.history = ctx
	chat_build_request_into(chat, prep, ctx.entries, ctx.dispatches, ctx.summary, connection, "")
	return true
}

// chat_build_request_into assembles a request from an explicit span of stored
// entries and the summary that precedes it. directive, when not empty, is
// appended as the final user message: that is how a compaction request asks for a
// summary while carrying the same instructions, tools, and cache identity as the
// conversation it is summarizing, so the provider prefix it reads is the warm one.
@(private)
chat_build_request_into :: proc(
	chat: ^Chat_Session,
	prep: ^Chat_Request_Prep,
	entries: []session.Entry,
	dispatches: []session.Entry,
	summary: string,
	connection: ai.Provider_Connection,
	directive: string,
) {
	prep.wire = make([dynamic]ai.Provider_Message, 0, len(entries) + 3, chat.allocator)
	prep.tools = make([dynamic]ai.Provider_Tool_Def, 0, chat.allocator)
	prep.calls = make([dynamic][dynamic]ai.Provider_Tool_Call, 0, chat.allocator)
	prep.feedback = make([dynamic]string, 0, chat.allocator)

	// The instruction lane is the most stable content a request carries, so it
	// travels beside the conversation rather than as a turn inside it.
	instructions := ""
	if chat.tools_enabled {
		instructions = chat.skill_instructions if chat.skill_instructions != "" else AGENT_SYSTEM_PROMPT
	} else if chat.skill_instructions != "" {
		instructions = chat.skill_instructions
	}
	// A checkpoint stands in for the history it covers, so the request opens
	// with the checkpoint message as the harness stored it and continues with
	// the entries after it.
	if summary != "" {
		append(&prep.wire, ai.Provider_Message{Role = .User, Content = summary})
	}
	chat_append_entries(&prep.wire, &prep.calls, &prep.feedback, connection.API, entries, dispatches, chat.allocator)
	if directive != "" {
		append(&prep.wire, ai.Provider_Message{Role = .User, Content = directive})
	}

	prep.request = ai.Provider_Request {
		API                  = connection.API,
		Model_Present        = true,
		Model                = chat.model_id,
		Instructions_Present = instructions != "",
		Instructions         = instructions,
		Messages_Present     = true,
		Messages             = prep.wire[:],
		// Every HTTP client names itself, and an endpoint that routes, throttles,
		// or traces by client has only this to read.
		User_Agent_Present   = true,
		User_Agent           = NABLA_USER_AGENT,
		// The session is this conversation. Reporting it as a header is how a
		// gateway can tell one conversation from another and keep a session
		// pinned to whatever it chose; the cache key below is a separate hint
		// that only some endpoints read.
		Session_Id_Present   = true,
		Session_Id           = string(chat.id),
	}
	// The harness replays history itself, so the endpoint is asked not to keep a
	// second copy. On Responses this also makes reasoning items carry their
	// encrypted content, which is what the verbatim record needs to be
	// self-contained rather than dependent on server-side state.
	prep.request.Store_Response_Present = true
	prep.request.Store_Response = false
	// The conversation is worth caching because later requests reuse its prefix,
	// including a compaction request, which reads that prefix to summarize it.
	prep.request.Cache_Request_Present = true
	prep.request.Cache_Request = true
	// The session id is the cache identity: stable for the session's life, so
	// related requests route together and account together. On Responses the
	// implicit breakpoint advances through the newest eligible boundary on its
	// own; on both APIs the key is the routing hint for models that need one. A
	// compaction request shares the conversation's identity because it shares the
	// conversation's prefix.
	prep.request.Prompt_Cache_Key_Present = true
	prep.request.Prompt_Cache_Key = string(chat.id)
	if chat.effort != "" {
		prep.request.Reasoning_Effort_Present = true
		prep.request.Reasoning_Effort = chat.effort
	}
	if chat.tools_enabled {
		for &definition in chat.tools.definitions {
			append(&prep.tools, ai.Provider_Tool_Def{Name = definition.name, Description = definition.description, Parameters_JSON = definition.input_schema})
		}
		prep.request.Tools = prep.tools[:]
	}
	prep.sizes = chat_request_sizes(instructions, prep.wire[:], prep.tools[:])
	prep.estimate = chat_estimate_input_tokens(instructions, prep.wire[:], prep.tools[:])
	// What this request may generate depends on what it carries, because the window is one
	// budget: a fuller context asks for a smaller answer rather than being refused. The
	// estimate does not depend on the bound, which is why it is computed first. A
	// summarization request gets the same rule and a larger answer, because its input is
	// the prefix rather than the whole context.
	prep.request.Max_Output_Tokens_Present = true
	prep.request.Max_Output_Tokens, _ = chat_request_output_bound(chat.capacity, prep.estimate)
}

// chat_append_entries turns stored entries into provider messages. Consecutive
// tool calls become one assistant message, which is how a provider sees a
// multi-call response, and a result names the call it answers through the
// sequence the two entries share.
//
// A call is replayed as what the harness ran, not always as what was proposed: a
// repaired call is replayed with its repair, and a call that never ran and whose
// arguments are not an object is not replayed as a call at all. An endpoint
// refuses a request carrying tool arguments it cannot parse, so replaying the
// model's own malformed bytes would make the request unsendable and poison every
// request that follows. What the model is owed instead is the harness's account
// of the refusal, spoken once, after the results of the calls that did run.
//
// On the Responses API a Response_Entry carries the endpoint's own items, so it
// becomes one verbatim message at that point in the conversation and the plain
// text and calls it already contains are not projected a second time. Native
// items are replayed only when they say exactly what this projection would say,
// because a response whose calls were repaired or refused carries bytes the
// endpoint will not take back. The calls are indexed either way, because a
// result names its call through the sequence the two entries share.
@(private)
chat_append_entries :: proc(
	messages: ^[dynamic]ai.Provider_Message,
	call_lists: ^[dynamic][dynamic]ai.Provider_Tool_Call,
	feedback: ^[dynamic]string,
	api: ai.API_Kind,
	entries: []session.Entry,
	dispatches: []session.Entry,
	allocator: mem.Allocator,
) {
	group: [dynamic]ai.Provider_Tool_Call
	group_open := false
	call_ids := make(map[i64]string, allocator = context.temp_allocator)
	defer delete(call_ids)

	// What each call actually ran with, keyed by the call it answers.
	effective := make(map[i64]string, allocator = context.temp_allocator)
	defer delete(effective)
	for dispatch in dispatches {
		payload, is_dispatch := dispatch.payload.(session.Tool_Dispatch_Entry)
		if !is_dispatch { continue }
		if related, present := dispatch.related_seq.?; present { effective[i64(related)] = payload.arguments }
	}

	// A call that is not replayed as a call still owes the model an answer, so its
	// result becomes harness feedback. The name is kept so the account says which
	// call it is about.
	refused := make(map[i64]string, allocator = context.temp_allocator)
	defer delete(refused)
	pending: [dynamic]string
	defer delete(pending)

	// A request whose calls this projection cannot replay from the proposal alone
	// cannot use its native items either, because those items carry the proposal.
	unfaithful := make(map[i64]bool, allocator = context.temp_allocator)
	defer delete(unfaithful)
	for entry in entries {
		call, is_call := entry.payload.(session.Tool_Call_Entry)
		if !is_call { continue }
		_, project, faithful := chat_replay_call(call, effective[i64(entry.seq)])
		if project && faithful { continue }
		if request, present := entry.request_no.?; present { unfaithful[i64(request)] = true }
	}

	// covered is the request whose assistant side a verbatim output already
	// carries. Its projected text and calls would be the same content twice.
	covered: Maybe(session.Request_No)

	for entry in entries {
		// Feedback waits for the last result of the response it belongs to, so the
		// results stay adjacent to the assistant message that asked for them.
		if entry.kind != .Tool_Result { chat_flush_feedback(messages, &pending) }
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
			if api == .OpenAI_Responses && !chat_response_unfaithful(unfaithful, entry.request_no) {
				append(messages, ai.Provider_Message{Verbatim_Items = payload.output})
				covered = entry.request_no
			}
		case session.Tool_Call_Entry:
			// The index is built before the coverage check: a result names its
			// call through the sequence whether or not the call is projected.
			call_ids[i64(entry.seq)] = payload.call_id
			if !chat_verbatim_covers(api, covered, entry.request_no) {
				arguments, project, _ := chat_replay_call(payload, effective[i64(entry.seq)])
				if project {
					append(&group, ai.Provider_Tool_Call{ID = payload.call_id, Item_ID = payload.item_id, Name = payload.name, Arguments = arguments})
					group_open = true
				} else {
					refused[i64(entry.seq)] = payload.name
				}
			}
		case session.Tool_Result_Entry:
			chat_flush_calls(messages, call_lists, &group, &group_open)
			call_seq: i64 = -1
			if related, present := entry.related_seq.?; present { call_seq = i64(related) }
			if name, is_refused := refused[call_seq]; is_refused {
				text := strings.concatenate({name, CHAT_REFUSED_CALL_SUFFIX, payload.content}, allocator)
				append(feedback, text)
				append(&pending, text)
			} else {
				// A result that was kept is sent as a handle instead of its content. The
				// handle is derived from the stored entry, so the model is told the same
				// thing on every request built from it.
				text := payload.content
				if payload.spilled {
					if call_seq < 0 {
						text = TOOL_RESULT_SPILLED_MESSAGE
					} else {
						text = tool_result_handle(payload.outcome, call_seq, len(payload.content), allocator)
						append(feedback, text)
					}
				}
				append(
					messages,
					ai.Provider_Message{Role = .Tool, Content = text, Tool_Call_ID = call_ids[call_seq], Tool_Is_Error = payload.outcome != .Success},
				)
			}
		case session.Tool_Dispatch_Entry, session.Checkpoint_Entry:
		// Bookkeeping a model is never shown.
		}
	}
	chat_flush_calls(messages, call_lists, &group, &group_open)
	chat_flush_feedback(messages, &pending)
	delete(group)
}

// CHAT_REFUSED_CALL_SUFFIX joins a call's name to the harness's account of why it
// was not run. It is a literal, so the same refusal always says the same bytes.
CHAT_REFUSED_CALL_SUFFIX :: " call was refused before it ran: "

// chat_replay_call decides what a request says a call was. A call that ran is
// replayed with the arguments it ran with, because a repair preserves the model's
// intent and the proposal is then not what ran. A call that never ran is replayed
// as proposed when the proposal is an object, and is not replayed as a call at
// all when it is not: an endpoint refuses arguments it cannot parse, and
// inventing arguments would put words in the model's mouth. faithful says the
// proposal is already exactly what the provider will be told, which is what lets
// a native response be replayed as it stands.
@(private)
chat_replay_call :: proc(call: session.Tool_Call_Entry, effective: string) -> (arguments: string, project: bool, faithful: bool) {
	if effective != "" { return effective, true, effective == call.arguments }
	if chat_arguments_object(call.arguments) { return call.arguments, true, true }
	return "", false, false
}

// chat_arguments_object reports whether a call's arguments are an object an
// endpoint can carry. It is a check on the bytes as sent, not a validation of the
// tool's own fields, which happens where the call is prepared.
@(private)
chat_arguments_object :: proc(raw: string) -> bool {
	if raw == "" { return false }
	value, parse_err := json.parse_string(raw, .JSON, true, context.temp_allocator)
	if parse_err != nil { return false }
	defer json.destroy_value(value, context.temp_allocator)
	_, is_object := value.(json.Object)
	return is_object
}

@(private)
chat_response_unfaithful :: proc(unfaithful: map[i64]bool, request_no: Maybe(session.Request_No)) -> bool {
	request, present := request_no.?
	return present && unfaithful[i64(request)]
}

@(private)
chat_flush_feedback :: proc(messages: ^[dynamic]ai.Provider_Message, pending: ^[dynamic]string) {
	for text in pending^ {
		append(messages, ai.Provider_Message{Role = .User, Content = text})
	}
	clear(pending)
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
// a per-message overhead cannot replace endpoint token counting, so the resolved
// model's capacity keeps a margin and refuses over-budget requests instead of
// sending them. Measured usage from the endpoint is evidence, never the estimate.
CHAT_CHARS_PER_TOKEN :: 4
CHAT_MESSAGE_OVERHEAD_TOKENS :: 8

// Chat_Request_Sizes is what one request costs, by part. The parts are what a person can
// act on: instructions come from configuration, tool schemas from the registry, and the
// conversation is what they can shorten.
Chat_Request_Sizes :: struct {
	instructions: int,
	tools:        int,
	conversation: int,
}

// chat_request_sizes measures each part of a request on its own. The whole request adds
// the parts before dividing by the same characters-per-token, so a part measured alone
// bounds what the whole can be: a part larger than the window is a request that cannot be
// sent, whatever else shrinks.
chat_request_sizes :: proc(instructions: string, messages: []ai.Provider_Message, tools: []ai.Provider_Tool_Def) -> Chat_Request_Sizes {
	return {
		instructions = chat_estimate_input_tokens(instructions, nil, nil),
		tools = chat_estimate_input_tokens("", nil, tools),
		conversation = chat_estimate_input_tokens("", messages, nil),
	}
}

// chat_admission_advice says what to change when a request does not fit. A part that alone
// exceeds what the window can hold is the whole reason nothing sent here fits, and naming
// it is the difference between shortening a prompt that cannot help and changing what can.
@(private)
chat_admission_advice :: proc(sizes: Chat_Request_Sizes, ceiling: int) -> string {
	switch {
	case sizes.instructions > ceiling:
		return "the instructions alone are larger than the window can hold; shorten them or raise the limits"
	case sizes.tools > ceiling:
		return "the tool schemas alone are larger than the window can hold; disable tools or raise the limits"
	case sizes.conversation > ceiling:
		return "the conversation alone is larger than the window can hold; compact or raise the limits"
	}
	return "shorten the prompt, compact, or raise the limits"
}

// chat_admission_check asks whether the estimate leaves room for an answer. It is not a
// check against a reserved budget: there is none. The message is temp-allocated; the
// caller clones it when the turn must record the failure.
chat_admission_check :: proc(chat: ^Chat_Session, estimate: int, sizes: Chat_Request_Sizes) -> (message: string, admitted: bool) {
	// The decision is recorded even when it admits the request: what the harness
	// estimated and what it compared that against is the whole reason a request was
	// refused later.
	binding: Log_Binding
	context.logger = log_rebind(&binding, log_correlation(chat))
	capacity := chat.capacity
	if capacity.window <= 0 {
		fields := [3]Log_Field {
			{key = "decision", value = "unconfigured"},
			{key = "estimate", value = i64(estimate)},
			{key = "context_window", value = i64(capacity.window)},
		}
		log_emit({level = .Warning, category = .Provider, event = "request.admission", fields = fields[:]})
		return "context admission needs context_window: add context_window to the model in config.lua", false
	}
	output, fits := chat_request_output_bound(capacity, estimate)
	admission := [8]Log_Field {
		{key = "decision", value = fits ? "admitted" : "refused"},
		{key = "estimate", value = i64(estimate)},
		{key = "context_window", value = i64(capacity.window)},
		{key = "output", value = i64(output)},
		{key = "margin", value = i64(capacity.margin)},
		// The parts travel with the decision: a refusal nobody can explain is what a
		// breakdown exists to prevent.
		{key = "instructions_tokens", value = i64(sizes.instructions)},
		{key = "tools_tokens", value = i64(sizes.tools)},
		{key = "conversation_tokens", value = i64(sizes.conversation)},
	}
	log_emit({level = .Info, category = .Provider, event = "request.admission", fields = admission[:]})
	if fits {
		return "", true
	}
	return fmt.tprintf(
			"request estimated at ~%d input tokens exceeds the ~%d the %d-token window can hold (%d for estimator error, %d for an answer): %s",
			estimate,
			chat_capacity_input_ceiling(capacity),
			capacity.window,
			capacity.margin,
			CHAT_OUTPUT_MIN_TOKENS,
			chat_admission_advice(sizes, chat_capacity_input_ceiling(capacity)),
		),
		false
}
