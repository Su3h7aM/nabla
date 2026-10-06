package agent

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

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

TOOL_SHELL_BACKGROUND_NOTICE :: "background processes left in the command's process group were terminated; start a long-running process with setsid to keep it"

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
@(require_results)
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
@(require_results)
tool_shell_start :: proc(command, directory: string, stdout_write, stderr_write: ^os.File) -> (child: Tool_Child, spawn: Tool_Spawn, err: os.Error) {
	shell := tool_shell_preferred()
	child, spawn, err = tool_spawn_grouped(shell, command, directory, stdout_write, stderr_write)
	if spawn != .Exec_Failed || shell == TOOL_SHELL_FALLBACK { return }
	return tool_spawn_grouped(TOOL_SHELL_FALLBACK, command, directory, stdout_write, stderr_write)
}

@(require_results)
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

	stop, wait_error, background_terminated := tool_drain_pipes(
		&child,
		stdout_read,
		stderr_read,
		time.tick_now(),
		args.timeout,
		ctx.control,
		&data,
		ctx.output_base,
		ctx.allocator,
	)
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
		message := "the command ran, but its exit status could not be read"
		if background_terminated { message = fmt.tprintf("%s. %s", message, TOOL_SHELL_BACKGROUND_NOTICE) }
		return tool_shell_finish(ctx, .Unknown, message, data, "exit unknown")
	}
	if !exited {
		message := "the command was ended by a signal"
		if background_terminated { message = fmt.tprintf("%s. %s", message, TOOL_SHELL_BACKGROUND_NOTICE) }
		return tool_shell_finish(ctx, .Tool_Failed, message, data, "signalled")
	}
	data.exit_code = exit_code
	if exit_code != 0 {
		message := fmt.tprintf("the command exited with status %d", exit_code)
		if background_terminated { message = fmt.tprintf("%s. %s", message, TOOL_SHELL_BACKGROUND_NOTICE) }
		return tool_shell_finish(ctx, .Tool_Failed, message, data, fmt.tprintf("exited %d", exit_code))
	}
	message := ""
	if background_terminated { message = TOOL_SHELL_BACKGROUND_NOTICE }
	return tool_shell_finish(ctx, .Success, message, data, "exited 0")
}

// tool_shell_not_started reports a command that did not start, naming the
// system's reason.
@(require_results)
tool_shell_not_started :: proc(ctx: ^Tool_Context, cause: os.Error, data: Shell_Output) -> Tool_Result {
	return tool_shell_finish(ctx, .Tool_Failed, fmt.tprintf("the command did not start: %s", os.error_string(cause)), data)
}

// tool_shell_finish builds a result from the sanitized streams captured by the drain.
@(require_results)
tool_shell_finish :: proc(ctx: ^Tool_Context, outcome: journal.Tool_Outcome, message: string, captured: Shell_Output, reason := "") -> Tool_Result {
	return tool_result_of(ctx, outcome, message, captured, reason)
}

@(require_results)
tool_resolve_path :: proc(workspace, path: string, field := "path", allocator := context.allocator) -> (string, Tool_Argument_Error) {
	if strings.contains_rune(path, 0) {
		return "", tool_argument_error(.Invalid_Value, field, "a path without a NUL byte", allocator)
	}
	if path != "" && path[0] == '/' {
		absolute, clone_error := strings.clone(path, allocator)
		if clone_error != nil { return "", tool_argument_error(.Out_Of_Memory) }
		return absolute, nil
	}
	joined, join_error := os.join_path([]string{workspace, path}, allocator)
	if join_error != nil { return "", tool_argument_error(.Out_Of_Memory) }
	return joined, nil
}
