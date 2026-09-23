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
		}; if message.Role == .Invalid { return .Invalid_Message }
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
	Kind:          Provider_Error_Kind,
	Message:       string,
	Provider_Code: string,
} // strings owned by receiver
Provider_Event :: union {
	Provider_Text_Event,
	Provider_Reasoning_Event,
	Provider_Usage_Event,
	Provider_Completed_Event,
	Provider_Error_Event,
}

// Provider_Tool_Calls_Destroy releases a call list and every string it owns. It is the one
// release path for calls a provider fact carries, so a new holder of one cannot free half
// of a call or leak the rest.
Provider_Tool_Calls_Destroy :: proc(calls: []Provider_Tool_Call, allocator := context.allocator) {
	for call in calls {
		if call.ID != "" { delete(call.ID, allocator) }
		if call.Item_ID != "" { delete(call.Item_ID, allocator) }
		if call.Name != "" { delete(call.Name, allocator) }
		if call.Arguments != "" { delete(call.Arguments, allocator) }
	}
	if calls != nil { delete(calls, allocator) }
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
	}
	event^ = nil
}

Provider_Stream_Phase :: enum {
	Open,
	Completed,
	Done,
	Failed,
}

// One payload can carry text, usage, and completion together. Three slots are
// enough for the current event set; tool calls stay inside completion.
PROVIDER_STREAM_BATCH_SLOTS :: 3
Provider_Stream_State :: struct {
	API:            API_Kind,
	Phase:          Provider_Stream_Phase,
	Tool_Fragments: [dynamic]Provider_Tool_Fragment, // owned assembly slots,
	Allocator:      mem.Allocator,
	// Operation-owned staging for one decoded payload. Drained before the
	// next payload is consumed; undrained events are destroyed with the
	// stream.
	Batch:          [PROVIDER_STREAM_BATCH_SLOTS]Provider_Event,
	Batch_Count:    int,
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

PROVIDER_MAX_TOOL_ARGS_BYTES :: 64 * 1024

Provider_Stream_Start :: proc(api: API_Kind, allocator := context.allocator) -> Provider_Stream_State {
	return {API = api, Phase = .Open, Allocator = allocator}
}

provider_stream_batch_clear :: proc(state: ^Provider_Stream_State) {
	for i in 0 ..< state.Batch_Count { Provider_Event_Destroy(&state.Batch[i], state.Allocator) }
	state.Batch_Count = 0
	for i in 0 ..< PROVIDER_STREAM_BATCH_SLOTS { state.Batch[i] = nil }
}

provider_stream_push :: proc(state: ^Provider_Stream_State, event: Provider_Event) {
	assert(state.Batch_Count < PROVIDER_STREAM_BATCH_SLOTS, "provider event batch overflow")
	if state.Batch_Count >= PROVIDER_STREAM_BATCH_SLOTS {
		owned := event
		Provider_Event_Destroy(&owned, state.Allocator)
		return
	}
	state.Batch[state.Batch_Count] = event
	state.Batch_Count += 1
}

// Discard staged success events and expose one error. A malformed payload
// never leaves a partial batch behind.
provider_stream_fail :: proc(
	state: ^Provider_Stream_State,
	kind: Provider_Error_Kind,
	message: string,
	stream_err := Provider_Stream_Error.Malformed_Event,
	code := "",
) -> Provider_Stream_Error {
	provider_stream_batch_clear(state)
	provider_stream_push(state, openai_error_event(kind, message, code, state.Allocator))
	state.Phase = .Failed
	return stream_err
}

// Transfers one owned event to the caller and clears its slot.
Provider_Stream_Drain :: proc(state: ^Provider_Stream_State) -> (Provider_Event, bool) {
	if state == nil || state.Batch_Count <= 0 { return nil, false }
	event := state.Batch[0]
	for i in 0 ..< state.Batch_Count - 1 { state.Batch[i] = state.Batch[i + 1] }
	state.Batch_Count -= 1
	state.Batch[state.Batch_Count] = nil
	return event, true
}

Provider_Stream_Destroy :: proc(state: ^Provider_Stream_State) {
	if state == nil { return }
	provider_stream_batch_clear(state)
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

provider_tool_fragment_append :: proc(state: ^Provider_Stream_State) -> ^Provider_Tool_Fragment {
	fragment := Provider_Tool_Fragment {
		Arguments = make([dynamic]u8, 0, state.Allocator),
	}
	append(&state.Tool_Fragments, fragment)
	return &state.Tool_Fragments[len(state.Tool_Fragments) - 1]
}

provider_tool_fragment_by_wire_index :: proc(state: ^Provider_Stream_State, index: i64) -> (^Provider_Tool_Fragment, bool) {
	if index < 0 { return nil, false }
	for &fragment in state.Tool_Fragments {
		if fragment.Wire_Index_Present && fragment.Wire_Index == index { return &fragment, true }
	}
	fragment := provider_tool_fragment_append(state)
	fragment.Wire_Index = index
	fragment.Wire_Index_Present = true
	return fragment, true
}

provider_tool_finalize :: proc(state: ^Provider_Stream_State, allocator := context.allocator) -> ([]Provider_Tool_Call, bool) {
	count := 0
	for &fragment in state.Tool_Fragments {
		if !fragment.Present { continue }
		count += 1
		if fragment.ID == "" || fragment.Name == "" { return nil, false }
		if len(fragment.Arguments) > PROVIDER_MAX_TOOL_ARGS_BYTES { return nil, false }
		for &other in state.Tool_Fragments {
			if &other == &fragment || !other.Present { continue }
			if other.ID != "" && other.ID == fragment.ID { return nil, false }
		}
	}
	if count == 0 { return nil, false }
	calls := make([]Provider_Tool_Call, count, allocator)
	i := 0
	for &fragment in state.Tool_Fragments {
		if !fragment.Present { continue }
		calls[i] = Provider_Tool_Call {
			ID        = strings.clone(fragment.ID, allocator),
			Item_ID   = strings.clone(fragment.Item_ID, allocator),
			Name      = strings.clone(fragment.Name, allocator),
			Arguments = strings.clone(string(fragment.Arguments[:]), allocator),
		}
		i += 1
	}
	return calls, true
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
}

Provider_Encode_Request :: proc(request: Provider_Request, allocator := context.allocator) -> (string, Provider_Request_Error) {
	return Provider_Encode_Request_Reusing(request, nil, allocator)
}

// Provider_Encode_Request_Reusing encodes a request, reusing what cache already holds for
// the texts this request carries again. A nil cache encodes every byte now.
//
// Reuse never changes what is sent: bytes are written from the cache only for the text
// they were written for.
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

Provider_Consume_Event_JSON :: proc(payload: string, state: ^Provider_Stream_State) -> Provider_Stream_Error {
	if state == nil { return .Invalid_State }
	if state^.Batch_Count > 0 { return .Batch_Not_Drained }
	if state^.API != .OpenAI_Responses {
		state^.Phase = .Failed
		return provider_stream_fail(state, .Invalid_Data, "API family has no JSON event transport", .Unsupported_API)
	}
	return openai_responses_consume_event(payload, state)
}

Provider_Consume_SSE_Data :: proc(payload: string, state: ^Provider_Stream_State) -> Provider_Stream_Error {
	if state == nil { return .Invalid_State }
	if state^.Batch_Count > 0 { return .Batch_Not_Drained }
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
