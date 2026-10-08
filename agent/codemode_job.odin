package agent

import "core:fmt"
import "core:mem"
import "core:strings"

import "nabla:agent/journal"

// Codemode_Child is one call a script started. Its handle is its position plus one. job is
// borrowed and stays valid until the batch is destroyed, because a retired job keeps its
// record and its name until then.
Codemode_Child :: struct {
	job:       ^Tool_Job,
	outcome:   journal.Tool_Outcome,
	committed: bool, // the result is recorded and kept for job.wait
	consumed:  bool, // job.wait took the result
}

@(private)
tool_job_lua_start :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, job: ^Tool_Job) {
	args := job.arguments.(Codemode_Args)
	children, children_error := make([dynamic]Codemode_Child, job.allocator)
	if children_error != nil {
		codemode_job_answer(job, .Tool_Failed, .Out_Of_Memory, "the Code Mode execution could not be tracked: out of memory", "out of memory")
		return
	}
	job.lua_children = children
	run, compiled := codemode_lua_start(args.code, &job.interrupt, args.timeout, job.allocator)
	if run == nil {
		codemode_job_answer(job, .Tool_Failed, .Unavailable, "the Lua execution could not be allocated", "executor unavailable")
		return
	}
	job.lua = run
	if !compiled {
		if run.failure == .Memory {
			codemode_job_answer(job, .Tool_Failed, .Out_Of_Memory, run.message, "Lua failed")
		} else {
			codemode_job_answer(job, .Tool_Failed, .Syntax_Error, run.message, "syntax error")
		}
		return
	}
	for &definition in chat.tools.definitions {
		if definition.name == TOOL_CODEMODE_NAME { continue }
		if !codemode_lua_install_tool(run, definition.name) {
			if run.failure == .Memory {
				codemode_job_answer(job, .Tool_Failed, .Out_Of_Memory, run.message, "Lua failed")
			} else {
				codemode_job_answer(job, .Tool_Failed, .Unavailable, "the Lua tool table could not be built", "executor unavailable")
			}
			return
		}
	}
	tool_job_lua_resume(jobs, chat, job)
}

// tool_job_lua_resume runs the script's next step and acts on what it reported.
@(private)
tool_job_lua_resume :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, job: ^Tool_Job) {
	event := Lua_Event.Failed
	if !codemode_lua_expired(job.lua) { event = codemode_lua_resume(job.lua) }
	if codemode_lua_expired(job.lua) {
		event = codemode_lua_settle(job.lua, .Failed, .Timed_Out, "the execution passed its timeout")
	}
	switch event {
	case .Slice:
		job.phase = .Queued
	case .Host_Request:
		codemode_job_request(jobs, chat, job)
	case .Returned, .Stopped, .Failed:
		codemode_job_stop_children(job)
		if codemode_job_settled(job) {
			codemode_job_finish(job)
		} else {
			job.phase = .Waiting
		}
	}
}

// codemode_job_request answers what the script asked for. An answer leaves the job queued
// to resume; a wait for a child still running parks it until the child commits.
@(private)
codemode_job_request :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, job: ^Tool_Job) {
	run := job.lua
	handle := run.request.handle
	if run.request.kind != .Wait {
		refusal: string
		handle, refusal = codemode_job_start_child(jobs, chat, job)
		if job.result != nil { return }
		if refusal != "" {
			answered := codemode_lua_answer_error(run, refusal)
			delete(refusal, run.allocator)
			if !answered {
				codemode_job_answer(job, .Tool_Failed, .Out_Of_Memory, "the refusal could not be handed to the script: out of memory", "out of memory")
				return
			}
			job.phase = .Queued
			return
		}
		if run.request.kind == .Start {
			codemode_lua_answer_handle(run, handle)
			job.phase = .Queued
			return
		}
	}

	if handle < 1 || handle > len(job.lua_children) || job.lua_children[handle - 1].consumed {
		message := fmt.tprintf("job.wait was given %d, which is not a handle from job.start that has not been waited on yet", handle)
		if !codemode_lua_answer_error(run, message) {
			codemode_job_answer(job, .Tool_Failed, .Out_Of_Memory, "the refusal could not be handed to the script: out of memory", "out of memory")
			return
		}
		job.phase = .Queued
		return
	}
	if !job.lua_children[handle - 1].committed {
		job.lua_waiting = handle
		job.phase = .Waiting
		return
	}
	codemode_job_deliver(job, handle)
}

@(private)
codemode_job_deliver :: proc(job: ^Tool_Job, handle: int) {
	codemode_lua_answer_kept(job.lua, handle)
	job.lua_children[handle - 1].consumed = true
	job.lua_waiting = 0
	job.phase = .Queued
}

