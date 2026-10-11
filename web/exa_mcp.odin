package web

import "core:fmt"
import "core:strings"

import "nabla:http/client"

// The endpoint and tool name are Exa's public MCP server; it takes no key. The
// tools parameter selects the advanced search tool, which takes the same filters
// as the REST API and returns the REST response as its text block.
@(private)
EXA_MCP_URL :: "https://mcp.exa.ai/mcp?tools=web_search_advanced_exa"
@(private)
EXA_MCP_TOOL :: "web_search_advanced_exa"
@(private)
EXA_MCP_REQUEST_ID :: 1

@(private)
Exa_MCP_Arguments :: struct {
	query:              string,
	numResults:         Maybe(int) `json:",omitempty"`,
	type:               string,
	enableHighlights:   bool,
	includeDomains:     []string `json:",omitempty"`,
	excludeDomains:     []string `json:",omitempty"`,
	startPublishedDate: string `json:",omitempty"`,
}

@(private)
Exa_MCP_Params :: struct {
	name:      string,
	arguments: Exa_MCP_Arguments,
}

@(private)
Exa_MCP_Request :: struct {
	jsonrpc: string,
	id:      int,
	method:  string,
	params:  Exa_MCP_Params,
}

@(private)
Exa_MCP_Wire :: struct {
	id:     Maybe(int),
	result: struct {
		content: Maybe([]struct {
				text: string,
			}),
		isError: bool,
	},
	error:  Maybe(struct {
			code: int,
		}),
}

@(private)
@(require_results)
exa_mcp_request :: proc(endpoint: Endpoint, query: Query) -> (request: client.Request, clamped_to: int, err: Error) {
	wire := Exa_MCP_Request {
		jsonrpc = "2.0",
		id = EXA_MCP_REQUEST_ID,
		method = "tools/call",
		params = {
			name = EXA_MCP_TOOL,
			arguments = {
				query = query.text,
				type = "auto",
				enableHighlights = true,
				includeDomains = query.include_domains,
				excludeDomains = query.exclude_domains,
			},
		},
	}
	count: int
	count, clamped_to = clamp_count(query.count, EXA_MAX_COUNT)
	if count > 0 { wire.params.arguments.numResults = count }
	if wire.params.arguments.startPublishedDate, err = exa_start_date(query.freshness); err.kind != .None { return }
	if request.body, err = json_encode(wire); err.kind != .None { return }
	request.url = endpoint.base_url if endpoint.base_url != "" else EXA_MCP_URL
	request.method = .Post
	// The server answers with either a JSON object or an event stream, and refuses a request that accepts only one.
	request.headers, err = headers_make({"Content-Type", "application/json"}, {"Accept", "application/json, text/event-stream"})
	return
}

// exa_mcp_decode reads the JSON-RPC reply to the request, which is a bare JSON
// object or an event stream whose data lines carry messages. Messages with
// another id, such as notifications, are skipped. The first text block of the
// result holds the Exa search response, which exa_decode reads.
@(private)
@(require_results)
exa_mcp_decode :: proc(body: []u8) -> (response: Response, err: Error) {
	wire: Exa_MCP_Wire
	text := strings.trim_space(string(body))
	found: bool
	if strings.has_prefix(text, "{") {
		if err = json_decode(transmute([]u8)text, &wire, "exa mcp"); err.kind != .None { return }
		found = wire.id == EXA_MCP_REQUEST_ID
	} else {
		for line in strings.split_lines_iterator(&text) {
			if !strings.has_prefix(line, "data:") { continue }
			payload := strings.trim_space(line[len("data:"):])
			if !strings.has_prefix(payload, "{") { continue }
			message: Exa_MCP_Wire
			if err = json_decode(transmute([]u8)payload, &message, "exa mcp"); err.kind != .None { return }
			if message.id != EXA_MCP_REQUEST_ID { continue }
			wire = message
			found = true
			break
		}
	}
	if !found { return {}, {kind = .Invalid_Response, detail = "exa mcp: the response holds no reply to the request"} }

	if rpc_error, failed := wire.error.?; failed {
		return {}, {kind = .Rejected, detail = fmt.tprintf("exa mcp: JSON-RPC error %d", rpc_error.code)}
	}
	content, present := wire.result.content.?
	if !present { return {}, {kind = .Invalid_Response, detail = "exa mcp: the reply has neither a result nor an error"} }
	for item in content {
		if item.text == "" { continue }
		if wire.result.isError { return {}, {kind = .Rejected, detail = "exa mcp: the tool reported an error"} }
		return exa_decode(transmute([]u8)item.text)
	}
	if wire.result.isError { return {}, {kind = .Rejected, detail = "exa mcp: the tool reported an error"} }
	return
}
