package mcp

import "core:mem"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:thread"
import "core:time"

// Environment_Entry is one variable a server is launched with. The environment is
// explicit and frozen: the harness does not pass its own, so a server sees only
// what the user configured.
Environment_Entry :: struct {
	name:  string,
	value: string,
}

// Stdio_Config is how to start one server. The strings are borrowed for the call
// that starts it.
Stdio_Config :: struct {
	// executable must be an absolute path. A server is launched by executable and
	// argv rather than through a shell, so a relative path would depend on a search
	// rule the user did not write.
	executable:        string,
	arguments:         []string,
	// working_directory is the server's directory; empty inherits the harness's.
	working_directory: string,
	environment:       []Environment_Entry,
}

stdio_config_clone :: proc(config: Stdio_Config, allocator: mem.Allocator) -> (Stdio_Config, Error) {
	clone: Stdio_Config
	clone_error: mem.Allocator_Error
	clone.executable, clone_error = strings.clone(config.executable, allocator)
	if clone_error != nil { return {}, error_make(.Out_Of_Memory, allocator = allocator) }
	clone.working_directory, clone_error = strings.clone(config.working_directory, allocator)
	if clone_error != nil {
		stdio_config_destroy(&clone, allocator)
		return {}, error_make(.Out_Of_Memory, allocator = allocator)
	}
	clone.arguments, clone_error = make([]string, len(config.arguments), allocator)
	if clone_error != nil {
		stdio_config_destroy(&clone, allocator)
		return {}, error_make(.Out_Of_Memory, allocator = allocator)
	}
	clone.environment, clone_error = make([]Environment_Entry, len(config.environment), allocator)
	if clone_error != nil {
		stdio_config_destroy(&clone, allocator)
		return {}, error_make(.Out_Of_Memory, allocator = allocator)
	}
	for argument, index in config.arguments {
		clone.arguments[index], clone_error = strings.clone(argument, allocator)
		if clone_error != nil {
			stdio_config_destroy(&clone, allocator)
			return {}, error_make(.Out_Of_Memory, allocator = allocator)
		}
	}
	for entry, index in config.environment {
		clone.environment[index].name, clone_error = strings.clone(entry.name, allocator)
		if clone_error != nil {
			stdio_config_destroy(&clone, allocator)
			return {}, error_make(.Out_Of_Memory, allocator = allocator)
		}
		clone.environment[index].value, clone_error = strings.clone(entry.value, allocator)
		if clone_error != nil {
			stdio_config_destroy(&clone, allocator)
			return {}, error_make(.Out_Of_Memory, allocator = allocator)
		}
	}
	return clone, {}
}

stdio_config_destroy :: proc(config: ^Stdio_Config, allocator := context.allocator) {
	delete(config.executable, allocator)
	delete(config.working_directory, allocator)
	for argument in config.arguments { delete(argument, allocator) }
	delete(config.arguments, allocator)
	for entry in config.environment {
		delete(entry.name, allocator)
		delete(entry.value, allocator)
	}
	delete(config.environment, allocator)
	config^ = {}
}

// Stdio is one running server and its framed message stream. The transport borrows
// its config for as long as the process lives.
//
// Standard input and output carry one JSON-RPC message per line. Standard error is
// diagnostic text only: a thread drains it into a bounded tail so a chatty server
// cannot block on a full pipe, and a request outcome never depends on it.
Stdio :: struct {
	pipes:         Stdio_Pipes,
	child:         Stdio_Child,
	started:       bool,
	line:          [dynamic]u8,
	line_offset:   int,
	out:           [dynamic]u8,
	stderr_tail:   [dynamic]u8,
	stderr_mutex:  sync.Mutex,
	stderr_thread: ^thread.Thread,
	stderr_stop:   bool,
	sigpipe_owned: bool,
	allocator:     mem.Allocator,
}

