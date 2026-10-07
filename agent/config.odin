package agent

import c "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
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
	compact_on_switch:            bool,
	// subagents_max_running is the configured subagent concurrency; zero means unset, which
	// is SUBAGENTS_MAX_RUNNING. A loaded value is always at least one.
	subagents_max_running:        int,
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

config_field_detail :: proc(path, expected: string, state: ^lua.State, idx: c.int, allocator: mem.Allocator) -> string {
	actual := string(lua.typename(state, lua.type(state, idx)))
	return fmt.aprintf("%s: expected %s, got %s", path, expected, actual, allocator = allocator)
}

config_model_field_detail :: proc(provider_id, model_id, field, expected: string, state: ^lua.State, idx: c.int, allocator: mem.Allocator) -> string {
	path := fmt.aprintf("providers[%q].models[%q]", provider_id, model_id, allocator = context.temp_allocator)
	if field != "" { path = fmt.aprintf("%s.%s", path, field, allocator = context.temp_allocator) }
	return config_field_detail(path, expected, state, idx, allocator)
}

config_provider_field_detail :: proc(provider_id, field, expected: string, state: ^lua.State, idx: c.int, allocator: mem.Allocator) -> string {
	path := fmt.aprintf("providers[%q]", provider_id, allocator = context.temp_allocator)
	if field != "" { path = fmt.aprintf("%s.%s", path, field, allocator = context.temp_allocator) }
	return config_field_detail(path, expected, state, idx, allocator)
}

config_lua_error_detail :: proc(state: ^lua.State, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	length: c.size_t
	message := lua.tolstring(state, -1, &length)
	if message == nil || length == 0 { return "", nil }
	return strings.clone(string(message), allocator)
}

@(require_results)
lua_string :: proc(state: ^lua.State, idx: c.int, allocator: mem.Allocator) -> (string, Config_Error) {
	if lua.type(state, idx) != .STRING { return "", .Invalid }
	length: c.size_t
	text := lua.tolstring(state, idx, &length)
	if text == nil { return "", .Invalid }
	value, clone_error := strings.clone(string(text), allocator)
	if clone_error != nil { return "", .Allocation }
	return value, .None
}

@(require_results)
lua_bool :: proc(state: ^lua.State, idx: c.int) -> (bool, bool) {
	if lua.type(state, idx) != .BOOLEAN { return false, false }
	return lua.toboolean(state, idx) != false, true
}

@(require_results)
lua_int :: proc(state: ^lua.State, idx: c.int) -> (int, bool) {
	if lua.type(state, idx) != .NUMBER { return 0, false }
	ok: b32
	value := lua.tointeger(state, idx, &ok)
	if !ok || value < 0 || value > lua.Integer(1 << 30) { return 0, false }
	return int(value), true
}

