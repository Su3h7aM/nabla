package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

TOOL_AGENT_SPAWN_NAME :: "agent_spawn"
TOOL_AGENT_SPAWN_DESCRIPTION :: "Start a subagent: a separate agent in a new session that works on one task in parallel with you and sends back only its answer. Delegate to keep your context small and to spend less: the subagent reads the files, runs the searches and commands, and works through the details, and you receive only the result you asked for. It usually runs cheaper than you, so give it bounded work such as investigating one area, tracing one behavior, or making one well-specified edit.\n\nScope each subagent narrowly. It sees none of your conversation, so prompt must state one specific task, every fact, decision, and path it needs (or exactly where to find them), what is out of scope, and exactly what to return. Write \"find where the session cache key is computed and report the file, line, and every caller\", not \"fix the caching bug\": a broad goal makes it wander and do work you did not need. instruction is its system prompt: how to work and the form of its answer. Split broad work into several focused subagents that run at once.\n\nA task you delegate is no longer yours: do not do it, or any part of it, yourself while the subagent runs. Work on something else or wait for the answer; doing the same work twice wastes what delegation saves, and your edits can collide with its edits.\n\nYou and every subagent share one workspace with no isolation, so an agent can overwrite or undo another agent's changes. Subagents cannot talk to each other, so coordinating them is your job. When several run at once, give each a task that touches files no other agent edits, and tell each in its prompt that other agents are working in the same workspace, which files are its own, and which it must leave alone. Do not edit a subagent's files yourself while it runs. When one subagent's work affects another's, relay what matters with agent_send.\n\nNormally pass only instruction and prompt. The defaults run your model at one effort level below yours, in the background. Set model, provider, or effort only when the user or your instruction files name the ones to use. model is a catalog model id with its vendor prefix, exactly as listed, such as anthropic/claude-sonnet-5-5; a short name like claude-sonnet-5-5 is not an alias and fails, and the error lists the models of your provider. provider is the id of a configured provider, not a vendor name, needed only when several providers serve the model; an unknown one fails and the error lists the configured providers.\n\nThe call returns the agent id at once. Keep working on anything that does not need the answer; the answer arrives later as a message, and if you have nothing else to do, end your turn and the answer starts a new one. While it runs, steer it with agent_send when you learn something that changes its task, answer its questions the same way, and stop it with agent_stop when its work is no longer needed. Set wait to true only when your very next step needs the answer and nothing else can proceed meanwhile; the call then blocks and returns the answer.\n\nWith acp_agent set, the subagent is that configured agent program, driven over the Agent Client Protocol, and model and effort are chosen among what it offers. Only the orchestrator can start subagents."
TOOL_AGENT_SPAWN_SCHEMA :: `{"type":"object","properties":{"instruction":{"type":["string","null"],"description":"The subagent's system prompt: how to work and what its answer must contain."},"prompt":{"type":"string","description":"One narrowly scoped task with every fact the subagent needs and exactly what it must return."},"model":{"type":["string","null"],"description":"Catalog model id with its vendor prefix, exactly as listed, such as anthropic/claude-sonnet-5-5; no alias or short name resolves. Leave out unless the user or your instructions name one. Default: your model."},"provider":{"type":["string","null"],"description":"Id of a configured provider (one with base_url, api, and api_key), not a vendor name such as openai. Needed only when several providers serve model. Default: your provider if it serves model, else the only provider that does."},"effort":{"type":["string","null"],"description":"Reasoning effort level. Leave out unless the user or your instructions name one. Default: one level below yours."},"wait":{"type":["boolean","null"],"description":"Block until the subagent finishes and return its answer. Default: false, run in the background and deliver the answer later as a message."},"acp_agent":{"type":["string","null"],"description":"Name of a configured ACP agent program to run as the subagent. Default: a native subagent."}},"required":["prompt"],"additionalProperties":false}`
TOOL_AGENT_SPAWN_FIELDS :: []string{"instruction", "prompt", "model", "provider", "effort", "wait", "acp_agent"}

TOOL_AGENT_SEND_NAME :: "agent_send"
TOOL_AGENT_SEND_DESCRIPTION :: "Send a message to another agent while it works. It reaches the recipient between its model requests, like a line the user types, and returns at once. The orchestrator names a running subagent in agent, which is required, to steer it: correct its course, narrow or change its task, answer its question, or pass on a fact that changes its work, instead of letting it finish the wrong job or stopping and restarting it. A subagent leaves agent out to message its orchestrator: ask about missing or ambiguous information, report that the task rests on a wrong premise, or share an early finding the orchestrator can act on now. A reply arrives as a message. A subagent that has finished takes no more messages, and subagents cannot message each other."
TOOL_AGENT_SEND_SCHEMA :: `{"type":"object","properties":{"agent":{"type":["string","null"],"description":"The subagent id that agent_spawn returned, such as agent-1. Required for the orchestrator; a subagent leaves it out to message its orchestrator."},"message":{"type":"string","description":"The message."}},"required":["message"],"additionalProperties":false}`
TOOL_AGENT_SEND_FIELDS :: []string{"agent", "message"}

