package agent

import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

import "nabla:agent/journal"

// Job_Phase is where the owner believes a worker is. Only the owner reads or writes it.
Job_Phase :: enum u8 {
	Idle,
	Running,
	Retired,
	Abandoned,
}

// Job is the part every worker kind shares: one thread, the fact that it finished, and what
// the owner needs to stop waiting for it. A kind embeds it in its own record, recovers the
// record with container_of, and keeps its own inputs and results beside it.
//
// The worker writes its results into its kind's record and then `published`, and nothing
// after the wake. The owner reads those results only once `published` is set.
Job :: struct {
	kind:      journal.Job_Kind,
	// phase is owner-only.
	phase:     Job_Phase,
	// run is the worker body. It runs on the job's thread with `allocator` as its context
	// allocator, and it must not publish: job_main does, after run returns.
	run:       proc(job: ^Job),
	// allocator is the process heap, which is thread-safe. The record itself and every
	// payload the worker allocates or reads come from it, never from the session's
	// allocator: the owner and the worker would then share one allocator, and a worker that
	// ignores its stop outlives the allocator the session releases. The creator sets it
	// before it builds the payloads.
	allocator: mem.Allocator,
	thread:    ^thread.Thread,
	// published is atomic: the worker stores it as its last write.
	published: bool,
	// stop_at is the owner's first sight that this worker should have stopped. The patience
	// it is given to publish is measured from it.
	stop_at:   Maybe(time.Tick),
	// record carries the request, attempt, call, or subagent the worker serves, for the
	// journal's job.abandoned and job.reclaimed.
	record:    journal.Record,
}

// JOB_THREAD_NAMES is what each kind's thread is called in a debugger.
JOB_THREAD_NAMES := [journal.Job_Kind]string {
	.Tool             = "nabla-tool",
	.Provider_Attempt = "nabla-attempt",
	.Compaction       = "nabla-compaction",
	.Subagent         = "nabla-subagent",
}

// job_launch starts the job's thread and reports whether it started. The job's kind, run, and
// allocator are set and no worker is running. A job that was retired may be launched again.
//
// The handle comes from the process heap, because an abandoned job keeps it and the
// session's allocator may be released by then. The watched signals are blocked across the
// creation, since a thread inherits its creator's mask and a worker must never run the
// process signal handler; blocking inside the worker would leave a startup window. The mask
// is restored on every path.
@(require_results)
job_launch :: proc(job: ^Job) -> bool {
	assert(job.phase == .Idle || job.phase == .Retired)
	assert(job.run != nil && job.allocator.procedure != nil)
	job.published = false
	job.stop_at = nil

	previous := chat_signal_block_watched()
	defer chat_signal_restore(previous)
	worker: ^thread.Thread
	{
		context.allocator = os.heap_allocator()
		worker = thread.create(job_main, name = JOB_THREAD_NAMES[job.kind])
	}
	if worker == nil { return false }
	worker.data = job
	job.thread = worker
	job.phase = .Running
	thread.start(worker)
	return true
}

// job_main is the thread procedure of every job. After the `published` store it touches
// nothing but the global wake, because the owner may free the job the moment it sees it.
@(private = "file")
job_main :: proc(worker: ^thread.Thread) {
	job := cast(^Job)worker.data
	context.allocator = job.allocator
	job.run(job)
	sync.atomic_store(&job.published, true)
	owner_wake_signal()
}

// job_published reports whether the worker has finished and its results may be read. Owner
// only.
@(require_results)
job_published :: proc(job: ^Job) -> bool {
	return sync.atomic_load(&job.published)
}

// job_wait_published waits on the owner wake until the worker publishes or the deadline
// passes, and reports whether it published. A wake that is not this worker's, or a signal,
// only makes it look again. Owner only.
@(require_results)
job_wait_published :: proc(job: ^Job, deadline: time.Tick) -> bool {
	for {
		seen := owner_wake_seen()
		if job_published(job) { return true }
		if time.tick_diff(time.tick_now(), deadline) <= 0 { return false }
		owner_wake_wait(seen, deadline)
	}
}

