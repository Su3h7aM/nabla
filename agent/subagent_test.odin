#+test
package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

// SUBAGENT_TEST_MAX_RUNNING is the configured cap the queueing tests run under. It differs from
// SUBAGENTS_MAX_RUNNING, so a test that passes proves the configured value is the one used.
SUBAGENT_TEST_MAX_RUNNING :: 2

@(test)
test_agent_status_reads_running_and_finished_children :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, {agent_provider_reply("finished")}, deferred = true) { return }
	defer agent_provider_stop(&provider)
	provider.hold = 1
	agent_provider_serve_now(&provider)
	endpoint := agent_provider_endpoint(&provider)
	defer delete(endpoint)
	catalog: Subagent_Test_Catalog
	defer subagent_test_catalog_destroy(&catalog)
	subagent_test_catalog_add(&catalog, "test-provider", "test-model", endpoint, nil)
	chat.catalog = {catalog = &catalog.catalog}
	delete(chat.provider_id, chat.allocator)
	chat.provider_id = strings.clone("test-provider", chat.allocator)
	delete(chat.model_id, chat.allocator)
	chat.model_id = strings.clone("test-model", chat.allocator)
	agent_team_note_parent(chat)
	_test_accept(test, chat, "start one")
	testing.expect_value(test, subagent_test_call(test, chat, "spawn_1", TOOL_AGENT_SPAWN_NAME, `{"prompt":"answer"}`), journal.TOOL_OUTCOME_NAMES[.Success])
	deadline := time.tick_add(time.tick_now(), AGENT_PROVIDER_BOUND)
	for {
		starts := _test_records(test, chat, {.Subagent_Started})
		if len(starts) != 1 { testing.fail_now(test, "the child start was not recorded") }
		latest, found, read_error := journal.read_latest(chat.store, {session = starts[0].subagent}, context.temp_allocator)
		if read_error != nil { testing.fail_now(test, "the child journal could not be read") }
		if found && latest.kind == .Request_Sent { break }
		if time.tick_diff(time.tick_now(), deadline) <= 0 { testing.fail_now(test, "the child did not send its request") }
		time.sleep(time.Millisecond)
	}
	ctx := Tool_Context{allocator = context.allocator, agents = chat.team, status_store = chat.store, status_session = chat.session}
	running := tool_agent_status_execute(&ctx, Agent_Status_Args{agent = "agent-1"})
	defer tool_result_destroy(&running)
	testing.expect_value(test, running.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(running.content, "status: running") && strings.contains(running.content, "last record: request.sent") && strings.contains(running.content, "age:"), running.content)
	sync.sema_post(&provider.release)
	if !testing.expect(test, chat_agents_wait(chat, nil)) { return }
	finished := tool_agent_status_execute(&ctx, Agent_Status_Args{agent = "agent-1"})
	defer tool_result_destroy(&finished)
	testing.expect_value(test, finished.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(finished.content, "status: completed") && strings.contains(finished.content, `resume: agent_send({"agent":"agent-1","message":"Continue your task."})`), finished.content)
}

// subagent_test_call runs one call of the orchestrator through the job table, as a model's
// proposal would be, so its admission, delegation records, and result are the real ones.
// It returns the call's outcome.
subagent_test_call :: proc(test: ^testing.T, chat: ^Chat_Session, id, name, arguments: string) -> string {
	_test_stage_call(test, chat, id, arguments, name)
	testing.expect_value(test, chat_run_tools(chat, {}), 1)
	chat_pending_calls_clear(chat)
	completed, _, read_error := journal.read_records(chat.store, {session = chat.session, kinds = {.Tool_Completed}}, 0, 0, context.temp_allocator)
	if read_error != nil || len(completed) == 0 { testing.fail_now(test, "the call's result could not be read") }
	payload: journal.Tool_Completed
	if journal.payload_decode(completed[len(completed) - 1].data, &payload, context.temp_allocator) !=
	   nil { testing.fail_now(test, "a result could not be read") }
	return payload.outcome
}

