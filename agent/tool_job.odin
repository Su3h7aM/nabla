package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
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
// Only the owner changes a phase and only the owner writes history. A worker
// publishes exactly one fact, its result, under the table's mutex, and exits; the
// owner adopts that fact into a phase. Nothing else crosses the boundary, so a worker
// never touches the session, the store, or another job.
//
// The table's records are allocated one at a time and never move, because an effect
// names a job and a running worker holds that address.

// TOOL_JOBS_MAX_ACTIVE bounds worker-placed jobs running at once. A Code Mode parent
// never occupies a slot while it waits for its children, so the bound cannot make a
// parent block its own child.
TOOL_JOBS_MAX_ACTIVE :: 4

// TOOL_JOBS_MAX bounds one model batch: how many calls a single response may commit.
// The model-facing limit on calls per response is smaller; this is the harness's own
// ceiling on the records it will hold for one response.
TOOL_JOBS_MAX :: 64

// TOOL_JOBS_MAX_ADMISSIONS bounds every admission in one batch, outer calls and Code
// Mode children together. The table keeps released jobs until the batch ends, so this
// is what bounds a script that makes many sequential calls, and it is deliberately
// larger than TOOL_JOBS_MAX: a script whose whole point is to loop over a directory must
// not run out of room at the size of one model response.
TOOL_JOBS_MAX_ADMISSIONS :: 256

// TOOL_JOBS_WAIT is how long the owner sleeps when no job is runnable. It bounds how
// late a turn cancellation is noticed after the last completion, in the same way the
// transport's wait slice bounds it during a request.
TOOL_JOBS_WAIT :: 50 * time.Millisecond

// TOOL_JOBS_STOP_PATIENCE is how long a call may keep running after its stop was asked for,
// by the turn's cancellation or by its own timeout. A backend that never returns cannot be
// stopped cooperatively, so past this the owner stops waiting: the call is answered with the
// outcome the harness can observe, and the job is handed to its worker, which releases it
// when it returns. Only process isolation can bound arbitrary native code harder.
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
	// Stuck: the owner stopped waiting and handed the job to its worker, which releases
	// it when it returns. The owner never touches a stuck job again, and nothing else may
	// either: the worker is the only owner left.
	Stuck,
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
	// Refuse: give a queued call the not-executed result the stop earned it.
	Refuse,
	// Abandon: answer a call that ignored its stop with what the harness observed, and hand
	// its job to the worker that is still running it.
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

// Lua_Call_Summary is one child call a Code Mode execution made, as its parent reports
// it. child is borrowed and stays valid until the batch is destroyed, because a released
// job keeps its record and its name until then.
Lua_Call_Summary :: struct {
	child:   ^Tool_Job,
	seq:     session.Seq,
	outcome: session.Tool_Outcome,
}

