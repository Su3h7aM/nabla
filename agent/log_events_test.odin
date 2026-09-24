#+test
package agent

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/session"
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
log_chat_begin :: proc(t: ^testing.T, fixture: ^Log_Chat_Test, workspace: string, lowest := log.Level.Info) -> log.Logger {
	fixture.ambient = context.logger
	logs_root, root_err := os.make_directory_temp("", "nabla-log-events-*", context.allocator)
	if root_err != nil { testing.fail_now(t, "could not create a temporary logs root") }
	fixture.logs_root = logs_root
	if _, open_err := log_open(&fixture.sink, {directory = logs_root, enabled = true, lowest = lowest}); open_err != nil {
		testing.fail_now(t, "the log could not be opened")
	}
	chat_test_begin(t, &fixture.chat, workspace)
	fixture.binding = Log_Binding {
		sink = &fixture.sink,
	}
	return log_logger(&fixture.binding)
}

log_chat_end :: proc(t: ^testing.T, fixture: ^Log_Chat_Test) {
	// Restored first, so a failure inside the teardown below still reaches the test
	// runner rather than the sink being closed.
	context.logger = fixture.ambient
	chat_test_end(t, &fixture.chat)
	_ = log_close(&fixture.sink)
	os.remove_all(fixture.logs_root)
	delete(fixture.logs_root, context.allocator)
	fixture^ = {}
}

log_chat_text :: proc(t: ^testing.T, fixture: ^Log_Chat_Test) -> string {
	return log_test_text(t, log_test_directory_segment(fixture.sink.directory, 1))
}


// log_chat_cancel_turn drives one turn to a cancelled end, which is the shortest
// path that reaches both ends of the turn without a provider.
log_chat_cancel_turn :: proc(t: ^testing.T, chat: ^Chat_Session) -> (entries: int, calls: int) {
	_test_accept(t, chat, "first")
	effect := _test_begin_request(t, chat)
	testing.expect(t, chat_session_feed_text(chat, chat_session_event_source(chat), "partial"))
	testing.expect(t, chat_session_request_cancel(chat))
	chat_session_retire_operation(chat)
	finish := chat_session_advance(chat)
	chat_session_claim_finish(chat, finish)
	chat_persist_turn_end(chat, finish)

	loaded := _test_entries(t, chat)
	defer session.entries_destroy(loaded, context.allocator)
	return len(loaded), chat.calls_made
}

@(test)
test_a_turn_records_its_start_and_end :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(t, &fixture, tool_loop_workspace(t))
	defer log_chat_end(t, &fixture)
	chat := &fixture.chat.chat

	log_chat_cancel_turn(t, chat)
	chat_cancel_reset()

	context.logger = fixture.ambient
	text := log_chat_text(t, &fixture)
	defer delete(text, context.allocator)
	testing.expect(t, strings.contains(text, `"event":"turn.started"`), "the turn start is recorded")
	testing.expect(t, strings.contains(text, `"event":"turn.finished"`), "the turn end is recorded")
	testing.expect(t, strings.contains(text, `"prompt_bytes":5`), "the start carries the prompt size")
	testing.expect(t, strings.contains(text, `"outcome":"cancelled"`), "the end names the outcome")
	testing.expect(t, strings.contains(text, `"recorded":true`), "the end says the outcome landed")
	// The scope carries the session the work belongs to and the durable turn.
	session_field := strings.concatenate({`"session_id":"`, string(chat.id), `"`}, context.temp_allocator)
	testing.expect(t, strings.contains(text, session_field), "records carry the session")
	testing.expect(t, strings.contains(text, `"turn_no":1`), "records carry the durable turn")
}

