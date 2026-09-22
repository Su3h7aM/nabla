#+test
package agent

// Support shared by the agent package's test files. The chat suites run against
// a real store, because a session's history is the store now and a fake would
// test the fake instead of the harness.

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "nabla:agent/session"

// test_retry_policy is the policy the suites run with: the production bounds, with a
// wait short enough that a retry costs a test milliseconds instead of a second. A suite
// that cares about the decision itself states its own policy and calls
// chat_recovery_decide directly.
test_retry_policy :: proc() -> Chat_Retry_Policy {
	policy := chat_retry_policy_default()
	policy.base_delay = 2 * time.Millisecond
	policy.max_delay = 4 * time.Millisecond
	policy.max_provider_delay = 25 * time.Millisecond
	policy.slice = time.Millisecond
	return policy
}

// test_compact_retry_policy is what the compaction suites run with: the compaction chain's
// own bound, with a wait short enough that a retry costs a test milliseconds instead of a
// second.
test_compact_retry_policy :: proc() -> Chat_Retry_Policy {
	policy := chat_compact_retry_policy_default()
	policy.base_delay = 2 * time.Millisecond
	policy.max_delay = 4 * time.Millisecond
	policy.max_provider_delay = 25 * time.Millisecond
	policy.slice = time.Millisecond
	return policy
}

// Chat_Test binds a running session to a temporary store. The store lives in the
// fixture so its address is stable while the session points at it.
Chat_Test :: struct {
	store: session.Store,
	dir:   string,
	chat:  Chat_Session,
}

// Chat_Notice_Log is what a front-end was told during one call. A notice is the
// harness's only channel to the user, so a test that cares about one captures it
// here; the log is a different record and is asserted separately.
Chat_Notice_Log :: struct {
	lines:     [dynamic]string,
	allocator: mem.Allocator,
}

chat_notice_log_begin :: proc(log: ^Chat_Notice_Log, allocator := context.allocator) -> Chat_Observer {
	log.allocator = allocator
	log.lines = make([dynamic]string, 0, allocator)
	return Chat_Observer{user_data = log, message = chat_notice_log_capture}
}

@(private)
chat_notice_log_capture :: proc(user_data: rawptr, kind: Chat_Message_Kind, text: string) {
	_ = kind
	log := cast(^Chat_Notice_Log)user_data
	append(&log.lines, strings.clone(text, log.allocator))
}

chat_notice_log_destroy :: proc(log: ^Chat_Notice_Log) {
	for line in log.lines { delete(line, log.allocator) }
	delete(log.lines)
	log^ = {}
}

// chat_notice_log_count is how many notices carried this text. A caller asserts on a
// count rather than on wording, so a reworded notice does not fail the test.
chat_notice_log_count :: proc(log: ^Chat_Notice_Log, contains: string) -> int {
	count := 0
	for line in log.lines { if strings.contains(line, contains) { count += 1 } }
	return count
}

// chat_test_capacity gives a session the context budget a resolved model with this
// window and output bound would carry. It goes through model_capacity, so a test
// states the model it means rather than the window arithmetic.
chat_test_capacity :: proc(chat: ^Chat_Session, window: int, output := 0) {
	chat.capacity = model_capacity(
		Catalog_Model{context_window_present = true, context_window = window, max_output_tokens_present = output > 0, max_output_tokens = output},
	)
}

