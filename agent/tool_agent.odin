package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

import "nabla:agent/journal"

TOOL_AGENT_NAME :: "agent"
TOOL_AGENT_DESCRIPTION :: "Manage subagents with start, message, configure, or stop. Only the orchestrator manages children; a subagent can only message its orchestrator. Call agents with action models to see live native model/provider choices and configured ACP programs. Normally start with only instruction and prompt; override model/provider/effort only when the user or your instructions name them.\n\nStart gives a separate session one narrow task. It sees none of your conversation, so supply all facts, paths, decisions, scope and exactly what to return. Delegate focused research or disjoint edits instead of broad goals. You receive its answer, not its working context; it usually runs cheaper. Do not do delegated work yourself while it runs. Everyone shares one workspace: assign disjoint files, tell each child who else is working and which files it owns, and do not edit its files. Children cannot talk to each other; relay relevant findings yourself.\n\nA background start returns an id at once, or queued when no slot is free. Keep working on independent work; answers arrive as messages. If nothing else can proceed, end your turn and the answer starts a new one. wait true blocks and returns the answer. Message a running or queued child to steer it, change its task, answer questions or pass on findings; delivery is between requests and the call returns at once.\n\nMessage to a finished child reopens the same id and session, including its task, history and last answer, whether it completed, failed, stopped or crashed. Use it for follow-ups and retries instead of repeating the task in a new child. It runs in the background and keeps its last model/effort. Configure with a message to reopen on another selection. A session another process is running cannot be reopened; unknown ids list this session's children and outcomes.\n\nConfigure names only what changes; it needs model, provider, effort or compact true, and may also send a message. A running child switches at its next request; the newest pending switch replaces the previous one. A switch that does not fit compacts first when configuration allows, otherwise the child reports refusal. Compaction installs at a request boundary. A finished child with compact true works while the summary runs if given a message, or ends once the summary installs without one; completion reaches you. ACP children reopen only with session/resume or session/load support. ACP model/effort switches apply between prompts; provider and compact are refused because ACP manages them.\n\nStop returns stopping at once. Work ends at the next step and a notice arrives as a message; a queued child never starts. Existing file changes remain. A finished child cannot be stopped.\n\nA subagent uses message with agent omitted to ask about missing facts, report a wrong premise or share an early finding. The orchestrator's reply arrives as a message."
TOOL_AGENT_SCHEMA :: `{"additionalProperties":false,"properties":{"acp_agent":{"description":"start: configured ACP program name, listed by agents action models. Default: native child. Model and effort are chosen among the program's offerings.","type":["string","null"]},"action":{"description":"start creates a child; message only sends text or reopens a child; configure changes model/provider/effort or compacts; stop cancels.","enum":["start","message","configure","stop"],"type":"string"},"agent":{"description":"message/configure/stop: child id returned by start. Required for the orchestrator. A subagent omits it to message the orchestrator.","type":["string","null"]},"compact":{"description":"configure: true requests compaction at a running child's request boundary, or on reopening a finished native child. Refused for ACP.","type":"boolean"},"effort":{"description":"start/configure: a stated reasoning effort level. start defaults to one level below yours; configure keeps the last effort or the nearest level the model states.","type":["string","null"]},"instruction":{"description":"start: system prompt, how to work and what to return.","type":["string","null"]},"message":{"description":"message: required, non-empty text. configure: optional text; required to reopen a finished child unless compact is true.","type":["string","null"]},"model":{"description":"start/configure: exact catalog model id with its vendor prefix; no aliases. See agents action models. start defaults to your model; configure keeps the child's last model.","type":["string","null"]},"prompt":{"description":"start: one narrow task with all needed facts, paths, scope and return requirements.","type":"string"},"provider":{"description":"start/configure: configured provider id, not a vendor name; needed when several providers serve model. start prefers your provider if it serves model, otherwise the only one that does; configure keeps the last provider.","type":["string","null"]},"wait":{"description":"start: default false, run in the background and deliver the answer later. true blocks and returns the answer; use only when nothing else can proceed before it.","type":["boolean","null"]}},"required":["action"],"type":"object"}`
TOOL_AGENT_MESSAGE_SCHEMA :: `{"additionalProperties":false,"properties":{"action":{"enum":["message"],"type":"string"},"agent":{"description":"Omit to message your orchestrator; no sibling messages.","type":["string","null"]},"message":{"description":"A non-empty message to your orchestrator.","type":"string"}},"required":["action","message"],"type":"object"}`
TOOL_AGENT_START_FIELDS :: []string{"action", "instruction", "prompt", "model", "provider", "effort", "wait", "acp_agent"}
TOOL_AGENT_MESSAGE_FIELDS :: []string{"action", "agent", "message"}
TOOL_AGENT_CONFIGURE_FIELDS :: []string{"action", "agent", "message", "model", "provider", "effort", "compact"}
TOOL_AGENT_STOP_FIELDS :: []string{"action", "agent"}

