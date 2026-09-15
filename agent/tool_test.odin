#+test
package agent

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "nabla:agent/session"
import "nabla:ai"

// Tool_Test drives one tool call through the real dispatch path against a real
// store, the way a completed response would.
Tool_Test :: struct {
	fixture:   Chat_Test,
	workspace: string,
	entries:   []session.Entry,
}

tool_test_begin :: proc(t: ^testing.T, test: ^Tool_Test) {
	workspace, workspace_error := os.make_directory_temp("", "nabla-tool-test-*", context.allocator)
	if workspace_error != nil { testing.fail_now(t, "could not create a tool test workspace") }
	test.workspace = workspace
	chat_test_begin(t, &test.fixture, workspace)
	test.fixture.chat.tools_enabled = true
	_test_accept(t, &test.fixture.chat, "tool test")
}

tool_test_end :: proc(t: ^testing.T, test: ^Tool_Test) {
	session.entries_destroy(test.entries, context.allocator)
	chat_test_end(t, &test.fixture)
	os.remove_all(test.workspace)
	delete(test.workspace, context.allocator)
}

tool_test_workspace :: proc(test: ^Tool_Test) -> string {
	return test.workspace
}

// tool_run stages one call and returns the result the harness recorded for it.
// The result borrows the record, which stays loaded until the next run or the
// test ends.
tool_run :: proc(t: ^testing.T, test: ^Tool_Test, name, arguments: string) -> session.Tool_Result_Entry {
	chat := &test.fixture.chat
	seq := _test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			request_no = chat.active_request,
			created_at_ms = session.now_ms(),
			payload = session.Tool_Call_Entry{call_id = "call_1", name = name, arguments = arguments},
		},
	)
	append(
		&chat.pending_calls,
		Chat_Tool_Call {
			id = chat_clone_string("call_1", chat.allocator),
			name = chat_clone_string(name, chat.allocator),
			arguments = chat_clone_string(arguments, chat.allocator),
			seq = seq,
		},
	)
	chat.state = .Executing_Tools

	count := chat_run_tools(chat, {})
	testing.expect_value(t, count, 1)
	testing.expect(t, chat_session_tools_done(chat, chat.active_turn_id, count))

	session.entries_destroy(test.entries, context.allocator)
	test.entries = _test_entries(t, chat)
	result, is_result := test.entries[len(test.entries) - 1].payload.(session.Tool_Result_Entry)
	if !testing.expect(t, is_result, "the last entry should be a result") { return {} }
	return result
}

// --- admission ---------------------------------------------------------------

@(test)
test_admission_rejects_structural_defects :: proc(t: ^testing.T) {
	cases := []struct {
		raw:      string,
		kind:     Tool_Argument_Error_Kind,
		accepted: bool,
	} {
		{`{"command":"echo"}`, .None, true},
		{`{}`, .None, true},
		{`[1,2]`, .Not_Object, false},
		{`{"a":1,"a":2}`, .Duplicate_Field, false},
		{`{"a":{"b":1,"b":2}}`, .Duplicate_Field, false},
		{`{"a":[{"b":1,"b":2}]}`, .Duplicate_Field, false},
		{`{"a":1} {"b":2}`, .Syntax, false},
		{`{"a":1} trailing`, .Syntax, false},
		{`{"a":1,}`, .Syntax, false},
		{`{,}`, .Syntax, false},
		{`{"a":1`, .Syntax, false},
		{`{"a" 1}`, .Syntax, false},
		{`{"a":`, .Syntax, false},
	}
	for c in cases {
		arguments := tool_arguments_prepare(c.raw, context.allocator)
		defer tool_arguments_destroy(&arguments, context.allocator)
		rejected := arguments.status == .Rejected
		testing.expectf(t, rejected != c.accepted, "%s was read as %v", c.raw, arguments.status)
		if rejected {
			testing.expectf(t, arguments.error.kind == c.kind, "%s reported %v", c.raw, arguments.error.kind)
		}
	}
}