TOOL_AGENT_STOP_NAME :: "agent_stop"
TOOL_AGENT_STOP_DESCRIPTION :: "Stop a running or queued subagent when its work is no longer needed or has gone wrong. The call returns at once with status stopping; the subagent's work ends at its next step and a notice that it stopped arrives as a message. A queued subagent never starts. Files it already changed stay as they are. A subagent that has finished cannot be stopped. Only the orchestrator can stop subagents."
TOOL_AGENT_STOP_SCHEMA :: `{"type":"object","properties":{"agent":{"type":"string","description":"The subagent id that agent_spawn returned, such as agent-1."}},"required":["agent"],"additionalProperties":false}`
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
	wait:        bool, // block until the answer; a subagent runs in the background otherwise
	acp_agent:   string,
}

Agent_Send_Args :: struct {
	agent:   string,
	message: string,
	// refusal is why dispatch did not record the message, set by the owner just before the
	// executor runs; "" when the message was recorded or the executor judges the call itself.
	refusal: string,
}

Agent_Stop_Args :: struct {
	agent: string,
}

@(require_results)
tool_agent_spawn_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Agent_Spawn_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_AGENT_SPAWN_FIELDS, allocator = ctx.allocator) or_return
	args.instruction = tool_field_optional_string(arguments, "instruction", allocator = ctx.allocator) or_return
	args.prompt = tool_field_string(arguments, "prompt", allocator = ctx.allocator) or_return
	if strings.trim_space(args.prompt) == "" { return {}, tool_argument_error(.Invalid_Value, "prompt", "a non-empty task", ctx.allocator) }
	args.model = tool_field_optional_string(arguments, "model", allocator = ctx.allocator) or_return
	args.provider = tool_field_optional_string(arguments, "provider", allocator = ctx.allocator) or_return
	args.effort = tool_field_optional_string(arguments, "effort", allocator = ctx.allocator) or_return
	args.wait = tool_field_optional_bool(arguments, "wait", allocator = ctx.allocator) or_return
	args.acp_agent = tool_field_optional_string(arguments, "acp_agent", allocator = ctx.allocator) or_return
	return
}

@(require_results)
tool_agent_send_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Agent_Send_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_AGENT_SEND_FIELDS, allocator = ctx.allocator) or_return
	args.agent = tool_field_optional_string(arguments, "agent", allocator = ctx.allocator) or_return
	args.message = tool_field_string(arguments, "message", allocator = ctx.allocator) or_return
	if strings.trim_space(args.message) == "" { return {}, tool_argument_error(.Invalid_Value, "message", "a non-empty message", ctx.allocator) }
	return
}

@(require_results)
tool_agent_stop_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Agent_Stop_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_AGENT_STOP_FIELDS, allocator = ctx.allocator) or_return
	args.agent = tool_field_string(arguments, "agent", allocator = ctx.allocator) or_return
	return
}

// tool_registry_describe_agents names the configured ACP agents in the spawn tool's description,
// so the model knows which it may start. agents is borrowed.
@(require_results)
tool_registry_describe_agents :: proc(registry: ^Tool_Registry, agents: []ACP_Agent_Config) -> Tool_Registry_Error {
	index := -1
	for definition, position in registry.definitions {
		if definition.kind == .Agent_Spawn { index = position }
	}
	if index < 0 { return {} }
	parts, parts_error := make([dynamic]string, 0, 2 + 4 * len(agents), context.temp_allocator)
	if parts_error != nil { return {kind = .Allocation, tool = TOOL_AGENT_SPAWN_NAME, detail = "the description could not be built"} }
	if describe_error := tool_agent_description_parts(&parts, agents); describe_error != nil {
		return {kind = .Allocation, tool = TOOL_AGENT_SPAWN_NAME, detail = "the description could not be built"}
	}
	description, allocation_error := strings.concatenate(parts[:], registry.allocator)
	if allocation_error != nil { return {kind = .Allocation, tool = TOOL_AGENT_SPAWN_NAME, detail = "the description could not be built"} }
	definition := &registry.definitions[index]
	delete(definition.description, registry.allocator)
	definition.description = description
	return {}
}

// tool_agent_description_parts collects the parts of the spawn description, naming the
// configured ACP agents. The parts borrow agents.
@(private = "file", require_results)
tool_agent_description_parts :: proc(parts: ^[dynamic]string, agents: []ACP_Agent_Config) -> mem.Allocator_Error {
	append(parts, TOOL_AGENT_SPAWN_DESCRIPTION) or_return
	if len(agents) == 0 { append(parts, " No ACP agents are configured, so leave acp_agent out.") or_return }
	if len(agents) > 0 { append(parts, " Configured ACP agents:") or_return }
	for agent in agents {
		append(parts, "\n- ", agent.name) or_return
		if agent.description != "" { append(parts, ": ", agent.description) or_return }
	}
	return nil
}

