#+test
package agent

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

// Tool_Test drives one tool call through the real dispatch path against a real
// journal, the way a completed response would.
Tool_Test :: struct {
	fixture:   Chat_Test,
	workspace: string,
}

// Tool_Test_Result is what the harness recorded for one call: the outcome and the text
// the model is shown. content and the read behind it live in temp memory.
Tool_Test_Result :: struct {
	outcome: journal.Tool_Outcome,
	content: string,
}

tool_test_begin :: proc(test: ^testing.T, tool_test: ^Tool_Test) {
	workspace, workspace_error := os.make_directory_temp("", "nabla-tool-test-*", context.allocator)
	if workspace_error != nil { testing.fail_now(test, "could not create a tool test workspace") }
	tool_test.workspace = workspace
	chat_test_begin(test, &tool_test.fixture, workspace)
	tool_test.fixture.chat.tools_enabled = true
	_test_accept(test, &tool_test.fixture.chat, "tool test")
}

tool_test_end :: proc(test: ^testing.T, tool_test: ^Tool_Test) {
	chat_test_end(test, &tool_test.fixture)
	os.remove_all(tool_test.workspace)
	delete(tool_test.workspace, context.allocator)
}

tool_test_workspace :: proc(tool_test: ^Tool_Test) -> string {
	return tool_test.workspace
}

// tool_test_result_of reads the outcome and the text out of one recorded call completion.
@(private)
tool_test_result_of :: proc(test: ^testing.T, record: journal.Record) -> Tool_Test_Result {
	completed: journal.Tool_Completed
	if decode_error := journal.payload_decode(record.data, &completed, context.temp_allocator); decode_error != nil {
		testing.fail_now(test, "the recorded outcome could not be read")
	}
	outcome, known := journal.enum_from_name(journal.TOOL_OUTCOME_NAMES, completed.outcome)
	if !known { testing.fail_now(test, "the recorded outcome is not a tool outcome") }
	return {outcome = outcome, content = string(record.body)}
}

// tool_test_last_result is what the session recorded for the newest call it ran.
@(private)
tool_test_last_result :: proc(test: ^testing.T, chat: ^Chat_Session) -> Tool_Test_Result {
	record, found, read_error := journal.read_latest(chat.store, {session = chat.session, kinds = {.Tool_Completed}}, context.temp_allocator)
	if read_error != nil { testing.fail_now(test, "the recorded result could not be read") }
	if !found { testing.fail_now(test, "the session recorded no result") }
	return tool_test_result_of(test, record)
}

// tool_test_results is every call outcome the session recorded, oldest first.
@(private)
tool_test_results :: proc(test: ^testing.T, chat: ^Chat_Session) -> [dynamic]Tool_Test_Result {
	records := _test_records(test, chat, {.Tool_Completed})
	results := make([dynamic]Tool_Test_Result, 0, len(records), context.temp_allocator)
	for record in records { append(&results, tool_test_result_of(test, record)) }
	return results
}

// tool_run stages one call and returns the result the harness recorded for it.
tool_run :: proc(test: ^testing.T, tool_test: ^Tool_Test, name, arguments: string) -> Tool_Test_Result {
	chat := &tool_test.fixture.chat
	_test_stage_call(test, chat, "call_1", arguments, name)
	count := chat_run_tools(chat, {})
	testing.expect_value(test, count, 1)
	testing.expect(test, chat_session_tools_done(chat, chat.active_turn_id, count))
	return tool_test_last_result(test, chat)
}

// --- admission ---------------------------------------------------------------

@(test)
test_admission_rejects_structural_defects :: proc(test: ^testing.T) {
	for raw in ([]string{`{"command":"echo"}`, `{}`, `{"a":9223372036854775807}`}) {
		arguments := tool_arguments_prepare(raw, context.allocator)
		defer tool_arguments_destroy(&arguments, context.allocator)
		testing.expectf(test, arguments.status == .Valid, "%s was read as %v", raw, arguments.status)
	}

	cases := []struct {
		raw:  string,
		kind: Tool_Argument_Error_Kind,
	} {
		{`[1,2]`, .Not_Object},
		{`{"a":1,"a":2}`, .Duplicate_Field},
		{`{"a":{"b":1,"b":2}}`, .Duplicate_Field},
		{`{"a":[{"b":1,"b":2}]}`, .Duplicate_Field},
		{`{"a":1} {"b":2}`, .Syntax},
		{`{"a":1} trailing`, .Syntax},
		{`{,}`, .Syntax},
		{`{"a":1,,}`, .Syntax},
		{`{"a":[,]}`, .Syntax},
		{`{"a":1`, .Syntax},
		{`{"a" 1}`, .Syntax},
		{`{"a":`, .Syntax},
		{`{"a":[99999999999999999999]}`, .Number_Out_Of_Range},
		{`{"a":-9223372036854775809}`, .Number_Out_Of_Range},
		{`{"a":1e400}`, .Number_Out_Of_Range},
	}
	for item in cases {
		arguments := tool_arguments_prepare(item.raw, context.allocator)
		defer tool_arguments_destroy(&arguments, context.allocator)
		defect, refused := arguments.error.?
		testing.expectf(test, refused && defect.kind == item.kind, "%s reported %v", item.raw, arguments.error)
	}
}

