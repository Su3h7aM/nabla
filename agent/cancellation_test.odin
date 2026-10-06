#+test
package agent

import "core:mem/virtual"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

// Cancellation is a request, not an outcome: the turn keeps its operation until
// retirement confirms it stopped, and only then does the single finalization owner
// settle the turn.
@(test)
test_cancelled_turn_retires_then_next_turn_runs :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "first")

	effect := _test_begin_request(test, chat)
	first_turn := effect.turn_id
	first_operation := chat.operation.id

	testing.expect(test, chat_session_feed_text(chat, chat_session_event_source(chat), "partial"))

	testing.expect(test, chat_session_request_cancel(chat))
	testing.expect_value(test, chat.state, Chat_State.Cancelling)
	// Requested, not retired: the operation is still running and still owns its
	// interrupt token.
	testing.expect_value(test, chat.operation.state, Chat_Operation_State.Running)
	testing.expect(test, chat_session_cancelled(chat))

	// The turn cannot settle while its operation is outstanding.
	pending := chat_session_advance(chat)
	testing.expect_value(test, pending.kind, Chat_Effect_Kind.None)
	testing.expect_value(test, chat.state, Chat_State.Cancelling)

	chat_session_retire_operation(chat)
	finish := chat_session_advance(chat)
	testing.expect_value(test, finish.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(test, finish.status, Chat_Terminal_Status.Cancelled)
	chat_session_claim_finish(chat, finish)
	testing.expect(test, chat_persist_turn_end(chat, finish))
	testing.expect_value(test, chat.state, Chat_State.Idle)

	// The turn's prompt and the text it produced before stopping are both kept:
	// the text is marked partial, so it is evidence and not an answer.
	ancestry, ancestry_error := journal.read_ancestry(chat.store, chat.session, chat.head, context.temp_allocator)
	if !testing.expect_value(test, ancestry_error, nil) { return }
	if !testing.expect_value(test, len(ancestry), 2) { return }
	testing.expect_value(test, ancestry[0].kind, journal.Node_Kind.User)
	if !testing.expect_value(test, ancestry[1].kind, journal.Node_Kind.Assistant) { return }
	assistant: journal.Assistant
	if !testing.expect_value(test, journal.payload_decode(ancestry[1].data, &assistant, context.temp_allocator), nil) { return }
	testing.expect_value(test, string(ancestry[1].body), "partial")
	testing.expect(test, assistant.partial, "text from a cancelled turn is partial")
	// The partial answer is evidence, never a finished answer a request reads.
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	projection := _test_projection(test, chat, &arena)
	testing.expect_value(test, len(projection.items), 1)

	// The turn's outcome reached the journal with the status the turn reached.
	turns := _test_records(test, chat, {.Turn_Completed})
	if !testing.expect_value(test, len(turns), 1) { return }
	completion: journal.Turn_Completed
	if !testing.expect_value(test, journal.payload_decode(turns[0].data, &completion, context.temp_allocator), nil) { return }
	testing.expect_value(test, completion.outcome, journal.TURN_OUTCOME_NAMES[.Cancelled])

	// A new turn starts immediately, with a fresh operation identity.
	_test_accept(test, chat, "second")
	testing.expect(test, chat.active_turn_id == first_turn + 1)
	effect = _test_begin_request(test, chat)
	testing.expect_value(test, chat.operation.id, first_operation + 1)
	testing.expect(test, chat_session_feed_completion(chat, chat_session_event_source(chat)))
	finish = chat_session_advance(chat)
	testing.expect_value(test, finish.status, Chat_Terminal_Status.Completed)
	chat_session_claim_finish(chat, finish)
	testing.expect(test, chat_persist_turn_end(chat, finish))
}

