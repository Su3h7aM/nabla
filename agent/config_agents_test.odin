#+test
package agent

import "core:fmt"
import "core:os"
import "core:testing"

// acp_agents_config_load writes a configuration and reads it back, so a test asserts what
// a user's file becomes rather than a struct it built itself. The path carries the
// caller's own name because the tests run concurrently.
@(private)
acp_agents_config_load :: proc(t: ^testing.T, name, body: string, allocator := context.allocator) -> ([]ACP_Agent_Config, Config_Error) {
	path := fmt.aprintf("/tmp/nabla-agents-%s-%d.lua", name, os.get_pid(), allocator = context.temp_allocator)
	defer os.remove(path)
	write_err := os.write_entire_file(path, body)
	testing.expect(t, write_err == nil)
	_, harness_options, _, err, detail := load_lua_config_full(path, allocator)
	if detail != "" { delete(detail, allocator) }
	return harness_options.acp_agents, err
}

@(test)
test_agents_config_reads_programs_in_name_order :: proc(t: ^testing.T) {
	agents, err := acp_agents_config_load(
		t,
		"read",
		`return { agents = {
			opencode = { command = "/home/me/.local/bin/opencode" },
			goose = { command = "goose", arguments = {"acp"}, description = "Goose, general coding agent" },
		} }`,
	)
	defer ACP_Agent_Configs_Destroy(agents)
	if !testing.expect_value(t, err, Config_Error.None) { return }
	if !testing.expect_value(t, len(agents), 2) { return }
	testing.expect_value(t, agents[0].name, "goose")
	testing.expect_value(t, agents[0].command, "goose")
	testing.expect_value(t, len(agents[0].arguments), 1)
	testing.expect_value(t, agents[0].arguments[0], "acp")
	testing.expect_value(t, agents[0].description, "Goose, general coding agent")
	testing.expect_value(t, agents[1].name, "opencode")
	testing.expect_value(t, agents[1].command, "/home/me/.local/bin/opencode")
	testing.expect_value(t, len(agents[1].arguments), 0)
	testing.expect_value(t, agents[1].description, "")

	// A field the reader does not know, or a missing command, is refused rather than
	// half-configured.
	cases := []string {
		`return { agents = { goose = { command = "goose", description = "d", model = "m" } } }`,
		`return { agents = { goose = { arguments = {"acp"} } } }`,
	}
	for body in cases {
		refused, refused_err := acp_agents_config_load(t, "refuse", body)
		testing.expectf(t, refused_err != .None, "%s should be refused", body)
		ACP_Agent_Configs_Destroy(refused)
	}
}
