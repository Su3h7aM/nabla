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
// all. LOG_RUN_ENTRY_LIMIT and LOG_RUN_DEPTH_LIMIT bound the work inside one run,
// which a run-count limit alone does not.
LOG_RUNS_SCAN_LIMIT :: 4096
LOG_RUN_ENTRY_LIMIT :: 4096
LOG_RUN_DEPTH_LIMIT :: 8

// Log_Closed_Run is one inactive run a cleanup pass may remove.
@(private)
Log_Closed_Run :: struct {
	path:     string, // owned by the pass that collected it
	age:      time.Duration,
	bytes:    i64,
	measured: bool,
}

// log_cleanup removes closed runs until the retention policy holds. The caller
// holds the cleanup lock: a run created during the scan would not be leased yet,
// and would be removed as an orphan.
@(private)
log_cleanup :: proc(logs_root: string, allocator: mem.Allocator) -> Log_Cleanup_Summary {
	return log_cleanup_within(logs_root, LOG_RETENTION_AGE, LOG_CLOSED_RUN_COUNT, LOG_CLOSED_RUN_BYTES, allocator)
}

// log_cleanup_within is log_cleanup with explicit bounds, which is what a test
// needs to reach a bound it cannot wait for.
@(private)
log_cleanup_within :: proc(logs_root: string, age: time.Duration, max_count: int, max_bytes: i64, allocator: mem.Allocator) -> Log_Cleanup_Summary {
	summary: Log_Cleanup_Summary
	runs_directory, okay := log_path_join(logs_root, LOG_RUNS_DIRECTORY, allocator)
	if !okay {
		summary.failed += 1
		return summary
	}
	defer delete(runs_directory, allocator)

	entries, read_err := os.read_directory_by_path(runs_directory, LOG_RUNS_SCAN_LIMIT, allocator)
	if read_err != nil {
		summary.failed += 1
		return summary
	}
	defer os.file_info_slice_delete(entries, allocator)
	if len(entries) == LOG_RUNS_SCAN_LIMIT { summary.scan_limited = true }

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
		if !join_okay {
			summary.failed += 1
			continue
		}
		lease_path, lease_okay := log_path_join(run_path, LOG_LEASE_NAME, allocator)
		if !lease_okay {
			delete(run_path, allocator)
			summary.failed += 1
			continue
		}
		// The pin, when the probe could take the lock, is held until this run has
		// been measured and removed, so no writer can claim it in between.
		pin, state := log_lock_pin(lease_path)
		delete(lease_path, allocator)
		switch state {
		case .Held:
			delete(run_path, allocator)
			continue
		case .Unknown:
			// Liveness could not be established, which is not the same as dead.
			delete(run_path, allocator)
			summary.failed += 1
			continue
		case .Free:
		}
		bytes, measured := log_run_bytes(run_path, allocator)
		if pin != nil { os.close(pin) }
		if !measured { summary.unmeasured += 1 }
		append(&closed, Log_Closed_Run{path = run_path, age = time.since(entry.modification_time), bytes = bytes, measured = measured})
	}

	// Oldest first, so one pass removes in the order the policy names and can stop
	// at the first run that is neither expired nor over a bound.
	slice.sort_by(closed[:], proc(a, b: Log_Closed_Run) -> bool { return a.age > b.age })

	total_bytes: i64
	for run in closed { total_bytes += run.bytes }

	// A run is only counted as removed once the directory is actually gone. A
	// failed deletion leaves the bound unsatisfied, so the pass keeps going rather
	// than reporting a target it did not reach.
	remaining := len(closed)
	for run in closed {
		if run.age <= age && remaining <= max_count && total_bytes <= max_bytes { break }
		if os.remove_all(run.path) == nil {
			summary.deleted += 1
			summary.freed_bytes += run.bytes
			total_bytes -= run.bytes
			remaining -= 1
		} else {
			summary.failed += 1
		}
	}
	return summary
}

// log_run_bytes is what a run directory occupies, which is what the byte bound
// measures. Capture payloads and sidecars live in subdirectories, so the walk is
// recursive. measured is false when some part of the run could not be counted: the
// byte bound is then an under-estimate and the pass says so rather than pretending
// it was exact.
@(private)
log_run_bytes :: proc(run_directory: string, allocator: mem.Allocator) -> (total: i64, measured: bool) {
	measured = true
	log_directory_bytes(run_directory, 0, allocator, &total, &measured)
	return
}

@(private)
log_directory_bytes :: proc(directory: string, depth: int, allocator: mem.Allocator, total: ^i64, measured: ^bool) {
	if depth > LOG_RUN_DEPTH_LIMIT {
		measured^ = false
		return
	}
	entries, read_err := os.read_directory_by_path(directory, LOG_RUN_ENTRY_LIMIT, allocator)
	if read_err != nil {
		measured^ = false
		return
	}
	defer os.file_info_slice_delete(entries, allocator)
	if len(entries) == LOG_RUN_ENTRY_LIMIT { measured^ = false }

	for entry in entries {
		#partial switch entry.type {
		case .Regular:
			total^ += entry.size
		case .Directory:
			path, join_okay := log_path_join(directory, entry.name, allocator)
			if !join_okay {
				measured^ = false
				continue
			}
			log_directory_bytes(path, depth + 1, allocator, total, measured)
			delete(path, allocator)
		case:
		// A symlink or a device is not followed and is not part of what the run
		// owns, so it is skipped rather than followed out of the run directory.
		}
	}
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
