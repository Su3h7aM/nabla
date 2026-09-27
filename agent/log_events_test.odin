#+test
package agent

import "core:encoding/json"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/journal"
import "nabla:ai"

// The state machine is driven here through the same helpers the rest of the suite
// uses, so a test reads back what the harness actually recorded for a real turn
// rather than what a hand-built record would have said.
//
// Every test here installs the harness sink on context.logger, and then has to
// put the test runner's logger back before it asserts anything. core:testing
// reports a failure by logging it, so a failure logged while the sink is
// installed is written into the log under test: the assertion is lost and the
// test passes. fixture.ambient is the runner's logger, and assigning it in the
// test's own scope is what restores it, because an assignment to context inside a
// callee configures only that callee.

Log_Chat_Test :: struct {
	chat:      Chat_Test,
	sink:      Log,
	binding:   Log_Binding,
	logs_root: string,
	// ambient is the logger the test runner installed. Every test saves it back onto
	// context.logger in its own scope before it asserts anything.
	ambient:   log.Logger,
}

// log_chat_begin is chat_test_begin with a writer attached, so the turn the test
// drives has somewhere to record itself. It returns the logger for the test to
// install: a helper cannot configure its caller's context, so the binding lives in
// the fixture and the caller assigns it in its own scope.
log_chat_begin :: proc(test: ^testing.T, fixture: ^Log_Chat_Test, workspace: string, lowest := log.Level.Info) -> log.Logger {
	fixture.ambient = context.logger
	logs_root, root_error := os.make_directory_temp("", "nabla-log-events-*", context.allocator)
	if root_error != nil { testing.fail_now(test, "could not create a temporary logs root") }
	fixture.logs_root = logs_root
	if _, open_error := log_open(&fixture.sink, {directory = logs_root, enabled = true, lowest = lowest}); open_error != nil {
		testing.fail_now(test, "the log could not be opened")
	}
	chat_test_begin(test, &fixture.chat, workspace)
	fixture.binding = Log_Binding {
		sink = &fixture.sink,
	}
	return log_logger(&fixture.binding)
}

log_chat_end :: proc(test: ^testing.T, fixture: ^Log_Chat_Test) {
	// Restored first, so a failure inside the teardown below still reaches the test
	// runner rather than the sink being closed.
	context.logger = fixture.ambient
	chat_test_end(test, &fixture.chat)
	_ = log_close(&fixture.sink)
	os.remove_all(fixture.logs_root)
	delete(fixture.logs_root, context.allocator)
	fixture^ = {}
}

log_chat_text :: proc(test: ^testing.T, fixture: ^Log_Chat_Test) -> string {
	return log_test_text(test, log_test_directory_segment(fixture.sink.directory, 1))
}


// log_chat_cancel_turn drives one turn to a cancelled end, which is the shortest
// path that reaches both ends of the turn without a provider. It returns how many
// facts the session committed and how many calls it made.
log_chat_cancel_turn :: proc(test: ^testing.T, chat: ^Chat_Session) -> (records: int, calls: int) {
	_test_accept(test, chat, "first")
	_test_begin_request(test, chat)
	testing.expect(test, chat_session_feed_text(chat, chat_session_event_source(chat), "partial"))
	testing.expect(test, chat_session_request_cancel(chat))
	chat_session_retire_operation(chat)
	finish := chat_session_advance(chat)
	chat_session_claim_finish(chat, finish)
	chat_persist_turn_end(chat, finish)
	return log_chat_record_count(test, chat), chat.calls_made
}

// log_chat_record_count is how many facts the session committed, which is what a
// diagnostic must not change.
@(private)
log_chat_record_count :: proc(test: ^testing.T, chat: ^Chat_Session) -> int {
	records, _, read_error := journal.read_records(chat.store, {session = chat.session}, 0, 0, context.temp_allocator)
	if read_error != nil { testing.fail_now(test, "the records could not be read") }
	return len(records)
}

@(test)
test_a_turn_records_its_start_and_end :: proc(test: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(test, &fixture, tool_loop_workspace(test))
	defer log_chat_end(test, &fixture)
	chat := &fixture.chat.chat

	log_chat_cancel_turn(test, chat)

	context.logger = fixture.ambient
	text := log_chat_text(test, &fixture)
	defer delete(text, context.allocator)
	testing.expect(test, strings.contains(text, `"event":"turn.started"`), "the turn start is recorded")
	testing.expect(test, strings.contains(text, `"event":"turn.finished"`), "the turn end is recorded")
	testing.expect(test, strings.contains(text, `"prompt_bytes":5`), "the start carries the prompt size")
	testing.expect(test, strings.contains(text, `"outcome":"cancelled"`), "the end names the outcome")
	testing.expect(test, strings.contains(text, `"recorded":true`), "the end says the outcome landed")
	// The scope carries the session the work belongs to and the durable turn.
	session_field := strings.concatenate({`"session_id":"`, chat_session_text(chat), `"`}, context.temp_allocator)
	testing.expect(test, strings.contains(text, session_field), "records carry the session")
	testing.expect(test, strings.contains(text, `"turn_no":1`), "records carry the durable turn")
}

