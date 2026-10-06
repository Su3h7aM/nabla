#+test
#+private file
package main

import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// A thread that never returns is what shutdown cannot wait for. These tests hold both
// halves of that: a thread that retires is released, and one that does not is reported
// instead of waited on. The thread is blocked on its own condition rather than leaked, so
// the test can release it and free it once the assertions are made.
//
// The state a worker waits on belongs to the test that started it. A package's tests run at
// once, so one shared state would be reset by whichever test started a worker next, while
// another test's worker was still waiting on the same condition.

Shutdown_Test_Thread :: struct {
	mu:      sync.Mutex,
	cond:    sync.Cond,
	started: bool,
	stop:    bool,
	// done is what the thread signals as its last action. It points at the event the code
	// under test waits on, which is this state's own unless the test names another.
	done:    ^sync.One_Shot_Event,
	own:     sync.One_Shot_Event,
}

// shutdown_test_state gives one test the state its worker waits on. It comes from the
// process heap rather than from the test's allocator: a worker that did not retire is still
// waiting on it when the test returns, and the allocator a test is given is recycled between
// tests. A worker that did retire releases it with the thread it was waiting for.
@(private)
shutdown_test_state :: proc() -> ^Shutdown_Test_Thread {
	state := new(Shutdown_Test_Thread, os.heap_allocator())
	state^ = {}
	state.done = &state.own
	return state
}

// shutdown_test_loop blocks until the test publishes its stop, which is what a tool stuck
// in a blocking syscall looks like from the thread that would join it. It allocates
// nothing, so a test releases it the same way whether or not it waited first.
shutdown_test_loop :: proc(worker: ^thread.Thread) {
	state := cast(^Shutdown_Test_Thread)worker.data
	defer sync.one_shot_event_signal(state.done)
	sync.mutex_lock(&state.mu)
	state.started = true
	sync.cond_broadcast(&state.cond)
	for !state.stop { sync.cond_wait(&state.cond, &state.mu) }
	sync.mutex_unlock(&state.mu)
}

// shutdown_test_start starts one thread and waits until it is blocked, so a test observes a
// thread that has entered its loop rather than one that has only been created.
shutdown_test_start :: proc(t: ^testing.T, state: ^Shutdown_Test_Thread, name: string) -> ^thread.Thread {
	worker := thread.create(shutdown_test_loop, name = name)
	if worker == nil { testing.fail_now(t, "the thread could not be created") }
	worker.data = state
	thread.start(worker)
	sync.mutex_lock(&state.mu)
	for !state.started { sync.cond_wait(&state.cond, &state.mu) }
	sync.mutex_unlock(&state.mu)
	return worker
}

// shutdown_test_release unblocks the thread and retires it, so every test ends with the
// thread freed rather than abandoned.
shutdown_test_release :: proc(t: ^testing.T, state: ^Shutdown_Test_Thread, worker: ^thread.Thread) {
	sync.mutex_lock(&state.mu)
	state.stop = true
	sync.cond_broadcast(&state.cond)
	sync.mutex_unlock(&state.mu)
	retired := join_retiring(worker, state.done, 2 * time.Second)
	testing.expect(t, retired, "a released thread should retire")
	if !retired { return }
	free(state, os.heap_allocator())
}

@(test)
test_join_retiring_gives_up_on_a_thread_that_never_returns :: proc(t: ^testing.T) {
	state := shutdown_test_state()
	worker := shutdown_test_start(t, state, "nabla-test-stuck")
	// The wait is short because the point is giving up, not the five seconds a real
	// shutdown grants a tool before it gives up on it.
	testing.expect(t, !join_retiring(worker, state.done, 20 * time.Millisecond), "a thread that never returns must not be reported as retired")
	// A thread that did not retire is left alone: thread.destroy would join it here.
	testing.expect(t, !thread.is_done(worker), "the thread should still be running")

	shutdown_test_release(t, state, worker)
}

@(test)
test_join_retiring_releases_a_thread_that_returns :: proc(t: ^testing.T) {
	state := shutdown_test_state()
	worker := shutdown_test_start(t, state, "nabla-test-returning")
	shutdown_test_release(t, state, worker)
}

// Shutdown gives up on a worker that does not retire instead of waiting for it. Nothing
// below that point is released: the worker can still reach the channel and the snapshot
// the rest of the release path would free.
@(test)
test_app_teardown_abandons_its_release_path_for_a_stuck_worker :: proc(t: ^testing.T) {
	app := App{}
	state := shutdown_test_state()
	state.done = &app.run.worker_done
	app.run.worker = shutdown_test_start(t, state, "nabla-test-worker")
	abandoned := app_teardown(&app, 20 * time.Millisecond)

	testing.expect(t, abandoned, "teardown must report that it left a worker running")
	testing.expect(t, app.run.worker != nil, "a worker that did not retire must not be claimed retired")

	// The teardown left the worker to the process; the test releases and retires it so the
	// suite holds no thread of its own.
	shutdown_test_release(t, state, app.run.worker)
	app.run.worker = nil
}
