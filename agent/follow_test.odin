#+test
package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/journal"
import "nabla:ai"

// Follow_Log is what a front-end was shown, in order, one entry per callback.
Follow_Log :: struct {
	events: [dynamic]string,
}

follow_log_add :: proc(user_data: rawptr, event: string) {
	log := cast(^Follow_Log)user_data
	append(&log.events, strings.clone(event))
}

follow_log_user :: proc(user_data: rawptr, text: string, origin: journal.User_Origin) {
	follow_log_add(user_data, fmt.tprintf("user:%s:%s", text, journal.USER_ORIGIN_NAMES[origin]))
}

follow_log_assistant :: proc(user_data: rawptr, text: string) {
	follow_log_add(user_data, fmt.tprintf("assistant:%s", text))
}

follow_log_call :: proc(user_data: rawptr, event: Chat_Tool_Event) {
	follow_log_add(user_data, fmt.tprintf("call:%s", event.name))
}

follow_log_result :: proc(user_data: rawptr, name, arguments: string, result: ^Tool_Result) {
	follow_log_add(user_data, fmt.tprintf("result:%s:%s", name, result.content))
}

follow_log_message :: proc(user_data: rawptr, kind: Chat_Message_Kind, text: string) {
	follow_log_add(user_data, fmt.tprintf("message:%s", text))
}

follow_log_observer :: proc(log: ^Follow_Log) -> Chat_Observer {
	return {
		user_data = log,
		user_text = follow_log_user,
		assistant_text = follow_log_assistant,
		tool_call = follow_log_call,
		tool_result = follow_log_result,
		message = follow_log_message,
	}
}

follow_log_destroy :: proc(log: ^Follow_Log) {
	for event in log.events { delete(event) }
	delete(log.events)
}

// follow_log_count is how many events start with prefix.
follow_log_count :: proc(log: ^Follow_Log, prefix: string) -> int {
	count := 0
	for event in log.events {
		if strings.has_prefix(event, prefix) { count += 1 }
	}
	return count
}

follow_body :: proc(text: string) -> []u8 {
	return transmute([]u8)text
}

// follow_open opens a second journal on the fixture's directory and follows the fixture's
// session with it, as another process does.
follow_open :: proc(test: ^testing.T, fixture: ^Chat_Test, follower: ^journal.Journal) {
	if open_error := journal.open(follower, fixture.directory, fixture.directory, journal.run_id_create(), .Read_Write); open_error != nil {
		testing.fail_now(test, "the follower journal could not be opened")
	}
	if follow_error := journal.follow(follower, fixture.chat.session); follow_error != nil { testing.fail_now(test, "the session could not be followed") }
}

follow_commit :: proc(test: ^testing.T, store: ^journal.Journal) {
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(test, "the commit failed") }
}

follow_send :: proc(test: ^testing.T, follower: ^journal.Journal, text: string) {
	if input_error := journal.append_input(follower, text, .Prompt); input_error != nil { testing.fail_now(test, "the line was not accepted") }
}

// A follower shows a delivered agent report as user text with its origin, so the
// front-end renders it as a subagent entry rather than a notice.
@(test)
test_a_follower_shows_a_delivered_agent_report_as_user_text :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	store := &fixture.store
	session := fixture.chat.session

	follower: journal.Journal
	follow_open(test, &fixture, &follower)
	defer _ = journal.close(&follower)
	follow, start_error := follow_start(&follower, session)
	if !testing.expect(test, start_error == nil, "the follow could not start") { return }

	log: Follow_Log
	defer follow_log_destroy(&log)
	observer := follow_log_observer(&log)

	_ = journal.append_node(
		store,
		{session = session, branch = journal.INITIAL_BRANCH, kind = .User, turn = 1},
		journal.User{origin = journal.USER_ORIGIN_NAMES[.Agent]},
		follow_body("agent-1 answered\nforty-two"),
	)
	follow_commit(test, store)
	if !testing.expect(test, follow_poll(&follower, session, &follow, observer) == nil, "the poll failed") { return }
	if !testing.expect_value(test, len(log.events), 1) { return }
	testing.expect_value(test, log.events[0], "user:agent-1 answered\nforty-two:agent")
}
// A follower shows a line another agent sent exactly once: the `user.input`
// record shows it, and the User node that delivers it is a repeat of the line,
// whatever origin the line carries.
@(test)
test_a_follower_shows_a_delivered_agent_input_once :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	session := fixture.chat.session

	follower: journal.Journal
	follow_open(test, &fixture, &follower)
	defer _ = journal.close(&follower)
	follow, start_error := follow_start(&follower, session)
	if !testing.expect(test, start_error == nil, "the follow could not start") { return }

	log: Follow_Log
	defer follow_log_destroy(&log)
	observer := follow_log_observer(&log)

	if input_error := journal.append_input(&follower, "agent-1 asks\nwhat next", .Agent); input_error != nil {
		testing.fail_now(test, "the agent line was not accepted")
	}
	if !testing.expect(test, follow_poll(&follower, session, &follow, observer) == nil, "the first poll failed") { return }
	if !testing.expect_value(test, len(log.events), 1) { return }
	testing.expect_value(test, log.events[0], "user:agent-1 asks\nwhat next:agent")

	accepted := chat_session_accept_message(&fixture.chat, "", .Agent, {})
	if !testing.expect_value(test, accepted, Chat_Accept.Accepted) { return }
	if !testing.expect(test, follow_poll(&follower, session, &follow, observer) == nil, "the second poll failed") { return }
	testing.expect_value(test, len(log.events), 1)
}