@(test)
test_a_superseded_operation_is_recorded :: proc(test: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(test, &fixture, tool_loop_workspace(test), .Debug)
	defer log_chat_end(test, &fixture)
	chat := &fixture.chat.chat

	_test_accept(test, chat, "first")
	_test_begin_request(test, chat)
	stale := chat_session_event_source(chat)
	testing.expect(test, chat_session_request_cancel(chat))
	chat_session_retire_operation(chat)
	finish := chat_session_advance(chat)
	chat_session_claim_finish(chat, finish)
	chat_persist_turn_end(chat, finish)

	// The retired operation's event is dropped, and that is what the record says.
	_test_accept(test, chat, "second")
	_test_begin_request(test, chat)
	testing.expect(test, !chat_session_feed_text(chat, stale, "late"))
	chat_session_retire_operation(chat)

	context.logger = fixture.ambient
	text := log_chat_text(test, &fixture)
	defer delete(text, context.allocator)
	testing.expect(test, strings.contains(text, `"event":"agent.event_ignored"`), "the dropped event is recorded")
	testing.expect(test, strings.contains(text, `"reason":"superseded_turn"`), "the record names why it was refused")
}

@(test)
test_a_tool_call_is_recorded_from_call_to_result :: proc(test: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(test, &fixture, tool_loop_workspace(test), .Debug)
	defer log_chat_end(test, &fixture)
	chat := &fixture.chat.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "run printf ok")

	arguments := `{"command":"printf tool-ok","working_directory":null,"timeout_ms":null}`
	_test_stage_call(test, chat, "call_1", arguments, TOOL_SHELL_NAME)
	testing.expect_value(test, chat_run_tools(chat, {}), 1)

	context.logger = fixture.ambient
	text := log_chat_text(test, &fixture)
	defer delete(text, context.allocator)
	// Every stage of the call, in the order it happened.
	previous := -1
	for event in ([?]string{"tool.call_received", "tool.arguments_prepared", "tool.dispatch_committed", "tool.execution_started", "tool.execution_finished", "tool.result_committed"}) {
		at := strings.index(text, event)
		testing.expectf(test, at >= 0, "the log should record %s", event)
		testing.expectf(test, at > previous, "%s should follow the stage before it", event)
		previous = at
	}
	// The call is followed by its own id, and the dispatch and the result name the
	// call they were stored as.
	testing.expect(test, strings.contains(text, `"call_id":"call_1"`), "every tool record carries the call")
	testing.expect(test, strings.contains(text, `"repairs":""`), "the admission says nothing was repaired")
	testing.expect(test, strings.contains(text, `"outcome":"success"`), "the execution outcome is named")
	testing.expect(test, strings.contains(text, `"call":1`), "the result names the call it was stored as")
}

@(test)
test_the_provider_record_names_the_encoded_body :: proc(test: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(test, &fixture, tool_loop_workspace(test))
	defer log_chat_end(test, &fixture)

	// The digest is computed here rather than by the code under test, so a record
	// that named a different body would not match it.
	body := `{"model":"test-model","input":"hello"}`
	report := ai.Provider_Operation_Report {
		stage = .Encoded,
		api   = .OpenAI_Responses,
		model = "test-model",
		tools = 3,
		body  = transmute([]u8)body,
	}
	observation: Provider_Log
	log_provider_report(&observation, report)

	context.logger = fixture.ambient
	text := log_chat_text(test, &fixture)
	defer delete(text, context.allocator)
	testing.expect(test, strings.contains(text, `"event":"provider.encoded"`), "the encoded body is recorded")
	testing.expect(test, strings.contains(text, `"api":"openai_responses"`), "the record names the API family")
	testing.expect(test, strings.contains(text, `"model":"test-model"`), "the record names the model")
	testing.expect(test, strings.contains(text, `"tools":3`), "the record counts the encoded tools")
	testing.expect_value(test, len(body), 38)
	testing.expect(test, strings.contains(text, `"body_bytes":38`), "the record counts the encoded bytes")
	testing.expect(
		test,
		strings.contains(text, "9a097790cd5c0aeb05c59c221f90963b0abbba75d5044c094beef975c536f26d"),
		"the record carries the digest of those exact bytes",
	)
}

