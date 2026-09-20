package agent

import "core:encoding/json"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:time"

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
	call_id:        string,
	workspace:      string,
	control:        Tool_Control,
	// arguments_json is the admitted argument text this call runs with, exactly as
	// the dispatch record holds it. A tool that reads fields uses arguments; an
	// executor that forwards the call elsewhere sends this, so the record and the
	// remote peer see the same bytes rather than two encodings of one value.
	arguments_json: string,
	// timeouts is the calling definition's own policy, copied here by
	// dispatch. A shared executor, one procedure serving many definitions
	// with different bindings, reads its bounds here instead of duplicating
	// them into adapter state. The definition stays the source of truth.
	timeouts:       Tool_Timeout_Policy,
	allocator:      mem.Allocator,
	skills:         ^skills.Catalog,
	// backend is the borrowed binding the definition was registered with, copied
	// here by dispatch. It is nil for native tools. Only the execute procedure
	// paired with the definition may interpret it; it must never be freed
	// through this struct. The registry owner keeps it alive until no registry
	// or in-flight turn can use it.
	backend:        rawptr,
	// compact is the session's compaction control, available only to native tools
	// that ask for a context change. It is borrowed and lives as long as the
	// session. source_seq is the committed call this execution belongs to, which is
	// how such a tool names the boundary it was called at.
	compact:        ^Compact_Control,
	source_seq:     session.Seq,
	// results reads a kept tool result back out of the session. It is borrowed and
	// lives for the whole batch, so every call in one turn can read what an earlier
	// call kept. Nil means results cannot be read here.
	results:        ^Result_Reader,
}

// Tool_Execute runs one admitted call. Returning .Invalid_Arguments promises the
// tool performed no effect, which is what lets dispatch record the refusal as a
// call that did not run.
Tool_Execute :: #type proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result

// Tool_Hint_Value is one static behavior statement about a tool. Unknown is
// the zero value, so absence of knowledge reads as unknown rather than as a
// claim. Unknown is the only honest answer when the behavior depends on
// run-time input, such as the command a shell call executes.
Tool_Hint_Value :: enum {
	Unknown,
	No,
	Yes,
}

// Tool_Behavior_Hints describes a tool before it runs. These are static facts
// for the harness, policy code, and diagnostics, not model-facing guidance:
// the description carries what the model needs, and provider tool formats have
// no portable hint fields. No vague members live here: every hint names one
// concrete property the future MCP adapter can map to the same-named protocol
// annotation.
Tool_Behavior_Hints :: struct {
	read_only:   Tool_Hint_Value,
	destructive: Tool_Hint_Value,
	idempotent:  Tool_Hint_Value,
	open_world:  Tool_Hint_Value,
}

// Tool_Timeout_Policy bounds how long one execution of a tool may run. A zero
// duration means no tool-specific bound, not a forgotten configuration: nothing
// else bounds it, because the turn sets no time bound of its own. Durations are
// time.Duration internally; milliseconds live only at the JSON argument boundary.
Tool_Timeout_Policy :: struct {
	default: time.Duration,
	maximum: time.Duration,
}

// Tool_Definition is one tool the harness can run. The strings are owned by the
// registry that holds the definition.
Tool_Definition :: struct {
	name:         string,
	description:  string,
	input_schema: string,
	hints:        Tool_Behavior_Hints,
	timeouts:     Tool_Timeout_Policy,
	execute:      Tool_Execute,
	// backend is borrowed adapter state, nil for native tools. The registry
	// copies the pointer but never frees what it points to: the adapter that
	// registered the definition owns the state and must keep it alive until no
	// registry holding the definition and no in-flight turn borrowing it
	// remains. Dispatch copies it into Tool_Context, and only the execute
	// procedure paired with this definition may cast it back.
	backend:      rawptr,
}

// Tool_Registry owns the tools available to a session. It is built before the
// first turn and is not mutated while a turn runs, so a turn borrows it.
Tool_Registry :: struct {
	definitions: [dynamic]Tool_Definition,
	allocator:   mem.Allocator,
}

