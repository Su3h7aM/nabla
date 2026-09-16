#+test
package agent

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/session"
import "nabla:ai"

// The state machine is driven here through the same helpers the rest of the suite
// uses, so a test reads back what the harness actually recorded for a real turn
// rather than what a hand-built record would have said.

Log_Chat_Test :: struct {
	chat:      Chat_Test,
	log:       Log,
	binding:   Log_Binding,
	logs_root: string,
}

// log_chat_begin is chat_test_begin with a writer attached, so the turn the test
// drives has somewhere to record itself. It returns the logger for the test to
// install: a helper cannot configure its caller's context, so the binding lives in
// the fixture and the caller assigns it in its own scope.
log_chat_begin :: proc(t: ^testing.T, fixture: ^Log_Chat_Test, workspace: string, lowest := log.Level.Info) -> log.Logger {
	logs_root, root_err := os.make_directory_temp("", "nabla-log-events-*", context.allocator)
	if root_err != nil { testing.fail_now(t, "could not create a temporary logs root") }
	fixture.logs_root = logs_root
	if _, open_err := log_open(&fixture.log, {directory = logs_root, enabled = true, lowest = lowest}); open_err != nil {
		testing.fail_now(t, "the log could not be opened")
	}
	chat_test_begin(t, &fixture.chat, workspace)
	fixture.binding = Log_Binding {
		sink = &fixture.log,
	}
	return log_logger(&fixture.binding)
}

log_chat_end :: proc(t: ^testing.T, fixture: ^Log_Chat_Test) {
	chat_test_end(t, &fixture.chat)
	_ = log_close(&fixture.log)
	os.remove_all(fixture.logs_root)
	delete(fixture.logs_root, context.allocator)
	fixture^ = {}
}

log_chat_text :: proc(t: ^testing.T, fixture: ^Log_Chat_Test) -> string {
	return log_test_text(t, log_test_directory_segment(fixture.log.directory, 1))
}

// log_chat_cancel_turn drives one turn to a cancelled end, which is the shortest
// path that reaches both ends of the turn without a provider.
log_chat_cancel_turn :: proc(t: ^testing.T, chat: ^Chat_Session) -> (entries: int, calls: int) {
	_test_accept(t, chat, "first")
	effect := _test_begin_request(t, chat)
	chat_effect_destroy(&effect)
	testing.expect(t, chat_session_feed_text(chat, chat_session_event_source(chat), "partial"))
	testing.expect(t, chat_session_request_cancel(chat))
	chat_session_retire_operation(chat)
	finish := chat_session_advance(chat)
	chat_persist_turn_end(chat, finish)
	chat_effect_destroy(&finish)

	loaded := _test_entries(t, chat)
	defer session.entries_destroy(loaded, context.allocator)
	return len(loaded), chat.calls_made
}

@(test)
test_a_turn_records_its_start_and_end :: proc(t: ^testing.T) {
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(t, &fixture, tool_loop_workspace(t))
	defer log_chat_end(t, &fixture)
	chat := &fixture.chat.chat

	log_chat_cancel_turn(t, chat)
	chat_cancel_reset()

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
	fixture: Log_Chat_Test
	context.logger = log_chat_begin(t, &fixture, tool_loop_workspace(t), .Debug)
	defer log_chat_end(t, &fixture)
	chat := &fixture.chat.chat

	_test_accept(t, chat, "first")
	effect := _test_begin_request(t, chat)
	stale := chat_session_event_source(chat)
	chat_effect_destroy(&effect)
	testing.expect(t, chat_session_request_cancel(chat))
	chat_session_retire_operation(chat)
	finish := chat_session_advance(chat)
	chat_persist_turn_end(chat, finish)
	chat_effect_destroy(&finish)
	chat_cancel_reset()

	// The retired operation's event is dropped, and that is what the record says.
	_test_accept(t, chat, "second")
	effect = _test_begin_request(t, chat)
	testing.expect(t, !chat_session_feed_text(chat, stale, "late"))
	chat_effect_destroy(&effect)
	chat_session_retire_operation(chat)

	text := log_chat_text(t, &fixture)
	defer delete(text, context.allocator)
	testing.expect(t, strings.contains(text, `"event":"agent.event_ignored"`), "the dropped event is recorded")
	testing.expect(t, strings.contains(text, `"reason":"superseded_turn"`), "the record names why it was refused")
}

@(test)
test_a_tool_call_is_recorded_from_call_to_result :: proc(t: ^testing.T) {
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
