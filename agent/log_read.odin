package agent

import "core:encoding/json"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "nabla:agent/session"

// The reader walks the runs it can find and visits the records of one session as
// they were written, so a caller can pipe them somewhere else. It parses each line
// rather than searching it: a record may carry text a peer sent, and that text must
// not be able to name another session.
//
// Estimated runs are ordered by directory modification time, which is approximate:
// rotation updates it too. A record's own run id is checked against the directory it
// was found in, and a record this reader cannot interpret is counted rather than
// guessed at.

// Log_Read_Selector narrows what the reader visits. A zero selector visits
// everything the session owns: zero severity is Debug, which is the lowest.
Log_Read_Selector :: struct {
	// level is the lowest severity to visit.
	level:      log.Level,
	// request_no, when set, visits only one logical request.
	request_no: Maybe(session.Request_No),
}

// Log_Read_Summary is what one read did and what it could not do. cannot_read counts
// runs, files, and paths that could not be read at all; records_skipped counts lines
// that are not records; records_unsupported counts records written by a format
// version this reader does not implement; records_foreign counts records whose run
// id does not match the directory they were found in; gaps counts removed segments
// the writer reported; partial_tails counts final lines that were never completed.
Log_Read_Summary :: struct {
	runs_scanned:        int,
	files_read:          int,
	cannot_read:         int,
	records:             int,
	records_skipped:     int,
	records_unsupported: int,
	records_foreign:     int,
	gaps:                int,
	partial_tails:       int,
	// A full directory page may omit runs in any order.
	runs_truncated:      bool,
	stopped:             bool,
}

// Log_Read_Visit is called with one record as it was written. run_id and line are
// borrowed until it returns. Returning false stops the read.
Log_Read_Visit :: #type proc(user_data: rawptr, run_id: string, line: string) -> bool

// Log_Read_Segment is one segment file of a run, with the number its name carries
// so the read order is the write order rather than the name order.
@(private)
Log_Read_Segment :: struct {
	name:   string,
	number: u64,
}

log_read_session :: proc(
	logs_root: string,
	session_id: session.Session_Id,
	user_data: rawptr,
	visit: Log_Read_Visit,
	selector: Log_Read_Selector = {},
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
	runs, runs_err := make([dynamic]Log_Read_Run, 0, len(entries), allocator)
	if runs_err != nil {
		summary.cannot_read += 1
		return summary
	}
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
		if !log_read_run(&summary, run, session_id, selector, user_data, visit, allocator) { break }
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
	selector: Log_Read_Selector,
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

	segments, segments_err := make([dynamic]Log_Read_Segment, 0, len(files), allocator)
	if segments_err != nil {
		summary.cannot_read += 1
		return true
	}
	defer {
		for segment in segments { delete(segment.name, allocator) }
		delete(segments)
	}
	for file in files {
		// Only a regular file whose name is one the writer produces is read: a
		// symlink, a lease, or anything else a peer left there is not a segment.
		if file.type != .Regular { continue }
		number, is_segment := log_segment_name_number(file.name)
		if !is_segment { continue }
		append(&segments, Log_Read_Segment{name = strings.clone(file.name, allocator) or_else "", number = number})
	}
	slice.sort_by(segments[:], proc(a, b: Log_Read_Segment) -> bool { return a.number < b.number })

	for segment in segments {
		path, joined := log_path_join(run.path, segment.name, allocator)
		if !joined {
			summary.cannot_read += 1
			continue
		}
		content, read_okay := log_read_segment(path, allocator)
		delete(path, allocator)
		if !read_okay {
			summary.cannot_read += 1
			continue
		}
		summary.files_read += 1
		if !log_read_segment_lines(summary, run.run_id, content, session_id, selector, user_data, visit, allocator) {
			delete(content, allocator)
			return false
		}
		delete(content, allocator)
	}
	return true
}

