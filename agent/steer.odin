package agent

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

import "nabla:agent/journal"
import "nabla:ai"

// Steering accepts input while a turn is running. A queued line joins the next request
// the turn builds; a turn that had already answered continues instead of finishing,
// which is the whole difference from a prompt sent while idle. Nothing here drops a
// line: it waits in the queue until the journal holds it as a user.input record. The
// front-end pushes from its own thread, so the queue is guarded; a message is never
// refused for its size.
Steer_Queue :: struct {
	mu:        sync.Mutex,
	items:     [dynamic]string, // owned FIFO
	allocator: mem.Allocator,
}

@(require_results)
steer_queue_init :: proc(allocator := context.allocator) -> Steer_Queue {
	queue := Steer_Queue {
		allocator = allocator,
	}
	queue.items.allocator = allocator
	return queue
}

steer_queue_destroy :: proc(queue: ^Steer_Queue) {
	for line in queue.items { delete(line, queue.allocator) }
	delete(queue.items)
	queue^ = {}
}

// steer_push clones a line into the queue and wakes the owner. False means the line
// could not be kept.
@(require_results)
steer_push :: proc(queue: ^Steer_Queue, text: string) -> bool {
	line, clone_error := strings.clone(text, queue.allocator)
	if clone_error != nil { return false }
	sync.mutex_lock(&queue.mu)
	_, append_error := append(&queue.items, line)
	sync.mutex_unlock(&queue.mu)
	if append_error != nil {
		delete(line, queue.allocator)
		return false
	}
	owner_wake_signal()
	return true
}

// steer_pop transfers ownership of the oldest line. False means empty.
@(require_results)
steer_pop :: proc(queue: ^Steer_Queue) -> (string, bool) {
	sync.mutex_lock(&queue.mu)
	defer sync.mutex_unlock(&queue.mu)
	if len(queue.items) == 0 { return "", false }
	line := queue.items[0]
	ordered_remove(&queue.items, 0)
	return line, true
}

// steer_pending reports whether a line is waiting.
steer_pending :: proc(queue: ^Steer_Queue) -> bool {
	sync.mutex_guard(&queue.mu)
	return len(queue.items) > 0
}

// steer_requeue puts a popped line back at the front of the queue. False means the
// queue could not take it back and the line was released.
@(require_results)
steer_requeue :: proc(queue: ^Steer_Queue, line: string) -> bool {
	sync.mutex_lock(&queue.mu)
	defer sync.mutex_unlock(&queue.mu)
	if !inject_at(&queue.items, 0, line) {
		delete(line, queue.allocator)
		return false
	}
	return true
}

// steer_take_all removes everything queued, oldest first, in one allocation the caller
// owns, released by steer_taken_destroy. On failure the lines stay queued.
@(require_results)
steer_take_all :: proc(queue: ^Steer_Queue) -> (taken: [dynamic]string, ok: bool) {
	sync.mutex_lock(&queue.mu)
	defer sync.mutex_unlock(&queue.mu)
	lines, allocation_error := make([dynamic]string, 0, len(queue.items), queue.allocator)
	if allocation_error != nil { return {}, false }
	for line in queue.items {
		if _, append_error := append(&lines, line); append_error != nil {
			delete(lines)
			return {}, false
		}
	}
	clear(&queue.items)
	return lines, true
}

// steer_taken_destroy releases what steer_take_all returned. Its lines belong to the
// queue allocator, never the ambient context.
steer_taken_destroy :: proc(queue: ^Steer_Queue, taken: [dynamic]string) {
	for line in taken { delete(line, queue.allocator) }
	delete(taken)
}

// steer_line_free releases a popped line, which belongs to the queue allocator.
steer_line_free :: proc(queue: ^Steer_Queue, line: string) {
	delete(line, queue.allocator)
}

// Steer_Context is the input a running turn may still consume. It is an observation
// source, not session state: the caller owns what it points at.
Steer_Context :: struct {
	queue:      ^Steer_Queue,
	// observe runs on the session owner at every collection step, including while
	// provider and tool jobs are running. It must not wait for those jobs.
	observe:    proc(steer: ^Steer_Context, observer: Chat_Observer),
	// apply, when not nil, is the caller's request-boundary hook: it installs any
	// selection the user asked for since the last request and returns the connection
	// the next request must use. Resolving a selection is the caller's business, so the
	// agent only asks; apply_data is whatever the caller needs to answer.
	apply:      proc(steer: ^Steer_Context) -> ai.Provider_Connection,
	apply_data: rawptr,
}

