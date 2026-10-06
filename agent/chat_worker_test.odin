#+test
package agent

import "base:runtime"
import "core:mem"
import "core:testing"

import "nabla:ai"

// A fact the worker cannot copy, or cannot queue, sets the lost flag instead of being
// dropped: the flag needs no allocation, so the owner always learns the response is not whole.
@(test)
test_lost_worker_fact_sets_the_lost_flag :: proc(test: ^testing.T) {
	failing := mem.Allocator {
		procedure = chat_loss_failing_allocate,
	}
	source := Chat_Event_Source {
		turn_id      = 1,
		operation_id = 1,
	}

	// The worker cannot copy the fragment it was handed.
	{
		mailbox: Owner_Mailbox
		mailbox_init(&mailbox, context.allocator)
		defer mailbox_destroy(&mailbox)
		worker := Chat_Request_Worker {
			allocator = failing,
			mailbox   = &mailbox,
			source    = source,
		}
		worker_runtime := Chat_Worker_Runtime {
			worker = &worker,
			source = source,
		}
		chat_worker_event(&worker_runtime, ai.Provider_Text_Event{Text = "a lost answer"})
		testing.expect_value(test, len(mailbox.events), 0)
		testing.expect(test, mailbox_take_lost(&mailbox), "an uncopied fragment is reported lost")
		testing.expect(test, !mailbox_take_lost(&mailbox), "the report is taken once")
	}

	// The fragment is copied, but the queue cannot take it.
	{
		mailbox: Owner_Mailbox
		mailbox_init(&mailbox, failing)
		worker := Chat_Request_Worker {
			allocator = context.allocator,
			mailbox   = &mailbox,
			source    = source,
		}
		worker_runtime := Chat_Worker_Runtime {
			worker = &worker,
			source = source,
		}
		chat_worker_event(&worker_runtime, ai.Provider_Text_Event{Text = "a lost answer"})
		testing.expect_value(test, len(mailbox.events), 0)
		testing.expect(test, mailbox_take_lost(&mailbox), "an unqueued event is reported lost")
	}
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
