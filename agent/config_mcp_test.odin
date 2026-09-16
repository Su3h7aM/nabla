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
test_mcp_config_reads_a_stdio_server :: proc(t: ^testing.T) {
	servers, err := mcp_config_load(
		t,
		"stdio",
		`return { mcp = { servers = { files = {
			trusted = true,
			executable = "/usr/bin/serve",
			arguments = {"--root", "/tmp"},
			working_directory = "/tmp",
			environment = {TOKEN = "${TOKEN}"},
			tools = {files_read = "read.file", files_list = "list.dir"},
			discovery_timeout_ms = 1000,
			call_timeout_ms = 2000,
		} } } }`,
	)
	defer mcp_servers_destroy(&servers)
	if !testing.expect_value(t, err, Config_Error.None) { return }
	if !testing.expect_value(t, len(servers), 1) { return }

	server := servers[0]
	testing.expect_value(t, server.id, "files")
	testing.expect_value(t, server.stdio.executable, "/usr/bin/serve")
	testing.expect_value(t, len(server.stdio.arguments), 2)
	testing.expect_value(t, server.stdio.arguments[0], "--root")
	testing.expect_value(t, server.stdio.working_directory, "/tmp")
	testing.expect_value(t, len(server.stdio.environment), 1)
	testing.expect_value(t, server.stdio.environment[0].name, "TOKEN")
	testing.expect_value(t, server.stdio.environment[0].value, "${TOKEN}")
	if !testing.expect_value(t, len(server.tools), 2) { return }
	// A Lua table's iteration order is unspecified, so the mapping is checked as a
	// set rather than by position.
	matched := 0
	for alias in server.tools {
		if alias.name == "files_read" {
			testing.expect_value(t, alias.remote_name, "read.file")
			matched += 1
		}
		if alias.name == "files_list" {
			testing.expect_value(t, alias.remote_name, "list.dir")
			matched += 1
		}
	}
	testing.expect_value(t, matched, 2)
	testing.expect_value(t, server.discovery_timeout, time.Second)
	testing.expect_value(t, server.call_timeout, 2 * time.Second)
	// A bound the file does not state falls back to the default rather than to zero.
	testing.expect_value(t, server.maximum_call_timeout, MCP_DEFAULT_MAXIMUM_CALL_TIMEOUT)
}

@(test)
test_mcp_config_refuses_what_it_cannot_run :: proc(t: ^testing.T) {
	cases := []string {
		// Not trusted: the trust decision is what gates starting a process.
		`return { mcp = { servers = { s = { executable = "/usr/bin/x", tools = {a = "b"} } } } }`,
		`return { mcp = { servers = { s = { trusted = false, executable = "/usr/bin/x", tools = {a = "b"} } } } }`,
		// A relative executable would depend on a search rule the user did not write.
		`return { mcp = { servers = { s = { trusted = true, executable = "serve", tools = {a = "b"} } } } }`,
		// An allowlist with nothing in it would expose nothing.
		`return { mcp = { servers = { s = { trusted = true, executable = "/usr/bin/x", tools = {} } } } }`,
		`return { mcp = { servers = { s = { trusted = true, executable = "/usr/bin/x" } } } }`,
		// An alias the provider could not be told about.
		`return { mcp = { servers = { s = { trusted = true, executable = "/usr/bin/x", tools = {["not a name"] = "b"} } } } }`,
		// A remote name the server cannot match.
		`return { mcp = { servers = { s = { trusted = true, executable = "/usr/bin/x", tools = {a = ""} } } } }`,
		// An unusable environment name and a non-string value.
		`return { mcp = { servers = { s = { trusted = true, executable = "/usr/bin/x", environment = {[" A"] = "b"}, tools = {a = "b"} } } } }`,
		`return { mcp = { servers = { s = { trusted = true, executable = "/usr/bin/x", environment = {A = 1}, tools = {a = "b"} } } } }`,
		// A call bound above its own ceiling.
		`return { mcp = { servers = { s = { trusted = true, executable = "/usr/bin/x", tools = {a = "b"}, call_timeout_ms = 5000, maximum_call_timeout_ms = 1000 } } } }`,
		// A bound of zero is not a bound.
		`return { mcp = { servers = { s = { trusted = true, executable = "/usr/bin/x", tools = {a = "b"}, call_timeout_ms = 0 } } } }`,
	}
	for body in cases {
		servers, err := mcp_config_load(t, "refuse", body)
		testing.expectf(t, err != .None, "%s should be refused", body)
		mcp_servers_destroy(&servers)
	}
}

// A configuration with no MCP section is a valid setup, and the aggregate is empty
// rather than absent.
@(test)
test_mcp_config_absent_is_empty :: proc(t: ^testing.T) {
	servers, err := mcp_config_load(t, "absent", `return { }`)
	defer mcp_servers_destroy(&servers)
	testing.expect_value(t, err, Config_Error.None)
	testing.expect_value(t, len(servers), 0)
}
