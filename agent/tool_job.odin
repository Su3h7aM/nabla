package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

// --- owned tool jobs -----------------------------------------------------------
//
// A tool call becomes a job before it becomes an execution. The job is the owner's
// record of one call: what was admitted, where it runs, what it produced, and what has
// been recorded. The owner decides and the worker executes, which is what lets a turn
// keep working while a tool blocks, and what lets one call stop without stopping its
// siblings.
//
// Only the owner changes a phase, writes history, and frees a job, after joining its
// worker. A worker publishes exactly one fact, its result, and exits.
//
// The table's records are allocated one at a time and never move, because an effect
// names a job and a running worker holds that address.

// TOOL_JOBS_MAX_ACTIVE is the floor of the bound on worker-placed jobs running at once;
// the table raises it to the processor core count. A Code Mode parent never occupies a
// slot while it waits for its children, so the bound cannot make a parent block its own
// child.
TOOL_JOBS_MAX_ACTIVE :: 4

// TOOL_JOBS_STOP_PATIENCE is how long a call may keep running after its stop was asked for,
// by the turn's cancellation or by its own timeout. A backend that never returns cannot be
// stopped cooperatively, so past this the call is answered as unknown and its job is
// abandoned: retained until its worker publishes, while the session keeps working.
TOOL_JOBS_STOP_PATIENCE :: 10 * time.Second

// Tool_Job_Phase is what a job has done and what it still owes. The phase answers one
// question: what kind of step is this job's next one.
Tool_Job_Phase :: enum {
	// Queued: the call and its arguments are admitted, and it waits for a lane and a
	// worker slot.
	Queued,
	// Dispatching: the dispatch write is outstanding. It is durable intent, not a
	// claim that the executor started.
	Dispatching,
	// Running: an executor owns the call.
	Running,
	// Waiting: a Lua execution is suspended until its current child records a result.
	Waiting,
	// Result_Ready: a terminal result exists and is not recorded.
	Result_Ready,
	// Committing: the result write is outstanding.
	Committing,
	// Retiring: the result was recorded, or deliberately dropped, and execution
	// resources may still need release.
	Retiring,
	// Retired: released, with its result in the record.
	Retired,
	// Unrecorded: released without a result in the record, because the session's
	// storage failed. Recovery records uncertainty for it later.
	Unrecorded,
	// Abandoned: the worker ignored its stop. The job and its thread handle are retained
	// until the worker publishes, and nothing the worker can reach is freed before then.
	Abandoned,
}

// Tool_Jobs_Stop is why a batch stopped admitting work. None is the zero value, so a
// batch that was never stopped reads as running.
Tool_Jobs_Stop :: enum {
	None,
	// The turn was cancelled. Calls that never ran are still recorded, as
	// not-executed results, because the turn's answers must stay complete.
	Cancelled,
	// A durable write failed. Nothing more can be recorded, so the batch drains and
	// reports what it already committed.
	Storage_Failed,
}

// Tool_Job_Effect is the one bounded step the owner should take next. The decision
// reads phases and performs no I/O and no execution, which is what makes the order
// testable without a thread.
Tool_Job_Effect :: enum {
	// Commit: record the result of the earliest uncommitted job.
	Commit,
	// Refuse: answer a queued call that cannot run, because the batch stopped or its lane
	// is held by an abandoned call.
	Refuse,
	// Abandon: answer a call that ignored its stop with what the harness observed, and
	// release its slot and native lane so later calls can run.
	Abandon,
	// Retire: release a settled job's execution resources.
	Retire,
	// Dispatch: record one call's dispatch entry and start its executor.
	Dispatch,
	// Wait: nothing is runnable; sleep until a completion or the wait slice ends.
	Wait,
	// Done: every job is released.
	Done,
}

// Tool_Job is one admitted call.
Tool_Job :: struct {
	// worker is the shared worker lifecycle: the thread, its publication, and the stop
	// patience. It is the first field, so a pointer to the call is a pointer to its Job. It
	// is not embedded with using, because the call's own phase has the same name.
	worker:         Job,
	// identity, owned by the table and stable for the job's life
	id:             u64,
	turn_id:        u64,
	ordinal:        int, // submission order, which is the order results are recorded in
	call:           ^Chat_Tool_Call, // borrowed: the session's staged calls outlive the batch
	name:           string, // owned by allocator
	call_id:        string, // owned by allocator

	// placement
	placement:      Tool_Placement,
	lane:           rawptr, // borrowed backend identity; nil is the shared native lane
	execute:        Tool_Execute,

	// Lua execution data. A nested call is embedded in its child job so the call
	// pointer stays stable when the table grows. lua_children are the calls the script
	// started, by handle, and lua_waiting is the handle job.wait is parked on, or zero.
	lua:            ^Lua_Run,
	lua_dispatched: bool,
	lua_children:   [dynamic]Codemode_Child,
	lua_waiting:    int,
	parent:         ^Tool_Job,
	nested_call:    Chat_Tool_Call,
	nested:         bool,

	// execution data, owned by allocator, which is a thread-safe heap
	allocator:      mem.Allocator,
	// admitted is the document the call was admitted from: a provider call is admitted here
	// from the text it arrived as, while a Lua child call arrives admitted, because its value
	// came from Lua rather than from a provider document. arguments is the typed call the
	// executor receives, read out of that document once.
	admitted:       Tool_Arguments,
	arguments:      Tool_Args,
	exec:           Tool_Context, // what the executor is given, for the job's whole life
	output_base:    string, // owned by allocator; what exec.output_base borrows

	// control
	phase:          Tool_Job_Phase,
	interrupt:      ai.Interrupt, // this job's own stop token
	// wake is a worker job's stop pipe: the owner signals it with the stop request,
	// which wakes a worker sleeping in poll, and closes it when it releases the job.
	wake:           Tool_Wake,
	// tabled says a batch's table holds this job. An abandoned job is already listed in the
	// session's abandoned jobs, but job_reclaim leaves it alone until its table is destroyed.
	tabled:         bool,

	// outcome
	result:         Tool_Result,
	result_present: bool,
	committed:      bool,
}

