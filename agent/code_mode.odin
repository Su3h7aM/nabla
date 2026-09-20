package agent

import "core:encoding/json"

TOOL_CODE_NAME :: "builtin_code"
TOOL_CODE_DESCRIPTION :: "Execute bounded Lua 5.4 code. Call an available tool through the tools table by its name, for example tools.builtin_read({path = 'README.md'}). Each call suspends the script until the tool finishes and returns its complete JSON result envelope as a Lua table. Use json.null for JSON null, because Lua nil means absence."
TOOL_CODE_SCHEMA :: `{"type":"object","properties":{"code":{"type":"string","description":"Lua 5.4 source code to execute."}},"required":["code"],"additionalProperties":false}`

Code_Mode_Result_Data :: struct {
	output: string `json:"output"`,
	logs:   string `json:"logs"`,
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
	return tool_result_failure(ctx, .Tool_Failed, "the Code Mode executor was not available", "executor unavailable")
}
