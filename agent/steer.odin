package agent

import "core:mem"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:thread"
import "core:time"

// Steering accepts input while a turn is running and applies it at the next
// safe boundary: before the next model request, after tool calls settled.
// One reader thread owns stdin and only ever touches the queue; the execution
// thread remains the only session writer. There are no parallel model
// requests and no scheduler.
//
// The reader never blocks unobservably: it polls stdin with a timeout and
// checks a stop flag each round, so shutdown joins within one interval.
// Closing stdin from another thread does not reliably interrupt a blocked
// read on Linux pseudo-terminals, so the reader is stopped, never yanked.
STEER_MAX_ITEMS :: 8
STEER_MAX_BYTES :: 32 * 1024
STEER_IDLE_POLL :: 50 * time.Millisecond
STEER_READ_POLL_MS :: 100

Steer_Queue :: struct {
	mu:        sync.Mutex,
	items:     [dynamic]string, // owned FIFO,
	bytes:     int,
	closed:    bool, // the reader reached EOF; no more input is coming,
	stop:      bool, // shutdown asked the reader to exit; polled, never forced,
	allocator: mem.Allocator,
}

steer_queue_init :: proc(allocator := context.allocator) -> Steer_Queue {
	return Steer_Queue{items = make([dynamic]string, 0, allocator), allocator = allocator}
}

steer_queue_destroy :: proc(queue: ^Steer_Queue) {
	for line in queue.items { delete(line, queue.allocator) }
	delete(queue.items)
	queue^ = {}
}

// steer_push clones a line into the queue. False means the bounds rejected
// it; the caller keeps nothing either way.
steer_push :: proc(queue: ^Steer_Queue, text: string) -> bool {
	ok := false
	sync.mutex_lock(&queue.mu)
	if len(queue.items) < STEER_MAX_ITEMS && queue.bytes + len(text) <= STEER_MAX_BYTES {
		append(&queue.items, strings.clone(text, queue.allocator))
		queue.bytes += len(text)
		ok = true
	}
	sync.mutex_unlock(&queue.mu)
	return ok
}

// steer_pop transfers ownership of the oldest line. False means empty.
steer_pop :: proc(queue: ^Steer_Queue) -> (string, bool) {
	sync.mutex_lock(&queue.mu)
	defer sync.mutex_unlock(&queue.mu)
	if len(queue.items) == 0 { return "", false }
	line := queue.items[0]
	ordered_remove(&queue.items, 0)
	queue.bytes -= len(line)
	return line, true
}

// steer_clear discards everything queued and reports how many lines went.
steer_clear :: proc(queue: ^Steer_Queue) -> int {
	sync.mutex_lock(&queue.mu)
	defer sync.mutex_unlock(&queue.mu)
	dropped := len(queue.items)
	for line in queue.items { delete(line, queue.allocator) }
	clear(&queue.items)
	queue.bytes = 0
	return dropped
}

steer_available :: proc(queue: ^Steer_Queue) -> bool {
	sync.mutex_lock(&queue.mu)
	defer sync.mutex_unlock(&queue.mu)
	return len(queue.items) > 0
}

// steer_drained reports a closed reader with nothing left to send.
steer_drained :: proc(queue: ^Steer_Queue) -> bool {
	sync.mutex_lock(&queue.mu)
	defer sync.mutex_unlock(&queue.mu)
	return queue.closed && len(queue.items) == 0
}

steer_close :: proc(queue: ^Steer_Queue) {
	sync.mutex_lock(&queue.mu)
	defer sync.mutex_unlock(&queue.mu)
	queue.closed = true
}

// steer_line_free releases a popped line. Pops transfer ownership, and the
// memory belongs to the queue allocator, never the ambient context.
steer_line_free :: proc(queue: ^Steer_Queue, line: string) {
	delete(line, queue.allocator)
}

Steer_Wait :: enum {
	Input,
	Closed,
	Cancelled,
}

// steer_idle_wait blocks the execution thread until a line is available, the
// reader reached EOF, or SIGINT arrived. Polling keeps the wait observable:
// a signal with no turn running ends the wait instead of stranding it.
steer_idle_wait :: proc(queue: ^Steer_Queue) -> Steer_Wait {
	for {
		if chat_cancel_requested() { return .Cancelled }
		if steer_available(queue) { return .Input }
		if steer_drained(queue) { return .Closed }
		time.sleep(STEER_IDLE_POLL)
	}
}

