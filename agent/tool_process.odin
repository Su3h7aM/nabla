package agent

import "base:runtime"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

TOOL_KILL_GRACE :: 500 * time.Millisecond

// Tool_Stop is why a drain loop stopped short of the child exiting on its own.
// Wait_Failed means the system refused the wait itself, so the child was stopped
// because nothing could observe it any more.
Tool_Stop :: enum {
	None,
	Cancelled,
	Timed_Out,
	Wait_Failed,
}

// Tool_Child tracks one spawned command. The exit state is recorded the first
// time it is observed, because the drain loop may reap the child while it is
// still reading pipes and the caller must not lose the exit code as a result.
// exited is false for a child a signal ended. exit watches for the child's exit
// and is released with tool_child_close.
Tool_Child :: struct {
	pid:          int,
	exit:         Tool_Exit_Watch,
	reaped:       bool,
	status_known: bool,
	exited:       bool,
	exit_code:    int,
}

// Tool_Spawn is how far a spawn got. Only Exec_Failed proves the program never
// ran, which is what lets a caller try another program without running a command
// twice.
Tool_Spawn :: enum {
	Started,
	Exec_Failed,
	Failed,
}

// TOOL_CHILD_SETUP_FAILED is the exit status of a forked child that could not
// prepare its process group, streams, or directory before exec.
@(private)
TOOL_CHILD_SETUP_FAILED :: 1

// TOOL_CHILD_EXEC_FAILED is the exit status of a forked child whose exec failed,
// the status a shell reports for a command it cannot run.
@(private)
TOOL_CHILD_EXEC_FAILED :: 127

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
	if i := strings.last_index_byte(shell, '/'); i >= 0 { name = shell[i + 1:] }
	if name == "fish" { return cstring("--private"), nil }
	return nil, nil
}

// tool_spawn_grouped starts shell in its own process group, running command with
// `shell -c` plus the history-isolation flags tool_spawn_shell_flags reports.
// A spawn that did not start reports the system's reason, including the reason
// exec gave. It is the shell's caller that decides which shell that is and what
// to do when it does not start.
//
// Odin's os.process_start cannot express this. It forks and execs with no
// pre-exec hook, so setpgid from the parent always fails with EACCES once the
// child has exec'd, and a group kill then misses the descendants. The child
// therefore has to create the group itself, before it execs.
//
// The harness may have other threads, so between fork and exec the child makes
// only async-signal-safe calls: it allocates, locks, and logs nothing, and every
// failure leaves through _exit, which runs no atexit handler and flushes no stdio.
tool_spawn_grouped :: proc(shell, command, directory: string, stdout_write, stderr_write: ^os.File) -> (child: Tool_Child, spawn: Tool_Spawn, err: os.Error) {
	// The C strings live only as long as the spawn: exec takes its own copy of the
	// arguments, so the parent releases its own when the call returns.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	shell_cstring := strings.clone_to_cstring(shell, context.temp_allocator) or_return
	source := strings.clone_to_cstring(command, context.temp_allocator) or_return
	work := strings.clone_to_cstring(directory, context.temp_allocator) or_return
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
	argv[count] = "-c"
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
	// started. Both ends close on exec, so a successful exec closes the child's
	// write end and the parent reads end-of-file, while a failed one lets the
	// child report its errno before it exits.
	exec_read, exec_write := os.pipe() or_return
	defer _ = os.close(exec_read)
	report_fd := tool_fd(exec_write)
	child_stdout, child_stderr := tool_fd(stdout_write), tool_fd(stderr_write)

	pid := posix.fork()
	if pid == -1 {
		_ = os.close(exec_write)
		return {}, .Failed, tool_errno()
	}
	if pid == 0 {
		// Standard input is closed: this is explicitly not a terminal.
		if posix.setpgid(0, 0) != .OK { posix._exit(TOOL_CHILD_SETUP_FAILED) }
		_ = posix.close(0)
		if posix.dup2(child_stdout, 1) == -1 { posix._exit(TOOL_CHILD_SETUP_FAILED) }
		if posix.dup2(child_stderr, 2) == -1 { posix._exit(TOOL_CHILD_SETUP_FAILED) }
		// Every pipe end closes on exec: os.pipe creates them that way.
		if posix.chdir(work) != .OK { posix._exit(TOOL_CHILD_SETUP_FAILED) }
		posix.execve(shell_cstring, &argv[0], envp)
		reported := [1]u8{u8(posix.errno())}
		_ = posix.write(report_fd, &reported[0], len(reported))
		posix._exit(TOOL_CHILD_EXEC_FAILED)
	}
	_ = os.close(exec_write)
	child.pid = int(pid)

	// The watch is taken before the report is read: the child cannot be reaped
	// before then, so the pid still names it.
	child.exit, err = tool_exit_watch_open(child.pid)
	if err != nil {
		tool_terminate_group(&child)
		return {}, .Failed, err
	}

	reported: [1]u8
	read_bytes, read_status := tool_read(exec_read, reported[:])
	for read_status == .Again {
		read_bytes, read_status = tool_read(exec_read, reported[:])
	}
	// Only the report says the exec failed. End-of-file means the child exec'd or
	// died before it could report, and a read that failed says nothing either; in
	// both cases the command may have run, so the child counts as started and the
	// caller waits for it the way it waits for any child.
	if read_status != .Ok || read_bytes == 0 { return child, .Started, nil }

	// The child never became the shell. Reap it here, so it leaves no zombie and
	// no pid a caller could mistake for a running command.
	_, _, _ = tool_child_reap(&child)
	tool_child_close(&child)
	return {}, .Exec_Failed, os.Platform_Error(i32(reported[0]))
}

