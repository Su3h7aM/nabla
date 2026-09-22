#+test
package agent

import "core:testing"

import "nabla:agent/session"
import "nabla:ai"
import "nabla:db"

// A turn whose outcome does not reach the store must not report the status the
// model reached, and the session must refuse further work: the conversation in
// memory would otherwise diverge from the conversation on disk.
@(test)
test_a_turn_outcome_that_cannot_be_recorded_latches_the_session :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
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

// A chain whose first attempt could not be recorded is released without a commit, and that
// release is what retires the operation the claim began. Nothing else can: an operation left
// running while its chain is gone is a turn with no effect left to take, and a turn in that
// state never reaches a status its caller can see.
@(test)
test_a_released_chain_retires_the_operation_it_began :: proc(t: ^testing.T) {
	defer chat_cancel_reset()

	fixture: Chat_Test
	chat_test_begin(t, &fixture, shell_test_workspace(context.temp_allocator))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)

	_test_accept(t, chat, "a turn whose first row will not be recorded")
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = "ftp://not-a-provider",
	}
	usages := make([dynamic]Chat_Request_Usage, 0, chat.allocator)
	defer delete(usages)
	chat_request_begin(chat, connection, test_retry_policy(), {})

	// A connection that refuses writes stands in for storage that went away, or filled up,
	// after the boundary and before the attempt's own row. Only that row is refused.
	if exec_err := db.exec(&fixture.store.conn, "PRAGMA query_only = ON"); exec_err != nil {
		testing.fail_now(t, "the store could not be made read-only")
	}

	send := chat_session_advance(chat)
	if !testing.expect_value(t, send.kind, Chat_Effect_Kind.Send_Attempt) { return }
	chat_chain_claim_send(chat)
	testing.expect(t, chat_session_storage_failed(chat), "the refused row must latch the session")
	testing.expect_value(t, chat.operation.state, Chat_Operation_State.Running)

	// Nothing can be sent, so the next effect is the commit that ends the chain.
	commit := chat_session_advance(chat)
	if !testing.expect_value(t, commit.kind, Chat_Effect_Kind.Commit_Response) { return }
	chat_chain_commit(chat, &usages)
	testing.expect_value(t, chat.operation.state, Chat_Operation_State.Retired)

	// The turn reaches a terminal status instead of coming back with a stage it cannot leave.
	finish := chat_session_advance(chat)
	testing.expect_value(t, finish.kind, Chat_Effect_Kind.Turn_Finished)
}
