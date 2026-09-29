package agent

import "core:time"

import "nabla:agent/journal"

// chat_record buffers one fact of the running session. The session, branch, and
// turn default to the chat's own; the other correlation columns are the caller's.
chat_record :: proc(chat: ^Chat_Session, header: journal.Record, payload: $Payload, body: []u8 = nil) {
	header := header
	header.session = chat.session
	if header.branch == 0 { header.branch = chat.branch }
	if header.turn == 0 { header.turn = chat.turn }
	journal.append_record(chat.store, header, payload, body)
}

// chat_node buffers the next step of the conversation on the chat's branch and
// makes it the head. It returns 0 when the journal has stopped writing, which the
// next commit reports.
chat_node :: proc(chat: ^Chat_Session, kind: journal.Node_Kind, payload: $Payload, body: []u8 = nil, covers: journal.Node_Id = 0) -> journal.Node_Id {
	node := journal.Node {
		session = chat.session,
		parent  = chat.head,
		branch  = chat.branch,
		kind    = kind,
		turn    = chat.turn,
		covers  = covers,
	}
	id := journal.append_node(chat.store, node, payload, body)
	if id != 0 { chat.head = id }
	return id
}

// chat_commit makes every buffered fact durable before the effect that depends on
// them proceeds. A failure stops the session; what names the step for the message.
@(require_results)
chat_commit :: proc(chat: ^Chat_Session, what: string) -> bool {
	// Diagnostics waiting in the ring ride in the same transaction.
	diag_drain(log_active_ring(), chat.store)
	if _, error := journal.commit(chat.store); error != nil {
		chat_session_record_failure(chat, what, error)
		return false
	}
	return true
}

// chat_session_text is the session id as the 32 hexadecimal characters a provider,
// a path, or a person reads. The text lives in the chat.
chat_session_text :: proc(chat: ^Chat_Session) -> string {
	return journal.session_id_to_hex(chat.session, chat.session_hex[:])
}

// chat_record_job_abandoned buffers that the owner stopped waiting for a worker of the
// given kind that ignored its stop for waited, out of TOOL_JOBS_STOP_PATIENCE. The header
// names the call, request, or subagent the worker served. Owner only.
chat_record_job_abandoned :: proc(chat: ^Chat_Session, header: journal.Record, kind: journal.Job_Kind, waited: time.Duration) {
	header := header
	header.kind = .Job_Abandoned
	chat_record(
		chat,
		header,
		journal.Job_Abandoned {
			job = journal.JOB_KIND_NAMES[kind],
			waited_ms = i64(waited / time.Millisecond),
			patience_ms = i64(TOOL_JOBS_STOP_PATIENCE / time.Millisecond),
		},
	)
}

// chat_record_job_reclaimed buffers that the owner released a retained worker of the
// given kind after it finished late. Owner only.
chat_record_job_reclaimed :: proc(chat: ^Chat_Session, header: journal.Record, kind: journal.Job_Kind) {
	header := header
	header.kind = .Job_Reclaimed
	chat_record(chat, header, journal.Job_Reclaimed{job = journal.JOB_KIND_NAMES[kind]})
}
