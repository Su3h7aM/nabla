#+test
package agent

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
	responses := []string{agent_provider_refusal("429 Too Many Requests", refusal), agent_provider_reply("second try")}
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
	for entry in ctx.entries {
		#partial switch payload in entry.payload {
		case session.Assistant_Entry:
			if payload.text == "second try" { answers += 1 }
		}
	}
	testing.expect_value(t, answers, 1)
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
