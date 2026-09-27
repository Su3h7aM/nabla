#+test
#+private file
package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import "nabla:agent/journal"

// SHELL_TEST_PROBE_VARIABLE is the variable the inheritance test exports for the
// command to read back.
SHELL_TEST_PROBE_VARIABLE :: "NABLA_SHELL_TEST_INHERITED"

// The shell tool runs the shell this process was started from, and under
// `odin test` that is whichever shell the developer happens to use. The suite
// runs POSIX commands, so it pins the portable shell once, here, for every test
// in the package rather than making each one depend on whose machine it runs on.
// The tests below set SHELL for their own cases.
@(init)
shell_test_pin_interpreter :: proc "contextless" () {
	_ = posix.setenv("SHELL", cstring(TOOL_SHELL_FALLBACK), true)
}

// shell_test_scratch makes a directory for the fixtures below.
shell_test_scratch :: proc(test: ^testing.T) -> string {
	directory, error := os.make_directory_temp("", "nabla-shell-test-*", context.allocator)
	if error != nil { testing.fail_now(test, "could not create a shell test directory") }
	return directory
}

// shell_test_program writes an executable file. A shell has to be a program, so
// the tests build programs out of files.
shell_test_program :: proc(test: ^testing.T, path, contents: string) {
	if os.write_entire_file(path, contents) != nil {
		testing.fail_now(test, "could not write a shell fixture")
	}
	if os.chmod(path, {.Read_User, .Write_User, .Execute_User}) != nil {
		testing.fail_now(test, "could not set shell fixture permissions")
	}
}

// shell_test_set_shell points SHELL at a path for one test.
shell_test_set_shell :: proc(test: ^testing.T, shell: string) {
	if os.set_env("SHELL", shell) != nil { testing.fail_now(test, "SHELL could not be set") }
}

// shell_test_clear_shell removes SHELL for one test.
shell_test_clear_shell :: proc(test: ^testing.T) {
	if !os.unset_env("SHELL") { testing.fail_now(test, "SHELL could not be removed") }
}

@(test)
test_shell_missing_child_is_not_a_successful_exit :: proc(test: ^testing.T) {
	child := Tool_Child {
		pid = 1,
	}
	testing.expect(test, tool_child_poll(&child), "a process that is not our child cannot be waited on")
	exited, _, waited := tool_child_reap(&child)
	testing.expect(test, !waited && !exited, "an absent child has no known exit status")
}

