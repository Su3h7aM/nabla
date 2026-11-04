package agent

import "base:runtime"
import "core:fmt"
import "core:strings"

import "nabla:agent/journal"
import "nabla:ai"

// Steer_Context holds the owner collection and request-boundary hooks.
// The caller owns the state apply_data points at for the duration of the turn.
Steer_Context :: struct {
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

// Staged_Text is one delivered input: the text its User node carries and the origin
// the node names.
Staged_Text :: struct {
	text:   string,
	origin: journal.User_Origin,
}

// chat_inbox_stage buffers one User node per record, in seq order, and returns each
// text with its origin in temp memory. Files a user.input or background completion
// names are copied onto that node. It commits nothing.
chat_inbox_stage :: proc(chat: ^Chat_Session, records: []journal.Record) -> []Staged_Text {
	staged, staged_error := make([]Staged_Text, len(records), context.temp_allocator)
	if staged_error != nil { return nil }
	for record, index in records {
		text, origin := inbox_text(record)
		user := journal.User {
			origin      = journal.USER_ORIGIN_NAMES[origin],
			message     = record.seq,
			attachments = inbox_attachments(record),
		}
		node := chat_node(chat, .User, user, transmute([]u8)text)
		if node == 0 { return staged[:index] }
		chat.delivered = record.seq
		staged[index] = {
			text   = text,
			origin = origin,
		}
	}
	return staged
}

// chat_inbox_report tells the front-end what a commit delivered.
chat_inbox_report :: proc(observer: Chat_Observer, staged: []Staged_Text) {
	for item in staged { _observer_user_text(observer, item.text, item.origin) }
}

// chat_inbox_deliver records what the session accepted and other agents sent it, as User
// nodes in one commit, and reports how many. It is for a settled point of a running turn.
chat_inbox_deliver :: proc(chat: ^Chat_Session, observer: Chat_Observer) -> int {
	records, read_ok := chat_inbox_read(chat)
	if !read_ok || len(records) == 0 { return 0 }
	staged := chat_inbox_stage(chat, records)
	if !chat_commit(chat, "the queued input could not be recorded") { return 0 }
	chat_inbox_report(observer, staged)
	return len(staged)
}

// chat_inbox_reports_pending reports whether something is waiting that was committed after
// this process claimed the session and starts a turn of its own: a background tool completion, an agent's report or
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

// chat_continuation_pending reports whether the model is owed a continuation request
// for what recovery settled while this process holds the claim: the session's last
// turn ended Interrupted when recovery closed it and left no final assistant answer,
// or recovered completions exist that no response request has consumed. A continuation
// is one ordinary turn over the same history, so the model sees the recovered results,
// including Unknown and Not_Executed outcomes, and decides what to do. Nothing Unknown
// is re-executed. A response request sent since recovery already continued it.
chat_continuation_pending :: proc(chat: ^Chat_Session) -> bool {
	if chat.storage_failed || !chat_journal_writable(chat) { return false }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	recovered, recovered_found, recovered_error := journal.read_latest(
		chat.store,
		{session = chat.session, kinds = {.Session_Recovered}},
		context.temp_allocator,
	)
	if recovered_error != nil || !recovered_found { return false }
	defer journal.record_destroy(&recovered, context.temp_allocator)
	if chat_response_since_recovery(chat, recovered.seq) { return false }
	return chat_interrupted_without_answer(chat, recovered.seq) || chat_results_unconsumed(chat, recovered.seq)
}

// chat_response_since_recovery reports whether a response request was sent after
// recovery settled the session. A compaction request does not count: it summarizes
// instead of answering.
@(private)
chat_response_since_recovery :: proc(chat: ^Chat_Session, recovered: journal.Journal_Seq) -> bool {
	sent, _, sent_error := journal.read_records(chat.store, {session = chat.session, kinds = {.Request_Sent}}, recovered, 0, context.temp_allocator)
	if sent_error != nil { return false }
	defer journal.records_destroy(sent, context.temp_allocator)
	for record in sent {
		purpose := journal.payload_as(record, journal.Request_Sent) or_continue
		if name, known := journal.enum_from_name(journal.REQUEST_PURPOSE_NAMES, purpose.purpose); known && name == .Response { return true }
	}
	return false
}

// chat_interrupted_without_answer reports whether the session's last turn ended
// Interrupted when recovery closed it and left no final assistant answer: no newer
// turn started, and the turn's newest assistant node still holds calls for the model
// to see, is partial, or is missing. A call-free assistant node is the turn's final
// answer, so the model already said its last word.
@(private)
chat_interrupted_without_answer :: proc(chat: ^Chat_Session, recovered: journal.Journal_Seq) -> bool {
	completed, completed_found, completed_error := journal.read_latest(chat.store, {session = chat.session, kinds = {.Turn_Completed}}, context.temp_allocator)
	if completed_error != nil || !completed_found { return false }
	defer journal.record_destroy(&completed, context.temp_allocator)
	ended := journal.payload_as(completed, journal.Turn_Completed) or_return
	outcome, known := journal.enum_from_name(journal.TURN_OUTCOME_NAMES, ended.outcome)
	if !known || outcome != .Interrupted || completed.seq > recovered { return false }
	started, started_found, started_error := journal.read_latest(chat.store, {session = chat.session, kinds = {.Turn_Started}}, context.temp_allocator)
	if started_error != nil { return false }
	defer if started_found { journal.record_destroy(&started, context.temp_allocator) }
	if started_found && started.turn > completed.turn { return false }
	assistant, assistant_found, assistant_error := journal.read_last_node(chat.store, chat.session, .Assistant, context.temp_allocator)
	if assistant_error != nil { return false }
	defer if assistant_found { journal.node_destroy(&assistant, context.temp_allocator) }
	if !assistant_found || assistant.turn != completed.turn { return assistant.turn < completed.turn }
	payload, has_payload := assistant.payload.?
	answer, is_assistant := payload.(journal.Assistant)
	if !has_payload || !is_assistant { return false }
	if answer.partial { return true }
	ids := [1]journal.Node_Id{assistant.id}
	proposed, _, proposed_error := journal.read_records(
		chat.store,
		{session = chat.session, kinds = {.Tool_Proposed}, nodes = ids[:]},
		0,
		1,
		context.temp_allocator,
	)
	if proposed_error != nil { return false }
	defer journal.records_destroy(proposed, context.temp_allocator)
	return len(proposed) > 0
}

// chat_results_unconsumed reports whether recovery settled completions that no response
// request has consumed yet: a completion committed at or before recovery, after the
// latest response request. Those are the tool, background, subagent, Lua, and Task
// completions recovery wrote for calls that never reported.
@(private)
chat_results_unconsumed :: proc(chat: ^Chat_Session, recovered: journal.Journal_Seq) -> bool {
	requests, _, requests_error := journal.read_records(chat.store, {session = chat.session, kinds = {.Request_Sent}}, 0, 0, context.temp_allocator)
	if requests_error != nil { return false }
	defer journal.records_destroy(requests, context.temp_allocator)
	answered: journal.Journal_Seq = 0
	for record in requests {
		purpose := journal.payload_as(record, journal.Request_Sent) or_continue
		if name, known := journal.enum_from_name(journal.REQUEST_PURPOSE_NAMES, purpose.purpose); known && name == .Response {
			answered = max(answered, record.seq)
		}
	}
	completed, _, completed_error := journal.read_records(
		chat.store,
		{session = chat.session, kinds = {.Tool_Completed, .Background_Completed, .Subagent_Completed, .Lua_Completed, .Task_Completed}},
		answered,
		0,
		context.temp_allocator,
	)
	if completed_error != nil { return false }
	defer journal.records_destroy(completed, context.temp_allocator)
	for record in completed {
		if record.seq <= recovered { return true }
	}
	return false
}

// user_input_origin is the origin a User_Input record names. An unreadable payload or
// an unknown origin name reads as .Steering. It allocates only in the temporary
// allocator.
user_input_origin :: proc(record: journal.Record) -> journal.User_Origin {
	if payload, has_payload := record.payload.?; has_payload {
		if input, is_input := payload.(journal.User_Input); is_input {
			if named, known := journal.enum_from_name(journal.USER_ORIGIN_NAMES, input.origin); known { return named }
		}
	}
	return .Steering
}

// inbox_text is the text a User node carries for one inbox record, and the origin the
// node names. A background tool completion starts with "job-<call> (<tool>) <state>"
// and a newline, then its unmodified result body. A report from or to another agent starts with a one-line heading naming
// the sender and the kind: "<name> answered", "<name> failed", "<name> stopped",
// "<name> asks", or "orchestrator says". Everything after the first newline is the
// body the front-end shows below the heading. The name is the one the start call gave
// the child, or the child's session when the record names none. Text is in temp memory.
@(private)
inbox_text :: proc(record: journal.Record) -> (text: string, origin: journal.User_Origin) {
	hex: [journal.SESSION_ID_HEX_LENGTH]u8
	body := string(record.body)
	#partial switch record.kind {
	case .User_Input:
		return body, user_input_origin(record)
	case .Background_Completed:
		completed, _ := journal.payload_as(record, journal.Background_Completed)
		state := "failed"
		switch completed.outcome {
		case journal.TOOL_OUTCOME_NAMES[.Success]:
			state = "finished"
		case journal.TOOL_OUTCOME_NAMES[.Cancelled]:
			state = "stopped"
		case journal.TOOL_OUTCOME_NAMES[.Unknown]:
			state = "lost"
		}
		name := background_job_name(record.call, context.temp_allocator)
		return fmt.tprintf("%s (%s) %s\n%s", name, completed.tool, state, body), .Job
	case .Subagent_Completed:
		// A payload that cannot be read still reports that the child ended.
		completed, _ := journal.payload_as(record, journal.Subagent_Completed)
		name := completed.name if completed.name != "" else strings.clone(journal.session_id_to_hex(record.subagent, hex[:]), context.temp_allocator)
		switch completed.outcome {
		case journal.TOOL_OUTCOME_NAMES[.Success]:
			if body == "" {
				selection := ""
				if completed.acp_model != "" { selection = fmt.tprintf("model: %s", completed.acp_model) }
				if completed.acp_effort != "" {
					selection = fmt.tprintf("%s%seffort: %s", selection, "\n" if selection != "" else "", completed.acp_effort)
				}
				return inbox_report(fmt.tprintf("%s finished", name), selection), .Agent
			}
			return inbox_report(fmt.tprintf("%s answered", name), body), .Agent
		case journal.TOOL_OUTCOME_NAMES[.Cancelled]:
			return inbox_report(fmt.tprintf("%s stopped", name), inbox_last_text(body)), .Agent
		}
		cause := completed.detail
		if last := inbox_last_text(body); last != "" {
			cause = last if cause == "" else fmt.tprintf("%s\n\n%s", cause, last)
		}
		return inbox_report(fmt.tprintf("%s failed", name), cause), .Agent
	case .Subagent_Message:
		if record.session != record.subagent { return inbox_report("orchestrator says", body), .Agent }
		message, _ := journal.payload_as(record, journal.Subagent_Message)
		name := message.name if message.name != "" else strings.clone(journal.session_id_to_hex(record.subagent, hex[:]), context.temp_allocator)
		return inbox_report(fmt.tprintf("%s asks", name), body), .Agent
	}
	return body, .Agent
}

