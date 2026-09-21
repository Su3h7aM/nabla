#+test
#+private file
package main

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

Shutdown_Test_Thread :: struct {
	mu:      sync.Mutex,
	cond:    sync.Cond,
	started: bool,
	stop:    bool,
}

@(private)
shutdown_test_thread: Shutdown_Test_Thread

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
shutdown_test_start :: proc(t: ^testing.T, name: string) -> ^thread.Thread {
	state := &shutdown_test_thread
	state^ = {}
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
shutdown_test_release :: proc(t: ^testing.T, worker: ^thread.Thread, name: string) {
	state := &shutdown_test_thread
	sync.mutex_lock(&state.mu)
	state.stop = true
	sync.cond_broadcast(&state.cond)
	sync.mutex_unlock(&state.mu)
	testing.expect(t, join_retiring(worker, name, 2 * time.Second), "a released thread should retire")
}

@(test)
test_join_retiring_reports_a_thread_that_never_returns :: proc(t: ^testing.T) {
	fixture: Log_Fixture
	log_fixture_open(t, &fixture)
	defer log_fixture_close(t, &fixture)
	context.logger = fixture.logger

	worker := shutdown_test_start(t, "nabla-test-stuck")
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

	shutdown_test_release(t, worker, "nabla-test-stuck")
}

@(test)
test_join_retiring_releases_a_thread_that_returns :: proc(t: ^testing.T) {
	worker := shutdown_test_start(t, "nabla-test-returning")
	shutdown_test_release(t, worker, "nabla-test-returning")
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
	app.run.worker = shutdown_test_start(t, "nabla-test-worker")
	app_teardown(&app, 20 * time.Millisecond)

	testing.expect(t, app.run.worker != nil, "a worker that did not retire must not be claimed retired")
	_ = agent.log_close(&fixture.sink)
	records := log_fixture_records(&fixture)
	if len(records) == 0 { testing.fail_now(t, "the report reached no log file") }
	testing.expectf(t, strings.contains(records, `"event":"runtime.thread_unretired"`), "no unretired-thread record: %s", records)
	testing.expectf(t, strings.contains(records, `"event":"runtime.teardown_abandoned"`), "the release path was abandoned silently: %s", records)

	// The teardown left the worker to the process; the test releases and retires it so the
	// suite holds no thread of its own.
	shutdown_test_release(t, app.run.worker, "nabla-test-worker")
	app.run.worker = nil
}
