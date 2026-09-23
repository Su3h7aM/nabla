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
// Client slots never move. Each binding has its own allocation, so collecting the
// pointers cannot invalidate a definition. A refresh keeps the previous generation
// alive until the session accepts the replacement registry.
MCP_Runtime :: struct {
	clients:            [dynamic]mcp.Client,
	bindings:           [dynamic]^agent.MCP_Tool_Backend,
	// server_started and server_discovered say which clients have been launched and
	// which have answered discovery since they were launched.
	server_started:     []bool,
	server_discovered:  []bool,
	// server_ids and server_launch name each slot for the lifecycle records, and
	// server_launch counts launches within this run so a restart is distinguishable
	// from a first launch without pretending to be a global identity.
	server_ids:         []string,
	server_launch:      []u64,
	alloc:              mem.Allocator,
	refresh_generation: u64,
}

// mcp_runtime_make reserves one stable client slot per configured server. Tool
// bindings are allocated after discovery because the server decides their count.
mcp_runtime_make :: proc(servers: []agent.MCP_Server_Config, alloc := context.allocator) -> (MCP_Runtime, bool) {
	runtime := MCP_Runtime {
		alloc = alloc,
	}
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
	runtime.server_launch, alloc_error = make([]u64, len(servers), alloc)
	if alloc_error != nil {
		mcp_runtime_destroy(&runtime)
		return {}, false
	}
	runtime.server_ids, alloc_error = make([]string, len(servers), alloc)
	if alloc_error != nil {
		mcp_runtime_destroy(&runtime)
		return {}, false
	}
	for server, index in servers {
		runtime.server_ids[index], alloc_error = strings.clone(server.id, alloc)
		if alloc_error != nil {
			mcp_runtime_destroy(&runtime)
			return {}, false
		}
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
	for &client, index in runtime.clients {
		if index < len(runtime.server_started) && runtime.server_started[index] && mcp.client_running(&client) {
			server_id := ""
			if index < len(runtime.server_ids) { server_id = runtime.server_ids[index] }
			launch: u64
			if index < len(runtime.server_launch) { launch = runtime.server_launch[index] }
			log_mcp_stopped(server_id, launch, "released")
		}
		mcp.client_destroy(&client)
	}
	delete(runtime.clients)
	mcp_bindings_destroy(&runtime.bindings, allocator)
	delete(runtime.server_started, allocator)
	delete(runtime.server_discovered, allocator)
	delete(runtime.server_launch, allocator)
	for id in runtime.server_ids { delete(id, allocator) }
	delete(runtime.server_ids, allocator)
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
		if runtime.server_started[index] {
			log_mcp_stopped(server.id, runtime.server_launch[index], "restart")
			mcp.client_destroy(client)
		}
		config_err := mcp.client_start(client, agent.mcp_stdio_config(server), runtime.alloc)
		if config_err.kind != .None {
			fmt.sbprintf(warnings, "\n%s: %s", server.id, mcp.error_text(config_err, context.temp_allocator))
			mcp.error_destroy(&config_err, runtime.alloc)
			runtime.server_started[index] = false
			runtime.server_discovered[index] = false
			return nil, false
		}
		runtime.server_started[index] = true
		runtime.server_launch[index] += 1
		log_mcp_started(server.id, runtime.server_launch[index])
		// A restarted server is a fresh one: it must be asked what it supports again.
		runtime.server_discovered[index] = false
	}

	if !runtime.server_discovered[index] {
		// Connecting negotiates a revision, so a server this client cannot speak to is
		// refused here with the revision it offered rather than failing later under
		// semantics neither side agreed to.
		wire := agent.MCP_Log {
			server_id = server.id,
		}
		connection, connect_err := mcp.client_connect(client, mcp_operation(server.discovery_timeout, &wire), runtime.alloc)
		if connect_err.kind != .None {
			fmt.sbprintf(warnings, "\n%s: %s", server.id, mcp.error_text(connect_err, context.temp_allocator))
			if connect_err.stderr_tail != "" {
				fmt.sbprintf(warnings, "\n%s: its last output was: %s", server.id, tail_excerpt(connect_err.stderr_tail))
			}
			mcp.error_destroy(&connect_err, runtime.alloc)
			return nil, false
		}
		log_mcp_negotiated(server.id, runtime.server_launch[index], connection)
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

// The MCP lifecycle is recorded from here because this is what launches and stops
// the processes. The server instance is a run-local launch counter, which is what
// tells a restart apart from the first launch. An exit status is not recorded
// because mcp does not expose one; the record names the stop instead of inventing
// a status.
log_mcp_started :: proc(server_id: string, instance: u64) {
	fields := [2]agent.Log_Field{{key = "server_id", value = server_id}, {key = "server_instance", value = instance}}
	agent.log_emit(agent.Log_Record{level = .Info, category = .MCP, event = "mcp.started", fields = fields[:]})
}

log_mcp_negotiated :: proc(server_id: string, instance: u64, connection: mcp.Connection) {
	fields := [5]agent.Log_Field {
		{key = "server_id", value = server_id},
		{key = "server_instance", value = instance},
		{key = "revision", value = mcp.protocol_version_name(connection.version)},
		{key = "server_name", value = connection.server_name},
		{key = "tools_supported", value = connection.tools_supported},
	}
	agent.log_emit(agent.Log_Record{level = .Info, category = .MCP, event = "mcp.negotiated", fields = fields[:]})
}

log_mcp_stopped :: proc(server_id: string, instance: u64, reason: string) {
	fields := [3]agent.Log_Field{{key = "server_id", value = server_id}, {key = "server_instance", value = instance}, {key = "reason", value = reason}}
	agent.log_emit(agent.Log_Record{level = .Info, category = .MCP, event = "mcp.stopped", fields = fields[:]})
}

// mcp_operation is the bound and the observer for one client operation. The wire
// log is declared by the caller, because the operation borrows it for its whole
// call and a log owned here would not outlive the return.
@(private)
mcp_operation :: proc(timeout: time.Duration, wire: ^agent.MCP_Log) -> mcp.Operation_Options {
	options: mcp.Operation_Options
	if timeout > 0 {
		options.control = {
			deadline_at  = time.tick_add(time.tick_now(), timeout),
			has_deadline = true,
		}
	}
	if agent.log_capture_wanted() { options.observer = agent.mcp_log_observer(wire) }
	return options
}

@(private)
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
@(private)
mcp_tool_config :: proc(server: agent.MCP_Server_Config, remote_name: string) -> (agent.MCP_Tool_Config, bool) {
	for config in server.tools {
		if config.remote_name == remote_name { return config, true }
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

	setup.mcp.refresh_generation += 1
	// The refresh is recorded against the session it changes, so the caller's
	// run-level logger is narrowed to this session for the whole refresh.
	binding: agent.Log_Binding
	context.logger = agent.log_rebind(&binding, agent.log_correlation(&setup.session))
	generation := setup.mcp.refresh_generation
	discovered, accepted, disabled, rejected, unavailable := 0, 0, 0, 0, 0
	installed := false
	started := time.tick_now()
	start_fields := [1]agent.Log_Field{{key = "generation", value = generation}}
	agent.log_emit({level = .Info, category = .Tool, event = "tools.refresh_started", fields = start_fields[:]})
	defer {
		fields := [8]agent.Log_Field {
			{key = "generation", value = generation},
			{key = "discovered", value = i64(discovered)},
			{key = "accepted", value = i64(accepted)},
			{key = "disabled", value = i64(disabled)},
			{key = "rejected", value = i64(rejected)},
			{key = "unavailable_servers", value = i64(unavailable)},
			{key = "installed", value = installed},
			{key = "elapsed_ms", value = agent.log_duration_ms(time.tick_since(started))},
		}
		agent.log_emit({level = .Info, category = .Tool, event = "tools.refresh_finished", fields = fields[:]})
	}
	registry, registry_err := agent.tool_registry_make(setup.alloc)
	if registry_err.kind != .None {
		return "the tool registry could not be built"
	}
	defer if !installed { agent.tool_registry_destroy(&registry) }

	warnings := strings.builder_make(context.temp_allocator)
	bindings, bindings_error := make([dynamic]^agent.MCP_Tool_Backend, 0, setup.alloc)
	if bindings_error != nil { return "the MCP binding table could not be allocated" }
	bindings_installed := false
	defer if !bindings_installed { mcp_bindings_destroy(&bindings, setup.alloc) }
	for server, index in setup.mcp_servers {
		client, available := mcp_runtime_ensure(&setup.mcp, setup.mcp_servers, index, &warnings)
		if !available { unavailable += 1; continue }
		wire := agent.MCP_Log {
			server_id = server.id,
		}
		page, list_err := mcp.client_tools_list(client, mcp_operation(server.discovery_timeout, &wire), setup.alloc)
		if list_err.kind != .None {
			unavailable += 1
			fmt.sbprintf(&warnings, "\n%s: %s", server.id, mcp.error_text(list_err, context.temp_allocator))
			mcp.error_destroy(&list_err, setup.alloc)
			continue
		}
		discovered += len(page.tools) + len(page.rejected)
		rejected += len(page.rejected)
		for tool in page.tools {
			config, configured := mcp_tool_config(server, tool.name)
			if configured && !config.enabled { disabled += 1; continue }
			local_name := tool.name
			if configured && config.name != "" { local_name = config.name }
			// The remote name is exact and arbitrary; the canonical name must be a flat
			// identifier. Punctuation is never rewritten, because two remote names could
			// collapse into one canonical name without the user being told.
			name := fmt.tprintf("%s_%s", server.id, local_name)
			if !agent.tool_name_valid(name) {
				rejected += 1
				fmt.sbprintf(&warnings, "\n%s: %s cannot become a tool name; shorten it with a tools entry", server.id, tool.name)
				continue
			}
			binding, binding_ok := mcp_binding_make(client, server.id, tool.name, setup.alloc)
			if !binding_ok {
				rejected += 1
				fmt.sbprintf(&warnings, "\n%s: %s: the binding could not be allocated", server.id, tool.name)
				continue
			}
			if append(&bindings, binding) != 1 {
				rejected += 1
				fmt.sbprintf(&warnings, "\n%s: %s: the binding table could not grow", server.id, tool.name)
				mcp_binding_destroy(binding, setup.alloc)
				continue
			}
			definition := agent.mcp_tool_definition(name, tool, binding, agent.mcp_timeout_policy(server))
			if add_err := agent.tool_registry_add(&registry, definition); add_err.kind != .None {
				rejected += 1
				fmt.sbprintf(&warnings, "\n%s: %s: %s", server.id, tool.name, add_err.detail)
				bindings[len(bindings) - 1] = nil
				resize(&bindings, len(bindings) - 1)
				mcp_binding_destroy(binding, setup.alloc)
				continue
			}
			accepted += 1
			fields := [4]agent.Log_Field {
				{key = "generation", value = generation},
				{key = "server_id", value = server.id},
				{key = "remote_name", value = tool.name},
				{key = "tool", value = name},
			}
			agent.log_emit({level = .Debug, category = .Tool, event = "tool.binding", fields = fields[:]})
		}
		for config in server.tools {
			found := false
			for tool in page.tools {
				if tool.name == config.remote_name { found = true; break }
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
	// Replacement destroys the old registry, so its bindings can now be released.
	mcp_bindings_destroy(&setup.mcp.bindings, setup.alloc)
	setup.mcp.bindings = bindings
	bindings_installed = true
	installed = true
	return strings.to_string(warnings)
}

// tail_excerpt is the end of what a server wrote to standard error, bounded, which
// is the part that says why it gave up.
@(private)
tail_excerpt :: proc(text: string) -> string {
	if len(text) <= MCP_STDERR_EXCERPT { return text }
	return text[len(text) - MCP_STDERR_EXCERPT:]
}

// MCP_STDERR_EXCERPT bounds how much of a server's own output a warning repeats.
MCP_STDERR_EXCERPT :: 1024
