#+test
package agent

import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "nabla:agent/journal"
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

// _steer_store_refuse stops the store from writing, which is the state a failed commit
// leaves the journal in: every later write is dropped and every commit reports it.
_steer_store_refuse :: proc(chat: ^Chat_Session) {
	chat.store.failure = journal.Journal_Error.Storage_Failed
}

// The request boundary is where a caller installs a selection the user changed
// mid-turn: the connection the hook returns is the one the request that follows is
// built for. The turn is handed the first endpoint and the hook replaces it before the
// first request, so which endpoint received the bytes is the proof.
@(test)
test_a_boundary_hook_hands_the_next_request_its_connection :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(test, chat, "say something")

	previous: Agent_Provider
	if !agent_provider_start(test, &previous, []string{}) { return }
	defer agent_provider_stop(&previous)
	installed: Agent_Provider
	if !agent_provider_start(test, &installed, {agent_provider_reply("from the new selection")}) { return }
	defer agent_provider_stop(&installed)

	initial := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&previous, chat.allocator),
	}
	defer delete(initial.Endpoint, chat.allocator)
	following := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&installed, chat.allocator),
	}
	defer delete(following.Endpoint, chat.allocator)

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	install := Boundary_Install {
		connection = following,
	}
	steer := Steer_Context {
		queue      = &queue,
		apply      = boundary_install_connection,
		apply_data = &install,
	}

	testing.expect(test, chat_run_turn_steered(chat, initial, test_retry_policy(), {}, &steer), "the turn completed")
	testing.expect(test, install.calls > 0, "the turn asked for a selection at its boundary")
	testing.expect_value(test, agent_provider_request_count(&previous), 0)
	if !testing.expect_value(test, agent_provider_request_count(&installed), 1) { return }
	testing.expect(test, strings.contains(agent_provider_request(&installed, 0), "say something"), "the request that followed the boundary is the turn's own")
}

@(test)
test_steer_queue_is_fifo_and_keeps_every_line_whole :: proc(test: ^testing.T) {
	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)

	testing.expect(test, steer_push(&queue, "first"))
	large := strings.repeat("x", 1 << 20, context.temp_allocator)
	testing.expect(test, steer_push(&queue, large))
	line, has_line := steer_pop(&queue)
	testing.expect(test, has_line)
	testing.expect_value(test, line, "first")
	delete(line, context.temp_allocator)
	line, has_line = steer_pop(&queue)
	testing.expect(test, has_line)
	testing.expect_value(test, len(line), len(large))
	delete(line, context.temp_allocator)
	_, has_line = steer_pop(&queue)
	testing.expect(test, !has_line)
}

// Taking the queue hands every line over in order and leaves the queue empty with its own
// budget back: a line that leaves the queue is neither still queued nor charged to it.
@(test)
test_taking_the_queue_hands_every_line_over :: proc(test: ^testing.T) {
	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	testing.expect(test, steer_push(&queue, "first"))
	testing.expect(test, steer_push(&queue, "second"))

	taken, taken_ok := steer_take_all(&queue)
	defer steer_taken_destroy(&queue, taken)
	if !testing.expect(test, taken_ok, "the queued lines could not be taken") { return }
	if !testing.expect_value(test, len(taken), 2) { return }
	testing.expect_value(test, taken[0], "first")
	testing.expect_value(test, taken[1], "second")
	_, has_line := steer_pop(&queue)
	testing.expect(test, !has_line, "the queue is empty after taking its lines")
}