// A message is a journal record committed before its recipient hears of it, and its
// recipient reads it from there: an orchestrator's message to a child is found in the
// child's inbox, and a child's message to its orchestrator is delivered as a User node at the
// next settled boundary and not before.
@(test)
test_agent_messages_are_recorded_first_and_delivered_at_steering_boundaries :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	member := Subagent {
		name    = "agent-1",
		session = journal.session_id_create(),
		team    = chat.team,
	}
	append(&chat.team.members, &member)
	defer clear(&chat.team.members)
	_test_accept(test, chat, "Investigate.")

	success := journal.TOOL_OUTCOME_NAMES[.Success]
	testing.expect_value(
		test,
		subagent_test_call(test, chat, "send_1", TOOL_AGENT_SEND_NAME, `{"agent":"agent-1","message":"Inspect the parser instead."}`),
		success,
	)
	sent := _test_records(test, chat, {.Subagent_Message})
	if !testing.expect_value(test, len(sent), 1) { return }
	testing.expect_value(test, sent[0].subagent, member.session)
	inbox, inbox_error := journal.read_inbox(chat.store, member.session, 0, context.temp_allocator)
	testing.expect_value(test, inbox_error, nil)
	if !testing.expect_value(test, len(inbox), 1) { return }
	text, origin := inbox_text(inbox[0])
	testing.expect(test, strings.contains(text, "Message from the orchestrator") && strings.contains(text, "Inspect the parser instead."), text)
	testing.expect_value(test, origin, journal.User_Origin.Agent)

	// A subagent can message only its orchestrator.
	child_context := Tool_Context {
		allocator = context.allocator,
		member    = &member,
	}
	to_sibling := tool_agent_send_execute(&child_context, Agent_Send_Args{agent = "agent-2", message = "Do this."})
	defer tool_result_destroy(&to_sibling)
	testing.expect_value(test, to_sibling.outcome, journal.Tool_Outcome.Invalid_Arguments)

	// The child's own journal carries its message to the orchestrator.
	chat_record(chat, {kind = .Subagent_Started, subagent = member.session}, journal.Subagent_Started{background = true})
	_test_commit(test, chat)
	child_store: journal.Journal
	if open_error := journal.open(&child_store, fixture.directory, fixture.directory, journal.run_id_create(), .Read_Write); open_error != nil {
		testing.fail_now(test, "the child's journal could not be opened")
	}
	defer _ = journal.close(&child_store)
	_, create_error := journal.create_session(
		&child_store,
		{id = member.session, workspace = tool_loop_workspace(test), role = .Subagent, parent_session = chat.session},
	)
	if create_error != nil { testing.fail_now(test, "the child's session could not be created") }
	journal.append_record(
		&child_store,
		{kind = .Subagent_Message, session = member.session, subagent = member.session},
		journal.Subagent_Message{name = member.name},
		transmute([]u8)string("The parser has a race."),
	)
	if _, commit_error := journal.commit(&child_store); commit_error != nil { testing.fail_now(test, "the child's message could not be committed") }
	// The child's message is not the orchestrator's own message to read back.
	own, _ := journal.read_inbox(chat.store, member.session, 0, context.temp_allocator)
	testing.expect_value(test, len(own), 1)

	chat.state = .Requesting
	chat_steering_observe(chat, {}, nil)
	delivered, _ := journal.last_delivered_message(chat.store, chat.session)
	testing.expect_value(test, delivered, journal.Journal_Seq(0))
	chat.state = .Preparing
	chat_steering_observe(chat, {}, nil)
	nodes, read_error := journal.read_ancestry(chat.store, chat.session, chat.head, context.temp_allocator)
	if read_error != nil { testing.fail_now(test, "the session's nodes could not be read") }
	agent_message := ""
	for node in nodes {
		if node.kind != .User { continue }
		user: journal.User
		if decode_error := journal.payload_decode(node.data, &user, context.temp_allocator); decode_error != nil {
			testing.fail_now(test, "a user node could not be read")
		}
		if user.origin == journal.USER_ORIGIN_NAMES[.Agent] { agent_message = string(node.body) }
	}
	testing.expect(test, strings.contains(agent_message, "The parser has a race.") && strings.contains(agent_message, "agent-1"), agent_message)
	chat_steering_observe(chat, {}, nil)
	again, _ := journal.read_inbox(chat.store, chat.session, chat.delivered, context.temp_allocator)
	testing.expect_value(test, len(again), 0)
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

	spawn := agent_provider_call(TOOL_AGENT_SPAWN_NAME, `{"instruction":"Answer with one word.","prompt":"what is six times seven","wait":true}`)
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
		started: journal.Subagent_Started
		if journal.payload_decode(record.data, &started, context.temp_allocator) != nil { testing.fail_now(test, "a start could not be read") }
		testing.expect_value(test, started.name, fmt.tprintf("agent-%d", record.call))
		testing.expect_value(test, string(record.body), "Answer with one word.")
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

// A subagent runs in the background by default and works while its orchestrator continues. Its answer reaches the
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
	for level in levels { append(&chat.effort_levels, chat_clone_string(level, chat.allocator) or_else "") }
	testing.expect(test, chat_session_set_effort(chat, "high"))

	spawn := agent_provider_call(TOOL_AGENT_SPAWN_NAME, `{"prompt":"what is six times seven","model":"sub-model"}`)
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

