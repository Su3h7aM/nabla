#+test
package main

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "nabla:agent"

// Log_Fixture holds a real writer, because the point of these tests is a record that
// outlives the process it describes. A logger is implicit state of the calling scope, so a
// helper cannot install it for its caller: the test that emits sets `context.logger` from
// `fixture.logger` itself.

Log_Fixture :: struct {
	sink:      agent.Log,
	binding:   agent.Log_Binding,
	directory: string,
	logger:    log.Logger,
}

log_fixture_open :: proc(t: ^testing.T, fixture: ^Log_Fixture) {
	directory, directory_err := os.make_directory_temp("", "nabla-test-log-*", context.allocator)
	if directory_err != nil { testing.fail_now(t, "the test directory could not be created") }
	fixture.directory = directory
	_, open_err := agent.log_open(&fixture.sink, {directory = directory, enabled = true, lowest = .Debug})
	if open_err != nil { testing.fail_now(t, "the log could not be opened") }
	fixture.binding = agent.Log_Binding {
		sink = &fixture.sink,
	}
	fixture.logger = agent.log_logger(&fixture.binding)
}

log_fixture_close :: proc(t: ^testing.T, fixture: ^Log_Fixture) {
	_ = agent.log_close(&fixture.sink)
	os.remove_all(fixture.directory)
	delete(fixture.directory, context.allocator)
}

// log_fixture_records returns everything the run wrote. The writer names its own run
// directory, so the test finds it rather than rebuilding an id it cannot know.
log_fixture_records :: proc(fixture: ^Log_Fixture) -> string {
	builder := strings.builder_make(context.temp_allocator)
	runs := strings.concatenate({fixture.directory, "/runs"}, context.temp_allocator)
	run_dirs, runs_err := os.read_directory_by_path(runs, 8, context.temp_allocator)
	if runs_err != nil { return "" }
	for run in run_dirs {
		segments, segments_err := os.read_directory_by_path(run.fullpath, 8, context.temp_allocator)
		if segments_err != nil { continue }
		for segment in segments {
			data, read_err := os.read_entire_file_from_path(segment.fullpath, context.temp_allocator)
			if read_err != nil { continue }
			strings.write_bytes(&builder, data)
		}
	}
	return strings.to_string(builder)
}
