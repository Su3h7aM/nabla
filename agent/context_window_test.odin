#+test
package agent

import "core:strings"
import "core:testing"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

// context_window_test_reply is an Anthropic stream that writes text and then stops for
// stop_reason.
context_window_test_reply :: proc(text, stop_reason: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate(
		{
			"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n",
			"event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1}}}\n\n",
			"event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
			"event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"",
			text,
			"\"}}\n\n",
			"event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
			"event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"",
			stop_reason,
			"\"}}\n\n",
			"event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
		},
		allocator,
	)
}

// context_window_test_finishes are the finish names the committed responses carry, oldest
// first, and context_window_test_purposes the purposes of the requests the session sent.
context_window_test_finishes :: proc(test: ^testing.T, chat: ^Chat_Session) -> []string {
	records := _test_records(test, chat, {.Response_Committed})
	finishes := make([]string, len(records), context.temp_allocator)
	for record, index in records {
		committed: journal.Response_Committed
		if !testing.expect_value(test, journal.payload_decode(record.data, &committed, context.temp_allocator), nil) { return nil }
		finishes[index] = committed.finish
	}
	return finishes
}

context_window_test_purposes :: proc(test: ^testing.T, chat: ^Chat_Session) -> []string {
	records := _test_records(test, chat, {.Request_Sent})
	purposes := make([]string, len(records), context.temp_allocator)
	for record, index in records {
		sent: journal.Request_Sent
		if !testing.expect_value(test, journal.payload_decode(record.data, &sent, context.temp_allocator), nil) { return nil }
		purposes[index] = sent.purpose
	}
	return purposes
}

// context_window_test_notice is the body of the one Notice node the session committed.
context_window_test_notice :: proc(test: ^testing.T, chat: ^Chat_Session) -> string {
	ancestry, ancestry_error := journal.read_ancestry(chat.store, chat.session, chat.head, context.temp_allocator)
	if !testing.expect_value(test, ancestry_error, nil) { return "" }
	notice := ""
	count := 0
	for node in ancestry {
		if node.kind != .Notice { continue }
		notice = string(node.body)
		count += 1
	}
	testing.expect_value(test, count, 1)
	return notice
}

// A response that filled the context window is committed truncated and executes nothing. The
// model is told the window filled, and the conversation is compacted before the next request,
// so the next request does not fill the window again.
@(test)
test_a_filled_context_window_compacts_before_the_next_request :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.model_api = .Anthropic_Messages
	chat_test_capacity(chat, 500_000)
	_test_accept(test, chat, "first")
	// More entries than the kept tail, so there is a prefix to summarize.
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}

	// The summary and the answer are the same stream, so which of the two requests reaches the
	// provider first does not matter.
	answer := context_window_test_reply("done", "end_turn")
	responses := []string{context_window_test_reply("half of a long ans", "model_context_window_exceeded"), answer, answer}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .Anthropic_Messages,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	testing.expect(test, chat_run_turn(chat, connection, test_retry_policy(), {}), "the turn completes after the compaction")

	// The summarizer's request is recorded before the request that follows the truncated one.
	purposes := context_window_test_purposes(test, chat)
	if !testing.expect_value(test, len(purposes), 3) { return }
	testing.expect_value(test, purposes[0], journal.REQUEST_PURPOSE_NAMES[.Response])
	testing.expect_value(test, purposes[1], journal.REQUEST_PURPOSE_NAMES[.Compaction])
	testing.expect_value(test, purposes[2], journal.REQUEST_PURPOSE_NAMES[.Response])

	// The seeded history committed twelve responses before the two this turn made.
	finishes := context_window_test_finishes(test, chat)
	if testing.expect_value(test, len(finishes), 14) {
		testing.expect_value(test, finishes[12], journal.RESPONSE_FINISH_NAMES[.Context_Window])
		testing.expect_value(test, finishes[13], journal.RESPONSE_FINISH_NAMES[.Stop])
	}
	testing.expect_value(test, context_window_test_notice(test, chat), chat_notice_text(.Context_Window))
	testing.expect(test, strings.contains(chat_notice_text(.Context_Window), "context window"), "the notice names the context window")
	testing.expect(test, !strings.contains(chat_notice_text(.Context_Window), "output limit"), "the notice does not blame the output limit")

	// The next foreground request carries the notice, and the compaction request carries the
	// summary directive. Both reach the provider; the turn does not wait for the second.
	deadline := time.tick_add(time.tick_now(), AGENT_PROVIDER_BOUND)
	for agent_provider_request_count(&provider) < 3 && time.tick_since(deadline) < 0 { time.sleep(2 * time.Millisecond) }
	if !testing.expect_value(test, agent_provider_request_count(&provider), 3) { return }
	summarizing := 0
	noticed := 0
	for index in 1 ..< 3 {
		request := agent_provider_request(&provider, index)
		if strings.contains(request, "Summarize the conversation above") { summarizing += 1 }
		if strings.contains(request, "context window filled") { noticed += 1 }
	}
	testing.expect_value(test, summarizing, 1)
	testing.expect_value(test, noticed, 1)
}

// A response that stopped at the output limit is unchanged: the notice blames the output
// limit, and the context is left alone because it was not the cause.
@(test)
test_an_output_limit_stop_does_not_compact :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.model_api = .Anthropic_Messages
	chat_test_capacity(chat, 500_000)
	_test_accept(test, chat, "first")
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}

	responses := []string{context_window_test_reply("half of a long ans", "max_tokens"), context_window_test_reply("done", "end_turn")}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .Anthropic_Messages,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	testing.expect(test, chat_run_turn(chat, connection, test_retry_policy(), {}), "the turn completes")
	testing.expect_value(test, agent_provider_request_count(&provider), 2)
	purposes := context_window_test_purposes(test, chat)
	if testing.expect_value(test, len(purposes), 2) {
		testing.expect_value(test, purposes[0], journal.REQUEST_PURPOSE_NAMES[.Response])
		testing.expect_value(test, purposes[1], journal.REQUEST_PURPOSE_NAMES[.Response])
	}
	finishes := context_window_test_finishes(test, chat)
	if testing.expect_value(test, len(finishes), 14) {
		testing.expect_value(test, finishes[12], journal.RESPONSE_FINISH_NAMES[.Length])
		testing.expect_value(test, finishes[13], journal.RESPONSE_FINISH_NAMES[.Stop])
	}
	testing.expect_value(test, context_window_test_notice(test, chat), chat_notice_text(.Truncated))
	testing.expect_value(test, chat.compact.state, Compact_State.Idle)
	testing.expect_value(test, chat.compact.pending, Compact_Trigger.None)
}