// A steering line is a message the user sent. Accepting it commits a user.input record in
// any phase, a request in flight included, and tells the front-end only after that commit.
// A User node delivers it at the next settled point, and the next request carries it.
@(test)
test_a_steering_line_is_accepted_at_once_and_delivered_at_a_settled_point :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "start")

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	testing.expect(test, steer_push(&queue, "steered"))

	// A request is in flight: the line is accepted, and nothing delivers it yet.
	chat.state = .Requesting
	notices: Chat_Notice_Log
	observer := chat_notice_log_begin(&notices)
	defer chat_notice_log_destroy(&notices)
	chat_steering_observe(chat, observer, &steer)
	testing.expect_value(test, chat_notice_log_count(&notices, "queued"), 1)
	testing.expect(test, !steer_pending(&queue), "the accepted line left the queue")
	accepted := _test_records(test, chat, {.User_Input})
	if !testing.expect_value(test, len(accepted), 1) { return }
	testing.expect_value(test, string(accepted[0].body), "steered")
	delivered_before, delivered_error := journal.last_delivered_message(chat.store, chat.session)
	testing.expect_value(test, delivered_error, nil)
	testing.expect_value(test, delivered_before, journal.Journal_Seq(0))

	// The request settles, which is the point a User node delivers it.
	chat.state = .Preparing
	chat_steering_observe(chat, observer, &steer)
	delivered_after, _ := journal.last_delivered_message(chat.store, chat.session)
	testing.expect_value(test, delivered_after, accepted[0].seq)

	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	projection := _test_projection(test, chat, &arena)
	if !testing.expect_value(test, len(projection.items), 2) { return }
	user, is_user := projection.items[1].payload.(Projected_User)
	if !testing.expect(test, is_user, "the steering line should be user text") { return }
	testing.expect_value(test, user.text, "steered")
	testing.expect_value(test, user.origin, journal.User_Origin.Steering)
	// The turn keeps its budgets: steering starts nothing.
	testing.expect_value(test, chat.requests_made, 0)
	// Delivered once: a later look finds nothing more to deliver.
	chat_steering_observe(chat, observer, &steer)
	testing.expect_value(test, len(_test_projection(test, chat, &arena).items), 2)
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

steering_probe_push_on_text :: proc(user_data: rawptr, _: string) {
	steering_probe_push(user_data)
}

// A steering line is a prompt that arrives while a request is running, and the only thing
// that makes it different from a prompt sent while idle is that it does not interrupt the
// request in flight. Once that request finishes, the line starts the next request on its
// own: the user does not submit anything else to deliver it.
@(test)
test_a_steering_line_starts_the_next_request_on_its_own :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(test, chat, "write a poem")

	provider: Agent_Provider
	if !agent_provider_start(test, &provider, {agent_provider_reply("one poem"), agent_provider_reply("another poem")}) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	queue := steer_queue_init(chat.allocator)
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

	testing.expect(test, chat_run_turn_steered(chat, connection, test_retry_policy(), observer, &steer), "the turn completed")
	testing.expect(test, probe.pushed, "the fixture pushed its line while the first request was running")
	if !testing.expect_value(test, agent_provider_request_count(&provider), 2) { return }
	testing.expect(test, !strings.contains(agent_provider_request(&provider, 0), "write another one"), "the request already in flight is not rebuilt")
	testing.expect(test, strings.contains(agent_provider_request(&provider, 1), "write another one"), "the line starts the request that follows it")
}