@(test)
test_admission_bounds_what_it_reads :: proc(t: ^testing.T) {
	arguments := tool_arguments_prepare(strings.repeat("{", TOOL_MAX_ARGS_BYTES + 1, context.temp_allocator), context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	testing.expect_value(t, arguments.status, Tool_Arguments_Status.Rejected)
	testing.expect_value(t, arguments.error.kind, Tool_Argument_Error_Kind.Too_Large)

	arguments = tool_arguments_prepare(strings.repeat(`{"a":`, TOOL_MAX_ARGS_DEPTH + 1, context.temp_allocator), context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	testing.expect_value(t, arguments.status, Tool_Arguments_Status.Rejected)
	testing.expect_value(t, arguments.error.kind, Tool_Argument_Error_Kind.Too_Deep)
}

// A raw control byte inside a string literal is the one defect the harness
// repairs, and the repaired document is read in full before anything runs.
@(test)
test_admission_repairs_control_bytes_only :: proc(t: ^testing.T) {
	arguments := tool_arguments_prepare("{\"command\":\"printf a\nb\"}", context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	if !testing.expect_value(t, arguments.status, Tool_Arguments_Status.Repaired) { return }
	testing.expect_value(t, arguments.repair, session.Tool_Repair.Escaped_Control_Characters)

	object, is_object := arguments.value.(json.Object)
	if !testing.expect(t, is_object, "the repaired document is an object") { return }
	command, command_error := tool_field_string(object, "command", allocator = context.allocator)
	defer tool_argument_error_destroy(&command_error, context.allocator)
	if !testing.expect_value(t, command_error.kind, Tool_Argument_Error_Kind.None) { return }
	testing.expect_value(t, command, "printf a\nb")

	refused := []string{`{"command":"a\qb"}`, `{"command":.}`, `{"command":"a","command":"b"}`}
	for raw in refused {
		arguments := tool_arguments_prepare(raw, context.allocator)
		defer tool_arguments_destroy(&arguments, context.allocator)
		testing.expectf(t, arguments.status == .Rejected, "%s must not be repaired", raw)
	}
}

// A field the schema never declared would run something other than what was
// advertised, so the reader and the advertised field list are held together.
@(test)
test_field_readers_report_the_defect :: proc(t: ^testing.T) {
	arguments := tool_arguments_prepare(`{"command":"echo","extra":1}`, context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	if !testing.expect_value(t, arguments.status, Tool_Arguments_Status.Valid) { return }
	args := arguments.value.(json.Object)

	known_error := tool_fields_known(args, TOOL_SHELL_FIELDS, allocator = context.allocator)
	defer tool_argument_error_destroy(&known_error, context.allocator)
	testing.expect_value(t, known_error.kind, Tool_Argument_Error_Kind.Unknown_Field)
	testing.expect_value(t, known_error.field, "extra")
	testing.expect(t, strings.contains(known_error.expected, "timeout_ms"), "the accepted fields are listed")
	testing.expect(t, tool_argument_error_text(known_error, context.temp_allocator) != "")

	if _, nested_error := tool_field_object(json.String("x"), "edits/0", context.allocator); nested_error.kind != .None {
		defer tool_argument_error_destroy(&nested_error, context.allocator)
		testing.expect_value(t, nested_error.kind, Tool_Argument_Error_Kind.Wrong_Type)
		testing.expect_value(t, nested_error.field, "edits/0")
	} else {
		testing.fail_now(t, "a non-object is refused")
	}
}

// --- the four tools ----------------------------------------------------------

@(test)
test_shell_runs_a_command_and_reports_what_it_did :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	result := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"printf hello"}`)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(result.content, `"status":"success"`), "the envelope names the outcome")
	testing.expect(t, strings.contains(result.content, `"stdout":"hello"`), "the output reaches the model")
	testing.expect(t, strings.contains(result.content, `"exit_code":0`), "the exit code is reported")

	failed := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"exit 3"}`)
	testing.expect_value(t, failed.outcome, session.Tool_Outcome.Tool_Failed)
	testing.expect(t, strings.contains(failed.content, `"exit_code":3`), "a nonzero exit is still reported")

	outside := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"pwd","working_directory":"/tmp"}`)
	testing.expect_value(t, outside.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(outside.content, `"stdout":"/tmp\n"`), "an absolute working directory is used as given")
}

@(test)
test_shell_refuses_arguments_after_recording_the_dispatch :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	result := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":""}`)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Invalid_Arguments)
	testing.expect(t, strings.contains(result.content, `"kind":"invalid_value"`), "the refusal names its kind")

	entries := _test_entries(t, &test.fixture.chat)
	defer session.entries_destroy(entries, context.allocator)
	// The dispatch preserves the effective arguments before execution. The
	// invalid-arguments outcome records that the tool performed no effect.
	if !testing.expect_value(t, len(entries), 4) { return }
	testing.expect_value(t, entries[1].kind, session.Entry_Kind.Tool_Call)
	testing.expect_value(t, entries[2].kind, session.Entry_Kind.Tool_Dispatch)
	testing.expect_value(t, entries[3].kind, session.Entry_Kind.Tool_Result)
}