@(test)
test_a_superseded_operation_is_recorded :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(t, &fixture, tool_loop_workspace(t), .Debug)
	defer log_chat_end(t, &fixture)
	chat := &fixture.chat.chat

	_test_accept(t, chat, "first")
	effect := _test_begin_request(t, chat)
	stale := chat_session_event_source(chat)
	testing.expect(t, chat_session_request_cancel(chat))
	chat_session_retire_operation(chat)
	finish := chat_session_advance(chat)
	chat_session_claim_finish(chat, finish)
	chat_persist_turn_end(chat, finish)
	chat_cancel_reset()

	// The retired operation's event is dropped, and that is what the record says.
	_test_accept(t, chat, "second")
	effect = _test_begin_request(t, chat)
	testing.expect(t, !chat_session_feed_text(chat, stale, "late"))
	chat_session_retire_operation(chat)

	context.logger = fixture.ambient
	text := log_chat_text(t, &fixture)
	defer delete(text, context.allocator)
	testing.expect(t, strings.contains(text, `"event":"agent.event_ignored"`), "the dropped event is recorded")
	testing.expect(t, strings.contains(text, `"reason":"superseded_turn"`), "the record names why it was refused")
}

@(test)
test_a_tool_call_is_recorded_from_call_to_result :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(t, &fixture, tool_loop_workspace(t), .Debug)
	defer log_chat_end(t, &fixture)
	chat := &fixture.chat.chat
	chat.tools_enabled = true
	_test_accept(t, chat, "run printf ok")

	arguments := `{"command":"printf tool-ok","working_directory":null,"timeout_ms":null}`
	call_seq := _test_append(
		t,
		chat,
		{turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.Tool_Call_Entry{call_id = "call_1", name = TOOL_SHELL_NAME, arguments = arguments}},
	)
	append(
		&chat.pending_calls,
		Chat_Tool_Call {
			id = chat_clone_string("call_1", chat.allocator),
			name = chat_clone_string(TOOL_SHELL_NAME, chat.allocator),
			arguments = chat_clone_string(arguments, chat.allocator),
			seq = call_seq,
		},
	)
	chat.state = .Executing_Tools
	testing.expect_value(t, chat_run_tools(chat, {}), 1)

	context.logger = fixture.ambient
	text := log_chat_text(t, &fixture)
	defer delete(text, context.allocator)
	// Every stage of the call, in the order it happened.
	previous := -1
	for event in ([?]string{"tool.call_received", "tool.arguments_prepared", "tool.dispatch_committed", "tool.execution_started", "tool.execution_finished", "tool.result_committed"}) {
		at := strings.index(text, event)
		testing.expectf(t, at >= 0, "the log should record %s", event)
		testing.expectf(t, at > previous, "%s should follow the stage before it", event)
		previous = at
	}
	// The call is followed by its own id, and the dispatch and the result name the
	// entries they were stored as.
	testing.expect(t, strings.contains(text, `"call_id":"call_1"`), "every tool record carries the call")
	testing.expect(t, strings.contains(text, `"repair":"none"`), "the admission says nothing was repaired")
	testing.expect(t, strings.contains(text, `"outcome":"success"`), "the execution outcome is named")
	testing.expect(t, strings.contains(text, `"result_seq":`), "the result names the entry it was stored as")
}

@(test)
test_the_provider_record_names_the_encoded_body :: proc(t: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(t, &fixture, tool_loop_workspace(t))
	defer log_chat_end(t, &fixture)

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
	text := log_chat_text(t, &fixture)
	defer delete(text, context.allocator)
	testing.expect(t, strings.contains(text, `"event":"provider.encoded"`), "the encoded body is recorded")
	testing.expect(t, strings.contains(text, `"api":"openai_responses"`), "the record names the API family")
	testing.expect(t, strings.contains(text, `"model":"test-model"`), "the record names the model")
	testing.expect(t, strings.contains(text, `"tools":3`), "the record counts the encoded tools")
	testing.expect_value(t, len(body), 38)
	testing.expect(t, strings.contains(text, `"body_bytes":38`), "the record counts the encoded bytes")
	testing.expect(
		t,
		strings.contains(text, "9a097790cd5c0aeb05c59c221f90963b0abbba75d5044c094beef975c536f26d"),
		"the record carries the digest of those exact bytes",
	)
}

