package agent

import "base:runtime"
import c "core:c"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import lua "vendor:lua/5.4"

import "nabla:ai"

// --- Lua execution boundary ---------------------------------------------------
//
// This file owns one Lua 5.4 execution: the state, the restricted environment, and the
// suspension protocol. It knows nothing about tools, the session, or the model.
//
// Script work runs on a private coroutine in bounded slices. Two things bring control
// back to the owner:
//
// - A host function (`tools.<name>`, `job.start`, `job.wait`) yields a request. The owner
//   records an answer through one of the `codemode_lua_answer_*` procedures and resumes;
//   the host function's continuation pushes the answer, so every push the owner causes
//   runs inside the resume, where a Lua error is caught.
// - The count hook yields. The owner resumes for another slice, or never resumes a run
//   that was stopped.
//
// Yielding rather than raising is what makes a stop final: a script cannot catch a
// suspension. Inside a C call, such as a `table.sort` comparator, the coroutine cannot
// yield, so the hook raises instead once the run should stop; the stop is final at the
// next point that can yield.
//
// A Lua error unwinds a C callback without running its defers, so callbacks allocate only
// from the run's scratch arena, inside an arena_temp that the error path ends before it
// raises. Whatever an error raised by Lua itself skips is reclaimed after the resume.

// LUA_SLICE_INSTRUCTIONS is how many VM instructions run between owner checkpoints.
// It is a scheduling quantum, not a limit.
LUA_SLICE_INSTRUCTIONS :: 10_000

// LUA_MAX_MESSAGE_BYTES bounds a diagnostic read out of Lua, traceback included.
LUA_MAX_MESSAGE_BYTES :: 2048

// LUA_MAX_LOG_BYTES bounds what `print` may keep. Output is returned, not streamed,
// so it is bounded where it is produced.
LUA_MAX_LOG_BYTES :: 8 * 1024

// LUA_CHUNK_NAME makes Lua name a source position as `code:3:`.
@(private)
LUA_CHUNK_NAME :: "@code"

// LUA_FIRST_UPVALUE is the pseudo-index of a C closure's first upvalue.
@(private)
LUA_FIRST_UPVALUE :: lua.REGISTRYINDEX - 1

// lua_os_fields is the part of the `os` library a script gets: clocks and dates, nothing
// that reaches the file system, the environment, or the process.
@(private, rodata)
lua_os_fields := [?]cstring{"clock", "date", "difftime", "time"}

// lua_removed_globals are the base functions a script does not get: loading code,
// driving the collector, and the harness's own diagnostics channel.
@(private, rodata)
lua_removed_globals := [?]cstring{"load", "loadfile", "dofile", "require", "collectgarbage", "warn"}

// Lua_Failure is how a run failed. None is a run that suspended, returned, or was
// cancelled.
Lua_Failure :: enum {
	None,
	Syntax,
	Runtime,
	Memory,
	Timed_Out,
}

// Lua_Event is what one step reported.
Lua_Event :: enum {
	// Returned: the chunk finished. Its values are on the coroutine stack.
	Returned,
	// Host_Request: the chunk asked the host to act. Nothing runs until it is answered.
	Host_Request,
	// Slice: the instruction slice ended with nothing terminal. Resuming continues.
	Slice,
	// Stopped: the run was cancelled. It is never resumed.
	Stopped,
	// Failed: syntax, runtime, memory, or timeout failure. It is never resumed.
	Failed,
}

// Lua_Request_Kind is what a script asked the host for.
Lua_Request_Kind :: enum {
	// Call: `tools.<name>(args)`, a child call the script waits for.
	Call,
	// Start: `job.start(name, args)`, a child call answered with its handle.
	Start,
	// Wait: `job.wait(handle)`, answered with that child's result.
	Wait,
}

// Lua_Request is one pending host request. name is owned by the run and empty for a
// wait. args_ref is a registry reference to the argument table, or lua.NOREF when the
// call had none.
Lua_Request :: struct {
	kind:     Lua_Request_Kind,
	name:     string,
	args_ref: i32,
	handle:   int,
	pending:  bool,
}

// Lua_Answer is how the owner answered the pending request.
Lua_Answer :: enum {
	// None: not answered yet.
	None,
	// Handle: job.start returns answer_handle.
	Handle,
	// Result: the call returns the result kept under answer_handle.
	Result,
	// Error: the call raises answer_message at the script's line.
	Error,
}