// codemode_job_start_child admits the requested call as a child job and returns its handle.
// A call the script can fix is refused with a message owned by the run's allocator, which
// the script receives as an error. A failure of the batch answers the parent itself.
@(private, require_results)
codemode_job_start_child :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, parent: ^Tool_Job) -> (handle: int, refusal: string) {
	run := parent.lua
	name := run.request.name
	if name == TOOL_CODEMODE_NAME {
		return 0, fmt.aprintf("%s cannot be called from Lua; run the code directly instead", name, allocator = run.allocator)
	}
	// The script's table is written once as the call's arguments document, which the child
	// is admitted from like any provider call, and which its record keeps.
	arguments, message := codemode_lua_request_arguments(run)
	if message != "" { return 0, message }
	defer delete(arguments, run.allocator)

	call_id := fmt.tprintf("%s/%d", parent.call_id, len(parent.lua_children) + 1)
	// The proposal is buffered here and committed with the child's admission.
	call := journal.next_call(chat.store)
	chat_record(
		chat,
		{kind = .Tool_Proposed, request = chat.request, call = call, parent_call = parent.call.call},
		journal.Tool_Proposed{provider_id = call_id, name = name},
		transmute([]u8)arguments,
	)

	// The job struct comes from the same heap as its data: a worker releases a job the owner
	// handed back, so that allocation has to outlive the batch and its session.
	allocator := jobs.worker_allocator
	child, allocation_error := new(Tool_Job, allocator)
	if allocation_error != nil {
		codemode_job_answer(parent, .Tool_Failed, .Unavailable, "the nested tool call could not be allocated", "allocation failed")
		return
	}
	child^ = {
		id        = jobs.next_id,
		turn_id   = parent.turn_id,
		ordinal   = len(jobs.jobs),
		placement = .Worker,
		phase     = .Queued,
		allocator = allocator,
		parent    = parent,
		nested    = true,
	}
	child.call = &child.nested_call
	child.nested_call.call = call
	clone_error: mem.Allocator_Error
	child.nested_call.id, clone_error = strings.clone(call_id, allocator)
	if clone_error == nil { child.nested_call.name, clone_error = strings.clone(name, allocator) }
	if clone_error == nil { child.nested_call.arguments, clone_error = strings.clone(arguments, allocator) }
	if clone_error == nil { child.name, clone_error = strings.clone(name, allocator) }
	if clone_error == nil { child.call_id, clone_error = strings.clone(call_id, allocator) }
	if clone_error != nil {
		// A child the harness cannot name is never published, so releasing it here releases
		// every copy it already owns.
		tool_job_release(child)
		codemode_job_answer(parent, .Tool_Failed, .Out_Of_Memory, "the nested tool call could not be allocated: out of memory", "out of memory")
		return
	}
	tool_job_admit(jobs, chat, {}, child)
	if _, append_failure := append(&parent.lua_children, Codemode_Child{job = child}); append_failure != nil {
		tool_job_release(child)
		codemode_job_answer(parent, .Tool_Failed, .Unavailable, "the nested tool job could not be tracked", "allocation failed")
		return
	}
	if !tool_jobs_publish(jobs, child) {
		_ = pop(&parent.lua_children)
		codemode_job_answer(parent, .Tool_Failed, .Unavailable, "the nested tool job could not be admitted", "allocation failed")
		return
	}
	return len(parent.lua_children), ""
}

// codemode_job_child_committed hands a recorded child result to its parent: it is kept for
// job.wait, delivered at once to a wait that is parked on it, and ends a script that is
// only waiting for its children to settle.
codemode_job_child_committed :: proc(jobs: ^Tool_Jobs, child: ^Tool_Job, result: ^Tool_Result) {
	parent := child.parent
	handle := 0
	for &entry, index in parent.lua_children {
		if entry.job != child { continue }
		entry.committed = true
		entry.outcome = result.outcome
		handle = index + 1
	}
	if parent.result != nil || handle == 0 { return }
	if jobs.stop != .None {
		codemode_job_answer(parent, .Cancelled, .Cancelled, "the Code Mode execution was cancelled", "cancelled")
		return
	}
	if parent.lua.terminal {
		if codemode_job_settled(parent) { codemode_job_finish(parent) }
		return
	}
	if !codemode_lua_keep_result(parent.lua, handle, result) {
		codemode_job_answer(
			parent,
			.Tool_Failed,
			.Out_Of_Memory,
			"the result of a call the script made could not be handed to it: out of memory",
			"out of memory",
		)
		return
	}
	if parent.lua_waiting == handle { codemode_job_deliver(parent, handle) }
}

