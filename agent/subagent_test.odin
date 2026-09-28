#+test
package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/journal"
import "nabla:ai"

@(test)
test_agent_messages_follow_steering_boundaries_and_reject_sibling_delivery :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	member := Subagent {
		name    = "agent-1",
		session = journal.session_id_create(),
		team    = chat.team,
		inbox   = steer_queue_init(context.allocator),
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
	testing.expect_value(test, to_child.outcome, journal.Tool_Outcome.Success)
	testing.expect_value(test, parent_context.subagent, member.session)
	line, queued := steer_pop(&member.inbox)
	defer steer_line_free(&member.inbox, line)
	testing.expect(test, queued && strings.contains(line, "Inspect the parser instead."))

	to_parent := tool_agent_send_execute(&child_context, Agent_Send_Args{message = "The parser has a race."})
	defer tool_result_destroy(&to_parent)
	testing.expect_value(test, to_parent.outcome, journal.Tool_Outcome.Success)
	testing.expect_value(test, child_context.subagent, member.session)
	_test_accept(test, chat, "Investigate.")
	chat.state = .Requesting
	chat_steering_observe(chat, {}, nil)
	testing.expect(test, steer_pending(chat.inbox), "an in-flight request must not consume steering")
	chat.state = .Preparing
	chat_steering_observe(chat, {}, nil)
	testing.expect(test, !steer_pending(chat.inbox), "the next settled boundary consumes steering")
	// The prompt and the agent's message are the session's user nodes, and the message is
	// the one the settled boundary recorded for the agent.
	nodes, read_error := journal.read_ancestry(chat.store, chat.session, chat.head, context.temp_allocator)
	if read_error != nil { testing.fail_now(test, "the session's nodes could not be read") }
	user_nodes := 0
	agent_message := ""
	for node in nodes {
		if node.kind != .User { continue }
		user_nodes += 1
		user: journal.User
		if decode_error := journal.payload_decode(node.data, &user, context.temp_allocator); decode_error != nil {
			testing.fail_now(test, "a user node could not be read")
		}
		if user.origin == journal.USER_ORIGIN_NAMES[.Agent] { agent_message = string(node.body) }
	}
	if !testing.expect_value(test, user_nodes, 2) { return }
	testing.expect(test, strings.contains(agent_message, "The parser has a race."), "the agent's message is recorded as a user node")

	to_sibling := tool_agent_send_execute(&child_context, Agent_Send_Args{agent = "agent-2", message = "Do this."})
	defer tool_result_destroy(&to_sibling)
	testing.expect_value(test, to_sibling.outcome, journal.Tool_Outcome.Invalid_Arguments)
	testing.expect(test, !steer_pending(chat.inbox), "a refused sibling message reaches nobody")
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
test_a_blocking_subagent_answers_the_call_that_started_it :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW)
	chat.client_instructions = strings.clone("parent-private-instructions", chat.allocator)

	spawn := agent_provider_call(TOOL_AGENT_SPAWN_NAME, `{"instruction":"Answer with one word.","prompt":"what is six times seven"}`)
	nested := agent_provider_call("builtin_codemode", `{"code":"return tools.agent_spawn({prompt = 'recurse'})"}`)
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, {spawn, nested, agent_provider_reply("forty-two"), agent_provider_reply("done")}) { return }
	defer agent_provider_stop(&provider)
	endpoint := agent_provider_endpoint(&provider)
	defer delete(endpoint)

	catalog: Subagent_Test_Catalog
	defer subagent_test_catalog_destroy(&catalog)
	subagent_test_catalog_add(&catalog, "test-provider", "test-model", endpoint, nil)
	chat.catalog = {
		catalog = &catalog.catalog,
	}

	_test_accept(test, chat, "ask a subagent")
	connection := ai.Provider_Connection {
		API        = .OpenAI_Chat_Completions,
		Endpoint   = endpoint,
		Credential = "test-key",
	}
	testing.expect(test, chat_run_turn_steered(chat, connection, test_retry_policy(), {}, nil), "the turn completed")

	if !testing.expect_value(test, agent_provider_request_count(&provider), 4) { return }
	child := agent_provider_request(&provider, 1)
	testing.expect(test, strings.contains(child, "what is six times seven"), "the subagent's request carries its task")
	testing.expect(test, strings.contains(child, "Answer with one word."), "the subagent's request carries its instruction")
	testing.expect(test, !strings.contains(child, "ask a subagent"), "the subagent does not see the orchestrator's conversation")
	testing.expect(test, !strings.contains(child, "parent-private-instructions"), "the caller must supply the child's instructions explicitly")
	testing.expect(test, !strings.contains(child, `"name":"agent_spawn"`), "children cannot discover delegation tools")
	session_text := chat_session_text(chat)
	testing.expect(test, strings.contains(child, fmt.tprintf("x-parent-session-id: %s", session_text)), "the subagent names its parent")
	testing.expect(test, strings.contains(child, fmt.tprintf(`"prompt_cache_key":"%s"`, session_text)), "the subagent shares its parent's cache key")
	testing.expect(test, strings.contains(agent_provider_request(&provider, 2), "agent_spawn"), "nested Lua receives feedback without spawning")
	testing.expect(test, strings.contains(agent_provider_request(&provider, 3), "forty-two"), "the orchestrator reads the answer")
	testing.expect(test, !agent_team_running(chat.team), "the finished subagent is released")

	// The delegation is in the orchestrator's journal: every start is closed by a
	// completion naming the same child, and the child's session is the one it named.
	records, _, read_error := journal.read_records(
		chat.store,
		journal.Filter{session = chat.session, kinds = {.Subagent_Started, .Subagent_Completed}},
		0,
		0,
		context.temp_allocator,
	)
	if read_error != nil { testing.fail_now(test, "the delegation records could not be read") }
	answered: journal.Session_Id
	for record in records {
		if record.kind != .Subagent_Started { continue }
		completions := 0
		for other in records {
			if other.kind != .Subagent_Completed || other.subagent != record.subagent { continue }
			completions += 1
			testing.expect_value(test, other.call, record.call)
			completion: journal.Subagent_Completed
			if journal.payload_decode(other.data, &completion, context.temp_allocator) != nil { testing.fail_now(test, "a completion could not be read") }
			if completion.outcome == journal.TOOL_OUTCOME_NAMES[.Success] {
				testing.expect_value(test, string(other.body), "forty-two")
				answered = record.subagent
			}
		}
		testing.expect_value(test, completions, 1)
	}
	children, children_error := journal.list_sessions(chat.store, {parent = chat.session}, context.temp_allocator)
	if children_error != nil { testing.fail_now(test, "the child sessions could not be listed") }
	if !testing.expect_value(test, len(children), 1) { return }
	testing.expect(test, answered != {} && children[0].id == answered, "the child's session is the one its start named")
}

