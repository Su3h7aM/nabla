#+test
package agent

import "core:encoding/json"
import "core:fmt"
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
		{`{"a":9223372036854775807}`, .None, true},
		{`{"a":[99999999999999999999]}`, .Number_Out_Of_Range, false},
		{`{"a":-9223372036854775809}`, .Number_Out_Of_Range, false},
		{`{"a":1e400}`, .Number_Out_Of_Range, false},
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
test_admission_bounds_nesting :: proc(t: ^testing.T) {
	arguments := tool_arguments_prepare(strings.repeat(`{"a":`, TOOL_MAX_ARGS_DEPTH + 1, context.temp_allocator), context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	testing.expect_value(t, arguments.status, Tool_Arguments_Status.Rejected)
	testing.expect_value(t, arguments.error.kind, Tool_Argument_Error_Kind.Too_Deep)
}

// A document is repaired only where it has one reading, and the repaired document is read
// in full before anything runs. Everything else is refused with its own defect.
@(test)
test_admission_repairs_only_what_has_one_reading :: proc(t: ^testing.T) {
	repaired := []struct {
		raw:       string,
		effective: string,
		repairs:   session.Tool_Repairs,
	} {
		{"{\"command\":\"printf a\nb\"}", `{"command":"printf a\nb"}`, {.Escaped_Control_Characters}},
		{"", `{}`, {.Empty_Arguments}},
		{" null ", `{}`, {.Empty_Arguments}},
		{`"{\"command\":\"echo\"}"`, `{"command":"echo"}`, {.Double_Encoded_Object}},
		{`"{\"command\":\"a\nb\"}"`, `{"command":"a\nb"}`, {.Double_Encoded_Object, .Escaped_Control_Characters}},
	}
	for c in repaired {
		arguments := tool_arguments_prepare(c.raw, context.allocator)
		defer tool_arguments_destroy(&arguments, context.allocator)
		testing.expectf(t, arguments.status == .Valid, "%q was read as %v", c.raw, arguments.status)
		testing.expect_value(t, arguments.effective, c.effective)
		testing.expect_value(t, arguments.repairs, c.repairs)
	}

	refused := []struct {
		raw:  string,
		kind: Tool_Argument_Error_Kind,
	} {
		{`{"command":"a\qb"}`, .Syntax},
		{`{"command":.}`, .Syntax},
		{`{"command":"a","command":"b"}`, .Duplicate_Field},
		{`"echo"`, .Not_Object},
		{`"{\"command\":\"echo\""`, .Syntax},
	}
	for c in refused {
		arguments := tool_arguments_prepare(c.raw, context.allocator)
		defer tool_arguments_destroy(&arguments, context.allocator)
		testing.expectf(t, arguments.error.kind == c.kind, "%s reported %v", c.raw, arguments.error.kind)
	}
}

// An integer field reads an integer written as a whole number or as a decimal string, writes
// the integer back into the document, and refuses any other reading.
@(test)
test_integer_fields_repair_one_reading :: proc(t: ^testing.T) {
	arguments := tool_arguments_prepare(`{"path":"notes.txt","offset":"5","limit":2.0}`, context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	ctx := Tool_Context {
		allocator = context.allocator,
	}
	args, args_error := tool_args_decode(&ctx, TOOL_READ_DEFINITION, arguments.value.(json.Object))
	if !testing.expect_value(t, args_error.kind, Tool_Argument_Error_Kind.None) { return }
	testing.expect_value(t, args.(Read_Args).offset, 5)
	testing.expect_value(t, args.(Read_Args).limit, 2)
	testing.expect_value(t, ctx.repairs, session.Tool_Repairs{.Integer_From_String, .Integer_From_Float})
	testing.expect_value(t, arguments.value.(json.Object)["offset"].(json.Integer), 5)

	for raw in ([]string{`"05"`, `"5 "`, `"+5"`, `"5.0"`, `"99999999999999999999"`, `2.5`, `1e300`, `true`}) {
		document := strings.concatenate({`{"path":"notes.txt","offset":`, raw, "}"}, context.temp_allocator)
		arguments := tool_arguments_prepare(document, context.allocator)
		defer tool_arguments_destroy(&arguments, context.allocator)
		if !testing.expect_value(t, arguments.status, Tool_Arguments_Status.Valid) { continue }
		_, refused := tool_args_decode(&ctx, TOOL_READ_DEFINITION, arguments.value.(json.Object))
		defer tool_argument_error_destroy(&refused, context.allocator)
		testing.expectf(t, refused.kind == .Wrong_Type, "%s was read as an integer", raw)
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
	testing.expect(t, strings.contains(result.content, "ok\n"), "the result names the outcome")
	testing.expect(t, strings.contains(result.content, "stdout:\nhello\n"), "the output reaches the model")
	testing.expect(t, strings.contains(result.content, `exit_code: 0`), "the exit code is reported")

	failed := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"exit 3"}`)
	testing.expect_value(t, failed.outcome, session.Tool_Outcome.Tool_Failed)
	testing.expect(t, strings.contains(failed.content, `exit_code: 3`), "a nonzero exit is still reported")

	outside := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"pwd","working_directory":"/tmp"}`)
	testing.expect_value(t, outside.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(outside.content, "stdout:\n/tmp\n"), "an absolute working directory is used as given")
}

@(test)
test_shell_refuses_arguments_before_dispatch :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	result := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":""}`)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Invalid_Arguments)
	testing.expect(t, strings.contains(result.content, `kind: invalid_value`), "the refusal names its kind")

	entries := _test_entries(t, &test.fixture.chat)
	defer session.entries_destroy(entries, context.allocator)
	// Invalid arguments are answered without dispatching an executor.
	if !testing.expect_value(t, len(entries), 3) { return }
	testing.expect_value(t, entries[1].kind, session.Entry_Kind.Tool_Call)
	testing.expect_value(t, entries[2].kind, session.Entry_Kind.Tool_Result)
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
	testing.expect(t, strings.contains(result.content, "\n\ntwo\nthree\n"), "the requested lines are returned")
	testing.expect(t, strings.contains(result.content, `total_lines: 4`), "the file's line count is reported")

	missing := tool_run(t, &test, TOOL_READ_NAME, `{"path":"gone.txt"}`)
	testing.expect_value(t, missing.outcome, session.Tool_Outcome.Tool_Failed)
}