// TOOL_AGENT_ORCHESTRATOR_ONLY is what a subagent is told when it tries to manage subagents.
TOOL_AGENT_ORCHESTRATOR_ONLY :: "only the orchestrator manages subagents; a subagent cannot start or stop one. If the task needs one, tell the orchestrator with agent_send"

@(require_results)
tool_agent_spawn_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Agent_Spawn_Args)
	if ctx.member != nil { return tool_result_failure(ctx, .Unavailable, TOOL_AGENT_ORCHESTRATOR_ONLY, "unavailable") }
	if ctx.agents == nil { return tool_result_failure(ctx, .Unavailable, "subagents are not available in this session", "unavailable") }
	member, problem := subagent_start(ctx.agents, args, ctx.call, ctx.subagent, ctx.allocator)
	if member == nil { return tool_result_failure(ctx, .Invalid_Arguments, problem, "not started") }
	ctx.subagent_started = true

	output := Agent_Output {
		agent  = member.name,
		status = subagent_status_names[.Running],
		model  = fmt.tprintf("%s/%s", member.selection.provider_id, member.selection.model_id),
		effort = member.effort if member.effort != "" else "default",
	}
	if args.effort != "" && args.effort != member.effort {
		output.notice = fmt.tprintf("effort %q is not a level of this model, so it runs as if effort were left out", args.effort)
	}
	if member.program.name != "" {
		// The agent program states its models and efforts only once it runs.
		output.model = member.program.model if member.program.model != "" else "the agent's default"
		output.effort = args.effort if args.effort != "" else "one level below yours, if the agent offers levels"
		output.notice = ""
	}
	if !args.wait {
		// Copy the reply before launch: a fast child can finish and be reaped immediately.
		// The texts that borrow from member are copied too, for the queued reply below.
		output.agent = fmt.tprintf("%s", member.name)
		output.effort = fmt.tprintf("%s", output.effort)
		output.model = fmt.tprintf("%s", output.model)
		result := tool_result_success(ctx, output, fmt.tprintf("%s started", output.agent))
		if result.allocation_failed {
			subagent_fail(member, .Failed, "the start result could not be allocated; nothing ran")
			subagent_finish(member)
			return result
		}
		queued_summary := fmt.tprintf("%s queued", output.agent)
		queued, launched := subagent_launch(member)
		if !launched {
			tool_result_destroy(&result)
			subagent_fail(member, .Failed, "its thread could not be created")
			subagent_finish(member)
			return tool_result_failure(ctx, .Tool_Failed, "the subagent's thread could not be created", "not started")
		}
		// member may be gone by now, so the reply of a child that waits for a slot is rebuilt
		// from the copies.
		if queued {
			tool_result_destroy(&result)
			output.status = subagent_status_names[.Queued]
			return tool_result_success(ctx, output, queued_summary)
		}
		return result
	}

	// A blocking subagent stops with this call.
	subagent_take_slot(member)
	member.stop.parent = ctx.control.interrupt
	member.parent_wake = ctx.control.wake
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
	case .Failed, .Running, .Queued:
		result = tool_result_of(ctx, .Tool_Failed, member.answer, output, "failed")
	}
	// The result owns its copies, so the member may be released once it is done.
	subagent_finish(member)
	return result
}

@(require_results)
tool_agent_send_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Agent_Send_Args)
	if member := ctx.member; member != nil {
		if args.agent != "" && args.agent != "orchestrator" {
			refused := tool_argument_error(.Invalid_Value, "agent", "nothing: a subagent can message only its orchestrator", ctx.allocator)
			return tool_result_refused(ctx, &refused)
		}
		return tool_result_success(ctx, Agent_Output{agent = "orchestrator", status = "queued"}, "queued")
	}
	if ctx.agents == nil { return tool_result_failure(ctx, .Unavailable, "subagents are not available in this session", "unavailable") }
	if args.agent == "" {
		refused := tool_argument_error(.Missing_Field, "agent", "the id of a running subagent", ctx.allocator)
		return tool_result_refused(ctx, &refused)
	}
	if args.refusal != "" { return tool_result_failure(ctx, .Tool_Failed, args.refusal, "not sent") }
	return tool_result_success(ctx, Agent_Output{agent = args.agent, status = "queued"}, "queued")
}

@(require_results)
tool_agent_stop_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Agent_Stop_Args)
	if ctx.member != nil { return tool_result_failure(ctx, .Unavailable, TOOL_AGENT_ORCHESTRATOR_ONLY, "unavailable") }
	if ctx.agents == nil { return tool_result_failure(ctx, .Unavailable, "subagents are not available in this session", "unavailable") }
	if problem := subagent_stop(ctx.agents, args.agent); problem != "" {
		return tool_result_failure(ctx, .Tool_Failed, problem, "not stopped")
	}
	return tool_result_success(ctx, Agent_Output{agent = args.agent, status = "stopping"}, "stopping")
}