// A line can arrive after the provider has started answering but before its response is
// committed. The answer must be parented before the line, and the next request must end with
// the user message so providers that require a user turn do not receive an assistant prefill.
@(test)
test_steering_during_response_waits_for_commit_before_recording :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(test, chat, "say something")

	provider: Agent_Provider
	if !agent_provider_start(test, &provider, {agent_provider_reply("first answer"), agent_provider_reply("second answer")}) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	queue := steer_queue_init(chat.allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	probe := Steering_Probe {
		queue = &queue,
		line  = "check the logs",
	}
	observer := Chat_Observer {
		user_data      = &probe,
		assistant_text = steering_probe_push_on_text,
	}

	if !testing.expect(test, chat_run_turn_steered(chat, connection, test_retry_policy(), observer, &steer), "the turn completed") { return }
	if !testing.expect(test, probe.pushed, "the line was queued while the provider response was being applied") { return }
	if !testing.expect_value(test, agent_provider_request_count(&provider), 2) { return }
	first_request := agent_provider_request(&provider, 0)
	second_request := agent_provider_request(&provider, 1)
	testing.expect(test, !strings.contains(first_request, probe.line), "the frozen request does not contain the line")
	testing.expect(test, strings.contains(second_request, "first answer"), "the next request includes the completed answer")
	steering_request_ends_with_user_line(test, second_request, probe.line, "first answer")

	records := _test_records(test, chat, {.Request_Sent, .Response_Committed, .Node_Committed})
	first_send: journal.Record
	first_response: journal.Record
	for record in records {
		if first_send.seq == 0 && record.kind == .Request_Sent {
			first_send = record
			continue
		}
		if first_send.seq != 0 && record.kind == .Response_Committed && record.request == first_send.request {
			first_response = record
			break
		}
	}
	if !testing.expect(test, first_send.seq != 0, "the first request was durably sent") ||
	   !testing.expect(test, first_response.seq != 0, "the first response was durably committed") { return }
	for record in records {
		if record.kind != .Node_Committed || record.seq <= first_send.seq || record.seq >= first_response.seq { continue }
		committed: journal.Node_Committed
		if decode_error := journal.payload_decode(record.data, &committed, context.temp_allocator); decode_error != nil {
			testing.fail_now(test, "the node commit could not be decoded")
		}
		testing.expect(test, committed.kind != journal.NODE_KIND_NAMES[.User], "no user node is committed between the send and its response")
	}
	ancestry, ancestry_error := journal.read_ancestry(chat.store, chat.session, chat.head, context.temp_allocator)
	if !testing.expect_value(test, ancestry_error, nil) { return }
	steering_after_answer := false
	for node in ancestry {
		if node.kind == .User && node.seq > first_response.seq && string(node.body) == probe.line { steering_after_answer = true }
	}
	testing.expect(test, steering_after_answer, "the queued line is recorded after the response")
}

@(private)
steering_request_ends_with_user_line :: proc(test: ^testing.T, request, expected_line, expected_answer: string) {
	_, separator, encoded := strings.partition(request, "\r\n\r\n")
	if !testing.expect(test, separator != "", "the provider request has a body") { return }
	value, parse_error := json.parse_string(encoded, .JSON, true, context.temp_allocator)
	if !testing.expect_value(test, parse_error, nil) { return }
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(test, object_ok, "the provider request is a JSON object") { return }
	messages, messages_ok := object["messages"].(json.Array)
	if !testing.expect(test, messages_ok && len(messages) >= 2, "the request has a conversation") { return }
	last, last_ok := messages[len(messages) - 1].(json.Object)
	prior, prior_ok := messages[len(messages) - 2].(json.Object)
	if !testing.expect(test, last_ok && prior_ok, "the last request messages are objects") { return }
	last_role, last_role_ok := last["role"].(json.String)
	last_content, last_content_ok := last["content"].(json.String)
	prior_role, prior_role_ok := prior["role"].(json.String)
	prior_content, prior_content_ok := prior["content"].(json.String)
	if !testing.expect(test, last_role_ok && last_content_ok && prior_role_ok && prior_content_ok, "the final request messages carry text") { return }
	testing.expect_value(test, string(prior_role), "assistant")
	testing.expect_value(test, string(prior_content), expected_answer)
	testing.expect_value(test, string(last_role), "user")
	testing.expect_value(test, string(last_content), expected_line)
}

