package agent

import "base:runtime"
import c "core:c"
import "core:mem"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import l "vendor:lua/5.4"

// --- Lua execution boundary ---------------------------------------------------
//
// This file owns one Lua 5.4 execution: the state, the restricted environment, the
// resource policy, and the suspension protocol. It knows nothing about tools, the
// session, or the model. Code Mode builds on it.
//
// The protocol is suspension, not callbacks. Script work runs on a private coroutine
// in bounded slices; the owner resumes it and reads what happened from its own data.
// Two things bring control back to the owner:
//
// - A tool wrapper yields a request. The owner answers it with `deliver`.
// - The count hook yields. The owner resumes for an ordinary slice, or stops for good
//   when a limit was reached. Every limit is enforced by not resuming.
//
// Yielding rather than raising is what makes the limits non-negotiable. Lua 5.4
// permits a count hook to yield with no values (`lua_sethook` in the reference
// manual), and a script cannot catch a suspension: it simply never runs again. A
// limit raised as an error from the hook would be catchable by `pcall`, which is the
// failure this design exists to avoid.
//
// The hook can only yield where the coroutine is yieldable. Inside a C library call,
// such as a comparator passed to `table.sort`, it is not, and yielding there raises
// "attempt to yield across a C-call boundary" into the script. The hook therefore
// checks `isyieldable` and defers a stop to the next firing instead of raising. The
// consequence to keep in mind: an instruction budget bounds Lua code, not work inside
// a C function, which is why the exposed library set is small and the inputs to its
// expensive operations are bounded hosts.

// --- policy -------------------------------------------------------------------

// Lua_Limits is the resource policy for one execution. Zero means no bound, which is
// only ever a deliberate choice: the defaults below are real limits.
Lua_Limits :: struct {
	// memory_bytes bounds Lua-managed memory. The allocator refuses a block that
	// would exceed it, which Lua reports as an out-of-memory error.
	memory_bytes: int,
	// instructions bounds VM instructions, the unit a count hook can measure.
	instructions: u64,
	// slice is how many instructions pass between owner checkpoints. It is the
	// granularity of cancellation, not a limit: a run at its slice boundary is
	// resumable.
	slice:        u64,
	// duration bounds wall-clock time from the first resume. It catches what an
	// instruction count cannot: a script parked inside a C function.
	duration:     time.Duration,
}

LUA_MEMORY_DEFAULT :: 32 * 1024 * 1024
LUA_INSTRUCTIONS_DEFAULT :: 10_000_000
LUA_SLICE_DEFAULT :: 10_000
LUA_SLICE_MAX :: 1_000_000
LUA_DURATION_DEFAULT :: 120 * time.Second

// LUA_MAX_MESSAGE_BYTES bounds a diagnostic read out of Lua. An error is a value in
// this harness, and the harness bounds every value it keeps.
LUA_MAX_MESSAGE_BYTES :: 1024

// LUA_MAX_LOG_BYTES bounds what `print` may keep. Output is returned, not streamed,
// so it is bounded where it is produced.
LUA_MAX_LOG_BYTES :: 8 * 1024

// LUA_HOST_RESERVE is extra memory available while the owner pushes values into Lua.
// A host-side push that runs out of memory raises an error with no protected frame to
// unwind to, which aborts the process. Host work therefore runs with a small reserve,
// so a script that has spent its budget cannot make the harness abort while a result
// is being delivered.
LUA_HOST_RESERVE :: 64 * 1024

lua_limits_default :: proc() -> Lua_Limits {
	return {memory_bytes = LUA_MEMORY_DEFAULT, instructions = LUA_INSTRUCTIONS_DEFAULT, slice = LUA_SLICE_DEFAULT, duration = LUA_DURATION_DEFAULT}
}

// Lua_Stop is why a run was stopped by policy. None is the zero value, so a run that
// was never stopped reads as running.
Lua_Stop :: enum {
	None,
	Cancelled,
	Deadline,
	Instructions,
}

