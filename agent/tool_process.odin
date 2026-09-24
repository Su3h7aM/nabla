package agent

import "base:runtime"
import "core:mem"
import "core:strings"
import linux "core:sys/linux"
import "core:sys/posix"
import "core:time"

TOOL_KILL_GRACE :: 500 * time.Millisecond

// Tool_Stop is why a drain loop stopped short of the child exiting on its own.
Tool_Stop :: enum {
	None,
	Cancelled,
	Timed_Out,
}

// Tool_Child tracks one spawned command. The exit status is recorded the first
// time it is observed, because the drain loop may reap the child while it is
// still reading pipes and the caller must not lose the exit code as a result.
Tool_Child :: struct {
	pid:    int,
	reaped: bool,
	status: u32,
}

// TOOL_SPAWN_EXEC_FAILED is the byte a forked child writes when it could not
// start the program it was forked for. Its presence, not its value, is the fact:
// the parent reads it to tell an exec that never happened from one that did,
// which is what lets a caller try another program without running a command
// twice.
@(private)
TOOL_SPAWN_EXEC_FAILED :: u8(1)

// tool_spawn_shell_flags reports the extra argv entries that keep a shell
// from touching the user's personal history without changing which
// configuration it reads. Fish is the one shell that needs one: unlike the
// POSIX shells, it consults its history even for `shell -c`, so it needs
// --private to neither read old nor store new history. History managers such
// as Atuin hook into fish through events that honor private mode, so tool
// commands stay out of the user's history while the shell keeps its full
// functionality. Bash and zsh already write no history for `-c`, and their rc
// files are only read by interactive or login shells, so they run as
// `shell -c command`, unchanged.
tool_spawn_shell_flags :: proc(shell: string) -> (first, second: cstring) {
	name := shell
	if i := strings.last_index_byte(shell, '/'); i >= 0 { name = shell[i+1:] }
	if name == "fish" { return cstring("--private"), nil }
	return nil, nil
}

// tool_spawn_grouped starts shell in its own process group, running command with
// `shell -c` plus the history-isolation flags tool_spawn_shell_flags reports,
// and reports whether the shell started. It is the shell's caller
// that decides which shell that is and what to do when it does not start.
//
// Odin's os.process_start cannot express this. It forks and execs with no
// pre-exec hook, so setpgid from the parent always fails with EACCES once the
// child has exec'd, and kill(-pid) then fails with ESRCH while descendants
// survive. The child therefore has to create the group itself, before it execs.
//
// The harness may have other threads, so the child calls nothing that allocates,
// locks, logs, or enters the Odin runtime: every call below is a raw Linux
// syscall, and failure paths leave through tool_child_exit, which runs no
// atexit handler and flushes no stdio.
tool_spawn_grouped :: proc(shell, command, directory: string, stdout_write, stderr_write: linux.Fd) -> (pid: int, started: bool) {
	// The C strings live only as long as the spawn: exec takes its own copy of the
	// arguments, so the parent releases its own when the call returns.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	shell_cstring := strings.clone_to_cstring(shell, context.temp_allocator)
	source := strings.clone_to_cstring(command, context.temp_allocator)
	dash_c := strings.clone_to_cstring("-c", context.temp_allocator)
	work := strings.clone_to_cstring(directory, context.temp_allocator)
	flag_first, flag_second := tool_spawn_shell_flags(shell)

	argv: [5]cstring
	argv[0] = shell_cstring
	count := 1
	if flag_first != nil {
		argv[count] = flag_first
		count += 1
	}
	if flag_second != nil {
		argv[count] = flag_second
		count += 1
	}
	argv[count] = dash_c
	count += 1
	argv[count] = source
	count += 1
	argv[count] = nil

	// The command inherits the environment this process was started with: the
	// user's own environment, as the shell that launched the harness exported it.
	// Nothing is added, removed, or rewritten here, because a tool the user can
	// run is a tool the command has to be able to run.
	envp := posix.environ

	// The exec status pipe carries one fact back to the parent: whether the shell
	// started. Both ends are CLOEXEC, so a successful exec closes the child's
	// write end and the parent reads end-of-file, while a failed one lets the
	// child report before it exits. Without it, an exec that never happened is
	// indistinguishable from a fork that never happened.
	exec_pipe: [2]linux.Fd
	if linux.pipe2(&exec_pipe, {.CLOEXEC}) != .NONE { return 0, false }

	child, fork_errno := linux.fork()
	if fork_errno != .NONE {
		_ = linux.close(exec_pipe[0])
		_ = linux.close(exec_pipe[1])
		return 0, false
	}
	if child == 0 {
		// Standard input is closed: this is explicitly not a terminal.
		if linux.setpgid(0, 0) != .NONE { tool_child_exit(1) }
		_ = linux.close(0)
		if _, dup_errno := linux.dup2(stdout_write, 1); dup_errno != .NONE { tool_child_exit(1) }
		if _, dup_errno := linux.dup2(stderr_write, 2); dup_errno != .NONE { tool_child_exit(1) }
		// The pipe read ends close on exec: they were created with CLOEXEC.
		if linux.chdir(work) != .NONE { tool_child_exit(1) }
		if linux.execve(shell_cstring, &argv[0], envp) != .NONE {
			reported := [1]u8{TOOL_SPAWN_EXEC_FAILED}
			_, _ = linux.write(exec_pipe[1], reported[:])
			tool_child_exit(127)
		}
		tool_child_exit(127)
	}

	_ = linux.close(exec_pipe[1])
	reported := [1]u8{0}
	read_bytes, read_errno := linux.read(exec_pipe[0], reported[:])
	for read_errno == .EINTR {
		read_bytes, read_errno = linux.read(exec_pipe[0], reported[:])
	}
	_ = linux.close(exec_pipe[0])
	// Only the report says the exec failed. End-of-file means the child exec'd or
	// died before it could report, and a read that failed says nothing either; in
	// both cases the command may have run, so the child counts as started and the
	// caller waits for it the way it waits for any child.
	if read_bytes <= 0 { return int(child), true }

	// The child never became the shell. Reap it here, so it leaves no zombie and
	// no pid a caller could mistake for a running command.
	failed := Tool_Child {
		pid = int(child),
	}
	_, _, _ = tool_child_reap(&failed)
	return 0, false
}

