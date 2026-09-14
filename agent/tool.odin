package agent

import "core:encoding/json"
import "core:mem"
import "core:slice"
import "core:strings"

import "nabla:agent/session"
import "nabla:agent/skills"
import "nabla:ai"

// Tool_Control is the caller's interruption policy for one execution. A zero
// value runs with no cancellation and no deadline.
Tool_Control :: struct {
	interrupt: ^ai.Interrupt,
	deadline:  ai.Deadline,
}

// Tool_Context is what one execution is given besides its arguments. Every
// string is borrowed and lives for the call.
Tool_Context :: struct {
	call_id:   string,
	workspace: string,
	control:   Tool_Control,
	allocator: mem.Allocator,
	skills:    ^skills.Catalog,
}

// Tool_Execute runs one admitted call. Returning .Invalid_Arguments promises the
// tool performed no effect, which is what lets dispatch record the refusal as a
// call that did not run.
Tool_Execute :: #type proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result

// Tool_Definition is one tool the harness can run. The strings are owned by the
// registry that holds the definition.
Tool_Definition :: struct {
	name:         string,
	description:  string,
	input_schema: string,
	execute:      Tool_Execute,
}

// Tool_Registry owns the tools available to a session. It is built before the
// first turn and is not mutated while a turn runs, so a turn borrows it.
Tool_Registry :: struct {
	definitions: [dynamic]Tool_Definition,
	allocator:   mem.Allocator,
}

tool_registry_make :: proc(allocator := context.allocator) -> Tool_Registry {
	registry := Tool_Registry {
		allocator = allocator,
	}
	registry.definitions = make([dynamic]Tool_Definition, 0, len(TOOL_NATIVE), allocator)
	for definition in TOOL_NATIVE { tool_registry_add(&registry, definition) }
	tool_registry_sort(&registry)
	return registry
}

tool_registry_destroy :: proc(registry: ^Tool_Registry) {
	for &definition in registry.definitions { tool_definition_destroy(&definition, registry.allocator) }
	delete(registry.definitions)
	registry^ = {}
}

// tool_registry_add copies a definition into the registry. A name already in use
// is refused rather than replaced: two tools sharing a name would make dispatch
// a coin toss.
tool_registry_add :: proc(registry: ^Tool_Registry, definition: Tool_Definition) -> bool {
	if definition.name == "" || definition.execute == nil { return false }
	if _, present := tool_registry_find(registry, definition.name); present { return false }
	append(
		&registry.definitions,
		Tool_Definition {
			name = strings.clone(definition.name, registry.allocator),
			description = strings.clone(definition.description, registry.allocator),
			input_schema = strings.clone(definition.input_schema, registry.allocator),
			execute = definition.execute,
		},
	)
	return true
}

tool_registry_find :: proc(registry: ^Tool_Registry, name: string) -> (^Tool_Definition, bool) {
	for &definition in registry.definitions {
		if definition.name == name { return &definition, true }
	}
	return nil, false
}

// tool_registry_sort fixes the advertisement order, so the cacheable prefix does
// not depend on the order tools were registered in.
tool_registry_sort :: proc(registry: ^Tool_Registry) {
	slice.sort_by(registry.definitions[:], proc(a, b: Tool_Definition) -> bool { return a.name < b.name })
}

tool_definition_destroy :: proc(definition: ^Tool_Definition, allocator: mem.Allocator) {
	delete(definition.name, allocator)
	delete(definition.description, allocator)
	delete(definition.input_schema, allocator)
	definition^ = {}
}

// --- results -----------------------------------------------------------------

// Tool_Empty is the data of a result that carries none of its own.
Tool_Empty :: struct {}

// Tool_Content is the one shape every tool result carries. status names the
// outcome and message explains it; data is the tool's own shape, and a result
// with nothing to report carries an empty object.
Tool_Content :: struct($T: typeid) {
	status:  string `json:"status"`,
	message: string `json:"message"`,
	data:    T `json:"data"`,
}

// Tool_Result is one finished call. content is the envelope the model reads, and
// it is exactly what the session stores.
Tool_Result :: struct {
	call_id:   string,
	outcome:   session.Tool_Outcome,
	reason:    string, // short line for the front-end
	content:   string, // the JSON envelope
	error:     Tool_Argument_Error, // set only when the outcome is .Invalid_Arguments
	allocator: mem.Allocator,
}

