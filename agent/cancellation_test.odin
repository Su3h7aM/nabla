#+test
package agent

import "core:testing"
import "core:time"

import "nabla:agent/session"
import "nabla:ai"

// Cancellation is a request, not an outcome: the turn keeps its operation until
// retirement confirms it stopped, and only then does the single finalization owner
// settle the turn.
@(test)
test_cancelled_turn_retires_then_next_turn_runs :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "first")

	effect := _test_begin_request(t, chat)
	first_turn := effect.turn_id
	first_operation := chat.operation.id
	chat_effect_destroy(&effect)

	testing.expect(t, chat_session_feed_text(chat, chat_session_event_source(chat), "partial"))

	testing.expect(t, chat_session_request_cancel(chat))
	testing.expect_value(t, chat.state, Chat_State.Cancelling)
	// Requested, not retired: the operation is still running and still owns its
	// interrupt token and deadline.
	testing.expect_value(t, chat.operation.state, Chat_Operation_State.Running)
	testing.expect(t, chat_session_cancelled(chat))

	// The turn cannot settle while its operation is outstanding.
	pending := chat_session_advance(chat)
	testing.expect_value(t, pending.kind, Chat_Effect_Kind.None)
	chat_effect_destroy(&pending)
	testing.expect_value(t, chat.state, Chat_State.Cancelling)

	chat_session_retire_operation(chat)
	finish := chat_session_advance(chat)
	testing.expect_value(t, finish.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Cancelled)
	chat_persist_turn_end(chat, finish)
	chat_effect_destroy(&finish)
	testing.expect_value(t, chat.state, Chat_State.Idle)

	// The turn's prompt and the text it produced before stopping are both kept:
	// the text is marked partial, so it is evidence and not an answer.
	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	if !testing.expect_value(t, len(entries), 2) { return }
	testing.expect_value(t, entries[0].kind, session.Entry_Kind.User)
	assistant, is_assistant := entries[1].payload.(session.Assistant_Entry)
	if !testing.expect(t, is_assistant, "the second entry should be assistant text") { return }
	testing.expect_value(t, assistant.text, "partial")
	testing.expect(t, assistant.partial, "text from a cancelled turn is partial")
	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	testing.expect_value(t, len(ctx.entries), 1)

	// A new turn starts immediately, with a fresh operation identity.
	_test_accept(t, chat, "second")
	testing.expect(t, chat.active_turn_id == first_turn + 1)
	effect = _test_begin_request(t, chat)
	testing.expect_value(t, chat.operation.id, first_operation + 1)
	chat_effect_destroy(&effect)
	testing.expect(t, chat_session_feed_completion(chat, chat_session_event_source(chat)))
	finish = chat_session_advance(chat)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Completed)
	chat_persist_turn_end(chat, finish)
	chat_effect_destroy(&finish)
}

// Events are identified by turn and operation. An event from a superseded operation
// must not reach the current turn, even when it arrives after a new turn started.
@(test)
test_stale_operation_events_are_rejected :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "first")

	effect := _test_begin_request(t, chat)
	stale := chat_session_event_source(chat)
	chat_effect_destroy(&effect)
	testing.expect(t, chat_session_request_cancel(chat))
	chat_session_retire_operation(chat)
	finish := chat_session_advance(chat)
	chat_persist_turn_end(chat, finish)
	chat_effect_destroy(&finish)
	chat_cancel_reset()

	_test_accept(t, chat, "second")
	effect = _test_begin_request(t, chat)
	current := chat_session_event_source(chat)
	chat_effect_destroy(&effect)
	testing.expect(t, current.operation_id != stale.operation_id)
	testing.expect(t, current.turn_id != stale.turn_id)

	testing.expect(t, !chat_session_feed_completion(chat, stale))
	testing.expect_value(t, chat.state, Chat_State.Requesting)
	testing.expect(t, !chat_session_feed_text(chat, stale, "stale text"))
	testing.expect_value(t, len(chat.partial_assistant), 0)
	testing.expect(t, !chat_session_feed_error(chat, stale, "stale error"))
	testing.expect_value(t, chat.last_error, "")
	calls := []ai.Provider_Tool_Call{{ID = "stale_call", Name = TOOL_SHELL_NAME, Arguments = `{}`}}
	testing.expect(t, !chat_session_feed_tool_calls(chat, stale, calls))
	// An operation id from another turn, and a turn id with the current operation,
	// are both rejected.
	testing.expect(t, !chat_session_feed_completion(chat, Chat_Event_Source{turn_id = current.turn_id, operation_id = stale.operation_id}))
	testing.expect(t, !chat_session_feed_completion(chat, Chat_Event_Source{turn_id = stale.turn_id, operation_id = current.operation_id}))
	testing.expect_value(t, chat.active_operation_id, current.operation_id)
}

