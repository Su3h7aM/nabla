#+test
package agent

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

// mcp_config_load writes a configuration and reads it back, so a test asserts what a
// user's file becomes rather than a struct it built itself. The path carries the
// caller's own name because the tests run concurrently.
@(private)
mcp_config_load :: proc(t: ^testing.T, name, body: string, allocator := context.allocator) -> ([dynamic]MCP_Server_Config, Config_Error) {
	path := fmt.aprintf("/tmp/nabla-mcp-%s-%d.lua", name, os.get_pid(), allocator = context.temp_allocator)
	defer os.remove(path)
	write_err := os.write_entire_file(path, body)
	testing.expect(t, write_err == nil)
	_, _, servers, err := load_lua_config_full(path, allocator)
	return servers, err
}

@(test)
test_mcp_config_reads_a_minimal_stdio_server :: proc(t: ^testing.T) {
	servers, err := mcp_config_load(t, "stdio-minimal", `return { mcp = { servers = { files = { executable = "/usr/bin/serve" } } } }`)
	defer mcp_servers_destroy(&servers)
	if !testing.expect_value(t, err, Config_Error.None) { return }
	if !testing.expect_value(t, len(servers), 1) { return }

	server := servers[0]
	testing.expect_value(t, server.id, "files")
	testing.expect_value(t, server.stdio.executable, "/usr/bin/serve")
	testing.expect_value(t, len(server.tools), 0)
	testing.expect_value(t, server.discovery_timeout, MCP_DEFAULT_DISCOVERY_TIMEOUT)
	testing.expect_value(t, server.call_timeout, MCP_DEFAULT_CALL_TIMEOUT)
	testing.expect_value(t, server.maximum_call_timeout, MCP_DEFAULT_MAXIMUM_CALL_TIMEOUT)
}

@(test)
test_mcp_config_reads_optional_launch_and_tool_overrides :: proc(t: ^testing.T) {
	servers, err := mcp_config_load(
		t,
		"stdio-options",
		`return { mcp = { servers = { files = {
			executable = "/usr/bin/serve",
			arguments = {"--root", "/tmp"},
			working_directory = "/tmp",
			environment = {TOKEN = "${TOKEN}"},
			tools = {
				["read.file"] = {name = "read"},
				["delete.file"] = {enabled = false},
			},
			discovery_timeout_ms = 1000,
			call_timeout_ms = 2000,
		} } } }`,
	)
	defer mcp_servers_destroy(&servers)
	if !testing.expect_value(t, err, Config_Error.None) { return }
	server := servers[0]
	testing.expect_value(t, len(server.stdio.arguments), 2)
	testing.expect_value(t, server.stdio.arguments[0], "--root")
	testing.expect_value(t, server.stdio.working_directory, "/tmp")
	testing.expect_value(t, len(server.stdio.environment), 1)
	if !testing.expect_value(t, len(server.tools), 2) { return }
	matched := 0
	for tool in server.tools {
		if tool.remote_name == "read.file" {
			testing.expect(t, tool.enabled)
			testing.expect_value(t, tool.name, "read")
			matched += 1
		}
		if tool.remote_name == "delete.file" {
			testing.expect(t, !tool.enabled)
			testing.expect_value(t, tool.name, "")
			matched += 1
		}
	}
	testing.expect_value(t, matched, 2)
	testing.expect_value(t, server.discovery_timeout, time.Second)
	testing.expect_value(t, server.call_timeout, 2 * time.Second)
	testing.expect_value(t, server.maximum_call_timeout, MCP_DEFAULT_MAXIMUM_CALL_TIMEOUT)
}

@(test)
test_mcp_stdio_environment_inherits_and_applies_overrides :: proc(t: ^testing.T) {
	servers, err := mcp_config_load(
		t,
		"environment",
		`return { mcp = { servers = { s = {
			executable = "/usr/bin/x",
			environment = {NABLA_MCP_TEST_VALUE = "configured"},
		} } } }`,
	)
	defer mcp_servers_destroy(&servers)
	if !testing.expect_value(t, err, Config_Error.None) { return }
	stdio := mcp_stdio_config(servers[0])
	found_path := false
	found_override := false
	for entry in stdio.environment {
		if entry.name == "PATH" { found_path = true }
		if entry.name == "NABLA_MCP_TEST_VALUE" && entry.value == "configured" { found_override = true }
	}
	testing.expect(t, found_path, "a configured server inherits the normal process environment")
	testing.expect(t, found_override, "configured variables are added to the inherited environment")
}

@(test)
test_mcp_config_refuses_what_it_cannot_run :: proc(t: ^testing.T) {
	cases := []string {
		`return { mcp = { servers = { s = { executable = "serve" } } } }`,
		`return { mcp = { servers = { ["bad server"] = { executable = "/usr/bin/x" } } } }`,
		`return { mcp = { servers = { s = { executable = "/usr/bin/x", tools = {a = false} } } } }`,
		`return { mcp = { servers = { s = { executable = "/usr/bin/x", tools = {a = {name = "bad name"}} } } } }`,
		`return { mcp = { servers = { s = { executable = "/usr/bin/x", tools = {a = {enabled = false, name = "b"}} } } } }`,
		`return { mcp = { servers = { s = { executable = "/usr/bin/x", environment = {[" A"] = "b"} } } } }`,
		`return { mcp = { servers = { s = { executable = "/usr/bin/x", environment = {A = 1} } } } }`,
		`return { mcp = { servers = { s = { executable = "/usr/bin/x", call_timeout_ms = 5000, maximum_call_timeout_ms = 1000 } } } }`,
		`return { mcp = { servers = { s = { executable = "/usr/bin/x", call_timeout_ms = 0 } } } }`,
	}
	for body in cases {
		servers, err := mcp_config_load(t, "refuse", body)
		testing.expectf(t, err != .None, "%s should be refused", body)
		mcp_servers_destroy(&servers)
	}
}

@(test)
test_mcp_config_absent_is_empty :: proc(t: ^testing.T) {
	servers, err := mcp_config_load(t, "absent", `return { }`)
	defer mcp_servers_destroy(&servers)
	testing.expect_value(t, err, Config_Error.None)
	testing.expect_value(t, len(servers), 0)
}
