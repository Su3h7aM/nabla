#+test
package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// A result is always kept whole. The model is shown at most a preview of it, cut further
// when the batch has little room left, followed by a notice naming the file that holds
// the complete output, which the model reads with the ordinary read tool.

// budget_test_fixture is a session whose workspace holds one file the read tool can
// return, so the result comes from the production tool path rather than from one built
// by hand.
@(private)
budget_test_fixture :: proc(test: ^testing.T, fixture: ^Chat_Test, workspace: ^string, lines, line_bytes: int) -> (chat: ^Chat_Session, content: string) {
	directory, directory_error := os.make_directory_temp("", "nabla-batch-budget-*", context.allocator)
	if directory_error != nil { testing.fail_now(test, "could not create a temporary workspace") }
	workspace^ = directory
	chat_test_begin(test, fixture, directory)

	builder := strings.builder_make(context.allocator)
	for _ in 0 ..< lines {
		for _ in 0 ..< line_bytes - 1 { strings.write_byte(&builder, 'a') }
		strings.write_byte(&builder, '\n')
	}
	content = strings.to_string(builder)

	path, path_error := os.join_path({directory, "large.txt"}, context.allocator)
	if path_error != nil { testing.fail_now(test, "could not build a path") }
	defer delete(path, context.allocator)
	if write_error := os.write_entire_file(path, transmute([]u8)content); write_error != nil {
		testing.fail_now(test, "could not write the fixture file")
	}
	chat = &fixture.chat
	chat.tools_enabled = true
	chat.last_estimate = 0
	chat.response_cost = 0
	return
}

// budget_test_result runs one read of the fixture file and returns the result the session
// recorded for it.
@(private)
budget_test_result :: proc(test: ^testing.T, chat: ^Chat_Session) -> Tool_Test_Result {
	_test_stage_call(test, chat, "call_large", `{"path":"large.txt"}`, TOOL_READ_NAME)
	testing.expect_value(test, chat_run_tools(chat, {}), 1)
	return tool_test_last_result(test, chat)
}

// budget_test_kept_file returns the complete output the notice in content names.
@(private)
budget_test_kept_file :: proc(test: ^testing.T, content: string) -> string {
	marker := "The complete output is in "
	start := strings.index(content, marker)
	if !testing.expect(test, start >= 0, "the preview must name the file that keeps the output") { return "" }
	rest := content[start + len(marker):]
	end := strings.index(rest, ";")
	if !testing.expect(test, end > 0, "the notice must end the path") { return "" }
	data, read_error := os.read_entire_file(rest[:end], context.temp_allocator)
	if !testing.expect(test, read_error == nil, "the kept output must be readable") { return "" }
	return string(data)
}

@(test)
test_a_large_result_is_previewed_and_kept_whole :: proc(test: ^testing.T) {
	fixture: Chat_Test
	workspace: string
	chat, content := budget_test_fixture(test, &fixture, &workspace, 2_000, 41)
	defer {
		chat_test_end(test, &fixture)
		os.remove_all(workspace)
		delete(workspace, context.allocator)
		delete(content)
	}
	chat_test_capacity(chat, 1_000_000, 4_096)

	result := budget_test_result(test, chat)
	testing.expect(test, len(result.content) <= TOOL_RESULT_PREVIEW_BYTES + 1024, "the model is shown a preview")
	testing.expect(test, strings.contains(result.content, TOOL_READ_NAME), "the notice names the tool that reads the rest")
	testing.expect(test, strings.contains(budget_test_kept_file(test, result.content), content), "the file keeps the complete output")
}

@(test)
test_a_cut_read_gives_the_offset_that_continues_the_file :: proc(test: ^testing.T) {
	fixture: Chat_Test
	workspace: string
	chat, content := budget_test_fixture(test, &fixture, &workspace, 2_000, 41)
	defer {
		chat_test_end(test, &fixture)
		os.remove_all(workspace)
		delete(workspace, context.allocator)
		delete(content)
	}
	chat_test_capacity(chat, 1_000_000, 4_096)

	result := budget_test_result(test, chat)
	notice_start := strings.index(result.content, "\n[output truncated")
	body_start := strings.index(result.content, "\n\n")
	if !testing.expect(test, notice_start > body_start && body_start >= 0, "the preview holds the header, the text, and the notice") { return }
	shown_lines := strings.count(result.content[body_start + 2:notice_start], "\n")
	next := fmt.tprintf("with offset %d ", 1 + shown_lines)
	testing.expect(test, strings.contains(result.content[notice_start:], next), "the notice gives the line that continues the file")
}

@(test)
test_a_result_the_batch_cannot_afford_is_still_kept_whole :: proc(test: ^testing.T) {
	fixture: Chat_Test
	workspace: string
	chat, content := budget_test_fixture(test, &fixture, &workspace, 200, 21)
	defer {
		chat_test_end(test, &fixture)
		os.remove_all(workspace)
		delete(workspace, context.allocator)
		delete(content)
	}
	// Almost no room is left, so the batch bound rather than the result's own size decides.
	chat_test_capacity(chat, 8_000, 4_096)
	chat.last_estimate = chat_capacity_input_ceiling(chat.capacity) - 256

	result := budget_test_result(test, chat)
	testing.expect(test, len(result.content) < 1024, "only the notice fits")
	testing.expect(test, strings.contains(budget_test_kept_file(test, result.content), content), "the file keeps the complete output")
}

@(test)
test_a_result_the_batch_can_afford_is_sent_whole :: proc(test: ^testing.T) {
	fixture: Chat_Test
	workspace: string
	chat, content := budget_test_fixture(test, &fixture, &workspace, 200, 2)
	defer {
		chat_test_end(test, &fixture)
		os.remove_all(workspace)
		delete(workspace, context.allocator)
		delete(content)
	}
	chat_test_capacity(chat, 8_000, 4_096)

	result := budget_test_result(test, chat)
	testing.expect(test, strings.contains(result.content, content), "a result with room is sent as it was observed")
	testing.expect(test, !strings.contains(result.content, "[output truncated"), "nothing is cut from it")
}
