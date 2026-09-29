#+test
package agent

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "core:mem/virtual"
import "nabla:agent/journal"
import "nabla:ai"

// Background compaction is exercised against a plain HTTP provider, because the
// property worth testing is a timing one: the summary arrives while the foreground
// is working and the context it replaces has already moved on.

COMPACT_TEST_BOUND :: 2 * time.Second

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

compact_provider_start :: proc(test: ^testing.T, provider: ^Compact_Provider, body: string, stall: bool) -> bool {
	provider^ = Compact_Provider {
		body  = body,
		stall = stall,
	}
	listener, listen_error := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0}, 1)
	if listen_error != nil {
		testing.expectf(test, false, "provider could not listen: %v", listen_error)
		return false
	}
	endpoint, endpoint_error := net.bound_endpoint(listener)
	if endpoint_error != nil {
		testing.expectf(test, false, "provider had no endpoint: %v", endpoint_error)
		net.close(listener)
		return false
	}
	if block_error := net.set_blocking(listener, false); block_error != nil {
		testing.expectf(test, false, "provider could not go non-blocking: %v", block_error)
		net.close(listener)
		return false
	}
	provider.listener = listener
	provider.port = endpoint.port
	provider.thread = test_thread_start(compact_provider_serve, provider, "nabla-test-provider")
	if provider.thread == nil {
		testing.expectf(test, false, "provider thread could not start")
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
		client, _, accept_error := net.accept_tcp(provider.listener)
		if accept_error == .Would_Block {
			time.sleep(2 * time.Millisecond)
			continue
		}
		if accept_error != .None { return }
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
		read, read_error := net.recv_tcp(socket, buffer[length:])
		if read_error != nil || read == 0 { return false }
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

compact_await_state :: proc(test: ^testing.T, chat: ^Chat_Session, wanted: Compact_State) -> bool {
	deadline := time.tick_add(time.tick_now(), COMPACT_TEST_BOUND)
	for time.tick_since(deadline) < 0 {
		chat_compact_poll(chat, {})
		if chat.compact.state == wanted { return true }
		if chat.compact.state == .Idle && wanted != .Idle { break }
		time.sleep(2 * time.Millisecond)
	}
	testing.fail_now(test, fmt.tprintf("the compaction never reached %v, it is %v", wanted, chat.compact.state))
}

// compact_fixture_begin opens a session with a large prefix, so a summary of it
// is meaningfully smaller, and starts a background provider plus a foreground one.
Compact_Setup :: struct {
	chat:       Chat_Test,
	background: Compact_Provider,
	foreground: Compact_Provider,
	big_prompt: string,
}

compact_setup_begin :: proc(test: ^testing.T, setup: ^Compact_Setup) -> bool {
	chat_test_begin(test, &setup.chat, tool_loop_workspace(test))
	started := false
	defer if !started { compact_setup_end(test, setup) }
	if !compact_provider_start(test, &setup.background, COMPACT_TEST_BODY, true) { return false }
	if !compact_provider_start(test, &setup.foreground, FOREGROUND_TEST_BODY, false) { return false }
	chat := &setup.chat.chat
	chat_test_capacity(chat, 500_000)
	setup.big_prompt = strings.repeat("context ", 4000) or_else ""
	if setup.big_prompt == "" { return false }
	_test_accept(test, chat, setup.big_prompt)
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}
	started = true
	return true
}

compact_setup_end :: proc(test: ^testing.T, setup: ^Compact_Setup) {
	delete(setup.big_prompt)
	compact_provider_stop(&setup.background)
	compact_provider_stop(&setup.foreground)
	chat_test_end(test, &setup.chat)
}

