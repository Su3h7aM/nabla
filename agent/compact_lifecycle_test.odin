#+test
package agent

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:agent/session"
import "nabla:ai"

// Background compaction is exercised against a plain HTTP provider, because the
// property worth testing is a timing one: the summary arrives while the foreground
// is working and the context it replaces has already moved on.

COMPACT_TEST_BOUND :: 10 * time.Second

COMPACT_TEST_SUMMARY :: "the earlier fixtures are built and their paths are recorded"

COMPACT_TEST_BODY ::
	"data: {\"choices\":[{\"delta\":{\"content\":\"" +
	COMPACT_TEST_SUMMARY +
	"\"},\"finish_reason\":null}]}\n\n" +
	"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" +
	"data: [DONE]\n\n"

FOREGROUND_TEST_BODY ::
	"data: {\"choices\":[{\"delta\":{\"content\":\"foreground-ok\"},\"finish_reason\":null}]}\n\n" +
	"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" +
	"data: [DONE]\n\n"

// Compact_Provider answers one request with a canned stream. A stalling one holds
// its response until the test releases it, which is how a summary that arrives
// late can be told apart from one that blocks.
Compact_Provider :: struct {
	listener: net.TCP_Socket,
	port:     int,
	thread:   ^thread.Thread,
	body:     string,
	stall:    bool,
	// stopping is how teardown ends a provider that never received a connection:
	// the listener is non-blocking, so the accept loop can observe it.
	stopping: b32,
	reached:  sync.Sema,
	release:  sync.Sema,
}

compact_provider_start :: proc(t: ^testing.T, provider: ^Compact_Provider, body: string, stall: bool) -> bool {
	provider^ = Compact_Provider {
		body  = body,
		stall = stall,
	}
	listener, listen_err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if listen_err != nil {
		testing.expectf(t, false, "provider could not listen: %v", listen_err)
		return false
	}
	endpoint, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil {
		testing.expectf(t, false, "provider had no endpoint: %v", endpoint_err)
		net.close(listener)
		return false
	}
	if block_err := net.set_blocking(listener, false); block_err != nil {
		testing.expectf(t, false, "provider could not go non-blocking: %v", block_err)
		net.close(listener)
		return false
	}
	provider.listener = listener
	provider.port = endpoint.port
	provider.thread = test_thread_start(compact_provider_serve, provider, "nabla-test-provider")
	if provider.thread == nil {
		testing.expectf(t, false, "provider thread could not start")
		net.close(listener)
		return false
	}
	return true
}

compact_provider_stop :: proc(provider: ^Compact_Provider) {
	if provider.thread == nil { return }
	sync.atomic_store(&provider.stopping, true)
	sync.sema_post(&provider.release)
	thread.join(provider.thread)
	thread.destroy(provider.thread)
	provider.thread = nil
	if provider.listener != {} {
		net.close(provider.listener)
		provider.listener = {}
	}
}

compact_provider_endpoint :: proc(provider: ^Compact_Provider, allocator := context.allocator) -> string {
	return fmt.aprintf("http://127.0.0.1:%d", provider.port, allocator = allocator)
}

compact_provider_serve :: proc(thread: ^thread.Thread) {
	provider := cast(^Compact_Provider)thread.data
	socket: net.TCP_Socket
	accepted := false
	for !accepted {
		if sync.atomic_load(&provider.stopping) { return }
		client, _, accept_err := net.accept_tcp(provider.listener)
		if accept_err == .Would_Block {
			time.sleep(2 * time.Millisecond)
			continue
		}
		if accept_err != .None { return }
		socket = client
		accepted = true
	}
	defer net.close(socket)
	if !compact_provider_read_request(socket) { return }
	sync.sema_post(&provider.reached)
	if provider.stall {
		if !sync.sema_wait_with_timeout(&provider.release, COMPACT_TEST_BOUND) { return }
	}
	head := fmt.aprintf(
		"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: %d\r\n\r\n",
		len(provider.body),
		allocator = context.temp_allocator,
	)
	_, _ = net.send_tcp(socket, transmute([]u8)head)
	_, _ = net.send_tcp(socket, transmute([]u8)provider.body)
}

