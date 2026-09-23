#+test
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// ISOLATED_CHILD_VARIABLE marks a child test-binary run that owns its process.
// This helper stays in the root test package because the root and agent test
// binaries are separate packages. The agent copy additionally clears an inherited
// signal mask, a requirement that does not belong in the root helper. The parent
// spawns the child filtered to one test and checks it ran exactly once and passed.
ISOLATED_CHILD_VARIABLE :: "NABLA_ISOLATED_CHILD"

// test_isolate_guard serializes isolated children. The children are the
// suite's heaviest actors (real processes, loopback servers), so one runs at
// a time while the rest of the suite stays fully parallel.
test_isolate_guard: sync.Mutex

// test_isolate_process re-runs a process-global test in a child of this test
// binary, so parallel tests never share environment, the process-wide cancel
// token, or pid-keyed paths. procedure is the caller's #procedure. True means
// this is the child, so run the body; false means the parent already checked
// the child, so return.
test_isolate_process :: proc(t: ^testing.T, procedure: string) -> bool {
	if len(os.get_env(ISOLATED_CHILD_VARIABLE, context.temp_allocator)) > 0 {
		return true
	}

	name := strings.trim_space(procedure)
	filter := fmt.tprintf("-tests:%s", name)

	// The child is this test binary, not whatever PATH resolves argv[0] to: a runner
	// may name it without a path, and a directory on PATH can hold another program by
	// that name.
	executable, executable_err := os.get_executable_path(context.allocator)
	if executable_err != nil { testing.fail_now(t, "the test binary could not be located") }

	current_env, env_err := os.environ(context.temp_allocator)
	if env_err != nil {
		delete(executable, context.allocator)
		testing.fail_now(t, "the environment could not be read")
	}
	// Borrowed for the spawn only: temp memory is never deleted.
	child_env := make([dynamic]string, 0, len(current_env) + 1, context.temp_allocator)
	append(&child_env, ..current_env)
	append(&child_env, ISOLATED_CHILD_VARIABLE + "=1")

	sync.mutex_lock(&test_isolate_guard)
	state, child_out, child_err, exec_err := os.process_exec({command = {executable, filter}, env = child_env[:]}, context.allocator)
	// The guard is released before every fail path, so a failed child can
	// never wedge the tests behind it.
	spawned := exec_err == nil
	ran_once := spawned && (strings.contains(string(child_out), "Finished 1 test in ") || strings.contains(string(child_err), "Finished 1 test in "))
	passed := ran_once && state.exit_code == 0
	sync.mutex_unlock(&test_isolate_guard)
	if !spawned {
		test_isolate_release(executable, child_out, child_err)
		testing.fail_now(t, "the isolated child could not start")
	}

	// The filter names one test: anything else means the child did not run
	// what the parent claims it checked.
	if !passed {
		message := fmt.tprintf("the isolated run of %s failed (exit %d):\n%s\n%s", name, state.exit_code, string(child_out), string(child_err))
		test_isolate_release(executable, child_out, child_err)
		testing.fail_now(t, message)
	}
	test_isolate_release(executable, child_out, child_err)
	return false
}

// test_isolate_release frees what a parent spawned with. A failing check aborts the
// test without running deferred statements, so every path releases before it fails.
@(private)
test_isolate_release :: proc(executable: string, child_out, child_err: []byte) {
	delete(executable, context.allocator)
	delete(child_out)
	delete(child_err)
}