Steer_Reader :: struct {
	thread:   ^thread.Thread,
	queue:    ^Steer_Queue,
	observer: Chat_Observer, // the front-end the reader reports queue depth to,
}

steer_serve :: proc(thread: ^thread.Thread) {
	reader := cast(^Steer_Reader)thread.data
	pending := make([dynamic]u8, 0, reader.queue.allocator)
	defer delete(pending)
	scratch: [4096]u8
	for {
		sync.mutex_lock(&reader.queue.mu)
		stop := reader.queue.stop
		sync.mutex_unlock(&reader.queue.mu)
		if stop { return }
		fds := [1]linux.Poll_Fd{{fd = 0, events = {.IN}}}
		ready, poll_errno := linux.poll(fds[:], STEER_READ_POLL_MS)
		if poll_errno != .NONE { continue }
		if ready <= 0 { continue }
		n, read_errno := linux.read(0, scratch[:])
		if read_errno == .EINTR || read_errno == .EAGAIN { continue }
		if read_errno != .NONE || n <= 0 {
			steer_flush_pending(reader.queue, reader.observer, &pending)
			steer_close(reader.queue)
			return
		}
		steer_feed_bytes(reader.queue, reader.observer, &pending, scratch[:n])
	}
}

// steer_feed_bytes accumulates a chunk and queues each complete line.
// Partial lines wait for the rest; over-bound lines are dropped with a note,
// exactly as if they had arrived whole.
steer_feed_bytes :: proc(queue: ^Steer_Queue, observer: Chat_Observer, pending: ^[dynamic]u8, chunk: []u8) {
	append(pending, ..chunk)
	start := 0
	for i in 0 ..< len(pending) {
		if pending[i] != '\n' { continue }
		steer_push_trimmed(queue, observer, string(pending[start:i]))
		start = i + 1
	}
	if start > 0 { remove_range(pending, 0, start) }
}

// steer_flush_pending queues the trailing partial line at EOF, if any.
steer_flush_pending :: proc(queue: ^Steer_Queue, observer: Chat_Observer, pending: ^[dynamic]u8) {
	if len(pending) == 0 { return }
	steer_push_trimmed(queue, observer, string(pending[:]))
	clear(pending)
}

steer_push_trimmed :: proc(queue: ^Steer_Queue, observer: Chat_Observer, text: string) {
	trimmed := strings.trim_space(text)
	if trimmed == "" { return }
	if steer_push(queue, trimmed) {
		depth := 0
		sync.mutex_lock(&queue.mu)
		depth = len(queue.items)
		sync.mutex_unlock(&queue.mu)
		_observer_queue(observer, .Queued, depth)
	} else {
		_observer_queue(observer, .Full, 0)
	}
}

// steer_reader_start spawns the reader with SIGINT already blocked, so the
// new thread inherits the mask and can never run the handler. Masking at
// thread entry would leave a startup window: the OS thread exists from
// thread.create, so a SIGINT could reach it first.
steer_reader_start :: proc(reader: ^Steer_Reader) -> bool {
	blocked := chat_watched_signals()
	previous: linux.Sig_Set
	_ = linux.rt_sigprocmask(.SIG_BLOCK, &blocked, &previous)
	defer _ = linux.rt_sigprocmask(.SIG_SETMASK, &previous, nil)

	started := thread.create(steer_serve, name = "svan-steer-reader")
	if started == nil { return false }
	started.data = reader
	thread.start(started)
	reader.thread = started
	return true
}

// steer_reader_stop asks the reader to exit and joins it. The reader polls
// the flag each round, so the join lands within one poll interval. Stdin is
// left alone: closing it from here cannot interrupt the reader's blocked
// read on a pseudo-terminal, and nothing else needs the fd closed.
steer_reader_stop :: proc(reader: ^Steer_Reader) {
	if reader == nil || reader.thread == nil { return }
	sync.mutex_lock(&reader.queue.mu)
	reader.queue.stop = true
	sync.mutex_unlock(&reader.queue.mu)
	thread.join(reader.thread)
	thread.destroy(reader.thread)
	reader.thread = nil
}
