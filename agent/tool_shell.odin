package agent

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import linux "core:sys/linux"
import "core:time"
import "core:unicode/utf8"

import "nabla:agent/session"

TOOL_SHELL_NAME :: "builtin.shell"

TOOL_SHELL_DESCRIPTION :: "Execute a command with /bin/sh in a fresh non-interactive process. Standard input is closed. Commands may use shell syntax. Directory and environment changes do not persist between calls. Returns bounded stdout and stderr, exit information, and truncation status. This is not a terminal or background-job service."

TOOL_SHELL_SCHEMA :: `{"type":"object","properties":{"command":{"type":"string","description":"Shell source to execute."},"working_directory":{"type":["string","null"],"description":"Directory in which to run the command. Relative paths start at the session workspace. Leave out or pass null for the workspace itself."},"timeout_ms":{"type":["integer","null"],"description":"Positive timeout in milliseconds. Leave out or pass null for the harness default."}},"required":["command"],"additionalProperties":false}`

TOOL_SHELL_FIELDS :: []string{"command", "working_directory", "timeout_ms"}

// TOOL_SHELL_DEFAULT_TIMEOUT and TOOL_SHELL_MAX_TIMEOUT are the tool's own
// policy, stated as durations. The definition below is the source of truth:
// argument parsing derives its millisecond bounds from it, so the JSON
// boundary is the only place milliseconds appear.
TOOL_SHELL_DEFAULT_TIMEOUT :: 30 * time.Second
TOOL_SHELL_MAX_TIMEOUT :: 120 * time.Second

// TOOL_SHELL_NOT_STARTED is the one thing a failed spawn can say. A pipe that
// could not be created, a fork that failed, and an exec that never reached the
// shell all look the same from here, and the harness will not invent a cause.
TOOL_SHELL_NOT_STARTED :: "the command did not start or its output was lost"

TOOL_MAX_STDOUT_BYTES :: 24 * 1024
TOOL_MAX_STDERR_BYTES :: 24 * 1024

// Both excerpts plus the JSON envelope must fit the result budget together.
#assert(TOOL_MAX_STDOUT_BYTES + TOOL_MAX_STDERR_BYTES < TOOL_MAX_RESULT_BYTES)

// Shell_Data is what a command produced. exit_code is present only when the
// command exited rather than being ended by a signal.
Shell_Data :: struct {
	stdout:            string `json:"stdout"`,
	stderr:            string `json:"stderr"`,
	exit_code:         Maybe(int) `json:"exit_code"`,
	stdout_truncated:  bool `json:"stdout_truncated"`,
	stderr_truncated:  bool `json:"stderr_truncated"`,
	output_incomplete: bool `json:"output_incomplete"`,
}

TOOL_SHELL_DEFINITION :: Tool_Definition {
	name = TOOL_SHELL_NAME,
	description = TOOL_SHELL_DESCRIPTION,
	input_schema = TOOL_SHELL_SCHEMA,
	// The command determines the behavior, so unknown is the only honest
	// static answer for everything but the open world it can reach.
	hints = {read_only = .Unknown, destructive = .Unknown, idempotent = .Unknown, open_world = .Yes},
	timeouts = {default = TOOL_SHELL_DEFAULT_TIMEOUT, maximum = TOOL_SHELL_MAX_TIMEOUT},
	execute = tool_shell_execute,
}

// Tool_Shell_Args is the shell's own view of a call. Its strings borrow the
// argument document, so they live only as long as that document does.
Tool_Shell_Args :: struct {
	command:           string,
	working_directory: string, // "" means the workspace root
	timeout_ms:        int,
}

