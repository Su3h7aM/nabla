#+test
package agent

import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "nabla:agent/journal"
import "nabla:ai"

Log_Chat_Test :: struct {
	chat:    Chat_Test,
	ring:    ^Diag_Ring,
	binding: Log_Binding,
	ambient: log.Logger,
}

log_chat_begin :: proc(test: ^testing.T, fixture: ^Log_Chat_Test, workspace: string, lowest := log.Level.Info) -> log.Logger {
	fixture.ambient = context.logger
	fixture.ring = new(Diag_Ring)
	fixture.ring.lowest = lowest
	chat_test_begin(test, &fixture.chat, workspace)
	fixture.binding = Log_Binding {
		ring = fixture.ring,
	}
	return log_logger(&fixture.binding)
}

log_chat_end :: proc(test: ^testing.T, fixture: ^Log_Chat_Test) {
	context.logger = fixture.ambient
	chat_test_end(test, &fixture.chat)
	free(fixture.ring)
	fixture^ = {}
}

log_chat_text :: proc(test: ^testing.T, fixture: ^Log_Chat_Test) -> string {
	text: [dynamic]u8
	records, _, read_error := journal.read_records(&fixture.chat.store, {kinds = {.Runtime_Message}}, 0, 0, context.allocator)
	if read_error != nil { testing.fail_now(test, "diagnostic records could not be read") }
	defer journal.records_destroy(records, context.allocator)
	for record in records {
		message: journal.Runtime_Message
		if journal.payload_decode(record.data, &message, context.temp_allocator) != nil { testing.fail_now(test, "diagnostic message could not be decoded") }
		append(&text, ..transmute([]u8)message.text)
		if record.session != {} {
			hex_text: [journal.SESSION_ID_HEX_LENGTH]u8
			append(&text, ..transmute([]u8)fmt.tprintf(" session_id=%s", journal.session_id_to_hex(record.session, hex_text[:])))
		}
		if record.turn != 0 { append(&text, ..transmute([]u8)fmt.tprintf(" turn_no=%d", record.turn)) }
		if record.request != 0 { append(&text, ..transmute([]u8)fmt.tprintf(" request_no=%d", record.request)) }
		append(&text, '\n')
	}
	entry: Diag_Entry
	for diag_pop(fixture.ring, &entry) {
		append(&text, ..entry.text[:entry.text_length])
		if entry.session != {} {
			hex_text: [journal.SESSION_ID_HEX_LENGTH]u8
			append(&text, ..transmute([]u8)fmt.tprintf(" session_id=%s", journal.session_id_to_hex(entry.session, hex_text[:])))
		}
		if entry.turn != 0 { append(&text, ..transmute([]u8)fmt.tprintf(" turn_no=%d", entry.turn)) }
		if entry.request != 0 { append(&text, ..transmute([]u8)fmt.tprintf(" request_no=%d", entry.request)) }
		append(&text, '\n')
	}
	return string(text[:])
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
	testing.expect(test, chat_persist_turn_end(chat, finish))
	return log_chat_record_count(test, chat), chat.calls_made
}