// A script that starts a background subagent and returns without waiting on it still starts
// it: the script's end does not stop a call whose work is meant to outlive it.
@(test)
test_a_script_starts_a_background_subagent_without_waiting :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW)

	script := agent_provider_call("builtin_codemode", `{"code":"job.start('agent_spawn', {prompt = 'what is six times seven', model = 'sub-model'})"}`)
	orchestrator: Agent_Provider
	if !agent_provider_start(test, &orchestrator, {script, agent_provider_reply("waiting"), agent_provider_reply("got it")}) { return }
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
	subagent_test_catalog_add(&catalog, "test-provider", "test-model", orchestrator_endpoint, nil)
	subagent_test_catalog_add(&catalog, "sub-provider", "sub-model", delegate_endpoint, nil)
	chat.catalog = {
		catalog = &catalog.catalog,
	}

	_test_accept(test, chat, "start a subagent from a script")
	connection := ai.Provider_Connection {
		API        = .OpenAI_Chat_Completions,
		Endpoint   = orchestrator_endpoint,
		Credential = "test-key",
	}
	testing.expect(test, chat_run_turn_steered(chat, connection, test_retry_policy(), {}, nil), "the turn completed before the subagent answered")

	agent_provider_serve_now(&delegate)
	if !testing.expect(test, chat_agents_wait(chat, nil), "the subagent's report arrives") { return }
	accepted, had_message := chat_session_accept_agent_message(chat, {})
	testing.expect(test, had_message && accepted == .Accepted)
	testing.expect(test, chat_run_turn_steered(chat, connection, test_retry_policy(), {}, nil), "the report's turn completed")
	testing.expect(test, strings.contains(agent_provider_request(&orchestrator, 2), "forty-two"), "the report carries the answer")
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
	_test_accept(test, chat, "start one")
	testing.expect_value(
		test,
		subagent_test_call(test, chat, "spawn_1", TOOL_AGENT_SPAWN_NAME, `{"prompt":"wait for instructions"}`),
		journal.TOOL_OUTCOME_NAMES[.Success],
	)
	tool_context := Tool_Context {
		allocator = context.allocator,
		agents    = chat.team,
	}
	stopped := tool_agent_stop_execute(&tool_context, Agent_Stop_Args{agent = "agent-1"})
	defer tool_result_destroy(&stopped)
	testing.expect_value(test, stopped.outcome, journal.Tool_Outcome.Success)
	if !testing.expect(test, chat_agents_wait(chat, nil)) { return }
	records, read_ok := chat_inbox_read(chat)
	if !testing.expect(test, read_ok && len(records) == 1) { return }
	message, _ := inbox_text(records[0])
	testing.expect(test, strings.contains(message, "agent-1 was stopped"), message)
	chat.delivered = records[0].seq
	testing.expect(test, !chat_agents_wait(chat, nil), "cancellation leaves no running child")
}

// A background child whose provider cuts the stream after part of an answer fails, and its
// report to the orchestrator names the child's session, the cause, and the text it had
// committed, so the orchestrator knows what was lost and where to look.
@(test)
test_a_failed_background_subagent_reports_its_session_cause_and_partial_text :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	// The provider says a resend is pointless, so the cut stream ends the child's turn with
	// what it had streamed instead of resending on the production schedule.
	cut := "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nx-should-retry: false\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"The parser lives in\"},\"finish_reason\":null}]}\n\n"
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, {cut}) { return }
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
	_test_accept(test, chat, "start one")
	testing.expect_value(
		test,
		subagent_test_call(test, chat, "spawn_1", TOOL_AGENT_SPAWN_NAME, `{"prompt":"find the parser"}`),
		journal.TOOL_OUTCOME_NAMES[.Success],
	)
	if !testing.expect(test, chat_agents_wait(chat, nil)) { return }
	records, read_ok := chat_inbox_read(chat)
	if !testing.expect(test, read_ok && len(records) == 1) { return }
	report, _ := inbox_text(records[0])
	session_hex: [journal.SESSION_ID_HEX_LENGTH]u8
	testing.expect(test, strings.contains(report, "Subagent agent-1 failed"), report)
	testing.expect(test, strings.contains(report, journal.session_id_to_hex(records[0].subagent, session_hex[:])), report)
	testing.expect(test, strings.contains(report, "The parser lives in"), report)
	completion: journal.Subagent_Completed
	if journal.payload_decode(records[0].data, &completion, context.temp_allocator) != nil { testing.fail_now(test, "the completion could not be read") }
	testing.expect_value(test, completion.outcome, journal.TOOL_OUTCOME_NAMES[.Tool_Failed])
	testing.expect(test, completion.detail != "" && strings.contains(report, completion.detail), report)
	testing.expect_value(test, string(records[0].body), "The parser lives in")
}