// tool_shell_args reads the shell's arguments and reports the first defect
// instead of a value, so a refused call is described exactly. The timeout
// bounds come from the tool definition: a model-requested timeout above the
// maximum is refused, never silently clamped.
tool_shell_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (Tool_Shell_Args, Tool_Argument_Error) {
	if known_error := tool_fields_known(arguments, TOOL_SHELL_FIELDS, allocator = ctx.allocator); known_error.kind != .None { return {}, known_error }
	command, command_error := tool_field_string(arguments, "command", allocator = ctx.allocator)
	if command_error.kind != .None { return {}, command_error }
	if strings.trim_space(command) == "" {
		return {}, tool_argument_error(.Invalid_Value, "command", "a non-empty shell command", ctx.allocator)
	}
	working_directory, directory_error := tool_field_optional_string(arguments, "working_directory", allocator = ctx.allocator)
	if directory_error.kind != .None { return {}, directory_error }
	if strings.contains_rune(working_directory, 0) {
		return {}, tool_argument_error(.Invalid_Value, "working_directory", "a path without a NUL byte", ctx.allocator)
	}
	timeout_ms, timeout_error := tool_field_optional_int(
		arguments,
		"timeout_ms",
		int(TOOL_SHELL_DEFINITION.timeouts.default / time.Millisecond),
		1,
		int(TOOL_SHELL_DEFINITION.timeouts.maximum / time.Millisecond),
		allocator = ctx.allocator,
	)
	if timeout_error.kind != .None { return {}, timeout_error }
	return Tool_Shell_Args{command = command, working_directory = working_directory, timeout_ms = timeout_ms}, {}
}

tool_shell_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	args, args_error := tool_shell_args(ctx, arguments)
	defer if args_error.kind != .None { tool_argument_error_destroy(&args_error, ctx.allocator) }
	if args_error.kind != .None { return tool_result_refused(ctx, &args_error) }

	directory, resolve_error := tool_resolve_path(ctx.workspace, args.working_directory, "working_directory", ctx.allocator)
	if resolve_error.kind != .None { return tool_result_refused(ctx, &resolve_error) }
	defer delete(directory, ctx.allocator)
	info, info_error := os.stat(directory, ctx.allocator)
	defer os.file_info_delete(info, ctx.allocator)
	if info_error != nil || info.type != .Directory {
		missing := tool_argument_error(.Invalid_Value, "working_directory", "a directory that exists", ctx.allocator)
		return tool_result_refused(ctx, &missing)
	}

	data: Shell_Data
	defer {
		delete(data.stdout, ctx.allocator)
		delete(data.stderr, ctx.allocator)
	}

	stdout_pipe, stderr_pipe: [2]linux.Fd
	if linux.pipe2(&stdout_pipe, {.CLOEXEC}) != .NONE {
		return tool_shell_finish(ctx, .Tool_Failed, TOOL_SHELL_NOT_STARTED, data)
	}
	if linux.pipe2(&stderr_pipe, {.CLOEXEC}) != .NONE {
		_ = linux.close(stdout_pipe[0])
		_ = linux.close(stdout_pipe[1])
		return tool_shell_finish(ctx, .Tool_Failed, TOOL_SHELL_NOT_STARTED, data)
	}
	pid, spawned := tool_spawn_grouped(args.command, directory, stdout_pipe[1], stderr_pipe[1])
	_ = linux.close(stdout_pipe[1])
	_ = linux.close(stderr_pipe[1])
	if !spawned {
		_ = linux.close(stdout_pipe[0])
		_ = linux.close(stderr_pipe[0])
		return tool_shell_finish(ctx, .Tool_Failed, TOOL_SHELL_NOT_STARTED, data)
	}

	child := Tool_Child {
		pid = pid,
	}
	// The requested timeout is clamped to the definition maximum, so no call
	// outlives the tool's own policy. The turn control stays separate from the
	// tool budget: cancellation reports Cancelled, while
	// only the budget expiring reports Timed_Out.
	start := time.tick_now()
	budget := tool_timeout_clamp(time.Duration(args.timeout_ms) * time.Millisecond, TOOL_SHELL_DEFINITION.timeouts.maximum)
	stop := tool_drain_pipes(&child, stdout_pipe[0], stderr_pipe[0], start, budget, ctx.control, &data, ctx.allocator)
	_ = linux.close(stdout_pipe[0])
	_ = linux.close(stderr_pipe[0])
	switch stop {
	case .Cancelled:
		return tool_shell_finish(ctx, .Cancelled, "the command was cancelled", data, "cancelled")
	case .Timed_Out:
		return tool_shell_finish(ctx, .Timed_Out, "the command exceeded its timeout", data, "timed out")
	case .None:
	}

	exited, exit_code, waited := tool_child_reap(&child)
	if !waited {
		return tool_shell_finish(ctx, .Unknown, "the command ran, but its exit status could not be read", data, "exit unknown")
	}
	if !exited {
		return tool_shell_finish(ctx, .Tool_Failed, "the command was ended by a signal", data, "signalled")
	}
	data.exit_code = exit_code
	if exit_code != 0 {
		return tool_shell_finish(ctx, .Tool_Failed, fmt.tprintf("the command exited with status %d", exit_code), data, fmt.tprintf("exited %d", exit_code))
	}
	return tool_shell_finish(ctx, .Success, "", data, "exited 0")
}

