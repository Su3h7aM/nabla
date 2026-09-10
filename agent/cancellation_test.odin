package agent

import "core:testing"
import "core:time"

import "nabla:ai"

// Cancellation is a request, not an outcome: the turn keeps its operation until
// retirement confirms it stopped, and only then does the single finalization owner
// settle the turn.
@(test)
test_cancelled_turn_retires_then_next_turn_runs :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.tools_enabled = true
	testing.expect(t, chat_session_accept_user(&session, "first"))

	effect := tool_loop_begin_request(&session)
	first_turn := effect.turn_id
	first_operation := session.operation.id
	chat_effect_destroy(&effect)

	published := chat_session_feed_text(&session, chat_session_event_source(&session), "partial")
	testing.expect_value(t, published.kind, Chat_Effect_Kind.Publish_Text)
	chat_effect_destroy(&published)

	testing.expect(t, chat_session_request_cancel(&session))
	testing.expect_value(t, session.state, Chat_State.Cancelling)
	// Requested, not retired: the operation is still running and still owns its
	// interrupt token and deadline.
	testing.expect_value(t, session.operation.state, Chat_Operation_State.Running)
	testing.expect(t, chat_session_cancelled(&session))

	// The turn cannot settle while its operation is outstanding.
	pending := chat_session_advance(&session)
	testing.expect_value(t, pending.kind, Chat_Effect_Kind.None)
	chat_effect_destroy(&pending)
	testing.expect_value(t, session.state, Chat_State.Cancelling)

	chat_session_retire_operation(&session)
	finish := chat_session_advance(&session)
	testing.expect_value(t, finish.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Cancelled)
	chat_effect_destroy(&finish)
	testing.expect_value(t, session.state, Chat_State.Idle)
	// Partial text is discarded rather than committed as an assistant response.
	testing.expect_value(t, len(session.messages), 1)

	// A new turn starts immediately, with a fresh operation identity.
	testing.expect(t, chat_session_accept_user(&session, "second"))
	testing.expect_value(t, session.active_turn_id, first_turn + 1)
	effect = tool_loop_begin_request(&session)
	testing.expect_value(t, session.operation.id, first_operation + 1)
	chat_effect_destroy(&effect)
	testing.expect(t, chat_session_feed_completion(&session, chat_session_event_source(&session)))
	finish = chat_session_advance(&session)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Completed)
	chat_effect_destroy(&finish)
}

// Events are identified by turn and operation. An event from a superseded operation
// must not reach the current turn, even when it arrives after a new turn started.
@(test)
test_stale_operation_events_are_rejected :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.tools_enabled = true
	testing.expect(t, chat_session_accept_user(&session, "first"))

	effect := tool_loop_begin_request(&session)
	stale := chat_session_event_source(&session)
	chat_effect_destroy(&effect)
	testing.expect(t, chat_session_request_cancel(&session))
	chat_session_retire_operation(&session)
	finish := chat_session_advance(&session)
	chat_effect_destroy(&finish)

	testing.expect(t, chat_session_accept_user(&session, "second"))
	effect = tool_loop_begin_request(&session)
	current := chat_session_event_source(&session)
	chat_effect_destroy(&effect)
	testing.expect(t, current.operation_id != stale.operation_id)
	testing.expect(t, current.turn_id != stale.turn_id)

	testing.expect(t, !chat_session_feed_completion(&session, stale))
	testing.expect_value(t, session.state, Chat_State.Requesting)
	stale_text := chat_session_feed_text(&session, stale, "stale text")
	testing.expect_value(t, stale_text.kind, Chat_Effect_Kind.None)
	chat_effect_destroy(&stale_text)
	testing.expect_value(t, len(session.partial_assistant), 0)
	testing.expect(t, !chat_session_feed_error(&session, stale, "stale error"))
	testing.expect_value(t, session.last_error, "")
	calls := []ai.Provider_Tool_Call{{ID = "stale_call", Name = TOOL_SHELL_NAME, Arguments = `{}`}}
	testing.expect(t, !chat_session_feed_tool_calls(&session, stale, calls))
	// An operation id from another turn, and a turn id with the current operation,
	// are both rejected.
	testing.expect(t, !chat_session_feed_completion(&session, Chat_Event_Source{turn_id = current.turn_id, operation_id = stale.operation_id}))
	testing.expect(t, !chat_session_feed_completion(&session, Chat_Event_Source{turn_id = stale.turn_id, operation_id = current.operation_id}))
	testing.expect_value(t, session.active_operation_id, current.operation_id)
}