// One owner finalizes each turn, and a turn reaches a terminal status once.
@(test)
test_turn_finalizes_exactly_once :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "once")

	effect := _test_begin_request(t, chat)
	chat_effect_destroy(&effect)
	testing.expect(t, chat_session_feed_completion(chat, chat_session_event_source(chat)))

	finish := chat_session_advance(chat)
	testing.expect_value(t, finish.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Completed)
	chat_persist_turn_end(chat, finish)
	chat_effect_destroy(&finish)

	// No second terminal effect, and no later transition.
	again := chat_session_advance(chat)
	testing.expect_value(t, again.kind, Chat_Effect_Kind.None)
	chat_effect_destroy(&again)
	testing.expect_value(t, chat.state, Chat_State.Idle)
	testing.expect_value(t, chat.terminal_status, Chat_Terminal_Status.Completed)
	// A completed turn cannot be relabelled as cancelled.
	testing.expect(t, !chat_session_request_cancel(chat))
	testing.expect_value(t, chat.terminal_status, Chat_Terminal_Status.Completed)
}

// The operation deadline is what the transport enforces while a request is in
// flight; the turn deadline is observed only at operation boundaries. They are
// separate facts, and the operation is clamped so it cannot outlive the turn.
@(test)
test_operation_deadline_distinct_from_turn_deadline :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "deadlines")

	effect := _test_begin_request(t, chat)
	chat_effect_destroy(&effect)
	operation_remaining, operation_active := ai.deadline_remaining(chat.operation.deadline)
	turn_remaining, turn_active := ai.deadline_remaining(chat.turn_deadline)
	testing.expect(t, operation_active)
	testing.expect(t, turn_active)
	testing.expectf(t, operation_remaining < turn_remaining, "operation bound %v is not tighter than turn bound %v", operation_remaining, turn_remaining)
	testing.expect(t, operation_remaining <= CHAT_OPERATION_DEADLINE)
	testing.expect(t, turn_remaining <= CHAT_TURN_DEADLINE)

	// A turn with less time left than an operation allows clamps the operation.
	chat.turn_deadline = ai.deadline_in(50 * time.Millisecond)
	chat_session_retire_operation(chat)
	chat_session_begin_operation(chat)
	clamped, clamped_active := ai.deadline_remaining(chat.operation.deadline)
	testing.expect(t, clamped_active)
	testing.expectf(t, clamped <= 50 * time.Millisecond, "operation was not clamped to the turn bound: %v", clamped)
	chat_session_retire_operation(chat)

	// An expired turn bound stops the turn at an operation boundary.
	chat.state = Chat_State.Preparing
	chat.turn_deadline = ai.deadline_in(-1 * time.Second)
	expired := chat_session_advance(chat)
	testing.expect_value(t, expired.kind, Chat_Effect_Kind.None)
	chat_effect_destroy(&expired)
	failure := chat_session_advance(chat)
	testing.expect_value(t, failure.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(t, failure.status, Chat_Terminal_Status.Failed)
	testing.expect_value(t, failure.error, "turn deadline exceeded")
	chat_effect_destroy(&failure)
}