// subagent_test_full_team points the orchestrator at catalog's one model and fills every
// slot with children the test finishes itself.
subagent_test_full_team :: proc(chat: ^Chat_Session, catalog: ^Subagent_Test_Catalog, endpoint: string) {
	subagent_test_catalog_add(catalog, "test-provider", "test-model", endpoint, nil)
	chat.catalog = {
		catalog = &catalog.catalog,
	}
	delete(chat.provider_id, chat.allocator)
	chat.provider_id = strings.clone("test-provider", chat.allocator)
	delete(chat.model_id, chat.allocator)
	chat.model_id = strings.clone("test-model", chat.allocator)
	chat.subagents_max_running = SUBAGENT_TEST_MAX_RUNNING
	agent_team_note_parent(chat)
	chat.team.running = SUBAGENT_TEST_MAX_RUNNING
}

// With every slot taken a background subagent queues instead of starting, and a slot freed by a
// finishing child admits the oldest queued one first.
@(test)
test_a_full_team_queues_background_subagents_in_order :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	provider: Agent_Provider
	// The provider never answers, so an admitted child stays running until teardown.
	if !agent_provider_start(test, &provider, {}) { return }
	defer agent_provider_stop(&provider)
	endpoint := agent_provider_endpoint(&provider)
	defer delete(endpoint)
	catalog: Subagent_Test_Catalog
	defer subagent_test_catalog_destroy(&catalog)
	subagent_test_full_team(chat, &catalog, endpoint)
	team := chat.team
	tool_context := Tool_Context {
		allocator = context.allocator,
		agents    = team,
	}
	for _ in 0 ..< 2 {
		// Dispatch names each child's session before it starts, so the test does too.
		tool_context.subagent = journal.session_id_create()
		started := tool_agent_spawn_execute(&tool_context, Agent_Spawn_Args{prompt = "wait for instructions"})
		defer tool_result_destroy(&started)
		testing.expect_value(test, started.outcome, journal.Tool_Outcome.Success)
		testing.expect(test, strings.contains(started.content, "queued"), started.content)
	}
	first, second := team.members[0], team.members[1]
	testing.expect(test, first.status == .Queued && first.thread == nil && second.status == .Queued && second.thread == nil)

	holder := Subagent {
		team     = team,
		admitted = true,
	}
	subagent_finish(&holder)
	testing.expect(test, first.status == .Running && first.thread != nil, "the oldest queued child takes the freed slot")
	testing.expect(test, second.status == .Queued && second.thread == nil, "the next one keeps waiting")
	testing.expect_value(test, team.running, SUBAGENT_TEST_MAX_RUNNING)
	holder.admitted = true
	subagent_finish(&holder)
	testing.expect(test, second.status == .Running && second.thread != nil, "the next freed slot admits the next child")
}

// A queued subagent that is stopped is reported stopped and never gets a thread.
@(test)
test_stopping_a_queued_subagent_never_starts_it :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, {}) { return }
	defer agent_provider_stop(&provider)
	endpoint := agent_provider_endpoint(&provider)
	defer delete(endpoint)
	catalog: Subagent_Test_Catalog
	defer subagent_test_catalog_destroy(&catalog)
	subagent_test_full_team(chat, &catalog, endpoint)
	_test_accept(test, chat, "start one")
	if !testing.expect_value(
		test,
		subagent_test_call(test, chat, "spawn_1", TOOL_AGENT_SPAWN_NAME, `{"prompt":"never runs"}`),
		journal.TOOL_OUTCOME_NAMES[.Success],
	) {
		return
	}
	tool_context := Tool_Context {
		allocator = context.allocator,
		agents    = chat.team,
	}
	stopped := tool_agent_stop_execute(&tool_context, Agent_Stop_Args{agent = "agent-1"})
	defer tool_result_destroy(&stopped)
	testing.expect_value(test, stopped.outcome, journal.Tool_Outcome.Success)
	member := chat.team.members[0]
	testing.expect(test, member.status == .Stopped && member.thread == nil && len(chat.team.waiting) == 0)
	testing.expect_value(test, member.cause, "stopped before it started; not executed")
	agent_team_reap(chat.team, chat)
	records, read_ok := chat_inbox_read(chat)
	if !testing.expect(test, read_ok && len(records) == 1) { return }
	message, _ := inbox_text(records[0])
	testing.expect(test, strings.contains(message, "agent-1 was stopped"), message)
	testing.expect_value(test, agent_provider_request_count(&provider), 0)
	testing.expect_value(test, chat.team.running, SUBAGENT_TEST_MAX_RUNNING)
}

