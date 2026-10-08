package agent

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

import "nabla:agent/journal"

// Follow is what a process showing a session another process runs keeps between polls.
// last is the highest seq rendered, so nothing is shown twice.
Follow :: struct {
	last:     journal.Journal_Seq,
	working:  bool,
	// estimate and window are the size of the newest response request and the window
	// it was checked against, zero before one.
	estimate: int,
	window:   int,
	// input is the seq of a `user.input` line the caller waits to see answered, zero
	// for none. follow_poll sets turn when the delivering User node is read, and ended
	// and outcome at that turn's `turn.completed`.
	input:    journal.Journal_Seq,
	turn:     journal.Turn_Id,
	ended:    bool,
	outcome:  journal.Turn_Outcome,
}

// follow_start positions a follow at the end of the journal. working and the estimate
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
// reports the same fact: a Code Mode child's result carries its script's call as
// parent_call, as the live view reports it. Records whose payload cannot be decoded
// are skipped. A journal error stops the poll with follow.last at the last record
// rendered. Nothing here writes the journal.
@(require_results)
follow_poll :: proc(store: ^journal.Journal, session: journal.Session_Id, follow: ^Follow, observer: Chat_Observer) -> journal.Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	records, _ := journal.read_records(store, {session = session}, follow.last, 0, context.temp_allocator) or_return
	for record in records {
		follow_record(store, follow, record, observer) or_return
		follow.last = record.seq
	}
	return nil
}

@(private = "file", require_results)
follow_record :: proc(store: ^journal.Journal, follow: ^Follow, record: journal.Record, observer: Chat_Observer) -> journal.Error {
	body := string(record.body)
	#partial switch record.kind {
	case .User_Input:
		_observer_user_text(observer, body, user_input_origin(record))
	case .Node_Committed:
		return follow_node(store, follow, record, observer)
	case .Tool_Proposed:
		if record.parent_call != 0 { return nil }
		proposed: journal.Tool_Proposed
		if journal.payload_decode(record.data, &proposed, context.temp_allocator) != nil { return nil }
		_observer_tool_call(observer, Chat_Tool_Event{call_id = proposed.provider_id, name = proposed.name, arguments = body})
	case .Tool_Completed:
		return follow_tool_result(store, record, observer)
	case .Turn_Started:
		follow.working = true
	case .Turn_Completed:
		defer _observer_turn_finished(observer)
		follow.working = false
		completed: journal.Turn_Completed
		decoded := journal.payload_decode(record.data, &completed, context.temp_allocator) == nil
		outcome := journal.Turn_Outcome.Failed
		if decoded {
			if named, known := journal.enum_from_name(journal.TURN_OUTCOME_NAMES, completed.outcome); known { outcome = named }
		}
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
// record; any other purpose is ignored.
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
		// A node delivering a user.input line repeats a line already shown;
		// any other delivery is that report's first display.
		if user.message != 0 && follow_delivered_input(store, user.message) { return nil }
		origin, _ := journal.enum_from_name(journal.USER_ORIGIN_NAMES, user.origin)
		// A delivered agent report shows as user text with its origin, so the
		// front-end renders it as a subagent entry rather than a notice.
		if origin == .Prompt || origin == .Agent {
			_observer_user_text(observer, body, origin)
		} else {
			_observer_message(observer, .Notice, body)
		}
	case .Assistant:
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

// follow_delivered_input reports whether the inbox record a User node delivers is a
// `user.input` line, which follow_record already showed when its record arrived. A
// read that fails or finds nothing shows the node: a report is never hidden because
// its source could not be read.
@(private = "file", require_results)
follow_delivered_input :: proc(store: ^journal.Journal, message: journal.Journal_Seq) -> bool {
	source, _, read_error := journal.read_records(store, {}, message - 1, 1, context.temp_allocator)
	if read_error != nil || len(source) != 1 || source[0].seq != message { return false }
	return source[0].kind == .User_Input
}

// follow_tool_result reports a finished call. The call's name is looked up from its
// `tool.proposed` record.
@(private = "file", require_results)
follow_tool_result :: proc(store: ^journal.Journal, record: journal.Record, observer: Chat_Observer) -> journal.Error {
	completed: journal.Tool_Completed
	if journal.payload_decode(record.data, &completed, context.temp_allocator) != nil { return nil }
	name := "tool"
	arguments: string
	proposals, _ := journal.read_records(
		store,
		{session = record.session, kinds = {.Tool_Proposed}, call = record.call},
		0,
		1,
		context.temp_allocator,
	) or_return
	if len(proposals) > 0 {
		proposed: journal.Tool_Proposed
		if journal.payload_decode(proposals[0].data, &proposed, context.temp_allocator) == nil {
			name = proposed.name
			arguments = string(proposals[0].body)
		}
	}
	outcome, _ := journal.enum_from_name(journal.TOOL_OUTCOME_NAMES, completed.outcome)
	result := Tool_Result {
		outcome   = outcome,
		reason    = journal.TOOL_OUTCOME_NAMES[outcome],
		content   = string(record.body),
		allocator = context.temp_allocator,
	}
	_observer_tool_result(observer, record.call, record.parent_call, name, arguments, &result)
	return nil
}

// session_lock_path is the lock file for session's claim in the lock directory locks.
// The path is owned by allocator.
@(require_results)
session_lock_path :: proc(locks: string, session: journal.Session_Id, allocator := context.allocator) -> (path: string, error: mem.Allocator_Error) {
	hex_text: [journal.SESSION_ID_HEX_LENGTH]u8
	return strings.concatenate({locks, "/", journal.session_id_to_hex(session, hex_text[:]), ".lock"}, allocator)
}
