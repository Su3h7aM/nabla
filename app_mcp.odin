#+build linux
package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

import "nabla:agent"
import "nabla:mcp"

// MCP_Runtime owns the running MCP clients and the adapter bindings that point into them.
// Client slots never move, and each binding has its own allocation, so collecting the
// pointers cannot invalidate a definition. A refresh keeps the previous generation alive
// until the session accepts the replacement registry.
MCP_Runtime :: struct {
	clients:           [dynamic]mcp.Client,
	bindings:          [dynamic]^agent.MCP_Tool_Backend,
	// server_started and server_discovered say which clients have been launched and
	// which have answered discovery since they were launched.
	server_started:    []bool,
	server_discovered: []bool,
	alloc:             mem.Allocator,
}

// mcp_runtime_make reserves one stable client slot per configured server. Tool
// bindings are allocated after discovery because the server decides their count.
@(require_results)
mcp_runtime_make :: proc(servers: []agent.MCP_Server_Config, alloc := context.allocator) -> (MCP_Runtime, bool) {
	runtime := MCP_Runtime {
		alloc = alloc,
	}
	runtime.clients.allocator = alloc
	if resize(&runtime.clients, len(servers)) != nil { return {}, false }
	alloc_error: mem.Allocator_Error
	runtime.server_started, alloc_error = make([]bool, len(servers), alloc)
	if alloc_error != nil {
		mcp_runtime_destroy(&runtime)
		return {}, false
	}
	runtime.server_discovered, alloc_error = make([]bool, len(servers), alloc)
	if alloc_error != nil {
		mcp_runtime_destroy(&runtime)
		return {}, false
	}
	return runtime, true
}

// mcp_runtime_destroy stops every server and releases the runtime. It must run only
// once the registry that borrows the bindings is gone, which is why it is called
// after the chat session is destroyed. A runtime that was never built, or was
// already released, owns nothing.
mcp_runtime_destroy :: proc(runtime: ^MCP_Runtime) {
	if runtime == nil || runtime.alloc.procedure == nil { return }
	allocator := runtime.alloc
	for &client in runtime.clients { mcp.client_destroy(&client) }
	delete(runtime.clients)
	mcp_bindings_destroy(&runtime.bindings, allocator)
	delete(runtime.server_started, allocator)
	delete(runtime.server_discovered, allocator)
	runtime^ = {}
}

