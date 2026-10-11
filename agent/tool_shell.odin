package agent

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "nabla:subprocess"

TOOL_SHELL_NAME :: "shell"

// TOOL_SHELL_BODY is what the shell tool does, after the sentence that names the shell it
// does it with. It is a format: the preview size in KiB, the in-memory size of one stream in
// MiB, and the default timeout in seconds.
TOOL_SHELL_BODY :: `The shell is the one the SHELL environment variable names, or /bin/sh when it names none or cannot be started. Write the command in that shell's syntax, which may not be POSIX sh. Each call starts a fresh non-interactive process in its own process group, with standard input closed (a command that prompts reads end of file) and this process's environment. Directory changes, variables, and background jobs do not carry over to the next call, so pass working_directory instead of relying on cd. Create or edit files with write or patch, not with a heredoc or echo redirection. This is not a terminal.

The result gives exit_code, then stdout and stderr as separate sections. A nonzero exit is outcome tool_failed and still returns its output. Output is never discarded: the result shows at most %d KiB, and when the command wrote more, the result ends with a notice naming a file that holds the whole result, which you read with read. A stream over %d MiB is written to its own file, named by stdout_complete_in or stderr_complete_in, and the result keeps only its beginning. The timeout is %d seconds for a waiting call and none for a background call unless you set timeout_ms, and there is no maximum; when it passes, the command's process group is terminated. Processes left running in that group when the command ends are terminated too, so start one that must outlive the command with setsid.`

// TOOL_SHELL_FISH_NOTES follows the body when the shell is fish, whose syntax models most
// often get wrong because they write bash.
TOOL_SHELL_FISH_NOTES :: ` Fish differs from bash in ways that fail the whole command: there is no heredoc (<<); loops and conditionals end with end, as in "for name in a b c; echo $name; end" and "if test -f x; echo yes; end", not do/done or fi; variables are set with "set name value" and the last exit status is $status, not $?; command substitution is (cmd); before fish 3.0 there is no && or ||, and "; and" and "; or" take their place; and a wildcard that matches nothing is an error, so quote a glob meant for the program, as in --include='*.odin'.`

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

TOOL_SHELL_SCHEMA ::
	`{"type":"object","properties":{` +
	`"wait":{"type":["boolean","null"],"description":"False runs the command in the background, answers at once with a job id, and delivers the result as a message when it ends. Use it for long work such as builds, test suites, or servers. A background command has no timeout unless you set timeout_ms. Default: true."},"command":{"type":"string","description":"The command, written in the syntax of the shell the tool description names."},"working_directory":{"type":["string","null"],"description":"Directory in which to run the command. Relative paths start at the session workspace. Leave out or pass null for the workspace itself."},"timeout_ms":{"type":["integer","null"],"description":"Positive timeout in milliseconds, with no maximum. Leave out or pass null for the default the tool description states."}},"required":["command"],"additionalProperties":false}`

TOOL_SHELL_FIELDS :: []string{"command", "working_directory", "timeout_ms", "wait"}

// TOOL_SHELL_DEFAULT_TIMEOUT applies when the model gives no timeout. There is no maximum.
TOOL_SHELL_DEFAULT_TIMEOUT :: 120 * time.Second

TOOL_SHELL_BACKGROUND_NOTICE :: "background processes left in the command's process group were terminated; start a long-running process with setsid to keep it"
// TOOL_SHELL_SEARCH_HINT_FORMAT is the note a shell result carries after its stdout and
// stderr sections when its command ran a file-search CLI. It states what ran and softly
// prefers the native tools for file search; the model decides what to call.
TOOL_SHELL_SEARCH_HINT_FORMAT :: "\nhint: this command ran %s; prefer the native find and grep tools for file search (paged results with cursors).\n"

// TOOL_SHELL_SEPARATORS end a command in a command list or a pipeline.
@(private)
TOOL_SHELL_SEPARATORS :: ";&|\n"

// TOOL_SHELL_BLANKS end a word of a command.
@(private)
TOOL_SHELL_BLANKS :: " \t\r"

