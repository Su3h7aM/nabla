#+test
package agent

import "core:strings"
import "core:testing"

import "nabla:agent/session"
import "nabla:ai"

// Boundary_Install is a caller's selection change: the connection it wants the next
// request built for, and how often the turn asked for one.
Boundary_Install :: struct {
	connection: ai.Provider_Connection,
	calls:      int,
}

boundary_install_connection :: proc(steer: ^Steer_Context) -> ai.Provider_Connection {
	install := cast(^Boundary_Install)steer.apply_data
	install.calls += 1
	return install.connection
}

// The request boundary is where a caller installs a selection the user changed
// mid-turn: the connection the hook returns is the one the request that follows is
// built for. The turn is handed the first endpoint and the hook replaces it before the
// first request, so which endpoint received the bytes is the proof.
@(test)
test_a_boundary_hook_hands_the_next_request_its_connection :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(t, chat, "say something")

	previous: Agent_Provider
	if !agent_provider_start(t, &previous, []string{}) { return }
	defer agent_provider_stop(&previous)
	installed: Agent_Provider
	if !agent_provider_start(t, &installed, {agent_provider_reply("from the new selection")}) { return }
	defer agent_provider_stop(&installed)

	initial := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&previous, chat.allocator),
	}
	defer delete(initial.Endpoint, chat.allocator)
	next := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&installed, chat.allocator),
	}
	defer delete(next.Endpoint, chat.allocator)

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	install := Boundary_Install {
		connection = next,
	}
	steer := Steer_Context {
		queue      = &queue,
		apply      = boundary_install_connection,
		apply_data = &install,
	}

	testing.expect(t, chat_run_turn_steered(chat, initial, test_retry_policy(), {}, &steer), "the turn completed")
	testing.expect(t, install.calls > 0, "the turn asked for a selection at its boundary")
	testing.expect_value(t, agent_provider_request_count(&previous), 0)
	if !testing.expect_value(t, agent_provider_request_count(&installed), 1) { return }
	testing.expect(t, strings.contains(agent_provider_request(&installed, 0), "say something"), "the request that followed the boundary is the turn's own")
}

@(test)
test_steer_queue_is_fifo_and_bounded :: proc(t: ^testing.T) {
	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)

	testing.expect(t, steer_push(&queue, "first"))
	testing.expect(t, steer_push(&queue, "second"))
	line, ok := steer_pop(&queue)
	testing.expect(t, ok)
	testing.expect_value(t, line, "first")
	delete(line, context.temp_allocator)
	line, ok = steer_pop(&queue)
	testing.expect(t, ok)
	testing.expect_value(t, line, "second")
	delete(line, context.temp_allocator)
	_, ok = steer_pop(&queue)
	testing.expect(t, !ok)

	for _ in 0 ..< STEER_MAX_ITEMS {
		testing.expect(t, steer_push(&queue, "x"))
	}
	testing.expect(t, !steer_push(&queue, "dropped"))
	taken := steer_take_all(&queue)
	testing.expect_value(t, len(taken), STEER_MAX_ITEMS)
	steer_taken_destroy(&queue, taken)
	testing.expect(t, steer_push(&queue, "again"))
}

@(test)
test_steer_queue_bounds_total_bytes :: proc(t: ^testing.T) {
	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)

	filler := strings.repeat("x", 6000, context.temp_allocator)
	defer delete(filler, context.temp_allocator)
	pushes := 0
	for steer_push(&queue, filler) { pushes += 1 }
	testing.expect(t, pushes == 5)
}