TOOL_AGENT_DEFINITION :: Tool_Definition {
	name = TOOL_AGENT_NAME,
	description = TOOL_AGENT_DESCRIPTION,
	input_schema = TOOL_AGENT_SCHEMA,
	hints = {read_only = .No, destructive = .Unknown, idempotent = .No, open_world = .Yes},
	placement = .Owner, // start is placed on a worker after argument decoding
	kind = .Agent,
	execute = tool_agent_execute,
}

TOOL_AGENTS_NAME :: "agents"
TOOL_AGENTS_DEFINITION :: Tool_Definition {
	name = TOOL_AGENTS_NAME,
	description = "Observe without changing a child or sending messages. list shows every child's name, status and session. status reads one child's journal: last selection, newest record and age, last failure, last Assistant text marked partial when applicable, unread messages and a resume call. models lists live configured providers and their model ids, known context/effort/cost facts, ACP programs and your current model/effort. Unknown ids list known children. Orchestrator only.",
	input_schema = `{"additionalProperties":false,"properties":{"action":{"description":"Default list. status inspects one child; models lists live provider/model and ACP choices.","enum":["list","status","models"],"type":"string"},"agent":{"description":"status only: required child id returned by agent action start.","type":"string"}},"type":"object"}`,
	hints = {read_only = .Yes, destructive = .No, idempotent = .Yes, open_world = .No},
	placement = .Owner,
	kind = .Agents,
	execute = tool_agents_execute,
}

Agent_Start_Args :: struct {
	instruction: string,
	prompt:      string,
	model:       string,
	provider:    string,
	effort:      string,
	wait:        bool, // block until the answer; a subagent runs in the background otherwise
	acp_agent:   string,
}

Agent_Message_Action :: enum {
	Message,
	Configure,
}

Agent_Message_Args :: struct {
	action:   Agent_Message_Action,
	agent:    string,
	message:  string,
	model:    string,
	provider: string,
	effort:   string,
	compact:  bool, // compact the finished child's context as it reopens; message may then be empty
	// refusal is why dispatch did not record the message, set by the owner just before the
	// executor runs; "" when the message was recorded or the executor judges the call itself.
	refusal:  string,
	// resume is set by the owner, with refusal, when the message continues a finished child:
	// resume.name borrows agent, and the other strings live in temp memory until the executor
	// returns.
	resume:   Subagent_Resume,
	// control is set by the owner, with the message, when the call changes a running child: the
	// switch already resolved and the compaction asked for. The job owns it until the executor
	// hands it to the child; a dispatch that cannot commit releases it.
	control:  Subagent_Control,
}

Agent_Stop_Args :: struct {
	agent: string,
}

Agents_Action :: enum {
	List,
	Status,
	Models,
}

Agents_Args :: struct {
	action: Agents_Action,
	agent:  string,
}

@(require_results)
tool_agent_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Tool_Args, err: Tool_Argument_Error) {
	action := tool_field_string(arguments, "action", allocator = ctx.allocator) or_return
	switch action {
	case "start":
		return tool_agent_start_args(ctx, arguments)
	case "message":
		return tool_agent_message_args(ctx, arguments, .Message)
	case "configure":
		return tool_agent_message_args(ctx, arguments, .Configure)
	case "stop":
		return tool_agent_stop_args(ctx, arguments)
	}
	return nil, tool_argument_error(.Invalid_Value, "action", "start, message, configure, or stop", ctx.allocator)
}