@(test)
test_admission_bounds_nesting :: proc(test: ^testing.T) {
	arguments := tool_arguments_prepare(strings.repeat(`{"a":`, TOOL_MAX_ARGS_DEPTH + 1, context.temp_allocator), context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	testing.expect_value(test, arguments.status, Tool_Arguments_Status.Rejected)
	testing.expect_value(test, tool_test_defect(arguments.error).kind, Tool_Argument_Error_Kind.Too_Deep)
}

// A document is repaired only where it has one reading, and the repaired document is read
// in full before anything runs. Everything else is refused with its own defect.
@(test)
test_admission_repairs_only_what_has_one_reading :: proc(test: ^testing.T) {
	repaired := []struct {
		raw:       string,
		effective: string,
		repairs:   Tool_Repairs,
	} {
		{"{\"command\":\"printf a\nb\"}", `{"command":"printf a\nb"}`, {.Escaped_Control_Characters}},
		{"{\"command\":\"a\x01\tb\\u00e9\"}", `{"command":"a\u0001\tb\u00e9"}`, {.Escaped_Control_Characters}},
		{"", `{}`, {.Empty_Arguments}},
		{" null ", `{}`, {.Empty_Arguments}},
		{`"{\"command\":\"echo\"}"`, `{"command":"echo"}`, {.Double_Encoded_Object}},
		{`"{\"command\":\"a\nb\"}"`, `{"command":"a\nb"}`, {.Double_Encoded_Object, .Escaped_Control_Characters}},
		{`{"command":"x,}", "list":[1, 2,] ,}`, `{"command":"x,}", "list":[1, 2 ]  }`, {.Trailing_Comma}},
	}
	for item in repaired {
		arguments := tool_arguments_prepare(item.raw, context.allocator)
		defer tool_arguments_destroy(&arguments, context.allocator)
		testing.expectf(test, arguments.status == .Valid, "%q was read as %v", item.raw, arguments.status)
		testing.expect_value(test, arguments.effective, item.effective)
		testing.expect_value(test, arguments.repairs, item.repairs)
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
	for item in refused {
		arguments := tool_arguments_prepare(item.raw, context.allocator)
		defer tool_arguments_destroy(&arguments, context.allocator)
		defect, failed := arguments.error.?
		testing.expectf(test, failed && defect.kind == item.kind, "%s reported %v", item.raw, arguments.error)
	}

	placed := tool_arguments_prepare("{\"path\":\"a\",\n \"path\":\"b\"}", context.allocator)
	defer tool_arguments_destroy(&placed, context.allocator)
	testing.expect_value(
		test,
		tool_argument_error_text(placed.error, context.temp_allocator),
		`field "path" appears twice in one object; a field may appear once, at line 2 column 2`,
	)
}

// An integer field reads an integer written as a whole number or as a decimal string, writes
// the integer back into the document, and refuses any other reading.
@(test)
test_integer_fields_repair_one_reading :: proc(test: ^testing.T) {
	arguments := tool_arguments_prepare(`{"path":"notes.txt","offset":"5","limit":2.0}`, context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	tool_context := Tool_Context {
		allocator = context.allocator,
	}
	read_arguments, arguments_error := tool_args_decode(&tool_context, TOOL_READ_DEFINITION, arguments.value.(json.Object))
	if !testing.expect_value(test, arguments_error, nil) { return }
	testing.expect_value(test, read_arguments.(Read_Args).offset, 5)
	testing.expect_value(test, read_arguments.(Read_Args).limit, 2)
	testing.expect_value(test, tool_context.repairs, Tool_Repairs{.Integer_From_String, .Integer_From_Float})
	testing.expect_value(test, arguments.value.(json.Object)["offset"].(json.Integer), 5)

	for raw in ([]string{`"05"`, `"5 "`, `"+5"`, `"5.0"`, `"99999999999999999999"`, `2.5`, `1e300`, `true`}) {
		document := strings.concatenate({`{"path":"notes.txt","offset":`, raw, "}"}, context.temp_allocator)
		arguments := tool_arguments_prepare(document, context.allocator)
		defer tool_arguments_destroy(&arguments, context.allocator)
		if !testing.expect_value(test, arguments.status, Tool_Arguments_Status.Valid) { continue }
		_, refused := tool_args_decode(&tool_context, TOOL_READ_DEFINITION, arguments.value.(json.Object))
		defer tool_argument_error_destroy(&refused, context.allocator)
		defect, failed := refused.?
		testing.expectf(test, failed && defect.kind == .Wrong_Type, "%s was read as an integer", raw)
	}
}

// A field the schema never declared would run something other than what was
// advertised, so the reader and the advertised field list are held together.
@(test)
test_field_readers_report_the_defect :: proc(test: ^testing.T) {
	arguments := tool_arguments_prepare(`{"command":"echo","extra":1}`, context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	if !testing.expect_value(test, arguments.status, Tool_Arguments_Status.Valid) { return }
	object := arguments.value.(json.Object)

	known_error := tool_fields_known(object, TOOL_SHELL_FIELDS, allocator = context.allocator)
	defer tool_argument_error_destroy(&known_error, context.allocator)
	unknown := tool_test_defect(known_error)
	testing.expect_value(test, unknown.kind, Tool_Argument_Error_Kind.Unknown_Field)
	testing.expect_value(test, unknown.field, "extra")
	testing.expect(test, strings.contains(unknown.expected, "timeout_ms"), "the accepted fields are listed")
	testing.expect(test, tool_argument_error_text(known_error, context.temp_allocator) != "")

	_, nested_error := tool_field_object(json.String("x"), "edits/0", context.allocator)
	defer tool_argument_error_destroy(&nested_error, context.allocator)
	nested := tool_test_defect(nested_error)
	testing.expect(test, nested_error != nil, "a non-object is refused")
	testing.expect_value(test, nested.kind, Tool_Argument_Error_Kind.Wrong_Type)
	testing.expect_value(test, nested.field, "edits/0")
}

// --- the four tools ----------------------------------------------------------

@(test)
test_shell_runs_a_command_and_reports_what_it_did :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	result := tool_run(test, &tool_test, TOOL_SHELL_NAME, `{"command":"printf hello"}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(result.content, "ok\n"), "the result names the outcome")
	testing.expect(test, strings.contains(result.content, "stdout:\nhello\n"), "the output reaches the model")
	testing.expect(test, strings.contains(result.content, `exit_code: 0`), "the exit code is reported")

	failed := tool_run(test, &tool_test, TOOL_SHELL_NAME, `{"command":"exit 3"}`)
	testing.expect_value(test, failed.outcome, journal.Tool_Outcome.Tool_Failed)
	testing.expect(test, strings.contains(failed.content, `exit_code: 3`), "a nonzero exit is still reported")

	outside := tool_run(test, &tool_test, TOOL_SHELL_NAME, `{"command":"pwd","working_directory":"/tmp"}`)
	testing.expect_value(test, outside.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(outside.content, "stdout:\n/tmp\n"), "an absolute working directory is used as given")
}

// A stream larger than memory holds is written whole to its file as it arrives, and the
// model is shown where to read it.
@(test)
test_shell_keeps_output_larger_than_memory_in_a_file :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	size :: 3 * TOOL_STREAM_MEMORY_BYTES
	command := fmt.tprintf(`{{"command":"head -c %d /dev/zero | tr '\\\\000' a"}}`, size)
	result := tool_run(test, &tool_test, TOOL_SHELL_NAME, command)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(result.content, fmt.tprintf("stdout_bytes: %d\n", size)), "the whole size is reported")

	marker := "stdout_complete_in: "
	start := strings.index(result.content, marker)
	if !testing.expect(test, start >= 0, "the result names the file that keeps the stream") { return }
	rest := result.content[start + len(marker):]
	path := rest[:strings.index_byte(rest, '\n')]
	info, stat_error := os.stat(path, context.temp_allocator)
	testing.expect(test, stat_error == nil, "the stream file exists")
	testing.expect_value(test, info.size, i64(size))
}

@(test)
test_shell_refuses_arguments_before_dispatch :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	result := tool_run(test, &tool_test, TOOL_SHELL_NAME, `{"command":""}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Invalid_Arguments)
	testing.expect(test, strings.contains(result.content, `kind: invalid_value`), "the refusal names its kind")

	// Invalid arguments are answered without dispatching an executor, which is why the
	// call has a proposal and a result but no admission between them.
	records := _test_records(test, &tool_test.fixture.chat, {.Tool_Proposed, .Tool_Admitted, .Tool_Completed})
	if !testing.expect_value(test, len(records), 2) { return }
	testing.expect_value(test, records[0].kind, journal.Record_Kind.Tool_Proposed)
	testing.expect_value(test, records[1].kind, journal.Record_Kind.Tool_Completed)
}

@(test)
test_read_reports_the_lines_it_returned :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	path := strings.concatenate({tool_test_workspace(&tool_test), "/notes.txt"}, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	if !tool_write_file(test, path, "one\ntwo\nthree\nfour\n") { return }

	arguments := strings.concatenate({`{"path":"`, path, `","offset":2,"limit":2}`}, context.temp_allocator)
	result := tool_run(test, &tool_test, TOOL_READ_NAME, arguments)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(result.content, "\n\ntwo\nthree\n"), "the requested lines are returned")
	testing.expect(test, strings.contains(result.content, `total_lines: 4`), "the file's line count is reported")

	missing := tool_run(test, &tool_test, TOOL_READ_NAME, `{"path":"gone.txt"}`)
	testing.expect_value(test, missing.outcome, journal.Tool_Outcome.Tool_Failed)
}

// A file the read tool cannot hand to the model is refused rather than encoded. A NUL byte
// and a byte that is not UTF-8 both mean the file is not text, and a result carrying either
// would not be JSON: the encoder escapes such a byte as a JSON5 sequence, and a reader that
// silently received only the prefix would not know it had.
@(test)
test_read_refuses_a_file_that_is_not_text :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	nul := strings.concatenate({tool_test_workspace(&tool_test), "/nul.bin"}, context.temp_allocator)
	defer delete(nul, context.temp_allocator)
	if !tool_write_file(test, nul, "one\x00two\n") { return }
	nul_arguments := strings.concatenate({`{"path":"`, nul, `"}`}, context.temp_allocator)
	nul_result := tool_run(test, &tool_test, TOOL_READ_NAME, nul_arguments)
	tool_test_result_matches(test, nul_result.content, .Tool_Failed, fmt.tprintf("%s is not a text file", nul))

	stray := strings.concatenate({tool_test_workspace(&tool_test), "/stray.bin"}, context.temp_allocator)
	defer delete(stray, context.temp_allocator)
	if !tool_write_file(test, stray, "good \xff\xfe bad \xc3\n") { return }
	stray_arguments := strings.concatenate({`{"path":"`, stray, `"}`}, context.temp_allocator)
	stray_result := tool_run(test, &tool_test, TOOL_READ_NAME, stray_arguments)
	tool_test_result_matches(test, stray_result.content, .Tool_Failed, fmt.tprintf("%s is not a text file", stray))

	// Text outside ASCII is valid UTF-8 and is returned as written.
	text := strings.concatenate({tool_test_workspace(&tool_test), "/text.txt"}, context.temp_allocator)
	defer delete(text, context.temp_allocator)
	if !tool_write_file(test, text, "caf\xc3\xa9\n") { return }
	text_arguments := strings.concatenate({`{"path":"`, text, `"}`}, context.temp_allocator)
	text_result := tool_run(test, &tool_test, TOOL_READ_NAME, text_arguments)
	testing.expect_value(test, text_result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(text_result.content, "caf\xc3\xa9"), "valid UTF-8 is returned as written")
}

@(test)
test_write_replaces_a_file_by_absolute_or_relative_path :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	out := strings.concatenate({tool_test_workspace(&tool_test), "/out.txt"}, context.temp_allocator)
	defer delete(out, context.temp_allocator)

	arguments := strings.concatenate({`{"path":"`, out, `","content":"first\n"}`}, context.temp_allocator)
	result := tool_run(test, &tool_test, TOOL_WRITE_NAME, arguments)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	if !tool_file_is(test, out, "first\n") { return }

	again := tool_run(test, &tool_test, TOOL_WRITE_NAME, `{"path":"out.txt","content":"second"}`)
	testing.expect_value(test, again.outcome, journal.Tool_Outcome.Success)
	if !tool_file_is(test, out, "second") { return }
}

