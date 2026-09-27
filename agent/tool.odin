package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "nabla:agent/session"
import "nabla:agent/skills"
import "nabla:ai"

// Tool_Control is the caller's interruption policy for one execution. A zero
// value runs with no cancellation.
//
// interrupt is the execution's own stop token, so one call can be stopped without
// stopping its siblings; it chains to the token of the work that owns it. It is
// optional.
//
// wake, when present, is the read end of a Tool_Wake that is signalled once
// interrupt is requested, so a tool that sleeps in poll wakes for the stop. It is
// borrowed and stays open for the whole execution. Without it a sleeping tool sees
// the stop only when its own wait ends.
Tool_Control :: struct {
	interrupt: ^ai.Interrupt,
	wake:      ^os.File,
}

// Tool_Wake is a pipe that becomes readable for good when it is signalled, which
// is how a stop reaches a tool asleep in poll. Its zero value is closed.
Tool_Wake :: struct {
	read:  ^os.File,
	write: ^os.File,
}

tool_wake_open :: proc() -> (wake: Tool_Wake, err: os.Error) {
	wake.read, wake.write = os.pipe() or_return
	return
}

// tool_wake_signal wakes every waiter on wake.read, now and later. Signalling again
// does nothing.
tool_wake_signal :: proc(wake: ^Tool_Wake) {
	if wake.write == nil { return }
	_ = os.close(wake.write)
	wake.write = nil
}

tool_wake_close :: proc(wake: ^Tool_Wake) {
	tool_wake_signal(wake)
	if wake.read != nil { _ = os.close(wake.read) }
	wake^ = {}
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
	// timeout is the definition's default, copied here so a shared executor reads the
	// value of the definition it runs for.
	timeout:        time.Duration,
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
	// repairs collects what reading the arguments changed in their values, which the owner
	// records with the call and writes back into the arguments the call runs with.
	repairs:        session.Tool_Repairs,
}

// Tool_Execute runs one admitted call. Returning .Invalid_Arguments promises the
// tool performed no effect, which is what lets dispatch record the refusal as a
// call that did not run.
Tool_Execute :: #type proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result

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

// Tool_Placement says where a definition's execution runs. It is data on the
// definition rather than behavior in a scheduler: the job table reads it and does the
// obvious thing.
//
// Worker is the zero value, because blocking work is what a tool is assumed to be
// until it says otherwise: files, processes, and MCP clients belong off the owner's
// thread. Owner is for short session-control operations that need the session's own
// storage, such as compaction intent and result lookup. Lua is an owner-driven
// coroutine: it may suspend on child jobs without occupying a worker.
Tool_Placement :: enum {
	Worker,
	Owner,
	Lua,
}

// Tool_Definition is one tool the harness can run. The strings are owned by the
// registry that holds the definition.
Tool_Definition :: struct {
	kind:           Tool_Kind,
	name:           string,
	description:    string,
	input_schema:   string,
	// integer_fields names the top-level fields whose schema type accepts an integer but
	// neither a string nor a number. It is read from input_schema by the registry, and only
	// for a tool whose arguments the harness does not read itself, so those fields can be
	// repaired the way a native reader repairs its own.
	integer_fields: []string,
	hints:          Tool_Behavior_Hints,
	placement:      Tool_Placement,
	// timeout applies from the start of an execution when the model gives none. Zero
	// means none. There is no maximum.
	timeout:        time.Duration,
	execute:        Tool_Execute,
	// backend is borrowed adapter state, nil for native tools. The registry
	// copies the pointer but never frees what it points to: the adapter that
	// registered the definition owns the state and must keep it alive until no
	// registry holding the definition and no in-flight turn borrowing it
	// remains. Dispatch copies it into Tool_Context, and only the execute
	// procedure paired with this definition may cast it back.
	backend:        rawptr,
	// lane is the serialization domain: calls with the same lane never run at once. nil is
	// the native lane; an MCP tool's lane is its client, whose one stdio stream serves
	// every tool of that server.
	lane:           rawptr,
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
	definitions, alloc_error := make([dynamic]Tool_Definition, 0, TOOL_NATIVE_COUNT, allocator)
	if alloc_error != nil { return {}, Tool_Registry_Error{kind = .Allocation} }
	registry.definitions = definitions
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
	// Allocation means the registry's owned definition table could not be created.
	Allocation,
}