@(require_results)
tool_agents_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Agents_Args, err: Tool_Argument_Error) {
	action := tool_field_optional_string(arguments, "action", allocator = ctx.allocator) or_return
	switch action {
	case "", "list":
		args.action = .List
	case "status":
		args.action = .Status
	case "models":
		args.action = .Models
	case:
		return {}, tool_argument_error(.Invalid_Value, "action", "list, status, or models", ctx.allocator)
	}
	if args.action == .Status {
		tool_fields_known(arguments, {"action", "agent"}, path = "agents(status)", allocator = ctx.allocator) or_return
		args.agent = tool_field_string(arguments, "agent", allocator = ctx.allocator) or_return
		if strings.trim_space(args.agent) == "" { return {}, tool_argument_error(.Invalid_Value, "agent", "a non-empty child id", ctx.allocator) }
	} else {
		tool_fields_known(arguments, {"action"}, path = "agents(models)" if args.action == .Models else "agents(list)", allocator = ctx.allocator) or_return
	}
	return
}

@(require_results)
tool_agents_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	if ctx.member != nil { return tool_result_failure(ctx, .Unavailable, TOOL_AGENT_ORCHESTRATOR_ONLY, "unavailable") }
	args := arguments.(Agents_Args)
	if args.action == .Models {
		if ctx.agents == nil { return tool_result_failure(ctx, .Unavailable, "subagents are not available in this session", "unavailable") }
		text, allocation_error := tool_agents_models(ctx.agents)
		if allocation_error != nil { return tool_result_failure(ctx, .Tool_Failed, "model choices could not be allocated", "not read") }
		return tool_result_success(ctx, Agents_Output{content = text}, "models")
	}
	if ctx.status_store == nil { return tool_result_failure(ctx, .Unavailable, "subagents are not available in this session", "unavailable") }
	text, problem := subagent_status_format(ctx.status_store, ctx.status_session, args.agent, ctx.agents)
	if problem != "" { return tool_result_failure(ctx, .Tool_Failed, problem, "not read") }
	return tool_result_success(ctx, Agents_Output{content = text}, "status" if args.action == .Status else "list")
}

@(require_results)
tool_agent_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	#partial switch args in arguments {
	case Agent_Start_Args:
		return tool_agent_start_execute(ctx, args)
	case Agent_Message_Args:
		if ctx.member != nil && args.action != .Message { return tool_result_failure(ctx, .Unavailable, TOOL_AGENT_ORCHESTRATOR_ONLY, "unavailable") }
		return tool_agent_message_execute(ctx, args)
	case Agent_Stop_Args:
		return tool_agent_stop_execute(ctx, args)
	case:
		return tool_result_failure(ctx, .Invalid_Arguments, "agent needs a valid action", "not executed")
	}
}

@(require_results)
tool_agent_start_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Agent_Start_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_AGENT_START_FIELDS, path = "agent(start)", allocator = ctx.allocator) or_return
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
tool_agent_message_args :: proc(
	ctx: ^Tool_Context,
	arguments: json.Object,
	action: Agent_Message_Action,
) -> (
	args: Agent_Message_Args,
	err: Tool_Argument_Error,
) {
	fields := TOOL_AGENT_CONFIGURE_FIELDS if action == .Configure else TOOL_AGENT_MESSAGE_FIELDS
	path := "agent(configure)" if action == .Configure else "agent(message)"
	tool_fields_known(arguments, fields, path = path, allocator = ctx.allocator) or_return
	args.action = action
	args.agent = tool_field_optional_string(arguments, "agent", allocator = ctx.allocator) or_return
	args.compact = tool_field_optional_bool(arguments, "compact", allocator = ctx.allocator) or_return
	args.model = tool_field_optional_string(arguments, "model", allocator = ctx.allocator) or_return
	args.provider = tool_field_optional_string(arguments, "provider", allocator = ctx.allocator) or_return
	args.effort = tool_field_optional_string(arguments, "effort", allocator = ctx.allocator) or_return
	if args.compact || args.model != "" || args.provider != "" || args.effort != "" {
		args.message = tool_field_optional_string(arguments, "message", allocator = ctx.allocator) or_return
	} else {
		if action ==
		   .Configure { return {}, tool_argument_error(.Invalid_Value, "action", "configure with model, provider, effort, or compact true; use message for plain text", ctx.allocator) }
		args.message = tool_field_string(arguments, "message", allocator = ctx.allocator) or_return
		if strings.trim_space(args.message) == "" { return {}, tool_argument_error(.Invalid_Value, "message", "a non-empty message", ctx.allocator) }
	}
	return
}