// compact_provider_read_request reads a whole request: the head terminates at a
// blank line and content-length states how much body follows.
compact_provider_read_request :: proc(socket: net.TCP_Socket) -> bool {
	buffer: [64 * 1024]u8
	length := 0
	head_end := -1
	content_length := -1
	for {
		if length >= len(buffer) { return false }
		read, read_err := net.recv_tcp(socket, buffer[length:])
		if read_err != nil || read == 0 { return false }
		length += read
		if head_end < 0 {
			text := string(buffer[:length])
			if end := strings.index(text, "\r\n\r\n"); end >= 0 {
				head_end = end + 4
				content_length = compact_provider_content_length(text[:end])
				if content_length < 0 { return false }
			}
		}
		if head_end >= 0 && length >= head_end + content_length { return true }
	}
}

@(private)
compact_provider_content_length :: proc(head: string) -> int {
	marker := strings.index(head, "content-length: ")
	if marker < 0 { return -1 }
	rest := head[marker + len("content-length: "):]
	digits := 0
	for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' { digits += 1 }
	if digits == 0 { return -1 }
	value, parsed := strconv.parse_int(rest[:digits])
	if !parsed { return -1 }
	return value
}

compact_await_state :: proc(t: ^testing.T, chat: ^Chat_Session, wanted: Compact_State) -> bool {
	deadline := time.tick_add(time.tick_now(), COMPACT_TEST_BOUND)
	for time.tick_since(deadline) < 0 {
		chat_compact_poll(chat, {})
		if chat.compact.state == wanted { return true }
		if chat.compact.state == .Idle && wanted != .Idle { break }
		time.sleep(2 * time.Millisecond)
	}
	testing.fail_now(t, "the compaction never reached the expected state")
}

// compact_fixture_begin opens a session with a large prefix, so a summary of it
// is meaningfully smaller, and starts a background provider plus a foreground one.
Compact_Setup :: struct {
	chat:       Chat_Test,
	background: Compact_Provider,
	foreground: Compact_Provider,
	big_prompt: string,
}

compact_setup_begin :: proc(t: ^testing.T, setup: ^Compact_Setup) -> bool {
	chat_test_begin(t, &setup.chat, tool_loop_workspace(t))
	if !compact_provider_start(t, &setup.background, COMPACT_TEST_BODY, true) { return false }
	if !compact_provider_start(t, &setup.foreground, FOREGROUND_TEST_BODY, false) { return false }
	chat := &setup.chat.chat
	chat_test_capacity(chat, 500_000)
	setup.big_prompt = strings.repeat("context ", 4000) or_else ""
	if setup.big_prompt == "" { return false }
	_test_accept(t, chat, setup.big_prompt)
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.Assistant_Entry{text = text}})
	}
	return true
}

compact_setup_end :: proc(t: ^testing.T, setup: ^Compact_Setup) {
	delete(setup.big_prompt)
	compact_provider_stop(&setup.background)
	compact_provider_stop(&setup.foreground)
	chat_test_end(t, &setup.chat)
}

