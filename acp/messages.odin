package acp

import "core:encoding/json"
import "core:mem"

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

// Methods an agent calls on its client. A session update is the agent's only
// streaming channel: everything a turn produces arrives as one of the update kinds
// below. Cancellation travels on the same name in both directions: ACP defines it as
// a notification, but a few clients send it as a request, and accepting that shape
// keeps cancellation draining.
METHOD_SESSION_CANCEL :: "session/cancel"
METHOD_SESSION_UPDATE :: "session/update"

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
UPDATE_AVAILABLE_COMMANDS :: "available_commands_update"

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
	Error,
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
	case .Error:
		return "error"
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

V1_Fs_Capabilities :: struct {
	read_text_file:  bool `json:"readTextFile"`,
	write_text_file: bool `json:"writeTextFile"`,
}

V1_Client_Capabilities :: struct {
	fs:       V1_Fs_Capabilities `json:"fs"`,
	terminal: bool `json:"terminal"`,
}

V1_Initialize_Params :: struct {
	protocol_version:    int `json:"protocolVersion"`,
	client_capabilities: Maybe(V1_Client_Capabilities) `json:"clientCapabilities,omitempty"`,
	client_info:         Maybe(Implementation) `json:"clientInfo,omitempty"`,
}

V2_Initialize_Params :: struct {
	protocol_version: int `json:"protocolVersion"`,
	capabilities:     V2_Client_Capabilities `json:"capabilities"`,
	info:             Implementation `json:"info"`,
}