@(test)
test_patch_applies_every_file_or_none :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	workspace := tool_test_workspace(&tool_test)
	code := strings.concatenate({workspace, "/code.txt"}, context.temp_allocator)
	gone := strings.concatenate({workspace, "/gone.txt"}, context.temp_allocator)
	added := strings.concatenate({workspace, "/new/added.txt"}, context.temp_allocator)
	later := strings.concatenate({workspace, "/later.txt"}, context.temp_allocator)
	if !tool_write_file(test, code, "one\ntwo  \nthree\nfour\nfive\n") { return }
	if !tool_write_file(test, gone, "bye\n") { return }

	// The first hunk matches only once trailing spaces are ignored.
	patch := `{"patch":"*** Begin Patch\n*** Update File: code.txt\n@@\n one\n-two\n+TWO\n three\n@@\n-five\n+FIVE\n*** Add File: new/added.txt\n+hello\n*** Delete File: gone.txt\n*** End Patch"}`
	result := tool_run(test, &tool_test, TOOL_PATCH_NAME, patch)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	tool_file_is(test, code, "one\nTWO\nthree\nfour\nFIVE\n")
	tool_file_is(test, added, "hello\n")
	testing.expect(test, !os.exists(gone), "a deleted file is removed")

	// A hunk that matches twice fails the whole patch, so no file in it is written.
	if !tool_write_file(test, code, "same\nsame\n") { return }
	ambiguous := `{"patch":"*** Begin Patch\n*** Add File: later.txt\n+x\n*** Update File: code.txt\n-same\n+once\n*** End Patch"}`
	failed := tool_run(test, &tool_test, TOOL_PATCH_NAME, ambiguous)
	testing.expect_value(test, failed.outcome, journal.Tool_Outcome.Tool_Failed)
	tool_file_is(test, code, "same\nsame\n")
	testing.expect(test, !os.exists(later), "a failed patch adds no file")
}