// tool_shell_finish bounds the captured streams to valid UTF-8 inside the model
// result budget and builds the envelope.
tool_shell_finish :: proc(ctx: ^Tool_Context, outcome: session.Tool_Outcome, message: string, captured: Shell_Data, reason := "") -> Tool_Result {
	data := captured
	stdout_sanitized, stdout_cut := tool_sanitize_stream(data.stdout, TOOL_MAX_STDOUT_BYTES, ctx.allocator)
	defer delete(stdout_sanitized, ctx.allocator)
	stderr_sanitized, stderr_cut := tool_sanitize_stream(data.stderr, TOOL_MAX_STDERR_BYTES, ctx.allocator)
	defer delete(stderr_sanitized, ctx.allocator)
	data.stdout = stdout_sanitized
	data.stderr = stderr_sanitized
	data.stdout_truncated = data.stdout_truncated || stdout_cut
	data.stderr_truncated = data.stderr_truncated || stderr_cut

	result := tool_result_of(ctx, outcome, message, data, reason)
	for len(result.content) > TOOL_MAX_RESULT_BYTES {
		delete(result.content, ctx.allocator)
		if len(data.stdout) == 0 && len(data.stderr) == 0 {
			data.output_incomplete = true
			result.content = tool_content_json(outcome, "the result did not fit the harness budget", data, ctx.allocator)
			break
		}
		if len(data.stdout) >= len(data.stderr) {
			data.stdout = tool_truncate_runes(data.stdout, len(data.stdout) / 2)
			data.stdout_truncated = true
		} else {
			data.stderr = tool_truncate_runes(data.stderr, len(data.stderr) / 2)
			data.stderr_truncated = true
		}
		data.output_incomplete = true
		result.content = tool_content_json(outcome, message, data, ctx.allocator)
	}
	return result
}

// tool_truncate_runes returns the longest prefix of s that is at most limit
// bytes and ends on a rune boundary. s must already be valid UTF-8.
@(private)
tool_truncate_runes :: proc(s: string, limit: int) -> string {
	if limit >= len(s) { return s }
	end := limit
	for end > 0 && s[end] & 0xC0 == 0x80 { end -= 1 }
	return s[:end]
}

// tool_sanitize_stream caps a captured stream, ends it on a rune boundary, and
// replaces bytes that would make the result invalid text. A tool result is read
// by a model, so invalid UTF-8 and control bytes become the replacement
// character instead of reaching the provider.
tool_sanitize_stream :: proc(raw: string, limit: int, allocator := context.allocator) -> (string, bool) {
	truncated := len(raw) > limit
	end := len(raw)
	if end > limit { end = limit }
	for end > 0 {
		_, width := utf8.decode_last_rune_in_string(raw[:end])
		if width > 0 { break }
		end -= 1
	}
	valid, _ := strings.to_valid_utf8(raw[:end], "\ufffd", allocator)
	defer delete(valid, allocator)
	builder := strings.builder_make(allocator)
	for r in valid {
		if r == utf8.RUNE_ERROR {
			strings.write_rune(&builder, utf8.RUNE_ERROR)
		} else if r < 0x20 && r != '\n' && r != '\t' || r == 0x7F {
			strings.write_rune(&builder, utf8.RUNE_ERROR)
		} else {
			strings.write_rune(&builder, r)
		}
	}
	return strings.to_string(builder), truncated
}

tool_resolve_path :: proc(workspace, path: string, field := "path", allocator := context.allocator) -> (string, Tool_Argument_Error) {
	if strings.contains_rune(path, 0) {
		return "", tool_argument_error(.Invalid_Value, field, "a path without a NUL byte", allocator)
	}
	if path != "" && path[0] == '/' { return strings.clone(path, allocator), {} }
	joined, join_error := os.join_path([]string{workspace, path}, allocator)
	if join_error != nil {
		return "", tool_argument_error(.Invalid_Value, field, "a valid path", allocator)
	}
	return joined, {}
}
