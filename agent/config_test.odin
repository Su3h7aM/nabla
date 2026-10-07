#+test
package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_lua_config_roundtrip :: proc(t: ^testing.T) {
	path := fmt.aprintf("/tmp/nabla-config-test-%d.lua", os.get_pid(), allocator = context.temp_allocator)
	defer os.remove(path)
	write_err := os.write_entire_file(
		path,
		`return { providers = { acme = {
			base_url = "https://api.acme.test",
			api = "openai_responses",
			transport = "websocket",
			api_key = "ACME_KEY",
			models = {
				chat = {
					display_name = "Chat",
					api = "openai_chat_completions",
					context_window = 100000,
					max_output_tokens = 4096,
					tools = true,
					input_modalities = {"text"},
					output_modalities = {"text"},
					thinking = {supported = true, toggle = true, levels = {"low", "high"}},
					cost = {input = 3, output = 15, cache_read = 0.3, cache_write = 3.75},
				},
				mini = {thinking = false, tools = false},
				old = {disabled = true},
			},
		} } }`,
	)
	testing.expect(t, write_err == nil)

	sources, _, servers, err, detail := load_lua_config(path)
	testing.expect_value(t, err, Config_Error.None)
	defer mcp_servers_destroy(&servers)
	defer if detail != "" { delete(detail) }
	defer catalog_sources_destroy(&sources)
	testing.expect_value(t, len(sources), 1)
	provider := sources[0]
	testing.expect_value(t, provider.id, "acme")
	testing.expect_value(t, provider.base_url.?, "https://api.acme.test")
	testing.expect_value(t, provider.api.?, "openai_responses")
	testing.expect(t, (provider.transport != nil))
	testing.expect_value(t, provider.transport.?, Provider_Transport.WebSocket)
	testing.expect_value(t, provider.api_key.?, "ACME_KEY")
	testing.expect_value(t, len(provider.models), 3)

	chat: ^Catalog_Model_Source
	mini: ^Catalog_Model_Source
	old: ^Catalog_Model_Source
	for &model in provider.models {
		switch model.id {
		case "chat":
			chat = &model
		case "mini":
			mini = &model
		case "old":
			old = &model
		}
	}
	testing.expect(t, chat != nil && mini != nil && old != nil)
	testing.expect_value(t, chat^.display_name.?, "Chat")
	testing.expect_value(t, chat^.api.?, "openai_chat_completions")
	testing.expect_value(t, chat^.context_window.?, 100000)
	testing.expect_value(t, chat^.max_output_tokens.?, 4096)
	testing.expect(t, chat^.tools.?)
	testing.expect_value(t, len(chat^.input_modalities.?), 1)
	testing.expect_value(t, chat^.input_modalities.?[0], "text")
	testing.expect_value(t, len(chat^.output_modalities.?), 1)
	testing.expect_value(t, chat^.output_modalities.?[0], "text")
	testing.expect(t, chat^.thinking.toggle.?)
	testing.expect_value(t, len(chat^.thinking.levels.?), 2)
	testing.expect_value(t, chat^.thinking.levels.?[0], "low")
	testing.expect_value(t, chat^.thinking.levels.?[1], "high")
	testing.expect_value(t, chat^.cost.input.?, 3.0)
	testing.expect_value(t, chat^.cost.output.?, 15.0)
	testing.expect(t, (chat^.cost.cache_read != nil))
	testing.expect_value(t, chat^.cost.cache_read.?, 0.3)
	testing.expect(t, (chat^.cost.cache_write != nil))
	testing.expect_value(t, chat^.cost.cache_write.?, 3.75)
	testing.expect(t, mini^.thinking.present && mini^.thinking.blocked)
	testing.expect(t, (old^.disabled.? or_else false))

	// A missing config is a valid empty setup, not an error; a path that exists
	// but cannot be read as a file still is.
	_, _, _, missing_err, missing_detail := load_lua_config("/tmp/nabla-config-test-missing.lua")
	defer if missing_detail != "" { delete(missing_detail) }
	testing.expect_value(t, missing_err, Config_Error.Missing)
	_, _, _, unreadable_err, unreadable_detail := load_lua_config("/tmp")
	defer if unreadable_detail != "" { delete(unreadable_detail) }
	testing.expect_value(t, unreadable_err, Config_Error.Read)
}

