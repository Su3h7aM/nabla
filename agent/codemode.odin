package agent

import "core:encoding/json"
import "core:time"

TOOL_CODEMODE_NAME :: "builtin_codemode"
TOOL_CODEMODE_DESCRIPTION :: "Run a Lua 5.4 program instead of several separate tool calls, and instead of a Python script through the shell. Call a tool as tools.<name>(args), for example tools.builtin_read({path = 'README.md'}); it waits and returns a table with outcome, message, and output. job.start(name, args) starts a call and returns a handle, and job.wait(handle) returns its result, so calls run while the program continues. Available: the string, table, math, and utf8 libraries, pcall, error, setmetatable, os.time, os.clock, os.date, json.encode, json.decode, and json.null, which stands for JSON null because nil means absence. print writes to the result's log. The chunk returns at most one value, which the result shows as a Lua literal."
TOOL_CODEMODE_SCHEMA :: `{"type":"object","properties":{"code":{"type":"string","description":"Lua 5.4 source code to execute."},"timeout_ms":{"type":["integer","null"],"description":"Positive timeout in milliseconds for the whole program. Leave out or pass null for no timeout."}},"required":["code"],"additionalProperties":false}`
TOOL_CODEMODE_FIELDS :: []string{"code", "timeout_ms"}

// CODEMODE_MAX_CALL_SUMMARIES bounds how many child summaries a result carries. The
// count is reported separately, so a truncated list still says how much a script did.
CODEMODE_MAX_CALL_SUMMARIES :: 32

// Codemode_Diagnostic is why an execution did not finish. It lives inside the ordinary
// result, not as a second stored outcome: the outer Tool_Outcome still says whether
// anything ran.
Codemode_Diagnostic :: enum {
	None,
	Syntax_Error,
	Runtime_Error,
	Invalid_Value,
	Out_Of_Memory,
	Output_Limit,
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
	.Output_Limit  = "output_limit",
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