// A follower shows what the runner commits through the same callbacks a runner's own
// front-end has, in order: a line it sent shows once, though the User node that delivers it
// is committed later, and the records of a Lua script's child call are not shown.
@(test)
test_a_follower_shows_the_records_the_runner_commits_in_order :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	store := &fixture.store
	session := fixture.chat.session

	follower: journal.Journal
	follow_open(test, &fixture, &follower)
	defer _ = journal.close(&follower)
	follow, start_error := follow_start(&follower, session)
	testing.expect(test, start_error == nil, "the follow could not start")
	testing.expect(test, !follow.working, "no turn runs yet")

	log: Follow_Log
	defer follow_log_destroy(&log)
	observer := follow_log_observer(&log)

	header := journal.Record {
		session = session,
		branch  = journal.INITIAL_BRANCH,
		turn    = 1,
	}
	started := header
	started.kind = .Turn_Started
	journal.append_record(store, started, journal.Turn_Started{})
	user := journal.append_node(
		store,
		{session = session, branch = journal.INITIAL_BRANCH, kind = .User, turn = 1},
		journal.User{origin = journal.USER_ORIGIN_NAMES[.Prompt]},
		follow_body("question"),
	)
	prepared := header
	prepared.kind = .Request_Prepared
	prepared.request = 1
	journal.append_record(
		store,
		prepared,
		journal.Request_Prepared{purpose = journal.REQUEST_PURPOSE_NAMES[.Response], estimate = 1234, context_window = 8000},
	)
	assistant := journal.append_node(
		store,
		{session = session, branch = journal.INITIAL_BRANCH, parent = user, kind = .Assistant, turn = 1},
		journal.Assistant{request = 1},
		follow_body("looking"),
	)
	proposed := header
	proposed.kind = .Tool_Proposed
	proposed.node = assistant
	proposed.request = 1
	proposed.call = 1
	journal.append_record(store, proposed, journal.Tool_Proposed{provider_id = "call_1", name = "shell"}, follow_body(`{"command":"ls"}`))
	follow_commit(test, store)

	testing.expect(test, follow_poll(&follower, session, &follow, observer) == nil, "the first poll failed")
	testing.expect(test, follow.working, "a turn started and has not completed")
	testing.expect_value(test, follow.estimate, 1234)
	testing.expect_value(test, follow.window, 8000)

	completed := header
	completed.kind = .Tool_Completed
	completed.node = assistant
	completed.request = 1
	completed.call = 1
	journal.append_record(store, completed, journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]}, follow_body("ok\nexit_code: 0"))
	// A child of a script is not part of the conversation.
	child := completed
	child.call = 2
	child.parent_call = 1
	journal.append_record(store, child, journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Success]}, follow_body("child result"))
	follow_commit(test, store)
	follow_send(test, &follower, "from the follower")
	ended := header
	ended.kind = .Turn_Completed
	journal.append_record(store, ended, journal.Turn_Completed{outcome = journal.TURN_OUTCOME_NAMES[.Completed]})
	follow_commit(test, store)

	// The claimant reads the follower's line, and its User node delivers it.
	lines, lines_error := journal.read_inbox(store, session, 0, context.temp_allocator)
	testing.expect(test, lines_error == nil, "the inbox could not be read")
	if !testing.expect_value(test, len(lines), 1) { return }
	testing.expect_value(test, string(lines[0].body), "from the follower")
	_ = journal.append_node(
		store,
		{session = session, branch = journal.INITIAL_BRANCH, parent = assistant, kind = .User, turn = 2},
		journal.User{origin = journal.USER_ORIGIN_NAMES[.Prompt], message = lines[0].seq},
		follow_body("from the follower"),
	)
	follow_commit(test, store)

	testing.expect(test, follow_poll(&follower, session, &follow, observer) == nil, "the second poll failed")
	testing.expect(test, !follow.working, "the turn completed")
	expected := [?]string{"user:question:prompt", "assistant:looking", "call:shell", "result:shell:ok\nexit_code: 0", "user:from the follower:prompt"}
	if !testing.expect_value(test, len(log.events), len(expected)) { return }
	for event, index in expected { testing.expect_value(test, log.events[index], event) }

	// Nothing is shown twice: a poll with nothing new shows nothing.
	testing.expect(test, follow_poll(&follower, session, &follow, observer) == nil, "the third poll failed")
	testing.expect_value(test, len(log.events), len(expected))
}