// log_read_segment reads one segment, bounded by what the writer may legally
// produce, and returns the bytes that existed when the read started. An active
// writer appends, so anything past that point is a tail this read must not treat as
// a record: it is ignored rather than reported as malformed.
@(private)
log_read_segment :: proc(path: string, allocator: mem.Allocator) -> (content: []u8, okay: bool) {
	// lstat, not stat: a symlink where a segment should be is not a segment, and this
	// reader never follows one out of the run directory. The File_Info owns its path,
	// so it is released here rather than left to the allocator's bookkeeping.
	info, stat_err := os.lstat(path, allocator)
	if stat_err != nil { return nil, false }
	defer os.file_info_delete(info, allocator)
	if info.type != .Regular { return nil, false }
	if info.size < 0 || info.size > i64(LOG_SEGMENT_BYTES + LOG_MAX_RECORD_BYTES) { return nil, false }
	bytes, read_err := os.read_entire_file(path, allocator)
	if read_err != nil { return nil, false }
	if len(bytes) > int(info.size) { bytes = bytes[:int(info.size)] }
	return bytes, true
}

// log_read_segment_lines splits one segment into lines and visits those the session
// owns. The final line is reported as a partial tail when it was never completed,
// which is what a crash between two writes leaves behind.
@(private)
log_read_segment_lines :: proc(
	summary: ^Log_Read_Summary,
	run_id: string,
	content: []u8,
	session_id: session.Session_Id,
	selector: Log_Read_Selector,
	user_data: rawptr,
	visit: Log_Read_Visit,
	allocator: mem.Allocator,
) -> bool {
	text := string(content)
	for len(text) > 0 {
		end := strings.index_byte(text, '\n')
		line: string
		if end < 0 {
			// The writer terminates every record with a newline, so a final fragment
			// without one was never completed.
			if len(text) > 0 { summary.partial_tails += 1 }
			return true
		}
		line = text[:end]
		text = text[end + 1:]
		if line == "" { continue }
		if !log_read_line(summary, run_id, line, session_id, selector, user_data, visit, allocator) {
			return false
		}
	}
	return true
}

// log_read_line validates one record's envelope and visits it when it belongs to the
// session being read. Every reason not to visit is counted separately, so a caller
// can tell an unreadable line from a record for someone else.
@(private)
log_read_line :: proc(
	summary: ^Log_Read_Summary,
	run_id: string,
	line: string,
	session_id: session.Session_Id,
	selector: Log_Read_Selector,
	user_data: rawptr,
	visit: Log_Read_Visit,
	allocator: mem.Allocator,
) -> bool {
	value, parse_err := json.parse_string(line, parse_integers = true, allocator = allocator)
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

	// The envelope is checked before anything it contains is believed: a record from
	// an unsupported format version is reported rather than interpreted, and a record
	// whose run id disagrees with its directory is not one this run wrote.
	version, has_version := log_read_integer(object, "version")
	if !has_version || version != i64(LOG_VERSION) {
		summary.records_unsupported += 1
		return true
	}
	recorded_run, has_run := log_read_string(object, "run_id")
	if !has_run || recorded_run != run_id {
		summary.records_foreign += 1
		return true
	}
	if _, has_seq := log_read_integer(object, "seq"); !has_seq {
		summary.records_skipped += 1
		return true
	}

	if event, has_event := log_read_string(object, "event"); has_event && event == "log.segment_removed" {
		// The writer removed a segment and said which sequence range left with it, so
		// a numbering gap is retention rather than loss.
		summary.gaps += 1
		return true
	}

	owner, has_session := log_read_string(object, "session_id")
	if !has_session || owner != string(session_id) { return true }

	if selector.level > log.Level.Debug {
		level_text, has_level := log_read_string(object, "level")
		level, _, known := log_level_parse(level_text)
		if !has_level || !known || level < selector.level { return true }
	}
	if wanted, filtered := selector.request_no.?; filtered {
		request_no, has_request := log_read_integer(object, "request_no")
		if !has_request || session.Request_No(request_no) != wanted { return true }
	}

	summary.records += 1
	if !visit(user_data, run_id, line) {
		summary.stopped = true
		return false
	}
	return true
}

@(private)
log_read_string :: proc(object: json.Object, key: string) -> (string, bool) {
	value, found := object[key]
	if !found { return "", false }
	text, is_text := value.(json.String)
	if !is_text { return "", false }
	return string(text), true
}

@(private)
log_read_integer :: proc(object: json.Object, key: string) -> (i64, bool) {
	value, found := object[key]
	if !found { return 0, false }
	integer, is_integer := value.(json.Integer)
	if !is_integer { return 0, false }
	return i64(integer), true
}