@(test)
test_acp_next_reports_a_malformed_json_rpc_frame :: proc(test: ^testing.T) {
	member := Subagent {
		allocator = context.allocator,
	}
	frames, frames_error := make([dynamic]string, context.allocator)
	if frames_error != nil { testing.fail_now(test, "could not create the ACP frame") }
	frame, frame_error := strings.clone("{}", context.allocator)
	if frame_error != nil {
		delete(frames)
		testing.fail_now(test, "could not create the ACP frame")
	}
	if _, append_error := append(&frames, frame); append_error != nil {
		delete(frame, context.allocator)
		delete(frames)
		testing.fail_now(test, "could not create the ACP frame")
	}
	connection := Acp_Connection {
		member = &member,
		frames = frames,
	}
	defer {
		for queued in connection.frames { delete(queued, context.allocator) }
		delete(connection.frames)
	}

	_, problem := acp_next(&connection)
	testing.expect(test, strings.contains(problem, "could not be parsed as JSON-RPC"), problem)
	testing.expect(test, strings.contains(problem, "does not declare JSON-RPC 2.0"), problem)
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
		printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"other","update":{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}}}\n'
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

	answered := tool_agent_spawn_execute(
		&tool_context,
		Agent_Spawn_Args{instruction = "Answer in one word.", prompt = "six times seven", acp_agent = "fake", wait = true},
	)
	defer tool_result_destroy(&answered)
	testing.expect_value(test, answered.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(answered.content, "forty-two") && !strings.contains(answered.content, "Let me compute"), answered.content)

	failed := tool_agent_spawn_execute(&tool_context, Agent_Spawn_Args{prompt = "something else", acp_agent = "fake", wait = true})
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

// A process that ends with one child running and one still queued loses neither outcome:
// recovery settles both delegations from the journal and restarts nothing, and the
// orchestrator's next request carries each outcome once.
@(test)
test_a_crash_with_a_running_and_a_queued_child_reports_both_outcomes_once :: proc(test: ^testing.T) {
	first: Chat_Test
	chat_test_begin(test, &first, tool_loop_workspace(test))
	chat := &first.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW)

	spawn_running := agent_provider_call(TOOL_AGENT_SPAWN_NAME, `{"prompt":"first task","model":"sub-model"}`)
	spawn_queued := agent_provider_call(TOOL_AGENT_SPAWN_NAME, `{"prompt":"second task","model":"sub-model"}`)
	orchestrator: Agent_Provider
	if !agent_provider_start(test, &orchestrator, {spawn_running, spawn_queued, agent_provider_reply("waiting")}) {
		chat_test_end(test, &first)
		return
	}
	defer agent_provider_stop(&orchestrator)
	// The children's provider accepts connections and never answers.
	hanging: Agent_Provider
	if !agent_provider_start(test, &hanging, {}) {
		chat_test_end(test, &first)
		return
	}
	defer agent_provider_stop(&hanging)
	orchestrator_endpoint := agent_provider_endpoint(&orchestrator)
	defer delete(orchestrator_endpoint)
	hanging_endpoint := agent_provider_endpoint(&hanging)
	defer delete(hanging_endpoint)
	catalog: Subagent_Test_Catalog
	defer subagent_test_catalog_destroy(&catalog)
	subagent_test_catalog_add(&catalog, "test-provider", "test-model", orchestrator_endpoint, nil)
	subagent_test_catalog_add(&catalog, "sub-provider", "sub-model", hanging_endpoint, nil)
	chat.catalog = {
		catalog = &catalog.catalog,
	}
	// One slot is free, so the first child runs and the second queues.
	chat.subagents_max_running = SUBAGENT_TEST_MAX_RUNNING
	chat.team.running = SUBAGENT_TEST_MAX_RUNNING - 1

	_test_accept(test, chat, "start two subagents")
	connection := ai.Provider_Connection {
		API        = .OpenAI_Chat_Completions,
		Endpoint   = orchestrator_endpoint,
		Credential = "test-key",
	}
	if !testing.expect(test, chat_run_turn_steered(chat, connection, test_retry_policy(), {}, nil), "the turn completed") {
		chat_test_end(test, &first)
		return
	}
	testing.expect_value(test, len(chat.team.waiting), 1)
	// The first child has made its session before it blocks on its provider.
	deadline := time.tick_add(time.tick_now(), 5 * time.Second)
	for {
		seen := owner_wake_seen()
		children, _ := journal.list_sessions(chat.store, {parent = chat.session}, context.temp_allocator)
		if len(children) == 1 || time.tick_diff(time.tick_now(), deadline) <= 0 { break }
		owner_wake_wait(seen, time.tick_add(time.tick_now(), 10 * time.Millisecond))
	}
	sends_before := agent_provider_request_count(&orchestrator)

	reopened: Chat_Test
	recovery := chat_test_reopen(test, &first, &reopened, tool_loop_workspace(test))
	defer chat_test_end(test, &reopened)
	next := &reopened.chat
	chat_test_capacity(next, CHAT_DEFAULT_CONTEXT_WINDOW)
	testing.expect_value(test, recovery.calls, 2)
	testing.expect_value(test, next.state, Chat_State.Idle)
	testing.expect(test, !agent_team_running(next.team), "nothing was restarted")
	testing.expect(test, !chat_inbox_reports_pending(next), "outcomes older than the claim start no turn of their own")
	testing.expect_value(test, agent_provider_request_count(&orchestrator), sends_before)

	answering: Agent_Provider
	if !agent_provider_start(test, &answering, {agent_provider_reply("understood")}) { return }
	defer agent_provider_stop(&answering)
	answering_endpoint := agent_provider_endpoint(&answering)
	defer delete(answering_endpoint)
	_test_accept(test, next, "what happened?")
	next_connection := ai.Provider_Connection {
		API        = .OpenAI_Chat_Completions,
		Endpoint   = answering_endpoint,
		Credential = "test-key",
	}
	testing.expect(test, chat_run_turn_steered(next, next_connection, test_retry_policy(), {}, nil), "the next turn completed")
	if !testing.expect_value(test, agent_provider_request_count(&answering), 1) { return }
	request := agent_provider_request(&answering, 0)
	testing.expect_value(test, strings.count(request, "the subagent never started"), 1)
	testing.expect_value(test, strings.count(request, "it may have taken effect"), 1)
}