// Tool_Jobs is one batch's table. Only the owner reads and writes it.
Tool_Jobs :: struct {
	jobs:             [dynamic]^Tool_Job,
	allocator:        mem.Allocator, // the session's: it owns the table, not the jobs
	next_id:          u64,
	active:           int, // worker-placed jobs running now
	max_active:       int, // most worker-placed jobs running at once
	committed:        int, // all durable results, including nested calls
	committed_roots:  int, // provider calls answered at the turn barrier
	stop:             Tool_Jobs_Stop,
	// worker_allocator is where job-owned storage comes from: the arguments a worker
	// reads, its context, and the result it produces. It is the process heap in
	// production, because a worker must not allocate from the session's allocator,
	// which may be a wrapper the owner is writing through at the same time. A test
	// passes a tracking allocator here to hold the batch to releasing every byte.
	worker_allocator: mem.Allocator,
	// budget decides what each result may put into the model's context. It is taken in
	// submission order, so a batch spends the window in the order the model asked.
	budget:           Tool_Budget,
	// chat is the session the batch runs in, borrowed. An abandoned job is recorded in its
	// journal and listed in its abandoned jobs, where it blocks only its own external lane.
	chat:             ^Chat_Session,
}

// --- lifetime ------------------------------------------------------------------

tool_jobs_init :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, capacity: int, worker_allocator: mem.Allocator) {
	jobs.allocator = chat.allocator
	jobs.worker_allocator = worker_allocator
	jobs.max_active = max(TOOL_JOBS_MAX_ACTIVE, os.get_processor_core_count())
	jobs.chat = chat
	table, table_error := make([dynamic]^Tool_Job, 0, capacity, chat.allocator)
	jobs.jobs = table
	if table_error != nil {
		// A batch with no table cannot admit a call, which is the state a failed durable write
		// leaves it in: it drains, and the turn reports the calls it never answered.
		jobs.stop = .Storage_Failed
	}
	jobs.budget = chat_tool_budget_open(chat, len(chat.pending_calls))
}

// tool_jobs_destroy releases the table and every job no worker can still reach. A running
// worker is asked to stop, together with the others, and is given the stop patience to
// publish; one that does not is abandoned and stays listed in the session's abandoned jobs.
tool_jobs_destroy :: proc(jobs: ^Tool_Jobs) {
	now := time.tick_now()
	for job in jobs.jobs {
		if job.worker.phase != .Running { continue }
		tool_job_request_stop(job)
		job_note_stop(&job.worker, true, now)
	}
	for job in jobs.jobs {
		if job.worker.phase != .Running { continue }
		if job_wait_published(&job.worker, job_stop_deadline(&job.worker)) {
			job_retire(&job.worker)
		} else {
			tool_job_abandon(jobs, job)
		}
	}
	for job in jobs.jobs {
		if job.phase == .Abandoned {
			// The session's list owns the job from here, and job_reclaim may now release it.
			job.tabled = false
			continue
		}
		tool_job_release(job)
	}
	delete(jobs.jobs)
	jobs^ = {}
}

// tool_job_abandon gives up waiting for a job's worker and records it. The job keeps what the
// worker can reach, and gives back its worker slot so the batch can keep running calls. Owner
// only.
@(private)
tool_job_abandon :: proc(jobs: ^Tool_Jobs, job: ^Tool_Job) {
	chat := jobs.chat
	_, parent_call := tool_job_record_placement(chat, job)
	job.worker.record = {
		request     = chat.request,
		call        = job.call.call,
		parent_call = parent_call,
	}
	job.phase = .Abandoned
	if job.placement == .Worker { jobs.active -= 1 }
	job_abandon(chat, &job.worker)
}

@(private)
tool_job_release :: proc(job: ^Tool_Job) {
	if job.lua != nil { codemode_lua_destroy(job.lua) }
	delete(job.lua_children)
	if job.nested {
		delete(job.nested_call.id, job.allocator)
		delete(job.nested_call.item_id, job.allocator)
		delete(job.nested_call.name, job.allocator)
		delete(job.nested_call.arguments, job.allocator)
	}
	tool_args_destroy(&job.arguments, job.allocator)
	tool_arguments_destroy(&job.admitted, job.allocator)
	if job.result_present { tool_result_destroy(&job.result) }
	tool_wake_close(&job.wake)
	delete(job.output_base, job.allocator)
	delete(job.name, job.allocator)
	delete(job.call_id, job.allocator)
	mem.free(job, job.allocator)
}

tool_jobs_committed :: proc(jobs: ^Tool_Jobs) -> int { return jobs.committed_roots }

