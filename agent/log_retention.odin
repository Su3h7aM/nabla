package agent

import "core:mem"
import "core:os"
import "core:slice"
import "core:time"

// Runs are kept for a bounded time and a bounded amount of disk, and a run that is
// still alive is never touched. Liveness is a lock rather than a timestamp or a
// process id: the kernel releases the lock when the process dies, so a crashed run
// is collected and a running one is not.
//
// Every run holds a lease for its whole life, and a run is created while the
// logs-wide cleanup lock is held, so a cleaner can never meet a run directory that
// has no lease yet.

LOG_CLEANUP_LOCK_NAME :: "cleanup.lock"
LOG_LEASE_NAME :: "lease"

// LOG_RETENTION_AGE is how long a closed run is kept.
LOG_RETENTION_AGE :: 14 * 24 * time.Hour

// LOG_CLOSED_RUN_COUNT and LOG_CLOSED_RUN_BYTES bound what closed runs may occupy
// together. The oldest go first. A live run is never counted against them, so a
// machine running several processes can hold more than the byte bound.
LOG_CLOSED_RUN_COUNT :: 128
LOG_CLOSED_RUN_BYTES :: 256 * 1024 * 1024

// LOG_RUNS_SCAN_LIMIT bounds how many run directories one pass inspects, so a logs
// directory that has grown without bound cannot make a launch, or a reader, walk it
// all.
LOG_RUNS_SCAN_LIMIT :: 4096

// log_run_is_active reports whether a run still holds its lease. A run directory
// whose lease is missing or unlocked belongs to a process that is gone, so nothing
// alive owns it.
@(private)
log_run_is_active :: proc(run_directory: string, allocator: mem.Allocator) -> bool {
	lease_path, okay := log_path_join(run_directory, LOG_LEASE_NAME, allocator)
	if !okay { return false }
	defer delete(lease_path, allocator)

	file, open_err := os.open(lease_path)
	if open_err != nil { return false }
	// Closing the file releases the probe's own lock, which is why the lock is taken
	// and dropped rather than kept.
	defer os.close(file)
	return !log_lock_platform_acquire(file, false)
}

// Log_Closed_Run is one inactive run a cleanup pass may remove.
@(private)
Log_Closed_Run :: struct {
	path:  string, // owned by the pass that collected it
	age:   time.Duration,
	bytes: i64,
}

// log_cleanup removes closed runs until the retention policy holds and reports what
// it removed. The caller holds the cleanup lock: a run created during the scan
// would not be leased yet, and would be removed as an orphan.
@(private)
log_cleanup :: proc(logs_root: string, allocator: mem.Allocator) -> (deleted: int, freed_bytes: i64) {
	return log_cleanup_within(logs_root, LOG_RETENTION_AGE, LOG_CLOSED_RUN_COUNT, LOG_CLOSED_RUN_BYTES, allocator)
}

// log_cleanup_within is log_cleanup with explicit bounds, which is what a test
// needs to reach a bound it cannot wait for.
@(private)
log_cleanup_within :: proc(
	logs_root: string,
	age: time.Duration,
	max_count: int,
	max_bytes: i64,
	allocator: mem.Allocator,
) -> (
	deleted: int,
	freed_bytes: i64,
) {
	runs_directory, okay := log_path_join(logs_root, LOG_RUNS_DIRECTORY, allocator)
	if !okay { return }
	defer delete(runs_directory, allocator)

	entries, read_err := os.read_directory_by_path(runs_directory, LOG_RUNS_SCAN_LIMIT, allocator)
	if read_err != nil { return }
	defer os.file_info_slice_delete(entries, allocator)

	closed := make([dynamic]Log_Closed_Run, 0, len(entries), allocator)
	defer {
		for run in closed { delete(run.path, allocator) }
		delete(closed)
	}
	for entry in entries {
		// A symlink is not a directory here, so it is left alone rather than
		// followed out of the logs directory.
		if entry.type != .Directory || !log_run_id_valid(entry.name) { continue }
		run_path, join_okay := log_path_join(runs_directory, entry.name, allocator)
		if !join_okay { continue }
		if log_run_is_active(run_path, allocator) {
			delete(run_path, allocator)
			continue
		}
		append(&closed, Log_Closed_Run{path = run_path, age = time.since(entry.modification_time), bytes = log_run_bytes(run_path, allocator)})
	}

	// Oldest first, so one pass removes in the order the policy names and can stop
	// at the first run that is neither expired nor over a bound.
	slice.sort_by(closed[:], proc(a, b: Log_Closed_Run) -> bool { return a.age > b.age })

	total_bytes: i64
	for run in closed { total_bytes += run.bytes }

	remaining := len(closed)
	for run in closed {
		if run.age <= age && remaining <= max_count && total_bytes <= max_bytes { break }
		if os.remove_all(run.path) == nil {
			deleted += 1
			freed_bytes += run.bytes
			total_bytes -= run.bytes
		}
		remaining -= 1
	}
	return
}

// log_run_bytes is what a run directory occupies, which is what the byte bound
// measures. A directory that cannot be read counts as nothing rather than failing
// the pass.
@(private)
log_run_bytes :: proc(run_directory: string, allocator: mem.Allocator) -> i64 {
	entries, read_err := os.read_all_directory_by_path(run_directory, allocator)
	if read_err != nil { return 0 }
	defer os.file_info_slice_delete(entries, allocator)

	total: i64
	for entry in entries {
		if entry.type == .Regular { total += entry.size }
	}
	return total
}

// log_run_id_valid reports whether a directory name has the shape a run id has, so
// an unrelated entry in the runs directory is never touched.
@(private)
log_run_id_valid :: proc(name: string) -> bool {
	if len(name) != LOG_RUN_ID_LENGTH { return false }
	for index in 0 ..< len(name) {
		switch name[index] {
		case '0' ..= '9', 'a' ..= 'f':
		case:
			return false
		}
	}
	return true
}