@(require_results)
tool_agent_stop_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Agent_Stop_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_AGENT_STOP_FIELDS, path = "agent(stop)", allocator = ctx.allocator) or_return
	args.agent = tool_field_string(arguments, "agent", allocator = ctx.allocator) or_return
	return
}

// tool_registry_remove_agent_management gives subagents only the message action of agent.
// Allocation failure leaves agent unchanged. The registry owns the replacement strings.
@(require_results)
tool_registry_remove_agent_management :: proc(registry: ^Tool_Registry) -> mem.Allocator_Error {
	for &definition in registry.definitions {
		if definition.kind != .Agent || definition.input_schema == TOOL_AGENT_MESSAGE_SCHEMA { continue }
		description, description_error := strings.clone(TOOL_AGENT_MESSAGE_DESCRIPTION, registry.allocator)
		if description_error != nil { return description_error }
		schema, schema_error := strings.clone(TOOL_AGENT_MESSAGE_SCHEMA, registry.allocator)
		if schema_error != nil {
			delete(description, registry.allocator)
			return schema_error
		}
		delete(definition.description, registry.allocator)
		delete(definition.input_schema, registry.allocator)
		definition.description = description
		definition.input_schema = schema
		definition.hints = {
			read_only   = .No,
			destructive = .No,
			idempotent  = .No,
			open_world  = .No,
		}
	}
	for index := len(registry.definitions) - 1; index >= 0; index -= 1 {
		definition := &registry.definitions[index]
		if definition.kind == .Agents {
			tool_definition_destroy(definition, registry.allocator)
			ordered_remove(&registry.definitions, index)
		}
	}
	return nil
}

TOOL_AGENT_MESSAGE_DESCRIPTION :: "Message your orchestrator with action message and agent omitted. Ask about missing facts or scope, report a wrong premise, or share an early finding it can act on. Its reply arrives as a message. Subagents cannot message siblings or manage subagents."

// tool_agents_models renders live catalog choices in temporary memory. Owner only.
// It holds the catalog lock only while reading metadata and copying it into the result.
@(private, require_results)
tool_agents_models :: proc(team: ^Agent_Team) -> (text: string, err: mem.Allocator_Error) {
	parts := make([dynamic]string, context.temp_allocator) or_return
	catalog: Catalog_Ref
	{
		sync.mutex_guard(&team.mutex)
		parent := &team.parent
		catalog = parent.catalog
		append(
			&parts,
			fmt.tprintf("current: %s/%s, effort %s\n", parent.provider_id, parent.model_id, parent.effort if parent.effort != "" else "default"),
		) or_return
		append(&parts, "ACP agents:\n") or_return
		if len(parent.acp_agents) == 0 { append(&parts, "  none configured\n") or_return }
		for program in parent.acp_agents {
			append(&parts, fmt.tprintf("  %s: %s\n", program.name, program.description)) or_return
		}
	}
	append(&parts, "Native providers and models (pass model id and provider id separately):\n") or_return
	if catalog.catalog == nil {
		append(&parts, "  no catalog available\n") or_return
		return strings.concatenate(parts[:], context.temp_allocator)
	}
	if catalog.mutex != nil { sync.mutex_lock(catalog.mutex) }
	defer if catalog.mutex != nil { sync.mutex_unlock(catalog.mutex) }
	for &provider in catalog.catalog.providers {
		if !provider_usable(&provider) { continue }
		append(&parts, fmt.tprintf("provider: %s\n", provider.id)) or_return
		for model in catalog.catalog.models {
			if model.provider_id != provider.id { continue }
			append(&parts, "  ", provider.id, "/", model.id) or_return
			if window, known := model.context_window.?; known { append(&parts, fmt.tprintf("; context %d tokens", window)) or_return }
			if output, known := model.max_output_tokens.?; known { append(&parts, fmt.tprintf("; max output %d tokens", output)) or_return }
			levels := model.thinking.levels.? or_else nil
			if len(levels) > 0 {
				append(&parts, "; effort ") or_return
				for level, index in levels {
					if index > 0 { append(&parts, ", ") or_return }
					append(&parts, level) or_return
				}
			} else {
				append(&parts, "; no stated effort levels") or_return
			}
			if price, known := model.cost.input.?; known { append(&parts, fmt.tprintf("; input $%g/M tokens", price)) or_return }
			if price, known := model.cost.output.?; known { append(&parts, fmt.tprintf("; output $%g/M tokens", price)) or_return }
			if price, known := model.cost.cache_read.?; known { append(&parts, fmt.tprintf("; cache read $%g/M tokens", price)) or_return }
			if price, known := model.cost.cache_write.?; known { append(&parts, fmt.tprintf("; cache write $%g/M tokens", price)) or_return }
			append(&parts, "\n") or_return
		}
	}
	return strings.concatenate(parts[:], context.temp_allocator)
}