// tool_jobs_settled reports whether every job is released, which is what ends the
// batch's loop. An abandoned job counts as settled.
@(require_results)
tool_jobs_settled :: proc(jobs: ^Tool_Jobs) -> bool {
	for job in jobs.jobs {
		switch job.phase {
		case .Queued, .Dispatching, .Running, .Waiting, .Result_Ready, .Committing, .Retiring:
			return false
		case .Retired, .Unrecorded, .Abandoned:
		}
	}
	return true
}

@(private)
tool_jobs_earliest :: proc(jobs: ^Tool_Jobs, phases: bit_set[Tool_Job_Phase]) -> ^Tool_Job {
	found: ^Tool_Job
	for job in jobs.jobs {
		if job.phase not_in phases { continue }
		if found == nil || job.ordinal < found.ordinal { found = job }
	}
	return found
}

// tool_jobs_earliest_live returns the job with the lowest ordinal that has not been
// released, or the earliest live child of that job. Results are recorded in submission
// order, which is the order the response asked its calls in, so the context budget is
// spent the way the model asked for it and a request built later sends the same batch in
// the same order. The table is in ordinal order, so the first live job is the earliest.
@(private)
tool_jobs_earliest_live :: proc(jobs: ^Tool_Jobs) -> ^Tool_Job {
	for job in jobs.jobs {
		switch job.phase {
		case .Retired, .Unrecorded, .Abandoned:
			continue
		case .Queued, .Dispatching, .Running, .Waiting, .Result_Ready, .Committing, .Retiring:
		}
		if child := codemode_job_live_child(job); child != nil { return child }
		return job
	}
	return nil
}

// --- submission ----------------------------------------------------------------

// tool_jobs_publish makes a fully initialized job visible to the owner table. The
// table append is part of admission: a job that is not published has no owner, so
// it must be released with the worker allocator before the batch changes state.
@(private, require_results)
tool_jobs_publish :: proc(jobs: ^Tool_Jobs, job: ^Tool_Job) -> bool {
	if append(&jobs.jobs, job) != 1 {
		tool_job_release(job)
		if jobs.stop == .None { jobs.stop = .Storage_Failed }
		return false
	}
	job.tabled = true
	jobs.next_id += 1
	return true
}

// tool_jobs_submit admits the calls a response committed into jobs. Admission is the
// owner's work: it resolves the definition, admits the arguments, and turns anything
// that cannot run into a result now, so the batch only ever executes admitted calls.
tool_jobs_submit :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, observer: Chat_Observer) {
	for &staged in chat.pending_calls {
		job, alloc_err := mem.new(Tool_Job, jobs.worker_allocator)
		if alloc_err != nil { return }
		job^ = {
			id        = jobs.next_id,
			turn_id   = chat.active_turn_id,
			ordinal   = len(jobs.jobs),
			call      = &staged,
			placement = .Worker,
			phase     = .Queued,
			allocator = jobs.worker_allocator,
		}
		name, name_error := strings.clone(staged.name, job.allocator)
		call_id, call_id_error := strings.clone(staged.id, job.allocator)
		job.name, job.call_id = name, call_id
		if name_error != nil || call_id_error != nil {
			// A call that cannot name itself cannot be admitted or recorded, so it is released
			// unanswered: the batch barrier ends the turn instead of claiming it ran.
			tool_job_release(job)
			return
		}
		tool_job_admit(jobs, chat, observer, job)
		if !tool_jobs_publish(jobs, job) { return }
	}
}

