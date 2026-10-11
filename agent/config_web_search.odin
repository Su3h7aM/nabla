package agent

import c "core:c"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import lua "vendor:lua/5.4"

import "nabla:web"

// Web_Search_Config is the `web_search` table of the configuration. It is allocated by the
// loader, owned by the loaded configuration for the process lifetime, and borrowed by the
// sessions and the tool that read it. A nil config disables the tool. Without a
// `web_search` key, configuration loading builds the endpoints from the environment.
//
// endpoints is the exact ordered provider list; an api_key in it is the configured text, which
// config_resolve_credential resolves when the tool runs, and "" means the provider's
// environment variable.
Web_Search_Config :: struct {
	endpoints: []web.Endpoint,
	services:  []web.Provider,
}

// web_search_config_destroy releases a config returned by load_web_search.
web_search_config_destroy :: proc(config: ^Web_Search_Config, allocator := context.allocator) {
	if config == nil { return }
	web.endpoints_destroy(config.endpoints, allocator)
	delete(config.services, allocator)
	free(config, allocator)
}

// web_search_services returns the engines in endpoint priority order, deduplicated, owned
// by allocator. Configuration loading keeps this native list beside its endpoints.
@(require_results)
web_search_services :: proc(endpoints: []web.Endpoint, allocator := context.allocator) -> (services: []web.Provider, err: mem.Allocator_Error) {
	list := make([dynamic]web.Provider, 0, len(endpoints), allocator) or_return
	seen: bit_set[web.Provider]
	for endpoint in endpoints {
		service := web.engine(endpoint.provider)
		if service in seen { continue }
		seen += {service}
		// Reserved above, so this cannot grow the list.
		append(&list, service)
	}
	return list[:], nil
}

// web_search_config_from_environment builds the default configuration, owned by allocator
// and released with web_search_config_destroy.
@(require_results)
web_search_config_from_environment :: proc(allocator := context.allocator) -> (config: ^Web_Search_Config, err: mem.Allocator_Error) {
	config = new(Web_Search_Config, allocator) or_return
	defer if err != nil {
		web_search_config_destroy(config, allocator)
		config = nil
	}
	config.endpoints = web.endpoints_from_environment(allocator) or_return
	config.services = web_search_services(config.endpoints, allocator) or_return
	return
}

@(private, require_results)
load_web_search_default :: proc(allocator: mem.Allocator) -> (^Web_Search_Config, Config_Error, string) {
	config, err := web_search_config_from_environment(allocator)
	if err != nil { return nil, .Allocation, "" }
	return config, .None, ""
}

// load_web_search reads the `web_search` table at the root. A missing key, `true`, and a
// table without providers all load the default endpoints. False disables the tool and loads
// as nil. A table that cannot be used
// is refused with a detail naming the field, owned by allocator.
@(require_results)
load_web_search :: proc(state: ^lua.State, root_idx: c.int, allocator: mem.Allocator) -> (config: ^Web_Search_Config, err: Config_Error, detail: string) {
	base := lua.gettop(state)
	defer lua.settop(state, base)
	lua_field(state, root_idx, "web_search")
	#partial switch lua.type(state, -1) {
	case .NIL:
		return load_web_search_default(allocator)
	case .BOOLEAN:
		if lua.toboolean(state, -1) != false { return load_web_search_default(allocator) }
		return nil, .None, ""
	}
	if !lua_plain_table(state, -1) { return nil, .Invalid, config_field_detail("web_search", "false or plain table", state, -1, allocator) }
	table := lua.absindex(state, -1)

	lua.pushnil(state)
	for lua.next(state, table) != 0 {
		key, key_error := lua_string(state, -2, context.temp_allocator)
		lua.pop(state, 1)
		if key_error != .None || key != "providers" {
			lua.pop(state, 1)
			return nil, .Invalid, fmt.aprintf("web_search: unknown field, expected providers", allocator = allocator)
		}
	}

	lua_field(state, table, "providers")
	if lua.type(state, -1) == .NIL { return load_web_search_default(allocator) }
	if !lua_plain_table(state, -1) { return nil, .Invalid, config_field_detail("web_search.providers", "plain list of tables", state, -1, allocator) }
	list := lua.absindex(state, -1)
	length := int(lua.rawlen(state, list))
	entries := 0
	lua.pushnil(state)
	for lua.next(state, list) != 0 {
		entries += 1
		lua.pop(state, 1)
	}
	if length == 0 || entries != length {
		return nil, .Invalid, fmt.aprintf("web_search.providers: expected a list with at least one provider", allocator = allocator)
	}

	endpoints, endpoints_error := make([dynamic]web.Endpoint, 0, length, allocator)
	if endpoints_error != nil { return nil, .Allocation, "" }
	defer if err != .None { web.endpoints_destroy(endpoints[:], allocator) }
	for position in 1 ..= length {
		lua.rawgeti(state, list, lua.Integer(position))
		endpoint: web.Endpoint
		load_error, load_detail := web_search_endpoint_load(state, -1, position, allocator, &endpoint)
		lua.pop(state, 1)
		if load_error != .None {
			delete(endpoint.api_key, allocator)
			delete(endpoint.base_url, allocator)
			return nil, load_error, load_detail
		}
		// Reserved above, so this cannot grow the list.
		append(&endpoints, endpoint)
	}
	made, make_error := new(Web_Search_Config, allocator)
	if make_error != nil { return nil, .Allocation, "" }
	made.endpoints = endpoints[:]
	services, services_error := web_search_services(made.endpoints, allocator)
	if services_error != nil {
		free(made, allocator)
		return nil, .Allocation, ""
	}
	made.services = services
	return made, .None, ""
}

