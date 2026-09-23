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
import "core:time"

import "nabla:agent/session"
import "nabla:db"

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
	running:  i32,
	// thread is the thread the last held call ran on, which is how a test
	// says the call left the owner.
	thread:   i64,
	release:  i32,
	returned: i32,
}

// Tool_Job_Hold_Lane is the borrowed backend identity a held definition is
// registered with. Distinct addresses are distinct lanes; definitions sharing
// one address run one at a time. The lane carries its test's state, so the
// executor reaches per-test counters through ctx.backend.
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
tool_job_hold_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	state := tool_job_hold_state(cast(^Tool_Job_Hold_Lane)ctx.backend)
	sync.atomic_add(&state.running, 1)
	defer sync.atomic_add(&state.running, -1)
	sync.atomic_store(&state.thread, i64(linux.gettid()))
	for !tool_job_hold_released(state) {
		if tool_control_cancelled(ctx.control) {
			return tool_result_failure(ctx, .Cancelled, "the call was stopped", "cancelled")
		}
		time.sleep(time.Millisecond)
	}
	return tool_result_success(ctx, Tool_Empty{}, "held")
}

// tool_job_immediate_execute finishes at once, which is what an owner-placed control
// operation does.
tool_job_immediate_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	return tool_result_success(ctx, Tool_Empty{}, "immediate")
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
	}
}

tool_job_test_register :: proc(t: ^testing.T, test: ^Tool_Test, definition: Tool_Definition) {
	added := tool_registry_add(&test.fixture.chat.tools, definition)
	if added.kind != .None { testing.fail_now(t, "the test tool was not registered") }
}

// --- driving -------------------------------------------------------------------

// tool_job_test_step performs exactly one effect and reports which one it was, so a
// test can assert the decision before its consequence exists.
tool_job_test_step :: proc(test: ^Tool_Test, jobs: ^Tool_Jobs) -> Tool_Job_Effect {
	return tool_job_test_step_at(test, jobs, time.tick_now())
}

// tool_job_test_step_at is the same step with the owner's clock supplied, so a test can
// reach the stop patience without waiting it out.
tool_job_test_step_at :: proc(test: ^Tool_Test, jobs: ^Tool_Jobs, now: time.Tick) -> Tool_Job_Effect {
	chat := &test.fixture.chat
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
		tool_jobs_retire(jobs, now)
	case .Dispatch:
		tool_jobs_dispatch(jobs, chat)
	case .Wait:
		// A stepped test advances its own clock, so the wait is bounded by the real one: what
		// it is waiting for is a worker's publication, not a deadline its own simulation has
		// already moved past.
		tool_jobs_await(jobs, time.tick_add(time.tick_now(), time.Millisecond))
	case .Done:
	}
	return effect
}

// tool_job_test_drain drives the batch to done the way the real driver does, latching
// any stop the session recorded first. The step cap turns a stuck job into a failure
// instead of a hang.
tool_job_test_drain :: proc(t: ^testing.T, test: ^Tool_Test, jobs: ^Tool_Jobs) {
	chat := &test.fixture.chat
	for _ in 0 ..< 100_000 {
		tool_jobs_latch_stop(jobs, chat)
		if tool_job_test_step(test, jobs) == .Done { return }
	}
	testing.fail_now(t, "the batch never settled")
}

// --- a call that ignores its stop ----------------------------------------------

// A deaf tool never looks at its control: it keeps working until the test releases it,
// which is what a backend stuck in a syscall looks like to the owner. It reports
// through its lane's per-test state like a held tool does.
tool_job_deaf_release_all :: proc(state: ^Tool_Job_Hold_State) {
	tool_job_hold_release_all(state)
}

tool_job_deaf_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	state := tool_job_hold_state(cast(^Tool_Job_Hold_Lane)ctx.backend)
	sync.atomic_add(&state.running, 1)
	for sync.atomic_load(&state.release) == 0 {
		time.sleep(time.Millisecond)
	}
	sync.atomic_add(&state.running, -1)
	sync.atomic_store(&state.returned, i32(1))
	return tool_result_success(ctx, Tool_Empty{}, "late")
}