@(test)
test_read_reports_the_lines_it_returned :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	path := strings.concatenate({tool_test_workspace(&test), "/notes.txt"}, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	if !tool_write_file(t, path, "one\ntwo\nthree\nfour\n") { return }

	arguments := strings.concatenate({`{"path":"`, path, `","offset":2,"limit":2}`}, context.temp_allocator)
	result := tool_run(t, &test, TOOL_READ_NAME, arguments)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(result.content, `"content":"two\nthree\n"`), "the requested lines are returned")
	testing.expect(t, strings.contains(result.content, `"total_lines":4`), "the file's line count is reported")

	missing := tool_run(t, &test, TOOL_READ_NAME, `{"path":"gone.txt"}`)
	testing.expect_value(t, missing.outcome, session.Tool_Outcome.Tool_Failed)
}

@(test)
test_write_replaces_a_file_by_absolute_or_relative_path :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	out := strings.concatenate({tool_test_workspace(&test), "/out.txt"}, context.temp_allocator)
	defer delete(out, context.temp_allocator)

	arguments := strings.concatenate({`{"path":"`, out, `","content":"first\n"}`}, context.temp_allocator)
	result := tool_run(t, &test, TOOL_WRITE_NAME, arguments)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
	if !tool_file_is(t, out, "first\n") { return }

	again := tool_run(t, &test, TOOL_WRITE_NAME, `{"path":"out.txt","content":"second"}`)
	testing.expect_value(t, again.outcome, session.Tool_Outcome.Success)
	if !tool_file_is(t, out, "second") { return }
}

@(test)
test_edit_applies_every_replacement_or_none :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	path := strings.concatenate({tool_test_workspace(&test), "/code.txt"}, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	if !tool_write_file(t, path, "alpha beta gamma\n") { return }

	arguments := strings.concatenate({`{"path":"`, path, `","edits":[{"old":"alpha","new":"ALPHA"},{"old":"gamma","new":"GAMMA"}]}`}, context.temp_allocator)
	result := tool_run(t, &test, TOOL_EDIT_NAME, arguments)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
	if !tool_file_is(t, path, "ALPHA beta GAMMA\n") { return }

	// A replacement that matches twice is refused, and the file is untouched.
	if !tool_write_file(t, path, "same same\n") { return }
	ambiguous := tool_run(t, &test, TOOL_EDIT_NAME, `{"path":"code.txt","edits":[{"old":"same","new":"once"}]}`)
	testing.expect_value(t, ambiguous.outcome, session.Tool_Outcome.Invalid_Arguments)
	if !tool_file_is(t, path, "same same\n") { return }

	overlap := tool_run(t, &test, TOOL_EDIT_NAME, `{"path":"code.txt","edits":[{"old":"same","new":"x"},{"old":"e s","new":"y"}]}`)
	testing.expect_value(t, overlap.outcome, session.Tool_Outcome.Invalid_Arguments)
	tool_file_is(t, path, "same same\n")
}

@(test)
test_every_native_tool_is_registered_complete :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	// The registry is sorted, so the advertised order never depends on the order
	// tools were registered in.
	chat := &test.fixture.chat
	if !testing.expect_value(t, len(chat.tools.definitions), len(TOOL_NATIVE)) { return }
	for index in 1 ..< len(chat.tools.definitions) {
		testing.expect(t, chat.tools.definitions[index - 1].name < chat.tools.definitions[index].name, "the advertised order is stable")
	}
	for definition in chat.tools.definitions {
		testing.expect(t, definition.description != "", "a tool is described")
		testing.expect(t, definition.input_schema != "", "a tool advertises its arguments")
		testing.expect(t, definition.execute != nil, "a tool has an executor")
	}
}

