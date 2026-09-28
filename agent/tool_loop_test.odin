#+test
package agent

import "core:encoding/json"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

// item_object and item_string read the encoded request body the way a provider
// would: by item type, role, and field. They exist so a test can assert wire
// order and absence of duplicates instead of asserting a struct it built itself.
@(private)
item_object :: proc(test: ^testing.T, items: json.Array, index: int) -> json.Object {
	object, ok := items[index].(json.Object)
	testing.expect(test, ok)
	return object
}

@(private)
item_string :: proc(object: json.Object, key: string) -> string {
	value, present := object[key]
	if !present { return "" }
	text, ok := value.(json.String)
	if !ok { return "" }
	return string(text)
}

tool_loop_connection :: ai.Provider_Connection {
	API = .OpenAI_Chat_Completions,
}

tool_loop_workspace :: proc(test: ^testing.T) -> string {
	workspace, workspace_error := os.get_working_directory(context.temp_allocator)
	testing.expect(test, workspace_error == nil)
	testing.expect(test, workspace != "")
	return workspace
}

@(test)
test_effort_selection_validates_levels :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat

	// No levels configured: only the default is selectable.
	testing.expect(test, chat_session_set_effort(chat, ""))
	testing.expect(test, !chat_session_set_effort(chat, "high"))

	append(&chat.effort_levels, strings.clone("low", chat.allocator))
	append(&chat.effort_levels, strings.clone("high", chat.allocator))
	testing.expect(test, chat_session_set_effort(chat, "high"))
	testing.expect_value(test, chat.effort, "high")
	testing.expect(test, !chat_session_set_effort(chat, "max"))
	testing.expect_value(test, chat.effort, "high")
	testing.expect(test, chat_session_set_effort(chat, ""))
	testing.expect_value(test, chat.effort, "")
}

@(test)
test_build_request_carries_selected_effort :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	append(&chat.effort_levels, strings.clone("high", chat.allocator))
	testing.expect(test, chat_session_set_effort(chat, "high"))
	_test_accept(test, chat, "hi")

	first: virtual.Arena
	first_request := request_test_prepare(test, chat, tool_loop_connection, &first)
	testing.expect(test, first_request.request.Reasoning_Effort_Present)
	testing.expect_value(test, first_request.request.Reasoning_Effort, "high")
	virtual.arena_destroy(&first)

	testing.expect(test, chat_session_set_effort(chat, ""))
	second: virtual.Arena
	second_request := request_test_prepare(test, chat, tool_loop_connection, &second)
	testing.expect(test, !second_request.request.Reasoning_Effort_Present)
	virtual.arena_destroy(&second)
}

@(test)
test_admission_refuses_without_window_or_budget :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat

	message, admitted := chat_admission_check(chat, 100, {})
	testing.expect(test, !admitted)
	testing.expect(test, strings.contains(message, "context_window"))

	chat_test_capacity(chat, 500000)
	_, admitted = chat_admission_check(chat, 100, {})
	testing.expect(test, admitted)

	// 490000 estimated plus default reserve plus margin does not fit 500000.
	message, admitted = chat_admission_check(chat, 490000, {})
	testing.expect(test, !admitted)
	testing.expect(test, strings.contains(message, "exceeds"))
	_ = message
}

// A part that alone cannot fit is what a refusal names: no prompt is short enough to send
// a request whose tool schemas do not fit, and saying so is what tells the user what to
// change.
@(test)
test_admission_names_the_part_that_alone_does_not_fit :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 4_000)
	_test_accept(test, chat, "hi")
	chat.tools_enabled = true

	// A schema whose description alone is far larger than the window this session runs with.
	schema := strings.concatenate({"{\"description\":\"", strings.repeat("x", 40_000, context.temp_allocator), "\"}"}, context.temp_allocator)
	defer delete(schema, context.temp_allocator)
	// The registry owns what it is given, so this goes through the same call a real tool
	// does rather than appending by hand.
	added := tool_registry_add(&chat.tools, {name = "test_big", description = "big", input_schema = schema, execute = tool_policy_probe_execute})
	testing.expect_value(test, added, Tool_Registry_Error{})

	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, tool_loop_connection, &arena)
	defer virtual.arena_destroy(&arena)
	// The window cannot hold the schemas alone, and the estimate says so.
	testing.expect(test, preparation.sizes.tools > chat_capacity_input_ceiling(chat.capacity), "the fixture must not fit")
	message, admitted := chat_admission_check(chat, preparation.estimate, preparation.sizes)
	testing.expect(test, !admitted, "a request whose tools alone do not fit is refused")
	testing.expect(test, strings.contains(message, "tool schemas"), message)
}

