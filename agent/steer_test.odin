#+test
package agent

import "core:strings"
import "core:testing"

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
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)

	testing.expect(t, !chat_session_steer(&session, "idle"))
	testing.expect(t, chat_session_accept_user(&session, "start"))
	testing.expect(t, chat_session_steer(&session, "steered"))
	testing.expect_value(t, len(session.messages), 2)
	testing.expect_value(t, session.messages[1].role, Chat_Role.User)
	testing.expect_value(t, session.messages[1].text, "steered")
	// The turn keeps its id and budgets: steering starts nothing.
	testing.expect_value(t, session.requests_made, 0)
}

@(test)
test_drain_injects_text_and_runs_commands :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	append(&session.effort_levels, strings.clone("high", context.temp_allocator))
	testing.expect(t, chat_session_accept_user(&session, "start"))

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
	chat_drain_steering(&session, {}, &steer)

	testing.expect(t, !quit)
	testing.expect_value(t, session.effort, "high")
	testing.expect_value(t, len(session.messages), 2)
	testing.expect_value(t, session.messages[1].text, "check the logs")
}

@(test)
test_drain_quit_discards_what_was_never_sent :: proc(t: ^testing.T) {
	session := chat_session_init(context.temp_allocator)
	defer chat_session_destroy(&session)
	testing.expect(t, chat_session_accept_user(&session, "start"))

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
	chat_drain_steering(&session, {}, &steer)

	testing.expect(t, quit)
	testing.expect_value(t, len(session.messages), 1)
}
