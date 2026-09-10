package agent

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"
import linux "core:sys/linux"
import "core:time"
import "core:unicode/utf8"

import "nabla:ai"

TOOL_SHELL_NAME :: "shell"

TOOL_SHELL_DESCRIPTION :: "Execute a command with /bin/sh in a fresh non-interactive process. Standard input is closed. Commands may use shell syntax. Directory and environment changes do not persist between calls. Returns bounded stdout and stderr, exit information, and truncation status. This is not a terminal or background-job service."

TOOL_SHELL_PARAMETERS_JSON :: `{"type":"object","properties":{"command":{"type":"string","description":"Shell source to execute."},"working_directory":{"type":["string","null"],"description":"Directory relative to the session workspace; null uses the workspace root."},"timeout_ms":{"type":["integer","null"],"description":"Positive timeout in milliseconds; null uses the harness default."}},"required":["command","working_directory","timeout_ms"],"additionalProperties":false}`

AGENT_SYSTEM_PROMPT :: "You are svan, a coding agent. You have one tool named shell that runs /bin/sh commands in a fresh non-interactive process inside the session workspace. Use it to inspect files, run programs, and report what they print. Pass working_directory relative to the workspace, or null for the workspace root. Pass timeout_ms in milliseconds, or null for the default. Directory and environment changes do not persist between calls and standard input is closed. Results come back as JSON with stdout, stderr, exit code, and truncation flags. Never invent command output. Call the tool when the user asks you to do something on the machine, and keep chat replies short."

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

Tool_Shell_Raw_Args :: struct {
	command:           string,
	working_directory: Maybe(string),
	timeout_ms:        Maybe(i64),
}

tool_shell_raw_args_destroy :: proc(raw_args: ^Tool_Shell_Raw_Args, allocator: mem.Allocator) {
	if raw_args == nil { return }
	if raw_args.command != "" { delete(raw_args.command, allocator) }
	if work, has_work := raw_args.working_directory.?; has_work { delete(work, allocator) }
	raw_args^ = {}
}

@(private)
tool_shell_unmarshal :: proc(raw: string, args: ^Tool_Shell_Raw_Args, allocator: mem.Allocator) -> bool {
	err := json.unmarshal_string(raw, args, .JSON, allocator)
	if err != nil { return false }
	// Builtin unmarshal skips unknown fields, so reject them explicitly
	// with the builtin tokenizer: top-level keys must be exactly the
	// three schema fields, each appearing once.
	tokenizer := json.make_tokenizer(raw, .JSON, true)
	seen_command, seen_work, seen_timeout := false, false, false
	token, token_err := json.get_token(&tokenizer)
	if (token_err != nil && token_err != .EOF) || token.kind != .Open_Brace { return false }
	for {
		token, token_err = json.get_token(&tokenizer)
		if token_err != nil && token_err != .EOF { return false }
		if token.kind == .Close_Brace { break }
		if token.kind != .String { return false }
		key := token.text[1:len(token.text) - 1]
		if key == "command" {
			if seen_command { return false }
			seen_command = true
		} else if key == "working_directory" {
			if seen_work { return false }
			seen_work = true
		} else if key == "timeout_ms" {
			if seen_timeout { return false }
			seen_timeout = true
		} else { return false }
		token, token_err = json.get_token(&tokenizer)
		if (token_err != nil && token_err != .EOF) || token.kind != .Colon { return false }
		token, token_err = json.get_token(&tokenizer)
		if token_err != nil && token_err != .EOF { return false }
		#partial switch token.kind {
		case .Open_Brace, .Open_Bracket:
			open := token.kind
			depth := 1
			for depth > 0 {
				token, token_err = json.get_token(&tokenizer)
				if token_err != nil && token_err != .EOF { return false }
				if token.kind == open { depth += 1 }
				if (open == .Open_Brace && token.kind == .Close_Brace) || (open == .Open_Bracket && token.kind == .Close_Bracket) { depth -= 1 }
				if token.kind == .EOF { return false }
			}
		case .String, .Integer, .Float, .True, .False, .Null:
		case:
			return false
		}
		token, token_err = json.get_token(&tokenizer)
		if token_err != nil && token_err != .EOF { return false }
		if token.kind == .Close_Brace { break }
		if token.kind != .Comma { return false }
	}
	if !seen_command || !seen_work || !seen_timeout { return false }
	token, token_err = json.get_token(&tokenizer)
	if token.kind != .EOF { return false }
	return true
}

tool_shell_parse_args :: proc(raw: string, allocator := context.allocator) -> (Tool_Shell_Args, bool) {
	args := Tool_Shell_Args{}
	ok := false
	defer if !ok { tool_shell_args_destroy(&args, allocator) }
	if len(raw) == 0 || len(raw) > TOOL_MAX_ARGS_BYTES { return args, false }
	raw_args: Tool_Shell_Raw_Args
	if !tool_shell_unmarshal(raw, &raw_args, allocator) { return args, false }
	defer tool_shell_raw_args_destroy(&raw_args, allocator)
	work_opt := raw_args.working_directory
	timeout_opt := raw_args.timeout_ms
	command_text := strings.trim_space(raw_args.command)
	if command_text == "" { return args, false }
	if strings.contains_rune(command_text, 0) { return args, false }
	args.command = strings.clone(command_text, allocator)
	work, work_present := work_opt.?
	if !work_present {
		args.working_directory = ""
	} else {
		work_text := strings.trim_space(work)
		if work_text == "" || strings.contains_rune(work_text, 0) { return args, false }
		// Parse-time shape check mirrors the executor: absolute paths
		// and parent escapes never reach a process, even before
		// workspace resolution.
		if work_text[0] == '/' { return args, false }
		for part in strings.split_iterator(&work_text, "/") {
			if part == ".." { return args, false }
		}
		args.working_directory = strings.clone(work_text, allocator)
	}
	timeout, timeout_present := timeout_opt.?
	if !timeout_present {
		args.timeout_ms = TOOL_DEFAULT_TIMEOUT_MS
	} else {
		if timeout <= 0 || timeout > i64(TOOL_MAX_TIMEOUT_MS) { return args, false }
		args.timeout_ms = int(timeout)
	}
	ok = true
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
	call_id:      string, // owned; matches the model call,
	status:       Tool_Result_Status,
	exit_code:    int,
	exit_present: bool,
	stdout:       string, // owned; sanitized excerpt,
	stderr:       string, // owned; sanitized excerpt,
	stdout_trunc: bool,
	stderr_trunc: bool,
	output_trunc: bool, // final JSON did not fit; excerpts were shrunk,
	error_text:   string, // owned; machine-readable reason, "" when none,
	allocator:    mem.Allocator,
}

tool_result_destroy :: proc(result: ^Tool_Result) {
	if result == nil { return }
	allocator := result.allocator
	if result.call_id != "" { delete(result.call_id, allocator) }
	if result.stdout != "" { delete(result.stdout, allocator) }
	if result.stderr != "" { delete(result.stderr, allocator) }
	if result.error_text != "" { delete(result.error_text, allocator) }
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
		object := make(json.Object, 8, allocator)
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
