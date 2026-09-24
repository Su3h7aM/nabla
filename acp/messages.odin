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
// newer version receives this one.
PROTOCOL_VERSION :: 1

// Methods a client calls.
METHOD_INITIALIZE :: "initialize"
METHOD_AUTHENTICATE :: "authenticate"
METHOD_SESSION_NEW :: "session/new"
METHOD_SESSION_LOAD :: "session/load"
METHOD_SESSION_PROMPT :: "session/prompt"
METHOD_SESSION_SET_CONFIG_OPTION :: "session/set_config_option"
METHOD_AUTH_LOGIN :: "auth/login"
METHOD_AUTH_LOGOUT :: "auth/logout"

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
// announced, In_Progress is one an executor owns, and the last two are terminal.
Tool_Status :: enum {
	Pending,
	In_Progress,
	Completed,
	Failed,
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
}

Mcp_Environment :: struct {
	name:  string `json:"name"`,
	value: string `json:"value"`,
}

// Mcp_Server is the stdio MCP server configuration carried by ACP. The optional
// type accepts the stdio discriminator; only stdio is implemented by this agent.
Mcp_Server :: struct {
	name:    string `json:"name"`,
	type:    string `json:"type,omitempty"`,
	command: string `json:"command"`,
	args:    []string `json:"args"`,
	env:     []Mcp_Environment `json:"env"`,
}

Session_Meta :: struct {
	session_title: string `json:"sessionTitle"`,
	system_prompt: json.Value `json:"systemPrompt"`,
}

Session_New_Params :: struct {
	cwd:                    string `json:"cwd"`,
	additional_directories: []string `json:"additionalDirectories"`,
	mcp_servers:            []Mcp_Server `json:"mcpServers"`,
	system_prompt:          string `json:"systemPrompt"`,
	meta:                   Session_Meta `json:"_meta"`,
}

Session_Load_Params :: struct {
	session_id:    string `json:"sessionId"`,
	cwd:           string `json:"cwd"`,
	mcp_servers:   []Mcp_Server `json:"mcpServers"`,
	system_prompt: string `json:"systemPrompt"`,
	meta:          Session_Meta `json:"_meta"`,
}

// Embedded_Resource is a resource the client inlined into the prompt: the file's text
// travels with the message instead of a link the agent would have to follow.
Embedded_Resource :: struct {
	uri:  string `json:"uri"`,
	text: string `json:"text"`,
}

// Content_Block is one element of a prompt. The union is by `type`, and every kind's
// fields live side by side rather than in a tagged union, because the JSON decoder fills
// the shape the document has and a block carries whichever fields its type names.
Content_Block :: struct {
	type:     string `json:"type"`,
	text:     string `json:"text"`,
	uri:      string `json:"uri"`,
	resource: Embedded_Resource `json:"resource"`,
}

Session_Prompt_Params :: struct {
	session_id: string `json:"sessionId"`,
	prompt:     []Content_Block `json:"prompt"`,
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

Mcp_Capabilities :: struct {
	http: bool `json:"http"`,
	sse:  bool `json:"sse"`,
}

Agent_Capabilities :: struct {
	load_session:        bool `json:"loadSession"`,
	prompt_capabilities: Prompt_Capabilities `json:"promptCapabilities"`,
	mcp_capabilities:    Mcp_Capabilities `json:"mcpCapabilities"`,
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
}

// Config_Value is one choice of the model selector.
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

// Empty_Result is the answer of a method that reports success by returning.
Empty_Result :: struct {}

Prompt_Result :: struct {
	stop_reason: string `json:"stopReason"`,
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
