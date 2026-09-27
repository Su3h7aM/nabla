#+test
package agent

import "core:fmt"
import "core:strings"
import "core:testing"

import "nabla:agent/session"
import "nabla:ai"

@(test)
test_agent_messages_follow_steering_boundaries_and_reject_sibling_delivery :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	member := Subagent {
		name  = "agent-1",
		team  = chat.team,
		inbox = steer_queue_init(context.allocator),
	}
	defer steer_queue_destroy(&member.inbox)
	append(&chat.team.members, &member)
	defer clear(&chat.team.members)
	parent_context := Tool_Context {
		allocator = context.allocator,
		agents    = chat.team,
	}
	child_context := Tool_Context {
		allocator = context.allocator,
		member    = &member,
	}
	to_child := tool_agent_send_execute(&parent_context, Agent_Send_Args{agent = "agent-1", message = "Inspect the parser instead."})
	defer tool_result_destroy(&to_child)
	testing.expect_value(t, to_child.outcome, session.Tool_Outcome.Success)
	line, queued := steer_pop(&member.inbox)
	defer steer_line_free(&member.inbox, line)
	testing.expect(t, queued && strings.contains(line, "Inspect the parser instead."))

	to_parent := tool_agent_send_execute(&child_context, Agent_Send_Args{message = "The parser has a race."})
	defer tool_result_destroy(&to_parent)
	testing.expect_value(t, to_parent.outcome, session.Tool_Outcome.Success)
	_test_accept(t, chat, "Investigate.")
	chat.state = .Requesting
	chat_steering_observe(chat, {}, nil)
	testing.expect(t, steer_pending(chat.inbox), "an in-flight request must not consume steering")
	chat.state = .Preparing
	chat_steering_observe(chat, {}, nil)
	testing.expect(t, !steer_pending(chat.inbox), "the next settled boundary consumes steering")
	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	if !testing.expect_value(t, len(entries), 2) { return }
	message, is_message := entries[1].payload.(session.User_Entry)
	testing.expect(t, is_message && message.origin == .Agent && strings.contains(message.text, "The parser has a race."))

	to_sibling := tool_agent_send_execute(&child_context, Agent_Send_Args{agent = "agent-2", message = "Do this."})
	defer tool_result_destroy(&to_sibling)
	testing.expect_value(t, to_sibling.outcome, session.Tool_Outcome.Invalid_Arguments)
	testing.expect(t, !steer_pending(chat.inbox), "a refused sibling message reaches nobody")
}

// agent_provider_call is one response proposing a single tool call.
agent_provider_call :: proc(name, arguments: string, allocator := context.temp_allocator) -> string {
	quoted_name := fmt.aprintf("%q", name, allocator = allocator)
	quoted_arguments := fmt.aprintf("%q", arguments, allocator = allocator)
	return strings.concatenate(
		{
			"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n",
			"data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":",
			quoted_name,
			",\"arguments\":",
			quoted_arguments,
			"}}]},\"finish_reason\":null}]}\n\n",
			"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
			"data: [DONE]\n\n",
		},
		allocator,
	)
}

// Subagent_Test_Catalog serves each fixture endpoint as one provider with one model.
Subagent_Test_Catalog :: struct {
	catalog: Catalog,
}

subagent_test_catalog_add :: proc(fixture: ^Subagent_Test_Catalog, provider_id, model_id, endpoint: string, levels: []string) {
	append(
		&fixture.catalog.providers,
		Catalog_Provider {
			id = provider_id,
			base_url = endpoint,
			base_url_present = true,
			api = "openai_chat_completions",
			api_present = true,
			api_key = "test-key",
			api_key_present = true,
		},
	)
	model := Catalog_Model {
		provider_id = provider_id,
		id = model_id,
		tools = true,
		tools_present = true,
		context_window = CHAT_DEFAULT_CONTEXT_WINDOW,
		context_window_present = true,
		thinking = {levels = levels, levels_present = len(levels) > 0},
	}
	model.capacity = model_capacity(model)
	append(&fixture.catalog.models, model)
}

subagent_test_catalog_destroy :: proc(fixture: ^Subagent_Test_Catalog) {
	delete(fixture.catalog.providers)
	delete(fixture.catalog.models)
}