// job_note_stop records when the owner first saw that a running worker should have stopped,
// which is where its patience is measured from. requested is the owner's own observation of
// the stop. Only the first sight counts, and only the owner's clock starts the patience.
job_note_stop :: proc(job: ^Job, requested: bool, now: time.Tick) {
	if !requested || job.phase != .Running || job.stop_at != nil { return }
	job.stop_at = now
}

// job_stop_deadline is when a stopped worker becomes overdue. The caller has already passed
// the stop to job_note_stop on a running job.
@(require_results)
job_stop_deadline :: proc(job: ^Job) -> time.Tick {
	at, stopped := job.stop_at.?
	assert(stopped)
	return time.tick_add(at, TOOL_JOBS_STOP_PATIENCE)
}

// job_overdue reports whether the worker has ignored its stop for the whole
// TOOL_JOBS_STOP_PATIENCE, which is as long as the owner waits for a worker that has not
// published. It is false while no stop was seen.
@(require_results)
job_overdue :: proc(job: ^Job, now: time.Tick) -> bool {
	at, stopped := job.stop_at.?
	if !stopped { return false }
	return time.tick_diff(at, now) >= TOOL_JOBS_STOP_PATIENCE
}

// job_retire ends a published job's thread. The worker has stored `published` and touches
// nothing else, so the join inside thread.destroy returns at once. The kind's record is
// still the owner's to read and release. Owner only.
job_retire :: proc(job: ^Job) {
	assert(job_published(job))
	thread.destroy(job.thread)
	job.thread = nil
	job.phase = .Retired
}

// job_abandon gives up on a worker that did not publish within its patience and records
// job.abandoned. The job, its payloads, and its thread handle stay allocated, because the
// worker may still reach them, and chat.abandoned keeps them until job_reclaim finds the
// worker published. The caller closes whatever the job left open and frees its own claims.
// Owner only.
job_abandon :: proc(chat: ^Chat_Session, job: ^Job) {
	job.phase = .Abandoned
	waited: time.Duration
	if at, stopped := job.stop_at.?; stopped { waited = time.tick_since(at) }
	chat_record_job_abandoned(chat, job.record, job.kind, waited)
	if _, append_error := append(&chat.abandoned, job); append_error != nil {
		// The list could not grow, so the job stays where it is with the worker that reaches it.
		chat_runtime_message(chat, .Error, "an abandoned job could not be listed for reclaim and is leaked")
	}
}

// job_reclaim releases every abandoned job whose worker has published since. The result is
// dropped, because the job's outcome was recorded when it was abandoned, and the thread is
// destroyed only now, when the join cannot block. A tool job is left alone while its batch's
// table still holds it, because the table reads the job until it is destroyed, and a provider
// attempt while the chain that abandoned it still holds it, because the chain's release is
// what moves the scratch arena into it. Owner only: it records each release in the session's
// journal.
job_reclaim :: proc(chat: ^Chat_Session) {
	jobs := &chat.abandoned
	for index := len(jobs) - 1; index >= 0; index -= 1 {
		job := jobs[index]
		if !job_published(job) { continue }
		if job.kind == .Tool && container_of(job, Tool_Job, "worker").tabled { continue }
		if job.kind == .Provider_Attempt && container_of(job, Chat_Request_Worker, "worker") == chat.chain.attempt { continue }
		thread.destroy(job.thread)
		job.thread = nil
		chat_record_job_reclaimed(chat, job.record, job.kind)
		switch job.kind {
		case .Compaction:
			chat_compact_job_destroy(container_of(job, Compact_Job, "job"))
		case .Tool:
			tool_job_release(container_of(job, Tool_Job, "worker"))
		case .Provider_Attempt:
			chat_request_worker_reclaim(container_of(job, Chat_Request_Worker, "worker"))
		case .Subagent:
			// Subagents keep their own list until they move onto Job, so none is listed here.
			assert(false, "an abandoned job of a kind that has not moved onto Job")
		}
		unordered_remove(jobs, index)
	}
}
