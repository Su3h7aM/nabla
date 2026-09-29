package agent

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"

import "nabla:agent/journal"
import "nabla:ai"

Optional_Request_Feature :: enum {
	Adaptive_Thinking,
	Cache_Hints,
}

Optional_Request_Features :: bit_set[Optional_Request_Feature;u8]

OPTIONAL_FEATURE_NAMES := [Optional_Request_Feature]string {
	.Adaptive_Thinking = "adaptive thinking",
	.Cache_Hints       = "cache hints",
}

// --- request assembly --------------------------------------------------------

// NABLA_USER_AGENT names this client to a provider endpoint. Every HTTP client
// sends one, and an endpoint that logs, routes, or throttles by client has only
// this to read.
NABLA_USER_AGENT :: "nabla/0.1.0"

// Chat_Request_Prep is one request built from the committed projection. Everything
// it holds, the projection included, is allocated in the arena it was prepared in and
// released with that arena. The wire is one ordered list: a verbatim Responses output
// is a message in it, at the position the response occupies in the conversation, so
// replay order and projection order are the same order.
Chat_Request_Prep :: struct {
	projection:     Projection,
	request:        ai.Provider_Request,
	wire:           [dynamic]ai.Provider_Message,
	tools:          [dynamic]ai.Provider_Tool_Def,
	calls:          [dynamic][dynamic]ai.Provider_Tool_Call,
	// feedback holds text the request borrows: what a refused call is said to be.
	feedback:       [dynamic]string,
	estimate:       int,
	// sizes is what each part of this request costs on its own. A part measured alone is
	// not a share of the whole, and that is the point: one that alone exceeds what the
	// window can hold will not fit in the whole either, and it is the one thing a person
	// has to change.
	sizes:          Chat_Request_Sizes,
	// replay_refused counts the endpoint's own response records this request refused to
	// replay: a record that cannot be sent back as input, or one that does not say what
	// this projection sends. The projection carries the same conversation, so the request
	// is complete either way; what it does not carry are the fields only the endpoint
	// models.
	replay_refused: int,
}

// chat_prepare reads the committed projection from the chat's head and builds the
// request that follows from it, in arena. Every request is built this way: there is
// no other copy of the conversation to fall out of step with.
@(private, require_results)
chat_prepare :: proc(chat: ^Chat_Session, connection: ai.Provider_Connection, arena: mem.Allocator) -> (prep: Chat_Request_Prep, error: journal.Error) {
	prep.projection = projection_load(chat.store, chat.session, chat.head, arena) or_return
	chat_build_request_into(chat, &prep, prep.projection.items, prep.projection.summary, connection, "", arena) or_return
	return prep, nil
}

// chat_rebuild_prep replaces prep with a request built from the projection as it is
// now, in the same arena. It is how a request is rebuilt after the active context
// changed under it, such as when a finished compaction was installed. False leaves
// the caller with nothing to send.
@(private, require_results)
chat_rebuild_prep :: proc(chat: ^Chat_Session, connection: ai.Provider_Connection, prep: ^Chat_Request_Prep, arena: mem.Allocator) -> bool {
	fresh, prep_error := chat_prepare(chat, connection, arena)
	if prep_error != nil {
		chat_session_record_failure(chat, "the context could not be read again", prep_error)
		return false
	}
	prep^ = fresh
	return true
}

// chat_request_optional_features reports the optional features request carries.
@(private)
chat_request_optional_features :: proc(request: ai.Provider_Request) -> Optional_Request_Features {
	features: Optional_Request_Features
	if request.Adaptive_Thinking { features += {.Adaptive_Thinking} }
	if (request.Cache_Request_Present && request.Cache_Request) || request.Prompt_Cache_Key_Present || request.Prompt_Cache_Options_Present {
		features += {.Cache_Hints}
	}
	return features
}

// chat_request_omit_feature removes feature from request, for an endpoint that refused it.
@(private)
chat_request_omit_feature :: proc(request: ^ai.Provider_Request, feature: Optional_Request_Feature) {
	switch feature {
	case .Adaptive_Thinking:
		request.Adaptive_Thinking = false
	case .Cache_Hints:
		request.Cache_Request_Present = false
		request.Cache_Request = false
		request.Prompt_Cache_Key_Present = false
		request.Prompt_Cache_Options_Present = false
	}
}