// Lua_Run is one execution. Every field is owned by the run or an observed count.
Lua_Run :: struct {
	allocator:       mem.Allocator,
	scratch:         virtual.Arena, // callback memory, reset after every resume
	state:           ^lua.State, // the main state; owns every value
	thread:          ^lua.State, // the private coroutine the chunk runs on
	interrupt:       ^ai.Interrupt, // borrowed; a requested interrupt stops the run
	deadline:        time.Tick, // zero means no timeout
	stop_requested:  bool, // latched by the owner
	failure:         Lua_Failure,
	terminal:        bool, // the run cannot be resumed
	message:         string, // why it stopped or failed
	traceback:       string, // the frames a runtime error unwound
	logs:            [dynamic]u8, // what print produced
	logs_truncated:  bool,
	request:         Lua_Request,
	answer:          Lua_Answer,
	answer_handle:   int,
	answer_message:  string, // owned; released after the resume that raised it
	results_ref:     i32, // registry table of committed child results by handle
	last_event:      Lua_Event, // what resume reports for a terminal run
	returned_values: int,
}

// --- state access --------------------------------------------------------------

// codemode_lua_run is the run a C callback belongs to. The run hangs off the state's
// extra space, which a new thread copies from the main state.
@(private)
codemode_lua_run :: proc "contextless" (state: ^lua.State) -> ^Lua_Run {
	return (cast(^^Lua_Run)lua.getextraspace(state))^
}

// codemode_lua_context is the context a C callback runs Odin code with: the run's
// allocator, and its scratch arena as the temporary allocator.
@(private)
codemode_lua_context :: proc "contextless" (run: ^Lua_Run) -> runtime.Context {
	context = runtime.default_context()
	context.allocator = run.allocator
	context.temp_allocator = virtual.arena_allocator(&run.scratch)
	return context
}

// codemode_lua_raise raises message at the calling line after ending temp, which message
// may live in: the push copies it first. It does not return.
@(private)
codemode_lua_raise :: proc(state: ^lua.State, message: string, temp: virtual.Arena_Temp) -> c.int {
	lua.L_where(state, 1)
	codemode_lua_push_string(state, message)
	lua.concat(state, 2)
	virtual.arena_temp_end(temp)
	return c.int(lua.error(state))
}

// --- memory --------------------------------------------------------------------

@(private)
LUA_ALLOCATION_ALIGNMENT :: 16

// codemode_lua_alloc is Lua's allocator over the run's allocator. Returning nil makes
// Lua raise an out-of-memory error. Lua passes a type tag rather than a size in osize
// when ptr is nil, and requires that shrinking a block never fails.
@(private)
codemode_lua_alloc :: proc "c" (user_data: rawptr, ptr: rawptr, osize, nsize: c.size_t) -> rawptr {
	run := cast(^Lua_Run)user_data
	context = codemode_lua_context(run)
	old_size := ptr == nil ? 0 : int(osize)
	if nsize == 0 {
		if ptr != nil { mem.free_with_size(ptr, old_size) }
		return nil
	}
	block, err := mem.resize_non_zeroed(ptr, old_size, int(nsize), LUA_ALLOCATION_ALIGNMENT)
	if err != nil { return int(nsize) <= old_size ? ptr : nil }
	return block
}

// --- stopping ------------------------------------------------------------------

@(private)
codemode_lua_expired :: proc "contextless" (run: ^Lua_Run) -> bool {
	return run.deadline != {} && time.tick_diff(run.deadline, time.tick_now()) >= 0
}

@(private)
codemode_lua_stopping :: proc "contextless" (run: ^Lua_Run) -> bool {
	return run.stop_requested || ai.interrupt_requested(run.interrupt) || codemode_lua_expired(run)
}

// codemode_lua_hook runs every LUA_SLICE_INSTRUCTIONS and yields, so the owner decides
// whether the run continues. Where the coroutine cannot yield, it raises once the run
// should stop, so a loop inside a C call cannot hold the owner. From then on it fires on
// every instruction, so a script that catches the raise yields at its next instruction.
@(private)
codemode_lua_hook :: proc "c" (state: ^lua.State, debug: ^lua.Debug) {
	if lua.isyieldable(state) {
		lua.yield(state, 0)
		return
	}
	if codemode_lua_stopping(codemode_lua_run(state)) {
		lua.sethook(state, codemode_lua_hook, lua.MASKCOUNT, 1)
		lua.L_error(state, "the execution was stopped")
	}
}