// The acceptance test: a summary arrives late, the foreground ran a whole turn in
// the meantime, and the context that results is the checkpoint followed by
// everything appended after the boundary it covers.
@(test)
test_a_background_compaction_keeps_the_work_that_followed_it :: proc(test: ^testing.T) {
	setup: Compact_Setup
	if !compact_setup_begin(test, &setup) { return }
	defer compact_setup_end(test, &setup)
	chat := &setup.chat.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	background := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = compact_provider_endpoint(&setup.background, context.temp_allocator),
	}
	foreground := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = compact_provider_endpoint(&setup.foreground, context.temp_allocator),
	}

	// What the foreground would send before any compaction, for comparison.
	before, before_error := chat_prepare(chat, background, virtual.arena_allocator(&arena))
	if before_error != nil { testing.fail_now(test, "chat_prepare failed") }
	before_estimate := before.estimate

	// The agent asks for a compaction; the fork is frozen from the request it was
	// about to send.
	prep, prep_error := chat_prepare(chat, background, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }
	testing.expect_value(test, chat_compact_request(chat, .Agent_Tool), Compact_Request_Result.Scheduled)
	chat_compact_consider(chat, {}, background, &prep)
	testing.expect_value(test, chat.compact.state, Compact_State.Running)

	// The summarizer has been asked, so the prefix is provably fixed.
	if !sync.sema_wait_with_timeout(&setup.background.reached, COMPACT_TEST_BOUND) {
		testing.fail_now(test, "the summarizer was never asked")
	}

	// The foreground completes a whole turn with the old context while the summary
	// is still in flight.
	if !testing.expect(test, chat_run_turn(chat, foreground, test_retry_policy(), {})) { return }

	// And one more entry lands after the fork.
	appended := _test_response(test, chat, 0, "after the fork")

	sync.sema_post(&setup.background.release)
	if !compact_await_state(test, chat, .Ready) { return }
	testing.expect(test, chat_compact_install(chat, {}))

	// The start is recorded under the compaction's own request, before the summary that ends it.
	compaction := _test_records(test, chat, {.Compaction_Started, .Compaction_Completed})
	if !testing.expect_value(test, len(compaction), 2) { return }
	testing.expect_value(test, compaction[0].kind, journal.Record_Kind.Compaction_Started)
	testing.expect_value(test, compaction[1].kind, journal.Record_Kind.Compaction_Completed)
	testing.expect(test, compaction[0].request != 0, "the start names the compaction's request")
	testing.expect_value(test, compaction[0].request, compaction[1].request)
	started: journal.Compaction_Started
	if decode_error := journal.payload_decode(compaction[0].data, &started, context.temp_allocator); decode_error != nil {
		testing.fail_now(test, "the compaction start could not be decoded")
	}
	testing.expect_value(test, started.trigger, compact_trigger_name(.Agent_Tool))
	testing.expect(test, started.covers != 0, "the start names the node the summary replaces")
	testing.expect(test, started.head_estimate > 0, "the start carries the estimate of the context it covers")

	// The active context is the checkpoint and everything after the boundary it
	// covers, including the entry appended while the summary was in flight.
	projection := _test_projection(test, chat, &arena)
	testing.expect(test, strings.contains(projection.summary, COMPACT_TEST_SUMMARY))
	survived_appended := false
	survived_foreground := false
	for entry in projection.items {
		if entry.node == appended { survived_appended = true }
		if text, is_assistant := entry.payload.(Projected_Assistant); is_assistant && strings.contains(text.text, "foreground-ok") {
			survived_foreground = true
		}
	}
	testing.expect(test, survived_appended, "an entry appended during compaction must survive installation")
	testing.expect(test, survived_foreground, "the work done during compaction must survive installation")

	// The next request opens with the checkpoint, and it is smaller than what it
	// replaced. The old prefix was the frozen request's messages; the new one is
	// the checkpoint plus the tail.
	after, after_error := chat_prepare(chat, background, virtual.arena_allocator(&arena))
	if after_error != nil { testing.fail_now(test, "chat_prepare failed") }

	testing.expect(test, len(after.request.Messages) > 0)
	testing.expect(test, strings.contains(after.request.Messages[0].Content, COMPACT_TEST_SUMMARY))
	testing.expect(test, after.estimate < before_estimate, "the compacted context must cost less than the one it replaced")
}

// compact_test_final_refusal is a transient refusal the provider forbids resending, so a summary
// chain ends after one send without suppressing later automatic starts.
compact_test_final_refusal :: proc() -> string {
	return agent_provider_refusal("503 Service Unavailable", `{"error":{"message":"try again later"}}`, "x-should-retry: false\r\n")
}

// A summary that never arrives leaves the session exactly as it was: no
// checkpoint, every entry still active, and the attempt recorded and closed.
@(test)
test_a_failed_compaction_leaves_the_context_alone :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	chat_test_capacity(chat, 500_000)
	_test_accept(test, chat, "first")
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}
	before_projection := _test_projection(test, chat, &arena)
	expected_entries := len(before_projection.items)

	provider: Agent_Provider
	responses := []string{compact_test_final_refusal()}
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)
	prep, prep_error := chat_prepare(chat, connection, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }
	testing.expect_value(test, chat_compact_request(chat, .User_Command), Compact_Request_Result.Scheduled)
	chat_compact_consider(chat, {}, connection, &prep)

	testing.expect_value(test, chat.compact.state, Compact_State.Running)
	if !compact_service_until(test, chat, .Idle) { return }
	testing.expect_value(test, agent_provider_request_count(&provider), 1)

	testing.expect(test, chat.compact.checkpoint == 0, "a failed compaction must not write a checkpoint")

	projection := _test_projection(test, chat, &arena)
	testing.expect_value(test, projection.summary, "")
	testing.expect_value(test, len(projection.items), expected_entries)

	// The attempt is a durable request, and it is closed rather than left running.
	sends := _test_records(test, chat, {.Request_Sent})
	rejections := _test_records(test, chat, {.Response_Rejected})
	if !testing.expect_value(test, len(sends), 1) || !testing.expect_value(test, len(rejections), 1) { return }
	sent: journal.Request_Sent
	if decode_error := journal.payload_decode(sends[0].data, &sent, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "compaction send could not be decoded") }
	testing.expect_value(test, sent.purpose, journal.REQUEST_PURPOSE_NAMES[.Compaction])
	testing.expect_value(test, len(sent.body_digest), journal.DIGEST_HEX_LENGTH)
	testing.expect(test, sent.body_bytes > 0, "the frozen body was not recorded with its size")
	testing.expect_value(test, rejections[0].request, sends[0].request)
}

// Teardown stops a running summary and abandons a worker that has not published, so the worker is
// never left running against memory the session is about to release.
@(test)
test_destroying_a_session_stops_its_compaction :: proc(test: ^testing.T) {
	setup: Compact_Setup
	if !compact_setup_begin(test, &setup) { return }
	chat := &setup.chat.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	background := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = compact_provider_endpoint(&setup.background, context.temp_allocator),
	}
	prep, prep_error := chat_prepare(chat, background, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }
	testing.expect_value(test, chat_compact_request(chat, .User_Command), Compact_Request_Result.Scheduled)
	chat_compact_consider(chat, {}, background, &prep)

	testing.expect_value(test, chat.compact.state, Compact_State.Running)
	if !sync.sema_wait_with_timeout(&setup.background.reached, COMPACT_TEST_BOUND) {
		compact_setup_end(test, &setup)
		testing.fail_now(test, "the summarizer was never asked")
	}
	// chat_test_end destroys the session, which must stop the worker; the stalled
	// provider is released so the worker can actually observe the interrupt.
	compact_setup_end(test, &setup)
}

