#+test
#+private file
package main

import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "nabla:agent"
import "nabla:agent/session"

// diagnostics_export_err collects what the export reports, so a passing test
// leaves the test runner's own output alone.
diagnostics_export_err :: proc(builder: ^strings.Builder) -> io.Writer {
	return strings.to_writer(builder)
}

// The export is driven through the real writer and the real reader: a run is
// written with a logger, then the bundle is read back off disk. The manifest is part
// of what is checked, because it is what makes an incomplete bundle legible.

export_test_join :: proc(parts: ..string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}

// export_test_run writes one run holding a run-level record and one record for the
// session, and returns the run id the caller must free.
export_test_run :: proc(t: ^testing.T, logs_root: string, session_id: session.Session_Id) -> string {
	log_record: agent.Log
	_, open_err := agent.log_open(&log_record, {directory = logs_root, enabled = true, lowest = .Info}, context.allocator)
	if open_err != nil { testing.fail_now(t, "the log could not be opened") }
	run_id := strings.clone(log_record.run_id, context.allocator)

	// The run-level record carries no session, which is what keeps it out of the
	// session stream, so the correlation is narrowed only for the turn's record.
	binding := agent.Log_Binding {
		sink = &log_record,
	}
	context.logger = agent.log_logger(&binding)
	agent.log_emit(agent.Log_Record{level = .Info, category = .Runtime, event = "run.started"})
	binding.correlation = agent.Log_Correlation {
		session_id = session_id,
		turn_no    = 1,
	}
	agent.log_emit(agent.Log_Record{level = .Info, category = .Agent, event = "turn.started"})
	_ = agent.log_close(&log_record)
	return run_id
}

export_test_text :: proc(t: ^testing.T, parts: ..string) -> string {
	content, read_err := os.read_entire_file(export_test_join(..parts), context.allocator)
	if read_err != nil { testing.fail_now(t, "an exported file could not be read") }
	return string(content)
}

export_test_logs_root :: proc(t: ^testing.T) -> string {
	directory, make_err := os.make_directory_temp("", "nabla-export-logs-*", context.allocator)
	if make_err != nil { testing.fail_now(t, "the logs root could not be created") }
	return directory
}

export_test_logs_root_remove :: proc(directory: string) {
	os.remove_all(directory)
	delete(directory, context.allocator)
}

@(test)
test_export_writes_a_bounded_bundle_with_a_manifest :: proc(t: ^testing.T) {
	logs_root := export_test_logs_root(t)
	defer export_test_logs_root_remove(logs_root)
	destination, destination_err := os.make_directory_temp("", "nabla-export-out-*", context.allocator)
	defer {
		os.remove_all(destination)
		delete(destination, context.allocator)
	}
	if destination_err != nil { testing.fail_now(t, "the destination could not be created") }
	// The export creates its destination exclusively, so the filled temporary
	// directory is removed first.
	_ = os.remove_all(destination)

	session_id := session.Session_Id("00112233445566778899aabbccddeeff")
	run_id := export_test_run(t, logs_root, session_id)
	defer delete(run_id, context.allocator)

	err_text: strings.Builder
	defer strings.builder_destroy(&err_text)
	testing.expect_value(t, diagnostics_export(logs_root, session_id, destination, {}, false, true, diagnostics_export_err(&err_text)), 0)
	testing.expect(t, strings.contains(strings.to_string(err_text), "exported"), "the export should be reported")

	session_text := export_test_text(t, destination, "session.jsonl")
	defer delete(session_text, context.allocator)
	testing.expect(t, strings.contains(session_text, `"event":"turn.started"`), "the session's own record is exported")
	testing.expect(t, !strings.contains(session_text, `"event":"run.started"`), "a run-level record is not in the session stream")

	// The run's own stream is copied whole, framing included, so the bundle reads the
	// way the run was written.
	run_text := export_test_text(t, destination, "runs", run_id, "events.jsonl")
	defer delete(run_text, context.allocator)
	testing.expect(t, strings.contains(run_text, `"event":"run.started"`), "the run's framing is copied")
	testing.expect(t, strings.contains(run_text, `"event":"turn.started"`), "the run's records are copied")

	manifest := export_test_text(t, destination, "manifest.json")
	defer delete(manifest, context.allocator)
	for needle in ([]string{`"session_id": "00112233445566778899aabbccddeeff"`, `"session.jsonl"`, `"runs/`, `"sha256"`, `"include_payloads": false`}) {
		testing.expectf(t, strings.contains(manifest, needle), "the manifest should contain %s", needle)
	}
}

