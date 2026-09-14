package agent

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import linux "core:sys/linux"
import "core:time"
import "core:unicode/utf8"

import "nabla:agent/session"
import "nabla:ai"

TOOL_SHELL_NAME :: "shell"

TOOL_SHELL_DESCRIPTION :: "Execute a command with /bin/sh in a fresh non-interactive process. Standard input is closed. Commands may use shell syntax. Directory and environment changes do not persist between calls. Returns bounded stdout and stderr, exit information, and truncation status. This is not a terminal or background-job service."

TOOL_SHELL_PARAMETERS_JSON :: `{"type":"object","properties":{"command":{"type":"string","description":"Shell source to execute."},"working_directory":{"type":["string","null"],"description":"Directory relative to the session workspace. Leave out or pass null for the workspace root."},"timeout_ms":{"type":["integer","null"],"description":"Positive timeout in milliseconds. Leave out or pass null for the harness default."}},"required":["command"],"additionalProperties":false}`

AGENT_SYSTEM_PROMPT :: "You are svan, a coding agent. You have one tool named shell that runs /bin/sh commands in a fresh non-interactive process inside the session workspace. Use it to inspect files, run programs, and report what they print. The command is the only argument you have to give. working_directory and timeout_ms are optional: leave them out, or pass null, and the harness runs in the session workspace with its own default timeout. Directory and environment changes do not persist between calls and standard input is closed. Results come back as JSON with stdout, stderr, exit code, and truncation flags. Never invent command output. Call the tool when the user asks you to do something on the machine, and keep chat replies short."

// TOOL_RECOVERED_RESULT is the model-visible result written for a call whose
// outcome the harness never observed, such as one a process died in the middle
// of. It has the envelope a normal result has, with the status saying what the
// harness knows rather than what it would have to guess.
TOOL_RECOVERED_RESULT :: `{"status":"unknown","exit_code":null,"stdout":"","stderr":"","stdout_truncated":false,"stderr_truncated":false,"output_incomplete":false,"error":"the session was interrupted before this call finished"}`

// TOOL_UNEXECUTED_RESULT is the model-visible result written for a call that was
// recorded but never dispatched, because the process died before the harness
// began it. Unlike TOOL_RECOVERED_RESULT the outcome is not in doubt: the call
// did not run.
TOOL_UNEXECUTED_RESULT :: `{"status":"not_executed","exit_code":null,"stdout":"","stderr":"","stdout_truncated":false,"stderr_truncated":false,"output_incomplete":false,"error":"the session was interrupted before this call started"}`

TOOL_MAX_ARGS_BYTES :: 64 * 1024
TOOL_MAX_CALLS_PER_RESPONSE :: 8
TOOL_MAX_CALLS_PER_TURN :: 32
TOOL_MAX_REQUESTS_PER_TURN :: 16
TOOL_DEFAULT_TIMEOUT_MS :: 30_000
TOOL_MAX_TIMEOUT_MS :: 120_000
TOOL_MAX_STDOUT_BYTES :: 32 * 1024
TOOL_MAX_STDERR_BYTES :: 32 * 1024
TOOL_MAX_RESULT_BYTES :: 512 * 1024
TOOL_SHELL_PATH :: "/bin/sh"

// Both excerpts plus the JSON envelope must fit the result budget together.
#assert(TOOL_MAX_STDOUT_BYTES + TOOL_MAX_STDERR_BYTES < TOOL_MAX_RESULT_BYTES)
// TOOL_KILL_GRACE bounds how long a terminated process group may take to exit on
// SIGTERM before it is killed outright.
TOOL_KILL_GRACE :: 500 * time.Millisecond

// Tool_Control is the caller's interruption policy for one execution. A zero value
// runs the command with no cancellation, bounded only by its timeout.
Tool_Control :: struct {
	interrupt: ^ai.Interrupt,
	deadline:  ai.Deadline,
}

Tool_Shell_Args :: struct {
	command:           string, // owned; shell source, never empty,
	working_directory: string, // owned; "" means the workspace root,
	timeout_ms:        int, // effective, clamped to the hard maximum,
}

tool_shell_args_destroy :: proc(args: ^Tool_Shell_Args, allocator := context.allocator) {
	if args == nil { return }
	if args.command != "" { delete(args.command, allocator) }
	if args.working_directory != "" { delete(args.working_directory, allocator) }
	args^ = {}
}