// V2_Client_Capabilities is deliberately limited to the v2 fields Nabla needs to
// recognize. Unknown client capabilities remain forward-compatible and are ignored.
V2_Client_Capabilities :: struct {
	auth: Maybe(V2_Client_Auth_Capabilities) `json:"auth,omitempty"`,
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

Session_New_Params :: struct {
	cwd:                    string `json:"cwd"`,
	additional_directories: []string `json:"additionalDirectories,omitempty"`,
	mcp_servers:            []MCP_Server `json:"mcpServers"`,
	meta:                   json.Value `json:"_meta,omitempty"`,
}

Session_Load_Params :: struct {
	session_id:  string `json:"sessionId"`,
	cwd:         string `json:"cwd"`,
	mcp_servers: []MCP_Server `json:"mcpServers"`,
	meta:        json.Value `json:"_meta,omitempty"`,
}

Replay_From :: struct {
	type: string `json:"type"`,
}

Session_Resume_Params :: struct {
	session_id:             string `json:"sessionId"`,
	cwd:                    string `json:"cwd"`,
	mcp_servers:            []MCP_Server `json:"mcpServers"`,
	additional_directories: []string `json:"additionalDirectories,omitempty"`,
	meta:                   json.Value `json:"_meta,omitempty"`,
	replay_from:            Maybe(Replay_From) `json:"replayFrom,omitempty"`,
}

Session_List_Params :: struct {
	cursor: string `json:"cursor"`,
	cwd:    string `json:"cwd"`,
}

Session_Close_Params :: struct {
	session_id: string `json:"sessionId"`,
}

// Content_Block is one element of a prompt or message. `_meta` and `annotations` are shared by every
// kind and nil when absent; variant holds the fields of the kind the wire `type` names. An empty string
// stands for an absent optional string where the schema allows absence.
Content_Block :: struct {
	meta:        json.Value,
	annotations: json.Value,
	variant:     union {
		Content_Text,
		Content_Image,
		Content_Audio,
		Content_Resource_Link,
		Content_Resource,
		Content_Other,
	},
}

Content_Text :: struct {
	text: string,
}

// Content_Image and Content_Audio hold base64 text in data, borrowed from the decoded JSON value.
Content_Image :: struct {
	data:      string,
	mime_type: string,
	uri:       string,
}

Content_Audio :: struct {
	data:      string,
	mime_type: string,
}

// Content_Resource_Link has a size of Maybe because zero is a real size.
Content_Resource_Link :: struct {
	uri:         string,
	name:        string,
	mime_type:   string,
	title:       string,
	description: string,
	size:        Maybe(i64),
	icons:       []Icon,
}

// Icon is v2 only. An empty sizes means any size.
Icon :: struct {
	src:       string,
	mime_type: string,
	sizes:     []string,
	theme:     string,
}

Content_Resource :: struct {
	resource: Resource_Contents,
}

// Resource_Contents is a resource a client inlined. A binary resource keeps its base64 text in blob,
// borrowed from the decoded JSON value.
Resource_Contents :: struct {
	meta:      json.Value,
	uri:       string,
	mime_type: string,
	variant:   union {
		Resource_Text,
		Resource_Blob,
	},
}

Resource_Text :: struct {
	text: string,
}

Resource_Blob :: struct {
	blob: string,
}

// Content_Other is a kind this package does not know. raw is the whole block, so encoding it writes
// the payload back unchanged.
Content_Other :: struct {
	type: string,
	raw:  json.Value,
}

Session_Prompt_Params :: struct {
	session_id: string `json:"sessionId"`,
	prompt:     []Content_Block `json:"prompt"`,
}

// Session_Prompt_Request is Session_Prompt_Params in wire form, built by session_prompt_request.
Session_Prompt_Request :: struct {
	session_id: string `json:"sessionId"`,
	prompt:     []json.Value `json:"prompt"`,
}

// content_block_decode reads one block from its JSON value. Its strings, meta, annotations and raw
// payload borrow from value, so value must outlive the block; only a resource link's icons are
// allocated with allocator, and content_block_destroy releases them. It returns Invalid for a
// mismatched shape and Allocation when the icons cannot be allocated. An unknown `type` is not an
// error: it becomes Content_Other.
@(require_results)
content_block_decode :: proc(value: json.Value, allocator := context.allocator) -> (block: Content_Block, err: Params_Error) {
	object, is_object := value.(json.Object)
	if !is_object { return {}, .Invalid }
	ok := true
	kind := field_string(object, "type", true, &ok)
	if !ok { return {}, .Invalid }
	block.meta = field_value(object, "_meta")
	block.annotations = field_value(object, "annotations")
	switch kind {
	case CONTENT_TEXT:
		block.variant = Content_Text {
			text = field_string(object, "text", true, &ok),
		}
	case CONTENT_IMAGE:
		block.variant = Content_Image {
			data      = field_string(object, "data", true, &ok),
			mime_type = field_string(object, "mimeType", false, &ok),
			uri       = field_string(object, "uri", false, &ok),
		}
	case CONTENT_AUDIO:
		block.variant = Content_Audio {
			data      = field_string(object, "data", true, &ok),
			mime_type = field_string(object, "mimeType", false, &ok),
		}
	case CONTENT_RESOURCE_LINK:
		link := Content_Resource_Link {
			uri         = field_string(object, "uri", true, &ok),
			name        = field_string(object, "name", false, &ok),
			mime_type   = field_string(object, "mimeType", false, &ok),
			title       = field_string(object, "title", false, &ok),
			description = field_string(object, "description", false, &ok),
		}
		switch size in object["size"] {
		case json.Integer:
			link.size = size
		case json.Null, nil:
		case json.Float, json.Boolean, json.String, json.Array, json.Object:
			ok = false
		}
		if !ok { return {}, .Invalid }
		link.icons = content_icons_decode(object["icons"], allocator) or_return
		block.variant = link
	case CONTENT_RESOURCE:
		resource_object, resource_is_object := object["resource"].(json.Object)
		if !resource_is_object { return {}, .Invalid }
		contents := Resource_Contents {
			meta      = field_value(resource_object, "_meta"),
			uri       = field_string(resource_object, "uri", true, &ok),
			mime_type = field_string(resource_object, "mimeType", false, &ok),
		}
		if _, has_blob := resource_object["blob"]; has_blob {
			contents.variant = Resource_Blob {
				blob = field_string(resource_object, "blob", true, &ok),
			}
		} else {
			contents.variant = Resource_Text {
				text = field_string(resource_object, "text", true, &ok),
			}
		}
		block.variant = Content_Resource {
			resource = contents,
		}
	case:
		block.variant = Content_Other {
			type = kind,
			raw  = value,
		}
	}
	if !ok { return {}, .Invalid }
	return block, .None
}

// content_block_destroy releases what content_block_decode allocated with allocator.
content_block_destroy :: proc(block: Content_Block, allocator := context.allocator) {
	if link, is_link := block.variant.(Content_Resource_Link); is_link {
		content_icons_destroy(link.icons, allocator)
	}
}

// field_string reads a string field. A missing or null field is empty, and a field of another type
// clears ok; a required field that is missing or null clears ok too.
@(private)
field_string :: proc(object: json.Object, key: string, required: bool, ok: ^bool) -> string {
	#partial switch text in object[key] {
	case json.String:
		return string(text)
	case json.Null, nil:
		if required { ok^ = false }
	case:
		ok^ = false
	}
	return ""
}

