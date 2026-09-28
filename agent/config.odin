package agent

import c "core:c/libc"
import "core:mem"
import "core:os"
import "core:strings"
import lua "vendor:lua/5.4"

// CONFIG_INSTRUCTIONS bounds how long the user's configuration Lua code may run.
// Configuration is evaluated on a harness thread, so this bound keeps that thread
// responsive; it caps nothing the model asked for.
CONFIG_INSTRUCTIONS :: 200000

Config_Error :: enum {
	None,
	Missing,
	Read,
	Lua,
	Root,
	Invalid,
	Allocation,
}

Harness_Options :: struct {
	disable_project_instructions: bool,
	// acp_agents is owned by the loaded configuration for the process lifetime.
	acp_agents:                   []ACP_Agent_Config,
}

config_error_text :: proc(err: Config_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Missing:
		return "missing config"
	case .Read:
		return "cannot read config"
	case .Lua:
		return "Lua execution failed"
	case .Root:
		return "config must return a plain table"
	case .Invalid:
		return "invalid config value"
	case .Allocation:
		return "config storage could not be allocated"
	}
	return "invalid config"
}

lua_limit_hook :: proc "c" (state: ^lua.State, ar: ^lua.Debug) {
	lua.pushstring(state, "configuration instruction limit exceeded")
	lua.error(state)
}

lua_string :: proc(state: ^lua.State, idx: c.int, allocator: mem.Allocator) -> (string, Config_Error) {
	if lua.type(state, idx) != .STRING { return "", .Invalid }
	length: c.size_t
	text := lua.tolstring(state, idx, &length)
	if text == nil { return "", .Invalid }
	value, clone_error := strings.clone(string(text), allocator)
	if clone_error != nil { return "", .Allocation }
	return value, .None
}

lua_bool :: proc(state: ^lua.State, idx: c.int) -> (bool, bool) {
	if lua.type(state, idx) != .BOOLEAN { return false, false }
	return lua.toboolean(state, idx) != false, true
}

lua_int :: proc(state: ^lua.State, idx: c.int) -> (int, bool) {
	if lua.type(state, idx) != .NUMBER { return 0, false }
	ok: b32
	value := lua.tointeger(state, idx, &ok)
	if !ok || value < 0 || value > lua.Integer(1 << 30) { return 0, false }
	return int(value), true
}

// lua_field pushes the named field, or nil when the value at idx is not a table.
// Indexing a non-table would raise a Lua error, which longjmps out of the Odin frame
// that called it; reading a missing field is the same condition without the hazard.
lua_field :: proc(state: ^lua.State, idx: c.int, name: string) -> c.int {
	if lua.type(state, idx) != .TABLE {
		lua.pushnil(state)
		return 0
	}
	name_c, name_err := strings.clone_to_cstring(name, context.temp_allocator)
	if name_err != nil {
		lua.pushnil(state)
		return 0
	}
	defer delete(name_c, context.temp_allocator)
	return lua.getfield(state, idx, name_c)
}

lua_plain_table :: proc(state: ^lua.State, idx: c.int) -> bool {
	if lua.type(state, idx) != .TABLE { return false }
	return lua.getmetatable(state, idx) == 0
}

