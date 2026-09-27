package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "nabla:agent/session"
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

// TOOL_JOBS_MAX_ACTIVE bounds worker-placed jobs running at once. A Code Mode parent
// never occupies a slot while it waits for its children, so the bound cannot make a
// parent block its own child.
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
	logging:        Log_Binding, // the worker's correlation, captured at admission

	// control
	phase:          Tool_Job_Phase,
	interrupt:      ai.Interrupt, // this job's own stop token
	// wake is a worker job's stop pipe: the owner signals it with the stop request,
	// which wakes a worker sleeping in poll, and closes it when it releases the job.
	wake:           Tool_Wake,
	// published is atomic. The worker sets it after writing result, and the owner reads result
	// only after seeing it.
	published:      bool,
	// launched says a worker thread runs this call; otherwise the job is the owner's alone.
	launched:       bool,
	// thread is created and destroyed by the owner, after the worker published.
	thread:         ^thread.Thread,
	// stopping and stop_at are the owner's observation that this job should have stopped and
	// when that was first seen, which is what the stop patience is measured from.
	stopping:       bool,
	stop_at:        time.Tick,

	// outcome
	result:         Tool_Result,
	result_present: bool,
	committed:      bool,
	// recorded_seq is the entry this job's result was recorded as. It is the
	// committed reference a later reader names, such as a Code Mode handle.
	recorded_seq:   session.Seq,
}

// Tool_Jobs is one batch's table. Only the owner reads and writes it.
Tool_Jobs :: struct {
	jobs:             [dynamic]^Tool_Job,
	allocator:        mem.Allocator, // the session's: it owns the table, not the jobs
	next_id:          u64,
	active:           int, // worker-placed jobs running now
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
	// abandoned is the session's list of jobs whose workers ignored their stop, borrowed.
	// Destroying the table moves its abandoned jobs there, and they block only their own
	// external lane.
	abandoned:        ^[dynamic]^Tool_Job,
}

// --- lifetime ------------------------------------------------------------------

tool_jobs_init :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, capacity: int, worker_allocator: mem.Allocator) {
	jobs.allocator = chat.allocator
	jobs.worker_allocator = worker_allocator
	jobs.abandoned = &chat.abandoned_jobs
	jobs.jobs = make([dynamic]^Tool_Job, 0, capacity, chat.allocator)
	jobs.budget = chat_tool_budget_open(chat, len(chat.pending_calls))
}

// tool_jobs_destroy releases the table and every job no worker can still reach. A job whose
// worker is still running is asked to stop and moves to the session's abandoned list.
tool_jobs_destroy :: proc(jobs: ^Tool_Jobs) {
	tool_jobs_collect(jobs)
	for job in jobs.jobs {
		if job.phase == .Running && job.launched {
			tool_job_request_stop(job)
			tool_jobs_mark_abandoned(jobs, job)
		}
		if job.phase == .Abandoned {
			if jobs.abandoned == nil || append(jobs.abandoned, job) != 1 {
				log_emit({level = .Error, category = .Tool, event = "tool.job_leaked"})
			}
			continue
		}
		tool_job_release(job)
	}
	delete(jobs.jobs)
	jobs^ = {}
}

// tool_jobs_reclaim releases every abandoned job whose worker has since published. Its call
// already has its recorded outcome, so the late result is dropped.
tool_jobs_reclaim :: proc(abandoned: ^[dynamic]^Tool_Job) {
	for index := len(abandoned) - 1; index >= 0; index -= 1 {
		job := abandoned[index]
		if !sync.atomic_load(&job.published) { continue }
		thread.destroy(job.thread)
		job.thread = nil
		fields := [1]Log_Field{{key = "tool", value = job.name}}
		log_emit({level = .Info, category = .Tool, event = "tool.job_reclaimed", fields = fields[:]})
		tool_job_release(job)
		unordered_remove(abandoned, index)
	}
}

// tool_jobs_mark_abandoned gives up waiting for a worker. The job keeps what the worker can
// reach, and gives back its worker slot so the batch can keep running calls.
@(private)
tool_jobs_mark_abandoned :: proc(jobs: ^Tool_Jobs, job: ^Tool_Job) {
	job.phase = .Abandoned
	if job.placement == .Worker { jobs.active -= 1 }
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
@(private)
tool_jobs_publish :: proc(jobs: ^Tool_Jobs, job: ^Tool_Job) -> bool {
	if append(&jobs.jobs, job) != 1 {
		tool_job_release(job)
		if jobs.stop == .None { jobs.stop = .Storage_Failed }
		return false
	}
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
		job.name = strings.clone(staged.name, job.allocator)
		job.call_id = strings.clone(staged.id, job.allocator)
		tool_job_admit(jobs, chat, observer, job)
		if !tool_jobs_publish(jobs, job) { return }
	}
}

