package acp

import "core:encoding/json"

// Protocol facts for the Agent Client Protocol.
//
// The agent side is what this package describes: the methods a client calls, the
// notifications an agent sends, and the payload shapes of both. The envelope and the
// framing are in protocol.odin and framing.odin; the outbound side is writer.odin.
// Nothing here knows about Nabla: a session id is opaque, a prompt is content blocks,
// and an update is a JSON document.

// PROTOCOL_VERSION is the version this package speaks. A client that asks for a
// newer version receives the latest one implemented here.
PROTOCOL_VERSION :: 1
PROTOCOL_VERSION_V2 :: 2

// Methods a client calls.
METHOD_INITIALIZE :: "initialize"
METHOD_AUTHENTICATE :: "authenticate"
METHOD_SESSION_NEW :: "session/new"
METHOD_SESSION_LOAD :: "session/load"
METHOD_SESSION_RESUME :: "session/resume"
METHOD_SESSION_LIST :: "session/list"
METHOD_SESSION_CLOSE :: "session/close"
METHOD_SESSION_SET_CONFIG_OPTION :: "session/set_config_option"
METHOD_AUTH_LOGIN :: "auth/login"
METHOD_AUTH_LOGOUT :: "auth/logout"
METHOD_SESSION_PROMPT :: "session/prompt"
// An agent calls this on its client: one tool call needs the user's answer before it runs.
METHOD_SESSION_REQUEST_PERMISSION :: "session/request_permission"

// Buzz's model selector uses this pre-standard ACP method when an agent advertises
// its model catalog. It is harmless for other ACP clients to ignore.
METHOD_SESSION_SET_MODEL :: "session/set_model"

// Notifications. A session update is the agent's only streaming channel: everything a
// turn produces arrives as one of the update kinds below. Cancellation travels on the
// same name in both directions: ACP defines it as a notification, but a few clients
// send it as a request, and accepting that shape keeps cancellation draining.
SESSION_CANCEL :: "session/cancel"
NOTIFICATION_SESSION_UPDATE :: "session/update"

// JSON-RPC error codes: the specification's four, then the code ACP defines.
ERROR_PARSE :: -32700
ERROR_INVALID_REQUEST :: -32600
ERROR_METHOD_NOT_FOUND :: -32601
ERROR_INVALID_PARAMS :: -32602
ERROR_INTERNAL :: -32603

// Session update kinds, as they appear in the `sessionUpdate` field.
UPDATE_USER_MESSAGE_CHUNK :: "user_message_chunk"
UPDATE_AGENT_MESSAGE_CHUNK :: "agent_message_chunk"
UPDATE_USER_MESSAGE :: "user_message"
UPDATE_AGENT_MESSAGE :: "agent_message"
UPDATE_AGENT_THOUGHT :: "agent_thought"
UPDATE_STATE :: "state_update"
UPDATE_TOOL_CALL :: "tool_call"
UPDATE_TOOL_CALL_UPDATE :: "tool_call_update"
UPDATE_TOOL_CALL_CONTENT_CHUNK :: "tool_call_content_chunk"
UPDATE_SESSION_INFO :: "session_info_update"
UPDATE_USAGE :: "usage_update"

// Content block kinds, as they appear in the `type` field.
CONTENT_TEXT :: "text"
CONTENT_IMAGE :: "image"
CONTENT_AUDIO :: "audio"
CONTENT_RESOURCE_LINK :: "resource_link"
CONTENT_RESOURCE :: "resource"

// Stop_Reason is why a turn ended. A client shows it and decides whether to continue;
// Cancelled is not a failure, it is the answer to the client's own cancellation.
Stop_Reason :: enum {
	End_Turn,
	Max_Tokens,
	Max_Turn_Requests,
	Refusal,
	Cancelled,
}

