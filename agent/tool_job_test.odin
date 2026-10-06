#+test
package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

// The tool job suite. It holds the properties the batch's phases exist for: a call
// runs off the owner's thread, a lane serializes what must not overlap, the worker
// bound holds, a stop still answers every committed call, and release leaves no thread
// and no byte behind.
//
// Every test drives the table directly instead of calling chat_run_tools, because the
// interesting states exist while a call is still running and the batch driver would
// run past them.

// --- a held executor -----------------------------------------------------------

// Held tools let a test look at the table while a call is running. Every field is
// touched by a worker and by the test thread, so all of them are read and written
// atomically. The state is per test: the executor's fixed signature reports
// through the definition's backend, so parallel tests never observe each other.
// The zero value is ready; no reset is needed.
Tool_Job_Hold_State :: struct {
	running: i32,
	// thread is the thread the last held call ran on, which is how a test
	// says the call left the owner.
	thread:  i64,
	release: i32,
}

// Tool_Job_Hold_Lane is the borrowed backend identity a held definition is
// registered with. Distinct addresses are distinct lanes; definitions sharing
// one address run one at a time. The lane carries its test's state, so the
// executor reaches per-test counters through tool_context.backend.
Tool_Job_Hold_Lane :: struct {
	state: ^Tool_Job_Hold_State,
}

tool_job_hold_lane :: proc(state: ^Tool_Job_Hold_State) -> Tool_Job_Hold_Lane {
	return {state = state}
}

tool_job_hold_state :: proc(lane: ^Tool_Job_Hold_Lane) -> ^Tool_Job_Hold_State {
	return lane.state
}

tool_job_hold_thread_id :: proc(state: ^Tool_Job_Hold_State) -> i64 {
	return sync.atomic_load(&state.thread)
}

tool_job_hold_released :: proc(state: ^Tool_Job_Hold_State) -> bool {
	return sync.atomic_load(&state.release) != 0
}

tool_job_hold_release_all :: proc(state: ^Tool_Job_Hold_State) {
	sync.atomic_store(&state.release, i32(1))
}

// tool_job_hold_execute blocks until the test releases it or its own control ends.
tool_job_hold_execute :: proc(tool_context: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	state := tool_job_hold_state(cast(^Tool_Job_Hold_Lane)tool_context.backend)
	sync.atomic_add(&state.running, 1)
	defer sync.atomic_add(&state.running, -1)
	sync.atomic_store(&state.thread, i64(linux.gettid()))
	for !tool_job_hold_released(state) {
		if tool_control_cancelled(tool_context.control) {
			return tool_result_failure(tool_context, .Cancelled, "the call was stopped", "cancelled")
		}
		time.sleep(time.Millisecond)
	}
	return tool_result_success(tool_context, nil, "held")
}

// tool_job_immediate_execute finishes at once, which is what an owner-placed control
// operation does.
tool_job_immediate_execute :: proc(tool_context: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	return tool_result_success(tool_context, nil, "immediate")
}

// tool_job_hold_definition is a held tool in one lane. lane is the borrowed backend
// identity: two definitions sharing one run one at a time. The lane carries the
// test's own counters, so parallel tests never observe each other.
tool_job_hold_definition :: proc(lane: ^Tool_Job_Hold_Lane, name: string, execute := tool_job_hold_execute) -> Tool_Definition {
	return Tool_Definition {
		name = name,
		description = "A tool the job tests control.",
		input_schema = `{"type":"object"}`,
		placement = .Worker,
		execute = execute,
		backend = lane,
		lane = lane,
	}
}

tool_job_test_register :: proc(test: ^testing.T, tool_test: ^Tool_Test, definition: Tool_Definition) {
	added := tool_registry_add(&tool_test.fixture.chat.tools, definition)
	if added.kind != .None { testing.fail_now(test, "the test tool was not registered") }
}

// --- driving -------------------------------------------------------------------

// tool_job_test_step performs exactly one effect and reports which one it was, so a
// test can assert the decision before its consequence exists.
tool_job_test_step :: proc(tool_test: ^Tool_Test, jobs: ^Tool_Jobs) -> Tool_Job_Effect {
	return tool_job_test_step_at(tool_test, jobs, time.tick_now())
}

// tool_job_test_step_at is the same step with the owner's clock supplied, so a test can
// reach the stop patience without waiting it out.
tool_job_test_step_at :: proc(tool_test: ^Tool_Test, jobs: ^Tool_Jobs, now: time.Tick) -> Tool_Job_Effect {
	chat := &tool_test.fixture.chat
	tool_jobs_observe(jobs, chat, now)
	effect := tool_jobs_next(jobs, now)
	switch effect {
	case .Commit:
		tool_jobs_commit(jobs, chat, {})
	case .Refuse:
		tool_jobs_refuse(jobs)
	case .Abandon:
		tool_jobs_abandon(jobs, chat, {}, now)
	case .Retire:
		tool_jobs_retire(jobs, chat, now)
	case .Dispatch:
		tool_jobs_dispatch(jobs, chat)
	case .Wait:
		// A stepped test advances its own clock, so the wait is bounded by the real one: what
		// it is waiting for is a worker's publication, not a deadline its own simulation has
		// already moved past.
		tool_jobs_await(jobs, time.tick_add(time.tick_now(), time.Millisecond), owner_wake_seen())
	case .Done:
	}
	return effect
}

