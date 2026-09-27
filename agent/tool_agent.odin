package agent

import "core:encoding/json"
import "core:fmt"
import "core:strings"

TOOL_AGENT_SPAWN_NAME :: "agent_spawn"
TOOL_AGENT_SPAWN_DESCRIPTION :: "Start a subagent: a separate agent in a new session that works on one task and returns a concise answer, so your own context keeps only the result. It inherits none of your conversation. You define it: instruction is its system prompt (how to work and what its answer must contain) and prompt is its task, which must give it every fact, decision, and path it needs, or say exactly where to find them. model and effort choose what runs it; by default it runs your model at one effort level below yours. By default this call waits and returns the answer. With background true it returns the agent id at once, the subagent works in parallel with you, and its answer arrives later as a message. Only the orchestrator can start subagents."
TOOL_AGENT_SPAWN_SCHEMA :: `{"type":"object","properties":{"instruction":{"type":["string","null"],"description":"The subagent's system prompt: how to work and what its answer must contain."},"prompt":{"type":"string","description":"The task, with every fact the subagent needs."},"model":{"type":["string","null"],"description":"Model id to run. Default: your model."},"provider":{"type":["string","null"],"description":"Provider of model, needed only when several serve it."},"effort":{"type":["string","null"],"description":"Reasoning effort level. Default: one level below yours."},"background":{"type":["boolean","null"],"description":"Return at once and deliver the answer later as a message. Default: false, wait for the answer."}},"required":["prompt"],"additionalProperties":false}`
TOOL_AGENT_SPAWN_FIELDS :: []string{"instruction", "prompt", "model", "provider", "effort", "background"}

TOOL_AGENT_SEND_NAME :: "agent_send"
TOOL_AGENT_SEND_DESCRIPTION :: "Send a message to another agent. It reaches the recipient between its model requests, like a line the user types while it works. The orchestrator names a running subagent in agent to steer it; a subagent leaves agent out to tell its orchestrator something it must know before the final answer. Subagents cannot message each other."
TOOL_AGENT_SEND_SCHEMA :: `{"type":"object","properties":{"agent":{"type":["string","null"],"description":"The subagent id, such as agent-1. Leave out to message the orchestrator."},"message":{"type":"string","description":"The message."}},"required":["message"],"additionalProperties":false}`
TOOL_AGENT_SEND_FIELDS :: []string{"agent", "message"}

TOOL_AGENT_STOP_NAME :: "agent_stop"
TOOL_AGENT_STOP_DESCRIPTION :: "Stop a running subagent. Its work ends at its next step and a notice that it stopped arrives as a message. Only the orchestrator can stop subagents."
TOOL_AGENT_STOP_SCHEMA :: `{"type":"object","properties":{"agent":{"type":"string","description":"The subagent id, such as agent-1."}},"required":["agent"],"additionalProperties":false}`
TOOL_AGENT_STOP_FIELDS :: []string{"agent"}

TOOL_AGENT_SPAWN_DEFINITION :: Tool_Definition {
	name = TOOL_AGENT_SPAWN_NAME,
	description = TOOL_AGENT_SPAWN_DESCRIPTION,
	input_schema = TOOL_AGENT_SPAWN_SCHEMA,
	hints = {read_only = .Unknown, destructive = .Unknown, idempotent = .No, open_world = .Yes},
	// A blocking subagent runs on this call's worker, which is the thread of its own it needs.
	placement = .Worker,
	kind = .Agent_Spawn,
	execute = tool_agent_spawn_execute,
}

TOOL_AGENT_SEND_DEFINITION :: Tool_Definition {
	name = TOOL_AGENT_SEND_NAME,
	description = TOOL_AGENT_SEND_DESCRIPTION,
	input_schema = TOOL_AGENT_SEND_SCHEMA,
	hints = {read_only = .No, destructive = .No, idempotent = .No, open_world = .No},
	// Queuing a message is a short memory operation.
	placement = .Owner,
	kind = .Agent_Send,
	execute = tool_agent_send_execute,
}

TOOL_AGENT_STOP_DEFINITION :: Tool_Definition {
	name = TOOL_AGENT_STOP_NAME,
	description = TOOL_AGENT_STOP_DESCRIPTION,
	input_schema = TOOL_AGENT_STOP_SCHEMA,
	hints = {read_only = .No, destructive = .Yes, idempotent = .Yes, open_world = .No},
	placement = .Owner,
	kind = .Agent_Stop,
	execute = tool_agent_stop_execute,
}

Agent_Spawn_Args :: struct {
	instruction: string,
	prompt:      string,
	model:       string,
	provider:    string,
	effort:      string,
	background:  bool,
}

Agent_Send_Args :: struct {
	agent:   string,
	message: string,
}

Agent_Stop_Args :: struct {
	agent: string,
}

tool_agent_spawn_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Agent_Spawn_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_AGENT_SPAWN_FIELDS, allocator = ctx.allocator) or_return
	args.instruction = tool_field_optional_string(arguments, "instruction", allocator = ctx.allocator) or_return
	args.prompt = tool_field_string(arguments, "prompt", allocator = ctx.allocator) or_return
	if strings.trim_space(args.prompt) == "" { return {}, tool_argument_error(.Invalid_Value, "prompt", "a non-empty task", ctx.allocator) }
	args.model = tool_field_optional_string(arguments, "model", allocator = ctx.allocator) or_return
	args.provider = tool_field_optional_string(arguments, "provider", allocator = ctx.allocator) or_return
	args.effort = tool_field_optional_string(arguments, "effort", allocator = ctx.allocator) or_return
	args.background = tool_field_optional_bool(arguments, "background", allocator = ctx.allocator) or_return
	return
}