// Lua_Failure is how a run failed on its own. None is the zero value: a run that
// suspended or returned has failed at nothing.
Lua_Failure :: enum {
	None,
	Syntax,
	Runtime,
	Memory,
}

// Lua_Event is what one step reported. Every member is an observation, and the owner
// decides what it means.
Lua_Event :: enum {
	// Returned: the chunk finished. Its values are on the coroutine stack.
	Returned,
	// Host_Request: the chunk asked the host to act. Nothing runs until it is answered.
	Host_Request,
	// Slice: the instruction slice ended with nothing terminal. Resuming continues.
	Slice,
	// Stopped: policy ended the run. It is never resumed.
	Stopped,
	// Failed: syntax, runtime, or memory failure. It is never resumed.
	Failed,
}

// Lua_Request_Kind is what a script asked for. One member today, because calling a
// tool is the only suspension a script has; task handles add members here, and every
// switch over this enum is exhaustive on purpose.
Lua_Request_Kind :: enum {
	Call,
}

// Lua_Request is one pending host request. name is owned by the run and valid until
// the request is answered or the run is destroyed. args_ref is a registry reference
// to the argument value, so the owner can convert it before answering without holding
// it on the coroutine stack.
Lua_Request :: struct {
	kind:     Lua_Request_Kind,
	name:     string,
	args_ref: c.int,
	pending:  bool,
}

// Lua_Run is one execution. Every field is owned by the run or an observed count.
Lua_Run :: struct {
	allocator:         mem.Allocator,
	limits:            Lua_Limits,
	L:                 ^l.State, // the main state; owns every value
	thread:            ^l.State, // the private coroutine the chunk runs on
	started:           time.Tick,
	instructions:      u64, // counted in slices, because the hook only knows the interval
	hook_fires:        int,
	non_yieldable:     int, // hook firings that could not yield; a stop waits for one that can
	memory_used:       int, // Lua-managed bytes, headers included
	memory_peak:       int,
	memory_limited:    bool, // the policy refused a block, rather than the system allocator
	host_reserve:      int, // extra headroom while the owner pushes values
	stop:              Lua_Stop, // latched; never cleared once set
	stop_requested:    bool, // the owner asked for cancellation
	failure:           Lua_Failure,
	terminal:          bool, // the run cannot be resumed
	message:           string, // owned; why it stopped or failed
	message_truncated: bool,
	logs:              [dynamic]u8, // owned; what print produced
	logs_truncated:    bool,
	request:           Lua_Request,
	steps:             int, // resumes, for diagnostics
	delivered:         int, // values the last delivery pushed, for the tool continuation
	last_event:        Lua_Event, // what resume and deliver report for a terminal run
	returned_values:   int,
}

// --- state access --------------------------------------------------------------

@(private)
code_mode_lua_run :: proc "c" (L: ^l.State) -> ^Lua_Run {
	space := cast(^rawptr)l.getextraspace(L)
	if space == nil || space^ == nil { return nil }
	return cast(^Lua_Run)space^
}

// code_mode_lua_bind attaches the run to a state. The hook and the tool wrappers are
// C callbacks that receive nothing but a state, so the run hangs off the state's extra
// space. It is set on the main state and again on the coroutine, because a new thread
// copies the extra space at creation.
@(private)
code_mode_lua_bind :: proc(run: ^Lua_Run, L: ^l.State) {
	space := cast(^rawptr)l.getextraspace(L)
	if space != nil { space^ = rawptr(run) }
}

// --- memory --------------------------------------------------------------------

@(private)
CODE_MODE_LUA_ALLOC_ALIGN :: 16

// CODE_MODE_LUA_ALLOCATION_SITE is the location recorded for the Lua heap. Lua
// allocates from C callbacks, which have no context, so the allocator interface is
// called directly and needs a location to pass along.
@(private)
CODE_MODE_LUA_ALLOCATION_SITE :: runtime.Source_Code_Location {
	file_path = "agent/code_mode_lua.odin",
	procedure = "code_mode_lua_alloc",
}