// lua_number reads a number that must be a finite, non-negative price. A price is
// a real value rather than a count, so it may be fractional.
@(require_results)
lua_number :: proc(state: ^lua.State, idx: c.int) -> (f64, bool) {
	if lua.type(state, idx) != .NUMBER { return 0, false }
	value := f64(lua.tonumber(state, idx))
	if value < 0 || math.is_nan(value) || math.is_inf(value) { return 0, false }
	return value, true
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

@(require_results)
lua_plain_table :: proc(state: ^lua.State, idx: c.int) -> bool {
	if lua.type(state, idx) != .TABLE { return false }
	return lua.getmetatable(state, idx) == 0
}

@(require_results)
load_model :: proc(
	state: ^lua.State,
	raw_idx: c.int,
	provider_id, model_id: string,
	allocator: mem.Allocator,
	out: ^Catalog_Model_Source,
) -> (
	Config_Error,
	string,
) {
	if !lua_plain_table(state, raw_idx) {
		return .Invalid, config_model_field_detail(provider_id, model_id, "", "plain table", state, raw_idx, allocator)
	}
	idx := lua.absindex(state, raw_idx)
	model_id_copy, model_id_copy_error := strings.clone(model_id, allocator)
	if model_id_copy_error != nil { return .Allocation, "" }
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
		if !ok { return .Invalid, config_model_field_detail(provider_id, model_id, "disabled", "boolean", state, -1, allocator) }
		out^.disabled = value
	}
	lua.settop(state, base)
	lua_field(state, idx, "api")
	if lua.type(state, -1) != .NIL {
		value, value_error := lua_string(state, -1, allocator)
		if value_error == .Invalid { return value_error, config_model_field_detail(provider_id, model_id, "api", "string", state, -1, allocator) }
		if value_error != .None { return value_error, "" }
		out^.api = value
	}
	lua.settop(state, base)
	lua_field(state, idx, "display_name")
	if lua.type(state, -1) != .NIL {
		value, value_error := lua_string(state, -1, allocator)
		if value_error == .Invalid { return value_error, config_model_field_detail(provider_id, model_id, "display_name", "string", state, -1, allocator) }
		if value_error != .None { return value_error, "" }
		out^.display_name = value
	}
	lua.settop(state, base)
	lua_field(state, idx, "context_window")
	if lua.type(state, -1) != .NIL {
		value, ok := lua_int(state, -1)
		if !ok { return .Invalid, config_model_field_detail(provider_id, model_id, "context_window", "non-negative integer", state, -1, allocator) }
		out^.context_window = value
	}
	lua.settop(state, base)
	lua_field(state, idx, "max_output_tokens")
	if lua.type(state, -1) != .NIL {
		value, ok := lua_int(state, -1)
		if !ok { return .Invalid, config_model_field_detail(provider_id, model_id, "max_output_tokens", "non-negative integer", state, -1, allocator) }
		out^.max_output_tokens = value
	}
	lua.settop(state, base)
	lua_field(state, idx, "tools")
	if lua.type(state, -1) != .NIL {
		value, ok := lua_bool(state, -1)
		if !ok { return .Invalid, config_model_field_detail(provider_id, model_id, "tools", "boolean", state, -1, allocator) }
		out^.tools = value
	}
	lua.settop(state, base)
	lua_field(state, idx, "input_modalities")
	if lua.type(state, -1) != .NIL {
		if !lua_plain_table(
			state,
			-1,
		) { return .Invalid, config_model_field_detail(provider_id, model_id, "input_modalities", "plain table of strings", state, -1, allocator) }
		for i in 1 ..= int(lua.rawlen(state, -1)) {
			lua.rawgeti(state, -1, lua.Integer(i))
			value, value_error := lua_string(state, -1, allocator)
			field := fmt.aprintf("input_modalities[%d]", i, allocator = context.temp_allocator)
			if value_error == .Invalid { return value_error, config_model_field_detail(provider_id, model_id, field, "string", state, -1, allocator) }
			if value_error != .None { return value_error, "" }
			appended := append(&input_modalities, value)
			if appended != 1 {
				if appended == 0 { delete(value, allocator) }
				return .Allocation, ""
			}
			lua.pop(state, 1)
		}
		out^.input_modalities = input_modalities[:]
		// Ownership moved to out; the failure cleanup below must not free it twice.
		input_modalities = nil
	}
	lua.settop(state, base)
	lua_field(state, idx, "output_modalities")
	if lua.type(state, -1) != .NIL {
		if !lua_plain_table(
			state,
			-1,
		) { return .Invalid, config_model_field_detail(provider_id, model_id, "output_modalities", "plain table of strings", state, -1, allocator) }
		for i in 1 ..= int(lua.rawlen(state, -1)) {
			lua.rawgeti(state, -1, lua.Integer(i))
			value, value_error := lua_string(state, -1, allocator)
			field := fmt.aprintf("output_modalities[%d]", i, allocator = context.temp_allocator)
			if value_error == .Invalid { return value_error, config_model_field_detail(provider_id, model_id, field, "string", state, -1, allocator) }
			if value_error != .None { return value_error, "" }
			appended := append(&output_modalities, value)
			if appended != 1 {
				if appended == 0 { delete(value, allocator) }
				return .Allocation, ""
			}
			lua.pop(state, 1)
		}
		out^.output_modalities = output_modalities[:]
		// Ownership moved to out; the failure cleanup below must not free it twice.
		output_modalities = nil
	}
	lua.settop(state, base)
	lua_field(state, idx, "thinking")
	if lua.type(state, -1) != .NIL {
		out^.thinking.present = true
		if lua.type(state, -1) == .BOOLEAN {
			supported := lua.toboolean(state, -1) != false
			out^.thinking.supported = supported
			if !supported { out^.thinking.blocked = true }
		} else if lua_plain_table(state, -1) {
			thinking_base := lua.gettop(state)
			lua_field(state, -1, "supported")
			if lua.type(state, -1) != .NIL {
				value, ok := lua_bool(state, -1)
				if !ok { return .Invalid, config_model_field_detail(provider_id, model_id, "thinking.supported", "boolean", state, -1, allocator) }
				out^.thinking.supported = value
				if !value { out^.thinking.blocked = true }
			}
			lua.settop(state, thinking_base)
			lua_field(state, -1, "toggle")
			if lua.type(state, -1) != .NIL {
				value, ok := lua_bool(state, -1)
				if !ok { return .Invalid, config_model_field_detail(provider_id, model_id, "thinking.toggle", "boolean", state, -1, allocator) }
				out^.thinking.toggle = value
			}
			lua.settop(state, thinking_base)
			lua_field(state, -1, "levels")
			if lua.type(state, -1) != .NIL {
				if !lua_plain_table(
					state,
					-1,
				) { return .Invalid, config_model_field_detail(provider_id, model_id, "thinking.levels", "plain table of strings", state, -1, allocator) }
				for i in 1 ..= int(lua.rawlen(state, -1)) {
					lua.rawgeti(state, -1, lua.Integer(i))
					value, value_error := lua_string(state, -1, allocator)
					field := fmt.aprintf("thinking.levels[%d]", i, allocator = context.temp_allocator)
					if value_error == .Invalid { return value_error, config_model_field_detail(provider_id, model_id, field, "string", state, -1, allocator) }
					if value_error != .None { return value_error, "" }
					appended := append(&thinking_levels, value)
					if appended != 1 {
						if appended == 0 { delete(value, allocator) }
						return .Allocation, ""
					}
					lua.pop(state, 1)
				}
				out^.thinking.levels = thinking_levels[:]
				// Ownership moved to out; the failure cleanup below must not free it twice.
				thinking_levels = nil
			}
			lua.settop(state, thinking_base)
		} else {
			return .Invalid, config_model_field_detail(provider_id, model_id, "thinking", "boolean or plain table", state, -1, allocator)
		}
	}
	lua.settop(state, base)
	lua_field(state, idx, "cost")
	if lua.type(state, -1) != .NIL {
		if !lua_plain_table(
			state,
			-1,
		) { return .Invalid, config_model_field_detail(provider_id, model_id, "cost", "plain table of non-negative numbers", state, -1, allocator) }
		cost_base := lua.gettop(state)
		lua_field(state, -1, "input")
		if lua.type(state, -1) != .NIL {
			value, ok := lua_number(state, -1)
			if !ok { return .Invalid, config_model_field_detail(provider_id, model_id, "cost.input", "finite non-negative number", state, -1, allocator) }
			out^.cost.input = value
		}
		lua.settop(state, cost_base)
		lua_field(state, -1, "output")
		if lua.type(state, -1) != .NIL {
			value, ok := lua_number(state, -1)
			if !ok { return .Invalid, config_model_field_detail(provider_id, model_id, "cost.output", "finite non-negative number", state, -1, allocator) }
			out^.cost.output = value
		}
		lua.settop(state, cost_base)
		lua_field(state, -1, "cache_read")
		if lua.type(state, -1) != .NIL {
			value, ok := lua_number(state, -1)
			if !ok { return .Invalid, config_model_field_detail(provider_id, model_id, "cost.cache_read", "finite non-negative number", state, -1, allocator) }
			out^.cost.cache_read = value
		}
		lua.settop(state, cost_base)
		lua_field(state, -1, "cache_write")
		if lua.type(state, -1) != .NIL {
			value, ok := lua_number(state, -1)
			if !ok { return .Invalid, config_model_field_detail(provider_id, model_id, "cost.cache_write", "finite non-negative number", state, -1, allocator) }
			out^.cost.cache_write = value
		}
		lua.settop(state, cost_base)
	}
	failed = false
	return .None, ""
}