// tool_timeout_expected is the constraint the timeout field has to satisfy, said
// once so a type defect and a range defect give the model the same answer. The
// text is temporary: the error that carries it copies it.
@(private)
tool_timeout_expected :: proc() -> string {
	return fmt.aprintf("a positive integer of milliseconds no greater than %d, or null", TOOL_MAX_TIMEOUT_MS, allocator = context.temp_allocator)
}

// tool_shell_read checks the argument document and reads it in one pass, and
// reports the first defect it can describe. Reading and checking together is what
// lets an optional field be absent, null, or empty and mean the same thing: the
// token is right there to be interpreted, where the builtin unmarshal would
// refuse an empty string in a field whose type is a number. Key comparison is on
// decoded bytes, so an escaped spelling of a field is the same field.
@(private)
tool_shell_read :: proc(raw: string, allocator: mem.Allocator) -> (Tool_Shell_Args, Tool_Argument_Error) {
	if len(raw) == 0 { return {}, tool_argument_error(.Syntax, allocator = allocator) }
	if len(raw) > TOOL_MAX_ARGS_BYTES { return {}, tool_argument_error(.Too_Large, allocator = allocator) }
	result := Tool_Shell_Args{timeout_ms = TOOL_DEFAULT_TIMEOUT_MS}
	complete := false
	defer if !complete { tool_shell_args_destroy(&result, allocator) }

	tokenizer := json.make_tokenizer(raw, .JSON, true)
	token, token_err := json.get_token(&tokenizer)
	if tool_token_bad(token, token_err) { return {}, tool_argument_error(.Syntax, offset = token.offset, allocator = allocator) }
	if token.kind != .Open_Brace { return {}, tool_argument_error(.Not_Object, offset = token.offset, allocator = allocator) }

	seen_command, seen_work, seen_timeout := false, false, false
	for {
		token, token_err = json.get_token(&tokenizer)
		if tool_token_bad(token, token_err) { return {}, tool_argument_error(.Syntax, offset = token.offset, allocator = allocator) }
		if token.kind == .Close_Brace { break }
		if token.kind != .String { return {}, tool_argument_error(.Syntax, offset = token.offset, allocator = allocator) }

		key, key_err := json.unquote_string(token, .JSON, context.temp_allocator)
		if key_err != nil { return {}, tool_argument_error(.Syntax, offset = token.offset, allocator = allocator) }

		field := ""
		switch key {
		case "command":
			if seen_command { return {}, tool_argument_error(.Duplicate_Field, "command", allocator = allocator) }
			seen_command = true
			field = "command"
		case "working_directory":
			if seen_work { return {}, tool_argument_error(.Duplicate_Field, "working_directory", allocator = allocator) }
			seen_work = true
			field = "working_directory"
		case "timeout_ms":
			if seen_timeout { return {}, tool_argument_error(.Duplicate_Field, "timeout_ms", allocator = allocator) }
			seen_timeout = true
			field = "timeout_ms"
		case:
			return {}, tool_argument_error(.Unknown_Field, key, allocator = allocator)
		}

		token, token_err = json.get_token(&tokenizer)
		if tool_token_bad(token, token_err) { return {}, tool_argument_error(.Syntax, offset = token.offset, allocator = allocator) }
		if token.kind != .Colon { return {}, tool_argument_error(.Syntax, offset = token.offset, allocator = allocator) }

		token, token_err = json.get_token(&tokenizer)
		if tool_token_bad(token, token_err) { return {}, tool_argument_error(.Syntax, offset = token.offset, allocator = allocator) }
		field_err := tool_shell_read_field(&result, field, token, allocator)
		if field_err.kind != .None { return {}, field_err }

		token, token_err = json.get_token(&tokenizer)
		if tool_token_bad(token, token_err) { return {}, tool_argument_error(.Syntax, offset = token.offset, allocator = allocator) }
		if token.kind == .Comma { continue }
		if token.kind == .Close_Brace { break }
		return {}, tool_argument_error(.Syntax, offset = token.offset, allocator = allocator)
	}
	if !seen_command { return {}, tool_argument_error(.Missing_Field, "command", allocator = allocator) }

	token, token_err = json.get_token(&tokenizer)
	if (token_err != nil && token_err != .EOF) || token.kind != .EOF {
		return {}, tool_argument_error(.Syntax, offset = token.offset, allocator = allocator)
	}
	complete = true
	return result, {}
}