@(test)
test_export_refuses_a_destination_that_already_exists :: proc(t: ^testing.T) {
	logs_root := export_test_logs_root(t)
	defer export_test_logs_root_remove(logs_root)
	destination, destination_err := os.make_directory_temp("", "nabla-export-taken-*", context.allocator)
	defer {
		os.remove_all(destination)
		delete(destination, context.allocator)
	}
	if destination_err != nil { testing.fail_now(t, "the destination could not be created") }

	session_id := session.Session_Id("00112233445566778899aabbccddeeff")
	run_id := export_test_run(t, logs_root, session_id)
	defer delete(run_id, context.allocator)

	// An export never writes where something already is, so a bundle cannot be mixed
	// with what a previous one left behind.
	err_text: strings.Builder
	defer strings.builder_destroy(&err_text)
	testing.expect_value(t, diagnostics_export(logs_root, session_id, destination, {}, false, true, diagnostics_export_err(&err_text)), 1)
	testing.expect(t, !os.exists(export_test_join(destination, EXPORT_MANIFEST_NAME)), "nothing is written into an existing directory")
}

@(test)
test_export_omits_payloads_unless_asked :: proc(t: ^testing.T) {
	logs_root := export_test_logs_root(t)
	defer export_test_logs_root_remove(logs_root)
	session_id := session.Session_Id("00112233445566778899aabbccddeeff")
	run_id := export_test_run(t, logs_root, session_id)
	defer delete(run_id, context.allocator)

	// An artifact the run left behind, standing in for one payload capture would have
	// written.
	captures := export_test_join(logs_root, agent.LOG_RUNS_DIRECTORY, run_id, EXPORT_CAPTURES_DIRECTORY)
	if make_err := os.make_directory_all(captures, EXPORT_DIRECTORY_PERMISSIONS); make_err != nil && make_err != .Exist {
		testing.fail_now(t, "the capture directory could not be created")
	}
	file, open_err := os.open(export_test_join(captures, "000001-request.body"), {.Write, .Create, .Trunc}, EXPORT_FILE_PERMISSIONS)
	if open_err != nil { testing.fail_now(t, "the artifact could not be created") }
	_, _ = os.write_string(file, "payload")
	_ = os.close(file)

	metadata_only, metadata_err := os.make_directory_temp("", "nabla-export-meta-*", context.allocator)
	defer {
		os.remove_all(metadata_only)
		delete(metadata_only, context.allocator)
	}
	if metadata_err != nil { testing.fail_now(t, "the destination could not be created") }
	_ = os.remove_all(metadata_only)
	err_meta, err_payloads: strings.Builder
	defer strings.builder_destroy(&err_meta)
	defer strings.builder_destroy(&err_payloads)
	testing.expect_value(t, diagnostics_export(logs_root, session_id, metadata_only, {}, false, true, diagnostics_export_err(&err_meta)), 0)
	testing.expect(t, !os.exists(export_test_join(metadata_only, "runs", run_id, EXPORT_CAPTURES_DIRECTORY)), "payloads are not copied by default")
	manifest := export_test_text(t, metadata_only, "manifest.json")
	defer delete(manifest, context.allocator)
	testing.expect(t, strings.contains(manifest, "payload captures that were not included"), "the omission is recorded")

	with_payloads, payloads_err := os.make_directory_temp("", "nabla-export-payloads-*", context.allocator)
	defer {
		os.remove_all(with_payloads)
		delete(with_payloads, context.allocator)
	}
	if payloads_err != nil { testing.fail_now(t, "the destination could not be created") }
	_ = os.remove_all(with_payloads)
	testing.expect_value(t, diagnostics_export(logs_root, session_id, with_payloads, {}, true, true, diagnostics_export_err(&err_payloads)), 0)
	artifact := export_test_text(t, with_payloads, "runs", run_id, EXPORT_CAPTURES_DIRECTORY, "000001-request.body")
	defer delete(artifact, context.allocator)
	testing.expect_value(t, artifact, "payload")
}

@(test)
test_export_selector_narrows_the_session_stream :: proc(t: ^testing.T) {
	logs_root := export_test_logs_root(t)
	defer export_test_logs_root_remove(logs_root)
	session_id := session.Session_Id("00112233445566778899aabbccddeeff")
	run_id := export_test_run(t, logs_root, session_id)
	defer delete(run_id, context.allocator)

	destination, destination_err := os.make_directory_temp("", "nabla-export-select-*", context.allocator)
	defer {
		os.remove_all(destination)
		delete(destination, context.allocator)
	}
	if destination_err != nil { testing.fail_now(t, "the destination could not be created") }
	_ = os.remove_all(destination)

	// The run's own records are Info, so a floor above that leaves the session stream
	// empty while the manifest still describes the selection.
	selector := agent.Log_Read_Selector {
		level = .Error,
	}
	err_text: strings.Builder
	defer strings.builder_destroy(&err_text)
	testing.expect_value(t, diagnostics_export(logs_root, session_id, destination, selector, false, true, diagnostics_export_err(&err_text)), 0)
	session_text := export_test_text(t, destination, "session.jsonl")
	defer delete(session_text, context.allocator)
	testing.expect_value(t, session_text, "")

	manifest := export_test_text(t, destination, "manifest.json")
	defer delete(manifest, context.allocator)
	testing.expect(t, strings.contains(manifest, `"level_floor": "error"`), "the manifest states the selection")
}