// A file the read tool cannot hand to the model is refused rather than encoded. A NUL byte
// and a byte that is not UTF-8 both mean the file is not text, and a result carrying either
// would not be JSON: the encoder escapes such a byte as a JSON5 sequence, and a reader that
// silently received only the prefix would not know it had.
@(test)
test_read_refuses_a_file_that_is_not_text :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	nul := strings.concatenate({tool_test_workspace(&test), "/nul.bin"}, context.temp_allocator)
	defer delete(nul, context.temp_allocator)
	if !tool_write_file(t, nul, "one\x00two\n") { return }
	nul_arguments := strings.concatenate({`{"path":"`, nul, `"}`}, context.temp_allocator)
	nul_result := tool_run(t, &test, TOOL_READ_NAME, nul_arguments)
	tool_test_result_matches(t, nul_result.content, .Tool_Failed, fmt.tprintf("%s is not a text file", nul))

	stray := strings.concatenate({tool_test_workspace(&test), "/stray.bin"}, context.temp_allocator)
	defer delete(stray, context.temp_allocator)
	if !tool_write_file(t, stray, "good \xff\xfe bad \xc3\n") { return }
	stray_arguments := strings.concatenate({`{"path":"`, stray, `"}`}, context.temp_allocator)
	stray_result := tool_run(t, &test, TOOL_READ_NAME, stray_arguments)
	tool_test_result_matches(t, stray_result.content, .Tool_Failed, fmt.tprintf("%s is not a text file", stray))

	// Text outside ASCII is valid UTF-8 and is returned as written.
	text := strings.concatenate({tool_test_workspace(&test), "/text.txt"}, context.temp_allocator)
	defer delete(text, context.temp_allocator)
	if !tool_write_file(t, text, "caf\xc3\xa9\n") { return }
	text_arguments := strings.concatenate({`{"path":"`, text, `"}`}, context.temp_allocator)
	text_result := tool_run(t, &test, TOOL_READ_NAME, text_arguments)
	testing.expect_value(t, text_result.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(text_result.content, "caf\xc3\xa9"), "valid UTF-8 is returned as written")
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
test_patch_applies_every_file_or_none :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	workspace := tool_test_workspace(&test)
	code := strings.concatenate({workspace, "/code.txt"}, context.temp_allocator)
	gone := strings.concatenate({workspace, "/gone.txt"}, context.temp_allocator)
	added := strings.concatenate({workspace, "/new/added.txt"}, context.temp_allocator)
	later := strings.concatenate({workspace, "/later.txt"}, context.temp_allocator)
	if !tool_write_file(t, code, "one\ntwo  \nthree\nfour\nfive\n") { return }
	if !tool_write_file(t, gone, "bye\n") { return }

	// The first hunk matches only once trailing spaces are ignored.
	patch := `{"patch":"*** Begin Patch\n*** Update File: code.txt\n@@\n one\n-two\n+TWO\n three\n@@\n-five\n+FIVE\n*** Add File: new/added.txt\n+hello\n*** Delete File: gone.txt\n*** End Patch"}`
	result := tool_run(t, &test, TOOL_PATCH_NAME, patch)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
	tool_file_is(t, code, "one\nTWO\nthree\nfour\nFIVE\n")
	tool_file_is(t, added, "hello\n")
	testing.expect(t, !os.exists(gone), "a deleted file is removed")

	// A hunk that matches twice fails the whole patch, so no file in it is written.
	if !tool_write_file(t, code, "same\nsame\n") { return }
	ambiguous := `{"patch":"*** Begin Patch\n*** Add File: later.txt\n+x\n*** Update File: code.txt\n-same\n+once\n*** End Patch"}`
	failed := tool_run(t, &test, TOOL_PATCH_NAME, ambiguous)
	testing.expect_value(t, failed.outcome, session.Tool_Outcome.Tool_Failed)
	tool_file_is(t, code, "same\nsame\n")
	testing.expect(t, !os.exists(later), "a failed patch adds no file")
}