// Events are identified by turn and operation. An event from a superseded operation
// must not reach the current turn, even when it arrives after a new turn started.
@(test)
test_stale_operation_events_are_rejected :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "first")

	effect := _test_begin_request(test, chat)
	stale := chat_session_event_source(chat)
	testing.expect(test, chat_session_request_cancel(chat))
	chat_session_retire_operation(chat)
	finish := chat_session_advance(chat)
	chat_session_claim_finish(chat, finish)
	testing.expect(test, chat_persist_turn_end(chat, finish))

	_test_accept(test, chat, "second")
	effect = _test_begin_request(test, chat)
	current := chat_session_event_source(chat)
	testing.expect(test, current.operation_id != stale.operation_id)
	testing.expect(test, current.turn_id != stale.turn_id)

	testing.expect(test, !chat_session_feed_completion(chat, stale))
	testing.expect_value(test, chat.state, Chat_State.Requesting)
	testing.expect(test, !chat_session_feed_text(chat, stale, "stale text"))
	testing.expect_value(test, len(chat.partial_assistant), 0)
	testing.expect(test, !chat_session_feed_error(chat, stale, "stale error"))
	testing.expect_value(test, chat.last_error, "")
	calls := []ai.Provider_Tool_Call{{ID = "stale_call", Name = TOOL_SHELL_NAME, Arguments = `{}`}}
	stale_notice, _ := chat_session_feed_tool_calls(chat, stale, calls)
	testing.expect_value(test, stale_notice, Chat_Notice.Ignored)
	// An operation id from another turn, and a turn id with the current operation,
	// are both rejected.
	testing.expect(test, !chat_session_feed_completion(chat, Chat_Event_Source{turn_id = current.turn_id, operation_id = stale.operation_id}))
	testing.expect(test, !chat_session_feed_completion(chat, Chat_Event_Source{turn_id = stale.turn_id, operation_id = current.operation_id}))
	testing.expect(test, chat.operation.id != stale.operation_id)
}

// One owner finalizes each turn, and a turn reaches a terminal status once.
@(test)
test_turn_finalizes_exactly_once :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "once")

	effect := _test_begin_request(test, chat)
	testing.expect(test, chat_session_feed_completion(chat, chat_session_event_source(chat)))

	finish := chat_session_advance(chat)
	testing.expect_value(test, finish.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(test, finish.status, Chat_Terminal_Status.Completed)
	chat_session_claim_finish(chat, finish)
	testing.expect(test, chat_persist_turn_end(chat, finish))

	// No second terminal effect, and no later transition.
	again := chat_session_advance(chat)
	testing.expect_value(test, again.kind, Chat_Effect_Kind.None)
	testing.expect_value(test, chat.state, Chat_State.Idle)
	testing.expect_value(test, chat.terminal_status, Chat_Terminal_Status.Completed)
	// A completed turn cannot be relabelled as cancelled.
	testing.expect(test, !chat_session_request_cancel(chat))
	testing.expect_value(test, chat.terminal_status, Chat_Terminal_Status.Completed)
}

// --- an attempt whose worker ignores its stop ---------------------------------

// Chain_Attempt_Hold stands in for the attempt's worker: it ignores the stop it is given until
// the test releases it, and then returns as a worker that finally finished would. A real
// attempt's worker is a transport that observes cancellation, so only a hold like this can
// outlive its stop. The attempt is the first field, so the hold is the attempt record's own
// heap allocation and the owner's release of the attempt frees it: a test never does.
Chain_Attempt_Hold :: struct {
	attempt: Chat_Request_Worker,
	release: sync.Sema,
}

// CHAIN_HOLD_BOUND is how long a hold ignores its stop. It outlasts anything a test waits, so a
// test that abandons one never waits for the hold to give up by itself.
CHAIN_HOLD_BOUND :: time.Minute

chain_attempt_hold_serve :: proc(job: ^Job) {
	hold := cast(^Chain_Attempt_Hold)job
	_ = sync.sema_wait_with_timeout(&hold.release, CHAIN_HOLD_BOUND)
}