// The agent's own trigger reaches the same intent the automatic path and the
// command reach, and it returns without waiting for anything.
@(test)
test_the_compact_tool_records_an_intent_and_returns :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	chat.tools_enabled = true
	_test_accept(test, chat, "run it")

	advertised := false
	for definition in chat.tools.definitions {
		if definition.name == TOOL_COMPACT_NAME { advertised = true }
	}
	testing.expect(test, advertised, "the harness must advertise context.compact")

	_test_stage_call(test, chat, "call_compact", `{}`, TOOL_COMPACT_NAME)
	testing.expect_value(test, chat_run_tools(chat, {}), 1)

	results := _test_records(test, chat, {.Tool_Completed})
	if !testing.expect_value(test, len(results), 1) { return }
	result: journal.Tool_Completed
	if decode_error := journal.payload_decode(results[0].data, &result, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "tool completion could not be decoded") }
	testing.expect_value(test, result.outcome, journal.TOOL_OUTCOME_NAMES[.Success])
	testing.expect(test, strings.contains(string(results[0].body), `state: scheduled`), "the result says the work was queued")

	// The intent is recorded, and nothing has started: a job starts at the next
	// request boundary, where the prefix it covers is a closed execution.
	testing.expect_value(test, chat.compact.pending, Compact_Trigger.Agent_Tool)
	testing.expect_value(test, chat.compact.state, Compact_State.Idle)
}

// A command while the session is settled starts the work immediately: there is no
// request boundary to wait for, and the request it freezes is the one it would
// send next.
@(test)
test_the_compact_command_starts_a_job_while_idle :: proc(test: ^testing.T) {
	setup: Compact_Setup
	if !compact_setup_begin(test, &setup) { return }
	defer compact_setup_end(test, &setup)
	chat := &setup.chat.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	chat.state = .Idle

	background := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = compact_provider_endpoint(&setup.background, context.temp_allocator),
	}
	testing.expect(test, chat_command_compact(chat, {}, background))
	testing.expect_value(test, chat.compact.state, Compact_State.Running)
	testing.expect_value(test, chat.compact.trigger, Compact_Trigger.User_Command)
	if !sync.sema_wait_with_timeout(&setup.background.reached, COMPACT_TEST_BOUND) {
		testing.fail_now(test, "the summarizer was never asked")
	}
}

// Pressure alone starts the work, before any request has been refused and before
// the window is full.
@(test)
test_pressure_starts_a_compaction_before_the_window_is_full :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	chat_test_capacity(chat, 500_000)
	_test_accept(test, chat, "first")
	// Enough context that the next request crosses the compaction trigger.
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_user(test, chat, large, .Prompt)
	// More entries than the kept tail, so there is a prefix to summarize.
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}

	provider: Agent_Provider
	responses := []string{compact_test_final_refusal()}
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)
	prep, prep_error := chat_prepare(chat, connection, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }

	// The trigger is where a summary starts, and it has to leave room for the
	// foreground to keep working, so the fixture stays below what the window admits.
	trigger := chat_compact_trigger(chat)
	testing.expect(test, prep.estimate >= trigger, "the fixture must cross the compaction trigger")
	testing.expect(test, prep.estimate <= chat_capacity_input_ceiling(chat.capacity), "the fixture must still be sendable")

	// A started summary says so, once, so the front-end can time it. Nothing was
	// started before this point, so no notice was emitted.
	notices: Chat_Notice_Log
	observer := chat_notice_log_begin(&notices)
	defer chat_notice_log_destroy(&notices)
	testing.expect_value(test, chat_notice_log_count(&notices, "background compaction"), 0)

	chat_compact_consider(chat, observer, connection, &prep)
	testing.expect_value(test, chat.compact.state, Compact_State.Running)
	testing.expect_value(test, chat.compact.trigger, Compact_Trigger.Pressure)
	testing.expect_value(test, chat_notice_log_count(&notices, "background compaction started"), 1)

	// A request that fits is never held up by the job, and a summary that never arrives
	// writes no checkpoint.
	if !compact_service_until(test, chat, .Idle) { return }
	projection := _test_projection(test, chat, &arena)
	testing.expect_value(test, projection.checkpoint, journal.Node_Id(0))
}