@(test)
test_patch_reads_loose_patches_with_one_meaning :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	code := strings.concatenate({tool_test_workspace(&test), "/code.txt"}, context.temp_allocator)

	// A unified diff without the envelope, whose line number picks one of two equal places.
	if !tool_write_file(t, code, "same\nx\nsame\nx\n") { return }
	unified := `{"patch":"--- a/code.txt\n+++ b/code.txt\n@@ -3,1 +3,1 @@\n-same\n+SAME\n"}`
	testing.expect_value(t, tool_run(t, &test, TOOL_PATCH_NAME, unified).outcome, session.Tool_Outcome.Success)
	tool_file_is(t, code, "same\nx\nSAME\nx\n")

	// A hunk that lost the file's indentation matches, and its added lines take that indentation.
	if !tool_write_file(t, code, "if x {\n\tfoo()\n}\n") { return }
	unindented := `{"patch":"*** Update File: code.txt\n if x {\n-foo()\n+bar()\n }\n"}`
	testing.expect_value(t, tool_run(t, &test, TOOL_PATCH_NAME, unindented).outcome, session.Tool_Outcome.Success)
	tool_file_is(t, code, "if x {\n\tbar()\n}\n")
}

@(test)
test_every_native_tool_is_registered_complete :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	// The registry is sorted, so the advertised order never depends on the order
	// tools were registered in.
	chat := &test.fixture.chat
	if !testing.expect_value(t, len(chat.tools.definitions), TOOL_NATIVE_COUNT) { return }
	for index in 1 ..< len(chat.tools.definitions) {
		testing.expect(t, chat.tools.definitions[index - 1].name < chat.tools.definitions[index].name, "the advertised order is stable")
	}
	for definition in chat.tools.definitions {
		testing.expect(t, definition.description != "", "a tool is described")
		testing.expect(t, definition.input_schema != "", "a tool advertises its arguments")
		testing.expect(t, definition.execute != nil, "a tool has an executor")
	}
}

