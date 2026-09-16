package agent

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "nabla:agent/session"

// Reading a run is the other half of writing one. A session is selected by a field
// rather than by a file name, because one run may hold records for several sessions
// and one session may span many runs. What the reader could not read is counted and
// reported rather than passed over: a diagnostic view that silently omits evidence
// is worse than one that says it is incomplete.

// Log_Read_Visit is called once per record, in the order the records were written
// across runs. Returning false stops the read, which is what a caller that can no
// longer write its output does.
Log_Read_Visit :: #type proc(user_data: rawptr, run_id: string, line: string) -> bool

// Log_Read_Summary is what one read did, including the parts it could not do.
Log_Read_Summary :: struct {
	runs_scanned:    int,
	files_read:      int,
	files_skipped:   int,
	records:         int,
	records_skipped: int,
	// runs_truncated says the logs held more runs than one pass inspects, so older
	// records may exist beyond what was read.
	runs_truncated:  bool,
}

// log_read_session visits every record written for session_id under logs_root,
// oldest run first. Only records that carry the session are visited: a run-level
// record such as run.started belongs to the run rather than to the session, and its
// run directory is named on every record that does belong to the session.
log_read_session :: proc(
	logs_root: string,
	session_id: session.Session_Id,
	user_data: rawptr,
	visit: Log_Read_Visit,
	allocator := context.allocator,
) -> Log_Read_Summary {
	summary: Log_Read_Summary
	runs_directory, joined := log_path_join(logs_root, LOG_RUNS_DIRECTORY, allocator)
	if !joined { return summary }
	defer delete(runs_directory, allocator)

	entries, read_err := os.read_directory_by_path(runs_directory, LOG_RUNS_SCAN_LIMIT, allocator)
	if read_err != nil { return summary }
	defer os.file_info_slice_delete(entries, allocator)
	if len(entries) == LOG_RUNS_SCAN_LIMIT { summary.runs_truncated = true }

	// Oldest first. A run directory is created when its process starts, so its
	// modification time orders the runs without reading a record.
	runs := make([dynamic]Log_Read_Run, 0, len(entries), allocator)
	defer {
		for run in runs { delete(run.path, allocator) }
		delete(runs)
	}
	for entry in entries {
		if entry.type != .Directory || !log_run_id_valid(entry.name) { continue }
		path, path_joined := log_path_join(runs_directory, entry.name, allocator)
		if !path_joined { continue }
		append(&runs, Log_Read_Run{path = path, run_id = entry.name, age = time.since(entry.modification_time)})
	}
	slice.sort_by(runs[:], proc(a, b: Log_Read_Run) -> bool { return a.age > b.age })

	for run in runs {
		summary.runs_scanned += 1
		if !log_read_run(&summary, run, session_id, user_data, visit, allocator) { break }
	}
	return summary
}

// Log_Read_Run is one run directory a read may descend into. path is owned by the
// read; run_id borrows the directory entry it came from.
@(private)
Log_Read_Run :: struct {
	path:   string,
	run_id: string,
	age:    time.Duration,
}

// log_read_run visits the records of one run and reports whether the read should
// continue. A run whose directory cannot be listed is counted and skipped: one
// unreadable run is not a reason to give up on the others.
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
		summary.files_skipped += 1
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
			summary.files_skipped += 1
			continue
		}
		content, read_err := os.read_entire_file(path, allocator)
		delete(path, allocator)
		if read_err != nil {
			summary.files_skipped += 1
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

// log_read_line parses one record far enough to know whether it belongs to the
// session. The whole line is parsed rather than searched: a record may carry text a
// peer sent, and that text must not be able to name another session.
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
	return visit(user_data, run_id, line)
}

// log_segment_name_valid reports whether a file name is one the writer produces, so
// nothing else in a run directory is read as a record.
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
