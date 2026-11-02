package agent

import "core:mem"
import "core:strings"
import "core:time"

import "nabla:agent/journal"

// session_environment_from_configs builds the session.environment payload for the
// standing instructions and MCP server list an interface installed. Every string
// is owned by allocator; release it with session_environment_destroy.
@(require_results)
session_environment_from_configs :: proc(
	instructions: string,
	servers: []MCP_Server_Config,
	allocator: mem.Allocator,
) -> (
	environment: journal.Session_Environment,
	error: Config_Error,
) {
	environment.instructions = environment_string_clone(instructions, allocator) or_return
	failed := true
	defer if failed { session_environment_destroy(&environment, allocator) }

	listed, list_error := make([]journal.Session_Environment_Server, len(servers), allocator)
	if list_error != nil { return {}, .Allocation }
	complete := false
	defer if !complete {
		for &entry in listed { session_environment_server_destroy(&entry, allocator) }
		delete(listed, allocator)
	}
	for server, index in servers {
		entry := &listed[index]
		entry.id = environment_string_clone(server.id, allocator) or_return
		entry.executable = environment_string_clone(server.stdio.executable, allocator) or_return
		entry.arguments = environment_strings_clone(server.stdio.arguments, allocator) or_return
		entry.working_directory = environment_string_clone(server.stdio.working_directory, allocator) or_return
		entry.environment = session_environment_variables_clone(server.stdio.environment, allocator) or_return
		entry.tools = session_environment_tools_clone(server.tools, allocator) or_return
		entry.discovery_timeout_ms = i64(server.discovery_timeout) / i64(time.Millisecond)
		entry.call_timeout_ms = i64(server.call_timeout) / i64(time.Millisecond)
	}
	complete = true
	environment.servers = listed
	failed = false
	return environment, .None
}

// session_environment_to_configs converts a session.environment payload into the
// server list the session runs with. Every string is owned by allocator; release
// it with mcp_servers_destroy. .Invalid means the record names something no server
// may use, which the caller refuses rather than installing half of it.
@(require_results)
session_environment_to_configs :: proc(
	environment: journal.Session_Environment,
	allocator: mem.Allocator,
) -> (
	servers: [dynamic]MCP_Server_Config,
	error: Config_Error,
) {
	result, result_error := make([dynamic]MCP_Server_Config, 0, len(environment.servers), allocator)
	if result_error != nil { return {}, .Allocation }
	failed := true
	defer if failed { mcp_servers_destroy(&result, allocator) }
	for server in environment.servers {
		config, config_error := session_environment_server_config(server, allocator)
		if config_error != .None { return {}, config_error }
		if append(&result, config) != 1 {
			mcp_server_config_destroy(&config, allocator)
			return {}, .Allocation
		}
	}
	failed = false
	return result, .None
}

// session_environment_destroy releases a payload session_environment_from_configs built.
session_environment_destroy :: proc(environment: ^journal.Session_Environment, allocator: mem.Allocator) {
	delete(environment.instructions, allocator)
	for &server in environment.servers { session_environment_server_destroy(&server, allocator) }
	delete(environment.servers, allocator)
	environment^ = {}
}

// session_environment_server_config converts one record server into the
// configuration the session runs with. .Invalid means the record names something
// no server may use: an id or executable the configuration would refuse, a
// non-positive timeout, a malformed environment, or a tool override that disables
// a tool and renames it at once.
@(private, require_results)
session_environment_server_config :: proc(
	server: journal.Session_Environment_Server,
	allocator: mem.Allocator,
) -> (
	config: MCP_Server_Config,
	error: Config_Error,
) {
	if !tool_name_valid(server.id) || !mcp_executable_valid(server.executable) { return {}, .Invalid }
	if server.discovery_timeout_ms <= 0 || server.call_timeout_ms <= 0 { return {}, .Invalid }
	config = MCP_Server_Config {
		discovery_timeout = time.Duration(server.discovery_timeout_ms) * time.Millisecond,
		call_timeout      = time.Duration(server.call_timeout_ms) * time.Millisecond,
	}
	failed := true
	defer if failed { mcp_server_config_destroy(&config, allocator) }
	config.id = environment_string_clone(server.id, allocator) or_return
	config.stdio.executable = environment_string_clone(server.executable, allocator) or_return
	config.stdio.arguments = environment_strings_clone(server.arguments, allocator) or_return
	config.stdio.working_directory = environment_string_clone(server.working_directory, allocator) or_return
	config.stdio.environment = session_environment_variables_load(server.environment, allocator) or_return
	config.tools = session_environment_tools_load(server.tools, allocator) or_return
	failed = false
	return config, .None
}

// session_environment_variables_clone copies a configured server's environment.
@(private, require_results)
session_environment_variables_clone :: proc(
	source: []MCP_Environment,
	allocator: mem.Allocator,
) -> (
	result: []journal.Session_Environment_Variable,
	error: Config_Error,
) {
	cloned, clone_error := make([]journal.Session_Environment_Variable, len(source), allocator)
	if clone_error != nil { return nil, .Allocation }
	complete := false
	defer if !complete {
		for &entry in cloned {
			delete(entry.name, allocator)
			delete(entry.value, allocator)
		}
		delete(cloned, allocator)
	}
	for entry, index in source {
		cloned[index].name = environment_string_clone(entry.name, allocator) or_return
		cloned[index].value = environment_string_clone(entry.value, allocator) or_return
	}
	complete = true
	return cloned, .None
}

