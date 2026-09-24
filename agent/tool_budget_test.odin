#+test
package agent

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/session"

// A result the batch cannot afford is kept whole in the record and replaced by a
// handle in the model's context. The handle names the call, and the read tool takes
// it from there, so the output the model was not shown is still reachable.

@(test)
test_the_handle_reserve_covers_the_real_handle :: proc(t: ^testing.T) {
	// The budget reserves a constant, so the constant has to hold for every handle.
	// This is what keeps it from drifting away from the text it stands for.
	for seq in ([]session.Seq{1, 999, 123_456}) {
		handle := tool_result_handle(.Success, i64(seq), 48 * 1024, context.temp_allocator)
		cost := tool_result_cost(handle)
		testing.expectf(t, cost <= TOOL_RESULT_HANDLE_TOKENS, "a handle for call %d costs %d tokens", seq, cost)
	}
}

@(test)
test_a_result_is_charged_what_it_costs_and_a_later_result_is_reserved_for :: proc(t: ^testing.T) {
	text := strings.repeat("x", 1000) or_else ""
	defer delete(text)
	cost := tool_result_cost(text)

	// With only this result to place, it is charged what it costs.
	roomy := Tool_Budget {
		remaining = cost,
		pending   = 1,
	}
	testing.expect(t, tool_budget_take(&roomy, text))
	testing.expect_value(t, roomy.remaining, 0)

	// One token short of the content plus a handle, and the same result no longer
	// fits: the handle for the result still to come is what the budget held back.
	reserving := Tool_Budget {
		remaining = cost + TOOL_RESULT_HANDLE_TOKENS - 1,
		pending   = 2,
	}
	testing.expect(t, !tool_budget_take(&reserving, text), "the later result's handle is reserved")
	testing.expect_value(t, reserving.remaining, cost - 1)
}

// budget_test_fixture is a session whose workspace holds one file the read tool can
// return, so the result comes from the production tool path rather than from a
// hand-built envelope.
@(private)
budget_test_fixture :: proc(t: ^testing.T, fixture: ^Chat_Test, workspace: ^string, lines, line_bytes: int) -> (chat: ^Chat_Session, content: string) {
	directory, directory_err := os.make_directory_temp("", "nabla-batch-budget-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "could not create a temporary workspace") }
	workspace^ = directory
	chat_test_begin(t, fixture, directory)

	// Many short lines rather than one long one: a single line is cut by the read
	// tool's own byte bound, and this test is about the batch bound instead.
	builder := strings.builder_make(context.allocator)
	for _ in 0 ..< lines {
		for _ in 0 ..< line_bytes - 1 { strings.write_byte(&builder, 'a') }
		strings.write_byte(&builder, '\n')
	}
	content = strings.to_string(builder)

	path, path_err := os.join_path({directory, "large.txt"}, context.allocator)
	if path_err != nil { testing.fail_now(t, "could not build a path") }
	defer delete(path, context.allocator)
	if write_err := os.write_entire_file(path, transmute([]u8)content); write_err != nil {
		testing.fail_now(t, "could not write the fixture file")
	}
	return &fixture.chat, content
}

@(test)
test_a_result_the_batch_cannot_afford_is_kept_and_referenced :: proc(t: ^testing.T) {
	fixture: Chat_Test
	workspace: string
	// Read returns the whole file, so the result is one the harness would otherwise
	// send in full.
	chat, content := budget_test_fixture(t, &fixture, &workspace, 2_000, 21)
	defer {
		chat_test_end(t, &fixture)
		os.remove_all(workspace)
		delete(workspace, context.allocator)
		delete(content)
	}
	chat.tools_enabled = true
	// Almost no room left for results, so the batch bound and not the result's own
	// size is what decides its fate.
	chat_test_capacity(chat, 8_000, 4_096)
	chat.last_estimate = chat_capacity_input_ceiling(chat.capacity) - 256
	chat.response_cost = 0

	_test_stage_call(t, chat, "call_large", `{"path":"large.txt"}`, TOOL_READ_NAME)
	testing.expect_value(t, chat_run_tools(chat, {}), 1)

	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	result: session.Tool_Result_Entry
	call_seq: session.Seq
	for entry in entries {
		payload, is_result := entry.payload.(session.Tool_Result_Entry)
		if !is_result { continue }
		result = payload
		if related, present := entry.related_seq.?; present { call_seq = related }
	}
	testing.expect(t, result.spilled, "a result with no room must be kept rather than sent")
	testing.expect(t, len(result.content) > 40_000, "the whole observed result is still in the record")

	// The request that follows carries a handle instead of the content, and the handle
	// names the call the read tool takes.
	prep, prep_err := chat_prepare(chat, tool_loop_connection, chat.allocator)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)
	handles := 0
	for message in prep.request.Messages {
		if message.Role != .Tool { continue }
		if !strings.contains(message.Content, TOOL_RESULT_READ_NAME) { continue }
		handles += 1
		testing.expect(t, strings.contains(message.Content, fmt.tprintf("%d", call_seq)), "the handle names the call to read")
		testing.expect(t, len(message.Content) < 1024, "the handle is small beside the output it replaces")
	}
	testing.expect_value(t, handles, 1)

	// The output is reachable: the read tool returns a page of what was kept.
	reader := Result_Reader {
		store      = chat.store,
		session_id = chat.id,
	}
	ctx := Tool_Context {
		call_id   = "call_read",
		workspace = workspace,
		allocator = context.allocator,
		results   = &reader,
	}
	// The arguments a model would send, built rather than parsed from a format string,
	// so the test exercises the tool rather than the JSON parser.
	arguments := make(json.Object, context.temp_allocator)
	defer delete(arguments)
	arguments["call_seq"] = json.Integer(call_seq)
	page := tool_result_read_execute(&ctx, arguments)
	defer tool_result_destroy(&page)
	testing.expect_value(t, page.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(page.content, "aaaa"), "the kept output is what the read returns")
}

@(test)
test_a_result_the_batch_can_afford_is_sent_whole :: proc(t: ^testing.T) {
	fixture: Chat_Test
	workspace: string
	chat, content := budget_test_fixture(t, &fixture, &workspace, 2_000, 2)
	defer {
		chat_test_end(t, &fixture)
		os.remove_all(workspace)
		delete(workspace, context.allocator)
		delete(content)
	}
	chat.tools_enabled = true
	chat_test_capacity(chat, 8_000, 4_096)
	chat.last_estimate = 0
	chat.response_cost = 0

	_test_stage_call(t, chat, "call_small", `{"path":"large.txt"}`, TOOL_READ_NAME)
	testing.expect_value(t, chat_run_tools(chat, {}), 1)

	entries := _test_entries(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	for entry in entries {
		payload, is_result := entry.payload.(session.Tool_Result_Entry)
		if !is_result { continue }
		testing.expect(t, !payload.spilled, "a result with room is sent as it was observed")
	}
}
