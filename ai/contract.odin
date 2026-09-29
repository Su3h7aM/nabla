package ai

import "core:encoding/json"
import "core:mem"
import "core:strings"

API_Kind :: enum {
	Invalid,
	OpenAI_Chat_Completions,
	OpenAI_Responses,
	Anthropic_Messages,
}

Provider_Connection :: struct {
	API:        API_Kind,
	Endpoint:   string,
	Credential: string, // borrowed until operation retirement; secret,
}

// Provider_Transport_Kind is one wire transport an API adapter can speak. It names a
// protocol capability, not a provider: whether an endpoint serves its API over a
// WebSocket is a property of the API the adapter implements, and nothing here is keyed
// on a provider or model identity.
Provider_Transport_Kind :: enum {
	HTTP,
	WebSocket,
}

// Provider_API_Transports reports which wire transports an API adapter implements. Every
// adapter speaks HTTP; one that also implements a connection-oriented transport says so
// here. The switch is exhaustive over the API families, so adding a family is a compile
// error until this package has decided what it can carry.
Provider_API_Transports :: proc(api: API_Kind) -> bit_set[Provider_Transport_Kind] {
	switch api {
	case .OpenAI_Responses:
		return {.HTTP, .WebSocket}
	case .OpenAI_Chat_Completions, .Anthropic_Messages:
		return {.HTTP}
	case .Invalid:
	}
	return {}
}

Provider_Role :: enum {
	Invalid,
	System,
	User,
	Assistant,
	Tool,
	// Reasoning carries an opaque Responses reasoning item for replay. The
	// content stays encrypted and unread; only id and encrypted_content are
	// kept, which is what the endpoint needs to continue reasoning.
	Reasoning,
}

Provider_Tool_Call :: struct {
	ID:        string, // borrowed until operation retirement; Chat id / Responses call_id,
	Item_ID:   string, // borrowed; Responses output-item id, empty for Chat,
	Name:      string, // borrowed until operation retirement,
	// Arguments is the raw argument text the endpoint produced, exactly as it
	// assembled it. It may be empty or malformed JSON: the provider boundary
	// decides that a call is trustworthy, not that its arguments are usable, and
	// the agent validates the document before anything runs.
	Arguments: string, // borrowed until operation retirement,
}

Provider_Tool_Def :: struct {
	Name:            string, // borrowed until operation retirement,
	Description:     string, // borrowed until operation retirement,
	Parameters_JSON: string, // borrowed until operation retirement,
}

Provider_Message :: struct {
	Role:                Provider_Role,
	Content:             string, // borrowed until operation retirement,
	Tool_Call_ID:        string, // borrowed; set on .Tool results, matches a call ID,
	// Tool_Is_Error marks a tool result the model should read as a failure. The
	// harness sets it for every outcome other than .Success: a nonzero exit is
	// .Tool_Failed, so it arrives as an error. It exists because some
	// providers carry the distinction on the wire.
	Tool_Is_Error:       bool,
	Tool_Calls:          []Provider_Tool_Call, // borrowed; set on assistant messages that request calls,
	Reasoning_ID:        string, // borrowed; set on .Reasoning, the output-item id,
	Reasoning_Encrypted: string, // borrowed; set on .Reasoning when the endpoint supplied it,
	Cache_Breakpoint:    bool, // when true, emit prompt_cache_breakpoint explicit on this message,
	// Verbatim_Items is a JSON array of Responses output items preserved at this
	// message's position. It is the replay slot: fields the harness does not
	// model, such as assistant phase, reasoning summaries, and annotations,
	// survive because nothing here is re-derived. The Responses encoder removes
	// output-only fields before splicing the array in place. Only the Responses
	// API accepts it; the harness sets it only for that API.
	Verbatim_Items:      string, // borrowed until operation retirement,
}

Prompt_Cache_Mode :: enum {
	Invalid,
	Implicit,
	Explicit,
}

