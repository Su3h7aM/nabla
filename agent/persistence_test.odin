#+test
package agent

import "core:testing"

import "nabla:agent/session"
import "nabla:db"

// A turn whose outcome does not reach the store must not report the status the
// model reached, and the session must refuse further work: the conversation in
// memory would otherwise diverge from the conversation on disk.
@(test)
test_a_turn_outcome_that_cannot_be_recorded_latches_the_session :: proc(t: ^testing.T) {
	defer chat_cancel_reset()

	fixture: Chat_Test
	chat_test_begin(t, &fixture, shell_test_workspace(context.temp_allocator))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat

	_test_accept(t, chat, "a turn that will not be recorded")
	effect := _test_begin_request(t, chat)
	testing.expect(t, chat_session_request_cancel(chat))
	chat_session_retire_operation(chat)

	finish := chat_session_advance(chat)
	if !testing.expect_value(t, finish.kind, Chat_Effect_Kind.Turn_Finished) { return }
	testing.expect_value(t, finish.status, Chat_Terminal_Status.Cancelled)

	// A connection that refuses writes stands in for storage that went away, or
	// filled up, while the turn was running.
	if exec_err := db.exec(&fixture.store.conn, "PRAGMA query_only = ON"); exec_err != nil {
		testing.fail_now(t, "the store could not be made read-only")
	}

	chat_session_claim_finish(chat, finish)
	testing.expect(t, !chat_persist_turn_end(chat, finish), "an unrecorded turn must not report that it was recorded")
	testing.expect(t, chat_session_storage_failed(chat), "the session must latch the failed write")
	testing.expect(t, chat_session_last_error(chat) != "", "the reason must be kept for the transcript")
	// The latch is what stops the next prompt, which is how the failure reaches a
	// user who never saw this turn's report.
	testing.expect_value(t, chat_session_accept_user(chat, "next", session.now_ms()), Chat_Accept.Storage_Failed)
}