// A provider that rejects the payload as too large is answered with a rebuilt request: the
// harness installs the summary it already has, sends the request built against it, and the
// refused payload is never sent again.
@(test)
test_a_rejected_payload_is_repaired_from_a_ready_summary :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	chat_test_capacity(chat, 500_000)
	_test_accept(test, chat, "first")
	// Enough context that the next request crosses the compaction trigger, and more entries
	// than the kept tail, so there is a prefix to summarize.
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_user(test, chat, large, .Prompt)
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}

	overflow := `{"error":{"code":"context_length_exceeded","message":"This model's maximum context length is 128000 tokens"}}`
	responses := []string{agent_provider_reply(COMPACT_TEST_SUMMARY), agent_provider_refusal("400 Bad Request", overflow), agent_provider_reply("repaired")}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	// Pressure starts the summary, so it waits for the context to reach the size it was
	// started for instead of installing at the next boundary. It is ready, and not yet
	// installed, when the provider refuses the payload it does not fit.
	prep, prep_error := chat_prepare(chat, connection, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }
	chat_compact_consider(chat, {}, connection, &prep)

	testing.expect_value(test, chat.compact.trigger, Compact_Trigger.Pressure)
	if !compact_await_state(test, chat, .Ready) { return }

	testing.expect(test, chat_run_turn(chat, connection, test_retry_policy(), {}), "the repaired turn completed")

	// Three sends: the summary, the payload the provider refused, and the request rebuilt
	// from the checkpoint. The refused payload is never sent again, and what replaces it is
	// smaller.
	if !testing.expect_value(test, agent_provider_request_count(&provider), 3) { return }
	refused := agent_provider_request(&provider, 1)
	repaired := agent_provider_request(&provider, 2)
	testing.expect(test, repaired != refused, "the repaired request is a new payload")
	testing.expect(test, len(repaired) < len(refused), "the repaired request is smaller")

	projection := _test_projection(test, chat, &arena)
	testing.expect(test, projection.summary != "", "the checkpoint is installed")
	answered: journal.Request_Id
	has_answered := false
	for entry in projection.items {
		if answer, is_answer := entry.payload.(Projected_Assistant); is_answer && answer.text == "repaired" {
			answered = entry.request
			has_answered = answered != 0
		}
	}
	if !testing.expect(test, has_answered, "the answer names the send that produced it") { return }

	sends := _test_records(test, chat, {.Request_Sent})
	rejections := _test_records(test, chat, {.Response_Rejected})
	compactions := _test_records(test, chat, {.Compaction_Completed})
	committed := _test_records(test, chat, {.Response_Committed})
	if !testing.expect_value(test, len(sends), 3) ||
	   !testing.expect_value(test, len(rejections), 1) ||
	   !testing.expect_value(test, len(compactions), 1) ||
	   !testing.expect(test, len(committed) > 0) { return }
	first := sends[1]
	second := sends[2]
	testing.expect_value(test, second.request, answered)
	testing.expect_value(test, second.request, first.request)
	testing.expect_value(test, second.attempt, journal.Attempt_No(2))
	testing.expect_value(test, committed[len(committed) - 1].request, answered)
	sent: journal.Request_Sent
	if decode_error := journal.payload_decode(second.data, &sent, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "repair send could not be decoded") }
	testing.expect_value(test, sent.recovery, "checkpoint_repair")
	testing.expect_value(test, rejections[0].request, first.request)
	evidence: journal.Response_Rejected
	if decode_error := journal.payload_decode(rejections[0].data, &evidence, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "rejection could not be decoded") }
	testing.expect_value(test, evidence.failure_class, "context_overflow")
	testing.expect_value(test, evidence.recovery, "context_exhausted")
}

// An overflow starts compaction when no summary is ready, waits for it, and sends the
// rebuilt request only after installing the checkpoint.
@(test)
test_a_rejected_payload_waits_for_a_summary_that_is_not_ready :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	chat_test_capacity(chat, 500_000)
	_test_accept(test, chat, "first")
	large := strings.repeat("work ", 160_000) or_else ""
	defer delete(large)
	_test_user(test, chat, large, .Prompt)
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}

	overflow := `{"error":{"code":"context_length_exceeded","message":"This model's maximum context length is 128000 tokens"}}`
	responses := []string{agent_provider_refusal("400 Bad Request", overflow), agent_provider_reply(COMPACT_TEST_SUMMARY), agent_provider_reply("repaired")}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	prep, prep_error := chat_prepare(chat, connection, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }
	testing.expect(test, prep.estimate < chat_compact_trigger(chat), "the summary is not started by pressure")
	testing.expect_value(test, chat.compact.state, Compact_State.Idle)

	testing.expect(test, chat_run_turn(chat, connection, test_retry_policy(), {}), "the overflow repaired after compaction")
	testing.expect_value(test, agent_provider_request_count(&provider), 3)
	testing.expect_value(test, chat_session_terminal_status(chat), Chat_Terminal_Status.Completed)

	refused := agent_provider_request(&provider, 0)
	repaired := agent_provider_request(&provider, 2)
	testing.expect(test, repaired != refused, "the repaired request is a new payload")
	testing.expect(test, len(repaired) < len(refused), "the repaired request is smaller")

	projection := _test_projection(test, chat, &arena)
	testing.expect(test, strings.contains(projection.summary, COMPACT_TEST_SUMMARY), "the summary was installed")
	has_answer := false
	for entry in projection.items {
		if answer, is_answer := entry.payload.(Projected_Assistant); is_answer && answer.text == "repaired" {
			has_answer = true
		}
	}
	testing.expect(test, has_answer, "the repaired response completed the turn")

	sends := _test_records(test, chat, {.Request_Sent})
	compactions := _test_records(test, chat, {.Compaction_Completed})
	if !testing.expect_value(test, len(sends), 3) || !testing.expect_value(test, len(compactions), 1) { return }
	second: journal.Request_Sent
	if decode_error := journal.payload_decode(sends[2].data, &second, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "repair send could not be decoded") }
	testing.expect_value(test, sends[2].attempt, journal.Attempt_No(2))
	testing.expect_value(test, second.recovery, "checkpoint_repair")
}