// tool_job_test_drain drives the batch to done the way the real driver does, latching
// any stop the session recorded first. The step cap turns a stuck job into a failure
// instead of a hang.
tool_job_test_drain :: proc(test: ^testing.T, tool_test: ^Tool_Test, jobs: ^Tool_Jobs) {
	chat := &tool_test.fixture.chat
	for _ in 0 ..< 100_000 {
		tool_jobs_latch_stop(jobs, chat)
		if tool_job_test_step(tool_test, jobs) == .Done { return }
	}
	testing.fail_now(test, "the batch never settled")
}

// --- a call that ignores its stop ----------------------------------------------

// A deaf tool never looks at its control: it keeps working until the test releases it,
// which is what a backend stuck in a syscall looks like to the owner. It reports
// through its lane's per-test state like a held tool does.
tool_job_deaf_execute :: proc(tool_context: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	state := tool_job_hold_state(cast(^Tool_Job_Hold_Lane)tool_context.backend)
	sync.atomic_add(&state.running, 1)
	for sync.atomic_load(&state.release) == 0 {
		time.sleep(time.Millisecond)
	}
	sync.atomic_add(&state.running, -1)
	return tool_result_success(tool_context, nil, "late")
}

// tool_job_test_hold_until waits for count held executions to be inside the executor,
// so a test observes running jobs rather than a scheduling guess. The wait is
// bounded: a job that never started (a failed launch, a stop before dispatch)
// must fail the test, never hang it.
tool_job_test_hold_until :: proc(test: ^testing.T, state: ^Tool_Job_Hold_State, count: i32) {
	for _ in 0 ..< 10_000 {
		if sync.atomic_load(&state.running) >= count { return }
		time.sleep(time.Millisecond)
	}
	// Release before failing, so a worker still inside the executor leaves
	// instead of spinning on a test that is already gone.
	sync.atomic_store(&state.release, 1)
	testing.fail_now(test, "the held calls never started")
}

// --- tests ---------------------------------------------------------------------

@(test)
test_codemode_suspends_for_a_nested_tool_job :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test_child", tool_job_immediate_execute))
	_test_stage_call(
		test,
		chat,
		"call_code",
		`{"code":"local first = tools.test_child({value = 7})\nlocal second = tools.test_child({value = 8})\nreturn first.outcome .. \"+\" .. second.outcome"}`,
		TOOL_CODEMODE_NAME,
	)

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})
	tool_job_test_drain(test, &tool_test, &jobs)

	testing.expect_value(test, len(jobs.jobs), 3)
	parent := jobs.jobs[0]
	first_child := jobs.jobs[1]
	second_child := jobs.jobs[2]
	testing.expect_value(test, parent.phase, Tool_Job_Phase.Retired)
	testing.expect_value(test, first_child.phase, Tool_Job_Phase.Retired)
	testing.expect_value(test, second_child.phase, Tool_Job_Phase.Retired)
	testing.expect(test, first_child.parent == parent, "the first nested call should belong to the Code Mode job")
	testing.expect(test, second_child.parent == parent, "the second nested call should belong to the Code Mode job")
	testing.expect(test, first_child.nested && second_child.nested, "nested calls should own their staged records")
	value, present := codemode_lua_returned_string(parent.lua)
	testing.expect(test, present, "the script should return the child outcomes")
	testing.expect_value(test, value, "success+success")
	testing.expect_value(test, jobs.committed, 3)
	testing.expect_value(test, tool_jobs_committed(&jobs), 1)
}

// tool_job_test_full_table refuses to grow the batch table, so a job that never reaches
// the table is reachable without a storage failure. Freeing still goes to the heap it
// handed out.
@(private)
tool_job_test_full_table :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	tracker := cast(^mem.Tracking_Allocator)data
	if mode == .Alloc { return nil, .Out_Of_Memory }
	return mem.tracking_allocator_proc(tracker, mode, size, alignment, old_memory, old_size, location)
}

// A nested child that cannot be published is released with the allocator that owns worker
// job storage, not the session allocator that owns the table.
@(test)
test_an_unpublished_nested_tool_job_frees_with_worker_allocator :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat

	worker_track: mem.Tracking_Allocator
	session_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&worker_track, context.allocator)
	mem.tracking_allocator_init(&session_track, context.allocator)
	session_track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	defer mem.tracking_allocator_destroy(&worker_track)
	defer mem.tracking_allocator_destroy(&session_track)

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, 0, mem.tracking_allocator(&worker_track))
	jobs.allocator = mem.tracking_allocator(&session_track)
	jobs.jobs.allocator = mem.Allocator {
		procedure = tool_job_test_full_table,
		data      = &session_track,
	}
	defer tool_jobs_destroy(&jobs)

	run, compiled := codemode_lua_start(`return tools.test({})`)
	if run == nil { testing.fail_now(test, "the Lua run could not be created") }
	defer codemode_lua_destroy(run)
	if !compiled { testing.fail_now(test, "the Lua test chunk did not compile") }
	if !codemode_lua_install_tool(run, "test") { testing.fail_now(test, "the Lua tool could not be installed") }
	if !testing.expect_value(test, codemode_lua_resume(run), Lua_Event.Host_Request) { return }

	call := Chat_Tool_Call {
		call = 1,
	}
	parent := Tool_Job {
		placement = .Lua,
		allocator = context.allocator,
		call_id   = chat_clone_string("parent", context.allocator) or_else "",
		lua       = run,
		call      = &call,
		turn_id   = chat.active_turn_id,
	}
	children, children_error := make([dynamic]Codemode_Child, 0, 1, context.allocator)
	if children_error != nil { testing.fail_now(test, "the parent tracking table could not be allocated") }
	parent.lua_children = children
	defer delete(parent.lua_children)
	parent.exec = Tool_Context {
		call_id   = parent.call_id,
		allocator = parent.allocator,
	}
	defer delete(parent.call_id, parent.allocator)
	defer if parent.result_present { tool_result_destroy(&parent.result) }

	codemode_job_request(&jobs, chat, &parent)

	testing.expect_value(test, parent.phase, Tool_Job_Phase.Result_Ready)
	testing.expect_value(test, len(jobs.jobs), 0)
	testing.expect_value(test, len(parent.lua_children), 0)
	testing.expect_value(test, len(worker_track.allocation_map), 0)
	testing.expect_value(test, len(session_track.bad_free_array), 0)
}