load_model :: proc(state: ^lua.State, raw_idx: c.int, provider_id, model_id: string, allocator: mem.Allocator, out: ^Catalog_Model_Source) -> Config_Error {
	if !lua_plain_table(state, raw_idx) { return .Invalid }
	idx := lua.absindex(state, raw_idx)
	model_id_copy, model_id_copy_error := strings.clone(model_id, allocator)
	if model_id_copy_error != nil { return .Allocation }
	out^.id = model_id_copy
	input_modalities: [dynamic]string
	input_modalities.allocator = allocator
	output_modalities: [dynamic]string
	output_modalities.allocator = allocator
	thinking_levels: [dynamic]string
	thinking_levels.allocator = allocator
	failed := true
	defer if failed {
		catalog_model_source_destroy(out, allocator)
		config_strings_destroy(&input_modalities, allocator)
		config_strings_destroy(&output_modalities, allocator)
		config_strings_destroy(&thinking_levels, allocator)
	}
	base := lua.gettop(state)
	defer lua.settop(state, base)
	lua_field(state, idx, "disabled")
	if lua.type(state, -1) != .NIL {
		value, ok := lua_bool(state, -1)
		if !ok { return .Invalid }
		out^.disabled = value
		out^.disabled_present = true
	}
	lua.settop(state, base)
	if out^.disabled_present && out^.disabled {
		failed = false
		return .None
	}
	lua_field(state, idx, "api")
	if lua.type(state, -1) != .NIL {
		value, value_error := lua_string(state, -1, allocator)
		if value_error != .None { return value_error }
		out^.api = value
		out^.api_present = true
	}
	lua.settop(state, base)
	lua_field(state, idx, "display_name")
	if lua.type(state, -1) != .NIL {
		value, value_error := lua_string(state, -1, allocator)
		if value_error != .None { return value_error }
		out^.display_name = value
		out^.display_name_present = true
	}
	lua.settop(state, base)
	lua_field(state, idx, "context_window")
	if lua.type(state, -1) != .NIL {
		value, ok := lua_int(state, -1)
		if !ok { return .Invalid }
		out^.context_window = value
		out^.context_window_present = true
	}
	lua.settop(state, base)
	lua_field(state, idx, "max_output_tokens")
	if lua.type(state, -1) != .NIL {
		value, ok := lua_int(state, -1)
		if !ok { return .Invalid }
		out^.max_output_tokens = value
		out^.max_output_tokens_present = true
	}
	lua.settop(state, base)
	lua_field(state, idx, "tools")
	if lua.type(state, -1) != .NIL {
		value, ok := lua_bool(state, -1)
		if !ok { return .Invalid }
		out^.tools = value
		out^.tools_present = true
	}
	lua.settop(state, base)
	lua_field(state, idx, "input_modalities")
	if lua.type(state, -1) != .NIL {
		if !lua_plain_table(state, -1) { return .Invalid }
		for i in 1 ..= int(lua.rawlen(state, -1)) {
			lua.rawgeti(state, -1, lua.Integer(i))
			value, value_error := lua_string(state, -1, allocator)
			if value_error != .None { return value_error }
			appended := append(&input_modalities, value)
			if appended != 1 {
				if appended == 0 { delete(value, allocator) }
				return .Allocation
			}
			lua.pop(state, 1)
		}
		out^.input_modalities = input_modalities[:]
		out^.input_modalities_present = true
		// Ownership moved to out; the failure cleanup below must not free it twice.
		input_modalities = nil
	}
	lua.settop(state, base)
	lua_field(state, idx, "output_modalities")
	if lua.type(state, -1) != .NIL {
		if !lua_plain_table(state, -1) { return .Invalid }
		for i in 1 ..= int(lua.rawlen(state, -1)) {
			lua.rawgeti(state, -1, lua.Integer(i))
			value, value_error := lua_string(state, -1, allocator)
			if value_error != .None { return value_error }
			appended := append(&output_modalities, value)
			if appended != 1 {
				if appended == 0 { delete(value, allocator) }
				return .Allocation
			}
			lua.pop(state, 1)
		}
		out^.output_modalities = output_modalities[:]
		out^.output_modalities_present = true
		// Ownership moved to out; the failure cleanup below must not free it twice.
		output_modalities = nil
	}
	lua.settop(state, base)
	lua_field(state, idx, "thinking")
	if lua.type(state, -1) != .NIL {
		out^.thinking.present = true
		if lua.type(state, -1) == .BOOLEAN {
			out^.thinking.supported = lua.toboolean(state, -1) != false
			out^.thinking.supported_present = true
			if !out^.thinking.supported { out^.thinking.blocked = true }
		} else if lua_plain_table(state, -1) {
			thinking_base := lua.gettop(state)
			lua_field(state, -1, "supported")
			if lua.type(state, -1) != .NIL {
				value, ok := lua_bool(state, -1)
				if !ok { return .Invalid }
				out^.thinking.supported = value
				out^.thinking.supported_present = true
				if !out^.thinking.supported { out^.thinking.blocked = true }
			}
			lua.settop(state, thinking_base)
			lua_field(state, -1, "toggle")
			if lua.type(state, -1) != .NIL {
				value, ok := lua_bool(state, -1)
				if !ok { return .Invalid }
				out^.thinking.toggle = value
				out^.thinking.toggle_present = true
			}
			lua.settop(state, thinking_base)
			lua_field(state, -1, "levels")
			if lua.type(state, -1) != .NIL {
				if !lua_plain_table(state, -1) { return .Invalid }
				for i in 1 ..= int(lua.rawlen(state, -1)) {
					lua.rawgeti(state, -1, lua.Integer(i))
					value, value_error := lua_string(state, -1, allocator)
					if value_error != .None { return value_error }
					appended := append(&thinking_levels, value)
					if appended != 1 {
						if appended == 0 { delete(value, allocator) }
						return .Allocation
					}
					lua.pop(state, 1)
				}
				out^.thinking.levels = thinking_levels[:]
				out^.thinking.levels_present = true
				// Ownership moved to out; the failure cleanup below must not free it twice.
				thinking_levels = nil
			}
			lua.settop(state, thinking_base)
		} else {
			return .Invalid
		}
	}
	failed = false
	return .None
}