// A background subagent works while its orchestrator continues. Its answer reaches the
// orchestrator as a message once the orchestrator's turn is over, and starts a turn of its
// own. With effort left out it runs one level below the orchestrator's.
@(test)
test_a_background_subagent_reports_its_answer_as_a_message :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW)
	levels := []string{"low", "medium", "high"}
	for level in levels { append(&chat.effort_levels, chat_clone_string(level, chat.allocator)) }
	testing.expect(test, chat_session_set_effort(chat, "high"))

	spawn := agent_provider_call(TOOL_AGENT_SPAWN_NAME, `{"prompt":"what is six times seven","model":"sub-model","background":true}`)
	orchestrator: Agent_Provider
	if !agent_provider_start(test, &orchestrator, {spawn, agent_provider_reply("waiting"), agent_provider_reply("got it")}) { return }
	defer agent_provider_stop(&orchestrator)
	delegate: Agent_Provider
	if !agent_provider_start(test, &delegate, {agent_provider_reply("forty-two")}, deferred = true) { return }
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

	_test_accept(test, chat, "start a subagent")
	connection := ai.Provider_Connection {
		API        = .OpenAI_Chat_Completions,
		Endpoint   = orchestrator_endpoint,
		Credential = "test-key",
	}
	testing.expect(test, chat_run_turn_steered(chat, connection, test_retry_policy(), {}, nil), "the first turn completed")
	testing.expect(test, strings.contains(agent_provider_request(&orchestrator, 1), "agent-1"), "the call returned the subagent's id")

	// The subagent has been waiting on its provider the whole time.
	agent_provider_serve_now(&delegate)
	if !testing.expect(test, chat_agents_wait(chat, nil), "the subagent's report arrives") { return }
	accepted, had_message := chat_session_accept_agent_message(chat, {})
	testing.expect(test, had_message && accepted == .Accepted)
	testing.expect(test, chat_run_turn_steered(chat, connection, test_retry_policy(), {}, nil), "the report's turn completed")
	testing.expect(test, !chat_agents_wait(chat, nil), "nothing more is pending")

	testing.expect(test, strings.contains(agent_provider_request(&delegate, 0), `"reasoning_effort":"medium"`), "the subagent runs one level below")
	report := agent_provider_request(&orchestrator, 2)
	testing.expect(test, strings.contains(report, "Subagent agent-1 completed"), "the report names the subagent")
	testing.expect(test, strings.contains(report, "forty-two"), "the report carries the answer")
}