// code_mode_lua_string_clone copies a string with an explicit allocator. It exists
// because C callbacks have no context and so cannot call `strings.clone`.
@(private)
code_mode_lua_string_clone :: proc(text: string, allocator: mem.Allocator) -> string {
	if text == "" || allocator.procedure == nil { return "" }
	block, err := allocator.procedure(allocator.data, .Alloc, len(text), 1, nil, 0, CODE_MODE_LUA_ALLOCATION_SITE)
	if err != nil || block == nil || len(block) < len(text) { return "" }
	mem.copy(raw_data(block), raw_data(text), len(text))
	return string(block[:len(text)])
}

// code_mode_lua_string_free releases a string made by code_mode_lua_string_clone.
@(private)
code_mode_lua_string_free :: proc(text: string, allocator: mem.Allocator) {
	if text == "" || allocator.procedure == nil { return }
	_, _ = allocator.procedure(allocator.data, .Free, 0, 0, raw_data(text), len(text), CODE_MODE_LUA_ALLOCATION_SITE)
}

// code_mode_lua_alloc is Lua's allocator. It runs from a C callback, so it calls the
// caller's allocator value directly and keeps its own byte count: the live blocks'
// requested sizes, exactly. Returning nil makes Lua raise an out-of-memory error,
// which the resuming call reports as a value.
//
// The old size Lua passes is only meaningful for a reallocation. Lua passes a
// non-zero old size for fresh allocations too (358 times while opening the standard
// libraries in one measurement), so a fresh block is counted by its new size and
// never by a difference.
@(private)
code_mode_lua_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: c.size_t) -> rawptr {
	run := cast(^Lua_Run)ud
	if run == nil { return nil }
	// Calling through an Odin allocator value needs a context, and a C callback has
	// none. Nothing here logs; every allocation goes through the run's own allocator.
	context = runtime.default_context()

	if nsize == 0 {
		if ptr != nil {
			run.memory_used -= int(osize)
			_, _ = run.allocator.procedure(run.allocator.data, .Free, 0, 0, ptr, int(osize), CODE_MODE_LUA_ALLOCATION_SITE)
		}
		return nil
	}

	limit := run.limits.memory_bytes + run.host_reserve
	if limit > 0 && run.memory_used + int(nsize) > limit {
		run.memory_limited = true
		return nil
	}

	block, err := run.allocator.procedure(run.allocator.data, .Alloc, int(nsize), CODE_MODE_LUA_ALLOC_ALIGN, nil, 0, CODE_MODE_LUA_ALLOCATION_SITE)
	if err != nil || block == nil { return nil }

	if ptr != nil {
		copy_size := int(osize)
		if int(nsize) < copy_size { copy_size = int(nsize) }
		mem.copy(raw_data(block), ptr, copy_size)
		_, _ = run.allocator.procedure(run.allocator.data, .Free, 0, 0, ptr, int(osize), CODE_MODE_LUA_ALLOCATION_SITE)
		run.memory_used += int(nsize) - int(osize)
	} else {
		run.memory_used += int(nsize)
	}
	if run.memory_used > run.memory_peak { run.memory_peak = run.memory_used }
	return raw_data(block)
}

@(private)
code_mode_lua_host_enter :: proc(run: ^Lua_Run) {
	run.host_reserve = LUA_HOST_RESERVE
}

@(private)
code_mode_lua_host_leave :: proc(run: ^Lua_Run) {
	run.host_reserve = 0
}

// --- the count hook ------------------------------------------------------------

// code_mode_lua_hook runs every `slice` instructions. It counts what has been spent,
// latches any stop the policy calls for, and yields. It never raises: a raised error
// would be script-catchable, while a suspension is not.
@(private)
code_mode_lua_hook :: proc "c" (L: ^l.State, ar: ^l.Debug) {
	run := code_mode_lua_run(L)
	if run == nil { return }
	run.hook_fires += 1
	run.instructions += run.limits.slice

	if run.stop == .None {
		switch {
		case run.stop_requested:
			run.stop = .Cancelled
		case run.limits.duration > 0 && time.tick_since(run.started) >= run.limits.duration:
			run.stop = .Deadline
		case run.limits.instructions > 0 && run.instructions >= run.limits.instructions:
			run.stop = .Instructions
		}
	}

	// A hook may yield only from a yieldable frame, and only with no values. When the
	// frame is not yieldable the stop stays latched and is taken at the next firing.
	if !l.isyieldable(L) {
		run.non_yieldable += 1
		return
	}
	l.yield(L, 0)
}

