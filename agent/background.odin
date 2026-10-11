package agent

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

// Background_Jobs owns detached tool jobs until their completion is committed and their
// workers retire. Only the session owner reads or changes the table. Workers hold their
// individually allocated jobs, never the table.
Background_Jobs :: struct {
	jobs: [dynamic]^Tool_Job,
}

@(private)
background_detach :: proc(chat: ^Chat_Session, jobs: ^Tool_Jobs, job: ^Tool_Job, observer: Chat_Observer, repairs: []string) {
	receipt, allocation_error := mem.new(Tool_Job, job.allocator)
	if allocation_error != nil {
		job.result = tool_result_failure(&job.exec, .Tool_Failed, "the background receipt could not be allocated", "out of memory")
		job.phase = .Result_Ready
		return
	}
	receipt^ = {
		id        = job.id,
		turn_id   = job.turn_id,
		ordinal   = job.ordinal,
		call      = job.call,
		allocator = job.allocator,
		phase     = .Retiring,
	}
	transferred := false
	defer if !transferred { tool_job_release(receipt) }
	receipt.name, allocation_error = strings.clone(job.name, receipt.allocator)
	if allocation_error == nil { receipt.call_id, allocation_error = strings.clone(job.call_id, receipt.allocator) }
	if chat.background.jobs.allocator.procedure == nil { chat.background.jobs.allocator = chat.allocator }
	if allocation_error == nil { allocation_error = reserve(&chat.background.jobs, len(chat.background.jobs) + 1) }
	if allocation_error != nil {
		job.result = tool_result_failure(&job.exec, .Tool_Failed, "the background job could not be retained", "out of memory")
		job.phase = .Result_Ready
		return
	}
	output := Background_Output {
		job    = background_job_name(job.exec.call, context.temp_allocator),
		status = "running",
	}
	if _, shell := job.arguments.(Shell_Args); shell {
		output.stdout_file = chat_tool_output_path(chat, job.exec.call, journal.KEPT_STDOUT_SUFFIX)
		output.stderr_file = chat_tool_output_path(chat, job.exec.call, journal.KEPT_STDERR_SUFFIX)
	}
	result := tool_result_success(&job.exec, output, "running in background")
	defer tool_result_destroy(&result)
	if result.allocation_failed || tool_result_report_repairs(&result, job.admitted.repairs) != nil {
		job.result = tool_result_failure(&job.exec, .Tool_Failed, "the background receipt could not be rendered", "out of memory")
		job.phase = .Result_Ready
		return
	}
	node, parent_call := tool_job_record_placement(chat, job)
	chat_record(
		chat,
		{kind = .Tool_Admitted, node = node, request = chat.request, call = job.exec.call, parent_call = parent_call},
		journal.Tool_Admitted{tool = job.name, repairs = repairs, background = true},
		transmute([]u8)job.admitted.effective,
	)
	chat_record(
		chat,
		{kind = .Tool_Started, node = node, request = chat.request, call = job.exec.call, parent_call = parent_call},
		journal.Tool_Started{tool = job.name},
	)
	if !chat_stage_tool_result(
		   chat,
		   {kind = .Tool_Completed, node = node, request = chat.request, call = job.exec.call, parent_call = parent_call},
		   &result,
	   ) ||
	   !chat_commit(chat, "the background dispatch and receipt could not be recorded") {
		tool_jobs_latch_stop(jobs, chat)
		return
	}
	receipt.committed = true
	receipt.tabled = true
	for &entry in jobs.jobs {
		if entry == job { entry = receipt; break }
	}
	transferred = true
	jobs.committed += 1
	jobs.committed_roots += 1
	_observer_tool_result(observer, job.exec.call, parent_call, job.name, job.call.arguments, &result)
	job.call = nil
	job.interrupt.parent = &chat.background_stop
	// The observer belongs to the turn; progress is available in the kept stream files.
	job.exec.stream = {}
	job.exec.skills = nil
	job.lane = nil
	if launch_error := tool_job_launch(job); launch_error != nil {
		job.result = tool_result_failure(
			&job.exec,
			.Tool_Failed,
			fmt.tprintf("the tool could not be started: %s", os.error_string(launch_error)),
			"not started",
		)
		background_complete(chat, job)
		tool_job_release(job)
		return
	}
	job.phase = .Running
	job.dispatched = time.tick_now()
	// Capacity was reserved before dispatch, so this ownership handoff cannot allocate.
	_, append_error := append(&chat.background.jobs, job)
	ensure(append_error == nil, "the reserved background table could not accept its job")
}

@(private)
background_complete :: proc(chat: ^Chat_Session, job: ^Tool_Job) {
	result := job.result.?
	job.result = nil
	defer tool_result_destroy(&result)
	if result.allocation_failed || tool_result_report_repairs(&result, job.admitted.repairs) != nil {
		chat_session_fail(chat, "a background result could not be rendered: out of memory", latch = false)
		background_record(chat, job, nil, "error unknown: the job finished, but its result could not be rendered: out of memory")
		return
	}
	budget := chat_tool_budget_open(chat, 1)
	tool_result_keep(&result, &budget, chat_tool_output_path(chat, job.exec.call))
	background_record(chat, job, &result, "error unknown: the job finished, but its result could not be recorded: out of memory")
}

