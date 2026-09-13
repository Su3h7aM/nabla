#+test
package agent

import "core:encoding/json"
import "core:testing"

import "nabla:agent/session"

@(test)
test_shell_parameters_schema_matches_parser :: proc(t: ^testing.T) {
	value, parse_err := json.parse_string(TOOL_SHELL_PARAMETERS_JSON, .JSON, true, context.temp_allocator)
	testing.expect_value(t, parse_err, nil)
	defer json.destroy_value(value, context.temp_allocator)
	object, is_object := value.(json.Object)
	testing.expect(t, is_object)
	required_raw, present := object["required"]
	testing.expect(t, present)
	required, is_array := required_raw.(json.Array)
	testing.expect(t, is_array)
	names := make([dynamic]string, 0, len(required), context.temp_allocator)
	for entry in required {
		name, is_string := entry.(json.String)
		testing.expect(t, is_string)
		if is_string { append(&names, string(name)) }
	}
	testing.expect_value(t, len(names), 3)
	expected_names := []string{"command", "working_directory", "timeout_ms"}
	for expected in expected_names {
		found := false
		for name in names {
			if name == expected { found = true }
		}
		testing.expectf(t, found, "schema required lacks %q", expected)
	}
}

@(test)
test_shell_parse_args_accepts_full_shape :: proc(t: ^testing.T) {
	raw := `{"command":"echo hi","working_directory":null,"timeout_ms":null}`
	args, ok := tool_shell_parse_args(raw, context.allocator)
	defer tool_shell_args_destroy(&args, context.allocator)
	testing.expect(t, ok)
	testing.expect_value(t, args.command, "echo hi")
	testing.expect_value(t, args.working_directory, "")
	testing.expect_value(t, args.timeout_ms, TOOL_DEFAULT_TIMEOUT_MS)
}

@(test)
test_shell_parse_args_rejects_shapes :: proc(t: ^testing.T) {
	cases := []string {
		`{}`,
		`{"command":"","working_directory":null,"timeout_ms":null}`,
		`{"command":"echo","working_directory":null}`,
		`{"command":"echo","working_directory":null,"timeout_ms":null,"extra":1}`,
		`{"command":"echo","command":"ls","working_directory":null,"timeout_ms":null}`,
		`{"command":"echo","working_directory":"/abs","timeout_ms":null}`,
		`{"command":"echo","working_directory":null,"timeout_ms":0}`,
		`{"command":"echo","working_directory":null,"timeout_ms":999999999}`,
		`[1,2]`,
	}
	for raw in cases {
		args, ok := tool_shell_parse_args(raw, context.allocator)
		tool_shell_args_destroy(&args, context.allocator)
		testing.expect(t, !ok)
	}
}

@(test)
test_shell_execute_enforces_timeout :: proc(t: ^testing.T) {
	args, ok := tool_shell_parse_args(`{"command":"sleep 5","working_directory":null,"timeout_ms":200}`, context.temp_allocator)
	testing.expect(t, ok)
	defer tool_shell_args_destroy(&args, context.temp_allocator)
	result := tool_shell_execute("call_timeout", args, tool_loop_workspace(t), {})
	defer tool_result_destroy(&result)
	testing.expect_value(t, result.status, Tool_Result_Status.Timed_Out)
}

@(test)
test_shell_execute_bounds_output :: proc(t: ^testing.T) {
	args, ok := tool_shell_parse_args(`{"command":"yes x | head -c 200000","working_directory":null,"timeout_ms":10000}`, context.temp_allocator)
	testing.expect(t, ok)
	defer tool_shell_args_destroy(&args, context.temp_allocator)
	result := tool_shell_execute("call_bound", args, tool_loop_workspace(t), {})
	defer tool_result_destroy(&result)
	testing.expect(t, result.stdout_trunc)
	testing.expect(t, len(result.stdout) <= TOOL_MAX_STDOUT_BYTES)
}