// One owner finalizes each turn, and a turn reaches a terminal status once.
@(test)
test_turn_finalizes_exactly_once :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.tools_enabled = true
	testing.expect(t, chat_session_accept_user(&session, "once"))

	effect := tool_loop_begin_request(&session)
	chat_effect_destroy(&effect)
	testing.expect(t, chat_session_feed_completion(&session, chat_session_event_source(&session)))

	finish := chat_session_advance(&session)
	testing.expect_value(t, finish.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Completed)
	chat_effect_destroy(&finish)

	// No second terminal effect, and no later transition.
	again := chat_session_advance(&session)
	testing.expect_value(t, again.kind, Chat_Effect_Kind.None)
	chat_effect_destroy(&again)
	testing.expect_value(t, session.state, Chat_State.Idle)
	testing.expect_value(t, session.terminal_status, Chat_Terminal_Status.Completed)
	// A completed turn cannot be relabelled as cancelled.
	testing.expect(t, !chat_session_request_cancel(&session))
	testing.expect_value(t, session.terminal_status, Chat_Terminal_Status.Completed)
}

// The operation deadline is what the transport enforces while a request is in
// flight; the turn deadline is observed only at operation boundaries. They are
// separate facts, and the operation is clamped so it cannot outlive the turn.
@(test)
test_operation_deadline_distinct_from_turn_deadline :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	session.workspace = tool_loop_workspace(t)
	session.tools_enabled = true
	testing.expect(t, chat_session_accept_user(&session, "deadlines"))

	effect := tool_loop_begin_request(&session)
	chat_effect_destroy(&effect)
	operation_remaining, operation_active := ai.deadline_remaining(session.operation.deadline)
	turn_remaining, turn_active := ai.deadline_remaining(session.turn_deadline)
	testing.expect(t, operation_active)
	testing.expect(t, turn_active)
	testing.expectf(t, operation_remaining < turn_remaining, "operation bound %v is not tighter than turn bound %v", operation_remaining, turn_remaining)
	testing.expect(t, operation_remaining <= CHAT_OPERATION_DEADLINE)
	testing.expect(t, turn_remaining <= CHAT_TURN_DEADLINE)

	// A turn with less time left than an operation allows clamps the operation.
	session.turn_deadline = ai.deadline_in(50 * time.Millisecond)
	chat_session_retire_operation(&session)
	chat_session_begin_operation(&session)
	clamped, clamped_active := ai.deadline_remaining(session.operation.deadline)
	testing.expect(t, clamped_active)
	testing.expectf(t, clamped <= 50 * time.Millisecond, "operation was not clamped to the turn bound: %v", clamped)
	chat_session_retire_operation(&session)

	// An expired turn bound stops the turn at an operation boundary.
	session.state = Chat_State.Preparing
	session.turn_deadline = ai.deadline_in(-1 * time.Second)
	expired := chat_session_advance(&session)
	testing.expect_value(t, expired.kind, Chat_Effect_Kind.None)
	chat_effect_destroy(&expired)
	failure := chat_session_advance(&session)
	testing.expect_value(t, failure.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(t, failure.status, Chat_Terminal_Status.Failed)
	testing.expect_value(t, failure.error, "turn deadline exceeded")
	chat_effect_destroy(&failure)
}