// Taking the queue hands every line over in order and leaves the queue empty with its own
// budget back: a line that leaves the queue is neither still queued nor charged to it.
@(test)
test_taking_the_queue_hands_every_line_over :: proc(t: ^testing.T) {
	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	testing.expect(t, steer_push(&queue, "first"))
	testing.expect(t, steer_push(&queue, "second"))

	taken := steer_take_all(&queue)
	defer steer_taken_destroy(&queue, taken)
	if !testing.expect_value(t, len(taken), 2) { return }
	testing.expect_value(t, taken[0], "first")
	testing.expect_value(t, taken[1], "second")
	_, has_line := steer_pop(&queue)
	testing.expect(t, !has_line, "the queue is empty after taking its lines")

	filler := strings.repeat("x", 6000, context.temp_allocator)
	defer delete(filler, context.temp_allocator)
	pushes := 0
	for steer_push(&queue, filler) { pushes += 1 }
	testing.expect_value(t, pushes, 5)
}

// A steering line is a message the user sent. Recording it is what makes it the session's,
// and the next request built from the history carries it. A session with no turn has
// nothing to attach it to, so the line stays with whoever queued it.
@(test)
test_recording_a_steering_line_attaches_it_to_the_running_turn :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat

	testing.expect_value(t, chat_session_steer(chat, "idle", session.now_ms()), Chat_Steer_Result.No_Turn)
	_test_accept(t, chat, "start")
	testing.expect_value(t, chat_session_steer(chat, "steered", session.now_ms()), Chat_Steer_Result.Recorded)

	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	if !testing.expect_value(t, len(ctx.entries), 2) { return }
	user, is_user := ctx.entries[1].payload.(session.User_Entry)
	if !testing.expect(t, is_user, "the steering line should be user text") { return }
	testing.expect_value(t, user.text, "steered")
	testing.expect_value(t, user.origin, session.User_Origin.Steering)
	// The turn keeps its budgets: steering starts nothing.
	testing.expect_value(t, chat.requests_made, 0)
}

// Steering_Probe pushes one line into the queue the first time a request finishes, which is
// the window the user's line arrives in: the request it interrupts is over and the turn has
// not decided what to do next.
Steering_Probe :: struct {
	queue:  ^Steer_Queue,
	line:   string,
	pushed: bool,
}

steering_probe_push :: proc(user_data: rawptr) {
	probe := cast(^Steering_Probe)user_data
	if probe.pushed { return }
	probe.pushed = steer_push(probe.queue, probe.line)
}

// A steering line is a prompt that arrives while a request is running, and the only thing
// that makes it different from a prompt sent while idle is that it does not interrupt the
// request in flight. Once that request finishes, the line starts the next request on its
// own: the user does not submit anything else to deliver it.
@(test)
test_a_steering_line_starts_the_next_request_on_its_own :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(t, chat, "write a poem")

	provider: Agent_Provider
	if !agent_provider_start(t, &provider, {agent_provider_reply("one poem"), agent_provider_reply("another poem")}) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	probe := Steering_Probe {
		queue = &queue,
		line  = "write another one",
	}
	observer := Chat_Observer {
		user_data        = &probe,
		request_finished = steering_probe_push,
	}

	testing.expect(t, chat_run_turn_steered(chat, connection, test_retry_policy(), observer, &steer), "the turn completed")
	testing.expect(t, probe.pushed, "the fixture pushed its line while the first request was running")
	if !testing.expect_value(t, agent_provider_request_count(&provider), 2) { return }
	testing.expect(t, !strings.contains(agent_provider_request(&provider, 0), "write another one"), "the request already in flight is not rebuilt")
	testing.expect(t, strings.contains(agent_provider_request(&provider, 1), "write another one"), "the line starts the request that follows it")
}

// A line recorded for a turn that had finished answering continues that turn instead of
// leaving it to end: the request the selector proposes next is the one that answers it.
@(test)
test_input_left_at_the_end_of_a_turn_keeps_it_running :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	_test_accept(t, chat, "write a poem")

	// The turn's request is running and its response completes without proposing anything,
	// which is where a turn decides to finish.
	_test_begin_request(t, chat)
	testing.expect(t, chat_session_feed_completion(chat, chat_session_event_source(chat)))
	testing.expect_value(t, chat.state, Chat_State.Finalizing)

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	testing.expect(t, steer_push(&queue, "write another one"))
	chat_steering_observe(chat, {}, &steer)

	testing.expect_value(t, chat.state, Chat_State.Preparing)
	effect := chat_session_advance(chat)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Start_Request)

	// The request that follows is built from the history the line is now part of.
	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	if !testing.expect_value(t, len(ctx.entries), 2) { return }
	user, is_user := ctx.entries[1].payload.(session.User_Entry)
	if !testing.expect(t, is_user, "the line should be the next thing the model reads") { return }
	testing.expect_value(t, user.text, "write another one")
}

