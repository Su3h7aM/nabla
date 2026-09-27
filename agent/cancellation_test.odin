#+test
package agent

import "core:mem/virtual"
import "core:testing"

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
	chat_persist_turn_end(chat, finish)
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
	chat_persist_turn_end(chat, finish)
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
	chat_persist_turn_end(chat, finish)

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
	testing.expect_value(test, chat_session_feed_tool_calls(chat, stale, calls), Chat_Notice.Ignored)
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
	chat_persist_turn_end(chat, finish)

	// No second terminal effect, and no later transition.
	again := chat_session_advance(chat)
	testing.expect_value(test, again.kind, Chat_Effect_Kind.None)
	testing.expect_value(test, chat.state, Chat_State.Idle)
	testing.expect_value(test, chat.terminal_status, Chat_Terminal_Status.Completed)
	// A completed turn cannot be relabelled as cancelled.
	testing.expect(test, !chat_session_request_cancel(chat))
	testing.expect_value(test, chat.terminal_status, Chat_Terminal_Status.Completed)
}