@(test)
test_an_untracked_nested_tool_job_is_never_published :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test", tool_job_immediate_execute))

	worker_track: mem.Tracking_Allocator
	session_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&worker_track, context.allocator)
	mem.tracking_allocator_init(&session_track, context.allocator)
	session_track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	defer mem.tracking_allocator_destroy(&worker_track)
	defer mem.tracking_allocator_destroy(&session_track)

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, 0, mem.tracking_allocator(&worker_track))
	defer tool_jobs_destroy(&jobs)

	run, compiled := codemode_lua_start(`return tools.test({})`)
	if run == nil { testing.fail_now(test, "the Lua run could not be created") }
	defer codemode_lua_destroy(run)
	if !compiled { testing.fail_now(test, "the Lua test chunk did not compile") }
	if !codemode_lua_install_tool(run, "test") { testing.fail_now(test, "the Lua tool could not be installed") }
	if !testing.expect_value(test, codemode_lua_resume(run), Lua_Event.Host_Request) { return }

	call := Chat_Tool_Call {
		call = 1,
	}
	parent := Tool_Job {
		placement = .Lua,
		allocator = context.allocator,
		call_id   = chat_clone_string("parent", context.allocator) or_else "",
		lua       = run,
		call      = &call,
		turn_id   = chat.active_turn_id,
	}
	parent.lua_children.allocator = mem.Allocator {
		procedure = tool_job_test_full_table,
		data      = &session_track,
	}
	parent.exec = Tool_Context {
		call_id   = parent.call_id,
		allocator = parent.allocator,
	}
	defer delete(parent.call_id, parent.allocator)
	defer delete(parent.lua_children)
	defer if parent.result_present { tool_result_destroy(&parent.result) }

	codemode_job_request(&jobs, chat, &parent)

	testing.expect_value(test, parent.phase, Tool_Job_Phase.Result_Ready)
	testing.expect_value(test, parent.result.outcome, journal.Tool_Outcome.Tool_Failed)
	testing.expect_value(test, len(parent.lua_children), 0)
	testing.expect_value(test, len(jobs.jobs), 0)
	testing.expect_value(test, len(worker_track.allocation_map), 0)
	testing.expect_value(test, len(session_track.bad_free_array), 0)
}

@(test)
test_codemode_waiting_on_a_child_expires_and_stops_it :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat

	source := `local result = tools.builtin_shell({command = "sleep 5", timeout_ms = 10000}) return result.outcome`
	arguments := make(json.Object, 2, context.temp_allocator)
	arguments["code"] = json.String(source)
	arguments["timeout_ms"] = json.Integer(100)
	encoded, encode_error := json.marshal(arguments, allocator = context.temp_allocator)
	if encode_error != nil { testing.fail_now(test, "the Code Mode arguments could not be encoded") }
	_test_stage_call(test, chat, "call_code", string(encoded), TOOL_CODEMODE_NAME)

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	started := time.tick_now()
	tool_job_test_drain(test, &tool_test, &jobs)
	elapsed := time.tick_since(started)

	parent := jobs.jobs[0]
	if !testing.expect_value(test, parent.lua.failure, Lua_Failure.Timed_Out) { return }
	if !testing.expect_value(test, len(parent.lua_children), 1) { return }
	testing.expect_value(test, parent.lua_children[0].outcome, journal.Tool_Outcome.Cancelled)
	testing.expect(test, elapsed < time.Second * 2, "the parent timeout should stop its child before the child's timeout")
	result := tool_test_last_result(test, chat)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Timed_Out)
}

// job.start runs calls while the script continues, job.wait takes their results in any
// order, and a call the script never waited for is stopped and still reported.
@(test)
test_codemode_jobs_start_and_wait_in_any_order :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test_child", tool_job_immediate_execute))
	source := `local a = job.start("test_child", {value = 1})
local b = job.start("test_child", {value = 2})
local second = job.wait(b)
local first = job.wait(a)
local again = pcall(job.wait, a)
job.start("test_child")
return first.outcome .. " " .. second.outcome .. " " .. tostring(again)`
	object := make(json.Object, 1, context.temp_allocator)
	object["code"] = json.String(source)
	arguments, marshal_error := json.marshal(object, allocator = context.temp_allocator)
	if marshal_error != nil { testing.fail_now(test, "the arguments could not be built") }
	_test_stage_call(test, chat, "call_code", string(arguments), TOOL_CODEMODE_NAME)

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})
	tool_job_test_drain(test, &tool_test, &jobs)

	if !testing.expect_value(test, len(jobs.jobs), 4) { return }
	value, _ := codemode_lua_returned_string(jobs.jobs[0].lua)
	testing.expect_value(test, value, "success success false")
	for job in jobs.jobs { testing.expect_value(test, job.phase, Tool_Job_Phase.Retired) }
	testing.expect_value(test, tool_jobs_committed(&jobs), 1)
	testing.expect_value(test, jobs.committed, 4)
}

