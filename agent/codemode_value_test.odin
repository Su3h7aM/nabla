#+test
#+private file
package agent

import "core:fmt"
import "core:strings"
import "core:testing"

codemode_value_test_start :: proc(t: ^testing.T, source: string) -> ^Lua_Run {
	run, compiled := codemode_lua_start(source)
	if run == nil { testing.fail_now(t, "the execution could not be created") }
	if !compiled {
		testing.expect(t, false, run.message)
		codemode_lua_destroy(run)
		testing.fail_now(t)
	}
	_ = codemode_lua_install_tool(run, "test_echo")
	return run
}

codemode_value_test_settle :: proc(run: ^Lua_Run) -> Lua_Event {
	event := codemode_lua_resume(run)
	for event == .Slice { event = codemode_lua_resume(run) }
	return event
}

// A script's table becomes the arguments document the child is admitted from, with fields in
// name order so the same table is always the same text.
@(test)
codemode_value_writes_tool_arguments :: proc(t: ^testing.T) {
	run := codemode_value_test_start(
		t,
		`return tools.test_echo({path = "README.md", missing = json.null, flags = {"a", "b"}, nested = {ok = true, count = 3}, ratio = 0.5})`,
	)
	defer codemode_lua_destroy(run)
	testing.expect_value(t, codemode_value_test_settle(run), Lua_Event.Host_Request)
	text, message := codemode_lua_request_arguments(run)
	defer delete(text)
	defer delete(message)
	testing.expect_value(t, message, "")
	testing.expect_value(t, text, `{"flags":["a","b"],"missing":null,"nested":{"count":3,"ok":true},"path":"README.md","ratio":0.5}`)

	array := codemode_value_test_start(t, `return tools.test_echo({"README.md"})`)
	defer codemode_lua_destroy(array)
	testing.expect_value(t, codemode_value_test_settle(array), Lua_Event.Host_Request)
	refused, refusal := codemode_lua_request_arguments(array)
	defer delete(refused)
	defer delete(refusal)
	testing.expect_value(t, refusal, "test_echo takes a table of named arguments, and was given an array")
}

@(test)
codemode_value_delivers_typed_output :: proc(t: ^testing.T) {
	run := codemode_value_test_start(
		t,
		`local r = tools.test_echo()
return r.outcome == "success" and r.output.stdout == "done" and r.output.exit_code == 2 and "yes" or "no"`,
	)
	defer codemode_lua_destroy(run)
	testing.expect_value(t, codemode_value_test_settle(run), Lua_Event.Host_Request)
	ctx := Tool_Context {
		allocator = context.allocator,
	}
	result := tool_result_success(&ctx, Shell_Output{stdout = "done", exit_code = 2})
	defer tool_result_destroy(&result)
	testing.expect(t, codemode_lua_keep_result(run, 1, &result), "the result should be kept")
	codemode_lua_answer_kept(run, 1)
	testing.expect_value(t, codemode_value_test_settle(run), Lua_Event.Returned)
	value, _ := codemode_lua_returned_string(run)
	testing.expect_value(t, value, "yes")
}

// print renders what a script debugs with and never calls into script code. The log is
// returned whole, however much a script prints.
@(test)
codemode_value_prints_the_values_a_script_debugs_with :: proc(t: ^testing.T) {
	run := codemode_value_test_start(
		t,
		`print("text", 42, true, nil, json.null)
print({ok = true, items = {1, 2}})
print({bad = function() end})
print(string.rep("x", 20000))`,
	)
	defer codemode_lua_destroy(run)
	testing.expect_value(t, codemode_value_test_settle(run), Lua_Event.Returned)
	logs := string(run.logs[:])
	expected := strings.concatenate(
		{"text 42 true nil json.null\n{items = {1, 2}, ok = true}\n<table>\n", strings.repeat("x", 20_000, context.temp_allocator), "\n"},
		context.temp_allocator,
	)
	testing.expect_value(t, logs, expected)
}

