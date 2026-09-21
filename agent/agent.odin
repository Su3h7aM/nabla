package agent

import "core:fmt"
import "core:mem"
import "core:time"

import "nabla:agent/session"
import "nabla:ai"

Chat_Effect_Kind :: enum {
	None,
	Start_Request,
	// Run_Tools admits the response's committed calls into the session-owned job
	// table. It does not run an executor.
	Run_Tools,
	// Step_Tools performs the one job effect carried in tool.
	Step_Tools,
	// Wait_Tools sleeps until a worker publishes or the wait slice ends.
	Wait_Tools,
	// Finish_Tools releases the settled table and closes the response's tool batch.
	Finish_Tools,
	Turn_Finished,
}

// Chat_Effect is what the current state wants done next. It carries no stored data and
// owns nothing: the driver reads the committed record when it runs an effect and writes
// the record when the effect settles, and a terminal error is read from the session that
// owns it.
Chat_Effect :: struct {
	kind:    Chat_Effect_Kind,
	turn_id: u64,
	tool:    Tool_Job_Effect,
	status:  Chat_Terminal_Status,
}

chat_effect_none :: proc() -> Chat_Effect { return Chat_Effect{kind = .None} }

chat_effect_destroy :: proc(effect: ^Chat_Effect) {
	effect^ = {}
}

// chat_session_observe applies facts that arrived from outside the owner: a worker's
// published result, a stop the session asked for, and the first sight of a call that
// should have stopped. It is the driver's collection step, so the state can be read
// without changing it.
chat_session_observe :: proc(chat: ^Chat_Session) {
	chat_session_observe_at(chat, time.tick_now())
}

// chat_session_observe_at is the same with the owner's clock supplied, so a driver that
// has already observed time does not read it twice and a test can supply it.
chat_session_observe_at :: proc(chat: ^Chat_Session, now: time.Tick) {
	if !chat.tool_jobs_active { return }
	tool_jobs_observe(&chat.tool_jobs, chat, now)
	if chat.tool_jobs.escaped { chat.worker_escaped = true }
}

// chat_session_tool_effect selects one bounded job-table effect while a batch is
// active. A batch that has not been admitted starts with Run_Tools; a settled batch
// ends with Finish_Tools. Nothing here runs an executor, waits, writes history, or
// adopts an observation: chat_session_observe has already brought those in.
@(private)
chat_session_tool_effect :: proc(chat: ^Chat_Session, now: time.Tick) -> Chat_Effect {
	if !chat.tool_jobs_active {
		return Chat_Effect{kind = .Run_Tools, turn_id = chat.active_turn_id}
	}
	next := tool_jobs_next(&chat.tool_jobs, now)
	switch next {
	case .Commit, .Refuse, .Abandon, .Retire, .Dispatch:
		return Chat_Effect{kind = .Step_Tools, turn_id = chat.active_turn_id, tool = next}
	case .Wait:
		return Chat_Effect{kind = .Wait_Tools, turn_id = chat.active_turn_id}
	case .Done:
		return Chat_Effect{kind = .Finish_Tools, turn_id = chat.active_turn_id}
	}
	return chat_effect_none()
}

// chat_session_advance selects the next effect for the current state, reading the clock
// for the caller that has no observation yet. Prefer chat_session_advance_at when the
// driver has one.
chat_session_advance :: proc(chat: ^Chat_Session) -> Chat_Effect {
	return chat_session_advance_at(chat, time.tick_now())
}

// chat_session_advance_at selects the next effect from the state as of now. It reads
// state and nothing else: no I/O, no lock, no logging, no allocation, and no counter
// change. The driver applies the transition the effect names, so calling it twice
// proposes the same work twice and launches or writes nothing.
chat_session_advance_at :: proc(chat: ^Chat_Session, now: time.Tick) -> Chat_Effect {
	switch chat.state {
	case .Idle, .Requesting:
		return chat_effect_none()
	case .Executing_Tools:
		return chat_session_tool_effect(chat, now)
	case .Preparing:
		return Chat_Effect{kind = .Start_Request, turn_id = chat.active_turn_id}
	case .Cancelling:
		// Tool jobs still have to settle their committed calls. Cancellation stops
		// admission; it does not permit dangling results or freed worker storage.
		if chat.tool_jobs_active { return chat_session_tool_effect(chat, now) }
		// Cancellation requested interruption; it did not stop anything. A cancelled
		// turn finalizes only after its operation is retired, which is the
		// confirmation that the request is no longer running.
		if chat.operation.state == .Running { return chat_effect_none() }
		return chat_finalize_turn(chat, .Cancelled)
	case .Finalizing:
		if chat.active_failed { return chat_finalize_turn(chat, .Failed) }
		return chat_finalize_turn(chat, .Completed)
	}
	return chat_effect_none()
}