// Admission must preserve every call the provider committed, including a batch larger
// than the old fixed table size. Unknown tools get results instead of disappearing.
@(test)
test_tool_batch_admits_every_committed_call :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	call_count :: 65
	for index in 0 ..< call_count {
		_test_stage_call(test, chat, fmt.tprintf("call_%d", index), "{}", "missing_tool")
	}

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})
	testing.expect_value(test, len(jobs.jobs), call_count)
	for job in jobs.jobs {
		testing.expect_value(test, job.phase, Tool_Job_Phase.Result_Ready)
	}
}

// A script can submit more child calls than the old one-response table size. The
// table keeps every job until the batch ends, even after a child has committed.
CODEMODE_TEST_CHILD_CALLS :: 72

@(test)
test_codemode_may_exceed_one_response_worth_of_calls :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test_step", tool_job_immediate_execute))
	// More children than the old fixed batch size.
	source := fmt.aprintf(
		`local seen = 0 for i = 1, %d do local r = tools.test_step() if r.outcome == "success" then seen = seen + 1 end end return seen`,
		CODEMODE_TEST_CHILD_CALLS,
		allocator = context.temp_allocator,
	)
	object := make(json.Object, 1, context.temp_allocator)
	object["code"] = json.String(source)
	arguments, marshal_error := json.marshal(object, allocator = context.temp_allocator)
	if marshal_error != nil { testing.fail_now(test, "the arguments could not be built") }
	_test_stage_call(test, chat, "call_code", string(arguments), TOOL_CODEMODE_NAME)

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})
	tool_job_test_drain(test, &tool_test, &jobs)

	testing.expect_value(test, len(jobs.jobs), CODEMODE_TEST_CHILD_CALLS + 1)
	testing.expect_value(test, tool_jobs_committed(&jobs), 1)

	// The parent's answer is what the script computed from every child it ran. A completion
	// names the call it settles, so the parent's answer is the completion whose call is
	// `call_code`, found by following that link rather than by guessing which result came
	// first.
	records := _test_records(test, chat, {.Tool_Proposed, .Tool_Completed})
	parent_call := journal.Call_Id(0)
	for record in records {
		if record.kind != .Tool_Proposed { continue }
		proposed: journal.Tool_Proposed
		if decode_error := journal.payload_decode(record.data, &proposed, context.temp_allocator); decode_error != nil {
			testing.fail_now(test, "a recorded proposal could not be read")
		}
		if proposed.provider_id == "call_code" { parent_call = record.call }
	}
	if !testing.expect(test, parent_call != 0, "the parent call should be recorded") { return }

	found := false
	for record in records {
		if record.kind != .Tool_Completed || record.call != parent_call { continue }
		found = true
		result := tool_test_result_of(test, record)
		testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
		testing.expect(test, strings.contains(result.content, fmt.tprintf(`value: %d`, CODEMODE_TEST_CHILD_CALLS)), result.content)
		// Every child the script committed is named in the parent's result, one summary
		// line each, however many there were.
		committed := 0
		for child_record in records {
			if child_record.kind == .Tool_Completed && child_record.parent_call == parent_call { committed += 1 }
		}
		testing.expect_value(test, committed, CODEMODE_TEST_CHILD_CALLS)
		testing.expect_value(test, strings.count(result.content, "call: "), CODEMODE_TEST_CHILD_CALLS)
	}
	testing.expect(test, found, "the script should have answered its call")
}

// A script's result says what the script did: one summary line per call, so a script that
// ran a hundred calls does not put a hundred results into the conversation.
@(test)
test_codemode_reports_what_its_script_did :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test_child", tool_job_immediate_execute))
	_test_stage_call(test, chat, "call_code", `{"code":"local a = tools.test_child()\nlocal b = tools.test_child()\nreturn \"done\""}`, TOOL_CODEMODE_NAME)

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})
	tool_job_test_drain(test, &tool_test, &jobs)

	records := _test_records(test, chat, {.Tool_Proposed, .Tool_Completed})
	// The parent is the call the response staged; every child completion names it.
	parent_call := journal.Call_Id(0)
	for record in records {
		if record.kind != .Tool_Proposed { continue }
		proposed: journal.Tool_Proposed
		if decode_error := journal.payload_decode(record.data, &proposed, context.temp_allocator); decode_error != nil {
			testing.fail_now(test, "a recorded proposal could not be read")
		}
		if proposed.provider_id == "call_code" { parent_call = record.call }
	}
	if !testing.expect(test, parent_call != 0, "the parent call should be recorded") { return }

	// Every child call the script made, by the call id a reader would name it by.
	child_calls := make([dynamic]journal.Call_Id, 0, 4, context.temp_allocator)
	content := ""
	for record in records {
		if record.kind != .Tool_Completed { continue }
		if record.call == parent_call { content = string(record.body) }
		if record.parent_call == parent_call { append(&child_calls, record.call) }
	}
	if !testing.expect_value(test, len(child_calls), 2) { return }
	if !testing.expect(test, content != "", "the parent should have recorded its result") { return }

	testing.expect(test, strings.contains(content, `calls_total: 2`), content)
	for child_call in child_calls {
		want := fmt.tprintf("call: %d test_child success", child_call)
		testing.expectf(test, strings.contains(content, want), "%s should carry %s", content, want)
	}
}