Prompt_Cache_Options :: struct {
	Mode_Present: bool,
	Mode:         Prompt_Cache_Mode,
	TTL_Present:  bool,
	TTL:          string, // borrowed; only "30m" per spec,
}

Provider_Request :: struct {
	API:                            API_Kind,
	Model_Present:                  bool,
	Model:                          string,
	// Instructions is the instruction content that precedes the conversation.
	// It is not a message: a conversation never contains an instruction turn,
	// and the prefix a later request reuses begins with it. Responses takes it
	// as the top-level `instructions` field; Chat Completions has no such field
	// and takes it as a leading system message.
	Instructions_Present:           bool,
	Instructions:                   string, // borrowed until operation retirement,
	Messages_Present:               bool,
	Messages:                       []Provider_Message,
	Tools:                          []Provider_Tool_Def, // borrowed; frozen for the whole turn,
	Max_Output_Tokens_Present:      bool,
	Max_Output_Tokens:              int,
	// Reasoning effort is a verbatim level validated against the model's
	// configured levels, never translated. Absent means provider default.
	Reasoning_Effort_Present:       bool,
	Reasoning_Effort:               string, // borrowed; valid only when present,
	Prompt_Cache_Key_Present:       bool,
	Prompt_Cache_Key:               string, // borrowed; optional routing/accounting hint,
	Prompt_Cache_Options_Present:   bool,
	Prompt_Cache_Options:           Prompt_Cache_Options,
	Prompt_Cache_Retention_Present: bool,
	Prompt_Cache_Retention:         string, // borrowed; deprecated, use options TTL,
	// Store_Response asks the endpoint to keep or discard its own copy of the
	// response. The harness replays history itself, so it asks the endpoint not
	// to keep a second copy; absent leaves the endpoint default. Both OpenAI
	// APIs accept the field.
	Store_Response_Present:         bool,
	Store_Response:                 bool,
	// Cache_Request asks the provider to keep this request's prefix for reuse by
	// later ones. It is false for content that recurs only when the turn does,
	// such as a summarization, so paying a cache-write premium for it cannot
	// displace the conversation's own entries. Absent means the provider decides.
	Cache_Request_Present:          bool,
	Cache_Request:                  bool,
	// User_Agent and Session_Id are the identities this client reports to the
	// endpoint. Both are opaque here: the caller supplies its own names, because
	// what identifies a client and a conversation is the caller's business. An
	// endpoint that routes, throttles, or traces by client needs them, and one
	// that has no use for them is sent no header.
	User_Agent_Present:             bool,
	User_Agent:                     string, // borrowed until operation retirement,
	Session_Id_Present:             bool,
	Session_Id:                     string, // borrowed until operation retirement,
	// Parent_Session_Id names the conversation that started this one, such as the
	// orchestrator of a subagent. "" sends no header. Borrowed until operation retirement.
	Parent_Session_Id:              string,
}

Provider_Request_Error :: enum {
	None,
	Unsupported_API,
	Missing_Model,
	Missing_Messages,
	Invalid_Instructions,
	Invalid_Message,
	Invalid_Tools,
	Invalid_Tool_Call,
	Invalid_Max_Output_Tokens,
	Missing_Max_Output_Tokens,
	Invalid_Reasoning_Effort,
	Invalid_Prompt_Cache_Key,
	Invalid_Prompt_Cache_Options,
	Invalid_Prompt_Cache_Retention,
	// Allocation means the local request body or cache could not be built.
	Allocation,
}

