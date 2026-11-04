#+test
package agent

import "core:mem/virtual"
import "core:testing"

import "nabla:agent/journal"
import "nabla:db"

@(test)
test_durable_steering_delivers_once_at_a_settled_point :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "start")
	_, error := journal.queue_push(chat.store, chat.session, .Steering, "steered", {"/missing-queued-attachment.png"})
	if error != nil { testing.fail_now(test, "could not enqueue steering") }
	chat.state = .Requesting
	chat_steering_observe(chat, {})
	testing.expect_value(test, len(_test_records(test, chat, {.User_Input})), 0)
	chat.state = .Preparing
	chat_steering_observe(chat, {})
	chat_steering_observe(chat, {})
	inputs := _test_records(test, chat, {.User_Input})
	if !testing.expect_value(test, len(inputs), 1) { return }
	testing.expect_value(test, string(inputs[0].body), "steered")
	testing.expect_value(test, len(_test_records(test, chat, {.Runtime_Message})), 1)
	entries, list_error := journal.queue_list(chat.store, chat.session, context.temp_allocator)
	testing.expect(test, list_error == nil)
	testing.expect_value(test, len(entries), 0)
	arena: virtual.Arena
	if error := virtual.arena_init_growing(&arena); error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	projection := _test_projection(test, chat, &arena)
	if !testing.expect_value(test, len(projection.items), 2) { return }
	user, is_user := projection.items[1].payload.(Projected_User)
	if !testing.expect(test, is_user) { return }
	testing.expect_value(test, user.text, "steered")
	testing.expect_value(test, user.origin, journal.User_Origin.Steering)
}

@(test)
test_durable_queue_hold_blocks_its_kind_but_not_follow_up :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "start")
	first, error := journal.queue_push(chat.store, chat.session, .Steering, "held", nil)
	if error != nil { testing.fail_now(test, "could not enqueue held steering") }
	if _, error := journal.queue_push(chat.store, chat.session, .Steering, "behind", nil); error != nil {
		testing.fail_now(test, "could not enqueue later steering")
	}
	if _, error := journal.queue_push(chat.store, chat.session, .Follow_Up, "next turn", nil); error != nil {
		testing.fail_now(test, "could not enqueue follow-up")
	}
	if _, held, error := journal.queue_hold(chat.store, chat.session, first, context.temp_allocator); error != nil || !held {
		testing.fail_now(test, "could not hold steering")
	}
	chat_steering_observe(chat, {})
	testing.expect_value(test, len(_test_records(test, chat, {.User_Input})), 0)
	entries, list_error := journal.queue_list(chat.store, chat.session, context.temp_allocator)
	testing.expect(test, list_error == nil)
	testing.expect_value(test, len(entries), 3)
	kind, ready_ok := chat_queue_ready(chat)
	testing.expect(test, ready_ok)
	testing.expect_value(test, kind, Maybe(journal.Queue_Kind)(journal.Queue_Kind.Follow_Up))
	if _, error := journal.queue_unhold(chat.store, chat.session, first); error != nil { testing.fail_now(test, "could not release steering") }
	chat_steering_observe(chat, {})
	testing.expect_value(test, len(_test_records(test, chat, {.User_Input})), 2)
	entries, list_error = journal.queue_list(chat.store, chat.session, context.temp_allocator)
	testing.expect(test, list_error == nil)
	if testing.expect_value(test, len(entries), 1) { testing.expect_value(test, entries[0].kind, journal.Queue_Kind.Follow_Up) }
}

@(test)
test_durable_queue_busy_delivery_retries_without_duplicates :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "start")
	if _, error := journal.queue_push(chat.store, chat.session, .Steering, "once", nil); error != nil {
		testing.fail_now(test, "could not enqueue steering")
	}
	writer, open_error := journal.open(fixture.directory, fixture.directory, journal.run_id_create(), .Read_Write, context.allocator)
	if open_error != nil { testing.fail_now(test, "could not open writer") }
	defer _ = journal.close(writer)
	if error := db.exec(&chat.store.connection, "PRAGMA busy_timeout=0"); error != nil { testing.fail_now(test, "could not disable busy wait") }
	if error := db.exec(&writer.connection, "BEGIN IMMEDIATE"); error != nil { testing.fail_now(test, "could not lock writer") }
	defer _ = db.rollback(&writer.connection)
	chat_steering_observe(chat, {})
	chat_steering_observe(chat, {})
	testing.expect(test, chat.queue_delivery_pending)
	testing.expect(test, !chat.queue_delivery.completed && !chat.storage_failed)
	testing.expect_value(test, len(_test_records(test, chat, {.User_Input})), 0)
	if error := db.rollback(&writer.connection); error != nil { testing.fail_now(test, "could not release writer") }
	chat_steering_observe(chat, {})
	chat_steering_observe(chat, {})
	testing.expect(test, !chat.queue_delivery_pending)
	testing.expect_value(test, len(_test_records(test, chat, {.User_Input})), 1)
	delivered, error := journal.last_delivered_message(chat.store, chat.session)
	testing.expect(test, error == nil)
	testing.expect_value(test, delivered, chat.queue_delivery.seq)
}
