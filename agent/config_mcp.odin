package agent

import c "core:c/libc"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import l "vendor:lua/5.4"

import "nabla:mcp"

// MCP_DEFAULT_DISCOVERY_TIMEOUT, MCP_DEFAULT_CALL_TIMEOUT, and
// MCP_DEFAULT_MAXIMUM_CALL_TIMEOUT are what a server gets when the configuration
// states none. They live here so a server's bounds are visible in one place.
MCP_DEFAULT_DISCOVERY_TIMEOUT :: 5 * time.Second
MCP_DEFAULT_CALL_TIMEOUT :: 30 * time.Second
MCP_DEFAULT_MAXIMUM_CALL_TIMEOUT :: 120 * time.Second

// MCP_MAX_SERVERS bounds how many servers one configuration may declare, and
// MCP_MAX_ENTRIES bounds one server's arguments, environment, and aliases.
MCP_MAX_SERVERS :: 32
MCP_MAX_ENTRIES :: 256

// MCP_Environment is one variable a server is launched with. Both strings are owned.
MCP_Environment :: struct {
	name:  string,
	value: string,
}

// MCP_Tool_Config overrides one discovered remote tool. Tools are enabled under
// their remote name by default. A matching entry may disable one or replace its
// model-visible name.
MCP_Tool_Config :: struct {
	remote_name: string,
	name:        string,
	enabled:     bool,
}

// MCP_Stdio_Config is how to launch one server. Every string is owned.
MCP_Stdio_Config :: struct {
	// executable is an absolute path: a server is launched by executable and argv
	// rather than through a shell, so a relative path would depend on a search rule
	// the user did not write.
	executable:        string,
	arguments:         []string,
	working_directory: string,
	environment:       []MCP_Environment,
}

// MCP_Server_Config is one configured server. Every string is owned, and the
// timeouts are already resolved from their defaults.
MCP_Server_Config :: struct {
	id:                   string,
	stdio:                MCP_Stdio_Config,
	tools:                []MCP_Tool_Config,
	discovery_timeout:    time.Duration,
	call_timeout:         time.Duration,
	maximum_call_timeout: time.Duration,
}

mcp_server_config_destroy :: proc(config: ^MCP_Server_Config, allocator := context.allocator) {
	delete(config.id, allocator)
	delete(config.stdio.executable, allocator)
	for argument in config.stdio.arguments { delete(argument, allocator) }
	if config.stdio.arguments != nil { delete(config.stdio.arguments, allocator) }
	delete(config.stdio.working_directory, allocator)
	for entry in config.stdio.environment {
		delete(entry.name, allocator)
		delete(entry.value, allocator)
	}
	if config.stdio.environment != nil { delete(config.stdio.environment, allocator) }
	for tool in config.tools {
		delete(tool.remote_name, allocator)
		delete(tool.name, allocator)
	}
	if config.tools != nil { delete(config.tools, allocator) }
	config^ = {}
}

mcp_servers_destroy :: proc(servers: ^[dynamic]MCP_Server_Config, allocator := context.allocator) {
	if servers == nil { return }
	for &server in servers^ { mcp_server_config_destroy(&server, allocator) }
	delete(servers^)
	servers^ = nil
}

// mcp_servers_load reads the `mcp.servers` table. A server is refused rather than
// half-configured: a field that cannot be used is something the user has to see, not
// something to guess a default for.
//
// The transport is chosen by which endpoint field is present. Only stdio exists, so
// `executable` is what selects it; a later transport would bring its own field, and
// setting two would be the error.
mcp_servers_load :: proc(L: ^l.State, idx: c.int, allocator: mem.Allocator) -> ([dynamic]MCP_Server_Config, Config_Error) {
	servers: [dynamic]MCP_Server_Config
	servers.allocator = allocator
	if l.type(L, idx) == .NIL { return servers, .None }
	if !lua_plain_table(L, idx) { return {}, .Invalid }

	table := l.absindex(L, idx)
	count := 0
	l.pushnil(L)
	for {
		if l.next(L, table) == 0 { break }
		count += 1
		if count > MCP_MAX_SERVERS || l.type(L, -2) != .STRING {
			mcp_servers_destroy(&servers, allocator)
			return {}, .Invalid
		}
		id, id_error := lua_string(L, -2, allocator)
		if id_error != .None {
			mcp_servers_destroy(&servers, allocator)
			return {}, id_error
		}
		if !tool_name_valid(id) {
			delete(id, allocator)
			mcp_servers_destroy(&servers, allocator)
			return {}, .Invalid
		}
		server: MCP_Server_Config
		load_err := mcp_server_load(L, -1, id, allocator, &server)
		delete(id, allocator)
		if load_err != .None {
			mcp_server_config_destroy(&server, allocator)
			mcp_servers_destroy(&servers, allocator)
			return {}, load_err
		}
		appended := append(&servers, server)
		if appended != 1 {
			if appended == 0 { mcp_server_config_destroy(&server, allocator) }
			mcp_servers_destroy(&servers, allocator)
			return {}, .Allocation
		}
		l.pop(L, 1)
	}
	return servers, .None
}