// chat_request_freeze encodes prep's request into encoded, with the bytes copied into
// allocator, which is the arena the attempt that sends them is retained with: it never
// sends bytes a later encode has written over. False means the turn has already failed
// with the reason.
@(private, require_results)
chat_request_freeze :: proc(
	chat: ^Chat_Session,
	prep: ^Chat_Request_Prep,
	encoded: ^ai.Provider_Encoded_Request,
	websocket_request: bool,
	allocator: mem.Allocator,
) -> bool {
	frozen: ai.Provider_Encoded_Request
	encode_err: ai.Provider_Operation_Error
	if websocket_request {
		frozen, encode_err = ai.Provider_Request_Freeze_WebSocket_Reusing(prep.request, &chat.encode_cache, chat.allocator)
	} else {
		frozen, encode_err = ai.Provider_Request_Freeze_Reusing(prep.request, &chat.encode_cache, chat.allocator)
	}
	if encode_err.kind != .None {
		chat_session_fail_turn(chat, encode_err.detail)
		ai.Provider_Operation_Error_Destroy(&encode_err, chat.allocator)
		return false
	}
	body, body_error := make([]u8, len(frozen.Body), allocator)
	if body_error != nil {
		chat_session_fail_turn(chat, "the rebuilt request body could not be kept for the attempt")
		return false
	}
	copy(body, frozen.Body)
	if !frozen.Body_Borrowed { delete(frozen.Body, chat.allocator) }
	frozen.Body = body
	frozen.Body_Borrowed = false
	encoded^ = frozen
	return true
}

// chat_build_request_into assembles a request from a span of projected items and the
// summary that precedes them, in arena. directive, when not empty, is appended as the
// final user message: that is how a compaction request asks for a summary while
// carrying the same instructions, tools, and cache identity as the conversation it is
// summarizing, so the provider prefix it reads is the warm one.
@(private, require_results)
chat_build_request_into :: proc(
	chat: ^Chat_Session,
	prep: ^Chat_Request_Prep,
	items: []Projection_Item,
	summary: string,
	connection: ai.Provider_Connection,
	directive: string,
	arena: mem.Allocator,
) -> mem.Allocator_Error {
	return chat_build_request_selection_into(
		chat,
		prep,
		items,
		summary,
		connection,
		chat.provider_id,
		chat.model_id,
		chat.capacity,
		chat.tools_enabled,
		chat.effort,
		chat.refused_features,
		directive,
		arena,
	)
}