// mcp_runtime_ensure makes sure the server at index is running and discovered, and
// returns its client. A server that cannot be started or does not answer discovery is
// reported once and contributes nothing to this refresh.
@(private, require_results)
mcp_runtime_ensure :: proc(runtime: ^MCP_Runtime, servers: []agent.MCP_Server_Config, index: int, warnings: ^strings.Builder) -> (^mcp.Client, bool) {
	server := servers[index]
	client := &runtime.clients[index]

	if !mcp.client_running(client) {
		if runtime.server_started[index] {
			mcp.client_destroy(client)
		}
		stdio, stdio_ok := agent.mcp_stdio_config(server)
		if !stdio_ok {
			fmt.sbprintf(warnings, "\n%s: the server environment could not be built", server.id)
			runtime.server_started[index] = false
			runtime.server_discovered[index] = false
			return nil, false
		}
		config_err := mcp.client_start(client, stdio, runtime.alloc)
		if config_err.kind != .None {
			fmt.sbprintf(warnings, "\n%s: %s", server.id, mcp.error_text(config_err, context.temp_allocator) or_else "the failure could not be described")
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
		// Connecting negotiates a revision, so a server this client cannot speak to is
		// refused here with the revision it offered rather than failing later under
		// semantics neither side agreed to.
		connection, connect_err := mcp.client_connect(client, mcp_operation(server.discovery_timeout), runtime.alloc)
		if connect_err.kind != .None {
			fmt.sbprintf(warnings, "\n%s: %s", server.id, mcp.error_text(connect_err, context.temp_allocator) or_else "the failure could not be described")
			if connect_err.stderr_tail != "" {
				fmt.sbprintf(warnings, "\n%s: its last output was: %s", server.id, connect_err.stderr_tail)
			}
			mcp.error_destroy(&connect_err, runtime.alloc)
			return nil, false
		}
		if !connection.tools_supported {
			fmt.sbprintf(warnings, "\n%s: it exposes no tools", server.id)
			mcp.connection_destroy(&connection, runtime.alloc)
			return nil, false
		}
		mcp.connection_destroy(&connection, runtime.alloc)
		runtime.server_discovered[index] = true
	}

	return client, true
}

// mcp_operation is the bound for one client operation.
@(private)
mcp_operation :: proc(timeout: time.Duration) -> mcp.Operation_Options {
	options: mcp.Operation_Options
	if timeout > 0 {
		options.control = {
			deadline_at  = time.tick_add(time.tick_now(), timeout),
			has_deadline = true,
		}
	}
	return options
}

@(private, require_results)
mcp_binding_make :: proc(client: ^mcp.Client, server_id, remote_name: string, allocator: mem.Allocator) -> (^agent.MCP_Tool_Backend, bool) {
	binding, alloc_error := new(agent.MCP_Tool_Backend, allocator)
	if alloc_error != nil { return nil, false }
	remote, clone_error := strings.clone(remote_name, allocator)
	if clone_error != nil {
		free(binding, allocator)
		return nil, false
	}
	binding^ = agent.MCP_Tool_Backend {
		client      = client,
		server_id   = server_id,
		remote_name = remote,
	}
	return binding, true
}

@(private)
mcp_binding_destroy :: proc(binding: ^agent.MCP_Tool_Backend, allocator: mem.Allocator) {
	if binding == nil { return }
	delete(binding.remote_name, allocator)
	free(binding, allocator)
}

@(private)
mcp_bindings_destroy :: proc(bindings: ^[dynamic]^agent.MCP_Tool_Backend, allocator: mem.Allocator) {
	for binding in bindings^ { mcp_binding_destroy(binding, allocator) }
	delete(bindings^)
	bindings^ = nil
}

// mcp_tool_config returns the override for one exact, case-sensitive remote name.
@(private, require_results)
mcp_tool_config :: proc(server: agent.MCP_Server_Config, remote_name: string) -> (agent.MCP_Tool_Config, bool) {
	for config in server.tools {
		if config.remote_name == remote_name { return config, true }
	}
	return {}, false
}

// app_tools_refresh rebuilds the session's tool registry from the native tools and every
// configured MCP server that answers. It runs only while the session is idle, so the
// registry it replaces is not borrowed. The returned warning is scratch memory, valid
// until the next reset; the caller copies it to outlive the call.
@(require_results)
app_tools_refresh :: proc(app: ^App) -> string {
	setup := &app.setup
	if len(setup.mcp_servers) == 0 { return "" }
	if agent.chat_session_state(&setup.session) != .Idle { return "" }
	// Child and abandoned workers may still call through these bindings.
	if setup.workers_abandoned || agent.chat_session_workers_outstanding(&setup.session) { return "" }

	installed := false
	registry, registry_err := agent.tool_registry_make(setup.alloc)
	if registry_err.kind != .None {
		return "the tool registry could not be built"
	}
	defer if !installed { agent.tool_registry_destroy(&registry) }
	if agent.tool_registry_describe_agents(&registry, setup.harness_options.acp_agents).kind != .None {
		return "the tool registry could not be built"
	}

	warnings, warnings_error := strings.builder_make(context.temp_allocator)
	if warnings_error != nil { return "the MCP warning buffer could not be allocated" }
	bindings, bindings_error := make([dynamic]^agent.MCP_Tool_Backend, 0, setup.alloc)
	if bindings_error != nil { return "the MCP binding table could not be allocated" }
	bindings_installed := false
	defer if !bindings_installed { mcp_bindings_destroy(&bindings, setup.alloc) }
	for server, index in setup.mcp_servers {
		client, available := mcp_runtime_ensure(&setup.mcp, setup.mcp_servers, index, &warnings)
		if !available {
			continue
		}
		page, list_err := mcp.client_tools_list(client, mcp_operation(server.discovery_timeout), setup.alloc)
		if list_err.kind != .None {
			fmt.sbprintf(&warnings, "\n%s: %s", server.id, mcp.error_text(list_err, context.temp_allocator) or_else "the failure could not be described")
			mcp.error_destroy(&list_err, setup.alloc)
			continue
		}
		for tool in page.tools {
			config, configured := mcp_tool_config(server, tool.name)
			if configured && !config.enabled {
				continue
			}
			local_name := tool.name
			if configured && config.name != "" { local_name = config.name }
			// The remote name is exact and arbitrary; the canonical name must be a flat
			// identifier. Punctuation is never rewritten, because two remote names could
			// collapse into one canonical name without the user being told.
			name := fmt.tprintf("%s_%s", server.id, local_name)
			if !agent.tool_name_valid(name) {
				fmt.sbprintf(&warnings, "\n%s: %s cannot become a tool name; shorten it with a tools entry", server.id, tool.name)
				continue
			}
			binding, binding_ok := mcp_binding_make(client, server.id, tool.name, setup.alloc)
			if !binding_ok {
				fmt.sbprintf(&warnings, "\n%s: %s: the binding could not be allocated", server.id, tool.name)
				continue
			}
			if append(&bindings, binding) != 1 {
				fmt.sbprintf(&warnings, "\n%s: %s: the binding table could not grow", server.id, tool.name)
				mcp_binding_destroy(binding, setup.alloc)
				continue
			}
			definition := agent.mcp_tool_definition(name, tool, binding, server.call_timeout)
			if add_err := agent.tool_registry_add(&registry, definition); add_err.kind != .None {
				fmt.sbprintf(&warnings, "\n%s: %s: %s", server.id, tool.name, add_err.detail)
				bindings[len(bindings) - 1] = nil
				// A shrink never allocates, so it cannot fail.
				_ = resize(&bindings, len(bindings) - 1)
				mcp_binding_destroy(binding, setup.alloc)
				continue
			}
		}
		for config in server.tools {
			found := false
			for tool in page.tools {
				if tool.name == config.remote_name {
					found = true
					break
				}
			}
			if !found { fmt.sbprintf(&warnings, "\n%s: the server did not list %s", server.id, config.remote_name) }
		}
		mcp.tool_page_destroy(&page, setup.alloc)
	}

	agent.tool_registry_sort(&registry)
	if replace_err := agent.chat_session_replace_tools(&setup.session, &registry); replace_err != .None {
		fmt.sbprintf(&warnings, "\nthe tool list could not be replaced")
		return strings.to_string(warnings)
	}
	// Replacement destroys the old registry, so its bindings can now be released, unless an
	// abandoned tool worker may still be using one; then they are left to process exit.
	if setup.workers_abandoned || agent.chat_session_workers_outstanding(&setup.session) {
		delete(setup.mcp.bindings)
	} else {
		mcp_bindings_destroy(&setup.mcp.bindings, setup.alloc)
	}
	setup.mcp.bindings = bindings
	bindings_installed = true
	installed = true
	return strings.to_string(warnings)
}