// An overflow cannot be repaired when the active history has no prefix to summarize.
@(test)
test_a_rejected_payload_without_a_compactable_prefix_ends_the_turn :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	chat_test_capacity(chat, 500_000)
	_test_accept(test, chat, "first")
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_user(test, chat, large, .Prompt)

	overflow := `{"error":{"code":"context_length_exceeded","message":"This model's maximum context length is 128000 tokens"}}`
	responses := []string{agent_provider_refusal("400 Bad Request", overflow)}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	testing.expect(test, !chat_run_turn(chat, connection, test_retry_policy(), {}), "the turn ends without a repair")
	// The refused payload is never sent again because compaction had no prefix to summarize.
	testing.expect_value(test, agent_provider_request_count(&provider), 1)
	testing.expect_value(test, chat_session_repair_refusal(chat), Chat_Repair_Refusal.No_Candidate)
	testing.expect_value(test, chat_session_terminal_status(chat), Chat_Terminal_Status.Failed)
	reason := chat_session_recovery_reason(chat)
	value, has_reason := reason.?
	testing.expect(test, has_reason, "the turn records why its chain stopped")
	testing.expect_value(test, value, Request_Recovery_Reason.Context_Exhausted)
	projection := _test_projection(test, chat, &arena)
	testing.expect_value(test, projection.summary, "")
	sends := _test_records(test, chat, {.Request_Sent})
	rejections := _test_records(test, chat, {.Response_Rejected})
	if !testing.expect_value(test, len(sends), 1) || !testing.expect_value(test, len(rejections), 1) { return }
	testing.expect_value(test, rejections[0].request, sends[0].request)
	evidence: journal.Response_Rejected
	if decode_error := journal.payload_decode(rejections[0].data, &evidence, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "rejection could not be decoded") }
	testing.expect_value(test, evidence.failure_class, "context_overflow")
	testing.expect_value(test, evidence.recovery, "context_exhausted")
	turns := _test_records(test, chat, {.Turn_Completed})
	if !testing.expect_value(test, len(turns), 1) { return }
	completed: journal.Turn_Completed
	if decode_error := journal.payload_decode(turns[0].data, &completed, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "turn outcome could not be decoded") }
	testing.expect_value(test, completed.outcome, journal.TURN_OUTCOME_NAMES[.Failed])
	testing.expect_value(test, completed.cause, "no_candidate")
}

// An idle session starts the summary a refused boundary recorded, from the prefix the seam
// picks, and says so when a later tick installs one: the user asked for nothing here.
@(test)
test_an_idle_session_starts_the_summary_a_refusal_recorded :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	chat_test_capacity(chat, 500_000)
	_test_accept(test, chat, "first")
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_user(test, chat, large, .Prompt)
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}
	// The turn is over, and the refusal left its intent behind.
	chat.state = .Idle
	testing.expect_value(test, chat_compact_request(chat, .Provider_Overflow), Compact_Request_Result.Scheduled)

	responses := []string{agent_provider_reply(COMPACT_TEST_SUMMARY)}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	notices: Chat_Notice_Log
	observer := chat_notice_log_begin(&notices)
	defer chat_notice_log_destroy(&notices)
	testing.expect(test, !chat_compact_idle_service(chat, observer, connection), "an idle tick that starts work changed no context")
	if !testing.expect_value(test, chat.compact.state, Compact_State.Running) { return }
	testing.expect_value(test, chat.compact.trigger, Compact_Trigger.Provider_Overflow)
	// The intent was consumed: a tick that has nothing recorded starts nothing.
	testing.expect(test, chat_compact_idle_service(chat, observer, connection) == false)
	if !compact_await_state(test, chat, .Ready) { return }

	testing.expect(test, chat_compact_idle_service(chat, observer, connection), "installing a ready summary changed the context")
	testing.expect_value(test, chat.compact.state, Compact_State.Idle)
	testing.expect(test, len(notices.lines) > 0, "an idle install is reported")
	projection := _test_projection(test, chat, &arena)
	testing.expect(test, projection.checkpoint != 0, "the checkpoint landed")
	testing.expect(test, projection.covers != 0, "the checkpoint covers the earlier context")
}

// compact_service_until services the session until it reaches a state, without waiting for
// anything it cannot do: it is what an idle tick does, in a loop.
compact_service_until :: proc(test: ^testing.T, chat: ^Chat_Session, wanted: Compact_State) -> bool {
	deadline := time.tick_add(time.tick_now(), COMPACT_TEST_BOUND)
	for time.tick_since(deadline) < 0 {
		chat_compact_service(chat, {})
		if chat.compact.state == wanted { return true }
		if chat.compact.state == .Idle && wanted != .Idle { break }
		time.sleep(2 * time.Millisecond)
	}
	testing.fail_now(test, fmt.tprintf("the compaction never reached %v, it is %v", wanted, chat.compact.state))
}

// A summary that failed the way a second send could repair is sent again, by the owner,
// with the same frozen bytes: the worker never retries, and the retry costs a request
// rather than a new preparation.
@(test)
test_a_transient_summary_failure_is_retried_on_the_same_bytes :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	chat_test_capacity(chat, 500_000)
	chat.compact_retry = test_retry_policy()
	_test_accept(test, chat, "first")
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_user(test, chat, large, .Prompt)
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}

	responses := []string {
		agent_provider_refusal("503 Service Unavailable", `{"error":{"message":"try again later"}}`),
		agent_provider_reply(COMPACT_TEST_SUMMARY),
	}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	prep, prep_error := chat_prepare(chat, connection, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }
	// Pressure starts the summary, so it waits for the context to reach the size it was
	// started for instead of installing at the next boundary: the test drives every attempt
	// itself.
	chat_compact_consider(chat, {}, connection, &prep)
	testing.expect_value(test, chat.compact.trigger, Compact_Trigger.Pressure)

	// The first attempt fails, and the owner waits rather than discarding the snapshot.
	if !compact_service_until(test, chat, .Backoff) { return }
	// Then it sends the same bytes again, and the second attempt produces the summary.
	if !compact_service_until(test, chat, .Ready) { return }
	testing.expect_value(test, agent_provider_request_count(&provider), 2)
	testing.expect(test, agent_provider_request(&provider, 0) == agent_provider_request(&provider, 1), "the retry must send the same bytes")

	sends := _test_records(test, chat, {.Request_Sent})
	rejections := _test_records(test, chat, {.Response_Rejected})
	committed := _test_records(test, chat, {.Compaction_Completed})
	if !testing.expect_value(test, len(sends), 2) ||
	   !testing.expect_value(test, len(rejections), 1) ||
	   !testing.expect_value(test, len(committed), 1) { return }
	testing.expect_value(test, sends[0].request, sends[1].request)
	testing.expect_value(test, sends[0].attempt, journal.Attempt_No(1))
	testing.expect_value(test, sends[1].attempt, journal.Attempt_No(2))
	testing.expect_value(test, committed[0].request, sends[1].request)
	sent: journal.Request_Sent
	if decode_error := journal.payload_decode(sends[1].data, &sent, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "retry send could not be decoded") }
	testing.expect_value(test, sent.recovery, "transient_retry")
	evidence: journal.Response_Rejected
	if decode_error := journal.payload_decode(rejections[0].data, &evidence, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "rejection could not be decoded") }
	testing.expect_value(test, evidence.failure_class, "provider_unavailable")
	testing.expect_value(test, evidence.recovery, "transient_failure")

	testing.expect(test, chat_compact_install(chat, {}), "the summary installs once it is ready")
}

