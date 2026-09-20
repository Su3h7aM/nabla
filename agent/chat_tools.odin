package agent

import "core:os"

import "nabla:agent/session"

// --- running tools -----------------------------------------------------------

// chat_run_tools executes the calls the current response committed. Each call's
// intent is recorded before it runs, and its result after, so an interruption between
// the two is legible as an unknown outcome rather than a guess.
//
// The batch's context budget is opened here, before the first result exists, and every
// result is charged against it in submission order; a result that does not fit is kept
// and replaced by a handle, so one turn cannot put more into the context than the
// window has left.
//
// The loop is the driver: it takes the one bounded step the table asks for and stops
// when every job is released. It returns how many calls it recorded, which is what the
// caller compares against the number of committed calls before the turn moves on.
@(private)
chat_run_tools :: proc(chat: ^Chat_Session, observer: Chat_Observer) -> int {
	jobs: Tool_Jobs
	// Job-owned storage comes from the process heap: a worker thread allocates while
	// the owner may be allocating too, so the two never share one allocator.
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)

	tool_jobs_submit(&jobs, chat, observer)
	for {
		tool_jobs_latch_stop(&jobs, chat)
		switch tool_jobs_next(&jobs) {
		case .Commit:
			tool_jobs_commit(&jobs, chat, observer)
		case .Refuse:
			tool_jobs_refuse(&jobs)
		case .Retire:
			tool_jobs_retire(&jobs)
		case .Dispatch:
			tool_jobs_dispatch(&jobs, chat)
		case .Wait:
			tool_jobs_wait(&jobs)
		case .Done:
			return tool_jobs_committed(&jobs)
		}
	}
}

// chat_record_tool_result appends the result entry a model later reads. It reports the
// entry it stored, and reports no entry when the write failed, which stops the turn: a
// call that ran and left no result is exactly the unanswered call the record must never
// have.
@(private)
chat_record_tool_result :: proc(chat: ^Chat_Session, staged: ^Chat_Tool_Call, result: ^Tool_Result, spilled: bool) -> (seq: session.Seq, recorded: bool) {
	error_text := ""
	if result.error.kind != .None { error_text = tool_argument_error_text(result.error, context.temp_allocator) }
	entry := session.New_Entry {
		turn_no = chat.turn_no,
		request_no = chat.active_request,
		created_at_ms = session.now_ms(),
		related_seq = staged.seq,
		payload = session.Tool_Result_Entry{outcome = result.outcome, error = error_text, content = result.content, origin = .Observed, spilled = spilled},
	}
	stored, append_error := session.entry_append(chat.store, chat.id, entry)
	if append_error != nil {
		chat_session_record_failure(chat, "the tool result could not be recorded", append_error)
		return {}, false
	}
	return stored, true
}