// Lines other processes committed while the session was idle start a turn, and every one
// reaches the model in seq order whichever process wrote it. A line older than the claim
// waits for the next prompt.
@(test)
test_the_runner_starts_a_turn_for_lines_other_processes_sent_while_idle :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)

	first, second: journal.Journal
	follow_open(test, &fixture, &first)
	defer _ = journal.close(&first)
	follow_open(test, &fixture, &second)
	defer _ = journal.close(&second)
	testing.expect(test, !chat_inbox_reports_pending(chat), "an idle session with an empty inbox starts nothing")

	follow_send(test, &first, "line one")
	follow_send(test, &second, "line two")
	follow_send(test, &first, "line three")
	testing.expect(test, chat_inbox_reports_pending(chat), "lines other processes sent start a turn")

	provider: Agent_Provider
	if !agent_provider_start(test, &provider, {agent_provider_reply("done")}) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	log: Follow_Log
	defer follow_log_destroy(&log)
	observer := follow_log_observer(&log)
	accepted, had_message := chat_session_accept_agent_message(chat, observer)
	testing.expect_value(test, accepted, Chat_Accept.Accepted)
	testing.expect(test, had_message, "a turn was started for the lines")
	testing.expect(test, chat_run_turn_steered(chat, connection, test_retry_policy(), observer, nil), "the turn completed")

	expected := [?]string{"user:line one:prompt", "user:line two:prompt", "user:line three:prompt"}
	if !testing.expect_value(test, follow_log_count(&log, "user:"), len(expected)) { return }
	for event, index in expected { testing.expect_value(test, log.events[index], event) }
	if !testing.expect_value(test, agent_provider_request_count(&provider), 1) { return }
	request := agent_provider_request(&provider, 0)
	one, two, three := strings.index(request, "line one"), strings.index(request, "line two"), strings.index(request, "line three")
	testing.expect(test, one >= 0 && two > one && three > two, "the model reads the lines in seq order")
	testing.expect(test, !chat_inbox_reports_pending(chat), "the lines were delivered")
}

// A line older than the claim is not a turn nobody waits for, so it waits for the next prompt.
@(test)
test_a_line_older_than_the_claim_waits_for_the_next_prompt :: proc(test: ^testing.T) {
	first: Chat_Test
	chat_test_begin(test, &first, tool_loop_workspace(test))
	follower: journal.Journal
	follow_open(test, &first, &follower)
	defer _ = journal.close(&follower)
	follow_send(test, &follower, "sent before the claim")

	reopened: Chat_Test
	_ = chat_test_reopen(test, &first, &reopened, tool_loop_workspace(test))
	defer chat_test_end(test, &reopened)
	testing.expect(test, !chat_inbox_reports_pending(&reopened.chat), "a line older than the claim starts no turn")
	follow_send(test, &follower, "sent after the claim")
	testing.expect(test, chat_inbox_reports_pending(&reopened.chat), "a line committed after the claim starts one")
}

Follow_Midturn_Probe :: struct {
	follower: ^journal.Journal,
	sent:     bool,
}

follow_midturn_send :: proc(user_data: rawptr) {
	probe := cast(^Follow_Midturn_Probe)user_data
	if probe.sent { return }
	probe.sent = true
	_ = journal.append_input(probe.follower, "mid turn line", .Prompt)
}

// A line another process commits while a request is in flight is delivered at the next
// settled point of the same turn, which makes the turn answer it.
@(test)
test_a_line_committed_during_a_turn_is_delivered_at_the_next_boundary :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)

	follower: journal.Journal
	follow_open(test, &fixture, &follower)
	defer _ = journal.close(&follower)

	provider: Agent_Provider
	if !agent_provider_start(test, &provider, {agent_provider_reply("first answer"), agent_provider_reply("second answer")}) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	probe := Follow_Midturn_Probe {
		follower = &follower,
	}
	observer := Chat_Observer {
		user_data        = &probe,
		request_prepared = follow_midturn_send,
	}
	_test_accept(test, chat, "the prompt")
	testing.expect(test, chat_run_turn_steered(chat, connection, test_retry_policy(), observer, nil), "the turn completed")
	testing.expect(test, probe.sent, "the line was committed during the first request")
	if !testing.expect_value(test, agent_provider_request_count(&provider), 2) { return }
	testing.expect_value(test, strings.count(agent_provider_request(&provider, 0), "mid turn line"), 0)
	testing.expect_value(test, strings.count(agent_provider_request(&provider, 1), "mid turn line"), 1)
	lines, _ := journal.read_inbox(chat.store, chat.session, 0, context.temp_allocator)
	delivered, _ := journal.last_delivered_message(chat.store, chat.session)
	if testing.expect_value(test, len(lines), 1) { testing.expect_value(test, delivered, lines[0].seq) }
}