// tool_token_bad reports a token that cannot be used: a tokenizer failure or an
// end of input where the document still owes structure.
@(private)
tool_token_bad :: proc(token: json.Token, err: json.Error) -> bool {
	return (err != nil && err != .EOF) || token.kind == .EOF
}

// tool_shell_read_field reads one field's value. command is the only field that
// has to be there. An optional field is not given when it is absent, null, or an
// empty string, because an empty string is what a model writes when it has
// nothing to say about a field it was told about. Anything else has to be a value
// of the declared type: inventing one would change what the model asked for.
@(private)
tool_shell_read_field :: proc(args: ^Tool_Shell_Args, field: string, token: json.Token, allocator: mem.Allocator) -> Tool_Argument_Error {
	switch field {
	case "command":
		if token.kind != .String { return tool_argument_error(.Wrong_Type, field, "a non-empty shell command", token.offset, allocator) }
		text, text_err := json.unquote_string(token, .JSON, allocator)
		if text_err != nil { return tool_argument_error(.Syntax, offset = token.offset, allocator = allocator) }
		defer delete(text, allocator)
		command := strings.trim_space(text)
		if command == "" || strings.contains_rune(command, 0) {
			return tool_argument_error(.Invalid_Value, field, "a non-empty shell command", token.offset, allocator)
		}
		args.command = strings.clone(command, allocator)
	case "working_directory":
		if token.kind == .Null { return {} }
		if token.kind != .String { return tool_argument_error(.Wrong_Type, field, "a relative path inside the workspace, or null", token.offset, allocator) }
		text, text_err := json.unquote_string(token, .JSON, allocator)
		if text_err != nil { return tool_argument_error(.Syntax, offset = token.offset, allocator = allocator) }
		defer delete(text, allocator)
		directory := strings.trim_space(text)
		if directory == "" { return {} }
		if strings.contains_rune(directory, 0) || directory[0] == '/' {
			return tool_argument_error(.Invalid_Value, field, "a relative path inside the workspace, or null", token.offset, allocator)
		}
		// The iterator consumes the string it walks, so the check walks a copy and
		// the clone below still sees the whole path.
		parts := directory
		for part in strings.split_iterator(&parts, "/") {
			if part == ".." {
				return tool_argument_error(.Invalid_Value, field, "a relative path inside the workspace, or null", token.offset, allocator)
			}
		}
		args.working_directory = strings.clone(directory, allocator)
	case "timeout_ms":
		if token.kind == .Null {
			args.timeout_ms = TOOL_DEFAULT_TIMEOUT_MS
			return {}
		}
		if token.kind == .String {
			text, text_err := json.unquote_string(token, .JSON, allocator)
			if text_err != nil { return tool_argument_error(.Syntax, offset = token.offset, allocator = allocator) }
			defer delete(text, allocator)
			if strings.trim_space(text) == "" {
				args.timeout_ms = TOOL_DEFAULT_TIMEOUT_MS
				return {}
			}
			return tool_argument_error(.Wrong_Type, field, tool_timeout_expected(), token.offset, allocator)
		}
		if token.kind != .Integer { return tool_argument_error(.Wrong_Type, field, tool_timeout_expected(), token.offset, allocator) }
		milliseconds, parsed := strconv.parse_i64(token.text, 10)
		if !parsed || milliseconds <= 0 || milliseconds > i64(TOOL_MAX_TIMEOUT_MS) {
			return tool_argument_error(.Invalid_Value, field, tool_timeout_expected(), token.offset, allocator)
		}
		args.timeout_ms = int(milliseconds)
	}
	return {}
}

// Tool_Preparation is the outcome of preparing one proposed call. A rejected
// preparation never runs: it exists only to tell the model what was wrong.
Tool_Preparation_Status :: enum {
	None,
	Valid,
	Repaired,
	Rejected,
}

Tool_Preparation :: struct {
	status:    Tool_Preparation_Status,
	// repair names what had to change for the call to be usable. It is set in
	// exactly the case where status is .Repaired.
	repair:    session.Tool_Repair,
	args:      Tool_Shell_Args,
	effective: string, // owned; the argument JSON the call runs with
	error:     Tool_Argument_Error,
}