// subagent_test_parent points the orchestrator at catalog's provider test-provider, which
// its children default to.
subagent_test_parent :: proc(chat: ^Chat_Session, catalog: ^Subagent_Test_Catalog) {
	chat.catalog = {
		catalog = &catalog.catalog,
	}
	delete(chat.provider_id, chat.allocator)
	chat.provider_id = strings.clone("test-provider", chat.allocator)
	delete(chat.model_id, chat.allocator)
	chat.model_id = strings.clone("test-model", chat.allocator)
	agent_team_note_parent(chat)
}

// subagent_test_report waits for the one report a child's end leaves in the orchestrator's
// inbox, marks it delivered, and returns its text.
subagent_test_report :: proc(test: ^testing.T, chat: ^Chat_Session) -> string {
	if !chat_agents_wait(chat, nil) { testing.fail_now(test, "no report arrived") }
	records, read_ok := chat_inbox_read(chat)
	if !read_ok || len(records) != 1 { testing.fail_now(test, "the inbox does not hold exactly one report") }
	chat.delivered = records[0].seq
	text, _ := inbox_text(records[0])
	return text
}

// subagent_test_result is the text of the newest tool result the orchestrator recorded.
subagent_test_result :: proc(test: ^testing.T, chat: ^Chat_Session) -> string {
	completed := _test_records(test, chat, {.Tool_Completed})
	if len(completed) == 0 { testing.fail_now(test, "no call has a result") }
	return string(completed[len(completed) - 1].body)
}

// agent_send to a child that has finished reopens its session. The child's second request
// carries its task, its answer, and the new message in the same session, and a message that
// could not be delivered because another process held the session is delivered with the next.
@(test)
test_agent_send_reopens_a_finished_subagent_in_its_own_session :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, {agent_provider_reply("forty-two"), agent_provider_reply("eighty-four")}) { return }
	defer agent_provider_stop(&provider)
	endpoint := agent_provider_endpoint(&provider)
	defer delete(endpoint)
	catalog: Subagent_Test_Catalog
	defer subagent_test_catalog_destroy(&catalog)
	subagent_test_catalog_add(&catalog, "test-provider", "test-model", endpoint, nil)
	subagent_test_parent(chat, &catalog)
	_test_accept(test, chat, "start one")

	success := journal.TOOL_OUTCOME_NAMES[.Success]
	testing.expect_value(test, subagent_test_call(test, chat, "spawn_1", TOOL_AGENT_SPAWN_NAME, `{"prompt":"what is six times seven"}`), success)
	testing.expect(test, strings.contains(subagent_test_report(test, chat), "forty-two"), "the child answered")
	children, children_error := journal.list_sessions(chat.store, {parent = chat.session}, context.temp_allocator)
	if !testing.expect(test, children_error == nil && len(children) == 1) { return }
	child := children[0].id

	// A session another process runs is refused by the claim, and the child's failure says so.
	holder: journal.Journal
	if open_error := journal.open(&holder, fixture.directory, fixture.directory, journal.run_id_create(), .Read_Write); open_error != nil {
		testing.fail_now(test, "the second journal could not be opened")
	}
	if _, claim_error := journal.claim(&holder, child); claim_error != nil { testing.fail_now(test, "the second journal could not claim the child") }
	testing.expect_value(test, subagent_test_call(test, chat, "send_1", TOOL_AGENT_SEND_NAME, `{"agent":"agent-1","message":"Try this."}`), success)
	refused := subagent_test_report(test, chat)
	testing.expect(test, strings.contains(refused, "agent-1 failed") && strings.contains(refused, "another process holds the session"), refused)
	holder_error := journal.close(&holder)
	testing.expect(test, holder_error == nil, "the second journal closed")

	testing.expect_value(test, subagent_test_call(test, chat, "send_2", TOOL_AGENT_SEND_NAME, `{"agent":"agent-1","message":"Now double it."}`), success)
	testing.expect(test, strings.contains(subagent_test_report(test, chat), "eighty-four"), "the reopened child answered")
	if !testing.expect_value(test, agent_provider_request_count(&provider), 2) { return }
	request := agent_provider_request(&provider, 1)
	for expected in ([]string{"what is six times seven", "forty-two", "Try this.", "Now double it."}) {
		testing.expect(test, strings.contains(request, expected), expected)
	}

	// It is the same session: no second child exists, and it holds both answers.
	children, children_error = journal.list_sessions(chat.store, {parent = chat.session}, context.temp_allocator)
	testing.expect(test, children_error == nil && len(children) == 1 && children[0].id == child, "no second session was made")
	_, head, head_error := journal.session_head(chat.store, child)
	if !testing.expect(test, head_error == nil) { return }
	nodes, nodes_error := journal.read_ancestry(chat.store, child, head, context.temp_allocator)
	if !testing.expect(test, nodes_error == nil) { return }
	answers := 0
	for node in nodes { if node.kind == .Assistant { answers += 1 } }
	testing.expect_value(test, answers, 2)
}