@(test)
test_a_writer_does_not_change_a_turn :: proc(test: ^testing.T) {
	// The same turn twice: once with nowhere to record and once with a writer. A
	// diagnostic that changed the durable outcome would show up as a difference
	// here.
	plain: Chat_Test
	chat_test_begin(test, &plain, tool_loop_workspace(test))
	defer chat_test_end(test, &plain)
	plain_records, plain_calls := log_chat_cancel_turn(test, &plain.chat)

	logged: Log_Chat_Test
	log_chat_begin(test, &logged, tool_loop_workspace(test))
	defer log_chat_end(test, &logged)
	logged_records, logged_calls := log_chat_cancel_turn(test, &logged.chat.chat)

	testing.expect(test, plain_records > 0, "the turn recorded something")
	testing.expect_value(test, logged_records, plain_records)
	testing.expect_value(test, logged_calls, plain_calls)
}

@(test)
test_an_admission_decision_is_recorded :: proc(test: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(test, &fixture, tool_loop_workspace(test))
	defer log_chat_end(test, &fixture)
	chat := &fixture.chat.chat

	// The window has to hold the estimate plus the reserved output plus the margin,
	// or nothing is ever admitted.
	chat_test_capacity(chat, 20_000)
	message, admitted := chat_admission_check(chat, 10, {})
	testing.expect(test, admitted, "a small request fits")
	testing.expect_value(test, message, "")

	_, refused := chat_admission_check(chat, 100_000, {})
	testing.expect(test, !refused, "an oversized request is refused")

	context.logger = fixture.ambient
	text := log_chat_text(test, &fixture)
	defer delete(text, context.allocator)
	testing.expect(test, strings.contains(text, `"event":"request.admission"`), "the decision is recorded")
	testing.expect(test, strings.contains(text, `"decision":"admitted"`), "the admission is named")
	testing.expect(test, strings.contains(text, `"decision":"refused"`), "the refusal is named")
	testing.expect(test, strings.contains(text, `"estimate":100000`), "the refusal carries what was estimated")
}

@(test)
test_starting_a_compaction_records_its_scope :: proc(test: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(test, &fixture, tool_loop_workspace(test))
	defer log_chat_end(test, &fixture)
	chat := &fixture.chat.chat
	chat_test_capacity(chat, 500_000)
	_test_accept(test, chat, "compact me")
	for answer in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, chat.request, answer)
	}

	// A dead endpoint is enough: what is under test is the record the harness
	// writes when it decides to compact, not the summary itself.
	dead := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = "http://127.0.0.1:9/",
	}
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	prep, prep_error := chat_prepare(chat, dead, virtual.arena_allocator(&arena))
	if prep_error != nil { testing.fail_now(test, "chat_prepare failed") }
	testing.expect_value(test, chat_compact_request(chat, .User_Command), Compact_Request_Result.Scheduled)
	chat_compact_consider(chat, {}, dead, &prep)
	testing.expect_value(test, chat.compact.state, Compact_State.Running)

	context.logger = fixture.ambient
	text := log_chat_text(test, &fixture)
	defer delete(text, context.allocator)
	testing.expect(test, strings.contains(text, `"event":"compaction.started"`), "the start is recorded")
	testing.expect(test, strings.contains(text, `"trigger":"user_command"`), "the trigger is named")
	testing.expect(test, strings.contains(text, `"turn_no":1`), "a compaction inside a turn names the turn")

	// Teardown joins the worker; the dead endpoint makes it finish promptly.
	chat_compact_destroy(chat)
}

@(test)
test_a_transfer_account_belongs_to_one_attempt :: proc(test: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(test, &fixture, tool_loop_workspace(test))
	defer log_chat_end(test, &fixture)

	// A first attempt that stopped after the head arrived.
	first: Provider_Log
	log_provider_report(
		&first,
		{
			stage = .Transfer,
			api = .OpenAI_Responses,
			transfer = {
				stopped_at = .Response_Body,
				request_bytes_accepted = 120,
				request_body_bytes_accepted = 90,
				request_complete = true,
				response_head_received = true,
				status = 200,
			},
		},
	)
	testing.expect(test, first.transfer_seen, "the transport's own account is kept")
	testing.expect_value(test, first.transfer.stopped_at, ai.Provider_Transfer_Phase.Response_Body)
	testing.expect_value(test, first.transfer.request_body_bytes_accepted, u64(90))
	testing.expect(test, first.transfer.request_complete, "the head went out with the body")

	// The next attempt starts from nothing, so a retry that never reaches the
	// transport cannot inherit the previous attempt's account. This is the same
	// property that keeps its byte count fresh.
	second: Provider_Log
	testing.expect(test, !second.transfer_seen, "an attempt with no transport account says so")
	testing.expect_value(test, second.transfer.request_bytes_accepted, u64(0))
	testing.expect_value(test, second.transfer.stopped_at, ai.Provider_Transfer_Phase.Validate)
	testing.expect(test, !second.transfer.response_head_received, "no head was received by an attempt that never ran")
}