// A blocking subagent runs the orchestrator's model in a session of its own, defined only by
// the instruction and task it was given, and its answer is the call's result. Its requests
// name the orchestrator as their parent and share its cache key.
@(test)
test_a_blocking_subagent_answers_the_call_that_started_it :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW)
	chat.client_instructions = strings.clone("parent-private-instructions", chat.allocator)

	spawn := agent_provider_call(TOOL_AGENT_SPAWN_NAME, `{"instruction":"Answer with one word.","prompt":"what is six times seven"}`)
	nested := agent_provider_call("builtin_codemode", `{"code":"return tools.agent_spawn({prompt = 'recurse'})"}`)
	provider: Agent_Provider
	if !agent_provider_start(t, &provider, {spawn, nested, agent_provider_reply("forty-two"), agent_provider_reply("done")}) { return }
	defer agent_provider_stop(&provider)
	endpoint := agent_provider_endpoint(&provider)
	defer delete(endpoint)

	catalog: Subagent_Test_Catalog
	defer subagent_test_catalog_destroy(&catalog)
	subagent_test_catalog_add(&catalog, "test-provider", "test-model", endpoint, nil)
	chat.catalog = {
		catalog = &catalog.catalog,
	}

	_test_accept(t, chat, "ask a subagent")
	connection := ai.Provider_Connection {
		API        = .OpenAI_Chat_Completions,
		Endpoint   = endpoint,
		Credential = "test-key",
	}
	testing.expect(t, chat_run_turn_steered(chat, connection, test_retry_policy(), {}, nil), "the turn completed")

	if !testing.expect_value(t, agent_provider_request_count(&provider), 4) { return }
	child := agent_provider_request(&provider, 1)
	testing.expect(t, strings.contains(child, "what is six times seven"), "the subagent's request carries its task")
	testing.expect(t, strings.contains(child, "Answer with one word."), "the subagent's request carries its instruction")
	testing.expect(t, !strings.contains(child, "ask a subagent"), "the subagent does not see the orchestrator's conversation")
	testing.expect(t, !strings.contains(child, "parent-private-instructions"), "the caller must supply the child's instructions explicitly")
	testing.expect(t, !strings.contains(child, `"name":"agent_spawn"`), "children cannot discover delegation tools")
	testing.expect(t, strings.contains(child, fmt.tprintf("x-parent-session-id: %s", chat.id)), "the subagent names its parent")
	testing.expect(t, strings.contains(child, fmt.tprintf(`"prompt_cache_key":"%s"`, chat.id)), "the subagent shares its parent's cache key")
	testing.expect(t, strings.contains(agent_provider_request(&provider, 2), "agent_spawn"), "nested Lua receives feedback without spawning")
	testing.expect(t, strings.contains(agent_provider_request(&provider, 3), "forty-two"), "the orchestrator reads the answer")
	testing.expect(t, !agent_team_running(chat.team), "the finished subagent is released")
}

// A background subagent works while its orchestrator continues. Its answer reaches the
// orchestrator as a message once the orchestrator's turn is over, and starts a turn of its
// own. With effort left out it runs one level below the orchestrator's.
@(test)
test_a_background_subagent_reports_its_answer_as_a_message :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW)
	levels := []string{"low", "medium", "high"}
	for level in levels { append(&chat.effort_levels, chat_clone_string(level, chat.allocator)) }
	testing.expect(t, chat_session_set_effort(chat, "high"))

	spawn := agent_provider_call(TOOL_AGENT_SPAWN_NAME, `{"prompt":"what is six times seven","model":"sub-model","background":true}`)
	orchestrator: Agent_Provider
	if !agent_provider_start(t, &orchestrator, {spawn, agent_provider_reply("waiting"), agent_provider_reply("got it")}) { return }
	defer agent_provider_stop(&orchestrator)
	delegate: Agent_Provider
	if !agent_provider_start(t, &delegate, {agent_provider_reply("forty-two")}, deferred = true) { return }
	defer agent_provider_stop(&delegate)
	orchestrator_endpoint := agent_provider_endpoint(&orchestrator)
	defer delete(orchestrator_endpoint)
	delegate_endpoint := agent_provider_endpoint(&delegate)
	defer delete(delegate_endpoint)

	catalog: Subagent_Test_Catalog
	defer subagent_test_catalog_destroy(&catalog)
	subagent_test_catalog_add(&catalog, "test-provider", "test-model", orchestrator_endpoint, levels)
	subagent_test_catalog_add(&catalog, "sub-provider", "sub-model", delegate_endpoint, levels)
	chat.catalog = {
		catalog = &catalog.catalog,
	}

	_test_accept(t, chat, "start a subagent")
	connection := ai.Provider_Connection {
		API        = .OpenAI_Chat_Completions,
		Endpoint   = orchestrator_endpoint,
		Credential = "test-key",
	}
	testing.expect(t, chat_run_turn_steered(chat, connection, test_retry_policy(), {}, nil), "the first turn completed")
	testing.expect(t, strings.contains(agent_provider_request(&orchestrator, 1), "agent-1"), "the call returned the subagent's id")

	// The subagent has been waiting on its provider the whole time.
	agent_provider_serve_now(&delegate)
	if !testing.expect(t, chat_agents_wait(chat, nil), "the subagent's report arrives") { return }
	accepted, had_message := chat_session_accept_agent_message(chat, {})
	testing.expect(t, had_message && accepted == .Accepted)
	testing.expect(t, chat_run_turn_steered(chat, connection, test_retry_policy(), {}, nil), "the report's turn completed")
	testing.expect(t, !chat_agents_wait(chat, nil), "nothing more is pending")

	testing.expect(t, strings.contains(agent_provider_request(&delegate, 0), `"reasoning_effort":"medium"`), "the subagent runs one level below")
	report := agent_provider_request(&orchestrator, 2)
	testing.expect(t, strings.contains(report, "Subagent agent-1 completed"), "the report names the subagent")
	testing.expect(t, strings.contains(report, "forty-two"), "the report carries the answer")
}

