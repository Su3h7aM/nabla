#+test
package agent

// A session whose turn died with a tool call running is continued, not replayed:
// the next server sends one new request over the recovered history, so the model
// sees the Unknown result and decides what to do.

import "core:strings"
import "core:testing"

import "nabla:agent/journal"
import "nabla:ai"

@(test)
test_continuation_runs_once_after_recovery :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	session := fixture.chat.session

	// A turn that prompted, sent one request, and died with one admitted call.
	prompt := "run the backup"
	answer := "starting the backup"
	arguments := "backup-database-now"
	store := fixture.store
	user := journal.append_node(
		store,
		{session = session, branch = journal.INITIAL_BRANCH, kind = .User, turn = 1},
		journal.User{origin = journal.USER_ORIGIN_NAMES[.Prompt]},
		transmute([]u8)prompt,
	)
	journal.append_record(
		store,
		{session = session, turn = 1, kind = .Turn_Started, model = "test-model"},
		journal.Turn_Started {
			instructions = "0000000000000000000000000000000000000000000000000000000000000000",
			manifest = "0000000000000000000000000000000000000000000000000000000000000000",
		},
	)
	journal.append_record(
		store,
		{session = session, turn = 1, request = 1, kind = .Request_Sent},
		journal.Request_Sent{purpose = journal.REQUEST_PURPOSE_NAMES[.Response], api = chat_api_name(.OpenAI_Chat_Completions), recovery = "initial"},
	)
	assistant := journal.append_node(
		store,
		{session = session, parent = user, branch = journal.INITIAL_BRANCH, kind = .Assistant, turn = 1},
		journal.Assistant{request = 1},
		transmute([]u8)answer,
	)
	journal.append_record(
		store,
		{session = session, turn = 1, node = assistant, request = 1, call = 1, kind = .Tool_Proposed},
		journal.Tool_Proposed{provider_id = "call_1", name = TOOL_SHELL_NAME},
		transmute([]u8)arguments,
	)
	journal.append_record(
		store,
		{session = session, turn = 1, node = assistant, request = 1, call = 1, kind = .Tool_Admitted},
		journal.Tool_Admitted{tool = TOOL_SHELL_NAME},
		transmute([]u8)arguments,
	)
	if _, commit_error := journal.commit(store); commit_error != nil { testing.fail_now(test, "the interrupted turn could not be committed") }

	// The process died there. The next open claims the session and recovers it.
	reopened: Chat_Test
	recovery := chat_test_reopen(test, &fixture, &reopened, tool_loop_workspace(test))
	defer chat_test_end(test, &reopened)
	testing.expect_value(test, recovery.turns, 1)
	testing.expect_value(test, recovery.calls, 1)
	testing.expect_value(test, recovery.results, 1)
	chat := &reopened.chat
	testing.expect(test, chat_continuation_pending(chat), "recovery left a continuation")

	// The continuation is one ordinary turn with no prompt of its own, the way the
	// session server runs it: it delivers nothing new and asks the model over the
	// recovered history.
	if chat_session_accept_message(chat, "", .Agent, {}) != .Accepted { testing.fail_now(test, "the continuation was not admitted") }
	responses := []string{agent_provider_reply("backup noted")}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)
	if !testing.expect(test, chat_run_turn(chat, connection, test_retry_policy(), {}), "the continuation turn completed") { return }
	testing.expect_value(test, agent_provider_request_count(&provider), 1)
	request := agent_provider_request(&provider, 0)
	testing.expect(test, strings.contains(request, arguments), "the recovered history reached the model")
	testing.expect(test, !chat_continuation_pending(chat), "the continuation runs once")
}