// tool_shell_search_command names the file-search CLI command runs, so its result can say
// so. It splits command into command lists at `;`, `&&`, `||`, `&`, and newline outside
// quotes, and checks the first command of each pipeline: a grep that filters another
// command's output is no file search. It reports false when no checked command is a
// file-search CLI. It reads only the command text: it never runs, blocks, or fails,
// whatever the command holds.
@(require_results)
tool_shell_search_command :: proc(command: string) -> (name: string, found: bool) {
	position := 0
	pipeline_start := true
	for position < len(command) {
		end := tool_shell_scan(command, position, TOOL_SHELL_SEPARATORS)
		if pipeline_start {
			name, found = tool_shell_search_cli(command[position:end])
			if found { return }
		}
		if end == len(command) { break }
		rest := command[end:]
		width := 1
		switch {
		case strings.has_prefix(rest, "||"):
			width = 2
			pipeline_start = true
		case strings.has_prefix(rest, "|&"):
			width = 2
			pipeline_start = false
		case rest[0] == '|':
			pipeline_start = false
		case:
			pipeline_start = true
		}
		position = end + width
	}
	return "", false
}

// tool_shell_search_cli names the file-search CLI that simple_command runs. It skips
// leading assignments, `(`, `{`, `!`, redirections, and wrapper words with their options,
// then reads the basename of the next word, and git's subcommand after its flags. A wrapper
// option that takes a value is skipped with it for sudo only.
@(private, require_results)
tool_shell_search_cli :: proc(simple_command: string) -> (name: string, found: bool) {
	position := 0
	wrapper := ""
	skip_word := false
	for {
		word, next, ok := tool_shell_next_word(simple_command, position)
		if !ok { return "", false }
		position = next
		word = strings.trim_left(word, "(")
		base := tool_shell_word_base(word)
		redirection := strings.trim_left(word, "0123456789")
		switch {
		case skip_word:
			skip_word = false
		case word == "" || word == "{" || word == "!":
		case strings.contains_rune(word, '='):
		// An assignment before the command, as in `FOO=1 rg ...`.
		case redirection != "" && (redirection[0] == '<' || redirection[0] == '>'):
			// `> file` keeps its target in the next word; `>file` holds it.
			skip_word = strings.trim_left(redirection, "<>") == ""
		case wrapper == "command" && word[0] == '-' && strings.contains_any(word, "vV"):
			// `command -v rg` describes rg and runs nothing.
			return "", false
		case wrapper != "" && word[0] == '-':
			skip_word = wrapper == "sudo" && tool_shell_sudo_flag_takes_value(word)
		case tool_shell_is_wrapper(base):
			wrapper = base
		case base == "git":
			return tool_shell_git_subcommand(simple_command, position)
		case:
			if tool_shell_is_search_cli(base) { return base, true }
			return "", false
		}
	}
}

// tool_shell_git_subcommand reports "git grep" when the subcommand in command, read from
// position after git's flags and their values, is grep.
@(private, require_results)
tool_shell_git_subcommand :: proc(command: string, position: int) -> (name: string, found: bool) {
	index := position
	skip_word := false
	for {
		word, next, ok := tool_shell_next_word(command, index)
		if !ok { return "", false }
		index = next
		switch {
		case skip_word:
			skip_word = false
		case strings.contains_rune(word, '='):
		case word[0] == '-':
			skip_word = tool_shell_git_flag_takes_value(word)
		case:
			if word == "grep" { return "git grep", true }
			return "", false
		}
	}
}

@(private, require_results)
tool_shell_is_search_cli :: proc(name: string) -> bool {
	switch name {
	case "grep", "egrep", "fgrep", "rg", "ag", "ack", "fd", "fdfind", "find", "locate":
		return true
	}
	return false
}

@(private, require_results)
tool_shell_is_wrapper :: proc(name: string) -> bool {
	switch name {
	case "sudo", "env", "command", "time", "nice", "nohup", "exec":
		return true
	}
	return false
}

// tool_shell_sudo_flag_takes_value reports whether the sudo flag takes the next word as its
// value. A `--flag=value` word never reaches here: its assignment is skipped whole.
@(private, require_results)
tool_shell_sudo_flag_takes_value :: proc(flag: string) -> bool {
	switch flag {
	case "-C",
	     "--close-from",
	     "-D",
	     "--chdir",
	     "-g",
	     "--group",
	     "-h",
	     "--host",
	     "-p",
	     "--prompt",
	     "-r",
	     "--role",
	     "-t",
	     "--type",
	     "-U",
	     "--other-user",
	     "-u",
	     "--user":
		return true
	}
	return false
}

