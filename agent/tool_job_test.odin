#+test
package agent

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:sync"
import linux "core:sys/linux"
import "core:testing"
import "core:time"

import "nabla:agent/session"

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
// atomically. Tests run serially, so package-level storage is how an executor with a
// fixed signature reports what it observed.
tool_job_hold_running: i32
// tool_job_hold_thread is the thread the last held call ran on, which is how a test
// says the call left the owner.
tool_job_hold_thread: i64
tool_job_hold_release: i32

tool_job_hold_reset :: proc() {
	sync.atomic_store(&tool_job_hold_running, i32(0))
	sync.atomic_store(&tool_job_hold_thread, i64(0))
	sync.atomic_store(&tool_job_hold_release, i32(0))
}

tool_job_hold_thread_id :: proc() -> i64 {
	return sync.atomic_load(&tool_job_hold_thread)
}

tool_job_hold_released :: proc() -> bool {
	return sync.atomic_load(&tool_job_hold_release) != 0
}

tool_job_hold_release_all :: proc() {
	sync.atomic_store(&tool_job_hold_release, i32(1))
}

// tool_job_hold_execute blocks until the test releases it or its own control ends.
tool_job_hold_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	sync.atomic_add(&tool_job_hold_running, 1)
	defer sync.atomic_add(&tool_job_hold_running, -1)
	sync.atomic_store(&tool_job_hold_thread, i64(linux.gettid()))
	for !tool_job_hold_released() {
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
// identity: two definitions sharing one run one at a time, and nil is the lane every
// native tool shares.
tool_job_hold_definition :: proc(name: string, lane: rawptr = nil, execute := tool_job_hold_execute) -> Tool_Definition {
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
	chat := &test.fixture.chat
	effect := tool_jobs_next(jobs)
	switch effect {
	case .Commit:
		tool_jobs_commit(jobs, chat, {})
	case .Refuse:
		tool_jobs_refuse(jobs)
	case .Retire:
		tool_jobs_retire(jobs)
	case .Dispatch:
		tool_jobs_dispatch(jobs, chat)
	case .Wait:
		tool_jobs_wait(jobs, time.Millisecond)
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

// tool_job_test_hold_until waits for count held executions to be inside the executor,
// so a test observes running jobs rather than a scheduling guess.
tool_job_test_hold_until :: proc(t: ^testing.T, count: i32) {
	for _ in 0 ..< 10_000 {
		if sync.atomic_load(&tool_job_hold_running) >= count { return }
		time.sleep(time.Millisecond)
	}
	testing.fail_now(t, "the held calls never started")
}

// --- tests ---------------------------------------------------------------------

// A worker-placed call runs on its own thread: the test thread keeps going while the
// call is still inside the executor, and the batch is not advanced by the completion.
@(test)
test_a_worker_placed_call_runs_on_another_thread :: proc(t: ^testing.T) {
	tool_job_hold_reset()
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	tool_job_test_register(t, &test, tool_job_hold_definition("test.hold"))
	_test_stage_call(t, chat, "call_hold", `{}`, "test.hold")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(t, 1)
	testing.expect(t, tool_job_hold_thread_id() != i64(linux.gettid()), "the call must not run on the owner's thread")
	testing.expect_value(t, jobs.jobs[0].phase, Tool_Job_Phase.Running)
	// The only thing left to do is wait: the call owns the lane and the owner.
	testing.expect_value(t, tool_jobs_next(&jobs), Tool_Job_Effect.Wait)

	tool_job_hold_release_all()
	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, 1)
	testing.expect_value(t, jobs.jobs[0].phase, Tool_Job_Phase.Retired)
}

// Native tools share one lane, so a second call waits for the first even though a
// worker slot is free.
@(test)
test_native_calls_share_one_lane :: proc(t: ^testing.T) {
	tool_job_hold_reset()
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	tool_job_test_register(t, &test, tool_job_hold_definition("test.first"))
	tool_job_test_register(t, &test, tool_job_hold_definition("test.second"))
	_test_stage_call(t, chat, "call_first", `{}`, "test.first")
	_test_stage_call(t, chat, "call_second", `{}`, "test.second")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(t, 1)
	testing.expect_value(t, jobs.jobs[0].phase, Tool_Job_Phase.Running)
	testing.expect_value(t, jobs.jobs[1].phase, Tool_Job_Phase.Queued)
	testing.expect_value(t, jobs.active, 1)

	tool_job_hold_release_all()
	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, 2)
	testing.expect_value(t, sync.atomic_load(&tool_job_hold_running), i32(0))
}

// Two MCP clients are two lanes, so their calls overlap: one stdio stream cannot be
// read by two calls, but two streams can.
@(test)
test_calls_to_different_backends_overlap :: proc(t: ^testing.T) {
	tool_job_hold_reset()
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	first_backend: u8
	second_backend: u8
	tool_job_test_register(t, &test, tool_job_hold_definition("test.first", &first_backend))
	tool_job_test_register(t, &test, tool_job_hold_definition("test.second", &second_backend))
	_test_stage_call(t, chat, "call_first", `{}`, "test.first")
	_test_stage_call(t, chat, "call_second", `{}`, "test.second")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Dispatch)
	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(t, 1)
	testing.expect_value(t, jobs.active, 2)
	testing.expect_value(t, jobs.jobs[0].phase, Tool_Job_Phase.Running)
	testing.expect_value(t, jobs.jobs[1].phase, Tool_Job_Phase.Running)

	tool_job_hold_release_all()
	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, 2)
}