load_provider :: proc(state: ^lua.State, raw_idx: c.int, provider_id: string, allocator: mem.Allocator, out: ^Catalog_Provider_Source) -> Config_Error {
	if !lua_plain_table(state, raw_idx) { return .Invalid }
	idx := lua.absindex(state, raw_idx)
	id, id_error := strings.clone(provider_id, allocator)
	if id_error != nil { return .Allocation }
	out^.id = id
	models: [dynamic]Catalog_Model_Source
	models.allocator = allocator
	failed := true
	// On failure the local list still owns every model, so it is released before
	// the provider, whose model field is not assigned until the end.
	defer if failed {
		for &model in models { catalog_model_source_destroy(&model, allocator) }
		delete(models)
		catalog_provider_source_destroy(out, allocator)
	}
	base := lua.gettop(state)
	defer lua.settop(state, base)
	lua_field(state, idx, "base_url")
	if lua.type(state, -1) != .NIL {
		value, value_error := lua_string(state, -1, allocator)
		if value_error != .None { return value_error }
		out^.base_url = value
		out^.base_url_present = true
	}
	lua.settop(state, base)
	lua_field(state, idx, "api")
	if lua.type(state, -1) != .NIL {
		value, value_error := lua_string(state, -1, allocator)
		if value_error != .None { return value_error }
		out^.api = value
		out^.api_present = true
	}
	lua.settop(state, base)
	lua_field(state, idx, "transport")
	if lua.type(state, -1) != .NIL {
		value, value_error := lua_string(state, -1, allocator)
		if value_error != .None { return value_error }
		switch value {
		case "http":
			out^.transport = .HTTP
		case "websocket":
			out^.transport = .WebSocket
		case "auto":
			out^.transport = .Auto
		case:
			delete(value, allocator)
			return .Invalid
		}
		delete(value, allocator)
		out^.transport_present = true
	}
	lua.settop(state, base)
	lua_field(state, idx, "api_key")
	if lua.type(state, -1) != .NIL {
		value, value_error := lua_string(state, -1, allocator)
		if value_error != .None { return value_error }
		out^.api_key = value
		out^.api_key_present = true
	}
	lua.settop(state, base)
	lua_field(state, idx, "models")
	if lua.type(state, -1) != .NIL {
		if !lua_plain_table(state, -1) { return .Invalid }
		models_idx := lua.absindex(state, -1)
		lua.pushnil(state)
		for {
			if lua.next(state, models_idx) == 0 { break }
			if lua.type(state, -2) != .STRING { return .Invalid }
			model_id, model_id_error := lua_string(state, -2, allocator)
			if model_id_error != .None { return model_id_error }
			model: Catalog_Model_Source
			err := load_model(state, -1, provider_id, model_id, allocator, &model)
			delete(model_id, allocator)
			if err != .None {
				catalog_model_source_destroy(&model, allocator)
				return err
			}
			appended := append(&models, model)
			if appended != 1 {
				if appended == 0 { catalog_model_source_destroy(&model, allocator) }
				return .Allocation
			}
			lua.pop(state, 1)
		}
		out^.models = models[:]
	}
	failed = false
	return .None
}

load_harness_options :: proc(state: ^lua.State, idx: c.int) -> (Harness_Options, Config_Error) {
	options: Harness_Options
	if lua.type(state, idx) == .NIL { return options, .None }
	if !lua_plain_table(state, idx) { return {}, .Invalid }
	base := lua.gettop(state)
	defer lua.settop(state, base)
	lua_field(state, idx, "project")
	if lua.type(state, -1) != .NIL {
		project, ok := lua_bool(state, -1)
		if !ok { return {}, .Invalid }
		options.disable_project_instructions = !project
	}
	return options, .None
}

