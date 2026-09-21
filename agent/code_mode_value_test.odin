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

// A wrapper takes no argument or exactly one table. A second argument is refused rather
// than discarded, because silently using one of two is a bug the script cannot see.
@(test)
code_mode_value_refuses_a_second_argument :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(t, `return tools.test_echo({}, {})`)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "test_echo"), "the tool should install")
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)

	arguments, message := code_mode_lua_request_json(run, context.allocator)
	defer delete(arguments, context.allocator)
	defer delete(message, context.allocator)
	testing.expect_value(t, arguments, "")
	testing.expect_value(t, message, "test_echo takes one table of arguments, and was given 2")
}

// One table is the whole argument contract. A scalar is a mistake in the script, not a
// call the harness should forward and let the tool refuse.
@(test)
code_mode_value_refuses_a_non_table_argument :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(t, `return tools.test_echo("README.md")`)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "test_echo"), "the tool should install")
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)

	arguments, message := code_mode_lua_request_json(run, context.allocator)
	defer delete(arguments, context.allocator)
	defer delete(message, context.allocator)
	testing.expect_value(t, arguments, "")
	testing.expect_value(t, message, "test_echo takes one table of named arguments")
}

// print is the harness's, so it renders the values a script prints while debugging
// without ever calling into script code.
@(test)
code_mode_value_prints_the_values_a_script_debugs_with :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(
		t,
		`print("text", 42, true, false, nil, json.null)
print({ok = true, items = {1, 2}})
print({bad = function() end})
return "done"`,
	)
	defer code_mode_lua_destroy(run)
	event := code_mode_lua_resume(run)
	for event == .Slice { event = code_mode_lua_resume(run) }
	testing.expect_value(t, event, Lua_Event.Returned)

	logs := code_mode_lua_logs(run)
	lines := strings.split(logs, "\n", context.temp_allocator)
	if !testing.expect_value(t, len(lines), 4) { return }
	testing.expect_value(t, lines[0], "text 42 true false nil null")
	testing.expect(t, strings.contains(lines[1], `"ok":true`), lines[1])
	testing.expect(t, strings.contains(lines[1], `"items":[1,2]`), lines[1])
	testing.expect_value(t, lines[2], "<table>")
}

// A JSON document is UTF-8, and an endpoint refuses one that is not. A Lua string is
// bytes, so the boundary is where that is decided rather than discovered by a provider.
// A NUL is a byte like any other and survives as an escape, never silently cut.
@(test)
code_mode_value_requires_utf8_at_the_boundary :: proc(t: ^testing.T) {
	cases := []struct {
		source: string,
		fault:  string,
	} {
		{`return "bad ` + "\xff\xfe" + ` bytes"`, "a string is not valid UTF-8"},
		{`return { [string.char(255)] = 1 }`, "a table key is not valid UTF-8"},
		{`return tools.test_echo({ path = "` + "\xc3" + `" })`, "a string is not valid UTF-8"},
	}
	for c in cases {
		run := code_mode_value_test_start(t, c.source)
		// The tool is installed for every case, so the argument-boundary case reaches the
		// conversion instead of failing on an absent name.
		_ = code_mode_lua_install_tool(run, "test_echo")
		event := code_mode_lua_resume(run)
		if event == .Host_Request {
			arguments, message := code_mode_lua_request_json(run, context.temp_allocator)
			testing.expectf(t, message == c.fault, "%q should refuse with %q, got %q", c.source, c.fault, message)
			testing.expect_value(t, arguments, "")
		} else {
			testing.expect_value(t, event, Lua_Event.Returned)
			_, message := code_mode_lua_returned_json(run, context.temp_allocator)
			testing.expectf(t, message == c.fault, "%q should refuse with %q, got %q", c.source, c.fault, message)
		}
		code_mode_lua_destroy(run)
	}
}

@(test)
code_mode_value_keeps_multibyte_text_and_nul :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(t, `return { text = "caf\xc3\xa9 \xe2\x86\x92 ok", nul = "a" .. string.char(0) .. "b" }`)
	defer code_mode_lua_destroy(run)
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Returned)
	value, message := code_mode_lua_returned_json(run, context.temp_allocator)
	if !testing.expect_value(t, message, "") { return }
	defer json.destroy_value(value, context.temp_allocator)
	encoded, encode_err := json.marshal(value, allocator = context.temp_allocator)
	if !testing.expect(t, encode_err == nil, "the value should encode") { return }
	testing.expect(t, strings.contains(string(encoded), `café`), string(encoded))
	testing.expect(t, strings.contains(string(encoded), `"nul":"a\u0000b"`), string(encoded))
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
