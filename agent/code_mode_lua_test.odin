#+test
#+private file
package agent

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"

// The Lua boundary suite. It proves the four things Code Mode depends on and that no
// later layer can compensate for: limits a script cannot swallow, slices that return
// control to the owner, a suspension a script cannot catch, and a restricted
// environment with nothing else in it.

// LUA_TEST_REFNIL is `luaL_ref`'s "no reference" value. A request with no arguments
// carries it, and the test asserts it rather than importing the binding.
LUA_TEST_REFNIL :: -1

// lua_test_settle drives a run that is expected to need no tool call, and fails the
// test if it asks for one.
lua_test_settle :: proc(t: ^testing.T, run: ^Lua_Run) -> (event: Lua_Event, slices: int) {
	requests: [dynamic]string
	defer {
		for name in requests { delete(name) }
		delete(requests)
	}
	event, slices = lua_test_drive(t, run, &requests)
	if len(requests) > 0 { testing.fail_now(t, "the run asked for a tool call it should not need") }
	return event, slices
}

// lua_test_drive resumes a run until it settles, answering tool requests and counting
// slices. A step cap turns a suspension bug into a failure instead of a hang.
lua_test_drive :: proc(t: ^testing.T, run: ^Lua_Run, requests: ^[dynamic]string) -> (event: Lua_Event, slices: int) {
	if run == nil { testing.fail_now(t, "there is no run") }
	for _ in 0 ..< 1_000_000 {
		event = code_mode_lua_resume(run)
		switch event {
		case .Slice:
			slices += 1
		case .Host_Request:
			append(requests, strings.clone(run.request.name, context.allocator))
			reply := fmt.aprintf("result:%s", run.request.name)
			defer delete(reply)
			code_mode_lua_deliver_string(run, reply)
		case .Returned, .Stopped, .Failed:
			return event, slices
		}
	}
	testing.fail_now(t, "the Lua run never settled")
}

// lua_test_start compiles one chunk with the default limits and fails the test when it
// does not compile. The caller owns the returned run.
lua_test_start :: proc(t: ^testing.T, source: string) -> ^Lua_Run {
	run, compiled := code_mode_lua_start(context.allocator, lua_limits_default(), source)
	if run == nil { testing.fail_now(t, "the execution could not be created") }
	if !compiled {
		testing.expectf(t, false, "the chunk did not compile: %s", code_mode_lua_message(run))
	}
	return run
}

@(test)
lua_run_returns_a_value :: proc(t: ^testing.T) {
	run := lua_test_start(t, "return 42")
	defer code_mode_lua_destroy(run)

	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Returned)
	value, present := code_mode_lua_returned_number(run)
	testing.expect(t, present, "the returned value should be a number")
	testing.expect_value(t, value, i64(42))
}

@(test)
lua_run_allows_an_empty_return :: proc(t: ^testing.T) {
	run := lua_test_start(t, "local x = 1")
	defer code_mode_lua_destroy(run)

	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Returned)
	testing.expect_value(t, code_mode_lua_returned_values(run), 0)
}

@(test)
lua_syntax_error_is_a_value :: proc(t: ^testing.T) {
	run, compiled := code_mode_lua_start(context.allocator, lua_limits_default(), "return 1 +")
	defer code_mode_lua_destroy(run)

	testing.expect(t, run != nil, "a failed compile still returns a run to read")
	testing.expect(t, !compiled, "the chunk should not compile")
	testing.expect_value(t, code_mode_lua_failure(run), Lua_Failure.Syntax)
	testing.expect(t, len(code_mode_lua_message(run)) > 0, "the failure should say something")
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Failed)
}

@(test)
lua_runtime_error_is_a_value :: proc(t: ^testing.T) {
	run := lua_test_start(t, "local x = nil\nreturn x.field")
	defer code_mode_lua_destroy(run)

	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Failed)
	testing.expect_value(t, code_mode_lua_failure(run), Lua_Failure.Runtime)
	testing.expect(t, strings.contains(code_mode_lua_message(run), "index a nil value"), "the message should be the Lua diagnostic")
}