// The acceptance test: a summary arrives late, the foreground ran a whole turn in
// the meantime, and the context that results is the checkpoint followed by
// everything appended after the boundary it covers.
@(test)
test_a_background_compaction_keeps_the_work_that_followed_it :: proc(t: ^testing.T) {
	setup: Compact_Setup
	if !compact_setup_begin(t, &setup) { return }
	defer compact_setup_end(t, &setup)
	chat := &setup.chat.chat

	background := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = compact_provider_endpoint(&setup.background, context.temp_allocator),
	}
	foreground := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = compact_provider_endpoint(&setup.foreground, context.temp_allocator),
	}

	// What the foreground would send before any compaction, for comparison.
	before, before_err := chat_prepare(chat, background)
	if before_err != nil { testing.fail_now(t, "chat_prepare failed") }
	before_estimate := before.estimate
	chat_request_prep_destroy(&before, chat.allocator)

	// The agent asks for a compaction; the fork is frozen from the request it was
	// about to send.
	prep, prep_err := chat_prepare(chat, background)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	testing.expect_value(t, chat_compact_request(chat, .Agent_Tool, nil), Compact_Request_Result.Scheduled)
	chat_compact_consider(chat, {}, background, &prep)
	testing.expect_value(t, chat.compact.state, Compact_State.Running)
	chat_request_prep_destroy(&prep, chat.allocator)

	// The summarizer has been asked, so the prefix is provably fixed.
	if !sync.sema_wait_with_timeout(&setup.background.reached, COMPACT_TEST_BOUND) {
		testing.fail_now(t, "the summarizer was never asked")
	}

	// The foreground completes a whole turn with the old context while the summary
	// is still in flight.
	if !testing.expect(t, chat_run_turn(chat, foreground, test_retry_policy(), {})) { return }

	// And one more entry lands after the fork.
	appended := _test_append(t, chat, {created_at_ms = 3_000, payload = session.Assistant_Entry{text = "after the fork"}})

	sync.sema_post(&setup.background.release)
	if !compact_await_state(t, chat, .Ready) { return }
	testing.expect(t, chat_compact_install(chat, {}))

	// The active context is the checkpoint and everything after the boundary it
	// covers, including the entry appended while the summary was in flight.
	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	testing.expect(t, strings.contains(ctx.summary, COMPACT_TEST_SUMMARY))
	survived_appended := false
	survived_foreground := false
	for entry in ctx.entries {
		if entry.seq == appended { survived_appended = true }
		if text, is_assistant := entry.payload.(session.Assistant_Entry); is_assistant && strings.contains(text.text, "foreground-ok") {
			survived_foreground = true
		}
	}
	testing.expect(t, survived_appended, "an entry appended during compaction must survive installation")
	testing.expect(t, survived_foreground, "the work done during compaction must survive installation")

	// The next request opens with the checkpoint, and it is smaller than what it
	// replaced. The old prefix was the frozen request's messages; the new one is
	// the checkpoint plus the tail.
	after, after_err := chat_prepare(chat, background)
	if after_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&after, chat.allocator)
	testing.expect(t, len(after.request.Messages) > 0)
	testing.expect(t, strings.contains(after.request.Messages[0].Content, COMPACT_TEST_SUMMARY))
	testing.expect(t, after.estimate < before_estimate, "the compacted context must cost less than the one it replaced")
}

// A summary that never arrives leaves the session exactly as it was: no
// checkpoint, every entry still active, and the attempt recorded and closed.
@(test)
test_a_failed_compaction_leaves_the_context_alone :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)
	_test_accept(t, chat, "first")
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.Assistant_Entry{text = text}})
	}
	before_entries := _test_entries(t, chat)
	expected_entries := len(before_entries)
	session.entries_destroy(before_entries, context.allocator)

	dead := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = "http://127.0.0.1:9/",
	}
	chat.compact_retry = test_compact_retry_policy()
	prep, prep_err := chat_prepare(chat, dead)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	testing.expect_value(t, chat_compact_request(chat, .User_Command), Compact_Request_Result.Scheduled)
	chat_compact_consider(chat, {}, dead, &prep)
	chat_request_prep_destroy(&prep, chat.allocator)
	testing.expect_value(t, chat.compact.state, Compact_State.Running)
	// A dead endpoint fails every attempt a chain may make, and the chain then ends.
	if !compact_service_until(t, chat, .Idle) { return }
	// The chain is exactly what the bound allows, and no further attempt begins.
	last, last_err := session.request_load(chat.store, chat.id, session.Request_No(CHAT_COMPACT_MAX_ATTEMPTS), chat.allocator)
	if !testing.expect_value(t, last_err, nil) { return }
	session.request_destroy(&last, chat.allocator)
	_, beyond_err := session.request_load(chat.store, chat.id, session.Request_No(CHAT_COMPACT_MAX_ATTEMPTS + 1), chat.allocator)
	testing.expect(t, beyond_err != nil, "an exhausted chain begins no further attempt")

	_, has_checkpoint, checkpoint_err := session.entry_latest_checkpoint(chat.store, chat.id)
	if checkpoint_err != nil { testing.fail_now(t, "entry_latest_checkpoint failed") }
	testing.expect(t, !has_checkpoint, "a failed compaction must not write a checkpoint")

	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	testing.expect_value(t, ctx.summary, "")
	testing.expect_value(t, len(ctx.entries), expected_entries)

	// The attempt is a durable request, and it is closed rather than left running.
	request, request_err := session.request_load(chat.store, chat.id, 1)
	if request_err != nil { testing.fail_now(t, "the compaction request should exist") }
	defer session.request_destroy(&request)
	testing.expect_value(t, request.purpose, session.Request_Purpose.Compaction)
	testing.expect_value(t, request.outcome, session.Outcome.Failed)
}