// A line recorded for a turn that had finished answering continues that turn instead of
// leaving it to end: the request the selector proposes next is the one that answers it.
@(test)
test_input_left_at_the_end_of_a_turn_keeps_it_running :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "write a poem")

	// The turn's request is running and its response completes without proposing anything,
	// which is where a turn decides to finish.
	_test_begin_request(test, chat)
	testing.expect(test, chat_session_feed_completion(chat, chat_session_event_source(chat)))
	testing.expect_value(test, chat.state, Chat_State.Finalizing)

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	testing.expect(test, steer_push(&queue, "write another one"))
	chat_steering_observe(chat, {}, &steer)

	testing.expect_value(test, chat.state, Chat_State.Preparing)
	effect := chat_session_advance(chat)
	testing.expect_value(test, effect.kind, Chat_Effect_Kind.Start_Request)

	// The request that follows is built from the history the line is now part of.
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	projection := _test_projection(test, chat, &arena)
	if !testing.expect_value(test, len(projection.items), 2) { return }
	user, is_user := projection.items[1].payload.(Projected_User)
	if !testing.expect(test, is_user, "the line should be the next thing the model reads") { return }
	testing.expect_value(test, user.text, "write another one")
}

// Input is recorded only where it reads correctly: a call without its result is not such a
// point, because an entry placed there would be read where a result belongs. The line waits
// until the batch settles, which is the boundary the next request starts from.
@(test)
test_input_waits_until_the_tool_batch_settles :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "run it")
	_test_begin_request(test, chat)

	calls := []ai.Provider_Tool_Call{{ID = "call_1", Name = TOOL_SHELL_NAME, Arguments = `{"command":"true"}`}}
	staged_notice, _ := chat_session_feed_tool_calls(chat, chat_session_event_source(chat), calls)
	testing.expect_value(test, staged_notice, Chat_Notice.None)
	testing.expect_value(test, chat.state, Chat_State.Executing_Tools)

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	testing.expect(test, steer_push(&queue, "use the other file"))
	chat_steering_observe(chat, {}, &steer)

	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	projection := _test_projection(test, chat, &arena)
	for item in projection.items {
		user, is_user := item.payload.(Projected_User)
		if !is_user { continue }
		testing.expect(test, user.origin != journal.User_Origin.Steering, "a call without its result is not a point input may be read at")
	}

	// The batch settles, which is the point the line may be recorded at.
	testing.expect(test, chat_session_tools_done(chat, chat.active_turn_id, len(chat.pending_calls)))
	chat_steering_observe(chat, {}, &steer)

	after := _test_projection(test, chat, &arena)
	steered := false
	for item in after.items {
		if user, is_user := item.payload.(Projected_User); is_user && user.origin == journal.User_Origin.Steering {
			steered = true
			testing.expect_value(test, user.text, "use the other file")
		}
	}
	testing.expect(test, steered, "the line is recorded once the batch it would read into has settled")
	_, still_queued := steer_pop(&queue)
	testing.expect(test, !still_queued, "the line left the queue into the record")
}

// A turn that failed has nothing left to answer with, so its input does not restart it: the
// line stays in the record, and the next request from this history carries it.
@(test)
test_input_does_not_restart_a_turn_that_failed :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "write a poem")
	chat_session_fail_turn(chat, "the provider refused the request")

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	testing.expect(test, steer_push(&queue, "write another one"))
	chat_steering_observe(chat, {}, &steer)

	testing.expect_value(test, chat.state, Chat_State.Finalizing)
	effect := chat_session_advance(chat)
	testing.expect_value(test, effect.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(test, effect.status, Chat_Terminal_Status.Failed)
}