// tool_child_exit leaves a forked child without running anything the parent's
// other threads could be holding, which is why it is exit_group and not exit.
tool_child_exit :: proc(code: i32) -> ! {
	linux.exit_group(code)
}

// tool_child_poll reports whether the child has finished, reaping it if it has.
// It never blocks.
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
// Pipes may close early while the child still sleeps, so a blocking reap would
// ignore cancellation and the deadline for the remainder of the child's life.
// Poll instead, with the same policy as the drain loop. Background descendants
// are not waited for: they only keep pipes open, and the caller closes those
// pipes on return.
tool_retire_child :: proc(child: ^Tool_Child, start: time.Tick, budget: time.Duration, control: Tool_Control) -> Tool_Stop {
	for !tool_child_poll(child) {
		if stop := tool_control_stop(control, start, budget); stop != .None {
			tool_terminate_group(child)
			return stop
		}
		time.sleep(5 * time.Millisecond)
	}
	return .None
}

// tool_drain_pipes reads both pipes to end of stream and reports why draining
// stopped. It never reads one pipe to EOF before the other, so a child cannot
// deadlock on a full pipe. Termination and reaping happen here, so the caller
// only ever sees a finished process.
tool_drain_pipes :: proc(
	child: ^Tool_Child,
	stdout_fd, stderr_fd: linux.Fd,
	start: time.Tick,
	budget: time.Duration,
	control: Tool_Control,
	data: ^Shell_Data,
	allocator: mem.Allocator,
) -> Tool_Stop {
	stdout_buf: [4096]u8
	stderr_buf: [4096]u8
	stdout_done, stderr_done := false, false
	for !stdout_done || !stderr_done {
		// One check covers both stops, and cancellation wins: a cancelled turn
		// is never reported as a timeout. Cancellation cannot preempt a
		// running tool any other way.
		if stop := tool_control_stop(control, start, budget); stop != .None {
			tool_terminate_group(child)
			return stop
		}
		progress := false
		if !stdout_done &&
		   tool_drain_ready(stdout_fd, stdout_buf[:], TOOL_MAX_STDOUT_BYTES, &data.stdout, &data.stdout_truncated, &stdout_done, allocator) { progress = true }
		if !stderr_done &&
		   tool_drain_ready(stderr_fd, stderr_buf[:], TOOL_MAX_STDERR_BYTES, &data.stderr, &data.stderr_truncated, &stderr_done, allocator) { progress = true }
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

// tool_append_bounded keeps at most limit bytes and records that anything beyond
// it was dropped.
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

// tool_terminate_group asks the whole tree to stop, escalates to SIGKILL once
// the grace period expires, and reaps the direct child. A process that ignores
// SIGTERM is why the escalation exists; descendants are why the group does.
tool_terminate_direct_child :: proc(child: ^Tool_Child) {
	if child.pid <= 0 || child.reaped { return }
	_ = linux.kill(linux.Pid(child.pid), .SIGTERM)
	grace := time.tick_add(time.tick_now(), TOOL_KILL_GRACE)
	for time.tick_since(grace) < 0 {
		if tool_child_poll(child) { return }
		time.sleep(5 * time.Millisecond)
	}
	_ = linux.kill(linux.Pid(child.pid), .SIGKILL)
	_, _, _ = tool_child_reap(child)
}

tool_terminate_group :: proc(child: ^Tool_Child) {
	if child.pid <= 0 { return }
	if tool_group_gone(child.pid) {
		tool_terminate_direct_child(child)
		return
	}
	tool_signal_group(child.pid, false)
	grace := time.tick_add(time.tick_now(), TOOL_KILL_GRACE)
	for time.tick_since(grace) < 0 {
		_ = tool_child_poll(child)
		if tool_group_gone(child.pid) {
			tool_terminate_direct_child(child)
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	tool_signal_group(child.pid, true)
	tool_terminate_direct_child(child)
}

tool_group_gone :: proc(pid: int) -> bool {
	if pid <= 0 { return true }
	return linux.kill(linux.Pid(-pid), linux.Signal(0)) == .ESRCH
}

tool_signal_group :: proc(pid: int, kill: bool) {
	signal: linux.Signal = .SIGKILL if kill else .SIGTERM
	_ = linux.kill(linux.Pid(-pid), signal)
}