// tool_job_test_hold_until waits for count held executions to be inside the executor,
// so a test observes running jobs rather than a scheduling guess. The wait is
// bounded: a job that never started (a failed launch, a stop before dispatch)
// must fail the test, never hang it.
tool_job_test_hold_until :: proc(t: ^testing.T, state: ^Tool_Job_Hold_State, count: i32) {
	for _ in 0 ..< 10_000 {
		if sync.atomic_load(&state.running) >= count { return }
		time.sleep(time.Millisecond)
	}
	// Release before failing, so a worker still inside the executor leaves
	// instead of spinning on a test that is already gone.
	sync.atomic_store(&state.release, 1)
	testing.fail_now(t, "the held calls never started")
}

// tool_job_test_returned_until waits for a deaf execution to come back after
// its release, so teardown observes the worker it handed the job to. Bounded
// like the hold wait above.
tool_job_test_returned_until :: proc(t: ^testing.T, state: ^Tool_Job_Hold_State) {
	for _ in 0 ..< 10_000 {
		if sync.atomic_load(&state.returned) != 0 { return }
		time.sleep(time.Millisecond)
	}
	testing.fail_now(t, "the released call never returned")
}

// --- tests ---------------------------------------------------------------------

@(test)
test_code_mode_suspends_for_a_nested_tool_job :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(t, &test, tool_job_hold_definition(&lane, "test_child", tool_job_immediate_execute))
	_test_stage_call(
		t,
		chat,
		"call_code",
		`{"code":"local first = tools.test_child({value = 7})\nlocal second = tools.test_child({value = 8})\nreturn first.status .. \"+\" .. second.status"}`,
		TOOL_CODE_NAME,
	)

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})
	tool_job_test_drain(t, &test, &jobs)

	testing.expect_value(t, len(jobs.jobs), 3)
	parent := jobs.jobs[0]
	first_child := jobs.jobs[1]
	second_child := jobs.jobs[2]
	testing.expect_value(t, parent.phase, Tool_Job_Phase.Retired)
	testing.expect_value(t, first_child.phase, Tool_Job_Phase.Retired)
	testing.expect_value(t, second_child.phase, Tool_Job_Phase.Retired)
	testing.expect(t, first_child.parent == parent, "the first nested call should belong to the Code Mode job")
	testing.expect(t, second_child.parent == parent, "the second nested call should belong to the Code Mode job")
	testing.expect(t, first_child.nested && second_child.nested, "nested calls should own their staged records")
	value, present := code_mode_lua_returned_string(parent.lua)
	testing.expect(t, present, "the script should return the child envelope statuses")
	testing.expect_value(t, value, "success+success")
	testing.expect_value(t, jobs.committed, 3)
	testing.expect_value(t, tool_jobs_committed(&jobs), 1)
}

// A nested child that cannot be recorded is released with the allocator that owns
// worker job storage, not the session allocator that owns the table.
@(test)
test_nested_tool_storage_failure_frees_with_worker_allocator :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat

	if exec_err := db.exec(&test.fixture.store.conn, "PRAGMA query_only = ON"); exec_err != nil {
		testing.fail_now(t, "the store could not be made read-only")
	}

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
	defer tool_jobs_destroy(&jobs)

	run, compiled := code_mode_lua_start(context.allocator, lua_limits_default(), `return tools.test({})`)
	if run == nil { testing.fail_now(t, "the Lua run could not be created") }
	defer code_mode_lua_destroy(run)
	if !compiled { testing.fail_now(t, "the Lua test chunk did not compile") }
	if !code_mode_lua_install_tool(run, "test") { testing.fail_now(t, "the Lua tool could not be installed") }
	if !testing.expect_value(t, code_mode_lua_resume(run), Lua_Event.Host_Request) { return }

	call := Chat_Tool_Call {
		seq = 1,
	}
	parent := Tool_Job {
		table     = &jobs,
		placement = .Lua,
		allocator = context.allocator,
		call_id   = chat_clone_string("parent", context.allocator),
		lua       = run,
		call      = &call,
		turn_id   = chat.active_turn_id,
	}
	parent.exec = Tool_Context {
		call_id   = parent.call_id,
		allocator = parent.allocator,
	}
	defer delete(parent.call_id, parent.allocator)
	defer if parent.result_present { tool_result_destroy(&parent.result) }

	tool_job_lua_submit_child(&jobs, chat, &parent)

	testing.expect_value(t, parent.phase, Tool_Job_Phase.Result_Ready)
	testing.expect_value(t, len(jobs.jobs), 0)
	testing.expect(t, chat_session_storage_failed(chat), "the refused child record latches storage failure")
	testing.expect_value(t, len(worker_track.allocation_map), 0)
	testing.expect_value(t, len(session_track.bad_free_array), 0)
}