// A subagent may not start subagents of its own, and the refusal tells it what it can do.
@(test)
test_a_subagent_cannot_start_a_subagent :: proc(test: ^testing.T) {
	member: Subagent
	tool_context := Tool_Context {
		call_id   = "call_1",
		allocator = context.allocator,
		member    = &member,
	}
	result := tool_agent_spawn_execute(&tool_context, Agent_Spawn_Args{prompt = "recurse"})
	defer tool_result_destroy(&result)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Unavailable)
	testing.expect(test, strings.contains(result.content, "agent_send"), "the refusal names what a subagent can do")
}

@(test)
test_stopping_a_background_subagent_reports_to_its_parent :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	provider: Agent_Provider
	// The provider accepts connections but never answers, so only the stop can end the child.
	if !agent_provider_start(test, &provider, {}) { return }
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
	tool_context := Tool_Context {
		allocator = context.allocator,
		agents    = chat.team,
	}
	started := tool_agent_spawn_execute(&tool_context, Agent_Spawn_Args{prompt = "wait for instructions", background = true})
	defer tool_result_destroy(&started)
	if !testing.expect_value(test, started.outcome, journal.Tool_Outcome.Success) { return }
	stopped := tool_agent_stop_execute(&tool_context, Agent_Stop_Args{agent = "agent-1"})
	defer tool_result_destroy(&stopped)
	testing.expect_value(test, stopped.outcome, journal.Tool_Outcome.Success)
	if !testing.expect(test, chat_agents_wait(chat, nil)) { return }
	message, queued := steer_pop(chat.inbox)
	defer steer_line_free(chat.inbox, message)
	testing.expect(test, queued && strings.contains(message, "agent-1 was stopped"))
	testing.expect(test, !chat_agents_wait(chat, nil), "cancellation leaves no running child")
}

// SUBAGENT_TEST_ACP_AGENT is an ACP version 2 agent. It answers each request by its method,
// narrates before a tool call, asks permission for the call, and fails when its prompt lacks
// the instruction or the task, flooding standard error before it does.
// SUBAGENT_TEST_ACP_NOISE_BYTES is replaced with that flood's size.
SUBAGENT_TEST_ACP_AGENT :: `#!/bin/sh
update() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":%s}}\n' "$1"; }
while IFS= read -r line; do
	id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
	case "$line" in
	*'"method":"initialize"'*)
		printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":2,"info":{"name":"fake","version":"1"}}}\n' "$id" ;;
	*'"method":"session/new"'*)
		printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"s1"}}\n' "$id" ;;
	*'"method":"session/prompt"'*)
		case "$line" in *'Answer in one word.'*'six times seven'*) ;; *) printf 'the beginning\n' 1>&2; head -c SUBAGENT_TEST_ACP_NOISE_BYTES /dev/zero | tr '\000' x 1>&2; echo "prompt lost its instruction or task" >&2; exit 1 ;; esac
		printf '{"jsonrpc":"2.0","id":%s,"result":{"messageId":"u1"}}\n' "$id"
		update '{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"Let me compute."}}'
		update '{"sessionUpdate":"tool_call_update","toolCallId":"c1","title":"multiply","status":"pending"}'
		printf '{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{"sessionId":"s1","title":"Run multiply?","options":[{"optionId":"no","name":"Reject","kind":"reject_once"},{"optionId":"yes","name":"Allow","kind":"allow_once"}]}}\n'
		IFS= read -r grant
		case "$grant" in *'"optionId":"yes"'*) ;; *) echo "permission was not granted: $grant" >&2; exit 1 ;; esac
		update '{"sessionUpdate":"agent_message_chunk","messageId":"m2","content":{"type":"text","text":"forty-"}}'
		update '{"sessionUpdate":"agent_message_chunk","messageId":"m2","content":{"type":"text","text":"two"}}'
		update '{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}' ;;
	esac
done
`