// Teardown must not leave the worker running against memory the session is about
// to release.
@(test)
test_destroying_a_session_stops_its_compaction :: proc(t: ^testing.T) {
	setup: Compact_Setup
	if !compact_setup_begin(t, &setup) { return }
	chat := &setup.chat.chat
	background := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = compact_provider_endpoint(&setup.background, context.temp_allocator),
	}
	prep, prep_err := chat_prepare(chat, background)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	testing.expect_value(t, chat_compact_request(chat, .User_Command), Compact_Request_Result.Scheduled)
	chat_compact_consider(chat, {}, background, &prep)
	chat_request_prep_destroy(&prep, chat.allocator)
	testing.expect_value(t, chat.compact.state, Compact_State.Running)
	if !sync.sema_wait_with_timeout(&setup.background.reached, COMPACT_TEST_BOUND) {
		compact_setup_end(t, &setup)
		testing.fail_now(t, "the summarizer was never asked")
	}
	// chat_test_end destroys the session, which must stop the worker; the stalled
	// provider is released so the worker can actually observe the interrupt.
	compact_setup_end(t, &setup)
}

// The agent's own trigger reaches the same intent the automatic path and the
// command reach, and it returns without waiting for anything.
@(test)
test_the_compact_tool_records_an_intent_and_returns :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "run it")

	advertised := false
	for definition in chat.tools.definitions {
		if definition.name == TOOL_COMPACT_NAME { advertised = true }
	}
	testing.expect(t, advertised, "the harness must advertise context.compact")

	_test_stage_call(t, chat, "call_compact", `{}`, TOOL_COMPACT_NAME)
	testing.expect_value(t, chat_run_tools(chat, {}), 1)

	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	result, is_result := entries[len(entries) - 1].payload.(session.Tool_Result_Entry)
	if !testing.expect(t, is_result, "the call must have a result") { return }
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(result.content, `"state":"scheduled"`), "the result says the work was queued")

	// The intent is recorded, and nothing has started: a job starts at the next
	// request boundary, where the prefix it covers is a closed execution.
	testing.expect_value(t, chat.compact.pending, Compact_Trigger.Agent_Tool)
	testing.expect_value(t, chat.compact.state, Compact_State.Idle)
}

// A command while the session is settled starts the work immediately: there is no
// request boundary to wait for, and the request it freezes is the one it would
// send next.
@(test)
test_the_compact_command_starts_a_job_while_idle :: proc(t: ^testing.T) {
	setup: Compact_Setup
	if !compact_setup_begin(t, &setup) { return }
	defer compact_setup_end(t, &setup)
	chat := &setup.chat.chat
	chat.state = .Idle

	background := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = compact_provider_endpoint(&setup.background, context.temp_allocator),
	}
	testing.expect(t, chat_command_compact(chat, {}, background, nil))
	testing.expect_value(t, chat.compact.state, Compact_State.Running)
	testing.expect_value(t, chat.compact.trigger, Compact_Trigger.User_Command)
	if !sync.sema_wait_with_timeout(&setup.background.reached, COMPACT_TEST_BOUND) {
		testing.fail_now(t, "the summarizer was never asked")
	}
}

