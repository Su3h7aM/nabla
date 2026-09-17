#+test
package agent

import "core:encoding/json"
import "core:strings"
import "core:testing"

import "nabla:agent/session"
import "nabla:ai"

// A provider that refuses once and then answers is sent the same bytes again, and the
// conversation gains exactly one answer: the abandoned attempt contributed nothing.
@(test)
test_a_refused_attempt_is_retried_on_the_same_bytes :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(t, chat, "say something")

	refusal := `{"error":{"message":"Rate limit reached"}}`
	// The refusal carries the provider's own evidence: the request id it answered with
	// and the delay it asked for.
	refusal_headers := "x-request-id: req_fixture\r\nretry-after: 2\r\n"
	responses := []string{agent_provider_refusal("429 Too Many Requests", refusal, refusal_headers), agent_provider_reply("second try")}
	provider: Agent_Provider
	if !agent_provider_start(t, &provider, responses) { return }
	defer agent_provider_stop(&provider)

	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	testing.expect(t, chat_run_turn(chat, connection, {}), "the turn completed after a retry")
	if !testing.expect_value(t, len(provider.requests), 2) { return }
	// A retry sends the same request: the bytes of the second attempt are the bytes of
	// the first, because the harness froze them before either one went out.
	testing.expectf(t, provider.requests[0] == provider.requests[1], "the retry must send the same bytes")

	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	answers := 0
	answered: session.Request_No
	has_answered := false
	for entry in ctx.entries {
		#partial switch payload in entry.payload {
		case session.Assistant_Entry:
			if payload.text == "second try" {
				answers += 1
				answered, has_answered = entry.request_no.?
			}
		}
	}
	testing.expect_value(t, answers, 1)
	if !testing.expect(t, has_answered, "the answer names the send that produced it") { return }

	// The chain is in the store rather than in the reader's head: the send that
	// answered names the send that failed, and each of them says what it was.
	second, second_err := session.request_load(chat.store, chat.id, answered, chat.allocator)
	if !testing.expect_value(t, second_err, nil) { return }
	defer session.request_destroy(&second, chat.allocator)
	testing.expect_value(t, second.outcome, session.Outcome.Completed)
	attempt, recovery, previous := attempt_record(t, second.input_json)
	testing.expect_value(t, attempt, i64(2))
	testing.expect_value(t, recovery, "transient_retry")
	first_number, has_previous := previous.?
	if !testing.expect(t, has_previous, "the second send names the first") { return }

	first, first_err := session.request_load(chat.store, chat.id, session.Request_No(first_number), chat.allocator)
	if !testing.expect_value(t, first_err, nil) { return }
	defer session.request_destroy(&first, chat.allocator)
	// The abandoned send keeps its own numbers, and it says how it ended rather than
	// being left running.
	testing.expect_value(t, first.outcome, session.Outcome.Failed)
	testing.expect(t, first.finished_at_ms != nil, "the abandoned send was finished")
	testing.expect(t, first.error_json != "", "the abandoned send says why it failed")
	first_attempt, first_recovery, first_previous := attempt_record(t, first.input_json)
	testing.expect_value(t, first_attempt, i64(1))
	testing.expect_value(t, first_recovery, "initial")
	testing.expect(t, first_previous == nil, "the first send of a chain names no predecessor")

	// The record of that failure is the evidence the layers observed, not the prose a
	// front-end would show: a reader can tell a rate limit from a bad request without
	// parsing the message, and the provider's request id and delay survive with it.
	evidence := error_record(t, first.error_json)
	testing.expect_value(t, evidence.format_version, i64(CHAT_REQUEST_ERROR_VERSION))
	testing.expect_value(t, evidence.kind, "http")
	testing.expect_value(t, evidence.failure_class, "rate_limited")
	testing.expect_value(t, evidence.status, i64(429))
	testing.expect_value(t, evidence.provider_request_id, "req_fixture")
	testing.expect_value(t, evidence.retry_after_ms, i64(2000))
	testing.expect_value(t, evidence.message, "Rate limit reached")
	// Nothing of the refused attempt reached the conversation, so nothing of it was
	// exposed.
	testing.expect(t, !evidence.text_exposed, "the refused attempt produced no visible text")
	testing.expect(t, !evidence.completion_accepted, "the refused attempt completed nothing")
}

// Error_Record is the failure evidence one row's error column carries, as a reader
// outside the harness would take it.
Error_Record :: struct {
	format_version:      i64,
	kind:                string,
	failure_class:       string,
	status:              i64,
	provider_code:       string,
	provider_request_id: string,
	retry_after_ms:      i64,
	retry_directive:     string,
	transport_cause:     string,
	text_exposed:        bool,
	completion_accepted: bool,
	message:             string,
}