// Input is recorded only where it reads correctly: a call without its result is not such a
// point, because an entry placed there would be read where a result belongs. The line waits
// until the batch settles, which is the boundary the next request starts from.
@(test)
test_input_waits_until_the_tool_batch_settles :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	_test_accept(t, chat, "run it")
	_test_begin_request(t, chat)

	calls := []ai.Provider_Tool_Call{{ID = "call_1", Name = TOOL_SHELL_NAME, Arguments = `{"command":"true"}`}}
	testing.expect_value(t, chat_session_feed_tool_calls(chat, chat_session_event_source(chat), calls), Chat_Notice.None)
	testing.expect_value(t, chat.state, Chat_State.Executing_Tools)

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	testing.expect(t, steer_push(&queue, "use the other file"))
	chat_steering_observe(chat, {}, &steer)

	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	for entry in ctx.entries {
		user, is_user := entry.payload.(session.User_Entry)
		if !is_user { continue }
		testing.expect(t, user.origin != session.User_Origin.Steering, "a call without its result is not a point input may be read at")
	}

	// The batch settles, which is the point the line may be recorded at.
	testing.expect(t, chat_session_tools_done(chat, chat.active_turn_id, len(chat.pending_calls)))
	chat_steering_observe(chat, {}, &steer)

	ctx_after := _test_context(t, chat)
	defer session.context_destroy(&ctx_after, context.allocator)
	steered := false
	for entry in ctx_after.entries {
		if user, is_user := entry.payload.(session.User_Entry); is_user && user.origin == session.User_Origin.Steering {
			steered = true
			testing.expect_value(t, user.text, "use the other file")
		}
	}
	testing.expect(t, steered, "the line is recorded once the batch it would read into has settled")
	_, still_queued := steer_pop(&queue)
	testing.expect(t, !still_queued, "the line left the queue into the record")
}

// A turn that failed has nothing left to answer with, so its input does not restart it: the
// line stays in the record, and the next request from this history carries it.
@(test)
test_input_does_not_restart_a_turn_that_failed :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	_test_accept(t, chat, "write a poem")
	chat_session_fail_turn(chat, "the provider refused the request")

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	testing.expect(t, steer_push(&queue, "write another one"))
	chat_steering_observe(chat, {}, &steer)

	testing.expect_value(t, chat.state, Chat_State.Finalizing)
	effect := chat_session_advance(chat)
	testing.expect_value(t, effect.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(t, effect.status, Chat_Terminal_Status.Failed)
}

// A turn that ends without proposing another request is the case that lost the line: the
// queue was empty at its last boundary and the turn took nothing with it. The turn end
// records what it was sent, so the next request built from this history carries it, and
// the entry is ordered after the answer it followed.
@(test)
test_a_turn_that_ends_without_a_request_records_what_it_was_sent :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	_test_accept(t, chat, "start")

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	// The path stops before it can propose another request, which is what a turn that
	// failed its own request does: the selector goes straight to the terminal effect.
	chat_session_fail_turn(chat, "the provider refused the request")
	testing.expect(t, steer_push(&queue, "check the logs"))

	testing.expect(t, !chat_run_turn_steered(chat, {}, test_retry_policy(), {}, &steer), "the turn failed")

	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	if !testing.expect(t, len(ctx.entries) > 0, "the session has a history") { return }
	user, is_user := ctx.entries[len(ctx.entries) - 1].payload.(session.User_Entry)
	if !testing.expect(t, is_user, "the turn end should have recorded the line it was sent") { return }
	testing.expect_value(t, user.text, "check the logs")
	testing.expect_value(t, user.origin, session.User_Origin.Steering)
	// It left the queue for the record, so no later request can deliver it twice.
	_, still_queued := steer_pop(&queue)
	testing.expect(t, !still_queued, "the line should have left the queue")
}