@(test)
test_config_env_reference_accepts_only_plain_names :: proc(t: ^testing.T) {
	cases := []struct {
		value: string,
		name:  string,
		ok:    bool,
	} {
		{"${OPENAI_API_KEY}", "OPENAI_API_KEY", true},
		{"${_private}", "_private", true},
		{"${A1}", "A1", true},
		// A literal secret is never a reference, including one that happens to
		// contain braces.
		{"sk-abc123", "", false},
		{"", "", false},
		{"${}", "", false},
		{"${1ABC}", "", false},
		{"${A B}", "", false},
		{"${A}", "A", true},
		{"${A}}$", "", false},
		{"$OPENAI_API_KEY", "", false},
	}
	for entry in cases {
		name, ok := config_env_reference(entry.value)
		testing.expectf(t, ok == entry.ok, "%q: ok=%v want %v", entry.value, ok, entry.ok)
		if entry.ok { testing.expect_value(t, name, entry.name) }
	}
}

@(test)
test_config_resolve_credential_reads_env_and_keeps_a_literal :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	literal, literal_ok := config_resolve_credential("sk-literal", context.temp_allocator)
	testing.expect(t, literal_ok)
	testing.expect_value(t, literal, "sk-literal")

	// An unset reference fails rather than resolving to an empty secret.
	_, unset_ok := config_resolve_credential("${NABLA_TEST_UNSET_CREDENTIAL}", context.temp_allocator)
	testing.expect(t, !unset_ok)

	// An empty value is not a credential.
	_, empty_ok := config_resolve_credential("", context.temp_allocator)
	testing.expect(t, !empty_ok)

	// A value that names an existing environment variable is that variable's
	// value, with or without the ${NAME} wrapper.
	testing.expect(t, os.set_env("NABLA_TEST_CREDENTIAL", "resolved-secret") == nil)
	defer os.unset_env("NABLA_TEST_CREDENTIAL")
	named, named_ok := config_resolve_credential("NABLA_TEST_CREDENTIAL", context.temp_allocator)
	testing.expect(t, named_ok)
	testing.expect_value(t, named, "resolved-secret")
	wrapped, wrapped_ok := config_resolve_credential("${NABLA_TEST_CREDENTIAL}", context.temp_allocator)
	testing.expect(t, wrapped_ok)
	testing.expect_value(t, wrapped, "resolved-secret")

	// A name that exists but resolves to nothing fails, so a miswired
	// reference never sends the variable's name as a key.
	testing.expect(t, os.set_env("NABLA_TEST_EMPTY_CREDENTIAL", "") == nil)
	defer os.unset_env("NABLA_TEST_EMPTY_CREDENTIAL")
	_, empty_named_ok := config_resolve_credential("NABLA_TEST_EMPTY_CREDENTIAL", context.temp_allocator)
	testing.expect(t, !empty_named_ok)
}

@(test)
test_lua_config_failures_leave_no_partial_sources :: proc(t: ^testing.T) {
	cases := []string {
		`return { providers = { acme = { models = { chat = { cost = { input = -1 } } } } } }`,
		`return { providers = { acme = { models = { chat = { display_name = 42 } } } } }`,
		`return { providers = { acme = { api_key = 42 } } }`,
		`return { providers = { acme = { transport = "udp" } } }`,
		`return { providers = { acme = { models = { chat = { tools = true }, bad = { context_window = -1 } } } } }`,
		`return { providers = { acme = { models = { chat = { input_modalities = {"text"}, output_modalities = "text" } } } } }`,
	}
	for config, i in cases {
		path := fmt.aprintf("/tmp/nabla-config-test-fail-%d-%d.lua", os.get_pid(), i, allocator = context.temp_allocator)
		defer os.remove(path)
		testing.expect(t, os.write_entire_file(path, transmute([]u8)config) == nil)
		sources, _, servers, err, detail := load_lua_config(path)
		testing.expectf(t, err != .None, "case %d loaded without error", i)
		testing.expect_value(t, len(sources), 0)
		if detail != "" { delete(detail) }
		mcp_servers_destroy(&servers)
		catalog_sources_destroy(&sources)
	}
}