@(private)
mcp_server_load :: proc(L: ^l.State, raw_idx: c.int, id: string, allocator: mem.Allocator, out: ^MCP_Server_Config) -> Config_Error {
	if !lua_plain_table(L, raw_idx) { return .Invalid }
	idx := l.absindex(L, raw_idx)
	server_id, server_id_error := strings.clone(id, allocator)
	if server_id_error != nil { return .Allocation }
	out^ = MCP_Server_Config {
		id                   = server_id,
		discovery_timeout    = MCP_DEFAULT_DISCOVERY_TIMEOUT,
		call_timeout         = MCP_DEFAULT_CALL_TIMEOUT,
		maximum_call_timeout = MCP_DEFAULT_MAXIMUM_CALL_TIMEOUT,
	}
	failed := true
	defer if failed { mcp_server_config_destroy(out, allocator) }
	base := l.gettop(L)
	defer l.settop(L, base)

	lua_field(L, idx, "executable")
	executable, executable_error := lua_string(L, -1, allocator)
	if executable_error != .None { return executable_error }
	if !strings.has_prefix(executable, "/") {
		delete(executable, allocator)
		return .Invalid
	}
	out^.stdio.executable = executable
	l.settop(L, base)

	lua_field(L, idx, "arguments")
	if l.type(L, -1) != .NIL {
		arguments, arguments_error := mcp_string_list(L, -1, allocator)
		if arguments_error != .None { return arguments_error }
		out^.stdio.arguments = arguments
	}
	l.settop(L, base)

	lua_field(L, idx, "working_directory")
	if l.type(L, -1) != .NIL {
		directory, directory_error := lua_string(L, -1, allocator)
		if directory_error != .None { return directory_error }
		out^.stdio.working_directory = directory
	}
	l.settop(L, base)

	lua_field(L, idx, "environment")
	if l.type(L, -1) != .NIL {
		environment, environment_error := mcp_environment_load(L, -1, allocator)
		if environment_error != .None { return environment_error }
		out^.stdio.environment = environment
	}
	l.settop(L, base)

	lua_field(L, idx, "tools")
	if l.type(L, -1) != .NIL {
		tools, tools_error := mcp_tool_configs_load(L, -1, allocator)
		if tools_error != .None { return tools_error }
		out^.tools = tools
	}
	l.settop(L, base)

	if value, present, value_ok := mcp_timeout_ms(L, idx, "discovery_timeout_ms"); !value_ok {
		return .Invalid
	} else if present {
		out^.discovery_timeout = value
	}
	if value, present, value_ok := mcp_timeout_ms(L, idx, "call_timeout_ms"); !value_ok {
		return .Invalid
	} else if present {
		out^.call_timeout = value
	}
	if value, present, value_ok := mcp_timeout_ms(L, idx, "maximum_call_timeout_ms"); !value_ok {
		return .Invalid
	} else if present {
		out^.maximum_call_timeout = value
	}
	if out^.call_timeout > out^.maximum_call_timeout { return .Invalid }

	failed = false
	return .None
}

// mcp_timeout_ms reads one optional millisecond bound. It is converted to a
// duration here, so milliseconds appear only in the configuration file.
@(private)
mcp_timeout_ms :: proc(L: ^l.State, idx: c.int, field: string) -> (value: time.Duration, present: bool, ok: bool) {
	base := l.gettop(L)
	defer l.settop(L, base)
	lua_field(L, idx, field)
	if l.type(L, -1) == .NIL { return 0, false, true }
	milliseconds, int_ok := lua_int(L, -1)
	if !int_ok || milliseconds <= 0 { return 0, true, false }
	return time.Duration(milliseconds) * time.Millisecond, true, true
}