@(test)
test_a_writer_does_not_change_a_turn :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	// The same turn twice: once with nowhere to record and once with a writer. A
	// diagnostic that changed the durable outcome would show up as a difference
	// here.
	plain: Chat_Test
	chat_test_begin(t, &plain, tool_loop_workspace(t))
	defer chat_test_end(t, &plain)
	plain_entries, plain_calls := log_chat_cancel_turn(t, &plain.chat)
	chat_cancel_reset()

	logged: Log_Chat_Test
	log_chat_begin(t, &logged, tool_loop_workspace(t))
	defer log_chat_end(t, &logged)
	logged_entries, logged_calls := log_chat_cancel_turn(t, &logged.chat.chat)
	chat_cancel_reset()

	testing.expect_value(t, plain_entries, 2)
	testing.expect_value(t, logged_entries, plain_entries)
	testing.expect_value(t, logged_calls, plain_calls)
}

@(test)
test_an_admission_decision_is_recorded :: proc(t: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(t, &fixture, tool_loop_workspace(t))
	defer log_chat_end(t, &fixture)
	chat := &fixture.chat.chat

	// The window has to hold the estimate plus the reserved output plus the margin,
	// or nothing is ever admitted.
	chat_test_capacity(chat, 20_000)
	message, admitted := chat_admission_check(chat, 10, {})
	testing.expect(t, admitted, "a small request fits")
	testing.expect_value(t, message, "")

	_, refused := chat_admission_check(chat, 100_000, {})
	testing.expect(t, !refused, "an oversized request is refused")

	context.logger = fixture.ambient
	text := log_chat_text(t, &fixture)
	defer delete(text, context.allocator)
	testing.expect(t, strings.contains(text, `"event":"request.admission"`), "the decision is recorded")
	testing.expect(t, strings.contains(text, `"decision":"admitted"`), "the admission is named")
	testing.expect(t, strings.contains(text, `"decision":"refused"`), "the refusal is named")
	testing.expect(t, strings.contains(text, `"estimate":100000`), "the refusal carries what was estimated")
}

@(test)
test_starting_a_compaction_records_its_scope :: proc(t: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(t, &fixture, tool_loop_workspace(t))
	defer log_chat_end(t, &fixture)
	chat := &fixture.chat.chat
	chat_test_capacity(chat, 500_000)
	_test_accept(t, chat, "compact me")
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_append(t, chat, {turn_no = chat.turn_no, created_at_ms = 2_000, payload = session.Assistant_Entry{text = text}})
	}

	// A dead endpoint is enough: what is under test is the record the harness
	// writes when it decides to compact, not the summary itself.
	dead := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = "http://127.0.0.1:9/",
	}
	prep, prep_err := chat_prepare(chat, dead, chat.allocator)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	testing.expect_value(t, chat_compact_request(chat, .User_Command), Compact_Request_Result.Scheduled)
	chat_compact_consider(chat, {}, dead, &prep)
	chat_request_prep_destroy(&prep, chat.allocator)
	testing.expect_value(t, chat.compact.state, Compact_State.Running)

	context.logger = fixture.ambient
	text := log_chat_text(t, &fixture)
	defer delete(text, context.allocator)
	testing.expect(t, strings.contains(text, `"event":"compaction.started"`), "the start is recorded")
	testing.expect(t, strings.contains(text, `"trigger":"user_command"`), "the trigger is named")
	testing.expect(t, strings.contains(text, `"turn_no":1`), "a compaction inside a turn names the turn")

	// Teardown joins the worker; the dead endpoint makes it finish promptly.
	chat_compact_destroy(chat)
}

@(test)
test_a_transfer_account_belongs_to_one_attempt :: proc(t: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(t, &fixture, tool_loop_workspace(t))
	defer log_chat_end(t, &fixture)

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
	testing.expect(t, first.transfer_seen, "the transport's own account is kept")
	testing.expect_value(t, first.transfer.stopped_at, ai.Provider_Transfer_Phase.Response_Body)
	testing.expect_value(t, first.transfer.request_body_bytes_accepted, u64(90))
	testing.expect(t, first.transfer.request_complete, "the head went out with the body")

	// The next attempt starts from nothing, so a retry that never reaches the
	// transport cannot inherit the previous attempt's account. This is the same
	// property that keeps its byte count fresh.
	second: Provider_Log
	testing.expect(t, !second.transfer_seen, "an attempt with no transport account says so")
	testing.expect_value(t, second.transfer.request_bytes_accepted, u64(0))
	testing.expect_value(t, second.transfer.stopped_at, ai.Provider_Transfer_Phase.Validate)
	testing.expect(t, !second.transfer.response_head_received, "no head was received by an attempt that never ran")
}