// The native definitions are compile-time constants, so building the registry
// from them must never fail. A failure here is a programming error, not a
// configuration the harness could recover from.
@(test)
test_native_registry_builds_without_error :: proc(t: ^testing.T) {
	registry, registry_error := tool_registry_make(context.allocator)
	defer tool_registry_destroy(&registry)
	testing.expect_value(t, registry_error.kind, Tool_Registry_Error_Kind.None)
	if registry_error.kind != .None { return }
	testing.expect_value(t, len(registry.definitions), len(TOOL_NATIVE))
}

// tool_test_dummy_execute stands in for an executor where only registration
// matters. Nothing runs through it.
tool_test_dummy_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	return tool_result_failure(ctx, .Tool_Failed, "dummy", "dummy")
}

tool_test_valid_definition :: proc(allocator := context.allocator) -> Tool_Definition {
	return Tool_Definition {
		name = strings.clone("test_tool", allocator),
		description = strings.clone("A test tool.", allocator),
		input_schema = strings.clone(`{"type":"object"}`, allocator),
		execute = tool_test_dummy_execute,
	}
}

tool_test_definition_destroy :: proc(definition: ^Tool_Definition, allocator := context.allocator) {
	delete(definition.name, allocator)
	delete(definition.description, allocator)
	delete(definition.input_schema, allocator)
	definition^ = {}
}

// Registration is where malformed definitions are refused. A bad definition
// must never reach request encoding, where it would fail after the request was
// already recorded.
@(test)
test_registry_rejects_invalid_definitions :: proc(t: ^testing.T) {
	// Each case names the one defect it carries; every other field is valid.
	// Replacements delete the original clone first and stay allocator-owned
	// (or empty), so the definition can still be destroyed unconditionally.
	cases := []struct {
		mutate: proc(definition: ^Tool_Definition),
		kind:   Tool_Registry_Error_Kind,
	} {
		{proc(definition: ^Tool_Definition) { delete(definition.name, context.allocator); definition.name = "" }, .Invalid_Name},
		{proc(definition: ^Tool_Definition) {
				delete(definition.name, context.allocator)
				definition.name = strings.clone("bad name", context.allocator)
			}, .Invalid_Name},
		{proc(definition: ^Tool_Definition) {
				delete(definition.name, context.allocator)
				definition.name = strings.clone("bad.name", context.allocator)
			}, .Invalid_Name},
		{proc(definition: ^Tool_Definition) { delete(definition.description, context.allocator); definition.description = "" }, .Missing_Description},
		{proc(definition: ^Tool_Definition) { delete(definition.input_schema, context.allocator); definition.input_schema = "" }, .Invalid_Schema},
		{proc(definition: ^Tool_Definition) {
				delete(definition.input_schema, context.allocator)
				definition.input_schema = strings.clone(`[]`, context.allocator)
			}, .Invalid_Schema},
		{proc(definition: ^Tool_Definition) {
				delete(definition.input_schema, context.allocator)
				definition.input_schema = strings.clone(`{"type":}`, context.allocator)
			}, .Invalid_Schema},
		{proc(definition: ^Tool_Definition) {
				delete(definition.input_schema, context.allocator)
				definition.input_schema = strings.clone(`{"a":1} trailing`, context.allocator)
			}, .Invalid_Schema},
		{proc(definition: ^Tool_Definition) { definition.timeouts.default = -time.Second }, .Invalid_Timeout},
		{proc(definition: ^Tool_Definition) {
				definition.timeouts.default = 2 * time.Second
				definition.timeouts.maximum = time.Second
			}, .Invalid_Timeout},
		{proc(definition: ^Tool_Definition) { definition.execute = nil }, .Missing_Execute},
	}
	for c in cases {
		definition := tool_test_valid_definition(context.allocator)
		c.mutate(&definition)
		registry := Tool_Registry {
			allocator = context.allocator,
		}
		registry.definitions = make([dynamic]Tool_Definition, 0, 1, context.allocator)
		add_error := tool_registry_add(&registry, definition)
		testing.expect_value(t, add_error.kind, c.kind)
		testing.expect_value(t, len(registry.definitions), 0)
		tool_registry_destroy(&registry)
		tool_test_definition_destroy(&definition, context.allocator)
	}

	// An overlong name, description, and schema are refused at their bounds.
	definition := tool_test_valid_definition(context.allocator)
	defer tool_test_definition_destroy(&definition, context.allocator)
	registry := Tool_Registry {
		allocator = context.allocator,
	}
	registry.definitions = make([dynamic]Tool_Definition, 0, 1, context.allocator)
	defer tool_registry_destroy(&registry)

	delete(definition.name, context.allocator)
	definition.name = strings.repeat("n", TOOL_MAX_NAME_BYTES + 1, context.allocator)
	testing.expect_value(t, tool_registry_add(&registry, definition).kind, Tool_Registry_Error_Kind.Invalid_Name)

	delete(definition.name, context.allocator)
	definition.name = strings.clone("test_tool", context.allocator)
	delete(definition.description, context.allocator)
	definition.description = strings.repeat("d", TOOL_MAX_DESCRIPTION_BYTES + 1, context.allocator)
	testing.expect_value(t, tool_registry_add(&registry, definition).kind, Tool_Registry_Error_Kind.Missing_Description)

	delete(definition.description, context.allocator)
	definition.description = strings.clone("A test tool.", context.allocator)
	delete(definition.input_schema, context.allocator)
	definition.input_schema = strings.concatenate(
		{`{"type":"object","x":"`, strings.repeat("x", TOOL_MAX_SCHEMA_BYTES, context.temp_allocator), `"}`},
		context.allocator,
	)
	testing.expect_value(t, tool_registry_add(&registry, definition).kind, Tool_Registry_Error_Kind.Invalid_Schema)
	testing.expect_value(t, len(registry.definitions), 0)
}