@(require_results)
Provider_Validate_Request :: proc(request: Provider_Request) -> Provider_Request_Error {
	switch request.API {
	case .OpenAI_Chat_Completions, .OpenAI_Responses, .Anthropic_Messages:
	case .Invalid:
		return .Unsupported_API
	}
	if !request.Model_Present || request.Model == "" { return .Missing_Model }
	if request.Instructions_Present && request.Instructions == "" { return .Invalid_Instructions }
	if !request.Messages_Present || len(request.Messages) == 0 { return .Missing_Messages }
	if request.Max_Output_Tokens_Present && request.Max_Output_Tokens <= 0 { return .Invalid_Max_Output_Tokens }
	if request.Reasoning_Effort_Present && request.Reasoning_Effort == "" { return .Invalid_Reasoning_Effort }
	if request.Prompt_Cache_Key_Present && request.Prompt_Cache_Key == "" { return .Invalid_Prompt_Cache_Key }
	if request.Prompt_Cache_Options_Present {
		if !request.Prompt_Cache_Options.Mode_Present && !request.Prompt_Cache_Options.TTL_Present { return .Invalid_Prompt_Cache_Options }
		if request.Prompt_Cache_Options.Mode_Present && request.Prompt_Cache_Options.Mode == .Invalid { return .Invalid_Prompt_Cache_Options }
		if request.Prompt_Cache_Options.TTL_Present && request.Prompt_Cache_Options.TTL != "30m" { return .Invalid_Prompt_Cache_Options }
	}
	if request.Prompt_Cache_Retention_Present &&
	   request.Prompt_Cache_Retention != "in_memory" &&
	   request.Prompt_Cache_Retention != "24h" { return .Invalid_Prompt_Cache_Retention }
	for message in request.Messages {
		// A verbatim message is one opaque replay array, not a role plus content,
		// so the role checks below do not apply to it. Only the Responses API
		// has native items to replay; asking another API to emit them would send
		// a message with no role and no content.
		if message.Verbatim_Items != "" {
			if request.API != .OpenAI_Responses { return .Invalid_Message }
			continue
		}
		if message.Role == .Invalid { return .Invalid_Message }
		#partial switch message.Role {
		case .Assistant:
			if message.Content == "" && len(message.Tool_Calls) == 0 { return .Invalid_Message }
		case .Tool:
			if message.Tool_Call_ID == "" { return .Invalid_Message }
		case .Reasoning:
			if message.Reasoning_ID == "" { return .Invalid_Message }
		case:
			if message.Content == "" { return .Invalid_Message }
		}
		for call in message.Tool_Calls {
			if call.ID == "" || call.Name == "" { return .Invalid_Tool_Call }
		}
	}
	for tool in request.Tools {
		if tool.Name == "" || tool.Parameters_JSON == "" { return .Invalid_Tools }
	}
	return .None
}

// Provider_Arguments_Object reports whether raw is the JSON object an endpoint carries as a
// tool call's arguments. Both OpenAI APIs type the field as text holding an object, so
// anything else -- empty, malformed, an array -- makes the request that carries it
// unsendable. This is a check on the bytes alone: whether the tool accepts the fields they
// name is the tool's own validator's business.
@(require_results)
Provider_Arguments_Object :: proc(raw: string, allocator := context.allocator) -> bool {
	if raw == "" { return false }
	value, parse_err := json.parse_string(raw, .JSON, true, allocator)
	if parse_err != nil { return false }
	defer json.destroy_value(value, allocator)
	_, is_object := value.(json.Object)
	return is_object
}

Provider_Finish_Reason :: enum {
	Unknown,
	Stop,
	Length,
	Content_Filter,
	Tool_Call,
}
Provider_Error_Kind :: enum {
	Invalid_Data,
	Stream_Truncated,
	API_Error,
	Unsupported_Tool_Output,
	// Cancelled and Timed_Out are distinct from stream defects: the response was
	// interrupted on purpose, and its partial output is not authoritative.
	Cancelled,
	Timed_Out,
	// TLS means the peer did not authenticate; it is never a usable response.
	TLS,
	// Allocation means the local stream state could not retain what it decoded. It
	// is a local failure: the provider sent a usable payload, and the client could
	// not keep it.
	Allocation,
}

