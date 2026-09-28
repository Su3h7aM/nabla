#+test
package agent

import "core:mem"
import "core:strings"
import "core:testing"

import "nabla:agent/journal"
import "nabla:ai"

Retry_Log :: struct {
	events:    [dynamic]Chat_Retry_Event,
	allocator: mem.Allocator,
}

retry_log_observer :: proc(log: ^Retry_Log) -> Chat_Observer {
	return {user_data = log, retry_scheduled = retry_log_append}
}

retry_log_append :: proc(user_data: rawptr, event: Chat_Retry_Event) {
	log := cast(^Retry_Log)user_data
	append(&log.events, event)
}

@(private)
request_chain_assert :: proc(test: ^testing.T, chat: ^Chat_Session, expected_attempts: int, expected_answer: string) -> []journal.Record {
	sent := _test_records(test, chat, {.Request_Sent})
	if !testing.expect_value(test, len(sent), expected_attempts) { return sent }
	request := sent[0].request
	for record, index in sent {
		testing.expect_value(test, record.request, request)
		testing.expect_value(test, record.attempt, journal.Attempt_No(index + 1))
		payload: journal.Request_Sent
		if testing.expect_value(test, journal.payload_decode(record.data, &payload, context.temp_allocator), nil) {
			testing.expect_value(test, payload.purpose, journal.REQUEST_PURPOSE_NAMES[.Response])
			testing.expect_value(test, payload.model_requested, chat.model_id)
			testing.expect_value(test, payload.recovery, "initial" if index == 0 else "transient_retry")
			testing.expect_value(test, len(payload.body_digest), journal.DIGEST_HEX_LENGTH)
			testing.expect(test, payload.body_bytes > 0, "the frozen body was not recorded with its size")
		}
	}
	responses := _test_records(test, chat, {.Response_Committed})
	if testing.expect_value(test, len(responses), 1) {
		testing.expect_value(test, responses[0].request, request)
		testing.expect_value(test, responses[0].attempt, journal.Attempt_No(expected_attempts))
	}
	ancestry, ancestry_error := journal.read_ancestry(chat.store, chat.session, chat.head, context.temp_allocator)
	if testing.expect_value(test, ancestry_error, nil) {
		answers := 0
		for node in ancestry {
			if node.kind == .Assistant && string(node.body) == expected_answer {
				answers += 1
				payload: journal.Assistant
				if testing.expect_value(test, journal.payload_decode(node.data, &payload, context.temp_allocator), nil) {
					testing.expect_value(test, payload.request, request)
					testing.expect(test, !payload.partial)
				}
			}
		}
		testing.expect_value(test, answers, 1)
	}
	return sent
}

@(test)
test_a_refused_attempt_is_retried_on_the_same_bytes :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(test, chat, "say something")
	refusal := `{"error":{"message":"Rate limit reached"}}`
	responses := []string {
		agent_provider_refusal("429 Too Many Requests", refusal, "x-request-id: req_fixture\r\nretry-after: 0\r\n"),
		agent_provider_reply("second try"),
	}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)
	testing.expect(test, chat_run_turn(chat, connection, test_retry_policy(), {}), "the turn completed after a retry")
	if !testing.expect_value(test, agent_provider_request_count(&provider), 2) { return }
	testing.expect(test, agent_provider_request(&provider, 0) == agent_provider_request(&provider, 1), "the retry repeats the frozen request")
	sent := request_chain_assert(test, chat, 2, "second try")
	if len(sent) != 2 { return }
	rejected := _test_records(test, chat, {.Response_Rejected})
	if !testing.expect_value(test, len(rejected), 1) { return }
	testing.expect_value(test, rejected[0].request, sent[0].request)
	testing.expect_value(test, rejected[0].attempt, journal.Attempt_No(1))
	evidence: journal.Response_Rejected
	if !testing.expect_value(test, journal.payload_decode(rejected[0].data, &evidence, context.temp_allocator), nil) { return }
	testing.expect_value(test, evidence.kind, "http")
	testing.expect_value(test, evidence.failure_class, "rate_limited")
	testing.expect_value(test, evidence.status, 429)
	testing.expect_value(test, evidence.provider_request_id, "req_fixture")
	if delay, present := evidence.retry_after_ms.?; testing.expect(test, present) { testing.expect_value(test, delay, i64(0)) }
	testing.expect_value(test, evidence.recovery, "transient_failure")
	testing.expect(test, evidence.delay_ms > 0)
	testing.expect_value(test, evidence.detail, "Rate limit reached")
	testing.expect(test, !evidence.text_exposed && !evidence.completion_accepted)
}