stop_reason_name :: proc(reason: Stop_Reason) -> string {
	switch reason {
	case .End_Turn:
		return "end_turn"
	case .Max_Tokens:
		return "max_tokens"
	case .Max_Turn_Requests:
		return "max_turn_requests"
	case .Refusal:
		return "refusal"
	case .Cancelled:
		return "cancelled"
	}
	return "end_turn"
}

// Tool_Kind classifies a tool call for display. Other is both the zero value and the
// honest answer for a tool the agent never classified.
Tool_Kind :: enum {
	Read,
	Edit,
	Delete,
	Move,
	Search,
	Execute,
	Think,
	Fetch,
	Switch_Mode,
	Other,
}

tool_kind_name :: proc(kind: Tool_Kind) -> string {
	switch kind {
	case .Read:
		return "read"
	case .Edit:
		return "edit"
	case .Delete:
		return "delete"
	case .Move:
		return "move"
	case .Search:
		return "search"
	case .Execute:
		return "execute"
	case .Think:
		return "think"
	case .Fetch:
		return "fetch"
	case .Switch_Mode:
		return "switch_mode"
	case .Other:
		return "other"
	}
	return "other"
}

// Tool_Status is where a call is in its life. Pending is a call the agent has
// announced, In_Progress is one an executor owns, and the last three are terminal.
// Cancelled is v2 only: v1 has no cancelled state, so a cancelled call reads as failed
// there.
Tool_Status :: enum {
	Pending,
	In_Progress,
	Completed,
	Failed,
	Cancelled,
}

tool_status_name :: proc(status: Tool_Status) -> string {
	switch status {
	case .Pending:
		return "pending"
	case .In_Progress:
		return "in_progress"
	case .Completed:
		return "completed"
	case .Failed:
		return "failed"
	case .Cancelled:
		return "cancelled"
	}
	return "pending"
}

// --- what a client sends -----------------------------------------------------

// Implementation names one side of the connection. A client sends its own in
// initialize; an agent answers with this one.
Implementation :: struct {
	name:    string `json:"name"`,
	title:   string `json:"title,omitempty"`,
	version: string `json:"version"`,
}

Fs_Capabilities :: struct {
	read_text_file:  bool `json:"readTextFile"`,
	write_text_file: bool `json:"writeTextFile"`,
}

Client_Capabilities :: struct {
	fs:       Fs_Capabilities `json:"fs"`,
	terminal: bool `json:"terminal"`,
}

Initialize_Params :: struct {
	protocol_version:    int `json:"protocolVersion"`,
	client_capabilities: Client_Capabilities `json:"clientCapabilities"`,
	client_info:         Implementation `json:"clientInfo"`,
	capabilities:        V2_Client_Capabilities `json:"capabilities"`,
	info:                Implementation `json:"info"`,
}

// V2_Client_Capabilities is deliberately limited to the v2 fields Nabla needs to
// recognize. Unknown client capabilities remain forward-compatible and are ignored.
V2_Client_Capabilities :: struct {
	auth: V2_Client_Auth_Capabilities `json:"auth"`,
}

V2_Client_Auth_Capabilities :: struct {
	terminal: bool `json:"terminal"`,
}

V2_Support :: struct {}

V1_Session_List_Capabilities :: struct {
	list: V2_Support `json:"list"`,
}

V2_Prompt_Capabilities :: struct {
	image:            Maybe(V2_Support) `json:"image,omitempty"`,
	embedded_context: V2_Support `json:"embeddedContext"`,
}

V2_Mcp_Capabilities :: struct {
	stdio: V2_Support `json:"stdio"`,
}

V2_Session_Capabilities :: struct {
	prompt: V2_Prompt_Capabilities `json:"prompt"`,
	mcp:    V2_Mcp_Capabilities `json:"mcp"`,
}

V2_Agent_Capabilities :: struct {
	session: V2_Session_Capabilities `json:"session"`,
}

V2_Initialize_Result :: struct {
	protocol_version: int `json:"protocolVersion"`,
	info:             Implementation `json:"info"`,
	capabilities:     V2_Agent_Capabilities `json:"capabilities"`,
	auth_methods:     []json.Value `json:"authMethods"`,
}

