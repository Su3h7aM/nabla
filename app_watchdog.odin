#+build linux
package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "nabla:agent"

// The front-end's event loop is the only thread that draws, reads keys, and honors a
// quit, and nothing it does is recorded while it runs. A loop that stops returning
// therefore leaves a run whose log simply ends: the worker's last record, then silence, a
// terminal frozen on its last frame, and a process that only a signal can end. This file
// closes that gap.
//
// The loop counts the phase it enters. A watcher thread compares that count against its
// own clock and, when the count has not moved for long enough that the loop cannot be
// working, records what the whole process is doing: the phase the loop entered, whether a
// turn is running, whether a terminal size was ever reported, and one record per thread
// with its state and what it waits on.
//
// The watcher takes no lock and reads no runtime state but its own atomics. A watchdog
// that needed the mutex a stall was holding would report nothing, which is the case it
// exists for. The stall is timed against the watcher's own clock, so the two threads share
// nothing a frozen loop could hold.

// Ui_Stage is the phase of one front-end iteration. The watcher reports the last phase the
// loop entered, so a stalled run says where the loop stopped rather than only that it did.
Ui_Stage :: enum u64 {
	Waiting, // blocked in the terminal read, which is where an idle loop lives
	Events, // applying the events that arrived
	Viewport, // asking the terminal for the size to draw into
	Runtime, // reading runtime state, which waits on the worker's mutex
	Drawing, // composing and presenting a frame
	Stop, // observing cancellation and the stop request
	Teardown, // stopping the runtime and joining the threads it started
}

ui_stage_names := [Ui_Stage]string {
	.Waiting  = "waiting",
	.Events   = "events",
	.Viewport = "viewport",
	.Runtime  = "runtime",
	.Drawing  = "drawing",
	.Stop     = "stop",
	.Teardown = "teardown",
}

// WATCHDOG_POLL is how often the watcher looks at the phase count. It is a scheduling
// delay, not a budget: nothing about the model or the context depends on it, and it only
// decides how precisely a stall is timed.
WATCHDOG_POLL :: 500 * time.Millisecond

// WATCHDOG_STALL is how long the phase count may stand still before the watcher reports.
// It sits above the longest wait the loop can make while healthy: a frame of even a large
// transcript is milliseconds of work, and the longest deliberate wait is the store's own
// five-second contention timeout, reached through the runtime mutex. A count this still
// means the loop is not running.
WATCHDOG_STALL :: 15 * time.Second

// WATCHDOG_REPEAT is how often a stall that is still going is reported again, so a run
// stuck for an hour says so more than once.
WATCHDOG_REPEAT :: 60 * time.Second

// WATCHDOG_THREADS bounds one report, which is a diagnostic bound rather than a policy: a
// run holds a handful of threads plus one per running call.
WATCHDOG_THREADS :: 32

// WATCHDOG_TASK_DIRECTORY is where Linux names a process's threads.
WATCHDOG_TASK_DIRECTORY :: "/proc/self/task"

Watchdog :: struct {
	worker:      ^thread.Thread,
	binding:     agent.Log_Binding, // borrowed from the setup, which outlives the worker
	beat:        u64, // atomic; how many phases the loop has entered
	stage:       u64, // atomic; the phase it entered last
	busy:        bool, // atomic; whether a turn was running
	viewport_ok: bool, // atomic; whether the terminal last reported a size
	stop:        bool, // atomic; set by the front-end before it joins
}

// watchdog_start runs the watcher for one front-end. False means the run continues without
// one: a missing watcher is a missing diagnostic, never a failed launch.
watchdog_start :: proc(app: ^App) -> bool {
	watchdog := &app.watchdog
	watchdog.binding = app.setup.log_binding
	watchdog.viewport_ok = true
	worker := thread.create(watchdog_worker, name = "nabla-tui-watchdog")
	if worker == nil { return false }
	worker.data = app
	watchdog.worker = worker
	thread.start(worker)
	return true
}