@(test)
test_a_chain_of_failures_ends_in_one_answer :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(test, chat, "say something")
	refusal := `{"error":{"message":"Rate limit reached"}}`
	responses := []string {
		agent_provider_refusal("429 Too Many Requests", refusal, "retry-after: 0\r\n"),
		agent_provider_truncated(),
		agent_provider_reply("third try"),
	}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)
	retries: Retry_Log
	retries.allocator = context.allocator
	retries.events = make([dynamic]Chat_Retry_Event, 0, 4, retries.allocator)
	defer delete(retries.events)
	testing.expect(test, chat_run_turn(chat, connection, test_retry_policy(), retry_log_observer(&retries)), "the turn completed after two retries")
	if !testing.expect_value(test, agent_provider_request_count(&provider), 3) { return }
	for index in 0 ..< 3 { testing.expect(test, agent_provider_request(&provider, index) == agent_provider_request(&provider, 0)) }
	sent := request_chain_assert(test, chat, 3, "third try")
	if len(sent) != 3 { return }
	rejected := _test_records(test, chat, {.Response_Rejected})
	if !testing.expect_value(test, len(rejected), 2) { return }
	for record, index in rejected {
		testing.expect_value(test, record.request, sent[0].request)
		testing.expect_value(test, record.attempt, journal.Attempt_No(index + 1))
		evidence: journal.Response_Rejected
		if !testing.expect_value(test, journal.payload_decode(record.data, &evidence, context.temp_allocator), nil) { continue }
		testing.expect_value(test, evidence.failure_class, "rate_limited" if index == 0 else "incomplete_stream")
		testing.expect_value(test, evidence.recovery, "transient_failure")
		if index == 0 { testing.expect_value(test, evidence.status, 429) }
		if index == 1 { testing.expect_value(test, evidence.kind, "stream") }
	}
	if !testing.expect_value(test, len(retries.events), 2) { return }
	for event, index in retries.events {
		testing.expect_value(test, event.next_attempt, index + 2)
		testing.expect_value(test, event.request, sent[0].request)
		testing.expect(test, event.delay > 0)
	}
	testing.expect_value(test, retries.events[0].failure_class, ai.Provider_Failure_Class.Rate_Limited)
	testing.expect_value(test, retries.events[1].failure_class, ai.Provider_Failure_Class.Incomplete_Stream)
}

@(test)
test_a_scripted_provider_completes_one_request :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(test, chat, "say something")
	responses := []string{agent_provider_reply("scripted reply")}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)
	testing.expect(test, chat_run_turn(chat, connection, test_retry_policy(), {}), "the turn completed")
	testing.expect_value(test, agent_provider_request_count(&provider), 1)
	testing.expect(test, !agent_provider_failed(&provider), "the scripted provider served its response")
	testing.expect_value(test, chat.last_error, "")
	testing.expect(test, strings.contains(agent_provider_request(&provider, 0), chat.model_id))
	testing.expect(test, strings.contains(agent_provider_request(&provider, 0), "say something"))
	request_chain_assert(test, chat, 1, "scripted reply")
}

@(test)
test_the_turn_record_carries_its_typed_failure :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "say something")
	chat.turn_recovery = .Context_Exhausted
	chat.turn_repair_refusal = .No_Candidate
	chat_session_fail_turn(chat, "the request does not fit the context: no summary")
	_test_settle(test, chat)
	records := _test_records(test, chat, {.Turn_Completed})
	if !testing.expect_value(test, len(records), 1) { return }
	completion: journal.Turn_Completed
	if !testing.expect_value(test, journal.payload_decode(records[0].data, &completion, context.temp_allocator), nil) { return }
	testing.expect_value(test, completion.outcome, "failed")
	testing.expect_value(test, completion.reason, "context_exhausted")
	testing.expect_value(test, completion.cause, "no_candidate")
	testing.expect_value(test, completion.detail, "the request does not fit the context: no summary")
}