// A child that failed is reopened by agent_send on a model of another provider, and the
// request that reaches it carries the whole conversation. Calls that cannot reopen it are
// refused with what the model needs to correct them, and leave no message behind.
@(test)
test_agent_send_reopens_a_failed_subagent_on_another_model :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	cut := "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nx-should-retry: false\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"The parser lives in\"},\"finish_reason\":null}]}\n\n"
	failing: Agent_Provider
	if !agent_provider_start(test, &failing, {cut}) { return }
	defer agent_provider_stop(&failing)
	other: Agent_Provider
	if !agent_provider_start(test, &other, {agent_provider_reply("parser.odin")}) { return }
	defer agent_provider_stop(&other)
	failing_endpoint := agent_provider_endpoint(&failing)
	defer delete(failing_endpoint)
	other_endpoint := agent_provider_endpoint(&other)
	defer delete(other_endpoint)
	catalog: Subagent_Test_Catalog
	defer subagent_test_catalog_destroy(&catalog)
	subagent_test_catalog_add(&catalog, "test-provider", "test-model", failing_endpoint, nil)
	subagent_test_catalog_add(&catalog, "other-provider", "other-model", other_endpoint, nil)
	subagent_test_parent(chat, &catalog)
	_test_accept(test, chat, "start one")

	success := journal.TOOL_OUTCOME_NAMES[.Success]
	testing.expect_value(
		test,
		subagent_test_call(test, chat, "spawn_1", TOOL_AGENT_SPAWN_NAME, `{"instruction":"Report file names only.","prompt":"find the parser"}`),
		success,
	)
	testing.expect(test, strings.contains(subagent_test_report(test, chat), "agent-1 failed"), "the child failed")

	// A name that is not a child of this session lists the ones that are, with how each ended.
	testing.expect(test, subagent_test_call(test, chat, "send_1", TOOL_AGENT_SEND_NAME, `{"agent":"agent-9","message":"Hello."}`) != success)
	testing.expect(test, strings.contains(subagent_test_result(test, chat), "agent-1 (failed)"), subagent_test_result(test, chat))
	// A provider that does not exist lists the ones that do, and a refused call leaves no message.
	testing.expect(
		test,
		subagent_test_call(test, chat, "send_2", TOOL_AGENT_SEND_NAME, `{"agent":"agent-1","message":"Continue.","provider":"nowhere"}`) != success,
	)
	testing.expect(
		test,
		strings.contains(subagent_test_result(test, chat), "configured providers: test-provider, other-provider"),
		subagent_test_result(test, chat),
	)
	testing.expect_value(test, len(_test_records(test, chat, {.Subagent_Message})), 0)

	testing.expect_value(
		test,
		subagent_test_call(test, chat, "send_3", TOOL_AGENT_SEND_NAME, `{"agent":"agent-1","message":"Continue.","model":"other-model"}`),
		success,
	)
	testing.expect(test, strings.contains(subagent_test_report(test, chat), "parser.odin"), "the reopened child answered")
	testing.expect_value(test, agent_provider_request_count(&failing), 1)
	if !testing.expect_value(test, agent_provider_request_count(&other), 1) { return }
	request := agent_provider_request(&other, 0)
	for expected in ([]string{"Report file names only.", "find the parser", "Continue."}) {
		testing.expect(test, strings.contains(request, expected), expected)
	}
	children, _ := journal.list_sessions(chat.store, {parent = chat.session}, context.temp_allocator)
	if !testing.expect_value(test, len(children), 1) { return }
	turn, found, turn_error := journal.read_latest(chat.store, {session = children[0].id, kinds = {.Turn_Started}}, context.temp_allocator)
	testing.expect(test, turn_error == nil && found)
	testing.expect_value(test, turn.provider, "other-provider")
	testing.expect_value(test, turn.model, "other-model")
}

