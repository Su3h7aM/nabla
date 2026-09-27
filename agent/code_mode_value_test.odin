#+test
#+private file
package agent

import "core:strings"
import "core:testing"

code_mode_value_test_start :: proc(t: ^testing.T, source: string) -> ^Lua_Run {
	run, compiled := code_mode_lua_start(source)
	if run == nil { testing.fail_now(t, "the execution could not be created") }
	if !compiled {
		code_mode_lua_destroy(run)
		testing.fail_now(t, "the source should compile")
	}
	return run
}

// The conversion produces the document the harness carries, so the fields a script writes are
// the fields a tool reads and the fields the record keeps.
@(test)
code_mode_value_converts_tool_arguments :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(
		t,
		`return tools.test_echo({path = "README.md", missing = json.null, flags = {"a", "b"}, nested = {ok = true, count = 3}})`,
	)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "test_echo"), "the tool should install")
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)

	arguments, message := code_mode_lua_request_arguments(run, context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	defer delete(message, context.allocator)
	testing.expect_value(t, message, "")
	testing.expect_value(t, arguments.status, Tool_Arguments_Status.Valid)
	testing.expect(t, strings.contains(arguments.effective, `"path":"README.md"`), arguments.effective)
	testing.expect(t, strings.contains(arguments.effective, `"missing":null`), arguments.effective)
	testing.expect(t, strings.contains(arguments.effective, `"flags":["a","b"]`), arguments.effective)
	testing.expect(t, strings.contains(arguments.effective, `"nested":{`), arguments.effective)
	testing.expect(t, strings.contains(arguments.effective, `"ok":true`), arguments.effective)
	testing.expect(t, strings.contains(arguments.effective, `"count":3`), arguments.effective)
}

@(test)
code_mode_value_delivers_typed_output :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(
		t,
		`local r = tools.test_echo({})
return r.outcome == "success" and r.output.stdout == "done" and r.output.exit_code == 2`,
	)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "test_echo"))
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)
	ctx := Tool_Context {
		allocator = context.allocator,
	}
	result := tool_result_success(&ctx, Shell_Output{stdout = "done", exit_code = 2})
	defer tool_result_destroy(&result)
	code_mode_lua_push_result(run, &result)
	event := code_mode_lua_deliver(run, 1)
	for event == .Slice { event = code_mode_lua_resume(run) }
	testing.expect_value(t, event, Lua_Event.Returned)
	testing.expect(t, code_mode_lua_returned_boolean(run))
}

// A wrapper takes no argument or exactly one table. A second argument is refused rather than
// discarded, because silently using one of two is a bug the script cannot see.
@(test)
code_mode_value_refuses_a_second_argument :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(t, `return tools.test_echo({}, {})`)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "test_echo"), "the tool should install")
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)

	arguments, message := code_mode_lua_request_arguments(run, context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	defer delete(message, context.allocator)
	testing.expect_value(t, message, "test_echo takes one table of arguments, and was given 2")
}

// One table is the whole argument contract. A scalar is a mistake in the script, not a call
// the harness should forward and let the tool refuse.
@(test)
code_mode_value_refuses_a_non_table_argument :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(t, `return tools.test_echo("README.md")`)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "test_echo"), "the tool should install")
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)

	arguments, message := code_mode_lua_request_arguments(run, context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	defer delete(message, context.allocator)
	testing.expect_value(t, message, "test_echo takes one table of named arguments")
}

// print is the harness's, so it renders the values a script prints while debugging without
// ever calling into script code.
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
	testing.expect(t, strings.contains(lines[1], `ok = true`), lines[1])
	testing.expect(t, strings.contains(lines[1], `items = {1, 2}`), lines[1])
	testing.expect_value(t, lines[2], "<table>")
}

