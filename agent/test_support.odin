#+test
package agent

// Support shared by the agent package's test files. The chat suites run against
// a real journal, because a session's history is the journal and a fake would
// test the fake instead of the harness.

import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

// test_retry_policy is the policy the suites run with: the production backoff, with a
// wait short enough that a retry costs a test milliseconds instead of a second. A suite
// that cares about the decision itself states its own policy and calls
// chat_recovery_decide directly.
test_retry_policy :: proc() -> Chat_Retry_Policy {
	policy := chat_retry_policy_default()
	policy.base_delay = 2 * time.Millisecond
	policy.max_delay = 4 * time.Millisecond
	return policy
}

// Chat_Test binds a running session to a journal in a temporary directory. The
// journal lives in the fixture so its address is stable while the session points at it.
Chat_Test :: struct {
	store:     journal.Journal,
	directory: string,
	chat:      Chat_Session,
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
	// A notice that cannot be copied is not captured; the test's own count is what reports it.
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
	for line in log.lines {
		if strings.contains(line, contains) { count += 1 }
	}
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

chat_test_begin :: proc(test: ^testing.T, fixture: ^Chat_Test, workspace: string) {
	directory, directory_error := os.make_directory_temp("", "nabla-agent-test-*", context.allocator)
	if directory_error != nil { testing.fail_now(test, "could not create a temporary directory") }
	fixture.directory = directory

	if open_error := journal.open(&fixture.store, directory, directory, journal.run_id_create(), .Read_Write); open_error != nil {
		testing.fail_now(
			test,
			strings.concatenate({"the journal could not be opened: ", journal.error_text(open_error, context.temp_allocator)}, context.temp_allocator),
		)
	}
	session, create_error := journal.create_session(&fixture.store, {workspace = workspace, role = .Main})
	if create_error != nil { testing.fail_now(test, "the session could not be created") }

	tool_error: Tool_Registry_Error
	fixture.chat, tool_error = chat_session_init(&fixture.store, session, journal.INITIAL_BRANCH, 0, workspace, context.allocator)
	if tool_error.kind != .None { testing.fail_now(test, "the tool registry could not be created") }
	fixture.chat.provider_id = chat_clone_string("test-provider", context.allocator) or_else ""
	fixture.chat.model_id = chat_clone_string("test-model", context.allocator) or_else ""
	fixture.chat.skill_instructions = test_skill_instructions(&fixture.chat)
	// Kept outputs go under the fixture's own directory, never the user's cache directory.
	delete(fixture.chat.tool_output_directory, context.allocator)
	tool_output_directory, join_error := os.join_path({directory, "tool-output"}, context.allocator)
	if join_error != nil { testing.fail_now(test, "the tool output directory could not be allocated") }
	fixture.chat.tool_output_directory = tool_output_directory
}

test_skill_instructions :: proc(chat: ^Chat_Session) -> string {
	return strings.clone(AGENT_SYSTEM_PROMPT, chat.allocator)
}

chat_test_end :: proc(test: ^testing.T, fixture: ^Chat_Test) {
	chat_session_destroy(&fixture.chat)
	if close_error := journal.close(&fixture.store); close_error != nil {
		testing.expectf(test, false, "the journal did not close: %s", journal.error_text(close_error, context.temp_allocator))
	}
	// The fixture's directory is abandoned; a removal that fails changes nothing in a test.
	_ = os.remove_all(fixture.directory)
	delete(fixture.directory, context.allocator)
	fixture^ = {}
}

_test_accept :: proc(test: ^testing.T, chat: ^Chat_Session, text: string) {
	if chat_session_accept_user(chat, text) != .Accepted {
		testing.fail_now(test, "the prompt was not admitted")
	}
}

_test_begin_request :: proc(test: ^testing.T, chat: ^Chat_Session) -> Chat_Effect {
	effect := chat_session_advance(chat)
	if effect.kind != .Start_Request { testing.fail_now(test, "expected a request to start") }
	chat_session_begin_request(chat)
	chat_session_begin_operation(chat)
	return effect
}

// _test_perform_request drives one logical request through the same effects the driver
// performs, for a suite that needs a settled request without a turn loop. The connection
// is expected to fail without a retry, so no backoff is waited.
@(private)
_test_perform_request :: proc(
	test: ^testing.T,
	chat: ^Chat_Session,
	connection: ai.Provider_Connection,
	policy: Chat_Retry_Policy,
	observer: Chat_Observer,
	usages: ^[dynamic]Chat_Request_Usage,
) {
	chat_request_begin(chat, connection, policy, observer)
	for {
		effect := chat_session_advance(chat)
		switch effect.kind {
		case .Send_Attempt:
			chat_chain_claim_send(chat)
			chat_chain_launch_send(chat)
		case .Await_Provider:
			// The attempt runs on a worker, so this is a real wait for its terminal outcome.
			chat_chain_await(chat, usages)
		case .Commit_Response:
			chat_chain_commit(chat, usages)
			return
		case .None, .Start_Request, .Wait_Retry, .Repair_Context, .Run_Tools, .Step_Tools, .Wait_Tools, .Finish_Tools, .Turn_Finished:
			testing.fail_now(test, "the request did not settle")
		}
	}
}

// _test_commit commits what a test buffered through the chat's journal.
_test_commit :: proc(test: ^testing.T, chat: ^Chat_Session) {
	if !chat_commit(chat, "the test history could not be recorded") { testing.fail_now(test, chat.last_error) }
}

// _test_user commits a User node, as a prompt or steering line would.
_test_user :: proc(test: ^testing.T, chat: ^Chat_Session, text: string, origin := journal.User_Origin.Steering) -> journal.Node_Id {
	node := chat_node(chat, .User, journal.User{origin = journal.USER_ORIGIN_NAMES[origin]}, transmute([]u8)text)
	_test_commit(test, chat)
	return node
}

// _test_response commits an Assistant node for a response of request, with its native
// output when one is given, as a completed response would, and makes it the node the
// next calls belong to.
_test_response :: proc(test: ^testing.T, chat: ^Chat_Session, request: journal.Request_Id, text: string, output := "") -> journal.Node_Id {
	node := chat_node(chat, .Assistant, journal.Assistant{request = request}, transmute([]u8)text)
	header := journal.Record {
		kind     = .Response_Committed,
		node     = node,
		request  = request,
		attempt  = 1,
		provider = chat.provider_id,
		model    = chat.model_id,
	}
	chat_record(chat, header, journal.Response_Committed{finish = journal.RESPONSE_FINISH_NAMES[.Stop]}, transmute([]u8)output)
	_test_commit(test, chat)
	chat.response_node = node
	return node
}

// _test_propose commits a tool.proposed record under the chat's response node and
// returns its call id.
_test_propose :: proc(
	test: ^testing.T,
	chat: ^Chat_Session,
	id, arguments: string,
	name := TOOL_SHELL_NAME,
	request: journal.Request_Id = 0,
) -> journal.Call_Id {
	call := journal.next_call(chat.store)
	chat_record(
		chat,
		{kind = .Tool_Proposed, node = chat.response_node, request = request, call = call},
		journal.Tool_Proposed{provider_id = id, name = name},
		transmute([]u8)arguments,
	)
	_test_commit(test, chat)
	return call
}

// _test_stage_call stages a provider call for execution exactly as a completed
// response does: its proposal is committed under an Assistant node first, and the
// staged call carries its id, so the admission and the result name the same call.
_test_stage_call :: proc(test: ^testing.T, chat: ^Chat_Session, id, arguments: string, name := TOOL_SHELL_NAME) {
	if chat.response_node == 0 { _test_response(test, chat, chat.request, "") }
	call := _test_propose(test, chat, id, arguments, name, chat.request)
	// A call that cannot be queued is not staged; the test's own assertions report it.
	append(
		&chat.pending_calls,
		Chat_Tool_Call {
			id = chat_clone_string(id, chat.allocator) or_else "",
			name = chat_clone_string(name, chat.allocator) or_else "",
			arguments = chat_clone_string(arguments, chat.allocator) or_else "",
			call = call,
		},
	)
	chat.state = .Executing_Tools
}

// _test_records reads the session's records of the given kinds, oldest first, into the
// temp allocator.
_test_records :: proc(test: ^testing.T, chat: ^Chat_Session, kinds: bit_set[journal.Record_Kind;u128]) -> []journal.Record {
	records, _, read_error := journal.read_records(chat.store, {session = chat.session, kinds = kinds}, 0, 0, context.temp_allocator)
	if read_error != nil { testing.fail_now(test, "the records could not be read") }
	return records
}

// _test_projection reads the projection from the chat's head into arena, which the
// caller initializes and destroys.
_test_projection :: proc(test: ^testing.T, chat: ^Chat_Session, arena: ^virtual.Arena) -> Projection {
	projection, load_error := projection_load(chat.store, chat.session, chat.head, virtual.arena_allocator(arena))
	if load_error != nil { testing.fail_now(test, "the projection could not be read") }
	return projection
}

// _test_settle drives the turn to its terminal effect and records it, which is
// what the driver does when it sees a finished turn.
_test_settle :: proc(test: ^testing.T, chat: ^Chat_Session) -> Chat_Effect {
	finish := chat_session_advance(chat)
	if finish.kind != .Turn_Finished { testing.fail_now(test, "expected the turn to finish") }
	chat_session_claim_finish(chat, finish)
	testing.expect(test, chat_persist_turn_end(chat, finish))
	return finish
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
			tool_jobs_await(&jobs, tool_jobs_deadline(&jobs))
		case .Done:
			committed := tool_jobs_committed(&jobs)
			if !chat_commit_results(chat, jobs.committed_roots) { return 0 }
			return committed
		}
	}
	return 0
}
