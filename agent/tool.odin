package agent

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "nabla:agent/journal"
import "nabla:agent/skills"
import "nabla:ai"

// Tool_Control is the caller's interruption policy for one execution. A zero
// value runs with no cancellation. interrupt is the execution's own stop token
// and is optional; wake, when present, is the borrowed read end of a Tool_Wake
// that wakes a tool sleeping in poll, and stays open for the whole execution.
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

@(require_results)
tool_wake_open :: proc() -> (wake: Tool_Wake, err: os.Error) {
	wake.read, wake.write = os.pipe() or_return
	return
}

// tool_wake_signal makes wake.read readable for good. Signalling again does nothing.
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
	call_id:          string,
	workspace:        string,
	control:          Tool_Control,
	// arguments_json is the admitted argument text, exactly as the dispatch record
	// holds it. A tool that reads fields uses arguments; an executor that forwards
	// the call elsewhere sends this text.
	arguments_json:   string,
	// output_base is where a tool may keep output too large to hold in memory, as
	// output_base plus a suffix; "" means nowhere to keep it.
	output_base:      string,
	// timeout is the definition's default for this execution.
	timeout:          time.Duration,
	allocator:        mem.Allocator,
	skills:           ^skills.Catalog,
	// backend is the borrowed adapter state the definition was registered with, nil
	// for native tools. Only the paired execute procedure may interpret it, and it
	// must never be freed through this struct.
	backend:          rawptr,
	// compact is the borrowed session compaction control for tools that ask for a
	// context change; call names the boundary the call was made at.
	compact:          ^Compact_Control,
	status_store:     ^journal.Journal, // borrowed by owner-placed agent_status
	status_session:   journal.Session_Id,
	call:             journal.Call_Id,
	// repairs collects what reading the arguments changed; the owner records it with
	// the call and writes it back into the arguments the call runs with.
	repairs:          Tool_Repairs,
	// agents is the calling orchestrator's team and member the calling subagent's own
	// record, set only for the agent tools; the other is nil. Both outlive the call.
	agents:           ^Agent_Team,
	member:           ^Subagent,
	// subagent is the delegation an agent tool call acts on, named by the child session.
	// The owner records it at dispatch except for agent_send to a live child, where it
	// is the delegation the message was queued on; the worker sets subagent_started
	// once the child runs.
	subagent:         journal.Session_Id,
	subagent_started: bool,
}

// Tool_Execute runs one admitted call. Returning .Invalid_Arguments promises the
// tool performed no effect, so dispatch records the refusal as a call that did not run.
Tool_Execute :: #type proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result

// Tool_Hint_Value is one static behavior statement about a tool. Unknown is the
// zero value; it is the answer when the behavior depends on run-time input, such
// as the command a shell call executes.
Tool_Hint_Value :: enum {
	Unknown,
	No,
	Yes,
}

// Tool_Behavior_Hints describes a tool before it runs. These are static facts for
// the harness, policy code, and diagnostics, not model-facing guidance; every hint
// names one concrete property the MCP adapter maps to the same-named protocol annotation.
Tool_Behavior_Hints :: struct {
	read_only:   Tool_Hint_Value,
	destructive: Tool_Hint_Value,
	idempotent:  Tool_Hint_Value,
	open_world:  Tool_Hint_Value,
}

// Tool_Placement says where a definition's execution runs; the job table reads it.
// Worker is the zero value for blocking work off the owner's thread. Owner is for
// short session-control operations on the session's own storage. Lua is an
// owner-driven coroutine that may suspend on child jobs without occupying a worker.
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
	// integer_fields names the top-level schema fields whose type accepts an integer
	// but neither a string nor a number. The registry reads it from input_schema for
	// tools whose arguments the harness does not read itself.
	integer_fields: []string,
	hints:          Tool_Behavior_Hints,
	placement:      Tool_Placement,
	// timeout applies from the start of an execution when the model gives none. Zero
	// means none; there is no maximum.
	timeout:        time.Duration,
	execute:        Tool_Execute,
	// backend is borrowed adapter state, nil for native tools. The registry copies the
	// pointer but never frees it; the registering adapter owns the state. Only the
	// paired execute procedure may cast it back.
	backend:        rawptr,
	// lane is the serialization domain: calls with the same lane never run at once.
	// nil is the native lane; an MCP tool's lane is its client.
	lane:           rawptr,
}

