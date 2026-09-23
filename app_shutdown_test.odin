#+test
#+private file
package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "nabla:agent"

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
}

// shutdown_test_state gives one test the state its worker waits on. It comes from the
// process heap rather than from the test's allocator: a worker that did not retire is still
// waiting on it when the test returns, and the allocator a test is given is recycled between
// tests. A worker that did retire releases it with the thread it was waiting for.
@(private)
shutdown_test_state :: proc() -> ^Shutdown_Test_Thread {
	state := new(Shutdown_Test_Thread, os.heap_allocator())
	state^ = {}
	return state
}

// shutdown_test_loop blocks until the test publishes its stop, which is what a tool stuck
// in a blocking syscall looks like from the thread that would join it. It allocates
// nothing, so a test releases it the same way whether or not it waited first.
shutdown_test_loop :: proc(worker: ^thread.Thread) {
	state := cast(^Shutdown_Test_Thread)worker.data
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
shutdown_test_release :: proc(t: ^testing.T, state: ^Shutdown_Test_Thread, worker: ^thread.Thread, name: string) {
	sync.mutex_lock(&state.mu)
	state.stop = true
	sync.cond_broadcast(&state.cond)
	sync.mutex_unlock(&state.mu)
	retired := join_retiring(worker, name, 2 * time.Second)
	testing.expect(t, retired, "a released thread should retire")
	if !retired { return }
	free(state, os.heap_allocator())
}

@(test)
test_join_retiring_reports_a_thread_that_never_returns :: proc(t: ^testing.T) {
	fixture: Log_Fixture
	log_fixture_open(t, &fixture)
	defer log_fixture_close(t, &fixture)
	context.logger = fixture.logger

	state := shutdown_test_state()
	worker := shutdown_test_start(t, state, "nabla-test-stuck")
	// The wait is short because the point is the report, not the five seconds a real
	// shutdown grants a tool before it gives up on it.
	testing.expect(t, !join_retiring(worker, "nabla-test-stuck", 20 * time.Millisecond), "a thread that never returns must not be reported as retired")
	// A thread that did not retire is left alone: thread.destroy would join it here.
	testing.expect(t, !thread.is_done(worker), "the thread should still be running")
	_ = agent.log_close(&fixture.sink)
	records := log_fixture_records(&fixture)
	if len(records) == 0 { testing.fail_now(t, "the report reached no log file") }
	testing.expectf(t, strings.contains(records, `"event":"runtime.thread_unretired"`), "no unretired-thread record: %s", records)
	testing.expectf(t, strings.contains(records, `"thread":"nabla-test-stuck"`), "the record does not name the thread: %s", records)

	shutdown_test_release(t, state, worker, "nabla-test-stuck")
}

@(test)
test_join_retiring_releases_a_thread_that_returns :: proc(t: ^testing.T) {
	state := shutdown_test_state()
	worker := shutdown_test_start(t, state, "nabla-test-returning")
	shutdown_test_release(t, state, worker, "nabla-test-returning")
}

// Shutdown gives up on a worker that does not retire instead of waiting for it, and it says
// so in the record. Nothing below that point is released: the worker can still reach the
// channel and the log binding the rest of the release path would free.
@(test)
test_app_teardown_abandons_its_release_path_for_a_stuck_worker :: proc(t: ^testing.T) {
	fixture: Log_Fixture
	log_fixture_open(t, &fixture)
	defer log_fixture_close(t, &fixture)
	context.logger = fixture.logger

	app := App{}
	app.setup.log_binding = fixture.binding
	state := shutdown_test_state()
	app.run.worker = shutdown_test_start(t, state, "nabla-test-worker")
	app_teardown(&app, 20 * time.Millisecond)

	testing.expect(t, app.run.worker != nil, "a worker that did not retire must not be claimed retired")
	_ = agent.log_close(&fixture.sink)
	records := log_fixture_records(&fixture)
	if len(records) == 0 { testing.fail_now(t, "the report reached no log file") }
	testing.expectf(t, strings.contains(records, `"event":"runtime.thread_unretired"`), "no unretired-thread record: %s", records)
	testing.expectf(t, strings.contains(records, `"event":"runtime.teardown_abandoned"`), "the release path was abandoned silently: %s", records)

	// The teardown left the worker to the process; the test releases and retires it so the
	// suite holds no thread of its own.
	shutdown_test_release(t, state, app.run.worker, "nabla-test-worker")
	app.run.worker = nil
}
