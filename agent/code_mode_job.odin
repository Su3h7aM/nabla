package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

import "nabla:agent/session"

@(private)
tool_job_lua_start :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, job: ^Tool_Job) {
	object := job.arguments.value.(json.Object)
	if fields_error := tool_fields_known(object, []string{"code"}, allocator = job.allocator); fields_error.kind != .None {
		job.result = tool_result_refused(&job.exec, &fields_error)
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	source, source_error := tool_field_string(object, "code", allocator = job.allocator)
	if source_error.kind != .None {
		job.result = tool_result_refused(&job.exec, &source_error)
		job.result_present = true
		job.phase = .Result_Ready
		return
	}

	run, compiled := code_mode_lua_start(job.allocator, lua_limits_default(), source)
	if run == nil {
		job.result = code_mode_failure(&job.exec, .Tool_Failed, .Unavailable, "the Lua execution could not be created", "executor unavailable")
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	job.lua = run
	if !compiled {
		job.result = code_mode_failure(&job.exec, .Tool_Failed, .Syntax_Error, code_mode_lua_message(run), "syntax error")
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	for &definition in chat.tools.definitions {
		if definition.name == TOOL_CODE_NAME { continue }
		if !code_mode_lua_install_tool(run, definition.name) {
			job.result = code_mode_failure(&job.exec, .Tool_Failed, .Unavailable, "the Lua tool table could not be built", "executor unavailable")
			job.result_present = true
			job.phase = .Result_Ready
			return
		}
	}
	tool_job_lua_resume(jobs, chat, job, false)
}

@(private)
tool_job_lua_resume :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, job: ^Tool_Job, deliver: bool) {
	event := Lua_Event.Slice
	if deliver {
		event = code_mode_lua_deliver_json(job.lua, job.lua_child_result, job.allocator)
		delete(job.lua_child_result, job.allocator)
		job.lua_child_result = ""
	} else {
		event = code_mode_lua_resume(job.lua)
	}

	switch event {
	case .Slice:
		job.phase = .Queued
	case .Host_Request:
		tool_job_lua_submit_child(jobs, chat, job)
	case .Returned:
		tool_job_lua_finish(job)
	case .Stopped:
		outcome := session.Tool_Outcome.Tool_Failed
		diagnostic := Code_Mode_Diagnostic.Instruction_Limit
		reason := "stopped"
		switch job.lua.stop {
		case .Cancelled:
			outcome = .Cancelled
			diagnostic = .Cancelled
			reason = "cancelled"
		case .Deadline:
			outcome = .Timed_Out
			diagnostic = .Deadline
			reason = "timed out"
		case .Instructions:
			reason = "instruction limit"
		case .None:
		}
		job.result = code_mode_failure(&job.exec, outcome, diagnostic, code_mode_lua_message(job.lua), reason)
		job.result_present = true
		job.phase = .Result_Ready
	case .Failed:
		diagnostic := Code_Mode_Diagnostic.Runtime_Error
		switch code_mode_lua_failure(job.lua) {
		case .Syntax:
			diagnostic = .Syntax_Error
		case .Memory:
			diagnostic = .Memory_Limit
		case .None, .Runtime:
		}
		job.result = code_mode_failure(&job.exec, .Tool_Failed, diagnostic, code_mode_lua_message(job.lua), "Lua failed")
		job.result_present = true
		job.phase = .Result_Ready
	}
}

// tool_job_lua_finish builds the parent result from a chunk that returned. The return
// value becomes structured JSON, so a script answers with an object or an array as
// easily as with a string, and the result budget is enforced here rather than by the
// generic oversized replacement, which would hide which value was too large.
@(private)
tool_job_lua_finish :: proc(job: ^Tool_Job) {
	run := job.lua
	logs := code_mode_lua_logs(run)
	output, message := code_mode_lua_returned_json(run, job.allocator)
	if message != "" {
		job.result = code_mode_failure(&job.exec, .Tool_Failed, .Invalid_Value, message, "invalid return value")
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	defer json.destroy_value(output, job.allocator)
	result := tool_result_of(
		&job.exec,
		.Success,
		"",
		Code_Mode_Result_Data{output = output, logs = logs, logs_truncated = code_mode_lua_logs_truncated(run)},
		"completed",
	)
	if len(result.content) > TOOL_MAX_RESULT_BYTES {
		tool_result_destroy(&result)
		job.result = code_mode_failure(
			&job.exec,
			.Tool_Failed,
			.Output_Limit,
			fmt.tprintf("the returned value and logs exceed the %d-byte result limit; return less from the script", TOOL_MAX_RESULT_BYTES),
			"output limit",
		)
		job.result_present = true
		job.phase = .Result_Ready
		return
	}
	job.result = result
	job.result_present = true
	job.phase = .Result_Ready
}

@(private)
tool_job_lua_submit_child :: proc(jobs: ^Tool_Jobs, chat: ^Chat_Session, parent: ^Tool_Job) {
	if len(jobs.jobs) >= TOOL_JOBS_MAX {
		parent.result = code_mode_failure(
			&parent.exec,
			.Tool_Failed,
			.Tool_Call_Limit,
			"the Code Mode execution created too many tool calls",
			"tool call limit",
		)
		parent.result_present = true
		parent.phase = .Result_Ready
		return
	}
	arguments, message := code_mode_lua_request_json(parent.lua, parent.allocator)
	if message != "" {
		parent.result = code_mode_failure(&parent.exec, .Invalid_Arguments, .Invalid_Value, message, "invalid child arguments")
		parent.result_present = true
		parent.phase = .Result_Ready
		return
	}
	defer delete(arguments, parent.allocator)

	child, alloc_error := mem.new(Tool_Job, jobs.allocator)
	if alloc_error != nil {
		parent.result = code_mode_failure(&parent.exec, .Tool_Failed, .Unavailable, "the nested tool call could not be allocated", "allocation failed")
		parent.result_present = true
		parent.phase = .Result_Ready
		return
	}

	parent.lua_child_no += 1
	call_id := fmt.aprintf("%s/%d", parent.call_id, parent.lua_child_no, allocator = parent.allocator)
	defer delete(call_id, parent.allocator)
	entry := session.New_Entry {
		turn_no = chat.turn_no,
		request_no = chat.active_request,
		created_at_ms = session.now_ms(),
		parent_call_seq = parent.call.seq,
		payload = session.Tool_Call_Entry{call_id = call_id, name = parent.lua.request.name, arguments = arguments},
	}
	call_seq, append_error := session.entry_append(chat.store, chat.id, entry)
	if append_error != nil {
		mem.free(child, jobs.allocator)
		chat_session_record_failure(chat, "the nested tool call could not be recorded", append_error)
		parent.result = code_mode_failure(&parent.exec, .Tool_Failed, .Unavailable, "the nested tool call could not be recorded", "storage failed")
		parent.result_present = true
		parent.phase = .Result_Ready
		return
	}

	child^ = {
		id        = jobs.next_id,
		turn_id   = parent.turn_id,
		ordinal   = len(jobs.jobs),
		table     = jobs,
		placement = .Worker,
		phase     = .Queued,
		allocator = jobs.worker_allocator,
		parent    = parent,
		nested    = true,
	}
	jobs.next_id += 1
	child.nested_call = {
		id        = strings.clone(call_id, child.allocator),
		name      = strings.clone(parent.lua.request.name, child.allocator),
		arguments = strings.clone(arguments, child.allocator),
		seq       = call_seq,
	}
	child.call = &child.nested_call
	child.name = strings.clone(child.nested_call.name, child.allocator)
	child.call_id = strings.clone(child.nested_call.id, child.allocator)
	tool_job_admit(jobs, chat, {}, child)
	append(&jobs.jobs, child)
	parent.lua_child = child
	parent.phase = .Waiting
}