MCP_Environment :: struct {
	name:  string `json:"name"`,
	value: string `json:"value"`,
}

// MCP_Server is the stdio MCP server configuration carried by ACP. The optional
// type is accepted for v1 clients and is required by v2 clients, but only stdio is
// implemented by this agent.
MCP_Server :: struct {
	name:    string `json:"name"`,
	type:    string `json:"type,omitempty"`,
	command: string `json:"command"`,
	args:    []string `json:"args"`,
	env:     []MCP_Environment `json:"env"`,
}

Session_Meta :: struct {
	session_title: string `json:"sessionTitle"`,
	system_prompt: json.Value `json:"systemPrompt"`,
}

Session_New_Params :: struct {
	cwd:                    string `json:"cwd"`,
	additional_directories: []string `json:"additionalDirectories"`,
	mcp_servers:            []MCP_Server `json:"mcpServers"`,
	system_prompt:          string `json:"systemPrompt"`,
	meta:                   Session_Meta `json:"_meta"`,
}

Session_Load_Params :: struct {
	session_id:    string `json:"sessionId"`,
	cwd:           string `json:"cwd"`,
	mcp_servers:   []MCP_Server `json:"mcpServers"`,
	system_prompt: string `json:"systemPrompt"`,
	meta:          Session_Meta `json:"_meta"`,
}

Replay_From :: struct {
	type: string `json:"type"`,
}

Session_Resume_Params :: struct {
	session_id:             string `json:"sessionId"`,
	cwd:                    string `json:"cwd"`,
	mcp_servers:            []MCP_Server `json:"mcpServers"`,
	additional_directories: []string `json:"additionalDirectories"`,
	system_prompt:          string `json:"systemPrompt"`,
	meta:                   Session_Meta `json:"_meta"`,
	replay_from:            Maybe(Replay_From) `json:"replayFrom"`,
}

Session_List_Params :: struct {
	cursor: string `json:"cursor"`,
	cwd:    string `json:"cwd"`,
}

Session_Close_Params :: struct {
	session_id: string `json:"sessionId"`,
}

// Embedded_Resource is a resource the client inlined into the prompt. Text travels with
// the message; a binary resource keeps its base64 text in blob, borrowed from the decoded JSON value, and blob_present reports whether the field was there at
// all.
Embedded_Resource :: struct {
	uri:          string `json:"uri"`,
	text:         string `json:"text"`,
	mime_type:    string `json:"mimeType,omitempty"`,
	blob:         string `json:"-"`,
	blob_present: bool `json:"-"`,
}

// Content_Block is one element of a prompt. The union is by `type`, and every kind's
// fields live side by side rather than in a tagged union, because the JSON decoder fills
// the shape the document has and a block carries whichever fields its type names. An image block keeps its base64 text in data, borrowed from the decoded JSON
// value.
Content_Block :: struct {
	type:      string `json:"type"`,
	text:      string `json:"text"`,
	uri:       string `json:"uri"`,
	data:      string `json:"data,omitempty"`,
	mime_type: string `json:"mimeType,omitempty"`,
	resource:  Embedded_Resource `json:"resource"`,
}

Session_Prompt_Params :: struct {
	session_id: string `json:"sessionId"`,
	prompt:     []Content_Block `json:"prompt"`,
}