// A stopped execution says which limit stopped it, so the failure is branchable rather
// than prose. The outcome stays what the harness observed; the kind names the fault.
@(test)
test_code_mode_reports_which_limit_stopped_it :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	_test_stage_call(t, chat, "call_code", `{"code":"while true do end"}`, TOOL_CODE_NAME)

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})
	tool_job_test_drain(t, &test, &jobs)

	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	recorded := false
	for entry in entries {
		result, is_result := entry.payload.(session.Tool_Result_Entry)
		if !is_result { continue }
		recorded = true
		testing.expect_value(t, result.outcome, session.Tool_Outcome.Tool_Failed)
		testing.expect(t, strings.contains(result.content, `"kind":"instruction_limit"`), result.content)
	}
	testing.expect(t, recorded, "a stopped execution still answers its call")
}

// A script whose point is to loop over many things must not run out of room at the size
// of one model response: the batch's admission budget counts outer calls and children
// together, and the table keeps released jobs, so the budget rather than the table size
// is what bounds a long script.
@(test)
test_code_mode_may_exceed_one_response_worth_of_calls :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(t, &test, tool_job_hold_definition(&lane, "test_step", tool_job_immediate_execute))
	// The script makes more calls than one model response could commit.
	source := fmt.aprintf(
		`local seen = 0 for i = 1, %d do local r = tools.test_step() if r.status == "success" then seen = seen + 1 end end return seen`,
		TOOL_JOBS_MAX + 8,
		allocator = context.temp_allocator,
	)
	object := make(json.Object, 1, context.temp_allocator)
	object["code"] = json.String(source)
	arguments, marshal_err := json.marshal(object, allocator = context.temp_allocator)
	if marshal_err != nil { testing.fail_now(t, "the arguments could not be built") }
	_test_stage_call(t, chat, "call_code", string(arguments), TOOL_CODE_NAME)

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})
	tool_job_test_drain(t, &test, &jobs)

	testing.expect_value(t, jobs.admitted, TOOL_JOBS_MAX + 9)
	testing.expect_value(t, tool_jobs_committed(&jobs), 1)

	// The parent's answer is what the script computed from every child it ran, which is
	// only possible if the table kept admitting after one response's worth of calls.
	// A result is linked to its call by related_seq, so the parent's answer is found by
	// following that link rather than by guessing which result came first. The load
	// raises the row limit, because one script's children fill a default page.
	entries, load_error := session.entries_load(chat.store, chat.id, {limit = session.ENTRIES_MAX_LIMIT}, context.allocator)
	if load_error != nil { testing.fail_now(t, "entries_load failed") }
	defer session.entries_destroy(entries, context.allocator)
	parent_seq: session.Seq
	for entry in entries {
		call, is_call := entry.payload.(session.Tool_Call_Entry)
		if is_call && call.call_id == "call_code" { parent_seq = entry.seq }
	}
	if !testing.expect(t, parent_seq != 0, "the parent call should be recorded") { return }

	found := false
	for entry in entries {
		result, is_result := entry.payload.(session.Tool_Result_Entry)
		if !is_result { continue }
		related, present := entry.related_seq.?
		if !present || related != parent_seq { continue }
		found = true
		testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
		testing.expect(t, strings.contains(result.content, fmt.tprintf(`"output":%d`, TOOL_JOBS_MAX + 8)), result.content)
	}
	testing.expect(t, found, "the script should have answered its call")
}