@(test)
test_repeated_invalid_compaction_refusals_restore_omitted_features :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.model_api = .Anthropic_Messages
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	chat_test_capacity(chat, 500_000)
	chat.compact_retry = test_retry_policy()
	_test_accept(test, chat, "first")
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_user(test, chat, large, .Prompt)
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}
	refusal := agent_provider_refusal("400 Bad Request", `{"error":{"message":"Unsupported parameter: thinking"}}`)
	responses := []string{refusal, refusal, refusal}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .Anthropic_Messages,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)
	prep, prep_error := chat_prepare(chat, connection, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }
	chat_compact_consider(chat, {}, connection, &prep)
	if !compact_service_until(test, chat, .Idle) { return }
	if !testing.expect_value(test, agent_provider_request_count(&provider), 1) { return }
	first := agent_provider_request(&provider, 0)
	testing.expect(test, strings.contains(first, `"thinking":{"type":"adaptive"}`), "the compaction request carries adaptive thinking")
	testing.expect(test, .Adaptive_Thinking in chat.refused_features)
	testing.expect(test, .Cache_Hints not_in chat.refused_features)
	testing.expect(test, .Adaptive_Thinking in chat.compact.omitted_features)

	// A later compaction uses the normal request builder, which leaves out the refused feature.
	chat.compact.last_failure_at = time.tick_add(time.tick_now(), -CHAT_COMPACT_COOLDOWN - time.Second)
	testing.expect_value(test, chat_compact_request(chat, .User_Command), Compact_Request_Result.Scheduled)
	prep, prep_error = chat_prepare(chat, connection, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }
	chat_compact_consider(chat, {}, connection, &prep)
	if !compact_service_until(test, chat, .Idle) { return }
	if !testing.expect_value(test, agent_provider_request_count(&provider), 2) { return }
	second := agent_provider_request(&provider, 1)
	testing.expect(test, !strings.contains(second, "thinking"), "the next compaction request omits adaptive thinking")
	testing.expect(test, strings.contains(second, "cache_control"), "the next request retains cache hints")
	testing.expect(test, .Adaptive_Thinking in chat.refused_features)
	testing.expect(test, .Cache_Hints in chat.refused_features)
	testing.expect(test, chat.compact.omitted_features == {.Adaptive_Thinking, .Cache_Hints})

	// Once neither optional feature is present, another invalid request proves the omissions
	// did not repair it, so both are made available to later requests again.
	chat.compact.last_failure_at = time.tick_add(time.tick_now(), -CHAT_COMPACT_COOLDOWN - time.Second)
	testing.expect_value(test, chat_compact_request(chat, .User_Command), Compact_Request_Result.Scheduled)
	prep, prep_error = chat_prepare(chat, connection, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }
	chat_compact_consider(chat, {}, connection, &prep)
	if !compact_service_until(test, chat, .Idle) { return }
	if !testing.expect_value(test, agent_provider_request_count(&provider), 3) { return }
	third := agent_provider_request(&provider, 2)
	testing.expect(test, !strings.contains(third, "thinking"), "the final request omits adaptive thinking")
	testing.expect(test, !strings.contains(third, "cache_control"), "the final request omits cache hints")
	testing.expect_value(test, chat.refused_features, Optional_Request_Features{})
	testing.expect_value(test, chat.compact.omitted_features, Optional_Request_Features{})

	sends := _test_records(test, chat, {.Request_Sent})
	if !testing.expect_value(test, len(sends), 3) { return }
	for send in sends {
		sent: journal.Request_Sent
		if decode_error := journal.payload_decode(send.data, &sent, context.temp_allocator);
		   decode_error != nil { testing.fail_now(test, "the compaction send could not be decoded") }
		testing.expect_value(test, send.attempt, journal.Attempt_No(1))
		testing.expect_value(test, sent.recovery, "initial")
	}
	rejections := _test_records(test, chat, {.Response_Rejected})
	testing.expect_value(test, len(rejections), 3)
}