@(require_results)
load_provider :: proc(
	state: ^lua.State,
	raw_idx: c.int,
	provider_id: string,
	allocator: mem.Allocator,
	out: ^Catalog_Provider_Source,
) -> (
	Config_Error,
	string,
) {
	if !lua_plain_table(state, raw_idx) {
		return .Invalid, config_provider_field_detail(provider_id, "", "plain table", state, raw_idx, allocator)
	}
	idx := lua.absindex(state, raw_idx)
	id, id_error := strings.clone(provider_id, allocator)
	if id_error != nil { return .Allocation, "" }
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
		if value_error == .Invalid { return value_error, config_provider_field_detail(provider_id, "base_url", "string", state, -1, allocator) }
		if value_error != .None { return value_error, "" }
		out^.base_url = value
	}
	lua.settop(state, base)
	lua_field(state, idx, "api")
	if lua.type(state, -1) != .NIL {
		value, value_error := lua_string(state, -1, allocator)
		if value_error == .Invalid { return value_error, config_provider_field_detail(provider_id, "api", "string", state, -1, allocator) }
		if value_error != .None { return value_error, "" }
		out^.api = value
	}
	lua.settop(state, base)
	lua_field(state, idx, "transport")
	if lua.type(state, -1) != .NIL {
		value, value_error := lua_string(state, -1, allocator)
		if value_error ==
		   .Invalid { return value_error, config_provider_field_detail(provider_id, "transport", "http, websocket, or auto", state, -1, allocator) }
		if value_error != .None { return value_error, "" }
		switch value {
		case "http":
			out^.transport = .HTTP
		case "websocket":
			out^.transport = .WebSocket
		case "auto":
			out^.transport = .Auto
		case:
			delete(value, allocator)
			return .Invalid, config_provider_field_detail(provider_id, "transport", "http, websocket, or auto", state, -1, allocator)
		}
		delete(value, allocator)
	}
	lua.settop(state, base)
	lua_field(state, idx, "stream_idle_timeout_ms")
	if lua.type(state, -1) != .NIL {
		milliseconds, ok := lua_int(state, -1)
		if !ok {
			return .Invalid, config_provider_field_detail(
				provider_id,
				"stream_idle_timeout_ms",
				"non-negative integer of milliseconds, 0 for none",
				state,
				-1,
				allocator,
			)
		}
		out^.stream_idle_timeout = time.Duration(milliseconds) * time.Millisecond
	}
	lua.settop(state, base)
	lua_field(state, idx, "api_key")
	if lua.type(state, -1) != .NIL {
		value, value_error := lua_string(state, -1, allocator)
		if value_error == .Invalid { return value_error, config_provider_field_detail(provider_id, "api_key", "string", state, -1, allocator) }
		if value_error != .None { return value_error, "" }
		out^.api_key = value
	}
	lua.settop(state, base)
	lua_field(state, idx, "models")
	if lua.type(state, -1) != .NIL {
		if !lua_plain_table(
			state,
			-1,
		) { return .Invalid, config_provider_field_detail(provider_id, "models", "plain table of model definitions", state, -1, allocator) }
		models_idx := lua.absindex(state, -1)
		lua.pushnil(state)
		for {
			if lua.next(state, models_idx) == 0 { break }
			if lua.type(state, -2) !=
			   .STRING { return .Invalid, config_provider_field_detail(provider_id, "models", "string model ids", state, -2, allocator) }
			model_id, model_id_error := lua_string(state, -2, allocator)
			if model_id_error ==
			   .Invalid { return model_id_error, config_provider_field_detail(provider_id, "models", "string model ids", state, -2, allocator) }
			if model_id_error != .None { return model_id_error, "" }
			model: Catalog_Model_Source
			err, detail := load_model(state, -1, provider_id, model_id, allocator, &model)
			delete(model_id, allocator)
			if err != .None {
				catalog_model_source_destroy(&model, allocator)
				return err, detail
			}
			appended := append(&models, model)
			if appended != 1 {
				if appended == 0 { catalog_model_source_destroy(&model, allocator) }
				return .Allocation, ""
			}
			lua.pop(state, 1)
		}
		out^.models = models[:]
	}
	failed = false
	return .None, ""
}