// Pressure alone starts the work, before any request has been refused and before
// the window is full.
@(test)
test_pressure_starts_a_compaction_before_the_window_is_full :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)
	_test_accept(t, chat, "first")
	// Enough context that the next request crosses the compaction trigger.
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.User_Entry{text = large, origin = .Prompt}})
	// More entries than the kept tail, so there is a prefix to summarize.
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_100, payload = session.Assistant_Entry{text = text}})
	}

	dead := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = "http://127.0.0.1:9/",
	}
	prep, prep_err := chat_prepare(chat, dead)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)

	// The trigger is where a summary starts, and it has to leave room for the
	// foreground to keep working, so the fixture stays below what the window admits.
	trigger := chat_compact_trigger(chat)
	testing.expect(t, prep.estimate >= trigger, "the fixture must cross the compaction trigger")
	testing.expect(t, prep.estimate <= chat_capacity_input_ceiling(chat.capacity), "the fixture must still be sendable")

	// A started summary says so, once, so the front-end can time it. Nothing was
	// started before this point, so no notice was emitted.
	notices: Chat_Notice_Log
	observer := chat_notice_log_begin(&notices)
	defer chat_notice_log_destroy(&notices)
	testing.expect_value(t, chat_notice_log_count(&notices, "background compaction"), 0)

	chat_compact_consider(chat, observer, dead, &prep)
	testing.expect_value(t, chat.compact.state, Compact_State.Running)
	testing.expect_value(t, chat.compact.trigger, Compact_Trigger.Pressure)
	testing.expect_value(t, chat_notice_log_count(&notices, "background compaction started"), 1)

	// A request that fits is never held up by the job. The dead endpoint fails every attempt
	// the chain may make, and a summary that never arrives writes no checkpoint.
	chat.compact_retry = test_compact_retry_policy()
	if !compact_service_until(t, chat, .Idle) { return }
	_, has_checkpoint, checkpoint_err := session.entry_latest_checkpoint(chat.store, chat.id)
	if checkpoint_err != nil { testing.fail_now(t, "entry_latest_checkpoint failed") }
	testing.expect(t, !has_checkpoint)
}