// Two followers retry the claim after the runner's drops: one takes it and the other stays
// a follower, and the session records exactly one new claim.
@(test)
test_two_followers_race_for_a_dropped_claim :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	session := fixture.chat.session
	first, second: journal.Journal
	follow_open(test, &fixture, &first)
	defer _ = journal.close(&first)
	follow_open(test, &fixture, &second)
	defer _ = journal.close(&second)
	follow_commit(test, &fixture.store)

	claims_before := len(_claim_records(test, &first, session))
	chat_session_destroy(&fixture.chat)
	if close_error := journal.close(&fixture.store); close_error != nil { testing.fail_now(test, "the runner's journal did not close") }
	defer {
		// The directory is abandoned; a removal that fails changes nothing in a test.
		_ = os.remove_all(fixture.directory)
		delete(fixture.directory, context.allocator)
	}

	_, first_error := journal.try_claim(&first)
	_, second_error := journal.try_claim(&second)
	winner_count := 0
	if first_error == nil { winner_count += 1 }
	if second_error == nil { winner_count += 1 }
	testing.expect_value(test, winner_count, 1)
	loser := &second if first_error == nil else &first
	winner := &first if first_error == nil else &second
	testing.expect_value(test, loser.followed, session)
	testing.expect_value(test, loser.claimed, journal.Session_Id{})
	testing.expect_value(test, winner.claimed, session)
	follow_commit(test, winner)
	testing.expect_value(test, len(_claim_records(test, winner, session)), claims_before + 1)
}

_claim_records :: proc(test: ^testing.T, store: ^journal.Journal, session: journal.Session_Id) -> []journal.Record {
	records, _, read_error := journal.read_records(store, {session = session, kinds = {.Session_Claimed}}, 0, 0, context.temp_allocator)
	if read_error != nil { testing.fail_now(test, "the claim records could not be read") }
	return records
}

@(test)
test_follow_attachment_snapshot_keeps_delivery_between_reads_once :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	store := &fixture.store
	session := fixture.chat.session
	follower: journal.Journal
	follow_open(test, &fixture, &follower)
	defer _ = journal.close(&follower)
	follow_send(test, &follower, "queued at attachment")
	pending, pending_error := journal.read_inbox(store, session, 0, context.temp_allocator)
	if !testing.expect(test, pending_error == nil && len(pending) == 1) { return }
	if error := journal.begin_read_snapshot(&follower); error != nil { testing.fail_now(test, "snapshot begin failed") }
	snapshot_open := true
	defer if snapshot_open { _ = journal.end_read_snapshot(&follower) }
	follow, start_error := follow_start(&follower, session)
	if !testing.expect(test, start_error == nil) { return }
	_, captured_head, head_error := journal.session_head(&follower, session)
	if !testing.expect(test, head_error == nil) { return }
	_ = journal.append_node(
		store,
		{session = session, branch = journal.INITIAL_BRANCH, parent = captured_head, kind = .User},
		journal.User{origin = journal.USER_ORIGIN_NAMES[.Prompt], message = pending[0].seq},
		follow_body("queued at attachment"),
	)
	follow_commit(test, store)
	delivered, delivered_error := journal.last_delivered_message(&follower, session)
	if !testing.expect(test, delivered_error == nil) { return }
	captured_pending, inbox_error := journal.read_inbox(&follower, session, delivered, context.allocator)
	defer journal.records_destroy(captured_pending, context.allocator)
	if !testing.expect(test, inbox_error == nil && len(captured_pending) == 1) { return }
	_, still_captured_head, captured_error := journal.session_head(&follower, session)
	testing.expect(test, captured_error == nil)
	testing.expect_value(test, still_captured_head, captured_head)
	if error := journal.end_read_snapshot(&follower); error != nil { testing.fail_now(test, "snapshot end failed") }
	snapshot_open = false
	log: Follow_Log
	defer follow_log_destroy(&log)
	observer := follow_log_observer(&log)
	for record in captured_pending {
		if record.kind == .User_Input {
			observer.user_text(observer.user_data, string(record.body), user_input_origin(record))
		}
	}
	testing.expect_value(test, follow_poll(&follower, session, &follow, observer), nil)
	testing.expect_value(test, follow_poll(&follower, session, &follow, observer), nil)
	testing.expect_value(test, follow_log_count(&log, "user:queued at attachment"), 1)
}