// A summary the harness cannot use is not regenerated: the chain ends, and the session
// waits out the cooldown before any new snapshot starts.
@(test)
test_a_summary_that_produced_nothing_is_not_sent_again :: proc(test: ^testing.T) {
	if !test_isolate_process(test, "test_a_summary_that_produced_nothing_is_not_sent_again") { return }
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	chat_test_capacity(chat, 500_000)
	chat.compact_retry = test_retry_policy()
	_test_accept(test, chat, "first")
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_user(test, chat, large, .Prompt)
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}

	// A stream that completes without writing anything: the exchange succeeded, and the
	// summary it produced is not one.
	responses := []string{agent_provider_reply("")}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	prep, prep_error := chat_prepare(chat, connection, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }
	// Pressure starts the summary, so it waits for the context to reach the size it was
	// started for instead of installing at the next boundary: the test drives every attempt
	// itself.
	chat_compact_consider(chat, {}, connection, &prep)
	testing.expect_value(test, chat.compact.trigger, Compact_Trigger.Pressure)

	if !compact_service_until(test, chat, .Idle) { return }
	testing.expect_value(test, agent_provider_request_count(&provider), 1)
	testing.expect(test, chat.compact.last_failure_at != {}, "a failed summary waits out its cooldown")

	sends := _test_records(test, chat, {.Request_Sent})
	rejections := _test_records(test, chat, {.Response_Rejected})
	if !testing.expect_value(test, len(sends), 1) || !testing.expect_value(test, len(rejections), 1) { return }
	testing.expect_value(test, sends[0].request, rejections[0].request)

}

// A summary the provider refuses for a reason the configuration would have to change for is
// not started again automatically. An explicit request is the user saying it is worth another
// try, so it clears that suppression.
@(test)
test_a_terminal_summary_failure_suppresses_automatic_starts :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	chat_test_capacity(chat, 500_000)
	chat.compact_retry = test_retry_policy()
	_test_accept(test, chat, "first")
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_user(test, chat, large, .Prompt)
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}

	responses := []string{agent_provider_refusal("401 Unauthorized", `{"error":{"message":"bad key"}}`)}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	prep, prep_error := chat_prepare(chat, connection, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }

	chat_compact_consider(chat, {}, connection, &prep)
	if !compact_service_until(test, chat, .Idle) { return }
	testing.expect(test, chat.compact.suppressed, "an unauthorized summary suppresses automatic starts")

	// The cooldown would explain a refusal on its own, so it is passed here: the suppression is
	// what stops the next automatic attempt.
	chat.compact.last_failure_at = time.tick_add(time.tick_now(), -CHAT_COMPACT_COOLDOWN - time.Second)
	chat_compact_consider(chat, {}, connection, &prep)
	testing.expect_value(test, chat.compact.state, Compact_State.Idle)

	testing.expect_value(test, chat_compact_request(chat, .User_Command), Compact_Request_Result.Scheduled)
	chat_compact_consider(chat, {}, connection, &prep)
	testing.expect(test, !chat.compact.suppressed, "an explicit request clears the suppression")
	testing.expect_value(test, chat.compact.state, Compact_State.Running)
}

// A chain that ended without a summary is not started again from the same context: the next
// automatic attempt waits for work the failed one never saw, because the same bytes would get
// the same answer.
@(test)
test_a_failed_chain_waits_for_the_context_to_move :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	chat_test_capacity(chat, 500_000)
	chat.compact_retry = test_retry_policy()
	_test_accept(test, chat, "first")
	large := strings.repeat("work ", 320_000) or_else ""
	defer delete(large)
	_test_user(test, chat, large, .Prompt)
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}

	provider: Agent_Provider
	responses := []string{compact_test_final_refusal()}
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	prep, prep_error := chat_prepare(chat, connection, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }
	chat_compact_consider(chat, {}, connection, &prep)
	if !compact_service_until(test, chat, .Idle) { return }
	testing.expect_value(test, agent_provider_request_count(&provider), 1)

	// Nothing about the context changed, so pressure starts nothing even with the cooldown
	// behind it.
	chat.compact.last_failure_at = time.tick_add(time.tick_now(), -CHAT_COMPACT_COOLDOWN - time.Second)
	chat_compact_consider(chat, {}, connection, &prep)
	testing.expect_value(test, chat.compact.state, Compact_State.Idle)

	// Work the failed chain never saw is what makes another summary worth asking for.
	_test_response(test, chat, 0, "after the failure")
	after, after_error := chat_prepare(chat, connection, virtual.arena_allocator(&arena))
	if after_error != nil { testing.fail_now(test, "chat_prepare failed") }

	chat_compact_consider(chat, {}, connection, &after)
	testing.expect_value(test, chat.compact.state, Compact_State.Running)
}

// --- a summary whose worker ignores its stop ----------------------------------

// Compact_Summary_Hold stands in for a summary's worker: it ignores the stop it is given until
// the test releases it, and then publishes the completion a worker that finally returned
// would. A summary against a real provider is a transport that observes cancellation, so only
// a hold like this can outlive its stop. A test allocates one on the process heap: the worker
// reaches it after the test's frame may be gone, and the owner releases the thread handle,
// never the test.
Compact_Summary_Hold :: struct {
	job:     ^Compact_Job,
	release: sync.Sema,
}

// COMPACT_HOLD_BOUND is how long a hold ignores its stop. It outlasts anything a test waits, so a
// test that abandons one never waits for the hold to give up by itself.
COMPACT_HOLD_BOUND :: time.Minute

compact_summary_hold_serve :: proc(thread: ^thread.Thread) {
	hold := cast(^Compact_Summary_Hold)thread.data
	_ = sync.sema_wait_with_timeout(&hold.release, COMPACT_HOLD_BOUND)
	sync.atomic_store(&hold.job.finished, true)
	owner_wake_signal()
}