// A script's result says what the script did. The summaries are what make a child's full
// result reachable: the model reads it back from call_seq with context_read_result, so a
// script that ran a hundred calls does not put a hundred results into the conversation.
@(test)
test_code_mode_reports_what_its_script_did :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(t, &test, tool_job_hold_definition(&lane, "test_child", tool_job_immediate_execute))
	_test_stage_call(t, chat, "call_code", `{"code":"local a = tools.test_child()\nlocal b = tools.test_child()\nreturn \"done\""}`, TOOL_CODE_NAME)

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})
	tool_job_test_drain(t, &test, &jobs)

	entries, load_error := session.entries_load(chat.store, chat.id, {limit = session.ENTRIES_MAX_LIMIT}, context.allocator)
	if load_error != nil { testing.fail_now(t, "entries_load failed") }
	defer session.entries_destroy(entries, context.allocator)

	// Every child call the script made, by the sequence a reader would name it by.
	child_seqs := make([dynamic]session.Seq, 0, 4, context.temp_allocator)
	parent_seq: session.Seq
	for entry in entries {
		call, is_call := entry.payload.(session.Tool_Call_Entry)
		if !is_call { continue }
		if call.call_id == "call_code" { parent_seq = entry.seq; continue }
		append(&child_seqs, entry.seq)
	}
	if !testing.expect_value(t, len(child_seqs), 2) { return }

	content := ""
	for entry in entries {
		result, is_result := entry.payload.(session.Tool_Result_Entry)
		if !is_result { continue }
		related, present := entry.related_seq.?
		if present && related == parent_seq { content = result.content }
	}
	if !testing.expect(t, content != "", "the parent should have recorded its result") { return }

	testing.expect(t, strings.contains(content, `"calls_total":2`), content)
	for seq in child_seqs {
		want := strings.concatenate({`{"call_seq":`, fmt.tprintf("%d", seq), `,"name":"test_child","outcome":"success"}`}, context.temp_allocator)
		testing.expectf(t, strings.contains(content, want), "%s should carry %s", content, want)
	}

	// The whole point of naming the sequence: a child's full result is reachable by it,
	// so a script can return a small answer and the model can still read back the one
	// result it wants.
	reader := Result_Reader {
		store      = chat.store,
		session_id = chat.id,
	}
	reader_ctx := Tool_Context {
		call_id   = "call_read",
		allocator = context.allocator,
		results   = &reader,
	}
	read_arguments := make(json.Object, context.temp_allocator)
	defer delete(read_arguments)
	read_arguments["call_seq"] = json.Integer(child_seqs[0])
	page := tool_result_read_execute(&reader_ctx, read_arguments)
	defer tool_result_destroy(&page)
	testing.expect_value(t, page.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(page.content, `"status":"success"`), page.content)
}

// A worker-placed call runs on its own thread: the test thread keeps going while the
// call is still inside the executor, and the batch is not advanced by the completion.
@(test)
test_a_worker_placed_call_runs_on_another_thread :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(t, &test, tool_job_hold_definition(&lane, "test_hold"))
	_test_stage_call(t, chat, "call_hold", `{}`, "test_hold")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(t, &hold, 1)
	testing.expect(t, tool_job_hold_thread_id(&hold) != i64(linux.gettid()), "the call must not run on the owner's thread")
	testing.expect_value(t, jobs.jobs[0].phase, Tool_Job_Phase.Running)
	// The only thing left to do is wait: the call owns the lane and the owner.
	testing.expect_value(t, tool_jobs_next(&jobs, time.tick_now()), Tool_Job_Effect.Wait)

	tool_job_hold_release_all(&hold)
	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, 1)
	testing.expect_value(t, jobs.jobs[0].phase, Tool_Job_Phase.Retired)
}

// Native tools share one lane, so a second call waits for the first even though a
// worker slot is free.
@(test)
test_native_calls_share_one_lane :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(t, &test, tool_job_hold_definition(&lane, "test_first"))
	tool_job_test_register(t, &test, tool_job_hold_definition(&lane, "test_second"))
	_test_stage_call(t, chat, "call_first", `{}`, "test_first")
	_test_stage_call(t, chat, "call_second", `{}`, "test_second")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(t, &hold, 1)
	testing.expect_value(t, jobs.jobs[0].phase, Tool_Job_Phase.Running)
	testing.expect_value(t, jobs.jobs[1].phase, Tool_Job_Phase.Queued)
	testing.expect_value(t, jobs.active, 1)

	tool_job_hold_release_all(&hold)
	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, 2)
	testing.expect_value(t, sync.atomic_load(&hold.running), i32(0))
}

// Two MCP clients are two lanes, so their calls overlap: one stdio stream cannot be
// read by two calls, but two streams can.
@(test)
test_calls_to_different_backends_overlap :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	hold: Tool_Job_Hold_State
	first_lane := tool_job_hold_lane(&hold)
	second_lane := tool_job_hold_lane(&hold)
	tool_job_test_register(t, &test, tool_job_hold_definition(&first_lane, "test_first"))
	tool_job_test_register(t, &test, tool_job_hold_definition(&second_lane, "test_second"))
	_test_stage_call(t, chat, "call_first", `{}`, "test_first")
	_test_stage_call(t, chat, "call_second", `{}`, "test_second")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Dispatch)
	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(t, &hold, 1)
	testing.expect_value(t, jobs.active, 2)
	testing.expect_value(t, jobs.jobs[0].phase, Tool_Job_Phase.Running)
	testing.expect_value(t, jobs.jobs[1].phase, Tool_Job_Phase.Running)

	tool_job_hold_release_all(&hold)
	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, 2)
}

