package agent

import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "nabla:agent/journal"
import "nabla:subprocess"

// Tool_Stop is why a drain loop stopped short of the child exiting on its own.
// Wait_Failed means the system refused the wait itself, so the child was stopped
// because nothing could observe it any more.
Tool_Stop :: enum {
	None,
	Cancelled,
	Timed_Out,
	Wait_Failed,
}

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
tool_spawn_grouped :: proc(
	shell, command, directory: string,
	stdout_write, stderr_write: ^os.File,
) -> (
	child: subprocess.Child,
	spawn: subprocess.Spawn,
	err: os.Error,
) {
	arguments, arguments_error := make([dynamic]string, 0, 4, context.temp_allocator)
	if arguments_error != nil { return {}, .Failed, arguments_error }
	append(&arguments, shell) or_return
	if flag := tool_spawn_shell_flags(shell); flag != nil { append(&arguments, string(flag)) or_return }
	append(&arguments, "-c", command) or_return
	return tool_spawn_command(arguments[:], directory, nil, stdout_write, stderr_write)
}

// tool_spawn_command starts an argv in a private process group with this process's environment. A nil
// input closes stdin. parent_death binds the child's lifetime to this supervising thread on Linux.
@(require_results)
tool_spawn_command :: proc(
	arguments: []string,
	directory: string,
	input, stdout_write, stderr_write: ^os.File,
	parent_death := false,
) -> (
	child: subprocess.Child,
	spawn: subprocess.Spawn,
	err: os.Error,
) {
	// The command inherits this process's environment: the user's own, as the shell that launched
	// the harness exported it. Nothing is added, removed, or rewritten here, because a tool the
	// user can run is a tool the command has to be able to run.
	environment, environment_error := os.environ(context.temp_allocator)
	if environment_error != nil { return {}, .Failed, environment_error }
	return subprocess.start(
		{
			argv = arguments,
			environment = environment,
			directory = directory,
			stdin = input,
			stdout = stdout_write,
			stderr = stderr_write,
			parent_death = parent_death,
		},
	)
}

// tool_control_fds appends the descriptors a stop wakes to fds: the call's wake,
// when it has one.
@(private)
tool_control_fds :: proc(fds: []subprocess.Poll, control: Tool_Control) -> int {
	if control.wake == nil { return 0 }
	fds[0] = {
		fd = subprocess.fd(control.wake),
	}
	return 1
}

// tool_retire_child waits for the child to exit without ever blocking
// unobservably. Pipes may close early while the child still sleeps, so the wait
// also wakes on a stop and ends at the deadline. After normal exit, remaining
// process-group members are terminated through the same escalation path.
@(require_results)
tool_retire_child :: proc(child: ^subprocess.Child, start: time.Tick, budget: time.Duration, control: Tool_Control) -> (Tool_Stop, os.Error, bool) {
	deadline := time.tick_add(start, budget)
	for !subprocess.child_poll(child) {
		if stop := tool_control_stop(control, start, budget); stop != .None {
			_ = subprocess.terminate_group(child)
			return stop, nil, false
		}
		fds: [2]subprocess.Poll
		fds[0] = {
			fd = child.exit,
		}
		count := 1 + tool_control_fds(fds[1:], control)
		if err := subprocess.poll(fds[:count], deadline, budget > 0); err != nil {
			_ = subprocess.terminate_group(child)
			return .Wait_Failed, err, false
		}
	}
	return .None, nil, subprocess.terminate_group(child)
}

// TOOL_STREAM_MEMORY_BYTES is how much of one output stream is held in memory. Every
// stream is also written to its spool file as it arrives; once a stream grows past the
// limit only its beginning stays in memory, so a command that prints without end cannot
// exhaust memory.
TOOL_STREAM_MEMORY_BYTES :: 1024 * 1024

// TOOL_STREAM_READ_BYTES is the fixed read buffer size, not an output limit.
TOOL_STREAM_READ_BYTES :: 4096

// TOOL_STREAM_SANITIZE_BYTES holds three replacement bytes per byte read, plus a partial UTF-8 sequence.
TOOL_STREAM_SANITIZE_BYTES :: 3 * (TOOL_STREAM_READ_BYTES + 3)

TOOL_STREAM_REPLACEMENT :: "\ufffd"

// Tool_Stream is one captured output stream while it is drained. kept holds the whole
// stream until it outgrows memory, and its beginning after that. spool_path names the
// file the whole stream goes to from the start, so an interrupted call leaves what it
// wrote; "" means the stream stays in memory whatever its size. overflow is set once the
// stream has bytes beyond kept, which makes the spool file the only whole copy.
@(private)
Tool_Stream :: struct {
	file:        ^os.File,
	kept:        [dynamic]u8,
	open:        bool,
	overflow:    bool,
	total:       int,
	spool_path:  string,
	spool:       ^os.File,
	pending:     [3]u8,
	pending_len: int,
	invalid_run: bool,
}