// --- host requests -------------------------------------------------------------

// codemode_lua_suspend records one host request and yields it to the owner. name_index
// is where the tool name is, or zero for none, and argument is where the one optional
// argument table is, or zero for none. What can be refused without the owner is refused
// here, as an ordinary Lua error at the caller's line.
@(private)
codemode_lua_suspend :: proc "c" (state: ^lua.State, kind: Lua_Request_Kind, name_index, argument: c.int, handle: int) -> c.int {
	run := codemode_lua_run(state)
	if !lua.isyieldable(state) {
		return c.int(lua.L_error(state, "a tool cannot be called inside a C call such as a table.sort comparator"))
	}
	if argument != 0 {
		count := lua.gettop(state) - argument + 1
		if count > 1 || (count == 1 && lua.type(state, argument) != .TABLE) {
			return c.int(lua.L_error(state, "a tool call takes one table of named arguments"))
		}
	}

	name := ""
	if name_index != 0 {
		context = codemode_lua_context(run)
		text, _ := codemode_lua_stack_string(state, name_index)
		clone_error: mem.Allocator_Error
		name, clone_error = strings.clone(text)
		if clone_error != nil { return c.int(lua.L_error(state, "the tool name could not be allocated")) }
	}
	args_ref: c.int = lua.NOREF
	if argument != 0 && lua.gettop(state) == argument { args_ref = lua.L_ref(state, lua.REGISTRYINDEX) }

	run.request = {
		kind     = kind,
		name     = name,
		args_ref = args_ref,
		handle   = handle,
		pending  = true,
	}
	return c.int(lua.yield(state, 0, 0, codemode_lua_answered))
}

// codemode_lua_answered continues a host function with the owner's answer.
@(private)
codemode_lua_answered :: proc "c" (state: ^lua.State, status: c.int, ctx: lua.KContext) -> c.int {
	run := codemode_lua_run(state)
	answer := run.answer
	run.answer = .None
	switch answer {
	case .Handle:
		lua.pushinteger(state, lua.Integer(run.answer_handle))
	case .Result:
		lua.rawgeti(state, lua.REGISTRYINDEX, lua.Integer(run.results_ref))
		lua.rawgeti(state, -1, lua.Integer(run.answer_handle))
		lua.pushnil(state)
		lua.rawseti(state, -3, lua.Integer(run.answer_handle))
		lua.remove(state, -2)
	case .Error:
		lua.L_where(state, 1)
		codemode_lua_push_string(state, run.answer_message)
		lua.concat(state, 2)
		return c.int(lua.error(state))
	case .None:
		lua.pushnil(state)
	}
	return 1
}

// codemode_lua_tool_call is the body of one `tools` entry. Its upvalue is the tool name.
@(private)
codemode_lua_tool_call :: proc "c" (state: ^lua.State) -> c.int {
	return codemode_lua_suspend(state, .Call, LUA_FIRST_UPVALUE, 1, 0)
}

// codemode_lua_job_start checks the name against its upvalue, the tools table, so an
// unknown tool is refused before a call is recorded.
@(private)
codemode_lua_job_start :: proc "c" (state: ^lua.State) -> c.int {
	lua.L_checkstring(state, 1)
	lua.pushvalue(state, 1)
	if lua.Type(lua.rawget(state, LUA_FIRST_UPVALUE)) == .NIL { return codemode_lua_unknown_tool(state, LUA_FIRST_UPVALUE, 1) }
	lua.pop(state, 1)
	return codemode_lua_suspend(state, .Start, 1, 2, 0)
}

@(private)
codemode_lua_job_wait :: proc "c" (state: ^lua.State) -> c.int {
	handle := lua.L_checkinteger(state, 1)
	return codemode_lua_suspend(state, .Wait, 0, 0, int(handle))
}

// codemode_lua_tools_index is the `tools` table's __index: reading a name that is not a
// tool is a mistake, so it raises with the names that are, rather than returning nil.
@(private)
codemode_lua_tools_index :: proc "c" (state: ^lua.State) -> c.int {
	return codemode_lua_unknown_tool(state, 1, 2)
}