// codemode_job_stop_children stops every child that has not committed: a queued one never
// runs, and a running one is asked to stop. Each still commits, so the record stays whole.
// A background agent start is left to run: the subagent it starts is meant to outlive the
// script, and the call itself returns at once. A cancelled turn still drops it before it runs.
@(private)
codemode_job_stop_children :: proc(job: ^Tool_Job) {
	for entry in job.lua_children {
		if entry.committed { continue }
		child := entry.job
		if start, is_start := child.arguments.(Agent_Start_Args); is_start && !start.wait { continue }
		#partial switch child.phase {
		case .Queued:
			child.result = tool_result_failure(&child.exec, .Not_Executed, "the script ended before this call ran", "not executed")
			child.phase = .Result_Ready
		case .Dispatching, .Running:
			tool_job_request_stop(child)
		}
	}
}

@(private, require_results)
codemode_job_settled :: proc(job: ^Tool_Job) -> bool {
	for entry in job.lua_children {
		if !entry.committed { return false }
	}
	return true
}

// codemode_job_live_child returns the earliest child that has not committed. Children commit
// before their parent and in the order they started.
codemode_job_live_child :: proc(job: ^Tool_Job) -> ^Tool_Job {
	for entry in job.lua_children {
		if !entry.committed { return entry.job }
	}
	return nil
}

// codemode_job_finish answers a script that ended and whose children all committed.
@(private)
codemode_job_finish :: proc(job: ^Tool_Job) {
	run := job.lua
	switch run.last_event {
	case .Returned:
		codemode_job_answer_value(job)
	case .Stopped:
		codemode_job_answer(job, .Cancelled, .Cancelled, run.message, "cancelled")
	case .Failed:
		switch run.failure {
		case .Timed_Out:
			codemode_job_answer(job, .Timed_Out, .Timed_Out, run.message, "timed out")
		case .Memory:
			codemode_job_answer(job, .Tool_Failed, .Out_Of_Memory, run.message, "Lua failed")
		case .Syntax:
			codemode_job_answer(job, .Tool_Failed, .Syntax_Error, run.message, "Lua failed")
		case .None, .Runtime:
			codemode_job_answer(job, .Tool_Failed, .Runtime_Error, run.message, "Lua failed")
		}
	case .Slice, .Host_Request:
		codemode_job_answer(job, .Tool_Failed, .Unavailable, "the execution ended while it was still running", "executor unavailable")
	}
}

// codemode_job_answer_value answers a script that returned. The value is written as a Lua
// literal, and the result is kept and shown the way every other result is.
@(private)
codemode_job_answer_value :: proc(job: ^Tool_Job) {
	run := job.lua
	value, message, diagnostic := codemode_lua_returned_literal(run)
	defer delete(value, run.allocator)
	defer delete(message, run.allocator)
	if diagnostic != .None {
		codemode_job_answer(job, .Tool_Failed, diagnostic, message, "invalid return value")
		return
	}
	output := Codemode_Output {
		value = value,
		logs  = string(run.logs[:]),
	}
	result := codemode_job_result(job, .Success, "", output, "completed")
	job.result = result
	job.phase = .Result_Ready
}

// codemode_job_answer gives a Code Mode job its failure result and stops the children it
// no longer waits for. The outcome says what the harness observed, and the diagnostic which
// limit or fault Code Mode hit.
@(private)
codemode_job_answer :: proc(job: ^Tool_Job, outcome: journal.Tool_Outcome, diagnostic: Codemode_Diagnostic, message: string, reason: string) {
	codemode_job_stop_children(job)
	output := Codemode_Output {
		failure = codemode_diagnostic_names[diagnostic],
	}
	if job.lua != nil {
		output.logs = string(job.lua.logs[:])
		output.traceback = job.lua.traceback
	}
	job.result = codemode_job_result(job, outcome, message, output, reason)
	job.phase = .Result_Ready
}

// codemode_job_result adds the summaries of the calls the script made, so a model can audit
// it and read one child's full result back by its call id. Every committed child is
// summarized; the summaries borrow the batch's child jobs, which the clone inside
// tool_result_of copies into the result's own memory.
@(private, require_results)
codemode_job_result :: proc(job: ^Tool_Job, outcome: journal.Tool_Outcome, message: string, output: Codemode_Output, reason: string) -> Tool_Result {
	output := output
	// One summary per committed child, so the list holds exactly what the count names.
	count := 0
	for entry in job.lua_children {
		if entry.committed { count += 1 }
	}
	allocator := job.exec.allocator
	summaries, allocation_error := make([]Codemode_Call, count, allocator)
	if allocation_error != nil {
		return tool_result_of(&job.exec, .Tool_Failed, "the calls the script made could not be summarized: out of memory", nil, "out of memory")
	}
	defer delete(summaries, allocator)
	position := 0
	for entry in job.lua_children {
		if !entry.committed { continue }
		summaries[position] = {
			call    = entry.job.call.call,
			name    = entry.job.name,
			outcome = journal.TOOL_OUTCOME_NAMES[entry.outcome],
		}
		position += 1
	}
	output.calls_total = position
	output.calls = summaries
	return tool_result_of(&job.exec, outcome, message, output, reason)
}