// TOOL_AGENT_ORCHESTRATOR_ONLY is what a subagent is told when it tries to manage subagents.
TOOL_AGENT_ORCHESTRATOR_ONLY :: "only the orchestrator manages subagents; a subagent can only message its orchestrator with agent action message, omitting agent"

// tool_agent_started_output describes a child that was just defined and has not run yet.
// requested_effort is the effort the call named, which the child runs without when its model
// does not state it, and the output says so. Its texts borrow member, except the temp-allocated
// ones.
@(private)
tool_agent_started_output :: proc(member: ^Subagent, requested_effort: string) -> Agent_Output {
	session_hex := make([]u8, journal.SESSION_ID_HEX_LENGTH, context.temp_allocator)
	output := Agent_Output {
		agent   = member.name,
		status  = subagent_status_names[.Running],
		model   = fmt.tprintf("%s/%s", member.selection.provider_id, member.selection.model_id),
		effort  = member.effort if member.effort != "" else "default",
		session = journal.session_id_to_hex(member.session, session_hex),
	}
	if member.program.name != "" {
		output.model = member.program.model if member.program.model != "" else "the agent's default"
		output.effort = member.effort if member.effort != "" else "one level below yours, if the agent offers levels"
		output.acp_session = member.acp_session
		return output
	}
	if requested_effort != "" && requested_effort != member.effort {
		output.notice = fmt.tprintf("effort %q is not a level of this model, so it runs as if effort were left out", requested_effort)
	}
	return output
}

// tool_agent_launch starts member in the background and answers the call at once: output
// with status running and summary "<name> <verb>", or queued when no slot is free. The texts
// that borrow member are copied before the launch, after which a quick child may already have
// been reaped, and the reply of a child that waits for a slot is rebuilt from the copies.
@(private, require_results)
tool_agent_launch :: proc(ctx: ^Tool_Context, member: ^Subagent, output: Agent_Output, verb: string) -> Tool_Result {
	output := output
	for field in ([]^string{&output.agent, &output.model, &output.effort, &output.acp_session}) {
		cloned, clone_error := strings.clone(field^, context.temp_allocator)
		if clone_error != nil {
			subagent_fail(member, .Failed, "the start result could not be allocated; nothing ran")
			subagent_finish(member)
			return tool_result_failure(ctx, .Tool_Failed, "the start result could not be allocated; nothing ran", "not started")
		}
		field^ = cloned
	}
	result := tool_result_success(ctx, output, fmt.tprintf("%s %s", output.agent, verb))
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
	// member may be gone by now.
	if queued {
		tool_result_destroy(&result)
		output.status = subagent_status_names[.Queued]
		return tool_result_success(ctx, output, queued_summary)
	}
	return result
}

@(require_results)
tool_agent_start_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Agent_Start_Args)
	if ctx.member != nil { return tool_result_failure(ctx, .Unavailable, TOOL_AGENT_ORCHESTRATOR_ONLY, "unavailable") }
	if ctx.agents == nil { return tool_result_failure(ctx, .Unavailable, "subagents are not available in this session", "unavailable") }
	member, problem := subagent_start(ctx.agents, args, ctx.call, ctx.subagent, ctx.allocator)
	if member == nil { return tool_result_failure(ctx, .Invalid_Arguments, problem, "not started") }
	ctx.subagent_started = true

	output := tool_agent_started_output(member, args.effort)
	if !args.wait { return tool_agent_launch(ctx, member, output, "started") }

	// A blocking subagent stops with this call.
	subagent_take_slot(member)
	member.stop.parent = ctx.control.interrupt
	member.parent_wake = ctx.control.wake
	subagent_run(member)
	output.status = subagent_status_names[member.status]
	output.acp_session = member.acp_session
	output.answer = member.answer
	result: Tool_Result
	switch member.status {
	case .Completed:
		result = tool_result_success(ctx, output, fmt.tprintf("%s completed", output.agent))
	case .Stopped:
		result = tool_result_of(ctx, .Cancelled, member.cause, output, "stopped")
	case .Failed, .Running, .Queued:
		result = tool_result_of(ctx, .Tool_Failed, member.cause, output, "failed")
	}
	// The result owns its copies, so the member may be released once it is done.
	subagent_finish(member)
	return result
}