// The worker bound holds: one more eligible call than there are slots stays queued, and
// goes the moment a slot frees.
@(test)
test_running_calls_are_bounded :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	// One lane each, so nothing but the worker bound can hold a call back.
	hold: Tool_Job_Hold_State
	lanes: [TOOL_JOBS_MAX_ACTIVE + 1]Tool_Job_Hold_Lane
	for &lane in lanes { lane = tool_job_hold_lane(&hold) }
	names := [TOOL_JOBS_MAX_ACTIVE + 1]string{"test_one", "test_two", "test_three", "test_four", "test_five"}
	for name, index in names {
		tool_job_test_register(t, &test, tool_job_hold_definition(&lanes[index], name))
		_test_stage_call(t, chat, name, `{}`, name)
	}

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	for {
		if tool_job_test_step(&test, &jobs) != .Dispatch { break }
		if jobs.active >= TOOL_JOBS_MAX_ACTIVE { break }
	}
	tool_job_test_hold_until(t, &hold, i32(TOOL_JOBS_MAX_ACTIVE))
	testing.expect_value(t, jobs.active, TOOL_JOBS_MAX_ACTIVE)
	testing.expect_value(t, sync.atomic_load(&hold.running), i32(TOOL_JOBS_MAX_ACTIVE))
	queued := 0
	for job in jobs.jobs {
		if job.phase == .Queued { queued += 1 }
	}
	testing.expect_value(t, queued, 1)
	// What is left is a wait, not a dispatch: the bound is real, not a preference.
	testing.expect_value(t, tool_jobs_next(&jobs, time.tick_now()), Tool_Job_Effect.Wait)

	tool_job_hold_release_all(&hold)
	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, len(names))
}