// A provider that rejects the payload as too large is answered with a rebuilt request: the
// harness installs the summary it already has, sends the request built against it, and the
// refused payload is never sent again.
@(test)
test_a_rejected_payload_is_repaired_from_a_ready_summary :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)
	_test_accept(t, chat, "first")
	// Enough context that the next request crosses the compaction trigger, and more entries
	// than the kept tail, so there is a prefix to summarize.
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.User_Entry{text = large, origin = .Prompt}})
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_100, payload = session.Assistant_Entry{text = text}})
	}

	overflow := `{"error":{"code":"context_length_exceeded","message":"This model's maximum context length is 128000 tokens"}}`
	responses := []string{agent_provider_reply(COMPACT_TEST_SUMMARY), agent_provider_refusal("400 Bad Request", overflow), agent_provider_reply("repaired")}
	provider: Agent_Provider
	if !agent_provider_start(t, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	// Pressure starts the summary, so it waits for the context to reach the size it was
	// started for instead of installing at the next boundary. It is ready, and not yet
	// installed, when the provider refuses the payload it does not fit.
	prep, prep_err := chat_prepare(chat, connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	chat_compact_consider(chat, {}, connection, &prep)
	chat_request_prep_destroy(&prep, chat.allocator)
	testing.expect_value(t, chat.compact.trigger, Compact_Trigger.Pressure)
	if !compact_await_state(t, chat, .Ready) { return }

	testing.expect(t, chat_run_turn(chat, connection, test_retry_policy(), {}), "the repaired turn completed")

	// Three sends: the summary, the payload the provider refused, and the request rebuilt
	// from the checkpoint. The refused payload is never sent again, and what replaces it is
	// smaller.
	if !testing.expect_value(t, len(provider.requests), 3) { return }
	testing.expect(t, provider.requests[2] != provider.requests[1], "the repaired request is a new payload")
	testing.expect(t, len(provider.requests[2]) < len(provider.requests[1]), "the repaired request is smaller")

	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	testing.expect(t, ctx.summary != "", "the checkpoint is installed")
	answered: session.Request_No
	has_answered := false
	for entry in ctx.entries {
		if answer, is_answer := entry.payload.(session.Assistant_Entry); is_answer && answer.text == "repaired" {
			answered, has_answered = entry.request_no.?
		}
	}
	if !testing.expect(t, has_answered, "the answer names the send that produced it") { return }

	// The refused send is a row of its own, and the send that replaced it names it.
	second, second_err := session.request_load(chat.store, chat.id, answered, chat.allocator)
	if !testing.expect_value(t, second_err, nil) { return }
	defer session.request_destroy(&second, chat.allocator)
	testing.expect_value(t, second.outcome, session.Outcome.Completed)
	attempt, recovery, previous := attempt_record(t, second.input_json)
	testing.expect_value(t, attempt, i64(2))
	testing.expect_value(t, recovery, "checkpoint_repair")
	first_number, has_previous := previous.?
	if !testing.expect(t, has_previous, "the repaired send names the refused one") { return }

	first, first_err := session.request_load(chat.store, chat.id, session.Request_No(first_number), chat.allocator)
	if !testing.expect_value(t, first_err, nil) { return }
	defer session.request_destroy(&first, chat.allocator)
	testing.expect_value(t, first.outcome, session.Outcome.Failed)
	evidence := error_record(t, first.error_json)
	testing.expect_value(t, evidence.failure_class, "context_overflow")
	testing.expect_value(t, evidence.recovery, "context_exhausted")
}

// A provider that rejects the payload with nothing to install ends the turn as context
// exhaustion, names the cause, and never sends the refused payload again.
@(test)
test_a_rejected_payload_with_nothing_to_install_ends_the_turn :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)
	_test_accept(t, chat, "first")
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.User_Entry{text = large, origin = .Prompt}})

	overflow := `{"error":{"code":"context_length_exceeded","message":"This model's maximum context length is 128000 tokens"}}`
	responses := []string{agent_provider_refusal("400 Bad Request", overflow)}
	provider: Agent_Provider
	if !agent_provider_start(t, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	testing.expect(t, !chat_run_turn(chat, connection, test_retry_policy(), {}), "the turn ends without a repair")
	// The refused payload is never sent again: there is nothing to send it with.
	testing.expect_value(t, len(provider.requests), 1)
	testing.expect_value(t, chat_session_repair_refusal(chat), Chat_Repair_Refusal.No_Candidate)
	testing.expect_value(t, chat_session_terminal_status(chat), Chat_Terminal_Status.Failed)
	reason, has_reason := chat_session_recovery_reason(chat)
	testing.expect(t, has_reason, "the turn records why its chain stopped")
	testing.expect_value(t, reason, Request_Recovery_Reason.Context_Exhausted)
	// The session keeps the pressure, so the next safe boundary starts the summary this
	// refusal was missing.
	testing.expect_value(t, chat.compact.pending, Compact_Trigger.Provider_Overflow)

	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	testing.expect_value(t, ctx.summary, "")
	request_no := session.Request_No(1)
	row, row_err := session.request_load(chat.store, chat.id, request_no, chat.allocator)
	if !testing.expect_value(t, row_err, nil) { return }
	defer session.request_destroy(&row, chat.allocator)
	testing.expect_value(t, row.outcome, session.Outcome.Failed)
	evidence := error_record(t, row.error_json)
	testing.expect_value(t, evidence.failure_class, "context_overflow")
	testing.expect_value(t, evidence.recovery, "context_exhausted")
}