// --- tool suspension -----------------------------------------------------------

// code_mode_lua_tool_call is the body of one entry in the `tools` table. Its single
// upvalue is the tool's canonical name. It records the request, takes a reference to
// the argument value, and suspends; the owner answers with `deliver`, and the
// continuation returns the delivered value to the script as the call's result.
@(private)
code_mode_lua_tool_call :: proc "c" (L: ^l.State) -> c.int {
	run := code_mode_lua_run(L)
	if run == nil || run.request.pending { return 0 }
	context = runtime.default_context()

	name := ""
	if l.type(L, l.REGISTRYINDEX - 1) == .STRING {
		length: c.size_t
		text := l.tolstring(L, l.REGISTRYINDEX - 1, &length)
		if text != nil { name = code_mode_lua_string_clone(string(text), run.allocator) }
	}
	args_ref: c.int = l.REFNIL
	if l.gettop(L) >= 1 { args_ref = l.L_ref(L, l.REGISTRYINDEX) }

	run.request.kind = .Call
	run.request.name = name
	run.request.args_ref = args_ref
	run.request.pending = true
	return c.int(l.yield(L, 0, 0, code_mode_lua_tool_resume))
}

@(private)
code_mode_lua_tool_resume :: proc "c" (L: ^l.State, status: c.int, ctx: l.KContext) -> c.int {
	run := code_mode_lua_run(L)
	if run == nil { return 0 }
	// The values the owner delivered are on top of the stack, and only those are the
	// call's results. The whole stack also holds the chunk and its arguments, so the
	// count comes from the run rather than from the stack depth.
	return c.int(run.delivered)
}

// --- restricted environment ----------------------------------------------------

// code_mode_lua_open_libraries installs the allowlist. `L_openlibs` is never called:
// a library that was never opened costs nothing to reason about, while one that was
// opened and then patched has to be kept patched.
@(private)
code_mode_lua_open_libraries :: proc(L: ^l.State) {
	l.L_requiref(L, cstring(l.GNAME), l.open_base, 1)
	l.pop(L, 1)
	l.L_requiref(L, cstring(l.STRLIBNAME), l.open_string, 1)
	l.pop(L, 1)
	l.L_requiref(L, cstring(l.TABLIBNAME), l.open_table, 1)
	l.pop(L, 1)
	l.L_requiref(L, cstring(l.MATHLIBNAME), l.open_math, 1)
	l.pop(L, 1)
	l.L_requiref(L, cstring(l.UTF8LIBNAME), l.open_utf8, 1)
	l.pop(L, 1)
}

// code_mode_lua_remove_global clears one global. Names are literals here, so this
// allocates nothing and cannot fail.
@(private)
code_mode_lua_remove_global :: proc(L: ^l.State, name: cstring) {
	l.pushnil(L)
	l.setglobal(L, name)
}

// code_mode_lua_remove_field clears one field of a global table.
@(private)
code_mode_lua_remove_field :: proc(L: ^l.State, table, field: cstring) {
	l.getglobal(L, table)
	if l.type(L, -1) != .TABLE {
		l.pop(L, 1)
		return
	}
	l.pushnil(L)
	l.setfield(L, -2, field)
	l.pop(L, 1)
}

