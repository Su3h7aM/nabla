package agent

import c "core:c/libc"
import "core:mem"
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

// MCP_Tool_Alias maps one advertised name to the remote name it stands for. The
// mapping is the allowlist: a remote tool with no alias is not exposed, so nothing
// reaches the model that the user did not name.
MCP_Tool_Alias :: struct {
	name:        string,
	remote_name: string,
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
	tools:                []MCP_Tool_Alias,
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
	for alias in config.tools {
		delete(alias.name, allocator)
		delete(alias.remote_name, allocator)
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
		id, id_ok := lua_string(L, -2, allocator)
		if !id_ok || id == "" {
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
		append(&servers, server)
		l.pop(L, 1)
	}
	return servers, .None
}

@(private)
mcp_server_load :: proc(L: ^l.State, raw_idx: c.int, id: string, allocator: mem.Allocator, out: ^MCP_Server_Config) -> Config_Error {
	if !lua_plain_table(L, raw_idx) { return .Invalid }
	idx := l.absindex(L, raw_idx)
	out^ = MCP_Server_Config {
		id                   = strings.clone(id, allocator),
		discovery_timeout    = MCP_DEFAULT_DISCOVERY_TIMEOUT,
		call_timeout         = MCP_DEFAULT_CALL_TIMEOUT,
		maximum_call_timeout = MCP_DEFAULT_MAXIMUM_CALL_TIMEOUT,
	}
	failed := true
	defer if failed { mcp_server_config_destroy(out, allocator) }
	base := l.gettop(L)
	defer l.settop(L, base)

	// Trust is a decision the user states. A server that is not trusted is never
	// started, so an absent or false flag is a configuration error rather than a
	// silently disabled server.
	lua_field(L, idx, "trusted")
	trusted, trusted_ok := lua_bool(L, -1)
	if !trusted_ok || !trusted { return .Invalid }
	l.settop(L, base)

	lua_field(L, idx, "executable")
	executable, executable_ok := lua_string(L, -1, allocator)
	if !executable_ok || !strings.has_prefix(executable, "/") {
		delete(executable, allocator)
		return .Invalid
	}
	out^.stdio.executable = executable
	l.settop(L, base)

	lua_field(L, idx, "arguments")
	if l.type(L, -1) != .NIL {
		arguments, arguments_ok := mcp_string_list(L, -1, allocator)
		if !arguments_ok { return .Invalid }
		out^.stdio.arguments = arguments
	}
	l.settop(L, base)

	lua_field(L, idx, "working_directory")
	if l.type(L, -1) != .NIL {
		directory, directory_ok := lua_string(L, -1, allocator)
		if !directory_ok { return .Invalid }
		out^.stdio.working_directory = directory
	}
	l.settop(L, base)

	lua_field(L, idx, "environment")
	if l.type(L, -1) != .NIL {
		environment, environment_ok := mcp_environment_load(L, -1, allocator)
		if !environment_ok { return .Invalid }
		out^.stdio.environment = environment
	}
	l.settop(L, base)

	lua_field(L, idx, "tools")
	if !lua_plain_table(L, -1) { return .Invalid }
	aliases, aliases_ok := mcp_tool_aliases_load(L, -1, allocator)
	if !aliases_ok { return .Invalid }
	out^.tools = aliases
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
mcp_string_list :: proc(L: ^l.State, raw_idx: c.int, allocator: mem.Allocator) -> ([]string, bool) {
	if !lua_plain_table(L, raw_idx) { return nil, false }
	index := l.absindex(L, raw_idx)
	length := int(l.rawlen(L, index))
	if length > MCP_MAX_ENTRIES { return nil, false }
	values := make([dynamic]string, 0, length, allocator)
	for position in 1 ..= length {
		l.rawgeti(L, index, l.Integer(position))
		value, value_ok := lua_string(L, -1, allocator)
		l.pop(L, 1)
		if !value_ok {
			mcp_strings_release(values, allocator)
			return nil, false
		}
		append(&values, value)
	}
	return values[:], true
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
mcp_environment_load :: proc(L: ^l.State, raw_idx: c.int, allocator: mem.Allocator) -> ([]MCP_Environment, bool) {
	index := l.absindex(L, raw_idx)
	entries := make([dynamic]MCP_Environment, 0, allocator)
	count := 0
	l.pushnil(L)
	for l.next(L, index) != 0 {
		count += 1
		if count > MCP_MAX_ENTRIES || l.type(L, -2) != .STRING {
			mcp_environment_release(entries, allocator)
			return nil, false
		}
		name, name_ok := lua_string(L, -2, allocator)
		value, value_ok := lua_string(L, -1, allocator)
		// Only the value is popped: the key has to stay for the next call to next.
		l.pop(L, 1)
		if !name_ok || !value_ok || !mcp_environment_name_valid(name) {
			delete(name, allocator)
			delete(value, allocator)
			mcp_environment_release(entries, allocator)
			return nil, false
		}
		append(&entries, MCP_Environment{name = name, value = value})
	}
	return entries[:], true
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

// mcp_tool_aliases_load reads the alias table. The advertised name is validated
// with the same rule the registry applies, so an alias that could not be registered
// is refused here where the user can see which one it was.
@(private)
mcp_tool_aliases_load :: proc(L: ^l.State, raw_idx: c.int, allocator: mem.Allocator) -> ([]MCP_Tool_Alias, bool) {
	index := l.absindex(L, raw_idx)
	aliases := make([dynamic]MCP_Tool_Alias, 0, allocator)
	count := 0
	l.pushnil(L)
	for l.next(L, index) != 0 {
		count += 1
		if count > MCP_MAX_ENTRIES || l.type(L, -2) != .STRING {
			mcp_tool_aliases_release(aliases, allocator)
			return nil, false
		}
		name, name_ok := lua_string(L, -2, allocator)
		remote_name, remote_ok := lua_string(L, -1, allocator)
		// Only the value is popped: the key has to stay for the next call to next.
		l.pop(L, 1)
		if !name_ok || !remote_ok || !tool_name_valid(name) || remote_name == "" {
			delete(name, allocator)
			delete(remote_name, allocator)
			mcp_tool_aliases_release(aliases, allocator)
			return nil, false
		}
		append(&aliases, MCP_Tool_Alias{name = name, remote_name = remote_name})
	}
	if len(aliases) == 0 {
		// An allowlist with nothing in it would expose nothing, which is never what a
		// configured server means.
		delete(aliases)
		return nil, false
	}
	return aliases[:], true
}

@(private)
mcp_tool_aliases_release :: proc(aliases: [dynamic]MCP_Tool_Alias, allocator: mem.Allocator) {
	for alias in aliases {
		delete(alias.name, allocator)
		delete(alias.remote_name, allocator)
	}
	delete(aliases)
}

// mcp_stdio_config is the transport view of a configured server. The strings are
// borrowed from config, which must outlive the call: mcp.Client clones what it keeps
// before it spawns anything.
mcp_stdio_config :: proc(config: MCP_Server_Config) -> mcp.Stdio_Config {
	environment := make([]mcp.Environment_Entry, len(config.stdio.environment), context.temp_allocator)
	for entry, index in config.stdio.environment {
		environment[index] = mcp.Environment_Entry {
			name  = entry.name,
			value = entry.value,
		}
	}
	return mcp.Stdio_Config {
		executable = config.stdio.executable,
		arguments = config.stdio.arguments,
		working_directory = config.stdio.working_directory,
		environment = environment,
	}
}

// mcp_timeout_policy is a configured server's bounds as a tool definition's policy.
// An adapted tool exposes no timeout argument to the model, so the call timeout is
// the bound and the maximum is the ceiling above it.
mcp_timeout_policy :: proc(config: MCP_Server_Config) -> Tool_Timeout_Policy {
	return {default = config.call_timeout, maximum = config.maximum_call_timeout}
}