// watchdog_stop ends the watcher and joins it. It runs before the log is closed, so a
// report can never outlive the sink it writes to. False means the watcher did not retire,
// so the caller must not release the log binding it is writing through.
watchdog_stop :: proc(app: ^App, patience := SHUTDOWN_JOIN_PATIENCE) -> bool {
	watchdog := &app.watchdog
	if watchdog.worker == nil { return true }
	sync.atomic_store(&watchdog.stop, true)
	if !join_retiring(watchdog.worker, "nabla-tui-watchdog", patience) { return false }
	watchdog.worker = nil
	return true
}

// watchdog_stage publishes the phase the loop is entering. Every store is a plain atomic,
// so publishing never waits, and the count that moves with it is what the watcher times.
watchdog_stage :: proc(app: ^App, stage: Ui_Stage) {
	watchdog := &app.watchdog
	if watchdog.worker == nil { return }
	sync.atomic_store(&watchdog.stage, u64(stage))
	sync.atomic_add(&watchdog.beat, 1)
}

// watchdog_observe records what the phase just entered can see. It is published apart from
// the phase so a report carries the last observation even when the loop stalls before
// reaching the next one.
watchdog_observe :: proc(app: ^App, busy, viewport_ok: bool) {
	watchdog := &app.watchdog
	if watchdog.worker == nil { return }
	sync.atomic_store(&watchdog.busy, busy)
	sync.atomic_store(&watchdog.viewport_ok, viewport_ok)
}

// Watchdog_Verdict is what one sample of the phase count concluded.
Watchdog_Verdict :: enum {
	// Wait: the loop is entering phases, or a reported stall is not due to be
	// repeated yet.
	Wait,
	// Report: the count has stood still for WATCHDOG_STALL and nothing has been
	// reported for this stall yet.
	Report,
	// Resumed: the count moved after a report, so the stall it reported is over and
	// the next still count is a new one.
	Resumed,
}

// watchdog_verdict decides one sample from the two durations that matter and whether a
// stall is already being reported. It takes durations rather than reading a clock, so the
// decision is testable without sleeping and without a thread.
watchdog_verdict :: proc(still, since_report: time.Duration, reporting: bool) -> Watchdog_Verdict {
	if still < WATCHDOG_STALL {
		return .Resumed if reporting else .Wait
	}
	if !reporting { return .Report }
	return .Report if since_report >= WATCHDOG_REPEAT else .Wait
}

watchdog_worker :: proc(handle: ^thread.Thread) {
	app := cast(^App)handle.data
	watchdog := &app.watchdog
	context.logger = agent.log_logger(&watchdog.binding)

	seen := sync.atomic_load(&watchdog.beat)
	seen_at := time.tick_now()
	reporting := false
	reported_at: time.Tick
	stall_at: time.Tick // when the still count was first reported
	for !sync.atomic_load(&watchdog.stop) {
		now := time.tick_now()
		beat := sync.atomic_load(&watchdog.beat)
		if beat != seen {
			seen = beat
			seen_at = now
		}
		still := time.tick_diff(seen_at, now)
		since_report := time.tick_diff(reported_at, now) if reporting else 0

		switch watchdog_verdict(still, since_report, reporting) {
		case .Report:
			watchdog_report(watchdog, still)
			if !reporting { stall_at = now }
			reporting = true
			reported_at = now
		case .Resumed:
			watchdog_report_resumed(watchdog, time.tick_diff(stall_at, now))
			reporting = false
		case .Wait:
		}
		free_all(context.temp_allocator)
		time.sleep(WATCHDOG_POLL)
	}
}