// A document is UTF-8, and an endpoint refuses one that is not. A Lua string is bytes, so the
// boundary is where that is decided rather than discovered by a provider. A NUL is a byte like
// any other and survives as an escape, never silently cut.
@(test)
code_mode_value_requires_utf8_at_the_boundary :: proc(t: ^testing.T) {
	cases := []struct {
		source: string,
		fault:  string,
	} {
		{`return tools.test_echo({text = "bad ` + "\xff\xfe" + ` bytes"})`, "the string at text is not valid UTF-8"},
		{`return tools.test_echo({ [string.char(255)] = 1 })`, "the key is not valid UTF-8"},
		{`return tools.test_echo({ path = "` + "\xc3" + `" })`, "the string at path is not valid UTF-8"},
		{`return { path = "` + "\xc3" + `" }`, "the string at path is not valid UTF-8"},
	}
	for c in cases {
		run := code_mode_value_test_start(t, c.source)
		// The tool is installed for every case, so the argument-boundary case reaches the
		// conversion instead of failing on an absent name.
		_ = code_mode_lua_install_tool(run, "test_echo")
		event := code_mode_lua_resume(run)
		if event == .Host_Request {
			arguments, message := code_mode_lua_request_arguments(run, context.temp_allocator)
			tool_arguments_destroy(&arguments, context.temp_allocator)
			testing.expectf(t, message == c.fault, "%q should refuse with %q, got %q", c.source, c.fault, message)
		} else {
			testing.expect_value(t, event, Lua_Event.Returned)
			_, message, _ := code_mode_lua_returned_literal(run, context.temp_allocator)
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
	value, message, _ := code_mode_lua_returned_literal(run, context.temp_allocator)
	if !testing.expect_value(t, message, "") { return }
	testing.expect(t, strings.contains(value, `café`), value)
	testing.expect(t, strings.contains(value, `nul = "a\x00b"`), value)
}

// A document carries finite numbers only: a value with no exact form is not one a script can
// hand to a tool or read back, and the refusal names where it was.
@(test)
code_mode_value_refuses_numbers_without_an_exact_form :: proc(t: ^testing.T) {
	cases := []struct {
		source: string,
		fault:  string,
	} {
		{`return 1/0`, "the number is not finite"},
		{`return { ratio = 0/0 }`, "the number at ratio is not finite"},
		{`return tools.test_echo({ ratio = -1/0 })`, "the number at ratio is not finite"},
	}
	for c in cases {
		run := code_mode_value_test_start(t, c.source)
		_ = code_mode_lua_install_tool(run, "test_echo")
		if code_mode_lua_resume(run) == .Host_Request {
			arguments, message := code_mode_lua_request_arguments(run, context.temp_allocator)
			tool_arguments_destroy(&arguments, context.temp_allocator)
			testing.expectf(t, message == c.fault, "%q should refuse with %q, got %q", c.source, c.fault, message)
		} else {
			_, message, diagnostic := code_mode_lua_returned_literal(run, context.temp_allocator)
			testing.expectf(t, message == c.fault, "%q should refuse with %q, got %q", c.source, c.fault, message)
			testing.expect_value(t, diagnostic, Code_Mode_Diagnostic.Invalid_Value)
		}
		code_mode_lua_destroy(run)
	}
}

// Table shape decides whether a value is an object or an array, and both the shape and the
// place it was found in are named, so a script author fixes the value rather than guessing.
@(test)
code_mode_value_classifies_table_shape :: proc(t: ^testing.T) {
	cases := []struct {
		source: string,
		fault:  string,
	} {
		{`local t = {} t[1] = "a" t[3] = "c" return tools.test_echo(t)`, "the array is not dense from 1"},
		{`local t = { "a", "b" } t.name = "x" return tools.test_echo(t)`, "the table mixes object fields and array indexes"},
		{`local t = {} t[true] = 1 return tools.test_echo(t)`, "the table has a key that is not a string or an array index"},
		{`local t = {} t[1.5] = 1 return tools.test_echo(t)`, "the table has a key that is not a string or an array index"},
		{`return tools.test_echo({items = {1, "two", [4] = "four"}})`, "the array at items is not dense from 1"},
		{`return {items = {1, "two", [4] = "four"}}`, "the array at items is not dense from 1"},
	}
	for c in cases {
		run := code_mode_value_test_start(t, c.source)
		_ = code_mode_lua_install_tool(run, "test_echo")
		if code_mode_lua_resume(run) == .Host_Request {
			arguments, message := code_mode_lua_request_arguments(run, context.temp_allocator)
			tool_arguments_destroy(&arguments, context.temp_allocator)
			testing.expectf(t, message == c.fault, "%q should refuse with %q, got %q", c.source, c.fault, message)
		} else {
			_, message, _ := code_mode_lua_returned_literal(run, context.temp_allocator)
			testing.expectf(t, message == c.fault, "%q should refuse with %q, got %q", c.source, c.fault, message)
		}
		code_mode_lua_destroy(run)
	}
}

@(test)
code_mode_value_rejects_cycles :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(t, `local value = {}
value.self = value
return tools.test_echo(value)`)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "test_echo"), "the tool should install")
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)

	arguments, message := code_mode_lua_request_arguments(run, context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	defer delete(message, context.allocator)
	testing.expect_value(t, message, "the value at self contains a cycle")
}

// The chunk has exactly one answer. Zero values are nil, one value is written as the Lua
// literal that builds it, and more than one is refused rather than silently truncated. Object
// fields are written in name order, so each case names the fragments its encoding must carry.
@(test)
code_mode_value_converts_the_chunk_return :: proc(t: ^testing.T) {
	cases := []struct {
		source:    string,
		fragments: []string,
	} {
		{`return "text"`, []string{`"text"`}},
		{`return 42`, []string{`42`}},
		{`return true`, []string{`true`}},
		{`return json.null`, []string{`json.null`}},
		{`local x = 1`, []string{`nil`}},
		{`return { status = "ok", items = { 1, 2, 3 } }`, []string{`items = {1, 2, 3}`, `status = "ok"`}},
		{`return { nested = { deep = { flag = false } } }`, []string{`nested = {deep = {flag = false}}`}},
	}
	for c in cases {
		run := code_mode_value_test_start(t, c.source)
		testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Returned)
		value, message, diagnostic := code_mode_lua_returned_literal(run, context.temp_allocator)
		if !testing.expectf(t, message == "", "%q should convert: %s", c.source, message) {
			code_mode_lua_destroy(run)
			continue
		}
		testing.expect_value(t, diagnostic, Code_Mode_Diagnostic.None)
		for fragment in c.fragments {
			testing.expectf(t, strings.contains(value, fragment), "%q should carry %s, got %s", c.source, fragment, value)
		}
		code_mode_lua_destroy(run)
	}
}

@(test)
code_mode_value_refuses_an_ambiguous_return :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(t, `return "first", "second"`)
	defer code_mode_lua_destroy(run)
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Returned)
	_, message, _ := code_mode_lua_returned_literal(run, context.temp_allocator)
	testing.expect(t, strings.contains(message, "more than one value"), message)
}

// A function is not a value the boundary carries, and the refusal names its type rather than
// pretending the script returned nothing.
@(test)
code_mode_value_refuses_a_return_the_conversion_cannot_carry :: proc(t: ^testing.T) {
	run := code_mode_value_test_start(t, `return {run = function() end}`)
	defer code_mode_lua_destroy(run)
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Returned)
	_, message, diagnostic := code_mode_lua_returned_literal(run, context.temp_allocator)
	testing.expect_value(t, message, "the function at run cannot be converted")
	testing.expect_value(t, diagnostic, Code_Mode_Diagnostic.Invalid_Value)
}