// A worker-placed call runs on its own thread: the test thread keeps going while the
// call is still inside the executor, and the batch is not advanced by the completion.
@(test)
test_a_worker_placed_call_runs_on_another_thread :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test_hold"))
	_test_stage_call(test, chat, "call_hold", `{}`, "test_hold")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	testing.expect_value(test, tool_job_test_step(&tool_test, &jobs), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(test, &hold, 1)
	testing.expect(test, tool_job_hold_thread_id(&hold) != i64(linux.gettid()), "the call must not run on the owner's thread")
	testing.expect_value(test, jobs.jobs[0].phase, Tool_Job_Phase.Running)
	// The only thing left to do is wait: the call owns the lane and the owner.
	testing.expect_value(test, tool_jobs_next(&jobs, time.tick_now()), Tool_Job_Effect.Wait)

	tool_job_hold_release_all(&hold)
	tool_job_test_drain(test, &tool_test, &jobs)
	testing.expect_value(test, jobs.committed, 1)
	testing.expect_value(test, jobs.jobs[0].phase, Tool_Job_Phase.Retired)
}

// Native tools share one lane, so a second call waits for the first even though a
// worker slot is free.
@(test)
test_native_calls_share_one_lane :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test_first"))
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test_second"))
	_test_stage_call(test, chat, "call_first", `{}`, "test_first")
	_test_stage_call(test, chat, "call_second", `{}`, "test_second")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	testing.expect_value(test, tool_job_test_step(&tool_test, &jobs), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(test, &hold, 1)
	testing.expect_value(test, jobs.jobs[0].phase, Tool_Job_Phase.Running)
	testing.expect_value(test, jobs.jobs[1].phase, Tool_Job_Phase.Queued)
	testing.expect_value(test, jobs.active, 1)

	tool_job_hold_release_all(&hold)
	tool_job_test_drain(test, &tool_test, &jobs)
	testing.expect_value(test, jobs.committed, 2)
	testing.expect_value(test, sync.atomic_load(&hold.running), i32(0))
}

// Two MCP clients are two lanes, so their calls overlap: one stdio stream cannot be
// read by two calls, but two streams can.
@(test)
test_calls_to_different_backends_overlap :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	first_lane := tool_job_hold_lane(&hold)
	second_lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&first_lane, "test_first"))
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&second_lane, "test_second"))
	_test_stage_call(test, chat, "call_first", `{}`, "test_first")
	_test_stage_call(test, chat, "call_second", `{}`, "test_second")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	testing.expect_value(test, tool_job_test_step(&tool_test, &jobs), Tool_Job_Effect.Dispatch)
	testing.expect_value(test, tool_job_test_step(&tool_test, &jobs), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(test, &hold, 1)
	testing.expect_value(test, jobs.active, 2)
	testing.expect_value(test, jobs.jobs[0].phase, Tool_Job_Phase.Running)
	testing.expect_value(test, jobs.jobs[1].phase, Tool_Job_Phase.Running)

	tool_job_hold_release_all(&hold)
	tool_job_test_drain(test, &tool_test, &jobs)
	testing.expect_value(test, jobs.committed, 2)
}

// The worker bound holds: one more eligible call than there are slots stays queued, and
// goes the moment a slot frees.
@(test)
test_running_calls_are_bounded :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	// One lane each, so nothing but the worker bound can hold a call back.
	hold: Tool_Job_Hold_State
	lanes: [TOOL_JOBS_MAX_ACTIVE + 1]Tool_Job_Hold_Lane
	for &lane in lanes { lane = tool_job_hold_lane(&hold) }
	names := [TOOL_JOBS_MAX_ACTIVE + 1]string{"test_one", "test_two", "test_three", "test_four", "test_five"}
	for name, index in names {
		tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lanes[index], name))
		_test_stage_call(test, chat, name, `{}`, name)
	}

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	jobs.max_active = TOOL_JOBS_MAX_ACTIVE
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	for {
		if tool_job_test_step(&tool_test, &jobs) != .Dispatch { break }
		if jobs.active >= TOOL_JOBS_MAX_ACTIVE { break }
	}
	tool_job_test_hold_until(test, &hold, i32(TOOL_JOBS_MAX_ACTIVE))
	testing.expect_value(test, jobs.active, TOOL_JOBS_MAX_ACTIVE)
	testing.expect_value(test, sync.atomic_load(&hold.running), i32(TOOL_JOBS_MAX_ACTIVE))
	queued := 0
	for job in jobs.jobs {
		if job.phase == .Queued { queued += 1 }
	}
	testing.expect_value(test, queued, 1)
	// What is left is a wait, not a dispatch: the bound is real, not a preference.
	testing.expect_value(test, tool_jobs_next(&jobs, time.tick_now()), Tool_Job_Effect.Wait)

	tool_job_hold_release_all(&hold)
	tool_job_test_drain(test, &tool_test, &jobs)
	testing.expect_value(test, jobs.committed, len(names))
}

