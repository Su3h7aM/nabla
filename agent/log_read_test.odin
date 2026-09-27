#+test
package agent

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// The reader is held to records the writer produced, so the format has one author
// and the reader cannot drift from it quietly.

Log_Read_Test :: struct {
	lines:   [dynamic]string, // owned copies of what the visitor saw
	runs:    [dynamic]string, // owned copies of the run each line came from
	stopped: bool,
}

log_read_visit :: proc(user_data: rawptr, run_id: string, line: string) -> bool {
	fixture := cast(^Log_Read_Test)user_data
	append(&fixture.lines, strings.clone(line, context.allocator))
	append(&fixture.runs, strings.clone(run_id, context.allocator))
	return !fixture.stopped
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
log_read_test_run :: proc(test: ^testing.T, logs_root: string, session_id: string, age: time.Duration) -> string {
	log: Log
	if _, open_error := log_open(&log, {directory = logs_root, enabled = true, lowest = .Info}); open_error != nil {
		testing.fail_now(test, "a run could not be opened")
	}
	run_id := strings.clone(log.run_id, context.allocator)
	directory := strings.clone(log.directory, context.allocator)
	defer delete(directory, context.allocator)

	// The writer is its own scope here, so the binding lives for the whole run.
	binding := Log_Binding {
		sink = &log,
	}
	context.logger = log_logger(&binding)
	log_emit({level = .Info, category = .Runtime, event = "run.started"})
	binding.correlation = Log_Correlation {
		session_id = session_id,
		turn_no    = 1,
	}
	log_emit({level = .Info, category = .Agent, event = "turn.started"})
	_ = log_close(&log)
	log_test_age_run(test, directory, age)
	return run_id
}

log_read_run_directory :: proc(logs_root, run_id: string) -> string {
	runs_directory, _ := log_path_join(logs_root, LOG_RUNS_DIRECTORY, context.temp_allocator)
	directory, _ := log_path_join(runs_directory, run_id, context.temp_allocator)
	return directory
}

@(test)
test_log_segment_names_are_recognized :: proc(test: ^testing.T) {
	number, written := log_segment_name_number("events-000001.jsonl")
	testing.expect(test, written && number == 1, "a written segment is recognized")

	_, lease := log_segment_name_number("lease")
	testing.expect(test, !lease, "the lease is not a segment")
	_, unpadded := log_segment_name_number("events-1.jsonl")
	testing.expect(test, !unpadded, "an unpadded number is not a segment")
	_, temporary := log_segment_name_number("events-000001.jsonl.tmp")
	testing.expect(test, !temporary, "a temporary file is not a segment")
	_, nondigit := log_segment_name_number("events-00000a.jsonl")
	testing.expect(test, !nondigit, "a non-digit is not a segment")
	_, embedded := log_segment_name_number("events-00001x.jsonl")
	testing.expect(test, !embedded, "a mixed name is not a segment")
	_, other := log_segment_name_number("other-000001.jsonl")
	testing.expect(test, !other, "another prefix is not a segment")
	_, bare := log_segment_name_number("000001.jsonl")
	testing.expect(test, !bare, "a bare number is not a segment")

	// A run that rotated past six digits keeps its numbers, which is what the
	// reader sorts by.
	wide, wide_ok := log_segment_name_number("events-1234567.jsonl")
	testing.expect(test, wide_ok && wide == 1_234_567, "a long segment number is read")
}

@(test)
test_log_read_visits_only_the_session :: proc(test: ^testing.T) {
	logs_root := log_test_root(test)
	defer log_test_root_remove(logs_root)
	session_id := "00112233445566778899aabbccddeeff"

	run_id := log_read_test_run(test, logs_root, session_id, time.Minute)
	defer delete(run_id, context.allocator)

	fixture: Log_Read_Test
	summary := log_read_session(logs_root, session_id, &fixture, log_read_visit)
	defer log_read_collect_destroy(&fixture)

	// The run wrote two records and only the session's own was visited.
	testing.expect_value(test, summary.runs_scanned, 1)
	testing.expect_value(test, summary.files_read, 1)
	testing.expect_value(test, summary.records, 1)
	testing.expect_value(test, len(fixture.lines), 1)
	testing.expect(test, strings.contains(fixture.lines[0], `"event":"turn.started"`), "the session's record is visited")
	testing.expect(test, !strings.contains(fixture.lines[0], `"event":"run.started"`), "a run-level record is not")
	testing.expect_value(test, fixture.runs[0], run_id)
	testing.expect_value(test, summary.records_skipped, 0)
	testing.expect_value(test, summary.cannot_read, 0)

	// Another session is not the one whose records these are.
	other: Log_Read_Test
	other_summary := log_read_session(logs_root, "ffeeddccbbaa99887766554433221100", &other, log_read_visit)
	defer log_read_collect_destroy(&other)
	testing.expect_value(test, other_summary.records, 0)
}

@(test)
test_log_read_orders_runs_oldest_first :: proc(test: ^testing.T) {
	logs_root := log_test_root(test)
	defer log_test_root_remove(logs_root)
	session_id := "00112233445566778899aabbccddeeff"

	// One session across two runs, the second written later and named as newer.
	older := log_read_test_run(test, logs_root, session_id, 2 * time.Hour)
	defer delete(older, context.allocator)
	newer := log_read_test_run(test, logs_root, session_id, time.Hour)
	defer delete(newer, context.allocator)

	fixture: Log_Read_Test
	summary := log_read_session(logs_root, session_id, &fixture, log_read_visit)
	defer log_read_collect_destroy(&fixture)

	testing.expect_value(test, summary.runs_scanned, 2)
	testing.expect_value(test, summary.records, 2)
	testing.expect_value(test, len(fixture.lines), 2)
	testing.expect(test, strings.contains(fixture.lines[0], older), "the older run is read first")
	testing.expect(test, strings.contains(fixture.lines[1], newer), "the newer run is read second")
	testing.expect_value(test, fixture.runs[0], older)
	testing.expect_value(test, fixture.runs[1], newer)
}

@(test)
test_log_read_stops_when_the_visitor_stops :: proc(test: ^testing.T) {
	logs_root := log_test_root(test)
	defer log_test_root_remove(logs_root)
	session_id := "00112233445566778899aabbccddeeff"

	older := log_read_test_run(test, logs_root, session_id, 2 * time.Hour)
	defer delete(older, context.allocator)
	newer := log_read_test_run(test, logs_root, session_id, time.Hour)
	defer delete(newer, context.allocator)

	fixture: Log_Read_Test
	fixture.stopped = true
	summary := log_read_session(logs_root, session_id, &fixture, log_read_visit)
	defer log_read_collect_destroy(&fixture)

	// One record was enough for the visitor; the newer run is left unread.
	testing.expect_value(test, summary.records, 1)
	testing.expect_value(test, len(fixture.lines), 1)
	testing.expect_value(test, summary.runs_scanned, 1)
	testing.expect(test, summary.stopped)
}

@(test)
test_log_read_reports_a_line_it_cannot_parse :: proc(test: ^testing.T) {
	logs_root := log_test_root(test)
	defer log_test_root_remove(logs_root)
	session_id := "00112233445566778899aabbccddeeff"

	run_id := log_read_test_run(test, logs_root, session_id, time.Minute)
	defer delete(run_id, context.allocator)

	// A torn final line is what a crash leaves behind, and it must not stop the read
	// or be passed off as a record.
	segment := log_test_directory_segment(log_read_run_directory(logs_root, run_id), 1)
	file, open_error := os.open(segment, {.Write, .Append})
	if open_error != nil { testing.fail_now(test, "the segment could not be opened to append") }
	os.write_string(file, "{\"version\":1,\"event\"")
	os.close(file)

	fixture: Log_Read_Test
	summary := log_read_session(logs_root, session_id, &fixture, log_read_visit)
	defer log_read_collect_destroy(&fixture)

	testing.expect_value(test, summary.records, 1)
	testing.expect_value(test, summary.partial_tails, 1)
	testing.expect_value(test, summary.records_skipped, 0)
	testing.expect_value(test, len(fixture.lines), 1)
}

@(test)
test_log_read_reports_missing_directories :: proc(test: ^testing.T) {
	logs_root := log_test_root(test)
	defer log_test_root_remove(logs_root)
	session_id := "00112233445566778899aabbccddeeff"
	fixture: Log_Read_Test
	defer log_read_collect_destroy(&fixture)

	// No writer has created runs/ yet.
	summary := log_read_session(logs_root, session_id, &fixture, log_read_visit)
	testing.expect_value(test, summary.cannot_read, 1)
	testing.expect_value(test, summary.records, 0)

	// Retention can remove a run between listing runs/ and opening the run.
	run := Log_Read_Run {
		path   = logs_root,
		run_id = "00112233445566778899aabbccddeeff",
	}
	testing.expect(test, os.remove_all(logs_root) == nil)
	summary = {}
	testing.expect(test, log_read_run(&summary, run, session_id, {}, &fixture, log_read_visit, context.allocator))
	testing.expect_value(test, summary.cannot_read, 1)
	testing.expect_value(test, summary.files_read, 0)
}

// log_read_test_raw_run writes one run directory with exactly the text given, which
// is what a test needs to hand the reader a record the writer would never produce.
log_read_test_raw_run :: proc(test: ^testing.T, logs_root, run_id, text: string) {
	runs_directory, _ := log_path_join(logs_root, LOG_RUNS_DIRECTORY, context.allocator)
	defer delete(runs_directory, context.allocator)
	if make_error := os.make_directory_all(runs_directory, LOG_DIRECTORY_PERMISSIONS); make_error != nil && make_error != .Exist {
		testing.fail_now(test, "the runs directory could not be created")
	}
	run_directory, _ := log_path_join(runs_directory, run_id, context.allocator)
	defer delete(run_directory, context.allocator)
	if make_error := os.make_directory(run_directory, LOG_DIRECTORY_PERMISSIONS); make_error != nil {
		testing.fail_now(test, "the run directory could not be created")
	}
	file, open_error := os.open(log_test_directory_segment(run_directory, 1), {.Write, .Create, .Trunc})
	if open_error != nil { testing.fail_now(test, "the segment could not be created") }
	defer os.close(file)
	if _, write_error := os.write_string(file, text); write_error != nil {
		testing.fail_now(test, "the segment could not be written")
	}
}

// log_read_test_record builds one complete record line, so a test can vary the
// fields that matter to the reader and nothing else.
log_read_test_record :: proc(run_id: string, sequence: int, level: string, event: string, session_id := "", request_no := 0) -> string {
	parts := make([dynamic]string, 0, 12, context.temp_allocator)
	append(&parts, `{"version":1,"run_id":"`)
	append(&parts, run_id)
	append(&parts, `","seq":`)
	append(&parts, fmt.tprintf("%d", sequence))
	append(&parts, `,"level":"`)
	append(&parts, level)
	append(&parts, `","category":"agent","event":"`)
	append(&parts, event)
	append(&parts, `"`)
	if session_id != "" {
		append(&parts, `,"session_id":"`)
		append(&parts, session_id)
		append(&parts, `"`)
	}
	if request_no != 0 {
		append(&parts, `,"request_no":`)
		append(&parts, fmt.tprintf("%d", request_no))
	}
	append(&parts, `}`)
	return strings.concatenate(parts[:], context.temp_allocator)
}

@(test)
test_log_read_reports_records_it_cannot_interpret :: proc(test: ^testing.T) {
	logs_root := log_test_root(test)
	defer log_test_root_remove(logs_root)
	run_id := "00112233445566778899aabbccddeeff"
	session_id := run_id

	text := strings.concatenate(
		{
			log_read_test_record("aaaabbbbccccddddeeeeffff00001111", 1, "info", "agent.transition"),
			"\n",
			log_read_test_record(run_id, 2, "info", "agent.transition", session_id),
			"\n",
			strings.concatenate(
				{`{"version":99,"run_id":"`, run_id, `","seq":3,"level":"info","category":"agent","event":"agent.transition","session_id":"`, run_id, `"}`},
				context.temp_allocator,
			),
			"\n",
		},
		context.temp_allocator,
	)
	log_read_test_raw_run(test, logs_root, run_id, text)

	fixture: Log_Read_Test
	summary := log_read_session(logs_root, session_id, &fixture, log_read_visit)
	defer log_read_collect_destroy(&fixture)

	// Only the record written by this run, in this format, is visited. The other two
	// are counted with the reason they were not, rather than interpreted.
	testing.expect_value(test, summary.records, 1)
	testing.expect_value(test, summary.records_foreign, 1)
	testing.expect_value(test, summary.records_unsupported, 1)
	testing.expect_value(test, summary.records_skipped, 0)
}

@(test)
test_log_read_counts_a_segment_the_writer_removed :: proc(test: ^testing.T) {
	logs_root := log_test_root(test)
	defer log_test_root_remove(logs_root)
	run_id := "00112233445566778899aabbccddeeff"
	session_id := run_id

	text := strings.concatenate(
		{
			log_read_test_record(run_id, 1, "info", "agent.transition", session_id),
			"\n",
			// What the writer leaves behind when retention drops an old segment: the
			// sequence range that left the window, so a numbering gap is explained.
			strings.concatenate(
				{
					`{"version":1,"run_id":"`,
					run_id,
					`","seq":2,"level":"info","category":"diagnostics","event":"log.segment_removed","segment":1,"from_seq":1,"to_seq":40,"removed":true}`,
				},
				context.temp_allocator,
			),
			"\n",
			log_read_test_record(run_id, 41, "info", "agent.transition", session_id),
			"\n",
		},
		context.temp_allocator,
	)
	log_read_test_raw_run(test, logs_root, run_id, text)

	fixture: Log_Read_Test
	summary := log_read_session(logs_root, session_id, &fixture, log_read_visit)
	defer log_read_collect_destroy(&fixture)

	testing.expect_value(test, summary.records, 2)
	testing.expect_value(test, summary.gaps, 1)
}

@(test)
test_log_read_selects_by_level_and_request :: proc(test: ^testing.T) {
	logs_root := log_test_root(test)
	defer log_test_root_remove(logs_root)
	run_id := "00112233445566778899aabbccddeeff"
	session_id := run_id

	text := strings.concatenate(
		{
			log_read_test_record(run_id, 1, "debug", "agent.transition", session_id, 6),
			"\n",
			log_read_test_record(run_id, 2, "info", "agent.transition", session_id, 6),
			"\n",
			log_read_test_record(run_id, 3, "error", "agent.transition", session_id, 6),
			"\n",
			log_read_test_record(run_id, 4, "error", "agent.transition", session_id, 7),
			"\n",
		},
		context.temp_allocator,
	)
	log_read_test_raw_run(test, logs_root, run_id, text)

	fixture: Log_Read_Test
	selector := Log_Read_Selector {
		level      = .Warning,
		request_no = 6,
	}
	summary := log_read_session(logs_root, session_id, &fixture, log_read_visit, selector)
	defer log_read_collect_destroy(&fixture)

	// One record is both at or above the threshold and part of the request asked for.
	testing.expect_value(test, summary.records, 1)
	testing.expect(test, strings.contains(fixture.lines[0], `"seq":3`), "the error of request 6 is the one visited")
}

@(test)
test_log_read_does_not_follow_a_symlink :: proc(test: ^testing.T) {
	logs_root := log_test_root(test)
	defer log_test_root_remove(logs_root)
	run_id := "00112233445566778899aabbccddeeff"
	session_id := run_id

	// A segment name that is a symlink to a readable file: the reader must report
	// what it did not read rather than follow the link out of the run directory.
	log_read_test_raw_run(test, logs_root, run_id, "")
	outside, outside_error := os.make_directory_temp("", "nabla-read-outside-*", context.allocator)
	defer {
		os.remove_all(outside)
		delete(outside, context.allocator)
	}
	if outside_error != nil { testing.fail_now(test, "the outside directory could not be created") }
	target, target_error := os.make_directory_temp("", "nabla-read-target-*", context.allocator)
	defer {
		os.remove_all(target)
		delete(target, context.allocator)
	}
	if target_error != nil { testing.fail_now(test, "the target directory could not be created") }

	runs_directory, _ := log_path_join(logs_root, LOG_RUNS_DIRECTORY, context.temp_allocator)
	run_directory, _ := log_path_join(runs_directory, run_id, context.temp_allocator)
	segment := log_test_directory_segment(run_directory, 1)
	_ = os.remove(segment)
	if link_error := os.symlink(logs_root, segment); link_error != nil {
		testing.fail_now(test, "the symlink could not be created")
	}

	fixture: Log_Read_Test
	summary := log_read_session(logs_root, session_id, &fixture, log_read_visit)
	defer log_read_collect_destroy(&fixture)

	testing.expect_value(test, summary.records, 0)
	testing.expect_value(test, summary.files_read, 0)
}