// tool_shell_git_flag_takes_value reports whether the git flag takes the next word as its
// value.
@(private, require_results)
tool_shell_git_flag_takes_value :: proc(flag: string) -> bool {
	switch flag {
	case "-C", "-c", "--config-env", "--git-dir", "--namespace", "--super-prefix", "--work-tree":
		return true
	}
	return false
}

// tool_shell_word_base strips one layer of surrounding quotes from a shell word and then
// its directory, so `"rg"`, `'rg'`, and `/usr/bin/rg` all read as `rg`. Interior quotes
// stay, so a word that only quotes part of its text names nothing known.
@(private, require_results)
tool_shell_word_base :: proc(word: string) -> string {
	name := word
	if len(name) >= 2 {
		first, last := name[0], name[len(name) - 1]
		if first == last && (first == '\'' || first == '"') { name = name[1:len(name) - 1] }
	}
	if slash := strings.last_index_byte(name, '/'); slash >= 0 { name = name[slash + 1:] }
	return name
}

// tool_shell_next_word reads the word of text that starts at or after position, skipping
// blanks first. The word borrows text. ok is false when no word follows.
@(private, require_results)
tool_shell_next_word :: proc(text: string, position: int) -> (word: string, next: int, ok: bool) {
	start := len(text) - len(strings.trim_left(text[position:], TOOL_SHELL_BLANKS))
	if start == len(text) { return "", start, false }
	end := tool_shell_scan(text, start, TOOL_SHELL_BLANKS)
	return text[start:end], end, true
}

// tool_shell_scan returns the index of the first byte of text at or after start that is in
// stops and outside quotes, backslash escapes, and comments, or len(text) when there is none.
// Single quotes hold every byte literally; elsewhere a backslash escapes the next byte. A `#`
// that starts a word begins a comment.
@(private, require_results)
tool_shell_scan :: proc(text: string, start: int, stops: string) -> int {
	quote := byte(0)
	index := start
	for index < len(text) {
		c := text[index]
		switch {
		case quote == '\'':
			if c == '\'' { quote = 0 }
		case c == '\\':
			index += 1
		case quote == '"':
			if c == '"' { quote = 0 }
		case c == '\'' || c == '"':
			quote = c
		case c == '#' && (index == 0 || strings.index_byte(" \t\r;&|\n(", text[index - 1]) >= 0):
			// A comment runs to the end of the line; the newline itself is still scanned.
			for index + 1 < len(text) && text[index + 1] != '\n' { index += 1 }
		case strings.index_byte(stops, c) >= 0:
			return index
		}
		index += 1
	}
	return len(text)
}

// tool_shell_search_hint appends the file-search hint for command to result's content,
// after the stdout and stderr sections. The command's own output bytes are untouched, and a
// command that runs no file-search CLI, or a hint that cannot be appended, leaves the
// result as it was: the hint never blocks, fails, or rewrites an execution.
@(require_results)
tool_shell_search_hint :: proc(ctx: ^Tool_Context, result: Tool_Result, command: string) -> Tool_Result {
	name, found := tool_shell_search_command(command)
	if !found { return result }
	result := result
	hint := fmt.tprintf(TOOL_SHELL_SEARCH_HINT_FORMAT, name)
	joined, join_error := strings.concatenate({result.content, hint}, result.allocator)
	if join_error != nil { return result }
	delete(result.content, result.allocator)
	result.content = joined
	return result
}

// tool_shell_description describes the shell tool for shell, which decides the syntax the
// model has to write. The caller owns the text, allocated with allocator.
@(require_results)
tool_shell_description :: proc(shell: string, allocator := context.allocator) -> string {
	notes := TOOL_SHELL_FISH_NOTES if os.base(shell) == "fish" else ""
	return fmt.aprintf(
		"Execute a command with %s (%s). " + TOOL_SHELL_BODY + "%s",
		os.base(shell),
		shell,
		TOOL_RESULT_PREVIEW_BYTES / 1024,
		TOOL_STREAM_MEMORY_BYTES / (1024 * 1024),
		int(TOOL_SHELL_DEFAULT_TIMEOUT / time.Second),
		notes,
		allocator = allocator,
	)
}

