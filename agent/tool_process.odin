package agent

import "base:runtime"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

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

// Tool_Fd is an operating-system descriptor number, the neutral form of what os.fd reports.
Tool_Fd :: distinct int

// TOOL_FD_NONE names no descriptor.
TOOL_FD_NONE :: Tool_Fd(-1)

// Tool_Poll is one descriptor of a readiness wait. ready is set by tool_poll_wait when the
// descriptor has data to read, reached its end, or failed, so a read on it will not block.
Tool_Poll :: struct {
	fd:    Tool_Fd,
	ready: bool,
}

// Tool_Exit_Watch is a descriptor that becomes readable once a child exits, so a
// wait for the child joins the same poll as its pipes. Its zero value watches
// nothing.
Tool_Exit_Watch :: struct {
	fd:   Tool_Fd,
	open: bool,
}

// Tool_Wait is what a wait on a child found. Running also covers a wait the system
// refused, which leaves the child's state unknown.
Tool_Wait :: enum {
	Running,
	Finished,
	Gone,
}

// Tool_Group_Signal is the signal sent to a process group.
Tool_Group_Signal :: enum {
	Terminate,
	Kill,
}

// Tool_Exec describes the command a forked child runs. argv and envp end in a nil entry.
// report is the descriptor the child writes one errno byte to when exec fails.
Tool_Exec :: struct {
	argv:         []cstring,
	envp:         []cstring,
	directory:    cstring,
	input:        Tool_Fd,
	output:       Tool_Fd,
	errors:       Tool_Fd,
	report:       Tool_Fd,
	parent_death: bool,
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
tool_spawn_shell_flags :: proc(shell: string) -> cstring {
	if os.base(shell) == "fish" { return cstring("--private") }
	return nil
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
// failure leaves through exit_group, which runs no atexit handler and flushes no stdio.
@(require_results)
tool_spawn_grouped :: proc(shell, command, directory: string, stdout_write, stderr_write: ^os.File) -> (child: Tool_Child, spawn: Tool_Spawn, err: os.Error) {
	arguments, arguments_error := make([dynamic]string, 0, 4, context.temp_allocator)
	if arguments_error != nil { return {}, .Failed, arguments_error }
	append(&arguments, shell) or_return
	if flag := tool_spawn_shell_flags(shell); flag != nil { append(&arguments, string(flag)) or_return }
	append(&arguments, "-c", command) or_return
	return tool_spawn_command(arguments[:], directory, nil, stdout_write, stderr_write)
}

// tool_spawn_command execs an argv in a private process group. A nil input closes stdin.
// parent_death binds the child's lifetime to this supervising thread on Linux.
@(require_results)
tool_spawn_command :: proc(
	arguments: []string,
	directory: string,
	input, stdout_write, stderr_write: ^os.File,
	parent_death := false,
) -> (
	child: Tool_Child,
	spawn: Tool_Spawn,
	err: os.Error,
) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if len(arguments) == 0 { return {}, .Failed, os.General_Error.Invalid_Command }
	argv, argv_error := make([]cstring, len(arguments) + 1, context.temp_allocator)
	if argv_error != nil { return {}, .Failed, argv_error }
	for argument, index in arguments {
		argument_text, argument_error := strings.clone_to_cstring(argument, context.temp_allocator)
		if argument_error != nil { return {}, .Failed, argument_error }
		argv[index] = argument_text
	}
	work, directory_error := strings.clone_to_cstring(directory, context.temp_allocator)
	if directory_error != nil { return {}, .Failed, directory_error }

	// The command inherits this process's environment: the user's own, as the shell
	// that launched the harness exported it. Nothing is added, removed, or rewritten
	// here, because a tool the user can run is a tool the command has to be able to
	// run. core:os keeps its cstring export private, so the list comes from
	// os.environ and is converted here, before the fork, because the child may not
	// allocate.
	environment, environment_error := os.environ(context.temp_allocator)
	if environment_error != nil { return {}, .Failed, environment_error }
	envp, envp_error := make([]cstring, len(environment) + 1, context.temp_allocator)
	if envp_error != nil { return {}, .Failed, envp_error }
	for entry, index in environment {
		entry_text, entry_error := strings.clone_to_cstring(entry, context.temp_allocator)
		if entry_error != nil { return {}, .Failed, entry_error }
		envp[index] = entry_text
	}

	// The exec status pipe carries one fact back to the parent: whether the shell
	// started. Both ends close on exec, so a successful exec closes the child's
	// write end and the parent reads end-of-file, while a failed one lets the
	// child report its errno before it exits.
	exec_read, exec_write, pipe_error := os.pipe()
	if pipe_error != nil { return {}, .Failed, pipe_error }
	defer _ = os.close(exec_read)
	child_input := TOOL_FD_NONE
	if input != nil { child_input = tool_fd(input) }

	pid, fork_error := tool_fork_exec(
		{
			argv = argv,
			envp = envp,
			directory = work,
			input = child_input,
			output = tool_fd(stdout_write),
			errors = tool_fd(stderr_write),
			report = tool_fd(exec_write),
			parent_death = parent_death,
		},
	)
	if fork_error != nil {
		_ = os.close(exec_write)
		return {}, .Failed, fork_error
	}
	_ = os.close(exec_write)
	child.pid = pid

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
tool_fd :: proc(file: ^os.File) -> Tool_Fd {
	return Tool_Fd(os.fd(file))
}

// tool_read reads what one pipe end holds into buffer.
tool_read :: proc(file: ^os.File, buffer: []u8) -> (count: int, status: Tool_Read) {
	n, err := os.read(file, buffer)
	if err == nil || err == io.Error.EOF { return n, .Ok }
	if tool_error_again(err) { return 0, .Again }
	return 0, .Failed
}

// tool_poll blocks until one of fds is ready or the deadline passes, and never
// wakes on its own otherwise. A signal restarts the wait with the time left.
@(private, require_results)
tool_poll :: proc(fds: []Tool_Poll, deadline: time.Tick, has_deadline: bool) -> os.Error {
	for {
		timeout: i32 = -1
		if has_deadline {
			remaining := time.tick_diff(time.tick_now(), deadline)
			timeout = remaining <= 0 ? 0 : i32(min((remaining + time.Millisecond - 1) / time.Millisecond, time.Duration(max(i32))))
		}
		interrupted, err := tool_poll_wait(fds, timeout)
		if !interrupted { return err }
	}
}

// tool_child_record keeps the exit state a wait reported.
@(private)
tool_child_record :: proc(child: ^Tool_Child, exited: bool, exit_code: int) {
	child.reaped = true
	child.status_known = true
	child.exited = exited
	if exited { child.exit_code = exit_code }
}

// tool_child_poll reports whether the child has finished, reaping it if it has.
// It never blocks.
@(require_results)
tool_child_poll :: proc(child: ^Tool_Child) -> bool {
	if child.reaped { return true }
	switch wait, exited, exit_code := tool_child_wait(child.pid, false); wait {
	case .Finished:
		tool_child_record(child, exited, exit_code)
	case .Gone:
		// No child left to wait for: it was already reaped.
		child.reaped = true
	case .Running:
	}
	return child.reaped
}

// tool_child_reap blocks until the child is reaped and reports its exit state. A
// process killed by a signal did not exit, so exited is false.
@(require_results)
tool_child_reap :: proc(child: ^Tool_Child) -> (exited: bool, exit_code: int, waited: bool) {
	if child.reaped { return child.exited, child.exit_code, child.status_known }
	switch wait, child_exited, child_exit_code := tool_child_wait(child.pid, true); wait {
	case .Finished:
		tool_child_record(child, child_exited, child_exit_code)
		return child.exited, child.exit_code, true
	case .Gone:
		child.reaped = true
	case .Running:
	}
	return false, 0, false
}

// tool_child_await blocks until the child exits or deadline passes, and reaps it
// if it exited.
@(private)
tool_child_await :: proc(child: ^Tool_Child, deadline: time.Tick) {
	if !child.exit.open { return }
	for !tool_child_poll(child) && time.tick_diff(time.tick_now(), deadline) > 0 {
		fds := [1]Tool_Poll{{fd = child.exit.fd}}
		if tool_poll(fds[:], deadline, true) != nil { return }
	}
}

// tool_control_fds appends the descriptors a stop wakes to fds: the call's wake,
// when it has one.
@(private)
tool_control_fds :: proc(fds: []Tool_Poll, control: Tool_Control) -> int {
	if control.wake == nil { return 0 }
	fds[0] = {
		fd = tool_fd(control.wake),
	}
	return 1
}

// tool_retire_child waits for the child to exit without ever blocking
// unobservably. Pipes may close early while the child still sleeps, so the wait
// also wakes on a stop and ends at the deadline. After normal exit, remaining
// process-group members are terminated through the same escalation path.
@(require_results)
tool_retire_child :: proc(child: ^Tool_Child, start: time.Tick, budget: time.Duration, control: Tool_Control) -> (Tool_Stop, os.Error, bool) {
	deadline := time.tick_add(start, budget)
	for !tool_child_poll(child) {
		if stop := tool_control_stop(control, start, budget); stop != .None {
			_ = tool_terminate_group(child)
			return stop, nil, false
		}
		fds: [2]Tool_Poll
		fds[0] = {
			fd = child.exit.fd,
		}
		count := 1 + tool_control_fds(fds[1:], control)
		if err := tool_poll(fds[:count], deadline, budget > 0); err != nil {
			_ = tool_terminate_group(child)
			return .Wait_Failed, err, false
		}
	}
	return .None, nil, tool_terminate_group(child)
}

// TOOL_STREAM_MEMORY_BYTES is how much of one output stream is held in memory. A stream
// that grows past it is written whole to its spool file as it arrives, and only its
// beginning stays in memory, so a command that prints without end cannot exhaust memory.
TOOL_STREAM_MEMORY_BYTES :: 1024 * 1024

// TOOL_STREAM_READ_BYTES is the fixed read buffer size, not an output limit.
TOOL_STREAM_READ_BYTES :: 4096

// TOOL_STREAM_SANITIZE_BYTES holds three replacement bytes per byte read, plus a partial UTF-8 sequence.
TOOL_STREAM_SANITIZE_BYTES :: 3 * (TOOL_STREAM_READ_BYTES + 3)

TOOL_STREAM_REPLACEMENT :: "\ufffd"

// Tool_Stream is one captured output stream while it is drained. kept holds the whole
// stream until it outgrows memory, and its beginning after that. spool_path names the
// file the whole stream goes to then; "" means the stream stays in memory whatever its size.
@(private)
Tool_Stream :: struct {
	file:        ^os.File,
	kept:        [dynamic]u8,
	open:        bool,
	total:       int,
	spool_path:  string,
	spool:       ^os.File,
	pending:     [3]u8,
	pending_len: int,
	invalid_run: bool,
}

// tool_stream_take sanitizes one chunk, then adds those same bytes to memory and any spool.
@(private, require_results)
tool_stream_take :: proc(stream: ^Tool_Stream, chunk: []u8) -> os.Error {
	stream.total += len(chunk)
	sanitized: [TOOL_STREAM_SANITIZE_BYTES]u8
	sanitized_len := tool_stream_sanitize(stream, chunk, false, sanitized[:])
	return tool_stream_write(stream, sanitized[:sanitized_len])
}

// tool_stream_finish writes an incomplete final UTF-8 sequence as replacement text.
@(private, require_results)
tool_stream_finish :: proc(stream: ^Tool_Stream) -> os.Error {
	sanitized: [TOOL_STREAM_SANITIZE_BYTES]u8
	sanitized_len := tool_stream_sanitize(stream, nil, true, sanitized[:])
	return tool_stream_write(stream, sanitized[:sanitized_len])
}

// tool_stream_sanitize replaces invalid UTF-8 and disallowed control bytes, carrying a partial rune into the next chunk.
@(private)
tool_stream_sanitize :: proc(stream: ^Tool_Stream, chunk: []u8, final: bool, output: []u8) -> int {
	assert(len(chunk) <= TOOL_STREAM_READ_BYTES)
	combined: [TOOL_STREAM_READ_BYTES + 3]u8
	combined_len := stream.pending_len + len(chunk)
	copy(combined[:], stream.pending[:stream.pending_len])
	copy(combined[stream.pending_len:combined_len], chunk)
	stream.pending_len = 0

	process_len := combined_len
	if !final {
		pending_len := tool_stream_incomplete_utf8_suffix(combined[:combined_len])
		process_len -= pending_len
		stream.pending_len = pending_len
		copy(stream.pending[:pending_len], combined[process_len:combined_len])
	}

	output_len := 0
	for index := 0; index < process_len; {
		rune, width := utf8.decode_rune_in_bytes(combined[index:process_len])
		invalid := rune == utf8.RUNE_ERROR && width == 1
		if invalid {
			if !stream.invalid_run {
				copy(output[output_len:], TOOL_STREAM_REPLACEMENT)
				output_len += len(TOOL_STREAM_REPLACEMENT)
			}
			stream.invalid_run = true
			index += width
			continue
		}

		stream.invalid_run = false
		breaks := rune == utf8.RUNE_ERROR || rune < 0x20 && rune != '\n' && rune != '\t' || rune == 0x7F
		if breaks {
			copy(output[output_len:], TOOL_STREAM_REPLACEMENT)
			output_len += len(TOOL_STREAM_REPLACEMENT)
		} else {
			copy(output[output_len:], combined[index:index + width])
			output_len += width
		}
		index += width
	}
	return output_len
}

// tool_stream_incomplete_utf8_suffix retains an incomplete final rune without buffering invalid encodings.
@(private)
tool_stream_incomplete_utf8_suffix :: proc(bytes: []u8) -> int {
	for distance := 0; distance < len(bytes) && distance <= 3; distance += 1 {
		start := len(bytes) - distance - 1
		if !utf8.rune_start(bytes[start]) { continue }
		if !utf8.full_rune(bytes[start:]) { return len(bytes) - start }
		return 0
	}
	return 0
}

// tool_stream_write stores sanitized bytes in memory and, once the threshold is crossed, in a spool.
@(private, require_results)
tool_stream_write :: proc(stream: ^Tool_Stream, chunk: []u8) -> os.Error {
	if stream.spool == nil && stream.spool_path != "" && len(stream.kept) + len(chunk) > TOOL_STREAM_MEMORY_BYTES {
		spool, open_error := tool_output_create(stream.spool_path)
		// A result is never discarded, so a failed spool open keeps the stream in memory.
		if open_error == nil {
			stream.spool = spool
			os.write(spool, stream.kept[:]) or_return
		}
	}
	if stream.spool == nil {
		_, append_error := append(&stream.kept, ..chunk)
		return append_error
	}
	os.write(stream.spool, chunk) or_return
	head := min(len(chunk), TOOL_STREAM_MEMORY_BYTES - len(stream.kept))
	if head > 0 {
		_, append_error := append(&stream.kept, ..chunk[:head])
		return append_error
	}
	return nil
}

// tool_stream_finish_all flushes partial UTF-8 suffixes before a drain result transfers the streams.
@(private, require_results)
tool_stream_finish_all :: proc(streams: []Tool_Stream) -> os.Error {
	for &stream in streams {
		tool_stream_finish(&stream) or_return
	}
	return nil
}

// tool_drain_pipes reads both pipes to end of stream and reports why draining
// stopped. It sleeps until a pipe has data, the child exits, the call is stopped,
// or the deadline passes, and never reads one pipe to EOF before the other, so a
// child cannot deadlock on a full pipe. Termination and reaping happen here, so
// the caller only ever sees a finished process.
@(require_results)
tool_drain_pipes :: proc(
	child: ^Tool_Child,
	stdout_read, stderr_read: ^os.File,
	start: time.Tick,
	budget: time.Duration,
	control: Tool_Control,
	data: ^Shell_Output,
	spool_base: string,
	allocator: mem.Allocator,
) -> (
	stop: Tool_Stop,
	wait_error: os.Error,
	background_terminated: bool,
) {
	deadline := time.tick_add(start, budget)
	streams := [2]Tool_Stream{{file = stdout_read, open = true}, {file = stderr_read, open = true}}
	// Both buffers, and both spool paths, are made before the defer that hands them to the
	// result, so a failure here releases what it made itself.
	allocation_error: os.Error
	for &stream in streams {
		stream.kept, allocation_error = make([dynamic]u8, allocator)
		if allocation_error != nil { break }
	}
	if spool_base != "" {
		if allocation_error == nil {
			streams[0].spool_path, allocation_error = strings.concatenate({spool_base, ".stdout.txt"}, allocator)
		}
		if allocation_error == nil {
			streams[1].spool_path, allocation_error = strings.concatenate({spool_base, ".stderr.txt"}, allocator)
		}
	}
	if allocation_error != nil {
		for &stream in streams {
			delete(stream.kept)
			delete(stream.spool_path, allocator)
		}
		return .Wait_Failed, allocation_error, false
	}
	// Everything the command wrote is kept, whatever the drain ends with.
	defer {
		data.stdout = string(streams[0].kept[:])
		data.stderr = string(streams[1].kept[:])
		data.stdout_bytes = streams[0].total
		data.stderr_bytes = streams[1].total
		// A stream that never outgrew memory has no file, so its name is released here and the
		// result takes the name of the file that does hold the whole stream.
		files := [2]^string{&data.stdout_file, &data.stderr_file}
		for stream, index in streams {
			if stream.spool != nil {
				_ = os.close(stream.spool)
				files[index]^ = stream.spool_path
			} else {
				delete(stream.spool_path, allocator)
			}
		}
	}
	scratch: [TOOL_STREAM_READ_BYTES]u8
	drain: for streams[0].open || streams[1].open {
		// One check covers both stops, and cancellation wins: a cancelled turn
		// is never reported as a timeout.
		if stop_reason := tool_control_stop(control, start, budget); stop_reason != .None {
			stop = stop_reason
			break
		}
		fds: [4]Tool_Poll
		slots := [2]int{-1, -1}
		count := 0
		for stream, index in streams {
			if !stream.open { continue }
			slots[index] = count
			fds[count] = {
				fd = tool_fd(stream.file),
			}
			count += 1
		}
		exit_slot := count
		fds[count] = {
			fd = child.exit.fd,
		}
		count += 1
		count += tool_control_fds(fds[count:], control)
		if err := tool_poll(fds[:count], deadline, budget > 0); err != nil {
			stop, wait_error = .Wait_Failed, err
			break
		}

		progress := false
		for &stream, index in streams {
			if slots[index] < 0 || !fds[slots[index]].ready { continue }
			progress = true
			n, status := tool_read(stream.file, scratch[:])
			if status == .Again { continue }
			if status == .Failed || n == 0 {
				stream.open = false
				wait_error = tool_stream_finish(&stream)
			} else {
				wait_error = tool_stream_take(&stream, scratch[:n])
			}
			if wait_error != nil {
				stop = .Wait_Failed
				break drain
			}
		}
		// An exited leader cannot write to a quiet pipe. Retire its group instead
		// of waiting until a background process closes the pipe.
		if !progress && fds[exit_slot].ready { break }
	}
	if stop != .None { _ = tool_terminate_group(child) }
	if finish_error := tool_stream_finish_all(streams[:]); finish_error != nil {
		if stop == .None { _ = tool_terminate_group(child) }
		stop, wait_error = .Wait_Failed, finish_error
	}
	if stop != .None { return stop, wait_error, false }
	return tool_retire_child(child, start, budget, control)
}

// tool_terminate_group asks the whole tree to stop, waits up to the grace period
// for the direct child to exit, then kills whatever of the group is left and reaps
// the child. It reports group members signalled after the direct child was reaped.
tool_terminate_group :: proc(child: ^Tool_Child) -> bool {
	if child.pid <= 0 { return false }
	term_sent := tool_group_signal(child.pid, .Terminate)
	was_reaped := child.reaped
	tool_child_await(child, time.tick_add(time.tick_now(), TOOL_KILL_GRACE))
	if was_reaped && term_sent {
		// A reaped leader cannot keep its group alive, so a successful group signal
		// means a background member remains. Give it the same TERM grace as the child path.
		no_fds: []Tool_Poll
		_ = tool_poll(no_fds, time.tick_add(time.tick_now(), TOOL_KILL_GRACE), true)
	}
	_ = tool_group_signal(child.pid, .Kill)
	if !child.reaped { _ = os.process_kill({pid = child.pid}) }
	_, _, _ = tool_child_reap(child)
	return was_reaped && term_sent
}