// tool_child_close releases the exit watch. The child must already be reaped.
tool_child_close :: proc(child: ^Tool_Child) {
	tool_exit_watch_close(&child.exit)
}

// Tool_Read is the outcome of one read on a pipe end.
Tool_Read :: enum {
	// Ok read the reported count of bytes; zero bytes is end of stream.
	Ok,
	// Again read nothing: the end was not ready or a signal interrupted the call.
	Again,
	Failed,
}

@(private)
tool_fd :: proc(file: ^os.File) -> posix.FD {
	return posix.FD(os.fd(file))
}

// tool_errno is the calling thread's last POSIX error as an os.Error.
@(private)
tool_errno :: proc() -> os.Error {
	return os.Platform_Error(i32(posix.errno()))
}

// tool_read reads what one pipe end holds into buffer.
tool_read :: proc(file: ^os.File, buffer: []u8) -> (count: int, status: Tool_Read) {
	n := posix.read(tool_fd(file), raw_data(buffer), uint(len(buffer)))
	if n >= 0 { return n, .Ok }
	#partial switch posix.errno() {
	case .EAGAIN, .EINTR:
		return 0, .Again
	}
	return 0, .Failed
}

// tool_poll blocks until one of fds is ready or the deadline passes, and never
// wakes on its own otherwise. A signal restarts the wait with the time left.
@(private)
tool_poll :: proc(fds: []posix.pollfd, deadline: time.Tick, has_deadline: bool) -> os.Error {
	for {
		timeout: i32 = -1
		if has_deadline {
			remaining := time.tick_diff(time.tick_now(), deadline)
			timeout = remaining <= 0 ? 0 : i32(min((remaining + time.Millisecond - 1) / time.Millisecond, time.Duration(max(i32))))
		}
		if posix.poll(raw_data(fds), posix.nfds_t(len(fds)), timeout) != -1 { return nil }
		if posix.errno() != .EINTR { return tool_errno() }
	}
}

// tool_child_record keeps the exit state a wait reported.
@(private)
tool_child_record :: proc(child: ^Tool_Child, status: i32) {
	child.reaped = true
	child.status_known = true
	child.exited = posix.WIFEXITED(status)
	if child.exited { child.exit_code = int(posix.WEXITSTATUS(status)) }
}

// tool_child_poll reports whether the child has finished, reaping it if it has.
// It never blocks.
tool_child_poll :: proc(child: ^Tool_Child) -> bool {
	if child.reaped { return true }
	status: i32
	reaped := posix.waitpid(posix.pid_t(child.pid), &status, {.NOHANG})
	if int(reaped) == child.pid {
		tool_child_record(child, status)
		return true
	}
	// No child left to wait for: it was already reaped.
	if reaped == -1 && posix.errno() == .ECHILD { child.reaped = true }
	return child.reaped
}

// tool_child_reap blocks until the child is reaped and reports its exit state. A
// process killed by a signal did not exit, so exited is false.
tool_child_reap :: proc(child: ^Tool_Child) -> (exited: bool, exit_code: int, waited: bool) {
	if child.reaped { return child.exited, child.exit_code, child.status_known }
	status: i32
	for {
		if int(posix.waitpid(posix.pid_t(child.pid), &status, {})) == child.pid { break }
		errno := posix.errno()
		if errno == .ECHILD {
			child.reaped = true
			return false, 0, false
		}
		if errno != .EINTR { return false, 0, false }
	}
	tool_child_record(child, status)
	return child.exited, child.exit_code, true
}

// tool_child_await blocks until the child exits or deadline passes, and reaps it
// if it exited.
@(private)
tool_child_await :: proc(child: ^Tool_Child, deadline: time.Tick) {
	if !child.exit.open { return }
	for !tool_child_poll(child) && time.tick_diff(time.tick_now(), deadline) > 0 {
		fds := [1]posix.pollfd{{fd = tool_exit_watch_fd(child.exit), events = {.IN}}}
		if tool_poll(fds[:], deadline, true) != nil { return }
	}
}

// tool_control_fds appends the descriptors a stop wakes to fds: the call's wake,
// when it has one.
@(private)
tool_control_fds :: proc(fds: []posix.pollfd, control: Tool_Control) -> int {
	if control.wake == nil { return 0 }
	fds[0] = {
		fd     = tool_fd(control.wake),
		events = {.IN},
	}
	return 1
}