// Tool_Registry_Error is why a definition was not registered. tool borrows the
// rejected definition's name and detail borrows static text, so both live only
// as long as the definition passed to the registering call.
Tool_Registry_Error :: struct {
	kind:   Tool_Registry_Error_Kind,
	tool:   string,
	detail: string,
}

// TOOL_MAX_NAME_BYTES is the common provider limit for a function name.
TOOL_MAX_NAME_BYTES :: 64

// TOOL_MAX_DESCRIPTION_BYTES bounds a tool description. Descriptions travel
// with every request, so an unbounded one would tax the cacheable prefix.
TOOL_MAX_DESCRIPTION_BYTES :: 4096

// TOOL_MAX_SCHEMA_BYTES bounds an input schema document. It matches the
// argument budget so a schema can never admit what arguments cannot carry.
TOOL_MAX_SCHEMA_BYTES :: 64 * 1024

// tool_name_valid admits one canonical tool name: a flat Lua identifier of at most
// 64 bytes. The same grammar is accepted by the provider APIs Nabla supports, so the
// registry name is used verbatim on the wire and inside Lua.
tool_name_valid :: proc(name: string) -> bool {
	if name == "" || len(name) > TOOL_MAX_NAME_BYTES { return false }
	first := name[0]
	if !(first >= 'a' && first <= 'z' || first >= 'A' && first <= 'Z' || first == '_') { return false }
	for i in 1 ..< len(name) {
		c := name[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' { continue }
		return false
	}
	return true
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
			detail = "a name must be a Lua identifier using letters, digits, and underscore, beginning with a letter or underscore, at most 64 bytes",
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
	if definition.timeout < 0 {
		return {kind = .Invalid_Timeout, tool = definition.name, detail = "a timeout cannot be negative"}
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
	defect, failed := admit_error.?
	if !failed { return "" }
	#partial switch defect.kind {
	case .Not_Object:
		return "the schema root must be a JSON object"
	case .Too_Deep:
		return "the schema nests too deeply"
	case .Duplicate_Field:
		return "the schema repeats a field name"
	case .Number_Out_Of_Range:
		return "the schema holds a number no 64-bit integer or finite float can hold"
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
	integer_fields: []string
	if definition.kind == .MCP || definition.kind == .Custom {
		fields, fields_error := tool_schema_integer_fields(definition.input_schema, registry.allocator)
		if fields_error != nil { return {kind = .Allocation, tool = definition.name, detail = "the schema's integer fields could not be recorded"} }
		integer_fields = fields
	}
	append(
		&registry.definitions,
		Tool_Definition {
			name = strings.clone(definition.name, registry.allocator),
			description = strings.clone(definition.description, registry.allocator),
			input_schema = strings.clone(definition.input_schema, registry.allocator),
			integer_fields = integer_fields,
			hints = definition.hints,
			placement = definition.placement,
			timeout = definition.timeout,
			execute = definition.execute,
			kind = definition.kind,
			backend = definition.backend,
			lane = definition.lane,
		},
	)
	return {}
}

// tool_schema_integer_fields returns, sorted and owned by allocator, the top-level
// properties of an input schema whose type accepts an integer but neither a string nor a
// number. A string or a float in such a field is invalid as sent, so reading it as an
// integer is its only reading. A schema that does not parse declares no such field.
@(private)
tool_schema_integer_fields :: proc(schema: string, allocator: mem.Allocator) -> (fields: []string, err: mem.Allocator_Error) {
	root, parse_error := json.parse_string(schema, .JSON, true, context.temp_allocator)
	defer json.destroy_value(root, context.temp_allocator)
	if parse_error != nil { return nil, nil }
	object, is_object := root.(json.Object)
	if !is_object { return nil, nil }
	properties, has_properties := object["properties"].(json.Object)
	if !has_properties { return nil, nil }

	names := make([dynamic]string, 0, len(properties), allocator) or_return
	defer if err != nil {
		for name in names { delete(name, allocator) }
		delete(names)
	}
	for name, property in properties {
		declared, is_declared := property.(json.Object)
		if !is_declared { continue }
		if !tool_schema_type_accepts(declared, "integer") { continue }
		if tool_schema_type_accepts(declared, "string") || tool_schema_type_accepts(declared, "number") { continue }
		append(&names, strings.clone(name, allocator) or_return) or_return
	}
	slice.sort(names[:])
	return names[:], nil
}

// tool_schema_type_accepts reports whether a property's "type", a name or a list of names,
// includes type_name.
@(private)
tool_schema_type_accepts :: proc(property: json.Object, type_name: string) -> bool {
	#partial switch declared in property["type"] {
	case json.String:
		return string(declared) == type_name
	case json.Array:
		for element in declared {
			if name, is_name := element.(json.String); is_name && string(name) == type_name { return true }
		}
	}
	return false
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
	for name in definition.integer_fields { delete(name, allocator) }
	delete(definition.integer_fields, allocator)
	definition^ = {}
}

// --- results -----------------------------------------------------------------

// TOOL_RESULT_READ_NAME is the tool that reads a result back. It is named here, beside
// the handle that tells the model to call it, because the tool and the handle are one
// contract.
TOOL_RESULT_READ_NAME :: "context_read_result"

// TOOL_RESULT_SPILLED_MESSAGE is what a handle says instead of the output. Every
// handle says the same thing, so a spilled result is always explained the same way.
TOOL_RESULT_SPILLED_MESSAGE :: "the observed output did not fit this context and was kept in the session; read it with context_read_result"

// TOOL_RESULT_HANDLE_TOKENS is what one handle costs the model's context. A handle is a
// fixed line carrying a sequence number and a byte count, so every handle costs nearly the
// same; a test holds the real one to this bound. Reserving a constant is what lets a batch's
// budget be closed before any result is recorded.
TOOL_RESULT_HANDLE_TOKENS :: 64

// tool_result_handle is the text the model is shown in place of a result that was kept
// rather than sent. It is derived from the stored entry, so it is not itself stored:
// one fact, one place. call_seq is what the read tool takes. The text is owned by
// allocator.
tool_result_handle :: proc(outcome: session.Tool_Outcome, call_seq: i64, bytes: int, allocator: mem.Allocator) -> string {
	head, _ := tool_result_render(outcome, TOOL_RESULT_SPILLED_MESSAGE, nil, context.temp_allocator)
	return fmt.aprintf("%scall_seq: %d\nbytes: %d\n", head, call_seq, bytes, allocator = allocator)
}

// Tool_Result is one finished call. output is what the tool produced, typed, and
// content is its rendering: the text the model reads, exactly as the session stores it.
// Every string and slice is owned by allocator.
Tool_Result :: struct {
	call_id:           string,
	outcome:           session.Tool_Outcome,
	reason:            string, // short line for the front-end
	message:           string, // why the outcome is what it is; "" for a plain success
	output:            Tool_Output,
	content:           string,
	error:             Tool_Argument_Error, // set only when the outcome is .Invalid_Arguments
	allocation_failed: bool,
	allocator:         mem.Allocator,
}

tool_result_destroy :: proc(result: ^Tool_Result) {
	allocator := result.allocator
	delete(result.call_id, allocator)
	delete(result.reason, allocator)
	delete(result.message, allocator)
	tool_output_destroy(&result.output, allocator)
	delete(result.content, allocator)
	tool_argument_error_destroy(&result.error, allocator)
	result^ = {}
}

// tool_result_of builds a result from what a tool produced. output may borrow; the
// result keeps its own copy. reason is a short line for the front-end.
tool_result_of :: proc(ctx: ^Tool_Context, outcome: session.Tool_Outcome, message: string, output: Tool_Output, reason := "") -> Tool_Result {
	result := Tool_Result {
		outcome   = outcome,
		allocator = ctx.allocator,
	}
	err: mem.Allocator_Error
	failed := false
	result.call_id, err = strings.clone(ctx.call_id, ctx.allocator)
	failed ||= err != nil
	result.reason, err = strings.clone(reason, ctx.allocator)
	failed ||= err != nil
	result.message, err = strings.clone(message, ctx.allocator)
	failed ||= err != nil
	result.output, err = tool_output_clone(output, ctx.allocator)
	failed ||= err != nil
	result.content, err = tool_result_render(outcome, message, output, ctx.allocator)
	failed ||= err != nil
	result.allocation_failed = failed
	return result
}

tool_result_success :: proc(ctx: ^Tool_Context, output: Tool_Output, reason := "") -> Tool_Result {
	return tool_result_of(ctx, .Success, "", output, reason)
}

// tool_result_failure is a result with no output of its own: a refusal, a timeout,
// a transport failure, or anything else the harness observed without output.
tool_result_failure :: proc(ctx: ^Tool_Context, outcome: session.Tool_Outcome, message: string, reason := "") -> Tool_Result {
	return tool_result_of(ctx, outcome, message, nil, reason)
}

// tool_result_refused takes ownership of err and answers a call whose arguments
// could not be admitted. Nothing ran, and the result says exactly why.
tool_result_refused :: proc(ctx: ^Tool_Context, err: ^Tool_Argument_Error) -> Tool_Result {
	text := tool_argument_error_text(err^, ctx.allocator)
	defer delete(text, ctx.allocator)
	result := tool_result_of(ctx, .Invalid_Arguments, text, tool_argument_failure(err^), text)
	result.error = err^
	err^ = {}
	return result
}

// tool_control_cancelled reports whether the execution, or the work that owns it, was
// asked to stop.
tool_control_cancelled :: proc(control: Tool_Control) -> bool {
	return ai.interrupt_requested(control.interrupt)
}

// tool_control_stop reports why an execution loop must stop. Cancellation wins over the
// timeout, which is measured from start; a zero timeout never expires.
tool_control_stop :: proc(control: Tool_Control, start: time.Tick, timeout: time.Duration) -> Tool_Stop {
	if tool_control_cancelled(control) { return .Cancelled }
	if timeout > 0 && time.tick_since(start) > timeout { return .Timed_Out }
	return .None
}

// --- advertisement -----------------------------------------------------------

// AGENT_SYSTEM_PROMPT states what the agent is for. What each tool does, and
// what arguments it takes, travels with the tool definitions, so this does not
// repeat them.
AGENT_SYSTEM_PROMPT :: "You are nabla, a coding agent working from a session workspace. The tools available to you are listed with their arguments. Each result starts with a line saying ok, or error with its kind and reason, then key: value facts, then after a blank line any raw output. Relative paths start at the workspace, while absolute paths may address the wider system. Use the tools to inspect files, make changes, and run programs. Never invent tool output. Keep chat replies short."

// TOOL_DECLARED is the native tools written as constants, in the order they are
// registered. tool_registry_sort fixes the advertised order after this list is
// read. The shell tool is not here: its description names the shell this process
// will run, so tool_registry_make builds it. Only the shell states a timeout
// policy; the file and skill tools carry a zero policy, which means no
// tool-specific bound rather than a forgotten configuration.
@(private)
TOOL_DECLARED := [?]Tool_Definition {
	TOOL_PATCH_DEFINITION,
	TOOL_READ_DEFINITION,
	TOOL_WRITE_DEFINITION,
	TOOL_LIST_SKILLS_DEFINITION,
	TOOL_LOAD_SKILL_DEFINITION,
	TOOL_COMPACT_DEFINITION,
	TOOL_RESULT_READ_DEFINITION,
	TOOL_CODEMODE_DEFINITION,
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

TOOL_RECOVERED_RESULT :: "error unknown: " + TOOL_RECOVERED_MESSAGE + "\n"
TOOL_UNEXECUTED_RESULT :: "error not_executed: " + TOOL_UNEXECUTED_MESSAGE + "\n"
