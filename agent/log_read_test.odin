#+test
package agent

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "nabla:agent/session"

// The reader is held to records the writer produced, so the format has one author
// and the reader cannot drift from it quietly.

Log_Read_Test :: struct {
	lines: [dynamic]string, // owned copies of what the visitor saw
	runs:  [dynamic]string, // owned copies of the run each line came from
}

log_read_visit :: proc(user_data: rawptr, run_id: string, line: string) -> bool {
	fixture := cast(^Log_Read_Test)user_data
	append(&fixture.lines, strings.clone(line, context.allocator))
	append(&fixture.runs, strings.clone(run_id, context.allocator))
	return true
}

log_read_collect_destroy :: proc(fixture: ^Log_Read_Test) {
	for line in fixture.lines { delete(line, context.allocator) }
	delete(fixture.lines)
	for run in fixture.runs { delete(run, context.allocator) }
	delete(fixture.runs)
	fixture^ = {}
}

// log_read_test_run writes one run that holds a run-level record and one record for
// the session, then closes it. age places the run in time, so a test can name which
// of two runs is older. The returned run id is owned by the caller.
log_read_test_run :: proc(t: ^testing.T, logs_root: string, session_id: session.Session_Id, age: time.Duration) -> string {
	log: Log
	if open_err := log_open(&log, {directory = logs_root, level = .Info}); open_err != nil {
		testing.fail_now(t, "a run could not be opened")
	}
	run_id := strings.clone(log.run_id, context.allocator)
	directory := strings.clone(log.directory, context.allocator)
	defer delete(directory, context.allocator)

	log_emit(Log_Context{log = &log}, Log_Record{level = .Info, category = .Runtime, event = "run.started"})
	log_emit(Log_Context{log = &log, session_id = session_id, turn_no = 1}, Log_Record{level = .Info, category = .Agent, event = "turn.started"})
	log_close(&log)
	log_test_age_run(t, directory, age)
	return run_id
}

log_read_run_directory :: proc(logs_root, run_id: string) -> string {
	runs_directory, _ := log_path_join(logs_root, LOG_RUNS_DIRECTORY, context.temp_allocator)
	directory, _ := log_path_join(runs_directory, run_id, context.temp_allocator)
	return directory
}

@(test)
test_log_segment_names_are_recognized :: proc(t: ^testing.T) {
	testing.expect(t, log_segment_name_valid("events-000001.jsonl"), "a written segment is recognized")
	testing.expect(t, !log_segment_name_valid("lease"), "the lease is not a segment")
	testing.expect(t, !log_segment_name_valid("events-1.jsonl"), "an unpadded number is not a segment")
	testing.expect(t, !log_segment_name_valid("events-000001.jsonl.tmp"), "a temporary file is not a segment")
	testing.expect(t, !log_segment_name_valid("events-00000a.jsonl"), "a non-digit is not a segment")
}

@(test)
test_log_read_visits_only_the_session :: proc(t: ^testing.T) {
	logs_root := log_test_root(t)
	defer log_test_root_remove(logs_root)
	session_id := session.Session_Id("00112233445566778899aabbccddeeff")

	run_id := log_read_test_run(t, logs_root, session_id, time.Minute)
	defer delete(run_id, context.allocator)

	fixture: Log_Read_Test
	summary := log_read_session(logs_root, session_id, &fixture, log_read_visit)
	defer log_read_collect_destroy(&fixture)

	// The run wrote two records and only the session's own was visited.
	testing.expect_value(t, summary.runs_scanned, 1)
	testing.expect_value(t, summary.files_read, 1)
	testing.expect_value(t, summary.records, 1)
	testing.expect_value(t, len(fixture.lines), 1)
	testing.expect(t, strings.contains(fixture.lines[0], `"event":"turn.started"`), "the session's record is visited")
	testing.expect(t, !strings.contains(fixture.lines[0], `"event":"run.started"`), "a run-level record is not")
	testing.expect_value(t, fixture.runs[0], run_id)
	testing.expect_value(t, summary.records_skipped, 0)
	testing.expect_value(t, summary.files_skipped, 0)

	// Another session is not the one whose records these are.
	other: Log_Read_Test
	other_summary := log_read_session(logs_root, session.Session_Id("ffeeddccbbaa99887766554433221100"), &other, log_read_visit)
	defer log_read_collect_destroy(&other)
	testing.expect_value(t, other_summary.records, 0)
}

@(test)
test_log_read_orders_runs_oldest_first :: proc(t: ^testing.T) {
	logs_root := log_test_root(t)
	defer log_test_root_remove(logs_root)
	session_id := session.Session_Id("00112233445566778899aabbccddeeff")

	// One session across two runs, the second written later and named as newer.
	older := log_read_test_run(t, logs_root, session_id, 2 * time.Hour)
	defer delete(older, context.allocator)
	newer := log_read_test_run(t, logs_root, session_id, time.Hour)
	defer delete(newer, context.allocator)

	fixture: Log_Read_Test
	summary := log_read_session(logs_root, session_id, &fixture, log_read_visit)
	defer log_read_collect_destroy(&fixture)

	testing.expect_value(t, summary.runs_scanned, 2)
	testing.expect_value(t, summary.records, 2)
	testing.expect_value(t, len(fixture.lines), 2)
	testing.expect(t, strings.contains(fixture.lines[0], older), "the older run is read first")
	testing.expect(t, strings.contains(fixture.lines[1], newer), "the newer run is read second")
	testing.expect_value(t, fixture.runs[0], older)
	testing.expect_value(t, fixture.runs[1], newer)
}

@(test)
test_log_read_reports_a_line_it_cannot_parse :: proc(t: ^testing.T) {
	logs_root := log_test_root(t)
	defer log_test_root_remove(logs_root)
	session_id := session.Session_Id("00112233445566778899aabbccddeeff")

	run_id := log_read_test_run(t, logs_root, session_id, time.Minute)
	defer delete(run_id, context.allocator)

	// A torn final line is what a crash leaves behind, and it must not stop the read
	// or be passed off as a record.
	segment := log_test_directory_segment(log_read_run_directory(logs_root, run_id), 1)
	file, open_err := os.open(segment, {.Write, .Append})
	if open_err != nil { testing.fail_now(t, "the segment could not be opened to append") }
	os.write_string(file, "{\"version\":1,\"event\"")
	os.close(file)

	fixture: Log_Read_Test
	summary := log_read_session(logs_root, session_id, &fixture, log_read_visit)
	defer log_read_collect_destroy(&fixture)

	testing.expect_value(t, summary.records, 1)
	testing.expect_value(t, summary.records_skipped, 1)
	testing.expect_value(t, len(fixture.lines), 1)
}