tool_agent_send_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Agent_Send_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_AGENT_SEND_FIELDS, allocator = ctx.allocator) or_return
	args.agent = tool_field_optional_string(arguments, "agent", allocator = ctx.allocator) or_return
	args.message = tool_field_string(arguments, "message", allocator = ctx.allocator) or_return
	if strings.trim_space(args.message) == "" { return {}, tool_argument_error(.Invalid_Value, "message", "a non-empty message", ctx.allocator) }
	return
}

tool_agent_stop_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Agent_Stop_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_AGENT_STOP_FIELDS, allocator = ctx.allocator) or_return
	args.agent = tool_field_string(arguments, "agent", allocator = ctx.allocator) or_return
	return
}

// TOOL_AGENT_ORCHESTRATOR_ONLY is what a subagent is told when it tries to manage subagents.
TOOL_AGENT_ORCHESTRATOR_ONLY :: "only the orchestrator manages subagents; a subagent cannot start or stop one. If the task needs one, tell the orchestrator with agent_send"

tool_agent_spawn_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Agent_Spawn_Args)
	if ctx.member != nil { return tool_result_failure(ctx, .Unavailable, TOOL_AGENT_ORCHESTRATOR_ONLY, "unavailable") }
	if ctx.agents == nil { return tool_result_failure(ctx, .Unavailable, "subagents are not available in this session", "unavailable") }
	member, problem := subagent_start(ctx.agents, args, ctx.allocator)
	if member == nil { return tool_result_failure(ctx, .Invalid_Arguments, problem, "not started") }

	output := Agent_Output {
		agent  = member.name,
		status = subagent_status_names[.Running],
		model  = fmt.tprintf("%s/%s", member.selection.provider_id, member.selection.model_id),
		effort = member.effort if member.effort != "" else "default",
	}
	if args.background {
		// Copy the reply before launch: a fast child can finish and be reaped immediately.
		result := tool_result_success(ctx, output, fmt.tprintf("%s started", output.agent))
		if result.allocation_failed {
			subagent_fail(member, .Failed, "the start result could not be allocated; nothing ran")
			subagent_finish(member, report = false)
			return result
		}
		if !subagent_launch(member) {
			tool_result_destroy(&result)
			subagent_fail(member, .Failed, "its thread could not be created")
			subagent_finish(member, report = false)
			return tool_result_failure(ctx, .Tool_Failed, "the subagent's thread could not be created", "not started")
		}
		return result
	}

	// A blocking subagent stops with this call.
	member.stop.parent = ctx.control.interrupt
	subagent_run(member)
	output.status = subagent_status_names[member.status]
	output.session = member.session_id
	result: Tool_Result
	switch member.status {
	case .Completed:
		output.answer = member.answer
		result = tool_result_success(ctx, output, fmt.tprintf("%s completed", output.agent))
	case .Stopped:
		result = tool_result_of(ctx, .Cancelled, member.answer, output, "stopped")
	case .Failed, .Running:
		result = tool_result_of(ctx, .Tool_Failed, member.answer, output, "failed")
	}
	// The result owns its copies, so the member may be released once it is done.
	subagent_finish(member, report = false)
	return result
}

tool_agent_send_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Agent_Send_Args)
	if member := ctx.member; member != nil {
		if args.agent != "" && args.agent != "orchestrator" {
			refused := tool_argument_error(.Invalid_Value, "agent", "nothing: a subagent can message only its orchestrator", ctx.allocator)
			return tool_result_refused(ctx, &refused)
		}
		if !subagent_report_message(member, args.message) {
			return tool_result_failure(ctx, .Tool_Failed, "the message could not be allocated", "not sent")
		}
		return tool_result_success(ctx, Agent_Output{agent = "orchestrator", status = "queued"}, "queued")
	}
	if ctx.agents == nil { return tool_result_failure(ctx, .Unavailable, "subagents are not available in this session", "unavailable") }
	if args.agent == "" {
		refused := tool_argument_error(.Missing_Field, "agent", "the id of a running subagent", ctx.allocator)
		return tool_result_refused(ctx, &refused)
	}
	if problem := subagent_send(ctx.agents, args.agent, args.message); problem != "" {
		return tool_result_failure(ctx, .Tool_Failed, problem, "not sent")
	}
	return tool_result_success(ctx, Agent_Output{agent = args.agent, status = "queued"}, "queued")
}

tool_agent_stop_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Agent_Stop_Args)
	if ctx.member != nil { return tool_result_failure(ctx, .Unavailable, TOOL_AGENT_ORCHESTRATOR_ONLY, "unavailable") }
	if ctx.agents == nil { return tool_result_failure(ctx, .Unavailable, "subagents are not available in this session", "unavailable") }
	if problem := subagent_stop(ctx.agents, args.agent); problem != "" {
		return tool_result_failure(ctx, .Tool_Failed, problem, "not stopped")
	}
	return tool_result_success(ctx, Agent_Output{agent = args.agent, status = "stopping"}, "stopping")
}