// chain_attempt_hold_start runs hold as the claimed attempt's worker. It stands in for
// chat_chain_launch_send, which starts the real transport instead.
@(private)
chain_attempt_hold_start :: proc(chat: ^Chat_Session, hold: ^Chain_Attempt_Hold) -> bool {
	chain := &chat.chain
	if chain.mailbox == nil {
		box, box_error := new(Owner_Mailbox, virtual.arena_allocator(&chain.scratch))
		if box_error != nil { return false }
		mailbox_init(box, os.heap_allocator())
		chain.mailbox = box
	}
	hold.attempt = {
		worker = {
			kind = .Provider_Attempt,
			run = chain_attempt_hold_serve,
			allocator = os.heap_allocator(),
			record = {request = chain.request, attempt = journal.Attempt_No(chain.attempts)},
		},
		mailbox = chain.mailbox,
	}
	if !job_launch(&hold.attempt.worker) { return false }
	chain.attempt = &hold.attempt
	return true
}

// An attempt whose worker ignores its stop is abandoned at the patience rather than waited for:
// its outcome is recorded, the turn ends, the session takes the next turn, and the attempt is
// released once its worker finally publishes.
@(test)
test_an_attempt_that_ignores_its_stop_is_abandoned :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, 500_000)

	hold := new(Chain_Attempt_Hold, os.heap_allocator())
	released := false
	defer if !released { sync.sema_post(&hold.release) }

	_test_accept(test, chat, "an attempt that never answers")
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = "http://127.0.0.1:1",
	}
	chat_request_begin(chat, connection, test_retry_policy(), {})
	testing.expect(test, chat_chain_claim_send(chat))
	testing.expect_value(test, chat.chain.stage, Chat_Request_Stage.Sending)
	if !chain_attempt_hold_start(chat, hold) {
		testing.fail_now(test, "the stuck attempt's worker could not be started")
	}

	// The turn is cancelled, and the owner's patience for the worker starts where it first saw
	// the stop: this observation is past the end of it.
	testing.expect(test, chat_session_request_cancel(chat))
	job_note_stop(&chat.chain.attempt.worker, true, time.tick_add(time.tick_now(), -(TOOL_JOBS_STOP_PATIENCE + time.Millisecond)))

	usages := make([dynamic]Chat_Request_Usage, 0, chat.allocator)
	defer delete(usages)
	// The owner stops waiting for it: the attempt is abandoned instead of joined, and its send
	// is recorded as the cancellation that asked it to stop.
	chat_chain_await(chat, &usages, owner_wake_seen())
	testing.expect_value(test, chat.chain.stage, Chat_Request_Stage.Committing)
	testing.expect_value(test, chat.chain.attempt.worker.phase, Job_Phase.Abandoned)
	request := chat.chain.request
	chat_chain_commit(chat, &usages)

	testing.expect_value(test, chat.chain.attempt, nil)
	testing.expect_value(test, len(chat.abandoned), 1)
	interrupted := _test_records(test, chat, {.Request_Interrupted})
	if !testing.expect_value(test, len(interrupted), 1) { return }
	testing.expect_value(test, interrupted[0].request, request)

	// The turn ends, and the session takes the next one with the worker still outstanding.
	finish := _test_settle(test, chat)
	testing.expect_value(test, finish.status, Chat_Terminal_Status.Cancelled)
	testing.expect(test, chat_session_workers_outstanding(chat), "an abandoned worker is outstanding")
	_test_accept(test, chat, "the turn after the abandoned attempt")
	_test_begin_request(test, chat)
	testing.expect(test, chat_session_feed_completion(chat, chat_session_event_source(chat)))
	next := _test_settle(test, chat)
	testing.expect_value(test, next.status, Chat_Terminal_Status.Completed)

	// The worker publishes at last, and the owner releases the attempt then: its result is
	// dropped, and nothing it reached is still kept.
	sync.sema_post(&hold.release)
	released = true
	deadline := time.tick_add(time.tick_now(), SHELL_TEST_BOUND)
	for len(chat.abandoned) > 0 && time.tick_since(deadline) < 0 {
		chat_session_observe_at(chat, time.tick_now())
		time.sleep(time.Millisecond)
	}
	testing.expect_value(test, len(chat.abandoned), 0)
	testing.expect(test, !chat_session_workers_outstanding(chat))
}