// session_environment_variables_load copies a record's environment, refusing a
// name no server may be launched with.
@(private, require_results)
session_environment_variables_load :: proc(
	source: []journal.Session_Environment_Variable,
	allocator: mem.Allocator,
) -> (
	result: []MCP_Environment,
	error: Config_Error,
) {
	loaded, load_error := make([]MCP_Environment, len(source), allocator)
	if load_error != nil { return nil, .Allocation }
	complete := false
	defer if !complete {
		for &entry in loaded {
			delete(entry.name, allocator)
			delete(entry.value, allocator)
		}
		delete(loaded, allocator)
	}
	for entry, index in source {
		if !mcp_environment_name_valid(entry.name) { return nil, .Invalid }
		loaded[index].name = environment_string_clone(entry.name, allocator) or_return
		loaded[index].value = environment_string_clone(entry.value, allocator) or_return
	}
	complete = true
	return loaded, .None
}

// session_environment_tools_clone copies a configured server's tool overrides.
@(private, require_results)
session_environment_tools_clone :: proc(
	source: []MCP_Tool_Config,
	allocator: mem.Allocator,
) -> (
	result: []journal.Session_Environment_Tool,
	error: Config_Error,
) {
	cloned, clone_error := make([]journal.Session_Environment_Tool, len(source), allocator)
	if clone_error != nil { return nil, .Allocation }
	complete := false
	defer if !complete {
		for &tool in cloned {
			delete(tool.remote_name, allocator)
			delete(tool.name, allocator)
		}
		delete(cloned, allocator)
	}
	for tool, index in source {
		cloned[index].remote_name = environment_string_clone(tool.remote_name, allocator) or_return
		cloned[index].name = environment_string_clone(tool.name, allocator) or_return
		cloned[index].enabled = tool.enabled
	}
	complete = true
	return cloned, .None
}

// session_environment_tools_load copies a record's tool overrides, refusing what
// the configuration would refuse: an empty remote name, an unusable replacement
// name, or an entry that disables a tool and renames it at once.
@(private, require_results)
session_environment_tools_load :: proc(
	source: []journal.Session_Environment_Tool,
	allocator: mem.Allocator,
) -> (
	result: []MCP_Tool_Config,
	error: Config_Error,
) {
	loaded, load_error := make([]MCP_Tool_Config, len(source), allocator)
	if load_error != nil { return nil, .Allocation }
	complete := false
	defer if !complete {
		for &tool in loaded {
			delete(tool.remote_name, allocator)
			delete(tool.name, allocator)
		}
		delete(loaded, allocator)
	}
	for tool, index in source {
		if tool.remote_name == "" { return nil, .Invalid }
		if tool.name != "" && !tool_name_valid(tool.name) { return nil, .Invalid }
		if !tool.enabled && tool.name != "" { return nil, .Invalid }
		loaded[index].remote_name = environment_string_clone(tool.remote_name, allocator) or_return
		loaded[index].name = environment_string_clone(tool.name, allocator) or_return
		loaded[index].enabled = tool.enabled
	}
	complete = true
	return loaded, .None
}

// environment_string_clone copies a record string onto the allocator.
@(private, require_results)
environment_string_clone :: proc(text: string, allocator: mem.Allocator) -> (string, Config_Error) {
	cloned, clone_error := strings.clone(text, allocator)
	if clone_error != nil { return "", .Allocation }
	return cloned, .None
}

// environment_strings_clone copies a record string list onto the allocator.
@(private, require_results)
environment_strings_clone :: proc(values: []string, allocator: mem.Allocator) -> ([]string, Config_Error) {
	cloned, clone_error := make([]string, len(values), allocator)
	if clone_error != nil { return nil, .Allocation }
	complete := false
	defer if !complete {
		for value in cloned { delete(value, allocator) }
		delete(cloned, allocator)
	}
	for value, index in values {
		cloned_value, clone_error := environment_string_clone(value, allocator)
		if clone_error != .None { return nil, clone_error }
		cloned[index] = cloned_value
	}
	complete = true
	return cloned, .None
}

// session_environment_server_destroy releases one built record server.
@(private)
session_environment_server_destroy :: proc(server: ^journal.Session_Environment_Server, allocator: mem.Allocator) {
	delete(server.id, allocator)
	delete(server.executable, allocator)
	delete(server.arguments, allocator)
	delete(server.working_directory, allocator)
	for &entry in server.environment {
		delete(entry.name, allocator)
		delete(entry.value, allocator)
	}
	delete(server.environment, allocator)
	for &tool in server.tools {
		delete(tool.remote_name, allocator)
		delete(tool.name, allocator)
	}
	delete(server.tools, allocator)
	server^ = {}
}
