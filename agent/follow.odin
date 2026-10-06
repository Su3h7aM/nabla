package agent

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

import "nabla:agent/journal"

// Follow is what a process that shows a session another process runs keeps between
// polls (section 8.6 of the architecture). The record that first showed a fact is its
// seq, so nothing is shown twice.
Follow :: struct {
	// last is the highest seq rendered.
	last:     journal.Journal_Seq,
	// working is whether a turn has started and not completed.
	working:  bool,
	// estimate and window are the size of the newest response request and the window it
	// was checked against, zero before one.
	estimate: int,
	window:   int,
	// input is the seq of a `user.input` line the caller waits to see answered, zero for
	// none. follow_poll sets turn when the User node that delivers it is read, and ended and
	// outcome when that turn's `turn.completed` is.
	input:    journal.Journal_Seq,
	turn:     journal.Turn_Id,
	ended:    bool,
	outcome:  journal.Turn_Outcome,
}

// follow_start positions a follow at the end of the journal. The caller arms its session
// watch first and captures this cursor, transcript head, and pending input in one read
// snapshot, then ends that snapshot before replay or callbacks. working and the estimate
// start from the newest turn and request records of session.
@(require_results)
follow_start :: proc(store: ^journal.Journal, session: journal.Session_Id) -> (follow: Follow, error: journal.Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	newest, newest_found := journal.read_latest(store, {}, context.temp_allocator) or_return
	if newest_found { follow.last = newest.seq }
	started, started_found := journal.read_latest(store, {session = session, kinds = {.Turn_Started}}, context.temp_allocator) or_return
	completed, completed_found := journal.read_latest(store, {session = session, kinds = {.Turn_Completed}}, context.temp_allocator) or_return
	follow.working = started_found && (!completed_found || started.seq > completed.seq)
	prepared, prepared_found := journal.read_latest(store, {session = session, kinds = {.Request_Prepared}}, context.temp_allocator) or_return
	if prepared_found { follow_prepared(&follow, prepared) }
	return follow, nil
}

// follow_poll renders the records of session committed after follow.last through the
// observer, in seq order, and advances follow. Each record is reported as the live view
// reports the same fact:
//
// - A `user.input` shows at once as the user's text, and the User node that later
//   delivers it (its message names that seq) is skipped, so the line shows once.
// - User, Assistant, Notice, Context, and Checkpoint nodes show their whole text, since
//   streamed deltas are not recorded.
// - `tool.proposed` announces a call, and `tool.completed` reports its result.
// - `turn.started` and `turn.completed` move follow.working, and a turn that did not
//   complete reports why. `request.prepared` updates the estimate and window.
// - With follow.input set, the User node that delivers that line records its turn in
//   follow.turn, and that turn's `turn.completed` sets follow.ended and follow.outcome. Both
//   are set before the observer hears the record, so a callback sees whether the node it is
//   shown belongs to the awaited turn.
// - `retry.scheduled`, `runtime.message`, and `selection.applied` show as messages.
//
// Records of a Lua script's child calls are skipped, as the live view skips them. A record
// whose payload cannot be decoded is skipped too: the harness never guesses at it, and one
// bad record must not stop the session from showing what follows. A journal error stops
// the poll with follow.last at the last record rendered, so the next poll continues there.
// Nothing here writes the journal.
@(require_results)
follow_poll :: proc(store: ^journal.Journal, session: journal.Session_Id, follow: ^Follow, observer: Chat_Observer) -> journal.Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	records, _ := journal.read_records(store, {session = session}, follow.last, 0, context.temp_allocator) or_return
	for record in records {
		if record.parent_call == 0 { follow_record(store, follow, record, observer) or_return }
		follow.last = record.seq
	}
	return nil
}