// chat_session_begin_request claims the request the selector proposed. The claim is
// the transition: the turn starts receiving and the request it is about to send is
// counted. Only the driver's accepted transition calls it, so a proposal that was
// merely selected changes nothing.
//
// The claim re-reads its own precondition, because the boundary that settles input
// runs between the proposal and the claim: a boundary that stopped the turn, such as
// one whose durable write failed, claims nothing and no request is prepared from it.
chat_session_begin_request :: proc(chat: ^Chat_Session) -> bool {
	if chat.state != .Preparing { return false }
	chat.requests_made += 1
	chat.state = .Requesting
	return true
}

// Chat_Input_Point is what a running turn can do with input the front-end queued.
Chat_Input_Point :: enum {
	// A request boundary: nothing is outstanding, so an entry recorded now reads after every
	// answer the model has given and before the request the selector is about to propose.
	Boundary,
	// The turn answered and has nothing left to do: an entry recorded now is a message the
	// model has not answered, so the turn continues to the request that answers it.
	After_Answer,
	// A request is in flight, a tool batch has not committed its results, or the turn already
	// failed or was cancelled: recording now would read in the wrong place, so the line waits.
	Wait,
}

// chat_session_input_point names where the turn is for input it has not answered. Only the
// two settled points accept input: a boundary, and the end of an answered turn. A request in
// flight and a call without its result are not settled, because an entry placed there would
// be read where a result belongs; a turn that failed keeps its outcome instead of continuing.
chat_session_input_point :: proc(chat: ^Chat_Session) -> Chat_Input_Point {
	switch chat.state {
	case .Preparing:
		return .Boundary
	case .Finalizing:
		if chat.active_failed { return .Wait }
		return .After_Answer
	case .Idle, .Requesting, .Executing_Tools, .Cancelling:
	}
	return .Wait
}

// chat_session_continue_for_input returns a turn that had finished answering to preparing.
// The entry just recorded is a message the model has not answered, so the next request is
// the one that answers it instead of the turn ending without one.
chat_session_continue_for_input :: proc(chat: ^Chat_Session) {
	if chat.state != .Finalizing { return }
	chat.state = .Preparing
}

// chat_session_fail_turn records a turn-level failure and moves to finalizing.
chat_session_fail_turn :: proc(chat: ^Chat_Session, message: string) -> Chat_Effect {
	delete(chat.last_error, chat.allocator)
	chat.last_error = chat_clone_string(message, chat.allocator)
	chat.active_failed = true
	chat.state = .Finalizing
	return chat_effect_none()
}

// chat_finalize_turn is the only place a turn reaches a terminal status. Every
// terminal path goes through it and it returns the session to Idle in the same
// step, so a turn finalizes exactly once and the next turn can start immediately.
//
// The error text stays on the session: the driver reads it when it records and reports
// the terminal status, so the effect owns nothing and a turn costs no clone.
//
// Uncommitted assistant text is not dropped here; the driver records it as a
// partial entry when it settles the turn.
chat_finalize_turn :: proc(chat: ^Chat_Session, status: Chat_Terminal_Status) -> Chat_Effect {
	turn_id := chat.active_turn_id
	chat.terminal_status = status
	chat.state = .Idle
	chat.active_failed = false
	return Chat_Effect{kind = .Turn_Finished, turn_id = turn_id, status = status}
}

chat_terminal_text :: proc(status: Chat_Terminal_Status) -> string {
	switch status {
	case .None:
		return "no status"
	case .Completed:
		return "completed"
	case .Failed:
		return "request failed"
	case .Cancelled:
		return "turn cancelled"
	}
	return "no status"
}

chat_report_terminal :: proc(chat: ^Chat_Session, observer: Chat_Observer, status: Chat_Terminal_Status) {
	if status == .Completed {
		_observer_assistant_end(observer)
		return
	}
	if chat.last_error != "" {
		_observer_message(observer, .Error, fmt.tprintf("%s: %s", chat_terminal_text(status), chat.last_error))
	} else {
		_observer_message(observer, .Error, chat_terminal_text(status))
	}
}

// chat_session_feed_text accepts a streamed fragment and returns whether it
// belongs to the running request.
chat_session_feed_text :: proc(chat: ^Chat_Session, source: Chat_Event_Source, text: string) -> bool {
	if !chat_session_accepts_event(chat, source) { return false }
	append(&chat.partial_assistant, text)
	return true
}

