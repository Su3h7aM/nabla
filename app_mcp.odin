#+build linux
package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

import "nabla:agent"
import "nabla:mcp"

// MCP_Runtime owns the running MCP clients and the adapter bindings that point into
// them.
//
// Both arrays are sized once, before any definition borrows a binding, and are never
// grown again. A dynamic-array append would move the backing store and leave every
// registry definition pointing at freed memory, which is the one mistake this type
// exists to make impossible.
MCP_Runtime :: struct {
	clients:           [dynamic]mcp.Client,
	bindings:          [dynamic]agent.MCP_Tool_Backend,
	// server_started and server_discovered say which clients have been launched and
	// which have answered discovery since they were launched.
	server_started:    []bool,
	server_discovered: []bool,
	alloc:             mem.Allocator,
}

// mcp_runtime_make reserves a slot for every configured server and every alias. The
// caller must have finished reading the configuration: the slot count is fixed here.
mcp_runtime_make :: proc(servers: []agent.MCP_Server_Config, alloc := context.allocator) -> MCP_Runtime {
	runtime := MCP_Runtime {
		alloc = alloc,
	}
	aliases := 0
	for server in servers { aliases += len(server.tools) }
	resize(&runtime.clients, len(servers))
	resize(&runtime.bindings, aliases)
	runtime.server_started = make([]bool, len(servers), alloc)
	runtime.server_discovered = make([]bool, len(servers), alloc)
	return runtime
}

// mcp_runtime_destroy stops every server and releases the runtime. It must run only
// once the registry that borrows the bindings is gone, which is why it is called
// after the chat session is destroyed.
mcp_runtime_destroy :: proc(runtime: ^MCP_Runtime) {
	allocator := runtime.alloc
	for &client in runtime.clients { mcp.client_destroy(&client) }
	delete(runtime.clients)
	delete(runtime.bindings)
	delete(runtime.server_started, allocator)
	delete(runtime.server_discovered, allocator)
	runtime^ = {}
}

// mcp_runtime_ensure makes sure the server at index is running and discovered, and
// returns its client. A server that cannot be started or does not answer discovery is
// reported once and contributes nothing to this refresh.
@(private)
mcp_runtime_ensure :: proc(runtime: ^MCP_Runtime, servers: []agent.MCP_Server_Config, index: int, warnings: ^strings.Builder) -> (^mcp.Client, bool) {
	server := servers[index]
	client := &runtime.clients[index]

	if !mcp.client_running(client) {
		if runtime.server_started[index] { mcp.client_destroy(client) }
		config_err := mcp.client_start(client, agent.mcp_stdio_config(server), runtime.alloc)
		if config_err.kind != .None {
			fmt.sbprintf(warnings, "\n%s: %s", server.id, mcp.error_text(config_err, context.temp_allocator))
			mcp.error_destroy(&config_err, runtime.alloc)
			runtime.server_started[index] = false
			runtime.server_discovered[index] = false
			return nil, false
		}
		runtime.server_started[index] = true
		// A restarted server is a fresh one: it must be asked what it supports again.
		runtime.server_discovered[index] = false
	}

	if !runtime.server_discovered[index] {
		discover, discover_err := mcp.client_discover(client, mcp_deadline(server.discovery_timeout))
		if discover_err.kind != .None {
			fmt.sbprintf(warnings, "\n%s: %s", server.id, mcp.error_text(discover_err, context.temp_allocator))
			mcp.error_destroy(&discover_err, runtime.alloc)
			return nil, false
		}
		// The version is a precondition for interpreting anything else, and a server
		// that exposes no tools has nothing to contribute.
		if !mcp.discover_supports_version(discover) {
			fmt.sbprintf(warnings, "\n%s: it does not support protocol version %s", server.id, mcp.PROTOCOL_VERSION)
			mcp.discover_result_destroy(&discover, runtime.alloc)
			return nil, false
		}
		if !discover.tools_supported {
			fmt.sbprintf(warnings, "\n%s: it exposes no tools", server.id)
			mcp.discover_result_destroy(&discover, runtime.alloc)
			return nil, false
		}
		mcp.discover_result_destroy(&discover, runtime.alloc)
		runtime.server_discovered[index] = true
	}

	return client, true
}