tool_preparation_destroy :: proc(prep: ^Tool_Preparation, allocator := context.allocator) {
	tool_shell_args_destroy(&prep.args, allocator)
	delete(prep.effective, allocator)
	tool_argument_error_destroy(&prep.error, allocator)
	prep^ = {}
}

// tool_shell_prepare reads a proposed call, repairs it only when the repair
// is forced, and reads it again. Reading runs once on the bytes the model sent;
// only a control-character defect that escaping resolves is accepted as a
// repair, and the repaired bytes are read in full before anything runs.
// Nothing else is rewritten, and no value is ever invented.
tool_shell_prepare :: proc(raw: string, allocator := context.allocator) -> (prep: Tool_Preparation) {
	prep.status = .Rejected
	args, read_err := tool_shell_read(raw, allocator)
	if read_err.kind == .None {
		prep.status = .Valid
		prep.args = args
		prep.effective = strings.clone(raw, allocator)
		return prep
	}
	repaired, changed := tool_arguments_escape_control_chars(raw, allocator)
	if !changed {
		prep.error = read_err
		return prep
	}
	repaired_args, repaired_err := tool_shell_read(repaired, allocator)
	if repaired_err.kind != .None {
		delete(repaired, allocator)
		prep.error = read_err
		return prep
	}
	prep.status = .Repaired
	prep.repair = .Escaped_Control_Characters
	prep.args = repaired_args
	prep.effective = repaired
	return prep
}

// tool_shell_parse_args is the decode-only view used by callers that own their
// own failure reporting. A deterministic repair is applied when one is forced.
tool_shell_parse_args :: proc(raw: string, allocator := context.allocator) -> (Tool_Shell_Args, bool) {
	prep := tool_shell_prepare(raw, allocator)
	defer tool_preparation_destroy(&prep, allocator)
	if prep.status == .Rejected { return {}, false }
	args := prep.args
	prep.args = {}
	return args, true
}

Tool_Result_Status :: enum {
	None,
	Exited,
	Invalid_Arguments,
	Spawn_Failed,
	Timed_Out,
	Cancelled,
	Not_Executed,
	IO_Failed,
}

Tool_Result :: struct {
	call_id:        string, // owned; matches the model call,
	status:         Tool_Result_Status,
	exit_code:      int,
	exit_present:   bool,
	stdout:         string, // owned; sanitized excerpt,
	stderr:         string, // owned; sanitized excerpt,
	stdout_trunc:   bool,
	stderr_trunc:   bool,
	output_trunc:   bool, // final JSON did not fit; excerpts were shrunk,
	error_text:     string, // owned; machine-readable reason, "" when none,
	argument_error: Tool_Argument_Error, // set only for .Invalid_Arguments,
	allocator:      mem.Allocator,
}

tool_result_destroy :: proc(result: ^Tool_Result) {
	if result == nil { return }
	allocator := result.allocator
	if result.call_id != "" { delete(result.call_id, allocator) }
	if result.stdout != "" { delete(result.stdout, allocator) }
	if result.stderr != "" { delete(result.stderr, allocator) }
	if result.error_text != "" { delete(result.error_text, allocator) }
	tool_argument_error_destroy(&result.argument_error, allocator)
	result^ = {}
}