// A call that ignores its stop is answered rather than waited for: the turn is not stuck
// behind a backend that will not return, and the call is recorded as the unknown outcome
// the harness actually observed. The job is handed to its worker, which releases every byte
// of it when it returns, so a backend that ignored cancellation leaves no leak behind but
// its thread: the owner keeps the thread handle, and a worker that never returns is a thread
// storage the process holds until it exits, which is the same rule as the memory the worker
// can still reach.
@(test)
test_a_call_that_ignores_its_stop_is_answered_and_released :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(t, &test, tool_job_hold_definition(&lane, "test_deaf", tool_job_deaf_execute))
	_test_stage_call(t, chat, "call_deaf", `{}`, "test_deaf")

	// The batch's own heap is tracked, so the test can hold the worker to releasing the job
	// it took over.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), mem.tracking_allocator(&track))
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	// The owner's clock is supplied, so the stop patience passes without waiting it out.
	started := time.tick_now()
	testing.expect_value(t, tool_job_test_step_at(&test, &jobs, started), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(t, &hold, 1)

	chat_cancel_request()
	defer chat_cancel_reset()
	tool_jobs_latch_stop(&jobs, chat)
	// The stop is observed at the tick it was asked for, and the call is still running, so
	// there is nothing to do but wait for it.
	testing.expect_value(t, tool_job_test_step_at(&test, &jobs, started), Tool_Job_Effect.Wait)
	testing.expect(t, jobs.jobs[0].stopping, "the batch should have observed that the call must stop")

	// Past the patience the call is answered with what the harness can say about it.
	late := time.tick_add(started, TOOL_JOBS_STOP_PATIENCE + time.Millisecond)
	testing.expect_value(t, tool_job_test_step_at(&test, &jobs, late), Tool_Job_Effect.Abandon)
	testing.expect_value(t, jobs.jobs[0].phase, Tool_Job_Phase.Stuck)
	testing.expect(t, jobs.escaped, "handing a job to its worker must latch the batch")
	// A job the owner gave up on is the worker's now, so it is not a tick the owner can wait
	// for: keeping its spent patience would make the wait beside a live call a spin.
	_, has_deadline := tool_jobs_deadline(&jobs).?
	testing.expect(t, !has_deadline, "a call handed to its worker must not remain the batch's deadline")
	testing.expect_value(t, jobs.committed, 1)
	testing.expect(t, tool_jobs_settled(&jobs), "the batch must settle without its stuck call")
	testing.expect_value(t, tool_job_test_step_at(&test, &jobs, late), Tool_Job_Effect.Done)
	testing.expect_value(t, sync.atomic_load(&hold.running), i32(1))

	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	results: [dynamic]session.Tool_Result_Entry
	defer delete(results)
	for entry in entries {
		if result, is_result := entry.payload.(session.Tool_Result_Entry); is_result { append(&results, result) }
	}
	if !testing.expect_value(t, len(results), 1) { return }
	testing.expect_value(t, results[0].outcome, session.Tool_Outcome.Unknown)

	// The worker still owns the job, and it releases it on its way out.
	tool_job_deaf_release_all(&hold)
	tool_job_test_returned_until(t, &hold)
	for _ in 0 ..< 10_000 {
		sync.mutex_guard(&track.mutex)
		if len(track.allocation_map) == 0 { break }
		time.sleep(time.Millisecond)
	}
	sync.mutex_guard(&track.mutex)
	if !testing.expectf(t, len(track.allocation_map) == 0, "the handed-back job leaked %d allocation(s)", len(track.allocation_map)) {
		for _, leak in track.allocation_map { testing.expectf(t, false, "leaked %v bytes at %v", leak.size, leak.location) }
	}
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// A cancelled turn still answers every committed call: the running call is stopped
// through its inherited control, and the queued one is refused without ever dispatching.
@(test)
test_a_stopped_turn_still_answers_every_call :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(t, &test, tool_job_hold_definition(&lane, "test_running"))
	tool_job_test_register(t, &test, tool_job_hold_definition(&lane, "test_queued"))
	_test_stage_call(t, chat, "call_running", `{}`, "test_running")
	_test_stage_call(t, chat, "call_queued", `{}`, "test_queued")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(t, &hold, 1)

	chat_cancel_request()
	defer chat_cancel_reset()
	tool_jobs_latch_stop(&jobs, chat)
	testing.expect_value(t, jobs.stop, Tool_Jobs_Stop.Cancelled)
	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Refuse)
	testing.expect_value(t, jobs.jobs[1].phase, Tool_Job_Phase.Result_Ready)

	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, 2)
	testing.expect_value(t, sync.atomic_load(&hold.running), i32(0))

	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	results: [dynamic]session.Tool_Result_Entry
	defer delete(results)
	for entry in entries {
		if result, is_result := entry.payload.(session.Tool_Result_Entry); is_result { append(&results, result) }
	}
	if !testing.expect_value(t, len(results), 2) { return }
	testing.expect_value(t, results[0].outcome, session.Tool_Outcome.Cancelled)
	testing.expect_value(t, results[1].outcome, session.Tool_Outcome.Not_Executed)
}

// An owner-placed control operation needs no worker slot: it completes while every
// slot is taken by a call that is still running.
@(test)
test_an_owner_placed_call_takes_no_worker_slot :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	hold: Tool_Job_Hold_State
	lanes: [TOOL_JOBS_MAX_ACTIVE]Tool_Job_Hold_Lane
	for &lane in lanes { lane = tool_job_hold_lane(&hold) }
	names := [TOOL_JOBS_MAX_ACTIVE]string{"test_one", "test_two", "test_three", "test_four"}
	for name, index in names {
		tool_job_test_register(t, &test, tool_job_hold_definition(&lanes[index], name))
		_test_stage_call(t, chat, name, `{}`, name)
	}
	control_lane := tool_job_hold_lane(&hold)
	owner_tool := tool_job_hold_definition(&control_lane, "test_control", tool_job_immediate_execute)
	owner_tool.placement = .Owner
	tool_job_test_register(t, &test, owner_tool)
	_test_stage_call(t, chat, "call_control", `{}`, "test_control")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	for jobs.active < TOOL_JOBS_MAX_ACTIVE {
		if tool_job_test_step(&test, &jobs) != .Dispatch { break }
	}
	tool_job_test_hold_until(t, &hold, i32(TOOL_JOBS_MAX_ACTIVE))
	testing.expect_value(t, jobs.active, TOOL_JOBS_MAX_ACTIVE)
	control := jobs.jobs[TOOL_JOBS_MAX_ACTIVE]
	testing.expect_value(t, control.placement, Tool_Placement.Owner)
	testing.expect_value(t, control.phase, Tool_Job_Phase.Queued)
	// It runs to a result while the four workers are still inside their executors.
	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Dispatch)
	testing.expect_value(t, control.phase, Tool_Job_Phase.Result_Ready)
	testing.expect_value(t, jobs.active, TOOL_JOBS_MAX_ACTIVE)

	tool_job_hold_release_all(&hold)
	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, len(names) + 1)
}