// The worker bound holds: one more eligible call than there are slots stays queued, and
// goes the moment a slot frees.
@(test)
test_running_calls_are_bounded :: proc(t: ^testing.T) {
	tool_job_hold_reset()
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	// One lane each, so nothing but the worker bound can hold a call back.
	lanes: [TOOL_JOBS_MAX_ACTIVE + 1]u8
	names := [TOOL_JOBS_MAX_ACTIVE + 1]string{"test.one", "test.two", "test.three", "test.four", "test.five"}
	for name, index in names {
		tool_job_test_register(t, &test, tool_job_hold_definition(name, &lanes[index]))
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
	tool_job_test_hold_until(t, i32(TOOL_JOBS_MAX_ACTIVE))
	testing.expect_value(t, jobs.active, TOOL_JOBS_MAX_ACTIVE)
	testing.expect_value(t, sync.atomic_load(&tool_job_hold_running), i32(TOOL_JOBS_MAX_ACTIVE))
	queued := 0
	for job in jobs.jobs {
		if job.phase == .Queued { queued += 1 }
	}
	testing.expect_value(t, queued, 1)
	// What is left is a wait, not a dispatch: the bound is real, not a preference.
	testing.expect_value(t, tool_jobs_next(&jobs), Tool_Job_Effect.Wait)

	tool_job_hold_release_all()
	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, len(names))
}

// A cancelled turn still answers every committed call: the running call is stopped
// through its inherited control, and the queued one is refused without ever dispatching.
@(test)
test_a_stopped_turn_still_answers_every_call :: proc(t: ^testing.T) {
	tool_job_hold_reset()
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	tool_job_test_register(t, &test, tool_job_hold_definition("test.running"))
	tool_job_test_register(t, &test, tool_job_hold_definition("test.queued"))
	_test_stage_call(t, chat, "call_running", `{}`, "test.running")
	_test_stage_call(t, chat, "call_queued", `{}`, "test.queued")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Dispatch)
	tool_job_test_hold_until(t, 1)

	chat_cancel_request()
	defer chat_cancel_reset()
	tool_jobs_latch_stop(&jobs, chat)
	testing.expect_value(t, jobs.stop, Tool_Jobs_Stop.Cancelled)
	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Refuse)
	testing.expect_value(t, jobs.jobs[1].phase, Tool_Job_Phase.Result_Ready)

	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, 2)
	testing.expect_value(t, sync.atomic_load(&tool_job_hold_running), i32(0))

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
	tool_job_hold_reset()
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	lanes: [TOOL_JOBS_MAX_ACTIVE]u8
	names := [TOOL_JOBS_MAX_ACTIVE]string{"test.one", "test.two", "test.three", "test.four"}
	for name, index in names {
		tool_job_test_register(t, &test, tool_job_hold_definition(name, &lanes[index]))
		_test_stage_call(t, chat, name, `{}`, name)
	}
	owner_tool := tool_job_hold_definition("test.control", nil, tool_job_immediate_execute)
	owner_tool.placement = .Owner
	tool_job_test_register(t, &test, owner_tool)
	_test_stage_call(t, chat, "call_control", `{}`, "test.control")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)
	tool_jobs_submit(&jobs, chat, {})

	for jobs.active < TOOL_JOBS_MAX_ACTIVE {
		if tool_job_test_step(&test, &jobs) != .Dispatch { break }
	}
	tool_job_test_hold_until(t, i32(TOOL_JOBS_MAX_ACTIVE))
	testing.expect_value(t, jobs.active, TOOL_JOBS_MAX_ACTIVE)
	control := jobs.jobs[TOOL_JOBS_MAX_ACTIVE]
	testing.expect_value(t, control.placement, Tool_Placement.Owner)
	testing.expect_value(t, control.phase, Tool_Job_Phase.Queued)
	// It runs to a result while the four workers are still inside their executors.
	testing.expect_value(t, tool_job_test_step(&test, &jobs), Tool_Job_Effect.Dispatch)
	testing.expect_value(t, control.phase, Tool_Job_Phase.Result_Ready)
	testing.expect_value(t, jobs.active, TOOL_JOBS_MAX_ACTIVE)

	tool_job_hold_release_all()
	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, len(names) + 1)
}