// code_mode_lua_restrict keeps the base library's useful parts and removes the ones
// that reach outside the execution, escape the value boundary, or hand the script
// control of the collector. Removing a name that is absent is not an error.
@(private)
code_mode_lua_restrict :: proc(L: ^l.State) {
	// Loading and dynamic code.
	code_mode_lua_remove_global(L, "load")
	code_mode_lua_remove_global(L, "loadfile")
	code_mode_lua_remove_global(L, "dofile")
	code_mode_lua_remove_global(L, "require")
	// Control of the collector, and diagnostics the harness owns.
	code_mode_lua_remove_global(L, "collectgarbage")
	code_mode_lua_remove_global(L, "warn")
	// Metatable access: value conversion is the host's, and it must never run script
	// code, so a table the script can re-shape from the host side is not wanted.
	code_mode_lua_remove_global(L, "setmetatable")
	code_mode_lua_remove_global(L, "getmetatable")
	code_mode_lua_remove_global(L, "rawset")
	// Protected calls are deliberately absent for now: a tool outcome is a value, so a
	// script has nothing to catch, and leaving them out keeps the error surface small.
	code_mode_lua_remove_global(L, "pcall")
	code_mode_lua_remove_global(L, "xpcall")
	// print is the harness's, so it writes to the run's bounded log.
	code_mode_lua_remove_global(L, "print")
	// Bytecode dumping would put a compiler back in the script's hands.
	code_mode_lua_remove_field(L, "string", "dump")
}

// code_mode_lua_print appends one line to the run's bounded log. Numbers become their
// Lua text; anything else becomes a type name, because calling `tostring` would run a
// metatable the harness does not control.
@(private)
code_mode_lua_print :: proc "c" (L: ^l.State) -> c.int {
	run := code_mode_lua_run(L)
	// A C callback has no context. Nothing here logs through it; it exists so the
	// bounded log buffer can grow through the run's own allocator.
	context = runtime.default_context()
	if run == nil { return 0 }
	count := l.gettop(L)
	for index in 1 ..= int(count) {
		if index > 1 { code_mode_lua_log_append(run, " ") }
		text, ok := code_mode_lua_stack_string(L, c.int(index))
		if ok {
			code_mode_lua_log_append(run, text)
		} else {
			code_mode_lua_log_append(run, "<")
			code_mode_lua_log_append(run, string(l.typename(L, l.type(L, c.int(index)))))
			code_mode_lua_log_append(run, ">")
		}
	}
	code_mode_lua_log_append(run, "\n")
	return 0
}

// code_mode_lua_stack_string reads a value that is already text. Strings and numbers
// convert; nothing else does.
@(private)
code_mode_lua_stack_string :: proc(L: ^l.State, index: c.int) -> (string, bool) {
	kind := l.type(L, index)
	if kind != .STRING && kind != .NUMBER { return "", false }
	length: c.size_t
	pointer := l.tolstring(L, index, &length)
	if pointer == nil { return "", false }
	bytes := cast([^]u8)pointer
	return string(bytes[:int(length)]), true
}

@(private)
code_mode_lua_log_append :: proc(run: ^Lua_Run, text: string) {
	if run.logs_truncated || text == "" { return }
	room := LUA_MAX_LOG_BYTES - len(run.logs)
	if room <= 0 {
		run.logs_truncated = true
		return
	}
	take := text
	if len(take) > room {
		take = code_mode_lua_truncate_runes(take, room)
		run.logs_truncated = true
	}
	start := len(run.logs)
	if err := resize(&run.logs, start + len(take)); err != nil {
		run.logs_truncated = true
		return
	}
	mem.copy(rawptr(raw_data(run.logs[start:])), rawptr(raw_data(take)), len(take))
}

// code_mode_lua_truncate_runes takes at most limit bytes and never cuts a character.
@(private)
code_mode_lua_truncate_runes :: proc(text: string, limit: int) -> string {
	if limit >= len(text) { return text }
	end := limit
	for end > 0 && !utf8.rune_start(text[end]) { end -= 1 }
	return text[:end]
}

// --- lifecycle -----------------------------------------------------------------

