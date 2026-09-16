#+test
package agent

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Retention is tested against real run directories: the point of the policy is
// which directories survive on disk, so a fake would test the fake.

log_test_root :: proc(t: ^testing.T) -> string {
	directory, directory_err := os.make_directory_temp("", "nabla-log-retention-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "could not create a temporary logs root") }
	return directory
}

log_test_root_remove :: proc(logs_root: string) {
	os.remove_all(logs_root)
	delete(logs_root, context.allocator)
}

// log_test_age_run sets a run directory's modification time, so a test can name
// which run is older instead of waiting for one to age.
log_test_age_run :: proc(t: ^testing.T, directory: string, age: time.Duration) {
	past := time.time_add(time.now(), -age)
	if change_err := os.change_times(directory, past, past); change_err != nil {
		testing.fail_now(t, "the run directory's time could not be set")
	}
}

// log_test_create_closed_runs opens and closes count runs and returns their
// directories, oldest first: each run is one minute older than the one after it.
// Minutes, because a test that is checking the count and byte bounds must not trip
// the age bound on the way. The result is released with log_test_free_directories.
log_test_create_closed_runs :: proc(t: ^testing.T, logs_root: string, count: int) -> []string {
	directories := make([]string, count, context.allocator)
	for index in 0 ..< count {
		log: Log
		if _, open_err := log_open(&log, {directory = logs_root, enabled = true, lowest = .Info}); open_err != nil {
			testing.fail_now(t, "a run could not be opened")
		}
		directories[index] = strings.clone(log.directory, context.allocator)
		// A record makes the run occupy bytes, which is what the byte bound measures.
		binding := Log_Binding {
			sink = &log,
		}
		context.logger = log_logger(&binding)
		log_emit({level = .Info, category = .Agent, event = "agent.transition"})
		_ = log_close(&log)
		log_test_age_run(t, directories[index], time.Duration(count - index) * time.Minute)
	}
	return directories
}

log_test_free_directories :: proc(directories: []string) {
	for directory in directories { delete(directory, context.allocator) }
	delete(directories, context.allocator)
}

// log_test_cleanup_lock is the lock a cleanup pass normally holds while it runs.
log_test_cleanup_lock :: proc(t: ^testing.T, logs_root: string) -> Log_Lock {
	path, okay := log_path_join(logs_root, LOG_CLEANUP_LOCK_NAME, context.temp_allocator)
	if !okay { testing.fail_now(t, "the cleanup lock path could not be built") }
	lock, lock_err := log_lock_acquire(path, false)
	if lock_err != nil { testing.fail_now(t, "the cleanup lock could not be taken") }
	return lock
}

// log_test_run_count counts the run directories under a logs root.
log_test_run_count :: proc(t: ^testing.T, logs_root: string) -> int {
	runs_directory, okay := log_path_join(logs_root, LOG_RUNS_DIRECTORY, context.temp_allocator)
	if !okay { testing.fail_now(t, "the runs directory path could not be built") }
	entries, read_err := os.read_all_directory_by_path(runs_directory, context.temp_allocator)
	if read_err != nil { return 0 }

	count := 0
	for entry in entries {
		if entry.type == .Directory && log_run_id_valid(entry.name) { count += 1 }
	}
	return count
}

@(test)
test_log_cleanup_keeps_a_leased_run :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)
	defer log_test_end(t, &fixture)

	live_directory := strings.clone(fixture.log.directory, context.allocator)
	defer delete(live_directory, context.allocator)
	// Age the live run past every bound: only its lease can keep it.
	log_test_age_run(t, live_directory, LOG_RETENTION_AGE * 2)

	second: Log
	if _, open_err := log_open(&second, {directory = fixture.directory, enabled = true, lowest = .Info}); open_err != nil {
		testing.fail_now(t, "the second log could not be opened")
	}
	defer _ = log_close(&second)

	testing.expect(t, os.exists(live_directory), "a leased run is never removed")
	testing.expect(t, os.exists(second.directory), "the run that just opened exists")
	testing.expect_value(t, log_test_run_count(t, fixture.directory), 2)
}