@(test)
test_shell_resolve_directory_stays_inside :: proc(t: ^testing.T) {
	resolved, ok := tool_resolve_directory("/work", "sub/dir", context.temp_allocator)
	defer if ok { delete(resolved, context.temp_allocator) }
	testing.expect(t, ok)
	testing.expect_value(t, resolved, "/work/sub/dir")
	_, ok = tool_resolve_directory("/work", "../escape", context.temp_allocator)
	testing.expect(t, !ok)
	_, ok = tool_resolve_directory("/work", "/abs", context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
test_shell_result_json_shape :: proc(t: ^testing.T) {
	result := Tool_Result {
		call_id      = "call_1",
		status       = .Exited,
		exit_code    = 0,
		exit_present = true,
		stdout       = "hello\n",
		stderr       = "",
		allocator    = context.temp_allocator,
	}
	// Strings borrow the literal; only the JSON output is owned here.
	text := tool_result_json(&result, context.temp_allocator)
	testing.expect(t, len(text) > 0)
	testing.expect(t, len(text) <= TOOL_MAX_RESULT_BYTES)
	result.call_id, result.stdout, result.stderr = "", "", ""
	tool_result_destroy(&result)
}

@(test)
test_shell_prepare_repairs_control_bytes_only :: proc(t: ^testing.T) {
	// A raw newline inside the command string is the one defect a repair is
	// forced to resolve, and the decoded command keeps the exact byte.
	raw := "{\"command\":\"printf a\nb\",\"working_directory\":null,\"timeout_ms\":null}"
	prep := tool_shell_prepare(raw, context.allocator)
	defer tool_preparation_destroy(&prep, context.allocator)
	if !testing.expect_value(t, prep.status, Tool_Preparation_Status.Repaired) { return }
	testing.expect_value(t, prep.repair, session.Tool_Repair.Escaped_Control_Characters)
	testing.expect_value(t, prep.args.command, "printf a\nb")
	testing.expect(t, prep.effective != raw, "the recorded arguments are the repaired bytes")

	// Everything else is reported, never guessed at.
	rejects := []string {
		`{"command":"a\qb","working_directory":null,"timeout_ms":null}`,
		`{"command":."working_directory":null,"timeout_ms":null}`,
		`{"command":"a","working_directory":null,"timeout_ms":null`,
		`{"command":"a","command":"b","working_directory":null,"timeout_ms":null}`,
	}
	for reject in rejects {
		args, ok := tool_shell_parse_args(reject, context.allocator)
		tool_shell_args_destroy(&args, context.allocator)
		testing.expectf(t, !ok, "%s must not be repaired", reject)
	}
}

@(test)
test_shell_prepare_reports_the_defect :: proc(t: ^testing.T) {
	cases := []struct {
		raw:   string,
		kind:  Tool_Argument_Error_Kind,
		field: string,
	} {
		{`[1,2]`, .Not_Object, ""},
		{`{}`, .Missing_Field, "command"},
		{`{"command":"a","working_directory":null,"timeout_ms":null,"x":1}`, .Unknown_Field, ""},
		{`{"command":"a","command":"b","working_directory":null,"timeout_ms":null}`, .Duplicate_Field, "command"},
		{`{"command":7,"working_directory":null,"timeout_ms":null}`, .Wrong_Type, "command"},
		{`{"command":"a","working_directory":null,"timeout_ms":0}`, .Invalid_Value, "timeout_ms"},
	}
	for c in cases {
		prep := tool_shell_prepare(c.raw, context.allocator)
		ok := testing.expectf(t, prep.status == .Rejected, "%s must be rejected", c.raw)
		if ok {
			testing.expect_value(t, prep.error.kind, c.kind)
			// A defect about a value has to name the constraint, or the model is told
			// only that something is wrong.
			if c.kind == .Wrong_Type || c.kind == .Invalid_Value {
				testing.expectf(t, prep.error.expected != "", "%s must say what was expected", c.raw)
			}
			testing.expect(t, tool_argument_error_text(prep.error, context.temp_allocator) != "")
		}
		if ok && c.field != "" { testing.expect_value(t, prep.error.field, c.field) }
		tool_preparation_destroy(&prep, context.allocator)
	}
}