// tool_test_dummy_execute stands in for an executor where only registration
// matters. Nothing runs through it.
tool_test_dummy_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
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
				definition.name = strings.clone("bad..name", context.allocator)
			}, .Invalid_Name},
		{proc(definition: ^Tool_Definition) {
				delete(definition.name, context.allocator)
				definition.name = strings.clone("bad-name", context.allocator)
			}, .Invalid_Name},
		{proc(definition: ^Tool_Definition) {
				delete(definition.name, context.allocator)
				definition.name = strings.clone("9bad_name", context.allocator)
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
		{proc(definition: ^Tool_Definition) { definition.timeout = -time.Second }, .Invalid_Timeout},
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
	definition.name = strings.concatenate({"test_", strings.repeat("n", TOOL_MAX_NAME_BYTES, context.temp_allocator)}, context.allocator)
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

// The canonical grammar is the narrowest of every boundary a name crosses: a Lua field
// identifier that OpenAI-compatible and Anthropic APIs also accept, inside the 64-byte
// provider limit. Everything outside it needs no round trip to be refused.
@(test)
test_canonical_name_grammar :: proc(t: ^testing.T) {
	valid := []string{"builtin_read", "fff_grep", "github_create_issue", "a", "_", "A9_z"}
	for name in valid { testing.expectf(t, tool_name_valid(name), "%q should be a valid tool name", name) }

	invalid := []string{"", "builtin.read", "fff-grep", "builtin read", "9lives", "\u00e9cho", "a.b-c"}
	for name in invalid { testing.expectf(t, !tool_name_valid(name), "%q should not be a valid tool name", name) }

	under_limit := strings.repeat("n", TOOL_MAX_NAME_BYTES, context.temp_allocator)
	over_limit := strings.repeat("n", TOOL_MAX_NAME_BYTES + 1, context.temp_allocator)
	testing.expect(t, tool_name_valid(under_limit), "a name at the provider limit is admitted")
	testing.expect(t, !tool_name_valid(over_limit), "a name past the provider limit is refused")
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
	duplicate := tool_shell_definition(TOOL_SHELL_FALLBACK, context.allocator)
	defer delete(duplicate.description, context.allocator)
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
	bound.name = strings.clone("test_bound_tool", context.allocator)
	bound.backend = &marker
	defer tool_test_definition_destroy(&bound, context.allocator)
	if !testing.expect_value(t, tool_registry_add(&registry, bound).kind, Tool_Registry_Error_Kind.None) { return }
	found_definition, bound_found := tool_registry_find(&registry, "test_bound_tool")
	if !testing.expect(t, bound_found, "the bound definition is registered") { return }
	testing.expect(t, found_definition.backend == &marker, "the backend binding is preserved")
}

// --- result finalization -------------------------------------------------------

// tool_test_result_matches checks the outcome line a stored result starts with.
tool_test_result_matches :: proc(t: ^testing.T, content: string, outcome: session.Tool_Outcome, message: string) -> bool {
	expected, err := tool_result_render(outcome, message, nil, context.temp_allocator)
	if !testing.expect_value(t, err, nil) { return false }
	return testing.expect(t, strings.has_prefix(content, expected), content)
}

// Finalization is the last step before storage: a result that fits passes through untouched,
// while one over the limit keeps the outcome the harness observed and says it was replaced.
@(test)
test_result_finalize_replaces_only_what_is_too_large :: proc(t: ^testing.T) {
	ctx := Tool_Context {
		call_id   = "call_1",
		allocator = context.allocator,
	}

	small := tool_result_success(&ctx, nil, "done")
	small_content := small.content
	finalized_small := tool_result_finalize(&ctx, small)
	defer tool_result_destroy(&finalized_small)
	testing.expect_value(t, finalized_small.outcome, session.Tool_Outcome.Success)
	testing.expect_value(t, finalized_small.content, small_content)

	// Finalization takes the result it is given, so only what it hands back is released.
	oversized := tool_result_success(&ctx, Read_Output{content = strings.repeat("x", TOOL_MAX_RESULT_BYTES, context.temp_allocator)}, "too large")
	finalized_oversized := tool_result_finalize(&ctx, oversized)
	defer tool_result_destroy(&finalized_oversized)
	testing.expect_value(t, finalized_oversized.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(finalized_oversized.content, TOOL_RESULT_REPLACED_OVERSIZED), finalized_oversized.content)
	testing.expect(t, len(finalized_oversized.content) <= TOOL_MAX_RESULT_BYTES, "a replaced result fits the limit")
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
	testing.expect(t, strings.contains(result.content, "truncated: true\n"), "a byte-truncated line must report truncation")
}

// --- timeout policy ------------------------------------------------------------

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
	testing.expect_value(t, tool_control_stop({}, past, time.Second), Tool_Stop.Timed_Out)
}

// A model-requested timeout is honored as given: the shell has no maximum.
@(test)
test_shell_honors_a_long_timeout :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	result := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"echo hi","timeout_ms":999999999}`)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
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
	result := tool_test_execute(&ctx, TOOL_WRITE_DEFINITION, object)
	defer tool_result_destroy(&result)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Cancelled)
	full := strings.concatenate({workspace, "/cancelled.txt"}, context.temp_allocator)
	testing.expect(t, !os.exists(full), "a cancelled write leaves no file")
}

// A patch cancelled before the rename keeps the destination unchanged.
@(test)
test_patch_cancelled_before_rename_keeps_destination :: proc(t: ^testing.T) {
	workspace, workspace_error := os.make_directory_temp("", "nabla-tool-cancel-*", context.allocator)
	if workspace_error != nil { testing.fail_now(t, "could not create a workspace") }
	defer {
		os.remove_all(workspace)
		delete(workspace, context.allocator)
	}
	path := strings.concatenate({workspace, "/code.txt"}, context.temp_allocator)
	if !tool_write_file(t, path, "alpha\n") { return }

	ctx := tool_test_cancelled_moment(workspace)
	arguments := tool_arguments_prepare(`{"patch":"*** Begin Patch\n*** Update File: code.txt\n-alpha\n+beta\n*** End Patch"}`, context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	object, is_object := arguments.value.(json.Object)
	if !testing.expect(t, is_object, "the arguments should parse") { return }
	result := tool_test_execute(&ctx, TOOL_PATCH_DEFINITION, object)
	defer tool_result_destroy(&result)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Cancelled)
	tool_file_is(t, path, "alpha\n")
}

// A replacement is an atomic swap: on success the session owns the new
// registry and the old one is gone, while a busy session keeps its registry
// and the caller keeps owning the replacement.
@(test)
test_replace_tools_swaps_only_while_idle :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	testing.expect_value(t, chat.state, Chat_State.Idle)

	replacement, make_error := tool_registry_make(chat.allocator)
	if !testing.expect_value(t, make_error.kind, Tool_Registry_Error_Kind.None) {
		tool_registry_destroy(&replacement)
		return
	}
	extra := Tool_Definition {
		name         = strings.clone("test_extra_tool", context.allocator),
		description  = strings.clone("An extra tool.", context.allocator),
		input_schema = strings.clone(`{"type":"object"}`, context.allocator),
		execute      = tool_test_dummy_execute,
	}
	defer tool_test_definition_destroy(&extra, context.allocator)
	if !testing.expect_value(t, tool_registry_add(&replacement, extra).kind, Tool_Registry_Error_Kind.None) {
		tool_registry_destroy(&replacement)
		return
	}
	tool_registry_sort(&replacement)

	testing.expect_value(t, chat_session_replace_tools(chat, &replacement), Tool_Registry_Replace_Error.None)
	testing.expect_value(t, len(chat.tools.definitions), TOOL_NATIVE_COUNT + 1)
	_, found := tool_registry_find(&chat.tools, "test_extra_tool")
	testing.expect(t, found, "the replacement registry is installed")

	// A turn is in flight, so the registry is frozen: the swap is refused and
	// the session keeps what it has.
	_test_accept(t, chat, "hi")
	second, second_error := tool_registry_make(chat.allocator)
	if !testing.expect_value(t, second_error.kind, Tool_Registry_Error_Kind.None) {
		tool_registry_destroy(&second)
		return
	}
	defer tool_registry_destroy(&second)
	testing.expect_value(t, chat_session_replace_tools(chat, &second), Tool_Registry_Replace_Error.Busy)
	_, still_there := tool_registry_find(&chat.tools, "test_extra_tool")
	testing.expect(t, still_there, "a busy session keeps its registry")
}

// --- recovery ----------------------------------------------------------------

// The recovery results are constants so recovery allocates nothing. A drift between them and
// the renderer would put text into a recovered session that no other result looks like, so
// they are held to it here.
@(test)
test_recovery_results_match_the_renderer :: proc(t: ^testing.T) {
	ctx := Tool_Context {
		allocator = context.temp_allocator,
	}
	recovered := tool_result_of(&ctx, .Unknown, TOOL_RECOVERED_MESSAGE, nil)
	defer tool_result_destroy(&recovered)
	testing.expect_value(t, recovered.content, TOOL_RECOVERED_RESULT)

	unexecuted := tool_result_of(&ctx, .Not_Executed, TOOL_UNEXECUTED_MESSAGE, nil)
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

// Exercise the provider adapter before calling a typed executor.
tool_test_execute :: proc(ctx: ^Tool_Context, definition: Tool_Definition, object: json.Object) -> Tool_Result {
	args, err := tool_args_decode(ctx, definition, object)
	defer tool_args_destroy(&args, ctx.allocator)
	defer tool_argument_error_destroy(&err, ctx.allocator)
	if err.kind != .None { return tool_result_refused(ctx, &err) }
	return definition.execute(ctx, args)
}