tool_result_destroy :: proc(result: ^Tool_Result) {
	allocator := result.allocator
	delete(result.call_id, allocator)
	delete(result.reason, allocator)
	delete(result.content, allocator)
	tool_argument_error_destroy(&result.error, allocator)
	result^ = {}
}

// tool_result_of builds a result from a tool's own data.
// reason is a short line for the front-end; the model reads the envelope.
tool_result_of :: proc(ctx: ^Tool_Context, outcome: session.Tool_Outcome, message: string, data: $T, reason := "") -> Tool_Result {
	return Tool_Result {
		call_id = strings.clone(ctx.call_id, ctx.allocator),
		outcome = outcome,
		reason = strings.clone(reason, ctx.allocator),
		content = tool_content_json(outcome, message, data, ctx.allocator),
		allocator = ctx.allocator,
	}
}

tool_result_success :: proc(ctx: ^Tool_Context, data: $T, reason := "") -> Tool_Result {
	return tool_result_of(ctx, .Success, "", data, reason)
}

// tool_result_failure is a result with no data of its own: a refusal, a timeout,
// a transport failure, or anything else the harness observed without output.
tool_result_failure :: proc(ctx: ^Tool_Context, outcome: session.Tool_Outcome, message: string, reason := "") -> Tool_Result {
	return tool_result_of(ctx, outcome, message, Tool_Empty{}, reason)
}

// tool_result_refused takes ownership of err and answers a call whose arguments
// could not be admitted. Nothing ran, and the result says exactly why.
tool_result_refused :: proc(ctx: ^Tool_Context, err: ^Tool_Argument_Error) -> Tool_Result {
	text := tool_argument_error_text(err^, ctx.allocator)
	defer delete(text, ctx.allocator)
	result := tool_result_of(ctx, .Invalid_Arguments, text, tool_argument_detail(err^), text)
	result.error = err^
	err^ = {}
	return result
}

@(private)
tool_content_json :: proc(outcome: session.Tool_Outcome, message: string, data: $T, allocator: mem.Allocator) -> string {
	content := Tool_Content(T) {
		status  = session.tool_outcome_name(outcome),
		message = message,
		data    = data,
	}
	encoded, marshal_err := json.marshal(content, allocator = allocator)
	if marshal_err != nil { return "" }
	return string(encoded)
}

// --- advertisement -----------------------------------------------------------

// AGENT_SYSTEM_PROMPT states what the agent is for. What each tool does, and
// what arguments it takes, travels with the tool definitions, so this does not
// repeat them.
AGENT_SYSTEM_PROMPT :: "You are svan, a coding agent working from a session workspace. The tools available to you are listed with their arguments. Each call returns a JSON object with a status and, on success, a data object. Relative paths start at the workspace, while absolute paths may address the wider system. Use the tools to inspect files, make changes, and run programs. Never invent tool output. Keep chat replies short."

// TOOL_MAX_CALLS_PER_RESPONSE and TOOL_MAX_CALLS_PER_TURN bound how much work one
// response can commit to, so a model cannot turn a single answer into an
// unbounded batch.
TOOL_MAX_CALLS_PER_RESPONSE :: 8
TOOL_MAX_CALLS_PER_TURN :: 32
TOOL_MAX_REQUESTS_PER_TURN :: 16

// The native tools, in the order they are registered. tool_registry_sort fixes
// the advertised order after this list is read.
@(private)
TOOL_NATIVE := [?]Tool_Definition {
	TOOL_EDIT_DEFINITION,
	TOOL_READ_DEFINITION,
	TOOL_SHELL_DEFINITION,
	TOOL_WRITE_DEFINITION,
	TOOL_LIST_SKILLS_DEFINITION,
	TOOL_LOAD_SKILL_DEFINITION,
}

// TOOL_RECOVERED_RESULT and TOOL_UNEXECUTED_RESULT are what recovery writes for a
// call the harness never observed. They are constants so recovery allocates
// nothing, and a test holds them to what the encoder produces for the same
// outcome and message.
TOOL_RECOVERED_MESSAGE :: "the session was interrupted before this call finished"
TOOL_UNEXECUTED_MESSAGE :: "the session was interrupted before this call started"

TOOL_RECOVERED_RESULT :: `{"status":"unknown","message":"the session was interrupted before this call finished","data":{}}`
TOOL_UNEXECUTED_RESULT :: `{"status":"not_executed","message":"the session was interrupted before this call started","data":{}}`
