package agent

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
test_lua_config_roundtrip :: proc(t: ^testing.T) {
	path := fmt.aprintf("/tmp/svan-config-test-%d.lua", os.get_pid(), allocator = context.temp_allocator)
	defer os.remove(path)
	write_err := os.write_entire_file(
		path,
		`return { providers = { acme = {
			base_url = "https://api.acme.test",
			api = "openai_responses",
			api_key_env = "ACME_KEY",
			models = {
				chat = {
					display_name = "Chat",
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
	defer config_sources_destroy(&sources)
	testing.expect_value(t, len(sources), 1)
	provider := sources[0]
	testing.expect_value(t, provider.id, "acme")
	testing.expect_value(t, provider.base_url, "https://api.acme.test")
	testing.expect_value(t, provider.api, "openai_responses")
	testing.expect_value(t, provider.api_key_env, "ACME_KEY")
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

	_, missing_err := load_lua_config("/tmp/svan-config-test-missing.lua")
	testing.expect_value(t, missing_err, Config_Error.Read)
}

@(test)
test_lua_config_failures_leave_no_partial_sources :: proc(t: ^testing.T) {
	cases := []string {
		`return { providers = { acme = { models = { chat = { display_name = 42 } } } } }`,
		`return { providers = { acme = { api_key_env = "A", api_key = "B" } } }`,
		`return { providers = { acme = { models = { chat = { tools = true }, bad = { context_window = -1 } } } } }`,
		`return { providers = { acme = { models = { chat = { input_modalities = {"text"}, output_modalities = "text" } } } } }`,
	}
	for config, i in cases {
		path := fmt.aprintf("/tmp/svan-config-test-fail-%d-%d.lua", os.get_pid(), i, allocator = context.temp_allocator)
		defer os.remove(path)
		testing.expect(t, os.write_entire_file(path, transmute([]u8)config) == nil)
		sources, err := load_lua_config(path)
		testing.expectf(t, err != .None, "case %d loaded without error", i)
		testing.expect_value(t, len(sources), 0)
		config_sources_destroy(&sources)
	}
}
