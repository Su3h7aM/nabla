#+test
package main

import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent"
import "nabla:agent/journal"

@(test)
test_serve_idle_queue_batches_steering_then_one_follow_up :: proc(test: ^testing.T) {
	workspace, workspace_error := os.make_directory_temp("", "nabla-serve-queue-*", context.allocator)
	if workspace_error != nil { testing.fail_now(test, "could not create workspace") }
	defer {
		_ = os.remove_all(workspace)
		delete(workspace)
	}
	fixture: agent.Chat_Test
	agent.chat_test_begin(test, &fixture, workspace)
	defer agent.chat_test_end(test, &fixture)
	if _, error := journal.commit(fixture.store); error != nil { testing.fail_now(test, "could not commit session") }
	provider: agent.Agent_Provider
	if !agent.agent_provider_start(test, &provider, {agent.agent_provider_reply("first answer"), agent.agent_provider_reply("second answer")}) { return }
	defer agent.agent_provider_stop(&provider)
	app: App
	app.setup.alloc = context.allocator
	app.run.alloc = context.allocator
	app.setup.store = fixture.store
	app.setup.session = fixture.chat
	fixture.chat = {}
	defer { fixture.chat = app.setup.session }
	chat := &app.setup.session
	app.run.connection = {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent.agent_provider_endpoint(&provider, context.allocator),
	}
	defer delete(app.run.connection.Endpoint)
	for text in ([]string{"first steering", "second steering"}) {
		if _, error := journal.queue_push(chat.store, chat.session, .Steering, text, nil); error != nil {
			testing.fail_now(test, "could not enqueue steering")
		}
	}
	for text in ([]string{"follow-up one", "follow-up two"}) {
		if _, error := journal.queue_push(chat.store, chat.session, .Follow_Up, text, nil); error != nil {
			testing.fail_now(test, "could not enqueue follow-up")
		}
	}
	step, step_ok := serve_step(&app)
	testing.expect(test, step_ok)
	testing.expect_value(test, step, Serve_Step.Turn)
	if !testing.expect(test, serve_run_turn(&app)) { return }
	if !testing.expect_value(test, agent.agent_provider_request_count(&provider), 1) { return }
	request := agent.agent_provider_request(&provider, 0)
	testing.expect(test, strings.contains(request, "first steering") && strings.contains(request, "second steering"))
	testing.expect(test, !strings.contains(request, "follow-up one"))
	entries, list_error := journal.queue_list(chat.store, chat.session, context.temp_allocator)
	testing.expect(test, list_error == nil)
	testing.expect_value(test, len(entries), 2)
	step, step_ok = serve_step(&app)
	testing.expect(test, step_ok)
	testing.expect_value(test, step, Serve_Step.Turn)
	if !testing.expect(test, serve_run_turn(&app)) { return }
	if !testing.expect_value(test, agent.agent_provider_request_count(&provider), 2) { return }
	request = agent.agent_provider_request(&provider, 1)
	testing.expect(test, strings.contains(request, "follow-up one"))
	testing.expect(test, !strings.contains(request, "follow-up two"))
	entries, list_error = journal.queue_list(chat.store, chat.session, context.temp_allocator)
	testing.expect(test, list_error == nil)
	if testing.expect_value(test, len(entries), 1) { testing.expect_value(test, entries[0].text, "follow-up two") }
	if _, error := journal.queue_push(chat.store, chat.session, .Follow_Up, "after cancel", nil); error != nil {
		testing.fail_now(test, "could not enqueue follow-up after cancellation")
	}
	client, open_error := journal.open(fixture.directory, fixture.directory, journal.run_id_create(), .Read_Write, context.allocator)
	if open_error != nil { testing.fail_now(test, "could not open client") }
	defer _ = journal.close(client)
	if error := journal.follow(client, chat.session); error != nil { testing.fail_now(test, "could not follow session") }
	if error := journal.append_command(client, journal.Cancel_Turn{}); error != nil { testing.fail_now(test, "could not cancel next turn") }
	wait_for_wake: Maybe(u32)
	testing.expect(test, serve_run_turn(&app, &wait_for_wake))
	testing.expect_value(test, chat.terminal_status, agent.Chat_Terminal_Status.Cancelled)
	_, waiting := wait_for_wake.?
	testing.expect(test, waiting, "a cancelled turn must not immediately restart queued work")
	testing.expect_value(test, agent.agent_provider_request_count(&provider), 2)
	entries, list_error = journal.queue_list(chat.store, chat.session, context.temp_allocator)
	testing.expect(test, list_error == nil)
	if !testing.expect_value(test, len(entries), 1) { return }
	testing.expect_value(test, entries[0].text, "after cancel")
	chat.queue_delivery_pending = true
	chat.queue_delivery_kind = .Follow_Up
	journal.queue_deliver(chat.store, chat.session, entries[0].id, nil, &chat.queue_delivery)
	if _, error := journal.queue_remove(chat.store, chat.session, entries[0].id); error != nil { testing.fail_now(test, "could not retract pending prompt") }
	wait_for_wake = nil
	turn := chat.active_turn_id
	testing.expect(test, serve_run_turn(&app, &wait_for_wake))
	_, waiting = wait_for_wake.?
	testing.expect(test, waiting, "a no-op delivery waits for another wake")
	testing.expect_value(test, chat.active_turn_id, turn)
	testing.expect_value(test, agent.agent_provider_request_count(&provider), 2)
}
