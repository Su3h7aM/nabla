package agent

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

import "nabla:agent/session"
import "nabla:ai"

// Steering accepts input while a turn is running and applies it at the next safe
// boundary: before the next model request, after tool calls settled. The front-end
// owns reading input, so it pushes lines here; the execution thread remains the
// only session writer. There are no parallel model requests and no scheduler.
//
// The queue is written by the front-end's thread and read by the execution
// thread, so it is guarded.
STEER_MAX_ITEMS :: 8
STEER_MAX_BYTES :: 32 * 1024

Steer_Queue :: struct {
	mu:        sync.Mutex,
	items:     [dynamic]string, // owned FIFO
	bytes:     int,
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

// steer_push clones a line into the queue. False means the bounds rejected it;
// the caller keeps nothing either way.
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

// steer_take_all removes everything queued, oldest first, and returns it in one
// allocation the caller owns. It is how a line queued for a request boundary the turn
// never reached leaves the queue: whoever takes it decides what it becomes, and
// steer_taken_destroy releases it.
steer_take_all :: proc(queue: ^Steer_Queue) -> [dynamic]string {
	sync.mutex_lock(&queue.mu)
	defer sync.mutex_unlock(&queue.mu)
	taken := make([dynamic]string, 0, len(queue.items), queue.allocator)
	append(&taken, ..queue.items[:])
	clear(&queue.items)
	queue.bytes = 0
	return taken
}

// steer_taken_destroy releases what steer_take_all returned. Its lines belong to the
// queue allocator, never the ambient context.
steer_taken_destroy :: proc(queue: ^Steer_Queue, taken: [dynamic]string) {
	for line in taken { delete(line, queue.allocator) }
	delete(taken)
}

// steer_line_free releases a popped line. Pops transfer ownership, and the
// memory belongs to the queue allocator, never the ambient context.
steer_line_free :: proc(queue: ^Steer_Queue, line: string) {
	delete(line, queue.allocator)
}

// Steer_Context is the input a running turn may still consume: the queue the
// front-end pushes lines into, a quit request one of those lines may carry, and the
// caller's hook for a selection the user changed. It is an observation source, not
// session state: the caller owns everything it points at, and a turn the caller gives
// no input passes none at all.
Steer_Context :: struct {
	queue:      ^Steer_Queue,
	// quit, when not nil, is set by a queued line that asks the session to end.
	// A caller with no such flag leaves it nil; the line is then reported and
	// ignored rather than dereferenced.
	quit:       ^bool,
	// apply, when not nil, is the caller's request-boundary hook: it installs any
	// selection the user asked for since the last request and returns the connection
	// the next request must use. Resolving a selection is the caller's business, so the
	// agent only asks; apply_data is whatever the caller needs to answer.
	apply:      proc(steer: ^Steer_Context) -> ai.Provider_Connection,
	apply_data: rawptr,
}

// chat_drain_steering applies the lines queued since the last request boundary. The
// driver runs it on the request the selector proposed and before the claim that counts
// it, so a line it records belongs to the request about to be prepared, and a write
// that fails stops the turn before anything is claimed for it.
//
// Commands run immediately, so /effort still lands before the request is read from the
// store; anything else becomes a user entry for the next request. A quit discards what
// was never sent.
chat_drain_steering :: proc(chat: ^Chat_Session, observer: Chat_Observer, steer: ^Steer_Context, connection: ai.Provider_Connection) {
	for {
		line, ok := steer_pop(steer.queue)
		if !ok { break }
		if line == "/quit" {
			steer_line_free(steer.queue, line)
			if steer.quit != nil { steer.quit^ = true }
			dropped := steer_clear(steer.queue)
			if dropped > 0 {
				_observer_message(observer, .Notice, fmt.tprintf("quitting after this turn finishes; dropped %d queued line(s)", dropped))
			} else {
				_observer_message(observer, .Notice, "quitting after this turn finishes")
			}
			return
		}
		if !chat_handle_command(chat, observer, steer.queue, line, steer.quit) {
			if line == "/compact" {
				chat_command_compact(chat, observer, connection)
			} else if strings.has_prefix(line, "/") {
				// A slash is a command, never a message. A command this path does not
				// answer to is refused rather than sent to the model as steering text.
				_observer_message(observer, .Notice, fmt.tprintf("%s is not available while a turn is running", line))
			} else if result := chat_session_steer(chat, line, session.now_ms()); result != .Accepted {
				// A line that arrived outside the boundary was never tried, so the turn's
				// own failure is not this line's to report: only a store that refused the
				// line has something to say about it.
				if result == .Storage_Failed {
					_observer_message(observer, .Error, chat.last_error)
				} else {
					_observer_message(observer, .Warning, "steering arrived outside a request boundary; dropped")
				}
			} else {
				_observer_user_text(observer, line)
			}
		}
		steer_line_free(steer.queue, line)
		if steer.quit != nil && steer.quit^ { return }
	}
}
