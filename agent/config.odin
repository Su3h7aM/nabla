package agent

import c "core:c/libc"
import "core:mem"
import "core:os"
import "core:strings"
import l "vendor:lua/5.4"

CONFIG_MAX_BYTES :: 1024 * 1024
CONFIG_MAX_ENTRIES :: 4096
CONFIG_MAX_LEVELS :: 64
CONFIG_MAX_DEPTH :: 16
CONFIG_INSTRUCTIONS :: 200000

Config_Error :: enum {
	None,
	Missing,
	Read,
	Lua,
	Root,
	Invalid,
}

Harness_Options :: struct {
	disable_project_instructions: bool,
}

config_error_text :: proc(e: Config_Error) -> string {
	switch e {
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
	}
	return "invalid config"
}

lua_limit_hook :: proc "c" (L: ^l.State, ar: ^l.Debug) {
	l.pushstring(L, "configuration instruction limit exceeded")
	l.error(L)
}

lua_string :: proc(L: ^l.State, idx: c.int, allocator: mem.Allocator) -> (string, bool) {
	if l.type(L, idx) != .STRING { return "", false }
	n: c.size_t
	p := l.tolstring(L, idx, &n)
	if p == nil || n > c.size_t(CONFIG_MAX_BYTES) { return "", false }
	return strings.clone(string(p), allocator), true
}

lua_bool :: proc(L: ^l.State, idx: c.int) -> (bool, bool) {
	if l.type(L, idx) != .BOOLEAN { return false, false }
	return l.toboolean(L, idx) != false, true
}

lua_int :: proc(L: ^l.State, idx: c.int) -> (int, bool) {
	if l.type(L, idx) != .NUMBER { return 0, false }
	ok: b32
	n := l.tointeger(L, idx, &ok)
	if !ok || n < 0 || n > l.Integer(1 << 30) { return 0, false }
	return int(n), true
}

// lua_field pushes the named field, or nil when the value at idx is not a table.
// Indexing a non-table would raise a Lua error, which longjmps out of the Odin frame
// that called it; reading a missing field is the same condition without the hazard.
lua_field :: proc(L: ^l.State, idx: c.int, name: string) -> c.int {
	if l.type(L, idx) != .TABLE {
		l.pushnil(L)
		return 0
	}
	name_c, name_err := strings.clone_to_cstring(name, context.temp_allocator)
	if name_err != nil {
		l.pushnil(L)
		return 0
	}
	defer delete(name_c, context.temp_allocator)
	return l.getfield(L, idx, name_c)
}

lua_plain_table :: proc(L: ^l.State, idx: c.int) -> bool {
	if l.type(L, idx) != .TABLE { return false }
	return l.getmetatable(L, idx) == 0
}