// tool_job_admit resolves one call and either queues it for execution or produces the
// result that refuses it. It performs no durable write: a refused call is a call that
// never dispatched, and the record says so by having no dispatch entry.
@(private)
tool_job_admit :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, observer: Chat_Observer, job: ^Tool_Job) {
	job.logging = tool_job_logging(job, chat)
	// Admission is the owner's, so every record it makes belongs to this call rather
	// than to the batch. The binding lives in the job, so the logger the frame leaves
	// behind points at storage that outlives it.
	previous := context.logger
	context.logger = log_logger(&job.logging)
	defer context.logger = previous

	job.exec = Tool_Context {
		call_id    = job.call_id,
		workspace  = chat.workspace,
		allocator  = job.allocator,
		skills     = chat_skill_catalog(chat),
		source_seq = job.call.seq,
	}
	if job.call.seq > 0 {
		job.output_base = chat_tool_output_path(chat, i64(job.call.seq), "", job.allocator)
		job.exec.output_base = job.output_base
	}
	received := [2]Log_Field{{key = "tool", value = job.name}, {key = "arguments_bytes", value = i64(len(job.call.arguments))}}
	log_emit({level = .Info, category = .Tool, event = "tool.call_received", fields = received[:]})
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
	repairs_text := tool_repairs_text(job.admitted.repairs, context.temp_allocator)
	prepared := [4]Log_Field {
		{key = "tool", value = job.name},
		{key = "status", value = tool_arguments_status_name(job.admitted.status)},
		{key = "repairs", value = repairs_text},
		{key = "effective_bytes", value = i64(len(job.admitted.effective))},
	}
	log_emit({level = .Debug, category = .Tool, event = "tool.arguments_prepared", fields = prepared[:]})

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
		notice := fmt.tprintf("a tool call was repaired before it ran: %s", tool_repairs_text(job.admitted.repairs, context.temp_allocator))
		_observer_message(observer, .Notice, notice)
	}
	// What the call runs with is the text the dispatch record holds, so an executor
	// that forwards the call cannot send something other than what was recorded.
	job.exec.arguments_json = job.admitted.effective
}

// tool_job_logging captures the owner's log destination for one call, because a worker
// thread has no context to inherit and would otherwise log nowhere.
@(private)
tool_job_logging :: proc(job: ^Tool_Job, chat: ^Chat_Session) -> Log_Binding {
	active := context.logger
	if active.procedure != log_procedure { return {} }
	source := cast(^Log_Binding)active.data
	if source == nil || source.sink == nil { return {} }
	return Log_Binding{sink = source.sink, correlation = log_correlation_for_call(chat, job.call_id)}
}

// --- decisions -----------------------------------------------------------------

// tool_jobs_observe applies what happened outside the batch to its state: workers that
// published a result, a stop the session asked for, and the owner's first sight of a
// call that should have stopped. It is the only place those facts enter the table, so
// tool_jobs_next can read the table without changing it.
tool_jobs_observe :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, now: time.Tick) {
	tool_jobs_collect(jobs)
	tool_jobs_latch_stop(jobs, chat)
	tool_jobs_note_stops(jobs, now)
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
	if tool_jobs_runnable(jobs) != nil { return .Dispatch }
	if !tool_jobs_settled(jobs) { return .Wait }
	return .Done
}

// tool_job_under_executor reports whether a call is in one of the two phases where the owner
// still watches for a stop it asked for: the dispatch write, or an executor running the call.

@(private)
tool_job_under_executor :: proc(job: ^Tool_Job) -> bool {
	switch job.phase {
	case .Dispatching, .Running:
		return true
	case .Queued, .Waiting, .Result_Ready, .Committing, .Retiring, .Retired, .Unrecorded, .Abandoned:
	}
	return false
}