@(test)
test_tool_calls_are_recorded_then_run :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "run printf ok")

	arguments := `{"command":"printf tool-ok","working_directory":null,"timeout_ms":null}`
	_test_stage_call(test, chat, "call_1", arguments)
	call := chat.pending_calls[0].call

	// The response proposed the call, the driver admitted and ran it, and the batch was
	// closed with the Results node that lists what it answered.
	count := chat_run_tools(chat, {})
	testing.expect_value(test, count, 1)
	testing.expect(test, chat_session_tools_done(chat, chat.active_turn_id, count), "the batch must answer every committed call")

	records := _test_records(test, chat, {.Tool_Proposed, .Tool_Admitted, .Tool_Completed})
	if !testing.expect_value(test, len(records), 3) { return }
	testing.expect_value(test, records[0].kind, journal.Record_Kind.Tool_Proposed)
	testing.expect_value(test, records[1].kind, journal.Record_Kind.Tool_Admitted)
	testing.expect_value(test, records[2].kind, journal.Record_Kind.Tool_Completed)
	for record in records { testing.expect_value(test, record.call, call) }
	testing.expect_value(test, string(records[0].body), arguments)

	admitted: journal.Tool_Admitted
	if decode_error := journal.payload_decode(records[1].data, &admitted, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "the admission could not be decoded") }
	testing.expect_value(test, admitted.tool, TOOL_SHELL_NAME)
	testing.expect_value(test, len(admitted.repairs), 0)
	testing.expect_value(test, string(records[1].body), arguments)

	completed: journal.Tool_Completed
	if decode_error := journal.payload_decode(records[2].data, &completed, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "the result could not be decoded") }
	testing.expect_value(test, completed.outcome, journal.TOOL_OUTCOME_NAMES[.Success])
	testing.expect(test, strings.contains(string(records[2].body), "tool-ok"), "the model-visible result should carry the output")

	ancestry, ancestry_error := journal.read_ancestry(chat.store, chat.session, chat.head, context.temp_allocator)
	if !testing.expect_value(test, ancestry_error, nil) { return }
	results: journal.Results
	found := false
	for node in ancestry {
		if node.kind != .Results { continue }
		if decode_error := journal.payload_decode(node.data, &results, context.temp_allocator);
		   decode_error != nil { testing.fail_now(test, "the results node could not be decoded") }
		found = true
	}
	if !testing.expect(test, found, "the answered batch commits a Results node") { return }
	if !testing.expect_value(test, len(results.calls), 1) { return }
	testing.expect_value(test, results.calls[0], call)
}