@(test)
lua_tool_table_shows_installed_names :: proc(t: ^testing.T) {
	run := lua_test_start(
		t,
		`local parts = {
	tostring(type(print)),
	tostring(type(tools)),
	tostring(type(tools["alpha"])),
	tostring(tools["missing"]),
}
return table.concat(parts, ",")`,
	)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "alpha"), "alpha should install")
	event, _ := lua_test_settle(t, run)
	testing.expectf(t, event == .Returned, "event %v message %s", event, code_mode_lua_message(run))
	text, ok := code_mode_lua_returned_string(run)
	testing.expect(t, ok, "a string should return")
	testing.expect_value(t, text, "function,table,function,nil")
}

@(test)
lua_tool_calls_suspend_and_resume :: proc(t: ^testing.T) {
	run := lua_test_start(
		t,
		`local first = tools["alpha"]({n = 1})
local second = tools["beta"]({n = 2})
print(first .. " " .. second)
return first .. "|" .. second
`,
	)
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "alpha"), "alpha should install")
	testing.expect(t, code_mode_lua_install_tool(run, "beta"), "beta should install")

	requests: [dynamic]string
	defer {
		for name in requests { delete(name) }
		delete(requests)
	}
	event, slices := lua_test_drive(t, run, &requests)
	if event != .Returned {
		testing.expectf(t, false, "the run should return: %v, %s", event, code_mode_lua_message(run))
	}
	testing.expect_value(t, slices, 0)
	testing.expect_value(t, len(requests), 2)
	if len(requests) == 2 {
		testing.expect_value(t, requests[0], "alpha")
		testing.expect_value(t, requests[1], "beta")
	}
	testing.expect_value(t, code_mode_lua_logs(run), "result:alpha result:beta\n")
	text, ok := code_mode_lua_returned_string(run)
	testing.expect(t, ok, "the composed value should be a string")
	testing.expect_value(t, text, "result:alpha|result:beta")
}

@(test)
lua_request_carries_its_arguments :: proc(t: ^testing.T) {
	run := lua_test_start(t, "return tools[\"alpha\"]()")
	defer code_mode_lua_destroy(run)
	testing.expect(t, code_mode_lua_install_tool(run, "alpha"), "alpha should install")

	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request)
	testing.expect_value(t, run.request.kind, Lua_Request_Kind.Call)
	testing.expect(t, run.request.pending, "the request should be pending")
	testing.expect_value(t, run.request.args_ref, LUA_TEST_REFNIL)

	// A second script passes a table, and the request carries a reference to it.
	second := lua_test_start(t, "return tools[\"alpha\"]({path = \"README.md\"})")
	defer code_mode_lua_destroy(second)
	testing.expect(t, code_mode_lua_install_tool(second, "alpha"), "alpha should install")
	testing.expect(t, code_mode_lua_install_tool(second, "alpha"), "alpha should install")
	first_event := code_mode_lua_resume(second)
	if first_event != .Host_Request {
		testing.expectf(t, false, "the second run should ask: %v, %s", first_event, code_mode_lua_message(second))
	}
	testing.expect(t, second.request.args_ref != LUA_TEST_REFNIL, "the argument table should be referenced")
}

@(test)
lua_instruction_budget_stops_the_run :: proc(t: ^testing.T) {
	limits := lua_limits_default()
	limits.instructions = 50_000
	limits.slice = 5_000
	run, compiled := code_mode_lua_start(context.allocator, limits, "while true do end")
	defer code_mode_lua_destroy(run)
	testing.expect(t, compiled, "the chunk should compile")

	event, _ := lua_test_settle(t, run)
	testing.expect_value(t, event, Lua_Event.Stopped)
	testing.expect_value(t, code_mode_lua_stop(run), Lua_Stop.Instructions)
	testing.expect_value(t, code_mode_lua_failure(run), Lua_Failure.None)
	testing.expect(t, code_mode_lua_instructions(run) >= 50_000, "the run should have spent its whole budget")

	// The stop is final: asking again runs nothing and reports the same observation.
	steps := run.steps
	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Stopped)
	testing.expect_value(t, run.steps, steps)
}

