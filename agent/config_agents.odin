package agent

import c "core:c"
import "core:mem"
import "core:slice"
import "core:strings"
import lua "vendor:lua/5.4"

// ACP_Agent_Config is one configured ACP agent program. Every string is owned by the
// allocator the configuration was read with.
ACP_Agent_Config :: struct {
	name:        string,
	command:     string,
	arguments:   []string,
	description: string,
}

// ACP_Agent_Config_Destroy releases one configuration read from the `agents` table.
ACP_Agent_Config_Destroy :: proc(config: ^ACP_Agent_Config, allocator := context.allocator) {
	acp_agent_config_destroy(config, allocator)
}

// ACP_Agent_Configs_Destroy releases a list read from the `agents` table.
ACP_Agent_Configs_Destroy :: proc(agents: []ACP_Agent_Config, allocator := context.allocator) {
	for &agent in agents { acp_agent_config_destroy(&agent, allocator) }
	if agents != nil { delete(agents, allocator) }
}

acp_agent_config_destroy :: proc(config: ^ACP_Agent_Config, allocator := context.allocator) {
	delete(config.name, allocator)
	delete(config.command, allocator)
	for argument in config.arguments { delete(argument, allocator) }
	if config.arguments != nil { delete(config.arguments, allocator) }
	delete(config.description, allocator)
	config^ = {}
}

acp_agents_destroy :: proc(agents: ^[dynamic]ACP_Agent_Config, allocator := context.allocator) {
	if agents == nil { return }
	for &agent in agents^ { acp_agent_config_destroy(&agent, allocator) }
	delete(agents^)
	agents^ = nil
}

// acp_agents_load reads the `agents` table, which is keyed by the name a caller uses to
// select the program. An entry is refused rather than half-configured: a field that
// cannot be used is something the user has to see, not something to guess a default for.
// The result is sorted by name so the order is deterministic.
@(require_results)
acp_agents_load :: proc(state: ^lua.State, idx: c.int, allocator: mem.Allocator) -> ([dynamic]ACP_Agent_Config, Config_Error) {
	agents: [dynamic]ACP_Agent_Config
	agents.allocator = allocator
	if lua.type(state, idx) == .NIL { return agents, .None }
	if !lua_plain_table(state, idx) { return {}, .Invalid }

	table := lua.absindex(state, idx)
	lua.pushnil(state)
	for {
		if lua.next(state, table) == 0 { break }
		if lua.type(state, -2) != .STRING {
			acp_agents_destroy(&agents, allocator)
			return {}, .Invalid
		}
		name, name_error := lua_string(state, -2, allocator)
		if name_error != .None {
			acp_agents_destroy(&agents, allocator)
			return {}, name_error
		}
		if name == "" {
			delete(name, allocator)
			acp_agents_destroy(&agents, allocator)
			return {}, .Invalid
		}
		agent: ACP_Agent_Config
		load_error := acp_agent_load(state, -1, name, allocator, &agent)
		delete(name, allocator)
		if load_error != .None {
			acp_agent_config_destroy(&agent, allocator)
			acp_agents_destroy(&agents, allocator)
			return {}, load_error
		}
		appended := append(&agents, agent)
		if appended != 1 {
			if appended == 0 { acp_agent_config_destroy(&agent, allocator) }
			acp_agents_destroy(&agents, allocator)
			return {}, .Allocation
		}
		lua.pop(state, 1)
	}
	slice.sort_by_key(agents[:], proc(agent: ACP_Agent_Config) -> string { return agent.name })
	return agents, .None
}

@(private, require_results)
acp_agent_load :: proc(state: ^lua.State, raw_idx: c.int, name: string, allocator: mem.Allocator, out: ^ACP_Agent_Config) -> Config_Error {
	if !lua_plain_table(state, raw_idx) { return .Invalid }
	idx := lua.absindex(state, raw_idx)
	fields_error := acp_agent_fields_known(state, idx)
	if fields_error != .None { return fields_error }
	name_copy, name_error := strings.clone(name, allocator)
	if name_error != nil { return .Allocation }
	out^ = ACP_Agent_Config {
		name = name_copy,
	}
	failed := true
	defer if failed { acp_agent_config_destroy(out, allocator) }
	base := lua.gettop(state)
	defer lua.settop(state, base)

	lua_field(state, idx, "command")
	command, command_error := lua_string(state, -1, allocator)
	if command_error != .None { return command_error }
	if command == "" {
		delete(command, allocator)
		return .Invalid
	}
	out^.command = command
	lua.settop(state, base)

	lua_field(state, idx, "arguments")
	if lua.type(state, -1) != .NIL {
		arguments, arguments_error := lua_string_list(state, -1, allocator)
		if arguments_error != .None { return arguments_error }
		out^.arguments = arguments
	}
	lua.settop(state, base)

	lua_field(state, idx, "description")
	if lua.type(state, -1) != .NIL {
		description, description_error := lua_string(state, -1, allocator)
		if description_error != .None { return description_error }
		out^.description = description
	}
	lua.settop(state, base)

	failed = false
	return .None
}

// acp_agent_fields_known refuses an entry that carries a key the reader does not know,
// so a misspelled field is reported rather than ignored.
@(private, require_results)
acp_agent_fields_known :: proc(state: ^lua.State, raw_idx: c.int) -> Config_Error {
	index := lua.absindex(state, raw_idx)
	base := lua.gettop(state)
	defer lua.settop(state, base)
	lua.pushnil(state)
	for lua.next(state, index) != 0 {
		key, key_error := lua_string(state, -2, context.temp_allocator)
		lua.pop(state, 1)
		if key_error != .None { return key_error }
		switch key {
		case "command", "arguments", "description":
		case:
			return .Invalid
		}
	}
	return .None
}
