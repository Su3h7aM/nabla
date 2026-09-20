#+test
#+private file
package agent

import "core:encoding/json"
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
	run := code_mode_value_test_start(
		t,
		`return tools.test_echo({path = "README.md", missing = json.null, flags = {"a", "b"}, nested = {ok = true, count = 3}})`,
	)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "test_echo"), "the tool should install")
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)

	arguments, message := code_mode_lua_request_json(run, context.allocator)
	defer delete(arguments)
	testing.expect_value(t, message, "")
	testing.expect(t, strings.contains(arguments, `"path":"README.md"`), arguments)
	testing.expect(t, strings.contains(arguments, `"missing":null`), arguments)
	testing.expect(t, strings.contains(arguments, `"flags":["a","b"]`), arguments)
	testing.expect(t, strings.contains(arguments, `"nested":{`), arguments)
	testing.expect(t, strings.contains(arguments, `"ok":true`), arguments)
	testing.expect(t, strings.contains(arguments, `"count":3`), arguments)
}

@(test)
code_mode_value_delivers_a_tool_envelope_as_a_table :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(
		t,
		`local result = tools.test_echo({})
return result.status .. ":" .. result.data.text .. ":" .. tostring(result.data.items[2]) .. ":" .. tostring(result.data.none == json.null)`,
	)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "test_echo"), "the tool should install")
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)

	event := code_mode_lua_deliver_json(run, `{"status":"success","message":"","data":{"text":"done","items":[1,2,3],"none":null}}`, context.allocator)
	for event == .Slice { event = code_mode_lua_resume(run) }
	testing.expect_value(t, event, Lua_Event.Returned)
	text, present := code_mode_lua_returned_string(run)
	testing.expect(t, present, "the script should return its composed text")
	testing.expect_value(t, text, "success:done:2:true")
}

@(test)
code_mode_value_rejects_cycles :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(t, `local value = {}
value.self = value
return tools.test_echo(value)`)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "test_echo"), "the tool should install")
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)

	arguments, message := code_mode_lua_request_json(run, context.allocator)
	defer delete(arguments)
	testing.expect_value(t, arguments, "")
	testing.expect_value(t, message, "the value contains a cycle")
}

// The chunk has exactly one answer. Zero values are JSON null, one value is converted
// as it stands, and more than one is refused rather than silently truncated. Object key
// order is the map's, so each case names the fragments its encoding must carry.
@(test)
code_mode_value_converts_the_chunk_return :: proc(t: ^testing.T) {
	cases := []struct {
		source:    string,
		fragments: []string,
	} {
		{`return "text"`, []string{`"text"`}},
		{`return 42`, []string{`42`}},
		{`return true`, []string{`true`}},
		{`return json.null`, []string{`null`}},
		{`local x = 1`, []string{`null`}},
		{`return { status = "ok", items = { 1, 2, 3 } }`, []string{`"status":"ok"`, `"items":[1,2,3]`}},
		{`return { nested = { deep = { flag = false } } }`, []string{`"nested":{"deep":{"flag":false}}`}},
	}
	for c in cases {
		run := code_mode_value_test_start(t, c.source)
		testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Returned)
		value, message := code_mode_lua_returned_json(run, context.temp_allocator)
		if !testing.expectf(t, message == "", "%q should convert: %s", c.source, message) {
			code_mode_lua_destroy(run)
			continue
		}
		encoded, encode_err := json.marshal(value, allocator = context.temp_allocator)
		testing.expectf(t, encode_err == nil, "%q should encode", c.source)
		for fragment in c.fragments {
			testing.expectf(t, strings.contains(string(encoded), fragment), "%q should carry %s, got %s", c.source, fragment, string(encoded))
		}
		json.destroy_value(value, context.temp_allocator)
		code_mode_lua_destroy(run)
	}
}

@(test)
code_mode_value_refuses_an_ambiguous_return :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(t, `return "first", "second"`)
	defer code_mode_lua_destroy(run)
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Returned)
	_, message := code_mode_lua_returned_json(run, context.temp_allocator)
	testing.expect(t, strings.contains(message, "more than one value"), message)
}

@(test)
code_mode_value_refuses_a_return_that_is_not_json :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(t, `return function() end`)
	defer code_mode_lua_destroy(run)
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Returned)
	_, message := code_mode_lua_returned_json(run, context.temp_allocator)
	testing.expect(t, strings.contains(message, "cannot be written as JSON"), message)
}