// chat_build_request_selection_into builds with an explicit identity and capacity without
// changing the session or its encode cache.
@(private, require_results)
chat_build_request_selection_into :: proc(
	chat: ^Chat_Session,
	prep: ^Chat_Request_Prep,
	items: []Projection_Item,
	summary: string,
	connection: ai.Provider_Connection,
	provider_id, model_id: string,
	capacity: Model_Capacity,
	tools_enabled: bool,
	effort: string,
	refused_features: Optional_Request_Features,
	directive: string,
	arena: mem.Allocator,
) -> mem.Allocator_Error {
	// The request carries one message per entry, so its list is the one table that is sized
	// before it is filled. The other three hold nothing yet: each carries the arena its first
	// entry grows from, and nothing here allocates before there is something to put in it.
	prep.wire = make([dynamic]ai.Provider_Message, 0, len(items) + 3, arena) or_return
	prep.tools.allocator = arena
	prep.calls.allocator = arena
	prep.feedback.allocator = arena

	// The instruction lane is the most stable content a request carries, so it
	// travels beside the conversation rather than as a turn inside it.
	instructions := ""
	if tools_enabled {
		instructions = chat.skill_instructions if chat.skill_instructions != "" else AGENT_SYSTEM_PROMPT
	} else if chat.skill_instructions != "" {
		instructions = chat.skill_instructions
	}
	// A checkpoint stands in for the history it covers, so the request opens
	// with the checkpoint message as the harness stored it and continues with
	// the items after it.
	if summary != "" {
		append(&prep.wire, ai.Provider_Message{Role = .User, Content = summary}) or_return
	}
	replay := Chat_Replay_Target {
		api      = connection.API,
		provider = provider_id,
		model    = model_id,
	}
	prep.replay_refused = chat_append_projection(&prep.wire, &prep.calls, &prep.feedback, replay, items, arena) or_return
	if directive != "" {
		append(&prep.wire, ai.Provider_Message{Role = .User, Content = directive}) or_return
	}

	session_text := strings.clone(chat_session_text(chat), arena) or_return
	prep.request = ai.Provider_Request {
		API                  = connection.API,
		Model_Present        = true,
		Model                = model_id,
		Instructions_Present = instructions != "",
		Instructions         = instructions,
		Messages_Present     = true,
		Messages             = prep.wire[:],
		User_Agent_Present   = true,
		User_Agent           = NABLA_USER_AGENT,
		// The session is this conversation. Reporting it as a header is how a
		// gateway can tell one conversation from another and keep a session
		// pinned to whatever it chose; the cache key below is a separate hint
		// that only some endpoints read.
		Session_Id_Present   = true,
		Session_Id           = session_text,
		Parent_Session_Id    = chat_parent_session(chat),
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
	// Only the Messages API has adaptive thinking, and every model it serves is asked for it:
	// one that cannot take it refuses the request, and the chain resends it without.
	prep.request.Adaptive_Thinking = connection.API == .Anthropic_Messages
	// The session id is the cache identity: stable for the session's life, so
	// related requests route together and account together. On Responses the
	// implicit breakpoint advances through the newest eligible boundary on its
	// own; on both APIs the key is the routing hint for models that need one. A
	// compaction request shares the conversation's identity because it shares the
	// conversation's prefix. A subagent uses its orchestrator's key: its requests open with
	// the orchestrator's tools and instructions, so they belong on the same cache.
	prep.request.Prompt_Cache_Key_Present = true
	prep.request.Prompt_Cache_Key = session_text
	if parent := chat_parent_session(chat); parent != "" { prep.request.Prompt_Cache_Key = parent }
	for feature in refused_features { chat_request_omit_feature(&prep.request, feature) }
	if effort != "" {
		prep.request.Reasoning_Effort_Present = true
		prep.request.Reasoning_Effort = effort
	}
	if tools_enabled {
		for &definition in chat.tools.definitions {
			append(
				&prep.tools,
				ai.Provider_Tool_Def{Name = definition.name, Description = definition.description, Parameters_JSON = definition.input_schema},
			) or_return
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
	prep.request.Max_Output_Tokens, _ = chat_request_output_bound(capacity, prep.estimate)
	return nil
}

// Chat_Replay_Target is who a request goes to. An endpoint's native output items are
// replayed only to the API, provider, and model that produced them; any other target
// gets the neutral text and calls.
Chat_Replay_Target :: struct {
	api:      ai.API_Kind,
	provider: string,
	model:    string,
}

// chat_append_projection turns projected items into provider messages. Consecutive
// calls become one assistant message, which is how a provider sees a multi-call
// response, and a result names its call through the call id the two share.
//
// A call is replayed as what the harness ran, not always as what was proposed: a
// repaired call is replayed with its repair, and a call that never ran and whose
// arguments are not an object is not replayed as a call at all. An endpoint
// refuses a request carrying tool arguments it cannot parse, so replaying the
// model's own malformed bytes would make the request unsendable and poison every
// request that follows. What the model is owed instead is the harness's account
// of the refusal, spoken once, after the results of the calls that did run.
//
// On the Responses API, a response's native output replayed to the model that
// produced it becomes one verbatim message at that point in the conversation, and
// the plain text and calls it already contains are not projected a second time. The
// record is read before it is replayed: only bytes the endpoint's input schema takes
// back and that say exactly what this projection would say are sent in place of it,
// because an endpoint's stream and its terminal array can disagree, and bytes it
// refuses fail every request built from that history.
//
// It reports how many records it refused, which is a fact about this request: the
// projection carries the same conversation, so a refusal changes the prefix the
// endpoint sees and nothing the model is told.
@(private, require_results)
chat_append_projection :: proc(
	messages: ^[dynamic]ai.Provider_Message,
	call_lists: ^[dynamic][dynamic]ai.Provider_Tool_Call,
	feedback: ^[dynamic]string,
	target: Chat_Replay_Target,
	items: []Projection_Item,
	arena: mem.Allocator,
) -> (
	replay_refused: int,
	allocation_error: mem.Allocator_Error,
) {
	// The lookups and replay parses are this projection's own, so the temp memory they use
	// is released when it ends. A caller that asked for the request in temp memory keeps
	// its own arena, because the messages land there.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = arena == context.temp_allocator)
	// Each group of calls becomes part of the request, so it grows in the request's arena.
	group: [dynamic]ai.Provider_Tool_Call
	group.allocator = arena
	group_open := false
	provider_ids := make(map[journal.Call_Id]string, allocator = context.temp_allocator)

	// A call that is not replayed as a call still owes the model an answer, so its
	// result becomes harness feedback. The name is kept so the account says which
	// call it is about.
	refused := make(map[journal.Call_Id]string, allocator = context.temp_allocator)
	// The feedback waiting for the result that follows it holds nothing yet; it carries the
	// allocator its entries grow from.
	pending: [dynamic]string
	pending.allocator = context.temp_allocator

	// A response whose native output is not replayed is projected as text and calls. It is
	// decided here, where the answer still decides what the whole request carries.
	verbatim := make(map[journal.Request_Id]bool, allocator = context.temp_allocator)
	unfaithful := make(map[journal.Request_Id]bool, allocator = context.temp_allocator)
	if target.api == .OpenAI_Responses {
		for item in items {
			call, is_call := item.payload.(Projected_Call)
			if !is_call { continue }
			_, project, faithful := chat_replay_call(call)
			if !project || !faithful { unfaithful[item.request] = true }
		}
	}
	for item in items {
		response, is_response := item.payload.(Projected_Response)
		if !is_response || item.request == 0 { continue }
		// Another endpoint's items mean nothing here; its response goes as text and calls.
		if response.provider != target.provider || response.model != target.model || response.api != chat_api_name(target.api) { continue }
		switch target.api {
		case .OpenAI_Responses:
			// A record that cannot be read is not replayed either: the projection is the
			// copy left.
			calls, readable := ai.Provider_Replay_Read(response.output, context.temp_allocator)
			if readable && !unfaithful[item.request] && chat_replay_record_agrees(calls, item.request, items) {
				verbatim[item.request] = true
			} else {
				replay_refused += 1
			}
		case .Anthropic_Messages:
			if response.output != "" {
				verbatim[item.request] = true
			} else {
				replay_refused += 1
			}
		case .OpenAI_Chat_Completions, .Invalid:
		}
	}

	for item in items {
		covered := verbatim[item.request]
		// Feedback waits for the last result of the response it belongs to, so the
		// results stay adjacent to the assistant message that asked for them.
		if _, is_result := item.payload.(Projected_Result); !is_result { chat_flush_feedback(messages, &pending) or_return }
		switch payload in item.payload {
		case Projected_User:
			chat_flush_calls(messages, call_lists, &group, &group_open) or_return
			append(messages, ai.Provider_Message{Role = .User, Content = payload.text}) or_return
		case Projected_Assistant:
			if !covered || target.api == .Anthropic_Messages {
				chat_flush_calls(messages, call_lists, &group, &group_open) or_return
				append(messages, ai.Provider_Message{Role = .Assistant, Content = payload.text}) or_return
			}
		case Projected_Response:
			chat_flush_calls(messages, call_lists, &group, &group_open) or_return
			if covered { append(messages, ai.Provider_Message{Verbatim_Items = payload.output}) or_return }
		case Projected_Call:
			// The provider id is indexed before the coverage check: a result names its
			// call whether or not the call is projected.
			provider_ids[payload.call] = payload.provider_id
			if covered && target.api == .OpenAI_Responses { continue }
			arguments, project, _ := chat_replay_call(payload)
			if project {
				append(
					&group,
					ai.Provider_Tool_Call{ID = payload.provider_id, Item_ID = payload.item_id, Name = payload.name, Arguments = arguments},
				) or_return
				group_open = true
			} else {
				refused[payload.call] = payload.name
			}
		case Projected_Result:
			chat_flush_calls(messages, call_lists, &group, &group_open) or_return
			if name, is_refused := refused[payload.call]; is_refused {
				text := strings.concatenate({name, CHAT_REFUSED_CALL_SUFFIX, payload.content}, arena) or_return
				append(feedback, text) or_return
				append(&pending, text) or_return
			} else {
				message := ai.Provider_Message {
					Role          = .Tool,
					Content       = payload.content,
					Tool_Call_ID  = provider_ids[payload.call],
					Tool_Is_Error = payload.outcome != .Success,
				}
				append(messages, message) or_return
			}
		}
	}
	chat_flush_calls(messages, call_lists, &group, &group_open) or_return
	chat_flush_feedback(messages, &pending) or_return
	return
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
chat_replay_call :: proc(call: Projected_Call) -> (arguments: string, project: bool, faithful: bool) {
	if call.admitted != "" { return call.admitted, true, call.admitted == call.proposed }
	if ai.Provider_Arguments_Object(call.proposed, context.temp_allocator) { return call.proposed, true, true }
	return "", false, false
}

// chat_replay_record_agrees reports whether one response's own items say exactly what this
// projection will send for that request. Every call the record declares must be a call the
// projection sends with the same argument bytes, and every call the projection sends must be
// declared: a record carrying a call the projection does not send shows the model a call
// nothing answered, and one missing a call the projection sends leaves that call's result
// naming a call the request never declared. An endpoint refuses both, so the record is not
// replayed when it cannot be shown to say the same thing.
@(private)
chat_replay_record_agrees :: proc(declared: []ai.Provider_Tool_Call, request: journal.Request_Id, items: []Projection_Item) -> bool {
	projected := 0
	for item in items {
		if item.request != request { continue }
		call, is_call := item.payload.(Projected_Call)
		if !is_call { continue }
		arguments, send, _ := chat_replay_call(call)
		if !send { continue }
		projected += 1
		matched := false
		for declaration in declared {
			if declaration.ID != call.provider_id { continue }
			if declaration.Arguments != arguments { return false }
			matched = true
			break
		}
		if !matched { return false }
	}
	return projected == len(declared)
}

@(private, require_results)
chat_flush_feedback :: proc(messages: ^[dynamic]ai.Provider_Message, pending: ^[dynamic]string) -> mem.Allocator_Error {
	for text in pending^ {
		append(messages, ai.Provider_Message{Role = .User, Content = text}) or_return
	}
	clear(pending)
	return nil
}

@(private, require_results)
chat_flush_calls :: proc(
	messages: ^[dynamic]ai.Provider_Message,
	call_lists: ^[dynamic][dynamic]ai.Provider_Tool_Call,
	group: ^[dynamic]ai.Provider_Tool_Call,
	open: ^bool,
) -> mem.Allocator_Error {
	if !open^ { return nil }
	append(call_lists, group^) or_return
	append(messages, ai.Provider_Message{Role = .Assistant, Tool_Calls = call_lists[len(call_lists) - 1][:]}) or_return
	allocator := group.allocator
	group^ = {}
	group.allocator = allocator
	open^ = false
	return nil
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
@(require_results)
chat_admission_check :: proc(chat: ^Chat_Session, estimate: int, sizes: Chat_Request_Sizes) -> (message: string, admitted: bool) {
	// The decision is recorded even when it admits the request: what the harness
	// estimated and what it compared that against is the whole reason a request was
	// refused later.
	capacity := chat.capacity
	admission := journal.Request_Admitted {
		estimate            = estimate,
		context_window      = capacity.window,
		margin              = capacity.margin,
		instructions_tokens = sizes.instructions,
		tools_tokens        = sizes.tools,
		conversation_tokens = sizes.conversation,
	}
	header := journal.Record {
		kind     = .Request_Admitted,
		request  = chat.chain.request,
		provider = chat.provider_id,
		model    = chat.model_id,
	}
	if capacity.window <= 0 {
		admission.decision = journal.ADMISSION_DECISION_NAMES[.Unconfigured]
		chat_record(chat, header, admission)
		return "context admission needs context_window: add context_window to the model in config.lua", false
	}
	output, fits := chat_request_output_bound(capacity, estimate)
	admission.decision = journal.ADMISSION_DECISION_NAMES[.Fits if fits else .Refused]
	admission.output = output
	chat_record(chat, header, admission)
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
