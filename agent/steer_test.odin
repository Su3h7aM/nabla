#+test
package agent

import "core:strings"
import "core:testing"

import "nabla:agent/session"

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

@(test)
test_steer_feed_splits_lines_across_chunks :: proc(t: ^testing.T) {
	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	pending := make([dynamic]u8, 0, context.temp_allocator)
	defer delete(pending)

	steer_feed_bytes(&queue, {}, &pending, transmute([]u8)string("hello\nwor"))
	steer_feed_bytes(&queue, {}, &pending, transmute([]u8)string("ld\n\n  \n"))
	line, ok := steer_pop(&queue)
	testing.expect(t, ok)
	testing.expect_value(t, line, "hello")
	steer_line_free(&queue, line)
	line, ok = steer_pop(&queue)
	testing.expect(t, ok)
	testing.expect_value(t, line, "world")
	steer_line_free(&queue, line)
	_, ok = steer_pop(&queue)
	testing.expect(t, !ok)

	steer_feed_bytes(&queue, {}, &pending, transmute([]u8)string("partial"))
	steer_flush_pending(&queue, {}, &pending)
	line, ok = steer_pop(&queue)
	testing.expect(t, ok)
	testing.expect_value(t, line, "partial")
	steer_line_free(&queue, line)
}

@(test)
test_steer_queue_close_leaves_leftovers :: proc(t: ^testing.T) {
	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)

	testing.expect(t, !steer_drained(&queue))
	testing.expect(t, steer_push(&queue, "late"))
	steer_close(&queue)
	testing.expect(t, !steer_drained(&queue))
	line, ok := steer_pop(&queue)
	testing.expect(t, ok)
	delete(line, context.temp_allocator)
	testing.expect(t, steer_drained(&queue))
}

@(test)
test_session_steer_only_at_request_boundary :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat

	testing.expect(t, !chat_session_steer(chat, "idle", session.now_ms()))
	_test_accept(t, chat, "start")
	testing.expect(t, chat_session_steer(chat, "steered", session.now_ms()))

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
