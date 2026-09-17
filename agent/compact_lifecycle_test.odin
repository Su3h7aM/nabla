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
	chat.context_window = 500_000
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
	if !testing.expect(t, chat_run_turn(chat, foreground, {})) { return }

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
	chat.context_window = 500_000
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
	prep, prep_err := chat_prepare(chat, dead)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	testing.expect_value(t, chat_compact_request(chat, .User_Command), Compact_Request_Result.Scheduled)
	chat_compact_consider(chat, {}, dead, &prep)
	chat_request_prep_destroy(&prep, chat.allocator)
	testing.expect_value(t, chat.compact.state, Compact_State.Running)
	if !compact_await_state(t, chat, .Idle) { return }

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
