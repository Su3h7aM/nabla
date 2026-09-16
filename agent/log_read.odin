package agent

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "nabla:agent/session"

// The callback borrows run_id and line until it returns. Returning false stops
// the read. Runs are grouped by directory modification time, not globally merged.
Log_Read_Visit :: #type proc(user_data: rawptr, run_id: string, line: string) -> bool

Log_Read_Summary :: struct {
	runs_scanned:    int,
	files_read:      int,
	// Counts directory, path allocation, and segment read failures.
	cannot_read:     int,
	records:         int,
	records_skipped: int,
	// A full directory page may omit runs in any order.
	runs_truncated:  bool,
	stopped:         bool,
}

// Only records carrying session_id are visited. Run-level framing is excluded.
// visit must be non-nil.
log_read_session :: proc(
	logs_root: string,
	session_id: session.Session_Id,
	user_data: rawptr,
	visit: Log_Read_Visit,
	allocator := context.allocator,
) -> Log_Read_Summary {
	summary: Log_Read_Summary
	runs_directory, joined := log_path_join(logs_root, LOG_RUNS_DIRECTORY, allocator)
	if !joined {
		summary.cannot_read += 1
		return summary
	}
	defer delete(runs_directory, allocator)

	entries, read_err := os.read_directory_by_path(runs_directory, LOG_RUNS_SCAN_LIMIT, allocator)
	if read_err != nil {
		summary.cannot_read += 1
		return summary
	}
	defer os.file_info_slice_delete(entries, allocator)
	if len(entries) == LOG_RUNS_SCAN_LIMIT { summary.runs_truncated = true }

	// Directory modification time is only an approximate run ordering: rotation
	// updates it too.
	runs := make([dynamic]Log_Read_Run, 0, len(entries), allocator)
	defer {
		for run in runs { delete(run.path, allocator) }
		delete(runs)
	}
	for entry in entries {
		if entry.type != .Directory || !log_run_id_valid(entry.name) { continue }
		path, path_joined := log_path_join(runs_directory, entry.name, allocator)
		if !path_joined {
			summary.cannot_read += 1
			continue
		}
		append(&runs, Log_Read_Run{path = path, run_id = entry.name, age = time.since(entry.modification_time)})
	}
	slice.sort_by(runs[:], proc(a, b: Log_Read_Run) -> bool { return a.age > b.age })

	for run in runs {
		summary.runs_scanned += 1
		if !log_read_run(&summary, run, session_id, user_data, visit, allocator) { break }
	}
	return summary
}

// path is owned; run_id borrows the directory entry.
@(private)
Log_Read_Run :: struct {
	path:   string,
	run_id: string,
	age:    time.Duration,
}

@(private)
log_read_run :: proc(
	summary: ^Log_Read_Summary,
	run: Log_Read_Run,
	session_id: session.Session_Id,
	user_data: rawptr,
	visit: Log_Read_Visit,
	allocator: mem.Allocator,
) -> bool {
	files, list_err := os.read_all_directory_by_path(run.path, allocator)
	if list_err != nil {
		summary.cannot_read += 1
		return true
	}
	defer os.file_info_slice_delete(files, allocator)

	segments := make([dynamic]string, 0, len(files), allocator)
	defer {
		for name in segments { delete(name, allocator) }
		delete(segments)
	}
	for file in files {
		if file.type != .Regular || !log_segment_name_valid(file.name) { continue }
		append(&segments, strings.clone(file.name, allocator))
	}
	// The writer zero-pads the number, so the name order is the write order.
	slice.sort_by(segments[:], proc(a, b: string) -> bool { return a < b })

	for name in segments {
		path, joined := log_path_join(run.path, name, allocator)
		if !joined {
			summary.cannot_read += 1
			continue
		}
		content, read_err := os.read_entire_file(path, allocator)
		delete(path, allocator)
		if read_err != nil {
			summary.cannot_read += 1
			continue
		}
		summary.files_read += 1
		text := string(content)
		start := 0
		for start < len(text) {
			end := strings.index_byte(text[start:], '\n')
			line: string
			if end < 0 {
				line = text[start:]
				start = len(text)
			} else {
				line = text[start:start + end]
				start += end + 1
			}
			if line == "" { continue }
			if !log_read_line(summary, run.run_id, line, session_id, user_data, visit, allocator) {
				delete(content, allocator)
				return false
			}
		}
		delete(content, allocator)
	}
	return true
}

// Parse rather than search: peer text can contain another session's id.
@(private)
log_read_line :: proc(
	summary: ^Log_Read_Summary,
	run_id: string,
	line: string,
	session_id: session.Session_Id,
	user_data: rawptr,
	visit: Log_Read_Visit,
	allocator: mem.Allocator,
) -> bool {
	value, parse_err := json.parse_string(line, allocator = allocator)
	if parse_err != .None {
		summary.records_skipped += 1
		return true
	}
	defer json.destroy_value(value, allocator)

	object, is_object := value.(json.Object)
	if !is_object {
		summary.records_skipped += 1
		return true
	}
	recorded, found := object["session_id"]
	if !found { return true }
	owner, is_text := recorded.(json.String)
	if !is_text || string(owner) != string(session_id) { return true }

	summary.records += 1
	if !visit(user_data, run_id, line) {
		summary.stopped = true
		return false
	}
	return true
}

@(private)
log_segment_name_valid :: proc(name: string) -> bool {
	if !strings.has_prefix(name, LOG_SEGMENT_PREFIX) || !strings.has_suffix(name, LOG_SEGMENT_SUFFIX) { return false }
	digits := name[len(LOG_SEGMENT_PREFIX):len(name) - len(LOG_SEGMENT_SUFFIX)]
	if len(digits) != 6 { return false }
	for index in 0 ..< len(digits) {
		if digits[index] < '0' || digits[index] > '9' { return false }
	}
	return true
}