Provider_Text_Event :: struct {
	Text: string,
} // owned by receiver
// Reasoning items arrive as their own event so the session stores them in
// wire order, interleaved with text and tool calls exactly as the endpoint
// produced them. Both strings are owned by the receiver.
Provider_Reasoning_Event :: struct {
	ID:        string,
	Encrypted: string,
}
Provider_Usage_Event :: struct {
	Cached_Input_Tokens:         i64,
	Cached_Input_Tokens_Present: bool,
	Cache_Write_Tokens:          i64,
	Cache_Write_Tokens_Present:  bool,
	Input_Tokens:                i64,
	Output_Tokens:               i64,
	Total_Tokens:                i64,
	Input_Tokens_Present:        bool,
	Output_Tokens_Present:       bool,
	Total_Tokens_Present:        bool,
}
Provider_Completed_Event :: struct {
	Reason:      Provider_Finish_Reason,
	Reason_Text: string, // owned by receiver,
	Tool_Calls:  []Provider_Tool_Call, // owned by receiver; present when Reason == .Tool_Call,
	// Raw_Output holds the terminal response's output array verbatim, exactly
	// as the endpoint sent it. Empty when the terminal event carried no
	// output array. The agent replays this verbatim for its next request, so
	// the fields the stream decoder does not model -- assistant phase,
	// reasoning summaries, annotations -- still round-trip; the Responses
	// encoder drops the output-only fields the input schema refuses. This is
	// the lossless-replay record; Tool_Calls stays the execution view.
	Raw_Output:  string, // owned by receiver,
} // Tool_Calls and Raw_Output owned by receiver
Provider_Error_Event :: struct {
	Kind:                 Provider_Error_Kind,
	Message:              string,
	Provider_Code:        string,
	Provider_Detail_Code: string,
} // strings owned by receiver
Provider_Event :: union {
	Provider_Text_Event,
	Provider_Reasoning_Event,
	Provider_Usage_Event,
	Provider_Completed_Event,
	Provider_Error_Event,
}

// Provider_Tool_Calls_Destroy releases a call list and every string it owns. A new holder
// of calls a provider fact carries cannot free half of a call or leak the rest.
Provider_Tool_Calls_Destroy :: proc(calls: []Provider_Tool_Call, allocator := context.allocator) {
	for &call in calls { provider_tool_call_destroy(&call, allocator) }
	if calls != nil { delete(calls, allocator) }
}

// provider_tool_call_destroy releases every string one call owns, wherever it is stored.
provider_tool_call_destroy :: proc(call: ^Provider_Tool_Call, allocator := context.allocator) {
	if call.ID != "" { delete(call.ID, allocator) }
	if call.Item_ID != "" { delete(call.Item_ID, allocator) }
	if call.Name != "" { delete(call.Name, allocator) }
	if call.Arguments != "" { delete(call.Arguments, allocator) }
	call^ = {}
}

Provider_Event_Destroy :: proc(event: ^Provider_Event, allocator := context.allocator) {
	if event == nil { return }
	#partial switch value in event^ {
	case Provider_Text_Event:
		if value.Text != "" { delete(value.Text, allocator) }
	case Provider_Reasoning_Event:
		if value.ID != "" { delete(value.ID, allocator) }
		if value.Encrypted != "" { delete(value.Encrypted, allocator) }
	case Provider_Completed_Event:
		if value.Reason_Text != "" { delete(value.Reason_Text, allocator) }
		if value.Raw_Output != "" { delete(value.Raw_Output, allocator) }
		Provider_Tool_Calls_Destroy(value.Tool_Calls, allocator)
	case Provider_Error_Event:
		if value.Message != "" { delete(value.Message, allocator) }
		if value.Provider_Code != "" { delete(value.Provider_Code, allocator) }
		if value.Provider_Detail_Code != "" { delete(value.Provider_Detail_Code, allocator) }
	}
	event^ = nil
}

Provider_Stream_Phase :: enum {
	Open,
	Completed,
	Done,
	Failed,
}

Provider_Stream_State :: struct {
	API:            API_Kind,
	Phase:          Provider_Stream_Phase,
	Tool_Fragments: [dynamic]Provider_Tool_Fragment, // owned assembly slots,
	Allocator:      mem.Allocator,
	// Operation-owned staging for one decoded payload. It grows to hold every
	// event the payload carried, is drained before the next payload is
	// consumed, and its undrained events are destroyed with the stream.
	Batch:          [dynamic]Provider_Event,
}

