package agent

import "core:mem"
import "core:strings"
import linux "core:sys/linux"
import "core:time"

TOOL_SHELL_PATH :: "/bin/sh"

// TOOL_KILL_GRACE bounds how long a terminated process group may take to exit on
// SIGTERM before it is killed outright.
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

// tool_spawn_grouped starts the shell in its own process group and returns the
// child pid.
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