// watchdog_report records the stalled loop and then the state of every thread. It reads its
// own atomics and /proc and nothing else.
//
// silent_ms is measured by the watcher, so it is the time since the watcher last saw the
// phase count move rather than the time the loop has been in the phase it names. The two
// agree to within one poll.
watchdog_report :: proc(watchdog: ^Watchdog, silent: time.Duration) {
	fields := [6]agent.Log_Field {
		{key = "silent_ms", value = agent.Log_Duration_Milliseconds(silent)},
		{key = "stage", value = ui_stage_names[Ui_Stage(sync.atomic_load(&watchdog.stage))]},
		{key = "turn_running", value = sync.atomic_load(&watchdog.busy)},
		{key = "viewport_ok", value = sync.atomic_load(&watchdog.viewport_ok)},
		{key = "cancel_requested", value = agent.chat_cancel_requested()},
		{key = "stop_requested", value = sync.atomic_load(&watchdog.stop)},
	}
	agent.log_emit(agent.Log_Record{level = .Warning, category = .Runtime, event = "ui.stalled", fields = fields[:]})
	watchdog_report_threads()
}

// watchdog_report_resumed closes a stall with how long it lasted, which is what separates a
// loop that was slow from one that was stuck.
watchdog_report_resumed :: proc(watchdog: ^Watchdog, stalled: time.Duration) {
	fields := [1]agent.Log_Field{{key = "stalled_ms", value = agent.Log_Duration_Milliseconds(stalled)}}
	agent.log_emit(agent.Log_Record{level = .Info, category = .Runtime, event = "ui.resumed", fields = fields[:]})
}

// watchdog_report_threads records every thread in the process with the state the kernel
// reports and what it waits on. Linux exposes no stack without privilege, so this is what a
// hung process can say about itself: which thread is running, and where each blocked thread
// is blocked.
watchdog_report_threads :: proc() {
	entries, directory_err := os.read_directory_by_path(WATCHDOG_TASK_DIRECTORY, WATCHDOG_THREADS, context.temp_allocator)
	if directory_err != nil { return }
	reported := 0
	for entry in entries {
		if reported >= WATCHDOG_THREADS { break }
		if entry.name == "" { continue }
		directory := strings.concatenate({WATCHDOG_TASK_DIRECTORY, "/", entry.name}, context.temp_allocator)
		fields := [4]agent.Log_Field {
			{key = "tid", value = entry.name},
			{key = "state", value = watchdog_thread_field(watchdog_read(directory, "stat"), 1)},
			{key = "waiting_on", value = watchdog_read(directory, "wchan")},
			{key = "syscall", value = watchdog_read(directory, "syscall")},
		}
		agent.log_emit(agent.Log_Record{level = .Warning, category = .Runtime, event = "runtime.thread", fields = fields[:]})
		reported += 1
	}
}

// watchdog_read reads one bounded file from a thread's directory. Every failure is
// silence: this is a diagnostic, and a thread that exited while it was listed is not an
// error worth a second record about.
watchdog_read :: proc(directory, name: string) -> string {
	path := strings.concatenate({directory, "/", name}, context.temp_allocator)
	data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil || len(data) == 0 { return "" }
	return strings.trim_space(string(data))
}

// watchdog_thread_field returns one space-separated field of a /proc/<tid>/stat line,
// counting from the first field after the command name. The command name is in parentheses
// and may itself contain spaces and parentheses, so counting starts after the last one.
watchdog_thread_field :: proc(stat: string, field: int) -> string {
	if field < 1 { return "" }
	close := strings.last_index_byte(stat, ')')
	if close < 0 { return "" }
	rest := stat[close + 1:]
	for rest != "" && rest[0] == ' ' { rest = rest[1:] }
	for _ in 1 ..< field {
		space := strings.index_byte(rest, ' ')
		if space < 0 { return "" }
		rest = rest[space + 1:]
		for rest != "" && rest[0] == ' ' { rest = rest[1:] }
	}
	if rest == "" { return "" }
	end := strings.index_byte(rest, ' ')
	if end < 0 { return rest }
	return rest[:end]
}