// tool_stream_take sanitizes one chunk, then adds those same bytes to memory and any spool.
// Those same sanitized bytes, when there are any, go to sink.report after the write, and
// the sink never changes the result.
@(private, require_results)
tool_stream_take :: proc(stream: ^Tool_Stream, chunk: []u8, sink := Tool_Stream_Sink{}) -> os.Error {
	stream.total += len(chunk)
	sanitized: [TOOL_STREAM_SANITIZE_BYTES]u8
	sanitized_len := tool_stream_sanitize(stream, chunk, false, sanitized[:])
	write_error := tool_stream_write(stream, sanitized[:sanitized_len])
	if sink.report != nil && sanitized_len > 0 {
		sink.report(sink.user_data, sink.call, sink.parent_call, string(sanitized[:sanitized_len]))
	}
	return write_error
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

// tool_stream_write stores sanitized bytes in the spool when there is one, and in memory up to the threshold.
@(private, require_results)
tool_stream_write :: proc(stream: ^Tool_Stream, chunk: []u8) -> os.Error {
	if stream.spool == nil {
		_, append_error := append(&stream.kept, ..chunk)
		return append_error
	}
	// A failed spool write leaves the stream in memory, because a result is never discarded
	// and a full disk must not end the command.
	if _, write_error := os.write(stream.spool, chunk); write_error != nil {
		_ = os.close(stream.spool)
		stream.spool = nil
		if !stream.overflow { _ = os.remove(stream.spool_path) }
		_, append_error := append(&stream.kept, ..chunk)
		return append_error
	}
	head := min(len(chunk), TOOL_STREAM_MEMORY_BYTES - len(stream.kept))
	if head < len(chunk) { stream.overflow = true }
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
	child: ^subprocess.Child,
	stdout_read, stderr_read: ^os.File,
	start: time.Tick,
	budget: time.Duration,
	control: Tool_Control,
	data: ^Shell_Output,
	spool_base: string,
	sink: Tool_Stream_Sink,
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
			streams[0].spool_path, allocation_error = strings.concatenate({spool_base, journal.KEPT_STDOUT_SUFFIX}, allocator)
		}
		if allocation_error == nil {
			streams[1].spool_path, allocation_error = strings.concatenate({spool_base, journal.KEPT_STDERR_SUFFIX}, allocator)
		}
	}
	if allocation_error != nil {
		for &stream in streams {
			delete(stream.kept)
			delete(stream.spool_path, allocator)
		}
		return .Wait_Failed, allocation_error, false
	}
	// A failed open keeps the stream in memory, because a result is never discarded.
	for &stream in streams {
		if stream.spool_path == "" { continue }
		spool, open_error := tool_output_create(stream.spool_path)
		if open_error == nil { stream.spool = spool }
	}
	// Everything the command wrote is kept, whatever the drain ends with.
	defer {
		data.stdout = string(streams[0].kept[:])
		data.stderr = string(streams[1].kept[:])
		data.stdout_bytes = streams[0].total
		data.stderr_bytes = streams[1].total
		// A stream that never outgrew memory is whole in the result, so its file is removed and
		// its name released; the result names the file of a stream that did.
		files := [2]^string{&data.stdout_file, &data.stderr_file}
		for stream, index in streams {
			if stream.spool != nil {
				_ = os.close(stream.spool)
			}
			if stream.overflow {
				files[index]^ = stream.spool_path
			} else {
				if stream.spool != nil { _ = os.remove(stream.spool_path) }
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
		fds: [4]subprocess.Poll
		slots := [2]int{-1, -1}
		count := 0
		for stream, index in streams {
			if !stream.open { continue }
			slots[index] = count
			fds[count] = {
				fd = subprocess.fd(stream.file),
			}
			count += 1
		}
		exit_slot := count
		fds[count] = {
			fd = child.exit,
		}
		count += 1
		count += tool_control_fds(fds[count:], control)
		if err := subprocess.poll(fds[:count], deadline, budget > 0); err != nil {
			stop, wait_error = .Wait_Failed, err
			break
		}

		progress := false
		for &stream, index in streams {
			if slots[index] < 0 || !fds[slots[index]].ready { continue }
			progress = true
			n, status := subprocess.read(stream.file, scratch[:])
			if status == .Again { continue }
			if status == .Failed || n == 0 {
				stream.open = false
				wait_error = tool_stream_finish(&stream)
			} else {
				wait_error = tool_stream_take(&stream, scratch[:n], sink)
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
	if stop != .None { _ = subprocess.terminate_group(child) }
	if finish_error := tool_stream_finish_all(streams[:]); finish_error != nil {
		if stop == .None { _ = subprocess.terminate_group(child) }
		stop, wait_error = .Wait_Failed, finish_error
	}
	if stop != .None { return stop, wait_error, false }
	return tool_retire_child(child, start, budget, control)
}