// tool_retire_child waits for the child to exit without ever blocking
// unobservably. Pipes may close early while the child still sleeps, so the wait
// also wakes on a stop and ends at the deadline. Background descendants are not
// waited for: they only keep pipes open, and the caller closes those pipes on
// return.
tool_retire_child :: proc(child: ^Tool_Child, start: time.Tick, budget: time.Duration, control: Tool_Control) -> (Tool_Stop, os.Error) {
	deadline := time.tick_add(start, budget)
	for !tool_child_poll(child) {
		if stop := tool_control_stop(control, start, budget); stop != .None {
			tool_terminate_group(child)
			return stop, nil
		}
		fds: [2]posix.pollfd
		fds[0] = {
			fd     = tool_exit_watch_fd(child.exit),
			events = {.IN},
		}
		count := 1 + tool_control_fds(fds[1:], control)
		if err := tool_poll(fds[:count], deadline, budget > 0); err != nil {
			tool_terminate_group(child)
			return .Wait_Failed, err
		}
	}
	return .None, nil
}

// Tool_Stream is one captured output stream while it is drained.
@(private)
Tool_Stream :: struct {
	file:      ^os.File,
	limit:     int,
	kept:      ^string,
	truncated: ^bool,
	open:      bool,
}

// tool_drain_pipes reads both pipes to end of stream and reports why draining
// stopped. It sleeps until a pipe has data, the child exits, the call is stopped,
// or the deadline passes, and never reads one pipe to EOF before the other, so a
// child cannot deadlock on a full pipe. Termination and reaping happen here, so
// the caller only ever sees a finished process.
tool_drain_pipes :: proc(
	child: ^Tool_Child,
	stdout_read, stderr_read: ^os.File,
	start: time.Tick,
	budget: time.Duration,
	control: Tool_Control,
	data: ^Shell_Data,
	allocator: mem.Allocator,
) -> (
	Tool_Stop,
	os.Error,
) {
	deadline := time.tick_add(start, budget)
	streams := [2]Tool_Stream {
		{file = stdout_read, limit = TOOL_MAX_STDOUT_BYTES, kept = &data.stdout, truncated = &data.stdout_truncated, open = true},
		{file = stderr_read, limit = TOOL_MAX_STDERR_BYTES, kept = &data.stderr, truncated = &data.stderr_truncated, open = true},
	}
	scratch: [4096]u8
	for streams[0].open || streams[1].open {
		// One check covers both stops, and cancellation wins: a cancelled turn
		// is never reported as a timeout.
		if stop := tool_control_stop(control, start, budget); stop != .None {
			tool_terminate_group(child)
			return stop, nil
		}
		fds: [4]posix.pollfd
		slots := [2]int{-1, -1}
		count := 0
		for stream, index in streams {
			if !stream.open { continue }
			slots[index] = count
			fds[count] = {
				fd     = tool_fd(stream.file),
				events = {.IN},
			}
			count += 1
		}
		exit_slot := count
		fds[count] = {
			fd     = tool_exit_watch_fd(child.exit),
			events = {.IN},
		}
		count += 1
		count += tool_control_fds(fds[count:], control)
		if err := tool_poll(fds[:count], deadline, budget > 0); err != nil {
			tool_terminate_group(child)
			return .Wait_Failed, err
		}

		progress := false
		for &stream, index in streams {
			if slots[index] < 0 || fds[slots[index]].revents == {} { continue }
			progress = true
			n, status := tool_read(stream.file, scratch[:])
			switch status {
			case .Again:
			case .Failed:
				stream.open = false
			case .Ok:
				if n == 0 {
					stream.open = false
				} else {
					tool_append_bounded(stream.kept, stream.truncated, scratch[:n], stream.limit, allocator)
				}
			}
		}
		// Only a descendant of an exited child could still hold a pipe open, and
		// background jobs are unsupported, so the child's exit ends the drain once
		// the pipes are quiet rather than waiting out the whole budget.
		if !progress && fds[exit_slot].revents != {} { break }
	}
	return tool_retire_child(child, start, budget, control)
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

// tool_terminate_group asks the whole tree to stop, waits up to the grace period
// for the direct child to exit, then kills whatever of the group is left and reaps
// the child. A process that ignores SIGTERM is why the escalation exists;
// descendants are why the signals go to the group.
tool_terminate_group :: proc(child: ^Tool_Child) {
	if child.pid <= 0 { return }
	group := posix.pid_t(child.pid)
	_ = posix.killpg(group, .SIGTERM)
	tool_child_await(child, time.tick_add(time.tick_now(), TOOL_KILL_GRACE))
	_ = posix.killpg(group, .SIGKILL)
	if !child.reaped { _ = posix.kill(group, .SIGKILL) }
	_, _, _ = tool_child_reap(child)
}
