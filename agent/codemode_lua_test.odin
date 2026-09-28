#+test
#+private file
package agent

import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"

// The Lua boundary suite: slices that return control to the owner, stops a script cannot
// catch, host requests, and the environment a script gets.

lua_test_start :: proc(t: ^testing.T, source: string, timeout: time.Duration = 0) -> ^Lua_Run {
	run, compiled := codemode_lua_start(source, timeout = timeout)
	if run == nil { testing.fail_now(t, "the execution could not be created") }
	if !compiled {
		testing.expect(t, false, run.message)
		codemode_lua_destroy(run)
		testing.fail_now(t)
	}
	return run
}

// lua_test_drive resumes a run until it settles. Each request is answered with the count of
// requests so far, and a step cap turns a suspension bug into a failure instead of a hang.
lua_test_drive :: proc(t: ^testing.T, run: ^Lua_Run) -> (event: Lua_Event, slices: int, calls: [dynamic]string) {
	calls = make([dynamic]string, context.temp_allocator)
	for _ in 0 ..< 1_000_000 {
		event = codemode_lua_resume(run)
		switch event {
		case .Slice:
			slices += 1
		case .Host_Request:
			append(&calls, strings.clone(run.request.name, context.temp_allocator))
			codemode_lua_answer_handle(run, len(calls))
		case .Returned, .Stopped, .Failed:
			return
		}
	}
	testing.fail_now(t, "the Lua run never settled")
}

lua_test_returned :: proc(t: ^testing.T, source: string) -> string {
	run := lua_test_start(t, source)
	defer codemode_lua_destroy(run)
	event, _, _ := lua_test_drive(t, run)
	testing.expectf(t, event == .Returned, "%s: %v %s", source, event, run.message)
	value, _ := codemode_lua_returned_string(run)
	return strings.clone(value, context.temp_allocator)
}

@(test)
lua_failures_are_values_with_their_position :: proc(t: ^testing.T) {
	syntax, compiled := codemode_lua_start("return 1 +")
	defer codemode_lua_destroy(syntax)
	testing.expect(t, !compiled, "the chunk should not compile")
	testing.expect_value(t, syntax.failure, Lua_Failure.Syntax)
	testing.expect(t, strings.has_prefix(syntax.message, "code:1:"), syntax.message)

	runtime_error := lua_test_start(t, "local function inner() local x = nil return x.field end\nlocal value = inner()\nreturn value")
	defer codemode_lua_destroy(runtime_error)
	testing.expect_value(t, codemode_lua_resume(runtime_error), Lua_Event.Failed)
	testing.expect_value(t, runtime_error.failure, Lua_Failure.Runtime)
	testing.expect(t, strings.has_prefix(runtime_error.message, "code:1: attempt to index a nil value"), runtime_error.message)
	testing.expect_value(t, runtime_error.traceback, "code:1: in local 'inner'\ncode:2: in main chunk")

	table_error := lua_test_start(t, `error({code = 1})`)
	defer codemode_lua_destroy(table_error)
	testing.expect_value(t, codemode_lua_resume(table_error), Lua_Event.Failed)
	testing.expect_value(t, table_error.message, "the script raised a non-string error: {code = 1}")

	// A failure message is kept whole, however long the text the script raised is.
	long_error := lua_test_start(t, `error(string.rep("y", 5000))`)
	defer codemode_lua_destroy(long_error)
	testing.expect_value(t, codemode_lua_resume(long_error), Lua_Event.Failed)
	testing.expect(t, strings.has_prefix(long_error.message, "code:1: yyy"), long_error.message)
	testing.expect_value(t, strings.count(long_error.message, "y"), 5_000)
	testing.expect(t, strings.has_suffix(long_error.traceback, "code:1: in main chunk"), long_error.traceback)

	unknown := lua_test_start(t, `return tools.gamma`)
	defer codemode_lua_destroy(unknown)
	testing.expect(t, codemode_lua_install_tool(unknown, "beta"), "beta should install")
	testing.expect(t, codemode_lua_install_tool(unknown, "alpha"), "alpha should install")
	testing.expect_value(t, codemode_lua_resume(unknown), Lua_Event.Failed)
	testing.expect(t, strings.has_prefix(unknown.message, `code:1: no tool named "gamma"; the tools are: alpha, beta.`), unknown.message)
}

@(test)
lua_host_requests_suspend_and_resume :: proc(t: ^testing.T) {
	run := lua_test_start(t, `local first = tools.alpha({n = 1})
local handle = job.start("beta", {n = 2})
return first .. "|" .. handle`)
	defer codemode_lua_destroy(run)
	testing.expect(t, codemode_lua_install_tool(run, "alpha"), "alpha should install")
	testing.expect(t, codemode_lua_install_tool(run, "beta"), "beta should install")

	testing.expect_value(t, codemode_lua_resume(run), Lua_Event.Host_Request)
	testing.expect_value(t, run.request.kind, Lua_Request_Kind.Call)
	testing.expect_value(t, run.request.name, "alpha")
	testing.expect_value(t, codemode_lua_resume(run), Lua_Event.Host_Request)
	codemode_lua_answer_handle(run, 3)
	testing.expect_value(t, codemode_lua_resume(run), Lua_Event.Host_Request)
	testing.expect_value(t, run.request.kind, Lua_Request_Kind.Start)
	testing.expect_value(t, run.request.name, "beta")
	codemode_lua_answer_handle(run, 7)
	testing.expect_value(t, codemode_lua_resume(run), Lua_Event.Returned)
	value, _ := codemode_lua_returned_string(run)
	testing.expect_value(t, value, "3|7")
}

