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
		connection = initial,
		apply      = boundary_install_connection,
		apply_data = &install,
	}

	testing.expect(t, chat_run_turn_steered(chat, initial, test_retry_policy(), {}, &steer), "the turn completed")
	testing.expect(t, install.calls > 0, "the turn asked for a selection at its boundary")
	testing.expect_value(t, len(previous.requests), 0)
	if !testing.expect_value(t, len(installed.requests), 1) { return }
	testing.expect(t, strings.contains(installed.requests[0], "say something"), "the request that followed the boundary is the turn's own")
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
	testing.expect_value(t, steer_clear(&queue), STEER_MAX_ITEMS)
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

@(test)
test_session_steer_only_at_request_boundary :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat

	testing.expect_value(t, chat_session_steer(chat, "idle", session.now_ms()), Chat_Steer_Result.Outside_Boundary)
	_test_accept(t, chat, "start")
	testing.expect_value(t, chat_session_steer(chat, "steered", session.now_ms()), Chat_Steer_Result.Accepted)

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

@(test)
test_drain_injects_text_and_runs_commands :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	append(&chat.effort_levels, strings.clone("high", chat.allocator))
	_test_accept(t, chat, "start")

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	testing.expect(t, steer_push(&queue, "check the logs"))
	testing.expect(t, steer_push(&queue, "/effort high"))
	quit := false
	steer := Steer_Context {
		queue       = &queue,
		quit        = &quit,
		provider_id = "p",
		model_id    = "m",
	}
	chat_drain_steering(chat, {}, &steer)

	testing.expect(t, !quit)
	testing.expect_value(t, chat.effort, "high")
	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	if !testing.expect_value(t, len(ctx.entries), 2) { return }
	user, is_user := ctx.entries[1].payload.(session.User_Entry)
	if !testing.expect(t, is_user, "the queued line should be user text") { return }
	testing.expect_value(t, user.text, "check the logs")
}

@(test)
test_drain_quit_discards_what_was_never_sent :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	_test_accept(t, chat, "start")

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	testing.expect(t, steer_push(&queue, "/quit"))
	testing.expect(t, steer_push(&queue, "never sent"))
	quit := false
	steer := Steer_Context {
		queue       = &queue,
		quit        = &quit,
		provider_id = "p",
		model_id    = "m",
	}
	chat_drain_steering(chat, {}, &steer)

	testing.expect(t, quit)
	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	testing.expect_value(t, len(entries), 1)
}

// A line that arrives after the turn already failed was never tried. The turn's own
// failure is not this line's to report, so the front-end is told about the boundary
// rather than shown a provider error the line had nothing to do with.
@(test)
test_a_late_steering_line_does_not_repeat_the_turn_error :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	_test_accept(t, chat, "start")
	chat_session_fail_turn(chat, "the provider refused the request")

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	testing.expect(t, steer_push(&queue, "check the logs"))
	quit := false
	steer := Steer_Context {
		queue       = &queue,
		quit        = &quit,
		provider_id = "p",
		model_id    = "m",
	}

	notices: Chat_Notice_Log
	observer := chat_notice_log_begin(&notices)
	defer chat_notice_log_destroy(&notices)
	chat_drain_steering(chat, observer, &steer)

	if !testing.expect_value(t, len(notices.lines), 1) { return }
	testing.expect(t, notices.lines[0] != "the provider refused the request", "a line that arrived too late must not report the turn's failure as its own")
}