tool_result_json :: proc(result: ^Tool_Result, allocator := context.allocator) -> string {
	status_text := "not_executed"
	#partial switch result.status {
	case .Exited:
		status_text = "exited"
	case .Invalid_Arguments:
		status_text = "invalid_arguments"
	case .Spawn_Failed:
		status_text = "spawn_failed"
	case .Timed_Out:
		status_text = "timed_out"
	case .Cancelled:
		status_text = "cancelled"
	case .IO_Failed:
		status_text = "io_failed"
	}
	stdout_text, stdout_trunc := tool_sanitize_stream(result.stdout, TOOL_MAX_STDOUT_BYTES, allocator)
	stderr_text, stderr_trunc := tool_sanitize_stream(result.stderr, TOOL_MAX_STDERR_BYTES, allocator)
	defer delete(stdout_text, allocator)
	defer delete(stderr_text, allocator)
	if result.stdout_trunc { stdout_trunc = true }
	if result.stderr_trunc { stderr_trunc = true }
	// Shrink excerpts until the envelope fits; truncation flags stay set.
	for {
		object := make(json.Object, 10, allocator)
		object[strings.clone("status", allocator)] = json.String(strings.clone(status_text, allocator))
		if result.exit_present {
			object[strings.clone("exit_code", allocator)] = json.Integer(i64(result.exit_code))
		} else {
			object[strings.clone("exit_code", allocator)] = json.Null{}
		}
		object[strings.clone("stdout", allocator)] = json.String(strings.clone(stdout_text, allocator))
		object[strings.clone("stderr", allocator)] = json.String(strings.clone(stderr_text, allocator))
		object[strings.clone("stdout_truncated", allocator)] = json.Boolean(stdout_trunc)
		object[strings.clone("stderr_truncated", allocator)] = json.Boolean(stderr_trunc)
		object[strings.clone("output_incomplete", allocator)] = json.Boolean(result.output_trunc)
		if result.error_text != "" {
			object[strings.clone("error", allocator)] = json.String(strings.clone(result.error_text, allocator))
		} else {
			object[strings.clone("error", allocator)] = json.Null{}
		}
		if result.status == .Invalid_Arguments && result.argument_error.kind != .None {
			object[strings.clone("code", allocator)] = json.String(strings.clone(tool_argument_error_code(result.argument_error), allocator))
			if result.argument_error.field != "" {
				object[strings.clone("field", allocator)] = json.String(strings.clone(result.argument_error.field, allocator))
			} else {
				object[strings.clone("field", allocator)] = json.Null{}
			}
		}
		text, unparse_err := json.unparse(json.Value(object), allocator = allocator)
		json.destroy_value(json.Value(object), allocator)
		if unparse_err != nil { return "" }
		if len(text) <= TOOL_MAX_RESULT_BYTES { return text }
		if len(stdout_text) == 0 && len(stderr_text) == 0 {
			delete(text, allocator)
			return ""
		}
		if len(stdout_text) >= len(stderr_text) {
			shrunk := stdout_text[:len(stdout_text) / 2]
			delete(stdout_text, allocator)
			stdout_text = strings.clone(shrunk, allocator)
			stdout_trunc = true
		} else {
			shrunk := stderr_text[:len(stderr_text) / 2]
			delete(stderr_text, allocator)
			stderr_text = strings.clone(shrunk, allocator)
			stderr_trunc = true
		}
		delete(text, allocator)
	}
}

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

tool_resolve_directory :: proc(workspace, working_directory: string, allocator := context.allocator) -> (string, bool) {
	ok := false
	resolved := ""
	defer if !ok && resolved != "" { delete(resolved, allocator) }
	if strings.contains_rune(working_directory, 0) { return "", false }
	if working_directory == "" {
		resolved = strings.clone(workspace, allocator)
	} else {
		cleaned := strings.clone(working_directory, allocator)
		defer delete(cleaned, allocator)
		forward := cleaned
		if strings.contains(cleaned, "\\") {
			forward, _ = strings.replace_all(cleaned, "\\", "/", allocator)
			defer delete(forward, allocator)
		}
		if len(forward) > 0 && forward[0] == '/' { return "", false }
		parts := strings.split(forward, "/", allocator)
		defer delete(parts, allocator)
		for part in parts {
			if part == ".." { return "", false }
		}
		resolved, _ = os.join_path([]string{workspace, forward}, allocator)
	}
	ok = true
	return resolved, true
}

