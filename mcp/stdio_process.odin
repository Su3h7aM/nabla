package mcp

import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "nabla:subprocess"

// Stdio_Pipes is the parent's end of a spawned server's three streams. Each end
// closes on exec, so no other child the process starts inherits it.
Stdio_Pipes :: struct {
	stdin:  ^os.File,
	stdout: ^os.File,
	stderr: ^os.File,
}

// STDIO_POLL_MAX is the most entries one wait takes: a pipe end, the server's
// exit watch, and the control's wake.
@(private)
STDIO_POLL_MAX :: 3

// stdio_spawn starts argv in its own process group with a pipe on each standard
// stream and exactly environment as its environment. directory is empty to
// inherit the parent's; a failure reports the system's reason, including what
// exec gave when the program could not be run.
@(require_results)
stdio_spawn :: proc(argv, environment: []string, directory: string) -> (pipes: Stdio_Pipes, child: subprocess.Child, err: os.Error) {
	// Each pipe end is closed exactly once on every path out of here, and a close that
	// fails only leaks a descriptor that this procedure cannot report anyway.
	stdin_read, stdin_write := os.pipe() or_return
	defer if err != nil { _ = os.close(stdin_write) }
	defer _ = os.close(stdin_read)
	stdout_read, stdout_write := os.pipe() or_return
	defer if err != nil { _ = os.close(stdout_read) }
	defer _ = os.close(stdout_write)
	stderr_read, stderr_write := os.pipe() or_return
	defer if err != nil { _ = os.close(stderr_read) }
	defer _ = os.close(stderr_write)

	started, _, start_error := subprocess.start(
		{argv = argv, environment = environment, directory = directory, stdin = stdin_read, stdout = stdout_write, stderr = stderr_write},
	)
	if start_error != nil { return {}, {}, start_error }
	return Stdio_Pipes{stdin = stdin_write, stdout = stdout_read, stderr = stderr_read}, started, nil
}

// stdio_pipes_close closes the parent's ends of a server's streams.
stdio_pipes_close :: proc(pipes: Stdio_Pipes) {
	// The caller is discarding these ends, so a close that fails changes nothing.
	_ = os.close(pipes.stdin)
	_ = os.close(pipes.stdout)
	_ = os.close(pipes.stderr)
}

// stdio_write writes as much of data as one pipe end accepts.
@(require_results)
stdio_write :: proc(file: ^os.File, data: []u8) -> (count: int, status: subprocess.Io) {
	bytes_written, err := os.write(file, data)
	if bytes_written > 0 || err == nil { return bytes_written, .Ok }
	if subprocess.error_again(err) { return 0, .Again }
	return 0, .Failed
}

// stdio_await_readable blocks until file has data or reaches end of stream, or
// until stop becomes readable, which wins.
@(require_results)
stdio_await_readable :: proc(file: ^os.File, stop: ^os.File) -> (stopped: bool, err: os.Error) {
	entries := [2]subprocess.Poll{{fd = subprocess.fd(file)}, {fd = subprocess.fd(stop)}}
	subprocess.poll(entries[:], {}, false) or_return
	return entries[1].ready, nil
}

// SIGPIPE is process-wide, but the stdio transport is not. These fields hold the
// saved disposition while at least one stdio server is running. The lock makes
// concurrent starts and stops agree on which one owns the restore.
@(private)
stdio_sigpipe_mutex: sync.Mutex
@(private)
stdio_sigpipe_users: int
@(private)
stdio_sigpipe_previous: Stdio_Signal_State
@(private)
stdio_sigpipe_saved: bool

// stdio_sigpipe_acquire makes a pipe write report EPIPE instead of terminating the
// process, and saves the disposition that was in force before the first stdio server.
@(require_results)
stdio_sigpipe_acquire :: proc() -> os.Error {
	sync.mutex_guard(&stdio_sigpipe_mutex)
	if stdio_sigpipe_users == 0 {
		stdio_sigpipe_ignore(&stdio_sigpipe_previous) or_return
		stdio_sigpipe_saved = true
	}
	stdio_sigpipe_users += 1
	return nil
}

// stdio_sigpipe_release restores the process disposition when the last stdio server
// stops. A failed restore is left to the process owner; the transport must not keep
// a stale reference count and prevent a later owner from trying again.
stdio_sigpipe_release :: proc() {
	sync.mutex_guard(&stdio_sigpipe_mutex)
	if stdio_sigpipe_users == 0 { return }
	stdio_sigpipe_users -= 1
	if stdio_sigpipe_users != 0 || !stdio_sigpipe_saved { return }
	stdio_sigpipe_restore(&stdio_sigpipe_previous)
	stdio_sigpipe_saved = false
}

// Stdio_Wait is what ended a wait on a pipe end.
Stdio_Wait :: enum {
	Ready,
	// Server_Gone means the pipe is not ready and the server has exited.
	Server_Gone,
	Stopped,
	Failed,
}

// stdio_wait sleeps until a pipe end is ready, the server exits, the control's wake
// is signalled, or its deadline passes. stop says why a Stopped wait ended, and err
// why a Failed one did.
@(require_results)
stdio_wait :: proc(
	file: ^os.File,
	direction: subprocess.Direction,
	child: ^subprocess.Child,
	control: Control,
) -> (
	result: Stdio_Wait,
	stop: Stop,
	err: os.Error,
) {
	for {
		if stop = control_stop(control); stop != .None { return .Stopped, stop, nil }
		entries: [STDIO_POLL_MAX]subprocess.Poll
		entries[0] = {
			fd        = subprocess.fd(file),
			direction = direction,
		}
		count := 1
		if child.exit_open {
			entries[count] = {
				fd = child.exit,
			}
			count += 1
		}
		if control.wake != nil {
			entries[count] = {
				fd = subprocess.fd(control.wake),
			}
			count += 1
		}
		if err = subprocess.poll(entries[:count], control.deadline_at, control.has_deadline); err != nil { return .Failed, .None, err }
		if entries[0].ready { return .Ready, .None, nil }
		if subprocess.child_poll(child) { return .Server_Gone, .None, nil }
	}
}

// stdio_vectors builds the argument and environment lists a spawn takes: the
// executable and its arguments, and each entry as NAME=VALUE. The arguments are
// borrowed; the environment strings are allocated and released with
// stdio_vectors_destroy.
@(require_results)
stdio_vectors :: proc(
	executable: string,
	arguments: []string,
	environment: []Environment_Entry,
	allocator: mem.Allocator,
) -> (
	argv: []string,
	pairs: []string,
	ok: bool,
) {
	argv_error: mem.Allocator_Error
	argv, argv_error = make([]string, len(arguments) + 1, allocator)
	if argv_error != nil { return nil, nil, false }
	argv[0] = executable
	copy(argv[1:], arguments)

	pairs_error: mem.Allocator_Error
	pairs, pairs_error = make([]string, len(environment), allocator)
	if pairs_error != nil {
		delete(argv, allocator)
		return nil, nil, false
	}
	for entry, index in environment {
		pair, pair_error := strings.concatenate({entry.name, "=", entry.value}, allocator)
		if pair_error != nil {
			stdio_vectors_destroy(argv, pairs[:index], allocator)
			return nil, nil, false
		}
		pairs[index] = pair
	}
	return argv, pairs, true
}

// stdio_vectors_destroy releases what stdio_vectors allocated.
stdio_vectors_destroy :: proc(argv, pairs: []string, allocator: mem.Allocator) {
	delete(argv, allocator)
	for pair in pairs { delete(pair, allocator) }
	delete(pairs, allocator)
}