// code_mode_lua_start creates the state, installs the restricted environment, and
// compiles the chunk into a private coroutine. Nothing runs yet.
//
// A run is returned even when the chunk does not compile, so the caller can read the
// message and must still destroy it. A nil run means the execution itself could not be
// allocated.
code_mode_lua_start :: proc(allocator: mem.Allocator, limits: Lua_Limits, source: string, name := "@code") -> (run: ^Lua_Run, compiled: bool) {
	backend := allocator
	if backend.procedure == nil { backend = context.allocator }

	block, block_error := mem.alloc(size_of(Lua_Run), align_of(Lua_Run), backend)
	if block == nil || block_error != nil { return nil, false }
	run = cast(^Lua_Run)block
	run^ = Lua_Run {
		allocator = backend,
		limits = limits,
		request = {args_ref = l.NOREF},
	}
	run.logs.allocator = backend
	if run.limits.slice == 0 { run.limits.slice = LUA_SLICE_DEFAULT }
	if run.limits.slice > LUA_SLICE_MAX { run.limits.slice = LUA_SLICE_MAX }

	run.L = l.newstate(code_mode_lua_alloc, rawptr(run))
	if run.L == nil {
		run.failure = .Memory
		run.terminal = true
		run.last_event = .Failed
		run.message = strings.clone("the Lua state could not be created", backend) or_else ""
		return run, false
	}
	code_mode_lua_bind(run, run.L)

	code_mode_lua_host_enter(run)
	code_mode_lua_open_libraries(run.L)
	code_mode_lua_restrict(run.L)
	l.pushcclosure(run.L, code_mode_lua_print, 0)
	l.setglobal(run.L, "print")
	l.newtable(run.L)
	l.setglobal(run.L, "tools")

	run.thread = l.newthread(run.L)
	// The thread stays on the main stack as a collector anchor: an unreferenced
	// suspended coroutine could otherwise be collected.
	code_mode_lua_bind(run, run.thread)
	l.sethook(run.thread, code_mode_lua_hook, l.MASKCOUNT, c.int(run.limits.slice))

	status := l.L_loadbuffer(run.thread, raw_data(source), c.size_t(len(source)), cstring(raw_data(name)), "t")
	code_mode_lua_host_leave(run)
	if status != .OK {
		run.failure = .Syntax
		run.terminal = true
		run.last_event = .Failed
		code_mode_lua_capture_message(run)
		return run, false
	}
	return run, true
}

// code_mode_lua_install_tool adds one entry to the `tools` table. The name is the
// canonical tool name, which is what a script writes between brackets.
code_mode_lua_install_tool :: proc(run: ^Lua_Run, name: string) -> bool {
	if run == nil || run.L == nil || name == "" || len(name) > TOOL_MAX_NAME_BYTES { return false }
	if strings.index_byte(name, 0) >= 0 { return false }
	code_mode_lua_host_enter(run)
	defer code_mode_lua_host_leave(run)

	// lua_getglobal answers with the type it pushed, not an index, so the index is read
	// from the stack top.
	_ = l.getglobal(run.L, "tools")
	table_index := l.gettop(run.L)
	if l.type(run.L, table_index) != .TABLE {
		l.settop(run.L, table_index - 1)
		return false
	}
	// The key goes on the stack before the value: `settable` reads t[top-2] = t[top-1].
	// The closure needs the name as its upvalue, and `pushcclosure` pops that upvalue, so
	// the name is pushed twice: once for the key, once for the closure. The table index
	// is kept from before the pushes rather than counted from the top; a wrong index is
	// an unprotected Lua error, which would abort the process.
	l.pushlstring(run.L, cstring(raw_data(name)), c.size_t(len(name)))
	l.pushlstring(run.L, cstring(raw_data(name)), c.size_t(len(name)))
	l.pushcclosure(run.L, code_mode_lua_tool_call, 1)
	l.settable(run.L, table_index)
	l.settop(run.L, table_index - 1)
	return true
}

// code_mode_lua_resume runs the script until it returns, requests, finishes a slice,
// is stopped, or fails. A run that is already terminal reports the observation that
// ended it again and runs nothing.
code_mode_lua_resume :: proc(run: ^Lua_Run) -> Lua_Event {
	if run == nil { return .Failed }
	if run.terminal { return run.last_event }
	if run.request.pending { return .Host_Request }
	return code_mode_lua_step(run, 0)
}