// session_prompt_params_decode reads the prompt's needed fields from its JSON value.
// Its strings borrow from value and its block slice is owned by allocator, so value
// must outlive the returned params, including the base64 text of images and blobs.
// It returns Invalid for a mismatched shape and Allocation when the block slice cannot
// be allocated.
@(require_results)
session_prompt_params_decode :: proc(value: json.Value, target: ^Session_Prompt_Params, allocator := context.allocator) -> Params_Error {
	object, is_object := value.(json.Object)
	if !is_object { return .Invalid }

	session_id_value, session_id_present := object["sessionId"]
	session_id, is_string := session_id_value.(json.String)
	if !session_id_present || !is_string { return .Invalid }
	prompt_value, prompt_present := object["prompt"]
	prompt, is_array := prompt_value.(json.Array)
	if !prompt_present || !is_array { return .Invalid }

	blocks, allocation_error := make([]Content_Block, len(prompt), allocator)
	if allocation_error != nil { return .Allocation }
	transferred := false
	defer if !transferred { delete(blocks, allocator) }
	for block_value, index in prompt {
		block_object, block_is_object := block_value.(json.Object)
		if !block_is_object { return .Invalid }
		type_value, type_present := block_object["type"]
		block_type, type_is_string := type_value.(json.String)
		if !type_present || !type_is_string { return .Invalid }
		block := Content_Block {
			type = string(block_type),
		}
		if text_value, present := block_object["text"]; present {
			text, text_is_string := text_value.(json.String)
			if !text_is_string { return .Invalid }
			block.text = string(text)
		}
		if uri_value, present := block_object["uri"]; present {
			uri, uri_is_string := uri_value.(json.String)
			if !uri_is_string { return .Invalid }
			block.uri = string(uri)
		}
		if data_value, present := block_object["data"]; present {
			data, data_is_string := data_value.(json.String)
			if !data_is_string { return .Invalid }
			block.data = string(data)
		}
		if mime_value, present := block_object["mimeType"]; present {
			mime, mime_is_string := mime_value.(json.String)
			if !mime_is_string { return .Invalid }
			block.mime_type = string(mime)
		}
		if resource_value, present := block_object["resource"]; present {
			resource_object, resource_is_object := resource_value.(json.Object)
			if !resource_is_object { return .Invalid }
			if uri_value, has_uri := resource_object["uri"]; has_uri {
				uri, uri_is_string := uri_value.(json.String)
				if !uri_is_string { return .Invalid }
				block.resource.uri = string(uri)
			}
			if text_value, has_text := resource_object["text"]; has_text {
				text, text_is_string := text_value.(json.String)
				if !text_is_string { return .Invalid }
				block.resource.text = string(text)
			}
			if mime_value, has_mime := resource_object["mimeType"]; has_mime {
				if mime, is_mime_string := mime_value.(json.String); is_mime_string {
					block.resource.mime_type = string(mime)
				} else if _, is_null := mime_value.(json.Null); !is_null {
					return .Invalid
				}
			}
			if blob_value, has_blob := resource_object["blob"]; has_blob {
				blob, is_blob_string := blob_value.(json.String)
				if !is_blob_string { return .Invalid }
				block.resource.blob = string(blob)
				block.resource.blob_present = true
			}
		}
		blocks[index] = block
	}

	target.session_id = string(session_id)
	target.prompt = blocks
	transferred = true
	return .None
}

Session_Cancel_Params :: struct {
	session_id: string `json:"sessionId"`,
}

// --- what an agent answers ---------------------------------------------------

Prompt_Capabilities :: struct {
	image:            bool `json:"image"`,
	audio:            bool `json:"audio"`,
	embedded_context: bool `json:"embeddedContext"`,
}

MCP_Capabilities :: struct {
	http: bool `json:"http"`,
	sse:  bool `json:"sse"`,
}

Agent_Capabilities :: struct {
	load_session:         bool `json:"loadSession"`,
	session_capabilities: V1_Session_List_Capabilities `json:"sessionCapabilities"`,
	prompt_capabilities:  Prompt_Capabilities `json:"promptCapabilities"`,
	mcp_capabilities:     MCP_Capabilities `json:"mcpCapabilities"`,
}

Initialize_Result :: struct {
	protocol_version:   int `json:"protocolVersion"`,
	agent_capabilities: Agent_Capabilities `json:"agentCapabilities"`,
	auth_methods:       []json.Value `json:"authMethods"`,
	agent_info:         Implementation `json:"agentInfo"`,
}