// tool_jobs_note_stops records when the owner first saw that a job should have stopped.
// The stop itself was requested by tool_jobs_latch_stop or by the job's own timeout; this
// is what makes the patience measurable without a clock read inside a transition's
// decision. Only a call a worker owns can outlive its stop.
@(private)
tool_jobs_note_stops :: proc(jobs: ^Tool_Jobs, now: time.Tick) {
	for job in jobs.jobs {
		if job.stopping || !job.launched || !tool_job_under_executor(job) { continue }
		if !tool_control_cancelled(job.exec.control) { continue }
		job.stopping = true
		job.stop_at = now
		fields := [2]Log_Field{{key = "tool", value = job.name}, {key = "patience_ms", value = Log_Duration_Milliseconds(TOOL_JOBS_STOP_PATIENCE)}}
		log_emit({level = .Warning, category = .Tool, event = "tool.stop_requested", fields = fields[:]})
	}
}

// tool_jobs_overdue returns the earliest running job that was asked to stop and has not. It
// is the call the owner can no longer wait for.
@(private)
tool_jobs_overdue :: proc(jobs: ^Tool_Jobs, now: time.Tick) -> ^Tool_Job {
	found: ^Tool_Job
	for job in jobs.jobs {
		if !tool_job_under_executor(job) { continue }
		if !job.launched || !job.stopping || time.tick_diff(job.stop_at, now) < TOOL_JOBS_STOP_PATIENCE { continue }
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
		if !tool_job_releasable(job) && !tool_jobs_stopped_long_enough(job, now) { continue }
		if found == nil || job.ordinal < found.ordinal { found = job }
	}
	return found
}

// tool_job_releasable reports whether no worker can still reach the job. A launched job
// leaves Running only when collection joined its worker or when it is abandoned.
@(private)
tool_job_releasable :: proc(job: ^Tool_Job) -> bool {
	return !job.launched || job.phase != .Running
}

@(private)
tool_jobs_stopped_long_enough :: proc(job: ^Tool_Job, now: time.Tick) -> bool {
	return job.stopping && time.tick_diff(job.stop_at, now) >= TOOL_JOBS_STOP_PATIENCE
}

// tool_jobs_published returns the earliest running job whose worker has published.
@(private)
tool_jobs_published :: proc(jobs: ^Tool_Jobs) -> ^Tool_Job {
	for job in jobs.jobs {
		if job.phase == .Running && sync.atomic_load(&job.published) { return job }
	}
	return nil
}

// tool_jobs_collect adopts published results and joins their workers, which is the proof
// that nothing else reaches the job.
@(private)
tool_jobs_collect :: proc(jobs: ^Tool_Jobs) {
	for job := tool_jobs_published(jobs); job != nil; job = tool_jobs_published(jobs) {
		thread.destroy(job.thread)
		job.thread = nil
		job.phase = .Result_Ready
		if job.placement == .Worker { jobs.active -= 1 }
	}
}