// stdio_start launches a server and begins draining its standard error. On failure
// the transport is left unstarted and owns nothing.
stdio_start :: proc(stdio: ^Stdio, config: Stdio_Config, allocator := context.allocator) -> Error {
	if !strings.has_prefix(config.executable, "/") {
		return error_make(.Spawn_Failed, "a server executable must be an absolute path", allocator = allocator)
	}
	argv, envp, vectors_ok := stdio_alloc_vectors(config.executable, config.arguments, config.environment, allocator)
	defer stdio_destroy_vectors(argv, envp, allocator)
	if !vectors_ok { return error_make(.Out_Of_Memory, allocator = allocator) }

	name := argv[0]
	directory: cstring
	if config.working_directory != "" {
		cloned, clone_ok := strings_clone_cstring(config.working_directory, context.temp_allocator)
		if !clone_ok { return error_make(.Out_Of_Memory, allocator = allocator) }
		directory = cloned
	}

	// A dead peer must be an error, not a signal that kills the harness.
	previous_sigpipe: linux.Sig_Action
	if !stdio_sigpipe_acquire(&previous_sigpipe) {
		return error_make(.Spawn_Failed, "the SIGPIPE disposition could not be saved", allocator = allocator)
	}
	stdio.sigpipe_owned = true
	pipes, child, spawned := stdio_spawn(name, raw_data(argv), raw_data(envp), directory)
	if !spawned {
		stdio_sigpipe_release()
		stdio.sigpipe_owned = false
		return error_make(.Spawn_Failed, allocator = allocator)
	}

	stdio.pipes = pipes
	stdio.child = child
	stdio.started = true
	stdio.allocator = allocator
	if stdio.line == nil {
		line, line_error := make([dynamic]u8, 0, allocator)
		if line_error != nil {
			stdio_stop(stdio)
			return error_make(.Out_Of_Memory, allocator = allocator)
		}
		stdio.line = line
	}
	if stdio.out == nil {
		out, out_error := make([dynamic]u8, 0, allocator)
		if out_error != nil {
			stdio_stop(stdio)
			return error_make(.Out_Of_Memory, allocator = allocator)
		}
		stdio.out = out
	}
	if stdio.stderr_tail == nil {
		stderr_tail, stderr_error := make([dynamic]u8, 0, allocator)
		if stderr_error != nil {
			stdio_stop(stdio)
			return error_make(.Out_Of_Memory, allocator = allocator)
		}
		stdio.stderr_tail = stderr_tail
		stdio.stderr_tail.allocator = allocator
	}
	// An end that is never polled would leave the server able to block mid-write.
	stdio_set_nonblocking(stdio.pipes.stdin)
	stdio_set_nonblocking(stdio.pipes.stdout)
	stdio_set_nonblocking(stdio.pipes.stderr)

	stdio.stderr_stop = false
	stdio.stderr_thread = thread.create(stdio_stderr_serve)
	if stdio.stderr_thread == nil {
		stdio_stop(stdio)
		return error_make(.Out_Of_Memory, allocator = allocator)
	}
	stdio.stderr_thread.data = stdio
	thread.start(stdio.stderr_thread)
	return {}
}

// stdio_stop shuts the server down and releases the transport's buffers. Closing
// the server's input is the portable graceful signal, so it is tried first, and
// the process group is escalated to only if the server does not go.
stdio_stop :: proc(stdio: ^Stdio) {
	if stdio.started {
		_ = linux.close(stdio.pipes.stdin)
		grace := time.tick_add(time.tick_now(), STDIO_KILL_GRACE)
		for !stdio_child_poll(&stdio.child) {
			if time.tick_since(grace) >= 0 { break }
			time.sleep(5 * time.Millisecond)
		}
		if !stdio.child.reaped { stdio_terminate_group(&stdio.child) }
		// The child is gone, so its ends of the remaining pipes are closed and the
		// drainer reaches end of stream on its own.
		_ = linux.close(stdio.pipes.stdout)
		_ = linux.close(stdio.pipes.stderr)
		stdio.started = false
	}
	if stdio.stderr_thread != nil {
		sync.atomic_store(&stdio.stderr_stop, true)
		thread.join(stdio.stderr_thread)
		thread.destroy(stdio.stderr_thread)
		stdio.stderr_thread = nil
	}
	delete(stdio.line)
	delete(stdio.out)
	delete(stdio.stderr_tail)
	if stdio.sigpipe_owned {
		stdio_sigpipe_release()
		stdio.sigpipe_owned = false
	}
	stdio^ = {}
}