Session_New_Result :: struct {
	session_id:     string `json:"sessionId"`,
	config_options: []V1_Config_Option `json:"configOptions,omitempty"`,
	models:         Models_State `json:"models"`,
}

Model_Info :: struct {
	model_id: string `json:"modelId"`,
	name:     string `json:"name"`,
}

// Models_State is Buzz's pre-standard model catalog: the selected model and every
// model the client may switch to. It travels beside the stable config options.
Models_State :: struct {
	current_model_id: string `json:"currentModelId"`,
	available_models: []Model_Info `json:"availableModels"`,
}

// Config_Value is one choice of a model selector. v1 and v2 options share it; only
// the option wrapper differs between the two wire shapes.
Config_Value :: struct {
	value: string `json:"value"`,
	name:  string `json:"name"`,
}

V1_Config_Option :: struct {
	id:            string `json:"id"`,
	name:          string `json:"name"`,
	category:      string `json:"category"`,
	type:          string `json:"type"`,
	current_value: string `json:"currentValue"`,
	options:       []Config_Value `json:"options"`,
}

V2_Config_Option :: struct {
	config_id:     string `json:"configId"`,
	name:          string `json:"name"`,
	category:      string `json:"category"`,
	type:          string `json:"type"`,
	current_value: string `json:"currentValue"`,
	options:       []Config_Value `json:"options"`,
}

V2_Session_New_Result :: struct {
	session_id:     string `json:"sessionId"`,
	config_options: []V2_Config_Option `json:"configOptions"`,
}

// Empty_Result is the answer of a method that reports success by returning.
Empty_Result :: struct {}

Prompt_Result :: struct {
	stop_reason: string `json:"stopReason"`,
}

Session_Set_Model_Params :: struct {
	session_id: string `json:"sessionId"`,
	model_id:   string `json:"modelId"`,
}

Session_Set_Model_Result :: struct {
	session_id: string `json:"sessionId"`,
	model_id:   string `json:"modelId"`,
}

Session_Set_Config_Option_Params :: struct {
	session_id: string `json:"sessionId"`,
	config_id:  string `json:"configId"`,
	type:       string `json:"type"`,
	value:      string `json:"value"`,
}

V1_Session_Set_Config_Option_Result :: struct {
	config_options: []V1_Config_Option `json:"configOptions"`,
}

V2_Session_Set_Config_Option_Result :: struct {
	config_options: []V2_Config_Option `json:"configOptions"`,
}

Session_Resume_Result :: struct {
	config_options: []V2_Config_Option `json:"configOptions,omitempty"`,
}

Session_Info :: struct {
	session_id: string `json:"sessionId"`,
	cwd:        string `json:"cwd"`,
	title:      string `json:"title,omitempty"`,
	updated_at: string `json:"updatedAt,omitempty"`,
}

Session_List_Result :: struct {
	sessions:    []Session_Info `json:"sessions"`,
	next_cursor: string `json:"nextCursor,omitempty"`,
}

Prompt_Accepted_Result :: struct {
	message_id: string `json:"messageId"`,
}

Message_Update :: struct {
	session_update: string `json:"sessionUpdate"`,
	message_id:     string `json:"messageId"`,
	content:        []Text_Content `json:"content"`,
}

State_Update :: struct {
	session_update: string `json:"sessionUpdate"`,
	state:          string `json:"state"`,
	stop_reason:    string `json:"stopReason,omitempty"`,
}

Tool_Call_Update_V2 :: struct {
	session_update: string `json:"sessionUpdate"`,
	tool_call_id:   string `json:"toolCallId"`,
	name:           string `json:"name,omitempty"`,
	title:          string `json:"title,omitempty"`,
	kind:           string `json:"kind,omitempty"`,
	status:         string `json:"status,omitempty"`,
	raw_input:      json.Value `json:"rawInput,omitempty"`,
	content:        []Tool_Call_Content `json:"content,omitempty"`,
}