@(test)
test_malformed_arguments_are_rejected_and_replayed :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, chat.capacity.window if chat.capacity.window > 0 else CHAT_DEFAULT_CONTEXT_WINDOW, 4096)
	_test_accept(test, chat, "malformed call")

	// The provider delivered a call whose argument document never parses. Nothing
	// runs, the model is told what is wrong, and the turn keeps going.
	_test_stage_call(test, chat, "call_bad", `{"command":`)
	call := chat.pending_calls[0].call
	count := chat_run_tools(chat, {})
	testing.expect_value(test, count, 1)
	testing.expect(test, chat_session_tools_done(chat, chat.active_turn_id, count))
	testing.expect_value(test, chat.state, Chat_State.Preparing)

	// A call that never ran has a proposal and a result, and no admission.
	records := _test_records(test, chat, {.Tool_Proposed, .Tool_Admitted, .Tool_Completed})
	if !testing.expect_value(test, len(records), 2) { return }
	testing.expect_value(test, records[0].kind, journal.Record_Kind.Tool_Proposed)
	testing.expect_value(test, records[1].kind, journal.Record_Kind.Tool_Completed)
	for record in records { testing.expect_value(test, record.call, call) }
	completed: journal.Tool_Completed
	if decode_error := journal.payload_decode(records[1].data, &completed, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "the result could not be decoded") }
	testing.expect_value(test, completed.outcome, journal.TOOL_OUTCOME_NAMES[.Invalid_Arguments])
	testing.expect(test, strings.contains(string(records[1].body), `kind: syntax`), "the result names the defect")

	// The proposal must never reach the wire: an endpoint refuses tool arguments it
	// cannot parse, and one unsendable request would poison every request after it.
	// The refusal is spoken in the call's place, for every API family.
	apis := []ai.API_Kind{.OpenAI_Chat_Completions, .OpenAI_Responses, .Anthropic_Messages}
	for api in apis {
		arena: virtual.Arena
		preparation := request_test_prepare(test, chat, {API = api}, &arena)
		body, encode_error := ai.Provider_Encode_Request(preparation.request)
		if !testing.expectf(test, encode_error == ai.Provider_Request_Error.None, "%v must encode a refused call", api) {
			virtual.arena_destroy(&arena)
			continue
		}
		testing.expectf(test, !strings.contains(body, `{\"command\":`), "%v must not carry the malformed proposal", api)
		testing.expectf(test, strings.contains(body, "was refused before it ran"), "%v must say the call did not run", api)
		delete(body)
		virtual.arena_destroy(&arena)
	}
}

@(test)
test_a_repaired_call_is_replayed_as_what_ran :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "repaired call")

	// A raw newline inside the command string and a timeout written as a string: the repairs
	// escape one and write the other as an integer, so the proposal and what ran differ.
	_test_stage_call(test, chat, "call_fix", "{\"command\":\"echo hello\n\",\"working_directory\":null,\"timeout_ms\":\"5000\"}")
	count := chat_run_tools(chat, {})
	testing.expect_value(test, count, 1)
	testing.expect(test, chat_session_tools_done(chat, chat.active_turn_id, count))

	// What was admitted names the repairs and holds the arguments the call ran with.
	records := _test_records(test, chat, {.Tool_Admitted})
	if !testing.expect_value(test, len(records), 1) { return }
	admitted: journal.Tool_Admitted
	if decode_error := journal.payload_decode(records[0].data, &admitted, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "the admission could not be decoded") }
	testing.expect(test, len(admitted.repairs) > 0, "the repair is recorded with the call")
	testing.expect(test, strings.contains(string(records[0].body), `"timeout_ms":5000`), "the admission holds what ran")

	// The result the model reads names the repairs, since its replayed call shows only what ran.
	results := _test_records(test, chat, {.Tool_Completed})
	if !testing.expect_value(test, len(results), 1) { return }
	testing.expect(
		test,
		strings.contains(string(results[0].body), "\nrepaired: escaped_control_characters, integer_from_string"),
		"the result reports the repairs",
	)

	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, {API = .OpenAI_Chat_Completions}, &arena)
	defer virtual.arena_destroy(&arena)

	seen := false
	for message in preparation.wire {
		for call in message.Tool_Calls {
			seen = true
			testing.expect(test, !strings.contains(call.Arguments, "\n"), "the repair is what the provider is told")
			testing.expect(test, strings.contains(call.Arguments, "echo hello"), "the command survives the repair")
			testing.expect(test, strings.contains(call.Arguments, `"timeout_ms":5000`), call.Arguments)
		}
	}
	testing.expect(test, seen, "a repaired call is still replayed as a call")
}