chat_test_begin :: proc(t: ^testing.T, fixture: ^Chat_Test, workspace: string) {
	directory, directory_err := os.make_directory_temp("", "nabla-agent-test-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "could not create a temporary directory") }
	fixture.dir = directory

	if err := session.store_open(&fixture.store, directory); err != nil {
		local := err
		testing.fail_now(t, strings.concatenate({"store_open failed: ", session.error_detail(&local)}, context.temp_allocator))
	}
	created, create_err := session.session_create(&fixture.store, {workspace = workspace}, 1_000)
	if create_err != nil { testing.fail_now(t, "session_create failed") }
	id := session.Session_Id(strings.clone(string(created.id), context.allocator))
	session.session_destroy(&created)

	if claim_err := session.session_claim(&fixture.store, id); claim_err != nil {
		testing.fail_now(t, "session_claim failed")
	}
	delete(string(id), context.allocator)

	// The running session borrows the id the claim owns, so the two cannot drift.
	claimed, held := session.session_claimed(&fixture.store)
	if !held { testing.fail_now(t, "the claim went missing") }
	fixture.chat = chat_session_init(&fixture.store, claimed, workspace, context.allocator)
	fixture.chat.provider_id = chat_clone_string("test-provider", context.allocator)
	fixture.chat.model_id = chat_clone_string("test-model", context.allocator)
	fixture.chat.skill_instructions = test_skill_instructions(&fixture.chat)
}

test_skill_instructions :: proc(chat: ^Chat_Session) -> string {
	return strings.clone(AGENT_SYSTEM_PROMPT, chat.allocator)
}

chat_test_end :: proc(t: ^testing.T, fixture: ^Chat_Test) {
	chat_session_destroy(&fixture.chat)
	session.session_release(&fixture.store)
	session.store_close(&fixture.store)
	os.remove_all(fixture.dir)
	delete(fixture.dir, context.allocator)
	fixture^ = {}
}

_test_accept :: proc(t: ^testing.T, chat: ^Chat_Session, text: string) {
	if chat_session_accept_user(chat, text, session.now_ms()) != .Accepted {
		testing.fail_now(t, "the prompt was not admitted")
	}
}

_test_begin_request :: proc(t: ^testing.T, chat: ^Chat_Session) -> Chat_Effect {
	effect := chat_session_advance(chat)
	if effect.kind != .Start_Request { testing.fail_now(t, "expected a request to start") }
	chat_session_begin_request(chat)
	chat_session_begin_operation(chat)
	return effect
}

_test_append :: proc(t: ^testing.T, chat: ^Chat_Session, entry: session.New_Entry) -> session.Seq {
	seq, err := session.entry_append(chat.store, chat.id, entry)
	if err != nil { testing.fail_now(t, "entry_append failed") }
	return seq
}

_test_entries :: proc(t: ^testing.T, chat: ^Chat_Session, allocator := context.allocator) -> []session.Entry {
	entries, err := session.entries_load(chat.store, chat.id, {}, allocator)
	if err != nil { testing.fail_now(t, "entries_load failed") }
	return entries
}

_test_context :: proc(t: ^testing.T, chat: ^Chat_Session, allocator := context.allocator) -> session.Context {
	ctx, err := session.context_load(chat.store, chat.id, allocator)
	if err != nil { testing.fail_now(t, "context_load failed") }
	return ctx
}

// _test_settle drives the turn to its terminal effect and records it, which is
// what the driver does when it sees a finished turn.
_test_settle :: proc(t: ^testing.T, chat: ^Chat_Session) -> Chat_Effect {
	finish := chat_session_advance(chat)
	if finish.kind != .Turn_Finished { testing.fail_now(t, "expected the turn to finish") }
	chat_session_claim_finish(chat, finish)
	chat_persist_turn_end(chat, finish)
	return finish
}

// _test_stage_call stages a provider call for execution exactly as a completed
// response does: the call entry is recorded first, and the staged call points at
// it, so the dispatch and the result can name the same call.
_test_stage_call :: proc(t: ^testing.T, chat: ^Chat_Session, id, arguments: string, name := TOOL_SHELL_NAME) {
	seq := _test_append(
		t,
		chat,
		{
			turn_no = chat.turn_no,
			request_no = chat.active_request,
			created_at_ms = session.now_ms(),
			payload = session.Tool_Call_Entry{call_id = id, name = name, arguments = arguments},
		},
	)
	append(
		&chat.pending_calls,
		Chat_Tool_Call {
			id = chat_clone_string(id, chat.allocator),
			name = chat_clone_string(name, chat.allocator),
			arguments = chat_clone_string(arguments, chat.allocator),
			seq = seq,
		},
	)
	chat.state = .Executing_Tools
}

// chat_run_tools runs the committed calls through the same job table the driver uses and
// returns the number of committed root results. It is the synchronous adapter for tests
// that do not need to observe the intermediate job phases; this file is test-only, so
// production has exactly one tool driver.
@(private)
chat_run_tools :: proc(chat: ^Chat_Session, observer: Chat_Observer) -> int {
	jobs: Tool_Jobs
	// Job-owned storage comes from the process heap: a worker thread allocates while the
	// owner may be allocating too, so the two never share one allocator.
	tool_jobs_init(&jobs, chat, len(chat.pending_calls), os.heap_allocator())
	defer tool_jobs_destroy(&jobs)

	tool_jobs_submit(&jobs, chat, observer)
	for _ in 0 ..< 100_000 {
		now := time.tick_now()
		tool_jobs_observe(&jobs, chat, now)
		switch tool_jobs_next(&jobs, now) {
		case .Commit:
			tool_jobs_commit(&jobs, chat, observer)
		case .Refuse:
			tool_jobs_refuse(&jobs)
		case .Abandon:
			tool_jobs_abandon(&jobs, chat, observer, now)
		case .Retire:
			tool_jobs_retire(&jobs, now)
		case .Dispatch:
			tool_jobs_dispatch(&jobs, chat)
		case .Wait:
			tool_jobs_wait(&jobs)
		case .Done:
			return tool_jobs_committed(&jobs)
		}
	}
	return 0
}