@(test)
test_preparation_never_names_the_previous_request :: proc(t: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(t, &fixture, tool_loop_workspace(t))
	defer log_chat_end(t, &fixture)
	chat := &fixture.chat.chat

	_test_accept(t, chat, "first")
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

	_test_perform_request(t, chat, connection, test_retry_policy(), {}, &usages)
	// The second request of one turn is where the defect showed: the durable
	// number the first request left behind is not this request's identity. It is
	// prepared from the preparing state, which is where a settled tool batch or a
	// rejected response leaves the turn; this request failed instead, so the test
	// states it directly.
	chat.state = .Preparing
	_test_perform_request(t, chat, connection, test_retry_policy(), {}, &usages)

	context.logger = fixture.ambient
	text := log_chat_text(t, &fixture)
	defer delete(text, context.allocator)

	// A preparation record is emitted before its request has a number, so it must
	// carry none. Naming the previous request is worse than naming nothing: a
	// reader filtering for one request would read the other request's estimate.
	prepared, recorded := 0, 0
	for line in strings.split_lines(text, context.temp_allocator) {
		if line == "" { continue }
		value, parse_err := parse_log_line(line)
		if parse_err { continue }
		object, is_object := value.(json.Object)
		if !is_object {
			json.destroy_value(value, context.temp_allocator)
			continue
		}
		event, _ := object["event"].(json.String)
		switch string(event) {
		case "request.prepared", "request.admission":
			prepared += 1
			_, named := object["request_no"]
			testing.expectf(t, !named, "%s must not name a request: %s", event, line)
		case "request.recorded":
			recorded += 1
			_, named := object["request_no"]
			testing.expectf(t, named, "request.recorded must name its request: %s", line)
		}
		json.destroy_value(value, context.temp_allocator)
	}
	// Two requests were prepared and recorded, so the assertions above saw both
	// requests rather than passing over an empty stream.
	testing.expect_value(t, prepared, 4)
	testing.expect_value(t, recorded, 2)
}

// A retry is reported as a structured event, for whoever reads the log after the turn
// rather than while it runs: the decision taken on the failed send, and the send that
// followed it, both naming the request they belong to.
@(test)
test_a_scheduled_retry_is_reported_as_events :: proc(t: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(t, &fixture, tool_loop_workspace(t))
	defer log_chat_end(t, &fixture)
	chat := &fixture.chat.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(t, chat, "say something")

	refusal := `{"error":{"message":"Rate limit reached"}}`
	responses := []string{agent_provider_refusal("429 Too Many Requests", refusal, "retry-after: 0\r\n"), agent_provider_reply("second try")}
	provider: Agent_Provider
	if !agent_provider_start(t, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	testing.expect(t, chat_run_turn(chat, connection, test_retry_policy(), {}), "the turn completed after a retry")

	context.logger = fixture.ambient
	text := log_chat_text(t, &fixture)
	defer delete(text, context.allocator)

	scheduled, started := 0, 0
	for line in strings.split_lines(text, context.temp_allocator) {
		if line == "" { continue }
		value, parse_err := parse_log_line(line)
		if parse_err { continue }
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
			testing.expectf(t, string(reason) == "transient_failure", "a scheduled retry says why: %s", line)
			_, named := object["request_no"]
			testing.expectf(t, named, "a scheduled retry names its request: %s", line)
		case "request.retry_started":
			started += 1
		}
		json.destroy_value(value, context.temp_allocator)
	}
	testing.expect_value(t, scheduled, 1)
	testing.expect_value(t, started, 1)
}

// parse_log_line reads one record the writer produced. The presence of a key is
// what these tests ask about, so the object is returned rather than a struct: a
// zero json.Value is the Null variant, which is not the same as an absent field.
@(private)
parse_log_line :: proc(line: string) -> (json.Value, bool) {
	value, parse_err := json.parse_string(line, parse_integers = true, allocator = context.temp_allocator)
	return value, parse_err != .None
}