@(test)
test_a_response_with_an_unparseable_call_is_not_replayed_verbatim :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, chat.capacity.window if chat.capacity.window > 0 else CHAT_DEFAULT_CONTEXT_WINDOW, 4096)
	_test_accept(test, chat, "native malformed call")

	// A native Responses output whose function_call carries arguments that do not
	// parse. Replaying it verbatim is exactly what the endpoint refuses, so the
	// response has to fall back to the projection, which can say it correctly.
	request := journal.next_request(chat.store)
	output := `[{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"trying"}]},{"type":"function_call","id":"fc_1","call_id":"call_v","name":"shell","arguments":"{\"command\": not_a_number}"}]`
	_test_response(test, chat, request, "trying", output)
	call := _test_propose(test, chat, "call_v", `{"command": not_a_number}`, TOOL_SHELL_NAME, request)
	content := `{"status":"invalid_arguments"}`
	chat_record(
		chat,
		{kind = .Tool_Completed, node = chat.response_node, request = request, call = call},
		journal.Tool_Completed{outcome = journal.TOOL_OUTCOME_NAMES[.Invalid_Arguments], detail = "the arguments are not valid JSON"},
		transmute([]u8)content,
	)
	_test_commit(test, chat)
	chat_node(chat, .Results, journal.Results{calls = []journal.Call_Id{call}})
	_test_commit(test, chat)

	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, {API = .OpenAI_Responses}, &arena)
	defer virtual.arena_destroy(&arena)
	body, encode_error := ai.Provider_Encode_Request(preparation.request)
	if !testing.expect_value(test, encode_error, ai.Provider_Request_Error.None) { return }
	defer delete(body)

	testing.expect(test, !strings.contains(body, `{\"command\":`), "the native record must not be replayed as it stands")
	testing.expect(test, strings.contains(body, "was refused before it ran"), "the refusal is spoken instead")
}

@(test)
test_a_record_that_contradicts_the_call_it_holds_is_not_replayed :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "record the endpoint cannot take back")

	// The endpoint's terminal record delivered an empty argument document while the call
	// that ran holds an object. Those bytes are not what ran, so the request that carries
	// them is refused, and the projection is what the endpoint reads back.
	request := journal.next_request(chat.store)
	output := `[{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"counting"}]},{"type":"function_call","id":"fc_1","call_id":"call_1","name":"shell","arguments":""}]`
	_test_response(test, chat, request, "counting", output)
	request_test_call(test, chat, request, "call_1", "{}", .Success, "fc_1")

	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, {API = .OpenAI_Responses}, &arena)
	defer virtual.arena_destroy(&arena)
	body, encode_error := ai.Provider_Encode_Request(preparation.request)
	if !testing.expect_value(test, encode_error, ai.Provider_Request_Error.None) { return }
	defer delete(body)
	value, parse_error := json.parse_string(body, .JSON, true, context.temp_allocator)
	if !testing.expect_value(test, parse_error, nil) { return }
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !testing.expect(test, object_ok) { return }
	input, input_ok := object["input"].(json.Array)
	if !testing.expect(test, input_ok) { return }

	// The call goes out as what it ran with, which is what the endpoint reads back.
	sent := ""
	for item in input {
		call, is_object := item.(json.Object)
		if !is_object || item_string(call, "type") != "function_call" { continue }
		sent = item_string(call, "arguments")
	}
	testing.expect_value(test, sent, "{}")
	testing.expect_value(test, preparation.replay_refused, 1)
}

@(test)
test_unknown_tool_is_reported_not_run :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "mystery")

	_test_stage_call(test, chat, "call_x", "{}", "nope")
	call := chat.pending_calls[0].call
	count := chat_run_tools(chat, {})
	testing.expect_value(test, count, 1)
	_ = chat_session_tools_done(chat, chat.active_turn_id, count)

	// The call never dispatched, so it has a result and no admission.
	records := _test_records(test, chat, {.Tool_Admitted, .Tool_Completed})
	if !testing.expect_value(test, len(records), 1) { return }
	testing.expect_value(test, records[0].call, call)
	completed: journal.Tool_Completed
	if decode_error := journal.payload_decode(records[0].data, &completed, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "the result could not be decoded") }
	testing.expect_value(test, completed.outcome, journal.TOOL_OUTCOME_NAMES[.Unavailable])
	testing.expect(test, strings.contains(string(records[0].body), "nope"), "the result names the tool the model asked for")
}