// Tool_Registry owns the tools available to a session. It is built before the
// first turn and is not mutated while a turn runs, so a turn borrows it.
Tool_Registry :: struct {
	definitions: [dynamic]Tool_Definition,
	allocator:   mem.Allocator,
}

@(require_results)
tool_registry_make :: proc(allocator := context.allocator) -> (registry: Tool_Registry, err: Tool_Registry_Error) {
	registry = Tool_Registry {
		allocator = allocator,
	}
	definitions, alloc_error := make([dynamic]Tool_Definition, 0, TOOL_NATIVE_COUNT, allocator)
	if alloc_error != nil { return {}, Tool_Registry_Error{kind = .Allocation} }
	registry.definitions = definitions
	// The shell tool's description names the shell this process runs, known only here,
	// so the shell tool is built rather than declared.
	shell := tool_shell_definition(tool_shell_preferred(), allocator)
	defer delete(shell.description, allocator)
	read := tool_read_definition(allocator)
	defer delete(read.description, allocator)
	for definition in TOOL_DECLARED {
		if add_error := tool_registry_add(&registry, definition); add_error.kind != .None {
			tool_registry_destroy(&registry)
			return {}, add_error
		}
	}
	for definition in ([?]Tool_Definition{shell, read}) {
		if add_error := tool_registry_add(&registry, definition); add_error.kind != .None {
			tool_registry_destroy(&registry)
			return {}, add_error
		}
	}
	tool_registry_sort(&registry)
	return registry, {}
}

tool_registry_destroy :: proc(registry: ^Tool_Registry) {
	for &definition in registry.definitions { tool_definition_destroy(&definition, registry.allocator) }
	delete(registry.definitions)
	registry^ = {}
}

// tool_registry_clone copies every definition of source into a registry of its own.
// Backend pointers are copied, never owned.
@(require_results)
tool_registry_clone :: proc(source: ^Tool_Registry, allocator := context.allocator) -> (registry: Tool_Registry, err: Tool_Registry_Error) {
	registry.allocator = allocator
	definitions, alloc_error := make([dynamic]Tool_Definition, 0, len(source.definitions), allocator)
	if alloc_error != nil { return {}, Tool_Registry_Error{kind = .Allocation} }
	registry.definitions = definitions
	for definition in source.definitions {
		if add_error := tool_registry_add(&registry, definition); add_error.kind != .None {
			tool_registry_destroy(&registry)
			return {}, add_error
		}
	}
	return registry, {}
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
// rejected definition's name and detail borrows static text.
Tool_Registry_Error :: struct {
	kind:   Tool_Registry_Error_Kind,
	tool:   string,
	detail: string,
}

// TOOL_MAX_NAME_BYTES is the common provider limit for a function name.
TOOL_MAX_NAME_BYTES :: 64

// tool_name_valid admits one canonical tool name: a flat Lua identifier of at most
// 64 bytes, used verbatim on the wire and inside Lua.
@(require_results)
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

// tool_definition_validate checks a definition before it is copied into a registry.
// The schema is admitted as JSON with an object root; general JSON Schema semantics
// stay the definition source's responsibility.
@(require_results)
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
// one JSON object. The returned string is static text.
@(private, require_results)
tool_schema_valid :: proc(schema: string) -> string {
	if schema == "" { return "a tool needs an input schema" }
	admit_error := tool_arguments_admit(schema, context.temp_allocator)
	defer tool_argument_error_destroy(&admit_error, context.temp_allocator)
	defect, failed := admit_error.?
	if !failed { return "" }
	#partial switch defect.kind {
	case .Not_Object:
		return "the schema root must be a JSON object"
	case .Duplicate_Field:
		return "the schema repeats a field name"
	case .Number_Out_Of_Range:
		return "the schema holds a number no 64-bit integer or finite float can hold"
	}
	return "the schema is not valid JSON"
}