Provider_Tool_Fragment :: struct {
	Present:            bool,
	Complete:           bool, // full arguments validated once (Responses done event),
	Item_ID:            string, // owned,
	ID:                 string, // owned; Chat id / Responses call_id,
	Name:               string, // owned,
	Arguments:          [dynamic]u8, // owned raw bytes,
	Wire_Index:         i64,
	Wire_Index_Present: bool,
	// Arguments_Started marks that streamed argument fragments have begun, so a
	// value stated by the opening event is replaced rather than appended to.
	// Anthropic states the input object on the block and streams its JSON after.
	Arguments_Started:  bool,
}

@(require_results)
Provider_Stream_Start :: proc(api: API_Kind, allocator := context.allocator) -> Provider_Stream_State {
	return {API = api, Phase = .Open, Allocator = allocator}
}

provider_stream_batch_clear :: proc(state: ^Provider_Stream_State) {
	for &event in state.Batch { Provider_Event_Destroy(&event, state.Allocator) }
	clear(&state.Batch)
}

// provider_stream_push stages one event under the stream's ownership. An event that
// cannot be staged is destroyed and fails the stream, so the caller retains nothing.
provider_stream_push :: proc(state: ^Provider_Stream_State, event: Provider_Event) {
	if state.Batch.allocator.procedure == nil { state.Batch.allocator = state.Allocator }
	if _, append_error := append(&state.Batch, event); append_error != nil {
		owned := event
		Provider_Event_Destroy(&owned, state.Allocator)
		state.Phase = .Failed
	}
}

// Discard staged success events and expose one error. A malformed payload
// never leaves a partial batch behind.
@(require_results)
provider_stream_fail :: proc(
	state: ^Provider_Stream_State,
	kind: Provider_Error_Kind,
	message: string,
	stream_err := Provider_Stream_Error.Malformed_Event,
	code := "",
) -> Provider_Stream_Error {
	provider_stream_batch_clear(state)
	event, event_error := openai_error_event(kind, message, code, allocator = state.Allocator)
	if event_error != nil {
		// The wording could not be retained. The kind still names the failure, so the
		// caller learns why the stream stopped rather than nothing at all.
		event = Provider_Error_Event {
			Kind = kind,
		}
	}
	provider_stream_push(state, event)
	state.Phase = .Failed
	return stream_err
}

// provider_stream_fail_allocation reports a stream that could not retain what it decoded.
// It is a local failure: the payload was usable, and the client could not keep it.
@(require_results)
provider_stream_fail_allocation :: proc(state: ^Provider_Stream_State, message: string) -> Provider_Stream_Error {
	return provider_stream_fail(state, .Allocation, message, .Allocation)
}

// Transfers one owned event to the caller and removes it from the batch.
@(require_results)
Provider_Stream_Drain :: proc(state: ^Provider_Stream_State) -> (Provider_Event, bool) {
	if state == nil { return nil, false }
	return pop_front_safe(&state.Batch)
}

Provider_Stream_Destroy :: proc(state: ^Provider_Stream_State) {
	if state == nil { return }
	provider_stream_batch_clear(state)
	delete(state.Batch)
	state.Batch = nil
	for &fragment in state.Tool_Fragments {
		if fragment.Item_ID != "" { delete(fragment.Item_ID, state.Allocator) }
		if fragment.ID != "" { delete(fragment.ID, state.Allocator) }
		if fragment.Name != "" { delete(fragment.Name, state.Allocator) }
		if fragment.Arguments != nil { delete(fragment.Arguments) }
	}
	delete(state.Tool_Fragments)
	state.Tool_Fragments = nil
}

provider_tool_fragments_present :: proc(state: ^Provider_Stream_State) -> bool {
	for &fragment in state.Tool_Fragments {
		if fragment.Present { return true }
	}
	return false
}