chat_session_feed_completion :: proc(chat: ^Chat_Session, source: Chat_Event_Source) -> bool {
	if !chat_session_accepts_event(chat, source) { return false }
	chat.state = .Finalizing
	return true
}

// chat_session_feed_response_output stages the verbatim Responses output array
// for the response being assembled. The output is the replay record; display
// text and executable calls travel through their own feeds alongside it.
// Only the Responses API calls this; Chat Completions has no replayable
// output items to preserve.
chat_session_feed_response_output :: proc(chat: ^Chat_Session, source: Chat_Event_Source, output: string) -> bool {
	if !chat_session_accepts_event(chat, source) { return false }
	if output == "" { return true }
	if chat.pending_response_present { return false }
	chat.pending_response.output = chat_clone_string(output, chat.allocator)
	chat.pending_response_present = true
	return true
}

// chat_session_set_effort validates a level against the model's configured
// levels and applies it to the next request. An empty level clears the
// override back to provider default. Effort never touches in-flight work:
// the builder copies the selection when it freezes each request.
chat_session_set_effort :: proc(chat: ^Chat_Session, level: string) -> bool {
	if level == "" {
		delete(chat.effort, chat.allocator)
		chat.effort = ""
		return true
	}
	for allowed in chat.effort_levels {
		if allowed == level {
			delete(chat.effort, chat.allocator)
			chat.effort = chat_clone_string(level, chat.allocator)
			return true
		}
	}
	return false
}

// Chat_Steer_Result is what recording a steering line did. A line the session did not
// record was never the session's, which is a different fact from a line it recorded and a
// request has yet to carry.
Chat_Steer_Result :: enum {
	// Recorded at the running turn. The next request built from this history carries it.
	Recorded,
	// No turn has run in this session, so there is no request that could carry the line
	// and nothing to attach it to. It stays with whoever queued it.
	No_Turn,
	// The store refused the write, so the line was not recorded and the session recorded
	// why in last_error. It stays with whoever queued it.
	Storage_Failed,
}

// chat_session_repair_refusal is why the last turn could not repair a payload the
// provider rejected as too large, and None when that is not why it ended.
chat_session_repair_refusal :: proc(chat: ^Chat_Session) -> Chat_Repair_Refusal {
	return chat.turn_repair_refusal
}

// chat_session_recovery_reason is why the last turn's chain stopped, and whether a
// reason was recorded at all. A turn that ended for a reason of its own, such as a tool
// that failed, carries none.
chat_session_recovery_reason :: proc(chat: ^Chat_Session) -> Maybe(Request_Recovery_Reason) {
	return chat.turn_recovery
}

// chat_session_terminal_status is the status the last turn reached. A caller that has to
// act on how a turn ended reads it after the turn, because the effect that carried it was
// consumed by the loop that ran it.
chat_session_terminal_status :: proc(chat: ^Chat_Session) -> Chat_Terminal_Status {
	return chat.terminal_status
}

// chat_session_worker_escaped reports that a tool worker ignored its stop and still owns
// borrowed session data. The session can no longer run a turn or be released normally: the
// owner stops the runtime and the process exits with what that worker can still reach.
chat_session_worker_escaped :: proc(chat: ^Chat_Session) -> bool {
	return chat.worker_escaped
}

// CHAT_WORKER_ESCAPED_NOTICE is what a front-end shows for that condition. The runtime is
// stopping and teardown will not release what the worker can reach, so there is nothing
// for the user to do but exit.
CHAT_WORKER_ESCAPED_NOTICE :: "a tool call did not stop; the harness must exit"

// chat_session_steer records a queued line as a user entry of the running turn. Unlike
// accept_user it starts no turn and resets no budget: the turn keeps its identity and its
// counters, so a steering line changes what a later request sends, never work already
// committed. Recording is what makes the line the session's, and the entry is ordered
// where it is written, so the request that follows reads the line after everything that
// was committed before it.
chat_session_steer :: proc(chat: ^Chat_Session, text: string, at_ms: i64) -> Chat_Steer_Result {
	turn_no, has_turn := chat.turn_no.?
	if !has_turn { return .No_Turn }
	entry := session.New_Entry {
		turn_no = turn_no,
		created_at_ms = at_ms,
		payload = session.User_Entry{text = text, origin = .Steering},
	}
	if _, err := session.entry_append(chat.store, chat.id, entry); err != nil {
		chat_session_record_failure(chat, "the steering line could not be recorded", err)
		return .Storage_Failed
	}
	return .Recorded
}