@(test)
test_patch_reads_loose_patches_with_one_meaning :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	code := strings.concatenate({tool_test_workspace(&tool_test), "/code.txt"}, context.temp_allocator)

	// A unified diff without the envelope, whose line number picks one of two equal places.
	if !tool_write_file(test, code, "same\nx\nsame\nx\n") { return }
	unified := `{"patch":"--- a/code.txt\n+++ b/code.txt\n@@ -3,1 +3,1 @@\n-same\n+SAME\n"}`
	testing.expect_value(test, tool_run(test, &tool_test, TOOL_PATCH_NAME, unified).outcome, journal.Tool_Outcome.Success)
	tool_file_is(test, code, "same\nx\nSAME\nx\n")

	// A hunk that lost the file's indentation matches, and its added lines take that indentation.
	if !tool_write_file(test, code, "if x {\n\tfoo()\n}\n") { return }
	unindented := `{"patch":"*** Update File: code.txt\n if x {\n-foo()\n+bar()\n }\n"}`
	testing.expect_value(test, tool_run(test, &tool_test, TOOL_PATCH_NAME, unindented).outcome, journal.Tool_Outcome.Success)
	tool_file_is(test, code, "if x {\n\tbar()\n}\n")
}

@(test)
test_every_native_tool_is_registered_complete :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	// The registry is sorted, so the advertised order never depends on the order
	// tools were registered in.
	chat := &tool_test.fixture.chat
	if !testing.expect_value(test, len(chat.tools.definitions), TOOL_NATIVE_COUNT) { return }
	for index in 1 ..< len(chat.tools.definitions) {
		testing.expect(test, chat.tools.definitions[index - 1].name < chat.tools.definitions[index].name, "the advertised order is stable")
	}
	for definition in chat.tools.definitions {
		testing.expect(test, definition.description != "", "a tool is described")
		testing.expect(test, definition.input_schema != "", "a tool advertises its arguments")
		testing.expect(test, definition.execute != nil, "a tool has an executor")
	}
}

