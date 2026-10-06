#+test
package agent

import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

import "nabla:agent/journal"

job_test_noop :: proc(job: ^Job) {  }

Job_Test_Hold :: struct {
	using job: Job,
	release:   sync.Sema,
}

job_test_hold_run :: proc(job: ^Job) {
	hold := cast(^Job_Test_Hold)job
	_ = sync.sema_wait_with_timeout(&hold.release, COMPACT_HOLD_BOUND)
}

// Waiting for a worker returns false at the deadline while it runs and true once it has
// published, without the owner polling.
@(test)
test_waiting_for_a_job_ends_at_its_publication_or_its_deadline :: proc(test: ^testing.T) {
	hold := new(Job_Test_Hold, os.heap_allocator())
	hold.job = {
		kind      = .Compaction,
		run       = job_test_hold_run,
		allocator = os.heap_allocator(),
	}
	if !testing.expect(test, job_launch(hold), "the job could not be started") {
		free(hold, os.heap_allocator())
		return
	}
	published := job_wait_published(hold, time.tick_add(time.tick_now(), 20 * time.Millisecond))
	sync.sema_post(&hold.release)
	testing.expect(test, !published, "a worker that was still running was reported as published")

	testing.expect(test, job_wait_published(hold, time.tick_add(time.tick_now(), COMPACT_TEST_BOUND)), "the worker never published")
	job_retire(hold)
	free(hold, os.heap_allocator())
}

// A job that published is retired: its thread is joined and released, and the owner reads
// its results afterwards.
@(test)
test_a_published_job_retires :: proc(test: ^testing.T) {
	// The job is on the heap because a worker that never published would still reach it.
	job := new(Job, os.heap_allocator())
	job^ = {
		kind      = .Compaction,
		run       = job_test_noop,
		allocator = os.heap_allocator(),
	}
	if !testing.expect(test, job_launch(job), "the job could not be started") { return }
	testing.expect_value(test, job.phase, Job_Phase.Running)

	deadline := time.tick_add(time.tick_now(), COMPACT_TEST_BOUND)
	for !job_published(job) && time.tick_since(deadline) < 0 {
		seen := owner_wake_seen()
		if job_published(job) { break }
		owner_wake_wait(seen, deadline)
	}
	if !testing.expect(test, job_published(job), "the worker never published") { return }

	job_retire(job)
	testing.expect_value(test, job.phase, Job_Phase.Retired)
	testing.expect(test, job.thread == nil, "a retired job kept its thread")
	free(job, os.heap_allocator())
}

// A worker that ignores its stop is overdue only after the whole patience, is abandoned
// with its job retained, and is released with a record of it once it publishes.
@(test)
test_an_overdue_job_is_abandoned_and_reclaimed_after_it_publishes :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat

	hold := new(Compact_Summary_Hold, os.heap_allocator())
	released := false
	defer if !released { sync.sema_post(&hold.release) }
	job := &hold.compact
	job^ = {
		job = {kind = .Compaction, run = compact_summary_hold_run, allocator = os.heap_allocator()},
		request = journal.next_request(chat.store),
		attempts = 1,
	}
	job.record = {
		request = job.request,
		attempt = 1,
	}
	if !testing.expect(test, job_launch(job), "the job could not be started") { return }

	request := job.request
	now := time.tick_now()
	testing.expect(test, !job_overdue(job, now), "a job nobody stopped was overdue")
	job_note_stop(job, true, now)
	testing.expect(test, !job_overdue(job, now), "a job was overdue the moment it was stopped")
	testing.expect(test, job_overdue(job, time.tick_add(now, TOOL_JOBS_STOP_PATIENCE)), "a job was not overdue after the patience")

	job_abandon(chat, job)
	testing.expect_value(test, job.phase, Job_Phase.Abandoned)
	testing.expect_value(test, len(chat.abandoned), 1)
	job_reclaim(chat)
	testing.expect_value(test, len(chat.abandoned), 1)

	sync.sema_post(&hold.release)
	released = true
	deadline := time.tick_add(time.tick_now(), COMPACT_TEST_BOUND)
	for len(chat.abandoned) > 0 && time.tick_since(deadline) < 0 {
		seen := owner_wake_seen()
		job_reclaim(chat)
		if len(chat.abandoned) == 0 { break }
		owner_wake_wait(seen, deadline)
	}
	testing.expect_value(test, len(chat.abandoned), 0)

	_test_commit(test, chat)
	records := _test_records(test, chat, {.Job_Abandoned, .Job_Reclaimed})
	if !testing.expect_value(test, len(records), 2) { return }
	testing.expect_value(test, records[0].kind, journal.Record_Kind.Job_Abandoned)
	testing.expect_value(test, records[1].kind, journal.Record_Kind.Job_Reclaimed)
	for record in records { testing.expect_value(test, record.request, request) }
}