chat_tool_call_clone :: proc(call: ai.Provider_Tool_Call, allocator: mem.Allocator) -> (Chat_Tool_Call, bool) {
	if call.ID == "" || call.Name == "" { return {}, false }
	return Chat_Tool_Call {
			id = chat_clone_string(call.ID, allocator),
			item_id = chat_clone_string(call.Item_ID, allocator),
			name = chat_clone_string(call.Name, allocator),
			arguments = chat_clone_string(call.Arguments, allocator),
		},
		true
}

// Chat_Notice is why a completed response could not be used as it stood. None
// means it was usable, and Ignored means the event did not belong to the running
// operation and nothing should happen at all. Every other member is a defect the
// model is told about: the response executes nothing, and the turn goes on to
// another request so the model can correct itself.
Chat_Notice :: enum {
	None,
	Ignored,
	Truncated,
	Missing_Call_Identity,
	Duplicate_Call_ID,
}

// chat_notice_text is the harness's own explanation of an unusable response. The
// text is a literal: the same notice always puts the same bytes into the
// conversation, so a recovery turn adds no avoidable churn to the cacheable
// prefix.
chat_notice_text :: proc(notice: Chat_Notice) -> string {
	switch notice {
	case .Truncated:
		return "the previous response was cut off by the output limit before it finished, so none of it was executed; reissue the work in smaller steps"
	case .Missing_Call_Identity:
		return "a proposed tool call carried no id or no tool name, so none of the calls ran; every call needs the provider's id and the tool's name"
	case .Duplicate_Call_ID:
		return "two proposed tool calls shared one id, so none of them ran; every call needs its own id"
	case .None, .Ignored:
		return ""
	}
	return ""
}

// chat_session_note_notice records that the running response was unusable and
// moves the turn on to another request. The notice itself is committed with the
// response that caused it, so the explanation follows the text it explains.
chat_session_note_notice :: proc(chat: ^Chat_Session, source: Chat_Event_Source, notice: Chat_Notice) -> bool {
	if !chat_session_accepts_event(chat, source) { return false }
	chat.pending_notice = notice
	chat.state = .Preparing
	return true
}

// chat_session_feed_tool_calls validates the calls a response assembled and
// stages them for execution. It reports None when they were staged, Ignored when
// the event did not belong to the running operation, and otherwise why the whole
// response was refused: calls are staged all at once or not at all, so a
// response is never half executed.
chat_session_feed_tool_calls :: proc(chat: ^Chat_Session, source: Chat_Event_Source, calls: []ai.Provider_Tool_Call) -> Chat_Notice {
	if !chat_session_accepts_event(chat, source) { return .Ignored }
	if len(calls) == 0 { return .Ignored }

	staged := make([dynamic]Chat_Tool_Call, 0, len(calls), chat.allocator)
	defer delete(staged)
	for call in calls {
		cloned, valid := chat_tool_call_clone(call, chat.allocator)
		if !valid {
			for &leftover in staged { chat_tool_call_destroy(&leftover, chat.allocator) }
			return .Missing_Call_Identity
		}
		for prior in staged {
			if prior.id == cloned.id {
				chat_tool_call_destroy(&cloned, chat.allocator)
				for &leftover in staged { chat_tool_call_destroy(&leftover, chat.allocator) }
				return .Duplicate_Call_ID
			}
		}
		append(&staged, cloned)
	}
	for staged_call in staged { append(&chat.pending_calls, staged_call) }
	clear(&staged)
	chat.state = .Executing_Tools
	return .None
}

chat_session_tools_done :: proc(chat: ^Chat_Session, turn_id: u64, results: int) -> bool {
	// A cancelled turn still resolves its committed calls, so its history stays
	// well formed even though no further request will be made.
	if chat.state != .Executing_Tools && chat.state != .Cancelling { return false }
	if chat.active_turn_id != turn_id { return false }
	if results != len(chat.pending_calls) { return false }
	chat.calls_made += len(chat.pending_calls)
	for &call in chat.pending_calls { chat_tool_call_destroy(&call, chat.allocator) }
	clear(&chat.pending_calls)
	// A cancelled turn resolves its committed calls but must not continue to another
	// request, so it stays in Cancelling for the finalization owner.
	if chat.state == .Executing_Tools { chat.state = .Preparing }
	return true
}

chat_session_feed_error :: proc(chat: ^Chat_Session, source: Chat_Event_Source, message: string) -> bool {
	if !chat_session_accepts_event(chat, source) { return false }
	delete(chat.last_error, chat.allocator)
	chat.last_error = chat_clone_string(message, chat.allocator)
	chat.active_failed = true
	chat.state = .Finalizing
	return true
}