// A call that ignores its stop is answered as unknown rather than waited for. Its job is
// abandoned: the queued call on the same backend is answered instead of waiting, the batch
// settles, the session accepts the next turn, and the job is reclaimed once its worker returns.
@(test)
test_a_call_that_ignores_its_stop_is_answered_and_abandoned :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test_deaf", tool_job_deaf_execute))
	_test_stage_call(test, chat, "call_deaf", `{}`, "test_deaf")
	_test_stage_call(test, chat, "call_behind", `{}`, "test_deaf")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	// The owner's clock is supplied, so the stop patience passes without waiting it out: the
	// stop is first seen a whole patience ago, and the abandonment's own clock read is past it.
	started := time.tick_add(time.tick_now(), -(TOOL_JOBS_STOP_PATIENCE + time.Millisecond))
	testing.expect_value(test, tool_job_test_step_at(&tool_test, &jobs, started), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(test, &hold, 1)

	// The call's own stop, as its timeout would ask for it: the turn itself keeps running.
	deaf_call := jobs.jobs[0].call.call
	tool_job_request_stop(jobs.jobs[0])
	// The stop is observed at the tick it was asked for, and the call is still running, so
	// there is nothing to do but wait for it.
	testing.expect_value(test, tool_job_test_step_at(&tool_test, &jobs, started), Tool_Job_Effect.Wait)
	testing.expect(test, jobs.jobs[0].worker.stop_at != nil, "the batch should have observed that the call must stop")

	// Past the patience the call is answered with what the harness can say about it.
	late := time.tick_now()
	testing.expect_value(test, tool_job_test_step_at(&tool_test, &jobs, late), Tool_Job_Effect.Abandon)
	testing.expect_value(test, jobs.jobs[0].phase, Tool_Job_Phase.Abandoned)
	testing.expect_value(test, jobs.active, 0)
	_, has_deadline := tool_jobs_deadline(&jobs).?
	testing.expect(test, !has_deadline, "an abandoned call must not remain the batch's deadline")
	// The queued call shares the stuck backend, so it is answered now instead of waiting.
	testing.expect_value(test, tool_job_test_step_at(&tool_test, &jobs, late), Tool_Job_Effect.Refuse)
	testing.expect_value(test, tool_job_test_step_at(&tool_test, &jobs, late), Tool_Job_Effect.Commit)
	testing.expect_value(test, tool_job_test_step_at(&tool_test, &jobs, late), Tool_Job_Effect.Retire)
	testing.expect_value(test, jobs.committed, 2)
	testing.expect(test, tool_jobs_settled(&jobs), "the batch must settle without its abandoned call")
	testing.expect_value(test, tool_job_test_step_at(&tool_test, &jobs, late), Tool_Job_Effect.Done)
	testing.expect_value(test, sync.atomic_load(&hold.running), i32(1))

	results := tool_test_results(test, chat)
	if !testing.expect_value(test, len(results), 2) { return }
	testing.expect_value(test, results[0].outcome, journal.Tool_Outcome.Unknown)
	testing.expect_value(test, results[1].outcome, journal.Tool_Outcome.Unavailable)

	// Releasing the table hands the stuck job to the session, which tracks it.
	tool_jobs_destroy(&jobs)
	testing.expect(test, chat_session_workers_outstanding(chat), "the stuck worker must still be tracked")

	// Once the worker returns, the session reclaims its job.
	tool_job_hold_release_all(&hold)
	for _ in 0 ..< 10_000 {
		if !chat_session_workers_outstanding(chat) { break }
		time.sleep(time.Millisecond)
	}
	testing.expect(test, !chat_session_workers_outstanding(chat), "a worker that returned must be reclaimed")

	// Giving up on the worker and releasing it late are both recorded, under the call they
	// concern and not the queued call that only waited behind it.
	_test_commit(test, chat)
	records := _test_records(test, chat, {.Job_Abandoned, .Job_Reclaimed})
	if !testing.expect_value(test, len(records), 2) { return }
	testing.expect_value(test, records[0].kind, journal.Record_Kind.Job_Abandoned)
	testing.expect_value(test, records[1].kind, journal.Record_Kind.Job_Reclaimed)
	for record in records { testing.expect_value(test, record.call, deaf_call) }
	abandoned: journal.Job_Abandoned
	if decode_error := journal.payload_decode(records[0].data, &abandoned, context.temp_allocator); decode_error != nil {
		testing.fail_now(test, "the abandonment could not be decoded")
	}
	testing.expect_value(test, abandoned.job, journal.JOB_KIND_NAMES[.Tool])
	testing.expect(test, abandoned.waited_ms >= i64(TOOL_JOBS_STOP_PATIENCE / time.Millisecond), "the wait covers the whole patience")
	testing.expect_value(test, abandoned.patience_ms, i64(TOOL_JOBS_STOP_PATIENCE / time.Millisecond))
	reclaimed: journal.Job_Reclaimed
	if decode_error := journal.payload_decode(records[1].data, &reclaimed, context.temp_allocator); decode_error != nil {
		testing.fail_now(test, "the reclaim could not be decoded")
	}
	testing.expect_value(test, reclaimed.job, journal.JOB_KIND_NAMES[.Tool])
}