@(test)
test_tool_loop_has_no_request_budget :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "loop")
	chat.requests_made = 1000

	// Selecting the request is a read: it proposes the same work however many times
	// it is asked, and counts nothing. The driver's claim is what starts the turn and
	// counts the request.
	effect := chat_session_advance(chat)
	testing.expect_value(test, effect.kind, Chat_Effect_Kind.Start_Request)
	testing.expect_value(test, chat.requests_made, 1000)
	testing.expect_value(test, chat.state, Chat_State.Preparing)

	chat_session_begin_request(chat)
	testing.expect_value(test, chat.requests_made, 1001)
	testing.expect_value(test, chat.state, Chat_State.Requesting)
	// The claim is not repeatable: the proposal was taken, and claiming it again is
	// not another request.
	testing.expect(test, !chat_session_begin_request(chat))
	testing.expect_value(test, chat.requests_made, 1001)
}

// The boundary that settles input runs between the proposal and the claim, so the claim
// has to answer for the state it finds: a turn a boundary stopped claims no request, and
// no request is prepared from a turn that already failed.
@(test)
test_a_claim_refuses_a_turn_that_stopped_at_its_boundary :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "work")
	chat.requests_made = 3

	effect := chat_session_advance(chat)
	testing.expect_value(test, effect.kind, Chat_Effect_Kind.Start_Request)

	// What a boundary does when its own durable write fails.
	chat_session_fail_turn(chat, "the steering line could not be recorded")
	testing.expect_value(test, chat.state, Chat_State.Finalizing)
	testing.expect(test, !chat_session_begin_request(chat), "a stopped turn claims no request")
	testing.expect_value(test, chat.requests_made, 3)
}

@(test)
test_the_first_prompt_names_the_session :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat

	// The title is the first line of the prompt that opened the session.
	_test_accept(test, chat, "explain the parser\nand then stop")
	testing.expect_value(test, _test_session_title(test, chat), "explain the parser")

	_test_begin_request(test, chat)
	testing.expect(test, chat_session_feed_completion(chat, chat_session_event_source(chat)))
	_test_settle(test, chat)

	// A later turn leaves the name alone.
	_test_accept(test, chat, "something else")
	testing.expect_value(test, _test_session_title(test, chat), "explain the parser")
}

// A response commits its tool calls and then the harness dispatches them. A
// process that dies between those two writes leaves a call with neither a dispatch
// nor a result, and recovery has to close it, because the provider is
// sent the call and its result together.
@(test)
test_a_recovered_call_reaches_the_model_answered :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	chat_test_capacity(chat, 200_000)
	_test_accept(test, chat, "run it")
	request := journal.next_request(chat.store)
	_test_response(test, chat, request, "")
	_test_propose(test, chat, "call_1", `{"command":"echo hi"}`, TOOL_SHELL_NAME, request)

	recovery, recover_error := journal.recover(chat.store)
	if recover_error != nil { testing.fail_now(test, "recovery failed") }
	testing.expect_value(test, recovery.calls, 1)

	// The process is gone: the head the reopened session reads is the one recovery wrote.
	_, head, head_error := journal.session_head(chat.store, chat.session)
	if head_error != nil { testing.fail_now(test, "the session head could not be read") }
	chat.head = head

	arena: virtual.Arena
	preparation := request_test_prepare(test, chat, tool_loop_connection, &arena)
	defer virtual.arena_destroy(&arena)

	// The call and its recovered result are adjacent, and the result names the
	// call it answers.
	calls_opened := 0
	answered := false
	call_id := ""
	for message in preparation.wire {
		if len(message.Tool_Calls) > 0 {
			calls_opened += 1
			call_id = message.Tool_Calls[0].ID
		}
		if message.Role == .Tool && strings.contains(message.Content, "did not run") {
			answered = true
			testing.expect_value(test, message.Tool_Call_ID, call_id)
		}
	}
	testing.expect_value(test, calls_opened, 1)
	testing.expect(test, answered, "the recovered call must reach the model with a result")
}

