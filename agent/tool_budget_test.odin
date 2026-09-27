#+test
package agent

import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent/session"

// A result is always kept whole. The model is shown at most a preview of it, cut further
// when the batch has little room left, followed by a notice naming the file that holds
// the complete output, which the model reads with the ordinary read tool.

// budget_test_fixture is a session whose workspace holds one file the read tool can
// return, so the result comes from the production tool path rather than from one built
// by hand.
@(private)
budget_test_fixture :: proc(t: ^testing.T, fixture: ^Chat_Test, workspace: ^string, lines, line_bytes: int) -> (chat: ^Chat_Session, content: string) {
	directory, directory_err := os.make_directory_temp("", "nabla-batch-budget-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "could not create a temporary workspace") }
	workspace^ = directory
	chat_test_begin(t, fixture, directory)

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
	chat = &fixture.chat
	chat.tools_enabled = true
	chat.last_estimate = 0
	chat.response_cost = 0
	return
}

// budget_test_result runs one read of the fixture file and returns the recorded result.
@(private)
budget_test_result :: proc(t: ^testing.T, chat: ^Chat_Session) -> (result: session.Tool_Result_Entry, entries: []session.Entry) {
	_test_stage_call(t, chat, "call_large", `{"path":"large.txt"}`, TOOL_READ_NAME)
	testing.expect_value(t, chat_run_tools(chat, {}), 1)
	entries = _test_entries(t, chat)
	for entry in entries {
		if payload, is_result := entry.payload.(session.Tool_Result_Entry); is_result { result = payload }
	}
	return
}

// budget_test_kept_file returns the complete output the notice in content names.
@(private)
budget_test_kept_file :: proc(t: ^testing.T, content: string) -> string {
	marker := "The complete output is in "
	start := strings.index(content, marker)
	if !testing.expect(t, start >= 0, "the preview must name the file that keeps the output") { return "" }
	rest := content[start + len(marker):]
	end := strings.index(rest, ";")
	if !testing.expect(t, end > 0, "the notice must end the path") { return "" }
	data, read_error := os.read_entire_file(rest[:end], context.temp_allocator)
	if !testing.expect(t, read_error == nil, "the kept output must be readable") { return "" }
	return string(data)
}

@(test)
test_a_large_result_is_previewed_and_kept_whole :: proc(t: ^testing.T) {
	fixture: Chat_Test
	workspace: string
	chat, content := budget_test_fixture(t, &fixture, &workspace, 2_000, 41)
	defer {
		chat_test_end(t, &fixture)
		os.remove_all(workspace)
		delete(workspace, context.allocator)
		delete(content)
	}
	chat_test_capacity(chat, 1_000_000, 4_096)

	result, entries := budget_test_result(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	testing.expect(t, len(result.content) <= TOOL_RESULT_PREVIEW_BYTES + 1024, "the model is shown a preview")
	testing.expect(t, strings.contains(result.content, TOOL_READ_NAME), "the notice names the tool that reads the rest")
	testing.expect(t, strings.contains(budget_test_kept_file(t, result.content), content), "the file keeps the complete output")
}

@(test)
test_a_result_the_batch_cannot_afford_is_still_kept_whole :: proc(t: ^testing.T) {
	fixture: Chat_Test
	workspace: string
	chat, content := budget_test_fixture(t, &fixture, &workspace, 200, 21)
	defer {
		chat_test_end(t, &fixture)
		os.remove_all(workspace)
		delete(workspace, context.allocator)
		delete(content)
	}
	// Almost no room is left, so the batch bound rather than the result's own size decides.
	chat_test_capacity(chat, 8_000, 4_096)
	chat.last_estimate = chat_capacity_input_ceiling(chat.capacity) - 256

	result, entries := budget_test_result(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	testing.expect(t, len(result.content) < 1024, "only the notice fits")
	testing.expect(t, strings.contains(budget_test_kept_file(t, result.content), content), "the file keeps the complete output")
}

@(test)
test_a_result_the_batch_can_afford_is_sent_whole :: proc(t: ^testing.T) {
	fixture: Chat_Test
	workspace: string
	chat, content := budget_test_fixture(t, &fixture, &workspace, 200, 2)
	defer {
		chat_test_end(t, &fixture)
		os.remove_all(workspace)
		delete(workspace, context.allocator)
		delete(content)
	}
	chat_test_capacity(chat, 8_000, 4_096)

	result, entries := budget_test_result(t, chat)
	defer session.entries_destroy(entries, context.allocator)
	testing.expect(t, strings.contains(result.content, content), "a result with room is sent as it was observed")
	testing.expect(t, !strings.contains(result.content, "[output truncated"), "nothing is cut from it")
}
