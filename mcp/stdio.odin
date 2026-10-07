package mcp

import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "nabla:subprocess"

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

@(require_results)
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
// diagnostic text only: a thread drains it so a chatty server cannot block on a full
// pipe, and a request outcome never depends on it.
Stdio :: struct {
	pipes:            Stdio_Pipes,
	child:            subprocess.Child,
	started:          bool,
	line:             [dynamic]u8,
	// line_start is where the unconsumed bytes of line begin: everything before it has been
	// returned to a reader already.
	line_start:       int,
	out:              [dynamic]u8,
	stderr_tail:      [dynamic]u8,
	stderr_mutex:     sync.Mutex,
	stderr_thread:    ^thread.Thread,
	// drain_stop_read and drain_stop_write stop the drainer: closing the write end
	// wakes it from its poll for good.
	drain_stop_read:  ^os.File,
	drain_stop_write: ^os.File,
	sigpipe_owned:    bool,
	allocator:        mem.Allocator,
}

// stdio_start launches a server and begins draining its standard error. On failure
// the transport is left unstarted and owns nothing.
@(require_results)
stdio_start :: proc(stdio: ^Stdio, config: Stdio_Config, allocator := context.allocator) -> Error {
	if !strings.has_prefix(config.executable, "/") {
		return error_make(.Spawn_Failed, "a server executable must be an absolute path", allocator = allocator)
	}
	argv, environment, vectors_ok := stdio_vectors(config.executable, config.arguments, config.environment, allocator)
	defer stdio_vectors_destroy(argv, environment, allocator)
	if !vectors_ok { return error_make(.Out_Of_Memory, allocator = allocator) }

	// A dead peer must be an error, not a signal that kills the harness.
	if sigpipe_error := stdio_sigpipe_acquire(); sigpipe_error != nil {
		return stdio_spawn_error("the SIGPIPE disposition could not be saved", sigpipe_error, allocator)
	}
	stdio.sigpipe_owned = true
	pipes, child, spawn_error := stdio_spawn(argv, environment, config.working_directory)
	if spawn_error != nil {
		stdio_sigpipe_release()
		stdio.sigpipe_owned = false
		return stdio_spawn_error("the server process could not be started", spawn_error, allocator)
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
	for file in ([3]^os.File{stdio.pipes.stdin, stdio.pipes.stdout, stdio.pipes.stderr}) {
		if blocking_error := stdio_set_nonblocking(file); blocking_error != nil {
			stdio_stop(stdio)
			return stdio_spawn_error("the server's pipes could not be made non-blocking", blocking_error, allocator)
		}
	}

	stop_read, stop_write, stop_error := os.pipe()
	if stop_error != nil {
		stdio_stop(stdio)
		return stdio_spawn_error("the standard error drain could not be prepared", stop_error, allocator)
	}
	stdio.drain_stop_read, stdio.drain_stop_write = stop_read, stop_write
	stdio.stderr_thread = thread.create(stdio_stderr_serve)
	if stdio.stderr_thread == nil {
		stdio_stop(stdio)
		return error_make(.Out_Of_Memory, allocator = allocator)
	}
	stdio.stderr_thread.data = stdio
	thread.start(stdio.stderr_thread)
	return {}
}

// stdio_spawn_error is a start failure that names what failed and the system's
// reason for it.
@(private, require_results)
stdio_spawn_error :: proc(what: string, cause: os.Error, allocator: mem.Allocator) -> Error {
	return error_make(.Spawn_Failed, fmt.tprintf("%s: %s", what, os.error_string(cause)), allocator)
}

// stdio_stop shuts the server down and releases the transport's buffers. Closing
// the server's input is the portable graceful signal, so it is tried first, and
// the process group is escalated to only if the server does not go.
stdio_stop :: proc(stdio: ^Stdio) {
	if stdio.started {
		// Every end is closed once, on the way out, and the transport may not report a
		// failure by then: a close that fails changes nothing.
		_ = os.close(stdio.pipes.stdin)
		subprocess.child_await(&stdio.child, time.tick_add(time.tick_now(), subprocess.KILL_GRACE))
		if !stdio.child.reaped { _ = subprocess.terminate_group(&stdio.child) }
		subprocess.child_close(&stdio.child)
	}
	// The drainer still reads standard error, so it is joined before that pipe
	// end closes.
	if stdio.drain_stop_write != nil { _ = os.close(stdio.drain_stop_write) }
	if stdio.stderr_thread != nil {
		thread.join(stdio.stderr_thread)
		thread.destroy(stdio.stderr_thread)
		stdio.stderr_thread = nil
	}
	if stdio.drain_stop_read != nil { _ = os.close(stdio.drain_stop_read) }
	if stdio.started {
		_ = os.close(stdio.pipes.stdout)
		_ = os.close(stdio.pipes.stderr)
		stdio.started = false
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
	return !subprocess.child_poll(&stdio.child)
}

// stdio_write_line writes one framed message. A message is one line, so the
// newline is added here and the caller's bytes must contain none. A write that does
// not complete leaves a partial line, which is not a message: the server cannot
// have acted on it, so the error is reported as not delivered.
@(require_results)
stdio_write_line :: proc(stdio: ^Stdio, message: string, control: Control) -> Error {
	if !stdio.started { return error_make(.Write_Failed, allocator = stdio.allocator) }
	clear(&stdio.out)
	if _, append_err := append(&stdio.out, ..transmute([]u8)message); append_err != nil {
		return error_make(.Out_Of_Memory, allocator = stdio.allocator)
	}
	if _, append_err := append(&stdio.out, '\n'); append_err != nil {
		return error_make(.Out_Of_Memory, allocator = stdio.allocator)
	}

	written := 0
	for written < len(stdio.out) {
		waited, stop, wait_error := stdio_wait(stdio.pipes.stdin, .Write, &stdio.child, control)
		switch waited {
		case .Ready:
		case .Stopped:
			return control_error(stop, .Not_Delivered, stdio.allocator)
		case .Server_Gone:
			return stdio_transport_error(stdio, .Server_Exited, .Not_Delivered)
		case .Failed:
			return stdio_wait_error(stdio, .Write_Failed, .Not_Delivered, wait_error)
		}
		count, status := stdio_write(stdio.pipes.stdin, stdio.out[written:])
		if status == .Again { continue }
		if status == .Failed || count <= 0 { return stdio_transport_error(stdio, .Write_Failed, .Not_Delivered) }
		written += count
	}
	return {}
}

// stdio_read_line reads one framed message and returns a view of it that is valid
// until the next read. Once a request is written, every failure to read its reply
// is reported as delivered: the server may have acted, which is what makes the
// outcome unknown rather than absent.
@(require_results)
stdio_read_line :: proc(stdio: ^Stdio, control: Control) -> (line: []u8, err: Error) {
	// searched counts the unconsumed bytes already known to hold no newline, so a long
	// line is scanned once in total instead of once per read.
	searched := 0
	for {
		if index := bytes.index_byte(stdio.line[stdio.line_start + searched:], '\n'); index >= 0 {
			start := stdio.line_start + searched + index
			line = stdio.line[stdio.line_start:start]
			stdio.line_start = start + 1
			return
		}
		searched = len(stdio.line) - stdio.line_start
		stdio_compact(stdio)
		if stop := control_stop(control); stop != .None {
			return nil, control_error(stop, .Delivered, stdio.allocator)
		}
		waited, stop, wait_error := stdio_wait(stdio.pipes.stdout, .Read, &stdio.child, control)
		switch waited {
		case .Ready:
		case .Stopped:
			return nil, control_error(stop, .Delivered, stdio.allocator)
		case .Server_Gone:
			return nil, stdio_transport_error(stdio, .Server_Exited, .Delivered)
		case .Failed:
			return nil, stdio_wait_error(stdio, .Read_Failed, .Delivered, wait_error)
		}
		buffer: [4096]u8
		count, status := subprocess.read(stdio.pipes.stdout, buffer[:])
		if status == .Again { continue }
		if status == .Failed || count <= 0 {
			kind := Error_Kind.End_Of_Stream
			if subprocess.child_poll(&stdio.child) { kind = .Server_Exited }
			return nil, stdio_transport_error(stdio, kind, .Delivered)
		}
		if _, append_err := append(&stdio.line, ..buffer[:count]); append_err != nil {
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
	if stdio.line_start == 0 { return }
	remaining := len(stdio.line) - stdio.line_start
	copy(stdio.line[:remaining], stdio.line[stdio.line_start:])
	// The buffer only gets shorter, and a dynamic array that is shortened never
	// allocates, so the resize cannot fail.
	_ = resize(&stdio.line, remaining)
	stdio.line_start = 0
}

// stdio_transport_error builds a transport failure with the delivery state and the
// server's own last words attached, so a diagnostic says what the server was
// complaining about.
@(private, require_results)
stdio_transport_error :: proc(stdio: ^Stdio, kind: Error_Kind, delivery: Delivery_State) -> Error {
	err := error_make(kind, allocator = stdio.allocator)
	err.delivery = delivery
	stdio_stderr_attach(stdio, &err)
	return err
}

// stdio_wait_error is a transport failure caused by the system refusing the wait
// itself, naming the system's reason.
@(private, require_results)
stdio_wait_error :: proc(stdio: ^Stdio, kind: Error_Kind, delivery: Delivery_State, cause: os.Error) -> Error {
	err := stdio_transport_error(stdio, kind, delivery)
	err.message = fmt.aprintf("the server's pipe could not be waited on: %s", os.error_string(cause), allocator = stdio.allocator)
	return err
}

// stdio_stderr_excerpt copies what the server wrote to standard error, owned by
// allocator. It is diagnostic text and never decides an outcome, so a copy that
// cannot be made is reported as the allocator's own failure rather than as an empty
// tail.
@(require_results)
stdio_stderr_excerpt :: proc(stdio: ^Stdio, allocator := context.allocator) -> (string, mem.Allocator_Error) {
	sync.mutex_guard(&stdio.stderr_mutex)
	if len(stdio.stderr_tail) == 0 { return "", nil }
	return strings.clone(string(stdio.stderr_tail[:]), allocator)
}

// stdio_stderr_attach puts the server's most recent output on err, which is where a
// reader looks for why the server did what it did. A tail that cannot be copied is
// left off: err already reports the failure that decides the outcome, and a
// diagnostic that cannot be owned must not replace it.
@(private)
stdio_stderr_attach :: proc(stdio: ^Stdio, err: ^Error) {
	tail, tail_error := stdio_stderr_excerpt(stdio, stdio.allocator)
	if tail_error != nil { return }
	err.stderr_tail = tail
}

// stdio_stderr_serve drains standard error. It runs on its own thread because a
// server that fills the pipe while the harness is not reading would block on its
// next write and never answer.
stdio_stderr_serve :: proc(thread: ^thread.Thread) {
	stdio := cast(^Stdio)thread.data
	buffer: [4096]u8
	// The drain ends at end of stream, on a read error, or when stdio_stop closes the
	// stop pipe: descendants of the server can hold standard error open after it exits.
	for {
		stopped, wait_error := stdio_await_readable(stdio.pipes.stderr, stdio.drain_stop_read)
		if stopped || wait_error != nil { return }
		read_count, status := subprocess.read(stdio.pipes.stderr, buffer[:])
		if status == .Again { continue }
		if status == .Failed || read_count <= 0 { return }
		if sync.mutex_guard(&stdio.stderr_mutex) {
			stdio_stderr_retain(stdio, buffer[:read_count])
		}
	}
}

// stdio_stderr_retain adds what the server just wrote and keeps only the most
// recent MAX_STDERR_TAIL_BYTES of it. The cut is moved to the next rune start, so
// the retained text stays valid UTF-8. The caller holds stderr_mutex.
@(private)
stdio_stderr_retain :: proc(stdio: ^Stdio, data: []u8) {
	// A tail that cannot grow keeps what it has: the drain has no caller to report
	// to, and this text is diagnostic, never an outcome.
	if _, append_error := append(&stdio.stderr_tail, ..data); append_error != nil { return }
	excess := len(stdio.stderr_tail) - MAX_STDERR_TAIL_BYTES
	if excess <= 0 { return }
	// A byte with the top bits 10 is the continuation of a rune that the cut would
	// otherwise split, so it is dropped along with the bytes before it.
	for excess < len(stdio.stderr_tail) && stdio.stderr_tail[excess] & 0b1100_0000 == 0b1000_0000 {
		excess += 1
	}
	remove_range(&stdio.stderr_tail, 0, excess)
}