// The shell the environment names is the program that runs the command, invoked
// as `shell -c command`. A fixture stands in for a shell, so the test says
// nothing about which shells the machine has.
@(test)
test_shell_runs_the_environment_shell :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	scratch := shell_test_scratch(test)
	defer os.remove_all(scratch)
	defer delete(scratch, context.allocator)
	fixture := fmt.aprintf("%s/fixture-shell", scratch, allocator = context.temp_allocator)
	shell_test_program(test, fixture, "#!/bin/sh\necho ran-as-fixture-shell \"$@\"\n")
	shell_test_set_shell(test, fixture)
	defer shell_test_set_shell(test, TOOL_SHELL_FALLBACK)

	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	result := tool_run(test, &tool_test, TOOL_SHELL_NAME, `{"command":"printf payload"}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(
		test,
		strings.contains(result.content, `ran-as-fixture-shell -c printf payload`),
		"the environment's shell ran the command as `shell -c command`",
	)
}

// The command inherits the environment this process was started with, so the
// agent works with the same variables, the same tools, and the same versions the
// user does.
@(test)
test_shell_inherits_the_process_environment :: proc(test: ^testing.T) {
	if os.set_env(SHELL_TEST_PROBE_VARIABLE, "inherited-value") != nil {
		testing.fail_now(test, "the probe variable could not be set")
	}
	defer _ = os.unset_env(SHELL_TEST_PROBE_VARIABLE)

	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	seen := tool_run(test, &tool_test, TOOL_SHELL_NAME, `{"command":"printf %s \"$NABLA_SHELL_TEST_INHERITED\""}`)
	testing.expect_value(test, seen.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(seen.content, "stdout:\ninherited-value\n"), "a variable of the process environment reaches the command")

	// The search path is the user's own, which is what makes their tools reachable.
	path := tool_run(test, &tool_test, TOOL_SHELL_NAME, `{"command":"printf %s \"$PATH\""}`)
	expected := fmt.aprintf("stdout:\n%s\n", os.get_env("PATH", context.temp_allocator), allocator = context.temp_allocator)
	testing.expectf(test, strings.contains(path.content, expected), "the command searches the user's own path: %s", path.content)
}

// A shell that cannot be started never ran the command, so the portable shell
// still runs it. The environment names no shell at all when something other than
// a shell started the harness, and names a broken program when the user's shell
// was removed from under it.
@(test)
test_shell_falls_back_to_the_portable_shell :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	shell_test_clear_shell(test)
	defer shell_test_set_shell(test, TOOL_SHELL_FALLBACK)
	unnamed := tool_run(test, &tool_test, TOOL_SHELL_NAME, `{"command":"printf no-shell-named"}`)
	testing.expect_value(test, unnamed.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(unnamed.content, "stdout:\nno-shell-named\n"), "the command runs when the environment names no shell")

	scratch := shell_test_scratch(test)
	defer os.remove_all(scratch)
	defer delete(scratch, context.allocator)
	// An executable file without a shebang: the kernel refuses to start it, and
	// nothing about the file says so before the exec.
	broken := fmt.aprintf("%s/broken-shell", scratch, allocator = context.temp_allocator)
	shell_test_program(test, broken, "this file is not a program")
	shell_test_set_shell(test, broken)
	fallback := tool_run(test, &tool_test, TOOL_SHELL_NAME, `{"command":"printf broken-shell-ran"}`)
	testing.expect_value(test, fallback.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(fallback.content, "stdout:\nbroken-shell-ran\n"), "the command runs when the environment's shell cannot be started")
}

// The instructions the agent receives name the shell it will run, so it writes
// the syntax that shell understands instead of guessing. The name comes from the
// environment, and the portable shell is named when the environment names none.
@(test)
test_advertised_description_names_the_running_shell :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	scratch := shell_test_scratch(test)
	defer os.remove_all(scratch)
	defer delete(scratch, context.allocator)
	fixture := fmt.aprintf("%s/nabla-shell", scratch, allocator = context.temp_allocator)
	shell_test_program(test, fixture, "#!/bin/sh\nexit 0\n")
	shell_test_set_shell(test, fixture)
	defer shell_test_set_shell(test, TOOL_SHELL_FALLBACK)

	registry, registry_error := tool_registry_make(context.allocator)
	defer tool_registry_destroy(&registry)
	if !testing.expect_value(test, registry_error.kind, Tool_Registry_Error_Kind.None) { return }
	definition, found := tool_registry_find(&registry, TOOL_SHELL_NAME)
	if !testing.expect(test, found, "the shell tool is registered") { return }
	testing.expectf(
		test,
		strings.contains(definition.description, "nabla-shell"),
		"the description names the shell the tool will run: %s",
		definition.description,
	)

	shell_test_clear_shell(test)
	defer shell_test_set_shell(test, TOOL_SHELL_FALLBACK)
	fallback, fallback_error := tool_registry_make(context.allocator)
	defer tool_registry_destroy(&fallback)
	if !testing.expect_value(test, fallback_error.kind, Tool_Registry_Error_Kind.None) { return }
	unnamed, unnamed_found := tool_registry_find(&fallback, TOOL_SHELL_NAME)
	if !testing.expect(test, unnamed_found, "the shell tool is registered without a named shell") { return }
	testing.expectf(
		test,
		strings.contains(unnamed.description, TOOL_SHELL_FALLBACK),
		"the description names the fallback when the environment names no shell: %s",
		unnamed.description,
	)
}

// The spawn keeps tool commands out of the user's shell history without
// changing which configuration the shell reads: fish runs private because it
// is the one shell that consults history even for `shell -c`, and anything
// else runs unchanged.
@(test)
test_spawn_shell_flags_keep_history_private :: proc(test: ^testing.T) {
	first, second := tool_spawn_shell_flags("/usr/bin/fish")
	testing.expect_value(test, string(first), "--private")
	testing.expect(test, second == nil, "fish takes no second flag")

	first, second = tool_spawn_shell_flags("fish")
	testing.expect_value(test, string(first), "--private")

	first, second = tool_spawn_shell_flags("/bin/bash")
	testing.expect(test, first == nil && second == nil, "bash runs unchanged")

	first, second = tool_spawn_shell_flags(TOOL_SHELL_FALLBACK)
	testing.expect(test, first == nil && second == nil, "the portable shell runs unchanged")

	first, second = tool_spawn_shell_flags("/usr/bin/zsh")
	testing.expect(test, first == nil && second == nil, "zsh runs unchanged")
}

// A shell named fish receives --private on its command line, so the command
// runs with history disabled while the shell keeps its configuration. A
// fixture stands in for fish, so the test says nothing about whether the
// machine has fish.
@(test)
test_shell_runs_fish_without_touching_history :: proc(test: ^testing.T) {
	if !test_isolate_process(test, #procedure) { return }
	scratch := shell_test_scratch(test)
	defer os.remove_all(scratch)
	defer delete(scratch, context.allocator)
	fixture := fmt.aprintf("%s/fish", scratch, allocator = context.temp_allocator)
	shell_test_program(test, fixture, "#!/bin/sh\necho ran-as-fish \"$@\"\n")
	shell_test_set_shell(test, fixture)
	defer shell_test_set_shell(test, TOOL_SHELL_FALLBACK)

	tool_test: Tool_Test
	tool_test_begin(test, &tool_test)
	defer tool_test_end(test, &tool_test)

	result := tool_run(test, &tool_test, TOOL_SHELL_NAME, `{"command":"printf payload"}`)
	testing.expect_value(test, result.outcome, journal.Tool_Outcome.Success)
	testing.expect(test, strings.contains(result.content, `ran-as-fish --private -c printf payload`), "fish runs the command with history disabled")
}