@(require_results)
load_harness_options :: proc(state: ^lua.State, root_idx: c.int, allocator: mem.Allocator) -> (Harness_Options, Config_Error, string) {
	options: Harness_Options
	base := lua.gettop(state)
	defer lua.settop(state, base)
	lua_field(state, root_idx, "instructions")
	if lua.type(state, -1) != .NIL {
		if !lua_plain_table(state, -1) { return {}, .Invalid, config_field_detail("instructions", "plain table", state, -1, allocator) }
		instructions_idx := lua.absindex(state, -1)
		lua_field(state, instructions_idx, "project")
		if lua.type(state, -1) != .NIL {
			project, ok := lua_bool(state, -1)
			if !ok { return {}, .Invalid, config_field_detail("instructions.project", "boolean", state, -1, allocator) }
			options.disable_project_instructions = !project
		}
	}
	lua.settop(state, base)
	lua_field(state, root_idx, "compact_on_switch")
	if lua.type(state, -1) != .NIL {
		value, ok := lua_bool(state, -1)
		if !ok { return {}, .Invalid, config_field_detail("compact_on_switch", "boolean", state, -1, allocator) }
		options.compact_on_switch = value
	}
	lua.settop(state, base)
	lua_field(state, root_idx, "subagents_max_running")
	if lua.type(state, -1) != .NIL {
		value, ok := lua_int(state, -1)
		if !ok || value < 1 { return {}, .Invalid, config_field_detail("subagents_max_running", "positive integer", state, -1, allocator) }
		options.subagents_max_running = value
	}
	return options, .None, ""
}