@(private)
mcp_string_list :: proc(L: ^l.State, raw_idx: c.int, allocator: mem.Allocator) -> ([]string, Config_Error) {
	if !lua_plain_table(L, raw_idx) { return nil, .Invalid }
	index := l.absindex(L, raw_idx)
	length := int(l.rawlen(L, index))
	if length > MCP_MAX_ENTRIES { return nil, .Invalid }
	values, values_error := make([dynamic]string, 0, length, allocator)
	if values_error != nil { return nil, .Allocation }
	for position in 1 ..= length {
		l.rawgeti(L, index, l.Integer(position))
		value, value_error := lua_string(L, -1, allocator)
		l.pop(L, 1)
		if value_error != .None {
			mcp_strings_release(values, allocator)
			return nil, value_error
		}
		appended := append(&values, value)
		if appended != 1 {
			if appended == 0 { delete(value, allocator) }
			mcp_strings_release(values, allocator)
			return nil, .Allocation
		}
	}
	return values[:], .None
}

@(private)
mcp_strings_release :: proc(values: [dynamic]string, allocator: mem.Allocator) {
	for value in values { delete(value, allocator) }
	delete(values)
}

// mcp_environment_load reads a name-to-value table. Names are checked for being
// usable as an environment variable so a malformed entry is refused here rather
// than by a server that silently sees nothing.
@(private)
mcp_environment_load :: proc(L: ^l.State, raw_idx: c.int, allocator: mem.Allocator) -> ([]MCP_Environment, Config_Error) {
	index := l.absindex(L, raw_idx)
	entries, entries_error := make([dynamic]MCP_Environment, 0, allocator)
	if entries_error != nil { return nil, .Allocation }
	count := 0
	l.pushnil(L)
	for l.next(L, index) != 0 {
		count += 1
		if count > MCP_MAX_ENTRIES || l.type(L, -2) != .STRING {
			mcp_environment_release(entries, allocator)
			return nil, .Invalid
		}
		name, name_error := lua_string(L, -2, allocator)
		value, value_error := lua_string(L, -1, allocator)
		// Only the value is popped: the key has to stay for the next call to next.
		l.pop(L, 1)
		if name_error != .None { delete(value, allocator); mcp_environment_release(entries, allocator); return nil, name_error }
		if value_error != .None { delete(name, allocator); mcp_environment_release(entries, allocator); return nil, value_error }
		if !mcp_environment_name_valid(name) {
			delete(name, allocator)
			delete(value, allocator)
			mcp_environment_release(entries, allocator)
			return nil, .Invalid
		}
		entry := MCP_Environment {
			name  = name,
			value = value,
		}
		appended := append(&entries, entry)
		if appended != 1 {
			if appended == 0 {
				delete(name, allocator)
				delete(value, allocator)
			}
			mcp_environment_release(entries, allocator)
			return nil, .Allocation
		}
	}
	return entries[:], .None
}

@(private)
mcp_environment_release :: proc(entries: [dynamic]MCP_Environment, allocator: mem.Allocator) {
	for entry in entries {
		delete(entry.name, allocator)
		delete(entry.value, allocator)
	}
	delete(entries)
}

@(private)
mcp_environment_name_valid :: proc(name: string) -> bool {
	if name == "" { return false }
	for character, index in name {
		switch {
		case character == '_', character >= 'A' && character <= 'Z', character >= 'a' && character <= 'z':
		case character >= '0' && character <= '9' && index > 0:
		case:
			return false
		}
	}
	return true
}

