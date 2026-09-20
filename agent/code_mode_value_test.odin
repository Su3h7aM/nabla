#+test
#+private file
package agent

import "core:strings"
import "core:testing"

code_mode_value_test_start :: proc(t: ^testing.T, source: string) -> ^Lua_Run {
	run, compiled := code_mode_lua_start(context.allocator, lua_limits_default(), source)
	if run == nil { testing.fail_now(t, "the execution could not be created") }
	if !compiled {
		code_mode_lua_destroy(run)
		testing.fail_now(t, "the source should compile")
	}
	return run
}

@(test)
code_mode_value_converts_tool_arguments_to_json :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(t, `return tools["test.echo"]({path = "README.md", flags = {"a", "b"}, nested = {ok = true, count = 3}})`)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "test.echo"), "the tool should install")
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)

	arguments, message := code_mode_lua_request_json(run, context.allocator)
	defer delete(arguments)
	testing.expect_value(t, message, "")
	testing.expect(t, strings.contains(arguments, `"path":"README.md"`), arguments)
	testing.expect(t, strings.contains(arguments, `"flags":["a","b"]`), arguments)
	testing.expect(t, strings.contains(arguments, `"nested":{`), arguments)
	testing.expect(t, strings.contains(arguments, `"ok":true`), arguments)
	testing.expect(t, strings.contains(arguments, `"count":3`), arguments)
}

@(test)
code_mode_value_delivers_a_tool_envelope_as_a_table :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(
		t,
		`local result = tools["test.echo"]({})
return result.status .. ":" .. result.data.text .. ":" .. tostring(result.data.items[2])`,
	)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "test.echo"), "the tool should install")
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)

	event := code_mode_lua_deliver_json(run, `{"status":"success","message":"","data":{"text":"done","items":[1,2,3]}}`, context.allocator)
	for event == .Slice { event = code_mode_lua_resume(run) }
	testing.expect_value(t, event, Lua_Event.Returned)
	text, present := code_mode_lua_returned_string(run)
	testing.expect(t, present, "the script should return its composed text")
	testing.expect_value(t, text, "success:done:2")
}

@(test)
code_mode_value_rejects_cycles :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(t, `local value = {}
value.self = value
return tools["test.echo"](value)`)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "test.echo"), "the tool should install")
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)

	arguments, message := code_mode_lua_request_json(run, context.allocator)
	defer delete(arguments)
	testing.expect_value(t, arguments, "")
	testing.expect_value(t, message, "the tool arguments contain a cycle")
}