load_model :: proc(L: ^l.State, raw_idx: c.int, provider_id, model_id: string, allocator: mem.Allocator, out: ^Catalog_Model_Source) -> Config_Error {
	if !lua_plain_table(L, raw_idx) { return .Invalid }
	idx := l.absindex(L, raw_idx)
	out^.id = strings.clone(model_id, allocator)
	input_modalities: [dynamic]string
	input_modalities.allocator = allocator
	output_modalities: [dynamic]string
	output_modalities.allocator = allocator
	thinking_levels: [dynamic]string
	thinking_levels.allocator = allocator
	failed := true
	defer if failed { catalog_model_source_destroy(out, allocator); config_strings_destroy(&input_modalities, allocator); config_strings_destroy(&output_modalities, allocator); config_strings_destroy(&thinking_levels, allocator) }
	base := l.gettop(L)
	defer l.settop(L, base)
	lua_field(L, idx, "disabled")
	if l.type(L, -1) != .NIL {
		value, ok := lua_bool(L, -1)
		if !ok { return .Invalid }
		out^.disabled = value
		out^.disabled_present = true
	}
	l.settop(L, base)
	if out^.disabled_present && out^.disabled {
		failed = false
		return .None
	}
	l.settop(L, base)
	lua_field(L, idx, "api")
	if l.type(L, -1) != .NIL {
		value, ok := lua_string(L, -1, allocator)
		if !ok { return .Invalid }
		out^.api = value
		out^.api_present = true
	}
	l.settop(L, base)
	lua_field(L, idx, "display_name")
	if l.type(L, -1) != .NIL {
		value, ok := lua_string(L, -1, allocator)
		if !ok { return .Invalid }
		out^.display_name = value
		out^.display_name_present = true
	}
	l.settop(L, base)
	lua_field(L, idx, "context_window")
	if l.type(L, -1) != .NIL {
		value, ok := lua_int(L, -1)
		if !ok { return .Invalid }
		out^.context_window = value
		out^.context_window_present = true
	}
	l.settop(L, base)
	lua_field(L, idx, "max_output_tokens")
	if l.type(L, -1) != .NIL {
		value, ok := lua_int(L, -1)
		if !ok { return .Invalid }
		out^.max_output_tokens = value
		out^.max_output_tokens_present = true
	}
	l.settop(L, base)
	lua_field(L, idx, "tools")
	if l.type(L, -1) != .NIL {
		value, ok := lua_bool(L, -1)
		if !ok { return .Invalid }
		out^.tools = value
		out^.tools_present = true
	}
	l.settop(L, base)
	lua_field(L, idx, "input_modalities")
	if l.type(L, -1) != .NIL {
		if !lua_plain_table(L, -1) || l.rawlen(L, -1) > l.Unsigned(CONFIG_MAX_LEVELS) { return .Invalid }
		for i in 1 ..= int(l.rawlen(L, -1)) {
			l.rawgeti(L, -1, l.Integer(i))
			value, ok := lua_string(L, -1, allocator)
			if !ok { return .Invalid }
			append(&input_modalities, value)
			l.pop(L, 1)
		}
		out^.input_modalities = input_modalities[:]
		out^.input_modalities_present = true
		// Ownership moved to out; the failure cleanup below must not free it twice.
		input_modalities = nil
	}
	l.settop(L, base)
	lua_field(L, idx, "output_modalities")
	if l.type(L, -1) != .NIL {
		if !lua_plain_table(L, -1) || l.rawlen(L, -1) > l.Unsigned(CONFIG_MAX_LEVELS) { return .Invalid }
		for i in 1 ..= int(l.rawlen(L, -1)) {
			l.rawgeti(L, -1, l.Integer(i))
			value, ok := lua_string(L, -1, allocator)
			if !ok { return .Invalid }
			append(&output_modalities, value)
			l.pop(L, 1)
		}
		out^.output_modalities = output_modalities[:]
		out^.output_modalities_present = true
		// Ownership moved to out; the failure cleanup below must not free it twice.
		output_modalities = nil
	}
	l.settop(L, base)
	lua_field(L, idx, "thinking")
	if l.type(L, -1) != .NIL {
		out^.thinking.present = true
		if l.type(L, -1) == .BOOLEAN {
			out^.thinking.supported = l.toboolean(L, -1) != false
			out^.thinking.supported_present = true
			if !out^.thinking.supported { out^.thinking.blocked = true }
		} else if lua_plain_table(L, -1) {
			tbase := l.gettop(L)
			lua_field(L, -1, "supported")
			if l.type(L, -1) != .NIL {
				value, ok := lua_bool(L, -1)
				if !ok { return .Invalid }
				out^.thinking.supported = value
				out^.thinking.supported_present = true
				if !out^.thinking.supported { out^.thinking.blocked = true }
			}
			l.settop(L, tbase)
			lua_field(L, -1, "toggle")
			if l.type(L, -1) != .NIL {
				value, ok := lua_bool(L, -1)
				if !ok { return .Invalid }
				out^.thinking.toggle = value
				out^.thinking.toggle_present = true
			}
			l.settop(L, tbase)
			lua_field(L, -1, "levels")
			if l.type(L, -1) != .NIL {
				if !lua_plain_table(L, -1) { return .Invalid }
				if l.rawlen(L, -1) > l.Unsigned(CONFIG_MAX_LEVELS) { return .Invalid }
				for i in 1 ..= int(l.rawlen(L, -1)) {
					l.rawgeti(L, -1, l.Integer(i))
					value, ok := lua_string(L, -1, allocator)
					if !ok { return .Invalid }
					append(&thinking_levels, value)
					l.pop(L, 1)
				}
				out^.thinking.levels = thinking_levels[:]
				out^.thinking.levels_present = true
				// Ownership moved to out; the failure cleanup below must not free it twice.
				thinking_levels = nil
			}
			l.settop(L, tbase)
		} else {
			return .Invalid
		}
	}
	failed = false
	return .None
}