@(private)
field_value :: proc(object: json.Object, key: string) -> json.Value {
	value := object[key]
	if _, is_null := value.(json.Null); is_null { return nil }
	return value
}

@(private)
content_icons_decode :: proc(value: json.Value, allocator: mem.Allocator) -> (icons: []Icon, err: Params_Error) {
	if _, is_null := value.(json.Null); is_null || value == nil { return nil, .None }
	items, is_array := value.(json.Array)
	if !is_array { return nil, .Invalid }
	made, make_error := make([]Icon, len(items), allocator)
	if make_error != nil { return nil, .Allocation }
	defer if err != .None { content_icons_destroy(made, allocator) }
	for item, index in items {
		object, is_object := item.(json.Object)
		if !is_object { return nil, .Invalid }
		ok := true
		made[index] = Icon {
			src       = field_string(object, "src", true, &ok),
			mime_type = field_string(object, "mimeType", false, &ok),
			theme     = field_string(object, "theme", false, &ok),
		}
		if !ok { return nil, .Invalid }
		sizes_value, has_sizes := object["sizes"]
		if !has_sizes { continue }
		if _, is_null := sizes_value.(json.Null); is_null { continue }
		sizes_array, sizes_is_array := sizes_value.(json.Array)
		if !sizes_is_array { return nil, .Invalid }
		sizes, sizes_error := make([]string, len(sizes_array), allocator)
		if sizes_error != nil { return nil, .Allocation }
		made[index].sizes = sizes
		for size_value, size_index in sizes_array {
			size, is_string := size_value.(json.String)
			if !is_string { return nil, .Invalid }
			sizes[size_index] = string(size)
		}
	}
	return made, .None
}

@(private)
content_icons_destroy :: proc(icons: []Icon, allocator: mem.Allocator) {
	for icon in icons { delete(icon.sizes, allocator) }
	delete(icons, allocator)
}

