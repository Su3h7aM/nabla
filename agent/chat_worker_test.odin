#+test
package agent

import "base:runtime"
import "core:mem"
import "core:testing"

import "nabla:ai"

// A response the harness could not keep whole is answered with the notice that says so: the
// model is told nothing ran and asked to send the work again, instead of a half-kept answer
// being committed as its own.
@(test)
test_lost_worker_fact_becomes_a_notice_the_model_can_act_on :: proc(test: ^testing.T) {
	mailbox: Owner_Mailbox
	mailbox_init(&mailbox, context.allocator)
	defer mailbox_destroy(&mailbox)
	worker := Chat_Request_Worker {
		allocator = mem.Allocator{procedure = chat_loss_failing_allocate},
		mailbox = &mailbox,
		source = Chat_Event_Source{turn_id = 1, operation_id = 1},
	}
	worker_runtime := Chat_Worker_Runtime {
		worker = &worker,
		source = worker.source,
	}
	// The worker cannot copy the fragment it was handed, so it reports the loss instead of
	// publishing empty text as the answer.
	chat_worker_event(&worker_runtime, ai.Provider_Text_Event{Text = "a lost answer"})

	events := mailbox_take_all(&mailbox)
	defer {
		for &event in events { chat_event_destroy(&event, mailbox.allocator) }
		delete(events)
	}
	if !testing.expect_value(test, len(events), 1) { return }
	if _, is_lost := events[0].(Chat_Lost_Event); !testing.expect(test, is_lost) { return }

	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "hello")
	_test_begin_request(test, chat)
	// The fact belongs to the running request, which is what its identity carries.
	lost := events[0].(Chat_Lost_Event)
	lost.source = chat_session_event_source(chat)
	event := Chat_Event(lost)

	chat_session_apply(chat, &event)
	testing.expect_value(test, chat.pending_notice, Chat_Notice.None)
	testing.expect(test, chat.active_failed, "a response the harness could not keep is not used")
	testing.expect_value(test, chat.last_error, CHAT_RESPONSE_NOT_KEPT)
}

chat_loss_failing_allocate :: proc(
	_: rawptr,
	_: mem.Allocator_Mode,
	_, _: int,
	_: rawptr,
	_: int,
	_: runtime.Source_Code_Location = #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	return nil, .Out_Of_Memory
}
