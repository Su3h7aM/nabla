#+test
#+private file
package main

import "core:io"
import "core:strings"
import "core:testing"

@(test)
test_diagnostics_writes_jsonl :: proc(t: ^testing.T) {
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	output := Diagnostics_Output {
		writer = strings.to_writer(&builder),
	}
	line := `{"event":"turn.started"}`
	testing.expect(t, diagnostics_visit(&output, "", line))
	testing.expect_value(t, strings.to_string(builder), "{\"event\":\"turn.started\"}\n")
	testing.expect(t, !output.broken)
}

Diagnostics_Test_Writer :: struct {
	calls:       int,
	fail_on:     int,
	short_write: bool,
}

diagnostics_test_write :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
	if mode != .Write { return 0, .Unsupported }
	writer := cast(^Diagnostics_Test_Writer)data
	writer.calls += 1
	if writer.calls == writer.fail_on {
		if writer.short_write { return i64(len(p) - 1), nil }
		return 0, .Closed
	}
	return i64(len(p)), nil
}

@(test)
test_diagnostics_stops_on_output_failure :: proc(t: ^testing.T) {
	// Test both the JSON and its newline, including short writes without an error.
	for fail_on in 1 ..= 2 {
		for short_write in 0 ..= 1 {
			writer := Diagnostics_Test_Writer {
				fail_on     = fail_on,
				short_write = short_write == 1,
			}
			output := Diagnostics_Output {
				writer = {procedure = diagnostics_test_write, data = &writer},
			}
			testing.expect(t, !diagnostics_visit(&output, "", `{"event":"turn.started"}`))
			testing.expect(t, output.broken)
			testing.expect_value(t, writer.calls, fail_on)
		}
	}
}