@(test)
lua_slices_return_control_to_the_owner :: proc(t: ^testing.T) {
	limits := lua_limits_default()
	limits.slice = 1_000
	run, compiled := code_mode_lua_start(context.allocator, limits, "local x = 0\nfor i = 1, 200000 do x = x + i end\nreturn x\n")
	defer code_mode_lua_destroy(run)
	testing.expect(t, compiled, "the chunk should compile")

	event, slices := lua_test_settle(t, run)
	testing.expect_value(t, event, Lua_Event.Returned)
	testing.expect(t, slices > 5, "a long loop should cross several slice boundaries")
}

@(test)
lua_cancellation_stops_without_an_error :: proc(t: ^testing.T) {
	limits := lua_limits_default()
	limits.slice = 1_000
	run, compiled := code_mode_lua_start(context.allocator, limits, "while true do end")
	defer code_mode_lua_destroy(run)
	testing.expect(t, compiled, "the chunk should compile")

	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Slice)
	code_mode_lua_request_stop(run)
	event, _ := lua_test_settle(t, run)
	testing.expect_value(t, event, Lua_Event.Stopped)
	testing.expect_value(t, code_mode_lua_stop(run), Lua_Stop.Cancelled)
	// Cancellation is not a script error, and a script cannot turn it into one.
	testing.expect_value(t, code_mode_lua_failure(run), Lua_Failure.None)
	testing.expect_value(t, code_mode_lua_message(run), "the execution was cancelled")
}

@(test)
lua_deadline_stops_the_run :: proc(t: ^testing.T) {
	limits := lua_limits_default()
	limits.slice = 10_000
	limits.duration = 20 * time.Millisecond
	run, compiled := code_mode_lua_start(context.allocator, limits, "while true do end")
	defer code_mode_lua_destroy(run)
	testing.expect(t, compiled, "the chunk should compile")

	event, _ := lua_test_settle(t, run)
	testing.expect_value(t, event, Lua_Event.Stopped)
	testing.expect_value(t, code_mode_lua_stop(run), Lua_Stop.Deadline)
}

@(test)
lua_memory_budget_stops_the_run :: proc(t: ^testing.T) {
	limits := lua_limits_default()
	limits.memory_bytes = 256 * 1024
	run, compiled := code_mode_lua_start(context.allocator, limits, `local held = {}
for i = 1, 100000 do held[i] = string.rep("x", 1000) end
return #held
`)
	defer code_mode_lua_destroy(run)
	testing.expect(t, compiled, "the chunk should compile")

	event, _ := lua_test_settle(t, run)
	testing.expect_value(t, event, Lua_Event.Failed)
	testing.expect_value(t, code_mode_lua_failure(run), Lua_Failure.Memory)
	testing.expect(t, code_mode_lua_memory_peak(run) <= limits.memory_bytes, "the peak should never pass the budget")
}

@(test)
lua_environment_is_restricted :: proc(t: ^testing.T) {
	run := lua_test_start(
		t,
		`local absent = {
	"io", "os", "package", "debug", "coroutine", "require", "load", "loadfile",
	"dofile", "collectgarbage", "setmetatable", "getmetatable", "rawset", "pcall",
	"xpcall", "warn",
}
for _, name in ipairs(absent) do
	if _G[name] ~= nil then return false end
end
if string.dump ~= nil then return false end
if type(print) ~= "function" then return false end
if type(tools) ~= "table" then return false end
if type(string.rep) ~= "function" then return false end
if type(table.sort) ~= "function" then return false end
if type(math.floor) ~= "function" then return false end
return true
`,
	)
	defer code_mode_lua_destroy(run)

	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Returned)
	testing.expect(t, code_mode_lua_returned_boolean(run), "every absent global should be absent")
}