// An idle session starts the summary a refused boundary recorded, from the prefix the seam
// picks, and says so when a later tick installs one: the user asked for nothing here.
@(test)
test_an_idle_session_starts_the_summary_a_refusal_recorded :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)
	_test_accept(t, chat, "first")
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.User_Entry{text = large, origin = .Prompt}})
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_100, payload = session.Assistant_Entry{text = text}})
	}
	// The turn is over, and the refusal left its intent behind.
	chat.state = .Idle
	testing.expect_value(t, chat_compact_request(chat, .Provider_Overflow), Compact_Request_Result.Scheduled)

	responses := []string{agent_provider_reply(COMPACT_TEST_SUMMARY)}
	provider: Agent_Provider
	if !agent_provider_start(t, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	notices: Chat_Notice_Log
	observer := chat_notice_log_begin(&notices)
	defer chat_notice_log_destroy(&notices)
	testing.expect(t, !chat_compact_idle_service(chat, observer, connection), "an idle tick that starts work changed no context")
	if !testing.expect_value(t, chat.compact.state, Compact_State.Running) { return }
	testing.expect_value(t, chat.compact.trigger, Compact_Trigger.Provider_Overflow)
	// The intent was consumed: a tick that has nothing recorded starts nothing.
	testing.expect(t, chat_compact_idle_service(chat, observer, connection) == false)
	if !compact_await_state(t, chat, .Ready) { return }

	testing.expect(t, chat_compact_idle_service(chat, observer, connection), "installing a ready summary changed the context")
	testing.expect_value(t, chat.compact.state, Compact_State.Idle)
	testing.expect(t, len(notices.lines) > 0, "an idle install is reported")
	_, has_checkpoint, checkpoint_err := session.entry_latest_checkpoint(chat.store, chat.id)
	if checkpoint_err != nil { testing.fail_now(t, "entry_latest_checkpoint failed") }
	testing.expect(t, has_checkpoint, "the checkpoint landed")
}

// compact_service_until services the session until it reaches a state, without waiting for
// anything it cannot do: it is what an idle tick does, in a loop.
compact_service_until :: proc(t: ^testing.T, chat: ^Chat_Session, wanted: Compact_State) -> bool {
	deadline := time.tick_add(time.tick_now(), COMPACT_TEST_BOUND)
	for time.tick_since(deadline) < 0 {
		chat_compact_service(chat, {})
		if chat.compact.state == wanted { return true }
		if chat.compact.state == .Idle && wanted != .Idle { break }
		time.sleep(2 * time.Millisecond)
	}
	testing.fail_now(t, fmt.tprintf("the compaction never reached %v, it is %v", wanted, chat.compact.state))
}