// code_mode_lua_deliver answers the pending request with the `nargs` values the caller
// has pushed on the coroutine stack, which become the tool call's result.
code_mode_lua_deliver :: proc(run: ^Lua_Run, nargs: int) -> Lua_Event {
	if run == nil { return .Failed }
	if run.terminal { return run.last_event }
	if !run.request.pending { return .Failed }
	code_mode_lua_request_clear(run)
	return code_mode_lua_step(run, nargs)
}

// code_mode_lua_deliver_string answers the pending request with one string. It is the
// simple case of delivery: the push happens under the host reserve, so a script cannot
// turn a spent budget into an abort.
code_mode_lua_deliver_string :: proc(run: ^Lua_Run, text: string) -> Lua_Event {
	if run == nil || run.thread == nil { return .Failed }
	if run.terminal { return run.last_event }
	if !run.request.pending { return .Failed }
	code_mode_lua_host_enter(run)
	pushed := l.pushlstring(run.thread, cstring(raw_data(text)), c.size_t(len(text))) != nil
	code_mode_lua_host_leave(run)
	if !pushed { return .Failed }
	return code_mode_lua_deliver(run, 1)
}

@(private)
code_mode_lua_request_clear :: proc(run: ^Lua_Run) {
	if run.request.args_ref != l.REFNIL && run.request.args_ref != l.NOREF {
		l.L_unref(run.L, l.REGISTRYINDEX, run.request.args_ref)
	}
	code_mode_lua_string_free(run.request.name, run.allocator)
	run.request.name = ""
	run.request.args_ref = l.NOREF
	run.request.pending = false
}

@(private)
code_mode_lua_step :: proc(run: ^Lua_Run, nargs: int) -> Lua_Event {
	run.steps += 1
	run.delivered = nargs
	// The wall-clock bound starts at the first resume, not at creation: a run may wait
	// for its turn, and time spent waiting is not execution time.
	if run.steps == 1 { run.started = time.tick_now() }
	results: c.int
	status := l.resume(run.thread, run.L, c.int(nargs), &results)
	switch status {
	case .OK:
		run.terminal = true
		run.returned_values = int(results)
		run.last_event = .Returned
		return .Returned
	case .YIELD:
		if run.stop != .None {
			// The hook suspended the coroutine so the run would stop here. It is never
			// resumed, which is what makes the stop uncatchable.
			run.terminal = true
			code_mode_lua_latch_message(run, lua_stop_message(run.stop))
			run.last_event = .Stopped
			return .Stopped
		}
		if run.request.pending {
			run.last_event = .Host_Request
			return .Host_Request
		}
		run.last_event = .Slice
		return .Slice
	case .ERRMEM:
		run.terminal = true
		run.failure = .Memory
		if run.memory_limited {
			run.message = strings.clone("the execution exceeded its memory budget", run.allocator) or_else ""
		} else {
			code_mode_lua_capture_message(run)
		}
		run.last_event = .Failed
		return .Failed
	case .ERRRUN, .ERRSYNTAX, .ERRERR, .ERRFILE:
		run.terminal = true
		run.failure = .Runtime
		code_mode_lua_capture_message(run)
		run.last_event = .Failed
		return .Failed
	}
	run.terminal = true
	run.failure = .Runtime
	code_mode_lua_latch_message(run, "the execution ended in an unknown state")
	run.last_event = .Failed
	return .Failed
}

@(private)
lua_stop_message :: proc(stop: Lua_Stop) -> string {
	switch stop {
	case .None:
		return ""
	case .Cancelled:
		return "the execution was cancelled"
	case .Deadline:
		return "the execution exceeded its time budget"
	case .Instructions:
		return "the execution exceeded its instruction budget"
	}
	return ""
}

// code_mode_lua_capture_message copies the error on top of the coroutine stack,
// bounded and cut on a character boundary.
@(private)
code_mode_lua_capture_message :: proc(run: ^Lua_Run) {
	text, ok := code_mode_lua_stack_string(run.thread, -1)
	if !ok {
		code_mode_lua_latch_message(run, "the execution failed")
		return
	}
	code_mode_lua_latch_message(run, text)
}