@(test)
test_usage_is_collected_per_request :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat

	usages := make([dynamic]Chat_Request_Usage, 0, context.temp_allocator)
	defer delete(usages)
	chat_session_observe_usage(
		chat,
		&usages,
		ai.Provider_Usage_Event{Input_Tokens = 12000, Input_Tokens_Present = true, Cached_Input_Tokens = 9000, Cached_Input_Tokens_Present = true},
	)
	chat_session_observe_usage(
		chat,
		&usages,
		ai.Provider_Usage_Event{Input_Tokens = 12100, Input_Tokens_Present = true, Cached_Input_Tokens = 11800, Cached_Input_Tokens_Present = true},
	)
	testing.expect_value(test, len(usages), 2)
	testing.expect_value(test, usages[0].usage.Cached_Input_Tokens, 9000)
	testing.expect_value(test, usages[1].usage.Cached_Input_Tokens, 11800)

	// The last measurement wins, and a field the provider never sent stays absent.
	total := chat_request_usage(&usages, 0)
	if value, present := total.input_tokens.?; present {
		testing.expect_value(test, value, i64(12100))
	} else {
		testing.fail_now(test, "reported input tokens should be recorded")
	}
	if _, present := total.cache_write_tokens.?; present {
		testing.fail_now(test, "an unreported measurement must stay unknown")
	}
}

// A response the harness cannot use does not end the turn. Nothing runs, the
// harness records why, and the state machine goes back to preparing a request so
// the model can correct itself.
@(test)
test_unusable_response_becomes_feedback_not_a_failure :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "duplicate calls")
	_test_begin_request(test, chat)

	// Two calls under one id: the harness will not pick a winner, so it runs
	// neither and says so.
	source := chat_session_event_source(chat)
	calls := []ai.Provider_Tool_Call {
		{ID = "call_1", Name = TOOL_SHELL_NAME, Arguments = `{"command":"a","working_directory":null,"timeout_ms":null}`},
		{ID = "call_1", Name = TOOL_SHELL_NAME, Arguments = `{"command":"b","working_directory":null,"timeout_ms":null}`},
	}
	testing.expect_value(test, chat_session_feed_tool_calls(chat, source, calls), Chat_Notice.Duplicate_Call_ID)
	testing.expect(test, chat_session_note_notice(chat, source, .Duplicate_Call_ID))
	testing.expect_value(test, chat.state, Chat_State.Preparing)

	usages := make([dynamic]Chat_Request_Usage, 0, chat.allocator)
	defer delete(usages)
	request := journal.next_request(chat.store)
	chat_commit_response(chat, request, 1, {finish_reason = .Tool_Call}, &usages)
	chat_session_retire_operation(chat)

	// The prompt and the harness explanation; no call and no result were recorded.
	testing.expect_value(test, len(_test_records(test, chat, {.Tool_Proposed, .Tool_Admitted, .Tool_Completed})), 0)
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	projection := _test_projection(test, chat, &arena)
	if !testing.expect_value(test, len(projection.items), 2) { return }
	notice, is_notice := projection.items[1].payload.(Projected_User)
	if !testing.expect(test, is_notice, "the harness explanation is conversation") { return }
	testing.expect_value(test, notice.origin, journal.User_Origin.Harness)
	testing.expect(test, strings.contains(notice.text, "own id"), "the explanation names the defect")
	testing.expect_value(test, chat.state, Chat_State.Preparing)

	// The next step is another request, not a stop.
	next := chat_session_advance(chat)
	testing.expect_value(test, next.kind, Chat_Effect_Kind.Start_Request)
}

