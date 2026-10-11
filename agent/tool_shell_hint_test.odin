#+test
#+private file
package agent

import "core:fmt"
import "core:strings"
import "core:testing"

import "nabla:agent/journal"

// The detector reads only the command text, so these cases never leave the process. An
// empty name means the command runs no file-search CLI.
@(test)
test_shell_search_command_names_the_file_search_cli :: proc(test: ^testing.T) {
	cases := []struct {
		command: string,
		name:    string,
	} {
		{"rg pattern", "rg"},
		{"/usr/bin/rg pattern", "rg"},
		{`'rg' pattern`, "rg"},
		{"VAR=1 grep pattern", "grep"},
		{"sudo -u alice fd pattern", "fd"},
		{"git -C dir grep pattern", "git grep"},
		{"cd d && rg x", "rg"},
		{"(grep x)", "grep"},
		{"time rg x", "rg"},
		{`FOO="x\" y" rg p`, "rg"},
		{"printf x | grep a", ""},
		{"echo grep", ""},
		{"findmnt /", ""},
		{"git commit -m grep", ""},
		{`echo "a; rg x"`, ""},
		{"command -v rg", ""},
		{"ls # a; rg x", ""},
		{"echo hi # c\nrg x", "rg"},
	}
	for item in cases {
		name, found := tool_shell_search_command(item.command)
		testing.expectf(test, name == item.name && found == (item.name != ""), "%q names %q, got %q (%v)", item.command, item.name, name, found)
	}
}

// A result that ran a file-search CLI carries one hint after its output sections. tool_run
// returns what the journal stored, so the hint is asserted on the record the model reads.
@(test)
test_shell_result_names_the_file_search_cli_it_ran :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	workspace := tool_test_workspace(&tool_test)
	haystack := strings.concatenate({workspace, "/hay.txt"}, context.temp_allocator)
	defer delete(haystack, context.temp_allocator)
	if !tool_write_file(test, haystack, "hello\nworld\n") { return }

	arguments := fmt.tprintf(`{{"command":"grep hello '%s'"}}`, haystack)
	result := tool_run(test, &tool_test, TOOL_SHELL_NAME, arguments)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(result.content, "stdout:\nhello\n"), "the command's own output is unchanged")
	hint := "hint: this command ran grep; prefer the native find and grep tools for file search"
	stdout_at := strings.index(result.content, "stdout:")
	hint_at := strings.index(result.content, hint)
	testing.expect(test, stdout_at >= 0 && hint_at > stdout_at, "the hint follows the output sections")
}

// A call that never executed carries no hint, even when its command is a file-search CLI.
@(test)
test_shell_refused_call_carries_no_hint :: proc(test: ^testing.T) {
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	refused := tool_run(test, &tool_test, TOOL_SHELL_NAME, `{"command":"grep hello","working_directory":"no-such-dir"}`)
	testing.expect_value(test, refused.outcome, journal.Tool_Outcome.Invalid_Arguments)
	testing.expect(test, !strings.contains(refused.content, "hint:"), "a call that never executed carries no hint")
}