load_provider :: proc(L: ^l.State, raw_idx: c.int, provider_id: string, allocator: mem.Allocator, out: ^Catalog_Provider_Source) -> Config_Error {
	if !lua_plain_table(L, raw_idx) { return .Invalid }
	idx := l.absindex(L, raw_idx)
	out^.id = strings.clone(provider_id, allocator)
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
	base := l.gettop(L)
	defer l.settop(L, base)
	lua_field(L, idx, "base_url")
	if l.type(L, -1) != .NIL {
		value, ok := lua_string(L, -1, allocator)
		if !ok { return .Invalid }
		out^.base_url = value
		out^.base_url_present = true
	}
	l.settop(L, base)
	lua_field(L, idx, "api")
	if l.type(L, -1) != .NIL {
		value, ok := lua_string(L, -1, allocator)
		if !ok { return .Invalid }
		out^.api = value
		out^.api_present = true
	}
	l.settop(L, base)
	lua_field(L, idx, "transport")
	if l.type(L, -1) != .NIL {
		value, ok := lua_string(L, -1, allocator)
		if !ok { return .Invalid }
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
	l.settop(L, base)
	lua_field(L, idx, "api_key")
	if l.type(L, -1) != .NIL {
		value, ok := lua_string(L, -1, allocator)
		if !ok { return .Invalid }
		out^.api_key = value
		out^.api_key_present = true
	}
	l.settop(L, base)
	lua_field(L, idx, "models")
	if l.type(L, -1) != .NIL {
		if !lua_plain_table(L, -1) { return .Invalid }
		models_idx := l.absindex(L, -1)
		count := 0
		l.pushnil(L)
		for {
			if l.next(L, models_idx) == 0 { break }
			count += 1
			if count > CONFIG_MAX_ENTRIES || l.type(L, -2) != .STRING { return .Invalid }
			model_id, ok := lua_string(L, -2, allocator)
			if !ok { return .Invalid }
			model: Catalog_Model_Source
			err := load_model(L, -1, provider_id, model_id, allocator, &model)
			delete(model_id, allocator)
			if err != .None {
				catalog_model_source_destroy(&model, allocator)
				return err
			}
			append(&models, model)
			l.pop(L, 1)
		}
		out^.models = models[:]
	}
	failed = false
	return .None
}

load_harness_options :: proc(L: ^l.State, idx: c.int) -> (Harness_Options, Config_Error) {
	options: Harness_Options
	if l.type(L, idx) == .NIL { return options, .None }
	if !lua_plain_table(L, idx) { return {}, .Invalid }
	base := l.gettop(L)
	defer l.settop(L, base)
	lua_field(L, idx, "project")
	if l.type(L, -1) != .NIL {
		project, ok := lua_bool(L, -1)
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
	if len(data) > CONFIG_MAX_BYTES { return {}, {}, {}, .Invalid }
	L := l.L_newstate(); if L == nil { return {}, {}, {}, .Lua }; defer l.close(L)
	l.sethook(L, lua_limit_hook, l.MASKCOUNT, CONFIG_INSTRUCTIONS)
	if l.L_loadbuffer(L, raw_data(data), c.size_t(len(data)), "@svan-config", "t") != .OK { return {}, {}, {}, .Lua }
	if l.pcall(L, 0, 1, 0) != 0 { return {}, {}, {}, .Lua }
	if !lua_plain_table(L, -1) { return {}, {}, {}, .Root }
	base := l.gettop(L)
	lua_field(L, -1, "instructions")
	options, options_err := load_harness_options(L, -1)
	if options_err != .None { return {}, {}, {}, options_err }
	l.settop(L, base)
	lua_field(L, -1, "providers")
	if l.type(L, -1) == .NIL {
		l.settop(L, base)
		return {}, options, load_mcp_servers_from(L, -1, allocator)
	}
	if !lua_plain_table(L, -1) { return {}, {}, {}, .Invalid }
	result: [dynamic]Catalog_Provider_Source
	result.allocator = allocator
	count := 0
	providers_idx := l.absindex(L, -1)
	l.pushnil(L)
	for {
		if l.next(L, providers_idx) == 0 { break }
		count += 1
		if count > CONFIG_MAX_ENTRIES || l.type(L, -2) != .STRING {
			catalog_sources_destroy(&result, allocator)
			return {}, {}, {}, .Invalid
		}
		provider_id, ok := lua_string(L, -2, allocator)
		if !ok {
			catalog_sources_destroy(&result, allocator)
			return {}, {}, {}, .Invalid
		}
		provider: Catalog_Provider_Source
		err := load_provider(L, -1, provider_id, allocator, &provider)
		delete(provider_id, allocator)
		if err != .None {
			catalog_provider_source_destroy(&provider, allocator)
			catalog_sources_destroy(&result, allocator)
			return {}, {}, {}, err
		}
		append(&result, provider)
		l.settop(L, providers_idx + 1)
	}
	l.settop(L, base)
	servers, servers_err := load_mcp_servers_from(L, -1, allocator)
	if servers_err != .None {
		catalog_sources_destroy(&result, allocator)
		return {}, {}, {}, servers_err
	}
	l.settop(L, base)
	return result, options, servers, .None
}

// load_mcp_servers_from reads the `mcp` table, which holds the `servers` table. The
// state is reset by the caller.
@(private)
load_mcp_servers_from :: proc(L: ^l.State, root_idx: c.int, allocator: mem.Allocator) -> ([dynamic]MCP_Server_Config, Config_Error) {
	base := l.gettop(L)
	defer l.settop(L, base)
	lua_field(L, root_idx, "mcp")
	if l.type(L, -1) == .NIL { return {}, .None }
	if !lua_plain_table(L, -1) { return {}, .Invalid }
	mcp_idx := l.absindex(L, -1)
	lua_field(L, mcp_idx, "servers")
	if l.type(L, -1) == .NIL { return {}, .None }
	return mcp_servers_load(L, -1, allocator)
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
	if len(data) > CONFIG_MAX_BYTES { return {}, .Invalid }
	L := l.L_newstate(); if L == nil { return {}, .Lua }; defer l.close(L)
	l.sethook(L, lua_limit_hook, l.MASKCOUNT, CONFIG_INSTRUCTIONS)
	if l.L_loadbuffer(L, raw_data(data), c.size_t(len(data)), "@svan-config", "t") != .OK { return {}, .Lua }
	if l.pcall(L, 0, 1, 0) != 0 { return {}, .Lua }
	if !lua_plain_table(L, -1) { return {}, .Root }
	base := l.gettop(L)
	lua_field(L, -1, "providers")
	if l.type(L, -1) == .NIL { return {}, .None }
	if !lua_plain_table(L, -1) { return {}, .Invalid }
	result: [dynamic]Catalog_Provider_Source
	result.allocator = allocator
	count := 0
	providers_idx := l.absindex(L, -1)
	l.pushnil(L)
	for {
		if l.next(L, providers_idx) == 0 { break }
		count += 1
		if count > CONFIG_MAX_ENTRIES || l.type(L, -2) != .STRING {
			catalog_sources_destroy(&result, allocator)
			return {}, .Invalid
		}
		provider_id, ok := lua_string(L, -2, allocator)
		if !ok {
			catalog_sources_destroy(&result, allocator)
			return {}, .Invalid
		}
		provider: Catalog_Provider_Source
		err := load_provider(L, -1, provider_id, allocator, &provider)
		delete(provider_id, allocator)
		if err != .None {
			catalog_provider_source_destroy(&provider, allocator)
			catalog_sources_destroy(&result, allocator)
			return {}, err
		}
		append(&result, provider)
		l.settop(L, providers_idx + 1)
	}
	l.settop(L, base)
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
	return strings.clone(value, allocator), true
}


// config_strings_destroy frees a loader-local string accumulator. Catalog fields
// are released by catalog_strings_destroy, which takes a slice.
config_strings_destroy :: proc(values: ^[dynamic]string, allocator: mem.Allocator) {
	if values == nil { return }
	for value in values^ { delete(value, allocator) }
	delete(values^)
	values^ = nil
}