// A collision is a configuration error, never a silent replacement. The first
// definition keeps its place and its backend binding.
@(test)
test_registry_refuses_name_collisions :: proc(t: ^testing.T) {
	registry, make_error := tool_registry_make(context.allocator)
	defer tool_registry_destroy(&registry)
	if !testing.expect_value(t, make_error.kind, Tool_Registry_Error_Kind.None) { return }
	before := len(registry.definitions)

	sentinel: u8 = 7
	duplicate := TOOL_SHELL_DEFINITION
	duplicate.backend = &sentinel
	add_error := tool_registry_add(&registry, duplicate)
	testing.expect_value(t, add_error.kind, Tool_Registry_Error_Kind.Name_Collision)
	testing.expect_value(t, add_error.tool, TOOL_SHELL_NAME)
	testing.expect_value(t, len(registry.definitions), before)

	// The registry owns its strings: the definition passed in is borrowed, and
	// freeing the caller's copy must not disturb what was stored.
	definition := tool_test_valid_definition(context.allocator)
	if !testing.expect_value(t, tool_registry_add(&registry, definition).kind, Tool_Registry_Error_Kind.None) {
		tool_test_definition_destroy(&definition, context.allocator)
		return
	}
	tool_test_definition_destroy(&definition, context.allocator)
	stored, found := tool_registry_find(&registry, "test_tool")
	if !testing.expect(t, found, "the stored definition survives its source") { return }
	testing.expect_value(t, stored.name, "test_tool")
	testing.expect_value(t, stored.description, "A test tool.")
	testing.expect_value(t, stored.input_schema, `{"type":"object"}`)

	// A borrowed backend binding is preserved through registration.
	marker: u8 = 13
	bound := tool_test_valid_definition(context.allocator)
	delete(bound.name, context.allocator)
	bound.name = strings.clone("bound_tool", context.allocator)
	bound.backend = &marker
	defer tool_test_definition_destroy(&bound, context.allocator)
	if !testing.expect_value(t, tool_registry_add(&registry, bound).kind, Tool_Registry_Error_Kind.None) { return }
	found_definition, bound_found := tool_registry_find(&registry, "bound_tool")
	if !testing.expect(t, bound_found, "the bound definition is registered") { return }
	testing.expect(t, found_definition.backend == &marker, "the backend binding is preserved")
}

