package agent

import "core:mem"
import "core:strings"
import "core:sync"

import "nabla:agent/session"
import "nabla:ai"

// Steering accepts input while a turn is running. A line the user sends is a message the
// model has not answered, so the turn makes the request that answers it: recording the line
// puts it in the next request the turn builds, and a turn that had already answered
// continues instead of finishing. That is the whole difference from a prompt sent while
// idle, which starts a turn of its own. Nothing here drops a line the user sent: it waits in
// the queue until the session holds it, and a store that cannot record it leaves it waiting.
//
// The front-end owns reading input, so it pushes lines here; the execution thread remains
// the only session writer. There are no parallel model requests and no scheduler. The
// queue is written by the front-end's thread and read by the execution thread, so it is
// guarded.
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

// steer_requeue puts a popped line back at the front of the queue and takes its
// ownership back. The queue is where input waits until the session holds it, so a line
// the session could not record returns here, in its own order, instead of being dropped.
// False means the queue could not take it back and the line was released: the one case
// where input cannot stay pending.
steer_requeue :: proc(queue: ^Steer_Queue, line: string) -> bool {
	sync.mutex_lock(&queue.mu)
	defer sync.mutex_unlock(&queue.mu)
	if !inject_at(&queue.items, 0, line) {
		delete(line, queue.allocator)
		return false
	}
	queue.bytes += len(line)
	return true
}

// steer_take_all removes everything queued, oldest first, and returns it in one
// allocation the caller owns. It is how input no turn recorded leaves the queue: whoever
// takes it decides what it becomes, and steer_taken_destroy releases it.
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

// Steer_Context is the input a running turn may still consume: the bounded queue the
// front-end pushes lines into, and the caller's hook for a selection the user changed.
// It is an observation source, not session state: the caller owns what it points at, and
// a turn the caller gives no input passes none at all.
Steer_Context :: struct {
	queue:      ^Steer_Queue,
	// apply, when not nil, is the caller's request-boundary hook: it installs any
	// selection the user asked for since the last request and returns the connection
	// the next request must use. Resolving a selection is the caller's business, so the
	// agent only asks; apply_data is whatever the caller needs to answer.
	apply:      proc(steer: ^Steer_Context) -> ai.Provider_Connection,
	apply_data: rawptr,
}

// chat_drain_steering hands the queued lines to the session, oldest first, and reports how
// many it recorded. A line leaves the queue only once the session has recorded it: recording
// is what makes the line the session's, and a store that refuses the write leaves it pending
// instead of dropping a message the user sent. The refusal is reported, so a line that cannot
// be delivered yet is diagnosable rather than gone.
chat_drain_steering :: proc(chat: ^Chat_Session, observer: Chat_Observer, steer: ^Steer_Context) -> int {
	recorded := 0
	for {
		line, ok := steer_pop(steer.queue)
		if !ok { break }
		switch chat_session_steer(chat, line, session.now_ms()) {
		case .Recorded:
			_observer_user_text(observer, line)
			steer_line_free(steer.queue, line)
			recorded += 1
		case .No_Turn:
			// Nothing has run that could carry the line, so it waits for the turn that
			// will, and the caller is told which condition is holding it up.
			_observer_message(observer, .Warning, "the steering line is waiting for a turn to carry it")
			steer_requeue(steer.queue, line)
			return recorded
		case .Storage_Failed:
			// The store refused it, so the line stays pending: the session's own error says
			// why, and nothing else may drop a message the user sent.
			_observer_message(observer, .Error, chat.last_error)
			if !steer_requeue(steer.queue, line) {
				_observer_message(observer, .Warning, "the steering line could not stay pending")
			}
			return recorded
		}
	}
	return recorded
}

// chat_steering_observe is the driver's collection step for input the front-end queued while
// the turn ran. It records the lines at a settled point of the turn, and a line recorded for
// a turn that had finished answering continues that turn: a message the user sent is one the
// model has not answered, so the next request this turn makes is the one that answers it.
//
// That is the whole difference between steering and a prompt sent while idle, which starts a
// turn of its own. A turn that failed or was cancelled keeps its outcome; its input stays in
// the record, and the next request built from that history carries it.
chat_steering_observe :: proc(chat: ^Chat_Session, observer: Chat_Observer, steer: ^Steer_Context) {
	point := chat_session_input_point(chat)
	if point == .Wait { return }
	if chat_drain_steering(chat, observer, steer) == 0 { return }
	if point == .After_Answer { chat_session_continue_for_input(chat) }
}