// mcp_tool_configs_load reads optional per-tool overrides. The key is the exact
// remote name. enabled defaults to true within an entry, and name is optional.
@(private)
mcp_tool_configs_load :: proc(L: ^l.State, raw_idx: c.int, allocator: mem.Allocator) -> ([]MCP_Tool_Config, Config_Error) {
	if !lua_plain_table(L, raw_idx) { return nil, .Invalid }
	index := l.absindex(L, raw_idx)
	configs, configs_error := make([dynamic]MCP_Tool_Config, 0, allocator)
	if configs_error != nil { return nil, .Allocation }
	count := 0
	l.pushnil(L)
	for l.next(L, index) != 0 {
		count += 1
		if count > MCP_MAX_ENTRIES || l.type(L, -2) != .STRING || !lua_plain_table(L, -1) {
			mcp_tool_configs_release(configs, allocator)
			return nil, .Invalid
		}
		remote_name, remote_error := lua_string(L, -2, allocator)
		if remote_error != .None {
			l.pop(L, 1)
			mcp_tool_configs_release(configs, allocator)
			return nil, remote_error
		}
		if remote_name == "" {
			delete(remote_name, allocator)
			l.pop(L, 1)
			mcp_tool_configs_release(configs, allocator)
			return nil, .Invalid
		}
		entry := l.absindex(L, -1)
		config := MCP_Tool_Config {
			remote_name = remote_name,
			enabled     = true,
		}

		lua_field(L, entry, "enabled")
		if l.type(L, -1) != .NIL {
			enabled, enabled_ok := lua_bool(L, -1)
			if !enabled_ok {
				delete(remote_name, allocator)
				l.pop(L, 2)
				mcp_tool_configs_release(configs, allocator)
				return nil, .Invalid
			}
			config.enabled = enabled
		}
		l.pop(L, 1)

		lua_field(L, entry, "name")
		if l.type(L, -1) != .NIL {
			name, name_error := lua_string(L, -1, allocator)
			if name_error != .None {
				delete(remote_name, allocator)
				l.pop(L, 2)
				mcp_tool_configs_release(configs, allocator)
				return nil, name_error
			}
			if !tool_name_valid(name) {
				delete(name, allocator)
				delete(remote_name, allocator)
				l.pop(L, 2)
				mcp_tool_configs_release(configs, allocator)
				return nil, .Invalid
			}
			config.name = name
		}
		l.pop(L, 1)
		// Only the value is popped: the key stays for the next call to next.
		l.pop(L, 1)

		if !config.enabled && config.name != "" {
			delete(config.remote_name, allocator)
			delete(config.name, allocator)
			mcp_tool_configs_release(configs, allocator)
			return nil, .Invalid
		}
		appended := append(&configs, config)
		if appended != 1 {
			if appended == 0 {
				delete(config.remote_name, allocator)
				delete(config.name, allocator)
			}
			mcp_tool_configs_release(configs, allocator)
			return nil, .Allocation
		}
	}
	return configs[:], .None
}

@(private)
mcp_tool_configs_release :: proc(configs: [dynamic]MCP_Tool_Config, allocator: mem.Allocator) {
	for config in configs {
		delete(config.remote_name, allocator)
		delete(config.name, allocator)
	}
	delete(configs)
}

// mcp_stdio_config is the transport view of a configured server. A normal child
// inherits the launch environment; configured entries replace or add variables.
// The strings are borrowed until mcp.Client clones the configuration.
mcp_stdio_config :: proc(config: MCP_Server_Config) -> mcp.Stdio_Config {
	environment := make([dynamic]mcp.Environment_Entry, 0, context.temp_allocator)
	if inherited, err := os.environ(context.temp_allocator); err == nil {
		for pair in inherited {
			separator := strings.index_byte(pair, '=')
			if separator <= 0 { continue }
			append(&environment, mcp.Environment_Entry{name = pair[:separator], value = pair[separator + 1:]})
		}
	}
	for override in config.stdio.environment {
		replaced := false
		for &entry in environment {
			if entry.name != override.name { continue }
			entry.value = override.value
			replaced = true
			break
		}
		if !replaced { append(&environment, mcp.Environment_Entry{name = override.name, value = override.value}) }
	}
	return mcp.Stdio_Config {
		executable = config.stdio.executable,
		arguments = config.stdio.arguments,
		working_directory = config.stdio.working_directory,
		environment = environment[:],
	}
}

// mcp_timeout_policy is a configured server's bounds as a tool definition's policy.
// An adapted tool exposes no timeout argument to the model, so the call timeout is
// the bound and the maximum is the ceiling above it.
mcp_timeout_policy :: proc(config: MCP_Server_Config) -> Tool_Timeout_Policy {
	return {default = config.call_timeout, maximum = config.maximum_call_timeout}
}