// tool_job_admit resolves one call and either queues it for execution or produces the
// result that refuses it. It performs no durable write: a refused call is a call that
// never dispatched, and the record says so by having no dispatch entry.
@(private)
tool_job_admit :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, observer: Chat_Observer, job: ^Tool_Job) {
	job.exec = Tool_Context {
		call_id   = job.call_id,
		workspace = chat.workspace,
		allocator = job.allocator,
		skills    = chat_skill_catalog(chat),
		call      = job.call.call,
	}
	if job.call.call > 0 {
		job.output_base = chat_tool_output_path(chat, job.call.call, "", job.allocator)
		job.exec.output_base = job.output_base
	}
	// The call is announced before anything decides whether it runs, so a front-end sees
	// the proposal itself. The result that follows names the same call id whatever the
	// harness decided here.
	_observer_tool_call(observer, Chat_Tool_Event{call_id = job.call_id, name = job.name, arguments = job.call.arguments})

	// A cancelled turn still answers every committed call, so a call that never ran
	// becomes a not-executed result rather than a silent gap in the record.
	if jobs.stop != .None || chat_session_cancelled(chat) {
		job.result = tool_result_failure(&job.exec, .Not_Executed, "the turn was cancelled before this call ran", "not executed")
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	definition, present := tool_registry_find(&chat.tools, job.name)
	if !present {
		job.result = tool_result_failure(&job.exec, .Unavailable, fmt.tprintf("no tool named %q is available", job.name), "unavailable")
		job.result_present = true
		job.phase = .Result_Ready
		return
	}

	job.placement = definition.placement
	job.lane = definition.lane
	job.execute = definition.execute
	job.exec.timeout = definition.timeout
	job.exec.backend = definition.backend
	job.interrupt.parent = &chat.stop
	job.exec.control = {
		interrupt = &job.interrupt,
	}
	// A worker must not reach the session's state, and it does not have to: the tool that
	// changes the context is owner-placed.
	if definition.placement == .Owner { job.exec.compact = &chat.compact }
	switch definition.kind {
	case .Agent_Spawn, .Agent_Send, .Agent_Stop:
		job.exec.agents = chat.team if chat.member == nil else nil
		job.exec.member = chat.member
		// A blocking subagent holds its worker for its whole run, so each has a lane of its
		// own and several run side by side.
		if definition.kind == .Agent_Spawn { job.lane = job }
	case .Custom, .Read, .Write, .Patch, .Shell, .List_Skills, .Load_Skill, .Compact, .Codemode, .MCP:
	}

	// A provider call is admitted here, from the text it arrived as. A Lua child call arrives
	// admitted, because its value came from Lua and was checked where it was read.
	if job.admitted.status == .None { job.admitted = tool_arguments_prepare(job.call.arguments, job.allocator) }

	if job.admitted.allocation_failed {
		job.result = tool_result_failure(&job.exec, .Tool_Failed, "the tool arguments could not be allocated", "allocation failed")
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	if job.admitted.status == .Rejected {
		job.result = tool_result_refused(&job.exec, &job.admitted.error)
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	if _, is_object := job.admitted.value.(json.Object); !is_object {
		job.result = tool_result_failure(&job.exec, .Invalid_Arguments, "the arguments are not a JSON object", "invalid arguments")
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	args, args_error := tool_args_decode(&job.exec, definition^, job.admitted.value.(json.Object))
	job.arguments = args
	if args_error != nil {
		job.admitted.repairs += job.exec.repairs
		defer tool_argument_error_destroy(&args_error, job.allocator)
		job.result = tool_result_refused(&job.exec, &args_error)
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	if job.exec.repairs != {} {
		// A field was rewritten while it was read, so the recorded arguments are written
		// again from the value, in key order, to say what the call runs with.
		effective, marshal_error := json.marshal(job.admitted.value, {sort_maps_by_key = true}, job.allocator)
		if marshal_error != nil {
			job.result = tool_result_failure(&job.exec, .Tool_Failed, "the repaired tool arguments could not be written", "allocation failed")
			job.result_present = true
			job.phase = .Result_Ready
			return
		}
		delete(job.admitted.effective, job.allocator)
		job.admitted.effective = string(effective)
		job.admitted.repairs += job.exec.repairs
	}
	if job.admitted.repairs != {} {
		notice_repairs, notice_error := tool_repairs_text(job.admitted.repairs, context.temp_allocator)
		if notice_error != nil { notice_repairs = "unwritten: out of memory" }
		notice := fmt.tprintf("a tool call was repaired before it ran: %s", notice_repairs)
		_observer_message(observer, .Notice, notice)
	}
	// What the call runs with is the text the dispatch record holds, so an executor
	// that forwards the call cannot send something other than what was recorded.
	job.exec.arguments_json = job.admitted.effective
}


// --- decisions -----------------------------------------------------------------

// tool_jobs_observe applies what happened outside the batch to its state: workers that
// published a result, a stop the session asked for, and the owner's first sight of a
// call that should have stopped. It is the only place those facts enter the table, so
// tool_jobs_next can read the table without changing it.
tool_jobs_observe :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, now: time.Tick) {
	// A published worker's join is the proof that nothing else reaches the job.
	for job in jobs.jobs {
		if job.worker.phase != .Running || !job_published(&job.worker) { continue }
		job_retire(&job.worker)
		job.phase = .Result_Ready
		if job.placement == .Worker { jobs.active -= 1 }
	}
	tool_jobs_latch_stop(jobs, chat)
	// Only a call a worker owns can outlive its stop, and the patience is measured from the
	// owner's first sight of the stop, which the job's own timeout or the turn asked for.
	for job in jobs.jobs {
		if job.worker.phase == .Running { job_note_stop(&job.worker, tool_control_cancelled(job.exec.control), now) }
	}
}

// tool_jobs_next is the batch's readiness order: answer what ignored its stop, settle what
// finished, release what settled, start what may start, and sleep only when there is nothing
// else. now is the owner's clock observation, so a test supplies it instead of waiting out
// the stop patience. It reads the table and performs no I/O, no executor call, and no clock
// read; tool_jobs_observe is what brings the outside facts in first. Settling work is never
// starved behind new work.
tool_jobs_next :: proc(jobs: ^Tool_Jobs, now: time.Tick) -> Tool_Job_Effect {
	if jobs.stop == .Storage_Failed {
		// Nothing more can be recorded, so there is nothing left to settle here: release what
		// can be released now and wait for what cannot.
		if tool_jobs_retirable(jobs, now) != nil { return .Retire }
		if !tool_jobs_settled(jobs) { return .Wait }
		return .Done
	}
	if job := tool_jobs_earliest_live(jobs); job != nil && job.phase == .Result_Ready { return .Commit }
	// A stopped batch stops admitting calls, and a queued call is one that was
	// admitted before the stop reached it.
	if jobs.stop != .None && tool_jobs_earliest(jobs, {.Queued}) != nil { return .Refuse }
	if tool_jobs_lane_abandoned(jobs) != nil { return .Refuse }
	if tool_jobs_earliest(jobs, {.Dispatching, .Running}) != nil && tool_jobs_overdue(jobs, now) != nil { return .Abandon }
	if tool_jobs_retirable(jobs, now) != nil { return .Retire }
	if tool_jobs_runnable(jobs, now) != nil { return .Dispatch }
	if !tool_jobs_settled(jobs) { return .Wait }
	return .Done
}

// tool_jobs_overdue returns the earliest running job whose worker was asked to stop and has
// not published within the patience. It is the call the owner can no longer wait for.
@(private)
tool_jobs_overdue :: proc(jobs: ^Tool_Jobs, now: time.Tick) -> ^Tool_Job {
	found: ^Tool_Job
	for job in jobs.jobs {
		if job.worker.phase != .Running || !job_overdue(&job.worker, now) { continue }
		if found == nil || job.ordinal < found.ordinal { found = job }
	}
	return found
}

// tool_jobs_retirable returns the earliest job the owner can release or abandon now.
@(private)
tool_jobs_retirable :: proc(jobs: ^Tool_Jobs, now: time.Tick) -> ^Tool_Job {
	phases: bit_set[Tool_Job_Phase] = {.Retiring}
	if jobs.stop == .Storage_Failed { phases = {.Dispatching, .Running, .Queued, .Waiting, .Result_Ready, .Retiring} }
	found: ^Tool_Job
	for job in jobs.jobs {
		if job.phase not_in phases { continue }
		if !tool_job_releasable(job) && !job_overdue(&job.worker, now) { continue }
		if found == nil || job.ordinal < found.ordinal { found = job }
	}
	return found
}

// tool_job_releasable reports whether no worker can still reach the job. A launched job
// leaves Running only when the owner joined its worker or abandoned it.
@(private, require_results)
tool_job_releasable :: proc(job: ^Tool_Job) -> bool {
	return job.worker.phase != .Running
}

// tool_jobs_published returns the earliest running job whose worker has published.
@(private)
tool_jobs_published :: proc(jobs: ^Tool_Jobs) -> ^Tool_Job {
	for job in jobs.jobs {
		if job.worker.phase == .Running && job_published(&job.worker) { return job }
	}
	return nil
}

// tool_jobs_runnable returns the earliest queued job or an expired Code Mode parent.
@(private)
tool_jobs_runnable :: proc(jobs: ^Tool_Jobs, now: time.Tick) -> ^Tool_Job {
	for job in jobs.jobs {
		if job.phase == .Waiting &&
		   job.placement == .Lua &&
		   job.lua != nil &&
		   !job.lua.terminal &&
		   job.lua.deadline != {} &&
		   time.tick_diff(job.lua.deadline, now) >= 0 {
			return job
		}
		if job.phase != .Queued { continue }
		if !tool_jobs_lane_free(jobs, job) { continue }
		if job.placement == .Worker && jobs.active >= jobs.max_active { continue }
		return job
	}
	return nil
}

// tool_jobs_lane_free reports whether a job's lane is unoccupied. A lane is a
// serialization domain: everything native shares one, and each MCP client is its own,
// because one stdio stream cannot be read by two calls at once. Occupancy is derived
// from the table rather than tracked separately, so a lane cannot be left busy by a
// job that was already released. An abandoned job gives up the native lane, so new
// native work takes over from it.
@(private, require_results)
tool_jobs_lane_free :: proc(jobs: ^Tool_Jobs, candidate: ^Tool_Job) -> bool {
	// A script runs on the owner in slices, so it never waits for a lane.
	if candidate.placement == .Lua { return true }
	for job in jobs.jobs {
		if job == candidate || job.lane != candidate.lane { continue }
		switch job.phase {
		case .Dispatching, .Running:
			return false
		case .Queued, .Waiting, .Result_Ready, .Committing, .Retiring, .Retired, .Unrecorded, .Abandoned:
		}
	}
	return true
}

// tool_jobs_lane_abandoned returns the earliest queued call whose external lane is held by an
// abandoned call. The stuck worker may still be using that backend, so the call is answered
// now instead of waiting for a worker that may never return.
@(private)
tool_jobs_lane_abandoned :: proc(jobs: ^Tool_Jobs) -> ^Tool_Job {
	for job in jobs.jobs {
		if job.phase != .Queued || job.placement == .Lua || job.lane == nil { continue }
		for other in jobs.jobs {
			if other.phase == .Abandoned && other.lane == job.lane { return job }
		}
		for other in jobs.chat.abandoned {
			if other.kind == .Tool && (cast(^Tool_Job)other).lane == job.lane { return job }
		}
	}
	return nil
}

// tool_jobs_latch_stop records a stop the owner observed outside the batch: a turn
// cancellation or a session whose storage failed. Cancellation is a request, not proof
// of retirement: running jobs are asked to stop and drained either way.
tool_jobs_latch_stop :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session) {
	candidate := jobs.stop
	if candidate == .None {
		switch {
		case chat.storage_failed:
			candidate = .Storage_Failed
		case chat_session_cancelled(chat):
			candidate = .Cancelled
		}
	}
	if candidate == .None { return }
	if jobs.stop == .None {
		jobs.stop = candidate
	}
	// A running job is asked once; the request is latched in its own token, so a
	// repeat is harmless and a job that ignores it is drained, not forgotten.
	for job in jobs.jobs {
		if job.phase == .Running { tool_job_request_stop(job) }
		if job.placement == .Lua && job.lua != nil {
			codemode_lua_request_stop(job.lua)
			if job.phase == .Queued && candidate == .Cancelled {
				codemode_job_answer(job, .Cancelled, .Cancelled, "the Code Mode execution was cancelled", "cancelled")
			}
		}
	}
}

// --- effects -------------------------------------------------------------------

// tool_job_record_placement names where a job's tool records belong: a provider call hangs
// on the assistant node that proposed it, while a Lua child hangs on the call that started
// it.
@(private)
tool_job_record_placement :: proc(chat: ^Chat_Session, job: ^Tool_Job) -> (node: journal.Node_Id, parent_call: journal.Call_Id) {
	if job.nested { return 0, job.parent.call.call }
	return chat.response_node, 0
}

// tool_jobs_dispatch records one call's dispatch entry and starts its executor. A call the
// turn stopped before this point is answered not executed and leaves no admission. Past
// that, the write comes first: a dispatch entry without a result is recovered as an
// unknown outcome, while a result without a dispatch entry would claim knowledge the
// harness does not have.
tool_jobs_dispatch :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session) {
	job := tool_jobs_runnable(jobs, time.tick_now())
	if job == nil { return }
	if job.placement == .Lua && job.lua_dispatched {
		tool_job_lua_resume(jobs, chat, job)
		return
	}
	job.phase = .Dispatching

	if tool_control_cancelled(job.exec.control) {
		job.result = tool_result_failure(&job.exec, .Not_Executed, "the turn was cancelled before this call ran", "not executed")
		job.result_present = true
		job.phase = .Result_Ready
		return
	}

	repair_names: [len(Tool_Repair)]string
	repair_count := 0
	for repair in job.admitted.repairs {
		repair_names[repair_count] = TOOL_REPAIR_NAMES[repair]
		repair_count += 1
	}
	if _, is_send := job.arguments.(Agent_Send_Args); is_send && job.exec.agents != nil && job.exec.member == nil {
		// A child that has finished is continued from its journal records, so its outcome is
		// committed before the message that continues it.
		_ = agent_team_reap(job.exec.agents, chat)
	}
	node, parent_call := tool_job_record_placement(chat, job)
	chat_record(
		chat,
		{kind = .Tool_Admitted, node = node, request = chat.request, call = job.call.call, parent_call = parent_call},
		journal.Tool_Admitted{tool = job.name, repairs = repair_names[:repair_count]},
		transmute([]u8)job.admitted.effective,
	)
	if spawn, is_spawn := job.arguments.(Agent_Spawn_Args); is_spawn && job.exec.agents != nil && job.exec.member == nil {
		// The delegation is named before its child exists, so the child's session is
		// traceable to this call whatever happens next.
		job.exec.subagent = journal.session_id_create()
		chat_record(
			chat,
			{kind = .Subagent_Started, node = node, request = chat.request, call = job.call.call, parent_call = parent_call, subagent = job.exec.subagent},
			journal.Subagent_Started {
				name = subagent_name(job.call.call, context.temp_allocator),
				program = spawn.acp_agent,
				provider = spawn.provider,
				model = spawn.model,
				effort = spawn.effort,
				background = !spawn.wait,
			},
			transmute([]u8)spawn.instruction,
		)
	}
	sends := false
	if send, is_send := &job.arguments.(Agent_Send_Args); is_send {
		sends = true
		tool_job_stage_message(chat, job, send, node, parent_call)
	}
	committed := chat_commit(chat, "the tool dispatch could not be recorded")
	// The recipient wakes only after the commit that holds its message.
	if sends && committed && job.exec.subagent != {} { owner_wake_signal() }
	if !committed {
		tool_jobs_latch_stop(jobs, chat)
		return
	}
	// The executor may run on a worker, which never writes, so the start is recorded here
	// at the owner's dispatch, the last point before its effect can begin.
	chat_record(
		chat,
		{kind = .Tool_Started, node = node, request = chat.request, call = job.call.call, parent_call = parent_call},
		journal.Tool_Started{tool = job.name},
	)
	if job.placement == .Owner {
		job.result = tool_job_execute(job)
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	if job.placement == .Lua {
		job.lua_dispatched = true
		tool_job_lua_start(jobs, chat, job)
		return
	}
	if launch_error := tool_job_launch(job); launch_error != nil {
		// A worker that could not start is a backend the harness could not run. The
		// dispatch entry stands, so the outcome is recorded honestly.
		message := fmt.tprintf("the tool could not be started: %s", os.error_string(launch_error))
		job.result = tool_result_failure(&job.exec, .Tool_Failed, message, "not started")
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	job.phase = .Running
	jobs.active += 1
}

// tool_job_stage_message buffers the subagent.message record of an agent_send call, so it
// commits in the barrier of the call's admission and the recipient is woken only after it.
// A message to a running child needs nothing more: the child reads it at a settled point, or
// the reap that finds it unread runs the child again. A message to a child that has finished
// continues it: a new subagent.started that opens the delegation is buffered first, and
// send.resume says how the executor starts the child. A recipient that cannot take the
// message is left in send.refusal for the executor to report, and nothing is recorded. A
// subagent's message to its orchestrator needs no check, because the orchestrator reads its
// journal at its own settled points.
@(private)
tool_job_stage_message :: proc(chat: ^Chat_Session, job: ^Tool_Job, send: ^Agent_Send_Args, node: journal.Node_Id, parent_call: journal.Call_Id) {
	header := journal.Record {
		kind        = .Subagent_Message,
		node        = node,
		request     = chat.request,
		call        = job.call.call,
		parent_call = parent_call,
	}
	if member := job.exec.member; member != nil {
		// A subagent can message only its orchestrator; the executor refuses the rest.
		if send.agent != "" && send.agent != "orchestrator" { return }
		header.subagent = member.session
		job.exec.subagent = member.session
		chat_record(chat, header, journal.Subagent_Message{name = member.name}, transmute([]u8)send.message)
		return
	}
	if job.exec.agents == nil || send.agent == "" { return }
	session, live := subagent_live(job.exec.agents, send.agent)
	if live {
		if send.model != "" || send.provider != "" || send.effort != "" {
			send.refusal = SUBAGENT_RUNNING_REFUSAL
			return
		}
		header.subagent = session
	} else {
		problem: string
		session, problem = subagent_resume_plan(chat, job.exec.agents, send)
		if problem != "" {
			send.refusal = problem
			return
		}
		header.subagent = session
		start := header
		start.kind = .Subagent_Started
		started := journal.Subagent_Started {
			name       = send.agent,
			provider   = send.provider,
			model      = send.model,
			effort     = send.effort,
			background = true,
		}
		chat_record(chat, start, started, transmute([]u8)send.resume.instruction)
	}
	job.exec.subagent = session
	chat_record(chat, header, journal.Subagent_Message{name = send.agent}, transmute([]u8)send.message)
}

// tool_jobs_abandon answers a call that ignored its stop with an unknown outcome and retains
// its job: the worker may still be running and may still publish into it.
tool_jobs_abandon :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, observer: Chat_Observer, now: time.Tick) {
	job := tool_jobs_overdue(jobs, now)
	if job == nil { return }

	if job_published(&job.worker) { return }
	message := fmt.tprintf("the tool did not stop within %v of its stop being requested; its outcome is unknown", TOOL_JOBS_STOP_PATIENCE)
	result := tool_result_failure(&job.exec, .Unknown, message, "did not stop")
	recorded := false
	if !result.allocation_failed {
		if !job.nested { tool_result_keep(&result, &jobs.budget, chat_tool_output_path(chat, job.call.call)) }
		node, parent_call := tool_job_record_placement(chat, job)
		recorded = chat_record_tool_result(chat, job.call.call, node, parent_call, &result)
	}

	if recorded {
		job.committed = true
		jobs.committed += 1
		if !job.nested { jobs.committed_roots += 1 }
	}
	// The unknown outcome is recorded before the abandonment, so recovery never sees an
	// abandoned call that still has no answer.
	tool_job_abandon(jobs, job)
	if recorded { _observer_tool_result(observer, job.name, &result) }
	tool_result_destroy(&result)
	if !recorded {
		// The answer could not be recorded, so the session's storage failed. Recovery still
		// answers this call from its dispatch entry.
		tool_jobs_latch_stop(jobs, chat)
	}
}

// tool_jobs_refuse answers one queued call that cannot run: the stop earned it a not-executed
// result, or its backend is still held by an abandoned call. The call never dispatched, so
// nothing ran and nothing needs to be undone.
tool_jobs_refuse :: proc(jobs: ^Tool_Jobs) {
	if jobs.stop != .None {
		job := tool_jobs_earliest(jobs, {.Queued})
		if job == nil { return }
		job.result = tool_result_failure(&job.exec, .Not_Executed, "the turn was cancelled before this call ran", "not executed")
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	job := tool_jobs_lane_abandoned(jobs)
	if job == nil { return }
	message := "this tool's server is still running an earlier call that did not stop, so this call was not executed; retry it once that call finishes, or use another tool"
	job.result = tool_result_failure(&job.exec, .Unavailable, message, "server busy")
	job.result_present = true
	job.phase = .Result_Ready
}

// tool_result_report_repairs adds a `repaired:` line after the result's first line. The
// projection replays the corrected arguments, so this line is how the model learns what it
// sent wrong.
@(private, require_results)
tool_result_report_repairs :: proc(result: ^Tool_Result, repairs: Tool_Repairs) -> mem.Allocator_Error {
	if repairs == {} { return nil }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	first, rest := result.content, ""
	if newline := strings.index_byte(result.content, '\n'); newline >= 0 {
		first, rest = result.content[:newline], result.content[newline + 1:]
	}
	names, names_error := tool_repairs_text(repairs, context.temp_allocator)
	if names_error != nil { return names_error }
	content := strings.concatenate({first, "\nrepaired: ", names, " (the arguments you sent were corrected)\n", rest}, result.allocator) or_return
	delete(result.content, result.allocator)
	result.content = content
	return nil
}

// tool_jobs_commit records the earliest uncommitted result. It is the one boundary
// between execution and storage: every observed result crosses it here, so the store
// only ever receives a bounded result.
tool_jobs_commit :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, observer: Chat_Observer) {
	job := tool_jobs_earliest_live(jobs)
	if job == nil || job.phase != .Result_Ready { return }
	job.phase = .Committing

	// The commit takes the result off the job: one owner at a time, and the release here is
	// the only one, so retirement has nothing left to free.
	result := job.result
	job.result = {}
	job.result_present = false
	if result.allocation_failed || tool_result_report_repairs(&result, job.admitted.repairs) != nil {
		tool_result_destroy(&result)
		job.phase = .Retiring
		if jobs.stop == .None { jobs.stop = .Storage_Failed }
		return
	}
	// The budget decides how much of this result the model is shown; the rest goes to a
	// file. The decision is stored, so a request built later sends the same bytes.
	if !job.nested { tool_result_keep(&result, &jobs.budget, chat_tool_output_path(chat, job.call.call)) }
	node, parent_call := tool_job_record_placement(chat, job)
	delegation := journal.Record {
		node        = node,
		request     = chat.request,
		call        = job.call.call,
		parent_call = parent_call,
		subagent    = job.exec.subagent,
	}
	// A call that opened a delegation and started no child closes it with its result. A
	// message was recorded with the call's dispatch, before its recipient could hear of it.
	opened := false
	switch args in job.arguments {
	case Agent_Spawn_Args:
		opened = delegation.subagent != {}
	case Agent_Send_Args:
		opened = args.resume.name != ""
	case Read_Args, Write_Args, Patch_Args, Shell_Args, List_Skills_Args, Load_Skill_Args, Codemode_Args, Agent_Stop_Args:
	case nil:
	}
	if opened && !job.exec.subagent_started {
		delegation.kind = .Subagent_Completed
		completed := journal.Subagent_Completed {
			outcome = journal.TOOL_OUTCOME_NAMES[.Not_Executed],
			detail  = "no subagent started",
		}
		chat_record(chat, delegation, completed, transmute([]u8)result.content)
	}
	if !chat_record_tool_result(chat, job.call.call, node, parent_call, &result) {
		// The result cannot be recorded, so it must not be reported as if it were.
		tool_result_destroy(&result)
		job.phase = .Result_Ready
		tool_jobs_latch_stop(jobs, chat)
		return
	}
	job.committed = true
	jobs.committed += 1
	if !job.nested { jobs.committed_roots += 1 }
	if job.parent != nil {
		codemode_job_child_committed(jobs, job, &result)
	}
	_observer_tool_result(observer, job.name, &result)
	tool_result_destroy(&result)
	job.phase = .Retiring
}

// tool_jobs_retire releases one settled job's execution resources and drops what could
// not be recorded. A job whose worker ignored its stop is abandoned instead; this is the
// only abandon path for a batch that can no longer record anything.
tool_jobs_retire :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, now: time.Tick) {
	job := tool_jobs_retirable(jobs, now)
	if job == nil { return }

	if !tool_job_releasable(job) {
		tool_job_abandon(jobs, job)
		return
	}
	if job.result_present {
		tool_result_destroy(&job.result)
		job.result_present = false
	}
	tool_args_destroy(&job.arguments, job.allocator)
	tool_arguments_destroy(&job.admitted, job.allocator)
	job.phase = job.committed ? .Retired : .Unrecorded
}

// tool_jobs_deadline returns the nearest Lua execution deadline or stop-patience expiry.
@(private)
tool_jobs_deadline :: proc(jobs: ^Tool_Jobs) -> Maybe(time.Tick) {
	earliest: Maybe(time.Tick)
	for job in jobs.jobs {
		if job.phase == .Waiting && job.lua != nil && !job.lua.terminal && job.lua.deadline != {} {
			due := job.lua.deadline
			if existing, has := earliest.?; !has || time.tick_diff(due, existing) < 0 { earliest = due }
		}
		if job.worker.phase != .Running { continue }
		stop_at, stopped := job.worker.stop_at.?
		if !stopped { continue }
		due := time.tick_add(stop_at, TOOL_JOBS_STOP_PATIENCE)
		if existing, has := earliest.?; !has || time.tick_diff(due, existing) < 0 { earliest = due }
	}
	return earliest
}

// tool_jobs_await blocks until a worker publishes, the deadline arrives, or a signal
// interrupts the wait.
@(private)
tool_jobs_await :: proc(jobs: ^Tool_Jobs, deadline: Maybe(time.Tick), seen: u32) {
	if tool_jobs_published(jobs) != nil { return }
	if tool_jobs_next(jobs, time.tick_now()) != .Wait { return }
	owner_wake_wait(seen, deadline)
}

// --- the executor --------------------------------------------------------------

// tool_job_execute runs one admitted call on whichever thread owns the job.
@(private, require_results)
tool_job_execute :: proc(job: ^Tool_Job) -> Tool_Result {
	return job.execute(&job.exec, job.arguments)
}

// tool_job_launch opens the job's stop pipe and starts its worker on the shared Job. It
// returns the pipe's error, or out of memory when the thread could not be created.
@(private, require_results)
tool_job_launch :: proc(job: ^Tool_Job) -> os.Error {
	job.wake = tool_wake_open() or_return
	job.exec.control.wake = job.wake.read
	job.worker = Job {
		kind      = .Tool,
		run       = tool_job_run,
		allocator = job.allocator,
	}
	if !job_launch(&job.worker) { return mem.Allocator_Error.Out_Of_Memory }
	return nil
}

// tool_job_request_stop asks a running job to stop and wakes its worker. A repeat
// is harmless: the request is latched in the job's own token.
@(private)
tool_job_request_stop :: proc(job: ^Tool_Job) {
	ai.interrupt_request(&job.interrupt)
	tool_wake_signal(&job.wake)
}

// tool_job_run executes one call on the job's thread. job_main publishes after it returns.
@(private)
tool_job_run :: proc(worker: ^Job) {
	job := cast(^Tool_Job)worker
	job.result = tool_job_execute(job)
	job.result_present = true
}