// content_block_encode builds the wire object of a block, with the `type` key added. The result
// borrows every string, meta, annotations and raw payload from block and owns only its objects and
// arrays, which it allocates with allocator; it is not releasable with json.destroy_value, so pass
// context.temp_allocator or an arena and free everything at once. A block with no variant encodes
// as null. It returns the allocator's error when an object cannot be allocated, leaving what was
// allocated to the allocator.
@(require_results)
content_block_encode :: proc(block: Content_Block, allocator := context.allocator) -> (value: json.Value, err: mem.Allocator_Error) {
	if other, is_other := block.variant.(Content_Other); is_other { return other.raw, nil }
	if block.variant == nil { return json.Null{}, nil }
	object := make(json.Object, 8, allocator) or_return
	if block.meta != nil { field_put(&object, "_meta", block.meta) or_return }
	if block.annotations != nil { field_put(&object, "annotations", block.annotations) or_return }
	switch kind in block.variant {
	case Content_Text:
		field_put(&object, "type", CONTENT_TEXT) or_return
		field_put(&object, "text", kind.text) or_return
	case Content_Image:
		field_put(&object, "type", CONTENT_IMAGE) or_return
		field_put(&object, "data", kind.data) or_return
		field_put(&object, "mimeType", kind.mime_type) or_return
		field_put_text(&object, "uri", kind.uri) or_return
	case Content_Audio:
		field_put(&object, "type", CONTENT_AUDIO) or_return
		field_put(&object, "data", kind.data) or_return
		field_put(&object, "mimeType", kind.mime_type) or_return
	case Content_Resource_Link:
		field_put(&object, "type", CONTENT_RESOURCE_LINK) or_return
		field_put(&object, "uri", kind.uri) or_return
		field_put(&object, "name", kind.name) or_return
		field_put_text(&object, "mimeType", kind.mime_type) or_return
		field_put_text(&object, "title", kind.title) or_return
		field_put_text(&object, "description", kind.description) or_return
		if size, has_size := kind.size.?; has_size { field_put(&object, "size", json.Integer(size)) or_return }
		if len(kind.icons) > 0 {
			icons := make(json.Array, 0, len(kind.icons), allocator) or_return
			for icon in kind.icons {
				icon_object := make(json.Object, 4, allocator) or_return
				field_put(&icon_object, "src", icon.src) or_return
				field_put_text(&icon_object, "mimeType", icon.mime_type) or_return
				field_put_text(&icon_object, "theme", icon.theme) or_return
				if len(icon.sizes) > 0 {
					sizes := make(json.Array, 0, len(icon.sizes), allocator) or_return
					for size in icon.sizes { _ = append(&sizes, json.String(size)) or_return }
					field_put(&icon_object, "sizes", sizes) or_return
				}
				_ = append(&icons, icon_object) or_return
			}
			field_put(&object, "icons", icons) or_return
		}
	case Content_Resource:
		field_put(&object, "type", CONTENT_RESOURCE) or_return
		contents := make(json.Object, 4, allocator) or_return
		if kind.resource.meta != nil { field_put(&contents, "_meta", kind.resource.meta) or_return }
		field_put(&contents, "uri", kind.resource.uri) or_return
		field_put_text(&contents, "mimeType", kind.resource.mime_type) or_return
		switch resource in kind.resource.variant {
		case Resource_Text:
			field_put(&contents, "text", resource.text) or_return
		case Resource_Blob:
			field_put(&contents, "blob", resource.blob) or_return
		}
		field_put(&object, "resource", contents) or_return
	case Content_Other:
	}
	return object, nil
}

@(private)
field_put :: proc(object: ^json.Object, key: string, value: json.Value) -> mem.Allocator_Error {
	if map_insert(object, key, value) == nil { return .Out_Of_Memory }
	return nil
}

@(private)
field_put_text :: proc(object: ^json.Object, key: string, text: string) -> mem.Allocator_Error {
	if text == "" { return nil }
	return field_put(object, key, json.String(text))
}

// session_prompt_request builds the wire form of params for the client role, since json.marshal
// cannot write a Content_Block. Its blocks follow content_block_encode: pass context.temp_allocator
// or an arena. It returns the allocator's error when the blocks cannot be allocated.
@(require_results)
session_prompt_request :: proc(params: Session_Prompt_Params, allocator := context.allocator) -> (request: Session_Prompt_Request, err: mem.Allocator_Error) {
	prompt := make([]json.Value, len(params.prompt), allocator) or_return
	for block, index in params.prompt {
		prompt[index] = content_block_encode(block, allocator) or_return
	}
	return {session_id = params.session_id, prompt = prompt}, nil
}