// Tool_Job is one admitted call.
Tool_Job :: struct {
	// identity, owned by the table and stable for the job's life
	id:               u64,
	turn_id:          u64,
	ordinal:          int, // submission order, which is the order results are recorded in
	call:             ^Chat_Tool_Call, // borrowed: the session's staged calls outlive the batch
	table:            ^Tool_Jobs, // borrowed: where this job publishes completion
	name:             string, // owned by allocator
	call_id:          string, // owned by allocator

	// placement
	placement:        Tool_Placement,
	lane:             rawptr, // borrowed backend identity; nil is the shared native lane
	execute:          Tool_Execute,

	// Lua execution data. A nested call is embedded in its child job so the call
	// pointer stays stable when the table grows. lua_calls is what the parent reports
	// about the children it ran: the owner appends one entry as each child commits, and
	// the parent's result carries them so a model can audit a script and reach one
	// child's full result by its sequence.
	lua:              ^Lua_Run,
	lua_dispatched:   bool,
	lua_child_no:     int,
	lua_child:        ^Tool_Job,
	lua_child_result: string, // owned by allocator until delivered
	lua_calls:        [dynamic]Lua_Call_Summary,
	lua_calls_total:  int,
	parent:           ^Tool_Job,
	nested_call:      Chat_Tool_Call,
	nested:           bool,

	// execution data, owned by allocator, which is a thread-safe heap
	allocator:        mem.Allocator,
	arguments:        Tool_Arguments,
	exec:             Tool_Context, // what the executor is given, for the job's whole life
	logging:          Log_Binding, // the worker's correlation, captured at admission

	// control
	phase:            Tool_Job_Phase,
	interrupt:        ai.Interrupt, // this job's own stop token
	// mu guards what separates the owner from the worker that runs this job: the published
	// result, whether the worker is done, and whether the owner handed the job back. It
	// lives in the job rather than in the table because the worker keeps it after the batch
	// is gone, and the table is the owner's.
	mu:               sync.Mutex,
	// published is set by the worker once it has finished with this job, and the owner never
	// clears it: it is what says a released job's storage is the owner's again.
	published:        bool,
	// launched says a worker thread owns this call. A job that never started one, an
	// owner-placed operation or a Lua execution, is the owner's for its whole life.
	launched:         bool,
	// adopted is the owner's record that it took the published result into its own care.
	adopted:          bool,
	// orphan is the owner's handoff: the worker releases this job itself.
	orphan:           bool,
	// stopping and stop_at are the owner's observation that this job should have stopped and
	// when that was first seen, which is what the stop patience is measured from.
	stopping:         bool,
	stop_at:          time.Tick,

	// outcome
	result:           Tool_Result,
	result_present:   bool,
	committed:        bool,
	// recorded_seq is the entry this job's result was recorded as. It is the
	// committed reference a later reader names, such as a Code Mode handle.
	recorded_seq:     session.Seq,
}

// Tool_Jobs is one batch's table. The owner reads and writes it; a worker only ever
// publishes its own completion, under the mutex.
Tool_Jobs :: struct {
	jobs:             [dynamic]^Tool_Job,
	allocator:        mem.Allocator, // the session's: it owns the table, not the jobs
	mutex:            sync.Mutex,
	cond:             sync.Cond,
	// woken is set by a worker when it publishes, so the owner never sleeps past a
	// completion that arrived between its decision and its wait.
	woken:            bool,
	next_id:          u64,
	admitted:         int, // every admission in this batch, outer calls and children
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
	// render is the reader owner-placed tools use to read kept results back. It lives
	// here, not in a frame, so a job can borrow it for its whole life.
	render:           Result_Reader,
}

// --- lifetime ------------------------------------------------------------------

tool_jobs_init :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, capacity: int, worker_allocator: mem.Allocator) {
	jobs.allocator = chat.allocator
	jobs.worker_allocator = worker_allocator
	bounded := capacity
	if bounded > TOOL_JOBS_MAX { bounded = TOOL_JOBS_MAX }
	jobs.jobs = make([dynamic]^Tool_Job, 0, bounded, chat.allocator)
	jobs.render = Result_Reader {
		store      = chat.store,
		session_id = chat.id,
	}
	jobs.budget = chat_tool_budget_open(chat, len(chat.pending_calls))
}

// tool_jobs_destroy releases the table and everything still in it. A job the owner handed
// to its worker is not freed here: that worker releases it when it returns, and this table
// is then the last thing the batch's owner releases.
tool_jobs_destroy :: proc(jobs: ^Tool_Jobs) {
	for job in jobs.jobs {
		if job.phase == .Stuck { continue }
		tool_job_release(job)
	}
	delete(jobs.jobs)
	jobs^ = {}
}

// tool_job_release frees everything one job owns. The job struct and its data come from the
// worker allocator, which is the process heap in production: a worker releases a job the
// owner handed back, so that storage has to outlive the batch.
@(private)
tool_job_release :: proc(job: ^Tool_Job) {
	if job.lua != nil { code_mode_lua_destroy(job.lua) }
	delete(job.lua_calls)
	delete(job.lua_child_result, job.allocator)
	if job.nested {
		delete(job.nested_call.id, job.allocator)
		delete(job.nested_call.item_id, job.allocator)
		delete(job.nested_call.name, job.allocator)
		delete(job.nested_call.arguments, job.allocator)
	}
	tool_arguments_destroy(&job.arguments, job.allocator)
	if job.result_present { tool_result_destroy(&job.result) }
	delete(job.name, job.allocator)
	delete(job.call_id, job.allocator)
	mem.free(job, job.allocator)
}

