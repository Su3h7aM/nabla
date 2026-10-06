package agent

import "core:encoding/json"
import "core:time"

TOOL_CODEMODE_NAME :: "builtin_codemode"
TOOL_CODEMODE_DESCRIPTION ::
	`Run a Lua 5.4 program that calls other tools. Use it instead of several separate tool calls when a task has several steps, computes or filters results, or edits a file by exact text, and instead of a Python, Perl, awk, or sed script run through builtin_shell. A single read or command needs no script.

Call a tool as tools.<name>(args) with one table of named arguments, for example tools.builtin_read({path = "README.md"}). The names are the tool names you were given, such as builtin_read, builtin_shell, builtin_write, and builtin_patch; builtin_codemode cannot be called from a script. The call waits and returns a table with three fields:
- outcome: a string such as "success", "tool_failed", "invalid_arguments", "timed_out", or "cancelled".
- message: why the call did not succeed, or an empty string.
- output: a table of the tool's result fields, absent when the tool produced none.
A failed call does not raise, so check outcome == "success" before using output. The fields of output are builtin_read: content (the lines read, which are the whole file only when first_line is 1 and truncated is false), path, first_line, line_count, total_lines, truncated (true when lines remain after the window); builtin_shell: stdout, stderr, exit_code (absent when a signal ended the command), and stdout_bytes, stderr_bytes, stdout_file, stderr_file for a stream too large to hold in memory; builtin_write: path, bytes; builtin_patch: files, summary. An unknown tool name or arguments that are not one table raise a Lua error at that line, which pcall catches.

To run calls at the same time, start each with job.start(name, args), which returns a handle, then collect it with job.wait(handle), which returns the same table as a direct call.

Only what the script returns or prints reaches you. The chunk may return one value (a string, number, boolean, or table of them; functions and cyclic tables are refused), which the result shows as a Lua literal, and print writes lines to a log. A child's output is not cut inside the script, but the script's own result is previewed like any tool result, so return only what you need.

Libraries: the base functions except load, loadfile, dofile, require, collectgarbage, and warn; string, table, math, utf8; os.time, os.clock, os.date, os.difftime; json.encode, json.decode, and json.null, which stands for JSON null because Lua nil means absence. There is no io, other os function, or coroutine: reach files and processes through tools.

Lua patterns give special meaning to ^ $ ( ) % . [ ] * + - ?. To find literal text use string.find(text, needle, 1, true) (plain = true), which returns the start and end positions. To edit a file by exact text, read it with a limit large enough that output.truncated is false, find the old text, join text:sub(1, start - 1), the new text, and text:sub(stop + 1), and write the result with builtin_write.`
TOOL_CODEMODE_SCHEMA :: `{"type":"object","properties":{"code":{"type":"string","description":"Lua 5.4 source. Call tools with tools.<name>(args); return one value and use print for a log."},"timeout_ms":{"type":["integer","null"],"description":"Positive timeout in milliseconds for the whole program. Leave out or pass null for no timeout."}},"required":["code"],"additionalProperties":false}`
TOOL_CODEMODE_FIELDS :: []string{"code", "timeout_ms"}

// Codemode_Diagnostic is why an execution did not finish. It lives inside the ordinary
// result, not as a second stored outcome: the outer Tool_Outcome still says whether
// anything ran.
Codemode_Diagnostic :: enum {
	None,
	Syntax_Error,
	Runtime_Error,
	Invalid_Value,
	Out_Of_Memory,
	Timed_Out,
	Cancelled,
	Unavailable,
}

@(private)
codemode_diagnostic_names := [Codemode_Diagnostic]string {
	.None          = "",
	.Syntax_Error  = "syntax_error",
	.Runtime_Error = "runtime_error",
	.Invalid_Value = "invalid_value",
	.Out_Of_Memory = "out_of_memory",
	.Timed_Out     = "timed_out",
	.Cancelled     = "cancelled",
	.Unavailable   = "unavailable",
}

TOOL_CODEMODE_DEFINITION :: Tool_Definition {
	name = TOOL_CODEMODE_NAME,
	description = TOOL_CODEMODE_DESCRIPTION,
	input_schema = TOOL_CODEMODE_SCHEMA,
	hints = {read_only = .No, destructive = .No, idempotent = .Unknown, open_world = .Unknown},
	placement = .Lua,
	// Lua jobs are driven by the owner through the job table. The procedure is a
	// registry invariant and a defensive fallback, not their execution path.
	kind = .Codemode,
	execute = tool_codemode_unreachable,
}

// tool_codemode_args reads the program and its optional timeout. Zero means no timeout.
tool_codemode_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Codemode_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_CODEMODE_FIELDS, allocator = ctx.allocator) or_return
	code := tool_field_string(arguments, "code", allocator = ctx.allocator) or_return
	timeout_ms := tool_field_optional_int(
		arguments,
		"timeout_ms",
		0,
		1,
		int(max(time.Duration) / time.Millisecond),
		&ctx.repairs,
		allocator = ctx.allocator,
	) or_return
	return {code = code, timeout = time.Duration(timeout_ms) * time.Millisecond}, nil
}

@(private)
tool_codemode_unreachable :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	output := Codemode_Output {
		failure = codemode_diagnostic_names[.Unavailable],
	}
	return tool_result_of(ctx, .Tool_Failed, "the Code Mode executor was not available", output, "executor unavailable")
}