// A subagent may not start subagents of its own, and the refusal tells it what it can do.
@(test)
test_a_subagent_cannot_start_a_subagent :: proc(t: ^testing.T) {
	member: Subagent
	ctx := Tool_Context {
		call_id   = "call_1",
		allocator = context.allocator,
		member    = &member,
	}
	result := tool_agent_spawn_execute(&ctx, Agent_Spawn_Args{prompt = "recurse"})
	defer tool_result_destroy(&result)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Unavailable)
	testing.expect(t, strings.contains(result.content, "agent_send"), "the refusal names what a subagent can do")
}

@(test)
test_stopping_a_background_subagent_reports_to_its_parent :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	provider: Agent_Provider
	// The provider accepts connections but never answers, so only the stop can end the child.
	if !agent_provider_start(t, &provider, {}) { return }
	defer agent_provider_stop(&provider)
	endpoint := agent_provider_endpoint(&provider)
	defer delete(endpoint)
	catalog: Subagent_Test_Catalog
	defer subagent_test_catalog_destroy(&catalog)
	subagent_test_catalog_add(&catalog, "test-provider", "test-model", endpoint, nil)
	chat.catalog = {
		catalog = &catalog.catalog,
	}
	delete(chat.provider_id, chat.allocator)
	chat.provider_id = strings.clone("test-provider", chat.allocator)
	delete(chat.model_id, chat.allocator)
	chat.model_id = strings.clone("test-model", chat.allocator)
	agent_team_note_parent(chat)
	ctx := Tool_Context {
		allocator = context.allocator,
		agents    = chat.team,
	}
	started := tool_agent_spawn_execute(&ctx, Agent_Spawn_Args{prompt = "wait for instructions", background = true})
	defer tool_result_destroy(&started)
	if !testing.expect_value(t, started.outcome, session.Tool_Outcome.Success) { return }
	stopped := tool_agent_stop_execute(&ctx, Agent_Stop_Args{agent = "agent-1"})
	defer tool_result_destroy(&stopped)
	testing.expect_value(t, stopped.outcome, session.Tool_Outcome.Success)
	if !testing.expect(t, chat_agents_wait(chat, nil)) { return }
	message, queued := steer_pop(chat.inbox)
	defer steer_line_free(chat.inbox, message)
	testing.expect(t, queued && strings.contains(message, "agent-1 was stopped"))
	testing.expect(t, !chat_agents_wait(chat, nil), "cancellation leaves no running child")
}

// Effort left out steps one level down, and the lowest level stays where it is.
@(test)
test_effort_steps_down_one_level :: proc(t: ^testing.T) {
	levels := []string{"minimal", "low", "medium", "high"}
	testing.expect_value(t, effort_step_down(levels, "high"), "medium")
	testing.expect_value(t, effort_step_down(levels, "low"), "minimal")
	testing.expect_value(t, effort_step_down(levels, "minimal"), "minimal")
	testing.expect_value(t, effort_step_down(levels, ""), "")
}