// load_lua_config returns the loaded sources and options. On failure, detail is empty
// or owned by allocator; the caller releases a non-empty detail with that allocator.
@(require_results)
load_lua_config :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	[dynamic]Catalog_Provider_Source,
	Harness_Options,
	[dynamic]MCP_Server_Config,
	Config_Error,
	string,
) {
	if path == "" { return {}, {}, {}, .None, "" }
	// A missing file is a valid setup: no providers, default options. Only a
	// file that exists but cannot be read is an error.
	if info, stat_err := os.stat(path, context.temp_allocator); stat_err != nil {
		if stat_err == os.General_Error.Not_Exist { return {}, {}, {}, .Missing, "" }
		return {}, {}, {}, .Read, ""
	} else if info.type != .Regular {
		return {}, {}, {}, .Read, ""
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil { return {}, {}, {}, .Read, "" }
	state := lua.L_newstate()
	if state == nil { return {}, {}, {}, .Lua, "" }
	defer lua.close(state)
	lua.sethook(state, lua_limit_hook, lua.MASKCOUNT, CONFIG_INSTRUCTIONS)
	chunk_name := fmt.aprintf("@%s", path, allocator = context.temp_allocator)
	chunk_name_c, chunk_name_error := strings.clone_to_cstring(chunk_name, context.temp_allocator)
	if chunk_name_error != nil { return {}, {}, {}, .Allocation, "" }
	defer delete(chunk_name_c, context.temp_allocator)
	if lua.L_loadbuffer(state, raw_data(data), c.size_t(len(data)), chunk_name_c, "t") != .OK {
		detail, detail_error := config_lua_error_detail(state, allocator)
		if detail_error != nil { return {}, {}, {}, .Allocation, "" }
		return {}, {}, {}, .Lua, detail
	}
	if lua.pcall(state, 0, 1, 0) != 0 {
		detail, detail_error := config_lua_error_detail(state, allocator)
		if detail_error != nil { return {}, {}, {}, .Allocation, "" }
		return {}, {}, {}, .Lua, detail
	}
	if !lua_plain_table(state, -1) { return {}, {}, {}, .Root, config_field_detail("return", "plain table", state, -1, allocator) }
	base := lua.gettop(state)
	options, options_err, options_detail := load_harness_options(state, -1, allocator)
	if options_err != .None { return {}, {}, {}, options_err, options_detail }
	lua.settop(state, base)
	result: [dynamic]Catalog_Provider_Source
	lua_field(state, -1, "providers")
	if lua.type(state, -1) != .NIL {
		if !lua_plain_table(state, -1) { return {}, {}, {}, .Invalid, config_field_detail("providers", "plain table", state, -1, allocator) }
		result.allocator = allocator
		providers_idx := lua.absindex(state, -1)
		lua.pushnil(state)
		for {
			if lua.next(state, providers_idx) == 0 { break }
			if lua.type(state, -2) != .STRING {
				catalog_sources_destroy(&result, allocator)
				return {}, {}, {}, .Invalid, config_field_detail("providers", "string provider ids", state, -2, allocator)
			}
			provider_id, provider_id_error := lua_string(state, -2, allocator)
			if provider_id_error != .None {
				catalog_sources_destroy(&result, allocator)
				return {}, {}, {}, provider_id_error, ""
			}
			provider: Catalog_Provider_Source
			err, provider_detail := load_provider(state, -1, provider_id, allocator, &provider)
			delete(provider_id, allocator)
			if err != .None {
				catalog_provider_source_destroy(&provider, allocator)
				catalog_sources_destroy(&result, allocator)
				return {}, {}, {}, err, provider_detail
			}
			appended := append(&result, provider)
			if appended != 1 {
				if appended == 0 { catalog_provider_source_destroy(&provider, allocator) }
				catalog_sources_destroy(&result, allocator)
				return {}, {}, {}, .Allocation, ""
			}
			lua.settop(state, providers_idx + 1)
		}
	}
	lua.settop(state, base)
	servers, servers_err := load_mcp_servers_from(state, -1, allocator)
	if servers_err != .None {
		catalog_sources_destroy(&result, allocator)
		mcp_detail, detail_error := strings.clone("mcp.servers: expected a valid server configuration", allocator)
		if detail_error != nil { return {}, {}, {}, .Allocation, "" }
		return {}, {}, {}, servers_err, mcp_detail
	}
	lua.settop(state, base)
	acp_agents, acp_agents_err := load_acp_agents_from(state, -1, allocator)
	if acp_agents_err != .None {
		catalog_sources_destroy(&result, allocator)
		mcp_servers_destroy(&servers, allocator)
		agents_detail, detail_error := strings.clone("agents: expected valid agent configurations", allocator)
		if detail_error != nil { return {}, {}, {}, .Allocation, "" }
		return {}, {}, {}, acp_agents_err, agents_detail
	}
	options.acp_agents = acp_agents[:]
	return result, options, servers, .None, ""
}

// load_mcp_servers_from reads the `mcp` table, which holds the `servers` table. The
// state is reset by the caller.
@(private, require_results)
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
@(private, require_results)
load_acp_agents_from :: proc(state: ^lua.State, root_idx: c.int, allocator: mem.Allocator) -> ([dynamic]ACP_Agent_Config, Config_Error) {
	base := lua.gettop(state)
	defer lua.settop(state, base)
	lua_field(state, root_idx, "agents")
	return acp_agents_load(state, -1, allocator)
}

// config_env_reference reports whether a configured value names an environment
// variable. `${NAME}` is the reference syntax configuration values already use
// for environment variables, and it is unambiguous: a literal secret never
// matches it. The name must be a plain identifier.
@(require_results)
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
@(require_results)
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