tool_shell_execute :: proc(call_id: string, args: Tool_Shell_Args, workspace: string, control: Tool_Control, allocator := context.allocator) -> Tool_Result {
	result := Tool_Result {
		call_id   = strings.clone(call_id, allocator),
		status    = .Not_Executed,
		allocator = allocator,
	}
	directory, dir_ok := tool_resolve_directory(workspace, args.working_directory, allocator)
	defer if dir_ok { delete(directory, allocator) }
	if !dir_ok {
		result.status = .Invalid_Arguments
		result.error_text = strings.clone("working directory escapes the workspace", allocator)
		return result
	}
	info, info_err := os.stat(directory, allocator)
	defer os.file_info_delete(info, allocator)
	if info_err != nil || info.type != .Directory {
		result.status = .Invalid_Arguments
		result.error_text = strings.clone("working directory does not exist", allocator)
		return result
	}
	stdout_pipe, stderr_pipe: [2]linux.Fd
	if linux.pipe2(&stdout_pipe, {.CLOEXEC}) != .NONE {
		result.status = .Spawn_Failed
		result.error_text = strings.clone("process did not start or output was lost", allocator)
		return result
	}
	if linux.pipe2(&stderr_pipe, {.CLOEXEC}) != .NONE {
		_ = linux.close(stdout_pipe[0])
		_ = linux.close(stdout_pipe[1])
		result.status = .Spawn_Failed
		result.error_text = strings.clone("process did not start or output was lost", allocator)
		return result
	}
	pid, spawned := tool_spawn_grouped(args.command, directory, stdout_pipe[1], stderr_pipe[1])
	_ = linux.close(stdout_pipe[1])
	_ = linux.close(stderr_pipe[1])
	if !spawned {
		_ = linux.close(stdout_pipe[0])
		_ = linux.close(stderr_pipe[0])
		result.status = .Spawn_Failed
		result.error_text = strings.clone("process did not start or output was lost", allocator)
		return result
	}
	child := Tool_Child {
		pid = pid,
	}
	start := time.tick_now()
	budget := time.Duration(args.timeout_ms) * time.Millisecond
	reason := tool_drain_pipes(&child, stdout_pipe[0], stderr_pipe[0], start, budget, control, &result, allocator)
	_ = linux.close(stdout_pipe[0])
	_ = linux.close(stderr_pipe[0])
	if reason != .None {
		result.status = reason
		if result.error_text != "" { delete(result.error_text, allocator) }
		result.error_text = strings.clone("command cancelled" if reason == .Cancelled else "command timed out", allocator)
		return result
	}
	exited, exit_code, waited := tool_child_reap(&child)
	if !waited || !exited {
		result.status = .IO_Failed
		result.error_text = strings.clone("process did not start or output was lost", allocator)
		return result
	}
	result.status = .Exited
	result.exit_code = exit_code
	result.exit_present = true
	return result
}

// tool_spawn_grouped starts the shell in its own process group and returns the
// child pid.
//
// Odin's os.process_start cannot express this. It forks and execs with no pre-exec
// hook, so setpgid from the parent always fails with EACCES once the child has
// exec'd, and kill(-pid) then fails with ESRCH while descendants survive. Measured
// over repeated attempts the group was never established. The child therefore has
// to create the group itself, before it execs.
//
// The harness may have other threads, so the child calls nothing that allocates,
// locks, logs, or enters the Odin runtime: every call below is a "contextless"
// raw Linux syscall, and failure paths leave through tool_child_exit, which is
// _exit and runs no atexit handler and flushes no stdio.
tool_spawn_grouped :: proc(command, directory: string, stdout_write, stderr_write: linux.Fd) -> (pid: int, ok: bool) {
	source := strings.clone_to_cstring(command, context.temp_allocator)
	dash_c := strings.clone_to_cstring("-c", context.temp_allocator)
	path_env := strings.clone_to_cstring("PATH=/usr/bin:/bin", context.temp_allocator)
	locale_env := strings.clone_to_cstring("LC_ALL=C.UTF-8", context.temp_allocator)
	work := strings.clone_to_cstring(directory, context.temp_allocator)

	argv := [4]cstring{TOOL_SHELL_PATH, dash_c, source, nil}
	envp := [3]cstring{path_env, locale_env, nil}

	child, fork_errno := linux.fork()
	if fork_errno != .NONE { return 0, false }
	if child == 0 {
		// Standard input is closed: this is explicitly not a terminal.
		if linux.setpgid(0, 0) != .NONE { tool_child_exit(1) }
		_ = linux.close(0)
		if _, dup_errno := linux.dup2(stdout_write, 1); dup_errno != .NONE { tool_child_exit(1) }
		if _, dup_errno := linux.dup2(stderr_write, 2); dup_errno != .NONE { tool_child_exit(1) }
		// The pipe read ends close on exec: they were created with CLOEXEC.
		if linux.chdir(work) != .NONE { tool_child_exit(1) }
		_ = linux.execve(TOOL_SHELL_PATH, &argv[0], &envp[0])
		tool_child_exit(127)
	}
	return int(child), true
}