tool_registry_make :: proc(allocator := context.allocator) -> (registry: Tool_Registry, err: Tool_Registry_Error) {
	registry = Tool_Registry {
		allocator = allocator,
	}
	registry.definitions = make([dynamic]Tool_Definition, 0, TOOL_NATIVE_COUNT, allocator)
	// The shell tool's description names the shell this process will run, which is
	// only known now, so the shell tool is built here rather than declared. The
	// registry clones the strings it keeps, and this function owns the built
	// description until it has.
	shell := tool_shell_definition(tool_shell_preferred(), allocator)
	defer delete(shell.description, allocator)
	for definition in TOOL_DECLARED {
		if add_error := tool_registry_add(&registry, definition); add_error.kind != .None {
			tool_registry_destroy(&registry)
			return {}, add_error
		}
	}
	if add_error := tool_registry_add(&registry, shell); add_error.kind != .None {
		tool_registry_destroy(&registry)
		return {}, add_error
	}
	tool_registry_sort(&registry)
	return registry, {}
}

tool_registry_destroy :: proc(registry: ^Tool_Registry) {
	for &definition in registry.definitions { tool_definition_destroy(&definition, registry.allocator) }
	delete(registry.definitions)
	registry^ = {}
}

// Tool_Registry_Error_Kind names why a definition was refused. None is the zero
// value, so a fresh error reads as no error.
Tool_Registry_Error_Kind :: enum {
	None,
	Invalid_Name,
	Missing_Description,
	Invalid_Schema,
	Invalid_Timeout,
	Missing_Execute,
	Name_Collision,
}

// Tool_Registry_Error is why a definition was not registered. tool borrows the
// rejected definition's name and detail borrows static text, so both live only
// as long as the definition passed to the registering call.
Tool_Registry_Error :: struct {
	kind:   Tool_Registry_Error_Kind,
	tool:   string,
	detail: string,
}

// TOOL_MAX_NAME_BYTES bounds a qualified tool name, including its namespace.
TOOL_MAX_NAME_BYTES :: 128

// TOOL_MAX_DESCRIPTION_BYTES bounds a tool description. Descriptions travel
// with every request, so an unbounded one would tax the cacheable prefix.
TOOL_MAX_DESCRIPTION_BYTES :: 4096

// TOOL_MAX_SCHEMA_BYTES bounds an input schema document. It matches the
// argument budget so a schema can never admit what arguments cannot carry.
TOOL_MAX_SCHEMA_BYTES :: 64 * 1024