// log_chat_record_count is how many facts the session committed, which is what a
// diagnostic must not change.
@(private)
log_chat_record_count :: proc(test: ^testing.T, chat: ^Chat_Session) -> int {
	records, _, read_error := journal.read_records(chat.store, {session = chat.session}, 0, 0, context.temp_allocator)
	if read_error != nil { testing.fail_now(test, "the records could not be read") }
	defer journal.records_destroy(records, context.temp_allocator)
	count := 0
	for record in records { if record.kind != .Runtime_Message { count += 1 } }
	return count
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
	testing.expect(test, strings.contains(text, "turn.started"), "the turn start is recorded")
	testing.expect(test, strings.contains(text, "turn.finished"), "the turn end is recorded")
	testing.expect(test, strings.contains(text, "prompt_bytes=5"), "the start carries the prompt size")
	testing.expect(test, strings.contains(text, "outcome=cancelled"), "the end names the outcome")
	testing.expect(test, strings.contains(text, "recorded=true"), "the end says the outcome landed")
	// The scope carries the session the work belongs to and the durable turn.
	session_field := strings.concatenate({"session_id=", chat_session_text(chat)}, context.temp_allocator)
	testing.expect(test, strings.contains(text, session_field), "records carry the session")
	testing.expect(test, strings.contains(text, "turn_no=1"), "records carry the durable turn")
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
	testing.expect(test, chat_persist_turn_end(chat, finish))

	// The retired operation's event is dropped, and that is what the record says.
	_test_accept(test, chat, "second")
	_test_begin_request(test, chat)
	testing.expect(test, !chat_session_feed_text(chat, stale, "late"))
	chat_session_retire_operation(chat)

	context.logger = fixture.ambient
	text := log_chat_text(test, &fixture)
	defer delete(text, context.allocator)
	testing.expect(test, strings.contains(text, "agent.event_ignored"), "the dropped event is recorded")
	testing.expect(test, strings.contains(text, "reason=superseded_turn"), "the record names why it was refused")
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
	testing.expect(test, strings.contains(text, "call_id=call_1"), "every tool record carries the call")
	testing.expect(test, strings.contains(text, "repairs="), "the admission says nothing was repaired")
	testing.expect(test, strings.contains(text, "outcome=success"), "the execution outcome is named")
	testing.expect(test, strings.contains(text, "call=1"), "the result names the call it was stored as")
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
	testing.expect(test, strings.contains(text, "provider.encoded"), "the encoded body is recorded")
	testing.expect(test, strings.contains(text, "api=openai_responses"), "the record names the API family")
	testing.expect(test, strings.contains(text, "model=test-model"), "the record names the model")
	testing.expect(test, strings.contains(text, "tools=3"), "the record counts the encoded tools")
	testing.expect_value(test, len(body), 38)
	testing.expect(test, strings.contains(text, "body_bytes=38"), "the record counts the encoded bytes")
	testing.expect(
		test,
		strings.contains(text, "9a097790cd5c0aeb05c59c221f90963b0abbba75d5044c094beef975c536f26d"),
		"the record carries the digest of those exact bytes",
	)
}