load_lua_config_full :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	[dynamic]Catalog_Provider_Source,
	Harness_Options,
	[dynamic]MCP_Server_Config,
	Config_Error,
) {
	if path == "" { return {}, {}, {}, .None }
	// A missing file is a valid setup: no providers, default options. Only a
	// file that exists but cannot be read is an error.
	if info, stat_err := os.stat(path, context.temp_allocator); stat_err != nil {
		if stat_err == os.General_Error.Not_Exist { return {}, {}, {}, .Missing }
		return {}, {}, {}, .Read
	} else if info.type != .Regular {
		return {}, {}, {}, .Read
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil { return {}, {}, {}, .Read }
	state := lua.L_newstate()
	if state == nil { return {}, {}, {}, .Lua }
	defer lua.close(state)
	lua.sethook(state, lua_limit_hook, lua.MASKCOUNT, CONFIG_INSTRUCTIONS)
	if lua.L_loadbuffer(state, raw_data(data), c.size_t(len(data)), "@nabla-config", "t") != .OK { return {}, {}, {}, .Lua }
	if lua.pcall(state, 0, 1, 0) != 0 { return {}, {}, {}, .Lua }
	if !lua_plain_table(state, -1) { return {}, {}, {}, .Root }
	base := lua.gettop(state)
	lua_field(state, -1, "instructions")
	options, options_err := load_harness_options(state, -1)
	if options_err != .None { return {}, {}, {}, options_err }
	lua.settop(state, base)
	result: [dynamic]Catalog_Provider_Source
	lua_field(state, -1, "providers")
	if lua.type(state, -1) != .NIL {
		if !lua_plain_table(state, -1) { return {}, {}, {}, .Invalid }
		result.allocator = allocator
		providers_idx := lua.absindex(state, -1)
		lua.pushnil(state)
		for {
			if lua.next(state, providers_idx) == 0 { break }
			if lua.type(state, -2) != .STRING {
				catalog_sources_destroy(&result, allocator)
				return {}, {}, {}, .Invalid
			}
			provider_id, provider_id_error := lua_string(state, -2, allocator)
			if provider_id_error != .None {
				catalog_sources_destroy(&result, allocator)
				return {}, {}, {}, provider_id_error
			}
			provider: Catalog_Provider_Source
			err := load_provider(state, -1, provider_id, allocator, &provider)
			delete(provider_id, allocator)
			if err != .None {
				catalog_provider_source_destroy(&provider, allocator)
				catalog_sources_destroy(&result, allocator)
				return {}, {}, {}, err
			}
			appended := append(&result, provider)
			if appended != 1 {
				if appended == 0 { catalog_provider_source_destroy(&provider, allocator) }
				catalog_sources_destroy(&result, allocator)
				return {}, {}, {}, .Allocation
			}
			lua.settop(state, providers_idx + 1)
		}
	}
	lua.settop(state, base)
	servers, servers_err := load_mcp_servers_from(state, -1, allocator)
	if servers_err != .None {
		catalog_sources_destroy(&result, allocator)
		return {}, {}, {}, servers_err
	}
	lua.settop(state, base)
	acp_agents, acp_agents_err := load_acp_agents_from(state, -1, allocator)
	if acp_agents_err != .None {
		catalog_sources_destroy(&result, allocator)
		mcp_servers_destroy(&servers, allocator)
		return {}, {}, {}, acp_agents_err
	}
	options.acp_agents = acp_agents[:]
	return result, options, servers, .None
}

// load_mcp_servers_from reads the `mcp` table, which holds the `servers` table. The
// state is reset by the caller.
@(private)
load_mcp_servers_from :: proc(state: ^lua.State, root_idx: c.int, allocator: mem.Allocator) -> ([dynamic]MCP_Server_Config, Config_Error) {
	base := lua.gettop(state)
	defer lua.settop(state, base)
	lua_field(state, root_idx, "mcp")
	if lua.type(state, -1) == .NIL { return {}, .None }
	if !lua_plain_table(state, -1) { return {}, .Invalid }
	mcp_idx := lua.absindex(state, -1)
	lua_field(state, mcp_idx, "servers")
	if lua.type(state, -1) == .NIL { return {}, .None }
	return mcp_servers_load(state, -1, allocator)
}

// load_acp_agents_from reads the `agents` table. The state is reset by the caller.
@(private)
load_acp_agents_from :: proc(state: ^lua.State, root_idx: c.int, allocator: mem.Allocator) -> ([dynamic]ACP_Agent_Config, Config_Error) {
	base := lua.gettop(state)
	defer lua.settop(state, base)
	lua_field(state, root_idx, "agents")
	return acp_agents_load(state, -1, allocator)
}

load_lua_config :: proc(path: string, allocator := context.allocator) -> ([dynamic]Catalog_Provider_Source, Config_Error) {
	if path == "" { return {}, .None }
	if info, stat_err := os.stat(path, context.temp_allocator); stat_err != nil {
		if stat_err == os.General_Error.Not_Exist { return {}, .Missing }
		return {}, .Read
	} else if info.type != .Regular {
		return {}, .Read
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil { return {}, .Read }
	state := lua.L_newstate()
	if state == nil { return {}, .Lua }
	defer lua.close(state)
	lua.sethook(state, lua_limit_hook, lua.MASKCOUNT, CONFIG_INSTRUCTIONS)
	if lua.L_loadbuffer(state, raw_data(data), c.size_t(len(data)), "@nabla-config", "t") != .OK { return {}, .Lua }
	if lua.pcall(state, 0, 1, 0) != 0 { return {}, .Lua }
	if !lua_plain_table(state, -1) { return {}, .Root }
	base := lua.gettop(state)
	lua_field(state, -1, "providers")
	if lua.type(state, -1) == .NIL { return {}, .None }
	if !lua_plain_table(state, -1) { return {}, .Invalid }
	result: [dynamic]Catalog_Provider_Source
	result.allocator = allocator
	providers_idx := lua.absindex(state, -1)
	lua.pushnil(state)
	for {
		if lua.next(state, providers_idx) == 0 { break }
		if lua.type(state, -2) != .STRING {
			catalog_sources_destroy(&result, allocator)
			return {}, .Invalid
		}
		provider_id, provider_id_error := lua_string(state, -2, allocator)
		if provider_id_error != .None {
			catalog_sources_destroy(&result, allocator)
			return {}, provider_id_error
		}
		provider: Catalog_Provider_Source
		err := load_provider(state, -1, provider_id, allocator, &provider)
		delete(provider_id, allocator)
		if err != .None {
			catalog_provider_source_destroy(&provider, allocator)
			catalog_sources_destroy(&result, allocator)
			return {}, err
		}
		appended := append(&result, provider)
		if appended != 1 {
			if appended == 0 { catalog_provider_source_destroy(&provider, allocator) }
			catalog_sources_destroy(&result, allocator)
			return {}, .Allocation
		}
		lua.settop(state, providers_idx + 1)
	}
	lua.settop(state, base)
	return result, .None
}

// config_env_reference reports whether a configured value names an environment
// variable. `${NAME}` is the reference syntax configuration values already use
// for environment variables, and it is unambiguous: a literal secret never
// matches it. The name must be a plain identifier.
config_env_reference :: proc(value: string) -> (name: string, ok: bool) {
	if len(value) < 4 || value[0] != '$' || value[1] != '{' || value[len(value) - 1] != '}' { return "", false }
	name = value[2:len(value) - 1]
	for character, index in name {
		switch {
		case character == '_', (character >= 'A' && character <= 'Z'), (character >= 'a' && character <= 'z'):
		case (character >= '0' && character <= '9') && index > 0:
		case:
			return "", false
		}
	}
	return name, true
}

// config_resolve_credential resolves a configured credential into a secret the
// caller owns. A value that names an existing environment variable is that
// variable's value, whether or not it is written as a `${NAME}` reference;
// anything else is the secret itself. A name that exists but resolves to empty
// fails, so a miswired reference can never send the variable's name as a key.
// Resolution happens at use rather than at load, so the catalog never holds a
// secret and no state file can.
config_resolve_credential :: proc(value: string, allocator := context.allocator) -> (secret: string, ok: bool) {
	if name, reference := config_env_reference(value); reference {
		found: bool
		secret, found = os.lookup_env(name, allocator)
		if !found || secret == "" { return "", false }
		return secret, true
	}
	if value == "" { return "", false }
	if found_value, found := os.lookup_env(value, allocator); found {
		if found_value == "" { return "", false }
		return found_value, true
	}
	literal, clone_error := strings.clone(value, allocator)
	if clone_error != nil { return "", false }
	return literal, true
}


// config_strings_destroy frees a loader-local string accumulator. Catalog fields
// are released by catalog_strings_destroy, which takes a slice.
config_strings_destroy :: proc(values: ^[dynamic]string, allocator: mem.Allocator) {
	if values == nil { return }
	for value in values^ { delete(value, allocator) }
	delete(values^)
	values^ = nil
}
