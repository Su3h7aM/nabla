package agent

import "core:encoding/json"

import "nabla:agent/session"

TOOL_CODE_NAME :: "builtin_code"
TOOL_CODE_DESCRIPTION :: "Execute bounded Lua 5.4 code. Call an available tool through the tools table by its name, for example tools.builtin_read({path = 'README.md'}). Each call suspends the script until the tool finishes and returns its complete JSON result envelope as a Lua table. Use json.null for JSON null, because Lua nil means absence. The chunk returns at most one value, which becomes the data field of this result."
TOOL_CODE_SCHEMA :: `{"type":"object","properties":{"code":{"type":"string","description":"Lua 5.4 source code to execute."}},"required":["code"],"additionalProperties":false}`

// Code_Mode_Result_Data is the data of an execution that finished. output is the
// chunk's return value as JSON, so a script may answer with an object or an array as
// easily as with a string. logs is what print produced, bounded by the Lua boundary.
Code_Mode_Result_Data :: struct {
	output:         json.Value `json:"output"`,
	logs:           string `json:"logs"`,
	logs_truncated: bool `json:"logs_truncated,omitempty"`,
}

// Code_Mode_Error_Data is the data of an execution that failed. kind names why, so a
// caller can branch on the failure instead of reading prose.
Code_Mode_Error_Data :: struct {
	kind: string `json:"kind"`,
}

// Code_Mode_Diagnostic is why an execution did not finish. It is a closed vocabulary
// that lives inside the ordinary result envelope, not a second stored outcome: the
// outer Tool_Outcome still says whether anything ran.
Code_Mode_Diagnostic :: enum {
	Syntax_Error,
	Runtime_Error,
	Invalid_Value,
	Memory_Limit,
	Instruction_Limit,
	Tool_Call_Limit,
	Output_Limit,
	Cancelled,
	Deadline,
	Unavailable,
}

@(private)
code_mode_diagnostic_names := [Code_Mode_Diagnostic]string {
	.Syntax_Error      = "syntax_error",
	.Runtime_Error     = "runtime_error",
	.Invalid_Value     = "invalid_value",
	.Memory_Limit      = "memory_limit",
	.Instruction_Limit = "instruction_limit",
	.Tool_Call_Limit   = "tool_call_limit",
	.Output_Limit      = "output_limit",
	.Cancelled         = "cancelled",
	.Deadline          = "deadline",
	.Unavailable       = "unavailable",
}

code_mode_diagnostic_name :: proc(diagnostic: Code_Mode_Diagnostic) -> string {
	return code_mode_diagnostic_names[diagnostic]
}

// code_mode_failure builds a Code Mode failure envelope. The outcome says what the
// harness observed; the diagnostic says which limit or fault Code Mode hit.
code_mode_failure :: proc(ctx: ^Tool_Context, outcome: session.Tool_Outcome, diagnostic: Code_Mode_Diagnostic, message: string, reason := "") -> Tool_Result {
	return tool_result_of(ctx, outcome, message, Code_Mode_Error_Data{kind = code_mode_diagnostic_name(diagnostic)}, reason)
}

TOOL_CODE_DEFINITION :: Tool_Definition {
	name = TOOL_CODE_NAME,
	description = TOOL_CODE_DESCRIPTION,
	input_schema = TOOL_CODE_SCHEMA,
	hints = {read_only = .No, destructive = .No, idempotent = .Unknown, open_world = .Unknown},
	placement = .Lua,
	// Lua jobs are driven by the owner through the job table. The procedure is a
	// registry invariant and a defensive fallback, not their execution path.
	execute = tool_code_unreachable,
}

@(private)
tool_code_unreachable :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	return code_mode_failure(ctx, .Tool_Failed, .Unavailable, "the Code Mode executor was not available", "executor unavailable")
}
