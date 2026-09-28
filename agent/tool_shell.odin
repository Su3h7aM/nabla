package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "nabla:agent/journal"

TOOL_SHELL_NAME :: "builtin_shell"

// TOOL_SHELL_BODY is what the shell tool does, after the sentence that names the
// shell it does it with.
TOOL_SHELL_BODY :: "Write the command in that shell's own syntax, which may not be POSIX sh. The command runs in a fresh non-interactive process with standard input closed, and it inherits this process's environment. Directory and environment changes do not persist between calls. Returns bounded stdout and stderr, exit information, and truncation status. This is not a terminal or background-job service."

// TOOL_SHELL_FALLBACK is the shell a command ends at when the shell this process
// was started from cannot run it. /bin/sh is the one shell a POSIX system has.
TOOL_SHELL_FALLBACK :: "/bin/sh"

// tool_shell_preferred returns the shell to run a command with: the one SHELL
// names, or the portable fallback when the environment names none. "" is not a
// shell, so it never reaches an exec.
tool_shell_preferred :: proc() -> string {
	shell, found := os.lookup_env("SHELL", context.temp_allocator)
	if !found || shell == "" { return TOOL_SHELL_FALLBACK }
	return shell
}

TOOL_SHELL_SCHEMA :: `{"type":"object","properties":{"command":{"type":"string","description":"Shell source to execute."},"working_directory":{"type":["string","null"],"description":"Directory in which to run the command. Relative paths start at the session workspace. Leave out or pass null for the workspace itself."},"timeout_ms":{"type":["integer","null"],"description":"Positive timeout in milliseconds. Leave out or pass null for the harness default."}},"required":["command"],"additionalProperties":false}`

TOOL_SHELL_FIELDS :: []string{"command", "working_directory", "timeout_ms"}

// TOOL_SHELL_DEFAULT_TIMEOUT applies when the model gives no timeout. There is no maximum.
TOOL_SHELL_DEFAULT_TIMEOUT :: 120 * time.Second

// tool_shell_definition is the shell tool, described for the shell this process
// will run: the shell decides the syntax the model has to write, and the tool does
// not translate between shells. The caller owns the description it returns and
// frees it once the registry has cloned it.
@(require_results)
tool_shell_definition :: proc(shell: string, allocator := context.allocator) -> Tool_Definition {
	return Tool_Definition {
		name = TOOL_SHELL_NAME,
		description = fmt.aprintf("Execute a command with %s (%s). " + TOOL_SHELL_BODY, os.base(shell), shell, allocator = allocator),
		input_schema = TOOL_SHELL_SCHEMA,
		// The command determines the behavior, so unknown is the only honest
		// static answer for everything but the open world it can reach.
		hints = {read_only = .Unknown, destructive = .Unknown, idempotent = .Unknown, open_world = .Yes},
		timeout = TOOL_SHELL_DEFAULT_TIMEOUT,
		kind = .Shell,
		execute = tool_shell_execute,
	}
}

// tool_shell_args reads the shell's arguments and reports the first defect
// instead of a value, so a refused call is described exactly. A timeout the
// model gives is honored as given; otherwise the definition's default applies.
tool_shell_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Shell_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_SHELL_FIELDS, allocator = ctx.allocator) or_return
	command := tool_field_string(arguments, "command", allocator = ctx.allocator) or_return
	if strings.trim_space(command) == "" {
		return {}, tool_argument_error(.Invalid_Value, "command", "a non-empty shell command", ctx.allocator)
	}
	working_directory := tool_field_optional_string(arguments, "working_directory", allocator = ctx.allocator) or_return
	if strings.contains_rune(working_directory, 0) {
		return {}, tool_argument_error(.Invalid_Value, "working_directory", "a path without a NUL byte", ctx.allocator)
	}
	timeout_ms := tool_field_optional_int(
		arguments,
		"timeout_ms",
		int(ctx.timeout / time.Millisecond),
		1,
		int(max(time.Duration) / time.Millisecond),
		&ctx.repairs,
		allocator = ctx.allocator,
	) or_return
	return {command = command, working_directory = working_directory, timeout = time.Duration(timeout_ms) * time.Millisecond}, nil
}

// tool_shell_start runs a command with the shell this process was started from,
// and with the portable shell when that shell cannot be started. Only a command
// that never started is tried twice: a shell that ran it has already had its
// effects, and running it again would repeat them.
tool_shell_start :: proc(command, directory: string, stdout_write, stderr_write: ^os.File) -> (child: Tool_Child, spawn: Tool_Spawn, err: os.Error) {
	shell := tool_shell_preferred()
	child, spawn, err = tool_spawn_grouped(shell, command, directory, stdout_write, stderr_write)
	if spawn != .Exec_Failed || shell == TOOL_SHELL_FALLBACK { return }
	return tool_spawn_grouped(TOOL_SHELL_FALLBACK, command, directory, stdout_write, stderr_write)
}