tool_jobs_committed :: proc(jobs: ^Tool_Jobs) -> int { return jobs.committed_roots }

// tool_jobs_settled reports whether every job is released, which is what ends the
// batch's loop. A job the owner handed to its worker is settled: waiting for it again is
// exactly what the stop patience exists to avoid.
tool_jobs_settled :: proc(jobs: ^Tool_Jobs) -> bool {
	for job in jobs.jobs {
		switch job.phase {
		case .Queued, .Dispatching, .Running, .Waiting, .Result_Ready, .Committing, .Retiring:
			return false
		case .Retired, .Unrecorded, .Stuck:
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
// released. Results are recorded in submission order, which is the order the response
// asked its calls in, so the context budget is spent the way the model asked for it
// and a request built later sends the same batch in the same order.
@(private)
tool_jobs_earliest_live :: proc(jobs: ^Tool_Jobs) -> ^Tool_Job {
	found: ^Tool_Job
	for job in jobs.jobs {
		switch job.phase {
		case .Retired, .Unrecorded, .Stuck:
			continue
		case .Waiting:
			if job.lua_child != nil { return job.lua_child }
			continue
		case .Queued, .Dispatching, .Running, .Result_Ready, .Committing, .Retiring:
		}
		if found == nil || job.ordinal < found.ordinal { found = job }
	}
	return found
}

// --- submission ----------------------------------------------------------------

// tool_jobs_submit admits the calls a response committed into jobs. Admission is the
// owner's work: it resolves the definition, admits the arguments, and turns anything
// that cannot run into a result now, so the batch only ever executes admitted calls.
tool_jobs_submit :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, observer: Chat_Observer) {
	for &staged in chat.pending_calls {
		if len(jobs.jobs) >= TOOL_JOBS_MAX { return }
		job, alloc_err := mem.new(Tool_Job, jobs.worker_allocator)
		if alloc_err != nil { return }
		job^ = {
			id        = jobs.next_id,
			turn_id   = chat.active_turn_id,
			ordinal   = len(jobs.jobs),
			call      = &staged,
			table     = jobs,
			placement = .Worker,
			phase     = .Queued,
			allocator = jobs.worker_allocator,
		}
		jobs.next_id += 1
		jobs.admitted += 1
		job.name = strings.clone(staged.name, job.allocator)
		job.call_id = strings.clone(staged.id, job.allocator)
		tool_job_admit(jobs, chat, observer, job)
		append(&jobs.jobs, job)
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
	received := [2]Log_Field{{key = "tool", value = job.name}, {key = "arguments_bytes", value = i64(len(job.call.arguments))}}
	log_emit({level = .Info, category = .Tool, event = "tool.call_received", fields = received[:]})

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
	job.lane = definition.backend
	job.execute = definition.execute
	job.exec.timeouts = definition.timeouts
	job.exec.backend = definition.backend
	job.exec.control = tool_control_with_timeout({interrupt = &job.interrupt, parent = &chat_cancel}, definition.timeouts.default)
	// A worker must not reach the session's storage, and it does not have to: the
	// tools that read a kept result or change the context are owner-placed.
	if definition.placement == .Owner {
		job.exec.compact = &chat.compact
		job.exec.results = &jobs.render
	}

	job.arguments = tool_arguments_prepare(job.call.arguments, job.allocator)
	prepared := [4]Log_Field {
		{key = "tool", value = job.name},
		{key = "status", value = tool_arguments_status_name(job.arguments.status)},
		{key = "repair", value = session.tool_repair_name(job.arguments.repair)},
		{key = "effective_bytes", value = i64(len(job.arguments.effective))},
	}
	log_emit({level = .Debug, category = .Tool, event = "tool.arguments_prepared", fields = prepared[:]})

	if job.arguments.status == .Rejected {
		job.result = tool_result_refused(&job.exec, &job.arguments.error)
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	if job.arguments.repair != .None {
		_observer_message(observer, .Notice, "a tool call was repaired before it ran: a raw control character was escaped")
	}
	if _, is_object := job.arguments.value.(json.Object); !is_object {
		job.result = tool_result_failure(&job.exec, .Invalid_Arguments, "the arguments are not a JSON object", "invalid arguments")
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	// What the call runs with is the text the dispatch record holds, so an executor
	// that forwards the call cannot send something other than what was recorded.
	job.exec.arguments_json = job.arguments.effective
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
	if tool_jobs_earliest(jobs, {.Dispatching, .Running}) != nil && tool_jobs_overdue(jobs, now) != nil { return .Abandon }
	if tool_jobs_retirable(jobs, now) != nil { return .Retire }
	if tool_jobs_runnable(jobs) != nil { return .Dispatch }
	if !tool_jobs_settled(jobs) { return .Wait }
	return .Done
}

// tool_jobs_note_stops records when the owner first saw that a job should have stopped.
// The stop itself was requested by tool_jobs_latch_stop or by the job's own timeout; this
// is what makes the patience measurable without a clock read inside a transition's
// decision. Only a call a worker owns can outlive its stop.
@(private)
tool_jobs_note_stops :: proc(jobs: ^Tool_Jobs, now: time.Tick) {
	for job in jobs.jobs {
		if job.stopping || !job.launched { continue }
		switch job.phase {
		case .Dispatching, .Running:
		case .Queued, .Waiting, .Result_Ready, .Committing, .Retiring, .Retired, .Unrecorded, .Stuck:
			continue
		}
		if !tool_control_cancelled(job.exec.control) { continue }
		job.stopping = true
		job.stop_at = now
		fields := [2]Log_Field{{key = "tool", value = job.name}, {key = "patience_ms", value = log_duration_ms(TOOL_JOBS_STOP_PATIENCE)}}
		log_emit({level = .Warning, category = .Tool, event = "tool.stop_requested", fields = fields[:]})
	}
}

// tool_jobs_overdue returns the earliest running job that was asked to stop and has not. It
// is the call the owner can no longer wait for.
@(private)
tool_jobs_overdue :: proc(jobs: ^Tool_Jobs, now: time.Tick) -> ^Tool_Job {
	found: ^Tool_Job
	for job in jobs.jobs {
		switch job.phase {
		case .Dispatching, .Running:
		case .Queued, .Waiting, .Result_Ready, .Committing, .Retiring, .Retired, .Unrecorded, .Stuck:
			continue
		}
		if !job.launched || !job.stopping || time.tick_diff(job.stop_at, now) < TOOL_JOBS_STOP_PATIENCE { continue }
		if found == nil || job.ordinal < found.ordinal { found = job }
	}
	return found
}

// tool_jobs_retirable returns the earliest job the owner can release or hand back now: one
// whose worker published, or one that ignored its stop long enough to be the worker's.
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

// tool_job_releasable reports whether the owner may release a job's storage: the job never
// started a worker, or its worker finished with it. Reading it takes the job's own mutex,
// which the worker holds until it is done with the job's fields.
@(private)
tool_job_releasable :: proc(job: ^Tool_Job) -> bool {
	if !job.launched { return true }
	sync.mutex_lock(&job.mu)
	defer sync.mutex_unlock(&job.mu)
	return job.published
}

@(private)
tool_jobs_stopped_long_enough :: proc(job: ^Tool_Job, now: time.Tick) -> bool {
	return job.stopping && time.tick_diff(job.stop_at, now) >= TOOL_JOBS_STOP_PATIENCE
}

// tool_jobs_collect adopts what the workers published. It is the only place a phase
// moves out of Running, and it reads a job's result under that job's own mutex, which is
// where the worker publishes it.
@(private)
tool_jobs_collect :: proc(jobs: ^Tool_Jobs) {
	for job in jobs.jobs {
		sync.mutex_lock(&job.mu)
		if !job.published || job.adopted || job.phase != .Running {
			sync.mutex_unlock(&job.mu)
			continue
		}
		job.adopted = true
		job.phase = .Result_Ready
		sync.mutex_unlock(&job.mu)
		if job.placement == .Worker && jobs.active > 0 { jobs.active -= 1 }
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
// job that was already released.
@(private)
tool_jobs_lane_free :: proc(jobs: ^Tool_Jobs, candidate: ^Tool_Job) -> bool {
	for job in jobs.jobs {
		if job == candidate || job.lane != candidate.lane { continue }
		switch job.phase {
		case .Dispatching, .Running, .Stuck:
			return false
		case .Queued, .Waiting, .Result_Ready, .Committing, .Retiring, .Retired, .Unrecorded:
		}
	}
	return true
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
		if job.phase == .Running { ai.interrupt_request(&job.interrupt) }
		if job.placement == .Lua && job.lua != nil {
			code_mode_lua_request_stop(job.lua)
			if job.phase == .Queued && candidate == .Cancelled {
				job.result = tool_result_failure(&job.exec, .Cancelled, "the Code Mode execution was cancelled", "cancelled")
				job.result_present = true
				job.phase = .Result_Ready
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
		tool_job_lua_resume(jobs, chat, job, job.lua_child_result != "")
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
		payload = session.Tool_Dispatch_Entry{tool = job.name, arguments = job.arguments.effective, repair = job.arguments.repair},
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
	if !tool_job_launch(job) {
		// A thread that could not start is a backend the harness could not run. The
		// dispatch entry stands, so the outcome is recorded honestly.
		job.result = tool_result_failure(&job.exec, .Tool_Failed, "the tool could not be started", "not started")
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	job.phase = .Running
	jobs.active += 1
}

// tool_jobs_abandon answers a call that ignored its stop and hands its job to the worker
// that is still running it. The answer is what the harness can honestly observe: the call
// dispatched and no result arrived, so its outcome is unknown rather than cancelled.
//
// The job's own mutex is held for the whole step, because the worker publishes through it:
// taking the lock is what makes "the worker has not published" a decision instead of a
// guess. It is the last thing the owner does with this job, so the worker may take over the
// job's storage as soon as it can lock the mutex and read orphan.
tool_jobs_abandon :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, observer: Chat_Observer, now: time.Tick) {
	job := tool_jobs_overdue(jobs, now)
	if job == nil { return }
	previous := context.logger
	context.logger = log_logger(&job.logging)
	defer context.logger = previous

	sync.mutex_lock(&job.mu)
	if job.published {
		// The worker published while the patience ran out: its result is the answer.
		sync.mutex_unlock(&job.mu)
		return
	}
	message := fmt.tprintf("the tool did not stop within %v of its stop being requested; its outcome is unknown", TOOL_JOBS_STOP_PATIENCE)
	finalized := tool_result_finalize(&job.exec, tool_result_failure(&job.exec, .Unknown, message, "did not stop"))
	spilled := false
	if !job.nested { spilled = !tool_budget_take(&jobs.budget, finalized.content) }
	result_seq, recorded := chat_record_tool_result(chat, job.call, &finalized, spilled)

	// From here the worker owns this job: it releases everything the job holds when it
	// returns, which is what keeps a call that ignores its stop from leaking its storage.
	job.orphan = true
	job.phase = .Stuck
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
	_observer_tool_result(observer, job.name, &finalized)
	sync.mutex_unlock(&job.mu)
	tool_result_destroy(&finalized)
	if !recorded {
		// The answer could not be recorded, so the session's storage failed. Recovery still
		// answers this call from its dispatch entry.
		tool_jobs_latch_stop(jobs, chat)
	}
}

// tool_jobs_refuse gives one queued call the result the stop earned it. The call never
// dispatched, so nothing ran and nothing needs to be undone.
tool_jobs_refuse :: proc(jobs: ^Tool_Jobs) {
	job := tool_jobs_earliest(jobs, {.Queued})
	if job == nil { return }
	job.result = tool_result_failure(&job.exec, .Not_Executed, "the turn was cancelled before this call ran", "not executed")
	job.result_present = true
	job.phase = .Result_Ready
}

// tool_jobs_commit records the earliest uncommitted result. It is the one boundary
// between execution and storage: every observed result crosses it here, so the store
// only ever receives a valid bounded envelope.
tool_jobs_commit :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, observer: Chat_Observer) {
	job := tool_jobs_earliest_live(jobs)
	if job == nil || job.phase != .Result_Ready { return }
	previous := context.logger
	context.logger = log_logger(&job.logging)
	defer context.logger = previous
	job.phase = .Committing

	// The commit takes the result off the job: one owner at a time. What comes back
	// shares the envelope's strings except when a violation was replaced, and it is
	// the single release for all of them, so retirement has nothing left to free.
	result := job.result
	job.result = {}
	job.result_present = false
	finalized := tool_result_finalize(&job.exec, result)
	// The budget decides whether the model is shown this result or a handle for it.
	// The decision is made once, here, and stored: a request built later sends the
	// same bytes however much the context has grown by then.
	spilled := false
	if !job.nested { spilled = !tool_budget_take(&jobs.budget, finalized.content) }
	result_seq, recorded := chat_record_tool_result(chat, job.call, &finalized, spilled)
	if !recorded {
		// The result cannot be recorded, so it must not be reported as if it were.
		tool_result_destroy(&finalized)
		job.phase = .Result_Ready
		tool_jobs_latch_stop(jobs, chat)
		return
	}
	job.committed = true
	job.recorded_seq = result_seq
	jobs.committed += 1
	if !job.nested { jobs.committed_roots += 1 }
	if job.parent != nil {
		// What a script did is reported by its parent, so the model can audit it and read
		// one child's full result back. The list is bounded and the count is not, because a
		// long script is the case this exists for.
		// The sequence is the child's call, because that is the key context_read_result
		// takes: a reader names the call the result answers, not the result.
		if len(job.parent.lua_calls) < CODE_MODE_MAX_CALL_SUMMARIES {
			append(&job.parent.lua_calls, Lua_Call_Summary{child = job, seq = job.call.seq, outcome = finalized.outcome})
		}
		job.parent.lua_calls_total += 1
		job.parent.lua_child_result = strings.clone(finalized.content, job.parent.allocator)
		job.parent.lua_child = nil
		if job.parent.lua_child_result == "" {
			job.parent.result = tool_result_failure(&job.parent.exec, .Tool_Failed, "the nested tool result could not be retained", "allocation failed")
			job.parent.result_present = true
			job.parent.phase = .Result_Ready
		} else if jobs.stop != .None {
			delete(job.parent.lua_child_result, job.parent.allocator)
			job.parent.lua_child_result = ""
			job.parent.result = tool_result_failure(&job.parent.exec, .Cancelled, "the Code Mode execution was cancelled", "cancelled")
			job.parent.result_present = true
			job.parent.phase = .Result_Ready
		} else {
			job.parent.phase = .Queued
		}
	}

	committed := [4]Log_Field {
		{key = "tool", value = job.name},
		{key = "outcome", value = session.tool_outcome_name(finalized.outcome)},
		{key = "result_seq", value = i64(result_seq)},
		{key = "spilled", value = spilled},
	}
	log_emit({level = .Info, category = .Tool, event = "tool.result_committed", fields = committed[:]})
	_observer_tool_result(observer, job.name, &finalized)
	tool_result_destroy(&finalized)
	job.phase = .Retiring
}

// tool_jobs_retire releases one settled job's execution resources and drops what could
// not be recorded. A result that reached the store is already owned by it. A job whose
// worker never published is the worker's, and the owner hands it back instead of waiting:
// now is the same observation the abandon step used, and the stop patience is measured from
// the job's own stop.
tool_jobs_retire :: proc(jobs: ^Tool_Jobs, now: time.Tick) {
	job := tool_jobs_retirable(jobs, now)
	if job == nil { return }

	if !tool_job_releasable(job) {
		// The worker ignored its stop, so the batch answers the call and leaves the job to
		// that worker. This is unreachable for a job the abandon step answered first, and it
		// is the only path for a batch that cannot record anything at all.
		sync.mutex_lock(&job.mu)
		job.orphan = true
		job.phase = .Stuck
		waited := time.tick_diff(job.stop_at, now)
		fields := [3]Log_Field {
			{key = "tool", value = job.name},
			{key = "outcome", value = session.tool_outcome_name(.Unknown)},
			{key = "waited_ms", value = i64(waited / time.Millisecond)},
		}
		log_emit({level = .Error, category = .Tool, event = "tool.job_stuck", fields = fields[:]})
		sync.mutex_unlock(&job.mu)
		return
	}
	if job.result_present {
		tool_result_destroy(&job.result)
		job.result_present = false
	}
	tool_arguments_destroy(&job.arguments, job.allocator)
	job.phase = job.committed ? .Retired : .Unrecorded
}

// tool_jobs_wait sleeps until a worker publishes or the wait slice ends. The wait
// releases the table's mutex, so a completion that arrives first is never missed.
tool_jobs_wait :: proc(jobs: ^Tool_Jobs, timeout := TOOL_JOBS_WAIT) {
	sync.mutex_lock(&jobs.mutex)
	if !jobs.woken { _ = sync.cond_wait_with_timeout(&jobs.cond, &jobs.mutex, timeout) }
	jobs.woken = false
	sync.mutex_unlock(&jobs.mutex)
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
	object, _ := job.arguments.value.(json.Object)
	result := job.execute(&job.exec, object)
	finished := [2]Log_Field{{key = "tool", value = job.name}, {key = "outcome", value = session.tool_outcome_name(result.outcome)}}
	log_emit({level = .Info, category = .Tool, event = "tool.execution_finished", fields = finished[:]})
	return result
}

// tool_job_launch starts one worker-placed job. The watched signals are blocked across
// creation so the worker inherits a mask that keeps it ineligible for the process
// handler: a tool must never run the handler that cancels its own turn.
//
// The thread releases itself. The owner must be able to give up on a call that ignores its
// stop, and a thread nobody joins is a thread nobody can free: a self-cleaning thread is
// removed by the runtime, and a job the owner handed back is released by its own worker.
@(private)
tool_job_launch :: proc(job: ^Tool_Job) -> bool {
	previous: linux.Sig_Set
	chat_signal_block_watched(&previous)
	worker := thread.create(tool_job_worker, name = "nabla-tool")
	chat_signal_restore(previous)
	if worker == nil { return false }
	worker.flags += {.Self_Cleanup}
	worker.data = job
	thread.start(worker)
	job.launched = true
	return true
}

// tool_job_worker runs one call off the owner's thread and publishes its result. It touches
// nothing belonging to the session: no store, no second job, and no context it did not set
// itself.
//
// A job the owner handed back is released here, and the mutex is held across that release:
// the owner takes the same mutex to decide the handoff, so a job is freed only once its
// owner has stopped using it.
@(private)
tool_job_worker :: proc(worker: ^thread.Thread) {
	job := cast(^Tool_Job)worker.data
	if job == nil { return }
	// A thread started without an explicit context gets the default one, so both the
	// allocator and the logger are set here rather than inherited.
	context.allocator = job.allocator
	context.logger = log_logger(&job.logging)

	result := tool_job_execute(job)
	// The table is read before the publish below: from that point the owner may release this
	// job, and the wake it needs is a local copy.
	table := job.table

	sync.mutex_lock(&job.mu)
	if job.orphan {
		// The owner gave up on this call and released nothing, so the result the worker just
		// produced is freed here along with the job that held it.
		tool_result_destroy(&result)
		tool_job_release(job)
		return
	}
	job.result = result
	job.result_present = true
	job.published = true
	sync.mutex_unlock(&job.mu)

	sync.mutex_lock(&table.mutex)
	table.woken = true
	sync.cond_signal(&table.cond)
	sync.mutex_unlock(&table.mutex)
}