@(test)
test_lua_config_validates_disabled_models_and_reports_the_field :: proc(t: ^testing.T) {
	path := fmt.aprintf("/tmp/nabla-config-disabled-%d.lua", os.get_pid(), allocator = context.temp_allocator)
	defer os.remove(path)
	body := `return { providers = { acme = { models = { chat = { disabled = true, tools = "yes" } } } } }`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)body) == nil)

	sources, _, servers, err, detail := load_lua_config(path)
	defer catalog_sources_destroy(&sources)
	defer mcp_servers_destroy(&servers)
	testing.expect_value(t, err, Config_Error.Invalid)
	defer if detail != "" { delete(detail) }
	testing.expect_value(t, len(sources), 0)
	testing.expect(t, strings.has_prefix(detail, `providers["acme"].models["chat"].tools: expected boolean, got string`))
}

@(test)
test_lua_config_loads_compact_on_switch :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "nabla-config-compact-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory, context.allocator)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	cases := []struct {
		name:  string,
		value: string,
		want:  bool,
	} {
		{"absent without instructions", `return {}`, false},
		{"absent with instructions", `return { instructions = {} }`, false},
		{"true", `return { compact_on_switch = true }`, true},
		{"false", `return { compact_on_switch = false }`, false},
	}
	for entry, index in cases {
		path := fmt.aprintf("%s/%d.lua", directory, index, allocator = context.temp_allocator)
		testing.expect(t, os.write_entire_file(path, transmute([]u8)entry.value) == nil)
		sources, options, servers, err, detail := load_lua_config(path)
		defer catalog_sources_destroy(&sources)
		defer mcp_servers_destroy(&servers)
		defer if detail != "" { delete(detail) }
		testing.expect_value(t, err, Config_Error.None)
		testing.expectf(t, options.compact_on_switch == entry.want, "%s: got %v want %v", entry.name, options.compact_on_switch, entry.want)
	}

	path := fmt.aprintf("%s/invalid.lua", directory, allocator = context.temp_allocator)
	body := `return { compact_on_switch = "yes" }`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)body) == nil)
	_, _, servers, err, detail := load_lua_config(path)
	defer mcp_servers_destroy(&servers)
	defer if detail != "" { delete(detail) }
	testing.expect_value(t, err, Config_Error.Invalid)
	testing.expect_value(t, detail, "compact_on_switch: expected boolean, got string")
}

@(test)
test_lua_config_loads_subagents_max_running :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "nabla-config-subagents-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory, context.allocator)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	cases := []struct {
		name:   string,
		body:   string,
		want:   int,
		detail: string,
	} {
		{"absent", `return {}`, 0, ""},
		{"set", `return { subagents_max_running = 8 }`, 8, ""},
		{"zero", `return { subagents_max_running = 0 }`, 0, "subagents_max_running: expected positive integer, got number"},
		{"negative", `return { subagents_max_running = -1 }`, 0, "subagents_max_running: expected positive integer, got number"},
		{"string", `return { subagents_max_running = "4" }`, 0, "subagents_max_running: expected positive integer, got string"},
	}
	for entry, index in cases {
		path := fmt.aprintf("%s/%d.lua", directory, index, allocator = context.temp_allocator)
		testing.expect(t, os.write_entire_file(path, transmute([]u8)entry.body) == nil)
		sources, options, servers, err, detail := load_lua_config(path)
		defer catalog_sources_destroy(&sources)
		defer mcp_servers_destroy(&servers)
		defer if detail != "" { delete(detail) }
		want_error := Config_Error.Invalid if entry.detail != "" else Config_Error.None
		testing.expectf(t, err == want_error, "%s: got %v want %v", entry.name, err, want_error)
		testing.expectf(t, detail == entry.detail, "%s: detail %q want %q", entry.name, detail, entry.detail)
		testing.expectf(t, options.subagents_max_running == entry.want, "%s: got %d want %d", entry.name, options.subagents_max_running, entry.want)
	}
}