// STEER_ACCEPTED_NOTICE is what the front-end is told for each line once the journal holds it.
STEER_ACCEPTED_NOTICE :: "queued; the model reads it at the next request"

// chat_steering_accept commits every queued line as one user.input record per line. A
// commit that fails busy keeps the buffered records for the next commit; any other
// failure returns the lines to the front of the queue in order.
chat_steering_accept :: proc(chat: ^Chat_Session, observer: Chat_Observer, steer: ^Steer_Context) {
	if chat.storage_failed || !chat_journal_writable(chat) { return }
	queue: ^Steer_Queue
	if steer != nil { queue = steer.queue }
	taken: [dynamic]string
	if queue != nil && steer_pending(queue) {
		lines, taken_ok := steer_take_all(queue)
		if taken_ok { taken = lines }
	}
	for line in taken {
		chat_record(chat, {kind = .User_Input}, journal.User_Input{origin = journal.USER_ORIGIN_NAMES[.Steering]}, transmute([]u8)line)
	}
	chat.unacknowledged += len(taken)
	if chat.unacknowledged == 0 { return }
	if _, commit_error := journal.commit(chat.store); commit_error != nil {
		if journal.error_is_busy(commit_error) {
			if queue != nil { steer_taken_destroy(queue, taken) }
			return
		}
		chat_session_record_failure(chat, "the steering line could not be recorded", commit_error)
		chat.unacknowledged -= len(taken)
		for index := len(taken) - 1; index >= 0; index -= 1 {
			if !steer_requeue(queue, taken[index]) {
				_observer_message(observer, .Warning, "a steering line could not stay pending")
			}
		}
		delete(taken)
		_observer_message(observer, .Error, chat.last_error)
		return
	}
	for _ in 0 ..< chat.unacknowledged { _observer_message(observer, .Notice, STEER_ACCEPTED_NOTICE) }
	chat.unacknowledged = 0
	if queue != nil { steer_taken_destroy(queue, taken) }
}

// chat_inbox_read returns the records addressed to the session that no User node has
// delivered, oldest first, in temp memory.
@(require_results)
chat_inbox_read :: proc(chat: ^Chat_Session) -> (records: []journal.Record, ok: bool) {
	if !chat_journal_writable(chat) { return nil, true }
	read_error: journal.Error
	records, read_error = journal.read_inbox(chat.store, chat.session, chat.delivered, context.temp_allocator)
	if read_error != nil {
		chat_session_record_failure(chat, "the session's queued input could not be read", read_error)
		return nil, false
	}
	return records, true
}

// chat_inbox_stage buffers one User node per record, in seq order, and returns the text
// of each in temp memory. It commits nothing.
chat_inbox_stage :: proc(chat: ^Chat_Session, records: []journal.Record) -> []string {
	texts, texts_error := make([]string, len(records), context.temp_allocator)
	if texts_error != nil { return nil }
	for record, index in records {
		text, origin := inbox_text(record)
		node := chat_node(chat, .User, journal.User{origin = journal.USER_ORIGIN_NAMES[origin], message = record.seq}, transmute([]u8)text)
		if node == 0 { return texts[:index] }
		chat.delivered = record.seq
		texts[index] = text
	}
	return texts
}

// chat_inbox_report tells the front-end what a commit delivered.
chat_inbox_report :: proc(observer: Chat_Observer, texts: []string) {
	for text in texts { _observer_user_text(observer, text) }
}

// chat_inbox_deliver records what the session accepted and other agents sent it, as User
// nodes in one commit, and reports how many. It is for a settled point of a running turn.
chat_inbox_deliver :: proc(chat: ^Chat_Session, observer: Chat_Observer) -> int {
	records, read_ok := chat_inbox_read(chat)
	if !read_ok || len(records) == 0 { return 0 }
	texts := chat_inbox_stage(chat, records)
	if !chat_commit(chat, "the queued input could not be recorded") { return 0 }
	chat_inbox_report(observer, texts)
	return len(texts)
}