@(test)
test_log_cleanup_removes_an_expired_closed_run :: proc(t: ^testing.T) {
	fixture: Log_Test
	log_test_begin(t, &fixture)

	closed_directory := strings.clone(fixture.log.directory, context.allocator)
	defer delete(closed_directory, context.allocator)
	// A record gives the run bytes to free, which is what the summary reports.
	{
		binding := log_test_install(&fixture)
		context.logger = log_logger(&binding)
		log_emit({level = .Info, category = .Agent, event = "agent.transition"})
	}
	_ = log_close(&fixture.log)
	log_test_age_run(t, closed_directory, LOG_RETENTION_AGE * 2)

	reopened: Log
	cleanup, open_err := log_open(&reopened, {directory = fixture.directory, enabled = true, lowest = .Info})
	if open_err != nil {
		testing.fail_now(t, "the log could not be reopened")
	}
	defer _ = log_close(&reopened)
	testing.expect_value(t, cleanup.deleted, 1)

	testing.expect(t, !os.exists(closed_directory), "an expired closed run is removed")
	testing.expect(t, os.exists(reopened.directory), "the live run stays")

	// The pass is returned to the caller rather than written by log_open, so it can
	// be reported after run.started. The summary is what the caller records.
	testing.expect_value(t, cleanup.failed, 0)
	testing.expect(t, cleanup.freed_bytes > 0, "the pass counts the bytes it freed")

	log_test_end(t, &fixture)
}

@(test)
test_log_cleanup_removes_an_unleased_orphan :: proc(t: ^testing.T) {
	logs_root := log_test_root(t)
	defer log_test_root_remove(logs_root)

	// A run whose process died before it could take its lease. The lease file is
	// missing entirely, which is what a crash between the two leaves behind.
	runs_directory, _ := log_path_join(logs_root, LOG_RUNS_DIRECTORY, context.allocator)
	defer delete(runs_directory, context.allocator)
	if make_err := os.make_directory_all(runs_directory, LOG_DIRECTORY_PERMISSIONS); make_err != nil && make_err != .Exist {
		testing.fail_now(t, "the runs directory could not be created")
	}
	orphan, _ := log_path_join(runs_directory, "00112233445566778899aabbccddeeff", context.allocator)
	defer delete(orphan, context.allocator)
	if make_err := os.make_directory(orphan, LOG_DIRECTORY_PERMISSIONS); make_err != nil {
		testing.fail_now(t, "the orphan run directory could not be created")
	}
	log_test_age_run(t, orphan, LOG_RETENTION_AGE * 2)

	launch: Log
	if _, open_err := log_open(&launch, {directory = logs_root, enabled = true, lowest = .Info}); open_err != nil {
		testing.fail_now(t, "the log could not be opened")
	}
	defer _ = log_close(&launch)

	testing.expect(t, !os.exists(orphan), "an unleased run is removed")
	testing.expect_value(t, log_test_run_count(t, logs_root), 1)
}

@(test)
test_log_cleanup_bounds_what_closed_runs_hold :: proc(t: ^testing.T) {
	logs_root := log_test_root(t)
	defer log_test_root_remove(logs_root)

	directories := log_test_create_closed_runs(t, logs_root, 3)
	defer log_test_free_directories(directories)

	lock := log_test_cleanup_lock(t, logs_root)
	defer log_lock_release(&lock)

	// Room for one run, with nothing expired and no byte pressure: the newest stays.
	first_pass := log_cleanup_within(logs_root, time.Hour, 1, LOG_CLOSED_RUN_BYTES, context.allocator)
	testing.expect_value(t, first_pass.deleted, 2)
	testing.expect_value(t, first_pass.failed, 0)
	testing.expect(t, os.exists(directories[2]), "the newest run is kept")
	testing.expect(t, !os.exists(directories[1]), "an older run is removed")
	testing.expect(t, !os.exists(directories[0]), "the oldest run is removed")

	// Room for one byte: even the last run cannot fit.
	second_pass := log_cleanup_within(logs_root, time.Hour, LOG_CLOSED_RUN_COUNT, 1, context.allocator)
	testing.expect_value(t, second_pass.deleted, 1)
	testing.expect(t, second_pass.freed_bytes > 0, "the freed byte count should be positive")
	testing.expect_value(t, log_test_run_count(t, logs_root), 0)
}