@(test)
lua_print_is_captured_and_bounded :: proc(t: ^testing.T) {
	run := lua_test_start(t, `print("hello", 42)
print({})
print(string.rep("x", 20000))
return true
`)
	defer code_mode_lua_destroy(run)

	testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Returned)
	logs := code_mode_lua_logs(run)
	testing.expect(t, strings.has_prefix(logs, "hello 42\n"), "print should capture strings and numbers")
	testing.expect(t, strings.contains(logs, "<table>"), "a table should be reported as a table")
	testing.expect(t, len(logs) <= LUA_MAX_LOG_BYTES, "the log should stay inside its budget")
	testing.expect(t, code_mode_lua_logs_truncated(run), "the oversized line should mark the log truncated")
}

@(test)
lua_install_refuses_a_bad_name :: proc(t: ^testing.T) {
	run := lua_test_start(t, "return true")
	defer code_mode_lua_destroy(run)

	testing.expect(t, !code_mode_lua_install_tool(run, ""), "an empty name should be refused")
	testing.expect(t, !code_mode_lua_install_tool(run, "alpha\x00beta"), "a name with a NUL should be refused")
	long_name := strings.repeat("a", TOOL_MAX_NAME_BYTES + 1, context.temp_allocator)
	testing.expect(t, !code_mode_lua_install_tool(run, long_name), "an oversized name should be refused")
	testing.expect(t, !code_mode_lua_install_tool(run, "builtin.read"), "a dotted name should be refused")
	testing.expect(t, !code_mode_lua_install_tool(run, "builtin-read"), "a hyphenated name should be refused")
	testing.expect(t, code_mode_lua_install_tool(run, "builtin_read"), "a canonical name should install")
}

@(test)
lua_destroy_returns_every_byte :: proc(t: ^testing.T) {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)

	run, compiled := code_mode_lua_start(
		mem.tracking_allocator(&tracker),
		lua_limits_default(),
		`local held = {}
for i = 1, 5000 do held[i] = string.format("%d", i) end
return #held
`,
	)
	testing.expect(t, compiled, "the chunk should compile")
	if run == nil { testing.fail_now(t, "the execution could not be created") }

	event, _ := lua_test_settle(t, run)
	testing.expect_value(t, event, Lua_Event.Returned)
	testing.expect(t, code_mode_lua_memory_used(run) > 0, "the run should hold Lua memory")
	code_mode_lua_destroy(run)

	testing.expect_value(t, len(tracker.allocation_map), 0)
}

@(test)
lua_stop_in_a_c_frame_defers :: proc(t: ^testing.T) {
	// A comparator runs inside a C function, where a hook cannot yield. The hook must
	// defer instead of raising, and the run must finish normally.
	limits := lua_limits_default()
	limits.slice = 300
	run, compiled := code_mode_lua_start(
		context.allocator,
		limits,
		`local t = {}
for i = 1, 3000 do t[i] = (i * 7919) % 3001 end
table.sort(t, function(a, b) return a < b end)
return t[1]
`,
	)
	defer code_mode_lua_destroy(run)
	testing.expect(t, compiled, "the chunk should compile")

	event, slices := lua_test_settle(t, run)
	testing.expect_value(t, event, Lua_Event.Returned)
	testing.expect(t, slices > 0, "the sort should cross slice boundaries")
	testing.expect(t, run.non_yieldable > 0, "the hook should have fired inside the C frame")
	value, present := code_mode_lua_returned_number(run)
	testing.expect(t, present, "the sort result should be a number")
	testing.expect_value(t, value, i64(1))
}