@(test)
test_diagnostics_do_not_change_a_turn :: proc(test: ^testing.T) {
	// The same turn with and without diagnostics must keep the same facts and calls.
	plain: Chat_Test
	chat_test_begin(test, &plain, tool_loop_workspace(test))
	defer chat_test_end(test, &plain)
	plain_records, plain_calls := log_chat_cancel_turn(test, &plain.chat)

	logged: Log_Chat_Test
	context.logger = log_chat_begin(test, &logged, tool_loop_workspace(test))
	defer log_chat_end(test, &logged)
	logged_records, logged_calls := log_chat_cancel_turn(test, &logged.chat.chat)
	context.logger = logged.ambient

	testing.expect(test, plain_records > 0, "the turn recorded something")
	testing.expect_value(test, logged_records, plain_records)
	testing.expect_value(test, logged_calls, plain_calls)
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
	testing.expect(test, strings.contains(text, "compaction.started"), "the start is recorded")
	testing.expect(test, strings.contains(text, "trigger=user_command"), "the trigger is named")
	testing.expect(test, strings.contains(text, "turn_no=1"), "a compaction inside a turn names the turn")

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
test_a_prepared_request_records_its_admission :: proc(test: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(test, &fixture, tool_loop_workspace(test))
	defer log_chat_end(test, &fixture)
	chat := &fixture.chat.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW, 64)
	_test_accept(test, chat, "say something")

	responses := []string{agent_provider_reply("ready")}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(connection.Endpoint, chat.allocator)

	testing.expect(test, chat_run_turn(chat, connection, test_retry_policy(), {}), "the request completed")
	records, _, read_error := journal.read_records(
		&fixture.chat.store,
		{session = chat.session, kinds = {.Request_Prepared, .Request_Admitted}},
		0,
		0,
		context.allocator,
	)
	if read_error != nil { testing.fail_now(test, "the request records could not be read") }
	defer journal.records_destroy(records, context.allocator)
	if !testing.expect_value(test, len(records), 2) { return }

	request: journal.Request_Id
	prepared_found, admitted_found := false, false
	for record in records {
		testing.expect_value(test, record.turn, journal.Turn_Id(1))
		testing.expect_value(test, record.request != 0, true)
		testing.expect_value(test, record.provider, chat.provider_id)
		testing.expect_value(test, record.model, chat.model_id)
		#partial switch record.kind {
		case .Request_Prepared:
			payload: journal.Request_Prepared
			if journal.payload_decode(record.data, &payload, context.temp_allocator) != nil {
				testing.fail_now(test, "request.prepared could not be decoded")
			}
			testing.expect_value(test, payload.purpose, journal.REQUEST_PURPOSE_NAMES[.Response])
			testing.expect_value(test, payload.api, "openai_chat_completions")
			testing.expect_value(test, payload.transport, "http")
			testing.expect(test, payload.estimate > 0, "the prepared request carries its estimate")
			testing.expect_value(test, payload.context_window, CHAT_DEFAULT_CONTEXT_WINDOW)
			testing.expect(test, payload.messages > 0, "the prepared request counts its messages")
			request = record.request
			prepared_found = true
		case .Request_Admitted:
			payload: journal.Request_Admitted
			if journal.payload_decode(record.data, &payload, context.temp_allocator) != nil {
				testing.fail_now(test, "request.admitted could not be decoded")
			}
			testing.expect_value(test, payload.decision, "fits")
			testing.expect(test, payload.estimate > 0, "the admission carries its estimate")
			testing.expect_value(test, payload.context_window, CHAT_DEFAULT_CONTEXT_WINDOW)
			admitted_found = true
		}
	}
	testing.expect(test, prepared_found, "the request preparation is recorded")
	testing.expect(test, admitted_found, "the admission decision is recorded")
	for record in records { testing.expect_value(test, record.request, request) }
}

@(test)
test_a_retry_records_its_schedule_and_completion :: proc(test: ^testing.T) {
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

	records, _, read_error := journal.read_records(
		&fixture.chat.store,
		{session = chat.session, kinds = {.Retry_Scheduled, .Retry_Completed}},
		0,
		0,
		context.allocator,
	)
	if read_error != nil { testing.fail_now(test, "the retry records could not be read") }
	defer journal.records_destroy(records, context.allocator)
	if !testing.expect_value(test, len(records), 2) { return }

	scheduled := records[0]
	completed := records[1]
	testing.expect_value(test, scheduled.kind, journal.Record_Kind.Retry_Scheduled)
	testing.expect_value(test, completed.kind, journal.Record_Kind.Retry_Completed)
	testing.expect_value(test, scheduled.request != 0, true)
	testing.expect_value(test, completed.request, scheduled.request)
	testing.expect_value(test, scheduled.attempt, journal.Attempt_No(1))
	testing.expect_value(test, completed.attempt, journal.Attempt_No(2))
	scheduled_payload: journal.Retry_Scheduled
	if journal.payload_decode(scheduled.data, &scheduled_payload, context.temp_allocator) != nil {
		testing.fail_now(test, "retry.scheduled could not be decoded")
	}
	testing.expect_value(test, scheduled_payload.purpose, journal.REQUEST_PURPOSE_NAMES[.Response])
	testing.expect_value(test, scheduled_payload.reason, "transient_failure")
	testing.expect_value(test, scheduled_payload.next_attempt, 2)
	completed_payload: journal.Retry_Completed
	if journal.payload_decode(completed.data, &completed_payload, context.temp_allocator) != nil {
		testing.fail_now(test, "retry.completed could not be decoded")
	}
	testing.expect_value(test, completed_payload.purpose, journal.REQUEST_PURPOSE_NAMES[.Response])
	testing.expect_value(test, completed_payload.outcome, "resent")
}