// tool_registry_add validates a definition and copies it into the registry. A name
// already in use is refused rather than replaced. The backend pointer is copied,
// never retained.
@(require_results)
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
	added := Tool_Definition {
		integer_fields = integer_fields,
		hints          = definition.hints,
		placement      = definition.placement,
		timeout        = definition.timeout,
		execute        = definition.execute,
		kind           = definition.kind,
		backend        = definition.backend,
		lane           = definition.lane,
	}
	copy_error: mem.Allocator_Error
	added.name, copy_error = strings.clone(definition.name, registry.allocator)
	if copy_error == nil { added.description, copy_error = strings.clone(definition.description, registry.allocator) }
	if copy_error == nil { added.input_schema, copy_error = strings.clone(definition.input_schema, registry.allocator) }
	if copy_error != nil {
		// The definition owns only the copies made so far, so releasing it here releases them.
		tool_definition_destroy(&added, registry.allocator)
		return {kind = .Allocation, tool = definition.name, detail = "the definition could not be copied"}
	}
	if _, append_error := append(&registry.definitions, added); append_error != nil {
		tool_definition_destroy(&added, registry.allocator)
		return {kind = .Allocation, tool = definition.name, detail = "the tool table could not be grown"}
	}
	return {}
}

// tool_schema_integer_fields returns, sorted and owned by allocator, the top-level
// properties of an input schema whose type accepts an integer but neither a string
// nor a number. A schema that does not parse declares no such field.
@(private, require_results)
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
@(private, require_results)
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

@(require_results)
tool_registry_find :: proc(registry: ^Tool_Registry, name: string) -> (^Tool_Definition, bool) {
	for &definition in registry.definitions {
		if definition.name == name { return &definition, true }
	}
	return nil, false
}

// tool_registry_sort fixes the advertisement order, so it does not depend on
// registration order.
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

// Tool_Result is one finished call. output is what the tool produced, typed, and
// content is its rendering, exactly as the session stores it. Every string and
// slice is owned by allocator.
Tool_Result :: struct {
	call_id:           string,
	outcome:           journal.Tool_Outcome,
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
// result keeps its own copy.
@(require_results)
tool_result_of :: proc(ctx: ^Tool_Context, outcome: journal.Tool_Outcome, message: string, output: Tool_Output, reason := "") -> Tool_Result {
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

@(require_results)
tool_result_success :: proc(ctx: ^Tool_Context, output: Tool_Output, reason := "") -> Tool_Result {
	return tool_result_of(ctx, .Success, "", output, reason)
}

// tool_result_failure is a result with no output of its own: a refusal, a timeout,
// a transport failure, or anything else the harness observed without output.
@(require_results)
tool_result_failure :: proc(ctx: ^Tool_Context, outcome: journal.Tool_Outcome, message: string, reason := "") -> Tool_Result {
	return tool_result_of(ctx, outcome, message, nil, reason)
}

// tool_result_refused takes ownership of err and answers a call whose arguments
// could not be admitted. Nothing ran.
@(require_results)
tool_result_refused :: proc(ctx: ^Tool_Context, err: ^Tool_Argument_Error) -> Tool_Result {
	text, text_error := tool_argument_error_text(err^, ctx.allocator)
	defer delete(text, ctx.allocator)
	if text_error != nil {
		// The refusal is answered without its own words, so it is released here rather than
		// handed to a result that never keeps it.
		tool_argument_error_destroy(err, ctx.allocator)
		return tool_result_failure(ctx, .Tool_Failed, "the refusal could not be described: out of memory", "out of memory")
	}
	result := tool_result_of(ctx, .Invalid_Arguments, text, tool_argument_failure(err^), text)
	result.error = err^
	err^ = {}
	return result
}

// tool_control_cancelled reports whether the execution or the work owning it was
// asked to stop.
@(require_results)
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
// read. The shell and read tools are not here: tool_registry_make builds their
// descriptions with the shell and preview size. Only the shell states a timeout
// policy; the file and skill tools carry a zero policy, which means no
// tool-specific bound rather than a forgotten configuration.
@(private)
TOOL_DECLARED := [?]Tool_Definition {
	TOOL_PATCH_DEFINITION,
	TOOL_WRITE_DEFINITION,
	TOOL_LIST_SKILLS_DEFINITION,
	TOOL_LOAD_SKILL_DEFINITION,
	TOOL_COMPACT_DEFINITION,
	TOOL_CODEMODE_DEFINITION,
	TOOL_AGENT_SPAWN_DEFINITION,
	TOOL_AGENT_SEND_DEFINITION,
	TOOL_AGENT_STOP_DEFINITION,
	TOOL_AGENT_STATUS_DEFINITION,
}

// TOOL_NATIVE_COUNT is how many native tools a registry holds: the declared ones,
// plus the shell and read tools, whose definitions are built at run time.
@(private)
TOOL_NATIVE_COUNT :: len(TOOL_DECLARED) + 2