// session_prompt_params_decode reads the prompt's needed fields from its JSON value.
// Its strings borrow from value and its block slice is owned by allocator, so value
// must outlive the returned params, including the base64 text of images and blobs.
// Release the blocks with content_block_destroy and then delete the slice.
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
	decoded := 0
	transferred := false
	defer if !transferred {
		for block in blocks[:decoded] { content_block_destroy(block, allocator) }
		delete(blocks, allocator)
	}
	for block_value, index in prompt {
		blocks[index] = content_block_decode(block_value, allocator) or_return
		decoded += 1
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

V1_Prompt_Capabilities :: struct {
	image:            bool `json:"image"`,
	audio:            bool `json:"audio"`,
	embedded_context: bool `json:"embeddedContext"`,
}

V1_MCP_Capabilities :: struct {
	http: bool `json:"http"`,
	sse:  bool `json:"sse"`,
}

V1_Agent_Capabilities :: struct {
	load_session:         bool `json:"loadSession"`,
	session_capabilities: V1_Session_List_Capabilities `json:"sessionCapabilities"`,
	prompt_capabilities:  V1_Prompt_Capabilities `json:"promptCapabilities"`,
	mcp_capabilities:     V1_MCP_Capabilities `json:"mcpCapabilities"`,
}

V1_Initialize_Result :: struct {
	protocol_version:   int `json:"protocolVersion"`,
	agent_capabilities: V1_Agent_Capabilities `json:"agentCapabilities"`,
	auth_methods:       []json.Value `json:"authMethods"`,
	agent_info:         Implementation `json:"agentInfo"`,
}

Session_New_Result :: struct {
	session_id:     string `json:"sessionId"`,
	config_options: []json.Value `json:"configOptions,omitempty"`,
}

CONFIG_TYPE_SELECT :: "select"
CONFIG_TYPE_BOOLEAN :: "boolean"

// Config_Option is one session configuration option. The kinds share the fields here and
// variant holds the rest. id is `id` on the v1 wire and `configId` on the v2 wire; an empty
// category or description is absent.
Config_Option :: struct {
	meta:        json.Value,
	id:          string,
	name:        string,
	category:    string,
	description: string,
	variant:     union {
		Config_Select,
		Config_Boolean,
		Config_Other,
	},
}

Config_Select :: struct {
	current_value: string,
	options:       Config_Select_Options,
}

// Config_Select_Options is a flat list of choices or the same choices under group headers.
Config_Select_Options :: union {
	[]Config_Value,
	[]Config_Group,
}

Config_Boolean :: struct {
	current_value: bool,
}

// Config_Other is a kind this package does not know. raw is the whole option, so encoding it
// writes the payload back unchanged; its shared fields are only in raw.
Config_Other :: struct {
	type: string,
	raw:  json.Value,
}

// Config_Value is one choice of a select option.
Config_Value :: struct {
	meta:        json.Value,
	value:       string,
	name:        string,
	description: string,
}

// Config_Group is a titled set of choices. id is `group` on the v1 wire and `groupId` on v2.
Config_Group :: struct {
	meta:    json.Value,
	id:      string,
	name:    string,
	options: []Config_Value,
}

// config_option_decode reads one option from its JSON value. Its strings, meta and raw payload
// borrow from value; only a select's choice slices are allocated with allocator, and
// config_option_destroy releases them. Either spelling of the id and group id is accepted. It
// returns Invalid for a mismatched shape and Allocation when a slice cannot be allocated. An unknown
// `type` is not an error: it becomes Config_Other.
@(require_results)
config_option_decode :: proc(value: json.Value, allocator := context.allocator) -> (option: Config_Option, err: Params_Error) {
	object, is_object := value.(json.Object)
	if !is_object { return {}, .Invalid }
	ok := true
	kind := field_string(object, "type", true, &ok)
	if !ok { return {}, .Invalid }
	if kind != CONFIG_TYPE_SELECT && kind != CONFIG_TYPE_BOOLEAN {
		return Config_Option{variant = Config_Other{type = kind, raw = value}}, .None
	}
	option.meta = field_value(object, "_meta")
	option.id = field_string(object, "id", false, &ok)
	if option.id == "" { option.id = field_string(object, "configId", false, &ok) }
	option.name = field_string(object, "name", false, &ok)
	option.category = field_string(object, "category", false, &ok)
	option.description = field_string(object, "description", false, &ok)
	if !ok || option.id == "" { return {}, .Invalid }
	switch kind {
	case CONFIG_TYPE_SELECT:
		select := Config_Select {
			current_value = field_string(object, "currentValue", true, &ok),
		}
		if !ok { return {}, .Invalid }
		select.options = config_select_options_decode(object["options"], allocator) or_return
		option.variant = select
	case CONFIG_TYPE_BOOLEAN:
		current, is_boolean := object["currentValue"].(json.Boolean)
		if !is_boolean { return {}, .Invalid }
		option.variant = Config_Boolean {
			current_value = bool(current),
		}
	}
	return option, .None
}

// config_option_destroy releases what config_option_decode allocated with allocator.
config_option_destroy :: proc(option: Config_Option, allocator := context.allocator) {
	select, is_select := option.variant.(Config_Select)
	if !is_select { return }
	switch options in select.options {
	case []Config_Value:
		delete(options, allocator)
	case []Config_Group:
		for group in options { delete(group.options, allocator) }
		delete(options, allocator)
	case nil:
	}
}

// config_options_decode reads a list of options; a missing or null list is empty. Release the
// result with config_options_destroy.
@(require_results)
config_options_decode :: proc(value: json.Value, allocator := context.allocator) -> (options: []Config_Option, err: Params_Error) {
	if _, is_null := value.(json.Null); is_null || value == nil { return nil, .None }
	items, is_array := value.(json.Array)
	if !is_array { return nil, .Invalid }
	made, make_error := make([]Config_Option, len(items), allocator)
	if make_error != nil { return nil, .Allocation }
	for item, index in items {
		made[index], err = config_option_decode(item, allocator)
		if err != .None {
			for option in made[:index] { config_option_destroy(option, allocator) }
			delete(made, allocator)
			return nil, err
		}
	}
	return made, .None
}

config_options_destroy :: proc(options: []Config_Option, allocator := context.allocator) {
	for option in options { config_option_destroy(option, allocator) }
	delete(options, allocator)
}

@(private)
config_select_options_decode :: proc(value: json.Value, allocator: mem.Allocator) -> (options: Config_Select_Options, err: Params_Error) {
	items, is_array := value.(json.Array)
	if !is_array { return nil, .Invalid }
	grouped := false
	if len(items) > 0 {
		first, is_object := items[0].(json.Object)
		if !is_object { return nil, .Invalid }
		_, grouped = first["options"]
	}
	if !grouped {
		values, make_error := make([]Config_Value, len(items), allocator)
		if make_error != nil { return nil, .Allocation }
		for item, index in items {
			values[index], err = config_value_decode(item)
			if err != .None {
				delete(values, allocator)
				return nil, err
			}
		}
		return values, .None
	}
	groups, make_error := make([]Config_Group, len(items), allocator)
	if make_error != nil { return nil, .Allocation }
	for item, index in items {
		groups[index], err = config_group_decode(item, allocator)
		if err != .None {
			for group in groups[:index] { delete(group.options, allocator) }
			delete(groups, allocator)
			return nil, err
		}
	}
	return groups, .None
}

@(private)
config_value_decode :: proc(value: json.Value) -> (choice: Config_Value, err: Params_Error) {
	object, is_object := value.(json.Object)
	if !is_object { return {}, .Invalid }
	ok := true
	choice = Config_Value {
		meta        = field_value(object, "_meta"),
		value       = field_string(object, "value", true, &ok),
		name        = field_string(object, "name", false, &ok),
		description = field_string(object, "description", false, &ok),
	}
	if !ok { return {}, .Invalid }
	return choice, .None
}

@(private)
config_group_decode :: proc(value: json.Value, allocator: mem.Allocator) -> (group: Config_Group, err: Params_Error) {
	object, is_object := value.(json.Object)
	if !is_object { return {}, .Invalid }
	ok := true
	group = Config_Group {
		meta = field_value(object, "_meta"),
		id   = field_string(object, "groupId", false, &ok),
		name = field_string(object, "name", false, &ok),
	}
	if group.id == "" { group.id = field_string(object, "group", false, &ok) }
	items, is_array := object["options"].(json.Array)
	if !ok || !is_array { return {}, .Invalid }
	choices, make_error := make([]Config_Value, len(items), allocator)
	if make_error != nil { return {}, .Allocation }
	for item, index in items {
		choices[index], err = config_value_decode(item)
		if err != .None {
			delete(choices, allocator)
			return {}, err
		}
	}
	group.options = choices
	return group, .None
}

// config_option_encode builds the wire object of an option for protocol version 1 or 2, which
// differ in the spelling of the ids. The result borrows every string, meta and raw payload from
// option and owns only its objects and arrays, which it allocates with allocator; as with
// content_block_encode, pass context.temp_allocator or an arena. An option with no variant encodes
// as null. It returns the allocator's error when an object cannot be allocated.
@(require_results)
config_option_encode :: proc(option: Config_Option, version: int, allocator := context.allocator) -> (value: json.Value, err: mem.Allocator_Error) {
	if other, is_other := option.variant.(Config_Other); is_other { return other.raw, nil }
	if option.variant == nil { return json.Null{}, nil }
	object := make(json.Object, 8, allocator) or_return
	if option.meta != nil { field_put(&object, "_meta", option.meta) or_return }
	field_put(&object, "id" if version < PROTOCOL_VERSION_V2 else "configId", option.id) or_return
	field_put(&object, "name", option.name) or_return
	field_put_text(&object, "category", option.category) or_return
	field_put_text(&object, "description", option.description) or_return
	switch kind in option.variant {
	case Config_Select:
		field_put(&object, "type", CONFIG_TYPE_SELECT) or_return
		field_put(&object, "currentValue", kind.current_value) or_return
		choices: json.Array
		switch options in kind.options {
		case []Config_Value:
			choices = config_values_encode(options, allocator) or_return
		case []Config_Group:
			choices = make(json.Array, 0, len(options), allocator) or_return
			for group in options {
				group_object := make(json.Object, 4, allocator) or_return
				if group.meta != nil { field_put(&group_object, "_meta", group.meta) or_return }
				field_put(&group_object, "group" if version < PROTOCOL_VERSION_V2 else "groupId", group.id) or_return
				field_put(&group_object, "name", group.name) or_return
				field_put(&group_object, "options", config_values_encode(group.options, allocator) or_return) or_return
				_ = append(&choices, group_object) or_return
			}
		case nil:
			choices = make(json.Array, 0, 0, allocator) or_return
		}
		field_put(&object, "options", choices) or_return
	case Config_Boolean:
		field_put(&object, "type", CONFIG_TYPE_BOOLEAN) or_return
		field_put(&object, "currentValue", json.Boolean(kind.current_value)) or_return
	case Config_Other:
	}
	return object, nil
}

// config_options_encode builds the wire list of options; see config_option_encode for ownership.
@(require_results)
config_options_encode :: proc(options: []Config_Option, version: int, allocator := context.allocator) -> (values: []json.Value, err: mem.Allocator_Error) {
	values = make([]json.Value, len(options), allocator) or_return
	for option, index in options {
		values[index] = config_option_encode(option, version, allocator) or_return
	}
	return values, nil
}

@(private)
config_values_encode :: proc(values: []Config_Value, allocator: mem.Allocator) -> (choices: json.Array, err: mem.Allocator_Error) {
	choices = make(json.Array, 0, len(values), allocator) or_return
	for choice in values {
		object := make(json.Object, 4, allocator) or_return
		if choice.meta != nil { field_put(&object, "_meta", choice.meta) or_return }
		field_put(&object, "value", choice.value) or_return
		field_put(&object, "name", choice.name) or_return
		field_put_text(&object, "description", choice.description) or_return
		_ = append(&choices, object) or_return
	}
	return choices, nil
}

V2_Session_New_Result :: struct {
	session_id:         string `json:"sessionId"`,
	config_options:     []json.Value `json:"configOptions"`,
	available_commands: []Available_Command `json:"availableCommands,omitempty"`,
}

// Empty_Result is the answer of a method that reports success by returning.
Empty_Result :: struct {}

Prompt_Result :: struct {
	stop_reason: string `json:"stopReason"`,
}

// Session_Set_Config_Option_Params is a request to change one option. The value kinds share
// the session and option ids.
Session_Set_Config_Option_Params :: struct {
	meta:       json.Value,
	session_id: string,
	config_id:  string,
	variant:    union {
		Config_Set_Id,
		Config_Set_Boolean,
		Config_Set_Other,
	},
}

Config_Set_Id :: struct {
	value: string,
}

Config_Set_Boolean :: struct {
	value: bool,
}

// Config_Set_Other is a value kind this package does not know; value is borrowed from the
// decoded document.
Config_Set_Other :: struct {
	type:  string,
	value: json.Value,
}

// Session_Set_Config_Option_Request is Session_Set_Config_Option_Params in wire form, built by
// session_set_config_option_request.
Session_Set_Config_Option_Request :: struct {
	meta:       json.Value `json:"_meta,omitempty"`,
	session_id: string `json:"sessionId"`,
	config_id:  string `json:"configId"`,
	type:       string `json:"type,omitempty"`,
	value:      json.Value `json:"value"`,
}

// session_set_config_option_request builds the wire form of params for protocol version 1 or 2.
// Version 2 requires the type of an id value, which version 1 leaves out. Its strings borrow from
// params and nothing is allocated.
session_set_config_option_request :: proc(params: Session_Set_Config_Option_Params, version: int) -> Session_Set_Config_Option_Request {
	request := Session_Set_Config_Option_Request {
		meta       = params.meta,
		session_id = params.session_id,
		config_id  = params.config_id,
	}
	switch kind in params.variant {
	case Config_Set_Id:
		request.value = json.String(kind.value)
		if version >= PROTOCOL_VERSION_V2 { request.type = "id" }
	case Config_Set_Boolean:
		request.type = CONFIG_TYPE_BOOLEAN
		request.value = json.Boolean(kind.value)
	case Config_Set_Other:
		request.type = kind.type
		request.value = kind.value
	case nil:
	}
	return request
}

// session_set_config_option_params_decode reads a set_config_option request of protocol version 1
// or 2. A missing type or `id` is a string id and `boolean` a bool. Any other type is a string id
// in version 1, where the specification reads an unknown type with a string payload that way, and
// Config_Set_Other in version 2. Its strings borrow from value, and nothing is allocated. It
// returns Invalid for a mismatched shape.
@(require_results)
session_set_config_option_params_decode :: proc(value: json.Value, version: int, target: ^Session_Set_Config_Option_Params) -> Params_Error {
	object, is_object := value.(json.Object)
	if !is_object { return .Invalid }
	ok := true
	params := Session_Set_Config_Option_Params {
		meta       = field_value(object, "_meta"),
		session_id = field_string(object, "sessionId", true, &ok),
		config_id  = field_string(object, "configId", true, &ok),
	}
	kind := field_string(object, "type", false, &ok)
	payload := object["value"]
	if !ok || payload == nil { return .Invalid }
	text, is_text := payload.(json.String)
	switch {
	case kind == CONFIG_TYPE_BOOLEAN:
		flag, is_flag := payload.(json.Boolean)
		if !is_flag { return .Invalid }
		params.variant = Config_Set_Boolean {
			value = bool(flag),
		}
	case kind == "" || kind == "id" || (is_text && version < PROTOCOL_VERSION_V2):
		if !is_text { return .Invalid }
		params.variant = Config_Set_Id {
			value = string(text),
		}
	case:
		params.variant = Config_Set_Other {
			type  = kind,
			value = payload,
		}
	}
	target^ = params
	return .None
}

Session_Set_Config_Option_Result :: struct {
	config_options: []json.Value `json:"configOptions"`,
}

Session_Resume_Result :: struct {
	config_options:     []json.Value `json:"configOptions,omitempty"`,
	available_commands: []Available_Command `json:"availableCommands,omitempty"`,
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

// Available_Command_Input describes text input. V2 uses type = "text"; V1 omits type.
Available_Command_Input :: struct {
	type: string `json:"type,omitempty"`,
	hint: string `json:"hint"`,
	meta: json.Value `json:"_meta,omitempty"`,
}

Available_Command :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
	input:       Maybe(Available_Command_Input) `json:"input,omitempty"`,
	meta:        json.Value `json:"_meta,omitempty"`,
}

// Available_Commands_Update replaces the entire command list. An empty list clears it.
Available_Commands_Update :: struct {
	session_update:     string `json:"sessionUpdate"`,
	available_commands: []Available_Command `json:"availableCommands"`,
	meta:               json.Value `json:"_meta,omitempty"`,
}

State_Update :: struct {
	session_update: string `json:"sessionUpdate"`,
	state:          string `json:"state"`,
	stop_reason:    string `json:"stopReason,omitempty"`,
	error:          Maybe(RPC_Error) `json:"error,omitempty"`,
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