// A cancelled turn still answers every committed call: the running call is stopped
// through its inherited control, and the queued one is refused without ever dispatching.
@(test)
test_a_stopped_turn_still_answers_every_call :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test_running"))
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test_queued"))
	_test_stage_call(test, chat, "call_running", `{}`, "test_running")
	_test_stage_call(test, chat, "call_queued", `{}`, "test_queued")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	testing.expect_value(test, tool_job_test_step(&tool_test, &jobs), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(test, &hold, 1)

	ai.interrupt_request(&chat.stop)
	tool_jobs_latch_stop(&jobs, chat)
	testing.expect_value(test, jobs.stop, Tool_Jobs_Stop.Cancelled)
	// The running call answers its stop on its own thread, and a result it published
	// first is settled before the refusal, so either order is correct.
	effect := tool_job_test_step(&tool_test, &jobs)
	if effect == .Commit { effect = tool_job_test_step(&tool_test, &jobs) }
	testing.expect_value(test, effect, Tool_Job_Effect.Refuse)
	testing.expect_value(test, jobs.jobs[1].phase, Tool_Job_Phase.Result_Ready)

	tool_job_test_drain(test, &tool_test, &jobs)
	testing.expect_value(test, jobs.committed, 2)
	testing.expect_value(test, sync.atomic_load(&hold.running), i32(0))

	results := tool_test_results(test, chat)
	if !testing.expect_value(test, len(results), 2) { return }
	testing.expect_value(test, results[0].outcome, journal.Tool_Outcome.Cancelled)
	testing.expect_value(test, results[1].outcome, journal.Tool_Outcome.Not_Executed)
}

// An owner-placed control operation needs no worker slot: it completes while every
// slot is taken by a call that is still running.
@(test)
test_an_owner_placed_call_takes_no_worker_slot :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	lanes: [TOOL_JOBS_MAX_ACTIVE]Tool_Job_Hold_Lane
	for &lane in lanes { lane = tool_job_hold_lane(&hold) }
	names := [TOOL_JOBS_MAX_ACTIVE]string{"test_one", "test_two", "test_three", "test_four"}
	for name, index in names {
		tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lanes[index], name))
		_test_stage_call(test, chat, name, `{}`, name)
	}
	control_lane := tool_job_hold_lane(&hold)
	owner_tool := tool_job_hold_definition(&control_lane, "test_control", tool_job_immediate_execute)
	owner_tool.placement = .Owner
	tool_job_test_register(test, &tool_test, owner_tool)
	_test_stage_call(test, chat, "call_control", `{}`, "test_control")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	jobs.max_active = TOOL_JOBS_MAX_ACTIVE
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	for jobs.active < TOOL_JOBS_MAX_ACTIVE {
		if tool_job_test_step(&tool_test, &jobs) != .Dispatch { break }
	}
	tool_job_test_hold_until(test, &hold, i32(TOOL_JOBS_MAX_ACTIVE))
	testing.expect_value(test, jobs.active, TOOL_JOBS_MAX_ACTIVE)
	control := jobs.jobs[TOOL_JOBS_MAX_ACTIVE]
	testing.expect_value(test, control.placement, Tool_Placement.Owner)
	testing.expect_value(test, control.phase, Tool_Job_Phase.Queued)
	// It runs to a result while the four workers are still inside their executors.
	testing.expect_value(test, tool_job_test_step(&tool_test, &jobs), Tool_Job_Effect.Dispatch)
	testing.expect_value(test, control.phase, Tool_Job_Phase.Result_Ready)
	testing.expect_value(test, jobs.active, TOOL_JOBS_MAX_ACTIVE)

	tool_job_hold_release_all(&hold)
	tool_job_test_drain(test, &tool_test, &jobs)
	testing.expect_value(test, jobs.committed, len(names) + 1)
}

// Release is complete: every worker has finished, every job-owned byte comes back to the
// allocator that handed it out, and the recorded results survive in the store. A finished
// worker is observed through the job it published, and the owner takes that worker's thread
// storage back in the same step; a call that ignores its stop never publishes, so its handle
// stays with the job until the process exits.
@(test)
test_a_settled_batch_releases_every_thread_and_byte :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat

	// The tracking allocator stands in for the process heap a worker allocates from,
	// so the test can hold the batch to releasing everything it took.
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)

	hold: Tool_Job_Hold_State
	first_lane := tool_job_hold_lane(&hold)
	second_lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&first_lane, "test_first"))
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&second_lane, "test_second"))
	_test_stage_call(test, chat, "call_first", `{"path":"a"}`, "test_first")
	_test_stage_call(test, chat, "call_second", `{"path":"b"}`, "test_second")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), mem.tracking_allocator(&tracker))
	tool_jobs_submit(&jobs, chat, {})
	tool_job_hold_release_all(&hold)
	tool_job_test_drain(test, &tool_test, &jobs)
	testing.expect_value(test, jobs.committed, 2)

	for job in jobs.jobs {
		testing.expect_value(test, job.phase, Tool_Job_Phase.Retired)
		testing.expect(test, !job.result_present, "the result must be released with the job")
	}
	testing.expect_value(test, jobs.active, 0)

	tool_jobs_destroy(&jobs)
	testing.expect_value(test, len(tracker.allocation_map), 0)
}