// compact_hold_job_start builds the summary a running job is: its frozen request, the row of
// the send it made, and a worker that ignores its stop. It stands in for chat_compact_start,
// which starts the real transport instead.
@(private)
compact_hold_job_start :: proc(test: ^testing.T, chat: ^Chat_Session, hold: ^Compact_Summary_Hold) -> ^Compact_Job {
	job := new(Compact_Job, os.heap_allocator())
	if job == nil { return nil }
	job^ = {
		attempts = 1,
	}
	chat_compact_job_allocator(job)
	job.output = make([dynamic]u8, 0, job.allocator)
	job.snapshot = Compact_Snapshot {
		api  = .OpenAI_Chat_Completions,
		body = strings.clone("{}", job.allocator),
	}
	job.request = journal.next_request(chat.store)
	if !chat_compact_begin_attempt(chat, job) {
		testing.fail_now(test, "the stuck summary's send could not be recorded")
	}
	hold.job = job
	job.thread = test_thread_start(compact_summary_hold_serve, hold, "nabla-stuck-summary")
	if job.thread == nil { return nil }
	chat.compact.job = job
	chat.compact.state = .Running
	chat.compact.trigger = .Agent_Tool
	return job
}

// A summary whose worker ignores its stop is abandoned at the patience: the slot it held is
// free for the next summary, the attempt it left open is closed, and the job is released once
// its worker publishes.
@(test)
test_a_summary_that_ignores_its_stop_is_abandoned :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)

	hold := new(Compact_Summary_Hold, os.heap_allocator())
	released := false
	defer if !released { sync.sema_post(&hold.release) }
	job := compact_hold_job_start(test, chat, hold)
	if job == nil { testing.fail_now(test, "the stuck summary job could not be started") }

	// A model change stops the summary, which is what gives its worker a stop to ignore.
	chat_compact_cancel(chat)
	testing.expect_value(test, chat.compact.state, Compact_State.Retiring)

	// An observation past the patience: the worker has had as long as it gets, so the owner
	// stops waiting for it.
	job.stop_at = time.tick_add(time.tick_now(), -(TOOL_JOBS_STOP_PATIENCE + time.Millisecond))
	chat_compact_poll(chat, {})
	testing.expect_value(test, chat.compact.state, Compact_State.Idle)
	testing.expect_value(test, chat.compact.job, nil)
	testing.expect_value(test, len(chat.abandoned_compactions), 1)
	interrupted := _test_records(test, chat, {.Request_Interrupted})
	if !testing.expect_value(test, len(interrupted), 1) { return }
	testing.expect_value(test, interrupted[0].request, job.request)
	request := job.request

	// The slot is free, so new work takes over from the worker that did not stop.
	testing.expect_value(test, chat_compact_request(chat, .User_Command), Compact_Request_Result.Scheduled)

	// The worker publishes at last, and the owner releases the job then.
	sync.sema_post(&hold.release)
	released = true
	deadline := time.tick_add(time.tick_now(), COMPACT_TEST_BOUND)
	for len(chat.abandoned_compactions) > 0 && time.tick_since(deadline) < 0 {
		chat_compact_poll(chat, {})
		time.sleep(time.Millisecond)
	}
	testing.expect_value(test, len(chat.abandoned_compactions), 0)

	// Giving up on the worker and releasing it late are both recorded, under the summary's request.
	_test_commit(test, chat)
	jobs := _test_records(test, chat, {.Job_Abandoned, .Job_Reclaimed})
	if !testing.expect_value(test, len(jobs), 2) { return }
	testing.expect_value(test, jobs[0].kind, journal.Record_Kind.Job_Abandoned)
	testing.expect_value(test, jobs[1].kind, journal.Record_Kind.Job_Reclaimed)
	for record in jobs { testing.expect_value(test, record.request, request) }
	abandoned: journal.Job_Abandoned
	if decode_error := journal.payload_decode(jobs[0].data, &abandoned, context.temp_allocator); decode_error != nil {
		testing.fail_now(test, "the abandonment could not be decoded")
	}
	testing.expect_value(test, abandoned.job, journal.JOB_KIND_NAMES[.Compaction])
	testing.expect_value(test, abandoned.patience_ms, i64(TOOL_JOBS_STOP_PATIENCE / time.Millisecond))
}

// Teardown asks a summary's worker to stop and abandons it when it does not: nothing the worker
// can reach is released under it, and teardown never waits for it.
@(test)
test_teardown_abandons_a_summary_that_ignores_its_stop :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)

	hold := new(Compact_Summary_Hold, os.heap_allocator())
	released := false
	defer if !released { sync.sema_post(&hold.release) }
	job := compact_hold_job_start(test, chat, hold)
	if job == nil { testing.fail_now(test, "the stuck summary job could not be started") }

	started := time.tick_now()
	chat_compact_destroy(chat)
	testing.expect(test, time.tick_since(started) < TOOL_JOBS_STOP_PATIENCE, "teardown waited for a worker that ignores its stop")
	testing.expect_value(test, chat.compact.state, Compact_State.Idle)
	testing.expect_value(test, chat.compact.job, nil)
	// The worker is still parked, and the job it reads was not released under it.
	testing.expect(test, !sync.atomic_load(&job.finished), "teardown joined a summary's worker")

	// The rest of the session goes the way a front-end teardown leaves it.
	chat_test_end(test, &fixture)

	// This test releases what teardown left behind, so the leak it is about does not outlive it:
	// the worker publishes, and the handle and job it can no longer reach are released.
	sync.sema_post(&hold.release)
	released = true
	published := time.tick_add(time.tick_now(), COMPACT_TEST_BOUND)
	for !sync.atomic_load(&job.finished) && time.tick_since(published) < 0 { time.sleep(time.Millisecond) }
	if !testing.expect(test, sync.atomic_load(&job.finished), "the abandoned worker never published") { return }
	thread.destroy(job.thread)
	job.thread = nil
	chat_compact_job_destroy(job)
}