Tool_Call_Content_Chunk :: struct {
	session_update: string `json:"sessionUpdate"`,
	tool_call_id:   string `json:"toolCallId"`,
	content:        Tool_Call_Content `json:"content"`,
}

Session_Info_Update :: struct {
	session_update: string `json:"sessionUpdate"`,
	title:          string `json:"title,omitempty"`,
}

Text_Content :: struct {
	type: string `json:"type"`,
	text: string `json:"text"`,
}

// Session_Notification is the params of one session/update notification, carrying one
// update of kind T.
Session_Notification :: struct($T: typeid) {
	session_id: string `json:"sessionId"`,
	update:     T `json:"update"`,
}

// Message_Chunk is one streamed fragment of a message. Chunks that share a message_id
// belong to one message; the field is omitted when the sender keeps no identity.
Message_Chunk :: struct {
	session_update: string `json:"sessionUpdate"`,
	content:        Text_Content `json:"content"`,
	message_id:     string `json:"messageId,omitempty"`,
}

// Tool_Call is the first update about one tool call: what it is called, the state it is
// in, and whatever output it already has. raw_input is the arguments document exactly as
// the model sent it; a call replayed from the record carries its output here instead of
// in a later update.
Tool_Call :: struct {
	session_update: string `json:"sessionUpdate"`,
	tool_call_id:   string `json:"toolCallId"`,
	title:          string `json:"title"`,
	kind:           string `json:"kind"`,
	status:         string `json:"status"`,
	raw_input:      json.Value `json:"rawInput,omitempty"`,
	content:        []Tool_Call_Content `json:"content,omitempty"`,
}

// Tool_Call_Content is one item of a tool call's output. Only inlined text is used
// here: a diff or a terminal would be a claim about the client's own state.
Tool_Call_Content :: struct {
	type:    string `json:"type"`,
	content: Text_Content `json:"content"`,
}

TOOL_CALL_CONTENT_INLINE :: "content"

// Tool_Call_Update reports the terminal state of a call that was already announced, with
// whatever output the agent has for it.
Tool_Call_Update :: struct {
	session_update: string `json:"sessionUpdate"`,
	tool_call_id:   string `json:"toolCallId"`,
	status:         string `json:"status"`,
	content:        []Tool_Call_Content `json:"content,omitempty"`,
}

// Usage_Update reports how much of the model's context the session holds and how large
// that context is, in tokens. A client shows it beside the conversation.
Usage_Update :: struct {
	session_update: string `json:"sessionUpdate"`,
	used:           i64 `json:"used"`,
	size:           i64 `json:"size"`,
}

// --- the client role ---------------------------------------------------------

// Permission_Option is one answer an agent offers for a tool call. kind is one of
// allow_once, allow_always, reject_once, or reject_always.
Permission_Option :: struct {
	option_id: string `json:"optionId"`,
	name:      string `json:"name"`,
	kind:      string `json:"kind"`,
}

// Request_Permission_Params is what an agent sends with METHOD_SESSION_REQUEST_PERMISSION.
// toolCall is left undecoded; a client that shows the call decodes it separately.
Request_Permission_Params :: struct {
	session_id: string `json:"sessionId"`,
	options:    []Permission_Option `json:"options"`,
}

// Permission_Outcome is the client's answer. outcome is "selected" or "cancelled", and
// option_id is present only when it is "selected".
Permission_Outcome :: struct {
	outcome:   string `json:"outcome"`,
	option_id: string `json:"optionId,omitempty"`,
}

Request_Permission_Result :: struct {
	outcome: Permission_Outcome `json:"outcome"`,
}

// Update_Kind is the part of a session update that names its kind. A client decodes
// Session_Notification(Update_Kind) first to learn which update the document carries.
Update_Kind :: struct {
	session_update: string `json:"sessionUpdate"`,
}