// The chat state machine owns the table and exposes one bounded effect at a time. Two
// advances before an effect is performed select the same effect and do not admit or
// launch anything twice.
@(test)
test_chat_advance_drives_session_owned_tool_jobs :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test_owned"))
	_test_stage_call(test, chat, "call_owned", `{}`, "test_owned")

	first := chat_session_advance(chat)
	second := chat_session_advance(chat)
	testing.expect_value(test, first.kind, Chat_Effect_Kind.Run_Tools)
	testing.expect_value(test, second.kind, Chat_Effect_Kind.Run_Tools)
	testing.expect(test, !chat.tool_jobs_active, "advance must not perform its own effect")

	chat_tool_jobs_begin(chat, {})
	testing.expect(test, chat.tool_jobs_active, "the submitted table belongs to the session")
	testing.expect_value(test, len(chat.tool_jobs.jobs), 1)

	dispatch := chat_session_advance(chat)
	testing.expect_value(test, dispatch.kind, Chat_Effect_Kind.Step_Tools)
	testing.expect_value(test, dispatch.tool, Tool_Job_Effect.Dispatch)
	chat_tool_jobs_step(chat, {}, dispatch.tool)
	tool_job_test_hold_until(test, &hold, 1)

	wait := chat_session_advance(chat)
	testing.expect_value(test, wait.kind, Chat_Effect_Kind.Wait_Tools)

	tool_job_hold_release_all(&hold)
	for _ in 0 ..< 100_000 {
		chat_session_observe_at(chat, time.tick_now())
		effect := chat_session_advance(chat)
		switch effect.kind {
		case .Step_Tools:
			chat_tool_jobs_step(chat, {}, effect.tool)
		case .Wait_Tools:
			chat_tool_jobs_wait(chat, owner_wake_seen())
		case .Finish_Tools:
			turn_id := effect.turn_id
			testing.expect(test, chat_tool_jobs_finish(chat, turn_id), "the settled batch should close")
			testing.expect(test, !chat.tool_jobs_active, "finishing releases the session table")
			testing.expect_value(test, chat.state, Chat_State.Preparing)
			return
		case .None, .Start_Request, .Send_Attempt, .Await_Provider, .Wait_Retry, .Repair_Context, .Commit_Response, .Run_Tools, .Turn_Finished:
			testing.fail_now(test, "the chat selected an invalid tool effect")
		}
	}
	testing.expect(test, false, "the session-owned batch never settled")
}

// Selection is a read. A worker's published result is not adopted by asking the state
// machine what to do next; the driver's observation step is what brings it in, and only
// then does the selection propose the commit.
@(test)
test_advance_does_not_adopt_a_published_result :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test_observe"))
	_test_stage_call(test, chat, "call_observe", `{}`, "test_observe")
	chat_tool_jobs_begin(chat, {})

	dispatch := chat_session_advance(chat)
	chat_tool_jobs_step(chat, {}, dispatch.tool)
	tool_job_test_hold_until(test, &hold, 1)

	tool_job_hold_release_all(&hold)
	for !job_published(&chat.tool_jobs.jobs[0].worker) {  }

	// The result exists in the job but has not been observed, so selection still proposes
	// a wait and the phase is untouched.
	wait := chat_session_advance(chat)
	testing.expect_value(test, wait.kind, Chat_Effect_Kind.Wait_Tools)
	testing.expect_value(test, chat.tool_jobs.jobs[0].phase, Tool_Job_Phase.Running)

	// Observing adopts it, and the next selection is the commit.
	chat_session_observe_at(chat, time.tick_now())
	commit := chat_session_advance(chat)
	testing.expect_value(test, commit.kind, Chat_Effect_Kind.Step_Tools)
	testing.expect_value(test, commit.tool, Tool_Job_Effect.Commit)
}

// Cancellation does not skip the job table. The cancelling state keeps selecting job
// effects until every committed call has a result and every producer has retired.
@(test)
test_cancelling_chat_drains_session_owned_jobs :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)
	chat := &tool_test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(test, &tool_test, tool_job_hold_definition(&lane, "test_cancel"))
	_test_stage_call(test, chat, "call_cancel", `{}`, "test_cancel")
	chat_tool_jobs_begin(chat, {})

	dispatch := chat_session_advance(chat)
	chat_tool_jobs_step(chat, {}, dispatch.tool)
	tool_job_test_hold_until(test, &hold, 1)

	chat_session_request_cancel(chat)
	testing.expect_value(test, chat.state, Chat_State.Cancelling)

	for _ in 0 ..< 100_000 {
		chat_session_observe_at(chat, time.tick_now())
		effect := chat_session_advance(chat)
		switch effect.kind {
		case .Step_Tools:
			chat_tool_jobs_step(chat, {}, effect.tool)
		case .Wait_Tools:
			chat_tool_jobs_wait(chat, owner_wake_seen())
		case .Finish_Tools:
			turn_id := effect.turn_id
			testing.expect(test, chat_tool_jobs_finish(chat, turn_id), "the cancelled batch should close")
			testing.expect_value(test, chat.state, Chat_State.Cancelling)
			testing.expect_value(test, chat.calls_made, 1)
			return
		case .None, .Start_Request, .Send_Attempt, .Await_Provider, .Wait_Retry, .Repair_Context, .Commit_Response, .Run_Tools, .Turn_Finished:
			testing.fail_now(test, "cancellation skipped the tool drain")
		}
	}
	testing.expect(test, false, "the cancelled session-owned batch never settled")
}