// stdio_running reports whether a server process is still up.
stdio_running :: proc(stdio: ^Stdio) -> bool {
	if !stdio.started { return false }
	return !stdio_child_poll(&stdio.child)
}

// stdio_write_line writes one framed message. A message is one line, so the
// newline is added here and the caller's bytes must contain none. A write that does
// not complete leaves a partial line, which is not a message: the server cannot
// have acted on it, so the error is reported as not delivered.
stdio_write_line :: proc(stdio: ^Stdio, message: string, control: Control) -> Error {
	if !stdio.started { return error_make(.Write_Failed, allocator = stdio.allocator) }
	clear(&stdio.out)
	message_bytes := transmute([]u8)message
	appended, append_err := append(&stdio.out, ..message_bytes)
	if append_err != nil || appended != len(message_bytes) {
		return error_make(.Out_Of_Memory, allocator = stdio.allocator)
	}
	appended, append_err = append(&stdio.out, '\n')
	if append_err != nil || appended != 1 {
		return error_make(.Out_Of_Memory, allocator = stdio.allocator)
	}

	written := 0
	for written < len(stdio.out) {
		ready, stop := stdio_wait(stdio.pipes.stdin, {.OUT}, control)
		if stop != .None { return control_error(stop, .Not_Delivered, stdio.allocator) }
		if !ready {
			if stdio_child_poll(&stdio.child) {
				return stdio_transport_error(stdio, .Server_Exited, .Not_Delivered)
			}
			continue
		}
		count, write_errno := linux.write(stdio.pipes.stdin, stdio.out[written:])
		if write_errno == .EAGAIN || write_errno == .EINTR { continue }
		if write_errno != .NONE {
			return stdio_transport_error(stdio, .Write_Failed, .Not_Delivered)
		}
		if count <= 0 { return stdio_transport_error(stdio, .Write_Failed, .Not_Delivered) }
		written += count
	}
	return {}
}

// stdio_read_line reads one framed message and returns a view of it that is valid
// until the next read. Once a request is written, every failure to read its reply
// is reported as delivered: the server may have acted, which is what makes the
// outcome unknown rather than absent.
stdio_read_line :: proc(stdio: ^Stdio, control: Control) -> (line: []u8, err: Error) {
	for {
		if start := stdio_find_newline(stdio.line[:], stdio.line_offset); start >= 0 {
			stdio.line_offset = start + 1
			return stdio.line[:start], {}
		}
		stdio_compact(stdio)
		if len(stdio.line) > MAX_MESSAGE_BYTES {
			return nil, stdio_transport_error(stdio, .Message_Too_Large, .Delivered)
		}
		if stop := control_stop(control); stop != .None {
			return nil, control_error(stop, .Delivered, stdio.allocator)
		}
		ready, stop := stdio_wait(stdio.pipes.stdout, {.IN}, control)
		if stop != .None { return nil, control_error(stop, .Delivered, stdio.allocator) }
		if !ready {
			// A hangup with nothing left to read is the end of the stream, and a
			// server that has exited is a more specific fact than that.
			if stdio_child_poll(&stdio.child) {
				return nil, stdio_transport_error(stdio, .Server_Exited, .Delivered)
			}
			continue
		}
		buffer: [4096]u8
		count, read_errno := linux.read(stdio.pipes.stdout, buffer[:])
		if read_errno == .EAGAIN || read_errno == .EINTR { continue }
		if read_errno != .NONE || count <= 0 {
			kind := Error_Kind.End_Of_Stream
			if stdio_child_poll(&stdio.child) { kind = .Server_Exited }
			return nil, stdio_transport_error(stdio, kind, .Delivered)
		}
		appended, append_err := append(&stdio.line, ..buffer[:count])
		if append_err != nil || appended != count {
			read_error := error_make(.Out_Of_Memory, allocator = stdio.allocator)
			read_error.delivery = .Delivered
			return nil, read_error
		}
	}
}