@(private)
code_mode_lua_latch_message :: proc(run: ^Lua_Run, text: string) {
	delete(run.message, run.allocator)
	body := text
	if len(body) > LUA_MAX_MESSAGE_BYTES {
		body = code_mode_lua_truncate_runes(body, LUA_MAX_MESSAGE_BYTES)
		run.message_truncated = true
	}
	run.message = strings.clone(body, run.allocator) or_else ""
}

// code_mode_lua_request_stop asks the run to stop at its next checkpoint. The request
// is latched: a script cannot cancel it, and a run that already stopped keeps its
// first reason.
code_mode_lua_request_stop :: proc(run: ^Lua_Run) {
	if run == nil { return }
	run.stop_requested = true
}

code_mode_lua_destroy :: proc(run: ^Lua_Run) {
	if run == nil { return }
	allocator := run.allocator
	// The reference is released while the state is still open: closing the state frees
	// the registry the reference lives in.
	code_mode_lua_request_clear(run)
	if run.L != nil {
		// Closing the main state releases every value, including a coroutine that was
		// suspended and never resumed.
		l.close(run.L)
		run.L = nil
		run.thread = nil
	}
	delete(run.message, allocator)
	delete(run.logs)
	mem.free(rawptr(run), allocator)
}

// --- observations --------------------------------------------------------------

// code_mode_lua_terminal reports whether the run cannot be resumed.
code_mode_lua_terminal :: proc(run: ^Lua_Run) -> bool {
	return run == nil || run.terminal
}

code_mode_lua_message :: proc(run: ^Lua_Run) -> string {
	if run == nil { return "" }
	return run.message
}

code_mode_lua_logs :: proc(run: ^Lua_Run) -> string {
	if run == nil { return "" }
	return string(run.logs[:])
}

code_mode_lua_logs_truncated :: proc(run: ^Lua_Run) -> bool {
	return run != nil && run.logs_truncated
}

code_mode_lua_failure :: proc(run: ^Lua_Run) -> Lua_Failure {
	if run == nil { return .Runtime }
	return run.failure
}

code_mode_lua_stop :: proc(run: ^Lua_Run) -> Lua_Stop {
	if run == nil { return .None }
	return run.stop
}

code_mode_lua_instructions :: proc(run: ^Lua_Run) -> u64 {
	if run == nil { return 0 }
	return run.instructions
}

code_mode_lua_memory_used :: proc(run: ^Lua_Run) -> int {
	if run == nil { return 0 }
	return run.memory_used
}

code_mode_lua_memory_peak :: proc(run: ^Lua_Run) -> int {
	if run == nil { return 0 }
	return run.memory_peak
}

code_mode_lua_returned_values :: proc(run: ^Lua_Run) -> int {
	if run == nil { return 0 }
	return run.returned_values
}

// code_mode_lua_returned_boolean reports whether the returned value is true. It exists
// so a caller can read the easy case of a result (a script answering a yes/no question)
// without a value conversion, which is a separate concern.
code_mode_lua_returned_boolean :: proc(run: ^Lua_Run) -> bool {
	if run == nil || run.thread == nil || !run.terminal || run.returned_values < 1 { return false }
	return l.toboolean(run.thread, c.int(-run.returned_values)) != false
}

// code_mode_lua_returned_string reads the returned value when it is a string.
code_mode_lua_returned_string :: proc(run: ^Lua_Run) -> (string, bool) {
	if run == nil || run.thread == nil || !run.terminal || run.returned_values < 1 { return "", false }
	return code_mode_lua_stack_string(run.thread, c.int(-run.returned_values))
}

// code_mode_lua_returned_number reports the returned value when it is a number.
code_mode_lua_returned_number :: proc(run: ^Lua_Run) -> (i64, bool) {
	if run == nil || run.thread == nil || !run.terminal || run.returned_values < 1 { return 0, false }
	ok: b32
	value := l.tointeger(run.thread, c.int(-run.returned_values), &ok)
	if !ok { return 0, false }
	return i64(value), true
}