// chat_inbox_reports_pending reports whether something is waiting that was committed after
// this process claimed the session and starts a turn of its own: an agent's report or
// message, or a line another process sent (section 8.6 of the architecture). A line this
// process accepted does not count, since its own prompt or turn already holds it, and
// neither does anything older than the claim: that waits for the next prompt. The lines
// this process wrote as a follower, before it took the session over, are the takeover's
// to deliver.
chat_inbox_reports_pending :: proc(chat: ^Chat_Session) -> bool {
	if chat.storage_failed || !chat_journal_writable(chat) { return false }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	records, read_error := journal.read_inbox(chat.store, chat.session, max(chat.delivered, chat.claimed_at), context.temp_allocator)
	if read_error != nil { return false }
	for record in records {
		if record.kind != .User_Input || record.run != chat.store.run { return true }
	}
	return false
}

// inbox_text is the text a User node carries for one inbox record, and the origin the
// node names. The text matches what the model knows: a child is named as the spawn call
// named it, and a record that has no name, such as one recovery wrote, names the child's
// session. A completion report names the child's session and, for a child that did not
// complete, the cause and the last text the child committed. Text is in temp memory.
@(private)
inbox_text :: proc(record: journal.Record) -> (text: string, origin: journal.User_Origin) {
	hex: [journal.SESSION_ID_HEX_LENGTH]u8
	body := string(record.body)
	#partial switch record.kind {
	case .User_Input:
		input: journal.User_Input
		if journal.payload_decode(record.data, &input, context.temp_allocator) == nil {
			if named, known := journal.enum_from_name(journal.USER_ORIGIN_NAMES, input.origin); known { return body, named }
		}
		return body, .Steering
	case .Subagent_Completed:
		completed: journal.Subagent_Completed
		// A payload that cannot be read still reports that the child ended.
		_ = journal.payload_decode(record.data, &completed, context.temp_allocator)
		name := completed.name if completed.name != "" else strings.clone(journal.session_id_to_hex(record.subagent, hex[:]), context.temp_allocator)
		session := journal.session_id_to_hex(record.subagent, hex[:])
		switch completed.outcome {
		case journal.TOOL_OUTCOME_NAMES[.Success]:
			return fmt.tprintf("Subagent %s completed (session %s). Its answer:\n\n%s", name, session, body), .Agent
		case journal.TOOL_OUTCOME_NAMES[.Cancelled]:
			return fmt.tprintf("Subagent %s was stopped before it finished (session %s).%s", name, session, inbox_last_text(body)), .Agent
		}
		return fmt.tprintf("Subagent %s failed (session %s): %s%s", name, session, completed.detail, inbox_last_text(body)), .Agent
	case .Subagent_Message:
		if record.session != record.subagent { return fmt.tprintf("Message from the orchestrator:\n%s", body), .Agent }
		message: journal.Subagent_Message
		_ = journal.payload_decode(record.data, &message, context.temp_allocator)
		name := message.name if message.name != "" else strings.clone(journal.session_id_to_hex(record.subagent, hex[:]), context.temp_allocator)
		return fmt.tprintf("Message from subagent %s, which is still working (reply with agent_send if it asks something):\n%s", name, body), .Agent
	}
	return body, .Agent
}

// inbox_last_text is the paragraph a report of a child that did not complete adds for the
// last text the child committed, "" when it committed none. Text is in temp memory.
@(private)
inbox_last_text :: proc(body: string) -> string {
	if body == "" { return "" }
	return fmt.tprintf("\n\nThe last text it committed, which may be cut off:\n\n%s", body)
}

// chat_steering_observe is the driver's collection step for input that reached the
// session while the turn ran: the user's queued lines become user.input records, and
// everything the session accepted and has not delivered becomes User nodes at a settled
// point of the turn. A delivery for a turn that had finished answering continues that
// turn: a message is one the model has not answered, so the next request this turn makes
// is the one that answers it.
//
// That is the whole difference between steering and a prompt sent while idle, which starts
// a turn of its own. A turn that failed or was cancelled keeps its outcome; its input stays
// pending in the journal, and the next turn delivers it before its prompt.
chat_steering_observe :: proc(chat: ^Chat_Session, observer: Chat_Observer, steer: ^Steer_Context) {
	chat_steering_accept(chat, observer, steer)
	point := chat_session_input_point(chat)
	if point == .Wait { return }
	if chat_inbox_deliver(chat, observer) == 0 { return }
	if point == .After_Answer { chat_session_continue_for_input(chat) }
}
