package agent

import "base:runtime"
import "core:os"
import "core:time"

import "nabla:agent/journal"

// --- running tools -----------------------------------------------------------

// chat_tool_jobs_begin admits the response's calls into session-owned state. It is
// the Run_Tools effect: no executor runs and no durable dispatch is written here.
@(private)
chat_tool_jobs_begin :: proc(chat: ^Chat_Session, observer: Chat_Observer) {
	if chat.tool_jobs_active { return }
	tool_jobs_init(&chat.tool_jobs, chat, len(chat.pending_calls), os.heap_allocator())
	chat.tool_jobs_active = true
	tool_jobs_submit(&chat.tool_jobs, chat, observer)
}

// chat_tool_jobs_step performs one bounded effect selected by
// chat_session_advance. The selector and performer are separate so calling advance
// twice cannot launch or write twice.
@(private)
chat_tool_jobs_step :: proc(chat: ^Chat_Session, observer: Chat_Observer, effect: Tool_Job_Effect) {
	if !chat.tool_jobs_active { return }
	switch effect {
	case .Commit:
		tool_jobs_commit(&chat.tool_jobs, chat, observer)
	case .Refuse:
		tool_jobs_refuse(&chat.tool_jobs)
	case .Abandon:
		tool_jobs_abandon(&chat.tool_jobs, chat, observer, time.tick_now())
	case .Retire:
		tool_jobs_retire(&chat.tool_jobs, time.tick_now())
	case .Dispatch:
		tool_jobs_dispatch(&chat.tool_jobs, chat)
	case .Wait, .Done:
	}
}

@(private)
chat_tool_jobs_wait :: proc(chat: ^Chat_Session) {
	if !chat.tool_jobs_active { return }
	// An unsettled batch has one deadline of its own, the patience a stopped call is given,
	// and no other reason to wake on its own: a completion wakes the owner instead.
	tool_jobs_await(&chat.tool_jobs, tool_jobs_deadline(&chat.tool_jobs))
}

// chat_tool_jobs_finish releases a settled batch and applies its committed result
// count to the chat barrier. A batch that answered every call it was given commits
// the Results node that lists them in proposal order. It is the only production path
// that clears the table.
@(private)
chat_tool_jobs_finish :: proc(chat: ^Chat_Session, turn_id: u64) -> bool {
	if !chat.tool_jobs_active || !tool_jobs_settled(&chat.tool_jobs) { return false }
	count := tool_jobs_committed(&chat.tool_jobs)
	roots := chat.tool_jobs.committed_roots
	tool_jobs_destroy(&chat.tool_jobs)
	chat.tool_jobs_active = false
	if !chat_commit_results(chat, roots) { return false }
	return chat_session_tools_done(chat, turn_id, count)
}

// chat_commit_results commits the Results node answering the staged calls, in proposal
// order, once roots results were committed for all of them. It reports false only when
// the commit failed.
@(private)
chat_commit_results :: proc(chat: ^Chat_Session, roots: int) -> bool {
	if roots != len(chat.pending_calls) || roots == 0 { return true }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	// The list is what the record says the batch answered, so a list that does not fit ends
	// the turn instead of being committed with part of the batch in it.
	calls, calls_error := make([]journal.Call_Id, roots, context.temp_allocator)
	if calls_error != nil {
		chat_session_fail(chat, "the tool results could not be kept for the record")
		return false
	}
	for staged, index in chat.pending_calls { calls[index] = staged.call }
	chat_node(chat, .Results, journal.Results{calls = calls})
	return chat_commit(chat, "the tool results could not be recorded")
}

// chat_record_tool_result commits the tool.completed record a model later reads. node is
// the Assistant node of a root call and parent_call the call that started a Lua child. It
// reports false when the commit failed, which stops the turn: a call that ran and left no
// result is exactly the unanswered call the record must never have.
@(private)
chat_record_tool_result :: proc(
	chat: ^Chat_Session,
	call: journal.Call_Id,
	node: journal.Node_Id,
	parent_call: journal.Call_Id,
	result: ^Tool_Result,
) -> bool {
	// The journal copies the error text, so the temp memory it was built in is released here.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	error_text := ""
	if result.error != nil {
		text, text_error := tool_argument_error_text(result.error, context.temp_allocator)
		error_text = text
		if text_error != nil { error_text = "the argument defect could not be described: out of memory" }
	}
	header := journal.Record {
		kind        = .Tool_Completed,
		node        = node,
		request     = chat.request,
		call        = call,
		parent_call = parent_call,
	}
	completed := journal.Tool_Completed {
		outcome = journal.TOOL_OUTCOME_NAMES[result.outcome],
		detail  = error_text,
	}
	chat_record(chat, header, completed, transmute([]u8)result.content)
	return chat_commit(chat, "the tool result could not be recorded")
}