// agent_send with compact and no message reopens a finished child only to compact it: the
// child's journal gets the summary and its checkpoint, and the orchestrator gets a completion.
// A later send names an effort, which the child's next turn runs with.
@(test)
test_agent_send_compacts_a_finished_subagent_and_continues_with_an_effort :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	provider: Agent_Provider
	// The child holds more than the newest messages a summary keeps verbatim, and the
	// oldest are longer than the summary, so there is something to summarize.
	bulk, _ := strings.repeat("forty-two ", 1000, context.temp_allocator)
	responses := make([dynamic]string, context.temp_allocator)
	append(&responses, agent_provider_reply(bulk))
	for _ in 0 ..< 5 { append(&responses, agent_provider_reply("again")) }
	append(&responses, agent_provider_reply(COMPACT_TEST_SUMMARY), agent_provider_reply("eighty-four"))
	if !agent_provider_start(test, &provider, responses[:]) { return }
	defer agent_provider_stop(&provider)
	endpoint := agent_provider_endpoint(&provider)
	defer delete(endpoint)
	catalog: Subagent_Test_Catalog
	defer subagent_test_catalog_destroy(&catalog)
	subagent_test_catalog_add(&catalog, "test-provider", "test-model", endpoint, {"low", "high"})
	subagent_test_parent(chat, &catalog)
	_test_accept(test, chat, "start one")

	success := journal.TOOL_OUTCOME_NAMES[.Success]
	testing.expect_value(test, subagent_test_call(test, chat, "spawn_1", TOOL_AGENT_SPAWN_NAME, `{"prompt":"what is six times seven"}`), success)
	testing.expect(test, strings.contains(subagent_test_report(test, chat), "forty-two"), "the child answered")
	children, children_error := journal.list_sessions(chat.store, {parent = chat.session}, context.temp_allocator)
	if !testing.expect(test, children_error == nil && len(children) == 1) { return }
	child := children[0].id
	for index in 0 ..< 5 {
		call := fmt.tprintf("more_%d", index)
		testing.expect_value(test, subagent_test_call(test, chat, call, TOOL_AGENT_SEND_NAME, `{"agent":"agent-1","message":"Again."}`), success)
		testing.expect(test, strings.contains(subagent_test_report(test, chat), "again"), "the child answered")
	}

	testing.expect_value(test, subagent_test_call(test, chat, "send_1", TOOL_AGENT_SEND_NAME, `{"agent":"agent-1","compact":true}`), success)
	testing.expect(test, strings.contains(subagent_test_report(test, chat), "agent-1 completed"), "the compaction ended with a completion")
	testing.expect_value(test, len(_test_records(test, chat, {.Subagent_Message})), 5)

	for kind in ([]journal.Record_Kind{.Compaction_Completed, .Checkpoint_Installed}) {
		records, _, read_error := journal.read_records(chat.store, {session = child, kinds = {kind}}, 0, 0, context.temp_allocator)
		testing.expect(test, read_error == nil && len(records) == 1, "the child's journal holds the compaction")
	}

	testing.expect_value(
		test,
		subagent_test_call(test, chat, "send_2", TOOL_AGENT_SEND_NAME, `{"agent":"agent-1","message":"Now double it.","effort":"high"}`),
		success,
	)
	testing.expect(test, strings.contains(subagent_test_report(test, chat), "eighty-four"), "the reopened child answered")
	turn, found, turn_error := journal.read_latest(chat.store, {session = child, kinds = {.Turn_Started}}, context.temp_allocator)
	testing.expect(test, turn_error == nil && found)
	started: journal.Turn_Started
	testing.expect(test, journal.payload_decode(turn.data, &started, context.temp_allocator) == nil)
	testing.expect_value(test, started.effort, "high")

	// Neither a message nor compact is not a call.
	testing.expect(test, subagent_test_call(test, chat, "send_3", TOOL_AGENT_SEND_NAME, `{"agent":"agent-1"}`) != success)
}