@(private = "file", require_results)
follow_record :: proc(store: ^journal.Journal, follow: ^Follow, record: journal.Record, observer: Chat_Observer) -> journal.Error {
	body := string(record.body)
	#partial switch record.kind {
	case .User_Input:
		_observer_user_text(observer, body)
	case .Node_Committed:
		return follow_node(store, follow, record, observer)
	case .Tool_Proposed:
		proposed: journal.Tool_Proposed
		if journal.payload_decode(record.data, &proposed, context.temp_allocator) != nil { return nil }
		_observer_tool_call(observer, Chat_Tool_Event{call_id = proposed.provider_id, name = proposed.name, arguments = body})
	case .Tool_Completed:
		return follow_tool_result(store, record, observer)
	case .Turn_Started:
		follow.working = true
	case .Turn_Completed:
		follow.working = false
		completed: journal.Turn_Completed
		decoded := journal.payload_decode(record.data, &completed, context.temp_allocator) == nil
		outcome := journal.Turn_Outcome.Failed
		if decoded { outcome, _ = journal.enum_from_name(journal.TURN_OUTCOME_NAMES, completed.outcome) }
		// An undecodable record still ends the awaited turn, as a failure, so a caller
		// that waits for it is not left waiting on a turn that is over.
		if follow.turn != 0 && record.turn == follow.turn {
			follow.ended = true
			follow.outcome = outcome
		}
		if !decoded { return nil }
		text: string
		switch outcome {
		case .Completed:
			return nil
		case .Failed:
			text = "request failed"
		case .Cancelled:
			text = "turn cancelled"
		case .Interrupted:
			text = "turn interrupted"
		}
		if completed.detail != "" { text = fmt.tprintf("%s: %s", text, completed.detail) }
		_observer_message(observer, .Error, text)
	case .Request_Prepared:
		follow_prepared(follow, record)
		_observer_request_prepared(observer)
	case .Retry_Scheduled:
		scheduled: journal.Retry_Scheduled
		if journal.payload_decode(record.data, &scheduled, context.temp_allocator) != nil { return nil }
		event := Chat_Retry_Event {
			request      = record.request,
			next_attempt = scheduled.next_attempt,
			delay        = time.Duration(scheduled.delay_ms) * time.Millisecond,
		}
		for reason in Request_Recovery_Reason {
			if request_recovery_reason_name(reason) == scheduled.reason { event.reason = reason }
		}
		// The record keeps the recovery reason and not the provider's failure class; a
		// refusal the chain repaired is the one class the display words differently.
		event.failure_class = .Invalid_Request if event.reason == .Adaptive_Thinking_Refused || event.reason == .Cache_Hints_Refused else .Unknown
		_observer_retry_scheduled(observer, event)
	case .Runtime_Message:
		message: journal.Runtime_Message
		if journal.payload_decode(record.data, &message, context.temp_allocator) != nil { return nil }
		kind := Chat_Message_Kind.Warning if message.level == journal.RUNTIME_LEVEL_NAMES[.Warning] else .Error
		_observer_message(observer, kind, message.text)
	case .Selection_Applied:
		applied: journal.Selection_Applied
		if journal.payload_decode(record.data, &applied, context.temp_allocator) != nil { return nil }
		_observer_message(observer, .Notice, fmt.tprintf("the session runs %s / %s", applied.provider, applied.model))
	}
	return nil
}

// follow_prepared takes the size of a response request from its `request.prepared`
// record. A compaction request is another conversation's size and is ignored.
@(private = "file")
follow_prepared :: proc(follow: ^Follow, record: journal.Record) {
	prepared: journal.Request_Prepared
	if journal.payload_decode(record.data, &prepared, context.temp_allocator) != nil { return }
	if prepared.purpose != journal.REQUEST_PURPOSE_NAMES[.Response] { return }
	follow.estimate = prepared.estimate
	follow.window = prepared.context_window
}

// follow_node shows the node a `node.committed` record names.
@(private = "file", require_results)
follow_node :: proc(store: ^journal.Journal, follow: ^Follow, record: journal.Record, observer: Chat_Observer) -> journal.Error {
	node := journal.read_node(store, record.session, record.node, context.temp_allocator) or_return
	body := string(node.body)
	#partial switch node.kind {
	case .User:
		user: journal.User
		if journal.payload_decode(node.data, &user, context.temp_allocator) != nil { return nil }
		if follow.input != 0 && user.message == follow.input { follow.turn = node.turn }
		origin, _ := journal.enum_from_name(journal.USER_ORIGIN_NAMES, user.origin)
		// A node that delivers a user.input line repeats a line already shown. One that
		// delivers an agent's report is the first the transcript shows of it.
		if user.message != 0 && origin != .Agent { return nil }
		if origin == .Prompt {
			_observer_user_text(observer, body)
		} else {
			_observer_message(observer, .Notice, body)
		}
	case .Assistant:
		// A response of calls alone has no text, and an empty entry would show nothing.
		if body == "" { return nil }
		_observer_assistant_begin(observer)
		_observer_assistant_text(observer, body)
		_observer_assistant_end(observer)
	case .Notice, .Context:
		_observer_message(observer, .Notice, body)
	case .Checkpoint:
		_observer_message(observer, .Notice, "(earlier turns are summarized)")
	}
	return nil
}

// follow_tool_result reports a finished call. The call's name is in its `tool.proposed`
// record, which a follower may have read in an earlier poll, so it is looked up.
@(private = "file", require_results)
follow_tool_result :: proc(store: ^journal.Journal, record: journal.Record, observer: Chat_Observer) -> journal.Error {
	completed: journal.Tool_Completed
	if journal.payload_decode(record.data, &completed, context.temp_allocator) != nil { return nil }
	name := "tool"
	proposals, _ := journal.read_records(
		store,
		{session = record.session, kinds = {.Tool_Proposed}, call = record.call},
		0,
		1,
		context.temp_allocator,
	) or_return
	if len(proposals) > 0 {
		proposed: journal.Tool_Proposed
		if journal.payload_decode(proposals[0].data, &proposed, context.temp_allocator) == nil { name = proposed.name }
	}
	outcome, _ := journal.enum_from_name(journal.TOOL_OUTCOME_NAMES, completed.outcome)
	result := Tool_Result {
		outcome   = outcome,
		reason    = journal.TOOL_OUTCOME_NAMES[outcome],
		content   = string(record.body),
		allocator = context.temp_allocator,
	}
	_observer_tool_result(observer, name, &result)
	return nil
}

// session_lock_path is the lock file the journal keeps session's claim on in the lock
// directory locks, which session_watch_add watches. The path is owned by allocator.
@(require_results)
session_lock_path :: proc(locks: string, session: journal.Session_Id, allocator := context.allocator) -> (path: string, error: mem.Allocator_Error) {
	hex_text: [journal.SESSION_ID_HEX_LENGTH]u8
	return strings.concatenate({locks, "/", journal.session_id_to_hex(session, hex_text[:]), ".lock"}, allocator)
}