// web_search_endpoint_load reads one `providers` entry. On failure out may hold strings the
// caller releases.
@(private, require_results)
web_search_endpoint_load :: proc(state: ^lua.State, raw_idx: c.int, position: int, allocator: mem.Allocator, out: ^web.Endpoint) -> (Config_Error, string) {
	path := fmt.tprintf("web_search.providers[%d]", position)
	if !lua_plain_table(state, raw_idx) { return .Invalid, config_field_detail(path, "plain table", state, raw_idx, allocator) }
	idx := lua.absindex(state, raw_idx)
	base := lua.gettop(state)
	defer lua.settop(state, base)

	lua.pushnil(state)
	for lua.next(state, idx) != 0 {
		key, key_error := lua_string(state, -2, context.temp_allocator)
		lua.pop(state, 1)
		switch {
		case key_error == .None && (key == "provider" || key == "api_key" || key == "base_url"):
		case:
			lua.pop(state, 1)
			return .Invalid, fmt.aprintf("%s: unknown field, expected provider, api_key, or base_url", path, allocator = allocator)
		}
	}

	lua_field(state, idx, "provider")
	if lua.type(state, -1) != .STRING { return .Invalid, config_field_detail(fmt.tprintf("%s.provider", path), "string", state, -1, allocator) }
	name, name_error := lua_string(state, -1, context.temp_allocator)
	if name_error != .None { return name_error, "" }
	provider, known := web.provider_parse(name)
	if !known {
		names := web.PROVIDER_NAMES
		return .Invalid, fmt.aprintf(
			"%s.provider: unknown provider %q, expected one of %s",
			path,
			name,
			strings.join(slice.enumerated_array(&names), ", ", context.temp_allocator),
			allocator = allocator,
		)
	}
	out.provider = provider
	lua.settop(state, base)

	field_error: Config_Error
	field_detail: string
	out.api_key, field_error, field_detail = web_search_string_field(state, idx, path, "api_key", allocator)
	if field_error != .None { return field_error, field_detail }
	out.base_url, field_error, field_detail = web_search_string_field(state, idx, path, "base_url", allocator)
	if field_error != .None { return field_error, field_detail }
	return .None, ""
}

// web_search_string_field reads an optional string field of an entry; absent is "".
@(private, require_results)
web_search_string_field :: proc(state: ^lua.State, idx: c.int, path, name: string, allocator: mem.Allocator) -> (string, Config_Error, string) {
	lua_field(state, idx, name)
	defer lua.pop(state, 1)
	if lua.type(state, -1) == .NIL { return "", .None, "" }
	value, value_error := lua_string(state, -1, allocator)
	if value_error == .Invalid { return "", .Invalid, config_field_detail(fmt.tprintf("%s.%s", path, name), "string", state, -1, allocator) }
	return value, value_error, ""
}