@(test)
test_lua_config_loads_stream_idle_timeout :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "nabla-config-idle-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory, context.allocator)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	cases := []struct {
		name:    string,
		body:    string,
		present: bool,
		want:    time.Duration,
		invalid: bool,
	} {
		{"absent", `return { providers = { acme = {} } }`, false, 0, false},
		{"set", `return { providers = { acme = { stream_idle_timeout_ms = 45000 } } }`, true, 45 * time.Second, false},
		{"none", `return { providers = { acme = { stream_idle_timeout_ms = 0 } } }`, true, 0, false},
		{"negative", `return { providers = { acme = { stream_idle_timeout_ms = -1 } } }`, false, 0, true},
		{"string", `return { providers = { acme = { stream_idle_timeout_ms = "60" } } }`, false, 0, true},
	}
	for entry, index in cases {
		path := fmt.aprintf("%s/%d.lua", directory, index, allocator = context.temp_allocator)
		testing.expect(t, os.write_entire_file(path, transmute([]u8)entry.body) == nil)
		sources, _, servers, err, detail := load_lua_config(path)
		defer catalog_sources_destroy(&sources)
		defer mcp_servers_destroy(&servers)
		defer if detail != "" { delete(detail) }
		if entry.invalid {
			testing.expectf(t, err == .Invalid, "%s: got %v", entry.name, err)
			testing.expectf(t, strings.has_prefix(detail, `providers["acme"].stream_idle_timeout_ms: expected`), "%s: detail %q", entry.name, detail)
			continue
		}
		if !testing.expectf(t, err == .None && len(sources) == 1, "%s: got %v", entry.name, err) { continue }
		testing.expectf(t, (sources[0].stream_idle_timeout != nil) == entry.present, "%s: presence", entry.name)
		testing.expectf(t, (sources[0].stream_idle_timeout.? or_else 0) == entry.want, "%s: got %v", entry.name, sources[0].stream_idle_timeout)
	}
}

// The timeout a request uses is the live catalog's: a stated value, including zero, wins,
// and everything else gets the default.
@(test)
test_stream_idle_timeout_reads_the_live_catalog :: proc(t: ^testing.T) {
	catalog := Catalog {
		allocator = context.allocator,
	}
	defer delete(catalog.providers)
	append(&catalog.providers, Catalog_Provider{id = "stated", stream_idle_timeout = 20 * time.Second})
	append(&catalog.providers, Catalog_Provider{id = "off", stream_idle_timeout = time.Duration(0)})
	append(&catalog.providers, Catalog_Provider{id = "silent"})
	ref := Catalog_Ref {
		catalog = &catalog,
	}
	testing.expect_value(t, catalog_stream_idle_timeout(ref, "stated"), 20 * time.Second)
	testing.expect_value(t, catalog_stream_idle_timeout(ref, "off"), time.Duration(0))
	testing.expect_value(t, catalog_stream_idle_timeout(ref, "silent"), STREAM_IDLE_TIMEOUT_DEFAULT)
	testing.expect_value(t, catalog_stream_idle_timeout(ref, "unknown"), STREAM_IDLE_TIMEOUT_DEFAULT)
	testing.expect_value(t, catalog_stream_idle_timeout({}, "stated"), STREAM_IDLE_TIMEOUT_DEFAULT)
}

@(test)
test_lua_config_preserves_the_parser_message_and_line :: proc(t: ^testing.T) {
	path := fmt.aprintf("/tmp/nabla-config-syntax-%d.lua", os.get_pid(), allocator = context.temp_allocator)
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("return {\n")) == nil)

	sources, _, servers, err, detail := load_lua_config(path)
	defer catalog_sources_destroy(&sources)
	defer mcp_servers_destroy(&servers)
	testing.expect_value(t, err, Config_Error.Lua)
	defer if detail != "" { delete(detail) }
	testing.expect(t, strings.has_prefix(detail, fmt.aprintf("%s:2:", path, allocator = context.temp_allocator)))
}