tool_shell_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Shell_Args)

	directory, resolve_error := tool_resolve_path(ctx.workspace, args.working_directory, "working_directory", ctx.allocator)
	if resolve_error != nil { return tool_result_refused(ctx, &resolve_error) }
	defer delete(directory, ctx.allocator)
	info, info_error := os.stat(directory, ctx.allocator)
	defer os.file_info_delete(info, ctx.allocator)
	if info_error != nil || info.type != .Directory {
		missing := tool_argument_error(.Invalid_Value, "working_directory", "a directory that exists", ctx.allocator)
		return tool_result_refused(ctx, &missing)
	}

	data: Shell_Output
	defer {
		delete(data.stdout, ctx.allocator)
		delete(data.stderr, ctx.allocator)
		delete(data.stdout_file, ctx.allocator)
		delete(data.stderr_file, ctx.allocator)
	}

	stdout_read, stdout_write, stdout_error := os.pipe()
	if stdout_error != nil { return tool_shell_not_started(ctx, stdout_error, data) }
	// The drain reports its own failure; closing the read ends it in every case.
	defer _ = os.close(stdout_read)
	stderr_read, stderr_write, stderr_error := os.pipe()
	if stderr_error != nil {
		_ = os.close(stdout_write)
		return tool_shell_not_started(ctx, stderr_error, data)
	}
	defer _ = os.close(stderr_read)
	child, spawn, spawn_error := tool_shell_start(args.command, directory, stdout_write, stderr_write)
	_ = os.close(stdout_write)
	_ = os.close(stderr_write)
	if spawn != .Started { return tool_shell_not_started(ctx, spawn_error, data) }
	defer tool_child_close(&child)

	stop, wait_error := tool_drain_pipes(&child, stdout_read, stderr_read, time.tick_now(), args.timeout, ctx.control, &data, ctx.output_base, ctx.allocator)
	switch stop {
	case .Wait_Failed:
		message := fmt.tprintf("the harness could not wait for the command, so it was stopped: %s", os.error_string(wait_error))
		return tool_shell_finish(ctx, .Tool_Failed, message, data, "wait failed")
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

// tool_shell_not_started reports a command that did not start, naming the
// system's reason.
tool_shell_not_started :: proc(ctx: ^Tool_Context, cause: os.Error, data: Shell_Output) -> Tool_Result {
	return tool_shell_finish(ctx, .Tool_Failed, fmt.tprintf("the command did not start: %s", os.error_string(cause)), data)
}

// tool_shell_finish sanitizes the captured streams to valid UTF-8 and builds the result. A
// stream that could not be prepared is reported rather than shown empty.
tool_shell_finish :: proc(ctx: ^Tool_Context, outcome: journal.Tool_Outcome, message: string, captured: Shell_Output, reason := "") -> Tool_Result {
	data := captured
	stdout_sanitized, stdout_error := tool_sanitize_stream(data.stdout, ctx.allocator)
	defer delete(stdout_sanitized, ctx.allocator)
	stderr_sanitized, stderr_error := tool_sanitize_stream(data.stderr, ctx.allocator)
	defer delete(stderr_sanitized, ctx.allocator)
	data.stdout = stdout_sanitized
	data.stderr = stderr_sanitized
	if stdout_error != nil || stderr_error != nil {
		// What the command wrote is lost, so the call says so instead of reading as a command
		// that printed nothing.
		return tool_result_of(ctx, .Tool_Failed, "the command's output could not be prepared: out of memory", data, "out of memory")
	}
	return tool_result_of(ctx, outcome, message, data, reason)
}

// tool_sanitize_stream returns raw with every byte that would make a result invalid text
// replaced by the replacement character: a result is read by a model, so invalid UTF-8 and
// control bytes never reach the provider. The text is owned by allocator.
tool_sanitize_stream :: proc(raw: string, allocator := context.allocator) -> (text: string, err: mem.Allocator_Error) {
	valid, valid_error := strings.to_valid_utf8(raw, "\ufffd", allocator)
	if valid_error != nil { return "", valid_error }
	defer delete(valid, allocator)
	builder := strings.builder_make(allocator) or_return
	defer if err != nil { strings.builder_destroy(&builder) }
	for r in valid {
		breaks := r == utf8.RUNE_ERROR || r < 0x20 && r != '\n' && r != '\t' || r == 0x7F
		character := utf8.RUNE_ERROR if breaks else r
		written, write_error := strings.write_rune(&builder, character)
		if write_error != nil || written != utf8.rune_size(character) { return "", .Out_Of_Memory }
	}
	return strings.to_string(builder), nil
}

tool_resolve_path :: proc(workspace, path: string, field := "path", allocator := context.allocator) -> (string, Tool_Argument_Error) {
	if strings.contains_rune(path, 0) {
		return "", tool_argument_error(.Invalid_Value, field, "a path without a NUL byte", allocator)
	}
	if path != "" && path[0] == '/' { return strings.clone(path, allocator), nil }
	joined, join_error := os.join_path([]string{workspace, path}, allocator)
	if join_error != nil {
		return "", tool_argument_error(.Invalid_Value, field, "a valid path", allocator)
	}
	return joined, nil
}