@(test)
test_preparation_never_names_the_previous_request :: proc(test: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(test, &fixture, tool_loop_workspace(test))
	defer log_chat_end(test, &fixture)
	chat := &fixture.chat.chat

	_test_accept(test, chat, "first")
	// Admission has to accept, or the request would compact instead, and a
	// compaction is a second provider request this test is not about.
	chat_test_capacity(chat, 256_000, 16_000)

	// A URL this client refuses fails the attempt as an invalid request, which is
	// not retried. So both requests are recorded without being sent, and the test
	// does not wait out a retry backoff.
	usages := make([dynamic]Chat_Request_Usage, 0, chat.allocator)
	defer delete(usages)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = "ftp://not-a-provider",
	}

	_test_perform_request(test, chat, connection, test_retry_policy(), {}, &usages)
	// The second request of one turn is where the defect showed: the durable
	// number the first request left behind is not this request's identity. It is
	// prepared from the preparing state, which is where a settled tool batch or a
	// rejected response leaves the turn; this request failed instead, so the test
	// states it directly.
	chat.state = .Preparing
	_test_perform_request(test, chat, connection, test_retry_policy(), {}, &usages)

	context.logger = fixture.ambient
	text := log_chat_text(test, &fixture)
	defer delete(text, context.allocator)

	// A preparation record is emitted before its request has a number, so it must
	// carry none. Naming the previous request is worse than naming nothing: a
	// reader filtering for one request would read the other request's estimate.
	prepared, recorded := 0, 0
	for line in strings.split_lines(text, context.temp_allocator) {
		if line == "" { continue }
		value, parse_error := parse_log_line(line)
		if parse_error { continue }
		object, is_object := value.(json.Object)
		if !is_object {
			json.destroy_value(value, context.temp_allocator)
			continue
		}
		event, _ := object["event"].(json.String)
		switch string(event) {
		case "request.prepared", "request.admission":
			prepared += 1
			if string(event) == "request.prepared" {
				_, turn_named := object["turn_no"]
				testing.expectf(test, turn_named, "request.prepared must name its turn: %s", line)
			}
			_, named := object["request_no"]
			testing.expectf(test, !named, "%s must not name a request: %s", event, line)
		case "request.recorded":
			recorded += 1
			_, named := object["request_no"]
			testing.expectf(test, named, "request.recorded must name its request: %s", line)
		}
		json.destroy_value(value, context.temp_allocator)
	}
	// Two requests were prepared and recorded, so the assertions above saw both
	// requests rather than passing over an empty stream.
	testing.expect_value(test, prepared, 4)
	testing.expect_value(test, recorded, 2)
}

// A retry is reported as a structured event, for whoever reads the log after the turn
// rather than while it runs: the decision taken on the failed send, and the send that
// followed it, both naming the request they belong to.
@(test)
test_a_scheduled_retry_is_reported_as_events :: proc(test: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(test, &fixture, tool_loop_workspace(test))
	defer log_chat_end(test, &fixture)
	chat := &fixture.chat.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(test, chat, "say something")

	refusal := `{"error":{"message":"Rate limit reached"}}`
	responses := []string{agent_provider_refusal("429 Too Many Requests", refusal, "retry-after: 0\r\n"), agent_provider_reply("second try")}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	testing.expect(test, chat_run_turn(chat, connection, test_retry_policy(), {}), "the turn completed after a retry")

	context.logger = fixture.ambient
	text := log_chat_text(test, &fixture)
	defer delete(text, context.allocator)

	scheduled, started := 0, 0
	for line in strings.split_lines(text, context.temp_allocator) {
		if line == "" { continue }
		value, parse_error := parse_log_line(line)
		if parse_error { continue }
		object, is_object := value.(json.Object)
		if !is_object {
			json.destroy_value(value, context.temp_allocator)
			continue
		}
		event, _ := object["event"].(json.String)
		switch string(event) {
		case "request.retry_scheduled":
			scheduled += 1
			reason, _ := object["reason"].(json.String)
			testing.expectf(test, string(reason) == "transient_failure", "a scheduled retry says why: %s", line)
			_, named := object["request_no"]
			testing.expectf(test, named, "a scheduled retry names its request: %s", line)
		case "request.retry_started":
			started += 1
		}
		json.destroy_value(value, context.temp_allocator)
	}
	testing.expect_value(test, scheduled, 1)
	testing.expect_value(test, started, 1)
}

// parse_log_line reads one record the writer produced. The presence of a key is
// what these tests ask about, so the object is returned rather than a struct: a
// zero json.Value is the Null variant, which is not the same as an absent field.
@(private)
parse_log_line :: proc(line: string) -> (json.Value, bool) {
	value, parse_error := json.parse_string(line, parse_integers = true, allocator = context.temp_allocator)
	return value, parse_error != .None
}