// A user's configuration is plain data, so this reader refuses nothing for its size.
// The fixture is past every fixed cap such a reader used to impose: a file over 1 MiB,
// more than 4,096 providers and models, a thinking list over 64 levels, more than 32
// MCP servers, and a server with more than 256 arguments, environment entries, and
// tool aliases.
@(test)
test_configuration_of_any_size_loads_whole :: proc(t: ^testing.T) {
	body := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&body)

	strings.write_string(&body, "return { providers = {")
	strings.write_string(&body, `padded = { api_key = "`)
	strings.write_string(&body, strings.repeat("x", 1200 * 1024, context.temp_allocator))
	strings.write_string(&body, `" },`)
	for index in 1 ..= 4100 { config_test_lua_index(&body, "p", index, " = {},") }
	strings.write_string(&body, "big = { models = {")
	for index in 1 ..= 4100 { config_test_lua_index(&body, "m", index, " = {},") }
	strings.write_string(&body, "wide = { thinking = { levels = {")
	for _ in 1 ..= 100 { strings.write_string(&body, `"level",`) }
	strings.write_string(&body, "} } } } } },")

	strings.write_string(&body, "mcp = { servers = {")
	strings.write_string(&body, `s0 = { executable = "/usr/bin/serve", arguments = {`)
	for _ in 1 ..= 300 { strings.write_string(&body, `"--flag",`) }
	strings.write_string(&body, "}, environment = {")
	for index in 1 ..= 300 { config_test_lua_index(&body, "VAR", index, ` = "v",`) }
	strings.write_string(&body, "}, tools = {")
	for index in 1 ..= 300 { config_test_lua_index(&body, `["remote.`, index, `"] = {enabled = false},`) }
	strings.write_string(&body, "} },")
	for index in 1 ..= 40 { config_test_lua_index(&body, "s", index, ` = { executable = "/usr/bin/serve" },`) }
	strings.write_string(&body, "} } }")

	path := fmt.aprintf("/tmp/nabla-config-test-large-%d.lua", os.get_pid(), allocator = context.temp_allocator)
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)strings.to_string(body)) == nil)

	sources, _, servers, err, detail := load_lua_config(path)
	defer delete(detail)
	defer catalog_sources_destroy(&sources)
	defer mcp_servers_destroy(&servers)
	if !testing.expect_value(t, err, Config_Error.None) { return }
	if !testing.expect_value(t, len(sources), 4102) { return }

	big: ^Catalog_Provider_Source
	padded: ^Catalog_Provider_Source
	for &provider in sources {
		if provider.id == "big" { big = &provider }
		if provider.id == "padded" { padded = &provider }
	}
	if !testing.expect(t, big != nil && padded != nil) { return }
	testing.expect_value(t, len(big.models), 4101)
	testing.expect_value(t, len(padded.api_key.?), 1200 * 1024)

	wide_model: ^Catalog_Model_Source
	for &model in big.models {
		if model.id == "wide" { wide_model = &model }
	}
	if !testing.expect(t, wide_model != nil) { return }
	testing.expect_value(t, len(wide_model.thinking.levels.?), 100)

	if !testing.expect_value(t, len(servers), 41) { return }
	wide: ^MCP_Server_Config
	for &server in servers {
		if server.id == "s0" { wide = &server }
	}
	if !testing.expect(t, wide != nil) { return }
	testing.expect_value(t, len(wide.stdio.arguments), 300)
	testing.expect_value(t, len(wide.stdio.environment), 300)
	testing.expect_value(t, len(wide.tools), 300)
}

// config_test_lua_index writes a Lua fragment with a decimal index between its
// prefix and suffix, which is how the large fixture names its entries.
@(private)
config_test_lua_index :: proc(body: ^strings.Builder, prefix: string, index: int, suffix: string) {
	strings.write_string(body, prefix)
	strings.write_int(body, index)
	strings.write_string(body, suffix)
}