// tool_local_name_valid accepts one namespace or local-name component.
tool_local_name_valid :: proc(name: string) -> bool {
	if name == "" { return false }
	for i in 0 ..< len(name) {
		c := name[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-' { continue }
		return false
	}
	return true
}

// tool_name_valid requires a namespace before the first dot. MCP local names may
// contain further dots, while every component uses the portable character set.
tool_name_valid :: proc(name: string) -> bool {
	if name == "" || len(name) > TOOL_MAX_NAME_BYTES { return false }
	separator := strings.index_byte(name, '.')
	if separator <= 0 || separator == len(name) - 1 { return false }
	if !tool_local_name_valid(name[:separator]) { return false }
	component_start := separator + 1
	for i in component_start ..< len(name) {
		if name[i] != '.' { continue }
		if !tool_local_name_valid(name[component_start:i]) { return false }
		component_start = i + 1
	}
	return tool_local_name_valid(name[component_start:])
}

// tool_definition_validate checks a definition before it is copied into a
// registry. The schema is admitted as bounded JSON with an object root, using
// the same tokenizer admission as argument documents; general JSON Schema
// semantics stay the definition source's responsibility.
tool_definition_validate :: proc(definition: Tool_Definition) -> Tool_Registry_Error {
	if !tool_name_valid(definition.name) {
		return {
			kind = .Invalid_Name,
			tool = definition.name,
			detail = "a name must be namespace.local-name using letters, digits, underscore, or hyphen, at most 128 bytes",
		}
	}
	if definition.description == "" {
		return {kind = .Missing_Description, tool = definition.name, detail = "a tool needs a description"}
	}
	if len(definition.description) > TOOL_MAX_DESCRIPTION_BYTES {
		return {kind = .Missing_Description, tool = definition.name, detail = "the description exceeds 4096 bytes"}
	}
	if schema_error := tool_schema_valid(definition.input_schema); schema_error != "" {
		return {kind = .Invalid_Schema, tool = definition.name, detail = schema_error}
	}
	if definition.timeouts.default < 0 || definition.timeouts.maximum < 0 {
		return {kind = .Invalid_Timeout, tool = definition.name, detail = "a timeout cannot be negative"}
	}
	if definition.timeouts.default > 0 && definition.timeouts.maximum > 0 && definition.timeouts.default > definition.timeouts.maximum {
		return {kind = .Invalid_Timeout, tool = definition.name, detail = "the default timeout exceeds the maximum"}
	}
	if definition.execute == nil {
		return {kind = .Missing_Execute, tool = definition.name, detail = "a tool needs an execute procedure"}
	}
	return {}
}

// tool_schema_valid reports why a schema document is unusable, or "" when it is
// one bounded JSON object. The returned string is static text.
@(private)
tool_schema_valid :: proc(schema: string) -> string {
	if schema == "" { return "a tool needs an input schema" }
	if len(schema) > TOOL_MAX_SCHEMA_BYTES { return "the schema exceeds 64 KiB" }
	admit_error := tool_arguments_admit(schema, context.temp_allocator)
	defer tool_argument_error_destroy(&admit_error, context.temp_allocator)
	switch admit_error.kind {
	case .None:
		return ""
	case .Not_Object:
		return "the schema root must be a JSON object"
	case .Too_Large:
		return "the schema exceeds 64 KiB"
	case .Too_Deep:
		return "the schema nests too deeply"
	case .Duplicate_Field:
		return "the schema repeats a field name"
	case .Syntax:
		return "the schema is not valid JSON"
	case .Unknown_Field, .Missing_Field, .Wrong_Type, .Invalid_Value:
		return "the schema is not valid JSON"
	}
	return "the schema is not valid JSON"
}

// tool_registry_add validates a definition and copies it into the registry. A
// name already in use is refused rather than replaced: two tools sharing a name
// would make dispatch a coin toss. The backend pointer is copied, never
// retained: the adapter keeps owning it.
tool_registry_add :: proc(registry: ^Tool_Registry, definition: Tool_Definition) -> Tool_Registry_Error {
	if invalid := tool_definition_validate(definition); invalid.kind != .None { return invalid }
	if _, present := tool_registry_find(registry, definition.name); present {
		return {kind = .Name_Collision, tool = definition.name, detail = "a tool with this name is already registered"}
	}
	append(
		&registry.definitions,
		Tool_Definition {
			name = strings.clone(definition.name, registry.allocator),
			description = strings.clone(definition.description, registry.allocator),
			input_schema = strings.clone(definition.input_schema, registry.allocator),
			hints = definition.hints,
			timeouts = definition.timeouts,
			execute = definition.execute,
			backend = definition.backend,
		},
	)
	return {}
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

// TOOL_MAX_RESULT_BYTES bounds the model-visible content of every tool result.
// A result that does not fit is shortened or replaced before it is stored, so
// no single call can consume a large part of the model context.
TOOL_MAX_RESULT_BYTES :: 64 * 1024

// TOOL_RESULT_REPLACED_OVERSIZED and TOOL_RESULT_REPLACED_MALFORMED are the
// messages of a replacement envelope. They are constants so a tool bug is
// always reported in the same bytes.
TOOL_RESULT_REPLACED_OVERSIZED :: "the tool result exceeded the harness output limit and was replaced"
TOOL_RESULT_REPLACED_MALFORMED :: "the tool returned a result the harness could not use"

// TOOL_RESULT_READ_NAME is the tool that reads a result back. It is named here, beside
// the handle that tells the model to call it, because the tool and the handle are one
// contract.
TOOL_RESULT_READ_NAME :: "context.read_result"

// TOOL_RESULT_SPILLED_MESSAGE is what a handle says instead of the output. Every
// handle says the same thing, so a spilled result is always explained the same way.
TOOL_RESULT_SPILLED_MESSAGE :: "the observed output did not fit this context and was kept in the session; read it with context.read_result"

// TOOL_RESULT_HANDLE_TOKENS is what one handle costs the model's context. A handle is
// a fixed envelope carrying a sequence number and a byte count, so every handle costs
// nearly the same; a test holds the real one to this bound. Reserving a constant is
// what lets a batch's budget be closed before any result is recorded.
TOOL_RESULT_HANDLE_TOKENS :: 64

// Tool_Result_Handle is the data of a handle: which call's result was kept, and how
// much of it there is. call_seq is what the read tool takes.
Tool_Result_Handle :: struct {
	call_seq: i64 `json:"call_seq"`,
	bytes:    int `json:"bytes"`,
}

// tool_result_handle is the envelope the model is shown in place of a result that was
// kept rather than sent. It is derived from the stored entry, so it is not itself
// stored: one fact, one place. The result is owned by allocator.
tool_result_handle :: proc(outcome: session.Tool_Outcome, call_seq: i64, bytes: int, allocator: mem.Allocator) -> string {
	return tool_content_json(outcome, TOOL_RESULT_SPILLED_MESSAGE, Tool_Result_Handle{call_seq = call_seq, bytes = bytes}, allocator)
}

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

// tool_result_finalize is the boundary between execution and storage, applied
// once in chat_run_tools immediately before the result is recorded. It
// verifies a tool's result against the result contract and returns it
// unchanged when it complies. A violation never reaches the store: the content
// is replaced with a minimal envelope that preserves the observed outcome, so
// a tool bug is reported instead of stored as malformed JSON. The outcome is
// always preserved, because the harness did observe the end: replacing it with
// Unknown would claim ignorance it does not have, and replacing success with
// failure (or the reverse) would rewrite what happened.
tool_result_finalize :: proc(ctx: ^Tool_Context, result: Tool_Result) -> Tool_Result {
	finalized := result
	if tool_result_valid(finalized.outcome, finalized.content) { return finalized }
	message := TOOL_RESULT_REPLACED_MALFORMED
	if len(finalized.content) > TOOL_MAX_RESULT_BYTES { message = TOOL_RESULT_REPLACED_OVERSIZED }
	delete(finalized.content, ctx.allocator)
	finalized.content = tool_content_json(finalized.outcome, message, Tool_Empty{}, ctx.allocator)
	return finalized
}

// tool_result_valid reports whether content is a usable result envelope for the
// outcome: one bounded JSON object carrying a matching status, a message
// string, and a data value.
@(private)
tool_result_valid :: proc(outcome: session.Tool_Outcome, content: string) -> bool {
	if content == "" || len(content) > TOOL_MAX_RESULT_BYTES { return false }
	value, parse_error := json.parse_string(content, .JSON, true, context.temp_allocator)
	if parse_error != nil { return false }
	defer json.destroy_value(value, context.temp_allocator)
	object, is_object := value.(json.Object)
	if !is_object { return false }
	status_value, status_present := object["status"]
	if !status_present { return false }
	status, status_is_string := status_value.(json.String)
	if !status_is_string || string(status) != session.tool_outcome_name(outcome) { return false }
	message_value, message_present := object["message"]
	if !message_present { return false }
	if _, message_is_string := message_value.(json.String); !message_is_string { return false }
	_, data_present := object["data"]
	return data_present
}

// --- timeout policy ------------------------------------------------------------

// tool_control_with_timeout derives the control for one execution bounded by
// timeout from now: the parent control with its deadline replaced by the
// earlier of the parent deadline and now plus the timeout. A non-positive
// timeout leaves the parent control unchanged. An expired parent deadline is
// never revived by a longer timeout.
tool_control_with_timeout :: proc(parent: Tool_Control, timeout: time.Duration) -> Tool_Control {
	if timeout <= 0 { return parent }
	return tool_control_earlier(parent, ai.deadline_in(timeout))
}

// tool_control_with_maximum clamps a requested bound the same way: the parent
// control with its deadline replaced by the earlier of the parent deadline and
// now plus the maximum. A non-positive maximum leaves the parent unchanged.
tool_control_with_maximum :: proc(parent: Tool_Control, maximum: time.Duration) -> Tool_Control {
	if maximum <= 0 { return parent }
	return tool_control_earlier(parent, ai.deadline_in(maximum))
}

@(private)
tool_control_earlier :: proc(parent: Tool_Control, candidate: ai.Deadline) -> Tool_Control {
	control := parent
	if !candidate.active { return control }
	if !control.deadline.active {
		control.deadline = candidate
		return control
	}
	parent_remaining, parent_ok := ai.deadline_remaining(control.deadline)
	candidate_remaining, candidate_ok := ai.deadline_remaining(candidate)
	if candidate_ok && (!parent_ok || candidate_remaining < parent_remaining) { control.deadline = candidate }
	return control
}

// tool_timeout_clamp bounds a requested timeout by the definition maximum. A
// non-positive maximum means no bound: the request stands as asked. Durations
// stay in time.Duration here; milliseconds live only at the JSON boundary.
tool_timeout_clamp :: proc(requested, maximum: time.Duration) -> time.Duration {
	if maximum > 0 && requested > maximum { return maximum }
	return requested
}

// tool_control_cancelled reports whether the execution owning this control
// ended: interruption was requested or the control's deadline passed. The
// deadline comes only from tool bounds; the turn itself sets none. A tool's own
// timeout budget is not cancellation; it has its own outcome and its own check.
tool_control_cancelled :: proc(control: Tool_Control) -> bool {
	return ai.interrupt_requested(control.interrupt) || ai.deadline_expired(control.deadline)
}

// tool_control_stop reports why an execution loop must stop. Cancellation wins
// over the tool timeout when both are observed: a cancelled turn is never
// reported as a timeout. control is the caller's control and budget is the tool's
// own bound; the two stay separate so the outcome can name which one fired.
tool_control_stop :: proc(control: Tool_Control, start: time.Tick, budget: time.Duration) -> Tool_Stop {
	if tool_control_cancelled(control) { return .Cancelled }
	if budget > 0 && time.tick_since(start) > budget { return .Timed_Out }
	return .None
}

// --- advertisement -----------------------------------------------------------

// AGENT_SYSTEM_PROMPT states what the agent is for. What each tool does, and
// what arguments it takes, travels with the tool definitions, so this does not
// repeat them.
AGENT_SYSTEM_PROMPT :: "You are svan, a coding agent working from a session workspace. The tools available to you are listed with their arguments. Each call returns a JSON object with a status and, on success, a data object. Relative paths start at the workspace, while absolute paths may address the wider system. Use the tools to inspect files, make changes, and run programs. Never invent tool output. Keep chat replies short."

// TOOL_DECLARED is the native tools written as constants, in the order they are
// registered. tool_registry_sort fixes the advertised order after this list is
// read. The shell tool is not here: its description names the shell this process
// will run, so tool_registry_make builds it. Only the shell states a timeout
// policy; the file and skill tools carry a zero policy, which means no
// tool-specific bound rather than a forgotten configuration.
@(private)
TOOL_DECLARED := [?]Tool_Definition {
	TOOL_EDIT_DEFINITION,
	TOOL_READ_DEFINITION,
	TOOL_WRITE_DEFINITION,
	TOOL_LIST_SKILLS_DEFINITION,
	TOOL_LOAD_SKILL_DEFINITION,
	TOOL_COMPACT_DEFINITION,
	TOOL_RESULT_READ_DEFINITION,
}

// TOOL_NATIVE_COUNT is how many native tools a registry holds: the declared ones,
// plus the shell tool, whose definition is built at run time.
@(private)
TOOL_NATIVE_COUNT :: len(TOOL_DECLARED) + 1

// TOOL_RECOVERED_RESULT and TOOL_UNEXECUTED_RESULT are what recovery writes for a
// call the harness never observed. They are constants so recovery allocates
// nothing, and a test holds them to what the encoder produces for the same
// outcome and message.
TOOL_RECOVERED_MESSAGE :: "the session was interrupted before this call finished"
TOOL_UNEXECUTED_MESSAGE :: "the session was interrupted before this call started"

TOOL_RECOVERED_RESULT :: `{"status":"unknown","message":"the session was interrupted before this call finished","data":{}}`
TOOL_UNEXECUTED_RESULT :: `{"status":"not_executed","message":"the session was interrupted before this call started","data":{}}`