// codemode_lua_unknown_tool raises for the name at name_index, listing the tools table at
// table_index in name order.
@(private)
codemode_lua_unknown_tool :: proc "c" (state: ^lua.State, table_index, name_index: c.int) -> c.int {
	run := codemode_lua_run(state)
	context = codemode_lua_context(run)
	temp := virtual.arena_temp_begin(&run.scratch)
	names := make([dynamic]string, context.temp_allocator)
	lua.pushnil(state)
	for lua.next(state, table_index) != 0 {
		lua.pop(state, 1)
		if name, is_text := codemode_lua_stack_string(state, -1); is_text { append(&names, name) }
	}
	slice.sort(names[:])
	name, _ := codemode_lua_stack_string(state, name_index)
	message := fmt.tprintf(
		"no tool named %q; the tools are: %s. Use rawget(tools, name) to test whether a tool exists",
		name,
		strings.join(names[:], ", ", context.temp_allocator),
	)
	return codemode_lua_raise(state, message, temp)
}

// --- restricted environment ----------------------------------------------------

// codemode_lua_open_libraries installs the allowlist. `L_openlibs` is never called: a
// library that was never opened costs nothing to reason about.
@(private)
codemode_lua_open_libraries :: proc(state: ^lua.State) {
	libraries := [?]lua.L_Reg {
		{lua.GNAME, lua.open_base},
		{lua.STRLIBNAME, lua.open_string},
		{lua.TABLIBNAME, lua.open_table},
		{lua.MATHLIBNAME, lua.open_math},
		{lua.UTF8LIBNAME, lua.open_utf8},
		{lua.OSLIBNAME, lua.open_os},
	}
	for library in libraries {
		lua.L_requiref(state, library.name, library.func, 1)
		lua.pop(state, 1)
	}

	for name in lua_removed_globals {
		lua.pushnil(state)
		lua.setglobal(state, name)
	}
	// Bytecode would put a loader back in the script's hands.
	lua.getglobal(state, lua.STRLIBNAME)
	lua.pushnil(state)
	lua.setfield(state, -2, "dump")
	lua.pop(state, 1)

	lua.createtable(state, 0, c.int(len(lua_os_fields)))
	lua.getglobal(state, lua.OSLIBNAME)
	for name in lua_os_fields {
		lua.getfield(state, -1, name)
		lua.setfield(state, -3, name)
	}
	lua.pop(state, 1)
	lua.setglobal(state, lua.OSLIBNAME)

	// setmetatable keeps the base function as its upvalue.
	lua.getglobal(state, "setmetatable")
	lua.pushcclosure(state, codemode_lua_setmetatable, 1)
	lua.setglobal(state, "setmetatable")
}

// codemode_lua_setmetatable refuses a metatable with `__gc`. A finalizer runs with hooks
// off, where no slice ends and no stop reaches it, and again when the state closes.
// Every other metamethod runs as ordinary script code, and the host reads values raw.
@(private)
codemode_lua_setmetatable :: proc "c" (state: ^lua.State) -> c.int {
	if lua.type(state, 2) == .TABLE {
		lua.pushstring(state, "__gc")
		finalizer := lua.Type(lua.rawget(state, 2))
		lua.pop(state, 1)
		if finalizer != .NIL { return c.int(lua.L_error(state, "a metatable with __gc is not allowed")) }
	}
	lua.pushvalue(state, LUA_FIRST_UPVALUE)
	lua.insert(state, 1)
	lua.call(state, lua.gettop(state) - 1, 1)
	return 1
}

// codemode_lua_install_table sets the global name to a new table of C functions.
@(private)
codemode_lua_install_table :: proc(state: ^lua.State, name: cstring, functions: []lua.L_Reg) {
	lua.createtable(state, 0, c.int(len(functions)))
	for function in functions {
		lua.pushcfunction(state, function.func)
		lua.setfield(state, -2, function.name)
	}
	lua.setglobal(state, name)
}

// --- print ---------------------------------------------------------------------

// codemode_lua_print appends one line to the run's bounded log. It never calls
// `tostring`, so printing runs no script code: a table prints as its Lua literal.
@(private)
codemode_lua_print :: proc "c" (state: ^lua.State) -> c.int {
	run := codemode_lua_run(state)
	context = codemode_lua_context(run)
	temp := virtual.arena_temp_begin(&run.scratch)
	for index in 1 ..= lua.gettop(state) {
		if index > 1 { codemode_lua_log_append(run, " ") }
		codemode_lua_log_value(run, state, index)
	}
	codemode_lua_log_append(run, "\n")
	virtual.arena_temp_end(temp)
	return 0
}