// compact drops the bytes a previous call already returned, so the buffer holds
// only the unconsumed tail.
@(private)
stdio_compact :: proc(stdio: ^Stdio) {
	if stdio.line_offset == 0 { return }
	remaining := len(stdio.line) - stdio.line_offset
	copy(stdio.line[:remaining], stdio.line[stdio.line_offset:])
	resize(&stdio.line, remaining)
	stdio.line_offset = 0
}

@(private)
stdio_find_newline :: proc(data: []u8, from: int) -> int {
	for index in from ..< len(data) {
		if data[index] == '\n' { return index }
	}
	return -1
}

// stdio_transport_error builds a transport failure with the delivery state and the
// server's own last words attached, so a diagnostic says what the server was
// complaining about.
@(private)
stdio_transport_error :: proc(stdio: ^Stdio, kind: Error_Kind, delivery: Delivery_State) -> Error {
	err := error_make(kind, allocator = stdio.allocator)
	err.delivery = delivery
	err.stderr_tail = stdio_stderr_excerpt(stdio, stdio.allocator)
	return err
}

// stdio_stderr_excerpt copies the bounded tail of what the server wrote to standard
// error. It is diagnostic text and never decides an outcome.
stdio_stderr_excerpt :: proc(stdio: ^Stdio, allocator := context.allocator) -> string {
	sync.mutex_lock(&stdio.stderr_mutex)
	defer sync.mutex_unlock(&stdio.stderr_mutex)
	if len(stdio.stderr_tail) == 0 { return "" }
	return strings.clone(string(stdio.stderr_tail[:]), allocator)
}

// stdio_stderr_serve drains standard error into a bounded tail. It runs on its own
// thread because a server that fills the pipe while the harness is not reading
// would block on its next write and never answer.
stdio_stderr_serve :: proc(thread: ^thread.Thread) {
	stdio := cast(^Stdio)thread.data
	buffer: [4096]u8
	for !sync.atomic_load(&stdio.stderr_stop) {
		fds := [1]linux.Poll_Fd{{fd = stdio.pipes.stderr, events = {.IN}}}
		count, poll_errno := linux.poll(fds[:], STDIO_POLL_SLICE_MS)
		if poll_errno != .NONE { return }
		if count <= 0 { continue }
		read_count, read_errno := linux.read(stdio.pipes.stderr, buffer[:])
		if read_errno == .EAGAIN || read_errno == .EINTR { continue }
		if read_errno != .NONE || read_count <= 0 { return }
		sync.mutex_lock(&stdio.stderr_mutex)
		stdio_tail_append(&stdio.stderr_tail, buffer[:read_count], stdio.allocator)
		sync.mutex_unlock(&stdio.stderr_mutex)
	}
}

// stdio_tail_append keeps the last MAX_STDERR_TAIL_BYTES bytes, so a server that
// logs without bound cannot make the harness hold its output.
@(private)
stdio_tail_append :: proc(tail: ^[dynamic]u8, chunk: []u8, allocator: mem.Allocator) {
	if len(chunk) >= MAX_STDERR_TAIL_BYTES {
		clear(tail)
		append(tail, ..chunk[len(chunk) - MAX_STDERR_TAIL_BYTES:])
		return
	}
	append(tail, ..chunk)
	excess := len(tail) - MAX_STDERR_TAIL_BYTES
	if excess <= 0 { return }
	remaining := len(tail) - excess
	copy(tail[:remaining], tail[excess:])
	resize(tail, remaining)
}