// subagent_test_acp_agent is SUBAGENT_TEST_ACP_AGENT whose standard-error flood is twice
// what the connection retains, so a report can only hold the end of it.
subagent_test_acp_agent :: proc() -> string {
	text, _ := strings.replace(
		SUBAGENT_TEST_ACP_AGENT,
		"SUBAGENT_TEST_ACP_NOISE_BYTES",
		fmt.tprintf("%d", SUBAGENT_ACP_STDERR_TAIL_BYTES * 2),
		1,
		context.temp_allocator,
	)
	return text
}

// A subagent can be any configured program that speaks ACP. Its answer is its last message, and a failure
// quotes the end of what the program wrote to stderr, and only that.
@(test)
test_an_acp_program_answers_as_a_subagent :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	directory, directory_error := os.make_directory_temp("", "nabla-acp-agent-*", context.allocator)
	if directory_error != nil { testing.fail_now(test, "could not create a temporary directory") }
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	script := strings.concatenate({directory, "/agent"}, context.temp_allocator)
	if os.write_entire_file(script, transmute([]u8)subagent_test_acp_agent()) != nil { testing.fail_now(test, "could not write the agent") }
	if os.chmod(script, {.Read_User, .Write_User, .Execute_User}) != nil { testing.fail_now(test, "could not make the agent executable") }
	agents := []ACP_Agent_Config{{name = "fake", command = script}}
	fixture.chat.acp_agents = agents
	agent_team_note_parent(&fixture.chat)
	tool_context := Tool_Context {
		allocator = context.allocator,
		agents    = fixture.chat.team,
	}

	answered := tool_agent_spawn_execute(&tool_context, Agent_Spawn_Args{instruction = "Answer in one word.", prompt = "six times seven", acp_agent = "fake"})
	defer tool_result_destroy(&answered)
	testing.expect_value(test, answered.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(answered.content, "forty-two") && !strings.contains(answered.content, "Let me compute"), answered.content)

	failed := tool_agent_spawn_execute(&tool_context, Agent_Spawn_Args{prompt = "something else", acp_agent = "fake"})
	defer tool_result_destroy(&failed)
	testing.expect_value(test, failed.outcome, journal.Tool_Outcome.Tool_Failed)
	testing.expect(test, strings.contains(failed.content, "prompt lost its instruction or task"), failed.content)
	testing.expect(test, !strings.contains(failed.content, "the beginning"), failed.content)
}

// Effort left out steps one level down, and the lowest level stays where it is. Across models
// it takes the next lower level both state, and nothing when they share none.
@(test)
test_effort_steps_down_one_level :: proc(test: ^testing.T) {
	levels := []string{"minimal", "low", "medium", "high"}
	testing.expect_value(test, effort_step_down(levels, levels, "high"), "medium")
	testing.expect_value(test, effort_step_down(levels, levels, "minimal"), "minimal")
	testing.expect_value(test, effort_step_down(levels, levels, ""), "")
	testing.expect_value(test, effort_step_down({"medium", "high", "max"}, {"low", "medium", "high"}, "max"), "high")
	testing.expect_value(test, effort_step_down({"low"}, {"medium", "high"}, "low"), "")
}