// error_record reads the fields of a request row's failure evidence.
error_record :: proc(t: ^testing.T, error_json: string) -> (record: Error_Record) {
	if !testing.expect(t, error_json != "", "the row carries failure evidence") { return }
	value, parse_err := json.parse_string(error_json, .JSON, true, context.temp_allocator)
	if parse_err != nil { testing.fail_now(t, "the failure record is not valid JSON") }
	defer json.destroy_value(value, context.temp_allocator)
	object, is_object := value.(json.Object)
	if !testing.expect(t, is_object, "the failure record is an object") { return }
	if number, is_integer := object["format_version"].(json.Integer); is_integer { record.format_version = i64(number) }
	if text, is_string := object["kind"].(json.String); is_string { record.kind = string(text) }
	if text, is_string := object["failure_class"].(json.String); is_string { record.failure_class = string(text) }
	if number, is_integer := object["status"].(json.Integer); is_integer { record.status = i64(number) }
	if text, is_string := object["provider_code"].(json.String); is_string { record.provider_code = string(text) }
	if text, is_string := object["provider_request_id"].(json.String); is_string { record.provider_request_id = string(text) }
	if number, is_integer := object["retry_after_ms"].(json.Integer); is_integer { record.retry_after_ms = i64(number) }
	if text, is_string := object["retry_directive"].(json.String); is_string { record.retry_directive = string(text) }
	if text, is_string := object["transport_cause"].(json.String); is_string { record.transport_cause = string(text) }
	if flag, is_bool := object["text_exposed"].(json.Boolean); is_bool { record.text_exposed = bool(flag) }
	if flag, is_bool := object["completion_accepted"].(json.Boolean); is_bool { record.completion_accepted = bool(flag) }
	if text, is_string := object["message"].(json.String); is_string { record.message = string(text) }
	return
}

// attempt_record reads the chain fields one request row's input record carries.
attempt_record :: proc(t: ^testing.T, input_json: string) -> (attempt: i64, recovery: string, previous: Maybe(i64)) {
	value, parse_err := json.parse_string(input_json, .JSON, true, context.temp_allocator)
	if parse_err != nil { testing.fail_now(t, "the input record is not valid JSON") }
	defer json.destroy_value(value, context.temp_allocator)
	object, is_object := value.(json.Object)
	if !testing.expect(t, is_object, "the input record is an object") { return }
	if number, is_integer := object["attempt_number"].(json.Integer); is_integer { attempt = i64(number) }
	if kind, is_string := object["recovery_kind"].(json.String); is_string { recovery = string(kind) }
	if number, is_integer := object["previous_request_no"].(json.Integer); is_integer { previous = i64(number) }
	return
}

// One request, one send, one answer: the scripted provider replies, the harness
// commits what came back, and the conversation holds the prompt and the answer.
// This is the base case every retry case is a variation of.
@(test)
test_a_scripted_provider_completes_one_request :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(t, chat, "say something")

	responses := []string{agent_provider_reply("scripted reply")}
	provider: Agent_Provider
	if !agent_provider_start(t, &provider, responses) { return }
	defer agent_provider_stop(&provider)

	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	testing.expect(t, chat_run_turn(chat, connection, {}), "the turn completed")
	testing.expect_value(t, len(provider.requests), 1)
	testing.expect(t, !provider.failed, "the scripted provider served its response")
	testing.expect(t, chat.last_error == "", chat.last_error)

	// What left this machine is the request the harness assembled: the model it
	// resolved and the prompt that asked for an answer.
	testing.expect(t, strings.contains(provider.requests[0], chat.model_id), "the request names the model")
	testing.expect(t, strings.contains(provider.requests[0], "say something"), "the request carries the prompt")

	ctx := _test_context(t, chat)
	defer session.context_destroy(&ctx, context.allocator)
	found_prompt := false
	found_reply := false
	request_no: session.Request_No
	has_request := false
	for entry in ctx.entries {
		#partial switch payload in entry.payload {
		case session.User_Entry:
			if payload.text == "say something" { found_prompt = true }
		case session.Assistant_Entry:
			if payload.text == "scripted reply" {
				found_reply = true
				testing.expect(t, !payload.partial, "a completed answer is not partial")
			}
			// The answer names the send that produced it, which is how the entry and
			// the request row are tied together.
			request_no, has_request = entry.request_no.?
		}
	}
	testing.expect(t, found_prompt, "the prompt is in the conversation")
	testing.expect(t, found_reply, "the answer is in the conversation")

	if testing.expect(t, has_request, "the answer names the send that produced it") {
		row, load_err := session.request_load(chat.store, chat.id, request_no, chat.allocator)
		if testing.expect_value(t, load_err, nil) {
			defer session.request_destroy(&row, chat.allocator)
			testing.expect_value(t, row.purpose, session.Request_Purpose.Response)
			testing.expect_value(t, row.outcome, session.Outcome.Completed)
			testing.expect(t, row.finished_at_ms != nil, "a request that ended says when")
		}
	}
}
