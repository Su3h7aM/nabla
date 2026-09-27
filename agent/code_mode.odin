package agent


import "nabla:agent/session"

TOOL_CODE_NAME :: "builtin_code"
TOOL_CODE_DESCRIPTION :: "Execute Lua 5.4 code. Call an available tool through the tools table by its name, for example tools.builtin_read({path = 'README.md'}). Each call suspends the script until the tool finishes and returns a table with outcome, message, and the tool's output fields. Use json.null for JSON null, because Lua nil means absence. The chunk returns at most one value, which this result shows as a Lua literal."
TOOL_CODE_SCHEMA :: `{"type":"object","properties":{"code":{"type":"string","description":"Lua 5.4 source code to execute."}},"required":["code"],"additionalProperties":false}`
TOOL_CODE_FIELDS :: []string{"code"}

// CODE_MODE_MAX_CALL_SUMMARIES bounds how many child summaries a result carries. The
// count is reported separately, so a truncated list still says how much a script did.
CODE_MODE_MAX_CALL_SUMMARIES :: 32

// Code_Mode_Diagnostic is why an execution did not finish. It is a closed vocabulary
// that lives inside the ordinary result, not a second stored outcome: the
// outer Tool_Outcome still says whether anything ran.
Code_Mode_Diagnostic :: enum {
	// None is the zero value: an execution that finished without a fault.
	None,
	Syntax_Error,
	Runtime_Error,
	Invalid_Value,
	Out_Of_Memory,
	Output_Limit,
	Cancelled,
	Unavailable,
}

@(private)
code_mode_diagnostic_names := [Code_Mode_Diagnostic]string {
	.None          = "",
	.Syntax_Error  = "syntax_error",
	.Runtime_Error = "runtime_error",
	.Invalid_Value = "invalid_value",
	.Out_Of_Memory = "out_of_memory",
	.Output_Limit  = "output_limit",
	.Cancelled     = "cancelled",
	.Unavailable   = "unavailable",
}

code_mode_diagnostic_name :: proc(diagnostic: Code_Mode_Diagnostic) -> string {
	return code_mode_diagnostic_names[diagnostic]
}

// code_mode_failure builds a Code Mode failure result. The outcome says what the
// harness observed; the diagnostic says which limit or fault Code Mode hit.
code_mode_failure :: proc(ctx: ^Tool_Context, outcome: session.Tool_Outcome, diagnostic: Code_Mode_Diagnostic, message: string, reason := "") -> Tool_Result {
	return tool_result_of(ctx, outcome, message, Code_Output{failure = code_mode_diagnostic_name(diagnostic)}, reason)
}

TOOL_CODE_DEFINITION :: Tool_Definition {
	name = TOOL_CODE_NAME,
	description = TOOL_CODE_DESCRIPTION,
	input_schema = TOOL_CODE_SCHEMA,
	hints = {read_only = .No, destructive = .No, idempotent = .Unknown, open_world = .Unknown},
	placement = .Lua,
	// Lua jobs are driven by the owner through the job table. The procedure is a
	// registry invariant and a defensive fallback, not their execution path.
	kind = .Code,
	execute = tool_code_unreachable,
}

@(private)
tool_code_unreachable :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	return code_mode_failure(ctx, .Tool_Failed, .Unavailable, "the Code Mode executor was not available", "executor unavailable")
}