// tool_agent_resume continues the finished child dispatch recorded for this call, in the
// background, with the model, provider, and effort the call named or else the ones its last
// turn used. The message was recorded with the call's admission, and the child's first step
// delivers it.
@(private, require_results)
tool_agent_resume :: proc(ctx: ^Tool_Context, args: Agent_Message_Args) -> Tool_Result {
	start := Agent_Start_Args {
		instruction = args.resume.instruction,
		acp_agent   = args.resume.program,
		prompt      = args.message, // empty only for a compaction that continues with no message
		model       = args.model,
		provider    = args.provider,
		effort      = args.effort,
	}
	if start.acp_agent != "" {
		if start.model == "" { start.model = args.resume.model_id }
		if start.effort == "" { start.effort = args.resume.effort }
	}
	member, problem := subagent_start(ctx.agents, start, ctx.call, ctx.subagent, ctx.allocator, args.resume)
	if member == nil { return tool_result_failure(ctx, .Invalid_Arguments, problem, "not resumed") }
	ctx.subagent_started = true
	return tool_agent_launch(ctx, member, tool_agent_started_output(member, args.effort), "resumed")
}

// tool_agent_queued_notice says what a call queued for a running child. The text is
// temp-allocated.
@(private)
tool_agent_queued_notice :: proc(args: Agent_Message_Args) -> string {
	queued := make([dynamic]string, context.temp_allocator)
	if args.message != "" { append(&queued, "the message") }
	if args.control.switching {
		selection := args.control.selection
		effort := args.control.effort if args.control.effort != "" else "default"
		if selection.model_id == "" {
			append(
				&queued,
				fmt.tprintf(
					"an ACP model/effort switch to %s at effort %s",
					args.control.acp_model if args.control.acp_model != "" else "the current model",
					effort,
				),
			)
		} else {
			append(&queued, fmt.tprintf("a switch to %s/%s at effort %s", selection.provider_id, selection.model_id, effort))
		}
	}
	if args.control.compact { append(&queued, "a compaction") }
	joined, _ := strings.join(queued[:], ", ", context.temp_allocator)
	return fmt.tprintf("queued for the running child: %s; it takes effect at the child's next request", joined)
}

@(require_results)
tool_agent_message_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Agent_Message_Args)
	if member := ctx.member; member != nil {
		if args.agent != "" && args.agent != "orchestrator" {
			refused := tool_argument_error(.Invalid_Value, "agent", "nothing: a subagent can message only its orchestrator", ctx.allocator)
			return tool_result_refused(ctx, &refused)
		}
		if args.model != "" || args.provider != "" || args.effort != "" || args.compact {
			refused := tool_argument_error(.Invalid_Value, "model", "nothing: only an orchestrator chooses a model for a subagent", ctx.allocator)
			return tool_result_refused(ctx, &refused)
		}
		return tool_result_success(ctx, Agent_Output{agent = "orchestrator", status = "queued"}, "queued")
	}
	if ctx.agents == nil { return tool_result_failure(ctx, .Unavailable, "subagents are not available in this session", "unavailable") }
	if args.agent == "" {
		refused := tool_argument_error(.Missing_Field, "agent", "the id of a subagent", ctx.allocator)
		return tool_result_refused(ctx, &refused)
	}
	if args.refusal != "" { return tool_result_failure(ctx, .Tool_Failed, args.refusal, "not sent") }
	if args.resume.name != "" { return tool_agent_resume(ctx, args) }
	output := Agent_Output {
		agent  = args.agent,
		status = "queued",
	}
	if args.control.switching || args.control.compact {
		output.notice = tool_agent_queued_notice(args)
		subagent_control_apply(ctx.agents, args.agent, &args.control)
	}
	return tool_result_success(ctx, output, "queued")
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