// --- result finalization -------------------------------------------------------

// tool_test_envelope_matches parses a stored result and checks the contract
// finalization guarantees: a bounded object with a matching status, a message,
// and a data value.
tool_test_envelope_matches :: proc(t: ^testing.T, content: string, outcome: session.Tool_Outcome, message: string) -> bool {
	if len(content) > TOOL_MAX_RESULT_BYTES { return testing.expect(t, false, "the envelope exceeds the result budget") }
	value, parse_error := json.parse_string(content, .JSON, true, context.temp_allocator)
	if parse_error != nil { return testing.expect(t, false, "the envelope is not valid JSON") }
	defer json.destroy_value(value, context.temp_allocator)
	object, is_object := value.(json.Object)
	if !is_object { return testing.expect(t, false, "the envelope root is not an object") }
	status, status_ok := object["status"].(json.String)
	if !status_ok || string(status) != session.tool_outcome_name(outcome) {
		return testing.expect(t, false, "the envelope status does not match the outcome")
	}
	text, message_ok := object["message"].(json.String)
	if !message_ok || string(text) != message {
		return testing.expect(t, false, "the envelope message is not what was expected")
	}
	if "data" not_in object { return testing.expect(t, false, "the envelope carries no data") }
	return true
}

tool_test_finalize_case :: proc(t: ^testing.T, outcome: session.Tool_Outcome, content: string, message: string) {
	ctx := Tool_Context {
		call_id   = "call_1",
		allocator = context.allocator,
	}
	result := Tool_Result {
		call_id   = strings.clone("call_1", context.allocator),
		outcome   = outcome,
		reason    = strings.clone("test", context.allocator),
		content   = strings.clone(content, context.allocator),
		allocator = context.allocator,
	}
	finalized := tool_result_finalize(&ctx, result)
	defer tool_result_destroy(&finalized)
	testing.expect_value(t, finalized.outcome, outcome)
	tool_test_envelope_matches(t, finalized.content, outcome, message)
}

// A valid result passes finalization untouched.
@(test)
test_result_finalize_keeps_valid_results :: proc(t: ^testing.T) {
	ctx := Tool_Context {
		call_id   = "call_1",
		allocator = context.allocator,
	}
	valid := tool_result_success(&ctx, Tool_Empty{}, "done")
	original := strings.clone(valid.content, context.allocator)
	defer delete(original, context.allocator)
	finalized := tool_result_finalize(&ctx, valid)
	defer tool_result_destroy(&finalized)
	testing.expect_value(t, finalized.outcome, session.Tool_Outcome.Success)
	testing.expect_value(t, finalized.content, original)
}

// A contract violation is replaced with a valid envelope that preserves the
// observed outcome.
@(test)
test_result_finalize_replaces_contract_violations :: proc(t: ^testing.T) {
	tool_test_finalize_case(t, .Success, "", TOOL_RESULT_REPLACED_MALFORMED)
	tool_test_finalize_case(t, .Success, "[1,2]", TOOL_RESULT_REPLACED_MALFORMED)
	tool_test_finalize_case(t, .Success, "not json", TOOL_RESULT_REPLACED_MALFORMED)
	tool_test_finalize_case(t, .Success, `{"status":"tool_failed","message":"x","data":{}}`, TOOL_RESULT_REPLACED_MALFORMED)
	tool_test_finalize_case(t, .Success, `{"status":"success","message":"x"}`, TOOL_RESULT_REPLACED_MALFORMED)
	tool_test_finalize_case(t, .Tool_Failed, strings.repeat("a", TOOL_MAX_RESULT_BYTES + 1, context.temp_allocator), TOOL_RESULT_REPLACED_OVERSIZED)
	// A well-formed refusal envelope is valid and passes through.
	tool_test_finalize_case(
		t,
		.Invalid_Arguments,
		`{"status":"invalid_arguments","message":"missing required field \"path\"","data":{"kind":"missing_field","field":"path","expected":""}}`,
		`missing required field "path"`,
	)
}