@(private)
codemode_lua_log_value :: proc(run: ^Lua_Run, state: ^lua.State, index: c.int) {
	switch lua.type(state, index) {
	case .NIL:
		codemode_lua_log_append(run, "nil")
	case .BOOLEAN:
		codemode_lua_log_append(run, lua.toboolean(state, index) ? "true" : "false")
	case .LIGHTUSERDATA:
		codemode_lua_log_append(run, lua.touserdata(state, index) == rawptr(run) ? "json.null" : "<lightuserdata>")
	case .TABLE:
		codemode_lua_log_table(run, state, index)
	case .STRING, .NUMBER:
		text, _ := codemode_lua_stack_string(state, index)
		codemode_lua_log_append(run, text)
	case .NONE, .FUNCTION, .USERDATA, .THREAD:
		codemode_lua_log_append(run, "<")
		codemode_lua_log_append(run, string(lua.typename(state, lua.type(state, index))))
		codemode_lua_log_append(run, ">")
	}
}

// codemode_lua_log_table writes a table as its Lua literal, or as `<table>` when the value
// conversion refuses it: `print` is a diagnostic and never fails the script.
@(private)
codemode_lua_log_table :: proc(run: ^Lua_Run, state: ^lua.State, index: c.int) {
	literal, message, _ := codemode_lua_convert(run, state, index, .Lua, CODEMODE_LOG_MAX_NODES, context.temp_allocator)
	codemode_lua_log_append(run, message == "" ? literal : "<table>")
}

@(private)
codemode_lua_log_append :: proc(run: ^Lua_Run, text: string) {
	if run.logs_truncated || text == "" { return }
	take := text
	room := LUA_MAX_LOG_BYTES - len(run.logs)
	if len(take) > room {
		take = codemode_lua_truncate_runes(take, room)
		run.logs_truncated = true
	}
	if _, err := append(&run.logs, take); err != nil { run.logs_truncated = true }
}

// codemode_lua_stack_string reads a value that is already text. Strings and numbers
// convert; nothing else does.
@(private)
codemode_lua_stack_string :: proc "contextless" (state: ^lua.State, index: c.int) -> (string, bool) {
	kind := lua.type(state, index)
	if kind != .STRING && kind != .NUMBER { return "", false }
	length: c.size_t
	pointer := lua.tolstring(state, index, &length)
	if pointer == nil { return "", false }
	return string((cast([^]u8)pointer)[:length]), true
}

// codemode_lua_push_string pushes a copy of text, which may hold any byte.
@(private)
codemode_lua_push_string :: proc "contextless" (state: ^lua.State, text: string) {
	lua.pushlstring(state, cstring(raw_data(text)), c.size_t(len(text)))
}

// codemode_lua_truncate_runes takes at most limit bytes and never cuts a character.
@(private)
codemode_lua_truncate_runes :: proc(text: string, limit: int) -> string {
	if limit >= len(text) { return text }
	end := max(limit, 0)
	for end > 0 && !utf8.rune_start(text[end]) { end -= 1 }
	return text[:end]
}

// --- lifecycle -----------------------------------------------------------------