// A response the stream could not decode does not end the turn either. The failure
// becomes the same kind of harness feedback as an unusable response, and the chain
// commit that follows the failed attempt must not turn it back into a failure.
@(test)
test_an_unreadable_response_becomes_feedback_not_a_failure :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat.tools_enabled = true
	_test_accept(test, chat, "work that gets an unreadable response")
	_test_begin_request(test, chat)

	// The stream could not be decoded. The model can still be reached, so the turn
	// must not fail: the failure becomes feedback and the turn prepares again.
	source := chat_session_event_source(chat)
	message := strings.clone("malformed provider stream event", os.heap_allocator())
	event: Chat_Event = Chat_Failure_Event {
		source  = source,
		kind    = .Invalid_Data,
		message = message,
	}
	chat_session_apply(chat, &event)
	chat_event_destroy(&event, os.heap_allocator())
	testing.expect(test, !chat.active_failed, "an unreadable response must not fail the turn")
	testing.expect_value(test, chat.pending_notice, Chat_Notice.Unreadable_Response)
	testing.expect_value(test, chat.state, Chat_State.Preparing)

	// The chain ends the way a real attempt does: the operation failed, and the retry
	// policy stopped the chain. Its commit must keep the turn going.
	request := journal.next_request(chat.store)
	chat.chain.active = true
	chat.chain.stage = .Committing
	chat.chain.attempts = 1
	chat.chain.request = request
	chat.chain.source = source
	chat.chain.operation_error = {
		kind          = .Stream,
		failure_class = .Invalid_Output,
		detail        = strings.clone("malformed provider stream event", os.heap_allocator()),
	}
	chat.chain.decision = {
		action = .Stop,
		reason = .Terminal_Failure,
	}
	usages := make([dynamic]Chat_Request_Usage, 0, chat.allocator)
	defer delete(usages)
	chat_chain_commit(chat, &usages)
	testing.expect(test, !chat.active_failed, "the chain commit must not turn feedback into a failure")

	// The prompt and the harness explanation; no call and no result were recorded.
	testing.expect_value(test, len(_test_records(test, chat, {.Tool_Proposed, .Tool_Admitted, .Tool_Completed})), 0)
	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil { testing.fail_now(test, "arena initialization failed") }
	defer virtual.arena_destroy(&arena)
	projection := _test_projection(test, chat, &arena)
	if !testing.expect_value(test, len(projection.items), 2) { return }
	notice, is_notice := projection.items[1].payload.(Projected_User)
	if !testing.expect(test, is_notice, "the harness explanation is conversation") { return }
	testing.expect_value(test, notice.origin, journal.User_Origin.Harness)
	testing.expect(test, strings.contains(notice.text, "sending it again"), "the explanation names the correction")
	testing.expect_value(test, chat.state, Chat_State.Preparing)

	// The next step is another request, not a stop.
	next := chat_session_advance(chat)
	testing.expect_value(test, next.kind, Chat_Effect_Kind.Start_Request)
}

// --- result rendering ---------------------------------------------------------