// tool_test_dummy_execute stands in for an executor where only registration
// matters. Nothing runs through it.
tool_test_dummy_execute :: proc(tool_context: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	return tool_result_failure(tool_context, .Tool_Failed, "dummy", "dummy")
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
test_registry_rejects_invalid_definitions :: proc(test: ^testing.T) {
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
	for item in cases {
		definition := tool_test_valid_definition(context.allocator)
		item.mutate(&definition)
		registry := Tool_Registry {
			allocator = context.allocator,
		}
		registry.definitions = make([dynamic]Tool_Definition, 0, 1, context.allocator)
		add_error := tool_registry_add(&registry, definition)
		testing.expect_value(test, add_error.kind, item.kind)
		testing.expect_value(test, len(registry.definitions), 0)
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
	testing.expect_value(test, tool_registry_add(&registry, definition).kind, Tool_Registry_Error_Kind.Invalid_Name)

	delete(definition.name, context.allocator)
	definition.name = strings.clone("test_tool", context.allocator)
	delete(definition.description, context.allocator)
	definition.description = strings.repeat("d", TOOL_MAX_DESCRIPTION_BYTES + 1, context.allocator)
	testing.expect_value(test, tool_registry_add(&registry, definition).kind, Tool_Registry_Error_Kind.Missing_Description)

	delete(definition.description, context.allocator)
	definition.description = strings.clone("A test tool.", context.allocator)
	delete(definition.input_schema, context.allocator)
	definition.input_schema = strings.concatenate(
		{`{"type":"object","x":"`, strings.repeat("x", TOOL_MAX_SCHEMA_BYTES, context.temp_allocator), `"}`},
		context.allocator,
	)
	testing.expect_value(test, tool_registry_add(&registry, definition).kind, Tool_Registry_Error_Kind.Invalid_Schema)
	testing.expect_value(test, len(registry.definitions), 0)
}

// The canonical grammar is the narrowest of every boundary a name crosses: a Lua field
// identifier that OpenAI-compatible and Anthropic APIs also accept, inside the 64-byte
// provider limit. Everything outside it needs no round trip to be refused.
@(test)
test_canonical_name_grammar :: proc(test: ^testing.T) {
	valid := []string{"builtin_read", "fff_grep", "github_create_issue", "a", "_", "A9_z"}
	for name in valid { testing.expectf(test, tool_name_valid(name), "%q should be a valid tool name", name) }

	invalid := []string{"", "builtin.read", "fff-grep", "builtin read", "9lives", "\u00e9cho", "a.b-c"}
	for name in invalid { testing.expectf(test, !tool_name_valid(name), "%q should not be a valid tool name", name) }

	under_limit := strings.repeat("n", TOOL_MAX_NAME_BYTES, context.temp_allocator)
	over_limit := strings.repeat("n", TOOL_MAX_NAME_BYTES + 1, context.temp_allocator)
	testing.expect(test, tool_name_valid(under_limit), "a name at the provider limit is admitted")
	testing.expect(test, !tool_name_valid(over_limit), "a name past the provider limit is refused")
}

// A collision is a configuration error, never a silent replacement. The first
// definition keeps its place and its backend binding.
@(test)
test_registry_refuses_name_collisions :: proc(test: ^testing.T) {
	registry, make_error := tool_registry_make(context.allocator)
	defer tool_registry_destroy(&registry)
	if !testing.expect_value(test, make_error.kind, Tool_Registry_Error_Kind.None) { return }
	before := len(registry.definitions)

	sentinel: u8 = 7
	duplicate := tool_shell_definition(TOOL_SHELL_FALLBACK, context.allocator)
	defer delete(duplicate.description, context.allocator)
	duplicate.backend = &sentinel
	add_error := tool_registry_add(&registry, duplicate)
	testing.expect_value(test, add_error.kind, Tool_Registry_Error_Kind.Name_Collision)
	testing.expect_value(test, add_error.tool, TOOL_SHELL_NAME)
	testing.expect_value(test, len(registry.definitions), before)

	// The registry owns its strings: the definition passed in is borrowed, and
	// freeing the caller's copy must not disturb what was stored.
	definition := tool_test_valid_definition(context.allocator)
	if !testing.expect_value(test, tool_registry_add(&registry, definition).kind, Tool_Registry_Error_Kind.None) {
		tool_test_definition_destroy(&definition, context.allocator)
		return
	}
	tool_test_definition_destroy(&definition, context.allocator)
	stored, found := tool_registry_find(&registry, "test_tool")
	if !testing.expect(test, found, "the stored definition survives its source") { return }
	testing.expect_value(test, stored.name, "test_tool")
	testing.expect_value(test, stored.description, "A test tool.")
	testing.expect_value(test, stored.input_schema, `{"type":"object"}`)

	// A borrowed backend binding is preserved through registration.
	marker: u8 = 13
	bound := tool_test_valid_definition(context.allocator)
	delete(bound.name, context.allocator)
	bound.name = strings.clone("test_bound_tool", context.allocator)
	bound.backend = &marker
	defer tool_test_definition_destroy(&bound, context.allocator)
	if !testing.expect_value(test, tool_registry_add(&registry, bound).kind, Tool_Registry_Error_Kind.None) { return }
	found_definition, bound_found := tool_registry_find(&registry, "test_bound_tool")
	if !testing.expect(test, bound_found, "the bound definition is registered") { return }
	testing.expect(test, found_definition.backend == &marker, "the backend binding is preserved")
}

// --- result finalization -------------------------------------------------------

// tool_test_result_matches checks the outcome line a stored result starts with.
tool_test_result_matches :: proc(test: ^testing.T, content: string, outcome: journal.Tool_Outcome, message: string) -> bool {
	expected, render_error := tool_result_render(outcome, message, nil, context.temp_allocator)
	if !testing.expect_value(test, render_error, nil) { return false }
	return testing.expect(test, strings.has_prefix(content, expected), content)
}

// The read tool adds no size limit of its own: a long line is read whole, the model is shown
// its beginning, and the complete output is kept in a file it can read.
@(test)
test_read_keeps_a_long_line_whole :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	long := strings.repeat("a", 256 * 1024, context.temp_allocator)
	line := strings.concatenate({long, "\n"}, context.temp_allocator)
	path := strings.concatenate({tool_test_workspace(&tool_test), "/long.txt"}, context.temp_allocator)
	if !tool_write_file(test, path, line) { return }

	result := tool_run(test, &tool_test, TOOL_READ_NAME, `{"path":"long.txt"}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, !strings.contains(result.content, "truncated: true\n"), "the read itself took the whole file")
	testing.expect(test, strings.contains(budget_test_kept_file(test, result.content), long), "the line must be kept whole")
}

// --- timeout policy ------------------------------------------------------------

// Cancellation wins over the tool timeout when both are observed, and the two
// stops are distinguishable: only the budget expiring reports Timed_Out.
@(test)
test_control_stop_names_the_stop :: proc(test: ^testing.T) {
	start := time.tick_now()
	testing.expect_value(test, tool_control_stop({}, start, time.Hour), Tool_Stop.None)

	interrupt: ai.Interrupt
	ai.interrupt_request(&interrupt)
	cancelled := Tool_Control {
		interrupt = &interrupt,
	}
	past := time.tick_add(time.tick_now(), -2 * time.Second)
	testing.expect_value(test, tool_control_stop(cancelled, past, time.Second), Tool_Stop.Cancelled)
	testing.expect_value(test, tool_control_stop({}, past, time.Second), Tool_Stop.Timed_Out)
}

// A model-requested timeout is honored as given: the shell has no maximum.
@(test)
test_shell_honors_a_long_timeout :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	result := tool_run(test, &tool_test, TOOL_SHELL_NAME, `{"command":"echo hi","timeout_ms":999999999}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
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
test_write_cancelled_before_begin_leaves_no_file :: proc(test: ^testing.T) {
	workspace, workspace_error := os.make_directory_temp("", "nabla-tool-cancel-*", context.allocator)
	if workspace_error != nil { testing.fail_now(test, "could not create a workspace") }
	defer {
		os.remove_all(workspace)
		delete(workspace, context.allocator)
	}

	tool_context := tool_test_cancelled_moment(workspace)
	arguments := tool_arguments_prepare(`{"path":"cancelled.txt","content":"hello"}`, context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	object, is_object := arguments.value.(json.Object)
	if !testing.expect(test, is_object, "the arguments should parse") { return }
	result := tool_test_execute(&tool_context, TOOL_WRITE_DEFINITION, object)
	defer tool_result_destroy(&result)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Cancelled)
	full := strings.concatenate({workspace, "/cancelled.txt"}, context.temp_allocator)
	testing.expect(test, !os.exists(full), "a cancelled write leaves no file")
}

// A patch cancelled before the rename keeps the destination unchanged.
@(test)
test_patch_cancelled_before_rename_keeps_destination :: proc(test: ^testing.T) {
	workspace, workspace_error := os.make_directory_temp("", "nabla-tool-cancel-*", context.allocator)
	if workspace_error != nil { testing.fail_now(test, "could not create a workspace") }
	defer {
		os.remove_all(workspace)
		delete(workspace, context.allocator)
	}
	path := strings.concatenate({workspace, "/code.txt"}, context.temp_allocator)
	if !tool_write_file(test, path, "alpha\n") { return }

	tool_context := tool_test_cancelled_moment(workspace)
	arguments := tool_arguments_prepare(`{"patch":"*** Begin Patch\n*** Update File: code.txt\n-alpha\n+beta\n*** End Patch"}`, context.allocator)
	defer tool_arguments_destroy(&arguments, context.allocator)
	object, is_object := arguments.value.(json.Object)
	if !testing.expect(test, is_object, "the arguments should parse") { return }
	result := tool_test_execute(&tool_context, TOOL_PATCH_DEFINITION, object)
	defer tool_result_destroy(&result)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Cancelled)
	tool_file_is(test, path, "alpha\n")
}

// A replacement is an atomic swap: on success the session owns the new
// registry and the old one is gone, while a busy session keeps its registry
// and the caller keeps owning the replacement.
@(test)
test_replace_tools_swaps_only_while_idle :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	testing.expect_value(test, chat.state, Chat_State.Idle)

	replacement, make_error := tool_registry_make(chat.allocator)
	if !testing.expect_value(test, make_error.kind, Tool_Registry_Error_Kind.None) {
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
	if !testing.expect_value(test, tool_registry_add(&replacement, extra).kind, Tool_Registry_Error_Kind.None) {
		tool_registry_destroy(&replacement)
		return
	}
	tool_registry_sort(&replacement)

	testing.expect_value(test, chat_session_replace_tools(chat, &replacement), Tool_Registry_Replace_Error.None)
	testing.expect_value(test, len(chat.tools.definitions), TOOL_NATIVE_COUNT + 1)
	_, found := tool_registry_find(&chat.tools, "test_extra_tool")
	testing.expect(test, found, "the replacement registry is installed")

	// A turn is in flight, so the registry is frozen: the swap is refused and
	// the session keeps what it has.
	_test_accept(test, chat, "hi")
	second, second_error := tool_registry_make(chat.allocator)
	if !testing.expect_value(test, second_error.kind, Tool_Registry_Error_Kind.None) {
		tool_registry_destroy(&second)
		return
	}
	defer tool_registry_destroy(&second)
	testing.expect_value(test, chat_session_replace_tools(chat, &second), Tool_Registry_Replace_Error.Busy)
	_, still_there := tool_registry_find(&chat.tools, "test_extra_tool")
	testing.expect(test, still_there, "a busy session keeps its registry")
}

// --- recovery ----------------------------------------------------------------

// The recovery results are constants so recovery allocates nothing. A drift between them and
// the renderer would put text into a recovered session that no other result looks like, so
// they are held to it here.
@(test)
test_recovery_results_match_the_renderer :: proc(test: ^testing.T) {
	tool_context := Tool_Context {
		allocator = context.temp_allocator,
	}
	recovered := tool_result_of(&tool_context, .Unknown, TOOL_RECOVERED_MESSAGE, nil)
	defer tool_result_destroy(&recovered)
	testing.expect_value(test, recovered.content, TOOL_RECOVERED_RESULT)

	unexecuted := tool_result_of(&tool_context, .Not_Executed, TOOL_UNEXECUTED_MESSAGE, nil)
	defer tool_result_destroy(&unexecuted)
	testing.expect_value(test, unexecuted.content, TOOL_UNEXECUTED_RESULT)
}

// --- helpers -----------------------------------------------------------------

tool_write_file :: proc(test: ^testing.T, path, content: string) -> bool {
	file, create_error := os.create(path)
	if create_error != nil {
		testing.fail_now(test, "the test file could not be created")
	}
	written, write_error := os.write(file, transmute([]u8)content)
	os.close(file)
	if write_error != nil || written != len(content) {
		testing.fail_now(test, "the test file could not be written")
	}
	return true
}

tool_file_is :: proc(test: ^testing.T, path, expected: string) -> bool {
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		testing.fail_now(test, "the test file could not be read")
	}
	defer delete(data, context.temp_allocator)
	return testing.expectf(test, string(data) == expected, "%s holds %q, not %q", path, string(data), expected)
}

// Exercise the provider adapter before calling a typed executor.
tool_test_execute :: proc(tool_context: ^Tool_Context, definition: Tool_Definition, object: json.Object) -> Tool_Result {
	arguments, argument_error := tool_args_decode(tool_context, definition, object)
	defer tool_args_destroy(&arguments, tool_context.allocator)
	defer tool_argument_error_destroy(&argument_error, tool_context.allocator)
	if argument_error != nil { return tool_result_refused(tool_context, &argument_error) }
	return definition.execute(tool_context, arguments)
}

// tool_test_defect is the defect an argument error holds, or the zero defect when it holds none.
tool_test_defect :: proc(argument_error: Tool_Argument_Error) -> Tool_Argument_Defect {
	return argument_error.? or_else {}
}