// codemode_lua_start creates the state, installs the environment, and compiles the chunk
// into a private coroutine. Nothing runs yet. A requested interrupt stops the run, and so
// does a positive timeout once it passes.
//
// A run is returned even when the chunk does not compile, so the caller can read the
// message; the caller destroys it either way. A nil run means nothing could be allocated.
codemode_lua_start :: proc(
	source: string,
	interrupt: ^ai.Interrupt = nil,
	timeout: time.Duration = 0,
	allocator := context.allocator,
) -> (
	run: ^Lua_Run,
	compiled: bool,
) {
	context.allocator = allocator
	allocation_error: mem.Allocator_Error
	run, allocation_error = new(Lua_Run)
	if allocation_error != nil { return nil, false }
	run^ = Lua_Run {
		allocator = allocator,
		interrupt = interrupt,
		request = {args_ref = lua.NOREF},
		logs = make([dynamic]u8),
	}
	if timeout > 0 { run.deadline = time.tick_add(time.tick_now(), timeout) }

	run.state = lua.newstate(codemode_lua_alloc, run)
	if run.state == nil {
		codemode_lua_settle(run, .Failed, .Memory, "the Lua state could not be created")
		return run, false
	}
	(cast(^^Lua_Run)lua.getextraspace(run.state))^ = run
	state := run.state

	codemode_lua_open_libraries(state)
	lua.pushcfunction(state, codemode_lua_print)
	lua.setglobal(state, "print")
	// `tools` raises on a name that is not a tool, and job.start checks names against it.
	lua.newtable(state)
	lua.createtable(state, 0, 1)
	lua.pushcfunction(state, codemode_lua_tools_index)
	lua.setfield(state, -2, "__index")
	lua.setmetatable(state, -2)
	lua.createtable(state, 0, 2)
	lua.pushvalue(state, -2)
	lua.pushcclosure(state, codemode_lua_job_start, 1)
	lua.setfield(state, -2, "start")
	lua.pushcfunction(state, codemode_lua_job_wait)
	lua.setfield(state, -2, "wait")
	lua.setglobal(state, "job")
	lua.setglobal(state, "tools")
	codemode_lua_install_table(state, "json", {{"encode", codemode_lua_json_encode}, {"decode", codemode_lua_json_decode}})
	// Lua nil means absence, so JSON null is a stable light-userdata identity.
	lua.getglobal(state, "json")
	lua.pushlightuserdata(state, run)
	lua.setfield(state, -2, "null")
	lua.pop(state, 1)
	lua.newtable(state)
	run.results_ref = lua.L_ref(state, lua.REGISTRYINDEX)

	// The thread stays on the main stack as a collector anchor.
	run.thread = lua.newthread(state)
	lua.sethook(run.thread, codemode_lua_hook, lua.MASKCOUNT, LUA_SLICE_INSTRUCTIONS)

	status := lua.L_loadbuffer(run.thread, raw_data(source), c.size_t(len(source)), LUA_CHUNK_NAME, "t")
	if status != .OK {
		text, _ := codemode_lua_stack_string(run.thread, -1)
		codemode_lua_settle(run, .Failed, .Syntax, text)
		return run, false
	}
	return run, true
}

// codemode_lua_install_tool adds one entry to the `tools` table under the tool's
// canonical name, which a script writes as an ordinary field: `tools.fff_grep`.
codemode_lua_install_tool :: proc(run: ^Lua_Run, name: string) -> bool {
	if run.state == nil || !tool_name_valid(name) { return false }
	state := run.state
	lua.getglobal(state, "tools")
	codemode_lua_push_string(state, name)
	codemode_lua_push_string(state, name)
	lua.pushcclosure(state, codemode_lua_tool_call, 1)
	lua.rawset(state, -3)
	lua.pop(state, 1)
	return true
}

// codemode_lua_resume runs one more slice, delivering the answers to a pending request. A
// request without answers stays pending, and a terminal run reports the observation that
// ended it again.
codemode_lua_resume :: proc(run: ^Lua_Run) -> Lua_Event {
	if run.terminal { return run.last_event }
	if !run.request.pending { return codemode_lua_step(run, 0) }
	if run.answer == .None { return .Host_Request }
	codemode_lua_request_clear(run)
	return codemode_lua_step(run, 0)
}

// codemode_lua_answer_error answers the pending request by raising message at the
// script's line, where the script may catch it with pcall. message is copied.
codemode_lua_answer_error :: proc(run: ^Lua_Run, message: string) {
	run.answer = .Error
	run.answer_message = strings.clone(message, run.allocator) or_else ""
}

// codemode_lua_answer_handle answers job.start with the child's handle.
codemode_lua_answer_handle :: proc(run: ^Lua_Run, handle: int) {
	run.answer = .Handle
	run.answer_handle = handle
}

// codemode_lua_answer_kept answers the pending request with the result kept under handle,
// which the answer releases.
codemode_lua_answer_kept :: proc(run: ^Lua_Run, handle: int) {
	run.answer = .Result
	run.answer_handle = handle
}

// codemode_lua_request_stop latches a stop. The run ends at its next slice.
codemode_lua_request_stop :: proc(run: ^Lua_Run) {
	run.stop_requested = true
}

codemode_lua_destroy :: proc(run: ^Lua_Run) {
	if run == nil { return }
	context.allocator = run.allocator
	// The reference lives in the registry, so it is released before the state closes.
	if run.state != nil {
		codemode_lua_request_clear(run)
		lua.close(run.state)
	}
	delete(run.answer_message)
	virtual.arena_destroy(&run.scratch)
	delete(run.message)
	delete(run.traceback)
	delete(run.logs)
	free(run)
}