// One walk serves arguments, json.encode, and the returned value, so its refusals are
// checked once, through the return, each naming what it refused and where.
@(test)
codemode_value_refuses_what_it_cannot_carry :: proc(t: ^testing.T) {
	cases := []struct {
		source:     string,
		message:    string,
		diagnostic: Codemode_Diagnostic,
	} {
		{`return {text = "bad ` + "\xff" + `"}`, "the string at text is not valid UTF-8", .Invalid_Value},
		{`return {[string.char(255)] = 1}`, "the field name is not valid UTF-8", .Invalid_Value},
		{`return {ratio = 0/0}`, "the number at ratio is not finite", .Invalid_Value},
		{`return {items = {1, "two", [4] = "four"}}`, "the array at items is not dense from 1", .Invalid_Value},
		{`return {"a", name = "x"}`, "the table mixes named fields and array indexes", .Invalid_Value},
		{`return {[1.5] = 1}`, "the table has a key that is not a string or an array index", .Invalid_Value},
		{`local value = {} value.self = value return value`, "the table at self contains a cycle", .Invalid_Value},
		{`return {run = print}`, "the function at run cannot be converted", .Invalid_Value},
		{`return 1, 2`, "the chunk returned more than one value; return one table instead", .Invalid_Value},
	}
	for test_case in cases {
		run := codemode_value_test_start(t, test_case.source)
		testing.expect_value(t, codemode_value_test_settle(run), Lua_Event.Returned)
		literal, message, diagnostic := codemode_lua_returned_literal(run)
		testing.expectf(t, message == test_case.message, "%q: got %q", test_case.source, message)
		testing.expect_value(t, diagnostic, test_case.diagnostic)
		delete(literal)
		delete(message)
		codemode_lua_destroy(run)
	}

	// The refusal names the whole path, however long the field name is.
	long_name := strings.repeat("n", 200, context.temp_allocator)
	source := strings.concatenate({`local value = {} value["`, long_name, `"] = function() end return value`}, context.temp_allocator)
	run := codemode_value_test_start(t, source)
	defer codemode_lua_destroy(run)
	testing.expect_value(t, codemode_value_test_settle(run), Lua_Event.Returned)
	literal, message, _ := codemode_lua_returned_literal(run)
	defer delete(literal)
	defer delete(message)
	testing.expect_value(t, message, fmt.aprintf("the function at %s cannot be converted", long_name, allocator = context.temp_allocator))
}

@(test)
codemode_value_converts_64_nested_tables_through_json :: proc(t: ^testing.T) {
	run := codemode_value_test_start(t, `local value = 1
for i = 1, 64 do value = {value = value} end
return json.decode(json.encode(value))`)
	defer codemode_lua_destroy(run)
	testing.expect_value(t, codemode_value_test_settle(run), Lua_Event.Returned)
	literal, message, diagnostic := codemode_lua_returned_literal(run)
	defer delete(literal)
	defer delete(message)
	testing.expect_value(t, message, "")
	testing.expect_value(t, diagnostic, Codemode_Diagnostic.None)

	expected := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&expected)
	for _ in 1 ..= 64 { strings.write_string(&expected, "{value = ") }
	strings.write_byte(&expected, '1')
	for _ in 1 ..= 64 { strings.write_byte(&expected, '}') }
	testing.expect_value(t, literal, strings.to_string(expected))
}

// The walk converts a value whole: no number of elements shortens the literal.
@(test)
codemode_value_converts_a_value_of_any_size :: proc(t: ^testing.T) {
	run := codemode_value_test_start(t, `local items = {} for i = 1, 20000 do items[i] = i end return items`)
	defer codemode_lua_destroy(run)
	testing.expect_value(t, codemode_value_test_settle(run), Lua_Event.Returned)
	literal, message, _ := codemode_lua_returned_literal(run)
	defer delete(literal)
	defer delete(message)
	testing.expect_value(t, message, "")

	expected := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&expected)
	strings.write_byte(&expected, '{')
	for item in 1 ..= 20_000 {
		if item > 1 { strings.write_string(&expected, ", ") }
		fmt.sbprint(&expected, item)
	}
	strings.write_byte(&expected, '}')
	testing.expectf(t, literal == strings.to_string(expected), "the literal should hold every element (%d bytes)", len(literal))
}

@(test)
codemode_value_writes_the_returned_literal :: proc(t: ^testing.T) {
	cases := []struct {
		source:  string,
		literal: string,
	} {
		{`local x = 1`, `nil`},
		{`return json.null`, `json.null`},
		{`return 2^53`, `9.007199254740992e+15`},
		{`return {status = "ok", ["two words"] = {1, 2.5}, ["end"] = true}`, `{["end"] = true, status = "ok", ["two words"] = {1, 2.5}}`},
		{`return "caf\xc3\xa9 " .. string.char(0)`, `"café \x00"`},
	}
	for test_case in cases {
		run := codemode_value_test_start(t, test_case.source)
		testing.expect_value(t, codemode_value_test_settle(run), Lua_Event.Returned)
		literal, message, _ := codemode_lua_returned_literal(run)
		testing.expectf(t, literal == test_case.literal, "%q: got %q (%s)", test_case.source, literal, message)
		delete(literal)
		delete(message)
		codemode_lua_destroy(run)
	}
}

@(test)
codemode_value_encodes_and_decodes_json :: proc(t: ^testing.T) {
	run := codemode_value_test_start(
		t,
		`local value = json.decode('{"b":"x\\n\\u00e9","a":[1,2.5,null]}')
local ok, err = pcall(json.decode, "{")
local _, wrapped = pcall(json.decode, "[99999999999999999999]")
return json.encode(value) .. "|" .. tostring(value.a[3] == json.null) .. "|" .. tostring(ok) .. "|" .. err .. "|" .. wrapped`,
	)
	defer codemode_lua_destroy(run)
	testing.expect_value(t, codemode_value_test_settle(run), Lua_Event.Returned)
	value, _ := codemode_lua_returned_string(run)
	testing.expect(t, strings.has_prefix(value, `{"a":[1,2.5,null],"b":"x\né"}|true|false|`), value)
	testing.expect(t, strings.contains(value, "json.decode refused the text: it is not valid JSON"), value)
	testing.expect(t, strings.contains(value, "no 64-bit integer"), value)
}
