#+test
package agent

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/session"

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

	result := tool_run(t, &test, TOOL_READ_NAME, `{"path":"notes.txt","offset":2,"limit":2}`)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(result.content, `"content":"two\nthree\n"`), "the requested lines are returned")
	testing.expect(t, strings.contains(result.content, `"total_lines":4`), "the file's line count is reported")

	missing := tool_run(t, &test, TOOL_READ_NAME, `{"path":"gone.txt"}`)
	testing.expect_value(t, missing.outcome, session.Tool_Outcome.Tool_Failed)
}

@(test)
test_write_replaces_a_file_and_keeps_a_refusal_from_touching_it :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	out := strings.concatenate({tool_test_workspace(&test), "/out.txt"}, context.temp_allocator)
	defer delete(out, context.temp_allocator)

	result := tool_run(t, &test, TOOL_WRITE_NAME, `{"path":"out.txt","content":"first\n"}`)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
	if !tool_file_is(t, out, "first\n") { return }

	again := tool_run(t, &test, TOOL_WRITE_NAME, `{"path":"out.txt","content":"second"}`)
	testing.expect_value(t, again.outcome, session.Tool_Outcome.Success)
	if !tool_file_is(t, out, "second") { return }

	tool_run(t, &test, TOOL_WRITE_NAME, `{"path":"../out.txt","content":"nope"}`)
	tool_file_is(t, out, "second")
}

@(test)
test_edit_applies_every_replacement_or_none :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	path := strings.concatenate({tool_test_workspace(&test), "/code.txt"}, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	if !tool_write_file(t, path, "alpha beta gamma\n") { return }

	result := tool_run(t, &test, TOOL_EDIT_NAME, `{"path":"code.txt","edits":[{"old":"alpha","new":"ALPHA"},{"old":"gamma","new":"GAMMA"}]}`)
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
