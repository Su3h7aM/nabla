package agent

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"
import "nabla:http/client"
import "nabla:web"

// Web_Failure_Text is how one failure kind reads to the model: what happened, and what it can
// do next. Neither names a provider; endpoint details stay in the result's reason.
@(private)
Web_Failure_Text :: struct {
	cause:  string,
	advice: string,
}

@(private)
TOOL_WEB_FAILURE_TEXT := [web.Error_Kind]Web_Failure_Text {
	.None                = {},
	.Missing_Credential  = {"no usable service is configured", "tell the user, or use another tool"},
	.Unauthorized        = {"access denied", "retrying will not help; try another source"},
	.Quota               = {"quota exhausted", "retrying soon will not help; try another source"},
	.Rate_Limited        = {"rate limited", "retry later"},
	.Rejected            = {"request rejected", "check the arguments; the same request will be rejected again"},
	.Server              = {"server error", "retry later, or try another source"},
	.Transport           = {"connection failed", "check the address, then retry"},
	.Timed_Out           = {"timed out", "raise timeout_ms to allow more time"},
	.Cancelled           = {"cancelled", ""},
	.Invalid_Response    = {"invalid response", "retrying will not help; try another source"},
	.Unsupported_Content = {"the content cannot be converted to text", "try another source"},
	.Challenged          = {"blocked by a bot challenge", "the site requires a browser; try another source"},
	.Out_Of_Memory       = {"out of memory", ""},
}

// tool_web_failure_cause names what happened in a failure, with its HTTP status when one was
// received. The result is in temp memory.
@(private)
tool_web_failure_cause :: proc(failure: web.Error) -> string {
	cause := TOOL_WEB_FAILURE_TEXT[failure.kind].cause
	if failure.kind == .Rejected && (failure.status == 404 || failure.status == 410) { cause = "not found" }
	if failure.status > 0 { return fmt.tprintf("%s (HTTP %d)", cause, failure.status) }
	return cause
}

// tool_web_failure_message is the model's text for a failed tool: the cause, the detail
// when with_detail is set, and the advice. A search leaves the detail out because it names
// an endpoint. The result is in temp memory.
@(private)
tool_web_failure_message :: proc(tool: string, failure: web.Error, with_detail: bool) -> string {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, "%s failed: %s", tool, tool_web_failure_cause(failure))
	if with_detail && failure.detail != "" { fmt.sbprintf(&builder, ": %s", failure.detail) }
	if failure.retry_after > 0 { fmt.sbprintf(&builder, " (retry after %v)", failure.retry_after) }
	advice := TOOL_WEB_FAILURE_TEXT[failure.kind].advice
	if failure.kind == .Rejected && (failure.status == 404 || failure.status == 410) { advice = "check the URL, or search for its current address" }
	if advice != "" { fmt.sbprintf(&builder, "; %s", advice) }
	return strings.to_string(builder)
}

// tool_web_failure_result answers a failed web tool. A timeout and a cancellation keep their
// own outcomes so the loop treats them as such.
@(private, require_results)
tool_web_failure_result :: proc(ctx: ^Tool_Context, tool: string, failure: web.Error, with_detail: bool, reason: string) -> Tool_Result {
	outcome := journal.Tool_Outcome.Tool_Failed
	#partial switch failure.kind {
	case .Timed_Out:
		outcome = .Timed_Out
	case .Cancelled:
		outcome = .Cancelled
	}
	return tool_result_failure(ctx, outcome, tool_web_failure_message(tool, failure, with_detail), reason)
}

@(private)
tool_web_control :: proc(control: Tool_Control, timeout: time.Duration) -> ai.HTTP_Control {
	result := ai.HTTP_Control {
		interrupt = control.interrupt,
	}
	if timeout > 0 { result.deadline = ai.deadline_in(timeout) }
	return result
}

@(private, require_results)
tool_web_timeout :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (timeout: time.Duration, err: Tool_Argument_Error) {
	timeout_ms := tool_field_optional_int(
		arguments,
		"timeout_ms",
		int(ctx.timeout / time.Millisecond),
		1,
		int(max(time.Duration) / time.Millisecond),
		&ctx.repairs,
		allocator = ctx.allocator,
	) or_return
	return time.Duration(timeout_ms) * time.Millisecond, nil
}

// tool_web_options borrows control for the whole HTTP operation.
@(private)
tool_web_options :: proc(control: ^ai.HTTP_Control) -> client.Options {
	return {probe = {check = ai.http_probe, user_data = control}}
}