@(private)
codemode_lua_request_clear :: proc(run: ^Lua_Run) {
	if run.request.args_ref != lua.NOREF { lua.L_unref(run.state, lua.REGISTRYINDEX, run.request.args_ref) }
	delete(run.request.name, run.allocator)
	run.request = {
		args_ref = lua.NOREF,
	}
}

@(private)
codemode_lua_step :: proc(run: ^Lua_Run, count: int) -> Lua_Event {
	results: c.int
	status := lua.resume(run.thread, run.state, c.int(count), &results)
	delete(run.answer_message, run.allocator)
	run.answer_message = ""
	virtual.arena_free_all(&run.scratch)
	switch status {
	case .OK:
		run.returned_values = int(results)
		return codemode_lua_settle(run, .Returned, .None, "")
	case .YIELD:
		if run.request.pending {
			run.last_event = .Host_Request
			return .Host_Request
		}
		if codemode_lua_stopping(run) { return codemode_lua_settle_stop(run) }
		run.last_event = .Slice
		return .Slice
	case .ERRMEM:
		text, _ := codemode_lua_stack_string(run.thread, -1)
		return codemode_lua_settle(run, .Failed, .Memory, text)
	case .ERRRUN, .ERRSYNTAX, .ERRERR, .ERRFILE:
		// A stop raised inside a C call surfaces here when nothing caught it.
		if codemode_lua_stopping(run) { return codemode_lua_settle_stop(run) }
		return codemode_lua_settle_error(run)
	}
	return codemode_lua_settle(run, .Failed, .Runtime, "the execution ended in an unknown state")
}

@(private)
codemode_lua_settle_stop :: proc(run: ^Lua_Run) -> Lua_Event {
	if codemode_lua_expired(run) { return codemode_lua_settle(run, .Failed, .Timed_Out, "the execution passed its timeout") }
	return codemode_lua_settle(run, .Stopped, .None, "the execution was cancelled")
}

// codemode_lua_settle_error keeps the error and, apart, the traceback of the frames it
// unwound, which the coroutine still holds after a failed resume. An error value that is
// not a string is written as its Lua literal, so `error({code = 1})` reads as itself.
@(private)
codemode_lua_settle_error :: proc(run: ^Lua_Run) -> Lua_Event {
	context.allocator = run.allocator
	text, is_text := codemode_lua_stack_string(run.thread, -1)
	literal, refusal, _ := codemode_lua_convert(run, run.thread, -1, .Lua, CODEMODE_LOG_MAX_NODES)
	defer delete(literal)
	defer delete(refusal)
	if !is_text {
		text = refusal == "" ? literal : string(lua.typename(run.thread, lua.type(run.thread, -1)))
		text = strings.concatenate({"the script raised a non-string error: ", text}, context.temp_allocator)
	}
	lua.L_traceback(run.state, run.thread, nil, 0)
	traceback, _ := codemode_lua_stack_string(run.state, -1)
	traceback = strings.trim_prefix(traceback, "stack traceback:\n")
	delete(run.traceback)
	run.traceback, _ = strings.replace_all(codemode_lua_truncate_runes(traceback, LUA_MAX_MESSAGE_BYTES), "\t", "")
	if raw_data(run.traceback) == raw_data(traceback) { run.traceback = strings.clone(run.traceback) or_else "" }
	lua.pop(run.state, 1)
	return codemode_lua_settle(run, .Failed, .Runtime, text)
}

// codemode_lua_settle makes the run terminal with its bounded message.
@(private)
codemode_lua_settle :: proc(run: ^Lua_Run, event: Lua_Event, failure: Lua_Failure, message: string) -> Lua_Event {
	run.terminal = true
	run.failure = failure
	run.last_event = event
	delete(run.message, run.allocator)
	run.message = strings.clone(codemode_lua_truncate_runes(message, LUA_MAX_MESSAGE_BYTES), run.allocator) or_else ""
	return event
}

// codemode_lua_returned_string reads the returned value when it is a string or number.
codemode_lua_returned_string :: proc(run: ^Lua_Run) -> (string, bool) {
	if run.last_event != .Returned || run.returned_values < 1 { return "", false }
	return codemode_lua_stack_string(run.thread, c.int(-run.returned_values))
}