// provider_tool_fragment_append reserves the next tool-call slot. The slot is owned by the
// stream and released with it, and a failure to reserve one fails the stream, so a call is
// never reserved without storage for its arguments.
@(require_results)
provider_tool_fragment_append :: proc(state: ^Provider_Stream_State) -> (^Provider_Tool_Fragment, Provider_Stream_Error) {
	arguments, arguments_error := make([dynamic]u8, 0, state.Allocator)
	if arguments_error != nil {
		return nil, provider_stream_fail_allocation(state, "the tool call could not be stored")
	}
	fragment := Provider_Tool_Fragment {
		Arguments = arguments,
	}
	if _, append_error := append(&state.Tool_Fragments, fragment); append_error != nil {
		delete(arguments)
		return nil, provider_stream_fail_allocation(state, "the tool call could not be stored")
	}
	return &state.Tool_Fragments[len(state.Tool_Fragments) - 1], .None
}

@(require_results)
provider_tool_fragment_by_wire_index :: proc(state: ^Provider_Stream_State, index: i64) -> (^Provider_Tool_Fragment, Provider_Stream_Error) {
	if index < 0 { return nil, provider_stream_fail(state, .Invalid_Data, "tool call index is invalid", .Tool_Limit) }
	for &fragment in state.Tool_Fragments {
		if fragment.Wire_Index_Present && fragment.Wire_Index == index { return &fragment, .None }
	}
	fragment, fragment_error := provider_tool_fragment_append(state)
	if fragment_error != .None { return nil, fragment_error }
	fragment.Wire_Index = index
	fragment.Wire_Index_Present = true
	return fragment, .None
}

// provider_call_clone_strings fills one call from the strings it is made of. It reports
// false, releasing whatever it copied, when the call could not be retained.
@(require_results)
provider_call_clone_strings :: proc(call: ^Provider_Tool_Call, id, item_id, name, arguments: string, allocator: mem.Allocator) -> bool {
	transferred := false
	defer if !transferred { provider_tool_call_destroy(call, allocator) }
	owned_id, id_error := strings.clone(id, allocator)
	if id_error != nil { return false }
	call.ID = owned_id
	owned_item_id, item_id_error := strings.clone(item_id, allocator)
	if item_id_error != nil { return false }
	call.Item_ID = owned_item_id
	owned_name, name_error := strings.clone(name, allocator)
	if name_error != nil { return false }
	call.Name = owned_name
	owned_arguments, arguments_error := strings.clone(arguments, allocator)
	if arguments_error != nil { return false }
	call.Arguments = owned_arguments
	transferred = true
	return true
}

// provider_call_clone copies one fragment's strings into the call it becomes. It reports
// false, releasing whatever it already copied, when the call could not be retained.
@(require_results)
provider_call_clone :: proc(fragment: ^Provider_Tool_Fragment, allocator: mem.Allocator) -> (call: Provider_Tool_Call, ok: bool) {
	ok = provider_call_clone_strings(&call, fragment.ID, fragment.Item_ID, fragment.Name, string(fragment.Arguments[:]), allocator)
	return call, ok
}