// tool_jobs_runnable returns the earliest queued job whose lane is free and whose
// placement can start now, or nil when the queue is waiting.
@(private)
tool_jobs_runnable :: proc(jobs: ^Tool_Jobs) -> ^Tool_Job {
	for job in jobs.jobs {
		if job.phase != .Queued { continue }
		if !tool_jobs_lane_free(jobs, job) { continue }
		if job.placement == .Worker && jobs.active >= TOOL_JOBS_MAX_ACTIVE { continue }
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
@(private)
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
		if jobs.abandoned == nil { continue }
		for other in jobs.abandoned {
			if other.lane == job.lane { return job }
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
		reason := candidate == .Storage_Failed ? "storage_failed" : "cancelled"
		fields := [1]Log_Field{{key = "reason", value = reason}}
		log_emit({level = .Info, category = .Tool, event = "tool.batch_stopping", fields = fields[:]})
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

// tool_jobs_dispatch records one call's dispatch entry and starts its executor. The
// write comes first: a dispatch entry without a result is recovered as an unknown
// outcome, while a result without a dispatch entry would claim knowledge the harness
// does not have.
tool_jobs_dispatch :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session) {
	job := tool_jobs_runnable(jobs)
	if job == nil { return }
	if job.placement == .Lua && job.lua_dispatched {
		tool_job_lua_resume(jobs, chat, job)
		return
	}
	previous := context.logger
	context.logger = log_logger(&job.logging)
	defer context.logger = previous
	job.phase = .Dispatching

	dispatch := session.New_Entry {
		turn_no = chat.turn_no,
		request_no = chat.active_request,
		created_at_ms = session.now_ms(),
		related_seq = job.call.seq,
		payload = session.Tool_Dispatch_Entry{tool = job.name, arguments = job.admitted.effective, repairs = job.admitted.repairs},
	}
	dispatch_seq, dispatch_error := session.entry_append(chat.store, chat.id, dispatch)
	if dispatch_error != nil {
		chat_session_record_failure(chat, "the tool dispatch could not be recorded", dispatch_error)
		tool_jobs_latch_stop(jobs, chat)
		return
	}
	dispatched := [2]Log_Field{{key = "tool", value = job.name}, {key = "dispatch_seq", value = i64(dispatch_seq)}}
	log_emit({level = .Info, category = .Tool, event = "tool.dispatch_committed", fields = dispatched[:]})

	// Cancellation can land after the intent was recorded but before execution
	// begins. The intent is durable, but the call never started.
	if tool_control_cancelled(job.exec.control) {
		job.result = tool_result_failure(&job.exec, .Not_Executed, "the turn was cancelled before this call ran", "not executed")
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
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

// tool_jobs_abandon answers a call that ignored its stop with an unknown outcome and retains
// its job: the worker may still be running and may still publish into it.
tool_jobs_abandon :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, observer: Chat_Observer, now: time.Tick) {
	job := tool_jobs_overdue(jobs, now)
	if job == nil { return }
	previous := context.logger
	context.logger = log_logger(&job.logging)
	defer context.logger = previous

	if sync.atomic_load(&job.published) { return }
	message := fmt.tprintf("the tool did not stop within %v of its stop being requested; its outcome is unknown", TOOL_JOBS_STOP_PATIENCE)
	result := tool_result_failure(&job.exec, .Unknown, message, "did not stop")
	result_seq: session.Seq
	recorded := false
	if !result.allocation_failed {
		if !job.nested { tool_result_keep(&result, &jobs.budget, chat_tool_output_path(chat, i64(job.call.seq))) }
		result_seq, recorded = chat_record_tool_result(chat, job.call, &result)
	}

	tool_jobs_mark_abandoned(jobs, job)
	if recorded {
		job.committed = true
		job.recorded_seq = result_seq
		jobs.committed += 1
		if !job.nested { jobs.committed_roots += 1 }
	}
	waited := time.tick_diff(job.stop_at, now)
	fields := [3]Log_Field {
		{key = "tool", value = job.name},
		{key = "outcome", value = session.tool_outcome_name(.Unknown)},
		{key = "waited_ms", value = i64(waited / time.Millisecond)},
	}
	log_emit({level = .Error, category = .Tool, event = "tool.job_stuck", fields = fields[:]})
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

// tool_jobs_commit records the earliest uncommitted result. It is the one boundary
// between execution and storage: every observed result crosses it here, so the store
// only ever receives a bounded result.
tool_jobs_commit :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, observer: Chat_Observer) {
	job := tool_jobs_earliest_live(jobs)
	if job == nil || job.phase != .Result_Ready { return }
	previous := context.logger
	context.logger = log_logger(&job.logging)
	defer context.logger = previous
	job.phase = .Committing

	// The commit takes the result off the job: one owner at a time, and the release here is
	// the only one, so retirement has nothing left to free.
	result := job.result
	job.result = {}
	job.result_present = false
	if result.allocation_failed {
		tool_result_destroy(&result)
		job.phase = .Retiring
		if jobs.stop == .None { jobs.stop = .Storage_Failed }
		return
	}
	// The budget decides how much of this result the model is shown; the rest goes to a
	// file. The decision is stored, so a request built later sends the same bytes.
	if !job.nested { tool_result_keep(&result, &jobs.budget, chat_tool_output_path(chat, i64(job.call.seq))) }
	result_seq, recorded := chat_record_tool_result(chat, job.call, &result)
	if !recorded {
		// The result cannot be recorded, so it must not be reported as if it were.
		tool_result_destroy(&result)
		job.phase = .Result_Ready
		tool_jobs_latch_stop(jobs, chat)
		return
	}
	job.committed = true
	job.recorded_seq = result_seq
	jobs.committed += 1
	if !job.nested { jobs.committed_roots += 1 }
	if job.parent != nil {
		codemode_job_child_committed(jobs, job, &result)
	}

	committed := [3]Log_Field {
		{key = "tool", value = job.name},
		{key = "outcome", value = session.tool_outcome_name(result.outcome)},
		{key = "result_seq", value = i64(result_seq)},
	}
	log_emit({level = .Info, category = .Tool, event = "tool.result_committed", fields = committed[:]})
	_observer_tool_result(observer, job.name, &result)
	tool_result_destroy(&result)
	job.phase = .Retiring
}

// tool_jobs_retire releases one settled job's execution resources and drops what could
// not be recorded. A job whose worker ignored its stop is abandoned instead; this is the
// only abandon path for a batch that can no longer record anything.
tool_jobs_retire :: proc(jobs: ^Tool_Jobs, now: time.Tick) {
	job := tool_jobs_retirable(jobs, now)
	if job == nil { return }

	if !tool_job_releasable(job) {
		tool_jobs_mark_abandoned(jobs, job)
		waited := time.tick_diff(job.stop_at, now)
		fields := [3]Log_Field {
			{key = "tool", value = job.name},
			{key = "outcome", value = session.tool_outcome_name(.Unknown)},
			{key = "waited_ms", value = i64(waited / time.Millisecond)},
		}
		log_emit({level = .Error, category = .Tool, event = "tool.job_stuck", fields = fields[:]})
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

// tool_jobs_deadline is the nearest stop-patience expiry among calls the owner still waits
// for, or nil when only a worker can change the table.
@(private)
tool_jobs_deadline :: proc(jobs: ^Tool_Jobs) -> Maybe(time.Tick) {
	earliest: Maybe(time.Tick)
	for job in jobs.jobs {
		if !job.launched || !job.stopping || !tool_job_under_executor(job) { continue }
		due := time.tick_add(job.stop_at, TOOL_JOBS_STOP_PATIENCE)
		if existing, has := earliest.?; !has || time.tick_diff(due, existing) < 0 { earliest = due }
	}
	return earliest
}

// tool_jobs_await blocks until a worker publishes, the deadline arrives, or a signal
// interrupts the wait.
@(private)
tool_jobs_await :: proc(jobs: ^Tool_Jobs, deadline: Maybe(time.Tick)) {
	seen := owner_wake_seen()
	if tool_jobs_published(jobs) != nil { return }
	if tool_jobs_next(jobs, time.tick_now()) != .Wait { return }
	owner_wake_wait(seen, deadline)
}

// --- the executor --------------------------------------------------------------

// tool_job_execute runs one admitted call and logs what it observed. It runs on
// whichever thread owns the job, so every record it makes carries the job's own
// correlation rather than the caller's.
@(private)
tool_job_execute :: proc(job: ^Tool_Job) -> Tool_Result {
	previous := context.logger
	context.logger = log_logger(&job.logging)
	defer context.logger = previous
	started := [1]Log_Field{{key = "tool", value = job.name}}
	log_emit({level = .Info, category = .Tool, event = "tool.execution_started", fields = started[:]})
	result := job.execute(&job.exec, job.arguments)
	finished := [2]Log_Field{{key = "tool", value = job.name}, {key = "outcome", value = session.tool_outcome_name(result.outcome)}}
	log_emit({level = .Info, category = .Tool, event = "tool.execution_finished", fields = finished[:]})
	return result
}

// tool_job_launch starts one worker-placed job. The watched signals are blocked across
// creation so the worker inherits a mask that keeps it from running the process handler.
@(private)
tool_job_launch :: proc(job: ^Tool_Job) -> os.Error {
	job.wake = tool_wake_open() or_return
	job.exec.control.wake = job.wake.read
	previous := chat_signal_block_watched()
	worker := thread.create(tool_job_worker, name = "nabla-tool")
	chat_signal_restore(previous)
	if worker == nil { return mem.Allocator_Error.Out_Of_Memory }
	worker.data = job
	job.thread = worker
	thread.start(worker)
	job.launched = true
	return nil
}

// tool_job_request_stop asks a running job to stop and wakes its worker. A repeat
// is harmless: the request is latched in the job's own token.
@(private)
tool_job_request_stop :: proc(job: ^Tool_Job) {
	ai.interrupt_request(&job.interrupt)
	tool_wake_signal(&job.wake)
}

// tool_job_worker runs one call and publishes its result. It touches nothing after the wake.
@(private)
tool_job_worker :: proc(worker: ^thread.Thread) {
	job := cast(^Tool_Job)worker.data
	context.allocator = job.allocator
	context.logger = log_logger(&job.logging)

	job.result = tool_job_execute(job)
	job.result_present = true
	sync.atomic_store(&job.published, true)
	owner_wake_signal()
}