// Release is complete: every worker has finished, every job-owned byte comes back to the
// allocator that handed it out, and the recorded results survive in the store. A finished
// worker is observed through the job it published, and the owner takes that worker's thread
// storage back in the same step; a call that ignores its stop never publishes, so its handle
// stays with the job until the process exits.
@(test)
test_a_settled_batch_releases_every_thread_and_byte :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat

	// The tracking allocator stands in for the process heap a worker allocates from,
	// so the test can hold the batch to releasing everything it took.
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)

	hold: Tool_Job_Hold_State
	first_lane := tool_job_hold_lane(&hold)
	second_lane := tool_job_hold_lane(&hold)
	tool_job_test_register(t, &test, tool_job_hold_definition(&first_lane, "test_first"))
	tool_job_test_register(t, &test, tool_job_hold_definition(&second_lane, "test_second"))
	_test_stage_call(t, chat, "call_first", `{"path":"a"}`, "test_first")
	_test_stage_call(t, chat, "call_second", `{"path":"b"}`, "test_second")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), mem.tracking_allocator(&tracker))
	tool_jobs_submit(&jobs, chat, {})
	tool_job_hold_release_all(&hold)
	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, 2)

	for job in jobs.jobs {
		testing.expect_value(t, job.phase, Tool_Job_Phase.Retired)
		testing.expect(t, !job.result_present, "the result must be released with the job")
	}
	testing.expect_value(t, jobs.active, 0)

	tool_jobs_destroy(&jobs)
	testing.expect_value(t, len(tracker.allocation_map), 0)
}

// The chat state machine owns the table and exposes one bounded effect at a time. Two
// advances before an effect is performed select the same effect and do not admit or
// launch anything twice.
@(test)
test_chat_advance_drives_session_owned_tool_jobs :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(t, &test, tool_job_hold_definition(&lane, "test_owned"))
	_test_stage_call(t, chat, "call_owned", `{}`, "test_owned")

	first := chat_session_advance(chat)
	second := chat_session_advance(chat)
	testing.expect_value(t, first.kind, Chat_Effect_Kind.Run_Tools)
	testing.expect_value(t, second.kind, Chat_Effect_Kind.Run_Tools)
	testing.expect(t, !chat.tool_jobs_active, "advance must not perform its own effect")

	chat_tool_jobs_begin(chat, {})
	testing.expect(t, chat.tool_jobs_active, "the submitted table belongs to the session")
	testing.expect_value(t, len(chat.tool_jobs.jobs), 1)

	dispatch := chat_session_advance(chat)
	testing.expect_value(t, dispatch.kind, Chat_Effect_Kind.Step_Tools)
	testing.expect_value(t, dispatch.tool, Tool_Job_Effect.Dispatch)
	chat_tool_jobs_step(chat, {}, dispatch.tool)
	tool_job_test_hold_until(t, &hold, 1)

	wait := chat_session_advance(chat)
	testing.expect_value(t, wait.kind, Chat_Effect_Kind.Wait_Tools)

	tool_job_hold_release_all(&hold)
	for _ in 0 ..< 100_000 {
		chat_session_observe(chat)
		effect := chat_session_advance(chat)
		switch effect.kind {
		case .Step_Tools:
			chat_tool_jobs_step(chat, {}, effect.tool)
		case .Wait_Tools:
			chat_tool_jobs_wait(chat)
		case .Finish_Tools:
			turn_id := effect.turn_id
			testing.expect(t, chat_tool_jobs_finish(chat, turn_id), "the settled batch should close")
			testing.expect(t, !chat.tool_jobs_active, "finishing releases the session table")
			testing.expect_value(t, chat.state, Chat_State.Preparing)
			return
		case .None, .Start_Request, .Send_Attempt, .Await_Provider, .Wait_Retry, .Repair_Context, .Commit_Response, .Run_Tools, .Turn_Finished:
			testing.fail_now(t, "the chat selected an invalid tool effect")
		}
	}
	testing.expect(t, false, "the session-owned batch never settled")
}