// tool_child_exit leaves a forked child without running anything the parent's other
// threads could be holding, which is why it is exit_group and not exit.
tool_child_exit :: proc(code: i32) -> ! {
	linux.exit_group(code)
}

// Tool_Child tracks one spawned command. The exit status is recorded the first time
// it is observed, because the drain loop may reap the child while it is still
// reading pipes and the caller must not lose the exit code as a result.
Tool_Child :: struct {
	pid:    int,
	reaped: bool,
	status: u32,
}

// tool_child_poll reports whether the child has finished, reaping it if it has. It
// never blocks.
tool_child_poll :: proc(child: ^Tool_Child) -> bool {
	if child.reaped { return true }
	status: u32
	reaped, wait_errno := linux.wait4(linux.Pid(child.pid), &status, {.WNOHANG}, nil)
	if reaped == linux.Pid(child.pid) {
		child.reaped = true
		child.status = status
		return true
	}
	// No child left to wait for: it was already reaped.
	if wait_errno == .ECHILD { child.reaped = true }
	return child.reaped
}

// tool_child_reap blocks until the child is reaped and reports its exit state. A
// process killed by a signal did not exit, so exited is false.
tool_child_reap :: proc(child: ^Tool_Child) -> (exited: bool, exit_code: int, waited: bool) {
	if child.reaped { return tool_child_status(child.status) }
	status: u32
	for {
		reaped, wait_errno := linux.wait4(linux.Pid(child.pid), &status, {}, nil)
		if reaped == linux.Pid(child.pid) { break }
		if wait_errno == .ECHILD {
			child.reaped = true
			return false, 0, true
		}
		if wait_errno != .EINTR { return false, 0, false }
	}
	child.reaped = true
	child.status = status
	return tool_child_status(status)
}

tool_child_status :: proc(status: u32) -> (exited: bool, exit_code: int, waited: bool) {
	if status & 0x7f != 0 { return false, int((status >> 8) & 0xff), true }
	return true, int((status >> 8) & 0xff), true
}

// tool_retire_child waits for retirement without ever blocking unobservably.
// Pipes may close early while the child still sleeps, so the blocking reap the
// drain loop used to call here ignored cancellation and deadlines for the
// remainder of the child's life. Poll instead, with the same policy as the
// drain loop. A reaped child is retired; background descendants are not waited
// for, they only keep pipes open, and the caller closes those pipes on return.
tool_retire_child :: proc(child: ^Tool_Child, start: time.Tick, budget: time.Duration, control: Tool_Control) -> Tool_Result_Status {
	for !tool_child_poll(child) {
		if ai.interrupt_requested(control.interrupt) || ai.deadline_expired(control.deadline) {
			tool_terminate_group(child)
			return .Cancelled
		}
		if time.tick_since(start) > budget {
			tool_terminate_group(child)
			return .Timed_Out
		}
		time.sleep(5 * time.Millisecond)
	}
	return .None
}

// tool_drain_pipes reads both pipes to end of stream and reports why draining
// stopped. It never reads one pipe to EOF before the other, so a child cannot
// deadlock on a full pipe. Termination and reaping happen here, so the caller only
// ever sees a finished process.
tool_drain_pipes :: proc(
	child: ^Tool_Child,
	stdout_fd, stderr_fd: linux.Fd,
	start: time.Tick,
	budget: time.Duration,
	control: Tool_Control,
	result: ^Tool_Result,
	allocator: mem.Allocator,
) -> Tool_Result_Status {
	stdout_buf: [4096]u8
	stderr_buf: [4096]u8
	stdout_done, stderr_done := false, false
	for !stdout_done || !stderr_done {
		// Cancellation is checked before the timeout so a cancelled turn is never
		// reported as a timeout. The deadline is checked because the turn bound
		// cannot preempt a running tool any other way.
		if ai.interrupt_requested(control.interrupt) || ai.deadline_expired(control.deadline) {
			tool_terminate_group(child)
			return .Cancelled
		}
		if time.tick_since(start) > budget {
			tool_terminate_group(child)
			return .Timed_Out
		}
		progress := false
		if !stdout_done &&
		   tool_drain_ready(stdout_fd, stdout_buf[:], TOOL_MAX_STDOUT_BYTES, &result.stdout, &result.stdout_trunc, &stdout_done, allocator) { progress = true }
		if !stderr_done &&
		   tool_drain_ready(stderr_fd, stderr_buf[:], TOOL_MAX_STDERR_BYTES, &result.stderr, &result.stderr_trunc, &stderr_done, allocator) { progress = true }
		if !progress {
			// Only a descendant of an exited child could still write, and background
			// jobs are unsupported, so stop rather than wait out the whole budget.
			if tool_child_poll(child) { break }
			time.sleep(5 * time.Millisecond)
		}
	}
	return tool_retire_child(child, start, budget, control)
}