// background_record commits the background.completed record that answers a job's receipt.
// When result is nil or cannot be staged, the record carries unrecorded instead: fixed text
// with an Unknown outcome, which needs no allocation, so the receipt is still answered.
@(private)
background_record :: proc(chat: ^Chat_Session, job: ^Tool_Job, result: ^Tool_Result, unrecorded: string) {
	header := journal.Record {
		kind = .Background_Completed,
		call = job.exec.call,
	}
	if result == nil || !chat_stage_tool_result(chat, header, result, job.name) {
		fallback := Tool_Result {
			outcome = .Unknown,
			content = unrecorded,
		}
		if !chat_stage_tool_result(chat, header, &fallback, job.name) { return }
	}
	// Commit failure is latched on the session for its owner to report.
	_ = chat_commit(chat, "a background job's outcome could not be recorded")
}

// background_stop_job asks a detached job to stop and starts its stop patience. Owner only.
@(private)
background_stop_job :: proc(job: ^Tool_Job) {
	tool_job_request_stop(job)
	job_note_stop(&job.worker, true, time.tick_now())
}

// background_reap commits published background results and releases their jobs. A worker
// that ignores its session stop is answered Unknown and abandoned. Owner only.
background_reap :: proc(chat: ^Chat_Session) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	now := time.tick_now()
	for index := 0; index < len(chat.background.jobs); {
		job := chat.background.jobs[index]
		if job_published(&job.worker) {
			job_retire(&job.worker)
			background_complete(chat, job)
			ordered_remove(&chat.background.jobs, index)
			tool_job_release(job)
			continue
		}
		if tool_control_cancelled(job.exec.control) && job.worker.stop_at == nil { background_stop_job(job) }
		if job_overdue(&job.worker, now) {
			// The worker still owns its result slot, so uncertainty is recorded without one.
			background_record(chat, job, nil, "error unknown: the operation may still be running; it did not confirm its stop")
			job.worker.record = {
				call = job.exec.call,
			}
			job.phase = .Abandoned
			job_abandon(chat, &job.worker)
			job.tabled = false
			ordered_remove(&chat.background.jobs, index)
			continue
		}
		index += 1
	}
}

@(require_results)
background_running :: proc(chat: ^Chat_Session) -> bool {
	return len(chat.background.jobs) > 0
}

@(private)
background_deadline :: proc(chat: ^Chat_Session) -> Maybe(time.Tick) {
	earliest: Maybe(time.Tick)
	for job in chat.background.jobs {
		if job.worker.stop_at == nil { continue }
		due := job_stop_deadline(&job.worker)
		if existing, has := earliest.?; !has || time.tick_diff(existing, due) < 0 { earliest = due }
	}
	return earliest
}

// chat_background_deadline returns the earlier of deadline and a stopped background
// worker's patience deadline. Owner only; nil means neither has a deadline.
@(require_results)
chat_background_deadline :: proc(chat: ^Chat_Session, deadline: Maybe(time.Tick)) -> Maybe(time.Tick) {
	background, has_background := background_deadline(chat).?
	if !has_background { return deadline }
	if caller, has_caller := deadline.?; has_caller && time.tick_diff(background, caller) < 0 { return deadline }
	return background
}

// background_destroy stops all detached jobs, retires published workers without committing,
// and abandons the rest after the stop patience. Recovery settles the open completions.
background_destroy :: proc(chat: ^Chat_Session) {
	for job in chat.background.jobs { background_stop_job(job) }
	for job in chat.background.jobs {
		if job_wait_published(&job.worker, job_stop_deadline(&job.worker)) {
			job_retire(&job.worker)
			tool_job_release(job)
		} else {
			job.worker.record = {
				call = job.exec.call,
			}
			job.phase = .Abandoned
			job_abandon(chat, &job.worker)
			job.tabled = false
		}
	}
	delete(chat.background.jobs)
	chat.background = {}
}

// chat_background_pending reports whether a report or message waits in the journal, or
// a child or detached tool still runs. It first commits finished jobs' reports. Owner only.
@(require_results)
chat_background_pending :: proc(chat: ^Chat_Session) -> bool {
	children_running := agent_team_running(chat.team)
	reopened := agent_team_reap(chat.team, chat)
	background_reap(chat)
	return chat_inbox_reports_pending(chat) || children_running || reopened || background_running(chat)
}

// chat_background_report_failure reports and consumes a failure observed without an open
// turn. A retryable failure restores Idle; a storage failure remains latched. It writes
// no turn completion and leaves last_error available to callers. Owner only.
@(require_results)
chat_background_report_failure :: proc(chat: ^Chat_Session, observer: Chat_Observer) -> bool {
	if chat.turn != 0 || chat.state != .Finalizing || !chat.active_failed { return false }
	_observer_message(observer, .Error, chat.last_error)
	chat.active_failed = false
	if !chat.storage_failed { chat.state = .Idle }
	return true
}

// chat_background_wait blocks until a report or message waits, and reports false when no
// child or detached tool runs any more, stop is requested, or the session failed. Owner only.
@(require_results)
chat_background_wait :: proc(chat: ^Chat_Session, stop: ^ai.Interrupt) -> bool {
	for {
		seen := owner_wake_seen()
		// Capture children before reap: one that publishes during reap still needs its report.
		children_running := agent_team_running(chat.team)
		reopened := agent_team_reap(chat.team, chat)
		background_reap(chat)
		if chat.active_failed || chat.storage_failed { return false }
		if chat_inbox_reports_pending(chat) { return true }
		running := children_running || reopened || background_running(chat)
		if !running || ai.interrupt_requested(stop) || ai.interrupt_requested(&process_interrupt) { return false }
		owner_wake_wait(seen, chat_background_deadline(chat, nil))
	}
}