@(private)
mcp_deadline :: proc(timeout: time.Duration) -> mcp.Control {
	if timeout <= 0 { return {} }
	return {deadline_at = time.tick_add(time.tick_now(), timeout), has_deadline = true}
}

// mcp_page_find finds the remote tool an alias stands for. The remote name is
// compared exactly: the protocol treats tool names as case-sensitive.
@(private)
mcp_page_find :: proc(page: mcp.Tool_Page, remote_name: string) -> (mcp.Tool, bool) {
	for tool in page.tools {
		if tool.name == remote_name { return tool, true }
	}
	return {}, false
}

// app_tools_refresh rebuilds the session's tool registry from the native tools and
// every configured MCP server that answers.
//
// It runs between turns, while the session is idle, so the registry it replaces is
// not borrowed by a running request or call. A server that cannot be reached
// contributes no tools and is reported once: a definition whose schema or backend no
// longer matches is worse than an absent tool, and other servers still contribute.
//
// The returned warning is allocated on the scratch allocator and is valid until the
// next reset; the caller copies it if it must outlive the call.
app_tools_refresh :: proc(app: ^App) -> string {
	setup := &app.setup
	if len(setup.mcp_servers) == 0 { return "" }
	if agent.chat_session_state(&setup.session) != .Idle { return "" }

	registry, registry_err := agent.tool_registry_make(setup.alloc)
	if registry_err.kind != .None {
		return "the tool registry could not be built"
	}
	installed := false
	defer if !installed { agent.tool_registry_destroy(&registry) }

	warnings := strings.builder_make(context.temp_allocator)
	alias_index := 0
	for server, index in setup.mcp_servers {
		client, available := mcp_runtime_ensure(&setup.mcp, setup.mcp_servers, index, &warnings)
		if !available {
			alias_index += len(server.tools)
			continue
		}
		page, list_err := mcp.client_tools_list(client, mcp_deadline(server.discovery_timeout), setup.alloc)
		if list_err.kind != .None {
			fmt.sbprintf(&warnings, "\n%s: %s", server.id, mcp.error_text(list_err, context.temp_allocator))
			mcp.error_destroy(&list_err, setup.alloc)
			alias_index += len(server.tools)
			continue
		}
		for alias in server.tools {
			// The binding lives in the runtime, whose slots are fixed, so a definition
			// that borrows this address stays valid for the runtime's life.
			binding := &setup.mcp.bindings[alias_index]
			alias_index += 1
			tool, found := mcp_page_find(page, alias.remote_name)
			if !found {
				fmt.sbprintf(&warnings, "\n%s: the server did not list %s", server.id, alias.remote_name)
				continue
			}
			binding^ = agent.MCP_Tool_Backend {
				client      = client,
				server_id   = server.id,
				remote_name = alias.remote_name,
			}
			definition := agent.mcp_tool_definition(alias.name, tool, binding, agent.mcp_timeout_policy(server))
			if add_err := agent.tool_registry_add(&registry, definition); add_err.kind != .None {
				fmt.sbprintf(&warnings, "\n%s: %s: %s", server.id, alias.name, add_err.detail)
			}
		}
		mcp.tool_page_destroy(&page, setup.alloc)
	}

	agent.tool_registry_sort(&registry)
	if replace_err := agent.chat_session_replace_tools(&setup.session, &registry); replace_err != .None {
		fmt.sbprintf(&warnings, "\nthe tool list could not be replaced")
		return strings.to_string(warnings)
	}
	// The session owns the registry now, and the old one is already destroyed, so
	// nothing borrows the previous bindings.
	installed = true
	return strings.to_string(warnings)
}