@(test)
test_read_reports_single_line_byte_truncation :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	// One line longer than the byte budget: the line span takes it whole, so
	// only the byte truncation marks the result incomplete.
	line := strings.concatenate({strings.repeat("a", TOOL_READ_MAX_BYTES + 100, context.temp_allocator), "\n"}, context.temp_allocator)
	path := strings.concatenate({tool_test_workspace(&test), "/long.txt"}, context.temp_allocator)
	if !tool_write_file(t, path, line) { return }

	result := tool_run(t, &test, TOOL_READ_NAME, `{"path":"long.txt"}`)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
	value, parse_error := json.parse_string(result.content, .JSON, true, context.temp_allocator)
	if parse_error != nil { testing.fail_now(t, "the result is not valid JSON") }
	defer json.destroy_value(value, context.temp_allocator)
	data, data_ok := value.(json.Object)["data"].(json.Object)
	if !testing.expect(t, data_ok, "the result carries data") { return }
	truncated, truncated_ok := data["truncated"].(json.Boolean)
	if !testing.expect(t, truncated_ok, "the result reports truncation") { return }
	testing.expect(t, bool(truncated), "a byte-truncated line must report truncation")
}

// --- timeout policy ------------------------------------------------------------

// The timeout layers compose with the earliest deadline winning: a requested
// bound is clamped to the definition maximum, and a tool timeout never revives
// an expired turn.
@(test)
test_timeout_helpers_compose_deadlines :: proc(t: ^testing.T) {
	testing.expect_value(t, tool_timeout_clamp(5 * time.Second, 120 * time.Second), 5 * time.Second)
	testing.expect_value(t, tool_timeout_clamp(time.Hour, 120 * time.Second), 120 * time.Second)
	testing.expect_value(t, tool_timeout_clamp(time.Hour, 0), time.Hour)

	parent := Tool_Control {
		deadline = ai.deadline_in(time.Hour),
	}
	shorter := tool_control_with_timeout(parent, time.Second)
	remaining, remaining_ok := ai.deadline_remaining(shorter.deadline)
	testing.expect(t, remaining_ok)
	testing.expect(t, remaining > 0 && remaining <= time.Second, "the shorter timeout applies")

	longer := tool_control_with_timeout(parent, 2 * time.Hour)
	parent_remaining, _ := ai.deadline_remaining(longer.deadline)
	testing.expect(t, parent_remaining > 59 * time.Minute, "the longer timeout keeps the parent deadline")

	unchanged := tool_control_with_timeout(parent, 0)
	testing.expect(t, unchanged.deadline == parent.deadline, "no timeout keeps the parent control")

	expired := Tool_Control {
		deadline = ai.deadline_in(-time.Second),
	}
	revived := tool_control_with_maximum(expired, time.Hour)
	testing.expect(t, ai.deadline_expired(revived.deadline), "a longer bound never revives an expired turn")
}

// Cancellation wins over the tool timeout when both are observed, and the two
// stops are distinguishable: only the budget expiring reports Timed_Out.
@(test)
test_control_stop_names_the_stop :: proc(t: ^testing.T) {
	start := time.tick_now()
	testing.expect_value(t, tool_control_stop({}, start, time.Hour), Tool_Stop.None)

	interrupt: ai.Interrupt
	ai.interrupt_request(&interrupt)
	cancelled := Tool_Control {
		interrupt = &interrupt,
	}
	past := time.tick_add(time.tick_now(), -2 * time.Second)
	testing.expect_value(t, tool_control_stop(cancelled, past, time.Second), Tool_Stop.Cancelled)

	expired := Tool_Control {
		deadline = ai.deadline_in(-time.Second),
	}
	testing.expect_value(t, tool_control_stop(expired, start, time.Hour), Tool_Stop.Cancelled)
	testing.expect_value(t, tool_control_stop({}, past, time.Second), Tool_Stop.Timed_Out)
}