// A turn that ends without proposing another request keeps what it accepted pending: the
// line is in the journal, no User node delivered it, and the next turn delivers it before
// its own prompt, so the line is neither lost nor read twice.
@(test)
test_a_line_accepted_by_a_turn_that_ends_goes_with_the_next_prompt :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "start")

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	// The path stops before it can propose another request, which is what a turn that
	// failed its own request does: the selector goes straight to the terminal effect.
	chat_session_fail_turn(chat, "the provider refused the request")
	testing.expect(test, steer_push(&queue, "check the logs"))
	testing.expect(test, !chat_run_turn_steered(chat, {}, test_retry_policy(), {}, &steer), "the turn failed")
	testing.expect(test, !steer_pending(&queue), "the line left the queue for the journal")
	testing.expect_value(test, len(_test_records(test, chat, {.User_Input})), 1)

	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	testing.expect_value(test, len(_test_projection(test, chat, &arena).items), 1)

	_test_accept(test, chat, "next prompt")
	projection := _test_projection(test, chat, &arena)
	if !testing.expect_value(test, len(projection.items), 3) { return }
	for expected, index in ([]string{"start", "check the logs", "next prompt"}) {
		user, is_user := projection.items[index].payload.(Projected_User)
		if !testing.expect(test, is_user, "the entry should be user text") { return }
		testing.expect_value(test, user.text, expected)
	}
	user, _ := projection.items[1].payload.(Projected_User)
	testing.expect_value(test, user.origin, journal.User_Origin.Steering)
}

// A steering line reaches the model in the next request the turn makes, which is the
// whole point of accepting input during a turn: the request the turn was already sending
// is frozen, and this one is built from the history the line is now part of.
@(test)
test_a_steering_line_reaches_the_request_that_follows_it :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(test, chat, "say something")

	provider: Agent_Provider
	if !agent_provider_start(test, &provider, {agent_provider_reply("done")}) { return }
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
	testing.expect(test, steer_push(&queue, "check the logs"))

	testing.expect(test, chat_run_turn_steered(chat, connection, test_retry_policy(), {}, &steer), "the turn completed")
	if !testing.expect_value(test, agent_provider_request_count(&provider), 1) { return }
	testing.expect(test, strings.contains(agent_provider_request(&provider, 0), "check the logs"), "the request should carry the line the user sent")
}

// A line the store refuses was never accepted, so the turn that could not commit it does
// not take it: it goes back to the queue, in order, with the failure reported, and the
// front-end is never told it was queued. Nothing the user sent is dropped by a write that
// did not happen.
@(test)
test_a_line_the_store_refuses_stays_pending :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "start")

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	steer := Steer_Context {
		queue = &queue,
	}
	testing.expect(test, steer_push(&queue, "check the logs"))
	testing.expect(test, steer_push(&queue, "and the config"))
	// A store that has stopped writing refuses every line.
	_steer_store_refuse(chat)

	notices: Chat_Notice_Log
	observer := chat_notice_log_begin(&notices)
	defer chat_notice_log_destroy(&notices)
	chat_steering_accept(chat, observer, &steer)

	for expected in ([]string{"check the logs", "and the config"}) {
		line, queued := steer_pop(&queue)
		if !testing.expect(test, queued, "a line the store refused should still be queued") { return }
		testing.expect_value(test, line, expected)
		steer_line_free(&queue, line)
	}
	testing.expect(test, len(notices.lines) > 0, "the refusal is reported")
	testing.expect_value(test, chat_notice_log_count(&notices, STEER_ACCEPTED_NOTICE), 0)
}

@(test)
test_delivery_records_queued_lines_in_order :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "start")

	queue := steer_queue_init(context.temp_allocator)
	defer steer_queue_destroy(&queue)
	testing.expect(test, steer_push(&queue, "check the logs"))
	testing.expect(test, steer_push(&queue, "and the config"))
	steer := Steer_Context {
		queue = &queue,
	}
	chat_steering_observe(chat, {}, &steer)

	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	projection := _test_projection(test, chat, &arena)
	if !testing.expect_value(test, len(projection.items), 3) { return }
	for expected, index in ([]string{"start", "check the logs", "and the config"}) {
		user, is_user := projection.items[index].payload.(Projected_User)
		if !testing.expect(test, is_user, "the entry should be user text") { return }
		testing.expect_value(test, user.text, expected)
	}
}

// Steering_Crash_Probe pushes one line when the turn is about to send its request, and ends
// the turn once the journal holds the line, so the test leaves a session whose line was
// accepted while the provider request was blocked and never delivered.
Steering_Crash_Probe :: struct {
	queue:   ^Steer_Queue,
	control: ^Turn_Control,
	line:    string,
	pushed:  bool,
}