// Release is complete: every worker is joined, every job-owned byte comes back to the
// allocator that handed it out, and the recorded results survive in the store.
@(test)
test_a_settled_batch_releases_every_thread_and_byte :: proc(t: ^testing.T) {
	tool_job_hold_reset()
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat

	// The tracking allocator stands in for the process heap a worker allocates from,
	// so the test can hold the batch to releasing everything it took.
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)

	first_backend: u8
	second_backend: u8
	tool_job_test_register(t, &test, tool_job_hold_definition("test.first", &first_backend))
	tool_job_test_register(t, &test, tool_job_hold_definition("test.second", &second_backend))
	_test_stage_call(t, chat, "call_first", `{"path":"a"}`, "test.first")
	_test_stage_call(t, chat, "call_second", `{"path":"b"}`, "test.second")

	jobs: Tool_Jobs
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), mem.tracking_allocator(&tracker))
	tool_jobs_submit(&jobs, chat, {})
	tool_job_hold_release_all()
	tool_job_test_drain(t, &test, &jobs)
	testing.expect_value(t, jobs.committed, 2)

	for job in jobs.jobs {
		testing.expect_value(t, job.phase, Tool_Job_Phase.Retired)
		testing.expect(t, job.worker == nil, "the worker must be joined and released")
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
	tool_job_hold_reset()
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	tool_job_test_register(t, &test, tool_job_hold_definition("test.owned"))
	_test_stage_call(t, chat, "call_owned", `{}`, "test.owned")

	first := chat_session_advance(chat)
	defer chat_effect_destroy(&first)
	second := chat_session_advance(chat)
	defer chat_effect_destroy(&second)
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
	chat_effect_destroy(&dispatch)
	tool_job_test_hold_until(t, 1)

	wait := chat_session_advance(chat)
	testing.expect_value(t, wait.kind, Chat_Effect_Kind.Wait_Tools)
	chat_effect_destroy(&wait)

	tool_job_hold_release_all()
	for _ in 0 ..< 100_000 {
		effect := chat_session_advance(chat)
		switch effect.kind {
		case .Step_Tools:
			chat_tool_jobs_step(chat, {}, effect.tool)
		case .Wait_Tools:
			chat_tool_jobs_wait(chat)
		case .Finish_Tools:
			turn_id := effect.turn_id
			chat_effect_destroy(&effect)
			testing.expect(t, chat_tool_jobs_finish(chat, turn_id), "the settled batch should close")
			testing.expect(t, !chat.tool_jobs_active, "finishing releases the session table")
			testing.expect_value(t, chat.state, Chat_State.Preparing)
			return
		case .None, .Start_Request, .Run_Tools, .Turn_Finished:
			testing.fail_now(t, "the chat selected an invalid tool effect")
		}
		chat_effect_destroy(&effect)
	}
	testing.expect(t, false, "the session-owned batch never settled")
}

// Cancellation does not skip the job table. The cancelling state keeps selecting job
// effects until every committed call has a result and every producer has retired.
@(test)
test_cancelling_chat_drains_session_owned_jobs :: proc(t: ^testing.T) {
	tool_job_hold_reset()
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)
	chat := &test.fixture.chat
	tool_job_test_register(t, &test, tool_job_hold_definition("test.cancel"))
	_test_stage_call(t, chat, "call_cancel", `{}`, "test.cancel")
	chat_tool_jobs_begin(chat, {})

	dispatch := chat_session_advance(chat)
	chat_tool_jobs_step(chat, {}, dispatch.tool)
	chat_effect_destroy(&dispatch)
	tool_job_test_hold_until(t, 1)

	chat_session_request_cancel(chat)
	defer chat_cancel_reset()
	testing.expect_value(t, chat.state, Chat_State.Cancelling)

	for _ in 0 ..< 100_000 {
		effect := chat_session_advance(chat)
		switch effect.kind {
		case .Step_Tools:
			chat_tool_jobs_step(chat, {}, effect.tool)
		case .Wait_Tools:
			chat_tool_jobs_wait(chat)
		case .Finish_Tools:
			turn_id := effect.turn_id
			chat_effect_destroy(&effect)
			testing.expect(t, chat_tool_jobs_finish(chat, turn_id), "the cancelled batch should close")
			testing.expect_value(t, chat.state, Chat_State.Cancelling)
			testing.expect_value(t, chat.calls_made, 1)
			return
		case .None, .Start_Request, .Run_Tools, .Turn_Finished:
			testing.fail_now(t, "cancellation skipped the tool drain")
		}
		chat_effect_destroy(&effect)
	}
	testing.expect(t, false, "the cancelled session-owned batch never settled")
}
