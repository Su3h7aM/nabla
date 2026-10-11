package agent

import "base:runtime"
import "core:encoding/json"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:time"

import "nabla:agent/journal"

TOOL_JOBS_NAME :: "jobs"
TOOL_JOBS_DESCRIPTION :: "Manage this session's background jobs, the tool calls you started with wait false. list shows every job still in the table: its id, tool, status (running, or stopping once a stop was requested), age in seconds since it was dispatched and, for shell, the files that keep its stdout and stderr. A job leaves the list when its completion is recorded. stop needs job, an id as job-<n> from the receipt or from list, requests that job's stop and returns stopping at once. The completion arrives later as a message and reports what was observed: Cancelled when the stop is confirmed, Unknown when it cannot be, or the tool's own result if it finished first, with whatever output the tool produced. A subagent is not a job: stop it with agent action stop.\n\nThere is no wait action. To wait for a job, end your response; its completion arrives as a message and resumes you. Polling with list is pointless, since completions arrive on their own."
TOOL_JOBS_SCHEMA :: `{"additionalProperties":false,"properties":{"action":{"description":"list shows the background jobs; stop requests one job's stop.","enum":["list","stop"],"type":"string"},"job":{"description":"stop: required job id, as job-<n>, from a receipt or from list.","type":["string","null"]}},"required":["action"],"type":"object"}`
TOOL_JOBS_STOP_FIELDS :: []string{"action", "job"}

TOOL_JOBS_DEFINITION :: Tool_Definition {
	name = TOOL_JOBS_NAME,
	description = TOOL_JOBS_DESCRIPTION,
	input_schema = TOOL_JOBS_SCHEMA,
	hints = {read_only = .No, destructive = .Yes, idempotent = .No, open_world = .No},
	placement = .Owner,
	kind = .Jobs,
	execute = tool_jobs_execute,
}

Jobs_Action :: enum {
	List,
	Stop,
}

Jobs_Args :: struct {
	action: Jobs_Action,
	job:    string,
}

@(require_results)
tool_jobs_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Jobs_Args, err: Tool_Argument_Error) {
	action := tool_field_string(arguments, "action", allocator = ctx.allocator) or_return
	switch action {
	case "list":
		tool_fields_known(arguments, {"action"}, path = "jobs(list)", allocator = ctx.allocator) or_return
		args.action = .List
	case "stop":
		tool_fields_known(arguments, TOOL_JOBS_STOP_FIELDS, path = "jobs(stop)", allocator = ctx.allocator) or_return
		args.action = .Stop
		args.job = tool_field_string(arguments, "job", allocator = ctx.allocator) or_return
		if strings.trim_space(args.job) == "" { return {}, tool_argument_error(.Invalid_Value, "job", "a job id such as job-12", ctx.allocator) }
	case:
		return {}, tool_argument_error(.Invalid_Value, "action", "list or stop", ctx.allocator)
	}
	return
}

// render_job_name writes a job's id, job- and its call id, without formatting a string.
@(private, require_results)
render_job_name :: proc(builder: ^strings.Builder, call: journal.Call_Id) -> mem.Allocator_Error {
	render_text(builder, "job-") or_return
	render_integer(builder, i64(call)) or_return
	return nil
}

// tool_jobs_listing renders the table with temp_allocator, or reports a failed allocation.
@(private, require_results)
tool_jobs_listing :: proc(jobs: []^Tool_Job) -> (text: string, err: mem.Allocator_Error) {
	builder := strings.builder_make(context.temp_allocator) or_return
	for job, index in jobs {
		if index > 0 { render_byte(&builder, '\n') or_return }
		render_text(&builder, "job: ") or_return
		render_job_name(&builder, job.exec.call) or_return
		render_byte(&builder, '\n') or_return
		render_field(&builder, "tool", job.name) or_return
		render_field(&builder, "status", "stopping" if tool_control_cancelled(job.exec.control) else "running") or_return
		render_text(&builder, "age: ") or_return
		render_integer(&builder, i64(time.duration_seconds(time.tick_since(job.dispatched)))) or_return
		render_text(&builder, "s\n") or_return
		if _, shell := job.arguments.(Shell_Args); shell && job.output_base != "" {
			render_text(&builder, "stdout_file: ") or_return
			render_text(&builder, job.output_base) or_return
			render_text(&builder, journal.KEPT_STDOUT_SUFFIX) or_return
			render_text(&builder, "\nstderr_file: ") or_return
			render_text(&builder, job.output_base) or_return
			render_text(&builder, journal.KEPT_STDERR_SUFFIX) or_return
			render_byte(&builder, '\n') or_return
		}
	}
	if len(jobs) == 0 { render_text(&builder, "No background jobs.") or_return }
	return strings.to_string(builder), nil
}

// tool_jobs_unknown_message names the current jobs after a stop named none of them.
@(private, require_results)
tool_jobs_unknown_message :: proc(jobs: []^Tool_Job, requested: string) -> (message: string, err: mem.Allocator_Error) {
	builder := strings.builder_make(context.temp_allocator) or_return
	render_text(&builder, "no background job named ") or_return
	render_quoted(&builder, requested) or_return
	render_text(&builder, "; current jobs: ") or_return
	for job, index in jobs {
		if index > 0 { render_text(&builder, ", ") or_return }
		render_job_name(&builder, job.exec.call) or_return
	}
	if len(jobs) == 0 { render_text(&builder, "none") or_return }
	return strings.to_string(builder), nil
}

@(require_results)
tool_jobs_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	args := arguments.(Jobs_Args)
	if ctx.background == nil { return tool_result_failure(ctx, .Unavailable, "background jobs are not available in this session", "unavailable") }
	jobs := ctx.background.jobs[:]
	if args.action == .List {
		content, listing_error := tool_jobs_listing(jobs)
		if listing_error != nil { return tool_result_failure(ctx, .Tool_Failed, "the job list could not be rendered", "out of memory") }
		return tool_result_success(ctx, Jobs_Output{count = len(jobs), content = content}, "list")
	}
	if strings.has_prefix(args.job, "job-") {
		if call, parsed := strconv.parse_u64_of_base(args.job[len("job-"):], 10); parsed {
			for job in jobs {
				if job.exec.call != journal.Call_Id(call) { continue }
				background_stop_job(job)
				return tool_result_success(ctx, Background_Output{job = args.job, status = "stopping"}, "stopping")
			}
		}
	}
	if strings.has_prefix(args.job, "agent-") {
		return tool_result_failure(ctx, .Invalid_Arguments, "agent-<n> is a subagent, not a job; use agent with action stop", "not stopped")
	}
	message, message_error := tool_jobs_unknown_message(jobs, args.job)
	if message_error != nil { return tool_result_failure(ctx, .Tool_Failed, "the job names could not be rendered", "out of memory") }
	return tool_result_failure(ctx, .Invalid_Arguments, message, "not stopped")
}