// A summary that failed the way a second send could repair is sent again, by the owner,
// with the same frozen bytes: the worker never retries, and the retry costs a request
// rather than a new preparation.
@(test)
test_a_transient_summary_failure_is_retried_on_the_same_bytes :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)
	chat.compact_retry = test_compact_retry_policy()
	_test_accept(t, chat, "first")
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.User_Entry{text = large, origin = .Prompt}})
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_100, payload = session.Assistant_Entry{text = text}})
	}

	responses := []string {
		agent_provider_refusal("503 Service Unavailable", `{"error":{"message":"try again later"}}`),
		agent_provider_reply(COMPACT_TEST_SUMMARY),
	}
	provider: Agent_Provider
	if !agent_provider_start(t, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	prep, prep_err := chat_prepare(chat, connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	// Pressure starts the summary, so it waits for the context to reach the size it was
	// started for instead of installing at the next boundary: the test drives every attempt
	// itself.
	chat_compact_consider(chat, {}, connection, &prep)
	testing.expect_value(t, chat.compact.trigger, Compact_Trigger.Pressure)
	chat_request_prep_destroy(&prep, chat.allocator)

	// The first attempt fails, and the owner waits rather than discarding the snapshot.
	if !compact_service_until(t, chat, .Backoff) { return }
	// Then it sends the same bytes again, and the second attempt produces the summary.
	if !compact_service_until(t, chat, .Ready) { return }
	testing.expect_value(t, len(provider.requests), 2)
	testing.expect(t, provider.requests[0] == provider.requests[1], "the retry must send the same bytes")

	// The chain is two rows: the attempt that failed says what the provider said and that a
	// retry was decided, and the attempt that followed names it.
	second, second_err := session.request_load(chat.store, chat.id, session.Request_No(2), chat.allocator)
	if !testing.expect_value(t, second_err, nil) { return }
	defer session.request_destroy(&second, chat.allocator)
	testing.expect_value(t, second.outcome, session.Outcome.Completed)
	attempt, recovery, previous := attempt_record(t, second.input_json)
	testing.expect_value(t, attempt, i64(2))
	testing.expect_value(t, recovery, "transient_retry")
	first_number, has_previous := previous.?
	if !testing.expect(t, has_previous, "the retried attempt names the one before it") { return }
	testing.expect_value(t, first_number, i64(1))

	first, first_err := session.request_load(chat.store, chat.id, session.Request_No(1), chat.allocator)
	if !testing.expect_value(t, first_err, nil) { return }
	defer session.request_destroy(&first, chat.allocator)
	testing.expect_value(t, first.outcome, session.Outcome.Failed)
	evidence := error_record(t, first.error_json)
	testing.expect_value(t, evidence.failure_class, "provider_unavailable")
	testing.expect_value(t, evidence.recovery, "transient_failure")

	testing.expect(t, chat_compact_install(chat, {}), "the summary installs once it is ready")
}

// A summary the harness cannot use is not regenerated: the chain ends, and the session
// waits out the cooldown before any new snapshot starts.
@(test)
test_a_summary_that_produced_nothing_is_not_sent_again :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)
	chat.compact_retry = test_compact_retry_policy()
	_test_accept(t, chat, "first")
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.User_Entry{text = large, origin = .Prompt}})
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_100, payload = session.Assistant_Entry{text = text}})
	}

	// A stream that completes without writing anything: the exchange succeeded, and the
	// summary it produced is not one.
	responses := []string{agent_provider_reply("")}
	provider: Agent_Provider
	if !agent_provider_start(t, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	prep, prep_err := chat_prepare(chat, connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	// Pressure starts the summary, so it waits for the context to reach the size it was
	// started for instead of installing at the next boundary: the test drives every attempt
	// itself.
	chat_compact_consider(chat, {}, connection, &prep)
	testing.expect_value(t, chat.compact.trigger, Compact_Trigger.Pressure)
	chat_request_prep_destroy(&prep, chat.allocator)

	if !compact_service_until(t, chat, .Idle) { return }
	testing.expect_value(t, len(provider.requests), 1)
	testing.expect(t, chat.compact.last_failure_at_ms > 0, "a failed summary waits out its cooldown")

	row, row_err := session.request_load(chat.store, chat.id, session.Request_No(1), chat.allocator)
	if !testing.expect_value(t, row_err, nil) { return }
	defer session.request_destroy(&row, chat.allocator)
	testing.expect_value(t, row.outcome, session.Outcome.Failed)
}

// The chain is bounded: a second transient failure ends it, and nothing is sent again.
@(test)
test_a_summary_chain_stops_at_its_bound :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)
	chat.compact_retry = test_compact_retry_policy()
	_test_accept(t, chat, "first")
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.User_Entry{text = large, origin = .Prompt}})
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_100, payload = session.Assistant_Entry{text = text}})
	}

	refusal := agent_provider_refusal("503 Service Unavailable", `{"error":{"message":"try again later"}}`)
	responses := []string{refusal, refusal}
	provider: Agent_Provider
	if !agent_provider_start(t, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	prep, prep_err := chat_prepare(chat, connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	// Pressure starts the summary, so it waits for the context to reach the size it was
	// started for instead of installing at the next boundary: the test drives every attempt
	// itself.
	chat_compact_consider(chat, {}, connection, &prep)
	testing.expect_value(t, chat.compact.trigger, Compact_Trigger.Pressure)
	chat_request_prep_destroy(&prep, chat.allocator)

	// Two sends, one retry, and then the chain is over: the third send never leaves.
	if !compact_service_until(t, chat, .Idle) { return }
	testing.expect_value(t, len(provider.requests), 2)
	testing.expect(t, chat.compact.last_failure_at_ms > 0, "an exhausted chain waits out its cooldown")
	_, has_checkpoint, checkpoint_err := session.entry_latest_checkpoint(chat.store, chat.id)
	if checkpoint_err != nil { testing.fail_now(t, "entry_latest_checkpoint failed") }
	testing.expect(t, !has_checkpoint)
}