// An unavailable tool never executes, and the result stored for it says so in the
// line the model reads.
@(test)
test_an_unavailable_tool_names_itself :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	result := tool_run(test, &tool_test, "no_such_tool", `{}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Unavailable)
	tool_test_result_matches(test, result.content, .Unavailable, `no tool named "no_such_tool" is available`)
}

// --- execution context policy -------------------------------------------------

// The probe records the policy and binding dispatch handed to one execution.
// The state is per definition: the executor's fixed signature reports through
// the definition's backend, so parallel tests never observe each other.
Tool_Policy_Probe :: struct {
	seen_timeout: time.Duration,
	seen_backend: rawptr,
}

// tool_policy_probe_execute is an adapter-style shared executor: one procedure
// serving many definitions, reading its bounds and binding from the context
// rather than from a definition it cannot name. A nil backend records nothing,
// so a definition that is never dispatched needs no probe.
tool_policy_probe_execute :: proc(tool_context: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	if probe := cast(^Tool_Policy_Probe)tool_context.backend; probe != nil {
		probe.seen_timeout = tool_context.timeout
		probe.seen_backend = tool_context.backend
	}
	return tool_result_success(tool_context, nil, "probed")
}

// One executor serves two definitions with different policies and bindings.
// Dispatch must hand each call the policy of the definition that was resolved
// for it, so no policy needs duplicating into adapter state.
@(test)
test_shared_executor_sees_definition_policy :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	probe_first: Tool_Policy_Probe
	probe_second: Tool_Policy_Probe
	first := Tool_Definition {
		name         = "test_probe_first",
		description  = "First probe tool.",
		input_schema = `{"type":"object"}`,
		timeout      = 5 * time.Second,
		execute      = tool_policy_probe_execute,
		backend      = &probe_first,
	}
	second := Tool_Definition {
		name         = "test_probe_second",
		description  = "Second probe tool.",
		input_schema = `{"type":"object"}`,
		timeout      = 30 * time.Second,
		execute      = tool_policy_probe_execute,
		backend      = &probe_second,
	}
	if !testing.expect_value(test, tool_registry_add(&tool_test.fixture.chat.tools, first).kind, Tool_Registry_Error_Kind.None) { return }
	if !testing.expect_value(test, tool_registry_add(&tool_test.fixture.chat.tools, second).kind, Tool_Registry_Error_Kind.None) { return }

	first_result := tool_run(test, &tool_test, "test_probe_first", `{}`)
	testing.expect_value(test, first_result.outcome, journal.Tool_Outcome.Success)
	testing.expect_value(test, probe_first.seen_timeout, 5 * time.Second)
	testing.expect(test, probe_first.seen_backend == &probe_first, "the first call carries the first binding")

	second_result := tool_run(test, &tool_test, "test_probe_second", `{}`)
	testing.expect_value(test, second_result.outcome, journal.Tool_Outcome.Success)
	testing.expect_value(test, probe_second.seen_timeout, 30 * time.Second)
	testing.expect(test, probe_second.seen_backend == &probe_second, "the second call carries the second binding")
}

// A batch that cannot answer every committed call must not leave the turn in a stage that would
// dispatch those calls again. The turn ends instead, and a cancellation keeps the status the
// user asked for.
@(test)
test_an_incomplete_tool_batch_ends_the_turn :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	_test_accept(test, chat, "run something")
	_test_stage_call(test, chat, "call_1", `{}`)
	chat.state = .Executing_Tools

	// The batch answered nothing, so the turn cannot continue to another request.
	testing.expect(test, !chat_session_tools_done(chat, chat.active_turn_id, 0))
	testing.expect_value(test, chat.state, Chat_State.Finalizing)
	testing.expect_value(test, chat.active_failed, true)

	// Cancellation is what the user asked for, so it keeps the status the turn ends with.
	chat.state = .Cancelling
	testing.expect(test, !chat_session_tools_done(chat, chat.active_turn_id, 0))
	testing.expect_value(test, chat.state, Chat_State.Cancelling)

	// The turn ends once, and the calls it could not answer are released rather than carried
	// into the next turn's batch.
	finish := chat_session_advance(chat)
	testing.expect_value(test, finish.kind, Chat_Effect_Kind.Turn_Finished)
	testing.expect_value(test, finish.status, Chat_Terminal_Status.Cancelled)
	chat_session_claim_finish(chat, finish)
	testing.expect(test, chat_persist_turn_end(chat, finish))
	testing.expect_value(test, chat.state, Chat_State.Idle)
	_test_accept(test, chat, "next")
	testing.expect_value(test, len(chat.pending_calls), 0)
}

// --- helpers ------------------------------------------------------------------

// _test_session_title is the name the journal holds for a session.
@(private)
_test_session_title :: proc(test: ^testing.T, chat: ^Chat_Session) -> string {
	record, found, read_error := journal.read_latest(chat.store, {session = chat.session, kinds = {.Session_Titled}}, context.temp_allocator)
	if read_error != nil { testing.fail_now(test, "the title could not be read") }
	if !testing.expect(test, found, "the session must be named") { return "" }
	title: journal.Session_Titled
	if decode_error := journal.payload_decode(record.data, &title, context.temp_allocator);
	   decode_error != nil { testing.fail_now(test, "the title could not be decoded") }
	return title.title
}