steering_crash_push :: proc(user_data: rawptr) {
	probe := cast(^Steering_Crash_Probe)user_data
	if probe.pushed { return }
	probe.pushed = steer_push(probe.queue, probe.line)
}

steering_crash_stop_when_accepted :: proc(user_data: rawptr, kind: Chat_Message_Kind, text: string) {
	probe := cast(^Steering_Crash_Probe)user_data
	if text == STEER_ACCEPTED_NOTICE { turn_control_stop(probe.control) }
}

// A line accepted during a blocked provider request is in the journal before anyone is told
// so, and the session that held it may go away. The next process to open the session finds
// the line, and the next prompt's request carries it once, before the prompt itself.
@(test)
test_a_line_accepted_before_a_crash_goes_with_the_next_prompt_once :: proc(test: ^testing.T) {
	first: Chat_Test
	chat_test_begin(test, &first, tool_loop_workspace(test))
	chat := &first.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(test, chat, "first prompt")

	// The provider accepts the connection and never answers, so the request stays blocked.
	blocked: Agent_Provider
	if !agent_provider_start(test, &blocked, {}) {
		chat_test_end(test, &first)
		return
	}
	defer agent_provider_stop(&blocked)
	blocked_connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&blocked),
	}
	defer delete(blocked_connection.Endpoint)

	queue := steer_queue_init(chat.allocator)
	defer steer_queue_destroy(&queue)
	control: Turn_Control
	probe := Steering_Crash_Probe {
		queue   = &queue,
		control = &control,
		line    = "check the logs",
	}
	observer := Chat_Observer {
		user_data        = &probe,
		request_prepared = steering_crash_push,
		message          = steering_crash_stop_when_accepted,
	}
	steer := Steer_Context {
		queue = &queue,
	}
	completed := chat_run_turn_steered(chat, blocked_connection, test_retry_policy(), observer, &steer, &control)
	testing.expect(test, !completed, "the turn ended before the blocked request answered")
	testing.expect(test, probe.pushed, "the line was queued while the request was being sent")
	accepted := _test_records(test, chat, {.User_Input})
	if !testing.expect_value(test, len(accepted), 1) {
		chat_test_end(test, &first)
		return
	}
	delivered, _ := journal.last_delivered_message(chat.store, chat.session)
	testing.expect_value(test, delivered, journal.Journal_Seq(0))
	accepted_seq := accepted[0].seq

	reopened: Chat_Test
	_ = chat_test_reopen(test, &first, &reopened, tool_loop_workspace(test))
	defer chat_test_end(test, &reopened)
	next := &reopened.chat
	chat_test_capacity(next, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	testing.expect_value(test, next.state, Chat_State.Idle)
	testing.expect(test, !chat_inbox_reports_pending(next), "an accepted line starts no turn of its own")

	answering: Agent_Provider
	if !agent_provider_start(test, &answering, {agent_provider_reply("done")}) { return }
	defer agent_provider_stop(&answering)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&answering, next.allocator),
	}
	defer delete(connection.Endpoint, next.allocator)
	_test_accept(test, next, "second prompt")
	testing.expect(test, chat_run_turn_steered(next, connection, test_retry_policy(), {}, nil), "the turn completed")
	if !testing.expect_value(test, agent_provider_request_count(&answering), 1) { return }
	request := agent_provider_request(&answering, 0)
	testing.expect_value(test, strings.count(request, probe.line), 1)
	line_at := strings.index(request, probe.line)
	prompt_at := strings.index(request, "second prompt")
	testing.expect(test, line_at >= 0 && prompt_at > line_at, "the line is read before the prompt that delivered it")
	delivered, _ = journal.last_delivered_message(next.store, next.session)
	testing.expect_value(test, delivered, accepted_seq)
}
