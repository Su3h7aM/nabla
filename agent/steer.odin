package agent

import "core:mem"
import "core:strings"
import "core:sync"

// Steering accepts input while a turn is running and applies it at the next safe
// boundary: before the next model request, after tool calls settled. The front-end
// owns reading input, so it pushes lines here; the execution thread remains the
// only session writer. There are no parallel model requests and no scheduler.
//
// The queue is written by the front-end's thread and read by the execution
// thread, which is the only reason it is guarded.
STEER_MAX_ITEMS :: 8
STEER_MAX_BYTES :: 32 * 1024

Steer_Queue :: struct {
	mu:        sync.Mutex,
	items:     [dynamic]string, // owned FIFO,
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

// steer_line_free releases a popped line. Pops transfer ownership, and the
// memory belongs to the queue allocator, never the ambient context.
steer_line_free :: proc(queue: ^Steer_Queue, line: string) {
	delete(line, queue.allocator)
}