// Refusals are Lua errors at the script's line, so a script can catch them with pcall.
@(test)
lua_refused_requests_raise_catchable_errors :: proc(t: ^testing.T) {
	run := lua_test_start(
		t,
		`local ok, err = pcall(job.wait, 3)
local ok_args, err_args = pcall(tools.alpha, "README.md")
local ok_sort, err_sort = pcall(table.sort, {2, 1}, function(a, b) tools.alpha() return a < b end)
return err .. "|" .. err_args .. "|" .. err_sort`,
	)
	defer codemode_lua_destroy(run)
	testing.expect(t, codemode_lua_install_tool(run, "alpha"), "alpha should install")
	testing.expect_value(t, codemode_lua_resume(run), Lua_Event.Host_Request)
	testing.expect_value(t, run.request.kind, Lua_Request_Kind.Wait)
	testing.expect_value(t, run.request.handle, 3)
	codemode_lua_answer_error(run, "no such handle")
	testing.expect_value(t, codemode_lua_resume(run), Lua_Event.Returned)
	value, _ := codemode_lua_returned_string(run)
	parts := strings.split(value, "|", context.temp_allocator)
	if !testing.expect_value(t, len(parts), 3) { return }
	testing.expect_value(t, parts[0], "no such handle")
	testing.expect(t, strings.has_suffix(parts[1], "a tool call takes one table of named arguments"), parts[1])
	testing.expect(t, strings.contains(parts[2], "inside a C call"), parts[2])
}

@(test)
lua_slices_return_control_and_a_stop_is_final :: proc(t: ^testing.T) {
	run := lua_test_start(t, "local x = 0\nfor i = 1, 200000 do x = x + i end\nwhile true do end")
	defer codemode_lua_destroy(run)
	for _ in 0 ..< 5 { testing.expect_value(t, codemode_lua_resume(run), Lua_Event.Slice) }
	codemode_lua_request_stop(run)
	testing.expect_value(t, codemode_lua_resume(run), Lua_Event.Stopped)
	testing.expect_value(t, run.failure, Lua_Failure.None)
	testing.expect_value(t, codemode_lua_resume(run), Lua_Event.Stopped)
}

// A loop inside a C call cannot yield, so a timeout raises there instead, and a pcall that
// catches it cannot keep the script alive past its next slice.
@(test)
lua_timeout_reaches_a_loop_inside_a_c_call :: proc(t: ^testing.T) {
	run := lua_test_start(t, `while true do pcall(table.sort, {3, 2, 1}, function(a, b) while true do end end) end`, 20 * time.Millisecond)
	defer codemode_lua_destroy(run)
	event, _, _ := lua_test_drive(t, run)
	testing.expect_value(t, event, Lua_Event.Failed)
	testing.expect_value(t, run.failure, Lua_Failure.Timed_Out)
}

@(test)
lua_environment_has_the_allowlist :: proc(t: ^testing.T) {
	absent := lua_test_returned(
		t,
		`local names = {"io", "package", "debug", "coroutine", "require", "load", "loadfile", "dofile", "collectgarbage", "warn"}
local present = {}
for _, name in ipairs(names) do if _G[name] ~= nil then present[#present + 1] = name end end
for _, name in ipairs({"execute", "exit", "getenv", "remove", "rename", "tmpname"}) do if os[name] ~= nil then present[#present + 1] = "os." .. name end end
if string.dump ~= nil then present[#present + 1] = "string.dump" end
return table.concat(present, ",")`,
	)
	testing.expect_value(t, absent, "")

	available := lua_test_returned(
		t,
		`local point = setmetatable({}, {__index = function(_, key) return key .. "!" end})
local ok = pcall(error, "x")
local date = os.date("!%Y", 0)
return point.x .. tostring(ok) .. date .. type(os.time()) .. type(os.clock()) .. utf8.char(233) .. math.floor(2.5) .. rawlen({1})`,
	)
	testing.expect_value(t, available, "x!false1970numbernumberé21")

	finalizer := lua_test_returned(t, `local ok, err = pcall(setmetatable, {}, {__gc = function() end}) return err`)
	testing.expect(t, strings.contains(finalizer, "__gc is not allowed"), finalizer)
}

@(test)
lua_install_refuses_a_bad_name :: proc(t: ^testing.T) {
	run := lua_test_start(t, "return true")
	defer codemode_lua_destroy(run)
	testing.expect(t, !codemode_lua_install_tool(run, ""), "an empty name should be refused")
	testing.expect(t, !codemode_lua_install_tool(run, "alpha\x00beta"), "a name with a NUL should be refused")
	testing.expect(t, !codemode_lua_install_tool(run, "builtin.read"), "a dotted name should be refused")
	testing.expect(t, codemode_lua_install_tool(run, "builtin_read"), "a canonical name should install")
}

@(test)
lua_destroy_returns_every_byte :: proc(t: ^testing.T) {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)

	run, compiled := codemode_lua_start(
		`local held = {}
for i = 1, 5000 do held[i] = string.format("%d", i) end
print(held[1], {1, 2})
local ok = pcall(json.decode, "[")
return json.encode(held)`,
		allocator = mem.tracking_allocator(&tracker),
	)
	testing.expect(t, compiled, "the chunk should compile")
	event, _, _ := lua_test_drive(t, run)
	testing.expect_value(t, event, Lua_Event.Returned)
	codemode_lua_destroy(run)
	testing.expect_value(t, len(tracker.allocation_map), 0)
}