// provider_tool_finalize assembles the calls the stream decoded. It fails the stream when
// the decoded calls are not a usable set or could not be retained, so a caller never holds
// half a call list.
@(require_results)
provider_tool_finalize :: proc(state: ^Provider_Stream_State, allocator := context.allocator) -> ([]Provider_Tool_Call, Provider_Stream_Error) {
	count := 0
	for &fragment in state.Tool_Fragments {
		if !fragment.Present { continue }
		count += 1
		if fragment.ID == "" || fragment.Name == "" {
			return nil, provider_stream_fail(state, .Invalid_Data, "tool calls are invalid")
		}
		for &other in state.Tool_Fragments {
			if &other == &fragment || !other.Present { continue }
			if other.ID != "" && other.ID == fragment.ID {
				return nil, provider_stream_fail(state, .Invalid_Data, "tool calls are invalid")
			}
		}
	}
	if count == 0 { return nil, provider_stream_fail(state, .Invalid_Data, "tool calls are invalid") }
	calls, make_error := make([]Provider_Tool_Call, count, allocator)
	if make_error != nil {
		return nil, provider_stream_fail_allocation(state, "the tool calls could not be retained")
	}
	filled := 0
	for &fragment in state.Tool_Fragments {
		if !fragment.Present { continue }
		call, call_ok := provider_call_clone(&fragment, allocator)
		if !call_ok {
			for i in 0 ..< filled { provider_tool_call_destroy(&calls[i], allocator) }
			delete(calls, allocator)
			return nil, provider_stream_fail_allocation(state, "the tool calls could not be retained")
		}
		calls[filled] = call
		filled += 1
	}
	return calls, .None
}
Provider_Stream_Error :: enum {
	None,
	Invalid_State,
	Unsupported_API,
	Invalid_JSON,
	Malformed_Event,
	Stream_Truncated,
	Tool_Limit,
	Batch_Not_Drained,
	// Allocation means the stream could not retain what it decoded.
	Allocation,
}

@(require_results)
Provider_Encode_Request :: proc(request: Provider_Request, allocator := context.allocator) -> (string, Provider_Request_Error) {
	return Provider_Encode_Request_Reusing(request, nil, allocator)
}

// Provider_Encode_Request_Reusing encodes a request, reusing what cache already holds for
// the texts this request carries again. A nil cache encodes every byte now.
//
// Reuse never changes what is sent: bytes are written from the cache only for the text
// they were written for.
@(require_results)
Provider_Encode_Request_Reusing :: proc(
	request: Provider_Request,
	cache: ^Provider_Encode_Cache,
	allocator := context.allocator,
) -> (
	string,
	Provider_Request_Error,
) {
	switch request.API {
	case .OpenAI_Chat_Completions:
		return openai_chat_encode_request(request, cache, allocator)
	case .OpenAI_Responses:
		return openai_responses_encode_request(request, cache, allocator)
	case .Anthropic_Messages:
		return anthropic_encode_request(request, cache, allocator)
	case .Invalid:
	}
	return "", .Unsupported_API
}

@(require_results)
Provider_Consume_Event_JSON :: proc(payload: string, state: ^Provider_Stream_State) -> Provider_Stream_Error {
	if state == nil { return .Invalid_State }
	if len(state^.Batch) > 0 { return .Batch_Not_Drained }
	if state^.API != .OpenAI_Responses {
		state^.Phase = .Failed
		return provider_stream_fail(state, .Invalid_Data, "API family has no JSON event transport", .Unsupported_API)
	}
	return openai_responses_consume_event(payload, state)
}

@(require_results)
Provider_Consume_SSE_Data :: proc(payload: string, state: ^Provider_Stream_State) -> Provider_Stream_Error {
	if state == nil { return .Invalid_State }
	if len(state^.Batch) > 0 { return .Batch_Not_Drained }
	switch state^.API {
	case .OpenAI_Chat_Completions:
		return openai_chat_consume_sse_data(payload, state)
	case .OpenAI_Responses:
		return openai_responses_consume_sse_data(payload, state)
	case .Anthropic_Messages:
		return anthropic_consume_sse_data(payload, state)
	case .Invalid:
	}
	state^.Phase = .Failed
	return provider_stream_fail(state, .Invalid_Data, "unsupported API family", .Unsupported_API)
}

// EOF is authoritative when a terminal event was already decoded. Some proxies
// close the stream without the `[DONE]` sentinel, and the Responses API never
// sends one. A still-open stream is truncation, not success.
@(require_results)
Provider_Stream_Finish :: proc(state: ^Provider_Stream_State) -> Provider_Stream_Error {
	if state == nil { return .Invalid_State }
	switch state^.Phase {
	case .Completed:
		state^.Phase = .Done
		return .None
	case .Done:
		return .None
	case .Open:
		return provider_stream_fail(state, .Stream_Truncated, "stream ended before completion", .Stream_Truncated)
	case .Failed:
		return .None
	}
	return .Invalid_State
}