// Selection is a read. A worker's published result is not adopted by asking the state
// machine what to do next; the driver's observation step is what brings it in, and only
// then does the selection propose the commit.
@(test)
test_advance_does_not_adopt_a_published_result :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(t, &test, tool_job_hold_definition(&lane, "test_observe"))
	_test_stage_call(t, chat, "call_observe", `{}`, "test_observe")
	chat_tool_jobs_begin(chat, {})

	dispatch := chat_session_advance(chat)
	chat_tool_jobs_step(chat, {}, dispatch.tool)
	tool_job_test_hold_until(t, &hold, 1)

	tool_job_hold_release_all(&hold)
	for {
		sync.mutex_guard(&chat.tool_jobs.jobs[0].mu)
		if chat.tool_jobs.jobs[0].published { break }
	}

	// The result exists in the job but has not been observed, so selection still proposes
	// a wait and the phase is untouched.
	wait := chat_session_advance(chat)
	testing.expect_value(t, wait.kind, Chat_Effect_Kind.Wait_Tools)
	testing.expect_value(t, chat.tool_jobs.jobs[0].phase, Tool_Job_Phase.Running)

	// Observing adopts it, and the next selection is the commit.
	chat_session_observe(chat)
	commit := chat_session_advance(chat)
	testing.expect_value(t, commit.kind, Chat_Effect_Kind.Step_Tools)
	testing.expect_value(t, commit.tool, Tool_Job_Effect.Commit)
}

// An escaped worker latches the session. The observation step is what carries the
// batch's escape into the session, and an escaped session admits no further turn, which
// is what keeps the workspace, registry generation, and backends it borrows from being
// released under a worker that is still running.
@(test)
test_an_escaped_worker_refuses_another_turn :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat

	testing.expect(t, !chat_session_worker_escaped(chat))
	tool_jobs_init(&chat.tool_jobs, chat, 0, os.heap_allocator())
	chat.tool_jobs_active = true
	chat.tool_jobs.escaped = true
	chat_session_observe(chat)
	testing.expect(t, chat_session_worker_escaped(chat))

	// The running turn does not ask the model for more work: the batch closes, and the turn
	// ends as a failure because the runtime can no longer be reused.
	chat.state = .Executing_Tools
	testing.expect(t, !chat_session_tools_done(chat, chat.active_turn_id, 0))
	testing.expect_value(t, chat.state, Chat_State.Finalizing)
	finish := chat_session_advance(chat)
	testing.expect_value(t, finish.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Failed)
	chat_session_claim_finish(chat, finish)

	before_entries := _test_entries(t, chat)
	before := len(before_entries)
	session.entries_destroy(before_entries, context.allocator)
	testing.expect_value(t, chat_session_accept_user(chat, "next", session.now_ms()), Chat_Accept.Worker_Escaped)

	// The refused prompt left no record behind.
	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	testing.expect_value(t, len(entries), before)
}

// Cancellation does not skip the job table. The cancelling state keeps selecting job
// effects until every committed call has a result and every producer has retired.
@(test)
test_cancelling_chat_drains_session_owned_jobs :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	hold: Tool_Job_Hold_State
	lane := tool_job_hold_lane(&hold)
	tool_job_test_register(t, &test, tool_job_hold_definition(&lane, "test_cancel"))
	_test_stage_call(t, chat, "call_cancel", `{}`, "test_cancel")
	chat_tool_jobs_begin(chat, {})

	dispatch := chat_session_advance(chat)
	chat_tool_jobs_step(chat, {}, dispatch.tool)
	tool_job_test_hold_until(t, &hold, 1)

	chat_session_request_cancel(chat)
	defer chat_cancel_reset()
	testing.expect_value(t, chat.state, Chat_State.Cancelling)

	for _ in 0 ..< 100_000 {
		chat_session_observe(chat)
		effect := chat_session_advance(chat)
		switch effect.kind {
		case .Step_Tools:
			chat_tool_jobs_step(chat, {}, effect.tool)
		case .Wait_Tools:
			chat_tool_jobs_wait(chat)
		case .Finish_Tools:
			turn_id := effect.turn_id
			testing.expect(t, chat_tool_jobs_finish(chat, turn_id), "the cancelled batch should close")
			testing.expect_value(t, chat.state, Chat_State.Cancelling)
			testing.expect_value(t, chat.calls_made, 1)
			return
		case .None, .Start_Request, .Send_Attempt, .Await_Provider, .Wait_Retry, .Repair_Context, .Commit_Response, .Run_Tools, .Turn_Finished:
			testing.fail_now(t, "cancellation skipped the tool drain")
		}
	}
	testing.expect(t, false, "the cancelled session-owned batch never settled")
}