// inbox_attachments is the files a user.input or background completion names, nil for any other record or a payload that cannot be read. The slice borrows the
// temporary allocator.
@(private)
inbox_attachments :: proc(record: journal.Record) -> []journal.Attachment {
	#partial switch record.kind {
	case .User_Input:
		if payload, has_payload := record.payload.?; has_payload {
			if value, is_input := payload.(journal.User_Input); is_input { return value.attachments }
		}
	case .Background_Completed:
		if completed, is_completed := journal.payload_as(record, journal.Background_Completed); is_completed { return completed.attachments }
	}
	return nil
}

// inbox_report is heading and a colon, then body on the lines below it, or the heading
// alone when the body is empty. Text is in temp memory.
@(private)
inbox_report :: proc(heading, body: string) -> string {
	if body == "" { return heading }
	return fmt.tprintf("%s:\n%s", heading, body)
}

// inbox_last_text is the paragraph a report of a child that did not complete adds after
// the cause for the last text the child committed, "" when it committed none. Text is
// in temp memory.
@(private)
inbox_last_text :: proc(body: string) -> string {
	if body == "" { return "" }
	return fmt.tprintf("The last text it committed, which may be cut off:\n\n%s", body)
}

// chat_steering_observe is the driver's collection step for input that reached the
// session while the turn ran. Only at a settled point of the turn do the user's queued
// lines become user.input records, and everything the session accepted and has not
// delivered become User nodes; until then a line stays in the queue, where the front-end
// shows it and can take it back. A delivery for a turn that had finished answering
// continues that turn: a message is one the model has not answered, so the next request
// this turn makes is the one that answers it.
//
// That is the whole difference between steering and a prompt sent while idle, which starts
// a turn of its own. A turn that failed or was cancelled keeps its outcome; its input stays
// pending in the journal, and the next turn delivers it before its prompt.
chat_steering_observe :: proc(chat: ^Chat_Session, observer: Chat_Observer) {
	point := chat_session_input_point(chat)
	if point == .Wait { return }
	if !chat_queue_deliver_ready(chat, {.Steering}) { return }
	if chat_inbox_deliver(chat, observer) == 0 { return }
	if point == .After_Answer { chat_session_continue_for_input(chat) }
}
