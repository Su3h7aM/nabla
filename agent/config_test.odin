#+test
package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

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
				},
				mini = {thinking = false, tools = false},
				old = {disabled = true},
			},
		} } }`,
	)
	testing.expect(t, write_err == nil)

	sources, err := load_lua_config(path)
	testing.expect_value(t, err, Config_Error.None)
	defer catalog_sources_destroy(&sources)
	testing.expect_value(t, len(sources), 1)
	provider := sources[0]
	testing.expect_value(t, provider.id, "acme")
	testing.expect_value(t, provider.base_url, "https://api.acme.test")
	testing.expect_value(t, provider.api, "openai_responses")
	testing.expect(t, provider.transport_present)
	testing.expect_value(t, provider.transport, Provider_Transport.WebSocket)
	testing.expect_value(t, provider.api_key, "ACME_KEY")
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
	testing.expect_value(t, chat^.display_name, "Chat")
	testing.expect_value(t, chat^.api, "openai_chat_completions")
	testing.expect_value(t, chat^.context_window, 100000)
	testing.expect_value(t, chat^.max_output_tokens, 4096)
	testing.expect(t, chat^.tools)
	testing.expect_value(t, len(chat^.input_modalities), 1)
	testing.expect_value(t, chat^.input_modalities[0], "text")
	testing.expect_value(t, len(chat^.output_modalities), 1)
	testing.expect_value(t, chat^.output_modalities[0], "text")
	testing.expect(t, chat^.thinking.toggle)
	testing.expect_value(t, len(chat^.thinking.levels), 2)
	testing.expect_value(t, chat^.thinking.levels[0], "low")
	testing.expect_value(t, chat^.thinking.levels[1], "high")
	testing.expect(t, mini^.thinking.present && mini^.thinking.blocked)
	testing.expect(t, old^.disabled_present && old^.disabled)

	// A missing config is a valid empty setup, not an error; a path that exists
	// but cannot be read as a file still is.
	_, missing_err := load_lua_config("/tmp/nabla-config-test-missing.lua")
	testing.expect_value(t, missing_err, Config_Error.Missing)
	_, unreadable_err := load_lua_config("/tmp")
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
		sources, err := load_lua_config(path)
		testing.expectf(t, err != .None, "case %d loaded without error", i)
		testing.expect_value(t, len(sources), 0)
		catalog_sources_destroy(&sources)
	}
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

	sources, _, servers, err := load_lua_config_full(path)
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
	testing.expect_value(t, len(padded.api_key), 1200 * 1024)

	wide_model: ^Catalog_Model_Source
	for &model in big.models {
		if model.id == "wide" { wide_model = &model }
	}
	if !testing.expect(t, wide_model != nil) { return }
	testing.expect_value(t, len(wide_model.thinking.levels), 100)

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
