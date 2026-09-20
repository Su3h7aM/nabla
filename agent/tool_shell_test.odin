#+test
#+private file
package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import "nabla:agent/session"

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
shell_test_scratch :: proc(t: ^testing.T) -> string {
	directory, err := os.make_directory_temp("", "nabla-shell-test-*", context.allocator)
	if err != nil { testing.fail_now(t, "could not create a shell test directory") }
	return directory
}

// shell_test_program writes an executable file. A shell has to be a program, so
// the tests build programs out of files.
shell_test_program :: proc(t: ^testing.T, path, contents: string) {
	if os.write_entire_file(path, contents) != nil {
		testing.fail_now(t, "could not write a shell fixture")
	}
	if os.chmod(path, {.Read_User, .Write_User, .Execute_User}) != nil {
		testing.fail_now(t, "could not set shell fixture permissions")
	}
}

// shell_test_set_shell points SHELL at a path for one test.
shell_test_set_shell :: proc(t: ^testing.T, shell: string) {
	if os.set_env("SHELL", shell) != nil { testing.fail_now(t, "SHELL could not be set") }
}

// shell_test_clear_shell removes SHELL for one test.
shell_test_clear_shell :: proc(t: ^testing.T) {
	if !os.unset_env("SHELL") { testing.fail_now(t, "SHELL could not be removed") }
}

// The shell the environment names is the program that runs the command, invoked
// as `shell -c command`. A fixture stands in for a shell, so the test says
// nothing about which shells the machine has.
@(test)
test_shell_runs_the_environment_shell :: proc(t: ^testing.T) {
	scratch := shell_test_scratch(t)
	defer os.remove_all(scratch)
	defer delete(scratch, context.allocator)
	fixture := fmt.aprintf("%s/fixture-shell", scratch, allocator = context.temp_allocator)
	shell_test_program(t, fixture, "#!/bin/sh\necho ran-as-fixture-shell \"$@\"\n")
	shell_test_set_shell(t, fixture)
	defer shell_test_set_shell(t, TOOL_SHELL_FALLBACK)

	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	result := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"printf payload"}`)
	testing.expect_value(t, result.outcome, session.Tool_Outcome.Success)
	testing.expect(
		t,
		strings.contains(result.content, `ran-as-fixture-shell -c printf payload`),
		"the environment's shell ran the command as `shell -c command`",
	)
}

// The command inherits the environment this process was started with, so the
// agent works with the same variables, the same tools, and the same versions the
// user does.
@(test)
test_shell_inherits_the_process_environment :: proc(t: ^testing.T) {
	if os.set_env(SHELL_TEST_PROBE_VARIABLE, "inherited-value") != nil {
		testing.fail_now(t, "the probe variable could not be set")
	}
	defer _ = os.unset_env(SHELL_TEST_PROBE_VARIABLE)

	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	seen := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"printf %s \"$NABLA_SHELL_TEST_INHERITED\""}`)
	testing.expect_value(t, seen.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(seen.content, `"stdout":"inherited-value"`), "a variable of the process environment reaches the command")

	// The search path is the user's own, which is what makes their tools reachable.
	path := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"printf %s \"$PATH\""}`)
	expected := fmt.aprintf(`"stdout":%q`, os.get_env("PATH", context.temp_allocator), allocator = context.temp_allocator)
	testing.expectf(t, strings.contains(path.content, expected), "the command searches the user's own path: %s", path.content)
}

// A shell that cannot be started never ran the command, so the portable shell
// still runs it. The environment names no shell at all when something other than
// a shell started the harness, and names a broken program when the user's shell
// was removed from under it.
@(test)
test_shell_falls_back_to_the_portable_shell :: proc(t: ^testing.T) {
	test: Tool_Test
	tool_test_begin(t, &test)
	defer tool_test_end(t, &test)

	shell_test_clear_shell(t)
	defer shell_test_set_shell(t, TOOL_SHELL_FALLBACK)
	unnamed := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"printf no-shell-named"}`)
	testing.expect_value(t, unnamed.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(unnamed.content, `"stdout":"no-shell-named"`), "the command runs when the environment names no shell")

	scratch := shell_test_scratch(t)
	defer os.remove_all(scratch)
	defer delete(scratch, context.allocator)
	// An executable file without a shebang: the kernel refuses to start it, and
	// nothing about the file says so before the exec.
	broken := fmt.aprintf("%s/broken-shell", scratch, allocator = context.temp_allocator)
	shell_test_program(t, broken, "this file is not a program")
	shell_test_set_shell(t, broken)
	fallback := tool_run(t, &test, TOOL_SHELL_NAME, `{"command":"printf broken-shell-ran"}`)
	testing.expect_value(t, fallback.outcome, session.Tool_Outcome.Success)
	testing.expect(t, strings.contains(fallback.content, `"stdout":"broken-shell-ran"`), "the command runs when the environment's shell cannot be started")
}

// The instructions the agent receives name the shell it will run, so it writes
// the syntax that shell understands instead of guessing. The name comes from the
// environment, and the portable shell is named when the environment names none.
@(test)
test_advertised_description_names_the_running_shell :: proc(t: ^testing.T) {
	scratch := shell_test_scratch(t)
	defer os.remove_all(scratch)
	defer delete(scratch, context.allocator)
	fixture := fmt.aprintf("%s/nabla-shell", scratch, allocator = context.temp_allocator)
	shell_test_program(t, fixture, "#!/bin/sh\nexit 0\n")
	shell_test_set_shell(t, fixture)
	defer shell_test_set_shell(t, TOOL_SHELL_FALLBACK)

	registry, registry_error := tool_registry_make(context.allocator)
	defer tool_registry_destroy(&registry)
	if !testing.expect_value(t, registry_error.kind, Tool_Registry_Error_Kind.None) { return }
	definition, found := tool_registry_find(&registry, TOOL_SHELL_NAME)
	if !testing.expect(t, found, "the shell tool is registered") { return }
	testing.expectf(
		t,
		strings.contains(definition.description, "nabla-shell"),
		"the description names the shell the tool will run: %s",
		definition.description,
	)

	shell_test_clear_shell(t)
	defer shell_test_set_shell(t, TOOL_SHELL_FALLBACK)
	fallback, fallback_error := tool_registry_make(context.allocator)
	defer tool_registry_destroy(&fallback)
	if !testing.expect_value(t, fallback_error.kind, Tool_Registry_Error_Kind.None) { return }
	unnamed, unnamed_found := tool_registry_find(&fallback, TOOL_SHELL_NAME)
	if !testing.expect(t, unnamed_found, "the shell tool is registered without a named shell") { return }
	testing.expectf(
		t,
		strings.contains(unnamed.description, TOOL_SHELL_FALLBACK),
		"the description names the fallback when the environment names no shell: %s",
		unnamed.description,
	)
}