// tool_drain_ready consumes whatever a pipe already holds. It never blocks.
tool_drain_ready :: proc(fd: linux.Fd, scratch: []u8, limit: int, kept: ^string, truncated: ^bool, done: ^bool, allocator: mem.Allocator) -> bool {
	fds := [1]linux.Poll_Fd{{fd = fd, events = {.IN}}}
	ready, poll_errno := linux.poll(fds[:], 0)
	if poll_errno != .NONE || ready <= 0 {
		// A hangup ends the stream once nothing is left to read.
		if .HUP in fds[0].revents { done^ = true }
		return false
	}
	n, read_errno := linux.read(fd, scratch)
	if read_errno == .EAGAIN || read_errno == .EINTR { return false }
	// Zero bytes with no error is end of stream; any other error ends it too.
	if read_errno != .NONE || n <= 0 {
		done^ = true
		return false
	}
	tool_append_bounded(kept, truncated, scratch[:n], limit, allocator)
	return true
}

// tool_append_bounded keeps at most limit bytes and records that anything beyond it
// was dropped.
tool_append_bounded :: proc(kept: ^string, truncated: ^bool, chunk: []u8, limit: int, allocator: mem.Allocator) {
	if len(kept^) >= limit {
		truncated^ = true
		return
	}
	space := limit - len(kept^)
	kept_chunk := chunk
	if len(kept_chunk) > space {
		kept_chunk = kept_chunk[:space]
		truncated^ = true
	}
	grown := make([dynamic]u8, len(kept^) + len(kept_chunk), allocator)
	copy(grown[:], transmute([]u8)kept^)
	copy(grown[len(kept^):], kept_chunk)
	if kept^ != "" { delete(kept^, allocator) }
	kept^ = string(grown[:])
}

// tool_terminate_group asks the whole tree to stop, escalates to SIGKILL once the
// grace period expires, and reaps the direct child. A process that ignores SIGTERM
// is why the escalation exists; descendants are why the group does.
tool_terminate_group :: proc(child: ^Tool_Child) {
	if child.pid <= 0 { return }
	tool_signal_group(child.pid, false)
	grace := time.tick_add(time.tick_now(), TOOL_KILL_GRACE)
	for time.tick_since(grace) < 0 {
		_ = tool_child_poll(child)
		if tool_group_gone(child.pid) { return }
		time.sleep(5 * time.Millisecond)
	}
	tool_signal_group(child.pid, true)
	tool_child_reap(child)
}

tool_group_gone :: proc(pid: int) -> bool {
	if pid <= 0 { return true }
	return linux.kill(linux.Pid(-pid), linux.Signal(0)) == .ESRCH
}

tool_signal_group :: proc(pid: int, kill: bool) {
	signal: linux.Signal = .SIGKILL if kill else .SIGTERM
	_ = linux.kill(linux.Pid(-pid), signal)
}

tool_error_result :: proc(call_id: string, status: Tool_Result_Status, reason: string, allocator := context.allocator) -> Tool_Result {
	return Tool_Result{call_id = strings.clone(call_id, allocator), status = status, error_text = strings.clone(reason, allocator), allocator = allocator}
}

// tool_argument_result takes ownership of err and returns the rejection the
// model sees for a call whose arguments could not be prepared. Nothing ran, and
// the result says exactly why.
tool_argument_result :: proc(call_id: string, err: ^Tool_Argument_Error, allocator := context.allocator) -> Tool_Result {
	result := Tool_Result {
		call_id        = strings.clone(call_id, allocator),
		status         = .Invalid_Arguments,
		error_text     = tool_argument_error_text(err^, allocator),
		argument_error = err^,
		allocator      = allocator,
	}
	err^ = {}
	return result
}