// tool_shell_definition is the shell tool, described for the shell this process
// will run: the shell decides the syntax the model has to write, and the tool does
// not translate between shells. The caller owns the description it returns and
// frees it once the registry has cloned it.
@(require_results)
tool_shell_definition :: proc(shell: string, allocator := context.allocator) -> Tool_Definition {
	return Tool_Definition {
		name = TOOL_SHELL_NAME,
		description = tool_shell_description(shell, allocator),
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
	wait := true
	if value, given := arguments["wait"]; given {
		if _, is_null := value.(json.Null); !is_null { wait = tool_field_optional_bool(arguments, "wait", allocator = ctx.allocator) or_return }
	}
	// A background command has no timeout unless the model gives one.
	default_timeout := ctx.timeout if wait else 0
	timeout_ms := tool_field_optional_int(
		arguments,
		"timeout_ms",
		int(default_timeout / time.Millisecond),
		1,
		int(max(time.Duration) / time.Millisecond),
		&ctx.repairs,
		allocator = ctx.allocator,
	) or_return
	return {command = command, working_directory = working_directory, timeout = time.Duration(timeout_ms) * time.Millisecond, wait = wait}, nil
}

// tool_shell_start runs a command with the shell this process was started from,
// and with the portable shell when that shell cannot be started. Only a command
// that never started is tried twice: a shell that ran it has already had its
// effects, and running it again would repeat them.
@(require_results)
tool_shell_start :: proc(
	command, directory: string,
	stdout_write, stderr_write: ^os.File,
) -> (
	child: subprocess.Child,
	spawn: subprocess.Spawn,
	err: os.Error,
) {
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
	defer subprocess.child_close(&child)

	// Only a command that started ran, so only its result can name a file-search CLI.
	result := tool_shell_finish(ctx, &child, stdout_read, stderr_read, args, &data)
	return tool_shell_search_hint(ctx, result, args.command)
}

// tool_shell_finish drains the output of a started command, waits for it, and reports how
// it ended.
@(require_results)
tool_shell_finish :: proc(
	ctx: ^Tool_Context,
	child: ^subprocess.Child,
	stdout_read, stderr_read: ^os.File,
	args: Shell_Args,
	data: ^Shell_Output,
) -> Tool_Result {
	stop, wait_error, background_terminated := tool_drain_pipes(
		child,
		stdout_read,
		stderr_read,
		time.tick_now(),
		args.timeout,
		ctx.control,
		data,
		ctx.output_base,
		ctx.stream,
		ctx.allocator,
	)
	switch stop {
	case .Wait_Failed:
		message := fmt.tprintf("the harness could not wait for the command, so it was stopped: %s", os.error_string(wait_error))
		return tool_result_of(ctx, .Tool_Failed, message, data^, "wait failed")
	case .Cancelled:
		return tool_result_of(ctx, .Cancelled, "the command was cancelled", data^, "cancelled")
	case .Timed_Out:
		return tool_result_of(ctx, .Timed_Out, "the command exceeded its timeout", data^, "timed out")
	case .None:
	}

	exited, exit_code, waited := subprocess.child_reap(child)
	if !waited {
		message := "the command ran, but its exit status could not be read"
		message = tool_shell_background_message(message, background_terminated)
		return tool_result_of(ctx, .Unknown, message, data^, "exit unknown")
	}
	if !exited {
		message := "the command was ended by a signal"
		message = tool_shell_background_message(message, background_terminated)
		return tool_result_of(ctx, .Tool_Failed, message, data^, "signalled")
	}
	data.exit_code = exit_code
	if exit_code != 0 {
		message := fmt.tprintf("the command exited with status %d", exit_code)
		message = tool_shell_background_message(message, background_terminated)
		return tool_result_of(ctx, .Tool_Failed, message, data^, fmt.tprintf("exited %d", exit_code))
	}
	message := ""
	if background_terminated { message = TOOL_SHELL_BACKGROUND_NOTICE }
	return tool_result_of(ctx, .Success, message, data^, "exited 0")
}

// tool_shell_not_started reports a command that did not start, naming the
// system's reason.
@(require_results)
tool_shell_not_started :: proc(ctx: ^Tool_Context, cause: os.Error, data: Shell_Output) -> Tool_Result {
	return tool_result_of(ctx, .Tool_Failed, fmt.tprintf("the command did not start: %s", os.error_string(cause)), data)
}

@(private)
tool_shell_background_message :: proc(message: string, background_terminated: bool) -> string {
	if background_terminated { return fmt.tprintf("%s. %s", message, TOOL_SHELL_BACKGROUND_NOTICE) }
	return message
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