// A model-requested timeout above the definition maximum is refused, never
// silently clamped: the model is told the constraint it must change.
@(test)
test_shell_refuses_timeout_above_maximum :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	result := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"echo hi","timeout_ms":999999999}`)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Invalid_Arguments)
}

// tool_test_cancelled_moment runs one file-tool execution with cancellation
// already requested, which is how the cooperative checks are reached without a
// second thread.
tool_test_cancelled_moment :: proc(workspace: string) -> Tool_Context {
	interrupt := new(ai.Interrupt, context.temp_allocator)
	ai.interrupt_request(interrupt)
	return Tool_Context{call_id = "call_cancelled", workspace = workspace, control = {interrupt = interrupt}, allocator = context.allocator}
}

// A write cancelled before it begins leaves no file behind.
@(test)
test_write_cancelled_before_begin_leaves_no_file :: proc(t: ^testing.T) {
	workspace, workspace_error := os.make_directory_temp("", "nabla-tool-cancel-*", context.allocator)
	if workspace_error != nil { testing.fail_now(t, "could not create a workspace") }
	defer {
		os.remove_all(workspace)
		delete(workspace, context.allocator)
	}

	ctx := tool_test_cancelled_moment(workspace)
	arguments := tool_arguments_prepare(`{"path":"cancelled.txt","content":"hello"}`, context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	object, is_object := arguments.value.(json.Object)
	if !testing.expect(t, is_object, "the arguments should parse") { return }
	result := tool_write_execute(&ctx, object)
	defer tool_result_destroy(&result)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Cancelled)
	full := strings.concatenate({workspace, "/cancelled.txt"}, context.temp_allocator)
	testing.expect(t, !os.exists(full), "a cancelled write leaves no file")
}

// An edit cancelled before the rename keeps the destination unchanged.
@(test)
test_edit_cancelled_before_rename_keeps_destination :: proc(t: ^testing.T) {
	workspace, workspace_error := os.make_directory_temp("", "nabla-tool-cancel-*", context.allocator)
	if workspace_error != nil { testing.fail_now(t, "could not create a workspace") }
	defer {
		os.remove_all(workspace)
		delete(workspace, context.allocator)
	}
	path := strings.concatenate({workspace, "/code.txt"}, context.temp_allocator)
	if !tool_write_file(t, path, "alpha\n") { return }

	ctx := tool_test_cancelled_moment(workspace)
	arguments := tool_arguments_prepare(`{"path":"code.txt","edits":[{"old":"alpha","new":"beta"}]}`, context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	object, is_object := arguments.value.(json.Object)
	if !testing.expect(t, is_object, "the arguments should parse") { return }
	result := tool_edit_execute(&ctx, object)
	defer tool_result_destroy(&result)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Cancelled)
	tool_file_is(t, path, "alpha\n")
}

// --- recovery ----------------------------------------------------------------

// The recovery results are constants so recovery allocates nothing. A drift
// between them and the encoder would put a shape into an old session that no
// current request produces, so they are held to it here.
@(test)
test_recovery_envelopes_match_the_encoder :: proc(t: ^testing.T) {
	ctx := Tool_Context {
		allocator = context.temp_allocator,
	}
	recovered := tool_result_of(&ctx, .Unknown, TOOL_RECOVERED_MESSAGE, Tool_Empty{})
	defer tool_result_destroy(&recovered)
	testing.expect_value(t, recovered.content, TOOL_RECOVERED_RESULT)

	unexecuted := tool_result_of(&ctx, .Not_Executed, TOOL_UNEXECUTED_MESSAGE, Tool_Empty{})
	defer tool_result_destroy(&unexecuted)
	testing.expect_value(t, unexecuted.content, TOOL_UNEXECUTED_RESULT)
}

// --- helpers -----------------------------------------------------------------

tool_write_file :: proc(t: ^testing.T, path, content: string) -> bool {
	file, create_error := os.create(path)
	if create_error != nil {
		testing.fail_now(t, "the test file could not be created")
	}
	written, write_error := os.write(file, transmute([]u8)content)
	os.close(file)
	if write_error != nil || written != len(content) {
		testing.fail_now(t, "the test file could not be written")
	}
	return true
}

tool_file_is :: proc(t: ^testing.T, path, expected: string) -> bool {
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		testing.fail_now(t, "the test file could not be read")
	}
	defer delete(data, context.temp_allocator)
	return testing.expectf(t, string(data) == expected, "%s holds %q, not %q", path, string(data), expected)
}