// A steering line reaches the model in the next request the turn makes, which is the
// whole point of accepting input during a turn: the request the turn was already sending
// is frozen, and this one is built from the history the line is now part of.
@(test)
test_a_steering_line_reaches_the_request_that_follows_it :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(t, chat, "say something")

	provider: Agent_Provider
	if !agent_provider_start(t, &provider, {agent_provider_reply("done")}) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	testing.expect(t, steer_push(&queue, "check the logs"))

	testing.expect(t, chat_run_turn_steered(chat, connection, test_retry_policy(), {}, &steer), "the turn completed")
	if !testing.expect_value(t, agent_provider_request_count(&provider), 1) { return }
	testing.expect(t, strings.contains(agent_provider_request(&provider, 0), "check the logs"), "the request should carry the line the user sent")
}

// A line the store refuses was never recorded, so the turn that could not record it does
// not take it: it stays queued, in order, with the failure reported. Nothing the user sent
// is dropped by a write that did not happen.
@(test)
test_a_line_the_store_refuses_stays_pending :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	_test_accept(t, chat, "start")

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	testing.expect(t, steer_push(&queue, "check the logs"))
	testing.expect(t, steer_push(&queue, "and the config"))
	// A store without the writer claim refuses every entry write.
	testing.expect(t, session.session_release(&fixture.store) == nil)

	notices: Chat_Notice_Log
	observer := chat_notice_log_begin(&notices)
	defer chat_notice_log_destroy(&notices)
	chat_drain_steering(chat, observer, &steer)

	for expected in ([]string{"check the logs", "and the config"}) {
		line, queued := steer_pop(&queue)
		if !testing.expect(t, queued, "a line the store refused should still be queued") { return }
		testing.expect_value(t, line, expected)
		steer_line_free(&queue, line)
	}
	testing.expect(t, len(notices.lines) > 0, "the refusal is reported")
}

@(test)
test_drain_records_queued_lines_in_order :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	_test_accept(t, chat, "start")

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	testing.expect(t, steer_push(&queue, "check the logs"))
	testing.expect(t, steer_push(&queue, "and the config"))
	steer := Steer_Context {
		queue = &queue,
	}
	chat_drain_steering(chat, {}, &steer)

	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	if !testing.expect_value(t, len(ctx.entries), 3) { return }
	for expected, index in ([]string{"start", "check the logs", "and the config"}) {
		user, is_user := ctx.entries[index].payload.(session.User_Entry)
		if !testing.expect(t, is_user, "the entry should be user text") { return }
		testing.expect_value(t, user.text, expected)
	}
}

// A line the session could not record reports that it is waiting, not a failure that
// belongs to the turn: the turn's own error is not this line's to repeat, and the line is
// still pending for the turn that can carry it.
@(test)
test_a_refused_steering_line_does_not_repeat_a_turn_error :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_session_fail_turn(chat, "the provider refused the request")

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	testing.expect(t, steer_push(&queue, "check the logs"))

	notices: Chat_Notice_Log
	observer := chat_notice_log_begin(&notices)
	defer chat_notice_log_destroy(&notices)
	chat_drain_steering(chat, observer, &steer)

	for line in notices.lines {
		testing.expect(t, line != "the provider refused the request", "a line with no turn must not repeat the turn's failure as its own")
	}
	testing.expect(t, len(notices.lines) > 0, "a line the session cannot carry is reported")
	_, queued := steer_pop(&queue)
	testing.expect(t, queued, "the line stays pending for the turn that can carry it")
}
